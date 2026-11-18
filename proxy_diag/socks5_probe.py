#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Static-proxy staged handshake probe.

Credentials are read ONLY from environment variables PX_USER / PX_PASS and are
never printed, logged or written to disk.  All replies are hex-dumped so the
exact failure stage is visible.

Usage:  python socks5_probe.py [tcp|socks5-noauth|socks5-auth|http-noauth|
                                http-auth|tls|ports|all]
"""
import base64
import json
import os
import socket
import ssl
import sys
import time

HOST = os.environ.get("PX_HOST", "72.245.197.103")
PORT = int(os.environ.get("PX_PORT", "9506"))
USER = os.environ.get("PX_USER", "")
PW = os.environ.get("PX_PASS", "")
TGT_HOST = os.environ.get("TGT_HOST", "www.gstatic.com")
TGT_PORT = int(os.environ.get("TGT_PORT", "443"))
IP_HOST = os.environ.get("IP_HOST", "ipinfo.io")
IP_PATH = os.environ.get("IP_PATH", "/ip")
TO = float(os.environ.get("PX_TIMEOUT", "12"))

RESULT = []


def hx(b, n=96):
    if b is None:
        return "None"
    s = b[:n].hex(" ")
    return s + ("" if len(b) <= n else " ...(+%d)" % (len(b) - n))


def tc(host=None, port=None, timeout=None):
    t0 = time.time()
    s = socket.create_connection((host or HOST, port or PORT), timeout=timeout or TO)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s, (time.time() - t0) * 1000.0


def rd(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("peer closed after %d/%d bytes" % (len(buf), n))
        buf += c
    return buf


def record(name, steps, ok, detail=""):
    RESULT.append({"test": name, "ok": ok, "detail": detail, "steps": steps})
    print("=== %s -> %s %s" % (name, "OK" if ok else "FAIL", detail))
    for st in steps:
        print("    %-24s %-5s %s" % (st[0], st[1], st[2]))


def https_get_ip(raw):
    """TLS over the tunnelled socket, then fetch the exit IP as plain text."""
    ctx = ssl.create_default_context()
    ss = ctx.wrap_socket(raw, server_hostname=IP_HOST)
    ss.settimeout(TO)
    req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: pxdiag/1.0\r\n"
           "Accept: */*\r\nConnection: close\r\n\r\n" % (IP_PATH, IP_HOST)).encode()
    ss.sendall(req)
    data = b""
    while True:
        try:
            c = ss.recv(4096)
        except socket.timeout:
            break
        if not c:
            break
        data += c
        if len(data) > 65536:
            break
    head, _, body = data.partition(b"\r\n\r\n")
    stat = head.split(b"\r\n")[0].decode("latin-1") if head else "(no status line)"
    txt = body.decode("latin-1", "replace").strip()
    # de-chunk if needed
    if "\r\n" in txt:
        txt = txt.split("\r\n")[0]
    return "%s | %r" % (stat, txt[:80])


def do_tcp():
    steps = []
    try:
        s, ms = tc()
        steps.append(("1 TCP connect", "OK", "%.1fms" % ms))
        s.settimeout(3.0)
        try:
            d = s.recv(64)
            steps.append(("2 server speaks first", "OK" if d else "EOF", hx(d) if d else "closed"))
        except socket.timeout:
            steps.append(("2 server speaks first", "none", "silent 3s (normal for socks5)"))
        except Exception as e:
            steps.append(("2 server speaks first", "ERR", repr(e)))
        s.close()
        record("tcp+passive", steps, True)
    except Exception as e:
        steps.append(("1 TCP connect", "FAIL", repr(e)))
        record("tcp+passive", steps, False)


def socks5(use_auth):
    name = "socks5-auth" if use_auth else "socks5-noauth"
    steps = []
    s = None
    try:
        s, ms = tc()
        steps.append(("1 TCP connect", "OK", "%.1fms" % ms))
    except Exception as e:
        steps.append(("1 TCP connect", "FAIL", repr(e)))
        record(name, steps, False)
        return
    try:
        gm = b"\x05\x02\x00\x02" if use_auth else b"\x05\x01\x00"
        t1 = time.time()
        s.sendall(gm)
        try:
            d = rd(s, 2)
        except Exception as e:
            steps.append(("2 recv method", "FAIL",
                          "%s after %.0fms (%r)" % (type(e).__name__, (time.time() - t1) * 1000, e)))
            raise
        steps.append(("2 recv method", "OK", "%s (%.0fms)" % (hx(d), (time.time() - t1) * 1000)))
        if d[0] != 0x05:
            raise ValueError("reply is NOT SOCKS5: ver=0x%02x first bytes=%r" % (d[0], d))
        if d[1] == 0xFF:
            raise ValueError("server replied 0xFF = NO ACCEPTABLE METHODS")
        if d[1] == 0x02:
            if not USER:
                raise ValueError("auth required but PX_USER is empty")
            u, p = USER.encode(), PW.encode()
            if len(u) > 255 or len(p) > 255:
                raise ValueError("credential too long")
            s.sendall(bytes([0x01, len(u)]) + u + bytes([len(p)]) + p)
            steps.append(("3 send user/pass", "OK",
                          "%dB sent, masked (user len %d, pass len %d)" % (2 + len(u) + len(p), len(u), len(p))))
            try:
                d2 = rd(s, 2)
            except Exception as e:
                steps.append(("4 recv auth status", "FAIL", "%s (%r)" % (type(e).__name__, e)))
                raise
            steps.append(("4 recv auth status", "OK", hx(d2)))
            if d2[1] != 0:
                raise ValueError("AUTH REJECTED by server: ver=0x%02x status=0x%02x" % (d2[0], d2[1]))
            steps.append(("5 auth", "OK", "accepted"))
        else:
            steps.append(("3 auth", "SKIP", "server chose method 0x%02x (no user/pass)" % d[1]))

        th = TGT_HOST.encode()
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(th)]) + th + TGT_PORT.to_bytes(2, "big"))
        steps.append(("6 send CONNECT", "OK", "%s:%d" % (TGT_HOST, TGT_PORT)))
        hdr = rd(s, 4)
        steps.append(("7 recv CONNECT reply", "OK", hx(hdr)))
        if hdr[1] != 0:
            raise ValueError("CONNECT refused rep=0x%02x" % hdr[1])
        atyp = hdr[3]
        if atyp == 1:
            rd(s, 6)
        elif atyp == 3:
            ln = rd(s, 1)[0]
            rd(s, ln + 2)
        elif atyp == 4:
            rd(s, 18)
        steps.append(("8 tunnel", "OK", "established"))
        ip = https_get_ip(s)
        steps.append(("9 HTTPS via tunnel", "OK", ip))
        record(name, steps, True, "exit " + ip)
    except Exception as e:
        steps.append(("!! FAILED", type(e).__name__, str(e)))
        record(name, steps, False)
    finally:
        try:
            s.close()
        except Exception:
            pass


def http_connect(use_auth):
    name = "http-connect-auth" if use_auth else "http-connect-noauth"
    steps = []
    s = None
    try:
        s, ms = tc()
        steps.append(("1 TCP connect", "OK", "%.1fms" % ms))
    except Exception as e:
        steps.append(("1 TCP connect", "FAIL", repr(e)))
        record(name, steps, False)
        return
    try:
        if use_auth:
            tok = base64.b64encode((USER + ":" + PW).encode()).decode()
            ah = "Proxy-Authorization: Basic %s\r\n" % tok
            shown = "Basic <masked %d chars>" % len(tok)
        else:
            ah, shown = "", "(none)"
        req = ("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n%s"
               "Proxy-Connection: Keep-Alive\r\nUser-Agent: pxdiag/1.0\r\n\r\n"
               % (TGT_HOST, TGT_PORT, TGT_HOST, TGT_PORT, ah)).encode()
        s.sendall(req)
        steps.append(("2 send CONNECT", "OK", "auth header " + shown))
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = s.recv(2048)
            if not c:
                raise ConnectionError("proxy CLOSED connection during CONNECT reply; got %r" % buf)
            buf += c
            if len(buf) > 16384:
                raise ValueError("oversized reply")
        head = buf.split(b"\r\n\r\n")[0].decode("latin-1")
        lines = head.split("\r\n")
        steps.append(("3 recv CONNECT reply", "OK", lines[0]))
        for ln in lines[1:]:
            low = ln.lower()
            if "authorization" in low or "authenticate" in low:
                steps.append(("3 hdr", "INFO", ln.split(":")[0] + ": <masked>"))
            else:
                steps.append(("3 hdr", "INFO", ln))
        parts = lines[0].split()
        code = int(parts[1]) if len(parts) > 1 else 0
        if code != 200:
            raise ValueError("CONNECT not established: HTTP %d" % code)
        ip = https_get_ip(s)
        steps.append(("4 HTTPS via tunnel", "OK", ip))
        record(name, steps, True, "exit " + ip)
    except Exception as e:
        steps.append(("!! FAILED", type(e).__name__, str(e)))
        record(name, steps, False)
    finally:
        try:
            s.close()
        except Exception:
            pass


def do_tls():
    """Is port 9506 maybe a TLS-wrapped proxy instead of plain SOCKS5?"""
    steps = []
    s = None
    try:
        s, ms = tc()
        steps.append(("1 TCP connect", "OK", "%.1fms" % ms))
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        t1 = time.time()
        try:
            ss = ctx.wrap_socket(s, server_hostname=HOST)
            steps.append(("2 TLS handshake", "OK", "%s %.0fms" % (ss.version(), (time.time() - t1) * 1000)))
            cert = ss.getpeercert()
            steps.append(("3 peer cert", "INFO", str(cert.get("subject") if cert else "(unverified)")))
            ss.close()
        except Exception as e:
            steps.append(("2 TLS handshake", "FAIL", "%s (%r)" % (type(e).__name__, e)))
            raise
        record("tls-on-9506", steps, True)
    except Exception:
        record("tls-on-9506", steps, False)
    finally:
        try:
            s.close()
        except Exception:
            pass


def do_ports():
    """If many unrelated ports 'connect', something in the path is answering
    SYN for us (middlebox / SYN proxy) and TCP success proves nothing."""
    steps = []
    ok_ports = []
    for p in [21, 22, 25, 80, 443, 8080, 8443, 9507, 12345, 65530]:
        try:
            s, ms = tc(port=p, timeout=6)
            s.close()
            steps.append(("port %d" % p, "OPEN", "%.0fms" % ms))
            ok_ports.append(p)
        except Exception as e:
            steps.append(("port %d" % p, "closed", type(e).__name__))
    steps.insert(0, ("port 9506 (target)", "OPEN" if 9506 else "-", "see tcp test"))
    record("port-profile", steps, True, "open=%s" % ok_ports)


def main():
    mode = (sys.argv[1] if len(sys.argv) > 1 else "all").lower()
    print("# target %s:%d  peer-auth-user-len=%d  timeout=%.0fs  tgt=%s:%d"
          % (HOST, PORT, len(USER), TO, TGT_HOST, TGT_PORT))
    if mode in ("tcp", "all"):
        do_tcp()
    if mode in ("socks5-noauth", "all"):
        socks5(False)
    if mode in ("socks5-auth", "all"):
        socks5(True)
    if mode in ("http-noauth", "all"):
        http_connect(False)
    if mode in ("http-auth", "all"):
        http_connect(True)
    if mode in ("tls", "all"):
        do_tls()
    if mode in ("ports", "all"):
        do_ports()
    ok = [r for r in RESULT if r["ok"]]
    print("\n# SUMMARY ok=%d/%d  ->  %s" % (len(ok), len(RESULT),
                                            ", ".join(r["test"] for r in ok) or "nothing"))
    out = os.environ.get("PX_OUT")
    if out:
        with open(out, "w", encoding="utf-8") as f:
            json.dump(RESULT, f, ensure_ascii=False, indent=1)
        print("# json -> %s" % out)


if __name__ == "__main__":
    main()
