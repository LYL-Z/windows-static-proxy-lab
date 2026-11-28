# CAB Skill · Windows Proxy Doctor 2.1.0 RC3

Windows 10/11 的新手设置向导和网络故障诊断 Skill。RC3 增加 Skill 侧的隔离演练入口，并把三种模式分开写清。RC2 的证据范围及剩余发布门槛见 [验收清单](RELEASE-GATE.md)。

## 第一次使用

1. 对照随包提供的 SHA-256，再解压。把内层 `windows-proxy-doctor` 整个文件夹复制到 Codex 项目的 `.agents/skills/` 或客户端文档指定的 Skill 目录。使用源码时可直接复制仓库中的 `skills/windows-proxy-doctor` 目录。确认安装目录内直接包含 `SKILL.md` 和 `scripts/`，然后重新打开 Codex 会话。 [Codex Skills 文档](https://developers.openai.com/codex/skills) · [Agent Skills 目录规范](https://agentskills.io/specification)
2. 对 Agent 说「用 Windows Proxy Doctor 检查我的网络」或「帮我准备代理设置」。说明现有网络是否有故障即可。Agent 会先用当前权限读取环境。你也可以说「检查我的网络，保持原配置」，只检查已有设置。
3. 看到需要你操作的步骤时，核对改动、涉及的费用或权限、预期结果和回退方式。拒绝安装或改动后仍可继续诊断。账号、支付和凭据留在服务或客户端自己的界面中处理。 [新手指南](references/getting-started.md)

升级时先停止前台监测，保留原版本文件夹的副本，再把候选装入干净的 Skill 目录。重新加载并跑一次只读检查。需要退回时换回原目录。卸载时停止监测并从客户端移除该 Skill 文件夹，私人检查点或备份按自己的保留计划处理。 [升级、卸载与回退](references/getting-started.md#升级卸载与回退)

## 高级命令

从 Skill 目录以当前用户运行。使用 Windows PowerShell 5.1 或受支持的更新版本。如系统执行策略阻止脚本，由管理员或用户按本机既有策略处理。

```powershell
powershell.exe -NoProfile -File .\scripts\Start-ProxyDoctor.ps1 -Goal Auto -Json
powershell.exe -NoProfile -File .\scripts\Start-ProxyDoctor.ps1 -Goal Diagnose -NetworkStatus Broken -Json
powershell.exe -NoProfile -File .\scripts\Get-ProxyDoctorEnvironment.ps1 -Json
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -File .\tests\Run-OnboardingTests.ps1
powershell.exe -NoProfile -File .\tests\Run-FaultClassTests.ps1
powershell.exe -NoProfile -File .\tests\Run-RecoveryTests.ps1
```

当前环境发现不要求指定端口。旧版的独立 Snapshot 和 Watch 脚本保留自身参数默认值。使用它们前，确认 `-MixedPort` 和可选 `-FirstHopPort` 与本机监听一致。Snapshot 的保存意图来自标准用户配置位置，可执行程序位置、代理规则和应用行为需独立确认。 [环境发现](references/environment-discovery.md)

    powershell.exe -NoProfile -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -Json
    powershell.exe -NoProfile -File .\scripts\Get-ProxyDoctorSnapshot.ps1 -IncludeWriterEvidence -Json
    powershell.exe -NoProfile -File .\scripts\Test-ProxyConsistency.ps1 -SnapshotFile .\examples\snapshot-mismatch.json

在用户选择并确认目标后，用向导的 `-VerifyUrl` 测量当前系统代理路径上的 HTTPS。高级工具 `Test-NetworkPath.ps1` 支持显式代理或直连探测，分别报告代理 CONNECT、TLS、HTTP 或 DNS 的观测结果。现有浏览器会话、UDP、IPv6 和其他应用各有自己的路径。 [故障处理手册](references/troubleshooting.md)

## 三种模式

| 模式 | 做什么 | 写系统代理 |
| --- | --- | --- |
| 只读诊断 | `Start-ProxyDoctor.ps1`、Snapshot、Lifecycle 观察等，只读本机状态并给证据 | 不写 |
| 隔离演练 | `recovery\Invoke-Recovery.ps1` 调随包 `engine\scripts\Invoke-IsolatedRecovery.ps1`，在 `%TEMP%` 一次性目录里以 `V4_TEST_MODE=1` 跑一次回滚 | 不写 |
| 需要授权的真实操作 | 安装、启动/停止客户端、改配置、清理数据：每次单独授权，由用户执行 | 由用户决定 |

真实生产写入未实现。`V4_TEST_MODE` 是进程内逻辑隔离，不是操作系统沙箱。

隔离演练要一句与本次操作绑定的确认短语。先不带短语运行一次，把打印出来的授权清单原样给用户看；用户明确同意后，再把它打印的短语原样传入：

```powershell
powershell.exe -NoProfile -File .\recovery\Invoke-Recovery.ps1 -AppRoot '<随包 Desktop/CLI 目录>'
powershell.exe -NoProfile -File .\recovery\Invoke-Recovery.ps1 -AppRoot '<随包 Desktop/CLI 目录>' -ConfirmPhrase 'RECOVER-ISOLATED 127.0.0.1:7897' -Json
```

短语错误、目标不同、空值或 `--yes` 都会被拒绝（exit 1，`ScriptStarted=false`），拒绝后仍可继续只读诊断。判定仍由 `scripts/RecoveryVerdict.ps1` 的 `CompleteSuccess` 负责。

## 观察重连

在 Skill 目录启动前台观察器。达到指定样本数后退出，也可按 Ctrl+C 停止。指定首跳端口可独立观察第二个客户端，单客户端场景可省略此参数。

    powershell.exe -NoProfile -File .\scripts\Watch-ProxyLifecycle.ps1 -Samples 24 -IntervalSeconds 5
    powershell.exe -NoProfile -File .\scripts\Watch-ProxyLifecycle.ps1 -IncludeWriterEvidence -Json

`LOCAL_READY` means the sampled local components agree. Supply `-HealthUrl` and optionally a distinct `-ApplicationUrl` to run HTTPS probes through the verified IPv4 mixed listener. Use endpoints you intend to contact and expect to succeed. `HTTPS_PROBE_OK` covers those endpoints through the explicit loopback path. An application may follow another path. The probe budget is up to two requests of 12 seconds each per sample, in addition to local collection and the interval. Default monitoring sends no HTTP or DNS probes.

控制台报告确认的状态转变及代理或监听变化。同一故障连续观察到两次才提示。`-Json` 每次采样输出一条记录，代理变化时包含采样前后状态。监听进程变化可用于对照时间线，实际写入者、上游节点和用户意图需要独立证据。主动操作界面的时间应单独记录。`PROXY_DISABLED` 与 `OTHER_PROXY_SELECTED` 是状态提示。`-IncludeWriterEvidence` 可查找从上次注册表读取开始到本次读取结束期间的已有事件，覆盖范围取决于日志和采样条件。

## Windows 设置写入证据

The opt-in command reads up to 1,000 matching event IDs per log from the past 15 minutes. It selects monitored values under the current user's Internet Settings key and its default connection settings. Output includes the time, field, executable basename, and available process and record IDs. Existing logging, access, and retention determine coverage. An empty or unavailable result leaves the writer unknown. A recorded event identifies an operation on the setting. Compare its time and record ID with local evidence before associating it with a particular incident. [Security 4657](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4657) · [Sysmon Event 13](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon#event-id-13-registryevent-value-set)

Snapshot 只报告 PAC 地址是否存在。诊断实际选路时，需单独核对每条连接、WPAD、策略及应用自己的设置。

## 安装包检查

从官方发布渠道独立取得 SHA-256 或已知发布者证书指纹。脚本只读取已下载文件，比较摘要和 Windows Authenticode 结果。

```powershell
$officialRelease = 'https://example.com/releases'
$officialSha256 = '<the SHA-256 published by the vendor>'
.\scripts\Test-ProxyDoctorInstaller.ps1 -InstallerPath .\downloaded-installer.exe -SourceUrl $officialRelease -ExpectedSha256 $officialSha256 -Json
```

`MATCHES_EXPECTED` 表示文件与提供的官方基准相符。`UNVERIFIED` 或 `REJECTED` 时停止安装，可继续只读诊断。发布页面真实性及操作授权仍需分别核实。 [Microsoft Authenticode 命令文档](https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature)

许可证见 [MIT 许可](LICENSE)。更多内容见 [变更日志](CHANGELOG.md)、[安全说明](SECURITY.md)和[历史现场观察](references/lifecycle-observations.md)。
