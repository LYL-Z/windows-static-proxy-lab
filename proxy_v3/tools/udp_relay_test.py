#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
udp_relay_test.py -- does a UDP datagram actually traverse the Clash UDP relay?

SOCKS5 UDP ASSOCIATE being "accepted" by mihomo only means the local listener
exists. Whether the *node* relays UDP depends on the proxy's `udp:` setting.
This sends a real STUN binding request through the relay and reports the
mapped address, or a timeout (= not relayed).
"""
import os
import socket
import struct

MAGIC = 0x2112A442
RELAY_HOST, RELAY_PORT = "127.0.0.1", 7897
STUN_HOST, STUN_PORT = "stun.cloudflare.com", 3478


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("closed")
        b += c
    return b


def main():
    ctl = socket.create_connection((RELAY_HOST, RELAY_PORT), timeout=10)
    ctl.sendall(b"\x05\x01\x00")
    if recv_exact(ctl, 2)[1] != 0:
        print("no-auth rejected"); return
    ctl.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
    hdr = recv_exact(ctl, 4)
    if hdr[1] != 0:
        print("UDP ASSOCIATE refused REP=0x%02x" % hdr[1]); return
    if hdr[3] == 1:
        recv_exact(ctl, 6)
    elif hdr[3] == 3:
        recv_exact(ctl, recv_exact(ctl, 1)[0] + 2)
    else:
        recv_exact(ctl, 18)

    target = socket.getaddrinfo(STUN_HOST, STUN_PORT, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    txn = os.urandom(12)
    stun = struct.pack(">HHI", 0x0001, 0, MAGIC) + txn
    # SOCKS5 UDP request header: RSV(2) FRAG(1) ATYP(1) ADDR PORT DATA
    udp_hdr = b"\x00\x00\x00\x01" + socket.inet_aton(target[0]) + target[1].to_bytes(2, "big")
    payload = udp_hdr + stun

    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(8)
    try:
        u.sendto(payload, (RELAY_HOST, RELAY_PORT))
        data, _ = u.recvfrom(2048)
    except socket.timeout:
        print("UDP through relay: TIMEOUT -> datagram not relayed (node udp:false)")
        return
    finally:
        u.close(); ctl.close()

    # strip SOCKS5 UDP response header
    if len(data) < 10:
        print("UDP response too short (%d bytes)" % len(data)); return
    atyp = data[3]
    off = 4 + (4 if atyp == 1 else (16 if atyp == 4 else 1 + data[4]))
    off += 2
    body = data[off:]
    if len(body) < 20 or struct.unpack(">H", body[0:2])[0] != 0x0101:
        print("UDP relayed but response is not STUN (%d bytes)" % len(body)); return
    pos, end = 20, min(20 + struct.unpack(">H", body[2:4])[0], len(body))
    while pos + 4 <= end:
        atype, alen = struct.unpack(">HH", body[pos:pos + 4])
        val = body[pos + 4:pos + 4 + alen]
        if atype in (0x0001, 0x0020) and val[1] == 1:
            raw = val[4:8]
            if atype == 0x0020:
                raw = struct.pack(">I", struct.unpack(">I", raw)[0] ^ MAGIC)
            print("UDP through relay: OK -> mapped %s (relayed via the node)" % socket.inet_ntoa(raw))
            return
        pos += 4 + alen
    print("UDP relayed, no MAPPED attribute found")


if __name__ == "__main__":
    main()
