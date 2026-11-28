"""Loopback protocol repro.

Measures one IPv4 TCP exchange and one IPv4 UDP exchange against listeners this
process binds to 127.0.0.1. A unique DNS query is sent only to a resolver this
process binds to 127.0.0.1; that record stays lab-only when the receiver counts
it. System DNS and DoH stay path-unknown because no receiver started here
counted those queries. WebRTC, browser DoH, public IPv6, and TURN stay
NotTested.

This process does not change DNS, IPv6, firewall, or proxy settings, and it
does not open a public resolver, a browser, or a TURN relay.
"""

from __future__ import annotations

import argparse
import json
import secrets
import socket
import struct
import sys
import time
from threading import Thread

CLASSES = ("Available", "Rejected", "TimedOut", "PathUnknown", "NotTested", "LabOnly")
STACK_UNAVAILABLE = {10047, 10049, 10051, 10065}


def sentence(protocol, body, socket_only, webrtc_note):
    socket_clause = ", and coverage is this socket only" if socket_only else ""
    webrtc_clause = ", and this is not WebRTC protection" if webrtc_note else ""
    # Same limit as ProtocolEvidence for IPv6 loopback. UDP uses a distinct name, so it is named here too.
    public_ipv6 = ", and this is not a public IPv6 path" if protocol in ("IPv6 loopback", "IPv6 UDP loopback") else ""
    return f"{protocol} {body}{socket_clause}{webrtc_clause}{public_ipv6}."


def finish(result, coverage, kind):
    if result not in CLASSES:
        raise RuntimeError(f"unknown protocol class: {result}")
    if "PathKnown" in coverage or "protected" in coverage.lower():
        raise RuntimeError("coverage claims PathKnown or protected")
    if result == "Available" and kind in ("dns", "doh", "webrtc"):
        raise RuntimeError("DNS, DoH, and WebRTC cannot be classified as Available")
    return result, coverage


def classify_dns(attempted, answer, hits, error, timed_out):
    if not attempted:
        return finish(
            "NotTested",
            "DNS was not queried, so the resolver path was not tested and this is not protection.",
            "dns",
        )
    if timed_out or error == 10060:
        return finish(
            "TimedOut",
            "DNS timed out, a timeout does not identify the resolver path, and this is not protection.",
            "dns",
        )
    if answer and hits <= 0:
        return finish(
            "PathUnknown",
            "A DNS answer is not a path proof, does not identify the recursive path, and is not protection.",
            "dns",
        )
    if answer and hits > 0:
        return finish(
            "LabOnly",
            "The controlled resolver saw this DNS query and the client received an answer, "
            "coverage is this query only, and this is not production protection.",
            "dns",
        )
    if error == 10013:
        return finish(
            "Rejected",
            "DNS was refused with error 10013, the resolver path stays unknown, and this refusal is not protection.",
            "dns",
        )
    return finish(
        "PathUnknown",
        "DNS finished without a receiver-confirmed query, the path is unknown, and this is not protection.",
        "dns",
    )


def classify_doh(attempted, status, hits, error, timed_out):
    if not attempted:
        return finish(
            "NotTested",
            "DoH was not requested, so the resolver path was not tested and this is not protection.",
            "doh",
        )
    if timed_out or error == 10060:
        return finish(
            "TimedOut",
            "DoH timed out, a timeout does not identify the resolver path, and this is not protection.",
            "doh",
        )
    if status is not None and hits <= 0:
        return finish(
            "PathUnknown",
            f"DoH HTTP {status} is not browser DoH and does not identify the resolver path, and this is not protection.",
            "doh",
        )
    if status is not None and hits > 0:
        return finish(
            "LabOnly",
            f"This controlled DoH exchange returned HTTP {status}, covers this request only, "
            "is not browser DoH, and is not production protection.",
            "doh",
        )
    if error == 10013:
        return finish(
            "Rejected",
            "DoH was refused with error 10013, the resolver path stays unknown, and this refusal is not protection.",
            "doh",
        )
    return finish(
        "PathUnknown",
        "DoH finished without a receiver-confirmed request, the path is unknown, and this is not protection.",
        "doh",
    )


def classify_socket(protocol, exchanged, hits, error, timed_out, lab_only, tested, webrtc_note, require_single_hit):
    if not tested:
        return finish(
            "NotTested",
            sentence(protocol, "was not tested and is not production protection", True, webrtc_note),
            "socket",
        )
    if exchanged and timed_out:
        return finish(
            "PathUnknown",
            sentence(
                protocol,
                "observation contradicts itself, so the path is unknown and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    if exchanged and require_single_hit and hits != 1:
        return finish(
            "PathUnknown",
            sentence(
                protocol,
                "did not match one receiver hit, so the path is unknown and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    if not exchanged and hits > 0:
        return finish(
            "PathUnknown",
            sentence(
                protocol,
                "receiver counted traffic without a matching exchange, so the path is unknown and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    if exchanged:
        how = "lab exchange" if lab_only else "exchange"
        result = "LabOnly" if lab_only else "Available"
        return finish(
            result,
            sentence(
                protocol,
                f"{how} covers this socket only and is not production protection",
                False,
                webrtc_note,
            ),
            "socket",
        )
    if timed_out or error == 10060:
        return finish(
            "TimedOut",
            sentence(
                protocol,
                "timed out, a timeout does not show that a filter blocked it, and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    if error == 10013:
        return finish(
            "Rejected",
            sentence(
                protocol,
                "was refused with error 10013, the refusing component stays unknown, and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    if error in STACK_UNAVAILABLE:
        return finish(
            "PathUnknown",
            sentence(
                protocol,
                f"address family is unavailable with error {error}, the path is unknown, and this is not production protection",
                True,
                webrtc_note,
            ),
            "socket",
        )
    return finish(
        "PathUnknown",
        sentence(
            protocol,
            "ended without a confirmed exchange, the path is unknown, and this is not production protection",
            True,
            webrtc_note,
        ),
        "socket",
    )


def classify_webrtc(browser, exchanged, hits, error, timed_out):
    if not browser:
        return finish(
            "NotTested",
            "WebRTC has no browser capture, so it is not tested and is not protection.",
            "webrtc",
        )
    if exchanged and timed_out:
        return finish(
            "PathUnknown",
            "WebRTC capture contradicts itself, so the path is unknown and this is not protection.",
            "webrtc",
        )
    if timed_out or error == 10060:
        return finish(
            "TimedOut",
            "WebRTC capture timed out, a timeout does not identify a path, and this is not protection.",
            "webrtc",
        )
    if exchanged and hits > 0:
        return finish(
            "LabOnly",
            "This browser capture covers this sample only and is not production protection.",
            "webrtc",
        )
    if error == 10013 and hits <= 0:
        return finish(
            "Rejected",
            "WebRTC capture was refused with error 10013, the path stays unknown, and this refusal is not protection.",
            "webrtc",
        )
    return finish(
        "PathUnknown",
        "This browser capture does not identify the selected path and is not protection.",
        "webrtc",
    )


def classifier_cases():
    cases = [
        (classify_dns(False, True, 1, None, False), "NotTested"),
        (classify_dns(True, True, 0, None, False), "PathUnknown"),
        (classify_dns(True, True, 1, None, False), "LabOnly"),
        (classify_dns(True, False, 0, 10060, True), "TimedOut"),
        (classify_dns(True, False, 0, 10013, False), "Rejected"),
        (classify_dns(True, False, 0, None, False), "PathUnknown"),
        (classify_doh(False, 200, 1, None, False), "NotTested"),
        (classify_doh(True, 200, 0, None, False), "PathUnknown"),
        (classify_doh(True, 403, 0, None, False), "PathUnknown"),
        (classify_doh(True, 200, 1, None, False), "LabOnly"),
        (classify_doh(True, None, 0, None, True), "TimedOut"),
        (classify_doh(True, None, 0, 10013, False), "Rejected"),
        (classify_webrtc(False, True, 1, None, False), "NotTested"),
        (classify_webrtc(True, True, 1, None, False), "LabOnly"),
        (classify_webrtc(True, False, 0, None, False), "PathUnknown"),
        (classify_socket("IPv4 loopback", True, 1, None, False, False, True, False, False), "Available"),
        (classify_socket("UDP loopback", True, 1, None, False, True, True, True, True), "LabOnly"),
        (classify_socket("IPv6 loopback", False, 0, 10013, False, False, True, False, True), "Rejected"),
        (classify_socket("IPv6 loopback", False, 0, 10060, True, False, True, False, True), "TimedOut"),
        (classify_socket("IPv6 loopback", True, 0, None, False, False, True, False, True), "PathUnknown"),
        (classify_socket("IPv6 loopback", True, 2, None, False, False, True, False, True), "PathUnknown"),
        (classify_socket("IPv6 loopback", False, 1, None, False, False, True, False, True), "PathUnknown"),
        (classify_socket("IPv6 loopback", False, 0, 10049, False, False, True, False, True), "PathUnknown"),
        (classify_socket("UDP loopback", False, 0, None, False, False, False, True, False), "NotTested"),
    ]
    failed = []
    for (result, coverage), expected in cases:
        if result != expected:
            failed.append(f"{expected} classified as {result}: {coverage}")
        if "protected" in coverage.lower() or "PathKnown" in coverage:
            failed.append(coverage)
        if result == "Available" and coverage.startswith(("DNS", "DoH", "WebRTC")):
            failed.append(coverage)
    dns_lab = classify_dns(True, True, 1, None, False)[1]
    if "this query only" not in dns_lab or "not production protection" not in dns_lab:
        failed.append(dns_lab)
    dns_answer = classify_dns(True, True, 0, None, False)[1]
    if "not a path proof" not in dns_answer:
        failed.append(dns_answer)
    doh_status = classify_doh(True, 200, 0, None, False)[1]
    doh_lab = classify_doh(True, 200, 1, None, False)[1]
    if "is not browser DoH" not in doh_status or "is not browser DoH" not in doh_lab:
        failed.append(doh_status + " | " + doh_lab)
    udp_lab = classify_socket("UDP loopback", True, 1, None, False, True, True, True, True)[1]
    if "this socket only" not in udp_lab or "not WebRTC protection" not in udp_lab:
        failed.append(udp_lab)
    ipv6_refusal = classify_socket("IPv6 loopback", False, 0, 10013, False, False, True, False, True)[1]
    if "not a public IPv6 path" not in ipv6_refusal:
        failed.append(ipv6_refusal)
    if classify_dns(True, True, 1, None, False)[0] == "Available":
        failed.append("DNS lab exchange became Available")
    if classify_doh(True, 200, 1, None, False)[0] == "Available":
        failed.append("DoH lab exchange became Available")
    return {"checked": len(cases), "failed": failed}


def winerror_of(exc):
    code = getattr(exc, "winerror", None)
    if code:
        return int(code)
    if isinstance(exc, TimeoutError):
        return 10060
    return None


def is_loopback(host):
    text = str(host).split("%", 1)[0].lower()
    return text in {"127.0.0.1", "::1", "0:0:0:0:0:0:0:1"}


def recv_exact(sock, size):
    chunks = []
    remaining = size
    while remaining:
        try:
            block = sock.recv(remaining)
        except (TimeoutError, OSError):
            return b""
        if not block:
            return b""
        chunks.append(block)
        remaining -= len(block)
    return b"".join(chunks)


def configure(sock, family):
    if family == socket.AF_INET6 and hasattr(socket, "IPV6_V6ONLY"):
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)


def tcp_exchange(family, address):
    token = secrets.token_bytes(16)
    state = {"hits": 0}
    server = socket.socket(family, socket.SOCK_STREAM)
    configure(server, family)
    try:
        server.bind((address, 0))
        bound = server.getsockname()
        if not is_loopback(bound[0]):
            raise RuntimeError("TCP listener is not loopback")
        server.listen(1)
        server.settimeout(2)
        port = bound[1]

        def serve():
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with conn:
                conn.settimeout(2)
                data = recv_exact(conn, len(token))
                if data == token:
                    state["hits"] += 1
                    conn.sendall(token)

        thread = Thread(target=serve, daemon=True)
        thread.start()
        started = time.perf_counter()
        matched = False
        error = None
        timed_out = False
        try:
            with socket.socket(family, socket.SOCK_STREAM) as client:
                configure(client, family)
                client.settimeout(2)
                client.connect((address, port))
                client.sendall(token)
                matched = recv_exact(client, len(token)) == token
        except TimeoutError:
            timed_out = True
            error = 10060
        except OSError as exc:
            error = winerror_of(exc)
            timed_out = error == 10060
        elapsed = max(0, round((time.perf_counter() - started) * 1000))
        thread.join(3)
        return state["hits"], matched, error, timed_out, elapsed
    finally:
        server.close()


def udp_exchange(family, address):
    token = secrets.token_bytes(16)
    state = {"hits": 0}
    server = socket.socket(family, socket.SOCK_DGRAM)
    configure(server, family)
    try:
        server.bind((address, 0))
        bound = server.getsockname()
        if not is_loopback(bound[0]):
            raise RuntimeError("UDP listener is not loopback")
        server.settimeout(2)
        port = bound[1]

        def serve():
            try:
                data, peer = server.recvfrom(64)
            except OSError:
                return
            if data == token and is_loopback(peer[0]):
                state["hits"] += 1
                server.sendto(token, peer)

        thread = Thread(target=serve, daemon=True)
        thread.start()
        started = time.perf_counter()
        matched = False
        error = None
        timed_out = False
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as client:
                configure(client, family)
                client.settimeout(2)
                client.sendto(token, (address, port))
                matched = client.recvfrom(64)[0] == token
        except TimeoutError:
            timed_out = True
            error = 10060
        except OSError as exc:
            error = winerror_of(exc)
            timed_out = error == 10060
        elapsed = max(0, round((time.perf_counter() - started) * 1000))
        thread.join(3)
        return state["hits"], matched, error, timed_out, elapsed
    finally:
        server.close()


def encode_qname(name):
    wire = b""
    for label in name.split("."):
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise RuntimeError("DNS label is empty or too long")
        wire += bytes((len(raw),)) + raw
    return wire + b"\x00"


def dns_query(name):
    tid = secrets.randbits(16)
    header = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    return tid, header + encode_qname(name) + struct.pack("!HH", 1, 1)


def parse_question(packet):
    if len(packet) < 17:
        return None
    index = 12
    labels = []
    while index < len(packet):
        length = packet[index]
        if length == 0:
            index += 1
            break
        if length > 63 or index + 1 + length > len(packet):
            return None
        labels.append(packet[index + 1:index + 1 + length])
        index += 1 + length
    if index + 4 > len(packet):
        return None
    qtype, qclass = struct.unpack("!HH", packet[index:index + 4])
    return b".".join(labels), packet[:2], packet[12:index + 4], qtype, qclass


def dns_lab_exchange():
    name = "cab-" + secrets.token_hex(8) + ".invalid"
    expected = name.encode("ascii")
    state = {"hits": 0}
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        server.bind(("127.0.0.1", 0))
        bound = server.getsockname()
        if not is_loopback(bound[0]):
            raise RuntimeError("DNS listener is not loopback")
        server.settimeout(2)
        port = bound[1]

        def serve():
            try:
                packet, peer = server.recvfrom(512)
            except OSError:
                return
            parsed = parse_question(packet)
            if parsed is None or not is_loopback(peer[0]):
                return
            qname, tid, question, qtype, qclass = parsed
            if qname != expected or qtype != 1 or qclass != 1:
                return
            state["hits"] += 1
            header = tid + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
            answer = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 0, 4) + socket.inet_aton("127.0.0.1")
            server.sendto(header + question + answer, peer)

        thread = Thread(target=serve, daemon=True)
        thread.start()
        started = time.perf_counter()
        answer = False
        error = None
        timed_out = False
        try:
            tid, query = dns_query(name)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(2)
                client.sendto(query, ("127.0.0.1", port))
                packet, peer = client.recvfrom(512)
            if is_loopback(peer[0]) and len(packet) >= 16 and packet[:2] == struct.pack("!H", tid):
                ancount = struct.unpack("!H", packet[6:8])[0]
                answer = ancount == 1 and packet.endswith(socket.inet_aton("127.0.0.1"))
        except TimeoutError:
            timed_out = True
            error = 10060
        except OSError as exc:
            error = winerror_of(exc)
            timed_out = error == 10060
        elapsed = max(0, round((time.perf_counter() - started) * 1000))
        thread.join(3)
        return state["hits"], answer, error, timed_out, elapsed
    finally:
        server.close()


def record(protocol, initiator, receiver, result, coverage, error, elapsed, **extra):
    item = {
        "protocol": protocol,
        "initiator": initiator,
        "receiver": receiver,
        "result": result,
        "errorCode": error,
        "elapsedMs": elapsed,
        "coverage": coverage,
    }
    item.update(extra)
    return item


def socket_record(protocol, initiator, receiver, family_note, transport, hits, matched, error, timed_out, elapsed, webrtc_note):
    result, coverage = classify_socket(
        protocol,
        matched,
        hits,
        error,
        timed_out,
        True,
        True,
        webrtc_note,
        True,
    )
    if family_note:
        coverage = coverage + " " + family_note
    return record(
        protocol,
        initiator,
        receiver,
        result,
        coverage,
        error,
        elapsed,
        receiverHits=hits,
        exchanged=bool(matched and hits == 1),
        timedOut=timed_out,
        measured=True,
        transport=transport,
    )


def probe_tcp(protocol, receiver, address, family, family_note, webrtc_note):
    try:
        hits, matched, error, timed_out, elapsed = tcp_exchange(family, address)
    except OSError as exc:
        hits, matched, timed_out, elapsed = 0, False, False, 0
        error = winerror_of(exc)
    return socket_record(
        protocol, "cab-protocol-repro", receiver, family_note, "tcp",
        hits, matched, error, timed_out, elapsed, webrtc_note,
    )


def probe_udp(protocol, receiver, address, family, family_note):
    try:
        hits, matched, error, timed_out, elapsed = udp_exchange(family, address)
    except OSError as exc:
        hits, matched, timed_out, elapsed = 0, False, False, 0
        error = winerror_of(exc)
    return socket_record(
        protocol, "cab-protocol-repro", receiver, family_note, "udp",
        hits, matched, error, timed_out, elapsed, True,
    )


def probe_dns_lab():
    try:
        hits, answer, error, timed_out, elapsed = dns_lab_exchange()
    except OSError as exc:
        hits, answer, timed_out, elapsed = 0, False, False, 0
        error = winerror_of(exc)
    result, coverage = classify_dns(True, answer, hits, error, timed_out)
    return record(
        "DNS",
        "cab-protocol-repro",
        "127.0.0.1",
        result,
        coverage,
        error,
        elapsed,
        receiverHits=hits,
        answerReceived=answer,
        attempted=True,
        measured=True,
        scope="lab-listener",
    )


def unobserved_dns():
    """No system query is sent. The path stays unknown without a counting receiver."""
    return record(
        "DNS",
        "system-resolver",
        "unobserved",
        "PathUnknown",
        "No receiver started by this repro counted a system DNS query, the path is unknown, and this is not protection.",
        None,
        0,
        receiverHits=0,
        answerReceived=False,
        attempted=False,
        measured=False,
        scope="system-unobserved",
    )


def unobserved_doh():
    return record(
        "DoH",
        "none",
        "unobserved",
        "PathUnknown",
        "No receiver started by this repro counted a DoH request, the path is unknown, and this is not protection.",
        None,
        0,
        receiverHits=0,
        httpStatus=None,
        attempted=False,
        measured=False,
        scope="unobserved",
        browserCaptured=False,
    )


def not_tested(protocol, initiator, receiver, coverage, **extra):
    return record(protocol, initiator, receiver, "NotTested", coverage, None, 0, measured=False, **extra)


def build_report():
    records = [
        probe_tcp("IPv4 loopback", "127.0.0.1", "127.0.0.1", socket.AF_INET, "", False),
        probe_udp("UDP loopback", "127.0.0.1", "127.0.0.1", socket.AF_INET, ""),
        probe_tcp("IPv6 loopback", "::1", "::1", socket.AF_INET6, "", False),
        probe_udp("IPv6 UDP loopback", "::1", "::1", socket.AF_INET6, ""),
        probe_dns_lab(),
        unobserved_dns(),
        unobserved_doh(),
        not_tested(
            "browser DoH",
            "browser",
            "unobserved",
            "Browser DoH was not captured, so it is not tested and is not protection.",
            browserCaptured=False,
            receiverHits=0,
        ),
        not_tested(
            "WebRTC",
            "browser",
            "unobserved",
            classify_webrtc(False, True, 1, None, False)[1],
            browserCaptured=False,
            receiverHits=0,
        ),
        not_tested(
            "public IPv6",
            "none",
            "unobserved",
            "Public IPv6 was not tested, a loopback socket does not identify it, and this is not protection.",
            receiverHits=0,
        ),
        not_tested(
            "TURN",
            "none",
            "unobserved",
            "TURN was not tested, no relay was contacted, and this is not protection.",
            receiverHits=0,
        ),
    ]
    return {
        "schemaVersion": 1,
        "tool": "cab-protocol-repro",
        "productionSettingsChanged": False,
        "classifier": classifier_cases(),
        "records": records,
    }


def problems_in(report):
    problems = []
    if report["classifier"]["failed"]:
        problems.extend(report["classifier"]["failed"])
    by_key = {}
    for item in report["records"]:
        key = (item["protocol"], item.get("scope"))
        by_key[key] = item
        coverage = item["coverage"]
        if item["result"] not in CLASSES:
            problems.append(f"bad class for {item['protocol']}")
        if "protected" in coverage.lower() or "PathKnown" in coverage or "PathKnown" in item["result"]:
            problems.append(f"forbidden claim in {item['protocol']}")
        if "verified" in json.dumps(item, ensure_ascii=True).lower():
            problems.append(f"verified claim in {item['protocol']}")
        if item["protocol"] in ("DNS", "DoH", "WebRTC", "browser DoH", "public IPv6", "TURN") and item["result"] == "Available":
            problems.append(f"{item['protocol']} was classified Available")
        if not coverage.strip():
            problems.append(f"empty coverage for {item['protocol']}")

    def need(protocol, scope):
        item = by_key.get((protocol, scope))
        if item is None:
            problems.append(f"missing {protocol} {scope}")
        return item

    ipv4 = need("IPv4 loopback", None)
    udp = need("UDP loopback", None)
    for item, label in ((ipv4, "IPv4 TCP"), (udp, "IPv4 UDP")):
        if item is None:
            continue
        if item["result"] != "LabOnly" or item["receiverHits"] != 1 or not item["exchanged"]:
            problems.append(
                f"{label} was not one counted loopback exchange: {item['result']} hits={item['receiverHits']}"
            )
        if "this socket only" not in item["coverage"] or "not production protection" not in item["coverage"]:
            problems.append(f"{label} coverage does not limit the socket")
        if item["receiver"] != "127.0.0.1":
            problems.append(f"{label} receiver left loopback")
    if udp and "not WebRTC protection" not in udp["coverage"]:
        problems.append("UDP coverage claims WebRTC protection")

    for protocol in ("IPv6 loopback", "IPv6 UDP loopback"):
        item = need(protocol, None)
        if item is None:
            continue
        if "not a public IPv6 path" not in item["coverage"]:
            problems.append(f"{protocol} coverage can be read as public IPv6")
        if item["result"] in ("Available", "LabOnly") and (item["receiverHits"] != 1 or not item["exchanged"]):
            problems.append(f"{protocol} exchange was not counted once")
        if item["receiver"] != "::1":
            problems.append(f"{protocol} receiver is not loopback")

    dns = need("DNS", "lab-listener")
    if dns is not None:
        if dns["result"] != "LabOnly" or dns["receiverHits"] != 1 or not dns["answerReceived"]:
            problems.append(
                f"lab DNS was not one counted query: {dns['result']} hits={dns['receiverHits']}"
            )
        if dns["receiver"] != "127.0.0.1":
            problems.append("lab DNS receiver left loopback")
        if "this query only" not in dns["coverage"] or "not production protection" not in dns["coverage"]:
            problems.append("lab DNS coverage is wider than this query")

    system_dns = need("DNS", "system-unobserved")
    doh = need("DoH", "unobserved")
    for item, label in ((system_dns, "system DNS"), (doh, "DoH")):
        if item is None:
            continue
        if item["result"] != "PathUnknown" or item["receiverHits"] != 0 or item["attempted"] or item["measured"]:
            problems.append(f"{label} was recorded as more than an unknown path")
        if "path is unknown" not in item["coverage"] or "not protection" not in item["coverage"]:
            problems.append(f"{label} coverage does not keep the path unknown")
    if doh is not None and doh["httpStatus"] is not None:
        problems.append("unobserved DoH invented an HTTP status")

    expectations = {
        "browser DoH": "Browser DoH was not captured",
        "WebRTC": "no browser capture",
        "public IPv6": "Public IPv6 was not tested",
        "TURN": "TURN was not tested",
    }
    for protocol, phrase in expectations.items():
        item = need(protocol, None)
        if item is None:
            continue
        if item["result"] != "NotTested" or phrase not in item["coverage"] or item["measured"]:
            problems.append(f"{protocol} is not left NotTested")
        if item.get("browserCaptured"):
            problems.append(f"{protocol} claims a browser capture")
    if report.get("productionSettingsChanged"):
        problems.append("report claims production settings changed")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Measure loopback listeners and check the recording rules")
    args = parser.parse_args()
    if not args.self_test:
        parser.error("pass --self-test; this repro has no public or browser mode")
    report = build_report()
    found = problems_in(report)
    print(json.dumps(report, indent=2))
    if found:
        print("\n".join(found), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
