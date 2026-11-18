# TEST-MATRIX — V6.0

最后更新：2026-11-18T04:55:00-08:00
状态：NOT_RUN / FAIL（复现缺陷）/ PASS（修复后）/ SKIPPED（必须记录原因）/ BLOCKED

## 1. 参数与状态

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| PARAM-01 | Repair + DryRun | exit 11，无生产写入 | NOT_RUN | — |
| PARAM-02 | Init + DryRun | exit 11，无 settings 写入 | NOT_RUN | — |
| PARAM-03 | Init + Repair | exit 11，无写入 | NOT_RUN | — |
| PARAM-04 | 缺失 settings | exit 11，无写入 | NOT_RUN | — |
| PARAM-05 | 非法 settings JSON | exit 11，不崩溃 | NOT_RUN | — |
| PARAM-06 | 非法 Mode 值 | 参数绑定失败，无写入 | NOT_RUN | — |
| PARAM-07 | DryRun 只读 | 不修改 appdata/settings/HKCU；仅声明式日志 | NOT_RUN | — |

## 2. 文件事务

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| TX-01 | 快照阶段失败 | 文件不变；应用进程状态还原；exit 非 0 | NOT_RUN | — |
| TX-02 | 第一次正式写入失败 | 文件不变；恢复执行；exit 非 0 | NOT_RUN | — |
| TX-03 | 第二次写入失败 | 前一次写入被回滚；文件哈希等于基线 | NOT_RUN | — |
| TX-04 | 第三次写入失败 | 前两次写入被回滚；文件哈希等于基线 | NOT_RUN | — |
| TX-05 | 首次写入成功后其他步骤失败 | 快照完整还原；系统代理还原 | NOT_RUN | — |
| TX-06 | 文件被占用 | 拒写、目标完好、临时文件清理 | NOT_RUN | — |
| TX-07 | 快照不完整/损坏 | 还原前拒绝，不覆盖现场 | NOT_RUN | — |
| TX-08 | 回滚中途再次失败 | 报告 40；已恢复项与失败项可区分；锁释放 | NOT_RUN | — |
| TX-09 | “磁盘空间不足” | 用注入写失败模拟，不真实填满磁盘 | NOT_RUN | — |
| TX-10 | 临时文件权限异常 | 失败可诊断，目标不受损 | NOT_RUN | — |
| TX-11 | 文件原本不存在 | 回滚删除新建文件，恢复“不存在”状态 | NOT_RUN | — |

## 3. 并发与锁

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| LOCK-01 | 两个事务同时执行 | 仅一个进入；另一个 exit 33 | NOT_RUN | — |
| LOCK-02 | 未获锁进程退出 | 不删除持有者的锁 | NOT_RUN | — |
| LOCK-03 | 其他进程持锁 | 超时拒绝，不写任何文件 | NOT_RUN | — |
| LOCK-04 | 锁持有者异常退出 | 陈旧锁可回收 | NOT_RUN | — |
| LOCK-05 | PID 复用 | 依据进程启动时间判陈旧 | NOT_RUN | — |
| LOCK-06 | 重复回滚 | 串行化且幂等 | NOT_RUN | — |
| LOCK-07 | 测试结束锁释放 | 无残留 .lock | NOT_RUN | — |
| LOCK-08 | Init 与其他事务竞争 | Init 不越过锁写 settings | NOT_RUN | — |

## 4. 日志与异常

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| LOG-01 | 日志目录不可写 | Start 失败不阻断主流程 | NOT_RUN | — |
| LOG-02 | 首次写日志失败 | 无异常逃逸 | NOT_RUN | — |
| LOG-03 | 异常处理阶段写日志失败 | 恢复仍执行 | NOT_RUN | — |
| LOG-04 | 回滚阶段写日志失败 | 恢复仍执行，exit 40 可保留 | NOT_RUN | — |
| LOG-05 | 证据文件输出失败 | 测试系统非零退出并明确报告 | NOT_RUN | — |
| LOG-06 | 错误码被异常覆盖 | 原始错误码保留到恢复结果 | NOT_RUN | — |

## 5. 数据完整性

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| DATA-01 | 无关配置保持不变 | 字节/哈希一致 | NOT_RUN | — |
| DATA-02 | 非目标 Profile 保持不变 | F08 七类用例全部通过 | NOT_RUN | — |
| DATA-03 | 文件存在/不存在状态恢复 | 含新建文件删除 | NOT_RUN | — |
| DATA-04 | 快照哈希一致 | 篡改被拒 | NOT_RUN | — |
| DATA-05 | 权限不被放宽 | ACL 仅当前用户/系统/管理员 | NOT_RUN | — |
| DATA-06 | 错误不误报成功 | exit code 与结果一致 | NOT_RUN | — |

## 6. 测试系统自验

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| META-01 | 全部有效测试通过 | exit 0 | NOT_RUN | — |
| META-02 | 任一必要测试失败 | 非零 | NOT_RUN | — |
| META-03 | 测试框架自身异常 | 非零 | NOT_RUN | — |
| META-04 | 零测试被执行 | 不得判通过 | NOT_RUN | — |
| META-05 | 测试被跳过 | 单独记录，不冒充通过 | NOT_RUN | — |
| META-06 | 证据写入失败 | 非零并明确报告 | NOT_RUN | — |
| META-07 | 失败结果不被后续成功覆盖 | 汇总含失败 | NOT_RUN | — |

## 7. 生命周期（隔离模拟）

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| LIFE-01 | 依赖组件未启动 | FAILED/DEGRADED，可解释 | NOT_RUN | — |
| LIFE-02 | 依赖启动延迟 | 等待后成功或超时明确 | NOT_RUN | — |
| LIFE-03 | 依赖进程退出 | 状态检测为 FAILED，不信任历史成功 | NOT_RUN | — |
| LIFE-04 | 配置文件损坏 | 状态脚本输出 FAILED，不崩溃 | NOT_RUN | — |
| LIFE-05 | 应用重复启动 | 已监听时不重复拉起 | NOT_RUN | — |
| LIFE-06 | 本地服务不可用 | firstHopOk=false | NOT_RUN | — |
| LIFE-07 | 用户主动退出 | 状态 FAILED/RAW | NOT_RUN | — |
| LIFE-08 | 配置被外部改变 | marker/hash 检测 | NOT_RUN | — |
| LIFE-09 | 配置与运行状态不一致 | DEGRADED + 具体原因 | NOT_RUN | — |

## 8. 安全

| ID | 场景 | 预期 | 状态 | 证据 |
|---|---|---|---|---|
| SEC-01 | DPAPI 往返 | 明文只存在于内存 | NOT_RUN | — |
| SEC-02 | settings/临时文件 ACL | 无 Everyone/Users | NOT_RUN | — |
| SEC-03 | 日志脱敏 | 密码/Basic 不出现 | NOT_RUN | — |
| SEC-04 | 工作树秘密扫描 | 0 命中（Gitleaks） | NOT_RUN | — |
| SEC-05 | Git 历史秘密扫描 | 0 命中或仅报告位置/次数 | NOT_RUN | — |
| SEC-06 | 公开仓库 PII/IP | 与用户确认范围 | NOT_RUN | — |
