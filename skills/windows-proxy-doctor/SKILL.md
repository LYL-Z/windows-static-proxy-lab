---
name: windows-proxy-doctor
description: Guide Windows users through proxy software discovery, first-time setup, scoped authorization, connectivity diagnosis, and recovery. Use for installation readiness, mismatched proxy settings, competing clients, no traffic, port conflicts, reconnect and routing problems, or a report that the proxy is not working.
license: MIT
metadata:
  version: "2.0.0"
  release-channel: "release-candidate"
  iteration: "rc2"
---

# Windows Proxy Doctor

Designed for Windows 10 and 11 with Windows PowerShell 5.1 or a later PowerShell host. A compatible agent can run local PowerShell or guide the user manually.

## Start here

1. Respond in the user's language. Ask whether they want help getting started or fixing a problem only if their request leaves the goal unclear. Start the safe local inventory immediately if you have a Windows shell.
2. Run `scripts/Start-ProxyDoctor.ps1 -Json` with the user's current permissions. Use `-Goal Setup` for first-time preparation and `-Goal Diagnose` for checking an existing setup or a reported fault. A sentence equivalent to “检查我的代理为什么没有正常工作” is a diagnose request: run `scripts/Start-ProxyDoctor.ps1 -Goal Diagnose -Json`, then call `Get-ProxyDoctorFaultClass` in `scripts/ProxyFaultClass.ps1`. `Resolve-ProxyDoctorUserRequest` maps that sentence onto this classification step. `USER_OFF` means the user turned the proxy off; do not recommend restoring it. `ALIGNED` is local agreement only and is not application success. An alert or UI status is not proof the network was blocked. When the user wants to resume, use their agreed local checkpoint with `-Goal Auto` and reconcile the reported step against new observations. Check actual tool availability before offering desktop or browser help.
3. Give the user the current step and next action in plain language. Keep local diagnosis, HTTPS results, the specific application's result, agreed configuration acceptance, and lifecycle evidence separate. `DIAGNOSIS_COMPLETE` covers local diagnosis only. `UNKNOWN` means evidence was unavailable. See [verification inputs](references/user-interaction.md#agent-的向导参数) before recording an observed result.
4. If the user needs to act, use `templates/user-action-request.md`. Explain the change, scope, expected impact and rollback. Download, install, access privileges, start/stop and modify network settings only within fresh, action-specific permission. For a downloaded installer, run `scripts/Test-ProxyDoctorInstaller.ps1` with a digest or signing certificate thumbprint independently obtained from the official source. Keep account registration, payments, identity checks, and entry of credentials with the user. Continue inventory and diagnosis when the user declines a change.
5. Before a scoped configuration change, record the verified starting state and recovery plan. Prefer native client controls. If multiple clients manage the same Windows settings, establish which client should own them and verify the others' listeners separately. On failure, follow the approved rollback and recheck the same path.
6. If a user reports completing a step but the checkpoint or action is unclear, inspect the agreed checkpoint and ask only for the missing detail. If the wizard returns `WRITE_FAILED`, explain that the current step can continue in this conversation but progress was not saved. Use a writable private location for a retry. Do not hand-edit the checkpoint or bypass the atomic writer. Use the getting-started guide for preparation or resumption and the troubleshooting guide for application faults.

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
