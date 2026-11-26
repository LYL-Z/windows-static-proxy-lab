"""Exercise the V4 classifier with disposable loopback sockets and a real curl process."""

import base64
from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
from threading import Thread


ROOT = Path(__file__).resolve().parents[3]
EXPECTED = "203.0.113.10"
OTHER = "198.51.100.9"
CURL = str(Path(os.environ["SystemRoot"]) / "System32" / "curl.exe")
POWERSHELL = str(Path(os.environ["SystemRoot"]) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")


class HttpHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_bytes(self, status, payload):
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class Origin(HttpHandler):
    def do_GET(self):
        self.server.hits += 1
        self.send_bytes(200, self.server.response.encode("ascii"))


class Core(HttpHandler):
    def do_GET(self):
        if self.path != self.server.allowed_url or self.server.down:
            self.send_bytes(502, b"fixture chain unavailable")
            return
        # Forward only to this test's own fixed loopback origin.
        connection = HTTPConnection("127.0.0.1", self.server.origin_port, timeout=2)
        try:
            connection.request("GET", "/identity")
            response = connection.getresponse()
            self.send_bytes(response.status, response.read())
        finally:
            connection.close()


class FirstHop(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        if self.rfile.readline(1024).startswith(b"CONNECT "):
            self.wfile.write(f"HTTP/1.1 {self.server.code} Fixture\r\n\r\n".encode("ascii"))


@contextmanager
def serving(server):
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def sample(workspace, hop_port, core_port, core_probe_port, windows_port, origin_url):
    lib = str(ROOT / "proxy_v4" / "lib" / "V4.ps1").replace("'", "''")
    code = f"""
    $ErrorActionPreference = 'Stop'
    . '{lib}'
    $hop = Test-V4FirstHop -Port {hop_port} -TimeoutMs 1200
    $core = Test-V4Port -Port {core_probe_port} -TimeoutMs 1200
    $r = Get-V4StateCore -Settings @{{mixedPort={core_port};host='{EXPECTED}'}} `
        -SystemProxy @{{enabled=$true;server='127.0.0.1:{windows_port}'}} `
        -AppPids @(42) -MixedPortOpen $core -FirstHop $hop -UiSystemProxy $true `
        -AutomaticProxyStatus NOT_OBSERVED -GetExitIp {{
            param($proxy)
            $text = & curl.exe -q --fail --silent --max-time 3 --proxy $proxy `
                --noproxy no-match.invalid '{origin_url}'
            if ($LASTEXITCODE -eq 0) {{ ($text -join '').Trim() }}
        }}
    [pscustomobject]$r | Select-Object state,firstHopStatus,mixedPort,chainStatus,faults,applicationPath |
        ConvertTo-Json -Compress
    """
    env = os.environ.copy()
    env.pop("PSMODULEPATH", None)
    env.update(V4_TEST_MODE="1", V4_TEST_ROOT=workspace)
    encoded = base64.b64encode(code.encode("utf-16-le")).decode("ascii")
    run = subprocess.run(
        [POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        env=env, capture_output=True, check=True, timeout=15,
    )
    return json.loads(run.stdout)


def transport_echo(family, protocol, address):
    stage = "socket"
    try:
        with socket.socket(family, protocol) as server, socket.socket(family, protocol) as client:
            server.settimeout(2)
            client.settimeout(2)
            stage = "bind"
            server.bind((address, 0))
            payload = b"v68 loopback payload"
            stage = "exchange"
            if protocol == socket.SOCK_STREAM:
                server.listen(1)
                client.connect(server.getsockname())
                accepted, _ = server.accept()
                with accepted:
                    accepted.settimeout(2)
                    client.sendall(payload)
                    accepted.sendall(accepted.recv(128))
                    assert client.recv(128) == payload
            else:
                client.sendto(payload, server.getsockname())
                received, peer = server.recvfrom(128)
                server.sendto(received, peer)
                assert client.recvfrom(128)[0] == payload
        return {"status": "ISOLATED_PASS"}
    except OSError as error:
        return {"status": "LOCAL_PROBE_UNAVAILABLE", "stage": stage,
                "winerror": getattr(error, "winerror", None), "errno": error.errno}


def main():
    rows = {}
    with tempfile.TemporaryDirectory(prefix="V68-loopback-") as workspace, \
            serving(ThreadingHTTPServer(("127.0.0.1", 0), Origin)) as origin, \
            serving(ThreadingHTTPServer(("127.0.0.1", 0), Core)) as core, \
            serving(socketserver.TCPServer(("127.0.0.1", 0), FirstHop)) as hop, \
            socket.socket(socket.AF_INET, socket.SOCK_STREAM) as closed:
        url = f"http://127.0.0.1:{origin.server_port}/identity"
        core.allowed_url, core.origin_port, core.down = url, origin.server_port, False
        origin.hits, origin.response, hop.code = 0, EXPECTED, 200
        closed.bind(("127.0.0.1", 0))  # Reserved but not listening.
        closed_port = closed.getsockname()[1]

        def observe(name, state, hop_port=hop.server_address[1], core_probe_port=core.server_port,
                    windows_port=core.server_port, fault=None):
            report = sample(workspace, hop_port, core.server_port, core_probe_port, windows_port, url)
            assert report["state"] == state, (name, report)
            assert report["applicationPath"] == "NOT_TESTED", (name, report)
            assert report["faults"] == ([fault] if fault else []), (name, report)
            rows[name] = report

        observe("normal", "CHAIN_VERIFIED")
        observe("first_hop_stopped", "DEGRADED", hop_port=closed_port, fault="FIRST_HOP_TCP_UNAVAILABLE")
        hop.code = 502
        observe("first_hop_listens_but_refuses_connect", "DEGRADED", fault="FIRST_HOP_CONNECT_FAILED")
        hop.code = 200
        core.down = True
        observe("first_hop_returned_but_chain_failed", "FAILED", fault="CHAIN_EXIT_UNVERIFIED")
        core.down = False
        observe("chain_reverified", "CHAIN_VERIFIED")
        observe("core_listener_lost", "FAILED", core_probe_port=closed_port, fault="CORE_LISTENER_UNVERIFIED")
        previous_hits = origin.hits
        curl = subprocess.run([CURL, "-q", "--fail", "--silent", "--max-time", "2",
                               "--proxy", f"http://127.0.0.1:{closed_port}", "--noproxy",
                               "no-match.invalid", url], timeout=5)
        assert curl.returncode and origin.hits == previous_hits
        observe("windows_proxy_target_drift", "DEGRADED", windows_port=closed_port, fault="SYSTEM_PROXY_DRIFT")
        origin.response = OTHER
        observe("unexpected_exit", "DEGRADED", fault="EXIT_MISMATCH")

    transport = {}
    for family, address in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        for protocol in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            transport[f"{family.name}_{protocol.name}"] = transport_echo(family, protocol, address)
    print(json.dumps({
        "source": "ISOLATED_REAL_LOOPBACK_WITH_SYNTHETIC_TOPOLOGY",
        "classifierInputs": "TCP/CONNECT and curl HTTP response with reserved documentation addresses",
        "applicationNegative": "explicit curl proxy unavailable, origin received no direct request",
        "scenarios": rows, "loopbackTransportEcho": transport,
        "realClientLifecycle": "NOT_TESTED",
        "proxiedUdpAndIpv6": "NOT_TESTED",
    }, indent=2))
    return int(any(result["status"] != "ISOLATED_PASS" for name, result in transport.items()
                   if name.startswith("AF_INET_")))


if __name__ == "__main__":
    raise SystemExit(main())
