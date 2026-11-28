# RecoveryResult

Desktop、CLI 和 Skill 使用同一组字段判断隔离恢复。事务退出码单独出现时不是成功。

完整成功必须同时为真：

| 字段 | 这次场景 |
| --- | --- |
| `ScriptStarted` | 脚本已启动 |
| `Cancelled` | false |
| `TimedOut` | false |
| `ProcessExit` | 0，这是包装进程，不是事务码 |
| `TransactionExit` | 等于 `ExpectedTransactionExit`。当前用户关闭场景是 32 |
| `ProfileRestored` | 隔离配置哈希与快照一致 |
| `WritesMatch` | 写入包含 `enabled=0`，并且没有 `enabled=1` |
| `JournalClear` | 没有残留事务日志 |
| `LiveUnchanged` | 当前用户的 `ProxyEnable` 和 `ProxyServer` 未变 |

`Isolation` 固定说明 `V4_TEST_MODE` 是进程内逻辑隔离，不是操作系统沙箱。CLI 只在 `CompleteSuccess` 为真时返回 0，否则返回 2。
