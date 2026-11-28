# 网络路径与协议矩阵（NETWORK-MATRIX）

测量时间：2026-11-18 03:13–03:22 (America/Los_Angeles)
前置状态：`state.ps1` = **HEALTHY / NEXIP**，系统代理 `127.0.0.1:7897`，StarSky「加速中」+ TUN(`utun119`)。

所有测量均为本机实测；每条给出可复现命令或证据文件。

## 1. 核心矩阵

| 组件 | 协议 | 实际路径 | 观测出口 | 状态 | 证据 |
|---|---|---|---|---|---|
| curl `--noproxy` | TCP | utun119 → StarSky | `142.111.173.93` | VERIFIED | §3.1 |
| curl `-x socks5h://127.0.0.1:7897` | TCP | Clash → StarSky → NexIP | **`192.0.2.254`** | VERIFIED | §3.1 |
| Python 裸 socket（无代理） | TCP | utun119 → StarSky | `142.111.173.93` | VERIFIED | V1 探测 |
| STUN 客户端（UDP，直连） | **UDP** | utun119 → StarSky | **`142.111.173.93`** | VERIFIED | `tools/stun_probe.py` |
| STUN 经 Clash UDP ASSOCIATE | **UDP** | Clash 中继 → **回落** → utun119 → StarSky | **`142.111.173.93`** | VERIFIED | `tools/udp_relay_test.py` |
| HTTPS 请求 | HTTP/1.1 | Clash → … → NexIP | 200 | VERIFIED | §3.2 |
| HTTPS 请求 | HTTP/2（ALPN） | 同上 | `h2` 协商成功，TLS1.3 | VERIFIED | `tools/proto_probe.py` |
| HTTPS 请求 | HTTP/3 | —— | 未测（客户端无 h3） | **NOT_TESTED** | §3.2 |
| 任意流量 | IPv6 | —— | 主机 0 个全局 v6 地址 | **N/A** | §3.3 |
| 域名解析 | DNS/UDP | `utun119` → `10.99.0.2` | StarSky 侧解析 | VERIFIED（配置） | §3.3 |
| 浏览器 HTTPS | TCP | WinINET `7897` | `192.0.2.254` | VERIFIED | 用户截图 + `state.ps1` |
| 浏览器 QUIC/WebRTC | UDP | utun119 → StarSky | `142.111.173.93` | VERIFIED（推断+实测） | §2 |
| 走 WinHTTP 的应用 | —— | **直连，完全绕过代理** | 取决于路由（StarSky） | VERIFIED（配置） | §3.3 |
| Node.js 应用 | TCP | 未测 | —— | **NOT_TESTED** | —— |

## 2. 为什么两个检测网站结论相反（这是本次最重要的发现）

- `ip.net.coffee` 的「Claude AI IP 检测」测的是**TCP/HTTPS** → 看到 `192.0.2.254`；
- `IPPure` 的 WebRTC 检测测的是 **STUN over UDP** → 看到 `142.111.173.93`。

**两个结果都是真的，它们测的是不同协议。** 本机实测复现：

```
STUN 直连        -> mapped 142.111.173.93
STUN 经 Clash 中继 -> mapped 142.111.173.93   ← 即使走 Clash 的 UDP 端口，也没走静态 IP
HTTPS 经 Clash   -> 192.0.2.254
```

原因：节点配置 `udp: false`，NexIP 静态 IP 这一跳**只承载 TCP**。UDP 在 mihomo 里回落，最终由 `utun119` 的 StarSky 承载。

因此 `142.111.173.93` 出现在 WebRTC/STUN 里**不是"泄漏了中国 IP"，而是"UDP 走了另一条腿"**。IPPure 标"可能泄漏"、ip.net.coffee 标"未检测到泄漏"，是两家对"泄漏"的定义不同（前者对比主出口，后者只判断是否暴露本机公网 IP）。

## 3. 分项证据

### 3.1 TCP 出口（两跳对照）

```
curl --noproxy '*'            https://api.ipify.org -> 142.111.173.93
curl -x socks5h://127.0.0.1:7897 https://api.ipify.org -> 192.0.2.254
```

### 3.2 HTTP 版本

本机 curl 8.22 (Schannel) **未编译 nghttp2 / h3**，`--http2`、`--http3` 直接报 "not supported"。
因此改用 ALPN 直接验证：经 SOCKS5 隧道对 `www.google.com` 握手，服务端选择 **`h2`（TLS 1.3）** → 链路支持 HTTP/2。

HTTP/3 **未测**（缺客户端）。但 HTTP/3 = QUIC = UDP，按 §2 的实测结果，若浏览器启用 QUIC，其流量会走 StarSky 而非静态 IP。

### 3.3 DNS / IPv6 / 代理层

| 项 | 实测 |
|---|---|
| DNS 服务器 | `utun119: 10.99.0.2`；`WLAN: 202.115.39.9, 202.115.39.6`；`以太网: 150.217.1.2` |
| 全局 IPv6 | **0 个** → IPv6 路径不存在 |
| WinINET | `ProxyEnable=1`, `127.0.0.1:7897` |
| WinHTTP | **`Direct access (no proxy server)`** |
| 环境变量 | 无 |

**WinHTTP 是 Direct 这一点很重要**：只走 WinHTTP 的应用（部分系统组件、某些安装器）**不会**经过 Clash，而是按路由走 StarSky。这解释了为什么"有些程序看起来没走静态 IP"。

## 4. 隐私影响（如实记录）

1. **UDP 不受静态 IP 保护**：任何 UDP（WebRTC、QUIC、部分游戏的语音/对战、DNS over UDP）都从 StarSky 出口离开。
2. **QUIC 会掩盖静态 IP 的选择**：访问支持 h3 的站点时，浏览器可能用 UDP 直连，出口变成 StarSky。
3. **WebRTC 当前暴露的是 StarSky 出口**（不是中国 IP），但仍与主出口不一致。
4. **WinHTTP 应用完全绕过代理**。

## 5. 可选的一致性改进（未擅自执行）

| 措施 | 效果 | 代价 |
|---|---|---|
| 浏览器关闭 QUIC（`chrome://flags` → Experimental QUIC protocol → Disabled） | 强制走 TCP，出口统一为静态 IP | h3 站点略慢；需重启浏览器 |
| 浏览器 WebRTC 策略改为 `disable_non_proxied_udp` | 阻止 UDP 绕过代理 | 视频会议类功能可能异常 |
| 节点开启 `udp: true`（若 NexIP 支持） | UDP 也走静态 IP | 需商家确认支持；可能不可用 |
| 用 `strict` 档取消自动降级 | 不会静默改出口 | 第一跳故障时直接断网 |

本报告**不**推荐修改浏览器指纹/时区/位置来让检测网站"看起来一致"——那是伪造身份，超出本任务边界。
