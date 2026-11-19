# ROUND2 事务 / 并发独立复审 — commit `abe0eaa`

> 复审角色：round2-transaction（独立第二意见，不采信主代理自评）
>
> 复审目标：`v5/short-run-hardening` @ `abe0eaa4b29f9d40b8157420d96fa09013d165da`（HEAD 于派单时）
>
> 基线：`36222c9`（此前 A/C/D 报告所审版本）
>
> 报告时间：2026-11-18（本地）
>
> 结论级别：**不具备无保留验收条件**（1×HIGH + 8×MED + 6×LOW；见 §1）

---

## 0. 复审对象、方法与声明

| 项 | 值 |
|---|---|
| 代码来源 | `git show abe0eaa:<path>` 与工作树逐行比对；本次只读 `proxy_v4/{lib/V4.ps1,apply-v4.ps1,rollback-v4.ps1,state-v4.ps1}` 与 `proxy_v6/tests/**` |
| 工作树状态 | 复审开始时 `proxy_v4/**` 与 `abe0eaa` **逐字节一致**（`git status` 无相关条目）；本轮全部静态阅读、套件运行（05:29–05:31）与探针/变异（05:31–05:33）都发生在该状态下。**05:36:29–05:37:48 之后**他人开始未提交地修改 `proxy_v4/{apply-v4.ps1,lib/V4.ps1,rollback-v4.ps1}` 与两个 infra 测试文件（见 §8）；本报告不对其负责，行号仍全部对 `abe0eaa` 的 blob |
| 静态方法 | 四个生产文件全文逐行阅读（非关键词检索），V6 相对基线的 diff 逐段对照 |
| 动态方法（允许范围内） | ① 运行隔离 V6 套件；② 在 `%TEMP%` 内复制 `V4.ps1` 并设 `V4_TEST_MODE=1` 的**自建集成探针**（用生产 `Invoke-V4ApplyTransaction` + 生产 `New-V4Snapshot/Restore-V4Snapshot/Set-V4Atomic/Write-V4Journal` 接线，仅对 test-mode 会拦截的 4 个系统委托打桩）；③ 在 `%TEMP%` 内对 `V4.ps1` 副本做变异，检验用例可证伪性；④ 在 `%TEMP%` 内复制 `apply-v4.ps1` 并以"干净环境"运行，检验真实脚本用例的隔离依赖 |
| 未执行 | 真实 `apply/rollback/state`、HKCU/系统代理写入、Clash 进程启停、真实网络、`proxy_v4/tests/faultinject-v4.ps1`（该文件已废弃为转发器） |
| 秘密处理 | 仅用 `203.0.113.x` / `fixture-*` 占位；本报告不含真实主机、账号、口令、DPAPI 密文、本机用户名/组名 |
| 测试污染 | 所有探针/变异体均在 `%TEMP%`，运行后未清理的临时目录不影响仓库；未改动任何受跟踪文件（仅本报告与 `evidence/v6/round2-transaction.json`） |

---

## 1. 结论摘要

### 1.1 计数

| 严重度 | 数量 | 编号 |
|---|---|---|
| HIGH | 1 | R2A-01 |
| MED | 8 | R2A-02 … R2A-09 |
| LOW | 6 | R2A-10 … R2A-15 |

### 1.2 对 F07/F08/F09/F10 的独立裁定

| 项 | 裁定 | 一句话依据 |
|---|---|---|
| **F07**（事务边界：首写失败/中途失败/快照失败/回滚再失败） | **主路径关闭**（残余 R2A-05/R2A-06/R2A-09） | 独立复跑 15/15 通过；自建集成探针在生产接线下验证"第三写失败→三文件回滚+代理/owner 还原+进程恢复"、"真实快照失败→不写 journal、无孤儿快照、进程恢复"、"恢复双失败→40 且保留 journal"；变异"关闭恢复"→F07 9/15 变红，证明用例可证伪 |
| **F08**（profiles.yaml 作用域） | **关闭** | 块级解析（`Get-V4ProfileBlock` 唯一 uid、`^` 顶格结束、重复 uid 抛错、非列表位 uid 抛错）；10/10 通过；变异"块结束判定失效"→F08 5/10 变红 |
| **F09**（Init 在锁前写 settings） | **关闭**（残余 LOW：Init 覆盖旧凭据不可回滚；隔离依赖见 R2A-08） | `apply-v4.ps1:38` 取锁早于 `:49-61` 的 Init；`Save-V4SettingsObject` 用 `Set-V4Atomic`+ACL 并抛 12；`F09-SUITE`、`INF-APPLY-INIT-01`、`INF-INIT-01..04` 通过 |
| **F10**（异常/恢复阶段日志阻断、二次失败） | **关闭**（残余：rollback 的 catch 覆盖 41→40；恢复委托缺失视为成功=R2A-15） | 恢复编排全部日志经 `Write-V4RecoveryNote` 包裹且 `Write-V4Log` 自身全捕获；变异"恢复永远返回原码"→F10 6/10 变红；`F07-06/07/14` 覆盖集成 |

### 1.3 最高残余风险（一句话）

**R2A-01**：V6 为修复 A-12 在 `rollback-v4.ps1` 的 catch 中新增了无条件 `Start-V4Clash`——它在**锁已被释放**（甚至从未取得锁）时被调用，因此"没快照/锁忙"这类只读失败也会去真实启动 Clash Verge，而这可能正发生在另一个持锁事务把应用停掉、正在替换三个文件的中途。这是本轮唯一 HIGH，且属 **V6 新引入**。

---

## 2. 发现清单

> 位置均为 `abe0eaa`。每条含：触发 / 期望 / 实测 / 最小隔离测试。
> `实测` 标注 `[实测]` 的是本轮真正执行过的；`[静态]` 的为逐行推导。

### R2A-01 HIGH — rollback 失败路径在**未持锁**状态下启动 Clash，且锁忙返回 40 而非 33（V6 新引入）

- **位置**：`proxy_v4/rollback-v4.ps1:64-72`（catch 中 `:68` `Start-V4Clash`）；`:34-35`（锁忙只 `throw`）；`:30-33`（无快照在取锁**之前**就 throw）；`:62`（内层 finally 已先释放锁）；对照 `proxy_v4/apply-v4.ps1:39` 的 33 契约。
- **触发**：
  1. 另一个 apply/rollback 持锁时执行 `rollback-v4.ps1 -SnapshotDir <dir>`；
  2. 或备份目录为空时执行 `rollback-v4.ps1`。
- **期望**：① rollback 在"未取得锁 / 无快照"这类**没有开始恢复**的失败上不得产生任何系统副作用；② 锁忙应与 apply 一致返回 33；③ 只有"已进入恢复且恢复失败"才允许补救性启动，且该启动应受同一把锁保护。
- **实测**：
  - `[实测 B1]` 空备份目录 → 退出码 **40**，输出出现 `V4 test mode blocks real operation: Start-V4Clash`，证明确实走到了**真实** `Start-V4Clash`（生产环境即 `Start-Process clash-verge.exe`）。
  - `[实测 B2]` 由外部活进程持锁（payload pid 存活且 `processStart` 一致，非陈旧）→ 等待 20s 后退出码 **40**（无 33），并同样走到真实 `Start-V4Clash`。
  - `[静态]` 内层 `:62` 已 `Exit-V4Lock`，catch 在锁外执行；`Start-V4ClashCore` 在"未监听且无进程"时会 `Launch`。
- **影响**：持锁事务的窗口内（快照已停应用、三文件替换中）被失败的 rollback 拉起应用：应用会读取半替换的 `clash-verge.yaml`/`profiles.yaml`，并可能按自身逻辑重写这两个文件，与事务写入竞争；也可能出现双实例。
- **最小隔离测试**：本轮 `%TEMP%` 探针 B1/B2（`V4_TEST_MODE=1`，靠 `Assert-V4ProductionOperation` 把真实启动拦成异常以观测"是否尝试"）。生产语义的等价测试需 fake-exe：把 `V4_TEST_MODE` 关掉、`V4_TEST_INSTALL/EXE` 指向假 exe 记录启动次数（当前 `Start-V4Clash` 在 test mode 下被硬拦，无法直接观测，这是测试设计缺口）。
- **修复方向**：`$startedRecovery` 标志（取得锁且进入 restore 之后才置位），仅在该标志为真时 catch 才尝试启动；锁忙/no-snapshot 单独映射 33/31 等码，并在 `-List` 之外的所有失败路径保持只读。

### R2A-02 MED — rollback 硬编码 7897，不读 `settings.mixedPort`（A-11 残余，非 V6 新引入）

- **位置**：`rollback-v4.ps1:38`（`Restore-V4Snapshot` 无 `-Port`）、`:50`/`:68`（`Start-V4Clash -TimeoutSec 40` 用默认 7897）；`V4.ps1:896`（`Restore-V4Snapshot -Port = 7897`）、`V4.ps1:684/710/730/801` 的默认端口。
- **触发**：用户 `mixedPort != 7897`（`settings.json` 可配置）时执行 rollback（成功或失败路径）。
- **期望**：与 apply 一致从 `Get-V4Settings` 取 `mixedPort` 传给 `Restore-V4Snapshot/-Port` 与 `Start-V4Clash`。
- **实测**：`[静态]` `rollback-v4.ps1` 全文无 `Get-V4Settings`/`mixedPort`；`Start-V4ClashCore` 以 7897 判监听，非默认端口时必然超时 40s 并记录 `clash did not come back`（退出码不变，属"谎报未启动"+40s 卡顿）。
- **最小隔离测试**：在 `%TEMP%` 下 `Save-V4Settings ... -MixedPort 65532`，对 `Start-V4ClashCore` 注入 `IsListening={ $global:Probe -ge 2 }` 并传入 rollback 实际使用的端口，断言使用 65532（当前会拿到 7897）。

### R2A-03 MED — 零条目/残缺快照清单被当作"恢复成功"，随后清空 journal 并声明"hash-verified"

- **位置**：`V4.ps1:821-858`（`Test-V4SnapshotManifest`：仅校验路径安全/重复/哈希，**不校验** schema、条目数量、必须覆盖 `profiles.yaml`、不校验 `systemProxy`）；`V4.ps1:860-893`；`rollback-v4.ps1:38-40`（`files restored and hash-verified` + `Clear-V4Journal`）。
- **触发**：`manifest.json` 可解析但 `files:[]`/`absent:[]`（外部截断、手改、旧 schema、或未来写入路径的半写），或清单只含部分条目。
- **期望**：拒绝"一个文件都没覆盖"的清单；至少要求 `profiles.yaml` 出现在 present 或 absent 之一；失败时不得清空 journal、不得打印 hash-verified。
- **实测**：`[实测 P4/B3]` `{"schema":2,"files":[],"absent":[]}` → `Restore-V4Snapshot` 正常返回，`Restore-V4Files.ok=$true`；`systemProxy` 缺失时 `$m.systemProxy` 为 `$null`。
- **影响**：journal 被清除后，下一次 apply 不再拦住"半应用状态"，等于把持久化的 fail-closed 信号销毁。
- **最小隔离测试**：`%TEMP%` 下构造空清单 → 断言 `Restore-V4Snapshot` 抛错；再构造只含 `profiles\other.yaml` 的清单 → 断言拒绝（缺 `profiles.yaml`）。

### R2A-04 MED — 恢复路径不重新加固 ACL；被重新创建的凭据文件回落到继承 ACL

- **位置**：`V4.ps1:868-893`（`Restore-V4Files` 只用 `Set-V4Atomic`，无 `Protect-V4Acl`）；`V4.ps1:895-907`；`rollback-v4.ps1:38`；对照 `apply-v4.ps1:146` 提供 `ProtectAcl` 且事务在 `V4.ps1:238-241` 对两个凭据文件加固。
- **触发**：recovery/rollback 时目标文件**不存在**（快照后应用/用户删掉、或崩溃窗口内被删），`Set-V4Atomic` 走 `[System.IO.File]::Move` 新建 → 新文件继承目录 ACL（`AreAccessRulesProtected=false`）。
- **期望**：恢复写完后对凭据文件重新执行 `Protect-V4Acl` 并校验（与 apply 同标准）。
- **实测**：`[实测 P5]` 已加固文件经 `File.Replace` 后仍满足 `Test-V4AclHardened`；删除后由 `Set-V4Atomic` 新建的文件 `Test-V4AclHardened=false`。`[实测 P5b/B4]` 由 `Restore-V4Files` 重建的 `clash-verge.yaml`（含明文口令）加固状态为 false。
- **最小隔离测试**：见 P5b/B4（临时 appdata + 快照 + 删除 live 文件 + `Restore-V4Files` + `Test-V4AclHardened`）。

### R2A-05 MED — `profiles.yaml` "读在停应用之前、写在停应用之后"：V6 引入的顺序回归（丢失更新）

- **位置**：`apply-v4.ps1:121-128`（读取并计算 `$pt`）→ `:166` 进入事务 → `V4.ps1:216` `$ops.Snapshot` → `V4.ps1:800-808`（`New-V4Snapshot` 内 `Stop-V4Clash`）→ `V4.ps1:223` 写 `profiles.yaml`。基线 `36222c9` 是 `:116` 快照（停应用）→ `:123` 读（已被 V6 调换）。
- **触发**：应用在被停止时/停止前重写 `profiles.yaml`（GUI 改 profile、退出时 flush）。读取与停止之间存在窗口（含两次 `mihomo -t` 之外的其它工作；本版顺序已把窗口压到毫秒级，但语义仍是"用停应用前的旧文本覆盖停应用后的新文本"）。
- **期望**：注册表文本应在应用停止之后读取（在事务内、快照后），或在写前做 compare-and-swap（哈希比对），不一致则拒绝。
- **实测**：`[静态]` 顺序如上；`[实测 P1/P2]` 证明成功写入的是调用方传入的 `$Context.ProfileText`（即停应用前的文本）。
- **影响**：静默丢失应用最后一次注册表写入；且快照（停应用后生成）保存的是**较新**版本，因此"成功路径写旧、回滚路径恢复新"，两条路径互相矛盾（不致命但语义不一致）。
- **最小隔离测试**：fake-app 夹具，让 `StopApp` 钩子改写 `profiles.yaml`，断言事务写出的内容等于停用后的内容（当前等于停用前）。

### R2A-06 MED — journal 无"提交阶段"，清除失败/末写后崩溃会把用户推向"回滚一个良好状态"

- **位置**：`V4.ps1:174-185`（journal 仅含 schema/snapshot/reason/started/pid，无 phase 或 commit 标记）；`V4.ps1:243-246` 与 `:273-276`（清除失败只 WARN）；`apply-v4.ps1:43-47`（下一次一律 34 并要求 `run rollback-v4.ps1 -SnapshotDir <snap>`）。
- **触发**：apply 全流程成功但 `Clear-V4Journal` 失败（文件被索引/杀软占用、IO 错误、ACL），或在"最后一次写成功之后、清 journal 之前"被硬杀。
- **期望**：提交语义显式化（例如先原子改名/写 `phase=committed`，或 journal 记录最后写入位置的哈希），使下一次运行能区分"已提交"与"脏"；仅"脏"才要求回滚。
- **实测**：`[实测 P7]` journal 往返/WhatIf 语义；`[静态]` 清除失败路径只 `Write-V4RecoveryNote ... 'WARN'`。
- **最小隔离测试**：把 `ClearJournal` 委托改成抛错并跑成功事务 → 断言下一次 apply 不应以 34 要求回滚已成功的状态（当前会要求）。

### R2A-07 MED — 证据链：提交内的"绿色证据"锚定的是 **36222c9 + 脏工作树**，且 75/75 用例 `assertions=0`，子结果文件被删除

- **位置**：`proxy_v6/evidence/v6/full.json`（HEAD 中）；`proxy_v6/tests/Harness.ps1:437-443`（"body completed without assertions" 也算 PASS）；`proxy_v6/tests/cases/ReproHelpers.ps1:13-38`（子进程 `result.json` 写在临时根，`finally` 里随 `Remove-TestTempRoot` 一起删除）。
- **实测**：
  - `git show HEAD:proxy_v6/evidence/v6/full.json` → `git.head=36222c9…`、`dirty=true`、`counts=75/75 pass`、**`assertions=0`（75 条全部）**。
  - 我本轮在 `abe0eaa` 复跑：`runId=c65ff255edf94d948715a1be04a7a375`、75/75、exit 0，但**同样 75 条 `assertions=0`**。
  - 每个用例唯一的持久证据是 harness 的 `{status:pass, assertions:0}`；F07/F08/F09/F10 的子断言结果文件在用例结束时被删除，无法事后审计"到底断言了什么"。
- **影响**：证据只能证明"用例体没抛异常"，不能证明"任何断言被执行过"。这与 `ISSUE-LEDGER §D` 自己的关闭规则（"失败测试先证明…"）不匹配：现有绿色证据不具备"可审计的断言执行"。
- **最小隔离测试**：注册一个"永远直接 return、零断言"的用例（`SelfTest` 已有 META 夹具可扩展）→ 断言 harness 应判非零（当前判 PASS）。这是自验证套件应覆盖的第 8 类元测试。
- **修复方向**：`assertions=0` 视为失败（或要求用例显式声明 `-AllowNoAssertions`）；委派型用例把子进程 `result.json` 复制到 `EvidenceDir`；在证据中记录 `casesDir` 的哈希与 `git diff` 摘要，避免"脏树产物"当作提交证据。

### R2A-08 MED — 真实脚本用例的隔离**只靠继承环境变量**，测试辅助既不注入也不校验

- **位置**：`proxy_v6/tests/lib/TestSupport.ps1:92-118`（`ProcessStartInfo` 未设置 `EnvironmentVariables`，完全继承父进程环境）；`proxy_v6/tests/repro/Repro-F09.ps1:7-8`（父进程设 `V4_TEST_MODE/V4_TEST_ROOT` 后 `:32` 用 `powershell -File apply-v4.ps1`）；`proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1:17-18` 同理，`:426-448`、`:479`、`:500`、`:539` 起真实 `apply/state` 子进程。
- **触发**：以干净环境运行（服务/计划任务/CI、`Start-Process -UseNewEnvironment`、未来 harness 改为显式环境）。
- **期望**：子进程显式注入 `V4_TEST_MODE=1` 与 `V4_TEST_ROOT=<temp>`；子脚本内断言 `$script:Root` 等于预期临时根，否则立即失败。
- **实测**：`[实测 环境实验室]` 把 `proxy_v4/apply-v4.ps1`+`lib/V4.ps1` 复制到 `%TEMP%lab`，清除 `V4_TEST_MODE/ROOT` 后运行 → 退出 11，并在 `%TEMP%labproxy_v4` 下创建 `config\` 与 `evidence\apply-*.log`；若带 `-Init`，会把含 DPAPI 密文的 `config\settings.json` 写进脚本根（仓内即 `publish\proxy_v4\config\settings.json`）。
- **影响**：测试安全性/可复现性依赖"调用者恰好没清环境"，与 V6 "测试不触真实对象"的声明不成立（当前运行下确实没触，但机制是偶然的）。
- **最小隔离测试**：`Invoke-TestChildPowerShell` 增加 `-Environment` 参数并强制注入；对每个真实脚本用例断言子进程输出的 `root=<temp>`。

### R2A-09 MED — 两个"通过"的 F07 用例对其声称的行为不可证伪

- **位置**：`proxy_v6/tests/repro/Repro-F07.ps1:175-181`（F07-05 "chain verification fails: system proxy restored"）、`:211-217`（F07-09 "app was not running before: failure must not leave it running"）。
- **触发**：实现退化。
- **实测（变异）**：
  - 变异 M1：把 `V4.ps1:257` 的 `if ($beforeProxy) {` 改成 `if ($false) {`（彻底不做代理还原）→ **F07-05 仍然 PASS**。原因：F07-05 的失败发生在 `V4.ps1:229-232` 的链路校验，此时 `SetSystemProxy`（`:233`）尚未执行，断言 `proxyServer -eq 'old:8080'` 恒真。
  - 变异 M2：把 `V4.ps1:255` 的恢复门槛改成 `if ($false) {`（完全关闭恢复）→ F07 9/15 变红，但 **F07-09 仍然 PASS**（它只断言"没被启动"，不校验恢复是否执行）。
- **期望**：F07-05 先制造"代理已被改成我们的值"的晚失败（与 F07-10 同型）；F07-09 增加 `restoreCalls -ge 1` 且 `startCalls -eq 0`。
- **注**：其余 13 条 F07、全部 10 条 F10、10 条 F08 均可证伪（见 §5 变异表），所以这是**局部**测试质量缺陷，不影响 §1.2 的总体裁定。

### R2A-10 LOW — 锁仍是"路径文件"而非持有句柄：获取=建+写+关，释放=读+比对+删（TOCTOU/ABA 仍在）

- **位置**：`V4.ps1:596-606`（`CreateNew` 后立即关闭句柄）、`:649-667`（读→比对 token→再读→`Remove-Item` 按路径删）。
- **触发**：持锁进程中 `Get-Process` 对被检查 pid 瞬时失败（被判陈旧）、或第三方删除锁文件（清理脚本/杀软隔离）→ 新进程删除旧锁并新建；旧持有者退出时其"再读比对"与 `Remove-Item` 不是原子动作，可能删掉**继任者**的锁。
- **期望**：锁以打开句柄（`FileShare.None`）或命名互斥体在事务期间持有，所有权由句柄身份判定，释放时不存在"按路径删"的窗口。
- **实测**：`[实测 P6]` 活持有者 + 错误 token 不会误删（说明 token 修复生效）；ABA 窗口本身未能在隔离环境确定性复现（`[静态]` 推导）。
- **注**：相对 A-01/D-01 已大幅收窄（`if (-not $Token) { return $false }`），故降为 LOW。

### R2A-11 LOW — `processStart` 为 null 且 pid 被复用时，锁永远不会被回收（永久 33）

- **位置**：`V4.ps1:616-624`：`elseif ($j.processStart -and (Get-V4ProcessStartToken ...) -ne $j.processStart) { $stale = $true }`——`processStart` 缺失/null 时**跳过**启动时间校验，只要 pid 存活即视为"持有者"。
- **触发**：写锁进程取不到自身 `StartTime`（`Get-V4ProcessStartToken` 返回 null，例如权限/时序异常）→ 锁内 `processStart: null`；该进程随后退出、pid 被无关进程复用 → 后来者永远等待 20s 后 exit 33。
- **期望**：`processStart` 缺失时按"有限宽限后判陈旧"处理（与空锁 2s 宽限同型），或记录第二个身份事实（如进程创建时间 + 映像名）。
- **实测**：`[实测 P6/B2]`（正常 payload 不会误判）；null payload 场景 `[静态]`。
- **最小隔离测试**：写 `{"pid":<本地活进程>,"token":"x","processStart":null}` → 断言 `Enter-V4Lock -TimeoutSec 2` 在宽限后返回非 null（当前返回 null）。

### R2A-12 LOW — 清单缺 `systemProxy` 时 rollback 会**清掉**用户的系统代理

- **位置**：`rollback-v4.ps1:42-49`：`$want = if ($m.systemProxy.enabled) {...} else { 'off' }`；`if ($m.systemProxy.enabled) { Set } else { Clear-V4SystemProxy }`；`V4.ps1:821-858` 不校验该字段。
- **触发**：恢复一个 schema 1/手写/旧格式快照（无 `systemProxy`）→ `$m.systemProxy` 为 `$null` → 走 `Clear-V4SystemProxy`，把用户代理置为 off，并覆盖 owner 为 `rollback`。
- **期望**：清单缺 `systemProxy` 时拒绝恢复，或按"不动系统代理"处理。
- **实测**：`[实测 P4/B3]` 证明 `Test-V4SnapshotManifest` 接受无 `systemProxy` 的清单且返回 `$null`。
- **最小隔离测试**：`Restore-V4Snapshot` 用无 `systemProxy` 清单 → 断言抛错；rollback 侧用 dry 桩断言未调用 Clear。

### R2A-13 LOW — `Set-V4Atomic` 硬杀残留 `.v4stage-*.tmp` / `*.bak`（含明文凭据、未加固、无启动清理）

- **位置**：`V4.ps1:910-942`（`:914-915` 生成 tmp/bak，`:925` 成功后删 bak；异常路径清理，但进程被硬杀时无补救）；全文件无启动期清扫。
- **触发**：写 `clash-verge.yaml`/`v4-managed.yaml` 期间硬杀/断电。
- **期望**：启动时清扫本目录内 `.v4stage-*` 与 `*.bak`（并对其加固），或把凭据隐藏到受保护目录。
- **实测**：`[实测 P5]` 正常/错误路径不残留（`INF-ATOMIC-01..03` 同结论）；硬杀路径 `[静态]`。
- **注**：A-20/D-23 的残余，V6 未处理。

### R2A-14 LOW — `-DryRun` 仍对**真实 appdata** 运行 `mihomo -t`（A-09 残余）

- **位置**：`apply-v4.ps1:112-113`（`Test-V4MihomoConfig -WorkDir $p.AppData`）、`V4.ps1:944-954`。
- **触发**：`-DryRun`；`mihomo -t` 以活动数据目录为 `-d`，可能触碰该目录内的缓存/锁文件（如 cache DB）。
- **期望**：`-d` 指向隔离临时目录（复制必要引用），使 DryRun 对 appdata 严格只读。
- **实测**：`[静态]`；`INF-DRYRUN-01` 只校验 `profiles.yaml/clash-verge.yaml/settings.json` 三个文件哈希，未覆盖 appdata 其它文件。
- **最小隔离测试**：`-WorkDir` 改为临时目录后，用真实 mihomo 比对 appdata mtime/文件集（当前环境无真实 core，未执行）。

### R2A-15 LOW — 恢复编排把"代理/owner 委托缺失(null)"当作恢复成功

- **位置**：`V4.ps1:256-270`（`$beforeProxy` 为空则不建 `$restoreProxy`；`$ownerKnown` 为假则不建 `$recoverOwner`）；`V4.ps1:129-136` 中对应步骤直接跳过且 `$proxyOk/$restoreOk` 保持 true。
- **触发**：未来 wiring 变更漏传 `GetSystemProxy`/`GetOwnerText`，或读取前抛异常 → 恢复"成功"却既不还原代理也不还原 owner（静默）。
- **期望**：若系统代理曾被本事务修改（可判定），而 `RestoreProxy` 缺失，则必须判 40。
- **实测**：`[静态]`；当前 `apply-v4.ps1:140-145` 始终提供两委托，故不可达。
- **注**：与 R2A-07 同源——"生产接线无端到端测试"。

---

## 3. 先验 A/D 发现逐条状态（对 `abe0eaa` 复核）

> `关闭`=源码与隔离证据均支持；`部分`=主路径已修但残余可复现/可推导；`仍开放`=与基线等价或更差。
> 先验报告（`AGENT-A-*`、`AGENT-D-*`）仅作输入，本表结论均回到 `abe0eaa` 源码与本轮实测。

| ID | 严重度 | 现状 | 依据（`abe0eaa`） |
|---|---|---|---|
| A-01 / D-01 | HIGH | **关闭** | `V4.ps1:649-667` token 校验、`if (-not $Token) { return $false }`；`F09-02`、`INF-LOCK-02`、P6/B2 |
| A-02 / D-02 | MED | **部分** | 空锁 2s 回收(`V4.ps1:610-615`)、PID 复用(`:622`)；残余 R2A-10/R2A-11 |
| A-03 / D-04 | HIGH | **关闭** | `V4.ps1:203-216` 先捕获 `wasRunning/beforeProxy/ownerBefore`，`:255` 三者任一即恢复；`F07-01`、P3b（真实快照失败） |
| A-04 / V6-S03 | HIGH | **关闭** | manifest `absent` 列表(`V4.ps1:758-798`)+恢复删除(`:884-891`)；`INF-SNAP-01/05` |
| A-05 / D-22 | HIGH | **部分** | 逐文件哈希落地校验(`V4.ps1:876-879`)、`INF-SNAP-02/04`；残余 R2A-03（空清单当成功） |
| A-06 / V6-S04 | HIGH | **关闭** | `:211-213` 捕获 + `:256-270` 还原代理/owner；F07-05/10、P2/P3 |
| A-07 / V6-S11 | HIGH | **关闭** | 锁(`apply:38`)先于 Init(`:49-61`)；`Save-V4SettingsObject` 原子+ACL+抛 12（`V4.ps1:375-388`）；`INF-APPLY-INIT-01`、`F09-01/03`。残余：Init 覆盖旧凭据不可回滚（LOW，设计选择） |
| A-08 / D-13 | HIGH | **部分** | journal 先于首写(`:217-225`)、34 门(`apply:43-47`)、`INF-JOURNAL-01`；残余 R2A-06（无 commit 阶段） |
| A-09 | MED | **部分** | DryRun 不写 config/settings/快照(`INF-DRYRUN-01`)；残余 R2A-14（真实 appdata 上跑 mihomo） |
| A-10 / V6-S07 | MED | **关闭** | dot-source 零写入(`INF-LAZY-01`)、`Start-V4Log` 失败返回 false 且不阻断(`apply:26-27`、`INF-LOG-01`) |
| A-11 / D-24 | MED | **仍开放（部分）** | R2A-02（硬编码 7897）；rollback 仍无条件启动应用(`:50`)且覆盖 owner='rollback'(`:60`) |
| A-12 | HIGH | **关闭** | `V4.ps1:99-158` 恢复编排 + `rollback:64-72`；P3、F10-01/04/08/09/10（变异 6/10 红） |
| A-13 | MED | **仍开放** | 仍只处理 `ProxyEnable/ProxyServer`（`V4.ps1:957-980`），PAC/`ProxyOverride`/禁用态 `ProxyServer` 未入快照 |
| A-14 | MED | **部分** | 事务内 owner 文本快照/还原(`:212,266-270`)；`-Repair` 的 owner 写失败不可回滚(`apply:84-85`)；rollback 不还原原 owner |
| A-15 / D-11 | MED | **关闭** | `Write-V4Log` 全捕获(`:63-70`)、`Write-V4RecoveryNote`(`:94-97`)；F10-01/02/03 |
| A-16 / D-03 | MED | **关闭**（残余 LOW） | `state-v4.ps1:14-25` 顶层兜底；`INF-STATE-SCRIPT-01`。残余：`UNKNOWN/RECOVERING` 在 `Get-V4StateCore` 中不可达（`V4.ps1:1311` 初始值必被覆盖；`RECOVERING` 仅出现在 state 脚本） |
| A-17 / D-16 | MED | **部分** | 新 harness 退出码契约+自验(`Harness.ps1:547-555`、`SelfTest` META-01..07)；残余 R2A-07/R2A-08/R2A-09 |
| A-18 / V6-S05 | MED | **关闭** | `Test-V4AclHardened` 逐 ACE 校验(`:529-548`)；调用方均检查(`apply:108,146`、`V4.ps1:757,805`、`378,386`)；`INF-ACL-01` |
| A-19 / D-21 | MED | **部分** | 恢复检查启动返回值(`:141`)；"启动成功"仍等于端口监听(`:716-726`)，无法证明是本实例 |
| A-20 / D-25 | LOW | **部分** | `File.Replace`+错误路径清理(`:919-940`)、`INF-ATOMIC-01..03`；硬杀残留 R2A-13 |
| A-21 / D-17 | HIGH | **关闭** | `faultinject-v4.ps1:12-19` 已改为转发并声明废弃，不再触碰 hosts |
| A-22 / V6-S12 | LOW | **关闭** | 日志名含毫秒+6 位随机(`:78`) |
| A-23 | LOW | **关闭** | 全文件无 `HKLM` 空语句（grep 0 命中） |
| A-24 / D-18 | LOW | **部分** | YAML 转义(`ConvertTo-V4YamlDoubleQuoted`，`INF-YAML-01`)；`-StaticPass` 仍在命令行(`apply:19`) |
| A-25 | LOW | **关闭** | `apply:126` 用 `[datetime]::UtcNow` |
| A-26 | LOW | **关闭** | `apply:6` 帮助已写 "strict (default)" |
| D-05 | HIGH | **关闭** | 代理还原 + 恢复启动使用 `$Context.Settings.mixedPort`(`V4.ps1:264`) |
| D-06 | HIGH | **部分** | `-Repair` 仍先写注册表再校验，仅进程内 try/catch 回滚(`apply:74-97`)，无 journal，硬杀不可恢复 |
| D-07 | MED-H | **关闭** | F08 块级重写 + 10 用例（变异 5/10 红） |
| D-08 | MED | **关闭** | `INF-YAML-01` |
| D-09 | MED | **部分** | Init 标量解析支持引号/#/转义(`INF-INIT-01/04`)，歧义拒绝(`INF-INIT-02`)；仍是受限 regex 解析器（复杂 YAML 会 fail-closed） |
| D-10 | MED | **关闭** | 同 A-18 |
| D-12 | MED | **部分** | apply 退出码成体系；但校验器/SetOwner 异常落 1，rollback 锁忙落 40（R2A-01） |
| D-14 | MED | **仍开放** | `Get-V4Integrity` 只展示哈希不校验（`V4.ps1:1372-1394`） |
| D-15 | MED | **仍开放** | 仍只支持 IPv4（`Assert-V4SettingsInput`） |
| D-19 | LOW | **部分** | 脱敏规则增多(`INF-REDACT-01/02`)；仍依赖正则，未注册的裸口令不可见 |
| D-20 | LOW | **部分** | 未发现明显死代码；`Clear-V4Journal -WhatIf` 无生产调用 |
| D-23 | LOW | **部分** | 快照目录先加固后拷贝(`V4.ps1:756-757`)；`.bak` 未显式加固（R2A-13） |
| D-24 | LOW | **部分** | rollback catch 覆盖 `$exit`（41→40），"恢复失败/启动失败"不可区分；R2A-01 |

**汇总**：A 组 26 条：关闭 15 / 部分 9 / 仍开放 2（A-11、A-13）。D 组 25 条：关闭 8 / 部分 15 / 仍开放 2（D-14、D-15）。其中 D-01/D-02/D-04/D-05/D-10/D-11/D-16/D-17/D-18/D-21/D-24/D-25 与 A 组同源，但已分别按 D 组原文口径复核。

---

## 4. F07/F08/F09/F10 的"残余路径"逐条核对

| 残余路径 | 现状 | 证据 |
|---|---|---|
| 快照失败（应用已停） | **已覆盖** | `V4.ps1:216` 抛 → `snap=null, applied=false, wasRunning!=null` → 恢复走"进程+代理+owner"；真实快照失败 P3b：不写 journal、无孤儿快照、进程恢复 |
| 第一/第二/第三写失败 | **已覆盖** | `F07-02/03/04`；P1→P2（第三写由真实 `mihomo -t` 校验失败触发）三文件回滚、代理/owner 还原、journal 清除 |
| 恢复双失败（restore 再失败） | **已覆盖** | `F07-06/07`、`F10-01/04/05`；P3：exit 40、journal 保留、代理已还原、进程仍需补救 |
| 日志失败 | **已覆盖** | `Write-V4Log`/`Write-V4RecoveryNote` 全保护；`F10-01/02/03` |
| 系统代理还原 | **已覆盖**（晚失败） | `F07-10`、P2/P3；**注意** `F07-05` 对该行为不可证伪（R2A-09） |
| owner 还原 | **已覆盖** | `V4.ps1:212-213,266-270`；P2 断言 owner 文本还原为事务前值；`F07-10` |
| 进程状态 | **部分** | 恢复按 `wasRunning` 决定启动/停止；但"启动成功"=端口监听（A-19 残余）；rollback 失败路径**无锁**启动（R2A-01） |
| 崩溃窗口（journal 之后/首写之前） | **已覆盖** | journal 先于首写，下一次 34 fail-closed；`INF-JOURNAL-01` |
| 崩溃窗口（末写之后/清 journal 之前） | **部分** | 只能靠"回滚掉一个已成功的状态"恢复（R2A-06） |
| 快照完整性/缺失/ACL/哈希 | **部分** | 哈希/路径/重复校验+`absent`（P4/P5 实测）；缺"最小覆盖集"与 `systemProxy` 存在性（R2A-03/R2A-12）；恢复不重新加固 ACL（R2A-04） |
| Init 在锁内 + 原子 settings | **已覆盖** | `apply:38/49-61`、`Save-V4SettingsObject`；`INF-APPLY-INIT-01`、`INF-SETTINGS-01`；Init 与后续失败不回滚 settings（设计选择） |

---

## 5. 测试可证伪性专项

### 5.1 我实际执行的命令（可复现）

```text
# 1) 隔离套件（全量）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -OutFile %TEMP%\r2-full-20261118-052936.json
  -> Loaded test files: 5 ; registered=75 executed=75 passed=75 failed=0 skipped=0 ; EXIT 0
  -> git.head=abe0eaa4b29f9d40b8157420d96fa09013d165da ; runId=c65ff255edf94d948715a1be04a7a375
  -> 75/75 用例 assertions=0（见 R2A-07）
# 2) 生产接线集成探针（%TEMP%，V4_TEST_MODE=1，仅 4 个系统委托打桩）
  -> P1 success(9/9 全绿) : 文件+代理+owner 写入、journal 清除
     P2 第三写失败        : 三文件回滚、代理/owner 还原、进程重启、journal 清除、exit=1(≠40)
     P3 恢复双失败        : exit=40、journal 保留、代理已还原、启动被尝试
     P3b 真实快照失败     : 无 journal、无孤儿快照、文件不变、进程恢复
     P4 空清单            : Restore-V4Snapshot 当成功（R2A-03）
     P5 Replace 保 ACL / Move 不保 ACL
     P5b 重建凭据文件     : 加固=false（R2A-04）
     P6 lock 活持有者/错 token 保护
     P7 journal 往返+WhatIf
# 3) rollback 脚本失败路径（%TEMP%，V4_TEST_MODE=1）
  -> B1 无快照   : exit 40 且尝试真实 Start-V4Clash（R2A-01）
     B2 外部活锁 : 等 20s、exit 40（无 33）、仍尝试真实 Start-V4Clash（R2A-01）
     B3 空清单   : 当成功（R2A-03）
     B4 重建文件 : ACL 未加固（R2A-04）
# 4) 变异（在 %TEMP% 的 V4.ps1 副本上，对 repro 套件）
  -> 恢复永远返回原码     : F10 4/10（6 红）   => F10 可证伪
  -> 关闭恢复门槛         : F07 6/15（9 红）  => F07 可证伪（但 F07-09 仍绿）
  -> 关闭代理还原+journal清 : F07 13/15（2 红；F07-05 仍绿）=> F07-05 空洞
  -> 关闭块结束判定       : F08 5/10（5 红）  => F08 可证伪
# 5) 干净环境真实脚本
  -> 复制 apply+lib 到 %TEMP%\lab，清 V4_TEST_MODE 后运行: exit 11，生成 <lab>\proxy_v4\config 与 evidence\*.log
```

### 5.2 判定

| 维度 | 结论 |
|---|---|
| harness 自验（META-01..07） | 存在且设计合理（退出码 3>4>1>2>0；零执行=2；证据写失败=4） |
| 用例可证伪性 | **总体成立**：F10/F07/F08 在定点变异下大量变红（不自我印证）；**局部不成立**：F07-05、F07-09（R2A-09） |
| "绿色"的可审计性 | **不足**：75/75 用例 `assertions=0`；委派型用例的子断言结果文件用完即删；提交内证据锚定 `36222c9`+脏树（R2A-07） |
| 隔离性 | 函数级用例（F07/F10/F08 与多数 INF）确实在临时根内；**真实脚本用例（F09/PARAM/APPLY-INIT/DRYRUN/JOURNAL/STATE-SCRIPT）仅靠继承环境变量**（R2A-08） |
| 子进程/退出码 | `Invoke-TestChildPowerShell` 正确捕获 ExitCode/超时（`TestSupport.ps1:119-148`）；`exit 2` 零测试契约正确 |
| 生产接线的覆盖 | **零覆盖**：没有任何用例执行 `apply-v4.ps1` `:120` 之后的真实事务路径（DryRun/JOURNAL/PARAM/APPLY-INIT 都在 `:119` 之前返回或退出），F07 用的是 `Repro-F07.ps1:97-131` 的全量 mock（R2A-07/R2A-15 的根因） |

---

## 6. 新引入 vs 继承

| 分类 | 条目 |
|---|---|
| **V6 新引入** | R2A-01（rollback catch 无条件真实启动，且锁已释放）；R2A-05（`profiles.yaml` 读-停-写顺序回归）；R2A-07（`assertions=0` 的委派用例 + 删除子证据）；R2A-08（真实脚本用例靠继承环境隔离）；R2A-15（恢复委托缺失视为成功） |
| **V6 修复但仍残余** | R2A-03（清单完整性）、R2A-04（恢复 ACL）、R2A-06（无 commit 阶段）、R2A-10/11（锁的 TOCTOU/身份事实）、R2A-12（systemProxy 缺失）、R2A-13（原子写残留） |
| **继承未变** | R2A-02（rollback 端口硬编码）、R2A-09（F07-05/09 空洞，用例本身是 V6 新写的，但属"测试质量"而非生产回归）、R2A-14（DryRun 的 mihomo 工作目录） |

---

## 7. 验收建议（不含自评采信）

1. **不建议以当前证据给"事务/并发无保留验收"**。F07/F08/F09/F10 的**主路径**在独立复跑与生产接线探针下均成立，但 R2A-01（HIGH，V6 新引入）是可触发的系统副作用，且 R2A-05 是"成功路径静默覆盖用户注册表"的数据面回归。
2. **关闭 R2A-01 的最低条件**：① rollback 仅在"已进入恢复"时补救启动；② 锁忙映射独立退出码（33）；③ 补一条 fake-exe 用例断言"未取得锁时进程未被启动"（当前 test-mode 的 `Assert-V4ProductionOperation` 让该断言不可写，需要 `V4_TEST_EXE` 级别的假 exe 支持）。
3. **关闭 R2A-03/R2A-04 的最低条件**：清单最小覆盖集校验 + 恢复后重新加固并校验 ACL，各补一条隔离用例。
4. **关闭 R2A-05 的最低条件**：注册表文本在快照（停应用）之后读取，或写入前做哈希 CAS；补一条 fake-app 停用即改写注册表的用例。
5. **证据链**：`assertions=0` 必须判失败或显式豁免；委派型用例把子结果 JSON 复制进 `EvidenceDir`；绿色证据必须在**干净工作树、提交哈希等于待验收提交**的条件下重跑。当前 HEAD 内的 `full.json` 锚定 `36222c9`+`dirty=true`，不能作为 `abe0eaa` 的验收证据。
6. **未做（必须披露）**：真实 `apply/rollback/state`、HKCU/系统代理、Clash 启停、真实 mihomo 校验、真实网络——本报告的全部结论不覆盖这些；`V5-05`（真实往返）仍开放。

---

## 8. 后记：复审后（未提交）工作树变动 — 不在本报告范围

本轮测量结束后（05:36:29–05:37:48），他人开始未提交地修改 `proxy_v4/apply-v4.ps1`、`proxy_v4/lib/V4.ps1`、`proxy_v4/rollback-v4.ps1`、`proxy_v6/tests/cases/60-infra.tests.ps1`、`proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1`，并新增 `70-ft.tests.ps1` 等文件。**这些改动我未复审、也未用于本报告的结论**，仅记录三点与本报告相关的事实，供第三轮注意：

1. 该在途改动是一次"test-mode 注入化"重构（`Enable-V4ProductionWrites`、`Set-V4TestRegistryWriter`、infra 增加 `INF-ROLLBACK-01/02` 真实 rollback 用例），其动机与本报告 R2A-07/R2A-08 指出的"生产接线零端到端覆盖"一致。
2. 该重构把 `Start-V4Clash`/`Stop-V4Clash` 改成 `if ($script:TestMode) { return $true }` **静默返回成功**。这会**掩盖 R2A-01**：rollback 失败路径的"真实启动尝试"在 test mode 下不再抛错，也就不再可观测。若采纳该写法，必须同时提供"假 exe / 启动计数器"来把 R2A-01 变成可断言行为（例如 `V4_TEST_INSTALL/EXE` 指向会写计数文件的假 exe，并允许 `Start-Process`）。
3. 该在途 diff **未触及** R2A-01（rollback catch 的无条件启动与 33/40 码）、R2A-02（硬编码 7897）、R2A-05（读-停-写顺序）。因此即便该重构合入，上述三条仍需单独修复。

## 附录 A：本轮实测证据摘要（无秘密）

| 项 | 值 |
|---|---|
| 套件运行 | `runId=c65ff255edf94d948715a1be04a7a375`，`filter=*`，75/75，exit 0，`git.head=abe0eaa`，`dirty=true`（仅因他人并发改动 evidence 目录） |
| 提交内证据 | `git show HEAD:proxy_v6/evidence/v6/full.json`：`git.head=36222c9`、`dirty=true`、75/75、`assertions=0`（75/75） |
| 探针 A | 9/9（P1,P2,P3,P3b,P4,P5,P5b,P6,P7），位置：`%TEMP%\r2probe-bench-<stamp>`，`V4_TEST_MODE=1`，`V4_TEST_APPDATA=<temp>\appdata` |
| 探针 B | 4/4（B1,B2,B3,B4），真实 `rollback-v4.ps1` 子进程，`V4_TEST_MODE=1` |
| 变异 | F10: 4/10；F07(关恢复): 6/15；F07(关代理还原+journal): 13/15；F08: 5/10 |
| 环境实验室 | 无 `V4_TEST_MODE` 的 apply 副本在 `<lab>\proxy_v4\` 下创建 `config\` 与 `evidence\*.log`，exit 11 |
| 机器证据 | `proxy_v6/evidence/v6/round2-transaction.json`（结构化摘要，无秘密） |
| 未执行 | 真实系统代理/进程/HKCU/网络/注册表；`faultinject-v4.ps1` |

## 附录 B：行号索引（`abe0eaa`）

- `proxy_v4/lib/V4.ps1`：`99-158` 恢复编排；`161-194` journal；`197-280` 事务；`337-401` settings；`476-517` Init；`529-575` ACL；`584-667` 锁；`743-819` 快照；`821-907` 清单/恢复；`910-942` 原子写；`957-1003` 系统代理/出口 IP；`1026-1051` owner；`1057-1168` profiles.yaml；`1298-1350` state-core；`1372-1394` integrity。
- `proxy_v4/apply-v4.ps1`：`26-27` 日志；`31-47` 参数/锁/journal 门；`49-61` Init；`69-71` 首跳；`74-97` Repair；`106-118` 校验/DryRun；`121-130` 注册表文本+校验器；`132-166` ops/ctx/事务；`175-183` catch/finally。
- `proxy_v4/rollback-v4.ps1`：`19-33` 列/默认快照；`34-35` 锁；`38-60` 恢复/代理/启动/owner；`62` 释放；`64-72` catch（R2A-01）。
- `proxy_v4/state-v4.ps1`：`14-25` 兜底；`36-39` marker 降级；`56-61` 退出码。
- `proxy_v6/tests`：`Harness.ps1:426-443`（零断言=通过）、`:547-555`（退出码）；`lib/TestSupport.ps1:92-148`（子进程环境/退出码）；`cases/ReproHelpers.ps1:13-38`；`cases/fixtures/Run-InfraCase.ps1:17-18,426-448,479,500,539`；`repro/Repro-F07.ps1:97-131`（全 mock）、`:175-181`、`:211-217`；`repro/Repro-F09.ps1:7-8,32`。
