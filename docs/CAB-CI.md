# CAB CI

Windows GitHub Actions 覆盖可以在托管 runner 上独立完成的部分。工作流不读取生产凭据，也不使用仓库 secrets。

## 自动

`.github/workflows/cab-windows.yml` 在 push、pull_request 和 workflow_dispatch 时于 `windows-latest` 运行：

- `core-tests`：对 `desktop/tests/ProxyDoctor.Core.Tests` 执行 `dotnet test`。这是 Desktop 和 CLI 共用的 Core 测试。
- `packaging-tests`：用 Windows PowerShell 5.1 运行 `desktop/packaging/Test-InstallProxyDoctor.ps1`。用例只在 GUID 命名的 TEMP 沙箱里安装、卸载，并证明启动项和系统代理指纹没有变化；复制中断是通过从外部锁住一个源文件触发的，安装器本身没有测试开关。
- `skill-tests`：用 runner 自带的 Windows PowerShell 5.1 运行 `skills/windows-proxy-doctor/tests/Run-Tests.ps1`、`Run-FaultClassTests.ps1` 和 `Run-OnboardingTests.ps1`。若安装了 `pwsh`，同一组脚本再运行一次，并打印该版本。缺少 `pwsh` 时任务失败，不再静默降级。
- `engine-tests`：用 Windows PowerShell 5.1 实际执行 `proxy_v6/tests/Run-Tests.ps1`（F77/F53），也就是 114 项引擎回归。先确认 `Run-Tests.ps1`、`Harness.ps1`、`lib/TestSupport.ps1` 三个入口存在，再执行套件；证据写到 `$env:RUNNER_TEMP\v6-evidence\evidence.json`，失败时打印计数、非 PASS 用例和 harness/evidence 错误，然后以套件自己的退出码失败。同一 job 再跑 `proxy_v6/tests/repro/CAB-CorruptPreparationJournal.ps1`（10 条断言，隔离 TEMP 根）。超时 40 分钟。
- `secret-scan`：在已跟踪文件中查找 PRIVATE KEY 块。失败时只列出路径，不打印文件内容。

## 引擎套件的可移植性

`proxy_v6/tests/Run-Tests.ps1` 只依赖 `windows-latest` 自带的 Windows PowerShell 5.1：

- 可移植：纯 PowerShell 5.1 用例、`Harness.ps1` + `lib/TestSupport.ps1`、子进程 `powershell.exe`、隔离 TEMP 根与合成夹具；不需要 Python、.NET、管理员权限或互联网。只读调用 `netsh winhttp show proxy` 和 HKCU 读取，用来证明前后不变。
- Windows 特定：DPAPI 密封（`INF-DPAPI-01`）、ACL 与锁（`INF-ACL-01`、`INF-LOCK-*`）、`FileShare` 语义、注册表代理项读取。这些在非 Windows 宿主上不可能通过，所以这个 job 只声明 `windows-latest`。

## 手动

`.github/workflows/cab-v69-seal.yml` 只在 workflow_dispatch 时运行 `proxy_v6/tests/repro/V69SnapshotSeal.ps1`。

`proxy_v6/tests/repro/CabProtocolLocal.ps1` 与 `proxy_v6/tests/repro/cab-protocol/`（含 836 行 `protocol_probe.py`）是可选证据工具，不进入 CI，也不作为门禁；`ProtocolEvidence` 的行为由上面的 `core-tests` 覆盖。

`proxy_v6/tests/repro/v69-failclose/failclose.py`、`v69-container/check_offline.py`、`v69-program-block/program_block.py` 需要 Python 或会改防火墙规则，保持手动，见 `docs/V69-ACCEPTANCE.md`。
