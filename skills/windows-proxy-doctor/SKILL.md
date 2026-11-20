---
name: windows-proxy-doctor
description: Guide Windows users through proxy software discovery, first-time setup, scoped authorization, connectivity diagnosis, and recovery. Use for installation readiness, mismatched proxy settings, competing clients, no traffic, port conflicts, or reconnect and routing problems.
license: MIT
metadata:
  version: "2.0.0"
  release-channel: "release-candidate"
---

# Windows Proxy Doctor

Designed for Windows 10 and 11 with Windows PowerShell 5.1 or a later PowerShell host. A compatible agent can run local PowerShell or guide the user manually.

## Start here

1. Respond in the user's language. Ask whether they want help getting started or fixing a problem only if their request leaves the goal unclear. Start the safe local inventory immediately if you have a Windows shell.
2. Run `scripts/Start-ProxyDoctor.ps1 -Goal Auto -Json` with the user's current permissions. Use `Setup` for onboarding and `Diagnose` for an existing setup or fault. Check the actual availability of shell, desktop and browser tools before offering assistance. Use manual page and button instructions when the relevant tool is unavailable.
3. Give the user the current step, the result in plain language, and the next action. `UNKNOWN` means evidence was unavailable. A healthy socket confirms a listener. A successful HTTPS probe confirms the tested endpoint and path. Treat saved client settings, UI toggles, effective Windows settings and actual application access as separate evidence.
4. If the user needs to act, use `templates/user-action-request.md`. Explain the change, scope, expected impact and rollback. Download, install, access privileges, start/stop and modify network settings only within fresh, action-specific permission. For a downloaded installer, run `scripts/Test-ProxyDoctorInstaller.ps1` with a digest or signing certificate thumbprint independently obtained from the official source. Keep account registration, payments, identity checks, and entry of credentials with the user. Continue inventory and diagnosis when the user declines a change.
5. Before a scoped configuration change, record the verified starting state and recovery plan. Prefer native client controls. If multiple clients manage the same Windows settings, establish which client should own them and verify the others' listeners separately. On failure, follow the approved rollback and recheck the same path.
6. To resume, load the explicit local checkpoint, re-run discovery, and verify any milestones the user reports. Reconfirm risky actions against the live state and current request. Label isolated tests, user observations, live observations and unknowns separately in the report.

The default guide reads local state. Keep active HTTPS/DNS probes explicit and scoped to the user's request. Keep authenticated account actions and secret values out of the diagnosis, command arguments, checkpoints and reports. Use the Skill for network setup and troubleshooting within the user's service terms and eligibility.

## Load only the relevant reference

| Task | Reference |
| --- | --- |
| First launch, installation choices and resuming | [Getting started](references/getting-started.md) |
| Inventory, alternate installations and ambiguous results | [Environment discovery](references/environment-discovery.md) |
| User decisions, trust checks, commercial disclosure and checkpoints | [User interaction](references/user-interaction.md) |
| Symptom to evidence, recovery and verification | [Troubleshooting](references/troubleshooting.md) |
| Startup, switching and observed lifecycle limits | [Lifecycle observations](references/lifecycle-observations.md) and [reliability gaps](references/reliability-gaps.md) |
| Technical evidence and publication | [Architecture](references/architecture.md), [targeted findings](references/targeted-findings.md), [safety](references/safety.md), [V1–V6 lessons](references/v1-v6-lessons.md) |

The [README](README.md) lists the existing diagnostics, watcher and backup commands. The [security guide](SECURITY.md) describes their operational boundaries.
