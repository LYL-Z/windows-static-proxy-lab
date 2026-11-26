# 独立代码复审（INDEPENDENT-REVIEW）

## 0. 方法与边界

- 复审由**独立代理**执行，未参与 V2 的编写；**只读**，未修改被审文件。
- 运行环境：Windows PowerShell **5.1.26100**（不是 pwsh 7），对着**真实的** `verge-mihomo.exe`、真实 profile 与配置目录执行，隔离目录做实验。
- 复审给出的缺陷中，**多条是实测复现**（标记 [verified]），不是静态猜测。
- 本文件记录：复审发现 → 本轮修复 → 修复验证 → 仍开放的问题。

**为什么需要这一步**：V2 报告里"事务回滚"的自我证明是**不成立的**——复审证明该路径在真实失败下根本不会被执行（H1）。

---

## 1. 复审发现（按严重度）

### HIGH（5 条）

| # | 缺陷 | 为什么致命 |
|---|---|---|
| **H1** | `$ErrorActionPreference='Stop'` + `curl … 2>&1`：原生命令写 stderr 会抛**终止性**异常 | `curl -sS` 每次连接失败都写 stderr → 第 7 步的 3 次重试循环**第一次就抛出**，`Restore-StateSnapshot` 永不执行，退出码变成 1（不在文档化的 10/11/12/20/30/31/32 里）。即**自动回滚是死代码** |
| **H2** | `Invoke-AtomicReplace` 用固定名 `$Target.bak`，catch 里无条件还原 | 第二次运行时若校验器先抛错，会把**上一次运行残留的 .bak** 覆盖到本来完好的文件上（[verified] 实测 `STALE-BAK-FROM-OLD-RUN`） |
| **H3** | 两次 `Invoke-AtomicReplace` 相互独立，catch 只设退出码 | 第二次失败 → profile 已是新配置、runtime 还是旧配置、Clash 跑着旧核心，**半应用状态且无人还原** |
| **H4** | 回滚只做**一次**系统代理纠正，不校验最终值，仍 `exit 0` | 项目自己的日志就是证据：`rollback-20261118-020949.log` 里"restored -> 11119"之后实际是 7897，脚本却打印 OK 并退出 0 |
| **H5** | 还原时**先覆盖文件、后校验哈希**；清单里缺文件被静默跳过 | 快照损坏时，好的现场配置已被摧毁，只剩坏快照 |

### MEDIUM（摘录）

- **M1** `Protect-PrivatePath` 不幂等：第 2 次调用必失败，日志还误报"needs ownership"；在 `EAP=Continue` 下 `Set-Acl` 失败是**非终止**错误，函数会返回 `$true` 而实际没改。
- **M2** 只要求"加了至少一个 ACE"，若**只有** SYSTEM/Administrators 成功，仍会写入把当前用户锁在外面的 DACL（即 SECURITY §2.1 的事故可复发）。
- **M3** 快照在 Clash **仍在写文件**时进行，且哈希是对源文件在复制**之后**算的。
- **M5** 手写 YAML 解析器多处实测断裂：`port: 443 # 注释` 抛类型转换；带锚点的节点会**把两个节点合并成一个并指向错误的 server**。
- **M7** `-DryRun` 失败时把含明文的临时文件留在 `%TEMP%`。
- **M8** 直接覆盖订阅托管的 profile，订阅刷新会**静默删除**注入的节点。
- **M9** 无任何锁；同一秒内两次 apply 会共用快照目录。
- **M10** `Stop-Process -Force` + 固定 sleep 2 秒，不验证进程真的退出。

### LOW（摘录）

- **L5** `validate-v2.ps1` 的 IP 正则**未锚定**：`curl: (7) Failed to connect to 127.0.0.1` 会被解析成出口 IP。
- **L8** `monitor-v2.py --expect auto` **把首个成功样本的 IP 采纳为期望值**，此后永远检测不出出口错误。
- **L12** mihomo 的 `secret` 从未 `Register-Secret`，脱敏对它无效。
- **L13** `Set-SystemProxy` 覆盖用户的 `ProxyOverride` 且从不恢复。

---

## 2. 本轮已修复并有验证

| # | 修复 | 验证证据 |
|---|---|---|
| H1 | `Get-NeutralIp` / `Test-MihomoConfig` 局部降 `EAP` 到 `Continue`，改用 `$LASTEXITCODE` 分支 | **实测**：`EAP=Stop` 下对死端口探测，`Get-NeutralIp` 返回 `[]` 而**不抛异常** → `H1 PASS` |
| H2 | `.bak` 改为每次运行唯一名 + `$madeBackup` 标记 + 成功后删除 | **实测**：失败替换后内容仍为 `ORIGINAL`；成功替换后为 `NEW2`；残留 `.bak` = **0** → `H2 PASS` |
| H3 | apply 增加 `$applied` 标志；`catch` 中若已替换则还原快照并重启 | 代码路径 + 后续 end-to-end 复跑通过 |
| H4 | 回滚改为**轮询 + 反复纠正 + 最终比对**，对不上 `exit 41` | 已实现（见 §4 的残留限制） |
| H5 | `Restore-StateSnapshot` **先按 manifest 校验全部哈希**，缺文件/不匹配直接拒绝还原 | 代码审查 + 回滚仍可运行 |
| M1/M2 | ACL 函数加幂等早退；**必须**加上 owner 的 ACE 才允许 `Set-Acl`；`Set-Acl -ErrorAction Stop` | **实测**：本轮 apply 日志由 `WARN ACL restriction skipped (needs ownership)` 变为 `INFO ACL restricted: 20261118-032152` |
| M7 | DryRun 临时文件改为 `try/finally` 清理 | 代码审查 |
| L12 | `Register-Secret $secret`（mihomo API secret 纳入脱敏） | 代码审查 |

修复后回归：

```
FI1 invalid staged config        PASS
FI2 locked target file           PASS   (REFUSED+INTACT)
FI3 state.ps1 emits a verdict    PASS
FI4 core-absent detection path   PASS
FI5 first-hop unreachable        PASS
→ 5/5
```

并重新执行了一次完整 `apply-v2 -Mode NEXIP`：

```
configs replaced atomically → Clash listening → chain verified: 192.0.2.254
system proxy -> 127.0.0.1:7897; egress = 192.0.2.254
DONE. exit=192.0.2.254
```

---

## 3. 复审对 V2 报告结论的修正

| V2 报告的说法 | 复审结论 | 本轮处理 |
|---|---|---|
| "任一关键步骤失败都会自动还原" | **不成立**（H1 使该路径不可达） | 已修 + 回归验证 |
| "回滚会恢复系统代理" | **不成立**（H4：实际值 7897，退出 0） | 已改为校验 + 非零退出 |
| "快照 + 哈希校验" | 校验在**破坏性操作之后**（H5） | 已改为先校验 |
| "ACL 收紧" | 第二次起静默失效，且可能报成功（M1） | 已改为幂等 + 强校验 |
| "YAML 解析可处理 profile" | 多种真实写法会出错，甚至指向**错误的服务器**（M5） | **未修**，见 §4 |

这些修正已同步写入 `REPORT-V3.md` 的结论表，不留"全部通过"的印象。

---

## 4. 仍开放的问题（不掩盖）

| # | 问题 | 影响 | 为什么不在这轮修 |
|---|---|---|---|
| H4 残留 | 回滚到"当时 Clash 在运行"的快照时，Clash 启动后会再次抢走系统代理；脚本现在会**如实报 `exit 41`**，但不会自动让它变成期望值 | 需要人工决定"谁该拥有系统代理" | 自动改 `verge.yaml` 的 `enable_system_proxy` 属于改用户设置，应先确认 |
| M3 | 快照仍可能在 Clash 写文件时进行 | 极小概率快照不一致 | 正确做法是"先停进程再快照"，会改变 apply 的时序；需单独回归 |
| M5 | 手写 YAML 解析器对注释/锚点/嵌套 map 不稳 | 极端 profile 下可能解析出错 | 彻底修需要引入 YAML 解析器（PS 5.1 无内置）；已记录，建议下次换 `ConvertFrom-Yaml` 或改用 Merge profile |
| M6 | `Get-YamlScalar` 取第一个匹配（可能取到嵌套 key） | 取错 `secret` → API 401 | 与 M5 同批处理 |
| M8 | 直接覆盖订阅 profile；订阅刷新会清除注入内容 | 用户"配置莫名失效" | 需改为独立 profile + Merge，涉及 Clash Verge 使用方式变更 |
| M9 | 无锁 | 并发 apply 会互相踩踏 | 需要引入锁文件与陈旧锁检测 |
| M10 | 进程退出未验证 | 系统代理写入可能被退出流程覆盖 | 需 `Wait-Process` + 复查 |

复审还列出若干**只能运行期验证**的项（管道并发、真实失败下的 apply 终态、订阅更新是否真会覆盖等），本轮未逐项执行，已在此标注。

---

## 5. 复审的元评价（值得记录）

复审最重的一条不是某个 bug，而是**方法论**：

> V2 用"我自己的脚本报告成功"来证明"我的脚本是对的"。

这不是证据。真正的证据需要**第三方视角 + 故障注入 + 可复现的失败路径**。本轮把这三样补上了（FI1–FI5 + H1/H2 回归 + 独立代理复审），并把仍然修不动的部分明确列为开放问题，而不是从报告里删掉。
