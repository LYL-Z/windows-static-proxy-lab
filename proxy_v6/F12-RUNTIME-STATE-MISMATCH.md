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
- 经 127.0.0.1:7897 出口：**192.0.2.254**（NexIP/V4 静态链）。
- 说明 Clash 链路本身可用；浏览器因 ProxyEnable=0 没走 Clash，所以 Clash 近 10 分钟几乎无流量、IP 信息显示 StarSky 出口。UI 的“节点延迟 332ms”只证明测速请求有响应，不证明浏览器在用该节点。

## 4. 与 F11 的关系
05:35 为恢复上网执行了 `ProxyEnable=0`（系统代理关闭），这是 F11 的应急状态。当前 HKCU 仍是该值，说明没有再次被覆盖（非 B/E）。V6 测试运行前后 HKCU/WinHTTP 一致（FT21 + final 运行记录）。未发现新的测试污染。

## 5. 状态检测修复
`Get-V4State` 现在读取 UI 的 `enable_system_proxy`（只读）并与真实 HKCU 比较：
- 状态输出新增 `uiSystemProxy`；
- UI 与 HKCU 不一致时报告额外 reason；
- 在有 settings 且其他路径正常时降为 DEGRADED；
- 生产目录 `C:\CAB-Lab\proxy_v4\config\settings.json` **存在**（933B，DACL 尚未 protected）；**publish 仓库的 `proxy_v4\config` 没有 settings.json**。因此 V6 state 从 publish 运行会 FAILED（settings missing）；若部署到生产并指向生产配置，预期 DEGRADED + UI reason。当前生产仍是 baseline，没有 `uiSystemProxy` 输出。
- 不再用 UI 或节点测速单条件判 HEALTHY。
测试：`INF-F12-01`（有 settings 时 DEGRADED）、`INF-F12-02`（settings 缺失时 FAILED + UI reason，适用于 publish 路径）、`INF-F12-03`（verge.yaml true/false/missing）。F12 的“检测”不等于“恢复使用”或“用户验收”。

## 5b. 当前生产状态判定
- 从 HKCU/UI/进程/出口只读观测：**DEGRADED**（系统代理关闭、UI 显示开启、浏览器走 StarSky 直连；Clash 链可用但未被浏览器使用）。
- 不是 HEALTHY；也不是新的 FAILED 事故。
- 生产 baseline 脚本没有 V6 的 `uiSystemProxy` 字段；只有部署 V6 后，才能由生产脚本输出该诊断。

## 6. 处理建议
- 当前保持 `ProxyEnable=0`，所有站点可用；不自动改回，避免中断。
- 若要让浏览器实际走 V4 静态链：需要用户确认 B 方案（国内直连规则 + 重新开启系统代理），并在开启前验证百度/Google；开启后 UI、HKCU、实际出口三者应一致。
- 若要仅消除 UI 误导：在 Clash Verge 中把“系统代理”开关关闭（只改 UI/配置，不动 HKCU），但这属于用户操作，未执行。