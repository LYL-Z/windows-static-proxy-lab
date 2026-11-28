# INDEPENDENT-REVIEW — V6.0

## 1. 第一轮（基线 36222c9）
| 子代理 | 报告 | 主要结果 |
|---|---|---|
| A 事务/并发 | AGENT-A-TRANSACTION-AUDIT.md | 30 项；A-01/A-03..A-08/A-12/A-21 HIGH；F01/F02/F03/F05/F06 按字面不成立 |
| B 测试基础设施 | AGENT-B-TEST-INFRA.md | Harness + META-01..07 7/7；0/1/2/3/4 负控通过 |
| C 安全 | AGENT-C-SECURITY-REVIEW.md | 15 项；C-01 快照明文、C-02 StaticPass、C-03 真实 hosts 测试 |
| D 代码审查 | AGENT-D-CODE-REVIEW.md | 25 项；D-01 锁、D-03 state、D-04/D-05 恢复、D-16/D-17 测试假阳性 |

第一轮报告只针对 36222c9；其发现已逐条映射到 ISSUE-LEDGER。

## 2. 第二轮（commit abe0eaa）
| 子代理 | 报告 | 结果 |
|---|---|---|
| round2-transaction | ROUND2-TRANSACTION-REVIEW.md | F07/F08/F09/F10 主路径关闭；1 HIGH R2A-01（rollback catch 未持锁启动）；8 MED；6 LOW |
| round2-security | ROUND2-SECURITY-REVIEW.md | 2 HIGH（R2C-01 脚本树 ACL、C-01 快照明文）；6 MED；7 LOW；15 项 C 状态 |
| final-acceptance (E) | FINAL-ACCEPTANCE-V6.md | 独立跑 75/75、META 7/7、gitleaks 0；裁定 NOT_READY，因二轮未回/Gate 文档未更新/证据 dirty |

## 3. 第二轮后的修复
- R2A-01：rollback 只在持锁且进入 restore 后补救启动；锁忙 33；INF-ROLLBACK-03。
- R2A-02：rollback 使用 mixedPort；INF-ROLLBACK-04。
- R2A-03：空/缺 profiles.yaml 清单拒绝；INF-SNAP-06/07。
- R2A-04：恢复后 ACL 加固；INF-SNAP-08。
- R2A-05：停应用后重读 profiles.yaml；F07-16。
- R2A-07：零断言判失败；父用例断言；最终干净树重跑。
- R2A-09：F07-05 改为代理后 ACL 失败；F07-09 断言 stopCalls。
- R2C-03/04/08：settings ACL、恢复 ACL、脱敏。
- R2C-01：repo/proxy_v4/proxy_v6/.git ACL 加固。
- F11：生产写门闩 + test writer + FT16–21。

## 4. 当前结论
- 功能/事务：92/92 隔离用例通过；无新增功能性 HIGH（待最终复审）。
- 安全：C-03/C-10/C-11 关闭；C-01 残余明文、C-02 文档警告、C-12 用户决定。
- F11：根因明确，修复和回归到位；**待独立复审确认**。
- Gate：NOT_READY，主要因最终提交后的第二轮复审/干净证据/推送未完成。
- 明确不接受：隔离 92/92 不能冒充真实生产 apply/rollback/boot/24h/72h；未轮换凭据。
