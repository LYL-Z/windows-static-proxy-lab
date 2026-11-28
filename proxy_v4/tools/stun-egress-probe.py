#!/usr/bin/env python3
"""Read-only STUN egress probe (standard library only).

Purpose
-------
Answer two narrow questions with evidence instead of opinion:

  1. Which public IPv4 address does a STUN binding request appear to come
     from when sent DIRECT (let the OS pick the path)?
  2. Which public IPv4 address does the same request appear to come from
     when it is carried by a SOCKS5 UDP ASSOCIATE session (default
     http://127.0.0.1:7897, the Clash Verge mixed port)?

It does NOT decide whether the user "leaks" a Chinese IP.  It reports
mapped addresses, whether they are private, and whether the two modes
differ.  Interpretation belongs to docs/net/WEBRTC-UDP.md.

Scope / safety
--------------
* no third party packages: socket/struct/os/sys/json/argparse/time only
* one binding request per server per mode; at most two attempts, 3 s apart,
  because a single lost UDP datagram must not be reported as "no egress"
* only the STUN servers declared below are contacted, 2 per run
* never prints credentials; the SOCKS5 handshake here is unauthenticated
  and the proxy endpoint is reported masked (host:port only)

Output: one JSON document on stdout (see --help for the field list).
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

# Declared targets.  Keep this list short and stable: every run contacts
# exactly these, twice at most (one attempt in direct mode, one via proxy).
STUN_SERVERS = [
    ("stun.cloudflare.com", 3478),
    ("stun.l.google.com", 19302),
]

MAGIC_COOKIE = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
ATTR_XOR_MAPPED_ADDRESS = 0x0020
ATTR_MAPPED_ADDRESS = 0x0001
ATTR_SOFTWARE = 0x8022
ATTR_RESPONSE_ORIGIN = 0x802B


def is_private_v4(ip):
    """RFC1918 / CGNAT / link-local / loopback / unspecified / multicast."""
    try:
        parts = [int(p) for p in ip.split(".")]
    except Exception:
        return False
    if len(parts) != 4 or any(p < 0 or p > 255 for p in parts):
        return False
    a, b = parts[0], parts[1]
    if a == 10 or a == 127 or a == 0 or (a >= 224):
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    if a == 169 and b == 254:
        return True
    if a == 100 and 64 <= b <= 127:
        return True
    return False


def build_binding_request():
    txid = os.urandom(12)
    header = struct.pack("!HHI", BINDING_REQUEST, 0, MAGIC_COOKIE) + txid
    return header, txid


def parse_message(data):
    """Return (mapped_ip, port, software, response_origin) or raise ValueError."""
    if len(data) < 20:
        raise ValueError("short STUN message")
    mtype, mlen, cookie = struct.unpack("!HHI", data[0:8])
    txid = data[8:20]
    body = data[20:20 + mlen]
    mapped = None
    port = None
    software = None
    origin = None
    offset = 0
    while offset + 4 <= len(body):
        atype, alen = struct.unpack("!HH", body[offset:offset + 4])
        value = body[offset + 4:offset + 4 + alen]
        offset += 4 + alen + ((4 - alen % 4) % 4)
        if atype == ATTR_XOR_MAPPED_ADDRESS and len(value) >= 8:
            family = value[1]
            xport = struct.unpack("!H", value[2:4])[0] ^ (MAGIC_COOKIE >> 16)
            if family == 0x01 and len(value) >= 8:
                raw = struct.unpack("!I", value[4:8])[0] ^ MAGIC_COOKIE
                mapped = socket.inet_ntoa(struct.pack("!I", raw))
                port = xport
        elif atype == ATTR_MAPPED_ADDRESS and mapped is None and len(value) >= 8:
            family = value[1]
            if family == 0x01:
                mapped = socket.inet_ntoa(value[4:8])
                port = struct.unpack("!H", value[2:4])[0]
        elif atype == ATTR_SOFTWARE:
            try:
                software = value.decode("utf-8", "replace")
            except Exception:
                software = None
        elif atype == ATTR_RESPONSE_ORIGIN and len(value) >= 8:
            try:
                origin = socket.inet_ntoa(value[4:8])
            except Exception:
                origin = None
    if mtype != BINDING_SUCCESS:
        raise ValueError("unexpected STUN message type 0x%04x" % mtype)
    return mapped, port, software, origin, txid


def stun_exchange_direct(server, port, timeout):
    """One binding request from an OS-routed UDP socket."""
    host_info = {"mode": "DIRECT", "server": "%s:%d" % (server, port)}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(timeout)
        # Resolve first so a DNS failure is its own evidence, not a timeout.
        try:
            family, _, _, _, addr = socket.getaddrinfo(server, port, socket.AF_INET,
                                                       socket.SOCK_DGRAM)[0]
        except Exception as exc:
            host_info["error"] = "resolve_failed: %s" % exc.__class__.__name__
            return host_info
        request, txid = build_binding_request()
        started = time.time()
        try:
            sock.sendto(request, addr)
            data, _ = sock.recvfrom(2048)
        except socket.timeout:
            host_info["error"] = "timeout"
            return host_info
        except OSError as exc:
            host_info["error"] = "udp_error: %s" % exc.__class__.__name__
            return host_info
        host_info["rttMs"] = round((time.time() - started) * 1000, 1)
        try:
            mapped, mport, software, origin, rtxid = parse_message(data)
        except Exception as exc:
            host_info["error"] = "parse_failed: %s" % exc.__class__.__name__
            return host_info
        if rtxid != txid:
            host_info["error"] = "transaction_id_mismatch"
            return host_info
        host_info.update(mapped=mapped, mappedPort=mport, software=software,
                         responseOrigin=origin, ok=bool(mapped),
                         private=is_private_v4(mapped) if mapped else None)
        return host_info
    finally:
        sock.close()


def socks5_udp_associate(proxy_host, proxy_port, target_host, target_port,
                         timeout, payload_len=0):
    """STUN request inside a SOCKS5 UDP ASSOCIATE session.

    Returns (json_info, stun_bytes_or_None).  The STUN bytes are parsed by
    the caller so both modes share one parser.
    """
    info = {"mode": "SOCKS5_UDP", "proxy": "%s:%d" % (proxy_host, proxy_port),
            "server": "%s:%d" % (target_host, target_port)}
    control = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    udp = None
    try:
        control.settimeout(timeout)
        try:
            control.connect((proxy_host, proxy_port))
        except OSError as exc:
            info["error"] = "control_connect_failed: %s" % exc.__class__.__name__
            return info, None
        control.sendall(b"\x05\x01\x00")
        reply = control.recv(2)
        if len(reply) != 2 or reply[0] != 0x05:
            info["error"] = "socks5_greeting_failed"
            return info, None
        if reply[1] != 0x00:
            info["error"] = "socks5_auth_required_or_unsupported:0x%02x" % reply[1]
            return info, None
        control.sendall(b"\x05\x03\x00\x01" + socket.inet_aton("0.0.0.0") +
                        struct.pack("!H", 0))
        head = control.recv(4)
        if len(head) != 4 or head[0] != 0x05:
            info["error"] = "udp_associate_reply_short"
            return info, None
        if head[1] != 0x00:
            info["error"] = "udp_associate_rejected:0x%02x" % head[1]
            return info, None
        atyp = head[3]
        if atyp == 0x01:
            relay_host = socket.inet_ntoa(control.recv(4))
        elif atyp == 0x04:
            raw = control.recv(16)
            relay_host = socket.inet_ntop(socket.AF_INET6, raw)
        elif atyp == 0x03:
            ln = control.recv(1)[0]
            relay_host = control.recv(ln).decode("ascii", "replace")
        else:
            info["error"] = "udp_associate_bad_atyp"
            return info, None
        relay_port = struct.unpack("!H", control.recv(2))[0]
        info["relay"] = "%s:%d" % (relay_host, relay_port)
        if relay_host in ("0.0.0.0", "::"):
            relay_host = proxy_host
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.settimeout(timeout)
        try:
            target_ip = socket.gethostbyname(target_host)
        except Exception as exc:
            info["error"] = "target_resolve_failed: %s" % exc.__class__.__name__
            return info, None
        request, txid = build_binding_request()
        packet = (b"\x00\x00\x00\x01" + socket.inet_aton(target_ip) +
                  struct.pack("!H", target_port) + request)
        started = time.time()
        try:
            udp.sendto(packet, (relay_host, relay_port))
            data, _ = udp.recvfrom(4096)
        except socket.timeout:
            info["error"] = "timeout"
            return info, None
        except OSError as exc:
            info["error"] = "udp_error: %s" % exc.__class__.__name__
            return info, None
        info["rttMs"] = round((time.time() - started) * 1000, 1)
        # Strip the SOCKS5 UDP response header.
        if len(data) < 10:
            info["error"] = "udp_reply_short"
            return info, None
        ratyp = data[3]
        if ratyp == 0x01:
            off = 4 + 4 + 2
        elif ratyp == 0x04:
            off = 4 + 16 + 2
        elif ratyp == 0x03:
            off = 4 + 1 + data[4] + 2
        else:
            info["error"] = "udp_reply_bad_atyp"
            return info, None
        info["txid"] = txid.hex()
        return info, data[off:]
    finally:
        if udp is not None:
            udp.close()
        control.close()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Read-only STUN egress probe (stdlib only).")
    parser.add_argument("--mode", choices=["direct", "socks5", "both"],
                        default="both")
    parser.add_argument("--proxy-host", default="127.0.0.1")
    parser.add_argument("--proxy-port", type=int, default=7897)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args(argv)

    evidence_time = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
    result = {
        "observedAt": evidence_time,
        "tool": "stun-egress-probe.py",
        "standardLibraryOnly": True,
        "declaredStunServers": ["%s:%d" % s for s in STUN_SERVERS],
        "attemptsPerServer": 2,
        "modes": {},
        "note": ("A mapped address is the address the STUN server saw. It proves "
                 "which egress the packet used; it does not by itself prove or "
                 "disprove a privacy problem."),
    }

    def run_direct():
        rows = []
        for server, port in STUN_SERVERS:
            row = None
            for _ in range(2):
                row = stun_exchange_direct(server, port, args.timeout)
                if row.get("ok") or row.get("error") != "timeout":
                    break
            rows.append(row)
        return rows

    def run_socks5():
        rows = []
        for server, port in STUN_SERVERS:
            row = None
            # A SOCKS5 UDP relay can drop the first datagram; one retry with a
            # fresh associate is still only 2 attempts per server.
            for _ in range(2):
                attempt, payload = socks5_udp_associate(
                    args.proxy_host, args.proxy_port, server, port, args.timeout)
                row = attempt
                if payload is not None:
                    try:
                        mapped, mport, software, origin, _txid = parse_message(payload)
                        row.update(mapped=mapped, mappedPort=mport, software=software,
                                   responseOrigin=origin, ok=bool(mapped),
                                   private=is_private_v4(mapped) if mapped else None)
                    except Exception as exc:
                        row["error"] = "parse_failed: %s" % exc.__class__.__name__
                if row.get("ok") or row.get("error") != "timeout":
                    break
            rows.append(row)
        return rows

    if args.mode in ("direct", "both"):
        result["modes"]["direct"] = run_direct()
    if args.mode in ("socks5", "both"):
        result["modes"]["socks5"] = run_socks5()

    # Aggregate: the set of distinct mapped addresses per mode, plus a simple
    # private-only flag.  Interpretation stays in webrtc-probe.ps1/docs.
    summary = {}
    for mode, rows in result["modes"].items():
        ips = sorted({r["mapped"] for r in rows if r.get("mapped")})
        priv = [r["private"] for r in rows if r.get("mapped")]
        summary[mode] = {
            "mapped": ips,
            "measured": len(ips),
            "privateOnly": bool(priv) and all(priv),
            "errors": [r.get("error") for r in rows if r.get("error")],
        }
    result["summary"] = summary
    json.dump(result, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
