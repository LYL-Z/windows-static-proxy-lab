#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Measure WHO closes the TCP session and from how far away.

A close arriving ~1 RTT (~240 ms) after connect = the remote host closed it.
A close arriving in ~0-5 ms = something on the local/path side killed it
(kernel firewall, WFP filter, local VPN driver, campus client, router ACL).

No credentials are used or printed here.
"""
import socket
import sys
import time

HOST = "72.245.197.103"
PORT = 9506


def trial(label, payload=None, wait_before=0.0, timeout=6.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        t0 = time.time()
        s.connect((HOST, PORT))
        t_conn = time.time()
        base = t_conn
        if wait_before:
            time.sleep(wait_before)
            base = time.time()
        if payload:
            s.sendall(payload)
            base = time.time()
        try:
            d = s.recv(128)
            t_recv = time.time()
            dt = (t_recv - base) * 1000
            kind = "FIN/EOF (graceful)" if not d else "DATA"
            print("%-30s connect=%6.1fms  close_after=%7.1fms  %-18s %r"
                  % (label, (t_conn - t0) * 1000, dt, kind, d[:32]))
        except socket.timeout:
            print("%-30s connect=%6.1fms  stayed OPEN for %ds (no close, no data)"
                  % (label, (t_conn - t0) * 1000, timeout))
        except ConnectionResetError as e:
            dt = (time.time() - base) * 1000
            print("%-30s connect=%6.1fms  RST after=%7.1fms  (%s)"
                  % (label, (t_conn - t0) * 1000, dt, e.__class__.__name__))
    except Exception as e:
        print("%-30s CONNECT FAILED %s: %s" % (label, type(e).__name__, e))
    finally:
        s.close()


print("# close-latency probes vs %s:%d  (RTT is ~240-260ms)" % (HOST, PORT))
print("# 1 RTT close => remote side; ~0ms close => local/path side\n")
trial("A1 no-payload (immediate)", None)
trial("A2 no-payload (immediate)", None)
trial("A3 no-payload, wait 1.0s", None, wait_before=1.0)
trial("B1 send 1 byte 0x05", b"\x05")
trial("B2 send sock5 greeting noauth", b"\x05\x01\x00")
trial("B3 send bare CRLF", b"\r\n\r\n")
trial("B4 send HTTP GET absolute-URI",
      b"GET http://ipinfo.io/ip HTTP/1.1\r\nHost: ipinfo.io\r\nUser-Agent: px/1.0\r\n\r\n")
trial("B5 send 64 zero bytes", b"\x00" * 64)
print("\n# control: same measurement against a known-good remote TLS port")
s2 = socket.socket()
try:
    t0 = time.time()
    s2.settimeout(8)
    s2.connect(("1.1.1.1", 443))
    t_conn = time.time()
    s2.settimeout(2.0)
    try:
        d = s2.recv(16)
        print("control 1.1.1.1:443  connect=%6.1fms  recv=> %r" % ((t_conn - t0) * 1000, d))
    except socket.timeout:
        print("control 1.1.1.1:443  connect=%6.1fms  stayed open (expected: TLS server waits for ClientHello)"
              % ((t_conn - t0) * 1000))
finally:
    s2.close()
