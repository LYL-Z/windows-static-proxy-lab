"""Exercise the repair CLI in fresh PowerShell processes against a file-backed receiver."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[2] / "proxy_v4"
FIRST = "127.0.0.1:19321"
CORE = "127.0.0.1:19322"
OTHER = "127.0.0.1:19444"
PS = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"]


def cli(root, script, args, env):
    return subprocess.run(
        [*PS, "-File", str(root / script), *args], env=env,
        capture_output=True, text=True, errors="replace", timeout=35,
    )


def write_selection(root, enabled, server):
    (root / "selection.json").write_text(json.dumps(dict(enabled=enabled, server=server)))
    (root / "events").write_text("")


def execute_case(root, env, name, enabled, before, code, after, enabled_after, writes, probes):
    write_selection(root, enabled, before)
    proc = cli(root, "apply-v4.ps1", ["-Repair"], {**env, "V69_RECOVERY_CASE": name})
    events = (root / "events").read_text().splitlines()
    observed = json.loads((root / "selection.json").read_text())
    observed_writes = [e.removeprefix("write-") for e in events if e.startswith("write-")]
    passed = (proc.returncode == code and observed["enabled"] == enabled_after
              and observed["server"] == after and observed_writes == writes
              and sum(e.startswith("probe-") for e in events) == probes
              and "unexpected-restart" not in events and "settings-status-only=False" not in events)
    return dict(case=name, injection=name, before=dict(enabled=enabled, server=before),
                expected=dict(code=code, server=after, enabled=enabled_after, writes=writes, probes=probes),
                exitCode=proc.returncode, receiver=observed, writes=observed_writes, events=events, passed=passed)


def interrupted_case(root, env, action, final_enabled, expected, code):
    write_selection(root, True, FIRST)
    crash = cli(root, "apply-v4.ps1", ["-Repair"], {**env, "V69_RECOVERY_CASE": "interrupted"})
    receipt = root / "repair-state" / "pending.json"
    saved = json.loads(receipt.read_text()) if receipt.is_file() else {}
    interrupted = json.loads((root / "selection.json").read_text())
    if not final_enabled:
        write_selection(root, False, CORE)
    guard = cli(root, "apply-v4.ps1", ["-Repair"], env)
    rollback_guard = cli(root, "rollback-v4.ps1", [], env)
    released = not (root / "config" / ".lock").exists()
    state = cli(root, "state-v4.ps1", ["-Json"], env)
    resolved = cli(root, "apply-v4.ps1", ["-ResolveRepair", action], env)
    after = json.loads((root / "selection.json").read_text())
    retained = receipt.exists()
    confirmed = (crash.returncode == 91 and interrupted == dict(enabled=True, server=CORE)
                 and saved.get("previous") == FIRST and saved.get("target") == CORE
                 and guard.returncode == rollback_guard.returncode == 34 and released
                 and "REVIEW_INTERRUPTED_REPAIR" in state.stdout and resolved.returncode == code
                 and after == dict(enabled=final_enabled, server=expected) and retained == (code != 0))
    if retained:
        acknowledged = cli(root, "apply-v4.ps1", ["-ResolveRepair", "KeepCurrent"], env)
        confirmed = confirmed and acknowledged.returncode == 0 and not receipt.exists()
    return dict(case="interrupted-" + ("on-" if final_enabled else "user-off-") + action,
                before=dict(enabled=True, server=FIRST), injection="terminate process after target write",
                crashExit=crash.returncode, afterCrash=interrupted, guardedApply=guard.returncode,
                guardedRollback=rollback_guard.returncode, lockReleased=released,
                stateDetected="REVIEW_INTERRUPTED_REPAIR" in state.stdout,
                resolveExit=resolved.returncode, receiver=after, receiptRetained=retained, passed=confirmed)


def run(root):
    (root / "lib").mkdir()
    (root / "config").mkdir()
    (root / "config" / "settings.json").write_text("{}")
    for name in ("apply-v4.ps1", "state-v4.ps1", "rollback-v4.ps1"):
        shutil.copyfile(SOURCE / name, root / name)
    lib = (SOURCE / "lib" / "V4.ps1").read_bytes()
    fixture = (HERE / "V69RecoveryFixture.ps1").read_bytes()
    (root / "lib" / "V4.ps1").write_bytes(lib + b"\n" + fixture)
    env = dict(os.environ, V4_TEST_MODE="1", V4_TEST_ROOT=str(root))
    # Windows PowerShell must discover its own Security module for the real ACL tests.
    env = {key: value for key, value in env.items() if key.upper() != "PSMODULEPATH"}
    readers = subprocess.run([*PS, "-File", str(HERE / "V69RecoveryReaders.ps1"),
                              str(SOURCE / "lib" / "V4.ps1")], env=env, timeout=15)
    cases = [
        ("user-off", False, FIRST, 32, FIRST, False, [], 0),
        ("user-other-target", True, OTHER, 32, OTHER, True, [], 0),
        ("unknown-image", True, FIRST, 32, FIRST, True, [], 0),
        ("already-correct", True, CORE, 0, CORE, True, [], 1),
        ("ambiguous-probe", True, FIRST, 31, FIRST, True, [], 1),
        ("eligible-drift", True, FIRST, 0, CORE, True, [CORE], 2),
        ("post-exit-mismatch", True, FIRST, 31, FIRST, True, [CORE, FIRST], 2),
        ("partial-setter", True, FIRST, 1, FIRST, True, [CORE, FIRST], 1),
        ("external-disable", True, FIRST, 32, CORE, False, [CORE], 2),
        ("rollback-error", True, FIRST, 40, CORE, True, [CORE, FIRST], 2),
    ]
    rows = [execute_case(root, env, *case) for case in cases]
    pending = root / "repair-state" / "pending.json"
    rows[-1]["retainedAfterFailedRollback"] = pending.is_file()
    rows[-1]["passed"] = rows[-1]["passed"] and pending.is_file()
    acknowledged = cli(root, "apply-v4.ps1", ["-ResolveRepair", "KeepCurrent"], env)
    rows[-1]["passed"] = rows[-1]["passed"] and acknowledged.returncode == 0 and not pending.exists()
    for action, enabled, outcome, rc in (("RestorePrevious", True, FIRST, 0),
                                          ("KeepCurrent", True, CORE, 0),
                                          ("RestorePrevious", False, CORE, 32)):
        rows.append(interrupted_case(root, env, action, enabled, outcome, rc))

    gate = root / "lock-holder.ps1"
    gate.write_text(
        ". (Join-Path $PSScriptRoot 'lib/V4.ps1')\n"
        "$mutex = Enter-V4UserMutationLock\nif (-not $mutex) {exit 1}\n"
        "try { [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ready'), 'held');"
        " while (-not (Test-Path (Join-Path $PSScriptRoot 'done'))) {Start-Sleep -Milliseconds 50} }"
        " finally {$mutex.ReleaseMutex(); $mutex.Dispose()}\n"
    )
    with subprocess.Popen([*PS, "-File", str(gate)], env=env) as holder:
        try:
            deadline = time.monotonic() + 10
            while not (root / "ready").exists():
                if time.monotonic() >= deadline or holder.poll() is not None:
                    raise RuntimeError("test lock holder did not become ready")
                time.sleep(0.05)
            rows.append(execute_case(root, env, "competing-process", True, FIRST, 33, FIRST, True, [], 0))
        finally:
            (root / "done").touch()
            try:
                holder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                holder.kill()
    rows.append(dict(case="provider-evidence", process="Windows PowerShell 5.1",
                     injection="malformed enable values, missing core image, competing listener owners",
                     expectedExit=0, exitCode=readers.returncode, passed=readers.returncode == 0))
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="v69-repair-") as directory:
        results = run(Path(directory))
    report = dict(process="Windows PowerShell 5.1, apply-v4.ps1 -Repair",
                  scope="isolated control plane; file-backed WinINet selection and synthetic IPv4 HTTPS samples",
                  results=results, passed=all(x["passed"] for x in results))
    if args.output:
        args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print("passed", sum(x["passed"] for x in results), "/", len(results))
    for row in results:
        if not row["passed"]:
            print(json.dumps(row))
    raise SystemExit(0 if report["passed"] else 1)
