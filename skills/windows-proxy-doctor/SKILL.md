---
name: windows-proxy-doctor
description: Read-only Windows network and proxy diagnostics for state mismatches, competing proxy clients, TCP/DNS/UDP path differences, transactional backup/rollback design, test isolation, credentials, and startup lifecycle.
license: MIT
metadata:
  version: "1.0.0"
  platforms: "Windows 10/11 PowerShell 5.1+"
---

# Windows Proxy Doctor

## When to use

Use this skill when the user reports any of:

- Browser works but a proxy client shows no traffic, or the reverse.
- Windows proxy / WinHTTP / Clash / StarSky / UI states disagree.
- A proxy change caused a network outage, or recovery is unclear.
- A backup, transaction, rollback, or test-isolation plan needs review.
- Startup, sleep, Wi-Fi reconnect, DNS, TCP, or UDP path behavior is suspect.

## Default posture

Read-only. Do not modify HKCU, WinHTTP, adapters, routes, TUN, DNS, firewall, Defender, certificates, proxy client configs, or credentials. Any production write requires separate explicit user authorization. This skill does not provide platform-account evasion, identity spoofing, CAPTCHA optimization, or region/account restriction bypass.

## Workflow

1. Freeze the facts: record time, HKCU proxy values, WinHTTP, relevant process names/PIDs, listeners, Clash UI enable_system_proxy, and file hashes. Do not print credentials.
2. Separate layers: application/UI state, OS proxy, local listener, first hop, DNS, TCP, UDP/WebRTC, and actual exit path are different layers. Never collapse them into one healthy flag.
3. Classify:
   - HEALTHY: actual OS proxy and UI agree, listener/process alive, required path probe passes.
   - DEGRADED: local service works but routing/UI/one layer disagrees.
   - FAILED: required proxy/listener/process is absent or path fails.
   - UNKNOWN: insufficient evidence; do not guess.
4. Report evidence, confidence, and what was not tested.
5. Only after explicit authorization propose or execute a change with backup, verification, and rollback.

## Scripts

| Script | Purpose |
|---|---|
| scripts/Get-ProxyDoctorSnapshot.ps1 | Read-only snapshot and classification. Use -TestFixture for isolated tests. |
| scripts/Test-ProxyConsistency.ps1 | Compare UI, actual, listener, and process evidence. |
| scripts/Test-NetworkPath.ps1 | TCP/DNS/path probes; optional explicit proxy. |
| scripts/Protect-Backup.ps1 | DPAPI-encrypt a backup zip; -Apply required. |
| scripts/Unprotect-Backup.ps1 | Decrypt and verify; never overwrites. |
| scripts/Test-Skill.ps1 | Validate format, references, fixtures, and secret hygiene. |

Run from the skill directory:

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

## References (load only when needed)

- references/v1-v6-lessons.md: failures, wrong assumptions, corrections, and reusable rules from V1-V6.
- references/architecture.md: layered model and state classification.
- references/safety.md: authorization, backup, test isolation, credential/publication rules.
- examples/: synthetic snapshots and commands.

## Non-negotiable rules

- Never use an isolated test as proof of production deployment.
- Never use an exit IP or third-party score as proof of account/service eligibility.
- Never store credentials in argv, shell history, logs, examples, or public files.
- Never delete the only valid backup to clean up.
- If evidence is missing, report UNKNOWN, not a guess.
