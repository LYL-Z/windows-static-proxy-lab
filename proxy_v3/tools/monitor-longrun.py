#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
monitor-longrun.py -- long-run stability monitor with honest accounting.

Key rules implemented (per the V3 task book):
  * first-attempt success rate is reported SEPARATELY from post-retry success
  * failed samples are never deleted or re-weighted
  * consecutive-failure streaks and per-hour failure distribution are recorded
  * a run that did not cover its full duration is reported as PENDING, never PASS
  * resumable: re-running appends and continues counting

Usage:
  python monitor-longrun.py --hours 24 --interval 60 --retry 2 --out evidence/soak-24h.jsonl
  python monitor-longrun.py --hours 72 --interval 120 --out evidence/soak-72h.jsonl
"""
import argparse
import json
import os
import socket
import ssl
import sys
import time
from urllib.parse import urlsplit

ENDPOINTS = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"]


def rx(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("closed")
        b += c
    return b


def socks5(s, host, port):
    s.sendall(b"\x05\x01\x00")
    r = rx(s, 2)
    if r[1] == 0xFF:
        raise RuntimeError("no auth method")
    if r[1] == 0x02:
        raise RuntimeError("auth required")
    h = host.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + port.to_bytes(2, "big"))
    hdr = rx(s, 4)
    if hdr[1] != 0:
        raise RuntimeError("CONNECT 0x%02x" % hdr[1])
    atyp = hdr[3]
    if atyp == 1:
        rx(s, 6)
    elif atyp == 3:
        rx(s, rx(s, 1)[0] + 2)
    else:
        rx(s, 18)


def once(proxy, timeout):
    r = {"t": int(time.time()), "ok": False, "ms": None, "ip": None, "err": None, "kind": None}
    t0 = time.time()
    s = None
    try:
        url = ENDPOINTS[r["t"] % len(ENDPOINTS)]
        u = urlsplit(url)
        if proxy is None:
            s = socket.create_connection((u.hostname, 443), timeout=timeout)
        else:
            s = socket.create_connection(proxy, timeout=timeout)
            socks5(s, u.hostname, 443)
        s.settimeout(timeout)
        ss = ssl.create_default_context().wrap_socket(s, server_hostname=u.hostname)
        ss.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n"
                    "User-Agent: soak3\r\n\r\n" % (u.path or "/", u.hostname)).encode())
        data = b""
        while True:
            c = ss.recv(4096)
            if not c:
                break
            data += c
            if len(data) > 65536:
                break
        head, _, body = data.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode("latin-1")
        ip = body.decode("latin-1", "replace").strip().split("\n")[0].strip()
        r["ip"] = ip[:40]
        if "200" not in status:
            r["err"] = "status %s" % status; r["kind"] = "http"
        else:
            r["ok"] = True
        ss.close()
    except socket.timeout:
        r["err"] = "timeout"; r["kind"] = "timeout"
    except ConnectionRefusedError:
        r["err"] = "refused"; r["kind"] = "refused"
    except ConnectionResetError:
        r["err"] = "reset"; r["kind"] = "reset"
    except ssl.SSLError as e:
        r["err"] = "tls: %s" % str(e)[:50]; r["kind"] = "tls"
    except Exception as e:
        r["err"] = "%s: %s" % (type(e).__name__, str(e)[:50]); r["kind"] = "other"
    finally:
        try:
            if s:
                s.close()
        except Exception:
            pass
    r["ms"] = round((time.time() - t0) * 1000, 1)
    return r


def pctl(v, q):
    if not v:
        return None
    s = sorted(v)
    return round(s[min(len(s) - 1, int(len(s) * q))], 0)


def aggregate(path):
    rows = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if ln:
                    try:
                        rows.append(json.loads(ln))
                    except Exception:
                        pass
    first = [r for r in rows if r.get("attempt") == 1]
    fa_ok = [r for r in first if r.get("ok")]
    any_ok = [r for r in rows if r.get("ok")]
    lat = [r["ms"] for r in fa_ok if r.get("ms")]

    # consecutive failure streaks on first attempts
    streak = best = 0
    for r in first:
        if r.get("ok"):
            streak = 0
        else:
            streak += 1
            best = max(best, streak)

    hours = {}
    for r in first:
        h = time.strftime("%Y-%m-%d %H", time.localtime(r["t"]))
        d = hours.setdefault(h, {"n": 0, "fail": 0})
        d["n"] += 1
        if not r.get("ok"):
            d["fail"] += 1

    return {
        "records": len(rows),
        "cycles": len(first),
        "firstAttemptSuccess": round(100.0 * len(fa_ok) / max(1, len(first)), 2),
        "postRetrySuccess": round(100.0 * len(any_ok) / max(1, len(rows)), 2),
        "firstAttemptFailures": len(first) - len(fa_ok),
        "retriesUsed": len(rows) - len(first),
        "maxConsecutiveFirstFailures": best,
        "latencyMs": {"p50": pctl(lat, .5), "p90": pctl(lat, .9), "p95": pctl(lat, .95), "p99": pctl(lat, .99)},
        "firstTs": rows[0]["t"] if rows else None,
        "lastTs": rows[-1]["t"] if rows else None,
        "spannedHours": round((rows[-1]["t"] - rows[0]["t"]) / 3600, 2) if len(rows) > 1 else 0,
        "hourly": hours,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default="127.0.0.1:7897")
    ap.add_argument("--direct", action="store_true")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--interval", type=float, default=60)
    ap.add_argument("--retry", type=int, default=2, help="retries AFTER a failed first attempt")
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--out", default="evidence/soak.jsonl")
    a = ap.parse_args()

    proxy = None if a.direct else tuple(a.proxy.split(":"))
    proxy = (proxy[0], int(proxy[1])) if proxy else None

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    start = time.time()
    end = start + a.hours * 3600
    print("# long-run start %s  hours=%.1f interval=%.0fs retry=%d proxy=%s"
          % (time.strftime("%Y-%m-%d %H:%M:%S"), a.hours, a.interval, a.retry,
             "direct" if a.direct else a.proxy), flush=True)

    with open(a.out, "a", encoding="utf-8") as f:
        cycle = 0
        while time.time() < end:
            cycle += 1
            r = once(proxy, a.timeout)
            r["attempt"] = 1
            r["cycle"] = cycle
            f.write(json.dumps(r) + "\n"); f.flush()
            line = "[%s] #%d attempt1 %s %sms %s" % (
                time.strftime("%H:%M:%S"), cycle, "PASS" if r["ok"] else "FAIL",
                r["ms"], r["ip"] or r["err"])
            if not r["ok"]:
                for k in range(1, a.retry + 1):
                    rr = once(proxy, a.timeout)
                    rr["attempt"] = 1 + k
                    rr["cycle"] = cycle
                    f.write(json.dumps(rr) + "\n"); f.flush()
                    line += " | retry%d %s" % (k, "PASS" if rr["ok"] else "FAIL")
                    if rr["ok"]:
                        break
            print(line, flush=True)
            time.sleep(a.interval)

    agg = aggregate(a.out)
    covered = agg["spannedHours"]
    complete = covered >= a.hours * 0.98
    print("\n===== LONG-RUN AGGREGATE =====")
    print(json.dumps({k: v for k, v in agg.items() if k != "hourly"}, ensure_ascii=False, indent=1))
    print("status: %s (covered %.2fh of %.1fh)" % ("COMPLETE" if complete else "PENDING", covered, a.hours))
    if not complete:
        return 7
    return 0 if agg["firstAttemptSuccess"] >= 99.0 else 5


if __name__ == "__main__":
    sys.exit(main())
