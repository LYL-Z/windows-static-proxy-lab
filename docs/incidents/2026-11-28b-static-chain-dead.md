# 事故记录：静态 IP 链路整体失效（2026-11-28 第二次）

> 状态：**静态 IP 不可用，已切回 StarSky 恢复上网**。
> 系统代理 = `127.0.0.1:11119`，出口 = `107.149.115.70`（StarSky 节点，**非**购买的静态 IP）。
> 前提：本记录是第一篇 `2026-11-28-browser-outage.md` 之后约 20 分钟的**再次失效**，成因不同。

## 1. 用户可见症状

| 现象 | 说明 |
|---|---|
| ChatGPT 网页上传图片失败：`Upload failed because of a network issue` | 页面与静态资源能加载，**XHR/POST 失败** |
| `ip.net.coffee` 显示 `未能自动检测 IP：Failed to fetch` | 页面自身的 API 请求失败，不是站点挂了 |
| Clash Verge 首页"IP 信息"：`获取 IP 信息失败: Error: Request cancelled` | Clash 自己向上游取值也失败 |
| 浏览器"能打开一部分、又打不开一部分" | 典型**间歇性/整体失败**，不是全部秒断 |

## 2. 量化测量（每站点 4 次，共 12 次）

| 路径 | 成功 / 失败 |
|---|---|
| `7897`（静态 IP 链路） | **0 / 12** |
| `11119`（StarSky 直连） | 8 / 12 |

```text
7897  chatgpt.com      (35) schannel: failed to receive handshake
7897  ip.net.coffee    (35) schannel: failed to receive handshake
7897  github.com       (35) schannel: failed to receive handshake
```

## 3. 排除"假失败"

Windows 的 curl 走 Schannel，会因**证书吊销检查不可达**报 `CRYPT_E_REVOCATION_OFFLINE`，浏览器不走这条路径。
用 `--ssl-no-revoke` 关闭吊销检查后复测：

| 路径 | chatgpt.com | google.com | ip.net.coffee |
|---|---|---|---|
| 7897 | 仍失败 | 仍失败 | 仍失败 |
| 11119 | **200** | **302** | **200** |

→ 7897 的失败**不是**吊销检查造成的假象。

## 4. 分阶段定位：断在哪一跳

```text
1) 第一跳 11119 TCP 监听         : True
2) 经第一跳访问普通网站           : 200          ← 第一跳自身健康
3) 经 7897 的明文 HTTP（SOCKS）  : curl: (52) Empty reply from server
4) 经 7897 的 HTTPS 出口         : 报错，拿不到 IP
5) 第一跳 CONNECT 到 NexIP:9506  : HTTP/1.1 200 Connection established
```

第 3 条决定性：**连明文 HTTP 都拿不到任何回应**，失败点在 SOCKS/上游，与 TLS 无关。
第 5 条说明：**TCP 层能连到 NexIP 的 9506**，但建立会话后没有 SOCKS 层回应——
与最早"从大陆直连时被接受 TCP 后立刻关闭"的现象一致，只是现在经 StarSky 也一样。

## 5. 处置

1. 系统代理 `7897` → `11119`（StarSky），立即恢复上网；
2. 验证：`baidu/google/chatgpt/ip.net.coffee/github` 全部 200/302，出口 `107.149.115.70`；
3. **未**修改任何 Clash/NexIP 配置，**未**删除凭据，**未**重装。

## 6. 根因判断（**未证实**，按可能性排序）

1. **来源 IP 不再被 NexIP 接受**：StarSky 换节点后出口变为 `107.149.115.70`（PEG TECH INC），不同于失败前的 `142.111.173.93`；
2. **NexIP 账号/实例侧问题**：到期、限流、被标记或临时封禁；
3. **商家线路变更**：接入地址/端口策略调整。

**最小区分实验（尚未执行）**：经第一跳向 `72.245.197.103:9506` 发 SOCKS5 问候，
看返回 `05 02`（服务正常，问题在认证/来源）还是直接断（来源被拒）。

## 7. 已知风险

- **Clash Verge 重启后可能把系统代理写回 `7897`**，浏览器会再次全挂；届时改回 `11119`。
- 当前出口是 StarSky 节点 IP，**不是**购买的静态 IP；"必须固定美国 IP"的用途当前不成立。

## 8. 与第一篇记录的关系

| 项 | 第一次（02:30） | 第二次（约 02:50） |
|---|---|---|
| 触发 | StarSky 核心重启，第一跳断开 | 第一跳正常，**NexIP 跳会话被丢弃** |
| 7897 表现 | 拨号失败 | 明文 HTTP 也 `Empty reply` |
| 恢复方式 | 等自愈 + 切回 7897 | 只能切 11119，静态 IP 未恢复 |