#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
stun_probe.py -- find the public IP observed by a STUN server over UDP.

Used to explain why WebRTC/STUN reports a different egress than HTTPS does:
STUN is UDP, and the Clash chain is TCP-only in this configuration, so UDP
leaves through whatever captures the default route (StarSky's TUN).

No dependencies. Sends a minimal RFC5389 binding request.
Usage: python stun_probe.py [server] [port]
"""
import os
import socket
import struct
import sys

MAGIC = 0x2112A442


def stun_query(host, port, timeout=6.0, family=socket.AF_INET):
    # binding request: type=0x0001, len=0, magic cookie, 12-byte txn id
    txn = os.urandom(12)
    pkt = struct.pack(">HHI", 0x0001, 0, MAGIC) + txn
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        infos = socket.getaddrinfo(host, port, family, socket.SOCK_DGRAM)
        addr = infos[0][4]
        s.sendto(pkt, addr)
        data, src = s.recvfrom(2048)
    finally:
        s.close()

    if len(data) < 20:
        raise RuntimeError("short STUN response")
    mtype, mlen = struct.unpack(">HH", data[0:4])
    if mtype != 0x0101:
        raise RuntimeError("unexpected STUN type 0x%04x" % mtype)

    pos = 20
    end = min(20 + mlen, len(data))
    while pos + 4 <= end:
        atype, alen = struct.unpack(">HH", data[pos:pos + 4])
        val = data[pos + 4:pos + 4 + alen]
        if atype in (0x0001, 0x0020):          # MAPPED / XOR-MAPPED
            fam = val[1]
            xport = struct.unpack(">H", val[2:4])[0]
            if fam == 0x01:
                raw = val[4:8]
                if atype == 0x0020:
                    raw = struct.pack(">I", struct.unpack(">I", raw)[0] ^ MAGIC)
                ip = socket.inet_ntoa(raw)
                port2 = xport ^ (MAGIC >> 16) if atype == 0x0020 else xport
                return ip, port2, src[0]
        pos += 4 + alen
    raise RuntimeError("no MAPPED address in response")


def main():
    servers = [
        ("stun.l.google.com", 19302, socket.AF_INET),
        ("stun.cloudflare.com", 3478, socket.AF_INET),
    ]
    if len(sys.argv) > 1:
        servers = [(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 19302, socket.AF_INET)]

    print("# STUN/UDP egress probe")
    for host, port, fam in servers:
        try:
            ip, p2, seen = stun_query(host, port, family=fam)
            print("  %-24s -> mapped %s:%d   (packet seen from %s)" % ("%s:%d" % (host, port), ip, p2, seen))
        except Exception as e:
            print("  %-24s -> FAILED %s: %s" % ("%s:%d" % (host, port), type(e).__name__, str(e)[:70]))


if __name__ == "__main__":
    main()
