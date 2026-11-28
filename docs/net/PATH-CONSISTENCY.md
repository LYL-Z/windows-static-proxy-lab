# IPv4 路径一致性（N1）

状态：2026-11-28 04:47-05:07（America/Los_Angeles）在本机实测。全程只读：未改动任何代理、TUN、DNS、路由、防火墙设置，未重启任何组件。

本文结论一句话：

```
egressConsistency = SPLIT_BY_DESIGN
```

国内 IPv4 从物理线路出去（112.194.196.155，中国联通），境外 IPv4 走代理链：应用使用 Clash 混合端口时出口是购买的静态 IP（72.245.197.103），应用不使用代理时出口是 TUN 客户端的隧道出口（107.149.115.70）。这个分流由本机可观测的规则决定，不是随机现象。

以下为本次改动新增的 `proxy_v4/tools/path-report.ps1` 的实跑输出（2026-11-28 05:06-05:07）：

```
  IPV4 EGRESS PATH REPORT   read-only   contract=cab-diag-contract/v2
  ----------------------------------------------------------------------------------------------------
  system proxy : enabled=True server=http://127.0.0.1:7897   (curl ignores this; browsers follow it)
  ipv4 default : utun119 -> 10.99.0.2 (metric 0)  tunnel=True
  clash config : mode=rule mixed-port=7897 tun.enable=false ipv6=true

path   class    target                           via    transport http egressIp        loc   ms
----   -----    ------                           ---    --------- ---- --------        ---   --
DIRECT FOREIGN  api.ipify.org                    DIRECT OK         200 107.149.115.70      1434
DIRECT FOREIGN  www.cloudflare.com/cdn-cgi/trace DIRECT OK         200 107.149.115.70  US  2926
DIRECT DOMESTIC ip.3322.net                      DIRECT OK         200 112.194.196.155       93
7897   FOREIGN  api.ipify.org                    PROXY  OK         200 72.245.197.103      5461
7897   FOREIGN  www.cloudflare.com/cdn-cgi/trace PROXY  OK         200 72.245.197.103  US  5122
7897   DOMESTIC ip.3322.net                      PROXY  OK         200 112.194.196.155       89
11119  FOREIGN  api.ipify.org                    PROXY  OK         200 107.149.115.70      2785
11119  FOREIGN  www.cloudflare.com/cdn-cgi/trace PROXY  OK         200 107.149.115.70  US  1250
11119  DOMESTIC ip.3322.net                      PROXY  OK         200 107.149.115.70      1519

  egressConsistency = SPLIT_BY_DESIGN
  reason            : split observed on path(s) DIRECT,7897 and explained by: clash rule: GEOIP,CN,DIRECT |
                      clash catch-all: MATCH,PROXY | ipv4 default route points at tunnel utun119 (metric 0)
  evidence time     : 2026-11-28T05:06:48.3713694-08:00
```

## 1. 方法，以及这里的「直连」到底是什么

声明的外部目标（除此之外不访问任何地址，请求间隔至少 250 ms）：

| 类别 | 目标 | 用途 |
|---|---|---|
| 境外 | `https://api.ipify.org` | 纯文本回显来源地址 |
| 境外 | `https://www.cloudflare.com/cdn-cgi/trace` | 同一请求的 `ip=` / `loc=` / `colo=` |
| 国内 | `http://ip.3322.net` | 国内主机，纯文本回显 |

三条路径：

| 路径 | 探测方式 | 真正决定出口的是谁 |
|---|---|---|
| `DIRECT` | `curl --noproxy "*"` | 完全没有代理库参与，数据包按系统路由表走 |
| `7897` | `curl -x http://127.0.0.1:7897 --noproxy=` | Clash Verge / verge-mihomo，规则模式 |
| `11119` | `curl -x http://127.0.0.1:11119 --noproxy=` | `magicspeed.exe`，Clash 用作 `dialer-proxy` 的本机第一跳 |

**`curl` 不读 Windows 系统代理**。所以每一行只代表它 `via` 列写的那一跳；系统代理单独列出，因为浏览器跟的是它，不是 curl。`--noproxy` 的处理沿用共享的 diag-contract（在 `proxy_v4/tests/incidents/invoke-inc-checks.ps1` 里被实测过，不是假设）。

每类测量覆盖的范围要说清：

* 这里的 `DIRECT` **不等于**「从物理网卡出去」。IPv4 默认路由指向一个 TUN 接口（见第 4 节），所以 `DIRECT` 的含义是「交给 TUN 客户端，由它自己的规则再决定」。
* `7897` 的含义是「Clash 收到了请求并套用了规则」。
* `11119` 的含义是「厂商本机中转收到了请求」。代理会把所有请求转发到它自己的出口，所以它对国内目标和境外目标返回同一个地址——这是正常行为，不是异常。

## 2. 实际在运行的配置（只读采集）

Clash Verge 运行时配置 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml`，只取白名单字段，凭据行从不解析进任何报告：

| 字段 | 值 |
|---|---|
| `mode` | `rule` |
| `mixed-port` | `7897` |
| `ipv6` | `true`（但见下方 IPv6 说明） |
| `tun.enable` | `false` |
| `rules` | `GEOIP,CN,DIRECT`，随后 `MATCH,PROXY` |
| `proxy-groups` | `PROXY`（`select`），只有一个成员 |
| 代理条目（仅类型/服务器） | `http 127.0.0.1:11119`（第一跳）、`socks5 72.245.197.103:9506`，`dialer-proxy` 指向第一跳，`udp: false` |

关键观察：

* **Clash 自己的 TUN 是关闭的**；这台机器上的 TUN 不是 Clash 的。
* 承载静态 IP 的 SOCKS5 条目写着 `udp: false`。
* 7897 由 `verge-mihomo` 监听（PID 47056，已确认监听 127.0.0.1:7897）；11119 由 `magicspeed.exe` 监听（PID 60488）。
* 真正拥有 `utun119` 的是另一个 TUN 客户端：适配器描述 `sing-tun Tunnel`，ifIndex 12，MTU 9000，地址 10.99.0.1/30，网关 10.99.0.2。进程为 `StarSky.exe`（PID 9276）——本机只有它可能创建 `sing-tun` 适配器。

系统级转发事实（只读注册表 / netsh）：

| 项 | 值 |
|---|---|
| `HKCU\...\Internet Settings\ProxyEnable` | `1` |
| `...\ProxyServer` | `127.0.0.1:7897` |
| WinHTTP（`netsh winhttp show proxy`） | 直连（无代理） |
| `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `NO_PROXY` 等环境变量 | 全部不存在 |
| utun119 的 DNS | `10.99.0.2`（TUN 客户端自己的解析器） |
| WLAN 的 DNS | `202.115.39.9`、`202.115.39.6`（四川联通） |
| IPv6 全局地址 | 没有；也没有 `::/0` 路由 → IPv6 无可用路径 |

## 3. 实测出口表（同一次运行，逐目标时间戳）

| 路径 | 目标类别 | 目标 | 出口 IPv4 | CF `loc` | 观测时间 |
|---|---|---|---|---|---|
| DIRECT | 境外 | api.ipify.org | 107.149.115.70 | - | 05:06:49 |
| DIRECT | 境外 | cloudflare.com/cdn-cgi/trace | 107.149.115.70 | US | 05:06:52 |
| DIRECT | 国内 | ip.3322.net | 112.194.196.155 | - | 05:06:53 |
| 7897 | 境外 | api.ipify.org | 72.245.197.103 | - | 05:06:58 |
| 7897 | 境外 | cloudflare.com/cdn-cgi/trace | 72.245.197.103 | US | 05:07:01 |
| 7897 | 国内 | ip.3322.net | 112.194.196.155 | - | 05:07:02 |
| 11119 | 境外 | api.ipify.org | 107.149.115.70 | - | 05:07:05 |
| 11119 | 境外 | cloudflare.com/cdn-cgi/trace | 107.149.115.70 | US | 05:07:07 |
| 11119 | 国内 | ip.3322.net | 107.149.115.70 | - | 05:07:09 |

同一时段三条路径的连通性健康度（`connectivity-matrix.ps1`，每目标 2 次采样，`-ForceIPv4`），用来排除「出口数字是抖动导致的」：

| 路径 | api.ipify.org | ip.3322.net | 结果 |
|---|---|---|---|
| DIRECT | 2/2，p50 2644 ms | 2/2，p50 95 ms | 4/4 |
| 7897 | 2/2，p50 3689 ms | 2/2，p50 88 ms | 4/4 |
| 11119 | 2/2，p50 1808 ms | 2/2，p50 1403 ms | 4/4 |

与用户上传的检测截图交叉核对（截图是用户的现场观测，不是本次运行产生的）：

| 截图数值 | 本次实测 | 是否吻合 |
|---|---|---|
| 国内 112.194.196.155（中国联通） | DIRECT 与 7897 的国内出口相同 | 吻合 |
| Cloudflare / Claude HTTPS 出口 72.245.197.103 | 7897 境外出口相同 | 吻合 |
| WebRTC UDP 出口 107.149.115.70 | UDP/STUN 相同（见 WEBRTC-UDP.md） | 吻合 |
| DNS 出口 162.158.165.227（Cloudflare） | 递归解析器出口实测 162.158.165.217，Cloudflare US，同一 /24 | 吻合（不同 anycast 实例） |

## 4. 接口 / 路由优先级：为什么这不是「两张网卡的分流」

### 4.1 原始优先级数据

`netsh interface ipv4 show interfaces`：

```
Idx     Met         MTU          State                Name
  1          75  4294967295  connected     Loopback Pseudo-Interface 1
 18           5        1500  disconnected  以太网
 12           0        9000  connected     utun119
  7          45        1500  connected     WLAN
 56        5000        1500  connected     vEthernet (WSL (Hyper-V firewall))
```

`route print -4` 中仅有的两条默认路由：

```
Network Destination        Netmask          Gateway       Interface  Metric
          0.0.0.0          0.0.0.0   10.133.167.254   10.133.162.234     45
          0.0.0.0          0.0.0.0        10.99.0.2        10.99.0.1      0
```

`Get-NetIPInterface -AddressFamily IPv4`：utun119 度量 0，WLAN 度量 45，WSL 5000，loopback 75。`Get-NetRoute` 显示两条默认路由的路由度量都是 0，因此总度量是 0（TUN）对 45（WLAN）。

Windows 取总度量最小者，即 utun119，用于所有没有更具体路由的目的地。用 `Find-NetRoute` 实测：

| 目的地 | 实际选中的接口 |
|---|---|
| 112.194.196.155（国内公网） | utun119 |
| 107.149.115.70 / 72.245.197.103 | utun119 |
| 1.1.1.1、223.5.5.5 | utun119 |
| 10.133.167.254（物理网关） | WLAN |

也就是说，在 Windows 的 IP 层**根本不存在**国内/境外路由分流：只有本地子网（10.133.160.0/21，on-link，度量 301）留在 WLAN，其余全部进入 TUN。

### 4.2 所以正确的解释

分流发生在路由表之上的一层：

1. Windows 把所有境外/公网 IPv4 流量送进 `utun119`；
2. TUN 客户端（StarSky）逐流判断，然后：
   - **直连**：经物理网卡发出（源 10.133.162.234 → ISP NAT 112.194.196.155）；
   - **走自己的隧道**：出口 107.149.115.70；
3. 另外，任何使用系统代理的应用（浏览器就是）把 HTTP(S) 交给 7897 的 Clash。Clash 套用 `GEOIP,CN,DIRECT`（国内 → 它自己的 DIRECT 拨号，同样落进 TUN 客户端，再从物理线路出去）和 `MATCH,PROXY`（境外 → 经本机第一跳 11119 到 SOCKS5 72.245.197.103）。

常说的「国内走物理网卡、境外走 TUN」在**出口**上是对的，在**机制**上是错的：数据包是先进 TUN，再由 TUN 客户端重新发出后才会到物理网卡。本机存在两个独立的决策点，它们共同产生了第 3 节的表：

| 行 | 决策点 | 起作用的规则 |
|---|---|---|
| DIRECT 国内 → 112.194.196.155 | TUN 客户端 | 它自己的国内/直连规则集（本机不可读，见未验证） |
| DIRECT 境外 → 107.149.115.70 | TUN 客户端 | 它自己的兜底代理规则 |
| 7897 国内 → 112.194.196.155 | Clash，然后 TUN 客户端 | `GEOIP,CN,DIRECT` |
| 7897 境外 → 72.245.197.103 | Clash | `MATCH,PROXY` → SOCKS5 静态 IP |
| 11119 任意 → 107.149.115.70 | `magicspeed.exe` | 它是纯转发代理（不分流） |

第一跳和 TUN 出口共用 107.149.115.70。较可能的机制是二者属于同一条厂商隧道，但 TUN 客户端的配置没有被读取，所以这一层属于推断而非已证（见第 7 节）。

## 5. 若要「全部走静态 IP」，代价是什么（仅分析，未实施）

「全部走静态 IP」不是改一行能达成的，因为有两个决策点和一个协议缺口：

1. **Clash 规则**：去掉 `GEOIP,CN,DIRECT`（或改用 Global 模式）会让 Clash 把国内流量也送进 `PROXY`。改动位置是生成出来的 `clash-verge.yaml` 的 `rules:`，或重新生成它的 Verge 配置档案。
2. **TUN 客户端规则**：即使 Clash 全量代理，**连到 SOCKS5 服务器的那条连接本身**仍要进 `utun119`，所以 TUN 客户端依旧决定它怎么出去。要彻底切换必须同时改 TUN 客户端规则——在 Clash 之外，也在本仓库之外。
3. **UDP 缺口**：静态 IP 条目是 `socks5 ... udp: false`，UDP（QUIC、WebRTC、DNS-over-UDP）今天无法经由静态 IP；强行如此只会丢弃或回落到直连，即 UDP 仍从 107.149.115.70 出去。WEBRTC-UDP.md 就是这条的实测。
4. **DNS**：系统解析器是 TUN 的 10.99.0.2，它经 Cloudflare 解析（实测解析器出口 162.158.165.217）。本地解析并未在使用，所以「全部走静态 IP」还需要单独决定 DNS，否则域名仍由当前解析器解析。

### 已实测的代价

| 维度 | 现状 | 若全部改走 72.245.197.103 | 证据 |
|---|---|---|---|
| 国内延迟 | 到 ip.3322.net p50 88-95 ms | 同一个请求经 7897 的境外目标已需 p50 3689-5767 ms；被强制走同一跳的国内站点会继承这个双跳开销 | 上文 connectivity-matrix p50 |
| 境外延迟 | p50 1434-2926 ms（DIRECT）/ 3689-5767 ms（7897） | 不改善，甚至更差（国内流量多一跳） | path-report 的 `ms` 列 |
| 可用性 | 代理故障时国内流量不受影响 | SOCKS5 或第一跳一挂，**全部**中断，包括本地管理页与系统更新 | `7897 → 11119 → 72.245.197.103` 双跳 |
| 国内服务 | 正常 | 境外 IP 风控：银行/支付/政务类站点、部分 CDN 与视频平台会地域限制或要求额外验证 | 本文未测（需真实账号） |
| CDN 就近性 | 国内 CDN 边缘 | 目标/CDN 看到美国来源，国内边缘可能被降级 | 由 `loc=US` 推断 |
| UDP/WebRTC | 不受代理影响 | 仍无法使用静态 IP（`udp: false`） | 已实测，见 WEBRTC-UDP.md |

以上改动一项都没有实施；`proxy_v4/tools/path-report.ps1` 只读。

## 6. 本次改动新增的工具

`proxy_v4/tools/path-report.ps1`（只读，复用 `diag-contract.ps1` v2 的 `-CaptureBody`，不另写一套 curl 探测）：

* 只探测它声明的 `-ForeignTargets` / `-DomesticTargets`，串行、间隔 ≥250 ms、强制 IPv4；
* 每行给出：路径、`via`（DIRECT/PROXY）、脱敏后的代理端点、transport、HTTP 状态、出口 IP、Cloudflare `loc`、耗时、时间戳；
* 只读采集决定因素：默认路由 + 接口度量 + TUN 识别、运行中的 Clash 配置（仅白名单字段）、Windows 系统代理设置；
* 只输出一条结论：`egressConsistency = CONSISTENT | SPLIT_BY_DESIGN | INCONSISTENT_UNKNOWN`，并附理由与逐目标证据清单；
* 退出码：`0` 所有计划探测都取到出口 IP，`2` 部分，`3` 完全没测到。

`diag-contract.ps1` 的改动是增量且可选：`-CaptureBody`（默认关闭）最多保留 `-MaxBodyBytes` 的响应体到 `.body`，版本 1 → 2；不请求时 `.body` 为 `$null`。`cab-doctor.ps1` 与 `connectivity-matrix.ps1` 的行为不变；改动后重跑了既有事件回归套件（10/10 通过）与新增的本地工具套件（6/6 通过）。

复现：

```powershell
cd proxy_v4\tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\path-report.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\path-report.ps1 -Json
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '.\connectivity-matrix.ps1' -Direct -Targets @('https://api.ipify.org','http://ip.3322.net') -Samples 2 -ForceIPv4"
cd ..\tests\tools; powershell -NoProfile -ExecutionPolicy Bypass -File .\invoke-tool-checks.ps1
```

## 7. 未验证 / 未覆盖

* TUN 客户端（StarSky）自己的配置与规则没有读取：`utun119` 内「国内直连 / 境外隧道」的分流是**由效果测出来的**，不是由配置证实的。`StarSky.exe` 与 `utun119` 的对应关系由适配器描述（`sing-tun Tunnel`）和进程列表推断。
* TUN 出口与 11119 出口同为 107.149.115.70 的原因属于推断（同一条厂商隧道），未打开任何配置证明。
* 国内回显目标只有 `ip.3322.net` 一个可用。选点时 `myip.ipip.net` 超时（curl 28），`ip.chinaz.com/getip.aspx` 返回 404/301，因此没有第二个国内回显可交叉确认。
* IPv6 未测（本机无全局 IPv6 地址、无 `::/0` 路由）。
* 既不走系统代理、也不走 TUN 的应用层路径（例如绑定到 WLAN 网卡的进程）未测。
* 延迟是 2 次采样的单次 p50，只表明量级，不是性能基线。
* 本文不判定当前分流是否「合理」或是否为相关服务商允许，这属于操作者决策。
