# FINAL-ACCEPTANCE-V6 — ROUND2（独立最终验收，含第三轮复审输入）

审查人：final-acceptance（Agent E，独立闸门；未参与实现）
审查时点：2026-11-18T06:07:00-08:00（America/Los_Angeles）

**审查对象（精确）**：**代码提交 `d5f2134`**（`v5/short-run-hardening`），以**干净 detached worktree @ `b9bb9a0`** 冻结后独立运行；`b9bb9a0` 是绑定 `d5f2134` 的最终证据提交。审查期间后续 `6e3cd09`（docs）、`01baaf5`（repo/.git ACL evidence）均无生产代码/测试差异；报告时 repo HEAD=`01baaf5`，origin 同点。

第三轮复审输入：`ROUND3-TRANSACTION-REVIEW.md`（06:05:30）与 `ROUND3-SECURITY-REVIEW.md`（06:05:49），均锚定 `d5f2134` / `b9bb9a0`。我阅读但不采信其结论，以下事实均独立核对。**截至报告时点，这两份 round3 报告仍是 untracked（HEAD 01baaf5 未包含），必须提交后才构成发布证据。**

前一版本报告 `FINAL-ACCEPTANCE-V6.md` 针对 `abe0eaa`，保留为历史；本报告取代它。

边界：未执行真实 apply/rollback/state；未修改 HKCU/系统代理/Clash/appdata/注册表/网络/计划任务/凭据；未安装模块；未运行 `proxy_v4\tests\faultinject-v4.ps1`；独立测试在 `%TEMP%` 冻结 worktree 中执行。

## 0. 结论

**VERDICT: NOT_READY**（可条件转 SHORT_RUN_ACCEPTED）

代码层短跑证据已经很强，且我独立复跑通过：**92/92、0 skipped、0 zero-assertion、assertions sum=128、exit 0**；META **7/7、exit 0**；最终 `final.json` 绑定 `d5f2134`、`dirty=false`；第三轮事务/安全复审均确认 **d5f2134 未新增 HIGH**，F11 原始 V4 探针路径已关闭。

但 Gate 仍不能无条件签署，剩余阻塞是**既有 HIGH 的用户处置、证据刷新与既有中危残余**，不是测试红：

1. **C-02 仍是未关闭 HIGH**：`-StaticPass` 仍在 `apply-v4.ps1:19`，命令行/PSReadLine 历史暴露不变；文档已如实警告，但代码暴露仍在。round3-security 明确把它列为 HIGH；需用户书面接受“仅 -Init 显式迁移”或移除/改安全输入。
2. **C-01 / C-12 需用户决定**：快照/备份仍含明文代理凭据（ACL 已加固、未加密、无保留期）；公开树有 19 个公网 IP、49 处用户路径、96 处项目路径、1 个用户名（均为计数，未打印值）。
3. **canonical self-test 证据陈旧**：`selftest/canonical/selftest.json` 仍是 `head=c562c18, dirty=true`；`final.json` 才是 `d5f2134, dirty=false`。我独立在 `b9bb9a0` 跑出 7/7、dirty=false，但仓库内该证据未刷新（R3-04）。
4. **第三轮新增中危残余**：R3-01 旧 `proxy_diag`/`proxy_v2`/`proxy_v3` 脚本仍可直接写真实 HKCU（无 latch/test guard，F11 类风险可经旧入口重现）；R3-02 系统代理注册表写入非原子（ProxyServer/ProxyEnable 两次写，失败可留不一致）。两项均 OPEN，建议修复或书面接受。
5. **F11 事件文档仍有矛盾行**：根因已写明主代理 05:02:37 临时探针；但同文“当前状态”仍写“ProxyServer='x' 来源未能确定”，且“未接触 HKCU”未区分探针与测试。
6. **其他既有残余**：R2A-06 journal 无 commit phase（OPEN，fail-closed）；R2A-10/11/13/14/15 LOW；R2C-08 URL username/`X-Api-Key` 仍未遮；C-04/C-15 部分过度声明。均已披露，不得标 CLOSED。

因此当前时点 **NOT_READY**。若用户完成 B2（C-02/C-01/C-12 书面处置）、B3（selftest 刷新）、B4（F11 文档修正），并对 R3-01/R3-02 修复或书面接受，则可转 **SHORT_RUN_ACCEPTED（有条件）**；真实生产 apply/rollback/boot/24h/72h 仍 DEFERRED-BY-USER，LONG_RUN 不在本次范围，凭据轮换仍 BLOCKED-USER。

## 1. 独立执行的证据（冻结 `b9bb9a0` / 代码 `d5f2134`）

| # | 项目 | 独立执行 | 结果 |
|---|---|---|---|
| R2E-1 | 全量 V6 套件 | 干净 detached worktree `b9bb9a0` 中运行 `Run-Tests.ps1 -Filter '*' -OutFile %TEMP%\e-b9-frozen.json` | **exit 0 / PASS**；head=b9bb9a0；dirty=false；92 registered / 92 executed / 92 passed / 0 failed / 0 skipped；harnessErrors=0；evidenceErrors=0；runId=2c0c1266c58c444282203dddc80d069f；06:01:06–06:03:07（119.8s） |
| R2E-2 | 断言/证据语义 | 同上 + 当前 Harness | 92 个 case `assertions>=1`（min=1，**sum=128**）；0 个零断言；无 skip；每 case 独立 evidence |
| R2E-3 | META-01..07 | worktree 中 `SelfTest.ps1 -OutDir %TEMP%\e-b9-selftest` | **exit 0 / SELFTEST_PASS**；7 selected / 7 checks / 7 passed；head=b9bb9a0；dirty=false；child exits 0/1/3/2/0/4/1 与期望一致；06:03:15–06:03:25 |
| R2E-4 | 提交的最终证据 | 只读 `proxy_v6/evidence/v6/final.json` | head=d5f2134；dirty=false；92/92；0 skipped；0 zero-assertion；92 个 per-case 文件齐全；id/status/assertions 与 case 记录一致；`filter=*` |
| R2E-5 | 提交的 self-test 证据 | 只读 `selftest/canonical/selftest.json` | 7/7、exit 0，但 **head=c562c18、dirty=true**；与最终代码/干净树不一致 → 证据缺口（R2E-3 仅我的 TEMP 证据） |
| R2E-6 | 秘密扫描 | `gitleaks dir` + `gitleaks git --all`（8.30.1，`--redact`，TEMP） | 均 **0 findings**、exit 0 |
| R2E-7 | 生产副作用 | 检查 `proxy_v4/config` / 我的测试路径 | 我的测试未写生产 config/settings/lock；FT16–FT21 在最终证据中通过（HKCU/WinHTTP 前后一致为测试断言） |
| R2E-8 | 代码 diff 核对 | `git diff abe0eaa..d5f2134` 关键段 | F11 生产写门闩、test writer、runner 强制 test mode、Start/Stop test no-op、rollback 先验 manifest、R2A-03/04/05/07/08 修复均在位 |

**目标漂移声明**：审查期间仓库从 `93027c6` → `d5f2134` → `b9bb9a0` → `6e3cd09` → `01baaf5`。我以冻结 `b9bb9a0`（=代码 `d5f2134`）为准；`6e3cd09`/`01baaf5` 无生产代码/测试差异，只改 docs/ACL 证据。

## 2. Release Gate 12 项（独立裁定）

| # | Gate 条件 | 状态 | 独立依据/残余 |
|---|---|---|---|
| 1 | 全部已确认 HIGH 软件安全缺陷关闭 | **PARTIAL** | F11 原始 V4 路径已关闭（round3 独立确认）；R2A-01 已修；**C-02 仍为未关闭 HIGH**；C-01/C-12 需用户接受；R3-01/R3-02 MED 新残余 |
| 2 | F01–F10 全部重新核验 | **PASS** | 92 用例；F07 16、F08 10、F09 套件、F10 10；F06 新增 INF-F06-01；见 §3 |
| 3 | F08/F09/F10 残余路径验证 | **PASS** | F08-09/10、F09-SUITE、F10-10、INF-APPLY-INIT-01；冻结全量通过 |
| 4 | 多文件事务负向测试全部通过 | **PASS** | F07-01..16；INF-SNAP-01..08、INF-ATOMIC-01..03；journal 05/11/13/14/15；冻结全量通过 |
| 5 | 回滚与并发测试全部通过 | **PASS** | INF-ROLLBACK-01..04（真实 rollback 脚本、损坏快照 40、锁忙 33、mixedPort 65532）；LOCK-01..05；FT19 |
| 6 | 日志故障不阻断必要恢复 | **PASS** | F10-01..10、INF-LOG-01/02；恢复日志全 best-effort |
| 7 | 无关配置不会被误修改 | **PASS** | F08 foreign blocks、F09 持锁不写 settings、INF-DRYRUN-01 哈希不变；DATA-01 真实 appdata 仍 DEFERRED |
| 8 | 测试框架退出码正确 | **PASS（独立）/ 证据缺口** | 我的干净 META 7/7；提交的 selftest 是 c562c18 dirty=true（R2E-5），需刷新 |
| 9 | 无虚假通过/未声明跳过 | **PASS** | 92 executed、0 skipped、零断言判失败；sum=128；父用例有断言 |
| 10 | 连续两轮独立复审无新增 HIGH | **PASS（第三轮）/ 证据待提交** | round1+round2+round3 事务/安全均完成；round3 两份报告确认 d5f2134 **无新增 HIGH**；新增 R3-01/R3-02 为 MED，F11 原始路径关闭；**两份 round3 报告当前 untracked，需提交** |
| 11 | 公开发布秘密扫描通过 | **PASS（secret）/ WAITING-USER（PII）** | Gitleaks 0；C-12 公网 IP/路径/用户名范围仍待用户决定 |
| 12 | 延期/阻塞项目明确披露 | **PASS** | RELEASE-GATE/ISSUE-LEDGER/TASK-STATE/TEST-MATRIX/USER-GUIDE 已披露；真实生产测试未执行、LONG_RUN deferred、轮换 blocked |

**Gate 汇总：PASS 11 / PARTIAL 1（Gate 1）；Gate 10 已由第三轮两份独立报告满足“无新增 HIGH”（报告待提交），但 R3-01/R3-02 为 MED、C-02 为既存 HIGH。**

### F11 专项

| 条件 | 状态 | 依据 |
|---|---|---|
| 根因明确 | **PASS（独立）** | round3 回到 git：`36222c9` 的 `Set-V4SystemProxy` 无 guard；探针 05:02:37 处于未提交中间态；事故文档描述一致 |
| 责任代码修复 | **PASS** | `Enable-V4ProductionWrites` + test registry writer + 测试模式 Start/Stop no-op + `Run-Tests.ps1` 强制 V4_TEST_MODE/ROOT；FT16–21 |
| 测试隔离独立复审 | **PASS（条件披露）** | ROUND3-TRANSACTION + ROUND3-SECURITY 独立确认 F11 原始 V4 写路径关闭；GENERAL 旧 V1–V3/diag 写面仍 R3-01 MED |
| FT16–FT21 | **PASS** | 冻结全量 6/6；FT16/17/18/19/21 断言真实 HKCU 前后一致；FT20 DEGRADED |
| 未授权生产配置修改为零 | **PASS（测试断言）** | FT21 HKCU/WinHTTP 前后一致；我的测试未写 HKCU；但 R3-01 旧脚本写面仍是已知风险 |
| 不再造成网络中断 | **PASS（隔离证据）** | 生产写门闩 + test writer；真实使用仍需用户观察 |

## 3. F01–F10 裁定

| ID | 裁定 | 证据 | 残余/边界 |
|---|---|---|---|
| F01 | VERIFIED-CLOSED | INF-PARAM-01/02、INF-DRYRUN-01；`apply:31-35` 互斥 | DryRun 仍写日志/锁/TEMP（LOW） |
| F02 | VERIFIED-CLOSED | journal 先于首写；F07-15、INF-JOURNAL-01 | snapshot→journal 崩溃窗口仍在（MED，已披露） |
| F03 | VERIFIED-CLOSED | 锁 token/processStart；F09-02/INF-LOCK-02；恢复在锁内 | 真实双 apply 并发未演练 |
| F04 | VERIFIED-CLOSED | F08-01/06/09；每次重写 updated | 真实 Clash 启动改写 profiles.yaml 未验证 |
| F05 | VERIFIED-CLOSED | META 7/7 + 92/92；旧套件退役转发 | 旧入口仍可触发全量测试（文档警告） |
| F06 | VERIFIED-CLOSED | INF-F06-01：strict=select 无 DIRECT；resilient=fallback 含 DIRECT | 无 |
| F07 | VERIFIED-CLOSED（引擎/集成） | 16 例；F07-05/09 改为可证伪；F07-16 停后重读；round3 变异 M1/M2 证伪 | 真实 apply 全链路未执行 |
| F08 | VERIFIED-CLOSED | 10 例；foreign block 不变 | `Test-V4ProfileText` 只校验 target block（MED 防御纵深） |
| F09 | VERIFIED-CLOSED | F09-SUITE（真实 apply 持锁 exit 33/不写 settings/不删 winner）、INF-APPLY-INIT-01、INF-INIT-01..04 | 20s 等待时序未压测 |
| F10 | VERIFIED-CLOSED | F10-01..10 + INF-LOG-01/02 | rollback catch 已由 INF-ROLLBACK 覆盖主路径 |

## 4. R2A / R2C / C / R3 残余独立裁定

| 项 | 状态 | 独立依据/说明 |
|---|---|---|
| R2A-01 rollback 失败路径未持锁启动 | **CLOSED** | `d5f2134` 先 `Test-V4SnapshotManifest` 再置 restoreAttempted；锁忙 33；INF-ROLLBACK-03；round3 独立确认 |
| R2A-02 mixedPort | **CLOSED** | rollback 读 settings.mixedPort；INF-ROLLBACK-04 |
| R2A-03 空/缺 profiles.yaml 清单 | **CLOSED** | Test-V4SnapshotManifest 拒绝零条目/缺 profiles.yaml；INF-SNAP-06/07 |
| R2A-04 还原后 ACL | **CLOSED** | Restore-V4Files 调 Protect-V4Acl；INF-SNAP-08 |
| R2A-05 停应用前读 profiles.yaml | **CLOSED** | ProfileTextBuilder 在 snapshot 后重读；F07-16 |
| R2A-06 journal commit phase | **OPEN（MED）** | 当前 fail-closed（保守要求 rollback）；已披露，未关闭 |
| R2A-07 零断言/证据绑定 | **CLOSED** | 零断言判失败；final.json 干净绑定 d5f2134；92 用例 sum=128 |
| R2A-08 测试隔离依赖环境 | **CLOSED（round3 更正）** | fixture 显式设 V4_TEST_MODE/ROOT；runner 兜底；残余只是 defense-in-depth |
| R2A-09 F07-05/09 不可证伪 | **CLOSED** | failAcl/stopCalls 改造；round3 M1/M2 变异证伪 |
| R2A-10/11/13/14/15 | **OPEN（LOW）** | 锁 TOCTOU、null processStart、原子写残留、DryRun 真实 workdir、委托缺失 |
| R2C-01 安装树 ACL | **MITIGATED（环境前提）** | 实测 root/proxy_v4/proxy_v6/.git 目标 ACL 仅 SYSTEM/Administrators/当前用户；repo-acl 1601 targets |
| R2C-03 settings ACL 读取校验 | **CLOSED** | Get-V4Settings 校验 config/settings ACL；INF-SETTINGS-04 |
| R2C-04 恢复 ACL | **CLOSED** | INF-SNAP-08 |
| R2C-05 evidence ACL | **MITIGATED** | repo/evidence/reviews ACL 加固；提交证据含本地路径仍 PII |
| R2C-06 PII | **WAITING-USER** | 19 个公网 IP/49 用户路径/96 项目路径/1 用户名；不得擅自改写历史 |
| R2C-07 证据绑定旧 HEAD | **PARTIAL** | final.json 干净；selftest 仍旧 HEAD dirty（R3-04） |
| R2C-08 脱敏 | **PARTIAL** | JSON key/Cookie/空格已遮；URL username、`X-Api-Key`/`apikey` 仍泄漏（round3-security 实测） |
| R3-01 旧脚本直接写 HKCU | **OPEN（MED）** | `proxy_diag`/`proxy_v2`/`proxy_v3` 的 Set-SystemProxy 无 latch/test guard；F11 类风险可经旧入口重现 |
| R3-02 系统代理写非原子 | **OPEN（MED）** | ProxyServer/ProxyEnable 两次写，中途失败可留不一致；建议备份/验证/回滚 |
| R3-03/04/05 | **OPEN（LOW）** | 继承 V4_TEST_* 未清理；selftest 未重绑；文档过度声明/C-04 早退 |
| C-01 快照明文 | **PARTIAL / ACCEPTED-RISK** | ACL 先加固、失败中止；未加密、无保留期；用户需明示接受 |
| C-02 -StaticPass | **OPEN（HIGH，已文档化）** | CLI 参数仍在；文档已警告；用户需书面接受“仅 -Init 显式迁移”或移除/改安全输入 |
| C-12 PII | **WAITING-USER** | 公网 IP/用户路径/项目路径/用户名；发布范围由用户决定 |

## 5. F11 事件记录与独立复审

- **记录**：`proxy_v6/INCIDENT-2026-11-18.md` 已提交，包含现象、根因（主代理 05:02:37 临时探针 `Set-V4SystemProxy -Server 'x'`）、恢复（05:34/05:35 人工 HKCU 修复）、影响范围、修复和 FT16–21。
- **根因可核对**：基线 `36222c9` 的 `Set-V4SystemProxy` 确无 `Assert-V4ProductionOperation`；`abe0eaa` 才加入 guard；round3 回到 git 复核一致。
- **独立复审**：ROUND3-TRANSACTION + ROUND3-SECURITY 均已出具；确认 F11 原始 V4 探针路径关闭、d5f2134 未新增 HIGH；R3-01（旧脚本写面）/R3-02（非原子写）为 MED。F11 专项可判 PASS，但 C-02 仍 HIGH。**两份报告目前 untracked，需提交并更新 Gate/ISSUE-LEDGER 的 F11 状态。**
- **文档缺陷**：INCIDENT 后半仍写“ProxyServer='x' 来源未能从现有日志确定”，与已定位根因冲突；“未接触 HKCU”未区分探针和测试。需修正（LOW/MED）。
- **我的边界**：我没有执行/验证 HKCU 修复；只读记录；未写 HKCU。生产当前状态以用户/事件记录为准，不由我确认。

## 6. 真实生产测试 / 长稳 / 凭据

| 项 | 状态 |
|---|---|
| 真实生产 apply/rollback/state | **未执行（DEFERRED-BY-USER）**；隔离 92/92 不能冒充 |
| 真实重启/睡眠/Wi-Fi/断网 | **未执行（DEFERRED-BY-USER）** |
| 24h/72h 长稳 | **DEFERRED-BY-USER**；LONG_RUN 不在本次验收 |
| NexIP 密码轮换 | **BLOCKED-USER**；不得声称已轮换 |
| Clash 2.5.10 缺 150bfae / #8593 | **OPEN（上游）** |
| 服务资格 | **NOT_READY**（第三方资格不由本项目测试决定） |

**明确不接受**：任何“真实生产 apply/rollback/boot 已验证”的说法；本报告没有任何此类证据。

## 7. 阻塞项与转绿条件

| # | 阻塞项 | 完成判据 |
|---|---|---|
| B1 | round3 报告入库/状态更新 | 实质复审已满足（两份 round3 确认 F11 原始 V4 路径关闭、d5f2134 无新增 HIGH）；但报告当前 untracked，需提交并更新 RELEASE-GATE/ISSUE-LEDGER 的 F11 状态与 Gate 10 |
| B2 | C-02 HIGH 用户处置 | 用户书面接受“仅 -Init 显式迁移、命令行密码风险自担”，或移除 `-StaticPass`/改安全输入；C-01 明文快照与 C-12 PII 同步书面接受/决定 |
| B3 | canonical self-test 证据刷新 | 在干净树 `b9bb9a0`（或后继）重跑 META 并提交 `selftest.json`，`dirty=false`、head=最终代码提交 |
| B4 | F11 事件文档修正 | 删除/修正“来源未能确定”矛盾行；明确探针 vs 测试的 HKCU 边界 |
| B5 | R3-01/R3-02 与既有残余 | 给旧 V1–V3/diag 写 HKCU 脚本加退役标记/latch（R3-01）；系统代理写改可回滚/验证（R3-02）；R2A-06、R2A-10/11/13/14/15、R3-03/04/05、R2C-08/C-04/C-15 保持 OPEN/ACCEPTED 并披露 |
| B6 | 真实环境范式 | 真实 apply/rollback/boot/24h 继续 DEFERRED；不得以隔离测试冒充；由用户另行执行并记录 |

关闭 B2–B4，且 B5 修复或书面接受后，可转 **SHORT_RUN_ACCEPTED（有条件）**；B6 作为已披露延期不阻止短跑。

## 8. 最终裁定

**NOT_READY**（不是 BLOCKED：B2–B5 可执行）。

- **代码层**：冻结 `b9bb9a0` / 代码 `d5f2134` 独立全量 **92/92、0 skip、0 zero-assertion、assertions sum=128、exit 0**；META **7/7、exit 0**；最终 `final.json` 干净绑定；Gitleaks 0；round3 两报告确认无新增 HIGH。
- **发布层**：Gate 1 PARTIAL（C-02 HIGH 未关闭、C-01/C-12 需用户接受、R3-01/R3-02 MED）；Gate 8 证据缺口（selftest 陈旧）；Gate 10 实质满足但 round3 报告未提交；F11 文档矛盾行。
- **明确不接受**：真实生产 apply/rollback/boot/24h/72h 未执行；凭据未轮换。
- 条件 B2–B4 满足、B5 处置后可转 **SHORT_RUN_ACCEPTED（有条件）**；LONG_RUN 仍 DEFERRED-BY-USER，SERVICE_ELIGIBILITY 仍 NOT_READY。

---

本报告只新增评审/证据文件，未改生产代码或跟踪文件（除本报告与可选的 `agent-e-acceptance-round2.json`）。审查对象与时间已固定；后续提交若改代码，需重新验收。

---

## DELTA — `0268e17` / `990d896`（2026-11-18T06:22-08:00）

**对象（精确）**：代码 `0268e17`；证据 `1c7fdad`（final.json head=0268e17, dirty=false, 94/94）；canonical self-test `ebbf2e6`（head=0268e17, dirty=false, 7/7）；docs `990d896`；报告时 repo HEAD=`076c975`（仅 Gate/TASK-STATE docs 更正，未改代码/证据），origin 同点。

### D.1 独立执行的增量证据

| 项 | 结果 |
|---|---|
| 目标 INF 子集（`Run-Tests.ps1 -Filter 'INF-*'`，TEMP） | **51/51 PASS，exit 0**；head=990d896，dirty=false；0 零断言、0 skip；available=94 |
| META-01..07（TEMP） | **7/7 PASS，exit 0**；head=990d896，dirty=false |
| 提交的 final.json（只读） | head=0268e17，dirty=false，**94/94**，0 skip，0 zero-assertion，sum=130，94 个 per-case 文件齐全 |
| 提交的 selftest（只读） | head=0268e17，dirty=false，**7/7**，exit 0 |
| C-02 源码核对 | 参数名改为 `-StaticPassFile`；但 PowerShell 唯一前缀绑定使旧拼写 `-StaticPass` **仍绑定到 `StaticPassFile`**。独立复现：CWD 无 `fixture-pass` → exit 11（credential file not found）；CWD 放入同名文件 → exit 10 且 settings 被写。故 `INF-APPLY-INIT-02`（“旧参数被拒”）是**假阳性**；文档/账本的“不再接受 -StaticPass”不准确 |
| F12 代码核对 | `Get-V4UiSystemProxy` 读取 `verge.yaml` 的 `enable_system_proxy`；`Get-V4StateCore` 加 `uiSystemProxy` 并在 UI/HKCU 不一致时 DEGRADED + reason；`state-v4` 输出该字段；`INF-F12-01` PASS |
| C-04/C-08/R3-02 | owner SID 校验已加；URL/JSON/API-key 脱敏已加（INF-REDACT-03 PASS）；系统代理两次写加失败补偿 |
| 新 HIGH | **未发现**（增量只读状态/脱敏/ACL owner/写补偿；无新增 HKCU/网络写路径） |

### D.2 逐项确认

- **C-02：PARTIAL / 不可审计地关闭**。参数名确实改为 `-StaticPassFile`，但 PowerShell 的唯一前缀绑定让旧命令行 `-StaticPass <密码>` **仍然可运行**（被当作 `-StaticPassFile <密码>`）：在临时 CWD 中无同名文件时 exit 11，有同名文件时 exit 10 且写 settings。也就是说：
  1) 旧拼写的秘密值仍会进入命令行/PSReadLine 历史（原 C-02 的核心暴露）；
  2) `INF-APPLY-INIT-02` 的“参数被拒”通过只是因为文件不存在，不是显式拒绝，是假阳性；
  3) 文档/账本“不再接受 -StaticPass”不准确。

  建议最小修复：增加墓碑参数 `[string]$StaticPass`，绑定后立即 `Fail 11 'removed; use -StaticPassFile <protected file>'`（不记录值）；`INF-APPLY-INIT-02` 断言该文案且在有同名文件时也不得写 settings；同步改文档。另有 LOW：`-StaticPassFile` 内容未做 ACL 校验，用户需保证文件受保护。
- **F12：分类正确，报告部分**。A+C（F11 应急恢复 + UI/实际不一致，非新污染）的定性合理；代码在 **settings 存在时**会把 UI/HKCU 不一致报为 DEGRADED 并附 reason，`INF-F12-01` 已覆盖。**但当前 production `proxy_v4/config/settings.json` 不存在**；`Get-V4StateCore` 在 `SettingsError`/`Settings=null` 时**先 return FAILED**，不会走到 UI mismatch 分支。独立复现：missing settings → `FAILED`，`uiSystemProxy=enabled`，reasons 仅 `settings.json missing`（无 UI 不一致 reason）；with settings → `DEGRADED` + UI reason。即：**当前生产状态脚本实际会报 FAILED（settings missing），不是文档所写“DEGRADED + UI reason”**；`uiSystemProxy` 字段仍可见，但缺点 explicit reason。建议把 UI mismatch 检查移到 early return 之前（或在该分支补 reason），并加“settings missing + UI on”用例；否则 F12 文档需限定“settings 存在时”。`Get-V4UiSystemProxy` 的 `verge.yaml` 文件解析也未被 INF-F12-01 覆盖（测试只直接传 `-UiSystemProxy`），属测试缺口。
- **C-04**：owner SID 校验已加；但 `Test-V4AclHardened` 仍不检查继承标志/不设置 owner，round3-security 的 C-04 “非继承 DACL 早退”残余仍在；SECURITY-REVIEW 的 `C-04 CLOSED` 仍属过度声明（MED/LOW）。
- **C-08**：URL userinfo、JSON key、`X-Api-Key`/`apikey`、Cookie 已遮；`INF-REDACT-03` 已加强并 PASS；可判 CLOSED（残余 `Harness.Protect-HarnessText` 与生产 `Get-V4Redacted` 是两套实现，未合并）。
- **R3-02**：系统代理两次写加本地补偿；仍非跨进程原子，且补偿无独立失败用例；保持 MED/部分修复。
- **R3-01**：旧 `proxy_diag`/`proxy_v2`/`proxy_v3` 入口仍可直接写 HKCU；本轮未改，仍 OPEN MED（F11 类风险可经旧入口重现）。
- **Gate 文档仍滞后**：`RELEASE-GATE-V6.md`（076c975）仍写 Gate 10 **FAIL**、F11 专项 **PENDING**、“SHORT_RUN_ACCEPTED 未达”；`ISSUE-LEDGER` F11 仍 `FIXED-PENDING-INDEPENDENT-REVIEW`；`TASK-STATE` 仍写旧 HEAD/远端（ebbf2e6/990d896）。实际上 round3 两份报告已随 `0268e17` 提交、C-02 已关闭、最终证据为 `1c7fdad`/`ebbf2e6`；这些记录需更新，否则发布记录与代码不一致。
- **C-01/C-12**：仍为 PARTIAL/WAITING-USER（明文快照、公网 IP/路径/用户名）；需用户书面接受/决定。
- **R2A-06**：journal commit phase 仍 OPEN（MED，fail-closed）；R2A-10/11/13/14/15、R3-03/04/05 等 LOW 保持 OPEN/ACCEPTED。

### D.3 增量裁定

**Delta verdict: NOT_READY**。

代码层短跑证据仍然强（94/94、自验 7/7、目标 INF 51/51），增量未新增功能性 HIGH；但 **C-02 因前缀绑定未可审计关闭**，且 F12 在当前 settings 缺失状态下报告不全，不能签署。转为 **SHORT_RUN_ACCEPTED（有条件）** 的最低条件：

1. **C-02 tombstone**：显式拒绝 `-StaticPass`（含旧拼写）并让 `INF-APPLY-INIT-02` 断言显式拒绝文案，不再依赖“文件不存在”；文档/账本改写为“旧拼写被拒绝”。
2. **F12 报告修正**：把 UI mismatch 检查放到 settings 缺失 early return 之前，或明确文档仅适用于 settings 存在；补 `settings missing + UI on` 用例与 `Get-V4UiSystemProxy` 文件解析用例（当前 production settings 缺失，state 实际 FAILED 而非 DEGRADED+reason）。
3. **C-01/C-12 用户书面处置**：接受 ACL 保护的明文快照、公开 IP/路径/用户名范围，或完成加密/脱敏。
4. **Gate/账本/TASK-STATE 更新**：Gate 10/F11、C-02/C-04/C-15、94/94/1c7fdad/ebbf2e6、HEAD 990d896/076c975 与 origin 同步状态；不得保留 Gate 10 FAIL/F11 PENDING。
5. **R3-01/R3-02 处置**：旧 diag/v2/v3 写 HKCU 入口加退役/latch（或书面接受）；R3-02 补补偿失败用例或接受非原子残余；R2A-06/C-04 残余保持披露。
6. **真实环境范式**：真实 apply/rollback/boot/24h/72h 未执行，继续 DEFERRED-BY-USER；LONG_RUN 不在本次；凭据轮换 BLOCKED-USER。

**明确不接受**：把隔离 94/94 当作真实生产 apply/rollback/boot 验证；本 delta 没有执行/验证真实 HKCU/网络/Clash。

---

## DELTA2 — `79198fd` / `32d8abc`（2026-11-18T06:36-08:00）

**对象（精确）**：代码 `79198fd`；最终证据 `32d8abc`（final.json head=79198fd, dirty=false, **97/97**, 0 skipped, 0 zero-assertion, sum=133）；canonical self-test head=79198fd, dirty=false, 7/7；docs `103f707`；gitleaks allowlist `dbbd259`；当前 HEAD=`dbbd259`，origin 同点，工作树干净。

### E.1 独立增量证据

| 项 | 结果 |
|---|---|
| 旧拼写墓碑（TEMP/test mode，同名文件存在） | `-StaticPass 'fixture-pass'` → **exit 11，`-StaticPass was removed; use -CredentialFile`**，无 settings；`-StaticPassFile 'fixture-pass'` → **exit 11，removal message**，无 settings |
| 新 `-CredentialFile`（TEMP，ACL hardened） | 合法文件 → **exit 10**，settings 被写（随后因无 appdata 路径失败，预期） |
| 目标用例 `INF-APPLY-INIT-*` | **3/3 PASS，exit 0**，head=dbbd259，dirty=false |
| 目标用例 `INF-F12-*` | **3/3 PASS，exit 0**，head=dbbd259，dirty=false |
| F12 missing-settings 复现（TEMP core） | Settings=$null + SettingsError='settings.json missing' + Ui=true → **FAILED**，`uiSystemProxy=enabled`，reasons=`UI reports system proxy enabled, actual HKCU is disabled` + `settings invalid: settings.json missing`；**不是 DEGRADED** |
| 提交 final.json（只读） | head=79198fd，dirty=false，**97/97**，0 skip，0 zero，sum=133，97 个 per-case 文件齐全 |
| 提交 selftest（只读） | head=79198fd，dirty=false，**7/7**，exit 0 |
| 独立 META | **7/7 PASS，exit 0**（TEMP） |
| Gitleaks | 工作树/历史 **0 findings**；`.gitleaks.toml` 仅允许 `proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1` 中合成字面量 `abcdef123456`，范围窄且已披露 |

### E.2 逐项确认

- **C-02：CLOSED（可审计）**。`-StaticPass` / `-StaticPassFile` 现在是显式墓碑参数，精确匹配、在 `$PSBoundParameters` 中检查后立即 `Fail 11`；即使 CWD 存在同名文件也不会被当作 `-CredentialFile` 路径。`INF-APPLY-INIT-02/03` 断言 removal message 而非“文件不存在”，前一轮的前缀绑定假阳性已消失。`-CredentialFile` 是唯一文件输入，`Test-V4AclHardened` 要求 ACL 合格。残余 LOW：用户若仍键入旧参数，秘密字符串会进入命令行/历史后才被拒绝；新文档用 `-CredentialFile`，这是用户操作风险，不是工具继续接受密码。
- **F12：正确**。当前 production `settings.json` 缺失，`Get-V4StateCore` 现在在 early return 前计算 UI mismatch 并追加 reason → **FAILED + UI reason**，不是 DEGRADED，也不是 HEALTHY；符合“当前是 F11 应急恢复 + UI mismatch，不是新污染”的定性。`INF-F12-02` 覆盖 missing settings + UI on；`INF-F12-03` 覆盖 `verge.yaml` true/false/缺键/缺文件；`Get-V4UiSystemProxy` 可通过 `V4_TEST_UI_CONFIG` 测试。残余 LOW：带引号的 `enable_system_proxy: "true"` 仍解析为 unknown（fail-open 于报告层，不影响安全/不会误报 HEALTHY）。
- **新 HIGH：无**。delta 只加墓碑/凭据文件 ACL 检查、F12 只读解析/报告；无新增生产写路径。
- **仍存的非 delta 残余**：C-01 明文快照、C-12 PII 需用户接受/决定；R3-01 旧 proxy_diag/v2/v3 仍可直接写 HKCU（MED）；R3-02 补偿仅进程内、仍非跨进程原子；C-04 继承标志残余；R2A-06 journal commit phase OPEN；R3-03/04/05 等 LOW。
- **Gate/账本仍滞后**：`RELEASE-GATE-V6.md`（dbbd259）仍写 Gate 10 **FAIL**、F11 **PENDING**、“SHORT_RUN_ACCEPTED 未达”；`ISSUE-LEDGER` F11 仍 FIXED-PENDING；`TASK-STATE` 仍写旧 HEAD/远端（ebbf2e6/32d8abc）。这些需更新为 79198fd/32d8abc/dbbd259、C-02 closed、F11 round3 confirmed、97/97。

### E.3 增量裁定

**Delta2 verdict: SHORT_RUN_ACCEPTED（有条件）**。

代码层短跑可接受：C-02 前缀绑定假阳性已消失（同名文件下墓碑仍 exit 11），F12 当前 production 报 FAILED + UI reason 正确，97/97/自验 7/7 干净绑定，无新 HIGH。**无条件发布仍 NOT_READY**，条件：

1. **C-01/C-12 用户书面处置**：接受 ACL 保护的明文快照、公开 IP/路径/用户名范围，或完成加密/脱敏。
2. **Gate/账本/TASK-STATE 更新**：Gate 10/F11、C-02/C-04/C-15、97/97、head 79198fd/32d8abc/dbbd259 与 origin 同步；不得保留 Gate 10 FAIL/F11 PENDING。
3. **R3-01/R3-02/C-04/R2A-06 处置/披露**：旧 diag/v2/v3 写 HKCU 入口加退役/latch 或书面接受；R3-02 补失败用例或接受非原子残余；C-04 继承标志/R2A-06 保持 OPEN。
4. **真实环境范式**：真实 apply/rollback/boot/24h/72h 未执行，继续 DEFERRED-BY-USER；LONG_RUN 不在本次；凭据轮换 BLOCKED-USER。

**明确不接受**：把隔离 97/97 当作真实生产 apply/rollback/boot 验证；本轮未执行/验证真实 HKCU/网络/Clash。
