# WebRTC / UDP 出口（N2）

状态：2026-11-28 04:50-05:04（America/Los_Angeles）在本机实测。全程只读：没有打开用户真实浏览器资料，未改动 TUN/代理/DNS/路由/防火墙，未重启任何组件。

`proxy_v4/tools/webrtc-probe.ps1` 给出的判定：

```
verdict = CONSISTENT
UDP direct   : 107.149.115.70
UDP via proxy: 107.149.115.70
TCP direct   : 107.149.115.70   (via DIRECT, transport=OK)
TCP via proxy: 72.245.197.103  (via PROXY)
browser ICE  : verdict=SRFLX_PUBLIC  mDNS=699c25ff-...local  literalHost=-  srflx=107.149.115.70
```

一句话读法：UDP 和裸 TCP 都以**107.149.115.70** 作为出口；**72.245.197.103** 只在应用使用 Clash 这一跳时出现。两者都不是国内公网地址 112.194.196.155。实测到的 UDP/TCP 差异是**不同协议走了不同代理出口**，不是中国公网 IP 被暴露的证据。

## 1. 测了什么、用什么测

| # | 测量 | 实现 | 结果 |
|---|---|---|---|
| 1 | 系统路由下 UDP 套接字发 STUN 绑定请求 | `tools/stun-egress-probe.py --mode direct`（仅标准库） | 从 `stun.cloudflare.com:3478` 得到 `107.149.115.70`，rtt 1073 ms |
| 2 | 同一 STUN 请求放进 127.0.0.1:7897 的 SOCKS5 UDP ASSOCIATE 会话 | `tools/stun-egress-probe.py --mode socks5` | `107.149.115.70`，rtt 1932 ms |
| 3 | TCP 出口，不走代理 | `diag-contract.ps1` 的探测 + `-CaptureBody` | `107.149.115.70` |
| 4 | TCP 出口，经 127.0.0.1:7897 | 同一探测加 `-x` | `72.245.197.103` |
| 5 | 浏览器 ICE 候选 | `tools/webrtc-browser-probe.ps1`：无界面 Edge + %TEMP% 下的一次性 `--user-data-dir` + DevTools 协议 | 2 个候选：一个 mDNS `host`，一个 `srflx 107.149.115.70` |

浏览器原始候选（逐字）：

```
candidate:331213419 1 udp 2113937151 24181d91-3d38-45a7-9d2a-927e8cae6571.local 56048 typ host generation 0 ufrag vz5S network-cost 999
candidate:440564212 1 udp 1677729535 107.149.115.70 52992 typ srflx raddr 0.0.0.0 rport 0 generation 0 ufrag vz5S network-cost 999
```

本次调查声明的外部目标（除此之外不访问任何地址；每种模式每个服务器一个绑定请求，最多两次、间隔 3 秒）：

* `stun.cloudflare.com:3478` —— 两种模式都返回了结果
* `stun.l.google.com:19302` —— **每次运行的两种模式都超时**（被记进 `unknown`，不会被静默丢掉）
* `https://api.ipify.org` —— 用于对比的 TCP 回显

## 2. 五种情况，分开说清

检测截图里「WebRTC IP」与「HTTPS IP」不同。这同一个观测可以有五种完全不同的含义。下面按情况逐一说明本机实际属于哪一种，并给出证据。

### 2.1 真实公网地址暴露（最危险的情况）—— 未观测到

定义：WebRTC 候选里带着操作者自己的国内公网 IPv4（112.194.196.155）或同线路的国内 ISP 地址，于是网页可以绕过代理得知家宽身份。

实测：没有任何 STUN 结果、也没有任何浏览器候选包含 112.194.196.155 或该线路的其他地址。本文出现的所有公网地址（107.149.115.70、72.245.197.103）都是转发出口，Cloudflare trace 标注 `loc=US`。

边界：本次运行只能代表它测过的那些路径（见第 6 节）。

### 2.2 只是不同代理出口（最符合本机的情况）—— 已观测到

定义：应用只代理 TCP（HTTP/SOCKS），不代理 UDP；UDP 按系统路由出去，于是两个出口不同。

实测链条：

| 协议 | 经过的跳 | 出口 |
|---|---|---|
| HTTPS 走系统代理 | 应用 → 127.0.0.1:7897 → 第一跳 127.0.0.1:11119 → socks5 72.245.197.103 | 72.245.197.103 |
| UDP / STUN，无代理跳 | 系统路由 → TUN `utun119` → 隧道客户端 | 107.149.115.70 |
| 裸 TCP，无代理跳 | 同上系统路由 | 107.149.115.70 |

所以 `107.149.115.70` 不是「伪装的中国 IP」：它就是本机裸 TCP 连接拿到的同一个地址，也是厂商本机第一跳返回的地址。截图里的那一对（72.245.197.103 对 107.149.115.70）正是这一组行。

还有一个实测细节：即使显式经 7897 做 SOCKS5 UDP ASSOCIATE，返回的也是 107.149.115.70，而不是 72.245.197.103。运行中的 Clash 配置在承载静态 IP 的 SOCKS5 条目上写着 `udp: false`，因此 UDP 无法经由该条目，客户端只能回落到不走该代理的数据报路径。这个机制与配置一致，但属于推断，本次运行没有向 Clash 控制器求证（它只监听命名管道）。

### 2.3 私有 / 本地候选（无害的情况）—— 未观测到，而且部分被默认机制隐藏

定义：网页唯一能多知道的地址是 RFC1918/CGNAT/链路本地或环回地址。

实测：浏览器只发出一个 `host` 候选，而且是 **mDNS 名称**（`*.local`），不是字面地址。现代 Chromium/Edge 会用这种方式混淆 host 候选，所以本地 `10.99.0.1`（TUN）/ `10.133.162.234`（WLAN）没有暴露给网页。`webrtc-probe.ps1` 只有在**全部**映射地址都是私有时才报 `PRIVATE_ONLY`；本例不是，因为 `srflx` 候选是公网地址——但那个公网地址属于 2.2 的代理出口，不属于本机线路。

### 2.4 检测站点分类差异 —— 很可能是，但未被证伪

定义：站点的「WebRTC IP」一栏本身不是泄漏指标，而是它自己从浏览器跑 STUN/ICE 测试的结果；这类测试按设计走的是不走代理的 UDP 路径。于是两条传输的两个出口就被显示成「两个 IP」。

实测支持：同机浏览器运行复现了同一个分叉（HTTPS 经代理 → 72.245.197.103；ICE → 107.149.115.70）。本次运行无法说明的是：那个检测页把它标成什么——本文没有打开该页面，其分类逻辑未知。建议把「WebRTC IP」读作「你的浏览器 UDP 路径的出口地址」，而不是「你的真实 IP」。

### 2.5 证据不足 —— 见显式清单

本次没有确立的内容全部列在第 6 节，并且每次运行都写进工具的 `unknown` 数组。工具的 `verdict` 词表被刻意限制为 `CONSISTENT / DIFFERENT_EGRESS / UNKNOWN / PRIVATE_ONLY`；没有「泄漏」/「安全」这类判定，因为这个探测产生不了那种结论。

## 3. 浏览器路径：如何在不碰用户资料的前提下验证

`tools/webrtc-browser-probe.ps1`：

* 必须显式给 `-Consent`（不给则：退出码 2、`verdict=UNVERIFIED`、`error=consent_required`，不启动任何东西——由测试 T06 覆盖）；
* 在 `%TEMP%` 下新建 **一次性** `--user-data-dir`，以无界面方式启动 Edge（`--headless=new --disable-gpu --no-first-run --no-default-browser-check`），绝不使用用户真实资料；
* 提供一个生成的本地页面，只建一个 `RTCPeerConnection`，STUN 服务器只使用声明的那一个，收集 10 秒后把候选字符串报出来；
* 通过 DevTools 协议读取结果（`Page.navigate` + `Runtime.evaluate`），随后只结束命令行中带本次临时目录的进程，并删除该目录；
* 浏览器启动失败时如实报 `UNVERIFIED` 及原因，不猜测。

结果（2026-11-28T05:03:26-08:00）：`verdict=SRFLX_PUBLIC`，一个 mDNS host 候选、一个 `srflx` 候选 `107.149.115.70`，**零个字面 host 候选**。

## 4. 通用「隐私控制」的副作用

以下是常见的缓解措施。本次一项都没有实施，列出是因为它们都有代价。

| 控制项 | 作用 | 与真实使用的冲突 |
|---|---|---|
| 禁用非代理 UDP（`WebRtcIPHandlingPolicy = disable_non_proxied_udp`，或 `chrome://flags` 等效项） | 禁止未经代理的 UDP，ICE 只能走中继/TURN 路径 | 网页版视频会议（Meet/Teams/Zoom web）、语音通话、屏幕共享和部分游戏会退化为中继媒体：延迟更高、带宽和 CPU 更多；若没有可达中继，通话直接失败。它并没有让代理承载 UDP，只是让 UDP 在无中继时不可用 |
| 把 ICE 候选限制为代理 / `default_public_interface_only` | 对 ICE 隐藏本地地址，但保留直连 UDP | 对媒体影响不大，但**不改变** UDP 的公网出口，网页看到的仍是 107.149.115.70 |
| 把包括 UDP 的一切都塞进代理 | 只有支持并承载 UDP ASSOCIATE 的代理才行 | 本机的静态 IP 条目声明 `udp: false`，无法承载媒体；不更换服务商就做不到 |
| mDNS host 候选混淆（当前已启用） | 把 host 候选替换为 `*.local` | 基本无副作用；这正是没有私有地址暴露的原因 |
| 彻底关闭 WebRTC | 直接移除风险面 | 破坏所有浏览器内通话/会议/P2P；多数用户不会接受 |

从实测得到的经验规则：唯一能消除**公网** UDP 出口的控制项是「禁用非代理 UDP」，而它恰好就是会破坏语音/视频的那一项。当前环境已经隐藏了本地地址（mDNS），UDP 也已经落在非国内出口（107.149.115.70）——这正是多数这类控制想达到的状态。

## 5. 本次改动新增的工具

`proxy_v4/tools/stun-egress-probe.py`

* 只用标准库（`socket`、`struct`、`os`、`sys`、`json`、`argparse`、`time`）；不装任何第三方包；
* 手工构造 STUN 绑定请求，解析 `XOR-MAPPED-ADDRESS`（0x0020），回退 `MAPPED-ADDRESS`，校验 transaction id；
* `--mode direct` 走系统路由套接字；`--mode socks5` 做真正的 SOCKS5 UDP ASSOCIATE（greeting、associate、UDP 封装、剥头）；
* 每种模式每个服务器最多两次尝试、间隔 3 秒；
* 本地判定私有/CGNAT/链路本地/环回，从不把结果标成「安全」或「已泄漏」。

`proxy_v4/tools/webrtc-probe.ps1`

* 编排 STUN 脚本 + 共享 `diag-contract.ps1` 的 TCP 探测，可选再做浏览器探测（`-IncludeBrowser`）；
* 输出 `udpEgress {direct, viaProxy}`、`tcpEgress {direct, viaProxy}`、`consistent`、`evidenceTime`、`unknown[]`、`verdict`、`verdictBasis`；
* `verdict` 取 `CONSISTENT / DIFFERENT_EGRESS / UNKNOWN / PRIVATE_ONLY`；`consistent` 在没有可比对象时为 `$null`，绝不默认为 `$true`；
* 每个缺口（STUN 超时、缺失 TCP 侧、跳过浏览器、未测 IPv6）都追加进 `unknown`，所以部分运行不可能被读成「干净」；
* `-SkipStun` 供离线使用，并强制 `verdict=UNKNOWN`。

`proxy_v4/tools/webrtc-browser-probe.ps1` —— 第 3 节描述的受控浏览器运行（需 `-Consent`）。

## 6. 未验证 / 未覆盖

* `stun.l.google.com:19302` 在两种模式下每次运行都超时。只有一台 STUN 服务器提供了证据，缺少第二个网络观测点。
* IPv6 UDP 出口未测（本机无全局 IPv6 地址、无 `::/0` 路由）。
* **用户真实浏览器资料**没有打开，因此那里实际生效的开关/策略未知：如果禁用非代理 UDP，或有扩展改写了 ICE，用户浏览器的行为可能与受控运行不同。受控运行用的是干净的一次性资料。
* TURN/中继行为未测（没有连接任何 TURN 服务器），只观测到 host 与 server-reflexive 候选。
* 没有向 Clash 控制器查询（它只监听命名管道），所以「UDP 因 `udp: false` 无法使用静态 IP 的 SOCKS5 条目」是由配置推导且与实测一致，不是由代理自身日志证明。
* 检测网站 UI 把 107.149.115.70 标成什么，未被复现；本次没有打开该页面。
* 隧道客户端停掉后的行为（UDP 会回落到物理线路还是失败）未测——停掉它超出本任务边界。
* 107.149.115.70 是本操作者独享还是服务商共享，未确认。
* 支持 UDP 的代理路径未测（本机没有配置这样的代理）。

## 7. 复现

```powershell
cd proxy_v4\tools
python .\stun-egress-probe.py --mode both
powershell -NoProfile -ExecutionPolicy Bypass -File .\webrtc-probe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\webrtc-probe.ps1 -Json
powershell -NoProfile -ExecutionPolicy Bypass -File .\webrtc-probe.ps1 -IncludeBrowser   # 会启动一次性无界面浏览器
powershell -NoProfile -ExecutionPolicy Bypass -File .\webrtc-browser-probe.ps1 -Consent
cd ..\tests\tools; powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke-tool-checks.ps1
```
