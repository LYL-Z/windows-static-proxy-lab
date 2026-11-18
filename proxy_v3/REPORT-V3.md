# REPORT-V3 — 可靠性、隐私、安全与最终工程验收

- 时间：2026-11-18 03:00 → 03:45 (America/Los_Angeles)
- 方式：实际操作系统、独立代理复审、真实测试、公开资料核验
- 交付目录：`D:\claude防封\proxy_v3\`（V1 `proxy_diag\`、V2 `proxy_v2\` 全部保留，未覆盖）
- 前提：未伪造身份/位置/设备指纹；未绕过任何平台限制；未购买/续费/退款；未提交工单

---

## 0. 总评

**V3.0 = PARTIAL PASS（工程） / NOT_READY（Claude 使用资格）**

V3 的价值不在于"又连上了"，而在于三件事：

1. **把 V2 的"自我证明"换成了独立复审 + 故障注入**，并**真的发现了 5 个 HIGH 缺陷**——其中 H1 意味着 V2 宣称的"自动回滚"在真实失败下**根本不会执行**；
2. **解释了长期困扰的出口不一致**：静态 IP 只承载 TCP，UDP 全部走 StarSky；
3. **P0 安全处置落地**：清掉历史记录与参考副本中的明文密码，收紧备份 ACL，暴露面从 17 个文件降到 0（文档/日志/脚本）。

---

## 1. 验收矩阵

| 项 | 要求 | 状态 | 关键依据 |
|---|---|---|---|
| **P0** 凭据与配置安全 | 处置已暴露凭据、审查历史/备份/扩展、ACL | **PASS**（含残余） | `SECURITY-REVIEW.md`；明文暴露 17→0；历史 1→0；两棵备份树 ACL 收紧。**残余**：快照 YAML 仍含明文（回滚需要），已 ACL 保护；**密码轮换待用户执行** |
| **P1** V2 独立代码复审 | 不得自我证明；故障注入 | **PASS** | `INDEPENDENT-REVIEW.md`；第三方代理复审，5 HIGH / 10 MEDIUM / 15 LOW；已修 8 项并回归验证；6 项明确列为开放 |
| **P2** 网络拓扑与协议审计 | TCP/UDP/HTTP1.1/2/3/IPv6/DNS/WebRTC/代理层 | **PASS**（部分 NOT_TESTED） | `NETWORK-MATRIX.md`；HTTP/3 与 Node.js 为 NOT_TESTED；IPv6 为 N/A（主机无全局 v6） |
| **P3** 静态代理尽调 | ARIN/BGP/RPKI/信誉/条款 | **PASS** | `IP-DUE-DILIGENCE.md`；住宅属性**未证实**；独享**未证实**；NexIP 条款无 SLA |
| **P4** 状态管理与可靠性 | 五态状态机 + 恢复 | **PARTIAL** | `state.ps1` 五态已实现并通过 5/5 故障注入；睡眠/唤醒、Wi-Fi 重连 **PENDING** |
| **P5** 24h/72h 长稳 | 首试成功率、失败不删、PENDING 不冒充通过 | **PENDING** | `LONG-RUN-STATUS.md`；工具就绪并冒烟 10/10，**24h/72h 未执行** |
| **P6** 账户安全与资格 | 政策核验 + 清单 | **NOT_READY**（Claude 资格）/ **PASS**（清单） | `ACCOUNT-SECURITY.md` |
| **P7** 供应商沟通 | 10 问技术咨询 | **PASS**（草稿） | `PROVIDER-QUESTIONS.md`；**未提交**，需用户批准 |
| **P8** 交付物 | 独立目录 + 证据 | **PASS** | 见 §6 |

---

## 2. P0 结果（能力范围内已闭环）

| 发现 | 处置 | 结果 |
|---|---|---|
| 17 个文件含明文密码 | 3 个 V1 参考副本打码；12 个快照保留但 ACL 收紧 | 文档/日志/脚本暴露 **0** |
| PowerShell 历史含 1 次密码 | 备份后原地打码 | **1 → 0** |
| 两棵备份树 ACL 未收紧 | `icacls /inheritance:r` 至 用户/SYSTEM/Administrators | `protected=True` |
| 7 个浏览器扩展，4 个有 `debugger`/`nativeMessaging` | 仅列元数据（未读 Cookie/令牌） | 待用户逐个复核 |

**必须由用户完成**：到 NexIP 后台**重置代理密码**，并确认重置**不影响 IP**（已列入咨询第 10 问）。

---

## 3. P1 复审的关键修正（这是本轮最重要的一节）

| V2 的自我结论 | 独立复审的结论 | 本轮 |
|---|---|---|
| "任一关键步骤失败会自动还原" | **不成立**：`EAP=Stop` + `curl 2>&1` 抛出终止异常，重试与还原是死代码（H1） | **已修 + 回归验证** |
| "回滚会恢复系统代理" | **不成立**：实际 7897，脚本仍 `exit 0`（H4，项目自己的日志为证） | **已修**（轮询校验，对不上 `exit 41`） |
| "快照 + 哈希校验" | 校验发生在**破坏性覆盖之后**（H5） | **已修**（先校验后还原） |
| "ACL 收紧" | 第二次起静默失败并可能误报成功（M1/M2） | **已修**（幂等 + 强制 owner ACE） |
| YAML 解析可处理 profile | 注释/锚点会解析错误，甚至指向错误服务器（M5） | **未修**（开放） |

修复后的实测：

```
H1 regression : EAP=Stop 下探测死端口返回 [] 而非抛异常   PASS
H2 regression : 失败替换后仍为 ORIGINAL；成功为 NEW2；残留 .bak=0  PASS
FI1..FI5      : 5/5 PASS
apply-v2      : configs replaced → chain verified 72.245.197.103 → 系统代理 7897   PASS
ACL           : 快照目录 ACL 成功（不再报 needs ownership）
```

---

## 4. P2 的核心发现：出口不一致的真相

| 协议 | 路径 | 出口 |
|---|---|---|
| TCP/HTTPS | Clash → StarSky → NexIP | **72.245.197.103** |
| UDP/STUN（直连） | utun119 → StarSky | **142.111.173.93** |
| UDP/STUN（**经 Clash UDP 中继**） | Clash 回落 → utun119 → StarSky | **142.111.173.93** |

结论：**静态 IP 只覆盖 TCP**。节点 `udp: false`，NexIP 侧也未文档化 UDP 支持。
所以 `IPPure` 的"WebRTC 可能泄漏"与 `ip.net.coffee` 的"未检测到泄漏"**都成立**，它们测的是不同协议。
另外两点：**WinHTTP 为 Direct**（只用 WinHTTP 的程序完全绕过代理）；**HTTP/2 可用**（ALPN h2），HTTP/3 因客户端缺失未测。

---

## 5. P3 尽调结论（分级，不给"100%"）

- **确认**：GTT `/15` → Arisk 客户记录 `C11472792` 的 `/21`；由 **AS3257** 宣告；geofeed 自述华盛顿 DC；RPKI **Valid**（AS3257 ROA，maxLength 24）；3 个公共 DNSBL 未收录。
- **未证实**：**真实家庭宽带**、"独享"。
- **反向证据**：Arisk 自己的 **AS395793 并不宣告**该段；按 NexIP 公开文章给出的"原生 vs 广播"判据，此形态更接近**运营商地址资源提供的静态 ISP 代理**。
- **条款**：NexIP **没有 SLA**（"努力实现 99.9%"，ISP 中断免责）；退款仅 3 天内且仅限"技术上无法使用"；IP"失效"可免费更换。
- **重要旁证**：NexIP 自己的配置文档（`doc.nexip.net` 对本次抓取返回 403，仅索引片段）明确给出"国内使用静态 IP 需先经中转"的章节，并记录过"静态住宅 SOCKS5 节点被墙，无法直接连接"。这与本机实测（大陆来源被立刻断开、美国来源正常）**相互印证**。

---

## 6. 交付物

| 文件 | 内容 |
|---|---|
| `REPORT-V3.md` | 本报告 |
| `INDEPENDENT-REVIEW.md` | 独立复审：5 HIGH / 10 MEDIUM / 15 LOW，修复与开放项 |
| `NETWORK-MATRIX.md` | 协议矩阵与出口一致性分析 |
| `IP-DUE-DILIGENCE.md` | ARIN/BGP/RPKI/geofeed/条款/第三方分类 |
| `SECURITY-REVIEW.md` | 凭据处置、ACL 事故复盘、扩展权限 |
| `ACCOUNT-SECURITY.md` | 资格 NOT_READY + 账户检查清单 |
| `PROVIDER-QUESTIONS.md` | 可直接发送的 10 问（未发送） |
| `LONG-RUN-STATUS.md` | 24h/72h PENDING 与判定规则 |
| `USER-GUIDE-V3.md` | 日常操作与故障顺序 |
| `CHANGELOG.md` | V1→V3 变更 |
| `state.ps1` `invoke-faultinjection.ps1` | 五态状态机、故障注入台 |
| `tools\stun_probe.py` `udp_relay_test.py` `proto_probe.py` `monitor-longrun.py` | UDP/协议/长稳工具 |
| `evidence\` `lib\` | 原始证据与自包含库 |

---

## 7. 未完成 / 需要用户的事

| 项 | 状态 | 谁来做 |
|---|---|---|
| 24h / 72h 长稳 | **PENDING** | 用户启动（命令在 `USER-GUIDE-V3.md`） |
| 睡眠唤醒 / Wi-Fi 重连 | **PENDING** | 需真实触发，会中断会话，需用户同意 |
| 代理密码轮换 | **待执行** | 用户在 NexIP 后台操作 |
| 提交供应商咨询 | **未发送** | 用户批准后 |
| M5/M6/M8/M9/M10 等复审开放项 | **开放** | 下一轮（需改 YAML 解析/Profile 机制/加锁） |
| Claude 使用资格 | **NOT_READY** | 用户自行向官方确认 |

---

## 8. 最后一句实话

这套系统现在**能在 TCP 上稳定地以 `72.245.197.103` 访问 HTTPS**，并且**第一次有了可独立复现的故障测试与诚实的失败报告**。

但它**不**等于"住宅 IP 已确认"、**不**等于"独享"、**不**等于"长期稳定已验收"，更**不**等于"Claude 使用资格成立"。

把这四件事混为一谈，就是上一版报告最大的问题；V3 不做这个混同。
