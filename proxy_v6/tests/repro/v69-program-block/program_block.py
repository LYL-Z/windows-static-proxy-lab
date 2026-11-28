"""Outbound block for one temporary test program.

The firewall rule names that program's full path and TCP to 127.0.0.1 only.
It is removed before the script exits. This is not a machine-wide kill switch.
"""
import json
import socket
import subprocess
import sys
import tempfile
import threading
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "probe.c"


def listen(port_holder, received, ready):
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(3)
    port_holder.append(server.getsockname()[1])
    ready.set()
    try:
        conn, _ = server.accept()
        with conn:
            data = conn.recv(4)
            if data == b"x":
                received.append(True)
    except OSError:
        pass
    finally:
        server.close()


def run_probe(exe, port):
    completed = subprocess.run([str(exe), str(port)], capture_output=True, text=True, timeout=8)
    return completed.returncode


def rule_exists(name):
    script = f"(Get-NetFirewallRule -Name '{name}' -ErrorAction SilentlyContinue | Measure-Object).Count"
    completed = subprocess.run(["powershell.exe", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=30)
    return completed.returncode == 0 and completed.stdout.strip() == "1"


def sandbox_rule_count():
    script = "(Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'codex_sandbox_offline_block_*' } | Measure-Object).Count"
    completed = subprocess.run(["powershell.exe", "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=40)
    text = completed.stdout.strip()
    return int(text) if text.isdigit() else None


def main():
    name = "v69-program-block-" + uuid.uuid4().hex
    report = {"coverage": "one temporary executable, TCP to 127.0.0.1", "rule": name, "removed": False}
    with tempfile.TemporaryDirectory(prefix="v69-block-") as folder:
        exe = Path(folder) / "probe.exe"
        compiled = subprocess.run(
            ["gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-municode", "-static", str(SOURCE), "-o", str(exe), "-lws2_32"],
            cwd=folder, capture_output=True, text=True, timeout=60)
        if compiled.returncode != 0 or not exe.is_file():
            report["status"] = "ENVIRONMENT_LIMIT"
            report["stage"] = "compile"
            print(json.dumps(report, indent=2))
            return 2
        before_rules = sandbox_rule_count()
        port_holder, received, ready = [], [], threading.Event()
        thread = threading.Thread(target=listen, args=(port_holder, received, ready))
        thread.start()
        ready.wait(3)
        port = port_holder[0]
        before = run_probe(exe, port)
        thread.join(3)
        report["before"] = {"exit": before, "receiver": len(received) == 1, "class": "PATH_VERIFIED" if before == 0 and received else "FAILED"}
        add = subprocess.run([
            "powershell.exe", "-NoProfile", "-Command",
            "$ErrorActionPreference='Stop'; New-NetFirewallRule -Name $env:V69_RULE -DisplayName $env:V69_RULE "
            "-Direction Outbound -Action Block -Program $env:V69_EXE -Protocol TCP -RemoteAddress 127.0.0.1 "
            "-Profile Any | Out-Null"
        ], capture_output=True, text=True, timeout=40, env={**dict(**{k: v for k, v in __import__('os').environ.items()}), "V69_RULE": name, "V69_EXE": str(exe)})
        try:
            if add.returncode != 0 or not rule_exists(name):
                detail = (add.stderr or add.stdout or "")
                report["status"] = "ENVIRONMENT_LIMIT"
                report["stage"] = "rule"
                report["class"] = "NOT_TESTED"
                report["ruleCreated"] = False
                report["removed"] = not rule_exists(name)
                report["error"] = "ACCESS_DENIED" if "Access is denied" in detail or "拒绝访问" in detail else "RULE_NOT_CREATED"
                report["sandboxRulesUnchanged"] = sandbox_rule_count() == before_rules
                print(json.dumps(report, indent=2))
                return 2
            port_holder, received, ready = [], [], threading.Event()
            thread = threading.Thread(target=listen, args=(port_holder, received, ready))
            thread.start()
            ready.wait(3)
            blocked = run_probe(exe, port_holder[0])
            thread.join(3)
            if blocked == 10013 and not received:
                blocked_class = "NETWORK_BLOCK"
            elif blocked in (10060, 4) or (blocked != 0 and not received):
                blocked_class = "UNKNOWN"
            elif received:
                blocked_class = "FAILED"
            else:
                blocked_class = "UNKNOWN"
            report["blocked"] = {"exit": blocked, "receiver": len(received) == 1, "class": blocked_class}
        finally:
            subprocess.run(["powershell.exe", "-NoProfile", "-Command",
                            "Remove-NetFirewallRule -Name $env:V69_RULE -ErrorAction SilentlyContinue"],
                           capture_output=True, text=True, timeout=40,
                           env={**dict(**{k: v for k, v in __import__('os').environ.items()}), "V69_RULE": name})
            report["removed"] = not rule_exists(name)
        if not report["removed"]:
            report["status"] = "FAILED"
            print(json.dumps(report, indent=2))
            return 1
        port_holder, received, ready = [], [], threading.Event()
        thread = threading.Thread(target=listen, args=(port_holder, received, ready))
        thread.start()
        ready.wait(3)
        after = run_probe(exe, port_holder[0])
        thread.join(3)
        report["after"] = {"exit": after, "receiver": len(received) == 1, "class": "PATH_VERIFIED" if after == 0 and received else "FAILED"}
        report["sandboxRulesUnchanged"] = sandbox_rule_count() == before_rules
        ok = (report["before"]["class"] == "PATH_VERIFIED" and report["blocked"]["class"] == "NETWORK_BLOCK"
              and report["after"]["class"] == "PATH_VERIFIED" and report["sandboxRulesUnchanged"])
        report["status"] = "PASS" if ok else "FAILED"
        print(json.dumps(report, indent=2))
        return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
