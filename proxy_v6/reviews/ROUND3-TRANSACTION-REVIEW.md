# ROUND3 事务 / 并发独立复审 — code `d5f2134`（证据 `b9bb9a0`，HEAD `01baaf5`）

> 复审角色：round2-transaction（第三轮定向复审；不采信主代理自评）
>
> **复审对象（精确提交）**
> - 代码：`d5f2134`（"fix(v6): verify snapshot before allowing rollback restart"）。`b9bb9a0`、`6e3cd09`、`01baaf5` 与 `d5f2134` 在 `proxy_v4/**` 与 `proxy_v6/tests/**` 上 **`git diff` 为空**（已核）。
> - 证据：`b9bb9a0` 的 `proxy_v6/evidence/v6/final.json` + `final.cases/0001..0092`；`01baaf5` 只改 `evidence/v6/repo-acl.json`。
> - 复审结束时 HEAD：`01baaf5`（工作树干净）。
> - 中间目标亦已核对：`c562c18` / `93027c6`（与 `d5f2134` 的唯一代码差异 = `rollback-v4.ps1` 的 2 行 manifest 预校验）。
> - 上一轮报告 `ROUND2-TRANSACTION-REVIEW.md` 锚定 `abe0eaa`，保持原样不改（见 §6 的更正说明，不在旧文件上静默改结论）。

---

## 1. 结论摘要

| 维度 | 裁定 |
|---|---|
| **F11 根因** | **独立确认成立**：`36222c9` 的 `Set-V4SystemProxy` **完全没有** `Assert-V4ProductionOperation`；探针 05:02:37 运行时 `abe0eaa`（05:27:12 提交，才加入断言）尚不存在 → 测试模式只隔离了文件根，未隔离注册表 → 真实写 HKCU。见 §2 |
| **F11 隔离洞是否关闭** | **针对该写路径：已关闭**（测试模式无 writer 即抛；生产模式需门闩）。**广义"测试代码可改生产"面：部分关闭**（ACL 写入器、`Start-V4ClashCore -Launch`、settings/owner/journal 仍不受门闩约束）→ 新增 R3-01（MED），非 HIGH |
| **R2A-01** | **关闭**（锁内补救启动 + 锁忙 exit 33 + `INF-ROLLBACK-03` 断言 start.log 为空） |
| **R2A-02** | **关闭**（`settings.mixedPort` → `Restore-V4Snapshot -Port` 与 `Start-V4Clash -Port`；`INF-ROLLBACK-04` 断言 `|65532`） |
| **R2A-03** | **关闭**（零条目/未覆盖 `profiles.yaml` 的清单被拒；`INF-SNAP-06/07`） |
| **R2A-04** | **关闭**（恢复后逐文件 `Protect-V4Acl`；`INF-SNAP-08`；另有新副作用见 R3-05） |
| **R2A-05** | **关闭**（`ProfileTextBuilder` 在快照/停应用之后重读；`F07-16`；本报告 M-变异可证伪） |
| **R2A-06** | **仍开放（MED，已被文档承认为 OPEN）**：journal 无提交阶段；清 journal 失败/末写后崩溃仍会把用户推向"回滚一个良好状态" |
| **R2A-07** | **关闭**（零断言即失败；父用例执行 `Assert-*`；92/92 全部 `assertions≥1`，合计 128；干净树锚定） |
| **R2A-08** | **关闭（并对上一轮表述作更正）**：各 fixture 本来就显式设 `V4_TEST_MODE`；runner 现再兜底。上一轮"仅靠继承环境"表述过强 → 见 §6 |
| **R2A-09** | **关闭**（F07-05 改为"代理已设置后的失败"，F07-09 增加 `stopCalls≥1`；两个定点变异验证其可证伪） |
| **92/92 final.json 可信度** | **可信**：`head=d5f2134, dirty=false, 92/92, skipped=0, zeroAssert=0, sum=128`；我以 `git archive d5f2134` 的独立树复跑 **92/92, exit 0, runId 1c0a92ab…, sum=128**，逐项与提交证据一致 |
| **新增 HIGH** | **无** |
| **本轮新发现** | 1×MED（R3-01）+ 5×LOW（R3-02…R3-06） |
| **验收建议** | **事务/并发维度：SHORT_RUN 可接受**，条件见 §7（披露 R2A-06 + R3-01 等；不得声称真实生产 apply/rollback 已验证） |

---

## 2. F11 根因的独立验证（不采信叙述，回到 git）

### 2.1 关键事实（全部可复现）

| 检查 | 结果 |
|---|---|
| `36222c9` 的 `Set-V4SystemProxy` | `git show 36222c9:proxy_v4/lib/V4.ps1` → 函数体直接 `Set-ItemProperty HKCU…ProxyServer`，**无任何 Assert/测试模式分支** |
| `abe0eaa` | 同一函数**新增** `Assert-V4ProductionOperation 'Set-V4SystemProxy'`（测试模式抛错） |
| 提交时间线（reflog） | `36222c9` 04:40:46 → **探针 05:02:37** → `abe0eaa` 05:27:12 → `c562c18` 05:53:49 → `d5f2134` 05:58:20 |
| 探针文件 | `_probe-new.ps1` **从未进入任何提交**（`git log --all -- <path>` 为空，工作树不存在）；`git log -S 'GUARD FAIL'` 只命中 `c562c18`（事故文档） |
| 结论 | 事故发生在 `36222c9` 基线的脏工作树上；当时 `Set-V4SystemProxy` 处于**无守卫**状态，`V4_TEST_MODE=1` 只能隔离 `$script:Root`，注册表写入不受控 → 与事故文档描述**完全一致**。事故**不可归因于 `abe0eaa` 的已提交代码**（该提交已带断言），而是一次**未提交中间态 + ad-hoc 探针**导致 |

### 2.2 新隔离机制的安全动态验证（我在 `%TEMP%` 用函数级 stub 完成，未触真实注册表/进程）

方法：子进程 dot-source `V4.ps1`（**生产模式**，不设 `V4_TEST_MODE`），在 dot-source 之前用同名函数覆盖 `Set-ItemProperty`/`Start-Process`/`Stop-Process`/`Get-Process`，dot-source 之后再覆盖 `Update-V4WinInet`——**即使守卫失效也不可能触达真实注册表**；同时只读比对真实 HKCU 前后值。

| 用例 | 结果 |
|---|---|
| L1 生产模式、未 `Enable` → `Set-V4SystemProxy` | 抛 `V4 production write blocked (call Enable-V4ProductionWrites …): system proxy registry write`；registry stub 0 次；真实 HKCU 不变 |
| L2 未 `Enable` → `Clear-V4SystemProxy` | 抛错，0 次写 |
| L3 未 `Enable` → `Start-V4Clash`/`Stop-V4Clash` | 均抛错，未触达 process stub |
| L4 `Enable-V4ProductionWrites` 后 → `Set-V4SystemProxy 'x'` | 恰好 2 次 stub：`ProxyServer=x`、`ProxyEnable=1`；真实 HKCU 不变 → **门闩是唯一闸门** |
| L5 `Clear` | `ProxyServer=<当前值>` + `ProxyEnable=0`（保留 ProxyServer） |
| L6 `V4_TEST_MODE=1` 且无 writer | 抛 `no test registry writer is installed`；`Enable` 返回 false 且不解除 |
| L7 `V4_TEST_MODE=1` + 安装 mock writer | 仅 mock 被调用；registry stub 0 次；真实 HKCU 不变 |

**结论**：F11 的"测试进程裸写 HKCU"路径关闭；L4 同时证明"一旦显式 `Enable`，写入即发生" → 门闩是**行为门闩**，不是能力沙箱（见 R3-01）。

### 2.3 F11 回归用例评估（FT16–FT21）

- `Run-FT-Case.ps1:18-20` 先设 `V4_TEST_MODE=1` 再 dot-source；每个"写"都走 mock；每次前后只读比对 HKCU（`ProxyEnable/ProxyServer/AutoConfigURL/ProxyOverride`）与 `netsh winhttp show proxy`（`Get-WinHttpSnapshot`）。
- **可证伪性**：若 test-mode 分支退回真实注册表，`Snapshot-Equal` 会在 FT16/17/18/19/21 变红（该断言比较真实 HKCU 的前后值）；FT20 用 `Get-V4StateCore` 证明 `ProxyServer=x` / 错误出口 IP **只能是 DEGRADED，不能是 HEALTHY**——即事故状态在 `state-v4.ps1` 上可见（该逻辑在 `abe0eaa` 已存在，FT20 是回归护栏）。
- **局限**：这些用例只读真实 HKCU，不写；它们验证的是"守卫存在且有效"，不是"生产路径真的会写"（后者按定义不可在隔离测试里执行）。

---

## 3. R2A-01 … R2A-15 逐条状态（目标 `d5f2134`）

| ID | 上轮严重度 | 现状 | 依据（行号为 `d5f2134`） |
|---|---|---|---|
| R2A-01 rollback 无锁补救启动 / 锁忙 40 | HIGH | **关闭** | `rollback-v4.ps1:43-48`（锁忙 `$exit=33` + `return`，不进入补救）；`:84` 仅 `$restoreAttempted` 为真才启动；`INF-ROLLBACK-03` 断言 `exit 33`、winner 锁仍在、`start.log` 为空。残余（c562c18 期）"清单非法也补救启动"已由 `d5f2134:57` 预校验修复；但**无回归用例断言该点** → R3-03 |
| R2A-02 硬编码 7897 | MED | **关闭** | `rollback-v4.ps1:20-22`（读 `settings.mixedPort`）→ `:59` `Restore-V4Snapshot -Port`、`:71/:86` `Start-V4Clash -Port`；`INF-ROLLBACK-04` 断言 start.log 含 `|65532` |
| R2A-03 空/残缺清单当成功 | MED | **关闭** | `V4.ps1:884-885`（无条目拒绝、必须覆盖 `profiles.yaml`）；`INF-SNAP-06/07` |
| R2A-04 恢复不重新加固 ACL | MED | **关闭** | `V4.ps1:909`（逐文件 `Protect-V4Acl`，失败即该条失败）；`INF-SNAP-08` 验证重建文件已加固 |
| R2A-05 读-停-写顺序 | MED | **关闭** | `V4.ps1:234`（快照后调用 `ProfileTextBuilder`）；`apply-v4.ps1:132-143,167`；`F07-16` + 本报告 M2 变异（关恢复时长红） |
| R2A-06 无提交阶段 | MED | **仍开放** | journal 结构未变（无 phase）；`V4.ps1:262-263` / `:292-293` 清除失败仍只 WARN；`CHANGELOG`/`TASK-STATE` 已如实标 OPEN |
| R2A-07 零断言/证据锚定 | MED | **关闭** | `Harness.ps1:441-443`（零断言=fail）；`ReproHelpers`/`Invoke-InfraCase`/`Invoke-FTCase` 改用 `Assert-*`；提交证据 92/92、`assertions` 合计 128、`head=d5f2134, dirty=false`；我的独立复跑同为 128 |
| R2A-08 隔离依赖继承环境 | MED | **关闭（并更正）** | 各 fixture 本就显式设 `V4_TEST_MODE/ROOT`（`Repro-F09.ps1:7-8`、`Run-InfraCase.ps1:17-18`、`Run-FT-Case.ps1:18-19`），runner 再兜底（`Run-Tests.ps1:29-30`）。上轮"仅靠继承"表述过强 → §6 |
| R2A-09 F07-05/09 不可证伪 | MED | **关闭** | `Repro-F07.ps1:176-182`（failAcl 使故障发生在 SetSystemProxy 之后）、`:212-221`（`stopCalls≥1`）；变异 M1/M2 见 §5 |
| R2A-10 锁是路径文件（TOCTOU/ABA） | LOW | **仍开放** | `Enter/Exit-V4Lock` 未改（`V4.ps1:604-687`）：获取=建+写+关，释放=读+比对+按路径删 |
| R2A-11 processStart=null + PID 复用 | LOW | **仍开放** | `V4.ps1:619-624` 仍 `if ($j.processStart -and …)` 跳过校验 |
| R2A-12 缺 systemProxy 时清代理 | LOW | **关闭** | `rollback-v4.ps1:62` `if (-not $KeepSystemProxy -and $m.systemProxy)`；`:75` 同样判空 |
| R2A-13 原子写硬杀残留 | LOW | **仍开放** | `Set-V4Atomic`（`V4.ps1:940-972`）未加启动清扫；`.bak` 仍是明文凭据副本 |
| R2A-14 DryRun 对真实 appdata 跑 mihomo | LOW | **仍开放** | `apply-v4.ps1:112-113` 仍 `-WorkDir $p.AppData` |
| R2A-15 恢复委托缺失视为成功 | LOW | **仍开放** | `Invoke-V4Recovery`（`V4.ps1:114-173`）未改 |

**统计**：关闭 10（R2A-01/02/03/04/05/07/08/09/12 + F11 根因链）；仍开放 6（R2A-06 MED + R2A-10/11/13/14/15 LOW）。

---

## 4. 本轮新发现

### R3-01 MED — 生产写门闩只覆盖"注册表/进程入口"，其余真实副作用能力未受约束

- **位置**：`V4.ps1:38-56`（门闩 + `Assert-V4ProductionOperation`）；受约束的只有 `Stop/Start-V4Clash`、`Write-V4SystemProxyRegistry`（`V4.ps1:705,752,997`）。**未受约束**：
  - `Protect-V4Acl`（`V4.ps1:570-596`，直接 `SetAccessControl`）——生产模式任意路径可被改 DACL（即 A-21 那类能力仍在）；
  - `Start-V4ClashCore -Launch { … }`（`V4.ps1:728-758`，公共函数，无 Assert）——可绕过 `Start-V4Clash` 的门闩直接 `Start-Process`；
  - `Save-V4Settings`/`Set-V4Owner`/`Write-V4Journal`（写仓库内 config/owner/journal）、`New-V4Snapshot`（复制真实 appdata 到仓库 backup/）。
- **触发**：生产模式下（`V4_TEST_MODE` 未设）任何被 dot-source 的脚本直接调用上述函数；或探针照抄 `apply/rollback` 头两行 `Enable-V4ProductionWrites` 后再调 `Set-V4SystemProxy`（L4 已证：一次 `Enable` 即恢复写入能力）。
- **期望**：把 ACL 写入、`Start-V4ClashCore` 的 `Launch`、settings/owner/journal 写入也纳入同一门闩（或改为"按操作类型的能力 token"）；`Enable` 不应是一个可随意调用的全局开关，而应由 `apply/rollback` 主流程在明确阶段开启并在退出时关闭。
- **实测**：L4（armed → 2 次 stub 写）；静态清单见上。
- **最小隔离测试**：现有 L1–L7 探针（`%TEMP%`，stub 化）；再加一条"生产模式下 `Protect-V4Acl <temp 文件>` 应被拒绝"的用例——当前会成功。
- **为何不是 HIGH**：不存在"纯 dot-source + 单次普通调用"即可触达 HKCU/进程/网络中断的路径（F11 那条已封）；剩余能力都要显式传入路径/脚本块或先 `Enable`。

### R3-02 LOW — ACL 门禁改变了错误码语义，`INF-STATE-SCRIPT-01` 已不再测试"损坏 JSON"

- **位置**：`V4.ps1:375-376`（`Get-V4Settings` 先查 ACL，再解析 JSON）。
- **触发**：未加固的 `config` 目录 + 损坏的 `settings.json`（正是 `INF-STATE-SCRIPT-01` 夹具的构造）。
- **期望/实测**：加固后损坏 JSON → 11（A1 实测）；未加固 + 损坏 JSON → **12**（A2 实测）。因此 `state-v4.ps1` 的 FAILED 原因是"ACL 未加固"而非"JSON 损坏"，该用例只因 `reasons -match 'settings'` 而通过——**用例名与断言意图不符**（覆盖由 `INF-SETTINGS-02` 在加固文件上补足）。
- **最小隔离测试**：`%TEMP%` 下构造上述两个目录，断言 11 vs 12（我已执行，3/3）。
- **建议**：夹具先 `Save-V4Settings` 加固再写损坏 JSON（与 INF-SETTINGS-02 一致），或把断言改为匹配 `settings`+`ACL|JSON` 二选一。

### R3-03 LOW — `d5f2134` 的"清单非法不补救启动"修复没有回归用例

- **位置**：`rollback-v4.ps1:57-58`（先 `Test-V4SnapshotManifest`，通过后才置 `$restoreAttempted=$true`）。
- **触发**：篡改快照后 rollback。
- **现状**：`INF-ROLLBACK-02` 只断言 exit 40 / live 文件不变 / 锁已释放，**未断言 `start.log` 为空**（`INF-ROLLBACK-03` 才断言该点，但那是锁忙路径）。因此若未来把 `:57` 删掉，92/92 仍会全绿。
- **最小隔离测试**：`INF-ROLLBACK-02` 增加 `V4_TEST_START_LOG` 与"日志必须为空"的断言（照抄 `INF-ROLLBACK-03` 的写法）。

### R3-04 LOW — rollback 的 41 仍会被 40 覆盖（D-24 残余）

- **位置**：`rollback-v4.ps1:68/77` 置 41，`:84-91` 的 catch 无条件 `$exit=40`。
- **触发**：系统代理校验失败后，`Start-V4Clash`/`Set-V4Owner` 再抛异常。
- **期望**：保留 41（或 41 优先于 40），便于区分"代理未还原"与"文件恢复失败"。

### R3-05 LOW — 恢复对**快照内全部文件**加固 ACL，一个 DACL 失败即把内容正确的恢复判为失败

- **位置**：`V4.ps1:909`（`Restore-V4Files` 对每个条目 `Protect-V4Acl`，失败即计入 failures → `Restore-V4Snapshot` 抛错 → rollback exit 40、journal 保留）。
- **触发**：恢复 `profiles\*.yaml`（用户订阅文件，含无关文件）时某文件 DACL 无法设置（只读卷/属主异常/被占用），或用户不希望订阅文件 ACL 被改写。
- **期望**：只对凭据承载目标（`clash-verge.yaml`、`v4-managed.yaml`）强制加固；其余文件加固失败降级为 WARN，不把内容恢复判失败。
- **注**：这是 R2A-04 修复带来的新副作用；风险低（fail-closed），但会放大"回滚失败 → 再回滚"的循环概率。

### R3-06 LOW — 测试文档未登记两条新契约

- `Harness.ps1:441-443` 现在把"零断言"判 FAIL，但 `proxy_v6/tests/README.md` 的退出码契约与用例约定未更新；
- `Run-Tests.ps1:29-30` 会在 `%TEMP%\v6-runner-<pid>` 建根且**不清理**（临时残留）；
- FT16–21 会**只读**真实 HKCU 与 `netsh winhttp show proxy`，属"生产只读"，应在测试契约中显式声明（否则用户中途改代理会让用例变红）；
- **FT 的"无写入"断言是事后检测式**：若 test-mode 分支将来回归，用例会在**已经真实写入 HKCU 之后**才变红——即 CI 自身可能复现 F11 的故障。缓解只能靠隔离账户/一次性虚拟机或注册表路径注入（当前无）。这应作为测试台残余风险写入发布说明。

---

## 5. 92/92 与证据可信度（独立复现）

| 项 | 提交证据（`b9bb9a0` 的 final.json） | 我的独立复跑（`git archive d5f2134` → `%TEMP%\r3tree-d5-*`） |
|---|---|---|
| 命令 | `Run-Tests.ps1 -OutFile proxy_v6\evidence\v6\final.json` | `Run-Tests.ps1 -OutFile %TEMP%\r3-final-20261118-060129.json` |
| runId | `b0e6fadece3e437a936f88f9508acdbb` | `1c0a92ab9aee48bc90aee5973dff77ce` |
| 时间 | 05:58:25 → 06:00:22（`d5f2134` 提交于 05:58:20，**之后**；`b9bb9a0` 提交于 06:00:32） | 06:01:29 → 06:03:29 |
| git | `head=d5f2134`、`dirty=false` | `git.available=false`（git-archive 导出树，无 .git；代码与 d5f2134 逐字节一致） |
| 计数 | 92/92，skipped=0，harnessErrors=0，evidenceErrors=0 | **92/92**，skipped=0，harnessErrors=0，evidenceErrors=0，exit 0 |
| assertions | 0 个零断言用例；min=1，sum=**128** | 0 个零断言用例；min=1，sum=**128** |
| 逐例证据 | `final.cases/0001..0092`（每例 `assertions≥1`） | 同结构，样例断言值一致（如 F07-01=2、INF-ROLLBACK-01=1、FT16=1） |

**结论**：`final.json` 满足"干净树 + 代码提交锚定 + 断言>0 + 零跳过"，且与我的独立运行**逐项一致**（含 assertions 总和 128）。可信。
**仍需声明的方法学边界**：① F07 仍是"引擎 + 全 mock ops"（`Repro-F07.ps1:97-131`），**`apply-v4.ps1` 的真实 ops/ctx 接线（含新的 `ProfileTextBuilder`）至今没有任何端到端用例执行**（DryRun/JOURNAL/PARAM/APPLY-INIT 都在 `apply:119` 之前返回或退出）；② rollback 现在有真实脚本端到端用例（`INF-ROLLBACK-01..04`），是实质进步；③ FT 用例只读生产状态。

**可证伪性（本轮变异，全部在 `%TEMP%\r3tree-d5-*` 副本上）**：
- M1 关闭代理还原（`if ($beforeProxy) {`→`if ($false) {`）→ `F07-05` **变红**（上轮为常绿空洞）、`F07-10` 变红；14/16。
- M2 关闭恢复门槛（`if ($snap -or $applied -or ($null -ne $wasRunning)) {`→`if ($false) {`）→ `F07-09` **变红**（"recovery was skipped entirely"）等 11 项，5/16。
→ R2A-09 的两个空洞确实被修复。

---

## 6. 对上一轮报告的更正（不修改旧文件）

- **R2A-08 表述过强**：上一轮写"真实脚本用例仅凭继承环境变量实现隔离"。复核后：`Repro-F09.ps1`、`Run-InfraCase.ps1`、`Run-FT-Case.ps1` 都在自己进程内**显式**设 `V4_TEST_MODE/V4_TEST_ROOT` 后再 spawn 子进程，隔离并非"偶然继承"；真正的残余只是"测试辅助不注入环境、子进程无 `Root` 自证"，以及"直接手跑 `apply-v4.ps1` 会按生产根写入"（那是生产入口的设计行为）。该条现按"关闭"计，并保留"defense-in-depth"建议（runner 已兜底）。
- **R2A-01 的"无锁启动"确实存在**（上轮 HIGH 成立）；本轮已在目标提交关闭，且 `INF-ROLLBACK-03` 的证据链（start.log 为空）能证伪回归。
- 上一轮报告保持 `abe0eaa` 锚定不改；本文件是唯一的新结论载体。

---

## 7. 验收建议（事务/并发维度）

**结论：SHORT_RUN 可接受（仅限本维度），附披露条件。**

可接受依据：
1. F11 根因独立确认（§2.1），写路径已在代码与用例两侧闭合（§2.2/2.3）；
2. R2A-01…05/07/09/12 关闭，且每条都有可证伪用例或我的独立探针/变异支撑；
3. 92/92 证据干净、锚定代码提交、断言>0，并被独立复现（§5）；
4. 未发现新的 HIGH。

必须同时披露/接受的残余（不阻塞 SHORT_RUN，但不得声称"全部关闭"）：
- **R2A-06（MED）**：journal 无提交阶段——清除失败或"末写后崩溃"会让下一次 apply 以 34 要求回滚一个已成功的状态。当前设计是 fail-closed，需用户知情。
- **R3-01（MED）**：门闩只覆盖注册表/进程入口；ACL 写入、`Start-V4ClashCore -Launch`、settings/owner/journal 仍不受约束，且一次 `Enable` 即恢复写能力。
- **LOW**：R2A-10（锁路径 TOCTOU）、R2A-11（null processStart）、R2A-13（原子写残留）、R2A-14（DryRun 真实 workdir）、R2A-15（委托缺失视为成功）、R3-02/03/04/05/06。
- **不可声称**：真实生产 `apply/rollback/state`、真实 HKCU 写入、Clash 启停、网络往返——本轮与上轮都未执行（用户环境中系统代理当前为"关闭"，任何恢复动作需用户确认）。
- Gate 侧建议：Gate 1 可对"事务/并发"记为 PASS（无 HIGH），但 Gate 10（连续两轮独立复审无新增 HIGH）需注意本轮新 MED（R3-01）不影响 HIGH 计数；Release 文本应把 R2A-06/R3-01 列入"已披露残余"。

---

## 附录 A：本轮执行的命令与产物（全部 `%TEMP%`）

| 项 | 路径 / ID |
|---|---|
| 最终套件（锚定代码提交） | `git archive --format=tar d5f2134` → `%TEMP%\r3tree-d5-060124`；`Run-Tests.ps1 -OutFile %TEMP%\r3-final-20261118-060129.json`；`runId=1c0a92ab9aee48bc90aee5973dff77ce`；92/92 exit 0；sum assertions=128；duration 118750ms |
| F11 门闩探针 | `%TEMP%\r3latch.ps1`（stub `Set-ItemProperty`/`Start-Process`/`Stop-Process`/`Get-Process` + dot-source 后覆盖 `Update-V4WinInet`）；L1–L7 7/7 |
| ACL 门禁顺序探针 | `%TEMP%\r3aclgate.ps1`；A1=11 / A2=12 / A3=加固已生效；3/3 |
| F07 变异 | `%TEMP%\r3mut-*`：M1 14/16、M2 5/16（F07-05/F07-09 均变红） |
| 只读 HKCU 比对 | 探针内 `Get-ItemProperty HKCU:\…\Internet Settings`（无任何写）；FT 系列由仓库用例负责 |
| 未执行 | 真实 `apply/rollback/state`、HKCU 写入、Clash 启停、网络、`faultinject-v4.ps1` |

## 附录 B：目标提交关键行号（`d5f2134`）

- `proxy_v4/lib/V4.ps1`：`38-56` 门闩/`Assert`；`234` `ProfileTextBuilder` 调用；`374-377` `Get-V4Settings` ACL 门禁；`705/752` Stop/Start 测试模式 no-op；`884-885` 清单完整性；`909` 恢复后加固；`988-1026` 系统代理 mock/门闩。
- `proxy_v4/apply-v4.ps1`：`24` `Enable`；`132-143` builder；`167` `ProfileTextBuilder` 接线。
- `proxy_v4/rollback-v4.ps1`：`13` `Enable`；`20-22` mixedPort；`43-48` 锁忙 33；`54-59` `restoreAttempted` 与 manifest 预校验；`62-77` 代理/启动/校验；`84-91` 锁内补救；`96-98` 外层 catch。
- `proxy_v6/tests`：`Harness.ps1:441-443`；`Run-Tests.ps1:29-30`；`repro/Repro-F07.ps1:93,176-182,212-221,238-247`；`cases/70-ft.tests.ps1:26-31`；`cases/fixtures/Run-FT-Case.ps1:18-20,25-48,79-154`；`cases/fixtures/Run-InfraCase.ps1:511,538-574,577-598,599-621,677-712`。
