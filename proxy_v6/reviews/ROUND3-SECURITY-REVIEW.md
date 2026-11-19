# ROUND3-SECURITY-REVIEW

**审查对象（最终）**：代码提交 `d5f2134`；最终证据提交 `b9bb9a0`；当前检出 HEAD `01baaf5`（`6e3cd09` 仅状态文档，`01baaf5` 仅 `repo-acl.json` ACL 记录；我已核对 `d5f2134..HEAD` 没有生产代码变化）。
**分支/远端**：`v5/short-run-hardening`，已推送；本地 HEAD `01baaf5`。
**审查类型**：F11 之后的第三轮聚焦安全复审；不采信提交内自评或前序报告作为结论。
**结论**：**F11 的原始 V4 探针路径已关闭；未发现 d5f2134 生产代码路径中的新 HIGH。但安全 Gate 仍不能无条件通过**：C-02（`-StaticPass`）仍是未关闭的 HIGH，C-01/C-12 仍需用户明示接受；另有 2 项中危残余（R3-01 旧 V1–V3/diag 脚本仍可直接写 HKCU；R3-02 系统代理注册表写入非原子）。建议最终状态：**SHORT_RUN_ACCEPTED（有条件）**，不是无条件发布。

## 1. 范围、方法与边界

- 代码以 `git archive HEAD` 和 `git diff d5f2134..HEAD` 为准；证据读取 `proxy_v6/evidence/v6/final.json`、`final.cases/`、`selftest`、`repo-acl.json`。
- 只读审查 + `%TEMP%` 隔离测试；未执行真实 apply/rollback/state；未读写/修改真实 HKCU；未运行网络请求、Clash 启停、计划任务或凭据操作。
- 允许的测试：`Run-Tests.ps1 -Filter 'INF-*' -OutFile <TEMP>`、`SelfTest.ps1 -OutDir <TEMP>`、以及自定义的 test-mode 探针。**没有运行 FT16–FT21 和全量 92 例**：FT 夹具会读取真实 HKCU/WinHTTP（只读，但受“不要触碰真实 HKCU”约束）；提交内 `final.json` 的 92/92 仅作只读核对。
- gitleaks 8.30.1：`dir`（HEAD 精确树、当前工作树）与 `git --log-opts=--all`，全部 `--redact`；另用自定义正则扫描 PII/凭据形态。报告只给计数/文件位置，不打印真实密码、用户名、DPAPI 密文、公网 IP 或邮箱值。

## 2. F11：原始探针路径已关闭，但旧写入面仍在

### 2.1 已确认的修复

| 控制 | 代码 | 独立验证 |
|---|---|---|
| test-mode 注册表写默认拒绝；只有 test writer 可 mock | `V4.ps1:47-51,997-1009` | test mode 无 writer 调用 `Set-V4SystemProxy -Server 'x'` 抛出：`V4 test mode blocks a real system-proxy write...`；`Enable-V4ProductionWrites` 返回 false |
| 生产写门闩 | `V4.ps1:41-57`；apply/rollback 显式 `Enable-V4ProductionWrites` | 非 test mode、未 Enable 时 `Set-V4SystemProxy` 抛出 `V4 production write blocked...`；test writer 在非 test mode 安装被拒绝 |
| test-mode Start/Stop 安全 no-op | `V4.ps1:702-712,749-760` | test mode 下 `Start-V4Clash`/`Stop-V4Clash` 返回 true，不启停真实进程；`INF-GUARD-01` 通过 |
| mock 写入 | `Set-V4TestRegistryWriter` | mock writer 收到 `enabled=true, server=x`；未调用真实 HKCU 写入 |
| rollback 补救启动前预验证 | `rollback-v4.ps1:56-59`（d5f2134） | 无效 manifest 的隔离回滚：exit 40，`V4_TEST_START_LOG` 为空，未调用 Start |
| 原始探针文件 | 不在 tracked tree/history；仅文档提及 | `git log --all --name-only -- '*probe*'` 无 `_probe-new.ps1`；工作树无该文件 |

结论：**05:02:37 那条 `Set-V4SystemProxy -Server 'x'` 探针路径在 V4 中已被阻断**。即使临时探针设置 `V4_TEST_MODE=1`，现在也会在写入注册表前抛错；即使不在 test mode，未显式 Enable 也会被 latch 拒绝。

### 2.2 未覆盖的同类生产写入面（R3-01）

F11 latch 只覆盖 `proxy_v4/lib/V4.ps1` 的系统代理函数。以下 tracked 旧脚本仍**直接**写真实 HKCU，且没有 test-mode/latch/恢复：

- `proxy_diag/apply-chain.ps1:152-155`：`ProxyServer='127.0.0.1:7897'`、`ProxyEnable=1`。
- `proxy_diag/rollback.ps1:23-27`：`ProxyEnable=0`、`ProxyServer='127.0.0.1:11119'`。
- `proxy_v2/lib/Common.ps1:380-392` 与 `proxy_v3/lib/Common.ps1:380-392`：`Set-SystemProxy`/`Clear-SystemProxy` 直接 `Set-ItemProperty`。
- 这些文件没有“DEPRECATED/do not run”头，也没有 test-mode guard；一次 ad-hoc 探针或误运行即可重复 F11 类事故（即使不是 V4 路径）。
- 严重度：**MEDIUM**，状态 **OPEN**。建议：在文件头标记退役/仅供历史阅读；或在入口加与 V4 相同的 `V4_TEST_MODE`/latch；至少从发布文档与测试约定中明确“不得调用 V1–V3/diag 写系统代理”。

### 2.3 FT16–FT21 的证据边界

- 提交内 `final.json` 记录 `FT16..FT21` 均 PASS；这说明在提供方运行中 6 个用例通过。
- 我没有独立运行它们：`Run-FT-Case.ps1:25-36,76-77,151-152` 会读取真实 HKCU 和 `netsh winhttp show proxy`（只读），与“不要触碰真实 HKCU”的审查约束冲突。
- FT 用例是“真实 HKCU 前后一致”的只读对照，不是完全 TEMP 隔离；若测试期间 Clash/用户改动 HKCU，可能误报。此点是测试设计限制，不是写入漏洞。

## 3. 请求项的独立裁定

| 项 | 裁定 | 证据/说明 |
|---|---|---|
| **C-01** 快照明文凭据 | **PARTIAL / 需用户接受** | `New-V4SnapshotFiles` 复制前加固目录；恢复后重新加固；但快照仍含明文代理密码/runtime secret/订阅 profile，无加密/保留期/清理。`SECURITY-NOTES.md:30`、`USER-GUIDE-V4.md:48` 已明确披露“未加密、不要上传”。风险不是“未知”，但仍需用户书面接受。 |
| **C-02** `-StaticPass` | **未关闭（HIGH，已文档化）** | `apply-v4.ps1:19` 仍接受密码参数；命令行/PSReadLine 历史暴露不变。`SECURITY-AUDIT-V4.md:7`、`USER-GUIDE-V4.md:47`、`SECURITY-NOTES.md:29` 现在明确警告，修正了旧文档的否认；但代码暴露仍在。若用户明确接受“仅 -Init 显式迁移”，可降为 ACCEPTED-RISK；否则应移除参数或改用安全输入。 |
| **C-12** 公开 PII/IP/路径 | **OPEN / WAITING-USER** | HEAD 树：**19 个唯一公网 IPv4、533 次、37 文件**（abe0eaa 时为 18/530/36；新增 1 个来自事故/状态记录）；**49 处 Windows 用户目录路径、43 文件、1 个用户名**；**96 处项目绝对路径、31 文件**；邮件形态 **6 机构 + 2 测试/example + 0 私人**。未打印任何值。事故文档新增了公网 IP，用户需决定脱敏或接受；不得未经批准改写历史。 |
| **C-13** manifest 无签名 | **ACCEPTED-RISK / LOW** | `Test-V4SnapshotManifest` 已拒绝零条目/无 profiles.yaml 的清单；rollback 先验证再设置 `restoreAttempted`；但 manifest 仍是 SHA256，不是签名/MAC，`-SnapshotDir` 仍接受任意路径；恢复目标受限于 appdata/profiles。 |
| **C-14** 供应链 | **ACCEPTED-RISK / LOW** | 仍无第三方 PS/npm/pip 依赖；但 mihomo/curl 无哈希/签名，`Get-V4Paths` 信任运行中 clash 路径，`curl.exe` 走 PATH。未新增依赖。 |
| **R2C-03** settings/state 读取不复核 ACL | **已关闭** | `Get-V4Settings` 先验证 config 目录和 settings 文件 ACL，失败抛 fault 12；`INF-SETTINGS-04` PASS；我的隔离测试也得到 code 12。 |
| **R2C-04** 恢复后不加固凭据文件 | **已关闭** | `Restore-V4Files` 在 `Set-V4Atomic` 后调用 `Protect-V4Acl` 并验证；`INF-SNAP-08` PASS；我的隔离测试恢复后 `Test-V4AclHardened=true`。残余：Clash 重启后重写 runtime 仍可能重置 ACL（C-07 范围）。 |
| **R2C-05** harness 证据 ACL | **MITIGATED（非代码强制）** | 实测 1594 个 repo 对象（含 evidence/.git）**0 个 broad ACE**；根 `publish` protected，仅 SYSTEM/Administrators/当前用户。默认证据目录继承受限；但 `Harness.ps1` 本身仍不调用 ACL 函数，若 `-OutFile` 指向非受保护目录则依赖该目录 ACL。 |
| **R2C-07** 证据绑定旧 HEAD/dirty | **基本关闭，selftest 残留** | `final.json`: head=`d5f2134`，dirty=false，92/92，0 skipped；`final.cases` 齐全。但 `selftest/canonical/selftest.json` 仍 head=`c562c18`、dirty=true；我在最终树上独立运行 SelfTest 7/7 PASS（TEMP 输出），但提交内 selftest 证据未重绑。 |
| **R2C-08** 脱敏缺口 | **PARTIAL** | JSON key/空格值/Cookie/Set-Cookie/Authorization/Proxy-Authorization/Basic/Bearer/client_secret 已遮；但 `socks5://user:pass@host` 输出 `socks5://user:"***"`，**用户名仍可见**；`X-Api-Key: ...` 与 `apikey=...` **不遮**。`INF-REDACT-03` 只断言 `user:pass` 不存在，未覆盖用户名/`X-Api-Key`，测试过弱。前一轮的“JSON/空格”部分已关闭。 |

### 其余 C 项（供 Gate 一致性）
- **C-03/C-10/C-11**：已关闭（旧 faultinject 退役；损坏 DPAPI state 结构化 exit 3；嵌套 .gitignore）。
- **C-04**：**PARTIAL**，不是 CLOSED。`Test-V4AclHardened` 仍不校验 owner/继承标志；隔离测试构造“仅当前用户 FullControl、无继承”的受保护目录，`Protect-V4Acl` 返回 true 并早退。`SECURITY-REVIEW-V6.md` 标 CLOSED 属过度声明。
- **C-05/C-09**：基本关闭（写失败抛 12；读取复核；repo/evidence ACL 已硬化）；C-09 仍无日志轮转/清理。
- **C-06/C-07**：PARTIAL/MITIGATED（目录先加固；运行 profile/runtime 仍先写后加固；应用重写 runtime 可回落）。
- **C-15**：**PARTIAL**。`SECURITY-AUDIT-V4.md:9` 仍写“必须含 owner ACE”，代码并不设置/校验 owner；`SECURITY-REVIEW-V6.md` 把 C-04/C-08/C-15 标 CLOSED、C-02 标 DOC-FIXED，证据不足；`RELEASE-GATE-V6.md:37` 的“未授权生产配置修改为零”与 F11 事故及旧脚本写入面不一致。

## 4. 新发现（R3）

| ID | 严重度 | 发现 | 证据 | 状态 |
|---|---|---|---|---|
| R3-01 | 中 | 旧 V1–V3/diag 脚本仍直接写真实 HKCU，无 latch/test guard；F11 类风险可经这些入口重现 | `proxy_diag/apply-chain.ps1:152-155`；`proxy_diag/rollback.ps1:23-27`；`proxy_v2/lib/Common.ps1:380-392`；`proxy_v3/lib/Common.ps1:380-392` | OPEN |
| R3-02 | 中 | `Write-V4SystemProxyRegistry` 分两次写 ProxyServer/ProxyEnable，无本地回滚/验证；第二次失败或进程中断可留下“新服务器 + 旧启用状态”的不一致；`Clear` 传入可能为空的 server | `V4.ps1:997-1018`；apply/repair 只在调用后回读并走恢复，恢复使用同一非原子写入 | OPEN |
| R3-03 | 低/中 | Runner 只强制 `V4_TEST_MODE/ROOT`，未清理继承的 `V4_TEST_APPDATA/RUNTIME/INSTALL/CORE/PROXY_*`；外部环境仍可把测试路径指到真实 appdata/路径 | `Run-Tests.ps1:29-31`；`V4.ps1:300-317`；fixture 只清理自身设置的变量 | PARTIAL |
| R3-04 | 低 | selftest 证据仍绑定 c562c18 + dirty=true，未绑定 d5f2134；final.json 已干净，但两套证据时间线不一致 | `evidence/selftest/canonical/selftest.json`；`evidence/v6/final.json` | OPEN（低） |
| R3-05 | 低 | 文档过度声明：C-04/C-08/C-15 被标 CLOSED，C-02 被标 DOC-FIXED；“未授权生产修改为零”与 F11/旧脚本不一致；`TASK-STATE` 仍写远端 b9bb9a0 而当前 HEAD 01baaf5 | `SECURITY-REVIEW-V6.md:26-39`；`SECURITY-AUDIT-V4.md:9`；`RELEASE-GATE-V6.md:37`；`TASK-STATE.md:15-17` | OPEN（低） |

**新 HIGH**：在 d5f2134 的生产代码路径（V4/rollback/apply）中**未发现新 HIGH**。C-02 是既存未关闭 HIGH；C-01/C-12 是需用户接受的既存风险，不是本轮新增代码漏洞。

## 5. gitleaks 与 PII 计数（无值）

### 5.1 gitleaks 8.30.1，--redact
| 扫描 | 结果 |
|---|---|
| HEAD 精确树（386 文件） | **0 findings** |
| 当前工作树 | **0 findings** |
| 全历史（12 commits / 907 unique blobs） | **0 findings** |
| 合成 canary（TEMP 随机 token） | 检出 **2** 条（`github-pat`/`generic-api-key`），`--redact` 生效；证明扫描器有效 |

未发现真实 DPAPI blob、GitHub token、私钥头、真实代理口令/用户名。唯一 DPAPI 头形态仍是 `proxy_v6/evidence/agent-c-secret-pii-scan.json` 的扫描模式字符串，不是 blob。合成凭据只在测试 fixture（`Run-InfraCase.ps1`、`Repro-F09.ps1`），不是真实值。

### 5.2 PII（HEAD 树，计数）
| 类别 | 计数 |
|---|---|
| 公网 IPv4 | **19 unique / 533 occurrences / 37 files**（较 abe0eaa +1/+3/+1；新增来自事故/状态记录） |
| Windows 用户目录路径 | **49 occurrences / 43 files / 1 unique username** |
| 项目绝对路径（`D:\claude防封`） | **96 occurrences / 31 files** |
| 盘符路径行 | **543 lines / 242 files** |
| 邮件形态 | **6 机构 + 2 test/example + 0 私人** |
| 本地 ignored 文件 | 未在 HEAD；未作为发布面计数 |

历史改写、IP/路径/用户名脱敏均未执行；C-12 仍需用户决定。

## 6. 独立测试与证据

| 测试 | 结果 |
|---|---|
| `Run-Tests.ps1 -Filter 'INF-*' -OutFile <TEMP>` | **49/49 PASS，exit 0**；evidence HEAD=`01baaf5`（代码与 d5f2134 相同）；包含 INF-SETTINGS-04、INF-SNAP-06/07/08、INF-ROLLBACK-01..04、INF-REDACT-03、INF-GUARD-01 |
| `SelfTest.ps1 -OutDir <TEMP>` | **7/7 PASS，exit 0**；当前树上独立运行 |
| 自定义 F11 探针 | test mode 无 writer 抛错；mock 写入只进 mock；非 test mode 未 Enable 抛 latch；test writer 非 test mode 拒绝；Start/Stop no-op |
| 自定义 rollback 预验证 | 无效 manifest：exit 40，start log 为空（d5f2134 行为） |
| 自定义 ACL/脱敏 | settings 宽 ACL → code 12；恢复文件 → ACL hardened；非继承 DACL 早退 true（C-04 残留）；JSON/Cookie 遮，URL username/`X-Api-Key` 泄漏 |
| 提交内 full.json | head=`d5f2134`、dirty=false、92/92、0 skipped；**只读核对，未独立全量执行** |
| FT16–FT21 | 提交内 6/6 PASS；**我未独立执行**（夹具读取真实 HKCU/WinHTTP） |
| 真实 apply/rollback/state | **未执行**；未改 HKCU/网络/Clash/凭据 |

## 7. 最终裁定与条件

**第三轮安全结论：F11 原始 V4 探针路径已关闭；d5f2134 未引入新 HIGH；但不能无条件签署。**

- **必须由用户明示接受或修复**
  1. **C-02**：`-StaticPass` 仍在；文档已警告，但命令行/历史暴露仍是 HIGH。移除参数或书面接受“仅 -Init 显式迁移”。
  2. **C-01**：快照/备份仍是明文；ACL 已前置、恢复已加固，但无加密/保留；需书面接受或增加加密/保留/清理。
  3. **C-12**：19 个公网 IP、49 处用户路径、96 处项目路径、1 个用户名公开；需用户决定脱敏或接受，不得擅自 rewrite 历史。
- **建议修复的中危**
  4. **R3-01**：旧 diag/v2/v3 脚本加退役标记或 latch；否则 F11 类写入面仍存在。
  5. **R3-02**：系统代理注册表写入改为可回滚/验证的单事务（或失败恢复前先备份当前两值并验证）。
- **建议修复的低危**
  6. R3-03 清理继承的 `V4_TEST_*`；R3-04 重绑 selftest 到 d5f2134；R3-05 修正 C-04/C-08/C-15/C-02 状态与“零未授权修改”表述；R2C-08 补 URL username/`X-Api-Key` 脱敏及测试。

**Gate 建议**：
- F11 专项（V4 原始路径）：**PASS（独立）**。
- 第三轮“无新增 HIGH”：**PASS**（d5f2134 生产代码）。
- Gate 1（全部 HIGH 关闭）：**PARTIAL**（C-02 未关闭）。
- 最终状态：**SHORT_RUN_ACCEPTED（有条件）**，条件为上述 C-02/C-01/C-12 用户书面处置；不是无条件发布。LONG_RUN 仍 DEFERRED-BY-USER，SERVICE_ELIGIBILITY 仍 NOT_READY，凭据轮换仍 BLOCKED-USER。

## 8. 限制

- 未独立运行全量 92 例/FT16–21：FT 读取真实 HKCU/WinHTTP，受审查约束；我运行了 49 个 INF 隔离用例、7/7 SelfTest 和自定义 F11/rollback/ACL/脱敏探针。
- 未执行真实 apply/rollback/state，未验证真实 HKCU/网络/Clash；ACL 扫描是只读测量，未修改任何对象。
- 未做跨用户 DPAPI、真实多用户竞争、锁 TOCTOU 动态复现；R3-02 的注册表部分失败为代码路径判断。
- gitleaks 默认规则不覆盖 PII/DPAPI；自定义正则只能证明本次范围未命中。未打印任何真实 secret/PII 值。
- 报告基于 d5f2134/b9bb9a0；当前 HEAD 01baaf5 的额外两个提交仅文档/ACL 记录，已核对无生产代码变化。审查末尾工作树被并发修改（`FINAL-ACCEPTANCE-V6.md` 有未提交修改、出现其他 round3 文件）；本报告不以这些并发文件为证据来源。

---

## DELTA — 2026-11-18 06:25 — 0268e17 / 1c7fdad / ebbf2e6 / 990d896

**审查对象（delta）**：代码 0268e17；最终证据 1c7fdad；规范 selftest ebbf2e6；文档 990d896。当前检出 HEAD 为 076c975（990d896..076c975 仅 RELEASE-GATE/TASK-STATE 文档变化，已核对无生产代码变化）。工作树有另一代理的未提交 FINAL-ACCEPTANCE 修改，本 delta 不以其为证据。
**范围**：只做 delta 复审，未重跑全量；未读写真实 HKCU/网络；未执行真实 apply/rollback/state。

### D1. C-02：不能判 CLOSED（高残余；测试存在假阳性）

- 新接口：apply-v4.ps1:19 已改为 -StaticPassFile；支持的显式 Init 路径可用（INF-APPLY-INIT-01 PASS），文档也已改为不再用命令行密码。
- 但 **PowerShell 参数前缀匹配仍使 -StaticPass 被接受**：-StaticPass 是 -StaticPassFile 的无歧义前缀。实际以 test mode 运行 apply -Init ... -StaticPass <值>，结果为 exit 11、credential file not found，不是参数绑定拒绝；临时参数脚本也证明 -StaticPass 绑定到 StaticPassFile。
- 影响：若用户沿用旧命令，密码仍进入 argv/PSReadLine 历史；只是被当成文件名后失败，不会写入 settings。原 C-02 的暴露面并未完全消除。
- 测试假阳性：INF-APPLY-INIT-02 只断言 exit != 0 且无 settings；上述“把密码当文件名”的失败同样满足，因此测试通过但并没有证明参数被拒绝。
- 建议：把参数改名为不以 StaticPass 开头的名字（如 -CredentialFile），或新增显式弃用的 -StaticPass 参数并在绑定后立即抛错；测试必须断言错误文本/参数拒绝，而不只是非零退出。C-02 在修复前应保持 OPEN/PARTIAL（高残余，仅旧语法）。

### D2. F12：分类与报告正确（合成验证）

- Get-V4UiSystemProxy 只读 APPDATA 下 Clash Verge verge.yaml 的 enable_system_proxy；Get-V4StateCore 新增 uiSystemProxy，并在 UI 与真实 HKCU 启用状态不一致时增加 reason、把非 FAILED 状态降为 DEGRADED；state-v4.ps1 的 JSON/文本均输出 uiSystemProxy。
- 合成 Get-V4StateCore 结果：
  - UI on / HKCU off -> DEGRADED，reason 含 “system proxy owned by off” 与 “UI reports system proxy enabled, actual HKCU is disabled”；
  - UI off / HKCU on -> DEGRADED，reason 含 “UI reports system proxy disabled...”；
  - 两者一致且链路正常 -> HEALTHY；
  - Clash down -> FAILED，仍保留 UI mismatch reason（FAILED 比 DEGRADED 更严重，合理）。
- 按 lead 提供的当前值（HKCU=0/UI=on，直连出口与 Clash 出口不同），预期状态是 DEGRADED（系统代理关闭 + UI 不一致），不是 HEALTHY；代码路径与 F12-RUNTIME-STATE-MISMATCH.md 一致。受“不触碰真实 HKCU/网络”约束，我未独立读取这些 live 值。
- INF-F12-01 PASS；F12 专文、state 输出、测试三者一致。

### D3. C-04 / C-08 / R3-02

- C-04：Test-V4AclHardened 已增加 owner SID 校验；原始“早退保留 Everyone/Users/只读 ACE、不校验 owner/FullControl”的 C-04 可判 CLOSED。仍有一个低残余：不校验继承标志；构造“仅当前用户 FullControl、无继承”的受保护目录时 Protect-V4Acl 仍返回 true（隔离验证）。这是可用性/幂等性残余，不是新的权限放宽。
- C-08：脱敏已把 URL userinfo 放在 key/value 规则之前，并加入 x-api-key/api_key/apikey；隔离验证 JSON、Cookie、URL username、X-Api-Key、apikey、api_key、client_secret、Proxy-Authorization 均被遮。C-08 可判 CLOSED；INF-REDACT-03 已把 URL 用例的 forbidden 从 user:pass 收紧为 user。
- R3-02：Write-V4SystemProxyRegistry 已加本地补偿：写入失败时恢复旧 ProxyServer/ProxyEnable。用 fake registry 注入“第二次写失败”，验证事件为 new server、new enable、old server、old enable，最终恢复旧值；仍非跨进程原子（进程在两次写之间被杀仍可能不一致），R3-02 降为 PARTIAL/低残余，不是新 HIGH。

### D4. 证据、gitleaks 与 PII（本轮新变化）

- final.json：head=0268e17、dirty=false、94/94、0 skipped；selftest：head=0268e17、dirty=false、7/7。R2C-07 可判 CLOSED。
- **gitleaks 不再为 0**：HEAD 精确树、工作树、全历史各 1 条 generic-api-key，文件为 proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1:744，secret_len=8，提交 0268e17。该值是合成 X-Api-Key 测试字面量，不是真实凭据；但 SECURITY-REVIEW-V6.md 的“工作树/历史 0 findings”和 RELEASE-GATE Gate 11 PASS 已不成立。建议加 allowlist/使用不会触发的占位符，并重跑扫描；不要把合成值写进报告。
- HEAD（076c975）PII 计数：公网 IPv4 19 unique / 537 occurrences / 39 files；Windows 用户目录路径 57 / 43 files / 1 username；项目绝对路径 97 / 32 files；盘符路径行 550 / 246 files；邮件 6 机构 + 2 test/example + 0 私人。C-12 仍 WAITING-USER，且计数较上一轮增加（F12/selftest 文档）。
- gitleaks 历史：17 commits / 1172 unique blobs，1 条上述合成命中；无真实 DPAPI/GitHub token/私钥/代理凭据。

### D5. 测试

- Run-Tests.ps1 -Filter INF-* -OutFile <TEMP>：**51/51 PASS，exit 0**，HEAD=990d896（代码 0268e17）；包含 INF-F12-01、INF-APPLY-INIT-02。
- 未独立运行全量 94/FT16-21（FT 读取真实 HKCU/WinHTTP）；final.json 仅只读核对。
- 关键 delta 发现：INF-APPLY-INIT-02 是假阳性（见 D1）；94/94 中的这个用例不能作为 C-02 关闭依据。

### D6. Delta 结论

- **C-02：未关闭**；新支持的 -StaticPassFile 路径安全，但旧 -StaticPass 仍作为前缀被接受，密码仍可进入 argv/历史；测试未证明拒绝。按原 C-02 口径，这是 HIGH 残余，不是 NEW HIGH 代码路径。
- **F12：分类/报告正确**；当前生产值按 lead 描述应为 DEGRADED，代码不自动改动网络。
- **C-04/C-08：可判 CLOSED**（C-04 保留继承低残余；C-08 已验证）。
- **R3-02：部分修复**（补偿有效，仍非原子）。
- **新 HIGH**：F12/C-04/C-08/补偿路径未发现新的生产 HIGH；但 C-02 仍未关闭，因此最终不能把 Gate 1 标 PASS。另有新的 LOW：gitleaks 1 条合成命中，使 Gate 11 的“0 findings”失效。
- 最终状态：**NOT_READY / SHORT_RUN_ACCEPTED WITH CONDITIONS**。阻断项：C-02 旧语法（HIGH）、C-01/C-12 用户书面接受、R3-01 旧写入面；Gate 11 需重新扫描/处理合成命中后才能 PASS。

---

## DELTA2 — 2026-11-18 06:38 — 79198fd / 32d8abc / dbbd259

**审查对象（final delta）**：代码 79198fd；最终证据 32d8abc（final.json head=79198fd、dirty=false、97/97、0 skipped）；规范 selftest head=79198fd、dirty=false、7/7；文档 103f707；gitleaks allowlist dbbd259。当前检出 HEAD 为 12821d1（dbbd259 之后为 FINAL-DELIVERY/GATE/TASK/F12 措辞等文档提交；已核对 79198fd..12821d1 无 .ps1 生产代码变化）。审查时工作树干净；本节只追加，不改变原 DELTA 的历史记录。

### E1. C-02：CLOSED（旧前缀假阳性已消除）

- apply-v4.ps1 现在同时声明 -CredentialFile 与墓碑 -StaticPass/-StaticPassFile；在任何文件读取/锁/Init 之前检查 PSBoundParameters，两个旧拼写都会 Fail 11：”-StaticPass was removed; use -CredentialFile <protected file>” / 同格式的 StaticPassFile。
- 独立测试（%TEMP% + V4_TEST_MODE=1，不触 HKCU/网络）：
  - 旧 -StaticPass 传入一个**确实存在的同名文件绝对路径**：exit 11、removal=true、settings 不存在；没有被当作 -StaticPassFile 读取。
  - 旧 -StaticPassFile 传入存在文件：exit 11、removal=true、settings 不存在。
  - 新 -CredentialFile + 受 ACL 保护的文件：exit 10（测试根无 appdata）、settings 已写、settings 内无明文口令；支持路径工作。
  - 同一测试中不再出现“文件存在 → exit 10 写 settings”的旧假阳性；INF-APPLY-INIT-02/03 现在断言 exit 11 且输出包含 removal 文案。
- 残余（低，非未关闭）：用户若手工键入旧拼写，口令仍会短暂出现在自己的命令行/Shell 历史中；但工具在读取前明确拒绝，不读取、不存储、不注册该值。原 C-02 的代码接受路径已关闭。

### E2. F12：报告准确（settings missing => FAILED + UI reason，不是 DEGRADED）

- Get-V4StateCore 在 settings 校验前计算 UI/HKCU mismatch 并加入 reason；SettingsError/缺 settings 的 early return 只把 state 置为 FAILED，reason 保留。
- 合成验证（无 HKCU 读写）：
  - Settings=null、SystemProxy=off、UiSystemProxy=true、无 SettingsError：state=FAILED；reasons=[“UI reports system proxy enabled, actual HKCU is disabled”, “settings.json missing”]。
  - Settings=null、SettingsError=“settings.json missing”、Ui=true：state=FAILED；reasons=[UI mismatch, “settings invalid: settings.json missing”]。
  - 因此当前生产“HKCU=0/UI=on/settings missing”应报 FAILED + UI reason，而不是 DEGRADED；与 lead 描述一致。受约束未读取 live HKCU/UI/网络。
  - INF-F12-01/02/03 均 PASS：UI on/off 对照、missing settings 保留 reason、verge.yaml true/false/missing key/missing file 解析。
- state-v4.ps1 的 JSON/文本均输出 uiSystemProxy；F12 专文同步更新。

### E3. 其他状态

- C-04：owner SID 校验已在；原 C-04 可判 CLOSED；非继承 DACL 的幂等性低残余仍在。
- C-08：URL/JSON/API-key/Cookie 脱敏已独立验证；保持 CLOSED。
- R3-02：本地补偿已验证（第二次写失败恢复旧 ProxyServer/ProxyEnable）；仍非跨进程原子，保持 PARTIAL/低残余。
- C-01/C-12/C-13/C-14：状态未变；C-01 快照明文凭据与 C-12 PII 仍需用户书面接受/决定；C-13/C-14 为 accepted low。R3-01 旧 diag/v2/v3 直接写 HKCU 的入口仍在，仍需退役/门闩或用户接受。

### E4. gitleaks：0（with allowlist）但 allowlist 过宽（R5-01，MEDIUM）

- 最终 HEAD 精确树：gitleaks 8.30.1 + .gitleaks.toml，0 findings；工作树 0；全历史 0（24 commits / 1410 blobs）。合成 X-Api-Key 字面量已替换，旧的 1 条合成命中不再出现。
- **新发现 R5-01（MEDIUM，扫描完整性）**：.gitleaks.toml 的 allowlist 同时写了整个文件路径 proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1 与该合成字面量正则。gitleaks 的 allowlist 字段按 OR 生效；独立实验：
  - 在 TEMP 复制该路径并放入一个合成高熵 token；同一 token 另放 other.ps1；用本仓库 allowlist 扫描 → 只有 other.ps1 被报，allowlisted 路径内的 token 被抑制。
  - 用 useDefault、无 allowlist 的配置扫描同一批文件 → 两条都报。
  - 证明：该 allowlist 会抑制该文件中**任何**未来 secret，而不只是历史合成字面量。Gate 11 的“0 findings”在输出上成立，但稳健性不成立。
  - 建议：删除 paths，只保留精确 regex/commit/fingerprint allowlist（或显式 condition=AND）；修复后重跑 tree/history/worktree。该发现是扫描器配置问题，不是真实凭据；不应为此降低 secret 扫描要求。

### E5. 测试与最终结论

- INF：54/54 PASS、exit 0（HEAD=ddf1d58，代码 79198fd；含 INF-APPLY-INIT-02/03、INF-F12-01/02/03、INF-GUARD、INF-REDACT）。
- final.json：head=79198fd、dirty=false、97/97、0 skipped；selftest：head=79198fd、dirty=false、7/7。未独立运行全量 97/FT；FT 读取真实 HKCU/WinHTTP，受“不触碰真实 HKCU”约束。
- **无新增 HIGH**：C-02 已关闭；F12、C-04、C-08、R3-02 补偿路径未发现新的生产 HIGH。当前剩余为 MEDIUM（R5-01 allowlist 过宽、R3-01 旧写入面、R3-02 非原子）与已披露的 C-01/C-12 用户决策/LOW（C-13/C-14、C-04 继承残余）。
- 最终安全状态：**SHORT_RUN_ACCEPTED WITH CONDITIONS**。条件：用户书面接受 C-01/C-12；R3-01 旧脚本退役/门闩；R5-01 allowlist 收窄并重扫。无 C-02 HIGH 阻断；不是无条件发布，LONG_RUN 仍 DEFERRED，服务资格仍 NOT_READY，凭据轮换仍 BLOCKED-USER。

