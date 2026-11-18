# F12 — RUNTIME_STATE_MISMATCH（只读诊断）

时间：2026-11-18T06:10–06:12（America/Los_Angeles）
结论：**A + C 的组合，属 F11 应急恢复后的预期状态 + UI/实际不一致；未发现 E（V6 测试再次污染）或新的未授权修改。**

## 1. 实际系统状态（只读）
| 项 | 值 |
|---|---|
| HKCU ProxyEnable | **0（关闭）** |
| HKCU ProxyServer | 127.0.0.1:7897（保留） |
| HKCU AutoConfigURL | 空 |
| ProxyOverride | 标准本地绕过列表 |
| WinHTTP | Direct access（无代理） |
| Clash Verge | PID 38928，04:40:35 启动 |
| verge-mihomo | PID 8216，04:40:36 启动 |
| StarSky | PID 27788，11-17 20:54:16 启动 |
| 7897 监听 | PID 8216（verge-mihomo） |
| 11119 监听 | PID 7268（StarSky 首跳） |

## 2. UI 与实际
Clash Verge 的 `verge.yaml` 仍保存：
- `enable_system_proxy: true`
- `enable_proxy_guard: false`
- `proxy_host: 127.0.0.1`
- `verge_mixed_port: 7897`

因此 UI 依据自己的配置显示“系统代理已开启”，但真实 HKCU 是关闭的。UI 与真实状态不一致，属 **C**。

## 3. 实际流量路径
- 直连（绕过系统代理）出口：**54.202.22.253**（StarSky 路径）。
- 经 127.0.0.1:7897 出口：**72.245.197.103**（NexIP/V4 静态链）。
- 说明 Clash 链路本身可用；浏览器因 ProxyEnable=0 没走 Clash，所以 Clash 近 10 分钟几乎无流量、IP 信息显示 StarSky 出口。UI 的“节点延迟 332ms”只证明测速请求有响应，不证明浏览器在用该节点。

## 4. 与 F11 的关系
05:35 为恢复上网执行了 `ProxyEnable=0`（系统代理关闭），这是 F11 的应急状态。当前 HKCU 仍是该值，说明没有再次被覆盖（非 B/E）。V6 测试运行前后 HKCU/WinHTTP 一致（FT21 + final 运行记录）。未发现新的测试污染。

## 5. 状态检测修复
`Get-V4State` 现在读取 UI 的 `enable_system_proxy`（只读）并与真实 HKCU 比较：
- HTTP 状态输出新增 `uiSystemProxy`；
- UI 与 HKCU 不一致时报告额外 reason，并降为 DEGRADED；
- 不再用 UI 或节点测速单条件判 HEALTHY。
测试：`INF-F12-01`。

## 6. 处理建议
- 当前保持 `ProxyEnable=0`，所有站点可用；不自动改回，避免中断。
- 若要让浏览器实际走 V4 静态链：需要用户确认 B 方案（国内直连规则 + 重新开启系统代理），并在开启前验证百度/Google；开启后 UI、HKCU、实际出口三者应一致。
- 若要仅消除 UI 误导：在 Clash Verge 中把“系统代理”开关关闭（只改 UI/配置，不动 HKCU），但这属于用户操作，未执行。
