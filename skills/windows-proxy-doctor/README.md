# windows-proxy-doctor

A read-only Windows network/proxy diagnostic Skill, derived from the V1-V6 engineering work in this repository.

## Install

Copy skills/windows-proxy-doctor/ into your Agent Skills directory (for example ~/.agents/skills/ or the skills directory used by your client), or point the client at this folder. The folder name and frontmatter name must both be windows-proxy-doctor.

No admin rights, no proxy client, and no browser extension are required for default diagnostics.

## Quick use

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -Json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ProxyConsistency.ps1 -SnapshotFile .\examples\snapshot-mismatch.json
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

## What it does not do

- It does not change system proxy, HKCU, WinHTTP, routes, TUN, DNS, firewall, or proxy client configs.
- It does not install extensions, read cookies/tokens, or change browser identity.
- It does not assess third-party account eligibility or provide evasion.
- It does not treat UI status, a ping, or a third-party IP score as ground truth.

See SKILL.md, SECURITY.md, and references/.
