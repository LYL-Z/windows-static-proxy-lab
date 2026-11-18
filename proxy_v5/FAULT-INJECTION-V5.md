# FAULT-INJECTION-V5

## 既有结果（V4，真实执行）
FT01–FT10、FT12、FT13、FT15 = **13/13 符合预期**（`proxy_v4/evidence/fault-injection-v4.json`）。

## 本轮复核的覆盖缺口
| 场景 | 状态 | 说明 |
|---|---|---|
| FT11 磁盘写入失败 | **NOT_TESTED** | 未构造满盘 |
| FT14 日志写入失败 | **NOT_TESTED** | 未构造只读日志目标 |
| 回滚中途二次故障 | **NOT_TESTED** | 需专门构造 |
| 依赖启动延迟/状态变化 | **NOT_TESTED** | 需 mock 依赖（StarSky 无法在隔离环境模拟） |
| 真实网络中断 | **NOT_TESTED** | 需用户确认 |

**结论**：13/13 ≠ 覆盖齐全。测试数量不等于覆盖质量。