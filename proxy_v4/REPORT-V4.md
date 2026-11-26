# REPORT-V4 — 安全加固、配置完整性、生命周期可靠性

时间：2026-11-18 03:45–04:05 (America/Los_Angeles)
目录：C:\CAB-Lab\proxy_v4\（V1/V2/V3 全部保留）

## 0. 总评：**PARTIAL — 未达到正式发布 Gate**

核心缺陷已关闭并可复现验证；**生命周期（重启/睡眠/Wi-Fi）与 24h/72h 长稳未执行**，凭据未轮换。
按任务书 P11，不得宣布正式发布。

## 1. 本轮实际关闭的缺陷

| 缺陷 | V3 状态 | V4 做法 | 验证 |
|---|---|---|---|
| M5/M6 YAML 解析 | 手写正则，注释/锚点会解析错，甚至指向错服务器 | **彻底不再解析 YAML**：改为 `config\settings.json`（原生 JSON），一次性迁移后失效 | 迁移成功；`mihomo -t` 通过 |
| 凭据静态存储 | 明文 | **DPAPI 加密**存于 settings.json，仅生成时解密 | 文件内无可读密码 |
| M9 并发无锁 | 无锁 | `config\.lock`（含 PID、陈旧锁回收） | FT04/FT10 = 串行化 |
| M10 进程退出 | `Stop-Process` + sleep 2s | 停止后**验证 PID 消失 + 端口释放**，超时抛错 | FT06 观测到 pids 状态 |
| M3 快照竞争 | 边写边拷 | 快照前**先停应用**，哈希取自副本 | apply 日志：stopping → snapshot |
| M8 订阅覆盖 | 直接覆盖订阅 profile | 注册**独立本地 profile `v4-managed`**，订阅文件不动 | profiles.yaml 注入 + 启动后链路仍正确 |
| H4 代理所有权 | 无模型 | `config\owner.json` 记录 owner/值/时间；state 报告实际所有者 | state 显示 owner=clash |
| H1 原生 stderr | 已修 | V4 全部 curl 调用沿用局部 EAP 保护 | 复用验证 |

## 2. 实测结果

```
apply-v4 -DryRun   -> staged configs pass mihomo -t
apply-v4           -> snapshot -> 注册独立 profile -> 原子替换 -> 启动 -> chain verified: 192.0.2.254
state-v4           -> STATE HEALTHY / NEXIP / firstHopOk True / exit 192.0.2.254
                      systemProxy 127.0.0.1:7897 (owner record: clash)
                      profile marker True / runtime marker(chain signature) True
faultinject-v4     -> 13/13 场景符合预期
```

已知瑕疵（如实记录）：故障注入台在 13/13 全通过时**仍返回退出码 1**（`exit $(if...)` 的表达式取值问题），未修；以输出与 JSON 为准。

## 3. 未完成项

| 项 | 状态 | 原因 |
|---|---|---|
| 5 次冷启动 / 5 次重启 | **PENDING** | 需真实重启电脑，须用户配合 |
| 5 次睡眠唤醒 / 5 次 Wi-Fi 重连 | **PENDING** | 会中断当前会话，须用户授权 |
| 24h / 72h 长稳 | **PENDING** | 时间不可压缩 |
| 凭据轮换 | **BLOCKED** | 须用户在 NexIP 后台操作 |
| FT11 磁盘满 / FT14 日志写失败 | **NOT_TESTED** | 需要满盘或只读日志目标，未构造 |
| P1 官方资料研究 | **PARTIAL** | 已委派独立检索（Clash Verge issues #7012/#8639/#8480/#7696/#7942、Mihomo 文档、MS Learn、Chromium、Cloudflare、reCAPTCHA），截至本报告撰写时结果尚未回收 |

## 4. 需要用户批准的系统变更（未执行）

Clash Verge 的登录任务当前为 `MultipleInstances: Parallel`（重复实例风险）。建议改为 `IgnoreNew`。
**未修改**：属系统任务计划变更，按任务书须先提交影响分析并获批。

另建议新增（未注册）一个**只读**登录健康检查任务：运行 `state-v4.ps1` 并在异常时通知，不修改任何网络设置。
## 5. P1 官方资料研究（已回收，含对本文的修正）

- **#7012（OPEN）**：链式代理在重启后失效，社区归因于运行时文件被 `profiles\*` 重新生成覆盖 → **必须写进源 profile**。V4 正是此做法，反证 V1/V2 的重启失效不是偶然。
- **#8639（CLOSED，v2.5.10）**：系统代理会被 guard 关掉、托盘仍显示开启。**这是对"Clash 拥有系统代理"设计的现实威胁**；V4 以"每次读真实 HKCU 值 + owner 比对"缓解，不信任 UI。
- **mihomo 不拒绝未知顶层键**（源码证据），此前流传的 `field … not found in type conf.RawConfig` 与 v1.19.x 矛盾。
- **UDP 机制已被源码确认**：`udp:false` 的节点在规则匹配中**被跳过**，规则链走完落到 DIRECT —— 与实测（UDP 出口 142.111.173.93 = 直连经 StarSky）一致。V3 的说法正确但机理表述不够准确，此处更正。
- **M8**：官方推荐"每订阅节点编辑 / 扩展配置"，V4 的"自建本地 profile + 改 profiles.yaml"可用但非官方路径，记为技术债。
- 检测指标：Bot Score 为**每请求 1–99、细粒度仅企业版**；Turnstile 成功只证明 token 被兑换；reCAPTCHA v3 为**每请求/每 action** 分数。**第三方 89/100 不是 Cloudflare 分数。**
- 详见 `P1-OFFICIAL-RESEARCH.md`。