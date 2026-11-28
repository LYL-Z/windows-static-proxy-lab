# CHANGELOG

## V4.0 — 2026-11-18 03:45–04:05
新增：`lib\V4.ps1` 引擎（JSON 设置源 + DPAPI 凭据、锁、进程退出验证、一致性快照、原子写、owner 记录、状态机）、
`apply-v4.ps1`、`rollback-v4.ps1`、`state-v4.ps1`、`tests\faultinject-v4.ps1`、12 份交付文档。
关闭：M5/M6（不再解析 YAML）、M8（独立本地 profile）、M9（锁）、M10（退出验证）、M3（停机快照）、H4（所有权模型）。
验证：apply 全链路成功（exit 192.0.2.254）；state HEALTHY；故障注入 13/13。
未完成：生命周期 5+5+5+5、24h/72h、凭据轮换、V4 完整回滚往返、FT11/FT14。

## V3.0 — 2026-11-18 03:00–03:45
独立复审（5 HIGH/10 MEDIUM/15 LOW）；修复 H1/H2/H3/H5/M1/M2/M7/L12；UDP 与 TCP 出口分离结论；P0 凭据处置。

## V2.0 — 2026-11-18 02:00–02:35
事务式 apply/rollback/status；300 次验收；三窗口对照；连接复用 0.35s。

## V1.0 — 2026-11-17 23:50–2026-11-18 01:45
分阶段协议探测；1×RTT 关判定；dialer-proxy 双跳。