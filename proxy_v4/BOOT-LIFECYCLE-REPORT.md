# BOOT-LIFECYCLE-REPORT

## 已确认的环境事实

- Clash Verge 登录任务：`MSFT_TaskLogonTrigger`，`MultipleInstances: Parallel`，`RunLevel: Limited`，用户上下文。
- `Parallel` 允许重复实例 → 与已知的启动竞争问题相关。

## 现状风险

登录时 StarSky 可能尚未加速 → 第一跳不可用 → `resilient` 档回落 DIRECT，出口变为本地 ISP。
`state-v4.ps1` 能检测该状态（DEGRADED + 原因），但**不会静默改配置**。

## 验证状态

5 次冷启动 / 5 次重启 / 5 次睡眠 / 5 次 Wi-Fi 重连：**全部 PENDING**（需用户配合真实重启与断网）。

## 建议（待批准，未执行）

1. 把 Clash Verge 登录任务的 `MultipleInstances` 改为 `IgnoreNew`；
2. 新增**只读**登录健康检查任务：运行 `state-v4.ps1 -Json`，异常时弹出通知（不修改任何设置）；
3. 不要在登录时自动拉起 StarSky（会引入未授权的高权限持久化与竞态）。