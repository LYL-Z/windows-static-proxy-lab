# AGENT-A 事务与并发审计（V6.0 独立接管）

审计人：Agent A（transaction & concurrency auditor）
审计时间：2026-11-18 04:51–05:12（America/Los_Angeles）
报告位置：D:\claude防封\publish\proxy_v6\reviews\AGENT-A-TRANSACTION-AUDIT.md

## 0. 审计对象、基线冻结与证据声明

| 项 | 值 |
|---|---|
| 代码仓库 | D:\claude防封\publish（分支 v5/short-run-hardening） |
| 冻结基线 | commit 36222c92c829a2ef08b71af2a3a3ff9a3c44b396（HEAD 与 origin 一致） |
| 基线 blob | apply-v4.ps1 711b13b9；lib/V4.ps1 74c436bf；rollback-v4.ps1 96b690ee；state-v4.ps1 328dfc8f；tests/faultinject-v4.ps1 87267b05 |
| 主报告行号 | 全部对 commit 36222c9 的 git blob，使用 git archive 导出的临时副本阅读与执行 |
| 审计时工作树 | **不干净**：apply/lib/rollback/state 四个生产文件被并发修改（见 §5）；本报告不把工作树当作基线 |
| 方法 | 完整逐行阅读五个文件（非关键词检索）+ T01–T14 隔离测试 |
| 未执行 | 真实 apply/rollback/state、HKCU/系统代理、Clash 进程启停、真实网络、原 faultinject-v4.ps1（见 A-21） |
| 秘密处理 | 测试只使用 canary 字符串；本报告不含真实主机、账号、口令、DPAPI 密文或 IP |

工作树漂移快照（写报告前一刻，2026-11-18 05:04:56）：

| 文件 | 行数 | sha256 前 16 | mtime |
|---|---|---|---|
| proxy_v4/apply-v4.ps1 | 158 | 122E0E350F212185 | 05:00:00 |
| proxy_v4/rollback-v4.ps1 | 67 | 049CD5C4B41F66C9 | 05:00:06 |
| proxy_v4/state-v4.ps1 | 61 | C92FF8423F297CA6 | 05:00:13 |
| proxy_v4/lib/V4.ps1 | 1223 | B188616A740145FC | 05:02:49 |
| proxy_v4/tests/faultinject-v4.ps1 | 141 | 38B61D16E8CC0952 | 04:35:59 |

git status 同时显示 proxy_v6/ 未跟踪，reviews/ 下已有 AGENT-C、AGENT-D 报告。本报告独立完成，未读取或采信其他代理的结论；其他代理的结论一律不作为证据。

## 1. 结论摘要

**发现计数：HIGH 10 / MED 13 / LOW 7（共 30；含工作树增量 D-01–D-04）。**

必须优先处理的阻塞项：

1. **A-01（HIGH）**：任何未取得锁的进程都会在 finally 删除锁持有者的 .lock；且 20s 超时短于一次正常 apply，并发下几乎必然触发。这是 M9“锁串行化”设计的直接反例。
2. **A-03 + A-04 + A-05（HIGH）**：事务在 New-V4Snapshot 内部停掉应用时就已“变脏”，但 $applied 直到 apply:140 才置位；快照失败或 profiles.yaml 读取失败时不重启、不恢复。快照不记录“原本不存在”，还原不删除新建文件，且逐文件 Copy-Item 不是原子恢复、没有落地后哈希校验。
3. **A-06（HIGH）**：事务失败恢复只还原文件和进程，不还原系统代理（HKCU）与 owner.json；-Repair 的失败路径完全没有恢复。
4. **A-07（HIGH）**：-Init 在取得锁之前写 settings.json，且使用非原子 WriteAllText；T02 已用真实 apply 源码复现“他人持锁时 settings 仍被写入”，T08 复现并发读者 1695/1699 次 IOException。
5. **A-08（HIGH）**：没有任何事务日志/意图记录；首个 live write 之后 Ctrl+C/kill/断电会留下半应用状态，下一次 apply 会把该状态当正常基线重新快照。
6. **A-12（HIGH）**：rollback 的 Restore 在停应用后失败时，catch 只 exit 40；系统代理还原和启动被跳过，应用停留在停止状态。
7. **D-01（HIGH，工作树）**：V6 新代码 New-V4SnapshotFiles 的 profiles 清单名少了分隔符（V4.ps1:645），把 profilesp1.yaml 写进 manifest；Test-V4SnapshotManifest 以 unsafe path 拒绝。**只要 profiles 目录里有任意 .yaml，快照就无法用于恢复，rollback 必然 40。**
8. **A-21（HIGH，测试台）**：faultinject-v4.ps1 的 FT12 直接对 C:\Windows\System32\drivers\etc\hosts 调用 ACL 修改路径；非提权时失败返回 false，但在有权限的账户上会真实改写系统文件 DACL。

对任务书 F01–F10 的独立裁定（详见 §4）：F01/F02/F03/F05/F06 按字面**不成立**（源码或隔离行为否证）；F04/F07/F08/F09 成立；F10 部分成立（残余为 catch 首个日志未保护）；其中 F02 的真实问题应改写为 A-03（事务边界在停进程而非首写）。

## 2. 事务模型与“变脏”的确切时刻

基线 apply-v4.ps1 的时间线（行号为基线）：

| 行 | 动作 | 已改变系统状态？ | 在 $applied 保护内？ |
|---|---|---|---|
| 95 | Get-V4Controller（读运行时文件） | 否 | — |
| 116 | New-V4Snapshot → lib:235 Stop-V4Clash → 应用被停止 | **是（进程）** | **否** |
| 124 | profiles.yaml 不可读 → Fail 10 | 应用已停止 | **否** |
| 140 | $applied = true | 否 | — |
| 141 | 写 profiles.yaml（第一个 live 文件写） | 是 | 是 |
| 145 | 写 profiles/v4-managed.yaml（若原不存在则新建） | 是 | 是 |
| 146 | 写 clash-verge.yaml | 是 | 是 |
| 150 | 启动应用 | 是 | 是 |
| 162 | 设置系统代理 | 是 | 是 |
| 165 | 写 owner.json | 是 | 是 |
| 182 | finally 释放锁 | — | — |

结论：

- **事务真正的 dirty 时刻是 lib:235 的 Stop-V4Clash（被 apply:116 的 New-V4Snapshot 触发）**，比 apply:140 早 24 行，也比第一个 live 文件写早 25 行。
- catch 的恢复条件是 `if ($applied -and $snap)`（apply:176）：快照创建失败时 $snap 为 $null；apply:124 的 Fail 10 时 $applied 仍为 $false。两种情况下 catch 都**不恢复、不重启**，应用被留在停止状态。
- 注释“F07: the transaction starts at the FIRST live write”（apply:139）只在“文件写”这个子集内成立，对进程状态与系统代理不成立。
- 该模型没有 journal：dirty 状态只存在于内存变量里；进程崩溃后不可恢复（A-08）。

## 3. 发现（基线 36222c9）

### 3.1 总表

| ID | 严重度 | 标题 | 位置 |
|---|---|---|---|
| A-01 | HIGH | 未持锁进程删除持有者锁（loser-deletes-winner） | apply:70/182；lib:178 |
| A-02 | MED | 锁是“文件存在”而非句柄；空锁永久卡死；PID 复用误判 | lib:152-176 |
| A-03 | HIGH | 事务边界在停进程；快照/读取失败不重启 | apply:116/124/140/176；lib:235 |
| A-04 | HIGH | 快照不记录“原本不存在”，还原不删除新建文件 | lib:240-255/279-284；apply:145 |
| A-05 | HIGH | 还原非原子、无落地校验，却记录“hash-verified” | lib:266-286；rollback:36-39 |
| A-06 | HIGH | 失败恢复不还原系统代理与 owner 记录 | apply:162-165/176-180 |
| A-07 | HIGH | -Init 在锁前写 settings；非原子；并发读者崩溃 | apply:36-70；lib:110-122 |
| A-08 | HIGH | 无事务日志；首写后崩溃留下半应用状态 | apply:140-147/170-182 |
| A-09 | MED | -DryRun 不是只读；依赖真实首跳与 AppData | apply:70/86-113；lib:53-59/313-323 |
| A-10 | MED | 日志初始化失败绕过退出码契约；dot-source 即建目录 | apply:22；lib:28-30/53-59 |
| A-11 | MED | rollback 语义：永远启动应用、端口默认 7897、owner 覆盖为 rollback | rollback:38-59 |
| A-12 | HIGH | 双失败：restore 停应用后失败即不再启动/不还原代理 | lib:278；rollback:38-65 |
| A-13 | MED | 系统代理快照/还原不完整（PAC/ProxyOverride/禁用时的 ProxyServer） | lib:326-340 |
| A-14 | MED | owner 记录无回滚；repair 先前值仅是自由文本 | lib:386-395；apply:91/165 |
| A-15 | MED | F10 残余：catch 首个日志未保护，可阻断恢复/掩蔽退出码 | apply:174/179；rollback:64 |
| A-16 | MED | state 契约违反：settings 缺失/非法时崩溃而非 exit 3 | state:11-14/63-68；lib:96-108/508 |
| A-17 | MED | 测试台给出假信心（FT04/05/06/08/09/10、零测试 exit 0） | tests:57-104/133-141 |
| A-18 | MED | ACL 加固失败被静默；Save 泄漏布尔值到管道 | apply:166-167；lib:120/125-149 |
| A-19 | MED | “启动成功”只等于端口在监听；恢复路径忽略启动返回值 | lib:216-227；apply:178 |
| A-20 | LOW | Set-V4Atomic 崩溃残留 .v4stage/.bak；Move-Item 非原子替换 | lib:289-311 |
| A-21 | HIGH | 测试台 FT12 直接对真实 hosts 调 ACL 修改路径 | tests:106-110 |
| A-22 | LOW | 日志文件名秒级，同秒运行混写 | lib:53-59 |
| A-23 | LOW | Stop-V4Clash 死代码 / 被省略的 HKLM 检查 | lib:186 |
| A-24 | LOW | 凭据未转义插入 YAML；-StaticPass 暴露于 argv | lib:439-447；apply:17 |
| A-25 | LOW | 基线 -Init 追加的 updated 用本地 1970 纪元（PST 偏差 -28800s） | apply:126 |
| A-26 | LOW | 帮助文本称 resilient 默认，代码默认 strict | apply:6 vs apply:14 |

### 3.2 HIGH 详细

#### A-01 HIGH — 未持锁进程删除持有者锁（loser-deletes-winner）

- 位置：apply-v4.ps1:70（Enter）、:182（finally 无条件 Exit）；lib/V4.ps1:178（Exit-V4Lock 直接 Remove-Item）；early Fail 在 apply:31/32/33/:69 也会走到同一 finally。
- 触发：任意第二个进程在锁被持有时启动，尤其是：-Repair -DryRun（在取锁前 Fail 11）、-Init -DryRun、settings.json 缺失（Fail 11）、或等待 20s 超时（Fail 33）。
- 观察：finally 从不检查本进程是否真正持锁；Exit-V4Lock 不校验 owner/内容/句柄。T02-A：holder 锁存在时运行 -Repair -DryRun，exit 11，**holder 的 .lock 被删除**；T02-B：holder 锁存在时运行 -Init（会写 settings 并等锁 20s），exit 33，**holder 的 .lock 同样被删除**。第三个进程随后可成功进入，两个事务可同时 Stop/写/快照。
- 期望：只有持锁 token 可释放；未获锁路径绝不触碰锁文件；锁超时必须大于最大事务时长或可等待事务结束。
- 隔离测试：T02（临时根目录复制真实 apply 源码；holder 由父进程写入 .lock 并存活；断言 loser 退出后锁文件仍在、第三次 Enter 失败）。这是纯文件/进程编排，不接触 HKCU、不启停 Clash。
- 证据：T02 A_exit=11、A_holder_lock_deleted=true；B_exit=33、B_holder_lock_deleted=true、B_settings_written_despite_lock=true。另：正常 apply 最坏耗时 ≥ 45s（Start）+ 3×curl（每次 3 站点×20s）远大于 20s，故并发下超时是必然而非偶然。

#### A-03 HIGH — 事务边界在停进程；快照/读取失败不重启

- 位置：apply:116（New-V4Snapshot）、:124（Fail 10）、:140（$applied=true）、:176（恢复条件）；lib:235（Stop-V4Clash）、:258（clashRunning 硬编码 false）。
- 触发：(a) New-V4Snapshot 在停止应用后任意失败（Copy-Item/Get-FileHash/manifest/Protect-V4Acl）；(b) New-V4Snapshot 返回后 profiles.yaml 读取失败（apply:124）；(c) $snap 赋值未完成（函数抛错）。
- 观察：应用已被停止；$snap 为 null 或 $applied 为 false → catch 不重启、不恢复，也没有任何日志说明“应用未恢复”。T04 用 mock 证明 Restore-V4Snapshot 从不启动应用；manifest 的 clashRunning 恒为 $false（lib:258），没有记录真实的停止前运行状态。
- 期望：在停止应用之前捕获 wasRunning；事务标记必须在停进程之前置 dirty；恢复路径必须覆盖“快照失败”，并在退出码/日志中区分“已恢复/未恢复”。
- 隔离测试：TX-01/TX-02 设计——mock Get-V4Paths/Get-V4AppPids/Stop-V4Clash（计数）与 New-V4Snapshot（注入抛错），运行 apply 事务副本；断言 Stop 已发生且 Start 被调用。T04 已证明现有 Restore 不会调用 Start。
- 证据：T04 stop_called=1、restore_start_called=0；source apply:176。

#### A-04 HIGH — 快照不记录“原本不存在”，还原不删除新建文件

- 位置：lib:240-255（只对存在的文件加入 files）、:279-284（只复制快照中存在的文件）；apply:145 新建 profiles/v4-managed.yaml。
- 触发：apply 首次运行（v4-managed.yaml 原本不存在），随后失败回滚；或运行期间应用/用户新建了根配置或 profile 文件。
- 观察：manifest 没有 absent 列表；Restore 不删除快照中不存在的目标。T04：还原后 profiles/v4-managed.yaml 与 extra-unrelated.yaml 仍存在；空快照还原是 no-op，快照之后新建的 clash-verge.yaml 仍存在。还原后的文件集合 ≠ 快照集合。
- 期望：manifest 记录 present 与 absent 两类；还原删除 absent 目标；还原完成后校验集合/哈希与快照一致。
- 隔离测试：DATA-03 / TX-11——临时 AppData；快照只含部分文件；删除/新建/修改现场后还原；断言 absent 被删除、present 哈希一致、用户自建未列名文件不被删除（避免误删）。T04 case1/2/empty 已执行。
- 证据：restore_new_managed_profile_still_there=true、restore_unrelated_extra_still_there=true、empty_snapshot_created_file_survives=true。

#### A-05 HIGH — 还原非原子、无落地校验，却记录“hash-verified”

- 位置：lib:266-286（Restore）、rollback:36-39。
- 触发：快照在恢复前被删除/篡改；或恢复时目标被占用、目标是目录、磁盘写入失败；或恢复中途进程退出。
- 观察：只在复制前对快照副本逐文件校验 SHA256；复制使用 Copy-Item -Force（无 temp+replace，无失败回滚，无落地后校验）。T04 统计：3 个 manifest 条目对应 3 次 Get-FileHash（仅校验副本），没有第 4–6 次落地校验；partial 用例中第一个文件已被覆盖、第二个复制抛错，函数抛出，现场半恢复。rollback:37 仍打印“files restored and hash-verified”，与实际行为不符。
- 期望：每文件 temp→校验→原子 replace→校验目标；失败时保持现场不变或回滚已改文件；日志只声明实际执行的校验；失败时报告已恢复/失败清单。
- 隔离测试：TX-07/TX-08——快照文件篡改（已有 T04）、目标为目录（已有 T04）、目标被独占（T03 同型）；断言无半恢复、日志不越权声明。T04 hashCalls=3、partial_threw=true。
- 证据：T04 restore_hash_verify_calls=3、partial_clashverge_restored=true、partial_threw=true。

#### A-06 HIGH — 失败恢复不还原系统代理与 owner 记录

- 位置：apply:162（Set-V4SystemProxy）、:164（Fail 32）、:165（Set-V4Owner）、:176-180（恢复只做 Restore + Start）。Repair 路径 apply:82-93 同样无恢复。
- 触发：系统代理已设置成功后，Fail 32（回读不一致）或 Set-V4Owner 写失败；-Repair 中 Set 成功但回读失败。
- 观察：catch 恢复文件并重启应用，但 HKCU 仍指向 127.0.0.1:mixedPort；owner.json 可能缺失或保留旧值。应用被以“旧配置”重启而系统代理仍指向本工具，状态自相矛盾；state 会把 systemProxy 报为本工具值而 owner 报 none/旧值。Repair 路径没有文件改动，但同样不还原已改写的系统代理（$applied 为 false 时 catch 什么也不做）。
- 期望：改动前记录 systemProxy(enabled/server) 与 owner；恢复时按记录还原并验证；Repair 也纳入同一恢复；owner 记录失败要回滚或删除。
- 隔离测试：HKCU 依赖注入——覆写 Get/Set/Clear-V4SystemProxy 与 Get/Set-V4Owner 为内存实现，在 SetOwner 注入异常；断言恢复时 Clear/Restore 被调用且 owner 被还原。不得触碰真实 HKCU（任务约束）。
- 证据：源码控制流；本次未执行 HKCU 路径。

#### A-07 HIGH — -Init 在锁前写 settings；非原子；并发读者崩溃

- 位置：apply:36-67（Init 迁移/写 settings）、:69（检查）、:70（取锁）；lib:110-122（Save 用 WriteAllText 直接写最终路径）、lib:96-108（Get 读同一文件）。
- 触发：另一个事务持锁时执行 apply -Init；两个 -Init 并发；state/apply 在 Save 写窗口读取 settings.json。
- 观察：T02-B（真实 apply 副本、父进程持锁）：settings.json 被写入（含 DPAPI 密文），随后在 20s 后 exit 33，且 holder 锁被删——Init 完全没有被锁保护。T02-D：Init 成功后 first-hop 失败 exit 20，settings.json 保留，没有回滚。T08：一个写者循环 WriteAllText，读者 1699 次尝试中 1695 次 IOException、0 次部分读、4 次完整读——并发读者不是看到旧/新版本，而是直接异常；state 无锁（A-16），apply 的 Get-V4Settings 也没有对 IOException 的专门处理。
- 期望：Init 在锁内；settings 走 temp+replace+校验+ACL；读者要么看到旧版要么看到新版；Init 失败可回滚或明确幂等。
- 隔离测试：LOCK-08/PARAM-02 + T08；T02-B/D。
- 证据：B_settings_written_despite_lock=true、B_exit=33、D_exit=20、D_settings_still_present=true；write_reader_io_failures=1695。

#### A-08 HIGH — 无事务日志；首写后崩溃留下半应用状态

- 位置：apply:140-147（三次 live 写）、:170-182（finally 只释放锁）；lib 无任何 journal/intent 文件。
- 触发：首个 live write 之后发生 Ctrl+C、控制台关闭、Stop-Process、断电。PowerShell 的 Ctrl+C 是 pipeline stop，catch 不执行，finally 会执行；因此不会走 :176 的恢复。
- 观察：系统可能处于“profiles.yaml 已改、v4-managed.yaml 已写、clash-verge.yaml 已写、应用未起、系统代理未设、owner 未写”的组合；没有 dirty marker，下次 apply 正常启动并把这个状态当作新基线快照，之后的 rollback 会“还原”到这个半状态。
- 期望：快照创建后写 intent（快照路径、目标文件、期望 hash、阶段）；成功后写 commit/清 intent；下次启动检测未完成 intent 并引导恢复；finally 只做不依赖状态的清理。
- 隔离测试：事务故障注入——子进程在第一个 Set-V4Atomic 返回后 Environment.Exit（不触发 catch），断言磁盘存在可识别的 intent/未完成标记且目标 hash 与快照可恢复；基线预期失败（无标记）。本次未执行（不能在真实 apply 上杀进程）。
- 证据：源码 + PowerShell finally/catch 语义；无 journal 代码。

#### A-12 HIGH — rollback 双失败：应用保持停止，系统代理不还原

- 位置：lib:278（Restore 内部停应用）；rollback:38（Restore 调用）、:41-47（代理还原，仅在 Restore 成功后执行）、:61-65（catch 只 exit 40）。
- 触发：rollback 时 Restore 先停应用，随后任一副本复制失败（文件被占用、目标是目录、磁盘错误）。
- 观察：Restore 抛出 → 外层 catch 记录并 exit 40；启动应用（:47-48）与系统代理还原（:41-47）都不执行；应用保持停止，系统代理可能仍指向本工具（若此前 apply 成功）。
- 期望：双失败也要尽力恢复代理与进程，并分别报告三项状态（files/proxy/process）；无法恢复时给出可操作指引；不要在单点失败后放弃全部恢复。
- 隔离测试：TX-08——临时 AppData + mock Stop（记录调用）+ 目标文件被目录占位；断言 Restore 失败后：Stop 已发生、Start 未调用（复现）、proxy 还原未调用（复现）、exit 40；修复后断言 Start/Proxy 仍被尝试。
- 证据：T04 partial 已证明“Restore 失败后不启动、半恢复”；本次 partial 用例的 mock 进程列表为空，Stop 未触发，需补 pids>0 用例来覆盖停应用后的路径。

#### A-21 HIGH — 测试台 FT12 直接对真实 hosts 调 ACL 修改路径

- 位置：tests/faultinject-v4.ps1:106-110。
- 触发：运行 faultinject-v4.ps1；当前账户能改写 hosts 的 DACL（管理员、UAC 关闭、服务账户）。
- 观察：Protect-V4Acl 对该系统文件执行 Get-Acl → SetAccessRuleProtection(true,false) → 移除全部 ACE → 重新加当前用户/SYSTEM/Administrators → Set-Acl。非提权时预期在 Get/Set 失败并返回 false；但这不是安全边界，有权限时它会**真实改写系统文件 ACL**。测试台必须默认不接触生产。
- 期望：用临时目录构造“无法拥有/无法 Set-Acl”的场景（例如在临时目录上设置 Deny-Write ACE），绝不指向系统文件。
- 隔离测试：%TEMP% 自建目录 + 对其父目录给当前用户 Deny-Write；断言 Protect-V4Acl 返回 false 且无异常逃逸；不得传 C:\Windows\...。
- 证据：源码；本次未运行（与 DECISION-LOG D-006 结论一致）。

### 3.3 MED 详细

#### A-02 MED — 锁是“文件存在”而非句柄；空锁永久卡死；PID 复用误判

- 位置：lib:152-176（Enter）、:178（Exit）。
- 触发：持锁进程被外部删除锁文件；崩溃发生在 CreateNew 与写入之间留下 0 字节锁；锁内 PID 被无关进程复用；旧锁内容为 pid= 前缀部分写入。
- 观察：T01——锁持有进程存活时外部删除锁文件后第二次 Enter 立即成功（double_holder=true，证明没有持有句柄）；0 字节锁让 Enter 等满 3s 后失败且锁永久保留，第二次尝试仍失败；pid= 部分写入同样永久阻塞；死 PID 0.01s 回收；活着的无关 PID 2.09s 阻塞；Exit-V4Lock 无条件删除他人记录。
- 期望：真正持有句柄或 token+进程启动时间；空/半写锁要按年龄回收；不得仅凭 PID 判活；Exit 校验 owner。
- 隔离测试：T01 A–F（临时锁路径；无 HKCU/进程启停）。
- 证据：见 T01 输出。

#### A-09 MED — -DryRun 不是只读；依赖真实首跳与 AppData

- 位置：apply:70（取锁写 config/.lock）、:22（Start-V4Log 写 evidence）、:86-112（TEMP staging、mihomo -t）、:113（返回）；lib:313-323（-d 使用真实 AppData）。
- 触发：任意 -DryRun。
- 观察：T02-E：valid settings + -DryRun，在 exit 20 之前新增 1 个 evidence 日志，锁文件被创建后删除；DryRun 必须在 first-hop 可用时才继续（离线不能 dry-run）；mihomo -t 以真实 AppData 为工作目录，无法证明零副作用。
- 期望：dry-run 不写锁/日志/生产目录（或显式 --output-temp），离线可完成静态生成+校验，mihomo -t 使用隔离工作目录。
- 隔离测试：PARAM-07——快照 config/evidence/appdata 的文件列表与哈希，运行 dry-run，断言零变化；断网环境断言仍可完成。
- 证据：T02-E evidence_logs_added=1、exit=20。

#### A-10 MED — 日志初始化失败绕过退出码契约；dot-source 即建目录

- 位置：apply:22（Start-V4Log 在 try 之前）；lib:28-30（任何 dot-source 都创建 config/backup）、:53-59。
- 触发：evidence 路径不可写/被同名文件占用；仓库目录只读；一次 dry-run 或 state 在只读环境执行。
- 观察：T09-A：把 evidence 建成文件后运行 apply -Repair -DryRun，脚本以未处理异常 exit 1，stderr 为 Add-Content 错误，未进入任何文档化退出码，且锁从未创建。T05/T03/T04 中 dot-source 都创建了 config/backup 目录（即使 state 声称只读、dry-run 声称不改动）。
- 期望：日志初始化失败降级并继续（warn），不阻断契约；只在真正写操作时创建目录；只读命令不创建目录。
- 隔离测试：LOG-01——把 evidence 父路径设为文件，断言 exit 仍是文档化代码且主流程继续；只读命令前后目录集合一致。
- 证据：T09-A exit=1、stderr 含 Add-Content。

#### A-11 MED — rollback 语义：永远启动应用、端口默认 7897、owner 覆盖为 rollback

- 位置：rollback:38、:47-48、:57、:59。
- 触发：回滚一个 apply 前应用未运行的快照；配置 mixedPort ≠ 7897；重复回滚。
- 观察：Start-V4Clash 无条件调用（默认端口 7897，而非快照/配置端口）；应用若未运行也会被启动；owner 被覆盖为 rollback，不恢复原 owner；Restore 内部 Stop 也用默认 7897。
- 期望：快照记录 clashRunningBefore（基线没有），回滚恢复该状态；使用快照/配置端口；owner 恢复为 snapshot 的原值或删除。
- 隔离测试：LOCK-06/OWNER-01——mock Start/Stop/Get-V4AppPids 与 Get-Set-V4SystemProxy；对“apply 前未运行”的快照回滚，断言 Start 不被调用；配置 7899 时断言等待 7899。
- 证据：源码；未执行真实 rollback。

#### A-13 MED — 系统代理快照/还原不完整

- 位置：lib:326-330（只读 ProxyEnable/ProxyServer）、:332-340（禁用时只写 ProxyEnable=0）、apply:163-164（只回读注册表）。
- 触发：用户原有 PAC（AutoConfigURL）、ProxyOverride、按协议代理字符串；原 ProxyEnable=0 且 ProxyServer 非空；PAC 覆盖 ProxyServer。
- 观察：PAC/ProxyOverride 完全不记录、不恢复；禁用路径 Clear-V4SystemProxy 只改 ProxyEnable，apply 设置的 ProxyServer 继续残留，用户以后手动启用会得到本工具的值；验证只读注册表，不检查 WinINET 生效值，PAC 存在时会假成功。
- 期望：记录并恢复 ProxyEnable/ProxyServer/ProxyOverride/AutoConfigURL；验证生效值；禁用时恢复原 ProxyServer 字符串。
- 隔离测试：把注册表访问抽象为可注入 provider（不碰 HKCU），用内存模型覆盖四种组合（PAC、Override、disabled+stale server、per-protocol）；断言往返字节级一致。
- 证据：源码；未执行 HKCU。

#### A-14 MED — owner 记录无回滚；repair 先前值仅是自由文本

- 位置：lib:386-395（Set-V4Owner 直接 WriteAllText）、apply:91（repair 的 previous 放在 note）、:165（仅成功末尾写）、:176-180（catch 不碰 owner）。
- 触发：apply 在 SetOwner 之前/期间失败；Repair 失败；rollback 后再次 apply。
- 观察：失败恢复后 owner.json 可能保留上一次 apply 的 clash/旧时间，或根本不存在；恢复不会把 owner 改回“非本工具”；rollback 把 owner 写成 rollback，state 把它当所有者展示。
- 期望：owner 记录在改动前捕获、失败时恢复/删除；repair 的先前值用结构化字段；rollback 恢复原 owner。
- 隔离测试：OWNER-02——mock owner 路径与系统代理，注入失败，断言 owner 文件内容回到基线；rollback 后断言 owner 不是 rollback 而是原值/无。
- 证据：源码。

#### A-15 MED — F10 残余：catch 首个日志未保护，可阻断恢复/掩蔽退出码

- 位置：apply:174（Write-V4Log 分类日志，在恢复之前，未包 try）、apply:179（恢复失败日志在 catch 内、$exit=40 之前）、rollback:64（日志在 $exit=40 之前）。
- 触发：Write-Host 抛错（控制台句柄失效/关闭）或 Get-V4Redacted 意外抛错。Add-Content 已被 lib:50 的 try/catch 吞掉，因此只有 Write-Host 分支是残余向量。
- 观察：apply:174 抛错则整个 catch 中断，:176-180 的恢复不执行，finally 以原 $exit 退出；apply:179 抛错则 $exit=40 不执行，退出码退回原始失败码；rollback:64 抛错则 $exit 保持 0，**报告成功而实际回滚失败**。
- 期望：异常分类/恢复/报告三段的每一次日志都不得改变控制流；退出码先赋值再日志。
- 隔离测试：LOG-03/04——在临时 apply/rollback 副本中把 Write-V4Log 替换为抛错桩（只改副本），注入一个 Fail，断言恢复函数仍被调用、exit 40 仍成立；rollback 断言不出现 exit 0。
- 证据：源码；本次未执行（无可复现的真实主机句柄失效）。

#### A-16 MED — state 契约违反：settings 缺失/非法时崩溃而非 exit 3

- 位置：state:11（EAP=Continue 被 lib:16 覆盖为 Stop）、:14（无 try 的 Get-V4State）、:63-68（退出码）；lib:96-108（throw）、lib:508（-ErrorAction SilentlyContinue 对 throw 无效）。
- 触发：首次使用（settings.json 不存在）、settings.json 损坏、DPAPI 无法解密（换用户）。
- 观察：T05：两种用例都 exit 1、stdout 0 字节、stderr 有异常，无 JSON；文档承诺 FAILED/UNKNOWN + exit 3。T10 证明 -ErrorAction SilentlyContinue 不能吞掉 throw，且 EAP 在 dot-source 后为 Stop。state 不取锁，可能与 -Init/apply 的 settings 写入相撞（T08 的 IOException）。
- 期望：顶层 try/catch，任何探测失败都输出合法 JSON（state=FAILED/UNKNOWN）并按文档 exit 3；读 settings 用共享读/重试。
- 隔离测试：PARAM-04/05 + LIFE-04——临时根目录（无 settings / 非法 JSON）运行 state -Json；断言 exit 3、stdout 为合法 JSON。T05 已执行。
- 证据：missing_settings_exit=1、stdout_len=0、badjson_exit=1。

#### A-17 MED — 测试台给出假信心

- 位置：tests:57-63（FT04）、:65-70（FT05）、:72-76（FT06）、:78-96（FT07/08/09）、:98-104（FT10）、:133-141（汇总/退出）。
- 触发：把 13/13 当作并发/恢复/状态已证。
- 观察：FT04/FT10 在同一进程内二次 Enter（同进程的 FileShare.None 也会失败，根本未验证跨进程竞争），完全不覆盖 apply 的 loser-delete；FT06 的 pass 参数是字面 $true（恒真）；FT05 只测 Test-V4Port，不测 Start-V4Clash；FT08/FT09 直接运行真实 state（含网络），不注入依赖故障；FT11/FT14 只在 notCovered 里声明未测；bench 的 EAP 被 lib 覆盖为 Stop，首个意外终止错误会中断后续场景且无汇总；零测试时 exit 0（T11）。另外：源码确实有最终 if ($passed -eq $total) { exit 0 } else { exit 1 }（tests:141），因此 REPORT-V4:35 的“exit $(if...) 表达式取值问题”无法从当前源码复现，旧证词不能作为 V5-07 的依据。
- 期望：跨进程锁竞争、未获锁不删锁、真实事务恢复、日志故障都要有独立负向用例；零测试/跳过/证据写失败必须非零或显式记录；pass 不得使用字面 $true。
- 隔离测试：META-01..07 + LOCK-01..05；T11 已提供零测试 exit 0、失败 exit 1、异常 exit 1、无 LASTEXITCODE 泄漏的行为基线。
- 证据：T11 zero_tests_exit=0、bench_rec_count=13、bench_ft06_pass_true=true；T10 EAP=Stop。

#### A-18 MED — ACL 加固失败被静默；Save 泄漏布尔值到管道

- 位置：apply:166-167（Protect-V4Acl 返回值被 | Out-Null 丢弃）、lib:120（Save 内同样丢弃）、lib:125-149（失败返回 false 而非抛错；:133 早退只检查“含我”，不检查 Everyone/Users）；T08 C 显示 Save 的 Protect 结果被输出到管道（True）。
- 触发：非 NTFS/无权限/ACL 已损坏；apply 成功但 ACL 未加固。
- 观察：apply 报告成功同时 secrets 仍可能是继承 ACL；state 不检测 ACL；Save 的 True 会污染 apply 的标准输出（若被 $(...) 捕获）。
- 期望：ACL 加固失败应作为事务错误（专用退出码）或至少 WARN；早退前验证无弱 ACE；函数不得污染管道。
- 隔离测试：SEC-02/DATA-05——临时目录 + 一个 Everyone 读 ACE，调用 Protect 断言返回 true 且 ACE 仅允许集合；对不可加固路径断言抛错/退出码。
- 证据：T08 save_settings_emits=[True]。

#### A-19 MED — “启动成功”只等于端口在监听；恢复路径忽略启动返回值

- 位置：lib:216-227（Start-V4Clash 只测端口）、apply:178（Start-V4Clash 结果 | Out-Null）、rollback:47-48（失败只 WARN，exit 仍 0）。
- 触发：端口被其他进程占用；应用启动但未监听；应用已在运行（基线会重复启动）；恢复启动失败。
- 观察：Start 返回 true 不能证明是我们的 Clash；apply:178 忽略启动失败仍报告“restore failed/原始码”；rollback 启动失败只 WARN 并以 0/41 退出。
- 期望：启动成功应验证进程身份/端口所有权；恢复路径必须检查并反映启动结果；已在运行时不得重复拉起。
- 隔离测试：LIFE-02/LIFE-05——mock Test-V4Port/Get-V4AppPids/Start-Process，验证“端口被占用”“已运行”“启动后端口未开”三种分支。
- 证据：源码；未执行启动路径。

### 3.4 LOW

| ID | 位置 | 触发 | 观察 vs 期望 | 隔离测试 |
|---|---|---|---|---|
| A-20 | lib:289-311 | Set-V4Atomic 校验后进程 killed | T03-E：目标目录残留 .v4stage-6a0f0e8b.yaml；基线用 Move-Item -Force 而非 File.Replace，无启动清理。期望临时/备份文件在下次启动被识别/清理，替换原子化。 | T03 E/F（已执行）；崩溃子进程退出 99，目标未变。 |
| A-22 | lib:53-59 | 同一秒两次 Start-V4Log | T09-B：两次得到同一文件，header 计数 2，两个进程混写。期望毫秒+随机后缀（V6 已修）。 | T09 B（已执行）。 |
| A-23 | lib:186 | 无 | `if ($pids.Count -eq 0 -and -not (Test-Path 'HKLM:\')) { }` 是空语句，暗示被省略的 HKLM 检查/注释。期望删除或补全。 | 静态；无运行价值。 |
| A-24 | lib:439-447；apply:17 | 凭据含双引号/换行 | T07：password 注入换行后生成配置出现注入的 udp: true 键；mihomo -t 是唯一语法门（P1 研究称 mihomo 不拒绝未知顶层键）。-StaticPass 会出现在进程命令行。期望 YAML 转义/引号校验；避免 argv 传秘密。 | T07（已执行，仅生成字符串，无系统接触）。 |
| A-25 | apply:126 | 首次追加 v4-managed 块 | T06：本地 1970 纪元比 UTC 少 28800s（PST）；下一次 refresh 才纠正。期望统一 UtcNow（V6 已修）。 | T06（已执行）。 |
| A-26 | apply:6 vs apply:14 | 无参数运行 | 帮助称 resilient 默认，代码默认 strict；运维预期与实际相反。期望文档/默认一致。 | 静态；`Get-Help` 参数默认值可直接验证。 |

## 4. F01–F10 复验裁定

| ID | 裁定 | 依据（隔离测试/源码） | 残余 | 复验测试 |
|---|---|---|---|---|
| F01 | **不成立（按字面）** | apply:31 互斥；T02-A/C：-Repair -DryRun 与 -Init -DryRun 都在任何代理/设置写入前 exit 11；DryRun 在 :113 返回，Repair 在 :93 返回，均到不了 :162。 | DryRun 仍写锁/日志/TEMP 并跑真实 mihomo -t（A-09）。 | PARAM-01/02/07。 |
| F02 | **不成立（按字面）** | $applied=true 在 apply:140，紧邻首个 live 写 :141；不存在“标志晚于首写”。 | 真实边界在 :116 停进程（A-03），标志语义仍错。 | TX-01/TX-02（快照失败→进程恢复）。 |
| F03 | **不成立（按字面）** | apply:170 的 finally 为空；恢复在 catch（:176）内、外层 finally（:182）释放锁之后才结束。rollback 的 finally 也在 catch 之前。 | 真正问题是未持锁也释放/删除（A-01）。 | LOCK-02/03。 |
| F04 | **成立（条件性）** | T06：CRLF 文件 updated 行不匹配（case4 false）；4 空格缩进时改到下一个 Profile 的 updated（case5 true）；V4 块无 updated 时改到下一个（case2 true）；append 纪元偏差 -28800s。 | V6 工作树已重写为按行块解析（C1/C3/C4 通过），但插入路径有 D-02。 | DATA-02 + 7 类 profiles.yaml 用例。 |
| F05 | **无法复现（描述不符）** | tests:141 存在 `if ($passed -eq $total) { exit 0 } else { ... exit 1 }`；T11：零测试 exit 0、一失败 exit 1、未捕获异常 exit 1、无 LASTEXITCODE 泄漏。REPORT-V4:35 所称 exit $(if...) 在源码中不存在。 | 测试台仍有 A-17/A-21（假信心、真实 hosts 风险）。 | META-01..07（含零测试必须非零）。 |
| F06 | **不成立** | T07：strict 组仅 US-WA-SOCKS5（strict_has_DIRECT=false）；resilient 才含 DIRECT（设计如此，fallback）。 | 默认值文档不一致（A-26）。 | DATA-01/DATA-02 + Build-V4Profile 单元。 |
| F07 | **成立（OPEN）** | 真实边界在停进程（A-03）；快照不完整/还原非原子（A-04/A-05）；恢复不还原代理/owner（A-06）；双失败（A-12）；无崩溃 journal（A-08）。 | V6 已引入 wasRunning/beforeProxy/Recovery（部分修复），但无 journal。 | TX-01..TX-11（按 §3 测试设计）。 |
| F08 | **成立（基线）** | T06 case2/case5：目标块无 updated 或缩进非 2 空格时，会改写下一个 Profile 的 updated；case7 不会补 current（validator 需自行发现）。 | V6 的块级解析已修（C1/C2 的“其它块不动”除了插入路径 D-02；Test-V4ProfileText 在写前拦截）。 | DATA-02 七类用例 + V6 的 Update/Test 单元。 |
| F09 | **成立（基线）** | T02-B：holder 持锁时 settings 仍被写入，随后 exit 33；T02-D：Init 成功 + 后续失败 settings 不回滚。 | V6 已改为锁后再 Init（apply:36-38），待负向测试确认。 | LOCK-08/PARAM-02 对 V6 重跑。 |
| F10 | **部分成立** | catch 首个日志 apply:174 未保护；恢复失败日志 :179 在 $exit=40 之前；rollback:64 在 exit 40 之前（理论上可退 0）。Add-Content 已被吞掉，仅 Write-Host 路径。 | V6 已把 Write-Host/日志包 try、恢复注记单独保护（V4:61-68/86-89）。 | LOG-03/04：把写日志替换为抛错桩，断言恢复仍执行、exit 40 成立。 |

对任务书旧裁定的修正：F01/F02/F03/F05/F06 的表述与 36222c9 源码不符，不能作为 V6 的待修事实；F04/F07/F08/F09 成立；F10 需按“catch 首个日志未保护 + 退出码赋值顺序”重述。

## 5. 工作树漂移与 V6 增量发现（重要）

审计期间生产文件被并发修改：04:51 时 apply 为 182 行（基线内容）；04:53 变为 170 行；05:00 变为 158 行并改为 Invoke-V4ApplyTransaction；V4.ps1 从 542 行变为 1223 行。本报告主结论锚定 commit 36222c9；本节锚定 2026-11-18 05:02:49 的 V4.ps1（sha B188616A740145FC）与 05:00 的 apply/rollback/state。**这些发现可能已被后续编辑修复，必须以当前源码复验。**

### D-01 HIGH — 快照 manifest 的 profiles 清单名缺分隔符，导致 rollback 必然失败

- 位置：V4.ps1:645（`$rel = 'profiles' + $fi.Name`，缺少 `\`；基线是 `'profiles\' + $_.Name`）。
- 触发：任意一次 apply 的 New-V4Snapshot，只要 profiles 目录下存在至少一个 .yaml（正常安装必然存在）。
- 观察：T12-A 用隔离 AppData 调用新 New-V4SnapshotFiles，manifest 出现 `profilesp1.yaml`；Test-V4SnapshotManifest 以 `snapshot manifest has an unsafe path: profilesp1.yaml` 拒绝；Restore-V4Files 同样拒绝。快照文件实际位于 snap\profiles\p1.yaml，manifest 指向 snap\profilesp1.yaml，即使放宽路径校验也会 `snapshot incomplete`。结果：**apply 成功后可回滚的假设不成立，rollback 必然 exit 40。**
- 期望：`$rel = 'profiles\' + $fi.Name` 或 `Join-Path 'profiles' $fi.Name`；并用 T12-A 回归。
- 隔离测试：T12-A（已执行）——临时 AppData + 一个 profiles/p1.yaml，调用 New-V4SnapshotFiles + Test-V4SnapshotManifest + Restore-V4Files；断言 manifest name 为 profiles\p1.yaml 且 restore ok。
- 证据：A_manifest_names=[clash-verge.yaml, profiles.yaml, profilesp1.yaml]；A_manifest_rejected=true；A_restore_error=unsafe path。

### D-02 MED — Update-V4ProfileText 插入路径使用过期索引，破坏下一个 Profile 并产生重复 current

- 位置：V4.ps1:944-949（先算 $currentIndex）、:986-990（在 $block.end 插入 updated）、:992（用旧 $currentIndex 写 current）。
- 触发：V4-Managed 块存在但没有 `updated:` 行（例如应用/用户重写 profiles.yaml 后丢字段），且 current 行在插入点之后（正常都在文件末尾）。
- 观察：T13：输入“我们的块无 updated + 下一个 SUBX 块有 updated + current: SUBX”，输出把 SUBX 的 updated 行替换成 `current: V4Mngd0001`，并留下原来的 `current: SUBX` → 两个 current、SUBX 的 updated 丢失。T14：Test-V4ProfileText 能捕获（current 计数=2）→ apply 在 :107 预检抛错（exit 1），**不会写坏生产文件**，但“块缺失 updated 时补插”的正常路径完全不可用。
- 期望：插入后重新计算 currentIndex，或先写 current 再插入；补充“块存在但缺 updated”“current 在插入点前/后”“下一个块紧随其后”三类用例。
- 隔离测试：T13/T14（已执行）；断言输出 current 计数=1、其它块 updated 原值保留、Test-V4ProfileText 通过。
- 证据：T13 输出两个 current；T14 guard_catches_shift_corruption=true、corrupted_current_count=2、corrupted_other_updated_kept=false。

### D-03 MED — 0 字节 .lock 仍会永久卡死（10 分钟年龄兜底不生效）

- 位置：V4.ps1:488-511（`$txt = Read-V4File`; `if ($txt) { try JSON... }`；年龄兜底只在 JSON 解析 catch 内）。
- 触发：进程在 File.Open(CreateNew) 与 fs.Write 之间被 kill，留下 0 字节锁；或文件被清空（纯空白内容会进入 JSON 解析 catch，仍可被年龄兜底；0 字节不会）。
- 观察：T12-D：0 字节锁 → Enter 等满 2.1s 返回 null，锁保留，第二次仍失败。与基线 A-02 相同；新的 token/processStart 设计没有覆盖“空文件”。
- 期望：`if (-not $txt)` 时直接按文件 LastWriteTime 年龄判定 stale；或创建锁时先写临时文件再原子 rename 到 .lock。
- 隔离测试：T12-D（已执行）。
- 证据：D_empty_lock_blocked=true、D_empty_lock_elapsed_s=2.1、D_empty_lock_persists=true。

### D-04 LOW — 陈旧锁回收仍有读-比较-删除 TOCTOU

- 位置：V4.ps1:512-515（`$again = Read-V4File; if ($again -eq $txt) { Remove-Item }`）。
- 触发：两个进程同时判定同一陈旧锁；A 删除并创建新锁，B 在读取 $again 之后、Remove 之前被抢占。
- 观察：B 可能删除 A 的新锁。窗口极小（两步之间），但仍是 TOCTOU；建议 rename 陈旧锁为唯一名字（原子）后再删。
- 期望：用 `Move-Item`/`File.Move` 抢占式回收；失败则重试，绝不按路径删除未经再次验证的锁。
- 隔离测试：双进程 + 在 Remove 前注入 Sleep 的测试钩子（仅测试副本）复现；基线无法注入，标注为设计级残余。
- 证据：静态（本次未执行）。

### D-05 基线与 V6 工作树的状态对照（固定到上述 sha）

| 基线项 | V6 工作树状态 | 依据 |
|---|---|---|
| A-01 loser-deletes-winner | **已修（待行为复验）** | lock 对象 + token 校验 + finally 仅 if ($lock)（apply:156；V4:523-541） |
| A-02 锁存在性/空锁/PID 复用 | 部分修复：token+processStart+Flush；**空锁仍卡死（D-03）**；新格式 PID 复用已缓解 | V4:458-521；T12-D |
| A-03 停进程后不重启 | **已修（设计）**：wasRunning 在快照前捕获，Recovery 负责 Stop/Restore/Proxy/Start；待 TX-01 复验 | apply:111-125；V4:91-208 |
| A-04 缺失追踪 | **设计已修**：manifest absent + Restore 删除 absent（T12-B 通过）；但被 D-01 阻断 | V4:628-667/753-760；T12-B |
| A-05 还原非原子/无落地校验 | **大部分已修**：Set-V4Atomic 用 File.Replace，validator 校验 tmp 哈希后再替换；失败聚合上报 | V4:737-811；T12-B |
| A-06 不还原代理/owner | **部分修**：beforeProxy + RestoreProxy；owner 仍无恢复；Repair 仍无恢复 | V4:158-160/192-204；apply:65-77 |
| A-07 Init 在锁前 | **已修**：锁后再 Init | apply:36-52；T02 需对 V6 重跑 |
| A-08 无 journal | **未修** | 全文件无 intent/commit 标记 |
| A-09 DryRun 非只读 | **未修**：仍取锁/写日志/TEMP；mihomo -t 仍用 p.AppData | apply:25/37/86-97 |
| A-10 日志初始化失败 | **已修**：Start-V4Log 返回 bool，失败仅 WARN；dot-source 不再建目录 | apply:25-26；V4:36-45/70-83 |
| A-11 rollback 语义 | **未修**：仍无条件启动、默认端口、owner=rollback | rollback:43-59 |
| A-12 rollback 双失败 | **未修**：Restore 失败后仍跳过代理/启动 | rollback:38-65；V4:769-775 |
| A-13 代理快照不完整 | **未修**：仍无 PAC/Override；禁用时只关 ProxyEnable | V4:826-845 |
| A-14 owner 无回滚 | **未修** | V4:183；rollback:59 |
| A-15 catch 日志未保护 | **已修**：Write-V4Log 全包 try；Write-V4RecoveryNote 单独 try | V4:61-89/105-144 |
| A-16 state 崩溃 | **已修**：顶层 try + 合成 FAILED JSON；T14 实测 exit 3 + 合法 JSON | state:14-27；T14 |
| A-17/A-21 测试台 | **未修**：tests 文件未改 | sha 38B61D16 |
| A-18 ACL 静默 | **已修**：Save/apply 检查失败并抛 12 | V4:306/314；apply:179-182 |
| A-19 启动判定 | 部分修：Start-V4ClashCore 不重复拉起、Recovery 检查启动返回值；成功仍只等于端口监听 | V4:578-607/127-129 |
| A-20 原子残留 | 部分修：改用 File.Replace；bake 残留/无启动清理仍在 | V4:779-811 |
| A-24 YAML 注入 | **未修**：Build 仍直接插值凭据（需复核） | V4:1018+ |
| A-26 默认值文档 | **未修**：apply:6 称 resilient 默认，:15 默认 strict | apply:6/15 |

## 6. 本环境无法测试的残余风险

1. **HKCU/系统代理真实语义**：PAC（AutoConfigURL）、ProxyOverride、按协议代理字符串、WinINET 生效值、Clash Verge 对系统代理的接管/释放（含上游 #8639）、刷新时机。禁止触碰 HKCU，本轮只能做函数注入级测试。
2. **真实 Clash 进程与 service 模式**：Stop/Start 的实际时序、服务自动重启、多实例、启动到监听的真实延迟、`Stop-V4Clash` 端口释放与进程名覆盖（mihomo.exe/clash-verge-service.exe）。禁止启停生产进程。
3. **真实 mihomo -t**：生成的 CRLF/LF YAML、未知字段容忍、注入后的语义（P1 研究称不拒绝未知顶层键）、大配置/慢磁盘下的超时（当前无超时）。
4. **真实 AppData 行为**：Clash Verge 启动时是否重写 clash-verge.yaml、是否改写 profiles.yaml 的 updated、profile 文件锁；这些决定 F08/F04 的真实触发概率。
5. **NTFS/ACL/DPAPI 边界**：非 NTFS 卷上 Protect-V4Acl 失败（Init 会硬失败）、跨用户 DPAPI、继承/所有者异常、杀毒软件锁定。
6. **崩溃/断电时序**：Ctrl+C、窗口关闭、kill -9、断电；本报告只能给出设计与模拟，未在真实 apply 上注入（禁止）。
7. **超时与网络**：first-hop/exit-IP 探测在真实网络下的失败模式、curl 版本差异、20/45s 超时的边界。
8. **并发交错**：PID 复用、跨进程锁回收的极小窗口（D-04）、两个事务同时 start 的窗口；未做真实双事务演练。
9. **磁盘满/只读卷/长路径/Unicode**：FT11 未覆盖；`$` 锚定正则在 CRLF 上的行为已由 T06 证明，但真实 profiles.yaml 的行尾未验证（禁止读生产 appdata 内容？只读是允许的，但本报告未读取）。
10. **工作树持续变化**：V6 重构在审计期间被多次修改（04:51–05:02），D-01/D-02/D-03 必须按冻结后的 sha 重新验证；不要在未冻结的代码上宣称缺陷关闭。

## 7. 隔离测试方法与可复现性

所有测试均在 %TEMP%\dsh-v4audit 下运行（脚本 T01–T14，非仓库文件）：

| 测试 | 内容 | 关键结果 |
|---|---|---|
| T01 | 基线锁语义：外部删除、0 字节/半写锁、死 PID、活无关 PID、Exit 越权 | double_holder=true；空锁 3.3s 后仍保留；活无关 PID 阻塞 2.09s；Exit 删除他人锁 |
| T02 | 真实 apply 源码副本 + 父进程持有锁：-Repair -DryRun、-Init、-Init -DryRun、-Init + first-hop 失败、DryRun 有效性 | A/B holder 锁被删；B settings 在锁外写入；C 互斥；D settings 不回滚；E DryRun 写 evidence 日志 |
| T03 | Set-V4Atomic：成功、validator 失败、目标被独占、只读目标、崩溃残留、Move-Item -Force | 前三者干净；只读目标被覆盖；崩溃残留 .v4stage |
| T04 | 快照/还原（mock 路径/进程/代理/哈希计数）：manifest、缺 missing 追踪、半恢复、篡改拒绝、空快照 | 缺 absent；还原无启动；hashCalls=manifest 条目数；篡改在停进程前拒绝；半恢复 |
| T05 | state 在 settings 缺失/非法 JSON | exit 1、stdout 0、无 JSON |
| T06 | 基线 profiles 文本算法 7 类用例 + CRLF + 纪元 | case2/5 改到下一块；CRLF updated 不刷新；纪元 -28800s |
| T07 | Build-V4Profile/Runtime（strict/resilient/注入） | strict 无 DIRECT；resilient 有；注入产生 udp:true |
| T08 | 非原子 settings 写入的并发读者；Save 管道污染 | 1695/1699 IOException；Save 输出 True |
| T09 | evidence 不可写时 apply 启动；日志名碰撞；启动后写日志失败被吞 | apply exit 1；同秒同文件；写失败不抛 |
| T10 | dot-source 的 EAP 覆盖；throw 不受 -ErrorAction 影响 | Continue→Stop；SilentlyContinue 仍 throw |
| T11 | 零测试/失败/抛错退出码；-File 的 LASTEXITCODE；bench 静态解析 | 零测试 exit 0；失败/抛错 exit 1；无泄漏；13 场景；FT06 恒真 |
| T12 | V6 新代码：快照 manifest 命名、手工修正后的 restore（absent）、Update/Test profile、空锁/token | D-01 复现；B 通过；C 通过；空锁卡死；token 校验正确 |
| T13 | V6 插入路径的文本 | 两个 current、SUBX updated 丢失 |
| T14 | V6 state 缺 settings；guard 捕获 D-02 | exit 3 + 合法 JSON；guard=true、corrupted=2 |

隔离规则：

- 基线文件用 `git archive 36222c9 proxy_v4` 导出到 temp，逐字节执行；工作树用 05:02 快照（sha B188616A）。
- 所有 root 重定向到 temp；从不调用真实 apply/rollback/state（T05/T14 的 state 仅在 settings 缺失/非法时启动，Get-V4Settings 在任何网络/进程操作之前抛错）。
- HKCU/进程/网络以函数覆写隔离：Get-V4Paths、Get-V4AppPids、Stop/Start-V4Clash、Get/Set/Clear-V4SystemProxy、Get-V4Owner、Get-CimInstance、Get-FileHash；不触碰真实注册表、不启停真实进程。
- 未运行原 faultinject-v4.ps1（FT12 风险）；其行为只做语法解析与源码审查。
- 所有 canary 只存在于测试进程内存；报告中不出现秘密原文。

局限：T02 的“真实 apply”是源码副本 + 临时根；它证明的是基线代码的控制流与文件行为，不证明真实 appdata 上的结果。T04/T12 的进程/代理为 mock；A-06/A-13/A-14 的真实 HKCU 行为未执行。

## 8. 交接建议（按优先级）

1. **P0（发布阻塞）**：A-01、A-03、A-04/A-05、A-06、A-12、D-01、A-21。其中 D-01 是当前工作树的唯一“rollback 必然失败”缺陷，应先修并跑 T12-A/B 回归。
2. **P0 工程治理**：先把生产文件冻结，再开始 F01–F10 的失败测试；当前审计期间四个生产文件被并发修改，任何“已修/已验”声明都不可靠。
3. **P1**：A-07（已完成于 V6）、A-08（新增 journal）、A-02/D-03（空锁年龄兜底）、A-13/A-14（系统代理与 owner 完整性）、A-15（有序退出码）、A-16（已修，补回归）。
4. **P1 测试系统**：A-17/A-21——把 FT12 改为临时目录 Deny-ACL 用例；FT04/FT10 改跨进程；FT06 删除恒真；FT11/FT14 用注入模拟；零测试/跳过/证据失败必须非零；用 META-01..07 自验。
5. **P2**：A-09（dry-run 真只读）、A-10（日志失败降级、目录惰性创建）、A-11、A-18、A-19、A-20、A-22–A-26、D-02、D-04。
6. **证据要求**：每个修复必须配一条“先失败”的隔离用例；不得再用 FT04/FT06 这类恒真/同进程用例作为“并发已验证”的证据；不得以“13/13”作为通过依据。

## 9. 对既有文档/声明的核对

| 声明 | 核对 |
|---|---|
| TASK-STATE.md:16 “工作区干净（无未提交变更）” | 审计时点不成立：4 个生产文件被修改（§0）；proxy_v6 未跟踪。 |
| RELEASE-GATE.md:7 “并发测试通过 PASS（FT04/FT10）” | 不成立：FT04/FT10 是同进程二次 Enter，未覆盖跨进程；A-01 在该测试下不可见。 |
| REPORT-V4.md:18 “FT06 观测到 pids 状态” | FT06 的 pass 参数是字面 $true，恒真。 |
| REPORT-V4.md:35 “exit $(if...) 表达式取值问题” | 当前源码 tests:141 无该表达式；描述与源码不符，不能作为 V5-07 依据。 |
| CONFIG-INTEGRITY.md:13-14 “快照在修改前、应用已停止；还原前逐文件 SHA256” | 前半成立；但 stop 是未受 $applied 保护的第一个 dirty 动作（A-03）；缺失文件不追踪（A-04）；替换用 Copy-Item 而非原子替换（A-05）。 |
| CONFIG-INTEGRITY.md:12 “临时文件→校验→重命名” | 仅 Set-V4Atomic 成立；Restore 不走该路径。 |
| CONFIG-INTEGRITY.md:19 “运行时 marker 会消失，state 用链路签名” | 与源码一致（state:25-30）。 |

—— 报告结束 ——
