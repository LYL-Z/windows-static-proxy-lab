"""Read-only preflight for the adjacent Windows Sandbox offline profile."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET


EXPECTED = {
    "Networking": "Disable", "ClipboardRedirection": "Disable", "AudioInput": "Disable",
    "VideoInput": "Disable", "PrinterRedirection": "Disable", "vGPU": "Disable",
    "ProtectedClient": "Enable",
}


def validate(raw):
    # This profile uses plain ASCII XML and no DTD, entities or processing instructions.
    if len(raw) > 8192 or not raw.isascii() or b"\x00" in raw or b"<!" in raw or b"<?" in raw:
        raise ValueError("unexpected XML encoding or declarations")
    root = ET.fromstring(raw)
    if root.tag != "Configuration" or root.attrib or (root.text or "").strip():
        raise ValueError("unexpected root")
    seen = set()
    for field in root:
        if (field.tag not in EXPECTED or field.tag in seen or field.attrib or len(field)
                or (field.tail or "").strip() or field.text != EXPECTED[field.tag]):
            raise ValueError("unexpected option, duplicate, or value")
        seen.add(field.tag)
    if seen != EXPECTED.keys():
        raise ValueError("required isolation option missing")


def launcher_present():
    if os.name != "nt":
        return None
    buf = ctypes.create_unicode_buffer(32768)
    count = ctypes.windll.kernel32.GetSystemDirectoryW(buf, len(buf))
    return (Path(buf.value) / "WindowsSandbox.exe").is_file() if 0 < count < len(buf) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="also check rejected profiles in memory")
    args = parser.parse_args()
    with Path(__file__).with_name("Offline.wsb").open("rb") as stream:
        raw = stream.read(8193)
    validate(raw)
    tests = {}
    if args.self_test:
        end = b"</Configuration>"
        extra = {
            "network enabled": raw.replace(b"<Networking>Disable", b"<Networking>Enable"),
            "network default": raw.replace(b"<Networking>Disable</Networking>", b""),
            "duplicate network": raw.replace(end, b"<Networking>Enable</Networking>" + end),
            "host folder": raw.replace(end, b"<MappedFolders/>" + end),
            "logon command": raw.replace(end, b"<LogonCommand/>" + end),
            "clipboard enabled": raw.replace(b"<ClipboardRedirection>Disable", b"<ClipboardRedirection>Enable"),
            "attribute": raw.replace(b"<Configuration>", b"<Configuration x='1'>"),
            "DTD": b"<!DOCTYPE Configuration>" + raw,
            "malformed XML": raw.replace(end, b""),
        }
        for name, variant in extra.items():
            try:
                validate(variant)
            except (ValueError, ET.ParseError):
                tests[name] = "REJECTED"
            else:
                raise ValueError("unsafe example accepted: " + name)
    launcher = launcher_present()
    print(json.dumps(dict(profile="Offline.wsb", sha256=hashlib.sha256(raw).hexdigest(),
                          staticProfile="PASS", systemDirectoryLauncher=launcher,
                          sandboxRuntime="NOT_TESTED", rejectedVariants=tests), indent=2))
    return 0 if launcher else 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, ET.ParseError) as error:
        print(json.dumps(dict(staticProfile="FAILED", error=type(error).__name__)))
        raise SystemExit(1)
