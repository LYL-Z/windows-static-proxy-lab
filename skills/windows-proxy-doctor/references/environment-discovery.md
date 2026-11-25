# 环境发现与证据解释

运行 `scripts/Get-ProxyDoctorEnvironment.ps1 -Json`，或通过 `Start-ProxyDoctor.ps1` 进入向导。以当前用户身份运行。支持 Windows PowerShell 5.1 及更新版本。该步骤收集本地环境、权限、软件与监听证据。诊断包无需安装网络驱动，也无需预设另一台电脑的目录或端口。

| 发现内容 | 如何解释 |
| --- | --- |
| Windows、体系结构、PowerShell 及管理员状态 | 用来匹配下载包及判断哪些只读项能访问。64 位硬件也可能运行 32 位 PowerShell。普通用户可完成基本检查。 |
| 安装清单与运行进程 | 安装证据与运行证据分别判断。运行中的文件可能来自便携版，安装登记也可能已经失效。当前用户和机器级记录可见性不同，其他用户、非标准目录和受限进程仍可能未知。 |
| Clash Verge、Mihomo、StarSky、浏览器及其他可识别客户端 | 软件名称和证据范围来自当前机器。已识别的软件无需重复安装。`UNKNOWN` 表示证据不足，先请用户定位现有软件或查看安装状态。 |
| Windows 手动代理和 PAC 是否配置 | 一种可观察到的系统设置。PAC 是可按目标选择路径的代理脚本，配置了它就需要用实际应用和目标验证。企业策略、自动检测、浏览器或应用自己的设置可能改变最终路径。 |
| WinHTTP | 这是某些应用和系统组件使用的另一套代理配置，单独读出。不能用它推断浏览器走的路径。读取失败时保留未知。 |
| 监听端口和所属进程 | 同一进程可监听多个端口。只有核对进程所有者才把端口关联到软件。环回地址只从本机访问。端口查询受当前会话权限限制。 |
| Browser 和 Desktop 工具 | 由 Agent 在本次会话核实后显式报告。发现浏览器应用无法推断 Agent 能否操作它。缺少工具时提供人工步骤。 |

软件发现与可用性需要独立证据。使用现有 `Get-ProxyDoctorSnapshot.ps1` 和 `Test-ProxyConsistency.ps1` 对照关心的端口与客户端保存意图。必要时用经过用户同意的 `-VerifyUrl` 或独立 `Test-NetworkPath.ps1` 验证实际目标。端口探测成功、代理握手成功和站点访问成功各有不同范围。 [分层架构](architecture.md)

如果原生客户端界面显示一个自定义端口，环境发现可用 `-CheckPort` 核对该端口。判断端口冲突时，应先确认目标程序是否负责该监听，然后比较实际所有者。

### 安装包来源与兼容性

先核对本机 Windows 和系统架构，再从厂商页查看当前版的兼容性及正确文件。Clash Verge 和独立 Mihomo 是不同组件。现有 Clash Verge 可能已包含所需的 Mihomo 核心，先确定需求再决定是否另装。StarSky 的 Windows 下载页由厂商提供，实际包仍须逐件核验。 [Clash Verge 发布页](https://github.com/clash-verge-rev/clash-verge-rev/releases) · [Mihomo 发布页](https://github.com/MetaCubeX/mihomo/releases) · [StarSky 官方入口](https://skystars.top/)

下载前确认来源和权限。运行前验证发布者的有效签名，或对照厂商通过可信渠道公布的该文件 SHA-256。每个步骤分别请求授权。来源不明、重定向目标异常、签名发布者不符、哈希不匹配或验证依据不足时，保留待核实状态。 [Microsoft 签名核验](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature?view=powershell-5.1) · [SHA-256 检查](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1)
