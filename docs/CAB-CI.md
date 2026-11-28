# CAB CI

Windows GitHub Actions 覆盖可以在托管 runner 上独立完成的部分。工作流不读取生产凭据，也不使用仓库 secrets。

## 自动

`.github/workflows/cab-windows.yml` 在 push、pull_request 和 workflow_dispatch 时于 `windows-latest` 运行：

- `core-tests`：对 `desktop/tests/ProxyDoctor.Core.Tests` 执行 `dotnet test`。这是 Desktop 和 CLI 共用的 Core 测试。
- `skill-tests`：用 runner 自带的 Windows PowerShell 5.1 运行 `skills/windows-proxy-doctor/tests/Run-Tests.ps1`、`Run-FaultClassTests.ps1` 和 `Run-OnboardingTests.ps1`。若安装了 `pwsh`，同一组脚本再运行一次，并打印该版本。
- `secret-scan`：在已跟踪文件中查找 PRIVATE KEY 块。失败时只列出路径，不打印文件内容。

## 手动

`.github/workflows/cab-v69-seal.yml` 只在 workflow_dispatch 时运行 `proxy_v6/tests/repro/V69SnapshotSeal.ps1`。

114 项引擎套件 `proxy_v6/tests/Run-Tests.ps1` 保持手工执行，不进入 CI。
