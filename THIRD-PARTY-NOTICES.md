# Third-party notices / 第三方许可声明

审查日期：2026-11-25。本文为源代码级初步依赖清单，不是已构建发行物的完整 SBOM 或最终再分发合规证明。各组件保留其原始许可证；CAB 的 Apache-2.0 不覆盖第三方软件。

## 直接依赖（Desktop 候选 `ec92e36`）

| 组件 | 版本 | 许可证 | 用途与来源 |
| --- | --- | --- | --- |
| .NET / WPF / Windows Forms | .NET 8 | MIT 为主；具体发行物存在单独许可和第三方声明 | 运行时及 UI；[.NET 许可说明](https://github.com/dotnet/core/blob/main/license-information.md) · [Windows 发行物说明](https://github.com/dotnet/core/blob/main/license-information-windows.md) · [WPF LICENSE](https://github.com/dotnet/wpf/blob/main/LICENSE.TXT) · [WPF notices](https://github.com/dotnet/wpf/blob/main/THIRD-PARTY-NOTICES.TXT) |
| CommunityToolkit.Mvvm | 8.3.2 | MIT | [NuGet 包](https://www.nuget.org/packages/CommunityToolkit.Mvvm/8.3.2) |
| Microsoft.NET.Test.Sdk | 17.11.1 | MIT | 开发测试；[NuGet 包](https://www.nuget.org/packages/Microsoft.NET.Test.Sdk/17.11.1) |
| xunit | 2.9.2 | Apache-2.0 | 开发测试；[NuGet 包](https://www.nuget.org/packages/xunit/2.9.2) |
| xunit.runner.visualstudio | 2.8.2 | Apache-2.0 | 开发测试；[NuGet 包](https://www.nuget.org/packages/xunit.runner.visualstudio/2.8.2) |

以上为直接 PackageReference 与 SDK 核查结果；不推定所有传递依赖都使用相同许可。发布 self-contained Windows 二进制时，应按实际 runtime pack 和打包内容保存随包许可、版权及第三方声明。测试依赖若不进入发行物，不应被描述为运行时组件。

## 独立外部软件与服务

- Clash Verge Rev：[GPL-3.0](https://github.com/clash-verge-rev/clash-verge-rev)。当前 Desktop 第三方声明将其列为未编入 CAB 的外部软件；其许可不因 CAB 的根许可而改变。
- Mihomo：[上游仓库及许可证](https://github.com/MetaCubeX/mihomo)。应按实际使用的上游版本核对许可证；不把上游程序、修改版或源码并入 CAB 的 Apache-2.0 授权。
- StarSky、NexIP：独立第三方软件或商业服务；其软件、账户、订阅和服务受各自厂商条款约束。CAB 不授予其再分发权、账户资格或商标权。
- Portmaster、WireGuard for Windows、Tauri、WPF-UI：候选文档中的研究对象；据现有 Desktop 声明未编入应用。后续如实际引入，应核对对应版本、源码、许可证与分发义务。
- PowerShell、Python、Windows 系统 API：运行环境或外部工具，不因调用而自动变成 CAB 源代码的一部分；随发行物实际分发时另行核验相关许可。

调用独立进程与将其代码链接、复制或组合分发并不等同。若未来引入 GPL 代码或打包 GPL 组件，须按具体集成方式重新审核义务，不得仅凭 Apache-2.0 根文件宣布兼容。

## 图片、配置与历史证据

第三方产品截图、商标、供应商素材、外部配置、日志及历史测试数据不是一概可自由再许可的 CAB 原创软件。各自权利与隐私义务保留；不要据根许可证推断可重新发布任何敏感信息或第三方资产。

## 发布前检查

1. 在冻结的发行提交上列出直接及传递依赖、实际版本与来源。
2. 核对 NuGet 恢复产物、runtime pack、安装器、字体、图标、脚本及二进制文件。
3. 将实际分发依赖的完整许可、版权和 NOTICE 随源码或发行物保存；生成 SBOM。
4. 对复制、修改或移植的上游代码保留原始声明，记录来源、版本和修改内容。
5. 不确定版权归属、许可兼容性或分发权时，先停止发布相应文件并解决问题。

本文件不替代上游许可证，也不是法律意见。
