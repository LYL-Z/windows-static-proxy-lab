# 架构

桌面程序、命令行和 Skill 共用 `ProxyDoctor.Core` 里的故障分类。恢复只调用固定脚本和两个目录参数，不把自由文本拼进 PowerShell。

- `ProxyDoctor.Core`：分类、只读采样、能力边界。
- `ProxyDoctor.Desktop`：WPF 窗口和托盘。默认 `asInvoker`。
- `ProxyDoctor.Cli`：把同一份只读结果打成 JSON。

技术选择是 C#、.NET 8 和 WPF，并使用 MIT 许可的 CommunityToolkit.Mvvm。没有引入 WinUI、Tauri 或 Electron。事务回滚仍由 V6.9 的 `rollback-v4.ps1` 执行。桌面和 CLI 只在临时测试根里调用它，不保留第二套注册表写入。

Clash Verge、Portmaster、WireGuard for Windows、WPF 和 CommunityToolkit 只作为结构参考。没有复制它们的源代码。
