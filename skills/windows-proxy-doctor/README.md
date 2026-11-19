# windows-proxy-doctor

A read-only Windows network/proxy diagnostic Skill, derived from the V1-V6 engineering work in this repository.

## Install

Copy skills/windows-proxy-doctor/ into your Agent Skills directory (for example ~/.agents/skills/ or the skills directory used by your client), or point the client at this folder. The folder name and frontmatter name must both be windows-proxy-doctor.

Run the bundled tests from the copied directory with Windows PowerShell 5.1. Default collection uses the current user's permissions. It requires no browser extension or proxy installation. Port arguments `-MixedPort` and `-FirstHopPort` default to `7897` and `11119`. The saved Clash intent is read from the standard per-user Clash Verge profile location when present.

## Quick use

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -IncludeWriterEvidence -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProxyConsistency.ps1 -SnapshotFile .\examples\snapshot-mismatch.json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

## Observe a reconnect

Run the foreground watcher from the copied directory. It completes after the selected samples. Ctrl+C stops it. `-FirstHopPort` enables an independent first-hop observation, so omit it for a single client.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Watch-ProxyLifecycle.ps1 -FirstHopPort 11119 -Samples 24 -IntervalSeconds 5
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Watch-ProxyLifecycle.ps1 -FirstHopPort 11119 -IncludeWriterEvidence -Json

`LOCAL_READY` means the sampled local components agree. Supply `-HealthUrl` and optionally a distinct `-ApplicationUrl` to run HTTPS probes through the verified IPv4 mixed listener. Use endpoints you intend to contact and expect to succeed. `HTTPS_PROBE_OK` covers those endpoints through the explicit loopback path. An application may follow another path. The probe budget is up to two requests of 12 seconds each per sample, in addition to local collection and the interval. Default monitoring sends no HTTP or DNS probes.

The console reports confirmed transitions and observed setting or listener changes. Fault alerts require two consecutive observations of the same state. `-Json` emits one record per sample. It includes sampled before and after values when the visible proxy settings change. The samples show correlation, including when a listener PID changes, with gaps between samples. They don't infer user intent, selected upstream node, or the actual writer. Record the time of any intentional UI action separately. `PROXY_DISABLED` and `OTHER_PROXY_SELECTED` describe observed settings and are informational. With `-IncludeWriterEvidence`, relevant existing records in the sample window are attached when OS settings change. Saving the JSON stream to a private local file is optional.

## Registry writer evidence

The opt-in command reads up to 1,000 matching event IDs per log from the past 15 minutes. It selects monitored values under the current user's Internet Settings key and its default connection settings. Output includes the time, field, executable basename, and available process and record IDs. Existing logging, access, and retention determine coverage. An empty or unavailable result leaves the writer unknown. A recorded event identifies an operation on the setting. Compare its time and record ID with local evidence before associating it with a particular incident. [Security 4657](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4657) · [Sysmon Event 13](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon#event-id-13-registryevent-value-set)

The snapshot reports PAC URL presence. Confirm per-connection settings, WPAD, policies, and application-specific overrides separately when diagnosing actual routing.

## Uninstall and recovery

Stop the watcher with Ctrl+C, then remove the installed `windows-proxy-doctor` folder. To roll back the Skill, copy the previous release folder into the same location after stopping the watcher. Keep privately saved evidence and backup files as needed. If a diagnostic detects drift, confirm the intended proxy, listener, and expected HTTPS route before a separately authorized change. Restore a real configuration backup after verifying its integrity and the target user's environment.

See SKILL.md, SECURITY.md, and references/.
