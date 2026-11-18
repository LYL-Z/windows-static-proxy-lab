# UPSTREAM-RESEARCH-V5

| 对象 | 事实 | 结论 |
|---|---|---|
| `6273552` | `docs(adr): decide proxy-chain persistence direction (#8278)`，2026-10-29 | 文档，非修复 |
| `150bfae` | `fix(proxy): persist manual chains and verify connected state`，2026-11-03T15:10Z | **真修复** |
| v2.5.10 发布 | 2026-11-03T10:04Z | 早于修复 5 小时 |
| compare | `v2.5.10...150bfae` = ahead 13 / behind 0 | **修复不在 2.5.10** |
| #7012 重启后链式失效 | open | **本机受影响** |
| #8593 系统代理开关回退 | open，v2.5.10 | **与本项目设计直接冲突** |
| #8639 系统代理自动关闭 | closed（报告者关闭） | 同类现象 |
| #8480 首次启动 15s 超时 | open | 45s 等待可覆盖 |
| #6670 开机自动开系统代理 | open | 历史同类 |

**行动建议**：升级到包含 `150bfae` 的版本可解 #7012，但 `#8593` 未修，且升级需隔离验证——**本轮不自动升级**。