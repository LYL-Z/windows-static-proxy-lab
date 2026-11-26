# 架构说明（ARCHITECTURE）

## 1. 三种运行模式

本系统只承认三种互斥的"网络出口状态"，任何时候都只有一种在生效。`status.ps1` 判定的是**实际生效**的模式，而不是"配置里写了什么"。

| 模式 | 入口（系统代理） | 第一跳 | 最终出口 | 谁在管系统代理 |
|---|---|---|---|---|
| `RAW` | 关闭 | 无 | 本地 ISP（中国联通四川） | 无人 |
| `STARSKY` | `127.0.0.1:11119` | StarSky 自身 | StarSky 节点（`142.111.173.93`） | StarSky |
| `NEXIP` | `127.0.0.1:7897` | StarSky `11119` | NexIP 静态 IP（`192.0.2.254`） | Clash Verge |

## 2. NEXIP 模式的数据流

```
应用 / 浏览器
   │  系统代理 127.0.0.1:7897 (HTTP) 或直连本机混合端口 (SOCKS5)
   ▼
Clash Verge Rev  (mihomo v1.19.33)
   │  规则: MATCH,PROXY        TUN: 关闭
   │  PROXY = fallback[ US-WA-SOCKS5 , DIRECT ]
   ▼
节点 US-WA-SOCKS5  ── dialer-proxy ──►  STAR-FIRSTHOP (127.0.0.1:11119)
                                            │  HTTP CONNECT 192.0.2.254:9506
                                            ▼
                                   StarSky 隧道（美国西雅图）
                                            │
                                            ▼
                          NexIP 192.0.2.254:9506  (SOCKS5 + 用户名密码)
                                            │
                                            ▼
                                       互联网（出口 = 192.0.2.254）
```

关键点：

- **为什么必须两跳**：NexIP 接入端对中国大陆来源 IP 采取"TCP 放行 → 立即关闭会话"，只有在境外来源 IP 下才进入 SOCKS5 协商（详见 REPORT-V2 §3）。因此必须先经一个境外第一跳。
- **为什么用 `dialer-proxy` 而不是靠 TUN**：`dialer-proxy` 把第一跳显式绑定在节点上，链路不依赖 `utun119` 的路由状态；StarSky 的 TUN 开或关都不影响本链路。
- **为什么 Clash 的 TUN 必须关闭**：StarSky 已用 `utun119`（sing-tun/Wintun）占用默认路由，两个 TUN 同时开启会互相劫持。

## 3. 系统代理所有权问题（本项目的核心故障源）

三个程序都可能写 `HKCU\...\Internet Settings\ProxyServer`：

1. Clash Verge —— 启动时若 `verge.yaml: enable_system_proxy: true`，会**主动**写入 `127.0.0.1:7897`；
2. StarSky —— 点击"开始加速"时会写入 `127.0.0.1:11119`；
3. 本工具集（`apply-v2` / `rollback-v2`）。

这不是理论风险，而是**实际发生过的故障**：2026-11-18 01:43–01:49 用户看到的出口 IP 是 StarSky 的 `142.111.173.93`，原因是 Clash 进程已不在、StarSky 重新占有了系统代理（证据见 REPORT-V2 §2）。

因此本系统的设计约定：

- 切换模式时**先停止会争夺系统代理的进程**，再写系统代理；
- `apply-v2` 只在**链路验证通过之后**才接管系统代理，失败即回滚；
- `rollback-v2` 若快照显示"当时 Clash 未运行"，则**不启动** Clash，避免它一启动就把系统代理改回去；
- `status.ps1` 永远报告"实际生效"的模式，并在代理被第三方改写时直接判 `MISMATCH`。

## 4. 组件与职责

| 组件 | 职责 | 是否会修改系统 |
|---|---|---|
| `lib/Common.ps1` | 路径/凭据/管道发现、mihomo API、系统代理读写、快照与原子替换、ACL | 仅被调用时 |
| `apply-v2.ps1` | 事务式切换模式（NEXIP / STARSKY / RAW） | 是 |
| `rollback-v2.ps1` | 从快照事务式恢复 + 哈希校验 | 是 |
| `status.ps1` | 只读：判定实际模式、探测真实出口 IP、给出原因 | 否 |
| `validate-v2.ps1` | 独立验收：N 次真实请求 + 成功率 + 分位数 | 否 |
| `benchmark.py` | 分阶段延迟（连接/握手/TLS/TTFB/总时长） | 否 |
| `monitor-v2.py` | 可续跑的长时稳定性采样（24h 用） | 否 |

## 5. 失败模式与降级语义

| 故障 | `resilient`（默认） | `strict` |
|---|---|---|
| StarSky 未启动 / 第一跳挂 | fallback 自动降到 `DIRECT`，**出口变为本地 ISP**；`status.ps1` 会显示 `DEGRADED` 与真实出口 | 链路不通，请求失败（不会被静默改出口） |
| mihomo 核心崩溃 | `status.ps1` → `NEXIP-CORE-DOWN` / `DEGRADED` | 同左 |
| Clash 整体退出 | 系统代理仍指向 7897，浏览器报错；`status.ps1` 提示 `MISMATCH` | 同左 |
| StarSky 抢走系统代理 | `status.ps1` → `MISMATCH`（模式显示 `STARSKY`） | 同左 |
| NexIP 认证失败 / 超时 | 该节点健康检查失败 → fallback 走 `DIRECT` | 请求失败 |

> `resilient` 的代价是"可能静默改用本地出口"。因为 `status.ps1` 每次都显示**真实出口 IP**，所以这不会变成"用户不知情的出口切换"；但如果你要求绝对不允许降级，请用 `-Profile strict` 重新应用。

## 6. 文件布局

```
C:\CAB-Lab\proxy_v2\
├─ lib\Common.ps1
├─ apply-v2.ps1  rollback-v2.ps1  status.ps1  validate-v2.ps1
├─ benchmark.py  monitor-v2.py
├─ backup\<yyyyMMdd-HHmmss>\   # 每次 apply 前的快照 + manifest.json（含 SHA256）
├─ test-results\               # 验收证据（JSON/JSONL/日志）
└─ *.md                        # 本套文档
```
