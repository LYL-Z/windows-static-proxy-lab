# Layered architecture and state model

## Layers

1. Application/UI: Clash Verge toggle, saved enable_system_proxy, tray state.
2. OS proxy: HKCU Internet Settings (ProxyEnable/ProxyServer/ProxyOverride),
   WinHTTP, WinINet refresh.
3. Local service: proxy client process, mixed listener, first-hop listener.
4. Resolution/routing: DNS, rules, GEOIP/domain matching, TUN/route.
5. Transport: TCP, UDP/WebRTC, QUIC.
6. Exit: direct ISP, StarSky, static proxy, other.

Each layer has independent evidence. A failure in one does not prove another.

## Classification

| State | Meaning |
|---|---|
| HEALTHY | Required layers agree and the requested path probe passes. |
| DEGRADED | Local service works but at least one layer disagrees (UI/OS, first hop, DNS, exit, UDP). |
| FAILED | Required process/listener/path is absent or a required probe fails. |
| UNKNOWN | Evidence is missing or stale; do not guess. |

## Data flow

    UI config -> OS proxy -> browser/application
                         -> local mixed port -> rules -> first hop -> upstream

The direct path bypasses the local proxy entirely. That is why a working browser
can coexist with an idle proxy client: the OS proxy may be off while the UI says on.

## Scripts mapping

- Get-ProxyDoctorSnapshot.ps1: layers 1-3 snapshot and classification.
- Test-ProxyConsistency.ps1: compares layer 1 vs 2 vs 3.
- Test-NetworkPath.ps1: layers 4-6 probes (TCP/DNS; UDP explicitly not probed).
- Protect-Backup.ps1 / Unprotect-Backup.ps1: backup integrity/encryption.
- Test-Skill.ps1 and tests/: static and isolated validation.

## Design constraints

- Windows PowerShell 5.1 compatibility.
- No admin requirement for the default read-only path.
- No secrets in output; redact credentials and unnecessary public IPs/paths.
- Tests use synthetic fixtures and a temporary root only.
