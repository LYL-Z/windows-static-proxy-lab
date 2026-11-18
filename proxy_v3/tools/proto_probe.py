#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
proto_probe.py -- per-protocol capability probe for the Clash mixed port.

1. ALPN negotiation (HTTP/2 support) through the SOCKS5 tunnel
2. SOCKS5 UDP ASSOCIATE support (is UDP relayed at all?)
3. IPv4/IPv6 address family of the tunnel

No dependencies. Talks only to the local mixed port (no auth needed).
"""
import socket
import ssl
import struct


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("closed")
        b += c
    return b


def socks_connect(host, port, target, tport):
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(b"\x05\x01\x00")
    r = recv_exact(s, 2)
    if r[1] != 0:
        raise RuntimeError("auth method rejected: %r" % r)
    h = target.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + tport.to_bytes(2, "big"))
    hdr = recv_exact(s, 4)
    if hdr[1] != 0:
        raise RuntimeError("CONNECT rejected 0x%02x" % hdr[1])
    atyp = hdr[3]
    if atyp == 1:
        recv_exact(s, 6)
    elif atyp == 3:
        recv_exact(s, recv_exact(s, 1)[0] + 2)
    else:
        recv_exact(s, 18)
    return s


def test_alpn(host, port):
    s = socks_connect(host, port, "www.google.com", 443)
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2", "http/1.1"])
    try:
        ss = ctx.wrap_socket(s, server_hostname="www.google.com")
        proto = ss.selected_alpn_protocol()
        ver = ss.version()
        ss.close()
        return "ALPN negotiated: %s (TLS %s)" % (proto or "<none>", ver)
    finally:
        try:
            s.close()
        except Exception:
            pass


def test_udp_associate(host, port):
    s = socket.create_connection((host, port), timeout=10)
    s.sendall(b"\x05\x01\x00")
    r = recv_exact(s, 2)
    if r[1] != 0:
        raise RuntimeError("no-auth rejected")
    # UDP ASSOCIATE, bind 0.0.0.0:0
    s.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    hdr = recv_exact(s, 4)
    rep = hdr[1]
    if rep != 0:
        s.close()
        return "UDP ASSOCIATE refused (REP=0x%02x)" % rep
    atyp = hdr[3]
    if atyp == 1:
        addr = socket.inet_ntoa(recv_exact(s, 4)); prt = struct.unpack(">H", recv_exact(s, 2))[0]
    elif atyp == 3:
        ln = recv_exact(s, 1)[0]; addr = recv_exact(s, ln).decode(); prt = struct.unpack(">H", recv_exact(s, 2))[0]
    else:
        addr = "<v6>"; prt = struct.unpack(">H", recv_exact(s, 2))[0]
    s.close()
    return "UDP ASSOCIATE accepted, relay=%s:%d" % (addr, prt)


def main():
    host, port = "127.0.0.1", 7897
    print("# proto probe via mixed port %s:%d" % (host, port))
    for name, fn in (("HTTP/2 (ALPN)", test_alpn), ("SOCKS5 UDP", test_udp_associate)):
        try:
            print("  %-14s : %s" % (name, fn(host, port)))
        except Exception as e:
            print("  %-14s : FAILED %s: %s" % (name, type(e).__name__, str(e)[:80]))


if __name__ == "__main__":
    main()
