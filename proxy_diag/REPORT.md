# NexIP 静态代理 —— 故障诊断与修复报告

- 时间：2026-11-18 01:06 → 01:45 (America/Los_Angeles)
- 机器：Windows 11 家庭中文版 (10.0.26300)，用户 `老黄之友\lenovo`（非管理员）
- 目标：NexIP 美国华盛顿原生静态 IP `192.0.2.254:9506`（HTTP/SOCKS5 同端口，用户名密码认证）
- 结论：**已修复并实测可用**；根因是「服务端只接受美国来源 IP 接入」+ Clash Verge 处于「直连」模式。

---

## 一、结论摘要（TL;DR）

| 项目 | 结果 |
|---|---|
| 真正根因 | NexIP 静态 IP 的接入网关对**中国大陆来源 IP**做「放行 TCP → 立即关闭会话」处理，不返回任何 SOCKS5/HTTP 字节；从美国来源 IP 接入则完全正常 |
| 第二问题 | Clash Verge 运行在 **直连(direct)** 模式，即使节点正常也不会走代理 |
| 非问题 | 密码/用户名错误、协议不匹配、本地防火墙、utun119 路由、DNS、端口隔离、StarSky 抢占端口——均已逐项排除 |
| 修复方式 | Mihomo **`dialer-proxy` 链式代理**：Clash → 本机 StarSky(127.0.0.1:11119) → 静态IP(9506) → 互联网 |
| 验收 | **20/20 成功（100%）**，全部出口 IP = `192.0.2.254`，连续 11.3 分钟；浏览器实测通过 |
| 回滚 | `rollback.ps1`（配置已全量备份） |

---

## 二、环境基线

```
适配器        : WLAN (Killer Wi-Fi 7 BE1750x) 10.133.161.125/21, 网关 10.133.167.254
公网出口(直连): 112.194.196.40  (AS4837 中国联通四川)  ← 修复前的实际出口
DNS           : 202.115.39.9 / 202.115.39.6
系统代理      : ProxyEnable=0（关闭），残留 ProxyServer=127.0.0.1:11119
WinHTTP       : Direct access (no proxy server)
环境变量代理  : 无（HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 均未设置）
hosts         : 无 72.245 / nexip 相关条目（有效条目 0 行）
防火墙        : Domain/Private/Public 全开；出站 Block 规则仅 3 条
                均属 DSH 沙箱自身(codex_sandbox_offline_*)，未拦截任何测试流量
虚拟网卡      : 修复前**无** TUN；测试期间 StarSky 开启后出现 utun119 (sing-tun/Wintun)
进程          : clash-verge 2.5.10 + verge-mihomo(v1.19.33) 监听 127.0.0.1:7897
                StarSky 1.0（当时为"未加速"的空闲状态，无监听端口）
```

---

## 三、诊断过程与证据

### 3.1 配置核对：完全正确
- 实际生效文件（由 `verge-mihomo.exe` 命令行确认）：`clash-verge.yaml`
- 商家面板显示：IP `192.0.2.254`，HTTP 端口 `9506`，SOCKS5 端口 `9506`，状态 **正常**，剩余 31 天，
  代理格式 `socks5://username:password@ip:port`
- 配置内用户名/密码与面板**逐字节一致**（用精确字符串比对验证，未在日志中输出明文）
- 结论：**地址、端口、账号密码、协议均无错误**

### 3.2 协议级分阶段探测（直连，无 TUN）

| 测试 | TCP 建连 | 结果 |
|---|---|---|
| 被动等待（不发任何字节） | OK ~250 ms | 服务器 **立即 FIN 关闭**，无数据 |
| SOCKS5 免认证问候 `05 01 00` | OK | 收到 EOF，**无 method 回复** |
| SOCKS5 用户名密码方法 `05 02 00 02` | OK | 连接被 **RST** |
| HTTP CONNECT（带/不带认证） | OK | 代理直接 **关闭连接**，无 `200/407` |
| TLS 直连 9506（是否 TLS 代理） | OK | `UNEXPECTED_EOF`，未进入 TLS 握手 |

### 3.3 关键判定：是谁关闭了连接？

| 探测 | connect 耗时 | 关闭到达 | 结论 |
|---|---|---|---|
| 不发数据、立即读 | 345 ms | **+251.5 ms** | 约 1×RTT |
| 不发数据、立即读（重复） | 303 ms | **+258.1 ms** | 约 1×RTT |
| 不发数据、等 1 s 再读 | 241 ms | +0.0 ms（FIN 已在缓冲区） | 关闭早已发生 |
| 发 1 字节 / 问候 / CRLF | ~250 ms | **+250 ms 后 RST** | 对端已半关闭 |

**RTT 约 240–260 ms（华盛顿 GTT 线路）→ 关闭恰好晚 1 个 RTT，说明 FIN 由美国远端主机发出；
若是本机 WFP/防火墙/虚拟网卡拦截，关闭应在 0–5 ms 内到达。**
连续 10 次复测：**10/10 全部被对端关闭**（connect ≈ 250 ms，关闭 ≈ +250 ms，字节数 0）。

### 3.4 对照实验：证明本地网络路径无问题

| 目标 | 结果 |
|---|---|
| `223.5.5.5:53` (TCP，非 443，空闲) | **保持打开 4 s** |
| `114.114.114.114:53` (TCP，空闲) | **保持打开 4 s** |
| `github.com:22` | 正常收到 SSH banner |
| `192.0.2.254:9506` | **+253 ms 被对端关闭** |
| 该 IP 的 80/443/8080/22/21/25… | 全部超时（仅 9506 放通） |

→ 本网络可以正常承载任意非 443 端口的 TCP 会话，因此 9506 的关闭不是校园网/运营商/防火墙造成；
同时"只有 9506 可达"说明我们访问的是商家真实接入主机（其防火墙 DROP 其它端口）。

### 3.5 商家面板自测
在商家控制台点击「测试」：**`请求超时，请稍后再试。` / `timeout of 30000ms exceeded`**
（此前你看到的 168.34ms 成功结果，在故障期间无法复现）

### 3.6 决定性对照：换成美国来源 IP 后全部正常
打开 StarSky（美国1 节点，出口 `142.111.173.93`）后，同一台机器、同一份配置：

```
1 TCP connect      OK   20.4 ms
2 recv method      OK   05 02        ← 服务器正常响应，要求用户名密码
3 send user/pass   OK   26 B (masked)
4 recv auth status OK   01 00        ← 认证通过
5 auth             OK   accepted
7 recv CONNECT rep OK   05 00 00 01
8 tunnel           OK   established
9 HTTPS via tunnel OK   HTTP/1.1 200 OK | 192.0.2.254   ← 出口 IP 正确
```

商家面板同一时刻自测也恢复为：**测试连接成功 171.95ms，出口 IP 192.0.2.254**。

---

## 四、根因

1. **主因（服务端准入限制）**：NexIP 静态 IP 接入端对中国大陆来源 IP 采取「TCP 三次握手放行 → 立即关闭会话」的策略，
   任何客户端都无法进入协议协商阶段。因此：
   - 不是密码错（**根本没走到认证**，一个认证字节都没发出）
   - 不是协议不匹配（SOCKS5/HTTP/TLS 三种开头完全同样的失败点）
   - 不是 Clash 的问题（Python 裸 socket 复现同样结果）
   - 不是端口错（9506 是唯一放通端口，且美国来源可正常完成握手）
2. **次要问题（客户端配置）**：Clash Verge 当时 `mode=direct`（直连），系统代理也处于关闭状态，
   所以即使节点可用，浏览器也不会走代理。
3. **历史现象解释**：你之前遇到的
   - `User was rejected by the SOCKS5 server (1 255)` → 服务器确实回了一个 `VER=1,STATUS=0xFF` 的认证拒绝
   - `Recv failure: Connection was reset` / `Proxy CONNECT aborted`
   属于同一条链路上的不同表现（来源 IP 变化/服务端策略切换），本质都是"未被允许接入"。

---

## 五、修复方案（已实施）

### 拓扑
```
应用 / 浏览器
   └─► Clash Verge 混合端口 127.0.0.1:7897   (mode: rule, tun: off)
         └─► 节点「美国-华盛顿-SOCKS5」 dialer-proxy = 「STAR-首跳」
               └─► StarSky 本机代理 127.0.0.1:11119   (美国1, 出口 142.111.173.93)
                     └─► NexIP 静态IP 192.0.2.254:9506 (SOCKS5 用户名密码)
                           └─► 互联网   (出口 = 192.0.2.254 ✔)
```

### 变更清单
| 文件 / 项目 | 变更 | 可回滚 |
|---|---|---|
| `profiles\LWMoQxn0PeIP.yaml` | 新增 `STAR-首跳` 节点；静态IP节点加 `dialer-proxy`；`mode: rule`；`mixed-port: 7897` | ✔ 备份 |
| `clash-verge.yaml`（运行时） | 同上 + `tun.enable: false` + `find-process-mode: off` + `tcp-concurrent: true` | ✔ 备份 |
| `config.yaml` | `mode: direct` → `mode: rule` | ✔ 备份 |
| `verge.yaml` | `enable_system_proxy: false → true`（由 Clash 自身接管系统代理） | ✔ 备份 |
| 系统代理 | `127.0.0.1:7897` | ✔ 备份 |

- **未改动**：StarSky 的任何设置、Windows Defender、防火墙、任何网络软件、路由表。
- **未关闭**任何安全功能。
- 备份目录：`C:\CAB-Lab\proxy_diag\backup\20261118-011610\`

### 操作方法（日常）
1. 先开 **StarSky** → 点「开始加速」（保持"加速中"，TUN 模式开/关均可，只要本地 11119 在监听）
2. 再开 **Clash Verge**（已设置为开机自启），确认首页：模式=**规则**，节点=`美国-华盛顿-SOCKS5`
3. 系统代理由 Clash 自动设置为 `127.0.0.1:7897`，浏览器直接可用
4. 需要临时不走代理：在 Clash 的 `PROXY` 组里切到 `DIRECT`

### 回滚
```powershell
powershell -ExecutionPolicy Bypass -File "C:\CAB-Lab\proxy_diag\rollback.ps1"
```
（还原全部 yaml + 关闭系统代理 + 重启 Clash Verge，回到 01:16 的原始状态）

### 重新应用
```powershell
powershell -ExecutionPolicy Bypass -File "C:\CAB-Lab\proxy_diag\apply-chain.ps1"
```
（幂等；会先检查 StarSky 11119 是否在监听，再写配置、校验、重启、改系统代理并验证出口 IP）

---

## 六、验收结果（实测）

| 验收项 | 要求 | 实测 | 结论 |
|---|---|---|---|
| Clash 配置加载 | 成功 | `mihomo -t` 两份配置均 `test is successful`，exit=0；重启后 API `mode=rule` | ✅ |
| 代理建立连接 | SOCKS5 或 HTTP 任一 | SOCKS5：认证通过 + CONNECT 成功 + TLS 成功 | ✅ |
| HTTPS 访问 | 正常 | `https://ipinfo.io/ip` 200；Google 204、Bing 200、API OpenAI 401(已到达) | ✅ |
| 出口 IP | 192.0.2.254 | **20/20 次全部为 192.0.2.254** | ✅ |
| 10 分钟 / 20 次 | 统计成功率与延迟 | **20/20 = 100%**，连续 **11.3 分钟**（01:24:02 → 01:35:17） | ✅ |
| 延迟 | 统计 | min 4,259 / p50 5,252 / avg 5,441 / max 7,823 ms（每次含完整 TLS 握手） | ⚠ 偏高，见下 |
| 浏览器 | 正常使用代理 | Chrome 打开 `ipinfo.io/ip` 显示 `192.0.2.254`（修复前后各验证一次） | ✅ |
| 原网络可恢复 | 可还原 | `rollback.ps1` 就绪；StarSky 未改动，仍正常（直连出口 142.111.173.93） | ✅ |
| 最终配置 | 给出 | 本报告 + `apply-chain.ps1` / `profile.WORKING.yaml` / `US-Static-fixed.yaml` | ✅ |

原始数据：`monitor_clash.jsonl`（20 行）。

---

## 七、已知限制与建议

1. **延迟偏高**：同端点对比 15 次——链式平均 **2.98 s**，仅经 StarSky 首跳平均 **1.79 s**；
   验收期 20 次完整 TLS 请求 p50 = 5.25 s（每次均为全新握手）。延迟测试 RTT ≈ 287–321 ms。
   `find-process-mode`、`tcp-concurrent`、DNS 缓存均已验证非瓶颈（关闭后无改善）。瓶颈在
   **StarSky 节点 + 美国住宅最后一公里**，属线路质量，本地无法再优化。
   → 建议：更换 StarSky 更快的节点/套餐后重测，或用一台更快的境外中转（任意 SOCKS5/HTTP 代理）替换 `STAR-首跳`。
2. **偶发 ~5 s 超时**：累计 58 次链式请求中 4 次失败（**约 7%**），失败几乎都落在恰好 5.000 s
   （`Empty reply from server` / 收不到 TLS 握手），重试即成功（曾连续 2 次失败后 5/5 立即恢复）。
   同端点仅经 StarSky 单跳时 15/15 无失败，判定为静态IP 路径抖动，而非配置问题。
3. **StarSky 必须保持"加速中"**：否则 `127.0.0.1:11119` 不在监听，链式代理首跳断开（`apply-chain.ps1` 会先检查）。
4. **HTTP 节点不通**：该端口实测只按 SOCKS5 工作（与商家 `socks5://` 格式一致），配置中已移除 HTTP 节点。
5. **Clash 的 TUN 必须保持关闭**：StarSky 已占用 utun119 作为默认路由，两者同时开 TUN 会冲突。

---

## 八、可选：向 NexIP 提交的技术说明

> 购买线路：`192.0.2.254:9506`（SOCKS5，美国华盛顿，原生静态IP），订单状态"正常"。
>
> 问题：从中国大陆（中国联通四川；出口 IP `112.194.196.x`）直连该接入地址时，
> **TCP 三次握手成功（约 250 ms，与华盛顿 RTT 一致），但服务器在约 1 个 RTT 后立即发送 FIN 关闭，
> 不返回任何协议字节**；无论客户端发送 SOCKS5 问候、HTTP CONNECT 或 TLS ClientHello，结果相同。
> 用裸 socket 分阶段测试复现：认证阶段从未到达（一个认证字节都未发出）。
>
> 对照：同一台机器、同一份凭据，改由美国来源 IP（`142.111.173.93`）接入时，
> SOCKS5 认证 `0x01 0x00` 通过、CONNECT 成功、HTTPS 出口 IP 正确显示 `192.0.2.254`；
> 商家后台"测试"按钮此时也显示 `测试连接成功 171.95ms`。
>
> 请确认：该线路是否限制来源 IP（仅允许境外/指定 IP 接入）？若为策略，请说明支持的国家/地区；
> 若不应限制，请检查该接入网关针对中国大陆来源的访问控制策略与实例健康状态。
> 另：故障期间后台"测试"按钮返回 `timeout of 30000ms exceeded`。

---

## 九、文件清单（`C:\CAB-Lab\proxy_diag\`）

| 文件 | 用途 |
|---|---|
| `REPORT.md` | 本报告 |
| `apply-chain.ps1` | 一键应用链式代理配置（幂等，含校验与出口IP验证） |
| `rollback.ps1` | 一键回滚到任务前状态 |
| `validate.ps1` | 20 次 / 10 分钟验收测试 |
| `monitor.py` | 全链路探测（TCP→SOCKS5→CONNECT→TLS→出口IP） |
| `socks5_probe.py` | 分阶段协议探测（含 HTTP CONNECT / TLS 判定） |
| `close_latency.py` | 判定"谁关闭了连接"（1×RTT 法） |
| `control_ports.py` | 路径对照实验 |
| `mihomo_api.ps1` | 通过命名管道访问 Mihomo API（只读为主） |
| `clash-verge.WORKING.yaml` / `profile.WORKING.yaml` / `US-Static-fixed.yaml` | 当前可用配置副本 |
| `monitor_clash.jsonl` | 20 次验收原始数据 |
| `backup\20261118-011610\` | 原始配置全量备份 + STATE-SNAPSHOT.json |
