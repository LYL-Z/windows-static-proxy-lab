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
