---
name: windows-proxy-doctor
description: Guide Windows users through proxy software discovery, first-time setup, scoped authorization, connectivity diagnosis, and isolated recovery rehearsal. Use for installation readiness, mismatched proxy settings, competing clients, no traffic, port conflicts, reconnect and routing problems, or a report that the proxy is not working.
license: MIT
metadata:
  version: "2.1.0"
  release-channel: "release-candidate"
  iteration: "rc3"
---

# CAB Skill · Windows Proxy Doctor

Designed for Windows 10 and 11 with Windows PowerShell 5.1 or a later PowerShell host. A compatible agent can run local PowerShell or guide the user manually.

## 三段边界：诊断 / 隔离演练 / 需要授权的真实操作

| 段 | 这一段实际做什么 | 会写系统代理吗 | 开始前需要什么 |
| --- | --- | --- | --- |
| 1. 只读诊断 | 读取当前用户的代理选择、客户端进程、回环监听和可选 HTTPS/DNS 探测，给出分类、证据范围和下一步 | 不会 | 当前权限；不需要额外授权 |
| 2. 隔离演练 | 在 `%TEMP%` 的一次性目录里，用随包且哈希相符的 `rollback-v4.ps1` 与 `V4.ps1`、以 `V4_TEST_MODE=1` 跑一次回滚；只影响该临时目录 | 不会 | 随包 Desktop/CLI 的 `engine` 目录，加上用户逐字确认的短语 |
| 3. 需要授权的真实操作 | 安装、启动或停止客户端、改配置、重启等由用户自己决定；本 Skill 只说明并等待单独授权 | 由用户在自己的操作里决定 | 每一次单独授权 |

**真实生产写入未实现。** 本 Skill 与 Desktop/CLI 目前都只做诊断和隔离演练：Executor 固定 `V4_TEST_MODE` + stub，不会写真实系统代理。`V4_TEST_MODE` 是进程内逻辑隔离，不是操作系统强制沙箱。不要把它们写成已经能写生产代理。

## 1. 只读诊断（默认，不需要额外授权）

1. Respond in the user's language. Ask whether they want help getting started or fixing a problem only if their request leaves the goal unclear. Start the safe local inventory immediately if you have a Windows shell.
2. Run `scripts/Start-ProxyDoctor.ps1 -Json` with the user's current permissions. Use `-Goal Setup` for first-time preparation and `-Goal Diagnose` for checking an existing setup or a reported fault. `Resolve-ProxyDoctorUserRequest` recognizes “检查我的网络”, “检查我的代理为什么没有正常工作”, “StarSky 已经重新开启，但 Clash 没有流量。”, “检查我的电脑网络配置是否正常。”, “检查网络故障并提供恢复方案。”, “全面检查我的网络”, “StarSky 停止运行了”, “Clash 没有流量” and “检查异常并提供恢复方案”. For diagnosis, run `scripts/Start-ProxyDoctor.ps1 -Goal Diagnose -Json`. Use the resulting `faultClass` from `Get-ProxyDoctorFaultClass` in `scripts/ProxyFaultClass.ps1`. “保持原配置，不擅自修改” or “不要修改” gives the request the `no-modify` intent. Preserve the configuration. If the user also explicitly asks for a check, run only the requested read-only checks. `USER_OFF` records a confirmed user decision and `OBSERVED_OFF` records a sampled off state with intent unknown. Preserve either state until the user authorizes a specific change. `ALIGNED` covers local agreement. Verify the actual application independently. When the user wants to resume, use their agreed local checkpoint with `-Goal Auto` and reconcile the reported step against new observations. Check actual tool availability before offering desktop or browser help.
3. Give the user the current step and next action in plain language. Keep local diagnosis, HTTPS results, the specific application's result, agreed configuration acceptance, and lifecycle evidence separate. `DIAGNOSIS_COMPLETE` covers local diagnosis only. `UNKNOWN` means evidence was unavailable. An alert or UI status is not proof the network was blocked. See [verification inputs](references/user-interaction.md#agent-的向导参数) before recording an observed result.
4. Reading local state is the default. Keep active HTTPS/DNS probes explicit and scoped to the user's request. Keep authenticated account actions and secret values out of the diagnosis, command arguments, checkpoints and reports. Continue inventory and diagnosis when the user declines a change.

## 2. 隔离演练（需要一句与本次操作绑定的确认短语）

`recovery/Invoke-Recovery.ps1` 是 Skill 侧唯一的恢复入口。它只做四件事：

1. 找到随包 `engine` 目录，按 `engine-manifest.json` 和写死在脚本里的已审哈希（与 `ProxyDoctor.RecoveryTrust` 相同）验证 `rollback-v4.ps1`、`lib\V4.ps1` 和包装脚本；
2. 用与 Desktop 确认框、CLI 相同的文字打印授权清单：操作、目标、操作范围、受影响资源、是否写系统代理、回滚方式、真实写入状态；
3. 调用随包的 `engine\scripts\Invoke-IsolatedRecovery.ps1` 并在一次性 TEMP 目录里运行，把结果透传出来；
4. 用现有的 `scripts/RecoveryVerdict.ps1` 判定结果。

它**不实现自己的恢复逻辑**，不写 HKCU Internet Settings，不改注册表，不重启或关闭客户端，不读写凭据。

Agent 必须按这个顺序做：

1. 先运行一次不匹配的调用，把打印出来的授权清单**原样**给用户看：

   ```powershell
   powershell.exe -NoProfile -File .\recovery\Invoke-Recovery.ps1 -AppRoot '<随包 Desktop/CLI 目录>'
   ```

   没有确认短语时它直接拒绝（exit 1，`ScriptStarted=false`），不会启动任何脚本。

2. 向用户明确询问是否同意这次隔离演练。用户同意之后，才把它打印的确认短语原样传入：

   ```powershell
   powershell.exe -NoProfile -File .\recovery\Invoke-Recovery.ps1 -AppRoot '<随包 Desktop/CLI 目录>' -ConfirmPhrase 'RECOVER-ISOLATED 127.0.0.1:7897' -Json
   ```

规则：

- 短语 = 操作名 `RECOVER-ISOLATED` + 空格 + 目标（例如本机回环监听 `127.0.0.1:7897`；代理未启用时是 `off`）。目标在执行开始时会重新读取，与短语不符就拒绝。
- 大小写不同、多一个字、目标不同、空值、`YES` 或 `--yes` 都不是授权：exit 1，`ScriptStarted=false`，`Reasons` 写明原因。
- 只有 `scripts/RecoveryVerdict.ps1` 的 `Test-ProxyDoctorRecoveryResult` 报告 `CompleteSuccess=true` 才算证据齐全。事务退出码 32 本身不是成功。
- 拒绝授权后仍然可以继续只做只读诊断，也可以再次预览这一段。
- 没有随包 `engine` 时它明确拒绝（`Reasons = engine unavailable`），不会退回到别的解释器或别的脚本。

## 3. 需要授权的真实操作

- 安装器、启动或停止客户端、修改配置、重启、清理浏览器数据等，都用 `templates/user-action-request.md` 说明改动、范围、费用或权限、预期结果和回退方式，并且**每一次**单独取得用户同意。下载安装包时先用 `scripts/Test-ProxyDoctorInstaller.ps1` 核对独立取得的摘要或签名指纹。
- 账号注册、付款、身份核验和凭据输入保留在用户自己的界面里。
- 真实系统代理写入：未实现。Skill 没有这样的执行器，也不会把隔离演练说成生产恢复。用户拒绝后仍可继续只读诊断。

## Load only the relevant reference

| Task | Reference |
| --- | --- |
| First launch, installation choices and resuming | [Getting started](references/getting-started.md) |
| Inventory, alternate installations and ambiguous results | [Environment discovery](references/environment-discovery.md) |
| User decisions, trust checks, commercial disclosure and checkpoints | [User interaction](references/user-interaction.md) |
| What may be done before a change is accepted | [Operator boundary](references/operator-boundary.md) |
| Symptom to evidence, recovery and verification | [Troubleshooting](references/troubleshooting.md). An isolated recovery is successful only when `Test-ProxyDoctorRecoveryResult` in `scripts/RecoveryVerdict.ps1` reports `CompleteSuccess`. Transaction exit 32 by itself is not success, and `V4_TEST_MODE` is not an operating-system sandbox. |
| Startup, switching and observed lifecycle limits | [Lifecycle observations](references/lifecycle-observations.md) and [reliability gaps](references/reliability-gaps.md) |
| Technical evidence and publication | [Architecture](references/architecture.md), [targeted findings](references/targeted-findings.md), [safety](references/safety.md), [V1–V6 lessons](references/v1-v6-lessons.md) |

The [README](README.md) lists the existing diagnostics, watcher and backup commands. The [security guide](SECURITY.md) describes their operational boundaries.
