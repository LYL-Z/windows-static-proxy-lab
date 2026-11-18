# ISSUE-LEDGER — V6.0

最后更新：2026-11-18T04:55:00-08:00
状态图例：OPEN / SUSPECTED / FIXED-PENDING-TEST / VERIFIED-CLOSED / BLOCKED-USER / DEFERRED-BY-USER

## A. 任务书要求重新裁定的 F01–F10

| 编号 | 严重度 | 问题（任务书口径） | 源码位置 | V6 初始裁定 | 证据 |
|---|---|---|---|---|---|
| F01 | HIGH | `-Repair` 与 `-DryRun` 未互斥，DryRun 可改真实系统代理 | apply-v4.ps1:31 | UNVERIFIED（源码有互斥，需行为测试） | — |
| F02 | HIGH | 事务标志晚于首次写入 | apply-v4.ps1:140 | UNVERIFIED / 任务书称仍 PARTIAL | — |
| F03 | HIGH | 锁在恢复前释放，可能暴露半恢复状态 | apply-v4.ps1:170 | UNVERIFIED（另有“失败获取锁仍删除他人锁”疑似缺陷） | — |
| F04 | MED | 托管 profile 的 updated 未每次刷新 | apply-v4.ps1:129-137 | UNVERIFIED | — |
| F05 | MED | 测试台 13/13 但退出码 1 | tests/faultinject-v4.ps1:141 | UNVERIFIED（V5-07 仍 OPEN） | — |
| F06 | MED | strict 组仍含 DIRECT | lib/V4.ps1:415-421 | UNVERIFIED（源码仅含 US-WA-SOCKS5） | — |
| F07 | HIGH | 事务边界：首次写失败/中途失败/快照失败/回滚再失败未证明 | apply-v4.ps1:140-147,176-180 | PARTIAL（任务书裁定）；需负向测试 | — |
| F08 | MED-HIGH | updated 正则未真正限定目标 Profile 块；目标无 updated 时会改到下一个 Profile | apply-v4.ps1:132-137 | PARTIAL；源码仍存在此路径 | — |
| F09 | HIGH | `-Init` 在取得互斥锁之前写 settings | apply-v4.ps1:36-70 | PARTIAL；源码顺序仍为 Init→Lock | — |
| F10 | HIGH | 异常处理起始处/回滚失败后的日志仍可能阻断恢复 | apply-v4.ps1:174-180 | PARTIAL；恢复链仍有未保护日志与二次失败 | — |

## B. V6 新发现/疑似缺陷（待失败测试证实后才可关闭）

| 编号 | 严重度 | 疑似问题 | 位置 | 状态 |
|---|---|---|---|---|
| V6-S01 | HIGH | 未获取锁的进程在 finally 中无条件 `Exit-V4Lock`，会删除锁持有者的锁 | apply-v4.ps1:70,182; rollback-v4.ps1:33,59 | SUSPECTED |
| V6-S02 | HIGH | 快照阶段失败时 `$snap` 为空且 `$applied` 为假，应用已被停止却不会重启 | apply-v4.ps1:116-118,176 | SUSPECTED |
| V6-S03 | HIGH | 快照不记录“文件原本不存在”，回滚不会删除新生成的 v4-managed.yaml | lib/V4.ps1:230-286 | SUSPECTED |
| V6-S04 | HIGH | 事务失败恢复只还原文件/进程，不还原系统代理 | apply-v4.ps1:176-180; lib/V4.ps1:326-340 | SUSPECTED |
| V6-S05 | MED | `Protect-V4Acl` 早退只检查“含我”，不检查是否存在 Everyone/Users 等弱规则 | lib/V4.ps1:133 | SUSPECTED |
| V6-S06 | HIGH | settings.json 非法时 `Get-V4State` 直接抛错，state 脚本无顶层兜底 | lib/V4.ps1:508; state-v4.ps1:14 | SUSPECTED |
| V6-S07 | MED | V4.ps1 加载即创建 config/backup；Start-V4Log 失败会阻断整个脚本（含 DryRun） | lib/V4.ps1:28-30,58 | SUSPECTED |
| V6-S08 | MED | `Set-V4Atomic` 失败回滚用 `Copy-Item -ErrorAction SilentlyContinue`，备份失败被吞；临时文件/ACL 语义未证 | lib/V4.ps1:289-311 | SUSPECTED |
| V6-S09 | MED | `Start-V4Clash` 不检测“已在监听”，重复启动实例 | lib/V4.ps1:216-227 | SUSPECTED |
| V6-S10 | MED | 锁内容可被 PID 复用误判；无 token 校验 | lib/V4.ps1:152-178 | SUSPECTED |
| V6-S11 | MED | `Save-V4Settings` 非原子、先写后加 ACL，存在弱 ACL 窗口 | lib/V4.ps1:110-122 | SUSPECTED |
| V6-S12 | LOW | 日志文件名仅秒级时间戳，并发/同秒运行会混写 | lib/V4.ps1:53-59 | SUSPECTED |

## C. 继承的 V5 开放项

| 编号 | 严重度 | 问题 | 状态 |
|---|---|---|---|
| V5-01 | HIGH | Clash 2.5.10 缺 `150bfae`，重启后链式代理失效 | OPEN（上游事实；本轮不改上游） |
| V5-02 | HIGH | 上游 #8593 系统代理回退 | OPEN（设计缓解，非本轮可关闭） |
| V5-03 | HIGH | NexIP 密码未轮换 | BLOCKED-USER |
| V5-05 | MED | V4 完整回滚往返未做 | OPEN（本轮用隔离往返替代，真实环境仍待用户） |
| V5-07 | LOW | 测试台 13/13 仍 exit 1 | OPEN（本轮重写测试系统并自验） |
| V5-08 | LOW | FT11/FT14 未测 | OPEN（本轮用隔离注入覆盖） |

## D. 关闭规则

只有“独立失败测试先证明缺陷存在 → 修复 → 同一测试转绿 + 独立复审确认”才可标 VERIFIED-CLOSED。
不得以源码存在某行、静态阅读或主代理自评作为关闭依据。
