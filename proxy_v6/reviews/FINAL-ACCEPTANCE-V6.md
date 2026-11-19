# FINAL-ACCEPTANCE-V6 — 独立最终验收（Agent E）

> **历史报告（针对 `abe0eaa`）**。最终代码/证据的裁定见 `FINAL-ACCEPTANCE-V6-ROUND2.md`（审查代码 `d5f2134` / 证据树 `b9bb9a0`）。本文件保留为第一轮记录，不覆盖旧结论。

审查人：final-acceptance（Agent E，独立闸门；未参与实现）
审查时点：2026-11-18T05:36:16-08:00（America/Los_Angeles）
目标：`abe0eaa4b29f9d40b8157420d96fa09013d165da`（branch `v5/short-run-hardening`，local HEAD；commit time 2026-11-18T05:27:12-08:00）
远端状态：`origin/v5/short-run-hardening` 仍为 `36222c9`，本地 ahead 1（未推送）。
边界：未执行真实 apply/rollback/state；未修改 HKCU/系统代理/Clash/appdata/注册表/网络/计划任务/凭据；未安装模块；未运行 `proxy_v4\tests\faultinject-v4.ps1`；仅只读审查 + `%TEMP%` 隔离测试。

## 0. 结论（先看这里）

**VERDICT: NOT_READY**

代码层的短跑隔离证据较强：独立全量 75/75、0 跳过、exit 0；自验 7/7；负控退出码 1/2/3/4 全部符合；Gitleaks 历史与工作树 0 命中。独立审查未发现新的功能性 HIGH。

但发布闸门尚不能签署，原因是**证据/记录/复审/安全残余/生产事件**，不是测试红：

1. **二轮独立复审未完成**：round1 的 4 份报告存在（基线 `36222c9`），round2-transaction / round2-security 仍在运行，审查时点尚无任何 round2 报告 → Gate 10 未证。
2. **提交内的 Gate 记录自相矛盾**：`proxy_v6/RELEASE-GATE-V6.md` 在目标提交中仍写 `NOT_READY（0/12 已证）`；ISSUE-LEDGER 的 F01–F10 仍为 UNVERIFIED/PARTIAL；TEST-MATRIX 61 处 NOT_RUN；TASK-STATE 的 P3–P9 仍“未开始”。提交消息却称“close F07-F10 …”。
3. **证据链未绑定目标提交**：被提交的 `evidence/v6/full.json` 与 `evidence/selftest/canonical/selftest.json` 内 `git.head = 36222c9`、`dirty = true`；HEAD 的 `final.json`（75/75，head=abe0eaa）在审查时点仍是 untracked，且工作树有 222 个已跟踪证据文件被删除、另有 3 个 untracked 项。
4. **回滚脚本没有隔离用例**：V6 测试对 `rollback-v4.ps1` 的引用为 0；回滚脚本的 lock/catch/restart 路径（含 A-12 修复）未被任何测试执行 → Gate 5 只能 PARTIAL。
5. **一个已确认 HIGH 安全项仍未关闭**：`-StaticPass` 命令行密码仍存在（`apply-v4.ps1:19`），而 `proxy_v4/SECURITY-AUDIT-V4.md:7` 仍称“不接受密码参数”，用户指南无命令历史警告 → C-02 仍 OPEN；C-01 的快照明文凭据仅“缓解”（ACL 前置 + 失败即中止），仍需用户明示接受残余。
6. **审查窗口内发生真实生产网络事件**：`proxy_v6/INCIDENT-2026-11-18.md`（untracked）记录了 05:28–05:35 的系统代理异常与 05:34/05:35 的人工 HKCU 修复；根因未定位，当前系统代理为关闭状态。该事件不是 V6 测试造成的证据（测试使用 V4_TEST_MODE/临时根），但它使“生产环境无影响/可真实短跑”的结论不能成立；任何真实 apply 都应在用户确认根因与安全状态后再谈。

因此：当前时点 **NOT_READY**；若下述阻塞项全部关闭，可复审转为 **SHORT_RUN_ACCEPTED**。这不是代码回归失败，而是发布证据与生产状态未闭合。

## 1. 独立执行的证据

| # | 项目 | 独立执行/核对 | 结果 |
|---|---|---|---|
| E-1 | 全量 V6 套件 | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -Filter '*' -OutFile %TEMP%\e-final-full.json` | **exit 0 / PASS**；head=abe0eaa；75 registered / 75 executed / 75 passed / 0 failed / 0 skipped；harnessErrors=0；evidenceErrors=0；runId=889c8faf96754f8c9db9e4ad82bfde57；05:28:08–05:29:25（76.3s） |
| E-2 | 自验 harness | `SelfTest.ps1 -OutDir %TEMP%\e-selftest-canonical` | **exit 0**；META-01..07 = 7/7 passed；child exit 0/1/3/2/0/4/1 与期望一致 |
| E-3 | 自验负控 | `-Filter META-99`、`-InjectCheckFailure META-01`、`-InjectHarnessError`、`-OutDir <file>` | 分别 **exit 2 / 1 / 3 / 4**，与文档契约一致 |
| E-4 | 真实 runner 零测试 | `Run-Tests.ps1 -Filter 'NO-SUCH-TEST-*'` | **exit 2**，输出 `[NO-TESTS]`；available=75，registered/executed=0 |
| E-5 | 全量跳过语义 | SelfTest META-05（mixed/all-skip/runtime-skip fixtures） | mixed=exit 0（skip=1 单独记录）；all-skip/runtime-skip=exit 2；skip 不计入 passed |
| E-6 | 证据写入失败 | SelfTest META-06 | final evidence 被阻断=exit 4；per-case 被阻断=exit 4 且 evidenceErrors 记录 |
| E-7 | 失败不被后续成功覆盖 | SelfTest META-07 | 先 FAIL 后 PASS → exit 1，证据 counts passed=1/failed=1 |
| E-8 | 秘密扫描 | `gitleaks git . --log-opts=--all` 与 `gitleaks dir .`（8.30.1，`--redact`，输出到 TEMP） | 两个报告均 **0 findings**；Agent C 的 canary 验证为 detected（其证据） |
| E-9 | 生产副作用检查 | 检查 `proxy_v4/config/settings.json`、`config/.lock`、`evidence` 最新时间 | 均不存在/最新日志仍为 03:49；我的测试未写生产 config/lock |
| E-10 | 提交内证据计数 | `git show abe0eaa:proxy_v6/evidence/v6/full.json` | 75/75、0 skip、exit 0；但 `git.head=36222c9`、`dirty=true`（见 §5） |
| E-11 | 工作树 HEAD 证据 | `proxy_v6/evidence/v6/final.json`（untracked） | 75/75、0 skip、exit 0；head=abe0eaa；`dirty=true`；75 个 per-case 文件齐全、与 case 记录一致 |
| E-12 | 源与文档核对 | 读取 apply/rollback/state/lib + 全部 75 个 case 注册 + 5 个 case 文件 | 见 §3/§4；无新增功能性 HIGH |

说明：E-1/E-2 的 `dirty=true` 是因为审查期间另一个进程删除了已跟踪的 `evidence/v6/full.json*` 并写入了 untracked 的 `final.*`，不是生产源码有未提交修改；测试代码来自 `abe0eaa` 的 worktree。我的运行输出在 `%TEMP%`，没有写入仓库证据目录。

## 2. Release Gate 12 项裁定

状态：PASS / PARTIAL / FAIL / 未证。此表以实际证据为准，不采信提交内自评。

| # | Gate 条件 | 状态 | 独立依据与残余 |
|---|---|---|---|
| 1 | 全部已确认 HIGH 软件安全缺陷关闭 | **PARTIAL** | round1 的 A-01/A-03/A-04/A-05/A-06/A-07/A-08/D-01/A-21 及 C-03 有修复和用例；A-12 有代码修复但**无用例**；C-01 已改为“先 ACL 后复制 + 失败即中止”，但快照仍是明文；**C-02 仍 OPEN**（见 §4）。round2-security 未回。 |
| 2 | F01–F10 全部重新核验 | **PASS（独立）** | 逐项见 §3；F06 只有静态+前轮行为证据，无 V6 回归用例。注意：仓库 ISSUE-LEDGER 仍写 UNVERIFIED/PARTIAL，记录未更新。 |
| 3 | F08/F09/F10 残余路径验证 | **PASS** | F08 10 例（含 CRLF/无 updated/相似 UID/重复 UID/非列表 UID/current 移位）；F09-SUITE（真实 apply 在父进程持锁下 exit 33、不写 settings、不删 winner lock）；F10 10 例（restore/start/proxy/owner/log 失败组合）。 |
| 4 | 多文件事务负向测试全部通过 | **PASS（引擎级）** | F07-01..15 覆盖 snapshot 失败、第 1/2/3 次写失败、proxy/owner 恢复、journal 清/留、journal 写失败先于首写；INF-SNAP-01..05、INF-ATOMIC-01..03。**真实 apply 脚本的成功/失败全链路未执行**（约束）。 |
| 5 | 回滚与并发测试全部通过 | **PARTIAL** | 并发/锁：F09-SUITE、INF-LOCK-01/02/03/05 通过；但 `rollback-v4.ps1` 在 V6 测试中引用数为 **0**，其 catch 重启、journal 清理、系统代理恢复路径未被执行；LOCK-06（重复回滚）无用例。 |
| 6 | 日志故障不阻断必要恢复 | **PASS** | F10-01/02/03（restore/start/log 抛错仍返回 40、不抛出）、INF-LOG-01/02；Write-V4Log 内部 try/catch，RecoveryNote 单独保护。 |
| 7 | 无关配置不会被误修改 | **PASS（隔离）** | F08-01/02/03/05/09/10 断言 foreign profile 不变；F09-01 断言持锁时不写 settings；INF-DRYRUN-01 断言 profiles/runtime/settings 哈希不变。DATA-01 的真实 appdata 未执行（约束）。 |
| 8 | 测试框架退出码正确 | **PASS** | E-2/E-3/E-4；0/1/2/3/4 均由独立负控验证，非“文档声明”。 |
| 9 | 无虚假通过/未声明跳过 | **PASS** | 75 executed、0 skipped；每 case 独立 evidence；SelfTest META-05/07 证明 skip 单独记录且后成功不覆盖失败。小瑕疵：父 harness 对子进程用例的 `assertions` 计数恒为 0（用例在子进程内断言），不影响 pass/fail 判定，但证据可读性弱。 |
| 10 | 连续两轮独立复审无新增 HIGH | **未证** | round1 有 AGENT-A/B/C/D 四份报告（基线 36222c9，明确不审修复后代码）；round2-transaction / round2-security 在审查时点仍 running，`proxy_v6/reviews/` 无 round2 文件。必须等两报告落地并复核。 |
| 11 | 公开发布秘密扫描通过 | **PASS（秘密）/ 待决（PII）** | Gitleaks 历史+工作树 0；自定义扫描 0 真实凭据/DPAPI/GitHub token/私钥；但仓库仍含公网 IPv4、绝对项目路径、Windows 用户路径（Agent C：18 个 IP/46 处路径），属 WAITING-USER 决策，不是 secret。 |
| 12 | 延期/阻塞项目明确披露 | **PASS（披露）/ 记录陈旧** | TASK-STATE §6、RELEASE-GATE 独立闸门、ISSUE-LEDGER C 已披露：凭据轮换 BLOCKED-USER、真实 boot/sleep/Wi-Fi/24h/72h DEFERRED、真实 apply/rollback 未执行、V5-01/V5-02 上游 OPEN、IP/路径 WAITING-USER。但 Gate 文件本身仍写 0/12，需更新为当前证据。 |

**Gate 汇总：PASS 9 / PARTIAL 2 / 未证 1 / FAIL 0（Gate 11 按“秘密 0 命中”计 PASS，PII 另标注 WAITING-USER）；但 Gate 1/5/10 与记录/证据链问题足以阻止签署。**

## 3. F01–F10 逐项裁定

| ID | 裁定 | 当前证据 | 残余/边界 |
|---|---|---|---|
| F01 | **VERIFIED-CLOSED** | `apply-v4.ps1:33-35` 在任何写入前互斥；INF-PARAM-01（Repair+DryRun/Init+Repair 均 exit 11、无 settings）；INF-DRYRUN-01（真实脚本 DryRun 无文件变化）；INF-PARAM-02（非法 Mode） | DryRun 仍加锁/写日志/跑 `mihomo -t`（A-09，LOW/MED，不是“改真实代理”） |
| F02 | **VERIFIED-CLOSED** | journal 先写、`$applied=true` 紧邻首写（`lib/V4.ps1:216-225`）；F07-15 断言 journal 写失败 exit 34 且 0 次 live write；INF-JOURNAL-01 断言 pending journal 阻断 apply 为 34 | 崩溃窗口：snapshot 停应用后、journal 落盘前被杀，无 journal 可恢复（见 §4 残余） |
| F03 | **VERIFIED-CLOSED** | 事务/恢复在 apply 的 try 内完成，锁在 finally 释放（`apply-v4.ps1:180-182`）；F07-06/07、F09-02、INF-LOCK-02 验证 loser 不删 winner 锁 | 真实双 apply 并发未演练（F09 为父持锁 + 子 apply） |
| F04 | **VERIFIED-CLOSED** | `Update-V4ProfileText` 每次按行块重写 updated 并重算 current（`lib/V4.ps1:1085-1148`）；F08-01/05/09 | 真实 Clash 启动是否改写 profiles.yaml 未验证（禁止真实 appdata 变更） |
| F05 | **VERIFIED-CLOSED（替换）** | 旧 V4 faultinject 已退役并改为 V6 委派（`faultinject-v4.ps1:1-19`）；V6 harness 自验 7/7 + 负控 1/2/3/4 | 旧文件仍可被误运行并触发 75 例全量；文档需明确“不要运行旧测试台” |
| F06 | **VERIFIED（静态+前轮行为；无 V6 用例）** | `Build-V4Profile` strict 仅 `US-WA-SOCKS5`，resilient 才含 `DIRECT`（`lib:1188-1209`）；round1 T07 strict_has_DIRECT=false | 建议补一个 V6 单测，否则未来回归无自动保护（MED/LOW） |
| F07 | **VERIFIED-CLOSED（引擎级）** | 15 例全绿；覆盖 snapshot 停应用后失败恢复、三次写失败回滚、proxy/owner 恢复、app 起/停、错误码保留、journal 成功清/失败留 | 真实 `apply-v4.ps1` 成功/失败全链路未执行；崩溃/kill 未模拟 |
| F08 | **VERIFIED-CLOSED** | 10 例全绿（F08-01..10）；覆盖目标无 updated、相似 UID、重复 UID、非列表 UID、CRLF、current 移位、append | `Test-V4ProfileText` 只校验 target block + current，不校验 foreign blocks；防御纵深不足（MED） |
| F09 | **VERIFIED-CLOSED** | F09-SUITE 3 检查：父进程持锁时真实 apply `-Init` exit 33、settings 不存在、winner lock 存在；Init+DryRun exit 11；INF-APPLY-INIT-01（Init 在锁内写 settings、缺路径 exit 10、锁释放）；INF-INIT-01..04 | 子进程等待锁 20s 的时序未做真实并发压测 |
| F10 | **VERIFIED-CLOSED** | 10 例全绿（restore/start/proxy/owner/log 失败组合，退出码 40 与步骤尝试）；INF-LOG-01/02 | `rollback-v4.ps1` 的 catch 日志/重启路径无用例覆盖 |

**F01–F10 结论：10/10 有独立裁定；F01–F05、F07–F10 有行为测试，F06 仅静态+前轮实验。**

## 4. HIGH/安全缺陷裁定（对 round1 报告的独立复核）

round1 报告作为线索，不作为结论；以下按当前源码/测试复核：

| 项 | 当前裁定 | 依据 |
|---|---|---|
| A-01 未持锁进程删 winner 锁 | **已关闭** | `Exit-V4Lock` 校验 token + 内容未变（`lib:649-667`）；INF-LOCK-02、F09-02 |
| A-03 停应用后失败不恢复 | **已关闭** | wasRunning 在 snapshot 前捕获；Recovery 停/还原/代理/owner/启动（`lib:99-158`、`197-280`）；F07-01/09 |
| A-04 快照不记录“原本不存在” | **已关闭** | manifest absent + restore 删除（`lib:743-892`）；INF-SNAP-01/05 |
| A-05 还原非原子/无落地校验 | **已关闭（逐文件）** | Set-V4Atomic + validator（`lib:868-907`、910-942）；INF-SNAP-02/04、ATOMIC-01..03 |
| A-06 不还原系统代理/owner | **已关闭** | Recovery 还原 proxy/owner（`lib:99-158`）；F07-05/10、F10-08/10 |
| A-07 Init 在锁前写 settings | **已关闭** | 锁先于 Init（`apply:37-61`）；F09-SUITE、INF-APPLY-INIT-01 |
| A-08 无事务 journal | **已关闭** | journal 先于首写、成功/恢复清、恢复失败保留（`lib:161-194`、`apply:43-47/166`）；F07-12..15、INF-JOURNAL-01 |
| A-12 rollback 双失败不重启 | **代码已改，无测试** | `rollback-v4.ps1:64-73` catch 重启；但 V6 无 rollback 用例 → 不能判 VERIFIED-CLOSED |
| D-01 快照 profiles 名称缺分隔符 | **已关闭** | `Join-Path 'profiles'`（`lib:776`）；INF-SNAP-05 |
| A-21 测试台改真实 hosts ACL | **已关闭** | 旧测试台退役（仅注释保留 hosts 字样）；V6 测试 0 引用 |
| C-01 快照明文凭据 + ACL 后置/静默 | **缓解，残余需接受** | 先 harden 目录再复制、失败即中止（`lib:756-757/805`）；我独立验证快照子文件 ACL 仅当前用户/SYSTEM/Administrators（DACL 继承，无 Everyone/Users）；但快照仍是明文，若被复制出机 ACL 不随行 |
| C-02 密码经命令行 | **OPEN（HIGH）** | `-StaticPass` 仍在（`apply:19`）；`SECURITY-AUDIT-V4.md:7` 称“不接受密码参数”又承认可显式传入；`USER-GUIDE-V4.md` 无命令历史警告（grep 0） |
| C-03 测试台真实系统风险 | **已关闭** | 旧测试台退役；V6 测试未出现真实 hosts/HKCU/进程写入（我的 E-9 检查） |
| D-03 0 字节锁卡死 | **已关闭** | 空锁按年龄回收（`lib:610-614`）；INF-LOCK-05 |
| D-04 陈旧锁回收 TOCTOU | **残余 LOW** | `lib:638-641` 读-比较-删除仍有极小窗口；未做注入测试 |
| C-04/C-05/C-08/C-10/C-11 | **已关闭/大幅缓解** | ACL 早退改为全量校验（`lib:529-575`）；调用方检查失败抛 12；脱敏扩展（`lib:50-61`）+ INF-REDACT-02；state 顶层兜底 + INF-STATE-SCRIPT-01；`.gitignore` 已含 `**/config/settings.json`/`.lock` |
| C-06/C-07/C-09 | **残余 MED** | settings 仍先写后加固；生成 profile/runtime 的明文窗口；runtime 被应用重写后 ACL 可能重置；日志 ACL 已 harden 但无轮转 |
| C-12 公网 IP/绝对路径 | **已披露，WAITING-USER** | Agent C 计数 18 IP/46 路径；TASK-STATE §6 待用户决定；不属于 secret |
| A-11/A-13/A-14/A-19/A-20/A-26 | **残余 MED/LOW** | rollback 无条件启动/默认端口；系统代理快照仅 enabled/server；owner 回滚写 rollback；启动判定仅端口；原子残留 .bak；`apply` 文件头仍写 strict(default)（已与参数一致，A-26 基本修） |
| 状态机 RECOVERING | **残余 MED** | `Get-V4StateCore` 不会产生 RECOVERING；`state-v4.ps1:58` 的分支不可达；round1 D-03 的 UNKNOWN/RECOVERING 结论仍部分成立 |
| snapshot→journal 崩溃窗口 | **残余 MED** | snapshot 停应用后、journal 写入前被 kill：无 journal，应用可能保持停止；异常路径有恢复，崩溃路径无 |

**HIGH 结论：round1 的代码/测试类 HIGH 均已修复或有测试支撑；C-02 是唯一未关闭的 HIGH 安全项。C-01 由 HIGH 降为“已缓解、需用户接受残余”。**

## 5. 证据链与记录一致性（阻塞项）

1. **提交内 Gate 文件仍是否定结论**：`RELEASE-GATE-V6.md:4` = `NOT_READY（0/12 已证）`；:23 = SHORT_RUN_ACCEPTED 未达；:30 = 初始 0/12。提交 `abe0eaa` 在 05:27 生成，文件时间 04:51，内容未随修复更新。
2. **ISSUE-LEDGER 仍 10 处 UNVERIFIED/PARTIAL**；TEST-MATRIX 61 处 NOT_RUN；TASK-STATE 写 P3–P9 未开始。与提交消息“close F07-F10 …”直接冲突。
3. **证据绑定父提交**：`git show abe0eaa:proxy_v6/evidence/v6/full.json` 内 `git.head=36222c92…`、`dirty=true`；`selftest/canonical/selftest.json` 同样 head=36222c9。它们是在提交前用 dirty worktree 跑出的，不能证明 `abe0eaa` 的树。
4. **HEAD 证据未入库**：`final.json` 与 `final.cases/` 是 untracked；同时 222 个已跟踪的 `full.json*` 被删除（工作树 `D`）。审查时点 `git status` 不干净，`origin` 仍停在 36222c9。
5. **计数一致性**：三份 full 运行（提交内 36222c9 dirty、HEAD final.json、我的独立 run）均为 75/75、0 skip、0 harness/evidence error；final.json 的 75 个 per-case 文件齐全且 id/status 一致。计数本身没有问题，问题是**哪棵树、哪次运行**被提交。
6. **父 harness `assertions=0`**：F07/F08/F09/F10/INF 用例的断言在子进程/Repro 内，父记录只显示 0；不是空跑（子进程结果 JSON + exit code 校验），但会误导审计者，建议在 evidence 中记录子进程 checks 数或映射。

## 6. 生产事件（审查窗口内的外部事件）

`proxy_v6/INCIDENT-2026-11-18.md`（untracked）记录：05:28–05:35 国内/国外网站不可用；只读诊断发现 HKCU `ProxyEnable=1`、`ProxyServer="x"`；05:34 人工改为 127.0.0.1:7897，05:35 因百度 502 又关闭系统代理（ProxyEnable=0）；根因未定位；文中称未执行真实 apply/rollback/state，但也明确记录了**人工 HKCU 修改**。

- 该事件**不是**我执行的；我没有读写/修改 HKCU，也没有独立验证事件文中的当前状态（受任务约束）。
- 该事件与 V6 测试隔离声明不矛盾（E-9：测试未写生产 config；测试全程 V4_TEST_MODE/临时根），但它推翻了“整个会话对生产零影响”的隐含前提，并说明上游/Clash Verge 系统代理回退（V5-02 #8593）风险是现实的。
- 在根因定位、用户确认安全状态、以及国内/国外可用性基线恢复之前，不应进行任何真实 apply；也不应把“短跑可接受”解释为“现在可以上生产”。这是 **BLOCKED-USER/INCIDENT** 项。

## 7. 延期/阻塞披露核对（不得声称已完成）

| 项 | 披露位置 | 状态 |
|---|---|---|
| NexIP 凭据轮换 | ISSUE-LEDGER V5-03；TASK-STATE §6 | **BLOCKED-USER**，未执行，不得声称已轮换 |
| 真实重启/睡眠/Wi-Fi 切换、24h/72h 长稳 | TASK-STATE §6；RELEASE-GATE 独立闸门 LONG_RUN | **DEFERRED-BY-USER**，未执行 |
| 真实生产 apply/rollback/state 网络路径 | RELEASE-GATE:26；本报告 §2/§5 | **未执行**；隔离测试不能冒充 |
| Clash 2.5.10 缺 150bfae（链式代理重启失效） | ISSUE-LEDGER V5-01 | **OPEN（上游）** |
| 上游 #8593 系统代理回退 | ISSUE-LEDGER V5-02；本次 INCIDENT 可能相关 | **OPEN（上游/待查）** |
| 公开仓库 IP/绝对路径脱敏 | TASK-STATE §6 | **WAITING-USER** |
| 24/72h/生命周期/服务资格 | RELEASE-GATE 独立闸门 | LONG_RUN DEFERRED；SERVICE_ELIGIBILITY NOT_READY |

这些项目均已披露；**没有任何独立证据表明真实生产 apply/rollback/boot 已执行**。历史 `proxy_v4/CHANGELOG.md` 的 03:45–04:05 apply 全链路/13/13 记录早于 `abe0eaa`，不能作为本提交的证据。

## 8. 阻塞项与转绿条件

以下全部关闭后，可重新召开 Gate（预计转为 SHORT_RUN_ACCEPTED；LONG_RUN 仍不在此范围）：

| # | 阻塞项 | 完成判据 |
|---|---|---|
| B1 | round2 独立复审 | round2-transaction + round2-security 报告落地；确认无新增 HIGH；报告针对 `abe0eaa`（或其后继提交）而非 36222c9 |
| B2 | Gate/账本/矩阵/状态更新 | RELEASE-GATE 12 项按证据更新（不得 0/12）；ISSUE-LEDGER F01–F10 标 VERIFIED-CLOSED/PARTIAL 且附证据；TEST-MATRIX 实际状态；TASK-STATE 当前阶段；CHANGELOG 记录本轮 |
| B3 | 证据链绑定目标提交 | 在干净 worktree 上重跑 full + selftest（或明确记录 commit+dirty 哈希）；把 final.json/per-case 提交；恢复被删的 full.json* 或正式替换；`git status` 干净；推送 branch（保持 Draft PR）；`origin` 指向目标提交 |
| B4 | rollback 脚本验证 | 增加 `rollback-v4.ps1` 的隔离用例（V4_TEST_MODE + 临时 root + 合成 snapshot），覆盖 restore 失败→catch 重启、journal 清理、系统代理恢复/41、重复回滚串行；或用户明确书面接受该路径延后并记录 |
| B5 | 安全残余 | C-02：移除 `-StaticPass` 或提供安全输入并修正 SECURITY-AUDIT/USER-GUIDE（明确命令历史风险）；C-01：用户书面接受“受 ACL 保护的明文快照”；C-12：用户决定 IP/路径披露 |
| B6 | 生产事件 | 用户确认根因（`ProxyServer="x"` 来源）、当前系统代理/网络状态安全、V4 真实短跑的前置条件；在此之前不得真实 apply；事件记录纳入发布说明 |
| B7 | 真实环境范式 | 继续保持“真实 apply/rollback/boot 未执行”的披露；不得以隔离 75/75 冒充生产验收；真实短跑由用户执行并另行记录 |
| B8 | 可选 LOW | F06 补 1 个 V6 用例；evidence 记录子进程 checks 数；`INCIDENT` 文件如发布需移入 reviews/evidence 并检查 PII |

## 9. 最终裁定

**NOT_READY**。

- 代码层：短跑隔离证据强（75/75、自验 7/7、负控 0/1/2/3/4、Gitleaks 0），未发现新的功能性 HIGH；F01–F10 均可逐项裁定（F06 为静态/前轮证据）。
- 发布层：Gate 1（C-02）、Gate 5（rollback 无用例）、Gate 10（二轮未回）未闭合；Gate 记录/证据链与目标提交不一致；工作树脏且未推送；生产事件未定根因。
- 因此当前不能签署 SHORT_RUN_ACCEPTED；也不接受任何“真实生产 apply/rollback/boot 已验证”的说法——它们没有执行。
- 条件满足（B1–B7）后，复审可给出 SHORT_RUN_ACCEPTED；LONG_RUN 仍为 DEFERRED-BY-USER，SERVICE_ELIGIBILITY 仍 NOT_READY。

---

报告不改动任何生产/跟踪文件；本文件为唯一新增评审产物（另有可选的 `proxy_v6/evidence/v6/agent-e-acceptance.json` 摘要）。所有数字均来自本报告的独立运行或对提交对象的只读读取。
