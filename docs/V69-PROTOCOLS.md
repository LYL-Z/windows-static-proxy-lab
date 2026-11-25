# DNS、IPv6、WebRTC 与浏览器站点数据

下列结果来自隔离目录里的真实进程。测试端点在本机，DNS 使用随机的 `.invalid` 名称，ICE 使用本机 STUN 服务和同一 Chrome 页中的两个对端。公网 NAT、真实通话及生产代理故障窗口均需另外验收。

## 如何复验

在 Windows 上准备 Python 3.9+、Node.js、系统自带的 curl.exe 和 Chrome。在仓库根目录运行：

```powershell
python .\proxy_v6\tests\repro\V69Protocols.py
```

Chrome 默认从常见安装位置发现，也可用 `--chrome` 指定程序。工具为隔离浏览器新建临时资料目录，关闭后移除。测试结果只记录计数、候选类型、传输协议、挑战是否匹配、Winsock 错误及进程退出码。`python .\proxy_v6\tests\repro\V69Protocols.py --self-test` 只检查结果分类，不打开浏览器。退出码 0 表示脚本所列局部断言通过，1 表示 DNS、浏览器或站点数据断言失败，2 表示 Chrome 不可用或 IPv6 回环交换没有通过。超时、路径未知和 `UNKNOWN` 都不能证明防火墙已经拦截。`BLOCKED` 只表示套接字收到明确的拒绝访问，并且接收端没有收到数据。

## 实测与证据边界

DNS、WebRTC 和站点数据仍是 2026-11-23 的接收端记录。IPv6 分类在 2026-11-24 用同一脚本的新版本重测，没有改动系统代理或防火墙。

同一台机器有三条已启用的出站阻止规则，名称以 `codex_sandbox_offline_block_` 开头，作用于任何程序。回环规则的远端地址包含 `127.0.0.0/255.0.0.0` 和 `::/127`。重测之后，IPv4 回环连接成功，经 IPv4 代理访问百度和 GitHub 仍返回 200。这些规则的地址范围覆盖 `::1`，但现有证据还不能确定它们就是 10013 的来源。本轮没有删除或停用任何规则。

| 路径 | 发起端、接收端及结果 |
| --- | --- |
| 显式 IPv4 DNS/UDP | 独立 Node 解析进程向一次性测试 DNS 服务器发送 A 查询，服务器实际收到 1 次，客户端收到预期的回环地址。另一个唯一名称由服务器返回 NXDOMAIN，客户端报告 ENOTFOUND、退出 2。两个断言均 PASS。 |
| 代理侧 DNS | curl 向测试 HTTP 代理发送绝对 URI。代理遇到指定的唯一名称时才调用受控解析器。DNS、代理和 HTTP 源站各命中 1 次，curl 返回对应的随机挑战。PASS。此实验验证一次代理侧解析，无法排除其他进程同时解析域名。 |
| Windows 系统 DNS、浏览器 DoH 和缓存 | 生产默认解析器实际目的地、Chrome DoH 协商/回退、缓存命中均 NOT_TESTED。这里没有刷新系统缓存。实验使用唯一名称、零 TTL 和新的解析进程，避免复用旧答案。要证明生产路径，需要以自有域名的唯一子域配合权威端及预期递归服务的查询证据，并在客户端区分缓存、普通 DNS 和加密传输。仅凭解析成功无法判定递归路径。参见 [Chrome 的 DoH 模式](https://chromeenterprise.google/intl/en_ca/policies/dns-over-https-mode/)。 |
| IPv6 TCP | curl 对 `[::1]` 的 HTTP 测试退出 7，接收端收件数为 0。随后的 Python 连接得到 Winsock 10013（拒绝访问）。分类为 BLOCKED。拒绝来自哪一个过滤组件仍未知，因此这不是已确认的网络失败关闭。 |
| IPv6 UDP | Python 向已绑定的 `[::1]` 回环服务发送挑战，两秒内没有回包，接收端收件数为 0，客户端超时退出 4。没有收到明确的拒绝错误，分类为 UNKNOWN。 |
| IPv6 公网快照 | 同一时刻回环地址存在，全局单播地址 0 个，IPv6 默认路由 0 条。这只说明当时没有现成的公网 IPv6 出口，不表示以后不会出现，也不能代替代理路径验收。wintun 驱动正在运行，同时有一个描述为 sing-tun 的适配器处于连接状态。Clash 保存配置中的 tun 开关为关闭。适配器归属进程未绑定。 |
| Chrome 默认 WebRTC | 两个对端都收集到 host 与 srflx UDP 候选。独立 STUN 服务实际响应 Chrome，DataChannel 接收方收到随机挑战，发送方收到对应 ACK，浏览器统计中选中 UDP。此样本的应用数据传输 PASS。STUN 见 [RFC 8489](https://www.rfc-editor.org/rfc/rfc8489.html)，ICE 见 [RFC 8445](https://www.rfc-editor.org/info/rfc8445/)。 |
| Chrome 限制非代理 UDP 的实验 | 第二个一次性 Chrome 仅对该进程启用 IP handling 测试选项。两个对端均完成收集且候选数为零，STUN 服务收到该浏览器的请求数为零，5.5 秒窗口内未建立数据通道。每轮浏览器启动前后，独立 UDP 客户端都核对了 STUN 回包中的事务号与映射端口。该受限实验的预期观测 PASS；UDP 经代理、OS 级 UDP 阻断、TURN 中继和视频通话仍为 NOT_TESTED。 |

实验中使用的 HTTP 代理只接收测试请求，不提供 TURN 或 UDP 转发。默认与限制两组结果说明，这个选项可能影响需要实时通信的功能；连接能力还取决于代理是否支持相关协议、是否有可达的 TURN 服务等。需要实测企业策略时，应在隔离机器查看策略实际生效状态并复测通话。以上 Chrome 命令行仅对临时浏览器有效。[Chromium 官方策略定义](https://chromium.googlesource.com/chromium/src/%2B/main/components/policy/resources/templates/policy_definitions/WebRtc/WebRtcIPHandling.yaml)

## 管理站点数据

### 单独复测 DoH 与客户端缓存

在有 Python、`cryptography` 和 `dnspython[doh]` 2.7.x 的测试环境中，运行 `python proxy_v6/tests/repro/V69DohCache.py`。受控 HTTPS 解析器绑定 IPv4 回环。随机测试名位于 `.invalid`，证书信任仅限测试客户端。不受信任的证书被拒绝，接收端记录零次 HTTP 请求。信任测试证书后，冷查询、同一解析器再次查询、仅清空该解析器缓存后三次均收到预期 A 记录，服务端的 TLS 请求增量依次为 1、0、1。这样可以区分“已有缓存答案”与“确实向受控解析器查询”。浏览器内建 DoH 和系统默认解析器仍需独立观测。

## 管理站点数据的操作

先确定 Chrome 个人资料、网站域名、数据类别与时间范围。删除登录 Cookie 可能退出账号，删除站点存储可能丢失离线内容或草稿，重置权限后网站可能再次询问。缓存和媒体权限分别管理。删除通常无法撤销，存在重要会话或未同步草稿时可取消。

在目标 Chrome 个人资料中，打开**设置 → 隐私和安全 → 第三方 Cookie → 查看所有网站数据和权限**，搜索并核对域名，再确认删除。仅需调整摄像头、麦克风或通知时，在该站点的权限页单项修改。需要移除缓存时，在“删除浏览数据”核对范围，选择“缓存的图片和文件”；这个对话框按时间和资料范围生效，可能涉及其他网站。保留希望继续使用的其他数据项。不要向诊断人员提供 Cookie、密码或登录令牌。[Chrome 官方单站点操作说明](https://support.google.com/chrome/answer/95647?hl=en)

隔离验收在临时资料中的两个不同主机各建立一个合成 Cookie 和一条 localStorage 记录。在选定主机返回 Clear-Site-Data 后，重新启动同一临时资料验证，该主机的两个标记消失，对照主机的两个标记仍在。两项验证均 PASS。缓存、权限和 Chrome 设置界面的人工删除流程没有在此用例中验收；真实个人资料的清理需用户指定范围。

Adobe 已在 2020 年底结束 Flash Player 支持。本次只探测传统 SharedObjects 目录及本机六个常见 Chrome 资料下的旧 Pepper Flash 目录是否存在，均未找到对应目录。自定义安装位置和其他 Windows 用户仍未知。此项没有读取真实 Cookie 或 Flash 文件内容。移除浏览数据不会抹去设备特征或服务端保存的账号历史。[Adobe Flash Player 生命周期说明](https://www.adobe.com/products/flashplayer/end-of-life.html)
