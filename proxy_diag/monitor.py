#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Continuous acceptance monitor for the static proxy.

Runs N full end-to-end attempts (TCP -> SOCKS5 method -> auth -> CONNECT ->
TLS -> GET exit IP) spaced by --interval seconds, records every attempt to
JSONL and prints a final success-rate / latency summary.

Credentials come from env PX_USER / PX_PASS and are never printed.
If the server never selects the user/pass method, no credential byte is ever
transmitted - that is also recorded.

Usage: python monitor.py --runs 20 --interval 30 --out monitor.jsonl
"""
import argparse
import json
import os
import socket
import ssl
import time

HOST = os.environ.get("PX_HOST", "127.0.0.1")
PORT = int(os.environ.get("PX_PORT", "9506"))
USER = os.environ.get("PX_USER", "")
PW = os.environ.get("PX_PASS", "")
IP_HOST = os.environ.get("IP_HOST", "ipinfo.io")
IP_PATH = os.environ.get("IP_PATH", "/ip")
TO = float(os.environ.get("PX_TIMEOUT", "8"))


def rd(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed after %d/%d" % (len(buf), n))
        buf += c
    return buf


def attempt():
    """One full end-to-end attempt. Returns dict."""
    r = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "ok": False,
         "stage": "tcp", "ms": None, "exit_ip": None, "err": None,
         "auth_sent": False}
    s = None
    t0 = time.time()
    try:
        s = socket.create_connection((HOST, PORT), timeout=TO)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        r["ms"] = round((time.time() - t0) * 1000, 1)

        r["stage"] = "greeting"
        s.sendall(b"\x05\x02\x00\x02")
        d = rd(s, 2)
        if d[0] != 5:
            raise ValueError("not socks5 ver=0x%02x" % d[0])
        if d[1] == 0xFF:
            raise ValueError("no acceptable methods")
        if d[1] == 0x02:
            r["stage"] = "auth"
            u, p = USER.encode(), PW.encode()
            s.sendall(bytes([1, len(u)]) + u + bytes([len(p)]) + p)
            r["auth_sent"] = True
            a = rd(s, 2)
            if a[1] != 0:
                raise ValueError("auth rejected 0x%02x" % a[1])

        r["stage"] = "connect"
        th = IP_HOST.encode()
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(th)]) + th + (443).to_bytes(2, "big"))
        h = rd(s, 4)
        if h[1] != 0:
            raise ValueError("connect rep=0x%02x" % h[1])
        atyp = h[3]
        if atyp == 1:
            rd(s, 6)
        elif atyp == 3:
            rd(s, rd(s, 1)[0] + 2)
        elif atyp == 4:
            rd(s, 18)

        r["stage"] = "tls+http"
        ctx = ssl.create_default_context()
        ss = ctx.wrap_socket(s, server_hostname=IP_HOST)
        ss.settimeout(TO)
        ss.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: mon/1.0\r\n"
                    "Connection: close\r\n\r\n" % (IP_PATH, IP_HOST)).encode())
        data = b""
        while True:
            c = ss.recv(4096)
            if not c:
                break
            data += c
            if len(data) > 65536:
                break
        body = data.partition(b"\r\n\r\n")[2].decode("latin-1", "replace")
        ip = body.strip().split("\r\n")[0].strip()
        r["exit_ip"] = ip
        r["ok"] = bool(ip)
        r["ms"] = round((time.time() - t0) * 1000, 1)
    except Exception as e:
        r["err"] = "%s: %s" % (type(e).__name__, str(e)[:90])
        r["ms"] = round((time.time() - t0) * 1000, 1)
    finally:
        try:
            s.close()
        except Exception:
            pass
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=20)
    ap.add_argument("--interval", type=float, default=30.0)
    ap.add_argument("--out", default="monitor.jsonl")
    a = ap.parse_args()

    print("# monitor %s:%d runs=%d interval=%.0fs" % (HOST, PORT, a.runs, a.interval))
    results = []
    with open(a.out, "a", encoding="utf-8") as f:
        for i in range(a.runs):
            r = attempt()
            results.append(r)
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
            f.flush()
            print("[%2d/%d] %s %-11s %7s ms  auth_sent=%-5s %s"
                  % (i + 1, a.runs, "PASS" if r["ok"] else "FAIL", r["stage"],
                     r["ms"], r["auth_sent"], r["exit_ip"] or r["err"] or ""))
            if i < a.runs - 1:
                time.sleep(a.interval)

    ok = [r for r in results if r["ok"]]
    fails = [r for r in results if not r["ok"]]
    print("\n===== SUMMARY =====")
    print("attempts : %d" % len(results))
    print("success  : %d  (%.0f%%)" % (len(ok), 100.0 * len(ok) / max(1, len(results))))
    print("failure  : %d" % len(fails))
    if ok:
        lat = sorted(r["ms"] for r in ok)
        print("latency  : min=%.0f p50=%.0f p95=%.0f max=%.0f ms"
              % (lat[0], lat[len(lat) // 2], lat[min(len(lat) - 1, int(len(lat) * .95))], lat[-1]))
        ips = {}
        for r in ok:
            ips[r["exit_ip"]] = ips.get(r["exit_ip"], 0) + 1
        print("exit ips : %s" % ips)
    if fails:
        st = {}
        for r in fails:
            st[r["stage"]] = st.get(r["stage"], 0) + 1
        print("failures by stage: %s" % st)
        errs = {}
        for r in fails:
            errs[r["err"]] = errs.get(r["err"], 0) + 1
        for e, c in sorted(errs.items(), key=lambda x: -x[1])[:5]:
            print("   %3dx %s" % (c, e))
        print("auth bytes transmitted during failures: %s"
              % any(r["auth_sent"] for r in fails))
    print("window   : %s .. %s" % (results[0]["ts"], results[-1]["ts"]))


if __name__ == "__main__":
    main()
