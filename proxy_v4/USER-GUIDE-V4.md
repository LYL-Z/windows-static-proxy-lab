# USER-GUIDE-V4

## 日常

```powershell
# 状态（只读）
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\state-v4.ps1

# 应用（StarSky 需在"加速中"）
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\apply-v4.ps1

# 回滚
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\rollback-v4.ps1 -List
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\rollback-v4.ps1
```

## 首次/重装

```powershell
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\apply-v4.ps1 -Init
```
（从当前 Clash 配置一次性迁移到 `config\settings.json`，密码以 DPAPI 加密保存）

## 退出码

`apply-v4`：0 成功 / 11 设置 / 20 第一跳 / 30 启动超时 / 31 链路验证 / 32 系统代理 / 33 锁占用 / 40 还原失败
`rollback-v4`：0 / 40 失败 / 41 系统代理未能保持
V6.8 候选的 `state-v4` 用退出码 2 表示部分验证（含 `CHAIN_VERIFIED` 和 `DEGRADED`），用 3 表示失败或未知。脚本观察单条 IPv4 HTTPS 样本，实际应用路径需要单独验收。

## 权限与风险

- 全部以**当前用户**运行，不需要管理员；不写 HKLM、不改任务计划、不动防火墙。
- 唯一系统改动是 HKCU 的 WinINET 代理与 Clash 配置文件。
- `settings.json` 含 DPAPI 密文，泄漏后仅同用户可解；仍建议限制目录访问。
- **不要**把 `proxy_v4` 放到共享/同步盘。

## V6.8 故障告警和操作顺序

可以直接用候选脚本读取现有配置。以下例子从包含 `publish` 和 `proxy_v4` 的工作区运行。监测在前台执行，Ctrl+C 停止。采样包括显式代理的 HTTPS 出口探测。

```powershell
powershell.exe -NoProfile -File .\publish\proxy_v4\state-v4.ps1 -ConfigDirectory .\proxy_v4\config -Samples 3 -IntervalSeconds 5
```

收到 `PAUSE_APPLICATIONS` 或发现出口未知时，先退出要求固定出口的应用并停止相关网页活动。告警为人工操作提示。下一次采样恢复到 `CHAIN_VERIFIED` 后，先用普通站点在实际应用中复测，再恢复原活动。

| 告警证据 | 优先核对 |
| --- | --- |
| `FIRST_HOP_TCP_UNAVAILABLE` / `FIRST_HOP_CONNECT_FAILED` | 分别看 StarSky 的加速界面、本地端口和 CONNECT。记录是否自行停止。恢复监听后继续检查完整链路。 |
| `CLASH_PROCESS_NOT_OBSERVED` / `CORE_LISTENER_UNVERIFIED` | 核对 Clash 界面与核心监听。先检查是否有人主动退出。 |
| `SYSTEM_PROXY_DRIFT` / `AUTOMATIC_PROXY_UNVERIFIED` | 核对 Windows 的目标、是否启用自动代理，以及应用选路。确认实际意图后再处理。 |
| `CHAIN_EXIT_UNVERIFIED` / `EXIT_MISMATCH` | 暂停使用该路径，检查出站规则、上游和测量端点。需要独立实测才能归因给供应商。 |

`-Repair` 是单次人工操作。候选在写入前后核对预期核心监听，拒绝覆盖无法确认的自动代理状态。回退验证失败返回 40，应保留现场。需要改动生产或重启客户端时，先获得相应授权；故障注入只在隔离环境执行。`-Json` 可能包含网络地址，保存到私人目录。

## V6.9 候选的单次修复与中断处理

先运行候选的只读状态命令。只有确认 Windows 手动代理已经启用、目标意外改为已知首跳，而且希望恢复到原 Clash 端口时，才授权一次 `apply-v4.ps1 -Repair`。修复会核对保存的开关、IPv4 监听进程的映像路径、配置标记以及写入前后的出口样本。用户主动关闭代理、选择其他端口或启用自动代理时，脚本会停止。每次授权最多写入一次目标，必要时尝试一次回退。

修复前会在当前用户的本地应用数据目录写入仅含两个回环目标和操作编号的恢复记录。若出现 `REVIEW_INTERRUPTED_REPAIR` 或退出码 34，请查看当前代理选择，保持相关应用暂停。以下两个命令都需要用户选定并授权。

- `apply-v4.ps1 -ResolveRepair KeepCurrent` 确认保留当前选择，清除这次记录。
- `apply-v4.ps1 -ResolveRepair RestorePrevious` 核对现有选择后恢复上一次记录的端口。用户已关闭代理或改选其他目标时会拒绝写入。退出码 40 表示回退未确认，保留记录待核查。

处理完中断记录后，重新运行只读状态命令，并在实际应用中向中性端点复测。旧版脚本及其他软件不读取该记录；正式换版前需保证所有写入入口使用同一候选版本。

## V6 安全警告

- `-Init` 已不接受命令行密码；显式迁移改用 `-CredentialFile <受保护文件>`。旧的 `-StaticPass`/`-StaticPassFile` 会被拒绝。优先从当前 Clash profile 迁移。
- 凭据文件需先加固 ACL：`. .\lib\V4.ps1; Protect-V4Acl -Path .\credential.txt`；未加固会被拒绝（ACL is not hardened）。
- `backup/` 快照含明文代理凭据；ACL 已加固但未加密，不要上传或共享。
- 真实 apply 前先 `-DryRun`；失败时不要手工删除 `config\transaction.json`，先看 ISSUE-LEDGER/R2A-06。
