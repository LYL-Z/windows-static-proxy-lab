"""Record the first failing loopback Winsock stage for IPv4 and IPv6, TCP and UDP.

Stages are bind, listen (TCP only), connect, send, and recv. The probe opens
sockets to 127.0.0.1 and ::1 only. It does not change firewall, DNS, routes,
or proxy settings. A timeout is not a confirmed block. A TCP 10013 names one
stage on that socket and is not a machine-wide kill switch.
"""
import argparse
import ipaddress
import json
import re
import secrets
import socket
from threading import Event, Thread


HOSTS = {"IPv4": "127.0.0.1", "IPv6": "::1"}
ORDER = (("TCP", "IPv4"), ("UDP", "IPv4"), ("TCP", "IPv6"), ("UDP", "IPv6"))
STAGES = ("bind", "listen", "connect", "send", "recv")
STACK_CODES = frozenset((10047, 10049, 10051, 10065))
CLIENT_TIMEOUT = 2.0
SERVER_TIMEOUT = 3.0
COVERAGE = (
    "A TCP 10013 names an access denial at one Winsock stage for that "
    "loopback socket and is not a machine-wide kill switch."
)
ALLOWED_LITERALS = frozenset({"127.0.0.1", "::1"})
IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
IPV6_RE = re.compile(r"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])")
# protocol, stage, winerror, timed_out, receiver_got_payload, echoed, unexpected, disagree, expected
CLASSIFIER_CASES = (
    ("TCP", None, None, False, True, True, False, False, "PASS"),
    ("UDP", None, None, False, True, True, False, False, "PASS"),
    ("TCP", "bind", 10013, False, False, False, False, False, "BLOCKED"),
    ("TCP", "listen", 10013, False, False, False, False, False, "BLOCKED"),
    ("TCP", "connect", 10013, False, False, False, False, False, "BLOCKED"),
    ("TCP", "send", 10013, False, False, False, False, False, "BLOCKED"),
    ("TCP", "recv", 10013, False, False, False, False, False, "BLOCKED"),
    ("UDP", "bind", 10013, False, False, False, False, False, "BLOCKED"),
    ("UDP", "connect", 10013, False, False, False, False, False, "BLOCKED"),
    ("UDP", "send", 10013, False, False, False, False, False, "BLOCKED"),
    ("UDP", "recv", 10013, False, False, False, False, False, "BLOCKED"),
    ("UDP", "listen", 10013, False, False, False, False, False, "FAILED"),
    ("TCP", "connect", 10047, False, False, False, False, False, "STACK_UNAVAILABLE"),
    ("TCP", "bind", 10049, False, False, False, False, False, "STACK_UNAVAILABLE"),
    ("UDP", "connect", 10051, False, False, False, False, False, "STACK_UNAVAILABLE"),
    ("UDP", "recv", 10065, False, False, False, False, False, "STACK_UNAVAILABLE"),
    ("TCP", None, 10065, False, False, False, False, False, "STACK_UNAVAILABLE"),
    ("UDP", "recv", None, True, False, False, False, False, "UNKNOWN"),
    ("UDP", "recv", 10060, True, False, False, False, False, "UNKNOWN"),
    ("UDP", "recv", 10060, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "connect", None, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "connect", 10061, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "recv", 10054, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "connect", 10050, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "connect", 10064, False, False, False, False, False, "UNKNOWN"),
    ("TCP", "connect", 10013, False, True, False, False, False, "FAILED"),
    ("TCP", "connect", 10013, False, False, True, False, False, "FAILED"),
    ("TCP", "connect", 10013, True, False, False, False, False, "FAILED"),
    ("TCP", None, 10013, False, False, False, False, False, "FAILED"),
    ("TCP", None, None, False, True, False, False, False, "FAILED"),
    ("TCP", None, None, False, False, True, False, False, "FAILED"),
    ("TCP", None, None, False, False, False, True, False, "FAILED"),
    ("TCP", None, None, False, True, True, True, False, "FAILED"),
    ("UDP", "recv", None, True, True, False, False, False, "FAILED"),
    ("TCP", "bind", 10049, False, True, False, False, False, "FAILED"),
    ("TCP", "connect", 10049, True, False, False, False, False, "FAILED"),
    ("TCP", "connect", 10013, False, False, False, True, False, "FAILED"),
    ("TCP", None, None, False, True, True, False, True, "FAILED"),
    ("TCP", "accept", None, False, False, False, False, False, "FAILED"),
    ("UDP", "accept", 10013, False, False, False, False, False, "FAILED"),
    ("ICMP", None, None, False, True, True, False, False, "FAILED"),
)


class StageFailure(Exception):
    def __init__(self, stage, winerror, timed_out):
        super().__init__(stage)
        self.stage = stage
        self.winerror = winerror
        self.timed_out = bool(timed_out)


def winsock_code(exc):
    code = getattr(exc, "winerror", None)
    if type(code) is int:
        return code
    return None


def is_timeout(exc):
    if isinstance(exc, TimeoutError):
        return True
    kind = getattr(socket, "timeout", None)
    return isinstance(kind, type) and kind is not OSError and isinstance(exc, kind)


def failure_from(stage, exc):
    code = winsock_code(exc)
    timed_out = is_timeout(exc) or code == 10060
    if is_timeout(exc) and code != 10060:
        code = None
    return StageFailure(stage, code, timed_out)


def classify(protocol, stage, winerror, timed_out, receiver_got_payload, echoed, unexpected, disagree=False):
    """Classify one exchange. One row does not change the next row's status.

    PASS requires the echoed payload and a receiver count, with no contrary signal.
    BLOCKED requires winerror 10013 at a named stage and no payload.
    STACK_UNAVAILABLE requires 10047, 10049, 10051, or 10065 before any payload.
    UNKNOWN is a timeout or any other inconclusive result. Timeout is not a block.
    """
    timeout = bool(timed_out) or winerror == 10060
    named = stage in STAGES
    arrived = bool(receiver_got_payload or echoed or unexpected)
    deny = winerror == 10013
    stack = winerror in STACK_CODES
    contradictory = (
        disagree
        or bool(unexpected)
        or bool(echoed) != bool(receiver_got_payload)
        or (protocol == "UDP" and stage == "listen")
        or (stage is not None and not named)
        or (echoed and receiver_got_payload and (stage is not None or winerror is not None or timeout))
        or (arrived and (deny or stack or timeout))
        or ((deny or stack) and timeout)
        or (deny and not named)
        or protocol not in ("TCP", "UDP")
    )
    if contradictory:
        return "FAILED"
    if echoed and receiver_got_payload:
        return "PASS"
    if deny:
        return "BLOCKED"
    if stack:
        return "STACK_UNAVAILABLE"
    return "UNKNOWN"


def foreign_addresses(text):
    found = IPV4_RE.findall(text) + IPV6_RE.findall(text)
    return [item for item in found if item not in ALLOWED_LITERALS]


def coverage_sentence_ok(text):
    if not isinstance(text, str) or text != text.strip() or "\n" in text:
        return False
    if text.count(".") != 1 or not text.endswith("."):
        return False
    lowered = text.lower()
    return "10013" in text and "machine-wide kill switch" in lowered and "tcp" in lowered and not foreign_addresses(text)


def row(protocol, family, stage, winerror, timed_out, receiver_got_payload, status):
    return {
        "protocol": protocol,
        "family": family,
        "stage": stage,
        "winerror": winerror if type(winerror) is int else None,
        "timedOut": bool(timed_out),
        "receiverGotPayload": bool(receiver_got_payload),
        "status": status,
    }


def same_loopback(family, observed):
    if not isinstance(observed, str):
        return False
    try:
        return ipaddress.ip_address(observed.split("%", 1)[0]) == ipaddress.ip_address(HOSTS[family])
    except ValueError:
        return False


def close_quietly(sock):
    if sock is None:
        return
    try:
        sock.close()
    except OSError:
        return


def open_socket(family, protocol, stage):
    address_family = socket.AF_INET if family == "IPv4" else socket.AF_INET6
    kind = socket.SOCK_STREAM if protocol == "TCP" else socket.SOCK_DGRAM
    sock = None
    try:
        sock = socket.socket(address_family, kind)
        if family == "IPv6":
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        if protocol == "TCP":
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock
    except (TimeoutError, OSError) as exc:
        close_quietly(sock)
        raise failure_from(stage, exc) from None


def recvall(sock, size):
    parts = bytearray()
    while len(parts) < size:
        chunk = sock.recv(size - len(parts))
        if not chunk:
            break
        parts.extend(chunk)
    return bytes(parts)


def serve(protocol, server, payload, outcome, ready):
    try:
        server.settimeout(SERVER_TIMEOUT)
    except (TimeoutError, OSError):
        outcome["fault"] = True
        ready.set()
        return
    ready.set()
    try:
        if protocol == "TCP":
            conn, _peer = server.accept()
            with conn:
                conn.settimeout(SERVER_TIMEOUT)
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                data = recvall(conn, len(payload))
                if data == payload:
                    outcome["hits"] += 1
                    conn.sendall(payload)
                elif data:
                    outcome["unexpected"] = True
            return
        data, peer = server.recvfrom(256)
        if data == payload:
            outcome["hits"] += 1
            server.sendto(payload, peer)
        elif data:
            outcome["unexpected"] = True
    except (TimeoutError, OSError):
        return
    except Exception:
        outcome["fault"] = True


def send_payload(protocol, sock, payload):
    try:
        if protocol == "TCP":
            sock.sendall(payload)
            return
        sent = sock.send(payload)
    except (TimeoutError, OSError) as exc:
        raise failure_from("send", exc) from None
    if sent != len(payload):
        raise StageFailure("send", None, False)


def read_reply(protocol, sock, size):
    try:
        if protocol == "TCP":
            return recvall(sock, size)
        return sock.recv(256)
    except (TimeoutError, OSError) as exc:
        raise failure_from("recv", exc) from None


def measure(protocol, family):
    host = HOSTS[family]
    payload = secrets.token_bytes(16)
    outcome = {"hits": 0, "unexpected": False, "fault": False}
    server = client = thread = None
    stage = winerror = None
    timed_out = echoed = disagree = False
    data = b""
    try:
        server = open_socket(family, protocol, "bind")
        try:
            server.bind((host, 0))
        except (TimeoutError, OSError) as exc:
            raise failure_from("bind", exc) from None
        bound = server.getsockname()
        port = bound[1] if bound else None
        if not isinstance(port, int) or not 0 < port <= 65535 or not same_loopback(family, bound[0]):
            disagree = True
            stage = "bind"
        else:
            if protocol == "TCP":
                try:
                    server.listen(1)
                except (TimeoutError, OSError) as exc:
                    raise failure_from("listen", exc) from None
            ready = Event()
            thread = Thread(target=serve, args=(protocol, server, payload, outcome, ready), daemon=True)
            thread.start()
            if not ready.wait(SERVER_TIMEOUT):
                disagree = True
                stage = "listen" if protocol == "TCP" else "bind"
            else:
                client = open_socket(family, protocol, "connect")
                client.settimeout(CLIENT_TIMEOUT)
                try:
                    client.connect((host, port))
                except (TimeoutError, OSError) as exc:
                    raise failure_from("connect", exc) from None
                send_payload(protocol, client, payload)
                data = read_reply(protocol, client, len(payload))
                if data == payload:
                    echoed = True
                elif data:
                    outcome["unexpected"] = True
                else:
                    stage = "recv"
    except StageFailure as failure:
        stage, winerror, timed_out = failure.stage, failure.winerror, failure.timed_out
    finally:
        close_quietly(client)
        close_quietly(server)
        if thread is not None:
            thread.join(SERVER_TIMEOUT)
            if thread.is_alive():
                disagree = True
    if outcome["fault"] or outcome["hits"] > 1:
        disagree = True
    unexpected = bool(outcome["unexpected"] or outcome["hits"] > 1 or (data and data != payload))
    receiver_got_payload = outcome["hits"] > 0
    status = classify(
        protocol, stage, winerror, timed_out, receiver_got_payload, echoed, unexpected, disagree
    )
    return row(protocol, family, stage, winerror, timed_out, receiver_got_payload, status)


def fault_row(protocol, family, exc):
    code = winsock_code(exc) if isinstance(exc, OSError) else None
    return row(protocol, family, None, code, False, False, "FAILED")


def safe_measure(protocol, family):
    try:
        return measure(protocol, family)
    except Exception as exc:
        return fault_row(protocol, family, exc)


def mapping_checks():
    timeout = failure_from("recv", TimeoutError())
    denied = OSError()
    denied.winerror = 10013
    denied_failure = failure_from("connect", denied)
    timed_code = OSError()
    timed_code.winerror = 10060
    timed_failure = failure_from("recv", timed_code)
    return (
        timeout.stage == "recv" and timeout.winerror is None and timeout.timed_out
        and denied_failure.stage == "connect" and denied_failure.winerror == 10013
        and not denied_failure.timed_out
        and timed_failure.winerror == 10060 and timed_failure.timed_out
    )


def sanitizer_checks():
    blocked = ("10.0.0.8", "0.0.0.0", "192.168.1.1", "2001:db8::1", "::ffff:127.0.0.1", "fe80::1")
    sample = {"rows": [row("TCP", "IPv6", "connect", 10013, False, False, "BLOCKED")], "coverage": COVERAGE}
    allowed = ("127.0.0.1", "::1", json.dumps(sample, indent=2), COVERAGE)
    blocked_hidden = all(foreign_addresses(item) for item in blocked)
    allowed_clean = not any(foreign_addresses(item) for item in allowed)
    return blocked_hidden and allowed_clean


def independent_calls():
    blocked = classify("TCP", "connect", 10013, False, False, False, False, False)
    passed = classify("TCP", None, None, False, True, True, False, False)
    return blocked == "BLOCKED" and passed == "PASS"


def self_test():
    opened = {"n": 0}
    original = socket.socket

    def banned(*_args, **_kwargs):
        opened["n"] += 1
        raise RuntimeError("socket")

    mismatches = []
    mapping_ok = coverage_ok = sanitizer_ok = independent_ok = False
    socket.socket = banned
    try:
        for index, case in enumerate(CLASSIFIER_CASES):
            got = classify(*case[:-1])
            if got != case[-1]:
                mismatches.append({"index": index, "expected": case[-1], "actual": got})
        mapping_ok = mapping_checks()
        coverage_ok = coverage_sentence_ok(COVERAGE)
        sanitizer_ok = sanitizer_checks()
        independent_ok = independent_calls()
    except RuntimeError as exc:
        if str(exc) != "socket":
            raise
    finally:
        socket.socket = original
    extras = (mapping_ok, coverage_ok, sanitizer_ok, independent_ok, opened["n"] == 0)
    report = {
        "checked": len(CLASSIFIER_CASES) + len(extras),
        "failed": len(mismatches) + sum(not item for item in extras),
        "socketsOpened": opened["n"],
    }
    if mismatches:
        report["mismatches"] = mismatches
    return report, report["failed"] == 0 and not foreign_addresses(json.dumps(report))


def live():
    report = {"rows": [safe_measure(protocol, family) for protocol, family in ORDER], "coverage": COVERAGE}
    ok = (
        len(report["rows"]) == 4
        and all(item["status"] != "FAILED" for item in report["rows"])
        and coverage_sentence_ok(COVERAGE)
    )
    return report, ok


def emit(report, ok):
    text = json.dumps(report, indent=2, ensure_ascii=True)
    if foreign_addresses(text):
        text = json.dumps({"status": "FAILED", "winerror": None, "coverage": COVERAGE}, indent=2, ensure_ascii=True)
        ok = False
        if foreign_addresses(text):
            text = '{"status": "FAILED", "winerror": null}'
    print(text)
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Check the classifier without opening sockets")
    args = parser.parse_args(argv)
    try:
        report, ok = self_test() if args.self_test else live()
    except Exception as exc:
        code = winsock_code(exc) if isinstance(exc, OSError) else None
        report, ok = ({"status": "FAILED", "winerror": code, "coverage": COVERAGE}, False)
    return emit(report, ok)


if __name__ == "__main__":
    raise SystemExit(main())
