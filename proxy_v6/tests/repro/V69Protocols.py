"""Loopback DNS, IPv6, ICE and STUN measurements. Outputs no SDP or user IP."""
import argparse
from contextlib import contextmanager
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
from threading import Event, Thread


LOCAL = "127.0.0.1"
COOKIE = 0x2112A442
NODE_RESOLVE = """
const {Resolver} = require('node:dns').promises;
const resolver = new Resolver({timeout:1000, tries:1});
resolver.setServers(['127.0.0.1:' + process.argv[1]]);
resolver.resolve4(process.argv[2]).then(x => console.log(x.join(',')))
  .catch(e => { console.log(e.code); process.exitCode = 2; });
"""


@contextmanager
def serve(server):
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)


class QuietHTTP(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body=b"", mime="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        if len(packet) < 17 or packet[4:12] != bytes.fromhex("0001000000000000"):
            return
        cursor, labels = 12, []
        while cursor < len(packet) and 0 < packet[cursor] <= 63:
            end = cursor + 1 + packet[cursor]
            labels.append(packet[cursor + 1:end])
            cursor = end
        if packet[cursor:cursor + 5] != b"\x00\x00\x01\x00\x01":
            return
        name = b".".join(labels).decode("ascii", errors="replace")
        kind = self.server.names.get(name)
        if kind is None:
            return
        self.server.received.append(kind)
        ok = kind != "negative"
        header = packet[:2] + struct.pack("!HHHHH", 0x8580 if ok else 0x8583, 1, int(ok), 0, 0)
        answer = bytes.fromhex("c00c00010001000000000004") + socket.inet_aton(LOCAL) if ok else b""
        sock.sendto(header + packet[12:cursor + 5] + answer, self.client_address)


class EchoOrigin(QuietHTTP):
    def do_GET(self):
        if self.path != "/" + self.server.challenge:
            self.reply(404)
            return
        self.server.hits += 1
        self.reply(200, self.server.challenge.encode())


def resolve(port, name):
    return subprocess.run(["node", "-e", NODE_RESOLVE, str(port), name],
                          capture_output=True, text=True, timeout=5)


def fetch(url, proxy=None):
    args = ["curl.exe", "-q", "--silent", "--fail", "--max-time", "4",
            "--noproxy", "unused.invalid" if proxy else "*"]
    if proxy:
        args.extend(["--proxy", proxy])
    return subprocess.run(args + [url], capture_output=True, text=True, timeout=6)


def dns_tests():
    token = secrets.token_hex(12)
    with serve(socketserver.UDPServer((LOCAL, 0), DNS)) as dns, \
            serve(ThreadingHTTPServer((LOCAL, 0), EchoOrigin)) as origin:
        origin.challenge, origin.hits = token, 0
        dns.names = {kind + token + ".invalid": kind for kind in ("direct", "negative", "proxy")}
        dns.received = []
        port = dns.server_address[1]
        cases = []
        for kind in ("direct", "negative"):
            start = len(dns.received)
            run = resolve(port, kind + token + ".invalid")
            expected = LOCAL if kind == "direct" else "ENOTFOUND"
            arrived = dns.received[start:].count(kind)
            matched = run.stdout.strip() == expected
            cases.append(dict(query=kind, receiverQueries=arrived, clientResponseMatched=matched,
                              exitCode=run.returncode, status="PASS" if arrived and matched and
                              run.returncode == (0 if kind == "direct" else 2) else "FAILED"))

        hostname = "proxy" + token + ".invalid"
        url = f"http://{hostname}:{origin.server_port}/{token}"

        class FixtureProxy(QuietHTTP):
            def do_GET(self):
                if self.path != url:
                    self.reply(403)
                    return
                self.server.hits += 1
                run = resolve(port, hostname)
                if run.returncode != 0 or run.stdout.strip() != LOCAL:
                    self.reply(502)
                    return
                conn = http.client.HTTPConnection(LOCAL, origin.server_port, timeout=2)
                try:
                    conn.request("GET", "/" + token)
                    reply = conn.getresponse()
                    self.reply(reply.status, reply.read())
                finally:
                    conn.close()

        with serve(ThreadingHTTPServer((LOCAL, 0), FixtureProxy)) as proxy:
            proxy.hits = 0
            run = fetch(url, f"http://{LOCAL}:{proxy.server_port}")
            arrived = dns.received.count("proxy")
            matched = run.stdout == token
            cases.append(dict(query="proxy-resolver", receiverQueries=arrived, proxyRequests=proxy.hits,
                              originRequests=origin.hits, clientResponseMatched=matched,
                              exitCode=run.returncode, status="PASS" if matched and arrived and
                              origin.hits == proxy.hits == 1 and run.returncode == 0 else "FAILED"))
    return cases


class Http6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


class UDP6(socketserver.UDPServer):
    address_family = socket.AF_INET6


class EchoUDP(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        if packet == self.server.challenge.encode():
            self.server.hits += 1
            sock.sendto(packet, self.client_address)


def classify_ipv6(matched, hits, winerror, timed_out):
    """Separate a verified exchange, an explicit socket denial, and an unknown path.

    A timeout or a missing error is not evidence that a filter blocked the packet.
    """
    if matched and hits == 1:
        return "PASS"
    if matched or hits:
        return "FAILED"
    if winerror == 10013:
        return "BLOCKED"
    if winerror in (10047, 10049, 10051, 10065):
        return "STACK_UNAVAILABLE"
    if timed_out or winerror in (10060, None):
        return "UNKNOWN"
    return "UNKNOWN"


def udp6_client(port, challenge):
    result = {"winerror": None, "timedOut": False, "matched": False}
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as sock:
            sock.settimeout(2)
            sock.connect(("::1", int(port)))
            sock.send(challenge.encode())
            result["matched"] = sock.recv(256) == challenge.encode()
    except TimeoutError:
        result["timedOut"] = True
    except OSError as exc:
        result["winerror"] = getattr(exc, "winerror", None)
        result["timedOut"] = result["winerror"] == 10060
    print(json.dumps(result))
    if result["matched"]:
        return 0
    return 4 if result["timedOut"] else 5


def tcp6_connect_error(port):
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
            sock.settimeout(2)
            sock.connect(("::1", int(port)))
        return {"winerror": None, "timedOut": False, "connected": True}
    except TimeoutError:
        return {"winerror": None, "timedOut": True, "connected": False}
    except OSError as exc:
        winerror = getattr(exc, "winerror", None)
        return {"winerror": winerror, "timedOut": winerror == 10060, "connected": False}


def ipv6_stack():
    script = r"""
$ErrorActionPreference = 'SilentlyContinue'
$addrs = @(Get-NetIPAddress -AddressFamily IPv6)
function Count-Class($pred) { @($addrs | Where-Object $pred).Count }
$loopbackCount = Count-Class { [string]$_.IPAddress -eq '::1' }
$linkLocalCount = Count-Class { [string]$_.IPAddress -like 'fe80:*' }
$globalCount = Count-Class {
  $ip = [string]$_.IPAddress
  $ip -ne '::1' -and $ip -notlike 'fe80:*' -and $ip -notlike 'fc*:*' -and $ip -notlike 'fd*:*'
}
$routeCount = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0').Count
$tunnelCount = @(Get-NetAdapter -IncludeHidden | Where-Object {
  $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'sing-tun|wintun|WireGuard|Tunnel'
}).Count
$wintunRunning = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -eq 'wintun' -and $_.State -eq 'Running' }).Count
'{0},{1},{2},{3},{4}' -f $loopbackCount, $linkLocalCount, $globalCount, $routeCount, [int]($tunnelCount -gt 0 -or $wintunRunning -gt 0)
"""
    empty = dict(loopbackAssigned=None, linkLocalAddresses=None, globalUnicastAddresses=None,
                 defaultRoutes=None, tunnelOrWintunActive=None, publicPathSnapshot="NOT_TESTED")
    try:
        run = subprocess.run(["powershell.exe", "-NoProfile", "-Command", script],
                             capture_output=True, text=True, timeout=40)
    except (OSError, subprocess.SubprocessError):
        return empty
    line = next((item.strip() for item in reversed(run.stdout.splitlines()) if "," in item), "")
    parts = line.split(",")
    if run.returncode != 0 or len(parts) != 5 or not all(part in ("0", "1") or part.isdigit() for part in parts):
        return empty
    loop, link, global_count, routes, tunnel = (int(part) for part in parts)
    if global_count == 0 and routes == 0:
        public = "NO_GLOBAL_ADDRESS_OR_DEFAULT_ROUTE"
    else:
        public = "PRESENT_NOT_TESTED"
    return dict(loopbackAssigned=loop > 0, linkLocalAddresses=link, globalUnicastAddresses=global_count,
                defaultRoutes=routes, tunnelOrWintunActive=bool(tunnel), publicPathSnapshot=public)


def ipv6_test(proto):
    server_type, handler = (Http6, EchoOrigin) if proto == "TCP" else (UDP6, EchoUDP)
    try:
        with serve(server_type(("::1", 0), handler)) as receiver:
            token = secrets.token_hex(12)
            receiver.challenge, receiver.hits = token, 0
            port = receiver.server_address[1]
            detail = {"winerror": None, "timedOut": False}
            if proto == "TCP":
                run = fetch(f"http://[::1]:{port}/{token}")
                matched = run.stdout == token
                if not matched:
                    detail = tcp6_connect_error(port)
            else:
                run = subprocess.run([sys.executable, __file__, "--udp6", str(port), token],
                                     capture_output=True, text=True, timeout=5)
                try:
                    detail = json.loads(run.stdout.strip() or "{}")
                except json.JSONDecodeError:
                    detail = {"winerror": None, "timedOut": False, "parseError": True}
                matched = bool(detail.get("matched")) and run.returncode == 0
            status = classify_ipv6(matched, receiver.hits, detail.get("winerror"), bool(detail.get("timedOut")))
            return dict(protocol=proto, client="curl" if proto == "TCP" else "python",
                        target="IPv6 loopback", receiverRequests=receiver.hits,
                        matched=matched, exitCode=run.returncode, winerror=detail.get("winerror"),
                        timedOut=bool(detail.get("timedOut")), status=status)
    except OSError as exc:
        return dict(protocol=proto, target="IPv6 loopback", status="STACK_UNAVAILABLE",
                    setupError=getattr(exc, "winerror", None) or exc.errno, exitCode=None)


class Stun(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) < 20 or data[:2] != b"\x00\x01" or data[4:8] != struct.pack("!I", COOKIE):
            return
        if int.from_bytes(data[2:4], "big") != len(data) - 20:
            return
        ip, port = self.client_address
        mapped = int.from_bytes(socket.inet_aton(ip), "big") ^ COOKIE
        attribute = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, port ^ (COOKIE >> 16), mapped)
        sock.sendto(struct.pack("!HH", 0x0101, len(attribute)) + data[4:20] + attribute, (ip, port))
        self.server.replies += 1


def stun_control(server):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.connect(server.server_address)
        tx = secrets.token_bytes(12)
        sock.send(struct.pack("!HHI", 1, 0, COOKIE) + tx)
        answer = sock.recv(128)
        ip, port = sock.getsockname()
        expected = struct.pack("!HHI", 0x0101, 12, COOKIE) + tx + struct.pack(
            "!HHBBHI", 0x0020, 8, 0, 1, port ^ (COOKIE >> 16),
            int.from_bytes(socket.inet_aton(ip), "big") ^ COOKIE)
        return answer == expected


def browser_test(chrome, mode):
    html = Path(__file__).with_suffix(".html").read_bytes()
    token = secrets.token_hex(16)
    ready = Event()
    result = {}
    with serve(socketserver.UDPServer((LOCAL, 0), Stun)) as stun:
        stun.replies = 0
        before = stun_control(stun)

        class Page(QuietHTTP):
            def do_GET(self):
                if self.path == f"/{token}/":
                    self.reply(200, html, "text/html")
                elif self.path == f"/{token}/setup":
                    self.reply(200, json.dumps(dict(port=stun.server_address[1], challenge=token)).encode(),
                               "application/json")
                elif self.path == f"/{token}/hold":
                    ready.wait(12)
                    self.reply(204)
                else:
                    self.reply(404)

            def do_POST(self):
                if self.path != f"/{token}/result":
                    self.reply(404)
                    return
                length = int(self.headers.get("Content-Length", 0))
                if not 0 < length <= 16384:
                    self.reply(400)
                    return
                result.update(json.loads(self.rfile.read(length)))
                self.reply(204)
                ready.set()

        replies_before = stun.replies
        with tempfile.TemporaryDirectory(prefix="v69-protocol-") as profile, \
                serve(ThreadingHTTPServer((LOCAL, 0), Page)) as http:
            # The test server rejects unrelated HTTP requests. External names never
            # need resolving; Chromium's implicit loopback bypass serves the page.
            args = [str(chrome), "--headless", "--dump-dom", "--no-first-run",
                    "--disable-extensions", "--disable-sync", "--disable-component-update",
                    "--disable-background-networking", "--disable-default-apps",
                    "--user-data-dir=" + profile, f"--proxy-server=http://{LOCAL}:{http.server_port}"]
            if mode != "default":
                args.append("--webrtc-ip-handling-policy=" + mode)
            args.append(f"http://{LOCAL}:{http.server_port}/{token}/")
            try:
                run = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=24)
                code = run.returncode
            except subprocess.TimeoutExpired:
                code = None
            finally:
                ready.set()
        browser_replies = stun.replies - replies_before
        after = stun_control(stun)
    observed = (isinstance(result.get("gathered"), list) and before and after and
                code == 0 and not result.get("error"))
    transferred = (result.get("dataSent") is True and result.get("dataReceived") is True and
                   result.get("outcome") == "round-trip" and result.get("selectedTransport") == "udp")
    complete_empty = result.get("gathered") == [] and result.get("gatheringState") == ["complete"] * 2
    if mode == "default":
        expected = transferred and browser_replies > 0
    else:
        expected = (complete_empty and browser_replies == 0 and
                    result.get("outcome") == "observation-timeout" and
                    result.get("dataSent") is False and result.get("dataReceived") is False)
    return dict(mode=mode, chromeExitCode=code, profileRemoved=not Path(profile).exists(),
                stunControls=[before, after], browserStunReplies=browser_replies, browser=result,
                observation="PASS" if observed and expected else "FAILED",
                proxyUdp="NOT_TESTED", enforcedUdpBlock="NOT_TESTED")


def site_data_test(chrome):
    """Delete synthetic data at one origin and observe an untouched control origin."""
    token = secrets.token_hex(16)
    key = "fixture_" + token
    events = []

    class DataPage(QuietHTTP):
        def do_GET(self):
            if self.path == "/" + token + "/clear":
                self.send_response(200)
                self.send_header("Clear-Site-Data", '"cookies", "storage", "cache"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path not in ("/" + token + "/create", "/" + token + "/check"):
                self.reply(404)
                return
            initialize = self.path.endswith("/create")
            # Only two generated values from this disposable profile are examined.
            script = """
            const key = %s;
            if (%s) {
              document.cookie = key + '=fixture; Max-Age=120; SameSite=Strict; Path=/';
              localStorage.setItem(key, 'fixture');
            }
            const state = [
              document.cookie.split('; ').includes(key + '=fixture'),
              localStorage.getItem(key) === 'fixture'
            ];
            document.body.textContent = 'fixture-result-' + state.join('-');
            """ % (json.dumps(key), json.dumps(initialize))
            self.reply(200, ("<body><script>" + script + "</script></body>").encode(), "text/html")

    with tempfile.TemporaryDirectory(prefix="v69-data-") as profile, \
            serve(ThreadingHTTPServer((LOCAL, 0), DataPage)) as http:
        # Use two distinct hosts: cookies are not separated by port.
        for host, action, present in ((LOCAL, "create", True), ("localhost", "create", True),
                                      (LOCAL, "clear", None), (LOCAL, "check", False),
                                      ("localhost", "check", True)):
            args = [str(chrome), "--headless", "--dump-dom", "--no-first-run",
                    "--disable-sync", "--disable-extensions", "--disable-component-update",
                    "--disable-background-networking", "--disable-default-apps",
                    "--user-data-dir=" + profile, f"--proxy-server=http://{LOCAL}:{http.server_port}",
                    f"http://{host}:{http.server_port}/{token}/{action}"]
            run = subprocess.run(args, capture_output=True, timeout=20)
            marker = b"fixture-result-true-true" if present else b"fixture-result-false-false"
            matched = run.returncode == 0 and (present is None or marker in run.stdout)
            events.append(dict(origin="selected" if host == LOCAL else "control", action=action,
                               markerMatched=matched, exitCode=run.returncode))
    return dict(events=events, profileRemoved=not Path(profile).exists(),
                status="PASS" if all(event["markerMatched"] for event in events) else "FAILED")


def classify_self_test():
    expected = (
        (True, 1, None, False, "PASS"),
        (False, 0, 10013, False, "BLOCKED"),
        (False, 0, None, True, "UNKNOWN"),
        (False, 0, 10060, True, "UNKNOWN"),
        (False, 0, 10049, False, "STACK_UNAVAILABLE"),
        (False, 0, 10051, False, "STACK_UNAVAILABLE"),
        (False, 1, 10013, False, "FAILED"),
        (True, 0, None, False, "FAILED"),
        (True, 2, None, False, "FAILED"),
    )
    failed = [row for row in expected if classify_ipv6(*row[:4]) != row[4]]
    print(json.dumps({"checked": len(expected), "failed": len(failed)}))
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", type=Path)
    parser.add_argument("--self-test", action="store_true", help="Check IPv6 result classification only")
    parser.add_argument("--udp6", nargs=2, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.udp6:
        return udp6_client(*args.udp6)
    if args.self_test:
        return classify_self_test()
    chrome = args.chrome
    if not chrome:
        chrome = next((p for key in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA") if key in os.environ
                       and (p := Path(os.environ[key]) / "Google/Chrome/Application/chrome.exe").is_file()), None)
    if not shutil.which("node") or not shutil.which("curl.exe"):
        parser.error("Node.js and Windows curl.exe are required")
    dns, ipv6 = dns_tests(), [ipv6_test(p) for p in ("TCP", "UDP")]
    rtc = [browser_test(chrome, mode) for mode in ("default", "disable_non_proxied_udp")] if chrome else []
    site_data = site_data_test(chrome) if chrome else {"status": "NOT_TESTED"}
    report = dict(dns=dns, ipv6=ipv6, ipv6Stack=ipv6_stack(), webRtc=rtc, browserAvailable=bool(chrome),
                  siteData=site_data, osResolver="NOT_TESTED", browserDoH="NOT_TESTED", production="NOT_TESTED")
    print(json.dumps(report, indent=2))
    # Exit 2 preserves limited/incomplete coverage. It never means "leak blocked".
    if (any(row["status"] != "PASS" for row in dns) or any(row["observation"] != "PASS" for row in rtc)
            or site_data["status"] == "FAILED"):
        return 1
    return 2 if not rtc or any(row["status"] != "PASS" for row in ipv6) else 0


if __name__ == "__main__":
    sys.exit(main())
