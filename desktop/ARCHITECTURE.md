# 架构

桌面程序、命令行和 Skill 共用 `ProxyDoctor.Core` 里的故障分类。界面不拼接用户输入去执行 PowerShell。

- `ProxyDoctor.Core`：分类、只读采样、能力边界。
- `ProxyDoctor.Desktop`：WPF 窗口和托盘。默认 `asInvoker`。
- `ProxyDoctor.Cli`：把同一份只读结果打成 JSON。

技术选择是 C#、.NET 8 和 WPF，并使用 MIT 许可的 CommunityToolkit.Mvvm。没有引入 WinUI、Tauri 或 Electron。现有 V6.9 脚本仍负责事务回滚；桌面程序这一版只读取状态，避免第二套写入逻辑。

Clash Verge、Portmaster、WireGuard for Windows、WPF 和 CommunityToolkit 只作为结构参考。没有复制它们的源代码。
