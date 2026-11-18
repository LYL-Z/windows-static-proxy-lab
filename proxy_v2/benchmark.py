#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
benchmark.py -- staged latency benchmark for a local proxy or a direct path.

Measures each phase separately so a slow chain can be attributed:
    connect -> SOCKS5 handshake -> CONNECT -> TLS -> TTFB -> full body

No third-party dependencies. Credentials are never needed: it talks to the
local mixed port (which requires no auth) or runs direct.

Usage:
  python benchmark.py --proxy 127.0.0.1:7897 --samples 30
  python benchmark.py --direct --samples 30
  python benchmark.py --proxy 127.0.0.1:11119 --http --samples 30 --out x.json
"""
import argparse
import json
import socket
import ssl
import statistics
import sys
import time

TARGET_HOST = "api.ipify.org"
TARGET_PATH = "/"


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    i = min(len(s) - 1, int(len(s) * q))
    return round(s[i], 1)


def socks5_handshake(sock, host, port, timeout):
    """no-auth SOCKS5; returns elapsed seconds"""
    t0 = time.time()
    sock.sendall(b"\x05\x01\x00")
    rep = recv_exact(sock, 2)
    if rep[1] == 0xFF:
        raise RuntimeError("proxy rejected no-auth")
    if rep[1] == 0x02:
        raise RuntimeError("proxy requires auth (use a mixed port from Clash)")
    h = host.encode()
    sock.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + port.to_bytes(2, "big"))
    hdr = recv_exact(sock, 4)
    if hdr[1] != 0:
        raise RuntimeError("CONNECT rejected 0x%02x" % hdr[1])
    atyp = hdr[3]
    if atyp == 1:
        recv_exact(sock, 6)
    elif atyp == 3:
        ln = recv_exact(sock, 1)[0]
        recv_exact(sock, ln + 2)
    else:
        recv_exact(sock, 18)
    return time.time() - t0


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed")
        buf += c
    return buf


def one_sample(proxy, use_http, timeout):
    host, port = proxy
    r = {"ok": False}
    t_start = time.time()
    sock = socket.socket()
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
        r["connect_ms"] = round((time.time() - t_start) * 1000, 1)

        if use_http:
            req = ("CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" % (TARGET_HOST, TARGET_HOST)).encode()
            sock.sendall(req)
            buf = b""
            while b"\r\n\r\n" not in buf:
                c = sock.recv(1024)
                if not c:
                    raise ConnectionError("first hop closed")
                buf += c
            if b" 200" not in buf.split(b"\r\n")[0]:
                raise RuntimeError("HTTP CONNECT failed: %r" % buf.split(b"\r\n")[0])
            r["socks_ms"] = 0.0
        else:
            r["socks_ms"] = round(socks5_handshake(sock, TARGET_HOST, 443, timeout) * 1000, 1)

        t_tls = time.time()
        ctx = ssl.create_default_context()
        ss = ctx.wrap_socket(sock, server_hostname=TARGET_HOST)
        r["tls_ms"] = round((time.time() - t_tls) * 1000, 1)

        t_req = time.time()
        ss.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: benchmark/2\r\n"
                    "Connection: close\r\nAccept: */*\r\n\r\n" % (TARGET_PATH, TARGET_HOST)).encode())
        first = ss.recv(1)
        r["ttfb_ms"] = round((time.time() - t_req) * 1000, 1)
        body = first
        while True:
            c = ss.recv(4096)
            if not c:
                break
            body += c
            if len(body) > 65536:
                break
        r["total_ms"] = round((time.time() - t_start) * 1000, 1)
        head, _, payload = body.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode("latin-1")
        r["status"] = status
        r["ip"] = payload.decode("latin-1").strip()[:40]
        r["ok"] = status.startswith("HTTP/") and ("200" in status)
        ss.close()
    except Exception as e:
        r["error"] = "%s: %s" % (type(e).__name__, str(e)[:80])
        r["total_ms"] = round((time.time() - t_start) * 1000, 1)
    finally:
        try:
            sock.close()
        except Exception:
            pass
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default="127.0.0.1:7897")
    ap.add_argument("--http", action="store_true", help="first hop speaks HTTP CONNECT instead of SOCKS5")
    ap.add_argument("--direct", action="store_true")
    ap.add_argument("--samples", type=int, default=30)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--timeout", type=float, default=25)
    ap.add_argument("--out", default=None)
    ap.add_argument("--label", default=None)
    a = ap.parse_args()

    if a.direct:
        label = a.label or "direct"
        # direct: no proxy hop; reuse the sample by tunnelling through a tiny local no-op
        # simpler: plain TLS to the target
        rows = []
        for i in range(a.samples):
            t0 = time.time()
            r = {"ok": False}
            try:
                s = socket.socket(); s.settimeout(a.timeout)
                t = time.time(); s.connect((TARGET_HOST, 443))
                r["connect_ms"] = round((time.time() - t) * 1000, 1)
                r["socks_ms"] = 0.0
                t = time.time()
                ss = ssl.create_default_context().wrap_socket(s, server_hostname=TARGET_HOST)
                r["tls_ms"] = round((time.time() - t) * 1000, 1)
                t = time.time()
                ss.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % (TARGET_PATH, TARGET_HOST)).encode())
                first = ss.recv(1)
                r["ttfb_ms"] = round((time.time() - t) * 1000, 1)
                body = first
                while True:
                    c = ss.recv(4096)
                    if not c:
                        break
                    body += c
                r["total_ms"] = round((time.time() - t0) * 1000, 1)
                head, _, payload = body.partition(b"\r\n\r\n")
                r["status"] = head.split(b"\r\n")[0].decode("latin-1")
                r["ip"] = payload.decode("latin-1").strip()[:40]
                r["ok"] = "200" in r["status"]
                ss.close()
            except Exception as e:
                r["error"] = "%s: %s" % (type(e).__name__, str(e)[:80])
            rows.append(r)
            if i < a.samples - 1:
                time.sleep(a.interval)
    else:
        host, port = a.proxy.split(":")
        label = a.label or ("%s://%s" % ("http" if a.http else "socks5h", a.proxy))
        rows = []
        for i in range(a.samples):
            rows.append(one_sample((host, int(port)), a.http, a.timeout))
            print("[%d/%d] %-46s %s" % (i + 1, a.samples,
                                        (rows[-1].get("error") or rows[-1].get("ip", ""))[:46],
                                        "%sms" % rows[-1].get("total_ms")), flush=True)
            if i < a.samples - 1:
                time.sleep(a.interval)

    ok = [r for r in rows if r.get("ok")]
    lat = [r["total_ms"] for r in ok if r.get("total_ms")]
    summary = {
        "label": label,
        "samples": len(rows),
        "passed": len(ok),
        "successRate": round(100.0 * len(ok) / max(1, len(rows)), 2),
        "latencyMs": {
            "connect": {"p50": pct([r.get("connect_ms", 0) for r in ok], .5), "p95": pct([r.get("connect_ms", 0) for r in ok], .95)},
            "handshake": {"p50": pct([r.get("socks_ms", 0) for r in ok], .5), "p95": pct([r.get("socks_ms", 0) for r in ok], .95)},
            "tls": {"p50": pct([r.get("tls_ms", 0) for r in ok], .5), "p95": pct([r.get("tls_ms", 0) for r in ok], .95)},
            "ttfb": {"p50": pct([r.get("ttfb_ms", 0) for r in ok], .5), "p95": pct([r.get("ttfb_ms", 0) for r in ok], .95)},
            "total": {"p50": pct(lat, .5), "p90": pct(lat, .90), "p95": pct(lat, .95), "p99": pct(lat, .99)},
        },
        "failures": [{"error": r.get("error")} for r in rows if not r.get("ok")][:50],
        "raw": rows,
    }
    print("\n===== %s =====" % label)
    print("samples %d  passed %d (%.1f%%)" % (summary["samples"], summary["passed"], summary["successRate"]))
    print("p50 total %sms  p95 %sms" % (summary["latencyMs"]["total"]["p50"], summary["latencyMs"]["total"]["p95"]))
    for k in ("connect", "handshake", "tls", "ttfb"):
        print("  %-10s p50=%sms p95=%sms" % (k, summary["latencyMs"][k]["p50"], summary["latencyMs"][k]["p95"]))

    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump(summary, f, ensure_ascii=False, indent=1)
        print("json -> %s" % a.out)
    return 0 if summary["passed"] == summary["samples"] else 5


if __name__ == "__main__":
    sys.exit(main())
