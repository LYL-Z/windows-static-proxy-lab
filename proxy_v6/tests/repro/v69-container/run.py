"""Isolated Windows network-isolation experiment. Requires MinGW-w64 gcc on PATH."""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import uuid


def wait_for_owned_child(pid, executable, gate):
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD,
                                                 wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
    kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    kernel.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
    handle = kernel.OpenProcess(0x100000 | 0x1000 | 1, False, pid)  # synchronize, query, terminate
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        buf = ctypes.create_unicode_buffer(32768)
        size = wintypes.DWORD(len(buf))
        if not kernel.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        if not Path(buf.value).samefile(executable):
            raise RuntimeError("unexpected child image")
        try:
            # The launcher already exited, and the child has checked its token.
            # It cannot open a network socket until this per-run signal exists.
            gate.touch(exist_ok=False)
            if kernel.WaitForSingleObject(handle, 9500) != 0:
                raise TimeoutError("probe did not terminate")
        finally:
            if kernel.WaitForSingleObject(handle, 0) == 258:
                if not kernel.TerminateProcess(handle, 74) or kernel.WaitForSingleObject(handle, 3000) != 0:
                    raise RuntimeError("could not reap owned probe")
        code = wintypes.DWORD()
        if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
            raise ctypes.WinError(ctypes.get_last_error())
        return code.value
    finally:
        kernel.CloseHandle(handle)


def run_case(exe, name, version, udp):
    family = socket.AF_INET6 if version == 6 else socket.AF_INET
    kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
    rows = []
    with socket.socket(family, kind) as receiver:
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        receiver.bind(("::1" if version == 6 else "127.0.0.1", 0))
        if not udp:
            receiver.listen(1)
        receiver.settimeout(0.1)
        args = [str(receiver.getsockname()[1]), str(version), "2" if udp else "1"]
        for phase in ("before", "after_launcher_exit", "rollback_control"):
            challenge = uuid.uuid4().hex[:16]
            stop = threading.Event()
            seen = []
            arrivals = []
            errors = []
            code = None
            probe_error = None

            def serve():
                while not stop.is_set():
                    try:
                        if udp:
                            data, peer = receiver.recvfrom(128)
                            arrivals.append(True)
                            seen.append(data)
                            receiver.sendto(data, peer)
                        else:
                            conn, _ = receiver.accept()
                            with conn:
                                arrivals.append(True)
                                conn.settimeout(1)
                                data = b""
                                while len(data) < 16:
                                    part = conn.recv(16 - len(data))
                                    if not part:
                                        break
                                    data += part
                                seen.append(data)
                                conn.sendall(data)
                    except socket.timeout:
                        continue
                    except OSError as error:
                        errors.append(error.winerror)
                        return

            thread = threading.Thread(target=serve)
            thread.start()
            try:
                if phase == "after_launcher_exit":
                    inherited = ("SystemRoot", "SystemDrive", "windir", "USERPROFILE", "LOCALAPPDATA",
                                 "APPDATA", "TEMP", "TMP", "ProgramData", "ProgramFiles", "PUBLIC")
                    env = {key: os.environ[key] for key in inherited if key in os.environ}
                    launcher = subprocess.run([exe, "launch", name, *args, challenge], capture_output=True,
                                              text=True, check=True, timeout=8, env=env)
                    code = wait_for_owned_child(int(launcher.stdout), exe, Path(str(exe) + ".gate-" + challenge))
                else:
                    code = subprocess.run([exe, "control", *args, challenge], timeout=8).returncode
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                probe_error = type(error).__name__
            finally:
                stop.set()
                thread.join()
            rows.append(dict(phase=phase, exit=code, peerArrivals=len(arrivals), receipts=len(seen),
                             probeError=probe_error, receiverErrors=errors,
                             echo=seen == [challenge.encode("ascii")]))
    controls = all(rows[i]["exit"] == 0 and rows[i]["echo"] and rows[i]["peerArrivals"] == 1 for i in (0, 2))
    status = "BLOCKED"
    if controls and rows[1]["exit"] == 10013:
        status = "PASS"
    elif controls and rows[1]["exit"] in (72, 10060):
        status = "PARTIAL"  # Clean controls but no explicit permission-denied response.
    if rows[1]["peerArrivals"] or rows[1]["exit"] == 0:
        status = "FAILED"
    if any(row["receiverErrors"] for row in rows):
        status = "FAILED"
    return dict(ip=version, protocol="UDP" if udp else "TCP", target="loopback",
                process="socket_probe", fault="zero network capabilities, launcher exited",
                expected="positive controls echo, isolated socket denied with WSAEACCES",
                status=status, controlsPassed=controls, phases=rows)


def main():
    results = []
    with tempfile.TemporaryDirectory(prefix="v69-socket-") as folder:
        exe = Path(folder) / "socket_probe.exe"
        subprocess.run(["gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-municode",
                        "-static", str(Path(__file__).with_name("socket_probe.c")), "-o", str(exe),
                        "-lws2_32", "-luserenv", "-ladvapi32"], check=True)
        name = "V69.SocketTest." + uuid.uuid4().hex
        sid = subprocess.check_output([exe, "create", name], text=True).strip()
        try:
            if not sid.startswith("S-1-15-2-"):
                raise ValueError("unexpected AppContainer SID")
            # Give only this fresh identity access to this test directory and binary.
            for path, access in ((folder, "(OI)(CI)(RX)"), (exe, "(RX)")):
                subprocess.run(["icacls", str(path), "/grant", "*" + sid + ":" + access],
                               check=True, stdout=subprocess.DEVNULL)
            for version in (4, 6):
                for udp in (False, True):
                    try:
                        results.append(run_case(exe, name, version, udp))
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                        results.append(dict(ip=version, protocol="UDP" if udp else "TCP", status="BLOCKED",
                                            failure=type(error).__name__, code=getattr(error, "winerror", None),
                                            launcherExit=getattr(error, "returncode", None),
                                            detail=getattr(error, "stderr", None)))
        finally:
            subprocess.run([exe, "remove", name], check=True)
    print(json.dumps(dict(cases=results, profileDeleteSucceeded=True, tempRemoved=not Path(folder).exists()), indent=2))
    if any(r["status"] == "FAILED" for r in results):
        return 1
    return 2 if any(r["status"] != "PASS" for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
