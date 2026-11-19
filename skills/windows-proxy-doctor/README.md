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

## Registry writer evidence

The opt-in command reads up to 1,000 matching event IDs per log from the past 15 minutes. It selects monitored values under the current user's Internet Settings key and its default connection settings. Output includes the time, field, executable basename, and available process and record IDs. Existing logging, access, and retention determine coverage. An empty or unavailable result leaves the writer unknown. A recorded event identifies an operation on the setting. Compare its time and record ID with local evidence before associating it with a particular incident. [Security 4657](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4657) · [Sysmon Event 13](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon#event-id-13-registryevent-value-set)

The snapshot reports PAC URL presence. Confirm per-connection settings, WPAD, policies, and application-specific overrides separately when diagnosing actual routing.

## Uninstall and recovery

Remove the installed `windows-proxy-doctor` folder from the location used by your client. Keep separately created backups and evidence until they are no longer needed. If a diagnostic detects drift, confirm the intended proxy, the listener, and the expected HTTPS route before making a separately authorized change. Restore a real configuration backup only after verifying its integrity and the target user's environment.

See SKILL.md, SECURITY.md, and references/.
