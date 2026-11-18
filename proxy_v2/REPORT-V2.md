# REPORT-V2 — 静态代理系统 V2.0 审计、改造与验收

- 时间：2026-11-18 02:00 → 02:35 (America/Los_Angeles)
- 环境：Windows 11 家庭中文版 (10.0.26300)，用户 `老黄之友\lenovo`（非管理员），PowerShell 5.1
- 工作目录：`D:\claude防封\proxy_v2\`（V1 成果保留在 `D:\claude防封\proxy_diag\`）
- 性质：通用网络连接 / 隐私 / 可靠性工程。涉及第三方服务时只做公开政策核验，不规避地区限制。

---

## 0. 结论与状态矩阵

**一句话**：上一版"连接已修复"的结论是对的，但**没有反映用户实际看到的出口 IP**——因为交付后 Clash 进程退出了，StarSky 重新占有了系统代理，浏览器实际走的是 StarSky。V2 把这件事变成**可检测、可复现、可自动恢复**的问题，并用事务式脚本消除了"配置改了但没生效"的模糊地带。

| 项 | 状态 | 依据 |
|---|---|---|
| P0 接管上一轮成果、重建基线 | **PASS** | §1 |
| P1 出口差异原因定位 | **PASS** | §2（直接证据） |
| P2 NexIP 质量独立审查 | **PARTIAL** | §3；独享性/滥用记录无法从本机证实 |
| P3 配置与脚本工程化改造 | **PASS** | §4；11 项缺陷逐条修复 |
| P4 三模式 + 故障恢复 | **PARTIAL** | §5；4/4 故障测试通过，睡眠/唤醒、Wi-Fi 重连未测 |
| P5 性能与稳定性验收 | **PARTIAL** | §6；**300/300（100%）**、3 窗口、连接复用、故障恢复均达标；**24h 长稳 PENDING** |
| P6 第三方服务适用性 | **PASS**（政策核验）／**NOT_READY**（Claude 使用资格） | §7 |
| P7 交付物 | **PASS** | §8 |

---

## 1. P0 — 接管与基线（不采信历史报告）

接管时刻的实时快照（2026-11-18 02:00）：

| 项 | 实测值 |
|---|---|
| `clash-verge` / `verge-mihomo` 进程 | **0 个（未运行）** |
| 7897 监听 | **无** |
| 系统代理 | `ProxyEnable=1`，`ProxyServer=127.0.0.1:11119`（**StarSky**） |
| 出站适配器 | `utun119`（sing-tun/Wintun，StarSky） + `WLAN`；默认路由 metric 0 → utun119 |
| StarSky 核心 | `magicspeed` PID 48964（01:42:58 启动） |
| 直连出口 | `142.111.173.93`（US / Washington / Seattle / AS26383 Baxet Group） |

配置哈希基线（SHA256 前 16 位，完整值见 `test-results\baseline.json`）：

```
clash-verge.yaml               260B7B0E1F32F7DC
config.yaml                    74CB60DA39C121A7
verge.yaml                     7EDBFD4A8AB645EA
profiles.yaml                  8D9867400D1E125B
profiles\LWMoQxn0PeIP.yaml     2866DBD6110A97EE
```

---

## 2. P1 — 出口 IP 差异的根因

### 2.1 路径矩阵（全部使用中立端点 `api.ipify.org`）

| 路径 | 实测出口 | 说明 |
|---|---|---|
| 直连（经 utun119） | `142.111.173.93` | StarSky 隧道 |
| 经 `127.0.0.1:11119`（StarSky 系统代理） | `142.111.173.93` | 与上一条相同 |
| 经 `127.0.0.1:7897`（Clash） | **连接被拒绝** | 7897 无监听，Clash 未运行 |

### 2.2 结论

用户在 01:43–01:49 看到的 `142.111.173.93`，是**当时系统代理已在 StarSky 手里、且 Clash 进程不在**的正常结果，而不是静态代理"又坏了"。

三条独立证据：

1. **进程与端口**：接管时 `clash-verge`/`verge-mihomo` 均为 0，7897 无监听；
2. **注册表**：`ProxyServer=127.0.0.1:11119`（StarSky 的端口），而非脚本设置的 7897；
3. **mihomo 崩溃前日志**（`logs\sidecar_latest.log`）：
   ```
   01:40:16  dial PROXY (match Match/) ... --> login.live.com:443
             error: 72.245.197.103:9506 connect error: 127.0.0.1:11119 connect error:
             dial tcp 127.0.0.1:11119: connectex: No connection could be made
             because the target machine actively refused it.
   ```
   即 **StarSky 在 01:40 左右重启，第一跳 11119 短暂拒绝连接**，链式代理随即全线失败；`magicspeed` 的启动时间 01:42:58 与此吻合。

### 2.3 关于"Clash 为什么会退出"

- `Application` 日志近 3 小时**无** clash/mihomo/verge 的 Error/Critical 事件；
- Clash Verge 应用日志在 `01:36:12` 之后**直接结束**，没有优雅退出记录；
- 因此判定为**非正常终止且原因不可确定（UNKNOWN）**，不做进一步推测。

### 2.4 由此得到的工程设计约束

**系统代理是三方争夺的共享资源**（Clash 启动、StarSky 启动、运维脚本）。这不是理论风险，而是本次的真实故障源。V2 的处理见 §4/§5。

---

## 3. P2 — NexIP 质量独立审查

### 3.1 注册与网络归属（RDAP，ARIN）

```
handle   : NET-72-245-192-0-2        name : GTT
range    : 72.245.192.0 - 72.245.199.255
type     : ASSIGNMENT                entity: C11472792 (registrant)
remark   : Geofeed https://ariskisp.com/rfc8805.csv
```

### 3.2 多源地理一致性（3 家，全部一致）

| 来源 | 国家/地区/城市 |
|---|---|
| ip-api.com | US / District of Columbia / Washington |
| ipinfo.io | US / District of Columbia / Washington |
| ipwho.is | US / District of Columbia / Washington |

→ **多源地理位置一致**，与商家"美国华盛顿"一致。

### 3.3 分类与"原生住宅"声明

| 判断维度 | 结果 | 性质 |
|---|---|---|
| ip-api `hosting` / `proxy` / `mobile` | `false` / `false` / `false` | 第三方数据库 |
| ASN 与 org | AS3257 GTT Communications；ISP 标注 Arisk Communications | 第三方数据库 |
| RDAP 性质 | 运营商（GTT）整段 ASSIGNMENT | 注册数据 |
| 商家声明 | "家宽原生 IP"、"独享"、"永不掉线" | **商家宣传，未独立验证** |
| 独享性 | **UNKNOWN** | 无法从客户端证实（同一 IP 是否被他人共享，只有商家知道） |

**审慎结论**：三条第三方数据都不把该 IP 标为 hosting/proxy，但也**不能**据此证明它是"家宽原生"；RDAP 显示它属于 GTT 的运营商网段并由 Arisk 运营，这更接近"运营商/ISP 网段"而非典型 residential 宽带。**商家声明与第三方判断不一致，需要商家提供更明确的说明**。

### 3.4 滥用记录

对 `103.197.245.72.*` 做了 4 个公共 DNSBL 查询（证据 `test-results\abuse-lookup.json`）：

| 列表 | 结果 | 解读 |
|---|---|---|
| `bl.spamcop.net` | NXDOMAIN | **未被列入** |
| `b.barracudacentral.org` | NXDOMAIN | **未被列入** |
| `dnsbl-1.uceprotect.net` | NXDOMAIN | **未被列入** |
| `zen.spamhaus.org` | `127.255.255.254` | Spamhaus 对公共解析器（1.1.1.1）返回的"拒绝服务"码，**不是列入**，判定为**无结论** |

→ 结论：**3 个公共黑名单均未收录**；Spamhaus 因公共解析器限制无法判定。这只能说明"没有出现在最常用的公开黑名单里"，**不等于**该 IP 在商业风控库里干净。

### 3.5 连接质量（本机实测，见 §6）

- 成功率高（多窗口 100%），但**延迟高**：端到端 p50 ≈ 2.6 s，其中 TLS 握手 p50 ≈ 2.2 s；
- 偶发 ~5 s 级超时（V1 累计 4/58，V2 窗口内未复现）。

### 3.6 必须保留的不确定性

> 我们只证明了：**从中国大陆来源接入会被立刻断开，从美国来源接入正常**。
> 我们**没有**证明 NexIP"只允许美国来源 IP"，也没有证明存在 IP 白名单。具体是哪一种访问控制策略，**必须由商家确认**。

---

## 4. P3 — 工程化改造（缺陷 → 修复）

| # | V1 缺陷 | V2 修复 | 验证方式 |
|---|---|---|---|
| 1 | 先覆盖正式配置，再跑 `mihomo -t` | 先写临时文件 → 校验 → **原子替换** | `apply-v2` 日志 "staged configs pass" |
| 2 | 校验失败没有事务回滚 | 任一关键步骤失败 → `Restore-StateSnapshot` 自动还原 | 代码路径 + `31` 分支 |
| 3 | 硬编码安装目录/配置目录/profile id | `Get-ClashPaths` 依次从**运行进程 → 卸载注册表 → 默认路径**发现；profile 由 `profiles.yaml: current` 解析 | 日志打印实测路径 |
| 4 | 硬编码命名管道 | `Get-MihomoChannel` 从**运行进程命令行 `-ext-ctl-pipe`** 或运行时配置解析 | "controller pipe detected (len=102)" |
| 5 | 只检查 11119 端口监听 | `Test-FirstHop` 发真实 `CONNECT` 并要求 `200` | 故障测试 A（对 11199 判定 DOWN） |
| 6 | 端口等待超时仍继续改系统代理 | 45 s 超时 → 还原 + `exit 30`，**绝不**碰系统代理 | 代码路径 |
| 7 | 验证失败只打印 FAIL | 全部失败路径返回非零退出码（10/11/12/20/30/31/32/40） | USER-GUIDE §3 |
| 8 | 重复执行可能残留 | 幂等：每次先快照、覆盖同一份 profile、节点名固定 | 连续三次 apply 均成功 |
| 9 | 备份/配置无权限收紧 | `Protect-PrivatePath`：仅 当前用户/SYSTEM/Administrators + **回读自检** | 见 SECURITY §2.1（含一次真实锁死与修复） |
| 10 | 凭据可能进日志/导出 | `Register-Secret` + `Get-Redacted` 全局脱敏；证据文件只含 IP 与时延 | 抽查日志/JSON 无明文 |
| 11 | —— | 不修改时区/指纹/地理位置，不关闭 Defender/防火墙 | 代码审查 |

**额外修复（过程中发现）**：

- PowerShell 5.1 会**丢弃空字符串原生参数**，导致 `curl -w '' -x <proxy>` 参数错位、把代理地址当成 URL（`Protocol "socks5h" is not for transfers`）。已移除空参数并验证。
- `$args` 是自动变量，不能用作普通参数数组（已改用 `$curlArgs`）。
- 快照函数把布尔值混入返回值，导致日志出现 `snapshot -> True`（已改为 `| Out-Null` 并返回路径）。
- 节点名改为 ASCII（`US-WA-SOCKS5` / `STAR-FIRSTHOP`），消除子进程 codepage 造成的乱码。

---

## 5. P4 — 三种模式与故障恢复

### 5.1 模式

`apply-v2.ps1 -Mode RAW | STARSKY | NEXIP`，每种模式切换后都会打印**预期出口**，并由 `status.ps1` 报告**实际出口**。详见 ARCHITECTURE §1。

### 5.2 故障测试（真实执行，证据 `test-results\fault-tests.json`）

| # | 场景 | 预期 | 实测 | 结果 |
|---|---|---|---|---|
| A | 第一跳探测对关闭端口 | DOWN | `port 11199 not listening` | **PASS** |
| B | StarSky 抢走系统代理（复现 P1 故障） | MISMATCH | `verdict=MISMATCH, mode=STARSKY` | **PASS** |
| C | 杀掉 mihomo 核心 | DEGRADED | `verdict=DEGRADED, mode=NEXIP-CORE-DOWN` | **PASS** |
| D | 核心崩溃后恢复 | OK | `restart=True, verdict=OK` | **PASS** |

### 5.3 回滚测试（真实执行）

对 `20261118-020424`（V2 改造前的快照）执行 `rollback-v2.ps1`：

```
restored clash-verge.yaml / config.yaml / verge.yaml / profiles.yaml / profiles\LWMoQxn0PeIP.yaml
system proxy restored -> 127.0.0.1:11119
hash verification passed for all restored files
```

**过程中发现并修复的新缺陷**：Clash Verge 启动时若 `enable_system_proxy: true`，会**再次改写**系统代理，覆盖回滚刚恢复的值。修复方式：

- 快照中新增 `clashRunning`；
- 回滚只在"快照时 Clash 确实在运行"才重启它；
- 若仍然被改写，**再断言一次**并记录 WARN。

### 5.4 未完成的故障场景

| 场景 | 状态 | 原因 |
|---|---|---|
| Windows 睡眠/唤醒 | **PENDING** | 需要长时间离开工位，未在本轮触发 |
| Wi-Fi 断开/重连 | **PENDING** | 会中断当前会话，未擅自执行 |
| StarSky 主动崩溃 | **PARTIAL** | 该场景在 01:40 已**自然发生**并有日志证据（§2.2）；未再主动杀进程，因为 StarSky 只能人工点"开始加速"恢复，失败会把用户留在断网状态 |

---

## 6. P5 — 性能与稳定性

### 6.1 测试窗口（中性端点，每次全新 TLS 握手）

| 窗口 | 时间 | 路径 | 样本 | 成功率 | p50 | p95 | TLS p50 |
|---|---|---|---|---|---|---|---|
| W1 | 02:07 | 链式（Clash 7897） | 15 | 100% | 2650 ms | 3256 ms | 2293 ms |
| W1 | 02:07 | 直连（StarSky TUN） | 15 | 100% | 1142 ms | 2283 ms | 806 ms |
| W2 | 02:11 | 链式（Clash 7897） | 20 | 100% | 2558 ms | 2932 ms | 2219 ms |
| W3 | 02:27 | 链式（Clash 7897） | 20 | 100% | 2738 ms | 4016 ms | 2356 ms |

### 6.2 300 次验收（已完成）

证据：`test-results\acceptance300-20261118-021150.json`

| 指标 | 结果 |
|---|---|
| 窗口 | 02:11:52 → 02:25:30（约 13.6 分钟） |
| 请求数 / 成功 | **300 / 300（100%）** |
| 失败原因分布 | 无（0 次失败） |
| 出口 IP | `72.245.197.103` × 300（100% 一致） |
| 延迟 | min **2324** / p50 **2678** / p90 **2950** / p95 **3201** / p99 **4274** / max **4577** ms |

对照工程验收目标：

| 目标 | 要求 | 实测 | 结论 |
|---|---|---|---|
| 有效请求数 | ≥ 300 | 300 | **达标** |
| 成功率 | ≥ 99% | 100% | **达标** |
| 失败可追溯 | 每项有日志 | 0 失败；`validate-v2` 对失败会记录 `n/ts/err` | **机制就绪** |
| 长连接 | 通过 | 复用后 2.54 s → **0.35 s**（见 §6.4） | **达标** |
| 故障恢复 | 通过 | 4/4（§5.2）+ 回滚往返（§5.3） | **达标** |
| 24h 长稳 | 连续运行 | **未执行** | **PENDING** |

### 6.3 连接复用（长连接）

同一条隧道内连续两次请求（`curl -w '%{num_connects}'`）：

```
请求 1: num_connects=1   total=2.543 s
请求 2: num_connects=0   total=0.346 s   ← 复用，无需重新握手
```

→ **2.6 s 是"新建 TLS 连接"的成本，不是每次请求的成本**。浏览器在 keep-alive 下，后续请求约 **0.35 s**，日常体感远好于 p50 数字。这也再次印证：瓶颈是握手往返，而非带宽或代理吞吐。

### 6.4 归因

- `connect` p50 ≈ 0.7–13 ms：本机到 7897 的环回，正常；
- `handshake` p50 ≈ 0 ms：Clash 混合端口无需认证；
- `ttfb` p50 ≈ 323–333 ms：首字节时间与直连（309 ms）**基本一致**；
- **`tls` p50 ≈ 2.2 s vs 直连 0.8 s**：整个链路的额外成本几乎全部落在 TLS 握手上。

→ 说明瓶颈不是 mihomo 的处理开销，而是**双跳 + 住宅最后一公里把 TLS 的往返次数放大了**（握手需要多次 RTT，任何丢包都会成倍放大）。V1 曾验证关闭 `find-process-mode`、`tcp-concurrent`、DNS 缓存均无改善，与此判断一致。

### 6.5 24 小时长稳

**PENDING**。工具已就绪，未执行满 24 小时，不得声称通过：

```powershell
python monitor-v2.py --hours 24 --interval 60 --out test-results\soak-24h.jsonl
```

---

## 7. P6 — 第三方服务适用性（Anthropic）

独立核验官方页面（2026-11-18 抓取，只读）：

| 结论 | 依据 |
|---|---|
| 存在正式 **Supported Regions Policy**，2026-11-12 生效，是**封闭清单**，"未列出的国家/地区即不支持" | anthropic.com/legal/supported-regions |
| 中国大陆不在清单内 | 同上；帮助中心清单亦不含 |
| 资格判定包含**人身实际所在位置**，且是三条并列门槛之一 | "Use by persons while physically located in an unsupported region…" |
| Usage Policy 明确禁止"违反 Supported Regions Policy 访问或为他人提供访问" | anthropic.com/legal/aup |
| Consumer Terms 要求账号信息真实完整，并禁止"bypassing any of our systems or protective measures" | anthropic.com/legal/consumer-terms |
| 申诉：`claude.ai/restricted`（需登录被封账号） | support.claude.com（Safeguards, warnings and appeals） |
| VPN/住宅代理 | **官方文本未提及**；政策从未把 IP 作为资格标准，也未认可更换出口即可获得资格 |

**因此（与本任务书一致）**：

- **美国静态 IP ≠ 符合 Claude 使用资格**（`NOT_READY`）；
- 不能以"出口 IP 检测通过"代替资格判断；
- 不应把第三方 IP 评分换算成"封禁概率"；
- 建议如需使用，先通过官方渠道确认资格（`claude.ai/restricted` 申诉、`support@anthropic.com`），而不是继续调网络参数。

> 本节只做政策事实核验，不包含任何规避地区限制的做法。

---

## 8. P7 — 交付物

| 文件 | 用途 |
|---|---|
| `REPORT-V2.md` | 本报告 |
| `ARCHITECTURE.md` | 拓扑、三方系统代理所有权、降级语义 |
| `SECURITY.md` | 凭据现实、脱敏、ACL 事故复盘、WebRTC 泄漏 |
| `USER-GUIDE.md` | 三模式操作、回滚、验收命令、错误码、FAQ |
| `apply-v2.ps1` | 事务式应用（含 DryRun） |
| `rollback-v2.ps1` | 事务式恢复 + 哈希校验 |
| `status.ps1` | 实时状态与真实出口判定 |
| `validate-v2.ps1` | 独立验收（N 次 + 成功率 + 分位数） |
| `benchmark.py` | 分阶段延迟 |
| `monitor-v2.py` | 可续跑长稳监测 |
| `lib/Common.ps1` | 共享库 |
| `test-results\` | 全部真实证据（JSON/JSONL/日志） |
| `backup\` | 每次 apply 前的快照 + `manifest.json`（含 SHA256） |

---

## 9. 已知限制

1. **链路依赖 StarSky 在"加速中"**。它一旦退出或重启，链式代理立即失效；`resilient` 会降级到本地出口（`status.ps1` 可立刻看出）。
2. **延迟 2–4 s**，不适合对时延敏感的场景。
3. **NexIP 的准入策略未经商家确认**，本报告只说"中国大陆来源被立即断开"这一事实。
4. **独享性、滥用记录、住宅属性**均无法从本机证实。
5. **Claude 使用资格 `NOT_READY`**：技术可用 ≠ 政策允许。
6. **睡眠/唤醒、Wi-Fi 重连、24h 长稳**未测（PENDING）。
