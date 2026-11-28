# Desktop / CLI / Skill 真实能力审计

审计对象：`D:\claude防封\cab-integration`，分支 `integration/cab-next`，基线 `f2454c0`。
审计方式：**纯只读静态审计**。未修改源码、未构建、未运行安装器、未执行任何测试套件、未发起网络请求、未读取任何凭据。
凡本报告写「未验证」，均表示该结论需要执行才能确认，本轮**没有执行**。

审计者：`cab-surface`（子代理）。唯一写入的文件是本报告。

---

## 0. 一句话结论

三块入口都有**真实实现**，而且核心逻辑不止是静态页面：Desktop 和 CLI 共享一个真正干活的 `ProxyDoctor.Core`（真读注册表、真跑 `netstat`、真发 HTTPS 探测），Skill 是一套真正在本地采集环境的 PowerShell 脚本。

但它们拼不成一个「用户装上就能用」的产品，缺口集中在三处：

1. **`docs/CAB-INTEGRATION.md:22` 声称「回滚演示只加载随包两份对应哈希的 Engine 文件」——没有任何打包步骤把 `proxy_v4` 放进发布物**。恢复功能只在二进制仍留在仓库树内时才可用。
2. **CI 在集成分支上根本不存在**（`.github` 目录被删，只存在于一个未合并分支），且历史上任何版本的 CI 都**没有**跑过 Engine 114 项回归。
3. **Skill 完全没有恢复执行器**，只有「判定恢复结果」的脚本；三块里只有 Desktop 有能力真的启动回滚脚本。

---

## 1. Desktop：目录结构、入口、进程模型

### 1.1 目录结构（源码，已排除 `bin/`、`obj/`）

```
desktop/
├─ ProxyDoctor.sln                      4 个项目
├─ ARCHITECTURE.md  README.md  USER-GUIDE.md  REQUIREMENTS.md
├─ CLIENT-LIMITS.md  SECURITY.md  SHA256SUMS.txt  THIRD-PARTY-NOTICES.md
├─ app.manifest（在 src/ 下）           asInvoker
├─ contracts/
│  ├─ recovery-fixtures.json            25 条恢复契约夹具
│  └─ recovery-result.md                恢复判定字段定义
├─ packaging/
│  ├─ Install-ProxyDoctor.ps1           文件夹安装/卸载器（12.7 KB）
│  └─ Test-InstallProxyDoctor.ps1       安装器回归（19.0 KB）
├─ scripts/
│  └─ Invoke-IsolatedRecovery.ps1       隔离恢复包装器（7.8 KB）
├─ src/
│  ├─ ProxyDoctor.Core/                 纯逻辑层（无 UI 依赖）
│  │   ├─ Diagnosis.cs                  故障分类 FaultClassifier、RequestRouter
│  │   ├─ LiveDiagnosis.cs              注册表/监听/进程读取、HTTPS 探测、DiagnosticEngine
│  │   ├─ Checks.cs                     10 项检查 CheckRunner
│  │   ├─ MonitorEngine.cs              多通道监测状态机
│  │   ├─ Monitor.cs                    SampleGate、FaultStreak、ClientLayers
│  │   ├─ ClientLifecycle.cs            客户端生命周期 6 状态分类
│  │   ├─ ProtocolEvidence.cs           协议证据分类
│  │   ├─ Recovery.cs                   IsolatedRecovery（真正起进程跑脚本）
│  │   ├─ RecoveryTrust.cs              哈希白名单、结果判定
│  │   └─ Runtime.cs                    IntentStore、EventLog、LiveChecks
│  ├─ ProxyDoctor.Desktop/              WPF 外壳
│  │   ├─ App.xaml / App.xaml.cs        启动入口 + 托盘
│  │   ├─ MainWindow.xaml (22.6 KB)     全部界面
│  │   ├─ MainWindow.xaml.cs            窗口 + 转换器
│  │   ├─ ShellViewModel.cs (23.4 KB)   MVVM 全部命令与采样调度
│  │   └─ Themes/{Light,Dark}.xaml
│  └─ ProxyDoctor.Cli/
│      └─ Program.cs                    37 行，唯一入口
└─ tests/ProxyDoctor.Core.Tests/        5 个测试文件
```

### 1.2 入口与启动方式

| 项 | 证据 |
| --- | --- |
| 项目文件 | `desktop/src/ProxyDoctor.Desktop/ProxyDoctor.Desktop.csproj:1-25`；`OutputType=WinExe`(:3)、`UseWPF=true`(:7)、`AssemblyName=ProxyDoctor`(:11)、`Version=1.3.0`(:13) |
| 程序入口 | `desktop/src/ProxyDoctor.Desktop/App.xaml:4` `Startup="OnStartup"` → `App.xaml.cs:14-45` |
| 启动参数 | `App.xaml.cs:16-21` 解析 `--capture <path>`、`--section <name>`、`--recover` |
| 托盘 | `App.xaml.cs:27-43` `NotifyIcon` + 菜单（打开 / 只读诊断 / 退出） |
| 权限 | `desktop/src/ProxyDoctor.Desktop/app.manifest:7` `requestedExecutionLevel level="asInvoker"` |
| 构建 | `desktop/README.md:13-16`：`dotnet test .\ProxyDoctor.sln -c Release` + `dotnet publish ... -r win-x64 --self-contained` |
| 安装 | `desktop/packaging/Install-ProxyDoctor.ps1:9` `-Action Install|Uninstall`、`:256` 强制目标必须在 `-AllowedRoot` 之内 |

### 1.3 「渲染进程 / 主进程」分工——前提不成立

这个仓库**不是** Electron/Tauri 应用，没有渲染进程与主进程之分：

- `desktop/ARCHITECTURE.md:9`：「技术选择是 C#、.NET 8 和 WPF……**没有引入 WinUI、Tauri 或 Electron**」
- `desktop/src/ProxyDoctor.Desktop/ProxyDoctor.Desktop.csproj:7` `UseWPF=true`；无 `package.json`、无 `node_modules`、无 `main`/`renderer` 目录

实际的「分工」是**单进程内的三层**：

| 层 | 位置 | 职责 |
| --- | --- | --- |
| 界面层（≈渲染进程） | `MainWindow.xaml` 349 行全体 XAML | 纯声明式布局，无业务逻辑 |
| 呈现逻辑层 | `MainWindow.xaml.cs:11` `new ShellViewModel()`；`ShellViewModel.cs` 496 行 | 命令、采样调度、格式化文案 |
| 逻辑层 | `ProxyDoctor.Core`（`csproj:21` 项目引用） | 注册表/监听/进程/探测/分类/恢复 |

界面与逻辑之间是标准 MVVM 数据绑定（`MainWindow.xaml.cs:16` `DataContext = _model`），全部按钮都绑到 `ShellViewModel` 的 `[RelayCommand]`，**没有空绑定的占位按钮**（见 `MainWindow.xaml:101-108, 116, 175, 186-188, 196, 204, 218, 243-244, 263, 294, 302, 310, 323-330, 342`）。

### 1.4 它调用的是哪一层？

**不是纯 mock，也不是纯粹的「直接 PowerShell」——两层都调，且各自边界清晰：**

1. **绝大多数能力走 `ProxyDoctor.Core` 的托管代码**（真读、真探测、不发子进程）：
   - 注册表只读：`LiveDiagnosis.cs:47-51` `LiveProxyStamp()`、`:55-89` `ReadObservation()` 均用 `Registry.CurrentUser.OpenSubKey(...)`，**只读打开**
   - 监听枚举：`LiveDiagnosis.cs:237-238` + `Checks.cs:70` 注释写明「`netstat -ano`，读取 TCP 监听行，再按 PID 取进程名」
   - HTTPS 探测：`LiveDiagnosis.cs:240-265` `HttpsProbe.SampleAsync` 真发请求到 `www.baidu.com` 与 `github.com`
   - 官方状态：`Runtime.cs:116-134` GET `https://status.claude.com/api/v2/status.json`
   - 回环交换：`Runtime.cs:83-114` 真开 socket 做 TCP 回环、`:136-158` 真做 UDP 回环
   - 系统 DNS：`Checks.cs:108-129` `Dns.GetHostAddressesAsync("example.com")`
   - DoH 端点：`Checks.cs:131-156` GET `https://dns.google/resolve?...`
   - 全库 `desktop/src` 内**没有任何注册表写入 API**（`git grep SetValue|CreateSubKey|DeleteValue|InternetSetOption` 零命中），与「只读」一致

2. **恢复动作是唯一走 PowerShell 的部分**：`Recovery.cs:100` 显式构造 `WindowsPowerShell\v1.0\powershell.exe` 进程，`:114-126` 传 `-NoProfile -ExecutionPolicy Bypass -File <script> -EngineRoot ... -WorkRoot ... -ExpectedRollbackSha ... -ExpectedLibrarySha ...`。它调用的是**仓库根目录的 `proxy_v4` 引擎脚本**，不是自己实现一套。

3. **Mock 只出现在演示模式**：`LiveDiagnosis.cs:304-323` `DiagnosticEngine.Demo()` 返回固定样例（`127.0.0.1:7897` / `verge-mihomo` 等），且 UI 强制标注「演示数据，不是这台电脑的实时结果」（`ShellViewModel.cs:48` `ModeLabel`、`:325-327`）。演示开关在 `ShellViewModel.cs:50-68`。

> 结论：Desktop 是**真实现**，不是静态页面。它的「只读检查」会真的读这台机器的注册表和端口。

---

## 2. CLI 与 Skill 的入口文件与实际执行的命令

### 2.1 CLI

| 项 | 证据 |
| --- | --- |
| 项目文件 | `desktop/src/ProxyDoctor.Cli/ProxyDoctor.Cli.csproj:1-13`；`AssemblyName=proxy-doctor`(:7) |
| 入口 | `desktop/src/ProxyDoctor.Cli/Program.cs`（全文 37 行，顶层语句） |

四个实际行为：

| 参数 | 实际执行 | 证据 |
| --- | --- | --- |
| `--sentences <文本…>` | 纯字符串意图路由，不碰系统 | `Program.cs:4-10` → `Diagnosis.cs:93-148` `RequestRouter`；输出 `diagnose`/`no-modify`/`unspecified` |
| `--isolated-recovery` | **真的起 PowerShell 跑回滚脚本** | `Program.cs:12-18` → `Recovery.cs:81-177`；`CompleteSuccess` 才返回 0，否则 2 |
| `--demo` | 固定样例 JSON | `Program.cs:20-21` → `LiveDiagnosis.cs:304` |
| （无参）默认 | **真发网络请求**：HTTPS 到 baidu/github + status.claude.com + 两个回环测试 | `Program.cs:21` → `LiveDiagnosis.cs:283-302` |

退出码语义：`Program.cs:37` 故障分类为 `Unknown` 时返回 2，否则 0。

**依赖情况**：只引用 `ProxyDoctor.Core`（`csproj:11`），不依赖任何外部脚本；但 `--isolated-recovery` 依赖与 Desktop 相同的 `proxy_v4` 引擎文件与 `desktop/scripts/Invoke-IsolatedRecovery.ps1`（`Recovery.cs:54-79`），因此**继承同一个缺口**（见 §3 缺口 #1）。

### 2.2 Skill

| 项 | 证据 |
| --- | --- |
| 清单入口 | `skills/windows-proxy-doctor/SKILL.md:1-37`（frontmatter `version: 2.0.0`、`release-channel: release-candidate`） |
| 主入口脚本 | `skills/windows-proxy-doctor/scripts/Start-ProxyDoctor.ps1`（282 行） |
| 调用方式 | `SKILL.md:18`：`scripts/Start-ProxyDoctor.ps1 -Json`，`-Goal Setup|Diagnose|Auto` |

`Start-ProxyDoctor.ps1` 实际做了什么（全部为只读采集 + 状态机推导，不发修改动作）：

| 步骤 | 证据 |
| --- | --- |
| 加载同目录依赖 | `:21-22` 点源 `ProxyDoctorVerification.ps1`、`ProxyFaultClass.ps1` |
| 环境发现 | `:128-129` 调 `Get-ProxyDoctorEnvironment.ps1 -AsObject`（真读注册表/进程/监听，`:52-196` 共 10 个函数） |
| 生成诊断信号 | `:131-158` 11 分支 `signal`（`PAC_PRESENT`/`LISTENER_MISSING`/`POSSIBLE_OWNER_MISMATCH`/`SAVED_SYSTEM_STATE_DIFFER`/`UNKNOWN_LOCAL_STATE` 等） |
| 故障分类 | `:268` `Get-ProxyDoctorFaultClass`（定义在 `ProxyFaultClass.ps1:86`） |
| 可选 HTTPS 验证 | `:62-80` `Measure-DoctorWebAccess`，`:85` 每次最多 2 站，`:86-93` 只允许无凭据/无查询/无片段的 https |
| 检查点原子写 | `:50-60` `Save-DoctorCheckpoint`（临时文件 + `File.Replace`），`:244-256` 写失败降级 `WRITE_FAILED` 不中断会话 |

**其它脚本入口**（`README.md:18-23, 28-30, 38-39, 58` 所列举的）全部存在，无悬空引用：

`Get-ProxyDoctorEnvironment.ps1`、`Get-ProxyDoctorSnapshot.ps1`、`Test-ProxyConsistency.ps1`、`Test-NetworkPath.ps1`、`Watch-ProxyLifecycle.ps1`、`Test-ProxyDoctorInstaller.ps1`、`RecoveryVerdict.ps1`、`Test-Skill.ps1`、`ProxyDoctorVerification.ps1`、`ProxyFaultClass.ps1`、`Protect-Backup.ps1`、`Unprotect-Backup.ps1`、`ProxyRegistryEvents.ps1`、`ProxyListeners.ps1`、`ProxyTarget.ps1`、`NetworkPathResult.ps1`。

**关键缺口：Skill 没有恢复执行器。** `skills/windows-proxy-doctor/scripts/RecoveryVerdict.ps1:1-5` 自己的头注释就写明：

> `Judges an isolated recovery result. A transaction exit code alone is not success.` / **`This does not run rollback and does not read the live Windows proxy.`**

`git grep 'rollback-v4|apply-v4|state-v4|proxy_v4' -- skills` 只命中两处**文档提及**（`SKILL.md:33`、`references/v1-v6-lessons.md:19`），**没有任何一行代码调用引擎脚本**。

---

## 3. 主表：能力 × {Desktop, CLI, Skill} × 真实状态

状态取值：**可用** = 有真实实现且已接到入口；**未接线** = 有代码但没有接到任何入口；**仅界面** = 只有文案/恒定量/占位；**不存在** = 该入口没有这项能力。

| # | 能力 | Desktop | CLI | Skill | 关键证据（路径:行） |
| --- | --- | --- | --- | --- | --- |
| 1 | 只读环境发现（系统代理 / 进程 / 回环监听） | **可用** | **可用** | **可用** | `LiveDiagnosis.cs:47-89`；`Program.cs:21`；`Start-ProxyDoctor.ps1:128-129` + `Get-ProxyDoctorEnvironment.ps1:52-196` |
| 2 | 故障分类 / 状态判定（7 类） | **可用** | **可用** | **可用** | `Diagnosis.cs:44-84`（C#）；`Program.cs:26-27,37`；`ProxyFaultClass.ps1:86-144`（PS，同 7 类） |
| 3 | 上游 HTTPS 探测（状态码 + 耗时） | **可用** | **可用** | **可用（按需）** | `LiveDiagnosis.cs:240-265`、`ShellViewModel.cs:152-157`；`LiveDiagnosis.cs:288`；`Start-ProxyDoctor.ps1:62-80,204` |
| 4 | DNS 探测 | **可用** | **不存在** | **可用** | `Checks.cs:108-129`（Desktop）；CLI 的 `ReadLiveAsync` 不含 `CheckRunner`（`LiveDiagnosis.cs:283-302`）；`Test-NetworkPath.ps1:49-54,68` |
| 5 | DoH 端点探测 | **可用** | **不存在** | **不存在** | `Checks.cs:131-156`；CLI/Skill 无对应实现（Skill 仅文档 `references/`） |
| 6 | IPv4 / IPv6 / UDP 回环 | **可用** | **部分可用**（IPv4+IPv6 有，UDP 无） | **不存在** | `Runtime.cs:83-158`、`Checks.cs:40-42`；`LiveDiagnosis.cs:294-295`（CLI 只调两次 `Loopback`，无 `UdpLoopback`）；Skill `Test-NetworkPath.ps1:3` 明写 `UDP/WebRTC is not probed` |
| 7 | WebRTC 检测 | **仅界面**（恒返回 `NotVerified`） | **不存在** | **仅界面**（文档说明不探测） | `Checks.cs:47-49` 写死「这次没有启动浏览器，也没有接收端计数」；`LiveDiagnosis.cs:297` 同；`references/reliability-gaps.md:51` |
| 8 | 持续监测（定时采样 / 暂停 / TTL / 抖动计数 / 托盘告警） | **可用** | **不存在** | **可用**（前台 `Watch-ProxyLifecycle`） | `MonitorEngine.cs:70-272`（真实状态机：`LocalHeartbeat` 20 s、`UpstreamHttps` 90 s、`Protocol` 15 min TTL，`:89-99`）；调度 `ShellViewModel.cs:93-172`；告警 `ShellViewModel.cs:372-384` + `App.xaml.cs:24-25`；Skill `Watch-ProxyLifecycle.ps1:42,64` |
| 9 | 事件持久化 + 用户意图记录 | **可用** | **不存在** | **可用**（检查点 JSON） | `Runtime.cs:7-46` `IntentStore`（`%LOCALAPPDATA%\ProxyDoctor\intent.json`）、`:48-79` `EventLog`（`events.jsonl`，200 条上限）；`ShellViewModel.cs:301-317`；`Start-ProxyDoctor.ps1:31-60` |
| 10 | 隔离恢复**演练**（跑真回滚脚本 + 完整证据判定） | **可用**（演练级） | **可用**（演练级） | **不存在**（只有判定器） | `Recovery.cs:81-177` 真起 `powershell.exe`；`Invoke-IsolatedRecovery.ps1:90-156` 哈希校验+注入 stub；判定 `RecoveryTrust.cs:77-142` / `RecoveryVerdict.ps1:48-85`；**Skill 无执行器**（`RecoveryVerdict.ps1:4` 自述） |
| 11 | 真实恢复动作（把用户系统代理改回原值） | **不存在** | **不存在** | **不存在** | 全部三入口都只跑「临时根 + `V4_TEST_MODE=1` + stub 注册表写入器」的固定夹具（`Invoke-IsolatedRecovery.ps1:65,93-96,109-126`），`RecoveryTrust.cs:68` 把期望写入硬编码为 `enabled=0 server=old:8080` |
| 12 | 客户端重连 / 重启 StarSky·Clash | **不存在** | **不存在** | **不存在** | `ClientLifecycle.cs:24-30` `LimitNote` 明写无受支持接口；`CLIENT-LIMITS.md:24-46` 逐条列已排除来源；`ClientLifecycle.cs:32-42` 只做分类 |
| 13 | 生产级失败关闭 / 整机阻断 | **仅界面**（能力目录恒为未验证） | **不存在** | **不存在** | `LiveDiagnosis.cs:30-41` `CapabilityCatalog` 全部 `Partial`/`NotVerified`——且该类型**未被任何代码调用**（见 §5）；`REQUIREMENTS.md:7,12` 自评「未验收」 |
| 14 | 安装 / 卸载 | **可用**（文件夹级） | **不存在** | **可用**（复制文件夹） | `Install-ProxyDoctor.ps1:132-252`（拒绝覆盖、拒绝重解析点、拒绝 Startup、卸载比对哈希）；`README.md` Skill 安装 = 复制目录 + `Test-Skill.ps1` |
| 15 | 结构化 JSON 输出 | **不存在** | **可用** | **可用** | `Program.cs:22-36`（完整 payload）；`Start-ProxyDoctor.ps1:270` `ConvertTo-Json -Depth 10` |
| 16 | 回归测试可执行入口 | **可用**（81 例） | 同 Core | **可用**（3 个 runner） | `desktop/ProxyDoctor.sln` 含 `ProxyDoctor.Core.Tests`；实测算例 = 81（见 §4.2）；`skills/.../tests/Run-Tests.ps1`、`Run-OnboardingTests.ps1`、`Run-FaultClassTests.ps1` |
| 17 | CI 自动回归 | **不存在** | **不存在** | **不存在** | 见 §4：`.github` 在 HEAD 与集成分支上不存在 |

### 3.1 三类能力的真实实现位置（任务第 3 项）

| 能力类 | 真实实现位置 | 判定 |
| --- | --- | --- |
| **故障监测** | `desktop/src/ProxyDoctor.Core/MonitorEngine.cs:70-272`（多通道状态机）+ `ShellViewModel.cs:93-172`（20 s/90 s 调度、`NetworkAddressChanged` 补测、`_busyGate` 防重入）；Skill 侧 `Watch-ProxyLifecycle.ps1:42-64` | **已接线可用**（Desktop / Skill）；CLI 无此能力 |
| **状态判定** | `Diagnosis.cs:44-84` `FaultClassifier`（7 类，带 fail-closed 的 `Unknown` 兜底）、`ClientLifecycle.cs:52-60`、`ProtocolEvidence.cs:217-294`；Skill 侧 `ProxyFaultClass.ps1:86-144` 独立实现同一套 7 类 | **已接线可用**（两个实现互为镜像，见缺口 #5） |
| **恢复动作** | `Recovery.cs:81-177` → `desktop/scripts/Invoke-IsolatedRecovery.ps1:1-157` → `proxy_v4/rollback-v4.ps1` + `proxy_v4/lib/V4.ps1` | **Desktop/CLI 已接线可用，但仅限固定夹具演练**；Skill **不存在**；「真实恢复用户状态」三块都**不存在** |

### 3.2 校验：三个哈希白名单是真的

`RecoveryTrust.cs:10-12` 硬编码三个 SHA-256。本轮实测：

| 文件 | 期望（`RecoveryTrust.cs`） | 实测 | 结论 |
| --- | --- | --- | --- |
| `proxy_v4/rollback-v4.ps1` | `04EDBA1C…D951EEE9` | `04edba1c…d951eee9` | **匹配** |
| `proxy_v4/lib/V4.ps1` | `4D41D4D6…5BABCC7D` | `4d41d4d6…5babcc7d` | **匹配** |
| `desktop/scripts/Invoke-IsolatedRecovery.ps1`（LF 归一化后） | `6F0EA61E…191C9999` | `6f0ea61e…191c9999` | **匹配** |

所以恢复链路不是「有代码但哈希对不上」——哈希是对的，**缺的是把文件送到用户机器上**。

---

## 4. CI 实际跑了什么

### 4.1 结论：集成分支上没有任何 CI

```
git ls-files | grep .github        → 零命中
git cat-file -e HEAD:.github/workflows/cab-windows.yml
  → fatal: path '.github/workflows/cab-windows.yml' does not exist in 'HEAD'
```

`docs/CAB-INTEGRATION.md` 通篇没有 CI 声明；`README.md:307` 自己承认：

> 上述为各工作线已有测试记录，**不是合并后主支的统一 CI 结果**。本次主支文档整合没有重新执行 Windows 测试。

### 4.2 CI 曾经存在过，然后被删了

`.github/` 只活在一个**未合并分支** `cab/b-actions`（`+ cab/b-actions`、`remotes/origin/cab/b-actions`），**不是 HEAD 的祖先**（`git merge-base --is-ancestor 4703752 HEAD` → exit 1）。演变：

| 提交 | 动作 |
| --- | --- |
| `4f61d58` | 新增 `.github/workflows/cab-v69-seal.yml`、`cab-windows.yml`（标题即「Add Windows CI for Core and skill tests **without the engine harness**」） |
| `ccc1c51` | 新增 `cab-desktop.yml`、`cab-engine.yml`、`cab-skill.yml` |
| `4018c29` | **删除** `cab-desktop.yml`、`cab-engine.yml`、`cab-skill.yml`（标题：「Remove overlapping Windows workflows that miss the requested checks」） |
| `4703752` | 修 `cab-windows.yml` 的引号 |

### 4.3 唯一现存的 workflow 到底跑什么（`cab/b-actions:.github/workflows/cab-windows.yml`）

三个 job：

1. `core-tests`：`dotnet test desktop/tests/ProxyDoctor.Core.Tests/…csproj --configuration Release`
2. `skill-tests`：强制用 `System32\WindowsPowerShell\v1.0\powershell.exe` 跑 `Run-Tests.ps1`、`Run-FaultClassTests.ps1`、`Run-OnboardingTests.ps1`，并校验 `$PSVersionTable.PSVersion.Major -eq 5`
3. `secret-scan`：`git grep -l -E` 扫 `BEGIN…PRIVATE KEY`，只打印路径不打印内容

**是否真跑 Engine 回归？不跑。** 文件头注释原文：

> `This file does not call proxy_v6/tests/Run-Tests.ps1.` / `That 114-case engine harness stays manual: it is long and environment-heavy.`

**PowerShell 7 缺失时的行为**：优雅跳过，不算失败。

```yaml
if (-not $command) {
  Write-Host 'pwsh is not installed. Second skill run skipped.'
  exit 0
}
```

注意这里有个**方向性**结论：整个仓库所有脚本都是 `#Requires -Version 5.1`，`proxy_v4/DEPENDENCY-LOCK.md:8` 明写「PowerShell 5.1.26100 / **不使用 PS7 语法**」，`proxy_v6/DECISION-LOG.md:12` 记录「**无 pwsh**」。本机实测也一致：`pwsh` → NOT FOUND，`powershell` → 5.1.26100，`dotnet` → 8.0.422。**PS7 从来不是运行时依赖，缺失不影响任何入口**；CI 里那一步只是「有就多跑一遍」的加测。

### 4.4 被删掉的 engine workflow 也不是 114 项回归

`ccc1c51:.github/workflows/cab-engine.yml` 头注释：

> `This job is a bounded check. It is not the 114-case engine harness, and a green run must not be reported as 114/114.` / `The full harness remains a local gate: powershell.exe … -File proxy_v6/tests/Run-Tests.ps1`

且脚本缺失时它 `exit 1` 并打印「This is not a pass of the 114-case harness」。

**所以：114 项 Engine 回归从来没有、也仍然没有 CI 覆盖，只能手工跑。**

### 4.5 关于「114」这个数字本身

- `proxy_v6/TEST-MATRIX.md:4`（2026-11-18）写的是 **97 用例 / 94 通过**
- `docs/V69-ACCEPTANCE.md:18,29` 与 `proxy_v6/RELEASE-GATE-V6.md:3` 写 `171d060` / `52df351` 为 **114/114**
- 两个提交在本仓库都存在（`171d060`、`52df351`，均 2026-11-25）
- `DESKTOP 与 CLI 共用的 Core` 81 项：**本轮静态核算吻合**——5 个测试文件共 `[Fact]` 60 + `InlineData` 21 = **81** 例（`ClassifierTests` 21+12、`ClientLifecycleTests` 8+4、`MonitorEngineTests` 12、`ProtocolEvidenceTests` 18+5、`RecoveryFixtureTests` 1）

**未验证**：所有测试本轮均**未执行**，无法确认当前 HEAD 是否仍全绿。

---

## 5. 「有代码但未接线」的具体清单

这些类型有实现、有测试，但**没有任何生产代码路径调用**：

| 符号 | 位置 | 状态 |
| --- | --- | --- |
| `CapabilityCatalog.Current()` | `LiveDiagnosis.cs:30-41` | **未接线**。隐私页读的是 `report.Capabilities`（`ShellViewModel.cs:205,342`），此方法零调用 |
| `RecoveryDrill.Run()` | `Runtime.cs:192-209` | **未接线**。这是纯内存 mock 演练（`IsolatedProxy`），生产与测试都无引用 |
| `AlertGate.ShouldNotify` | `Checks.cs:162-177` | **未接线**。真实告警走 `MonitorEngine.Record` 的 `outcome.Notify`（`ShellViewModel.cs:373-384`），此类型只被测试引用（`ClassifierTests.cs:180`） |
| `RecoveryResult.EvidenceScope` 常量 | `Recovery.cs:23-24` | 仅用于 `FormatRun` 文案，无判定作用（正常） |

另有一处「接线了但等于没接」的：

- **授权门槛形同虚设**：`Recovery.cs:85-86` 要求传入字符串**精确等于** `AuthorizationText`，看起来是个闸门。但 Desktop 与 CLI 都直接把常量传进去——`ShellViewModel.cs:247` `IsolatedRecovery.ExecuteAsync(IsolatedRecovery.AuthorizationText, …)`、`Program.cs:15` 同样。也就是说用户**点一下按钮就等于「授权成功」**，界面 `MainWindow.xaml:321` 展示的确认文字只是说明，不需要用户输入。这个检查对「防止误触」没有实际约束力。

---

## 6. 最小可交付产品（MVP）建议

目标：「用户拿过去能真的装上、跑起来、看懂结果，且知道哪些结论不能信」。**6 项以内**：

| # | 要接的东西 | 为什么是它 | 工作量判断 |
| --- | --- | --- | --- |
| **1** | **把 `proxy_v4/rollback-v4.ps1` + `proxy_v4/lib/V4.ps1` 写进发布物，并让 `FindEngineRoot()` 不依赖仓库层级** | 这是唯一挡住「装完就能用」的硬缺口。现在 `FindEngineRoot()`（`Recovery.cs:54-66`）从 `AppContext.BaseDirectory` 向上找 8 层；实测从 `bin\Release\net8.0-windows\win-x64` 要向上 **7 层**才到仓库根——**只剩 1 层余量**，且一旦装到 `%LOCALAPPDATA%` 之类位置就彻底失效，恢复按钮只会返回「没有找到哈希相符的…」（`Recovery.cs:89-90`） | 小。发布步骤加 `proxy_v4/` 复制 + `FindEngineRoot` 改成「先看 `AppContext.BaseDirectory\engine\`，再回退到向上搜索」 |
| **2** | **单个正式分发包（zip + 校验清单）** | 现在只有 `Install-ProxyDoctor.ps1`（拷文件夹）和 `SHA256SUMS.txt`（写的是本地 publish 的哈希，`SHA256SUMS.txt:5-7` 自述「publish folder is local and is not stored in git」）。用户实际拿不到一个「下载→解压→双击」的东西 | 小。一条 `dotnet publish` + 复制 `proxy_v4` + 生成清单 |
| **3** | **把 Engine 114 项回归挂进 CI，或至少挂成 `workflow_dispatch` 的手动门** | 现在三块入口都宣称「Engine 已验证」，而 CI 里**从来没有**这条。它是三块共同信任的底座（Desktop/CLI 的恢复、Skill 的判定器都基于它），却没有自动证据 | 中。`proxy_v6/tests/Run-Tests.ps1` 已存在，需要配 runner 与超时 |
| **4** | **Skill 加一个恢复执行脚本，或明确把 Skill 定位成「只诊断不恢复」** | `RecoveryVerdict.ps1:4` 自述不跑回滚；Skill 没有任何执行器。用户被引导到「恢复」这一步时会断掉。要么接上（复用 `Invoke-IsolatedRecovery.ps1`），要么在 `SKILL.md` 里把边界写死 | 小（改文案）/ 中（接执行器，需同步哈希白名单） |
| **5** | **给 Desktop 补 `--diagnose --json` 之类的一键可验证入口，或让 CLI 覆盖 DNS/DoH/UDP** | CLI 的默认路径只出 HTTPS + Claude 状态 + 两个回环（`LiveDiagnosis.cs:283-302`），**没有** `CheckRunner` 的 10 项全套。导致「CLI 输出结构化证据」这句话在 DNS/DoH/UDP 上不成立，支持工单拿不到完整证据 | 小。CLI 增加一条走 `CheckRunner.RunAll` 的分支即可复用现有实现 |
| **6** | **把 `docs/CAB-INTEGRATION.md:22` 的「随包 Engine」说法改成与事实一致** | 文档现在描述的能力比代码交付的多。这一项零成本，但直接决定用户会不会以为「装完就有恢复」 | 极小 |

**不建议现在做**（会把 MVP 拖死）：真实系统代理写入、客户端重连、WebRTC 真采集、生产级失败关闭。这四项在 `REQUIREMENTS.md:7-14` 本身都是「未验收」，且缺厂商接口/隔离环境，不是接线问题而是**能力尚未实现**。

---

## 7. 必须先修的接线缺口（按影响排序）

| 排序 | 缺口 | 影响 | 证据 | 修法 |
| --- | --- | --- | --- | --- |
| **1** | **Engine 文件不进发布物，恢复功能只在仓库树内可用** | 决定性。用户装上后「授权并执行隔离回滚」必然失败，返回 `没有找到哈希相符的 rollback-v4.ps1、V4.ps1 或隔离脚本`。而 `docs/CAB-INTEGRATION.md:22` 却写「回滚演示只加载**随包**两份对应哈希的 Engine 文件」 | `desktop/src/ProxyDoctor.Desktop/ProxyDoctor.Desktop.csproj:24` 只复制 `scripts\Invoke-IsolatedRecovery.ps1`；`Recovery.cs:56-65` 向上找 8 层；实测 `bin\…\win-x64` → 仓库根 = 7 层；全仓库无任何脚本把 `proxy_v4` 放进发布目录（`git grep proxy_v4 -- desktop docs` 只有文档与读取代码） | 发布步骤复制 `proxy_v4/{rollback-v4.ps1,lib/V4.ps1}` 到输出目录；`FindEngineRoot()` 优先看输出目录内的相对路径 |
| **2** | **CI 在集成分支上不存在；Engine 回归从未自动化** | 高。三块入口共享的底座没有任何自动证据；`integration/cab-next` 上 `dotnet test` 与 Skill 测试都没人跑。历史上唯一的 engine workflow 也只跑 V69SnapshotSeal 且已被删 | `git ls-files` 无 `.github`；`cab-windows.yml`（分支 `cab/b-actions`）自述不跑 `Run-Tests.ps1`；`ccc1c51` 的 `cab-engine.yml` 自述「not the 114-case engine harness」 | 把 `cab-windows.yml` 合进集成分支，再补一个 `workflow_dispatch` 的 engine 全量 job |
| **3** | **Skill 没有恢复执行器，恢复链路在 Skill 侧断开** | 高。`SKILL.md:33` 把用户导向「恢复」，但 Skill 只有判定器。用户从 Skill 走到底会发现没有动作可执行 | `skills/windows-proxy-doctor/scripts/RecoveryVerdict.ps1:4`「This does not run rollback」；`git grep rollback-v4 -- skills` 只命中文档 | 复用 `desktop/scripts/Invoke-IsolatedRecovery.ps1`（把哈希白名单同步进 Skill），或在 `SKILL.md` 明确「恢复只能走 Desktop」 |
| **4** | **授权门槛不是真门槛** | 中。`Recovery.cs:85-86` 的字符串比对看起来是闸门，但调用方直接传常量，用户点按钮即通过。误触没有成本 | `ShellViewModel.cs:247`、`Program.cs:15` 均传 `IsolatedRecovery.AuthorizationText`；`MainWindow.xaml:321` 只展示不需输入 | UI 加输入框比对，或改成 `--recover` 需要额外 flag/二次确认 |
| **5** | **同一套故障语义在两个语言里各写一遍（C# 与 PS）** | 中。Desktop/CLI 用 `Diagnosis.cs:44-84`，Skill 用 `ProxyFaultClass.ps1:86-144`。7 类名称映射正确，但任何一侧改动都不会被另一侧发现——没有共享夹具测试同时锁两边 | 两个文件独立实现；`desktop/contracts/` 只有恢复夹具，**没有**分类共享夹具 | 把分类用例做成 `contracts/fault-cases.json`，两边测试都读它 |
| **6** | **CLI 覆盖面弱于 Desktop，但对外宣称「结构化证据」** | 中。DNS/DoH/UDP 在 CLI 上完全缺失，排障时拿不到这些证据 | `LiveDiagnosis.cs:283-302` vs `Checks.cs:18-54`（10 项） | CLI 增加走 `CheckRunner.RunAll` 的模式 |
| **7** | **恢复只有「固定夹具演练」，没有真实恢复** | 中（但属于能力未实现，不是纯接线）。期望值全部硬编码为「用户关闭场景」 | `Invoke-IsolatedRecovery.ps1:93-96` 固定 `V4_TEST_PROXY_ENABLE='0'`、`V4_TEST_PROXY_SERVER='old:8080'`；`:110-124` 注入 stub；`RecoveryTrust.cs:68` 硬编码 `enabled=0 server=old:8080`；`:13` `ExpectedTransactionExit = 32` | 若要真恢复，需要新场景 + 真实写入授权链路（`REQUIREMENTS.md:18` 明确生产快照未迁移） |
| **8** | **三个未接线的死代码类型** | 低。误导后续维护者以为有额外能力 | `CapabilityCatalog`（`LiveDiagnosis.cs:30`）、`RecoveryDrill`（`Runtime.cs:192`）、`AlertGate`（`Checks.cs:162`）均无生产调用 | 删除，或接进隐私页/告警 |
| **9** | **恢复契约夹具双份维护** | 低。当前两份**逐字节相同**（SHA-256 `9778A76B…072FC3F`，各 25 例），但没有任何机制保证下次一起改 | `desktop/contracts/recovery-fixtures.json` 与 `skills/windows-proxy-doctor/tests/fixtures/recovery-fixtures.json` | 用构建步骤复制，或加一条 CI 比对 |

---

## 8. 未验证清单（诚实边界）

本轮**没有执行**任何东西，以下结论需要跑起来才能确认：

1. **所有测试是否仍全绿**（Core 81 例、Skill 3 个 runner、`proxy_v6/tests/Run-Tests.ps1`）。仅做了静态计数。
2. **`proxy_v6/tests/Run-Tests.ps1` 能否在当前树跑通**。它依赖 `tests/lib/TestSupport.ps1`、`Harness.ps1`、`evidence/` 等；未执行。
3. **隔离恢复在真实机器上的端到端结果**。理论上路径通（哈希匹配、stub 注入、临时目录校验都在），但**没有实跑**，因此「点按钮能成功」是推断而非观测。
4. **Desktop 的 WPF 界面是否真能起窗口**。`bin\Release\net8.0-windows\win-x64\` 里有构建产物，但未启动。
5. **`Install-ProxyDoctor.ps1` 的实际安装行为**。只读了代码，未运行（任务明确禁止运行安装器）。
6. **114/114 与 97/97 两个引擎数字哪个对应当前树**。两者指向不同提交/日期，未复跑。
7. **Skill 15 项基础 / 21 项故障分类的精确例数**。`Run-OnboardingTests.ps1` 的 24 个 `Case` 标签与「24 项向导」吻合；另两个 runner 用断言计数（53 次 `Assert-` 调用）而非常规用例标签，未运行故无法确认实际用例数。

## 9. 审计合规声明

- 全程只读：未修改任何源码、未构建、未执行安装器、未启动 Desktop/CLI。
- 未执行任何网络请求脚本（Desktop/CLI/Skill 中所有会出网的路径均只做静态阅读）。
- 未读取任何凭据文件；`secret-scan` 相关内容只看了 workflow 逻辑，未执行。
- 唯一写入：本文件 `docs/plan/surfaces-gap.md`。
