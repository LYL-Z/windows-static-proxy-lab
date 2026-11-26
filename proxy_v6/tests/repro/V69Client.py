"""Run a disposable Chrome and a local HTTP receiver. Python 3.11+, websockets 13.x."""

import argparse
from collections import Counter
from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import multiprocessing as mp
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
from threading import Event, Lock, Thread
import time
from urllib.parse import urlsplit

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect


LOOPBACK = "127.0.0.1"


class QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class Receiver(QuietHandler):
    def do_GET(self):
        prefix = self.server.prefix
        if not self.path.startswith(prefix):
            self.reply(404, b"")
            return
        key = self.path[len(prefix):]
        # This unpredictable marker is known only by the forwarding fixture and receiver.
        route = "relay" if self.headers.get("X-Lab-Hop") == self.server.marker else "direct"
        with self.server.lock:
            self.server.hits[key, route] += 1
        if key == "document":
            self.reply(200, b"<html data-lab='ready'><title>Local test</title></html>", "text/html")
        elif key == "active":
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"A")
            self.wfile.flush()
            self.server.release.wait(20)
            try:
                self.wfile.write(b"B")
            except OSError:
                pass
        else:
            self.reply(200, b"fixture")


class Relay(QuietHandler):
    def do_GET(self):
        target = urlsplit(self.path)
        if (target.scheme != "http" or target.netloc != self.server.destination
                or not target.path.startswith(self.server.prefix) or target.query):
            self.reply(403, b"")
            return
        if self.server.unavailable.is_set():
            self.reply(502, b"fixed test upstream unavailable")
            return
        connection = HTTPConnection(LOOPBACK, self.server.origin_port, timeout=22)
        try:
            connection.request("GET", target.path, headers={"X-Lab-Hop": self.server.marker})
            response = connection.getresponse()
            self.send_response(response.status)
            for name in ("Content-Length", "Content-Type", "Cache-Control"):
                if response.getheader(name):
                    self.send_header(name, response.getheader(name))
            self.end_headers()
            while chunk := response.read(1 if target.path.endswith("/active") else 4096):
                self.wfile.write(chunk)
                self.wfile.flush()
        finally:
            connection.close()


def serve_relay(port, origin_port, prefix, marker, unavailable, ready):
    with ThreadingHTTPServer((LOOPBACK, port), Relay) as server:
        server.origin_port = origin_port
        server.destination = f"{LOOPBACK}:{origin_port}"
        server.prefix, server.marker, server.unavailable = prefix, marker, unavailable
        ready.send(server.server_port)
        ready.close()
        server.serve_forever()


def monitor(port, health_url, ready):
    """A real observation process; it neither selects routes nor enforces Chrome policy."""
    first = True
    while True:
        connection = HTTPConnection(LOOPBACK, port, timeout=2)
        try:
            connection.request("GET", health_url)
            response = connection.getresponse()
            ok = response.status == 200 and response.read() == b"fixture"
        finally:
            connection.close()
        if first:
            ready.send(ok)
            ready.close()
            first = False
        time.sleep(1)


@contextmanager
def process(target, *args):
    receive, send = mp.Pipe(duplex=False)
    child = mp.Process(target=target, args=(*args, send), daemon=True)
    child.start()
    send.close()
    try:
        if not receive.poll(10):
            raise TimeoutError("fixture did not become ready")
        yield child, receive.recv()
    finally:
        receive.close()
        if child.is_alive():
            child.terminate()
        child.join(5)
        if child.is_alive():
            raise RuntimeError("fixture did not stop")


class DevTools:
    def __init__(self, channel):
        self.channel = channel
        self.sequence = 0
        self.fixture_url = None
        self.requests = {}
        self.transport_errors = {}

    def collect_event(self, message):
        event = message.get("method")
        data = message.get("params", {})
        if event == "Network.requestWillBeSent" and self.fixture_url:
            url = data["request"]["url"]
            if url.startswith(self.fixture_url):
                self.requests[data["requestId"]] = url[len(self.fixture_url):]
        elif event == "Network.loadingFailed":
            key = self.requests.get(data["requestId"])
            if key is not None:
                self.transport_errors[key] = data.get("errorText")

    def call(self, method, **params):
        self.sequence += 1
        self.channel.send(json.dumps(dict(id=self.sequence, method=method, params=params)))
        while True:
            message = json.loads(self.channel.recv(timeout=15))
            if message.get("id") == self.sequence:
                if "error" in message:
                    raise RuntimeError(f"{method} returned a protocol error")
                return message["result"]
            self.collect_event(message)

    def evaluate(self, expression):
        result = self.call("Runtime.evaluate", expression=expression, awaitPromise=True,
                           returnByValue=True)
        if "exceptionDetails" in result:
            raise RuntimeError("fixture page evaluation failed")
        return result["result"].get("value")


def wait_for(probe, label):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.05)
    raise TimeoutError(label)


@contextmanager
def browser(executable, port, required, metadata):
    with tempfile.TemporaryDirectory(prefix="V69-blank-profile-") as profile:
        flags = ["--headless=new", "--no-first-run", "--disable-background-networking",
                 "--disable-component-update", "--disable-sync", "--disable-extensions",
                 "--disable-default-apps", "--no-default-browser-check",
                 "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                 f"--user-data-dir={profile}", f"--proxy-server=http://{LOOPBACK}:{port}"]
        if required:
            # Override Chromium's implicit localhost bypass only inside this test profile.
            flags.append("--proxy-bypass-list=<-loopback>")
        child = subprocess.Popen([executable, *flags, "about:blank"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        browser_channel = None
        try:
            port_file = Path(profile, "DevToolsActivePort")

            def read_endpoint():
                if child.poll() is not None:
                    raise RuntimeError(f"test Chrome exited early with code {child.returncode}")
                if port_file.exists():
                    fields = port_file.read_text().splitlines()
                    if len(fields) == 2:
                        return int(fields[0]), fields[1]

            debugger_port, browser_path = wait_for(read_endpoint, "DevTools startup")
            browser_channel = connect(f"ws://{LOOPBACK}:{debugger_port}{browser_path}")
            browser_api = DevTools(browser_channel)
            processes = browser_api.call("SystemInfo.getProcessInfo")["processInfo"]
            metadata["processTypes"] = sorted({item["type"] for item in processes})
            metadata["browser"] = browser_api.call("Browser.getVersion")["product"]
            # Direct, fixture-owned debugging control channel. No application requests use it.
            control = HTTPConnection(LOOPBACK, debugger_port, timeout=3)
            try:
                control.request("GET", "/json/list")
                pages = json.loads(control.getresponse().read())
            finally:
                control.close()
            page_url = next(item["webSocketDebuggerUrl"] for item in pages if item["type"] == "page")
            with connect(page_url) as page_channel:
                yield DevTools(page_channel)
        finally:
            try:
                if browser_channel is not None:
                    try:
                        browser_channel.send('{"id":9999,"method":"Browser.close"}')
                    except (OSError, ConnectionClosed):
                        pass
                    finally:
                        browser_channel.close()
            finally:
                try:
                    metadata["exitCode"] = child.wait(timeout=7)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    metadata["exitCode"] = child.wait(timeout=5)
    metadata["temporaryProfileRemoved"] = not Path(profile).exists()


def fetch(page, key):
    return page.evaluate(
        "(async()=>{try{const r=await fetch(" + json.dumps(key) +
        ",{cache:'no-store',signal:AbortSignal.timeout(5000)});"
        "return [r.status,await r.text()]}catch(e){return [0,e.name]}})()")


def navigate(page, url):
    page.call("Page.navigate", url=url)
    wait_for(lambda: page.evaluate("document.documentElement?.dataset.lab==='ready'"), "fixture HTML")


def run(executable, report):
    prefix, marker = "/" + secrets.token_hex(12) + "/", secrets.token_hex(24)
    with ThreadingHTTPServer((LOOPBACK, 0), Receiver) as origin:
        origin.hits, origin.lock, origin.release = Counter(), Lock(), Event()
        origin.prefix, origin.marker = prefix, marker
        thread = Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        url = f"http://{LOOPBACK}:{origin.server_port}{prefix}"
        unavailable = mp.Event()
        args = origin.server_port, prefix, marker, unavailable
        try:
            with process(serve_relay, 0, *args) as (relay, port), \
                    browser(executable, port, True, report["protectedProcess"]) as page:
                page.fixture_url = url
                page.call("Network.enable")
                navigate(page, url + "document")

                def check(name, key, before, action, expected, sender, expected_hits):
                    with origin.lock:
                        hits = [origin.hits[key, kind] for kind in ("relay", "direct")]
                    ok = sender == expected and hits == expected_hits
                    report["cases"].append(dict(name=name, before=before, action=action,
                        expected=dict(sender=expected, receiverRelayAndDirect=expected_hits),
                        sender=sender, receiverRelayAndDirect=hits, status="PASS" if ok else "FAILED"))
                    if not ok:
                        raise ValueError(f"observation mismatch in {name}")

                check("normal", "normal", "relay available", "fresh page fetch",
                      [200, "fixture"], fetch(page, "normal"), [1, 0])
                with process(monitor, port, url + "health") as (observer, observed):
                    if observed is not True:
                        raise ValueError("monitor did not verify the fixture")
                    observer.terminate()
                    observer.join(4)
                    report["observerExitCode"] = observer.exitcode
                    if observer.is_alive():
                        raise RuntimeError("monitor still alive")
                check("monitorExited", "no-monitor", "browser and relay live", "terminate monitor",
                      [200, "fixture"], fetch(page, "no-monitor"), [1, 0])
                unavailable.set()
                check("upstreamUnavailable", "upstream-down", "monitor absent, relay listening",
                      "relay returns HTTP 502", [502, "fixed test upstream unavailable"],
                      fetch(page, "upstream-down"), [0, 0])
                unavailable.clear()
                check("upstreamRestored", "upstream-up", "relay listening, upstream 502",
                      "restore fixture upstream", [200, "fixture"], fetch(page, "upstream-up"), [1, 0])
                page.evaluate("""void(window.streamResult=(async()=>{
                  try {const r=await fetch('active',{signal:AbortSignal.timeout(10000)});
                    const reader=r.body.getReader(); const first=await reader.read();
                    window.firstByte=new TextDecoder().decode(first.value);
                    const second=await reader.read(); return second.done?'early-end':'continued';
                  }catch(e){return e.name}
                })())""")
                wait_for(lambda: page.evaluate("window.firstByte==='A'"), "active response first byte")
                relay.terminate()
                relay.join(4)
                report["relayExitCode"] = relay.exitcode
                if relay.is_alive():
                    raise RuntimeError("relay still alive")
                check("activeInterrupted", "active", "receiver delivered first byte through relay",
                      "terminate relay process mid-response", "TypeError",
                      page.evaluate("window.streamResult"), [1, 0])
                origin.release.set()
                check("freshAfterExit", "lost", "relay and observer exited",
                      "fresh fetch in same browser", [0, "TypeError"], fetch(page, "lost"), [0, 0])
                with browser(executable, port, False, report["controlProcess"]) as direct_control:
                    navigate(direct_control, url + "document")
                    check("directPositiveControl", "control", "relay still exited",
                          "separate Chrome default localhost bypass", [200, "fixture"],
                          fetch(direct_control, "control"), [0, 1])
                with process(serve_relay, port, *args):
                    check("restoredOnSamePort", "restored", "no manager, original Chrome still open",
                          "restart fixture relay at original port", [200, "fixture"],
                          fetch(page, "restored"), [1, 0])
                page.call("Network.disable")
                report["browserTransportErrors"] = page.transport_errors
            # Cover late retries through shutdown. The positive control also proves the same
            # receiver was available during the negative observations.
            with origin.lock:
                totals = {key: origin.hits[key, "direct"] for key in
                          ("normal", "no-monitor", "upstream-down", "upstream-up", "active",
                           "lost", "restored", "control")}
            report["directRequestsThroughBrowserExit"] = totals
            if any(count != int(key == "control") for key, count in totals.items()):
                raise ValueError("late unexpected direct request")
        finally:
            origin.release.set()
            origin.shutdown()
            thread.join(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chrome", type=Path, default=Path(os.environ.get("ProgramFiles", ""),
                        "Google", "Chrome", "Application", "chrome.exe"))
    options = parser.parse_args()
    report = dict(scope="Explicit per-process Chrome HTTP requests to a neutral IPv4 loopback receiver",
                  protocol="HTTP over IPv4 TCP", destination="numeric loopback",
                  protectedProcess={}, controlProcess={}, cases=[], status="FAILED",
                  realProductionClients="NOT_TESTED", backgroundTraffic="NOT_TESTED",
                  systemProxyInheritance="NOT_TESTED", firewall="NOT_TESTED")
    try:
        run(options.chrome, report)
        if any(proc.get("exitCode") != 0 or not proc.get("temporaryProfileRemoved")
               for proc in (report["protectedProcess"], report["controlProcess"])):
            raise RuntimeError("disposable browser cleanup failed")
        report["status"] = "PASS"
    except Exception as error:
        # Exception text may include private host paths. Preserve the stage/case without them.
        report["exceptionType"] = type(error).__name__
        report["error"] = str(error) if type(error) in (ValueError, TimeoutError) else "fixture failed"
    report["exitCode"] = int(report["status"] != "PASS")
    print(json.dumps(report, indent=2))
    return report["exitCode"]


if __name__ == "__main__":
    raise SystemExit(main())
