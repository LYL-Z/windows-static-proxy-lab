---
name: windows-proxy-doctor
description: Read-only Windows network and proxy diagnostics for state mismatches, competing proxy clients, TCP/DNS/UDP path differences, transactional backup/rollback design, test isolation, credentials, and startup lifecycle.
license: MIT
metadata:
  version: "1.3.0"
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
   Compare the Windows manual HTTP(S) proxy target with the expected listener even when both toggles are on. Test the Windows-selected path and the explicit mixed-port path independently when a target differs.
   For startup incidents, record the order in which the listener, first-hop CONNECT and verified HTTPS path become ready. Treat unavailable settings as unknown. A snapshot can identify a proxy target mismatch. Attributing the write requires a recorded writer or event.
   For SOCKS5 compatibility, compare client-resolved IPv4 and proxy-resolved domain CONNECT with certificate validation intact. For UDP, record the association reply and a separately verified datagram round trip. See references/targeted-findings.md.
3. Classify:
   - HEALTHY: actual OS proxy and UI agree, listener/process alive, required path probe passes.
   - DEGRADED: local service works but routing/UI/one layer disagrees.
   - FAILED: required proxy/listener/process is absent or path fails.
   - UNKNOWN: insufficient evidence; do not guess.
4. Report evidence, confidence, and what was not tested.
5. When considering a manual recovery, verify saved proxy intent, the active managed profile and the expected HTTPS path. Resolve pending transactions and conflicting writers before requesting a change. Record an actual lifecycle run before claiming automatic recovery.

## Scripts

| Script | Purpose |
|---|---|
| scripts/Get-ProxyDoctorSnapshot.ps1 | Read-only snapshot. It reports UNKNOWN when local settings agree and the HTTPS exit is unmeasured. Use -TestFixture for isolated tests. |
| scripts/Test-ProxyConsistency.ps1 | Compare saved UI, Windows manual HTTP(S) target, and local socket/process facts. Exit 3 indicates insufficient evidence to establish consistency. |
| scripts/Test-NetworkPath.ps1 | HTTP(S) and Windows DNS samples. Compare `-Proxy` with `-Direct` for public targets, or compare `socks5://` with `socks5h://` on a loopback listener. CONNECT and origin HTTP statuses are reported separately. |
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
- references/targeted-findings.md: GEOIP/CN rule diff, Baidu 502 attribution, SOCKS5 UDP ASSOCIATE result, WebRTC split-path explanation, candidate options.
- references/reliability-gaps.md: StarSky/first-hop behavior, startup ordering, fail-closed coverage, TCP-only scope, manual Repair vs automatic recovery.
- examples/: synthetic snapshots and commands.

## Non-negotiable rules

- Never use an isolated test as proof of production deployment.
- Never use an exit IP or third-party score as proof of account/service eligibility.
- Never store credentials in argv, shell history, logs, examples, or public files.
- Never delete the only valid backup to clean up.
- If evidence is missing, report UNKNOWN, not a guess.
