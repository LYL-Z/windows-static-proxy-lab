# AGENT-D 独立对抗性代码审查报告（proxy_v4 @ 36222c9）

| 项 | 内容 |
|---|---|
| 角色 | Agent D：独立对抗性代码审查（不采信既有报告/提交信息，只采信源码与可复现实验） |
| 冻结基线 | 36222c92c829a2ef08b71af2a3a3ff9a3c44b396（v5/short-run-hardening） |
| 被审对象 | proxy_v4/apply-v4.ps1（182 行）、rollback-v4.ps1（65）、state-v4.ps1（68）、lib/V4.ps1（542）、tests/faultinject-v4.ps1（141） |
| 基线 blob | apply 711b13b、rollback 96b690e、state 328dfc8、lib 74c436b、tests 87267b0 |
| 环境 | Windows PowerShell 5.1.26100.9818（Desktop），非提权 |
| 约束遵守 | 未运行真实 apply/rollback/state；未读写 HKCU、未启停 Clash、未改 appdata/注册表/网络/计划任务/凭据。所有执行均在 %TEMP%/d-review-v4 的独立副本中进行，副本由 git show 36222c9 生成。 |
| 报告日期 | 2026-11-18（America/Los_Angeles） |

> 重要（基线与工作树漂移）：审查开始时按基线提交读取源码；审查过程中另一执行者持续改写了工作树（当前未提交 blob：apply 819d5eb/158 行、lib 91a0d06/1209 行、state 3dbee94/61 行、rollback 64e50b1/67 行）。本报告所有行号均指 36222c9；工作树中已出现 token 锁、state 兜底、V4_TEST_MODE 隔离等方向性改动，但**未提交、未验证、仍在变化，不属于本报告结论**。最终代码必须用本报告的可证伪测试重新裁定。

## 0. 结论（先看这里）

1. **基线不可发布**。源码层成立 HIGH 7 项（D-01/D-03/D-04/D-05/D-06/D-16/D-17）与 MED-HIGH 2 项（D-02/D-07）。其中 D-01/D-03 已用隔离实验直接复现，D-04/D-05/D-06 为源码级确定结论（未在真实系统上执行 -Repair）；D-16/D-17 由测试台源码逐条核对得出。
2. **13/13 故障注入不能作为任何 Gate 证据**：13 个用例中至少 5 个是空转或假阳性（D-16），且有 1 个用例直接对系统 hosts 文件发起 ACL 改写（D-17）。
3. **仓库内的主要证据（apply 日志、fault-injection JSON、owner.json）产生于 03:47–03:49，早于被审代码的三个修复提交（04:28/04:36/04:40）**，且日志显示 mode=resilient，而基线默认已改为 strict。因此这些证据不能证明基线通过任何测试（§4.4）。
4. 既有主张中，「F01/F03/F05/F06 已关闭」「HIGH 缺陷全部关闭并有第三方复审」「核心配置事务完整」「CONFIG-INTEGRITY 不变量 1/3 成立」「不接受密码参数」「五态状态机」均**不支持**（§4）。

## 1. 基线、方法与证据链

### 1.1 方法
- 逐行通读 5 个基线文件；对 F08 的 profiles.yaml 逻辑、-Init 迁移正则、YAML 生成、脱敏函数做**逐字复刻**的单元实验（副本位于 %TEMP%/d-review-v4/cases）。
- 用 3 个真实子进程验证锁互斥（非同进程模拟）。
- 用桩函数（stub）覆盖状态机的全部分支，不触发网络/注册表/进程。
- 用 apply/rollback 的**真实脚本副本**验证未获锁/参数错误路径的退出码与锁副作用（在 settings 缺失或非法处提前失败，未进入 appdata 路径）。
- 对照 evidence/、README、RELEASE-GATE、REPORT、CONFIG-INTEGRITY、SECURITY-AUDIT 与源码逐条核对。

### 1.2 未做（如实声明）
- 未执行真实 apply/rollback/state；未验证真实 HKCU、appdata、Clash、网络、DPAPI 真实凭据。
- 未测试生命周期（重启/睡眠/Wi-Fi）、24h/72h、真实回滚往返。
- 未运行 mihomo 二进制（避免接触 Clash/appdata；因此 mihomo -t 在真实 appdata 上的副作用仍未证）。
- 未审查工作树中的 1209 行进行中重构。

### 1.3 已证事实（摘要）
- 3 进程锁：持有者 P1 仍存活时，未获锁的 P2 在 finally 中删除了 P1 的锁，P3 随即获得锁（附录 A1）。
- apply 在未获锁（exit 33）和参数错误（exit 11）两条路径上都删除了**别人持有**的锁；rollback 在同一场景保留锁（不一致）（A2）。
- settings.json 缺失时 state-v4 直接抛错、exit 1、无 JSON（A3）。
- F08：CRLF 文件不刷新；我方条目缺 updated 时改写下一订阅的 updated；相似 UID 时既不追加也改写他人 updated（A4）。
- YAML 生成未转义：密码含双引号即破坏标量；用户名含换行可注入同级键（A5）。
- -Init 迁移：缩进式/flow/引号 type/type 在前的 profile 均 0 候选；密码 p#ss 被截断为 p（A6）。
- Protect-V4Acl 早退：仅给当前用户 Read 的受保护 DACL 被判定为已保护（返回 True）（A8）。
- 锁陈旧判定：pid=4（System，存活但无关）3 秒不回收；死 pid 可回收（A9）。
- dot-source lib/V4.ps1 会把调用方 EAP 从 Continue 改成 Stop（A10）。

## 2. 发现清单

> 严重度定义：HIGH=可在正常路径上造成未恢复的错误状态/安全或数据损坏/发布证据失效；MED=特定但现实触发下错误或误导；LOW=健壮性/可维护性/文档。
> 每条给出 位置 / 触发 / 期望 / 证据 / 可证伪测试。位置均为 36222c9 的行号。

### D-01 HIGH｜锁所有权缺失：未获锁的进程删除持有者的锁，互斥被破坏
- 位置：apply-v4.ps1:70、182；lib/V4.ps1:152-178（Enter/Exit-V4Lock）。rollback-v4.ps1:33、59 对照。
- 触发：任何 apply 结束路径，包括参数冲突（31-33）、settings 缺失（69）、Fail 33（70）、-DryRun 早退（113）——这些路径都从未或未能获得锁，但 finally（182）无条件调用 Exit-V4Lock（178 直接 Remove-Item，无 token/pid 校验）。
- 期望：只有锁持有者能释放；未获锁的失败方不得删除锁文件；释放需 token 校验。
- 证据：
  - A2-T1：持锁者存在时执行 apply -Init -DryRun → exit 11，锁被删除。
  - A2-T2：持锁者存在时执行 apply（settings 存在）→ 21 秒后 exit 33，锁被删除。
  - A1：P2（未获锁）删除 P1 的锁后，P3 在 P1 仍持有（P1 存活）时获得锁 → 两个「管理者」同时进入临界区。
  - A2-T3：rollback 在同样场景 exit 40 且锁保留 → apply 与 rollback 语义不一致，说明这是实现缺陷而非设计。
- 可证伪测试（LOCK-01/LOCK-02）：进程 A Enter-V4Lock 并持有 12s；进程 B 执行一次 apply 的失败路径；进程 C 在 B 退出后 Enter-V4Lock -TimeoutSec 3。期望 C=false；实测 C=true（A1）。
- 影响：锁只提供「文件存在」提示，不提供互斥；并发 apply/rollback 可同时改写 profiles.yaml、clash-verge.yaml 与 HKCU。

### D-02 MED-HIGH｜陈旧锁判定可被 PID 复用卡死，且存在 ABA 删除竞态
- 位置：lib/V4.ps1:164-170。
- 触发：(a) 崩溃留下的锁，其 pid 被无关进程复用 → 每个等待者都看到「存活」，20s 后 exit 33，锁永久卡死，只能手工删除；(b) 两个等待者读到同一陈旧内容，A 先删除并新建锁，B 仍按旧判断执行 Remove-Item，删除 A 的新锁 → 两者先后进入临界区。
- 期望：锁内容含随机 token+进程启动时间，删除前重读并比对，或用句柄/命名 mutex 持有。
- 证据：A9：pid=4 的锁 3s 不回收；pid=999999 的锁立即回收。A1 的删除语义为该竞态提供了必要条件。
- 可证伪测试：写入 pid=4（存活无关进程）与 pid=999999 两种锁，断言前者被判定为不可回收并明确告警 / 后者回收；再注入 ABA 交错（B 在 A 删除并重建后执行删除），断言新锁存活。

### D-03 HIGH｜settings 缺失/非法时 state-v4 崩溃；UNKNOWN/RECOVERING 两个状态不可达
- 位置：lib/V4.ps1:506-522（508 Get-V4Settings；521-522 不可达分支）；state-v4.ps1:14（无顶层 catch）；lib 在 dot-source 时把 EAP 置为 Stop（lib:16）。
- 触发：settings.json 不存在、JSON 非法、DPAPI 无法解密（换用户/复制机器）。
- 期望：报告 UNKNOWN（exit 3）或结构化错误 JSON，不抛 PowerShell 栈；文档承诺的五态中包含 UNKNOWN/RECOVERING。
- 证据：
  - A3：Get-V4Settings -ErrorAction SilentlyContinue 仍 THREW；state-v4 -Json（无 settings）exit=1、无 JSON；settings 为非法 JSON 时 exit=1。
  - 桩状态机矩阵（A11）：可达状态仅 HEALTHY/DEGRADED/FAILED（mode RAW/NEXIP），RECOVERING 0 次、UNKNOWN 0 次。
  - A10：state-v4.ps1:11 的 Continue 被 lib 的 Stop 覆盖，顶层 throw 无法被「Continue」吞掉。
- 可证伪测试（PARAM-04/05、LIFE-04）：移除 settings.json 运行 state -Json，断言 exit ∈ {0,2,3} 且 stdout 为可解析 JSON；当前 exit=1 且无 JSON。另断言存在一个代码路径返回 RECOVERING/UNKNOWN。
- 备注：同一缺陷使 V6 TEST-MATRIX 的 PARAM-05（非法 settings → exit 11 不崩溃）与实现不符（apply 实际 exit 1，见 D-12）。

### D-04 HIGH｜快照阶段失败：应用已被停止，但既无退出码也无恢复
- 位置：apply-v4.ps1:116-118、176；lib/V4.ps1:235（快照函数内部先 Stop-V4Clash）、230-264。
- 触发：New-V4Snapshot 在 Stop-V4Clash 之后抛错（Copy-Item 失败、backup 目录不可写、ACL 失败、磁盘满）。
- 期望：恢复应用运行（或至少明确报告「应用已停止/网络中断」），退出码 40；不得以 exit 1 静默离开。
- 证据：快照路径变量 $snap 仅在 New-V4Snapshot 返回后赋值（apply:116），$applied 仍为 false；catch（176）的恢复条件 $applied -and $snap 两者皆不满足 → 不重启、不还原，exit=1。此时 HKCU 仍可能指向 127.0.0.1:<mixed-port>，机器断网。
- 可证伪测试（TX-01）：在隔离 appdata 中使 backup 目录不可写（或注入 Copy-Item 失败），运行 apply，断言 Clash 被重新拉起且 exit=40；当前不会。需要 V6 的 test-mode 注入能力，禁止在真实 appdata 上做。

### D-05 HIGH｜事务失败恢复只还原文件，不还原系统代理；恢复启动校验用错端口
- 位置：apply-v4.ps1:162-164、176-180；lib/V4.ps1:258、266-286、184、217、224。
- 触发：Set-V4SystemProxy（162）之后任一失败：系统代理验证失败（164 Fail 32）、Set-V4Owner 失败、Protect-V4Acl 抛错、日志异常；或链验证后仍失败。
- 期望：文件+进程+**注册表系统代理**一并回到快照状态；恢复启动必须用配置的 mixedPort 校验。
- 证据：
  - Restore-V4Snapshot（266-286）只复制文件并重启，从不读取/写回 manifest.systemProxy；manifest 记录了 systemProxy，但唯一消费者是 rollback。
  - apply 的恢复调用 Start-V4Clash -TimeoutSec 30（178），Start-V4Clash 的 Port 默认 7897（217）；New-V4Snapshot/Restore 的 Stop-V4Clash 同样默认 7897（184），而 mixedPort 可配置（apply:18）。
  - 结果：混合端口非 7897 时，恢复既不验证正确端口，也可能在旧配置未监听 7897 的情况下报告「恢复完成」；系统代理留在新值。
- 可证伪测试（TX-05）：注入 Set-V4Owner 失败，断言 HKCU 回到快照值且 Clash 在配置端口可监听；当前 HKCU 不回滚。
- 备注：D-04+D-05 合起来意味着「事务」在失败时最多恢复到「文件旧、代理新、应用可能未起」。

### D-06 HIGH｜-Repair 在脏标志之前写注册表，失败不可恢复
- 位置：apply-v4.ps1:82-93（$applied 从未置 true）。
- 触发：-Repair 在 Set-V4SystemProxy（88）之后失败：验证（90 Fail 32）、Set-V4Owner（91）、日志。
- 期望：写注册表前置脏标志并具备补偿；或 repair 自带回滚（恢复 prev）。
- 证据：catch（176）依赖 $applied -and $snap；repair 路径 $applied=false、$snap=null → 不恢复，exit 为 32/1，而 HKCU 已被改。
- 可证伪测试：在隔离 test-mode 下注入 Set-V4Owner 失败，运行 -Repair，断言系统代理恢复为 prev 或 exit=40；当前不恢复。

### D-07 MED-HIGH｜F08 残余：profiles.yaml 作用域仍会不改/错改，且无解析校验
- 位置：apply-v4.ps1:125-138。
- 触发与实测（逐字复刻，A4）：
  1. C1（CRLF 文件，我方条目存在）：updated 完全不刷新（1763000001 → 1763000001）。原因：正则 (?m)^(  updated:\s*)\S+$ 的 $ 在 .NET 中不匹配 CRLF 的 \r 之前（正则没有 \s* 吸收 \r）。
  2. C2（LF 文件，我方条目缺 updated，后面有别的订阅）：**把下一个订阅的 updated 改成当前纪元**（1763000000 → 1795006717），我方仍无 updated。
  3. C3（外来 uid 为 V4Mngd00010，前缀相同）：-notmatch 'uid:\s*V4Mngd0001' 误判「已存在」→ 不追加；IndexOf('uid: V4Mngd0001') 命中前缀 → 改写外来条目的 updated。
  4. C5：current 值带引号时被替换为无引号（归一化副作用）。
  5. 校验器只检查 ^current:\s*\S+（141），不验证 YAML 结构；改写后没有 mihomo -t。
- 期望：把 profiles.yaml 当作结构解析（items 列表）或严格块边界（含终止条件）+ 必须命中我方块，否则拒绝写入；只允许目标字节变化；写入前做 YAML 解析校验。
- 可证伪测试（DATA-02 七类）：对 C1/C2/C3/C4/C5 各跑一次，断言 (a) 我方 updated 每次刷新；(b) 除我方块外所有行 byte-identical；(c) 任何不确定情形 exit≠0 且文件不变。当前 C1 不刷新、C2/C3 损坏他人数据。
- 备注：36222c9 提交信息称「Independently tested: two foreign items keep 111111/333333 while ours becomes 999999」，只覆盖了 C4 式 happy path；(?m)+CRLF 与「缺 updated」两种现实输入未覆盖。

### D-08 MED｜生成的 YAML 未做任何转义，凭据可破坏配置或注入键
- 位置：lib/V4.ps1:443-444（username/password）、472（secret）、475（pipe）。
- 触发：settings 中的用户名/密码（来自迁移或显式参数）含双引号、反斜杠、换行、#；app 的 secret 含空格/冒号。
- 期望：按 YAML 规范转义/引用；或先构造对象再序列化；仅靠 mihomo -t 语法校验不足以证明语义正确。
- 证据（A5，合成值）：
  - 密码 AAA"BBB → 生成 password: "AAA"BBB"（标量提前闭合，配置语义错误或 -t 失败）。
  - 用户名 x"+换行+四个空格 udp: true+换行+dialer-proxy: "DIRECT → 生成第 20-22 行多出 udp: true / dialer-proxy: "DIRECT"，随后模板自身的 udp: false / dialer-proxy: "STAR-FIRSTHOP"（24-25）重复。任何不重复键的注入（如 tls/sni）将保持 YAML 合法。
  - 证据日志 03:47:41 的首次 -Init 就在 mihomo -t 上失败（exit 1，「unexpected」），原因未记录，与凭据特殊字符/转义不足相符（不能据此定因，但说明该路径在真实凭据上曾经失败）。
- 可证伪测试：用双引号、反斜杠、换行、#、空格组合生成 profile/runtime，断言 mihomo -t 通过**且**解析回来的凭据与输入逐字节相等；当前第一步就失败或第二步不等。

### D-09 MED｜-Init 迁移用正则解析 YAML：常见布局 0 候选，密码在 # 处被静默截断
- 位置：apply-v4.ps1:47-56。
- 触发：订阅/运行时 profile 的 proxies 列表为缩进式（两个空格 + - name:）、flow 式（- {name: ...}）、type: "socks5" 带引号、type 在 name 之前；或密码含 #。
- 期望：要么用可靠的 YAML 读取，要么在任何不确定时失败并给出可操作错误；绝不允许「静默存错凭据」。
- 证据（A6）：A 缩进=0 候选；C 引号 type=0；D flow=0；E type 在前=0；B 非缩进=1 但 password: p#ss 被捕获为 p（提取正则 [^\r\n#]+ 在 # 处截断，YAML 里 # 在非空白后并不是注释）。
- 可证伪测试：上述 5 类样例 + 密码含 #/空格的样例；断言「要么 exit 11 并说明原因，要么存盘凭据与源逐字节相等」。当前 B 静默截断。
- 备注：与 README/REPORT 的「M5/M6 彻底不再解析 YAML」直接矛盾；CONFIG-INTEGRITY 也自认 profiles.yaml 仍用文本修改。

### D-10 MED｜Protect-V4Acl 早退接受弱 DACL；调用方忽略失败
- 位置：lib/V4.ps1:125-149（133 早退；137-144 只校验「我」存在）；调用点：lib:120、262，apply:166-167。
- 触发：目录/文件已是「受保护 DACL」但只有当前用户 Read，或缺少 SYSTEM/Administrators，或含 Everyone 等弱规则。
- 期望：幂等判断必须验证「当前用户 FullControl + SYSTEM + Administrators」，否则修复；失败必须告警/失败，不能静默。
- 证据（A8）：构造仅当前用户 Read 的受保护 DACL → Protect-V4Acl 返回 True，DACL 未改变；SECURITY-AUDIT 却声称「仅当前用户/系统/管理员」（DATA-05 也这样要求）。
- 可证伪测试（SEC-02/DATA-05）：构造 4 类 DACL（仅 Read、含 Everyone、缺 SYSTEM、正确），断言返回值与最终 ACE 集符合预期；当前第 1 类误报成功。

### D-11 MED｜日志失败阻断恢复；恢复失败分支的日志未受保护
- 位置：lib/V4.ps1:53-59（Start-V4Log 无 try）、apply:22、rollback:13、apply:179。
- 触发：evidence 目录不可写/被同名文件占用/磁盘满 → Start-V4Log 在 try 之外抛出，apply/rollback 完全不能启动（连 DryRun 也不行）；恢复区块中 179 行的 restore failed 日志若抛错，则 $exit=40 不会写入，恢复失败被静默并保留旧退出码。
- 期望：日志是尽力而为；恢复链中的任何日志失败不得阻断恢复或吞掉 40。
- 证据（A12）：evidence 被替换为文件时 apply -DryRun exit=1，未做任何校验。
- 可证伪测试（LOG-01/03/04）：日志目标不可写时 apply/rollback 仍应执行并给出正确退出码；当前直接 exit 1。

### D-12 MED｜退出码契约不成体系，且默认值/文档互相矛盾
- 位置：apply:8-9（文档码）、27（Fail）、14（Mode 默认 strict）、6（注释称 resilient 默认）、74/96/124/141（Fail 10，共 4 种语义）、lib:500（默认 secret）。
- 触发/证据：
  - settings 结构非法 → exit 1（T6，A13），文档写 11；PARAM-05 期望 11。
  - Fail 10（clash 路径/控制器/profiles.yaml）未在文档出现。
  - 参数默认 -Mode strict，但文件头注释写 resilient、owner.json 与 03:48 证据日志都是 mode=resilient → 证据与基线不是同一构建。
  - Fail 32 消息拼接 $px.server（未启用时为 null），日志可读性差。
- 期望：单一退出码表（含 1/10 与 settings 错误），参数默认与文档/证据一致；每个码有负向测试。
- 可证伪测试：为 0/1/10/11/20/30/31/32/33/40 各写一条用例并断言；当前至少 1（settings 非法）与 11（文档）不符。

### D-13 MED｜事务顺序：先切 current 再写 profile，且无 journal/崩溃恢复
- 位置：apply:138-146。
- 触发：进程被杀/断电发生在写 profiles.yaml（141）之后、写 profiles/v4-managed.yaml（145）之前。
- 后果：profiles.yaml 的 current 指向 V4-Mngd，但 profile 文件不存在或为旧内容；HKCU 可能已指向 7897；下次启动无自动检测/回滚，state 只会报 FAILED/DEGRADED。
- 期望：先落 profile 文件、再切 current；写入前记录 journal（阶段、快照目录、目标哈希），下次 apply/启动时能检测半事务并恢复；或在下一步失败时明确披露「需手工回滚」。
- 可证伪测试：在 141 与 145 之间注入进程自杀（test-mode），重启后断言自动恢复或明确恢复指引；当前两者皆无。补 TX-02/03/04 覆盖。

### D-14 MED｜state 的「哈希完整性」只展示不校验
- 位置：state-v4.ps1:15、21、23；V4.ps1:536。
- 触发：profile 被订阅/应用/人工改写。
- 期望：记录 apply 时的哈希（受 ACL 保护）并在 state 中比对；marker 只是可复制的注释，不能作为完整性依据。
- 证据：profileHash 只截断显示，无期望值；markerOk 只判断前缀；runtime 用链路签名（已声明）。LIFE-08 无法被现有实现检出。
- 可证伪测试：篡改 profile 但保留 marker/哈希显示不变，断言 state DEGRADED；当前 HEALTHY（只要链正常）。

### D-15 MED｜健康判据过严且仅支持 IPv4
- 位置：lib:536（exitViaChain -eq host）、apply:159、lib:360（IPv4 正则）。
- 触发：供应商出口 IP 不等于入口服务器 IP（网关/多出口/轮换），或出口为 IPv6。
- 后果：正常链路被判 DEGRADED；apply 以 exit 31 拒绝安装；IPv6 出口直接 FAILED。
- 证据：A11-E（stub 出口不同 → DEGRADED）；A11-F（无 IPv4 出口 → FAILED）。
- 期望：把「期望出口」做成可配置项/允许列表，文档明示；至少区分「链路可用」与「出口等于入口」。
- 可证伪测试：stub 一个可用但出口不同的链路，断言 state 不误报 DEGRADED 或文档明确该限制并有测试。

### D-16 HIGH｜故障注入台大量空转/假阳性，「13/13」无证明力
- 位置：tests/faultinject-v4.ps1:65-96、106-110、133-141。
- 逐条：
  - FT05（65-70）：测试自己实现了一个等待循环，**没有调用 Start-V4Clash**；与被测实现无关。
  - FT06（72-76）：断言值硬编码 true，actual 为 pids=N，永远 PASS。
  - FT08（84-89）：不注入任何依赖故障，只跑真实 state 并断言 [bool] 状态；在健康机器上 PASS，在干净检出（无 settings）上 ERROR/FAIL。
  - FT09（91-96）：名为「user stops manager」，但没有停止任何进程；断言 state 属于集合；证据实际=HEALTHY，与场景名矛盾。
  - FT04/FT10（57-63、98-104）：同进程两次 Enter-V4Lock，不是并发；若生产锁已被真实操作持有则两条都「通过」（空转）。
  - FT01（28-33）：Test-V4MihomoConfig 在 core 缺失时抛 mihomo core not found，catch 同样记为 REJECTED（A14）→ 与配置是否正确无关。
  - FT12（106-110）：对系统 hosts 调 Protect-V4Acl；返回 false 也可能只是路径不存在/权限不足；且不验证调用方如何处理 false。
  - 汇总（133-141）：passed -eq total 在 0 个用例时也 exit 0；没有期望用例数；evidence 不记录 exit code、不绑定 commit/blob/命令行。
  - 覆盖缺口：**整个测试台从未调用 apply-v4.ps1 或 rollback-v4.ps1**（grep 仅 state-v4 两次）；因此退出码、事务回滚、锁竞争、系统代理、快照成功路径全部未测。
- 期望：每个场景必须对被测函数注入/打桩并断言具体结果；跨进程；固定用例数、零测试即失败；证据含 commit+退出码。
- 可证伪测试（META-02/04）：删除任一场景后套件仍应失败；注入真实第二个进程；把 FT01 的 core 置空后应 FAIL 而不是 PASS。

### D-17 HIGH｜测试台不隔离且触及系统对象（安全性）
- 位置：tests:5-6（声称 isolated/read-only）、12、22、108；lib:28-30。
- 事实：
  - dot-source lib 即创建/使用真实 proxy_v4/config、backup 目录；FT04/FT10 在真实 config/.lock 上取/放锁（并发真实操作时阻塞 5s 或以空转方式 PASS）。
  - FT08/FT09 运行真实 state-v4.ps1：有 settings 时会读 HKCU、经 socks5 走 curl 外网（网络副作用），并依赖机器状态。
  - FT12 对 C:/Windows/System32/drivers/etc/hosts 调用 Protect-V4Acl：函数会 Remove 所有 ACE、加当前用户 FullControl 并 Set-Acl；非提权通常失败，但**在提权/具备 WRITE_DAC 时会真实改写 hosts DACL 且不恢复**。这违反任务书「不改系统」的约束，也与脚本头部「only production contact is read-only」矛盾。
  - 发布树中 config/settings.json 已被移除，因此从干净检出运行该套件 FT08/FT09 必然 ERROR，13/13 无法复现。
- 期望：临时 root + 危险函数（HKCU/Start-Process/Stop-Process/系统路径）在测试模式拒绝；绝不把系统文件当测试目标。
- 可证伪测试：运行前后对比 git status 与 hosts 文件哈希/ACL，断言零变化；当前会新增 backup/ 目录并依赖真实环境。

### D-18 MED｜凭据处理：命令行密码、非原子写入、无 schema 校验
- 位置：apply:17（-StaticPass）、lib:110-122（Save-V4Settings）、lib:96-108。
- 事实：
  - -StaticPass 使密码进入进程命令行（其他同用户进程可读 Win32_Process.CommandLine，本项目自己就这么读）与 PSReadLine 历史；SECURITY-AUDIT 却写「不接受密码参数」，只在括注里承认「迁移时可显式传入」，属于自我矛盾。
  - settings.json 用 WriteAllText 直接覆盖，随后才 Protect-V4Acl：崩溃窗口内是弱 ACL/可截断；无备份、无 schema 校验（T6 的非法结构 → exit 1）。
- 期望：删除密码命令行参数（stdin/SecureString）；tmp+rename+ACL；校验字段并给出 11。
- 可证伪测试（SEC-01/02）：命令行含密码的用例应被拒绝或明确告警；并发/中断写入后 settings 仍可解析。

### D-19 LOW｜脱敏不完整
- 位置：lib:35-42。
- 事实（A7，合成值）：password: "AA BB CC" → "***" BB CC"（泄漏后半段并残留引号）；password: "ABCD" → "***""；少于 4 字符的秘密不注册；Bearer token 不脱敏。FT15 只覆盖「4+ 字面量 + Basic」。
- 期望：结构化脱敏（YAML 值解析/全字段替换），并对文档声明的每一类做测试。
- 可证伪测试（SEC-03）：用含空格/短值/Bearer/代理 URL 的样本跑日志与异常输出，断言输出不含任何秘密片段。

### D-20 LOW｜死代码/不可达分支/未使用字段
- lib:186 if ($pids.Count -eq 0 -and -not (Test-Path 'HKLM:/')) 空语句；lib:507 $p = Get-V4Paths 未使用；lib:258 clashRunning=false 写入但 rollback 从不读取；lib:513/521 UNKNOWN 不可达；state 的 RECOVERING 不可达；apply:147 重复 $applied=true；lib:350-363 无代理分支从未被调用；rollback 从不读 manifest.clashRunning。
- 期望：删除或实现；文档不要承诺不存在的状态/字段。
- 可证伪测试：分支覆盖（本报告 A11）与静态 grep。

### D-21 LOW｜Start-V4Clash 不区分「已有监听」与「自己启动成功」
- 位置：lib:216-227（224 只看端口）。
- 触发：端口已被其他程序占用，或应用已在运行；重复 Start-Process 产生第二实例；返回 true 不代表配置已生效。
- 期望：先判断进程/端口归属，记录启动 pid；失败时给出具体原因。
- 可证伪测试（LIFE-05）：占用 7897 后调用，断言不返回 true 或明确报告「端口被他人占用」。

### D-22 LOW｜manifest 语义与回滚副作用
- 位置：lib:235、258；rollback:47。
- 事实：systemProxy 在停应用**之后**读取（若应用退出时清理代理，快照会记为 off）；clashRunning 恒 false；rollback 总是 Start-V4Clash（47），即使用户原本没运行也会被拉起。回滚会改变用户状态。
- 期望：停止前采集状态，恢复原运行状态。
- 可证伪测试（TX-11/LIFE-07）：应用原本未运行时执行 rollback，断言不启动应用。

### D-23 LOW｜明文凭据的临时/备份副本
- 位置：lib:292-300（.v4stage-*.yaml、target.rand.bak 在 appdata 同目录创建）、lib:250-262（快照复制 profiles 后才 Protect-V4Acl）、apply:166-167（ACL 在写入之后）。
- 触发：进程在 Set-V4Atomic 中途被杀 → 残留含 password/secret 的临时文件；ACL 保护尚未施加。
- 期望：以受限 ACL 创建临时文件；失败/崩溃后用启动清扫清理。
- 可证伪测试：在写入阶段杀进程，扫描 appdata 的 .v4stage-*/.bak 是否存在且 ACL 是否受限；当前未验证。

### D-24 LOW｜rollback 二次失败与错误码覆盖
- 位置：rollback:36-57、61-64。
- 触发：恢复中途失败（partial restore）、后续 Set-V4Owner 抛错；或先置 41 后再抛错。
- 事实：catch 统一置 40，可能覆盖更具体的 41（44/54）；Start-V4Clash 失败只 WARN，退出码可能仍为 0；部分恢复没有逐文件报告；rollback:37 的 files restored and hash-verified 只验证了快照源，未验证落地文件。
- 期望：记录每步结果、保留最具体的码、失败项可诊断（TX-08/LOG-06）。
- 可证伪测试：注入第 2 个文件复制失败，断言退出码与已恢复清单；当前只有 exit 40。

### D-25 LOW｜Set-V4Atomic 在恢复失败时仍删除唯一备份
- 位置：lib:289-311（298 备份、299 Move、305-308 回拷 + 删除）。
- 触发：Move 之后某步失败且回拷失败（目标被占用）→ Copy-Item -ErrorAction SilentlyContinue 吞错，随后无条件删除 .bak → 旧内容丢失且无诊断。
- 期望：回拷后校验，失败保留备份并上抛。
- 备注：按源码顺序，FT03 的失败点更可能是备份 Copy-Item（目标以 FileShare.None 打开，Copy-Item 读取失败），而非 Move；该用例未实跑证实，也未覆盖「Move 后失败」的路径。

## 3. 测试台逐用例裁定

| 用例 | 声称覆盖 | 实际 | 裁定 |
|---|---|---|---|
| FT01 | 损坏配置被拒 | core 缺失也 REJECTED；core 存在时用真实 appdata 作 -d 跑 mihomo | 假阳性风险，未证 apply 的写前校验 |
| FT02 | 哈希不符拒绝 | 真（仅快照预校验） | 有效但窄 |
| FT03 | 占用文件拒写 + 完好 | 按源码顺序失败点更可能是备份 Copy-Item，不是 Move（未实跑） | 部分有效，机制未被证实 |
| FT04 | 第二个管理者被锁拒 | 同进程；无并发；生产锁路径 | 无效（D-01/D-16） |
| FT05 | 启动超时路径 | 自写等待循环，未调用 Start-V4Clash | 空转 |
| FT06 | 退出验证可观测 | 硬编码 true | 空转 |
| FT07 | 第一跳不可用检出 | 真 | 有效但仅 helper |
| FT08 | 依赖故障后 state 存活 | 无故障注入；跑真实 state；断言 bool | 环境相关/空转 |
| FT09 | 用户停管理者 | 未停进程；actual=HEALTHY | 与名称矛盾 |
| FT10 | 刷新/更新串行化 | 同 FT04 | 无效 |
| FT12 | ACL 失败返回 false | 目标为系统 hosts；false 可因路径不存在；不测调用方 | 危险且无效 |
| FT13 | 不完整快照拒绝 | 真 | 有效但窄 |
| FT15 | 秘密 + Basic 脱敏 | 窄（4+ 字面量 + Basic） | 部分有效 |

汇总语义：if ($passed -eq $total) exit 0（141）没有期望用例数，0 个用例也 exit 0；evidence JSON 不含退出码、命令、commit/blob，无法把「13/13」绑定到任何构建。

## 4. 对既有主张的裁定

### 4.1 任务书 F01–F10
| 主张 | 裁定 | 依据 |
|---|---|---|
| F01 Repair+DryRun 未互斥，DryRun 可改真实代理 | **不成立** | apply:31-33 在所有动作前互斥；A15 三种组合均 exit 11，仅产生 3 个 evidence 日志（无 settings/config 写入） |
| F02 事务标志晚于首次正式写入 | **不成立（针对 140 行）**；但 repair（D-06）与「快照前已停应用」（D-04）仍未置标志 | apply:140 在 141 之前置 true |
| F03 锁在恢复前释放 | **不成立**（顺序正确：catch 先于 finally）；真实缺陷是 D-01 的所有权 | apply:172-182；rollback:59 |
| F04 updated 未每次刷新 | **成立**（新机理：CRLF 锚点，A4-C1） | apply:132-137 |
| F05 13/13 但 exit 1 | **不成立**（基线 exit 0；REPORT 的说法已过期）；但 13/13 无证明力（D-16） | tests:141 |
| F06 strict 组仍含 DIRECT | **不成立**（strict 仅 US-WA-SOCKS5；DIRECT 仅在 resilient） | lib:415-421 |
| F07 事务边界不完整 | **部分成立**（D-04/D-05/D-06/D-13） | — |
| F08 updated 未真正限定目标块 | **部分成立且仍可损坏他人数据**（A4-C2/C3） | apply:125-138 |
| F09 -Init 先于锁写 settings | **成立**（apply:36-67 先于 70；且 A2-T1 证明未获锁也删锁） | — |
| F10 日志可阻断恢复 | **部分成立**（Start-V4Log 阻断整个脚本；catch 内 179 行未保护） | D-11 |

### 4.2 V6 ISSUE-LEDGER 的 S01–S12
- S01 锁所有权：**确认**（D-01，有运行证据；比 SUSPECTED 更强）。
- S02 快照失败后不重启：**确认**（D-04，源码级）。
- S03 不记录「文件原本不存在」：**确认**（rollback 不删除 apply 新建的 v4-managed.yaml；manifest 无存在性字段）。
- S04 不还原系统代理：**确认**（D-05）。
- S05 ACL 早退：**确认**（D-10，有实验）。
- S06 state 抛错：**确认**（D-03，exit 1 实测）。
- S07 V4.ps1 加载即建目录 / Start-V4Log 阻断：**确认**（D-17/D-11，A12）。
- S08 Set-V4Atomic 回拷吞错：**部分确认**（D-25；成功路径的临时文件清理正常）。
- S09 Start-V4Clash 不查已有监听：**确认**（D-21）。
- S10 PID 复用/无 token：**确认**（D-02，A9）。
- S11 Save-V4Settings 非原子+ACL 窗口：**确认**（D-18）。
- S12 日志文件名秒级：**确认**（lib:57；同秒并发混写，LOW）。

### 4.3 文档主张
| 文档主张 | 裁定 | 依据 |
|---|---|---|
| README：PASS on config integrity, concurrency, fault injection (13/13), credential redaction | **不支持** | 无并发测试（D-01/D-16）；F08 损坏他项（D-07）；脱敏不全（D-19）；测试台空转（D-16） |
| RELEASE-GATE：HIGH 缺陷全部关闭…第三方复审确认 | **不支持** | 仓库内唯一 REVIEW 文件是 proxy_v3/INDEPENDENT-REVIEW.md（V3 范围），无 V4 复审产物；且 D-01/03/04/05/06 为 HIGH |
| RELEASE-GATE：核心配置事务完整 PASS | **不支持** | D-04/D-05/D-13 |
| RELEASE-GATE：无秘密进入普通日志…扫描 0 明文 PASS | **无证据/不成立** | 仓库无扫描产物；A7 显示脱敏可泄漏 |
| CONFIG-INTEGRITY 不变量 1「任何写入前必须 mihomo -t」 | **不成立** | profiles.yaml（141）只过正则；settings.json/owner.json 也不过 |
| CONFIG-INTEGRITY 不变量 3「快照在任何修改之前」 | **不成立** | -Init 写 settings（38/63）在快照前；日志/锁亦是写 |
| CONFIG-INTEGRITY 不变量 5「marker 丢失即 DEGRADED」 | **部分成立** | 仅在 state=HEALTHY 时降级；且 marker 可伪造（D-14） |
| SECURITY-AUDIT：命令行参数不接受密码参数 | **不成立** | apply:17 -StaticPass |
| state-v4 头：five-state / 0 HEALTHY/RECOVERING | **不成立** | RECOVERING/UNKNOWN 不可达（D-03/A11） |
| REPORT-V4：故障注入台 13/13 仍 exit 1，未修 | **与源码相反** | tests:141 全通过时 exit 0；报告未更新 |
| CHANGELOG：关闭 M5/M6（不再解析 YAML） | **不成立** | 迁移正则（D-09）与 profiles.yaml 文本改写（D-07） |
| REPORT-V4 §2 apply → chain verified / state HEALTHY / 13/13 | **不能作为基线证据** | 证据时间 03:47-03:49 早于基线提交 04:40；mode=resilient 而基线默认 strict；无 commit/blob 绑定 |
| BOOT-LIFECYCLE：state 能检测 resilient 回落 | **部分成立** | 桩测试 E 可检出出口不同；但 settings 缺失时 state 直接崩溃 |

### 4.4 证据链问题（独立于代码缺陷）
- evidence/apply-20261118-034741.log（首次 -Init）在迁移成功后 mihomo -t 失败，退出码未知（报告为 unexpected → 1），下一条 DryRun 同样失败；原因未记录。**唯一一次 -Init 证据是失败的**，而 REPORT 未提及。
- owner.json 的 note=mode=resilient、pid=26872，与基线默认 strict 不一致。
- fault-injection-v4.json 无退出码、无命令行、无 commit/blob/时间与代码版本的绑定；FT08/FT09 的 actual=HEALTHY。
- baseline.json 的 5 个文件哈希无法复核（文件已从发布树移除）。

## 5. 未覆盖与残余风险
- 生命周期（重启/睡眠/Wi-Fi）、24h/72h、真实回滚往返、凭据轮换：未测（与 V4 文档一致）。
- mihomo -t 在真实 appdata 上的副作用（cache/db）未证；apply 与 FT01 都以真实 appdata 作 -d。
- DPAPI：用假凭据在临时 root 验证了「生成→解密」往返可用；未验证换用户/换机器、settings 被复制后的行为（预期 throw → exit 1，见 D-03/D-12）。
- 工作树中的 V6 重构（1209 行 lib）未审查；其中已出现 token 锁（Exit-V4Lock 接受 lock 对象）、state try/catch、V4_TEST_MODE 根目录隔离等方向性改动，与本报告 D-01/D-03/D-17 方向一致，但**未验证、未提交、仍在变化**，不得据此关闭任何缺陷。

## 6. 建议的关闭/验收条件
1. 先修 D-01/D-02/D-03/D-04/D-05/D-06（事务与锁的半成品状态是发布阻塞）。
2. 修 D-07/D-09/D-10/D-11/D-17 并删/隔离 -StaticPass（D-18）。
3. 重建测试台：跨进程锁、apply/rollback 全退出码、注入式写失败/恢复失败/日志失败、零测试失败、固定用例数、隔离 root、禁止系统路径（hosts/注册表/真实 appdata）。
4. 证据规范：每条证据含 commit、文件 blob、命令行、退出码、时间；禁止沿用 03:47-03:49 的旧证据。
5. 文档与源码对齐：五态、退出码、不变量、SECURITY-AUDIT 参数、REPORT 的 exit 1 说法、CONFIG-INTEGRITY 的「任何写入前 mihomo -t」。
6. 最终代码冻结后，用本报告附录 B 的隔离用例重跑 D-01/D-03/D-07 的可证伪测试。

## 附录 A：关键实验输出（已脱敏）

A1 三进程锁（临时 root）：P1 acquired=True（pid=P1，04:56:04）；P2 acquired=False（锁存在→清理→不存在）；P3 在 P1 仍运行（HasExited=False）时 acquired=True。
A2 apply/rollback 锁副作用：apply -Init -DryRun exit=11，锁被删；apply（settings 存在）exit=33（21s），锁被删；rollback 持锁场景 exit=40，锁保留。
A3 state：Get-V4Settings -ErrorAction SilentlyContinue → THREW；state -Json 无 settings → exit=1、stderr 有栈、无 JSON；非法 JSON → exit=1。
A4 F08：C1 updated 不刷新；C2 他人 updated 1763000000→1795006717；C3 他人 updated 被改写且未追加；C4 正常；C5 引号被去掉。
A5 YAML：password: "AAA"BBB"；注入后 20-25 行为 username/udp/dialer-proxy 交错。
A6 迁移：缩进 0、引号 0、flow 0、type 在前 0、非缩进 1（密码 p#ss→p）。
A7 脱敏：password: "AA BB CC"→"***" BB CC"；"ABCD"→"***""；Basic 已脱敏；Bearer 未脱敏；3 字符秘密未脱敏。
A8 ACL：返回 True；最终 ACE 仅当前用户 Read。
A9 锁陈旧：pid=4 3s 不回收；pid=999999 立即回收。
A10 EAP：dot-source 前 Continue → 后 Stop。
A11 状态机桩：A app 未运行→FAILED/RAW；B 端口关→FAILED；C 代理他人→DEGRADED；D 第一跳断→DEGRADED；E 出口≠入口→DEGRADED；F 无出口→FAILED；G 全好→HEALTHY；RECOVERING/UNKNOWN 各 0。
A12 日志：evidence 为文件 → apply -DryRun exit=1（Add-Content 失败）。
A13 settings：{"schema":1} → exit=1，unexpected: Cannot bind argument。
A14 core 缺失：Test-V4MihomoConfig 抛 mihomo core not found（FT01 仍记 REJECTED）。
A15 参数互斥：-Repair -DryRun / -Init -Repair / -Init -DryRun 均 exit=11；仅新增 3 个 evidence 日志。

## 附录 B：复现方法（不外泄、不触碰生产）
- 副本：git show 36222c9:proxy_v4/... → %TEMP%/d-review-v4/proxy_v4/（lib、apply、rollback、state、tests）。
- 锁用例：三个子进程分别 dot-source 临时 lib，按 A1 时序执行；或直接用 apply 的失败路径（A2）。
- F08：逐字复刻 apply:125-138 的脚本，喂 C1-C5 输入，比较除目标块外的行。
- 状态机：dot-source 临时 lib 后覆盖 Get-V4Paths/Get-V4AppPids/Test-V4Port/Get-V4SystemProxy/Test-V4FirstHop/Get-V4ExitIp/Get-V4Owner，喂 A11 的 7 组输入。
- 所有用例脚本位于 %TEMP%/d-review-v4/cases（仓库外），未修改生产文件。

---
审查者签名：Agent D（独立代码审查）。本报告只写 proxy_v6/reviews/AGENT-D-CODE-REVIEW.md，未修改任何生产文件；工作树中其它未提交改动来自并行执行者，与本报告无关。
