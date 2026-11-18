#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
monitor-v2.py -- resumable long-run stability monitor.

Writes one JSONL record per sample, flushes immediately, and can be stopped and
restarted without losing history (-Resume reads the existing file and continues
the count). Prints an aggregate report at the end (or on Ctrl+C).

Designed for the 24h acceptance run:
    python monitor-v2.py --hours 24 --interval 60 --out test-results/soak-24h.jsonl

A run that has not completed its full duration is reported as PENDING by the
caller; this tool never claims more than the samples it actually wrote.

Exit codes: 0 completed, 5 below threshold, 6 setup error.
"""
import argparse
import json
import math
import os
import socket
import ssl
import sys
import time
from concurrent.futures import ThreadPoolExecutor

IP_ENDPOINTS = ["https://api.ipify.org", "https://ifconfig.me/ip", "https://icanhazip.com"]


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed")
        buf += c
    return buf


def socks5_connect(sock, host, port, timeout):
    sock.sendall(b"\x05\x01\x00")
    rep = recv_exact(sock, 2)
    if rep[1] == 0xFF:
        raise RuntimeError("no acceptable auth method")
    if rep[1] == 0x02:
        raise RuntimeError("proxy demands auth (use Clash mixed port)")
    h = host.encode()
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + port.to_bytes(2, "big"))
    hdr = recv_exact(sock, 4)
    if hdr[1] != 0:
        raise RuntimeError("CONNECT rep 0x%02x" % hdr[1])
    atyp = hdr[3]
    if atyp == 1:
        recv_exact(sock, 6)
    elif atyp == 3:
        recv_exact(sock, recv_exact(sock, 1)[0] + 2)
    else:
        recv_exact(sock, 18)


def https_via(sock, host, path):
    ctx = ssl.create_default_context()
    ss = ctx.wrap_socket(sock, server_hostname=host)
    ss.settimeout(25)
    ss.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: soak/2\r\n"
                "Connection: close\r\nAccept: */*\r\n\r\n" % (path, host)).encode())
    data = b""
    while True:
        c = ss.recv(4096)
        if not c:
            break
        data += c
        if len(data) > 65536:
            break
    head, _, body = data.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].decode("latin-1", "replace")
    return status, body.decode("latin-1", "replace").strip()


def sample(proxy, expect, timeout):
    from urllib.parse import urlsplit
    r = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "ok": False, "ms": None,
         "exit_ip": None, "error": None, "kind": None}
    t0 = time.time()
    host = None
    sock = None
    try:
        url = IP_ENDPOINTS[int(time.time()) % len(IP_ENDPOINTS)]
        u = urlsplit(url)
        host, path = u.hostname, u.path or "/"
        if proxy is None:
            sock = socket.create_connection((host, 443), timeout=timeout)
        else:
            ph, pp = proxy
            sock = socket.create_connection((ph, pp), timeout=timeout)
            sock.settimeout(timeout)
            socks5_connect(sock, host, 443, timeout)
        status, body = https_via(sock, host, path)
        ip = body.strip().split("\n")[0].strip()
        r["exit_ip"] = ip[:40]
        r["status"] = status
        if "200" not in status:
            r["error"] = "http status %s" % status
            r["kind"] = "http"
        elif expect and ip != expect:
            r["error"] = "exit mismatch (%s)" % ip
            r["kind"] = "bad_exit"
        else:
            r["ok"] = True
    except socket.timeout:
        r["error"] = "timeout"; r["kind"] = "timeout"
    except ConnectionResetError:
        r["error"] = "reset"; r["kind"] = "reset"
    except ConnectionRefusedError:
        r["error"] = "refused"; r["kind"] = "refused"
    except ssl.SSLError as e:
        r["error"] = "tls: %s" % str(e)[:60]; r["kind"] = "tls"
    except Exception as e:
        r["error"] = "%s: %s" % (type(e).__name__, str(e)[:60]); r["kind"] = "other"
    finally:
        try:
            if sock:
                sock.close()
        except Exception:
            pass
    r["ms"] = round((time.time() - t0) * 1000, 1)
    return r


def pct(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    return round(s[min(len(s) - 1, int(len(s) * q))], 0)


def aggregate(path, expect):
    rows = []
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for ln in f:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    rows.append(json.loads(ln))
                except Exception:
                    pass
    ok = [r for r in rows if r.get("ok")]
    lat = [r["ms"] for r in ok if r.get("ms")]
    kinds = {}
    for r in rows:
        if not r.get("ok"):
            kinds[r.get("kind") or "other"] = kinds.get(r.get("kind") or "other", 0) + 1
    ips = {}
    for r in ok:
        ips[r.get("exit_ip")] = ips.get(r.get("exit_ip"), 0) + 1
    return {
        "samples": len(rows),
        "passed": len(ok),
        "successRate": round(100.0 * len(ok) / max(1, len(rows)), 2),
        "expect": expect,
        "first": rows[0]["ts"] if rows else None,
        "last": rows[-1]["ts"] if rows else None,
        "spanHours": round((time.mktime(time.strptime(rows[-1]["ts"], "%Y-%m-%dT%H:%M:%S")) -
                            time.mktime(time.strptime(rows[0]["ts"], "%Y-%m-%dT%H:%M:%S"))) / 3600, 2) if len(rows) > 1 else 0,
        "latencyMs": {"p50": pct(lat, .5), "p90": pct(lat, .9), "p95": pct(lat, .95), "p99": pct(lat, .99), "max": max(lat) if lat else None},
        "exitIps": ips,
        "failures": kinds,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default="127.0.0.1:7897")
    ap.add_argument("--direct", action="store_true")
    ap.add_argument("--expect", default="auto")
    ap.add_argument("--hours", type=float, default=1.0)
    ap.add_argument("--interval", type=float, default=60.0)
    ap.add_argument("--concurrency", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--out", default="test-results/soak.jsonl")
    a = ap.parse_args()

    proxy = None
    if not a.direct:
        h, p = a.proxy.split(":")
        proxy = (h, int(p))

    expect = None if a.expect in ("auto-none", "") else a.expect
    if expect == "auto":
        # best effort: take the exit reported by the first successful sample
        expect = None

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    existing = 0
    if os.path.exists(a.out):
        with open(a.out, "r", encoding="utf-8") as f:
            existing = sum(1 for ln in f if ln.strip())
    print("# monitor-v2 proxy=%s expect=%s interval=%.0fs hours=%.1f resume_from=%d"
          % ("direct" if a.direct else a.proxy, expect, a.interval, a.hours, existing), flush=True)

    deadline = time.time() + a.hours * 3600
    total = 0
    passed = 0
    n = existing
    try:
        with open(a.out, "a", encoding="utf-8") as f:
            while time.time() < deadline:
                batch = max(1, a.concurrency)
                if batch == 1:
                    r = sample(proxy, expect, a.timeout)
                    recs = [r]
                else:
                    with ThreadPoolExecutor(max_workers=batch) as ex:
                        recs = list(ex.map(lambda _: sample(proxy, expect, a.timeout), range(batch)))
                for r in recs:
                    if r["ok"] and expect is None:
                        expect = r["exit_ip"]
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    f.flush()
                    n += 1
                    total += 1
                    if r["ok"]:
                        passed += 1
                    print("[%s] %s %6sms %s" % (
                        r["ts"][11:], "PASS" if r["ok"] else "FAIL", r["ms"],
                        r["exit_ip"] or r["error"]), flush=True)
                time.sleep(a.interval)
    except KeyboardInterrupt:
        print("\n# interrupted by user", flush=True)

    agg = aggregate(a.out, expect)
    print("\n===== AGGREGATE %s =====" % a.out)
    print(json.dumps(agg, ensure_ascii=False, indent=1))
    complete = (time.time() >= deadline) and (a.hours > 0)
    print("# completed=%s  (a not-completed run must be reported as PENDING)" % complete)
    return 0 if (complete and agg["successRate"] >= 99.0) else (5 if complete else 7)


if __name__ == "__main__":
    sys.exit(main())
