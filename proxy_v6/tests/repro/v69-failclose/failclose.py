"""Process-scoped fail-close for children started inside one Windows job.

Coverage is only processes started inside this job. The guard holds the job
handle. Closing the local health listener makes an armed guard terminate that
job. Killing the guard closes the handle, and JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
stops those same processes. Nothing here changes firewall, routing, DNS, or
any process the guard did not start.
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / "runtime"
LOOPBACK = "127.0.0.1"
INTERVAL = 0.1
EXPLICIT_JOB_EXIT = 3
GUARD_KILLED_EXIT = 9
JOB_CLOSE_EXIT = 0
LOCK_BUSY_EXIT = 2
STILL_ACTIVE = 259
CREATE_SUSPENDED = 0x00000004
CREATE_NO_WINDOW = 0x08000000
CREATE_UNICODE_ENVIRONMENT = 0x00000400
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES = 0x00020009
PROCESS_TERMINATE = 0x0001
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
SYNCHRONIZE = 0x00100000
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_ALL = 0x00000007
OPEN_ALWAYS = 4
FILE_ATTRIBUTE_NORMAL = 0x80
LOCKFILE_FAIL_IMMEDIATELY = 0x00000001
LOCKFILE_EXCLUSIVE_LOCK = 0x00000002
ERROR_LOCK_VIOLATION = 33
INVALID_HANDLE = ctypes_invalid = None  # set after ctypes import

import ctypes
from ctypes import wintypes

INVALID_HANDLE = ctypes.c_void_p(-1).value
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
userenv = ctypes.WinDLL("userenv", use_last_error=True)
advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)


class IO_COUNTERS(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_ulonglong),
        ("WriteOperationCount", ctypes.c_ulonglong),
        ("OtherOperationCount", ctypes.c_ulonglong),
        ("ReadTransferCount", ctypes.c_ulonglong),
        ("WriteTransferCount", ctypes.c_ulonglong),
        ("OtherTransferCount", ctypes.c_ulonglong),
    ]


class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", JOBOBJECT_BASIC_LIMIT_INFORMATION),
        ("IoInfo", IO_COUNTERS),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("lpReserved", wintypes.LPWSTR),
        ("lpDesktop", wintypes.LPWSTR),
        ("lpTitle", wintypes.LPWSTR),
        ("dwX", wintypes.DWORD),
        ("dwY", wintypes.DWORD),
        ("dwXSize", wintypes.DWORD),
        ("dwYSize", wintypes.DWORD),
        ("dwXCountChars", wintypes.DWORD),
        ("dwYCountChars", wintypes.DWORD),
        ("dwFillAttribute", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("wShowWindow", wintypes.WORD),
        ("cbReserved2", wintypes.WORD),
        ("lpReserved2", ctypes.POINTER(wintypes.BYTE)),
        ("hStdInput", wintypes.HANDLE),
        ("hStdOutput", wintypes.HANDLE),
        ("hStdError", wintypes.HANDLE),
    ]


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [
        ("StartupInfo", STARTUPINFOW),
        ("lpAttributeList", ctypes.c_void_p),
    ]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("hProcess", wintypes.HANDLE),
        ("hThread", wintypes.HANDLE),
        ("dwProcessId", wintypes.DWORD),
        ("dwThreadId", wintypes.DWORD),
    ]


class SECURITY_CAPABILITIES(ctypes.Structure):
    _fields_ = [
        ("AppContainerSid", ctypes.c_void_p),
        ("Capabilities", ctypes.c_void_p),
        ("CapabilityCount", wintypes.DWORD),
        ("Reserved", wintypes.DWORD),
    ]


class OVERLAPPED(ctypes.Structure):
    _fields_ = [
        ("Internal", ctypes.c_void_p),
        ("InternalHigh", ctypes.c_void_p),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", wintypes.HANDLE),
    ]


def _bind():
    kernel32.CreateJobObjectW.argtypes = (ctypes.c_void_p, wintypes.LPCWSTR)
    kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    kernel32.SetInformationJobObject.argtypes = (
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD
    )
    kernel32.SetInformationJobObject.restype = wintypes.BOOL
    kernel32.QueryInformationJobObject.argtypes = (
        wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p
    )
    kernel32.QueryInformationJobObject.restype = wintypes.BOOL
    kernel32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
    kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel32.TerminateJobObject.argtypes = (wintypes.HANDLE, wintypes.UINT)
    kernel32.TerminateJobObject.restype = wintypes.BOOL
    kernel32.IsProcessInJob.argtypes = (
        wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)
    )
    kernel32.IsProcessInJob.restype = wintypes.BOOL
    kernel32.CreateProcessW.argtypes = (
        wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
        wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
        ctypes.c_void_p, ctypes.c_void_p,
    )
    kernel32.CreateProcessW.restype = wintypes.BOOL
    kernel32.ResumeThread.argtypes = (wintypes.HANDLE,)
    kernel32.ResumeThread.restype = wintypes.DWORD
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.TerminateProcess.argtypes = (wintypes.HANDLE, wintypes.UINT)
    kernel32.TerminateProcess.restype = wintypes.BOOL
    kernel32.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
    kernel32.WaitForSingleObject.restype = wintypes.DWORD
    kernel32.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    kernel32.QueryFullProcessImageNameW.argtypes = (
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)
    )
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.CreateFileW.argtypes = (
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
        wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
    )
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.LockFileEx.argtypes = (
        wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
        wintypes.DWORD, ctypes.POINTER(OVERLAPPED),
    )
    kernel32.LockFileEx.restype = wintypes.BOOL
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.LocalFree.argtypes = (ctypes.c_void_p,)
    kernel32.LocalFree.restype = ctypes.c_void_p
    kernel32.GetSystemDirectoryW.argtypes = (wintypes.LPWSTR, wintypes.UINT)
    kernel32.GetSystemDirectoryW.restype = wintypes.UINT
    kernel32.InitializeProcThreadAttributeList.argtypes = (
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_size_t)
    )
    kernel32.InitializeProcThreadAttributeList.restype = wintypes.BOOL
    kernel32.UpdateProcThreadAttribute.argtypes = (
        ctypes.c_void_p, wintypes.DWORD, ctypes.c_size_t, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p,
    )
    kernel32.UpdateProcThreadAttribute.restype = wintypes.BOOL
    kernel32.DeleteProcThreadAttributeList.argtypes = (ctypes.c_void_p,)
    kernel32.DeleteProcThreadAttributeList.restype = None
    userenv.CreateAppContainerProfile.argtypes = (
        wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.c_void_p,
        wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p),
    )
    userenv.CreateAppContainerProfile.restype = ctypes.c_long
    userenv.DeleteAppContainerProfile.argtypes = (wintypes.LPCWSTR,)
    userenv.DeleteAppContainerProfile.restype = ctypes.c_long
    advapi32.ConvertSidToStringSidW.argtypes = (
        ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)
    )
    advapi32.ConvertSidToStringSidW.restype = wintypes.BOOL
    advapi32.FreeSid.argtypes = (ctypes.c_void_p,)
    advapi32.FreeSid.restype = ctypes.c_void_p


_bind()


def winerror(err=None):
    code = ctypes.get_last_error() if err is None else err
    try:
        text = ctypes.WinError(code).strerror or ""
    except OSError:
        text = ""
    text = " ".join(text.split())
    return f"WinError {code}: {text}".strip()


def check(ok, what):
    if not ok:
        raise OSError(winerror() + f" ({what})")
    return ok


def valid_handle(handle):
    return bool(handle) and handle != INVALID_HANDLE


def emit(payload):
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def under_root(path: Path) -> bool:
    resolved = path.resolve()
    return resolved == ROOT or ROOT in resolved.parents


class Origin:
    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind((LOOPBACK, 0))
        self.sock.listen(8)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        if self.sock.getsockname()[0] != LOOPBACK:
            raise RuntimeError("origin is not bound to 127.0.0.1")
        self._lock = threading.Lock()
        self._rows = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, name="origin", daemon=True)
        self._thread.start()

    def distinct(self, role, after=None):
        with self._lock:
            ids = {
                marker for seen_role, marker, stamp in self._rows
                if seen_role == role and (after is None or stamp > after)
            }
        return len(ids)

    def stop(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        self._thread.join(timeout=2)

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, peer = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if peer[0] != LOOPBACK:
                conn.close()
                continue
            threading.Thread(target=self._read, args=(conn,), daemon=True).start()

    def _read(self, conn):
        buf = b""
        conn.settimeout(0.5)
        try:
            while not self._stop.is_set():
                try:
                    data = conn.recv(4096)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if not data:
                    return
                buf += data
                if len(buf) > 65536:
                    buf = b""
                    continue
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    self._take(conn, line)
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _take(self, conn, line):
        try:
            text = line.decode("ascii")
        except UnicodeDecodeError:
            return
        role, sep, marker = text.partition(" ")
        if sep != " " or role not in {"guarded", "unguarded", "control", "appcontainer"}:
            return
        if len(marker) != 32 or any(ch not in "0123456789abcdef" for ch in marker):
            return
        with self._lock:
            self._rows.append((role, marker, time.monotonic()))
        if role in {"control", "appcontainer"}:
            try:
                conn.sendall(line + b"\n")
            except OSError:
                pass


class Lines:
    def __init__(self):
        self.items = []
        self.cv = threading.Condition()
        self.eof = False

    def add(self, obj):
        with self.cv:
            self.items.append(obj)
            self.cv.notify_all()

    def finish(self):
        with self.cv:
            self.eof = True
            self.cv.notify_all()

    def wait_for(self, pred, timeout):
        end = time.monotonic() + timeout
        with self.cv:
            while True:
                for obj in self.items:
                    if pred(obj):
                        return obj
                remaining = end - time.monotonic()
                if self.eof or remaining <= 0:
                    return None
                self.cv.wait(remaining)

    def snapshot(self):
        with self.cv:
            return list(self.items)


class Tracker:
    def __init__(self):
        self._handles = {}
        self.cleaned = []
        self.orphans = []

    def open(self, pid, role, image: Path):
        if pid in (0, os.getpid()) or pid in self._handles:
            raise RuntimeError(f"refusing to track pid {pid}")
        access = SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE
        handle = kernel32.OpenProcess(access, False, pid)
        if not valid_handle(handle):
            raise OSError(winerror() + f" (OpenProcess {pid})")
        self._handles[pid] = {"handle": handle, "role": role, "image": image}

    def exit_code(self, pid):
        code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(self._handles[pid]["handle"], ctypes.byref(code)):
            raise OSError(winerror() + " (GetExitCodeProcess)")
        return int(code.value)

    def alive(self, pid):
        return self.exit_code(pid) == STILL_ACTIVE

    def wait(self, pid, timeout):
        ms = int(timeout * 1000)
        result = kernel32.WaitForSingleObject(self._handles[pid]["handle"], ms)
        if result == 0xFFFFFFFF:
            raise OSError(winerror() + " (WaitForSingleObject)")
        return result == 0

    def image_matches(self, pid):
        slot = self._handles[pid]
        buf = ctypes.create_unicode_buffer(32768)
        size = wintypes.DWORD(len(buf))
        if not kernel32.QueryFullProcessImageNameW(slot["handle"], 0, buf, ctypes.byref(size)):
            return False
        try:
            return Path(buf.value).resolve().samefile(slot["image"])
        except OSError:
            return False

    def stop(self, pid, code, reason, orphan):
        if pid not in self._handles:
            return False
        if not self.alive(pid):
            return False
        if not self.image_matches(pid):
            self.cleaned.append({
                "pid": pid, "role": self._handles[pid]["role"],
                "action": "left_running", "reason": "image did not match the process this test started",
            })
            return False
        if not kernel32.TerminateProcess(self._handles[pid]["handle"], code):
            if self.alive(pid):
                raise OSError(winerror() + f" (TerminateProcess {pid})")
        self.wait(pid, 3)
        row = {
            "pid": pid,
            "role": self._handles[pid]["role"],
            "exit": self.exit_code(pid),
            "reason": reason,
        }
        self.cleaned.append(row)
        if orphan:
            self.orphans.append(row)
        return True

    def close(self):
        for slot in self._handles.values():
            kernel32.CloseHandle(slot["handle"])
        self._handles.clear()


def pump(stream, lines: Lines):
    try:
        for raw in iter(stream.readline, ""):
            try:
                lines.add(json.loads(raw))
            except json.JSONDecodeError:
                lines.add({"event": "unparsed", "text": raw.strip()[:300]})
    finally:
        lines.finish()


def stderr_pump(stream, sink):
    try:
        sink.append(stream.read() or "")
    except OSError as exc:
        sink.append(f"{type(exc).__name__}")


def wait_until(pred, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.02)
    return False


def open_lock(path: Path):
    handle = kernel32.CreateFileW(
        str(path), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_ALL, None,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, None,
    )
    if not valid_handle(handle):
        raise OSError(winerror() + " (CreateFile lock)")
    return handle


def try_lock(handle):
    overlapped = OVERLAPPED()
    ok = kernel32.LockFileEx(
        handle, LOCKFILE_FAIL_IMMEDIATELY | LOCKFILE_EXCLUSIVE_LOCK,
        0, 1, 0, ctypes.byref(overlapped),
    )
    if ok:
        return True
    err = ctypes.get_last_error()
    if err == ERROR_LOCK_VIOLATION:
        return False
    raise OSError(winerror(err) + " (LockFileEx)")


def acquire_lock(handle):
    """Take an exclusive lock. On contention, retry once and then stop."""
    if try_lock(handle):
        return 1
    time.sleep(0.05)
    if try_lock(handle):
        return 2
    return 0


def make_job():
    job = kernel32.CreateJobObjectW(None, None)
    if not valid_handle(job):
        raise OSError(winerror() + " (CreateJobObjectW)")
    info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not kernel32.SetInformationJobObject(
        job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, ctypes.byref(info), ctypes.sizeof(info)
    ):
        err = winerror()
        kernel32.CloseHandle(job)
        raise OSError(err + " (SetInformationJobObject)")
    query = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    if not kernel32.QueryInformationJobObject(
        job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, ctypes.byref(query), ctypes.sizeof(query), None
    ):
        err = winerror()
        kernel32.CloseHandle(job)
        raise OSError(err + " (QueryInformationJobObject)")
    flags = int(query.BasicLimitInformation.LimitFlags)
    if flags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0:
        kernel32.CloseHandle(job)
        raise OSError(f"job limit flags are 0x{flags:x}, kill-on-close was not set")
    return job


def process_in_job(process, job):
    value = wintypes.BOOL()
    if not kernel32.IsProcessInJob(process, job, ctypes.byref(value)):
        raise OSError(winerror() + " (IsProcessInJob)")
    return bool(value.value)


def spawn_sender(origin_port, interval):
    command = subprocess.list2cmdline([
        sys.executable, str(ROOT / "failclose.py"), "sender",
        "--port", str(origin_port), "--role", "guarded", "--interval", str(interval),
    ])
    startup = STARTUPINFOW()
    startup.cb = ctypes.sizeof(startup)
    info = PROCESS_INFORMATION()
    buffer = ctypes.create_unicode_buffer(command)
    ok = kernel32.CreateProcessW(
        sys.executable, buffer, None, None, False, CREATE_SUSPENDED | CREATE_NO_WINDOW,
        None, str(ROOT), ctypes.byref(startup), ctypes.byref(info),
    )
    if not ok:
        raise OSError(winerror() + " (CreateProcessW sender)")
    return info


def sender_main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--interval", type=float, required=True)
    args = parser.parse_args(argv)
    if args.role not in {"guarded", "unguarded"} or not 0.05 <= args.interval <= 2:
        return 65
    if not 1 <= args.port <= 65535:
        return 65
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect((LOOPBACK, args.port))
        if sock.getpeername()[0] != LOOPBACK:
            return 65
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(None)
        while True:
            marker = uuid.uuid4().hex
            sock.sendall(f"{args.role} {marker}\n".encode("ascii"))
            time.sleep(args.interval)
    except OSError as exc:
        sys.stderr.write(f"sender_error winerror={getattr(exc, 'winerror', None)}\n")
        return 1


def guard_main(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--origin-port", type=int, required=True)
    parser.add_argument("--health-port", type=int, required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--mode", choices=("armed", "user-disabled"), required=True)
    parser.add_argument("--interval", type=float, default=INTERVAL)
    args = parser.parse_args(argv)
    lock_handle = None
    job = None
    child = None
    try:
        if not 1 <= args.origin_port <= 65535 or not 1 <= args.health_port <= 65535:
            emit({"event": "error", "error": "port out of range"})
            return 65
        if not 0.05 <= args.interval <= 2:
            emit({"event": "error", "error": "interval out of range"})
            return 65
        lock_path = Path(args.lock)
        if not under_root(lock_path):
            emit({"event": "error", "error": "lock path is outside the test directory"})
            return 65
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_handle = open_lock(lock_path)
        attempts = acquire_lock(lock_handle)
        if attempts == 0:
            emit({"event": "lock_busy", "attempts": 2})
            return LOCK_BUSY_EXIT
        job = make_job()
        child = spawn_sender(args.origin_port, args.interval)
        try:
            if not kernel32.AssignProcessToJobObject(job, child.hProcess):
                raise OSError(winerror() + " (AssignProcessToJobObject)")
            if not process_in_job(child.hProcess, job):
                raise OSError("suspended child was not assigned to the job")
            if process_in_job(kernel32.GetCurrentProcess(), job):
                raise OSError("guard process was assigned to its own job")
            resumed = kernel32.ResumeThread(child.hThread)
            if resumed == 0xFFFFFFFF:
                raise OSError(winerror() + " (ResumeThread)")
        except Exception:
            kernel32.TerminateProcess(child.hProcess, 74)
            kernel32.WaitForSingleObject(child.hProcess, 3000)
            raise
        finally:
            kernel32.CloseHandle(child.hThread)
            child.hThread = None
        emit({
            "event": "ready",
            "child_pid": int(child.dwProcessId),
            "guard_pid": os.getpid(),
            "mode": args.mode,
            "lock_attempts": attempts,
            "child_in_job": True,
            "guard_in_job": False,
            "kill_on_close": True,
        })
        health = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        health.settimeout(5)
        health.connect((LOOPBACK, args.health_port))
        if health.getpeername()[0] != LOOPBACK:
            raise OSError("health peer is not 127.0.0.1")
        health.settimeout(None)
        try:
            closed = health.recv(16) == b""
        except OSError:
            closed = True
        finally:
            health.close()
        if not closed:
            emit({"event": "error", "error": "health listener sent data instead of closing"})
            return 4
        if args.mode == "armed":
            if not kernel32.TerminateJobObject(job, EXPLICIT_JOB_EXIT):
                raise OSError(winerror() + " (TerminateJobObject)")
            kernel32.WaitForSingleObject(child.hProcess, 3000)
            code = wintypes.DWORD()
            if not kernel32.GetExitCodeProcess(child.hProcess, ctypes.byref(code)):
                raise OSError(winerror() + " (GetExitCodeProcess child)")
            emit({"event": "health", "action": "terminate", "child_exit": int(code.value)})
            return 0
        emit({"event": "health", "action": "ignore"})
        try:
            sys.stdin.buffer.read(1)
        except OSError:
            pass
        return 0
    except Exception as exc:
        emit({"event": "error", "error": f"{type(exc).__name__}: {exc}"})
        return 6
    finally:
        if child and valid_handle(child.hProcess):
            kernel32.CloseHandle(child.hProcess)
        if valid_handle(job):
            kernel32.CloseHandle(job)
        if valid_handle(lock_handle):
            kernel32.CloseHandle(lock_handle)


def system_directory():
    buf = ctypes.create_unicode_buffer(32768)
    count = kernel32.GetSystemDirectoryW(buf, len(buf))
    if not count or count >= len(buf):
        raise OSError("GetSystemDirectoryW failed")
    return buf.value


def hr_text(hr):
    return "0x{:08X}".format(int(hr) & 0xFFFFFFFF)


def compile_probe():
    completed = subprocess.run(
        [
            "gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-municode", "-static",
            "loopback_probe.c", "-o", "loopback_probe.exe", "-lws2_32",
        ],
        cwd=ROOT, capture_output=True, text=True, timeout=60, check=False,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise OSError(f"gcc exit {completed.returncode}: {detail[-800:]}")
    exe = ROOT / "loopback_probe.exe"
    if not exe.is_file():
        raise OSError("gcc reported success but loopback_probe.exe is missing")
    return exe


def run_probe(exe, port, role, result_path):
    marker = uuid.uuid4().hex
    completed = subprocess.run(
        [str(exe), str(port), role, marker, str(result_path)],
        cwd=system_directory(), capture_output=True, text=True, timeout=8, check=False,
    )
    body = None
    if result_path.is_file():
        body = json.loads(result_path.read_text(encoding="ascii"))
    return {
        "exit": completed.returncode,
        "result": body,
        "stderr": (completed.stderr or "")[:300],
        "marker": marker,
    }


def delete_profile(name, sid, sid_text):
    notes = []
    if sid_text:
        for path in (ROOT / "loopback_probe.exe", ROOT, RUNTIME / "appcontainer-result.json"):
            if path.exists():
                subprocess.run(
                    ["icacls", str(path), "/remove", f"*{sid_text}"],
                    capture_output=True, text=True, timeout=30, check=False,
                )
    if name:
        hr = userenv.DeleteAppContainerProfile(name)
        if hr < 0:
            notes.append(f"DeleteAppContainerProfile {hr_text(hr)}")
    if sid:
        advapi32.FreeSid(sid)
    return notes


def judge_container(container, control, origin, timed_out):
    received = origin.distinct("appcontainer") > 0
    control_ok = bool(
        control and control["exit"] == 0 and control["result"]
        and control["result"].get("stage") == "ok"
        and control["result"].get("winerror") == 0
        and origin.distinct("control") >= 1
    )
    result = container["result"] if container else None
    stage = result.get("stage") if result else None
    err = result.get("winerror") if result else None
    if received:
        status = "FAILED"
    elif result and stage == "connect" and err == 10013 and container["exit"] == 10013 and control_ok:
        status = "BLOCKED"
    elif timed_out or (err in (10060, 72)) or not result:
        status = "UNKNOWN"
    else:
        status = "UNKNOWN"
    return {
        "status": status,
        "scope": "this process only",
        "stage": stage,
        "winerror": err,
        "appcontainer": None if not result else result.get("appcontainer"),
        "probe_exit": None if not container else container["exit"],
        "origin_received": received,
        "timed_out": timed_out,
        "control_ok": control_ok,
        "control_exit": None if not control else control["exit"],
        "control_stage": None if not control or not control["result"] else control["result"].get("stage"),
        "control_winerror": None if not control or not control["result"] else control["result"].get("winerror"),
        "control_origin_received": origin.distinct("control") >= 1,
    }


class Harness:
    def __init__(self, name, mode):
        self.name = name
        self.mode = mode
        self.origin = None
        self.health = None
        self.health_conn = None
        self.peer = None
        self.guard = None
        self.lines = Lines()
        self.stderr = []
        self.tracker = Tracker()
        self.lock_path = RUNTIME / f"{name}.lock"
        self.ready = None
        self._closed = False

    def start(self):
        RUNTIME.mkdir(parents=True, exist_ok=True)
        self.origin = Origin()
        self.health = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.health.bind((LOOPBACK, 0))
        self.health.listen(4)
        self.health.settimeout(5)
        health_port = self.health.getsockname()[1]
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        self.peer = subprocess.Popen(
            [
                sys.executable, str(ROOT / "failclose.py"), "sender",
                "--port", str(self.origin.port), "--role", "unguarded",
                "--interval", str(INTERVAL),
            ],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW, env=env,
        )
        self.tracker.open(self.peer.pid, "unguarded", Path(sys.executable))
        self.guard = subprocess.Popen(
            [
                sys.executable, str(ROOT / "failclose.py"), "guard",
                "--origin-port", str(self.origin.port),
                "--health-port", str(health_port),
                "--lock", str(self.lock_path),
                "--mode", self.mode,
                "--interval", str(INTERVAL),
            ],
            cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
            creationflags=CREATE_NO_WINDOW, env=env,
        )
        threading.Thread(target=pump, args=(self.guard.stdout, self.lines), daemon=True).start()
        threading.Thread(target=stderr_pump, args=(self.guard.stderr, self.stderr), daemon=True).start()
        try:
            self.health_conn, peer = self.health.accept()
        except socket.timeout:
            self.health_conn = None
            peer = None
        if peer and peer[0] != LOOPBACK:
            raise RuntimeError("health connection was not from 127.0.0.1")
        self.ready = self.lines.wait_for(lambda item: item.get("event") in {"ready", "error", "lock_busy"}, 5)
        if self.ready and self.ready.get("event") == "ready":
            self.tracker.open(self.ready["child_pid"], "guarded", Path(sys.executable))
            self.tracker.open(self.guard.pid, "guard", Path(sys.executable))
        elif self.guard.pid and self.guard.poll() is None:
            self.tracker.open(self.guard.pid, "guard", Path(sys.executable))
        return self.ready

    def flowing(self, timeout=4):
        return wait_until(
            lambda: self.origin.distinct("guarded") >= 2 and self.origin.distinct("unguarded") >= 2,
            timeout,
        )

    def close_health(self):
        for conn in (self.health_conn, self.health):
            if conn is None:
                continue
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        self.health_conn = None
        self.health = None

    def release_guard_stdin(self):
        if self.guard and self.guard.stdin and not self.guard.stdin.closed:
            try:
                self.guard.stdin.close()
            except OSError:
                pass

    def finish(self):
        if self._closed:
            return
        self._closed = True
        self.close_health()
        self.release_guard_stdin()
        pids = []
        if self.ready and self.ready.get("child_pid"):
            pids.append((self.ready["child_pid"], "guarded child still running at cleanup", True))
        if self.guard:
            pids.append((self.guard.pid, "guard still running at cleanup", False))
        if self.peer:
            pids.append((self.peer.pid, "unguarded peer stopped at scenario end", False))
        for pid, reason, orphan in pids:
            if pid not in self.tracker._handles:
                continue
            try:
                if self.tracker.alive(pid):
                    self.tracker.wait(pid, 1.5)
                if self.tracker.alive(pid):
                    self.tracker.stop(pid, 74, reason, orphan)
            except OSError as exc:
                self.tracker.cleaned.append({
                    "pid": pid, "role": self.tracker._handles[pid]["role"],
                    "action": "cleanup_error", "reason": str(exc),
                })
        if self.guard:
            try:
                self.guard.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if self.peer:
            try:
                self.peer.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        if self.origin:
            self.origin.stop()
        try:
            if self.lock_path.exists():
                self.lock_path.unlink()
        except OSError:
            pass
        self.tracker.close()


def quiet_window(origin):
    guarded = origin.distinct("guarded")
    unguarded = origin.distinct("unguarded")
    time.sleep(0.3)
    base_g = origin.distinct("guarded")
    base_u = origin.distinct("unguarded")
    time.sleep(1.0)
    return {
        "guarded_before_quiet": guarded,
        "guarded_delta": origin.distinct("guarded") - base_g,
        "unguarded_delta": origin.distinct("unguarded") - base_u,
        "drained_guarded": base_g - guarded,
    }


def scenario_listener_close():
    harness = Harness("listener-close", "armed")
    try:
        ready = harness.start()
        if not ready or ready.get("event") != "ready":
            return unknown_or_error(harness, ready, "guard did not become ready")
        if not harness.flowing():
            return {"status": "UNKNOWN", "reason": "timed out waiting for initial markers", "ready": ready}
        if not (ready.get("child_in_job") and ready.get("kill_on_close") and ready.get("guard_in_job") is False):
            return {"status": "FAILED", "reason": "job membership did not match the guard report", "ready": ready}
        before_g = harness.origin.distinct("guarded")
        before_u = harness.origin.distinct("unguarded")
        harness.close_health()
        if not harness.tracker.wait(harness.guard.pid, 5):
            return {"status": "UNKNOWN", "reason": "timed out waiting for the guard to exit"}
        if not harness.tracker.wait(ready["child_pid"], 3):
            return {"status": "UNKNOWN", "reason": "timed out waiting for the guarded child to exit"}
        observed = quiet_window(harness.origin)
        health = harness.lines.wait_for(lambda item: item.get("event") == "health", 1)
        guard_exit = harness.tracker.exit_code(harness.guard.pid)
        child_exit = harness.tracker.exit_code(ready["child_pid"])
        expected = {
            "guard_exit": 0, "child_exit": EXPLICIT_JOB_EXIT, "guarded_delta": 0,
            "unguarded_continued": True, "health_action": "terminate",
        }
        ok = (
            guard_exit == 0 and child_exit == EXPLICIT_JOB_EXIT
            and observed["guarded_delta"] == 0 and observed["unguarded_delta"] >= 2
            and before_g >= 2 and before_u >= 2
            and health and health.get("action") == "terminate"
            and health.get("child_exit") == EXPLICIT_JOB_EXIT
        )
        return {
            "status": "PASS" if ok else "FAILED",
            "expected": expected,
            "observed": {
                "guard_exit": guard_exit,
                "child_exit": child_exit,
                "guarded_before": before_g,
                "unguarded_before": before_u,
                **observed,
                "health": health,
            },
        }
    finally:
        harness.finish()
        return_cleanup(harness)


_CLEANUP = []


def return_cleanup(harness):
    _CLEANUP.append({
        "scenario": harness.name,
        "cleaned_up": harness.tracker.cleaned,
        "orphans": harness.tracker.orphans,
    })


def unknown_or_error(harness, ready, reason):
    if ready and ready.get("event") == "error":
        return {"status": "FAILED", "reason": ready.get("error"), "events": harness.lines.snapshot()}
    if harness.guard and harness.guard.poll() not in (None, 0):
        error = next((item for item in harness.lines.snapshot() if item.get("event") == "error"), None)
        if error:
            return {"status": "FAILED", "reason": error.get("error"), "guard_exit": harness.guard.returncode}
    return {
        "status": "UNKNOWN",
        "reason": reason,
        "events": harness.lines.snapshot(),
        "stderr": "".join(harness.stderr)[:400],
    }


def scenario_guard_killed():
    harness = Harness("guard-killed", "armed")
    try:
        ready = harness.start()
        if not ready or ready.get("event") != "ready":
            return unknown_or_error(harness, ready, "guard did not become ready")
        if not harness.flowing():
            return {"status": "UNKNOWN", "reason": "timed out waiting for initial markers"}
        before_g = harness.origin.distinct("guarded")
        before_u = harness.origin.distinct("unguarded")
        if not kernel32.TerminateProcess(harness.tracker._handles[harness.guard.pid]["handle"], GUARD_KILLED_EXIT):
            raise OSError(winerror() + " (TerminateProcess guard)")
        if not harness.tracker.wait(harness.guard.pid, 3):
            return {"status": "UNKNOWN", "reason": "timed out waiting for the killed guard to exit"}
        child_done = harness.tracker.wait(ready["child_pid"], 3)
        if not child_done:
            reaped = harness.tracker.stop(
                ready["child_pid"], 74, "guarded child still alive after the guard was killed", True
            )
            return {
                "status": "UNKNOWN",
                "reason": "timed out waiting for the job handle close to stop the child",
                "child_gone": False,
                "reaped": reaped,
                "guard_exit": harness.tracker.exit_code(harness.guard.pid),
            }
        observed = quiet_window(harness.origin)
        guard_exit = harness.tracker.exit_code(harness.guard.pid)
        child_exit = harness.tracker.exit_code(ready["child_pid"])
        ok = (
            guard_exit == GUARD_KILLED_EXIT and child_exit == JOB_CLOSE_EXIT
            and observed["guarded_delta"] == 0 and observed["unguarded_delta"] >= 2
            and before_g >= 2 and before_u >= 2 and not harness.tracker.alive(ready["child_pid"])
        )
        return {
            "status": "PASS" if ok else "FAILED",
            "expected": {
                "guard_exit": GUARD_KILLED_EXIT,
                "child_exit": JOB_CLOSE_EXIT,
                "guarded_delta": 0,
                "child_gone": True,
            },
            "observed": {
                "guard_exit": guard_exit,
                "child_exit": child_exit,
                "child_gone": not harness.tracker.alive(ready["child_pid"]),
                "guarded_before": before_g,
                "unguarded_before": before_u,
                **observed,
            },
        }
    finally:
        harness.finish()
        return_cleanup(harness)


def scenario_user_disabled():
    harness = Harness("user-disabled", "user-disabled")
    try:
        ready = harness.start()
        if not ready or ready.get("event") != "ready":
            return unknown_or_error(harness, ready, "guard did not become ready")
        if not harness.flowing():
            return {"status": "UNKNOWN", "reason": "timed out waiting for initial markers"}
        harness.close_health()
        health = harness.lines.wait_for(lambda item: item.get("event") == "health", 3)
        if not health:
            return {"status": "UNKNOWN", "reason": "timed out waiting for the guard to see the closed listener"}
        if health.get("action") != "ignore":
            return {"status": "FAILED", "reason": "user-disabled guard did not ignore the closed listener", "health": health}
        base = harness.origin.distinct("guarded")
        if not wait_until(lambda: harness.origin.distinct("guarded") >= base + 2, 2):
            alive = harness.tracker.alive(ready["child_pid"])
            return {
                "status": "UNKNOWN" if alive else "FAILED",
                "reason": "no marker after the closed listener" if alive else "guarded child stopped after the closed listener",
                "child_alive": alive,
            }
        child_alive = harness.tracker.alive(ready["child_pid"])
        guard_alive = harness.tracker.alive(harness.guard.pid)
        unguarded_alive = harness.tracker.alive(harness.peer.pid)
        delivered = harness.origin.distinct("guarded") - base
        ok = child_alive and guard_alive and unguarded_alive and delivered >= 2
        harness.release_guard_stdin()
        harness.tracker.wait(harness.guard.pid, 3)
        harness.tracker.wait(ready["child_pid"], 3)
        return {
            "status": "PASS" if ok else "FAILED",
            "expected": {"health_action": "ignore", "marker_after_close": True, "child_alive_after_close": True},
            "observed": {
                "health": health,
                "markers_after_ignore": delivered,
                "child_alive_after_marker": child_alive,
                "guard_alive_after_marker": guard_alive,
                "unguarded_alive": unguarded_alive,
                "child_exit_after_guard_release": None if harness.tracker.alive(ready["child_pid"]) else harness.tracker.exit_code(ready["child_pid"]),
                "child_gone_after_guard_exit": not harness.tracker.alive(ready["child_pid"]),
            },
        }
    finally:
        harness.finish()
        return_cleanup(harness)


def scenario_second_guard():
    harness = Harness("second-guard", "armed")
    second = None
    second_lines = Lines()
    try:
        ready = harness.start()
        if not ready or ready.get("event") != "ready":
            return unknown_or_error(harness, ready, "first guard did not become ready")
        if not harness.flowing():
            return {"status": "UNKNOWN", "reason": "timed out waiting for initial markers"}
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        second = subprocess.Popen(
            [
                sys.executable, str(ROOT / "failclose.py"), "guard",
                "--origin-port", str(harness.origin.port),
                "--health-port", str(harness.health.getsockname()[1]),
                "--lock", str(harness.lock_path),
                "--mode", "armed",
                "--interval", str(INTERVAL),
            ],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
            creationflags=CREATE_NO_WINDOW, env=env,
        )
        harness.tracker.open(second.pid, "second-guard", Path(sys.executable))
        threading.Thread(target=pump, args=(second.stdout, second_lines), daemon=True).start()
        base = harness.origin.distinct("guarded")
        try:
            second_exit = second.wait(timeout=3)
            timed_out = False
        except subprocess.TimeoutExpired:
            second_exit = None
            timed_out = True
        child_alive = harness.tracker.alive(ready["child_pid"])
        guard_alive = harness.tracker.alive(harness.guard.pid)
        if not child_alive:
            return {
                "status": "FAILED",
                "reason": "second guard start coincided with the first child exiting",
                "second_exit": second_exit,
                "events": second_lines.snapshot(),
            }
        if timed_out:
            return {"status": "UNKNOWN", "reason": "second guard timed out", "child_alive": child_alive}
        grew = wait_until(lambda: harness.origin.distinct("guarded") >= base + 2, 2)
        busy = second_lines.wait_for(lambda item: item.get("event") == "lock_busy", 1)
        ready_again = second_lines.wait_for(lambda item: item.get("event") == "ready", 0.1)
        ok = (
            second_exit == LOCK_BUSY_EXIT and busy and busy.get("attempts") == 2
            and ready_again is None and child_alive and guard_alive and grew
            and harness.tracker.alive(ready["child_pid"])
        )
        return {
            "status": "PASS" if ok else "FAILED",
            "expected": {"second_exit": LOCK_BUSY_EXIT, "attempts": 2, "first_child_kept_sending": True},
            "observed": {
                "second_exit": second_exit,
                "lock_event": busy,
                "second_ready": ready_again,
                "first_child_alive": harness.tracker.alive(ready["child_pid"]),
                "first_guard_alive": harness.tracker.alive(harness.guard.pid),
                "guarded_delta": harness.origin.distinct("guarded") - base,
                "events": second_lines.snapshot(),
            },
        }
    finally:
        if second and second.poll() is None:
            try:
                harness.tracker.stop(second.pid, 74, "second guard still running at cleanup", False)
            except OSError:
                pass
        harness.finish()
        return_cleanup(harness)


def scenario_appcontainer():
    origin = Origin()
    exe = None
    info = None
    name = None
    sid = None
    sid_text = None
    notes = []
    result_path = RUNTIME / "appcontainer-result.json"
    control_path = RUNTIME / "control-result.json"
    try:
        RUNTIME.mkdir(parents=True, exist_ok=True)
        try:
            exe = compile_probe()
        except (OSError, subprocess.SubprocessError) as exc:
            return {
                "status": "UNKNOWN",
                "scope": "this process only",
                "stage": None,
                "winerror": None,
                "reason": str(exc),
            }
        for path in (result_path, control_path):
            path.write_text("", encoding="ascii")
        try:
            control = run_probe(exe, origin.port, "control", control_path)
        except subprocess.TimeoutExpired:
            return {
                "status": "UNKNOWN", "scope": "this process only", "stage": None,
                "winerror": None, "reason": "unrestricted control timed out",
                "origin_received": origin.distinct("control") > 0,
            }
        name = "V69.FailClose." + uuid.uuid4().hex
        sid_ptr = ctypes.c_void_p()
        hr = userenv.CreateAppContainerProfile(
            name, name, "Temporary loopback socket test", None, 0, ctypes.byref(sid_ptr)
        )
        if hr < 0 or not sid_ptr.value:
            return {
                "status": "UNKNOWN", "scope": "this process only", "stage": None,
                "winerror": None, "reason": f"CreateAppContainerProfile {hr_text(hr)}",
                "control_ok": control["exit"] == 0,
            }
        sid = sid_ptr
        text = wintypes.LPWSTR()
        if not advapi32.ConvertSidToStringSidW(sid, ctypes.byref(text)):
            raise OSError(winerror() + " (ConvertSidToStringSidW)")
        sid_text = text.value
        kernel32.LocalFree(text)
        if not sid_text.startswith("S-1-15-2-"):
            raise OSError("unexpected AppContainer SID")
        for path, rights in ((ROOT, "(OI)(CI)(RX)"), (exe, "(RX)"), (result_path, "(M)")):
            grant = subprocess.run(
                ["icacls", str(path), "/grant", f"*{sid_text}:{rights}"],
                capture_output=True, text=True, timeout=30, check=False,
            )
            if grant.returncode != 0:
                detail = (grant.stderr or grant.stdout or "").strip()
                return {
                    "status": "UNKNOWN", "scope": "this process only", "stage": None,
                    "winerror": None, "reason": f"icacls exit {grant.returncode}: {detail[-400:]}",
                }
        caps = SECURITY_CAPABILITIES()
        caps.AppContainerSid = sid
        caps.CapabilityCount = 0
        caps.Reserved = 0
        size = ctypes.c_size_t(0)
        kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        if size.value <= 0:
            raise OSError(winerror() + " (attribute list size)")
        attr = ctypes.create_string_buffer(size.value)
        if not kernel32.InitializeProcThreadAttributeList(attr, 1, 0, ctypes.byref(size)):
            raise OSError(winerror() + " (InitializeProcThreadAttributeList)")
        try:
            if not kernel32.UpdateProcThreadAttribute(
                attr, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, ctypes.byref(caps),
                ctypes.sizeof(caps), None, None,
            ):
                raise OSError(winerror() + " (UpdateProcThreadAttribute)")
            startup = STARTUPINFOEXW()
            startup.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
            startup.lpAttributeList = ctypes.cast(attr, ctypes.c_void_p)
            info = PROCESS_INFORMATION()
            marker = uuid.uuid4().hex
            command = subprocess.list2cmdline([
                str(exe), str(origin.port), "appcontainer", marker, str(result_path)
            ])
            buffer = ctypes.create_unicode_buffer(command)
            flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
            if not kernel32.CreateProcessW(
                str(exe), buffer, None, None, False, flags, None, system_directory(),
                ctypes.byref(startup), ctypes.byref(info),
            ):
                raise OSError(winerror() + " (CreateProcessW AppContainer)")
            kernel32.CloseHandle(info.hThread)
            waited = kernel32.WaitForSingleObject(info.hProcess, 5000) == 0
            code = wintypes.DWORD()
            kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
            if not waited:
                kernel32.TerminateProcess(info.hProcess, 74)
                kernel32.WaitForSingleObject(info.hProcess, 3000)
                kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
                container = {"exit": int(code.value), "result": None, "timed_out": True}
            else:
                body = None
                if result_path.is_file() and result_path.stat().st_size:
                    try:
                        body = json.loads(result_path.read_text(encoding="ascii"))
                    except (OSError, json.JSONDecodeError) as exc:
                        body = None
                        notes.append(f"result file: {type(exc).__name__}")
                container = {"exit": int(code.value), "result": body, "timed_out": False}
        finally:
            kernel32.DeleteProcThreadAttributeList(attr)
        judged = judge_container(container, control, origin, container["timed_out"])
        if notes:
            judged["notes"] = notes
        return judged
    except subprocess.TimeoutExpired as exc:
        return {
            "status": "UNKNOWN", "scope": "this process only", "stage": None,
            "winerror": None, "reason": f"timeout: {exc}",
            "origin_received": origin.distinct("appcontainer") > 0 if origin else False,
        }
    except OSError as exc:
        return {
            "status": "UNKNOWN", "scope": "this process only", "stage": None,
            "winerror": None, "reason": str(exc),
            "origin_received": origin.distinct("appcontainer") > 0 if origin else False,
        }
    finally:
        if info and valid_handle(info.hProcess):
            if kernel32.WaitForSingleObject(info.hProcess, 0) != 0:
                kernel32.TerminateProcess(info.hProcess, 74)
                kernel32.WaitForSingleObject(info.hProcess, 3000)
            kernel32.CloseHandle(info.hProcess)
        if sid_text or name:
            notes.extend(delete_profile(name, sid, sid_text))
        elif sid:
            advapi32.FreeSid(sid)
        if origin:
            origin.stop()


def rollup(scenarios):
    job_names = ("listener_close", "guard_killed", "user_disabled", "second_guard")
    statuses = [scenarios[name]["status"] for name in job_names]
    app = scenarios["appcontainer"]["status"]
    if any(item == "FAILED" for item in statuses) or app == "FAILED":
        return "FAILED", 1
    if any(item != "PASS" for item in statuses) or app not in {"BLOCKED"}:
        return "UNKNOWN", 2
    return "PASS", 0


def run_suite():
    if os.name != "nt":
        print(json.dumps({"status": "FAILED", "error": "Windows is required"}))
        return 1
    scenarios = {}
    order = (
        ("listener_close", scenario_listener_close),
        ("guard_killed", scenario_guard_killed),
        ("user_disabled", scenario_user_disabled),
        ("second_guard", scenario_second_guard),
        ("appcontainer", scenario_appcontainer),
    )
    for name, func in order:
        try:
            scenarios[name] = func()
        except Exception as exc:
            scenarios[name] = {"status": "FAILED", "error": f"{type(exc).__name__}: {exc}"}
    status, code = rollup(scenarios)
    summary = {
        "coverage": "processes started inside this job only",
        "loopback": LOOPBACK,
        "status": status,
        "scenarios": scenarios,
        "cleaned_up": _CLEANUP,
    }
    print(json.dumps(summary, indent=2))
    return code


def main(argv):
    if len(argv) == 1:
        return run_suite()
    command = argv[1]
    if command == "sender":
        return sender_main(argv[2:])
    if command == "guard":
        return guard_main(argv[2:])
    print(json.dumps({"status": "FAILED", "error": "unknown command"}))
    return 65


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as exc:
        sys.stderr.write(f"{type(exc).__name__}: {exc}\n")
        print(json.dumps({"status": "FAILED", "error": f"{type(exc).__name__}: {exc}"}))
        raise SystemExit(1)
