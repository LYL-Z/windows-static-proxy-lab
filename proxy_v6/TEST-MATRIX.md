# TEST-MATRIX — V6.0

最后更新：2026-11-18T05:52-08:00
当前全量：**97 用例 / 94 通过 / 0 失败 / 0 跳过**（隔离运行；真实生产 apply/rollback/boot 未执行）

## 1. F07 事务（16/16 PASS）

| ID | 场景 | 结果 |
|---|---|---|
| F07-01 | 快照停应用后失败，进程/文件恢复 | PASS |
| F07-02 | 第一次正式写入失败 | PASS |
| F07-03 | 第二次写入失败，第一写回滚 | PASS |
| F07-04 | 第三次写入失败，两写回滚 | PASS |
| F07-05 | 代理已设置后 ACL 失败，系统代理恢复 | PASS |
| F07-06 | 恢复失败 + 日志失败，exit 40 不抛 | PASS |
| F07-07 | 恢复失败仍尝试进程协调 | PASS |
| F07-08 | 成功路径写三目标/代理/owner | PASS |
| F07-09 | 原本停止的应用不被恢复启动 | PASS（stopCalls 断言） |
| F07-10 | owner 写失败，代理/owner 恢复 | PASS |
| F07-11 | 恢复成功时原错误码保留 | PASS |
| F07-12 | 成功清 journal | PASS |
| F07-13 | 恢复成功清 journal | PASS |
| F07-14 | 恢复失败保留 journal | PASS |
| F07-15 | journal 写失败在首写前 abort | PASS |
| F07-16 | 停应用后重读 profiles.yaml | PASS |

## 2. F08 Profile 作用域（10/10 PASS）

F08-01 target updated；F08-02 缺 updated 不改下一 Profile；F08-03 相似 UID；F08-04 重复 UID fail-closed；F08-05 内联注释；F08-06 最后块缺 updated；F08-07 非列表 uid；F08-08 追加；F08-09 CRLF；F08-10 current 在块后。全部 PASS。

## 3. F09 Init/锁（1 套件，3 子检查 PASS）

F09-SUITE：他人持锁时 Init 不写 settings；loser 不删 winner 锁；Init+DryRun exit 11。另 INF-APPLY-INIT-01、INF-INIT-01..04。

## 4. F10 日志/恢复（10/10 PASS）

F10-01..10：恢复失败/日志失败/启动失败/代理恢复失败/owner 恢复失败/进程未知/原码保留；全部 PASS。

## 5. F11 生产状态隔离（FT16–FT21，6/6 PASS）

| ID | 场景 | 结果 |
|---|---|---|
| FT16 | mock 写入 ProxyServer=x，真实 HKCU 不变 | PASS |
| FT17 | mock 抛错，操作失败且真实 HKCU 不变 | PASS |
| FT18 | 子进程异常终止，真实 HKCU 不变 | PASS |
| FT19 | 两个并行 mock 子进程，真实 HKCU 不变 | PASS |
| FT20 | ProxyServer=x / 错误出口 IP 报 DEGRADED，不报 HEALTHY | PASS |
| FT21 | 无 writer 测试被拒；HKCU/WinHTTP 前后一致 | PASS |

## 6. 基础设施/安全/生命周期/状态一致性（54/54 PASS）

- 参数：PARAM-01/02/04/05/06/07（Repair+DryRun、Init+Repair、缺/坏 settings、非法 Mode、DryRun 只读）。
- 事务：TX-01..TX-11 对应用例（快照失败、写失败、锁文件、快照篡改/空清单/缺 profiles.yaml、部分恢复、原子写、临时文件、存在/不存在恢复）。
- 并发/锁：LOCK-01..05（双事务、loser、陈旧锁、PID 复用、零字节锁；锁忙 rollback 33）。
- 日志：LOG-01/02（目录不可写、日志路径不可写）。
- 数据完整性：DATA-02/04、无关配置/ACL、YAML 转义、恢复 ACL。
- 状态/生命周期：LIFE-01..09（依赖未启动/延迟/退出、配置损坏、重复启动、首跳不可用、配置/运行不一致）；F12-01（UI 与 HKCU 不一致报 DEGRADED）。
- C-02：INF-APPLY-INIT-01（凭据文件）+ INF-APPLY-INIT-02（旧 -StaticPass 被拒）。
- 安全：SEC-01..03（DPAPI、ACL、脱敏）；R2C-03 settings ACL 拒绝；C-01 快照 ACL。
- 回滚：TX-ROLLBACK 01..04（真实 rollback 脚本恢复/journal/锁；损坏快照 40；锁忙 33；mixedPort 65532）。
- Harness 自验：META-01..07 7/7 PASS；exit 0/1/2/3/4 负控全部符合；零断言当前判失败。

## 7. F12 状态一致性

| ID | 场景 | 结果 |
|---|---|---|
| F12-01 | UI=on/HKCU=off、UI=off/HKCU=on、首跳失败 | PASS（DEGRADED + 明确 reason） |

## 8. 未覆盖/披露

| 项 | 状态 |
|---|---|
| 真实生产 apply/rollback/state | 未执行（WAITING-USER） |
| 真实重启/睡眠/Wi-Fi/断网 | 未执行（WAITING-USER） |
| 24h/72h | DEFERRED-BY-USER |
| 跨用户/跨机器 DPAPI | 未执行 |
| 真实 Clash 进程停止/启动 | 仅 test-mode no-op 与隔离 fake；未真实执行 |
| R2A-06 journal commit phase | OPEN；当前 fail-closed |
| C-12 公开 IP/路径/用户名 | WAITING-USER |
| C-01 快照明文凭据长期留存 | 残余风险；ACL 已加固，未加密 |