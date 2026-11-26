#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Control experiment: can THIS network keep an arbitrary non-443 TCP session
open?  If yes, then the 9506 session teardown must come from the remote side.

Each target is connected, left idle for 4 s, and we record whether the socket
stays open, gets closed by the peer, or is reset.
"""
import os
import socket
import time

TARGETS = [
    ("1.1.1.1", 853, "Cloudflare DoT - waits for TLS ClientHello"),
    ("8.8.8.8", 853, "Google DoT - waits for TLS ClientHello"),
    ("1.1.1.1", 443, "Cloudflare HTTPS"),
    ("223.5.5.5", 53, "AliDNS over TCP"),
    ("114.114.114.114", 53, "114DNS over TCP"),
    ("github.com", 22, "GitHub SSH - sends banner"),
    (os.environ["PX_HOST"], 9506, "TARGET static proxy"),
]

print("%-22s %-6s %-10s %s" % ("target", "conn", "idle 4s", "verdict/detail"))
print("-" * 100)
for host, port, note in TARGETS:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(8)
    try:
        t0 = time.time()
        s.connect((host, port))
        t_conn = (time.time() - t0) * 1000
    except socket.timeout:
        print("%-22s %-6s %-10s cannot connect (timeout)  [%s]"
              % ("%s:%d" % (host, port), "-", "-", note))
        s.close()
        continue
    except Exception as e:
        print("%-22s %-6s %-10s connect refused/%s  [%s]"
              % ("%s:%d" % (host, port), "-", "-", type(e).__name__, note))
        s.close()
        continue

    s.settimeout(4.0)
    try:
        d = s.recv(64)
        dt = (time.time() - t0) * 1000 - t_conn
        if d:
            verdict = "remote spoke first (+%.0fms)" % dt
            detail = repr(d[:40])
        else:
            verdict = "CLOSED by peer (+%.0fms)" % dt
            detail = "EOF"
    except socket.timeout:
        verdict = "STAYED OPEN 4s"
        detail = "no data, no close"
    except ConnectionResetError:
        verdict = "RESET by peer"
        detail = ""
    finally:
        s.close()
    print("%-22s %-6s %-10s %s  [%s]"
          % ("%s:%d" % (host, port), "%.0fms" % t_conn, verdict, detail, note))
