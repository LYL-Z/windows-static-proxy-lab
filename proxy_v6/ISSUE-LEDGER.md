# ISSUE-LEDGER — V6.0

最后更新：2026-11-25。新增：用户关闭代理后，快照回滚和失败恢复不再把同一代理重新打开。隔离回归 `171d060` 为 114/114。生产目录仍未替换。
状态图例：OPEN / FIXED-PENDING-REVIEW / VERIFIED-CLOSED / WAITING-USER / DEFERRED-BY-USER / ACCEPTED-RISK

## A. F11 — 生产状态污染事故（CRITICAL，最高优先级）

| 项 | 内容 |
|---|---|
| ID | **F11 — PRODUCTION_STATE_CORRUPTION** |
| 等级 | **CRITICAL**（生产状态被测试/探针污染；测试隔离失效） |
| 现象 | HKCU Internet Settings: ProxyEnable=1, ProxyServer="x"；国内外浏览器 ERR_PROXY_CONNECTION_FAILED；QQ 正常 |
| 根因 | 主代理 05:02:37 运行临时探针 `_probe-new.ps1`，调用 `Set-V4SystemProxy -Server 'x'`。当时 `Set-V4SystemProxy` 尚未接入 `Assert-V4ProductionOperation`，测试模式只隔离文件根，未隔离注册表。探针输出 `GUARD FAIL`，说明这次调用未抛错；探针没有恢复 HKCU，随后被删除 |
| 责任归属 | 主代理自己的临时探针；不是 harness 测试、不是故障注入套件、不是子代理、不是 V4 生产脚本 |
| 影响 | 仅 HKCU 系统代理值；未改路由/TUN/IPv6/StarSky/Clash 配置 |
| 恢复 | 05:34 将 ProxyServer 改为 127.0.0.1:7897；因百度经 Clash 502，05:35 将 ProxyEnable=0；当前关闭系统代理，Baidu/Google/ipify 均 200 |
| 代码修复 | 测试模式注册表写默认抛错；test writer 才可 mock；生产脚本必须 `Enable-V4ProductionWrites`；Start/Stop 测试模式安全 no-op |
| 回归测试 | FT16 mock x；FT17 mock 失败；FT18 异常终止；FT19 并行；FT20 异常状态不误报 HEALTHY；FT21 HKCU/WinHTTP 前后一致 |
| 状态 | **VERIFIED-CLOSED（代码层）**：round3 transaction/security + final acceptance delta2 独立确认；生产目录仍是 baseline，未部署 |

## A2. F12 — 运行时状态不一致（只读诊断）

| 项 | 内容 |
|---|---|
| ID | **F12 — RUNTIME_STATE_MISMATCH** |
| 等级 | 中（状态报告/UI 一致性；非新事故） |
| 现象 | UI 显示系统代理开启；HKCU ProxyEnable=0；Clash 无流量；IP 信息显示 StarSky 出口 |
| 诊断 | HKCU=0/127.0.0.1:7897，WinHTTP Direct；Clash/StarSky/7897/11119 均正常；直连 54.202.22.253，经 Clash 72.245.197.103 |
| 定性 | **A + C**：F11 应急恢复保留 ProxyEnable=0（预期）+ Clash UI 配置 enable_system_proxy=true 未同步；非 E（无新测试污染） |
| 处理 | 状态脚本新增 uiSystemProxy 与 UI/HKCU 不一致 reason（INF-F12-01）；不自动改生产网络；B 方案需用户确认 |
| 状态 | **EXPECTED-STATE / UI-MISMATCH（待用户决定是否重新开启 Clash 链路）** |

## B. 任务书 F01–F10

| 编号 | 裁定 | 证据 |
|---|---|---|
| F01 | VERIFIED-CLOSED | INF-PARAM-01、F09-03；Repair+DryRun / Init+DryRun / Init+Repair 均 exit 11 且无 settings |
| F02 | VERIFIED-CLOSED（语义修正） | 首写前 journal/脏标志；F07-02/15；真正“脏”含快照停进程，恢复已覆盖 |
| F03 | VERIFIED-CLOSED（语义修正） | 锁 token/进程启动时间；失败获锁不删他人锁；F09-SUITE/FT21；原“释放顺序”不是真实缺陷 |
| F04 | VERIFIED-CLOSED | F08-01/06/09：updated 每次刷新，缺字段则插入 |
| F05 | VERIFIED-CLOSED | META-01..07 自验 + 92/92 全量 exit 0；零断言现在判失败 |
| F06 | VERIFIED-CLOSED | INF-F06-01：strict=select 无 DIRECT；resilient=fallback 含 DIRECT |
| F07 | VERIFIED-CLOSED（主路径） | 16 个 F07 用例；首/二/三写失败、快照失败、恢复双失败、代理/owner/进程恢复、journal |
| F08 | VERIFIED-CLOSED | 10 个 F08 用例：缺失 updated、相似 UID、重复 UID、CRLF、内联注释、current 位置、追加 |
| F09 | VERIFIED-CLOSED | 锁先于 Init；Init 原子写 + ACL；F09-SUITE、INF-APPLY-INIT-01、INF-INIT-01..04 |
| F10 | VERIFIED-CLOSED | 10 个 F10 用例；日志全失败仍恢复；恢复失败返回 40；owner/proxy 恢复委托失败也 40 |

## C. 第二轮复审新发现

| 编号 | 严重度 | 问题 | 状态 |
|---|---|---|---|
| R2A-01 | HIGH | rollback catch 未持锁/未恢复也启动 Clash；锁忙返回 40 | **FIXED-PENDING-REVIEW**：锁内恢复标志 + 33；INF-ROLLBACK-03 |
| R2A-02 | MED | rollback 硬编码 7897 | **FIXED-PENDING-REVIEW**：读 settings.mixedPort；INF-ROLLBACK-04 |
| R2A-03 | MED | 零条目/缺 profiles.yaml 的清单被当成功并清 journal | **FIXED-PENDING-REVIEW**：INF-SNAP-06/07 |
| R2A-04 | MED | 恢复重建的凭据文件不重新加固 ACL | **FIXED-PENDING-REVIEW**：Restore-V4Files 调 Protect；INF-SNAP-08 |
| R2A-05 | MED | profiles.yaml 在停应用前读、后写，可能覆盖应用退出写 | **FIXED-PENDING-REVIEW**：ProfileTextBuilder；F07-16 |
| R2A-06 | MED | journal 无 commit 阶段；清除失败/末写后崩溃会要求回滚良好状态 | **OPEN**（已披露；当前 fail-closed，保守回滚） |
| R2A-07 | MED | 证据断言数 0、证据绑定 36222c9+dirty | **FIXED-PENDING-REVIEW**：零断言失败；父用例断言；最终干净树重跑 |
| R2A-08 | MED | 真实脚本子进程只靠继承环境变量隔离 | **PARTIAL**：Run-Tests 强制设置 V4_TEST_MODE/ROOT；fixture 仍继承 |
| R2A-09 | MED | F07-05/F07-09 不可证伪 | **FIXED**：F07-05 改为代理后 ACL 失败；F07-09 断言 stopCalls |
| R2A-10..15 | LOW | 见 ROUND2-TRANSACTION-REVIEW.md | OPEN/ACCEPTED，逐条披露 |

| 编号 | 严重度 | 问题 | 状态 |
|---|---|---|---|
| C-02 | HIGH | `-StaticPass` 命令行历史暴露 | **VERIFIED-CLOSED**：改 `-CredentialFile`；旧拼写墓碑拒绝；INF-APPLY-INIT-02/03 |
| R2C-01 | HIGH | 安装/脚本树可被 Authenticated Users 改写 | **MITIGATED**：repo/proxy_v4/proxy_v6/.git 384+ 对象 ACL 已加固；repo-acl.json |
| R2C-03 | MED | settings/state 读取不复核 ACL | **FIXED**：Get-V4Settings 校验 config/settings ACL；INF-SETTINGS-04 |
| R2C-04 | MED | 恢复路径不重新加固凭据文件 | **FIXED**：INF-SNAP-08 |
| R2C-05 | MED | harness 证据目录/文件宽 ACL | **MITIGATED**：evidence/reviews 目录已加固；后续运行继承 |
| R2C-06 | LOW | 公开树 PII（绝对路径/用户名/IP） | **WAITING-USER**；不得擅自改写历史 |
| R2C-07 | MED | 证据绑定旧 HEAD + dirty | **FIXED-PENDING**：干净树重跑 final.json |
| R2C-08 | MED | 脱敏 JSON key/URL/空格仍泄漏 | **FIXED**：INF-REDACT-02/03 |

## D. 继承的 V5 开放项

| 编号 | 状态 |
|---|---|
| V5-01 上游 2.5.10 缺 150bfae | OPEN（上游事实） |
| V5-02 #8593 系统代理回退 | OPEN（上游/设计风险） |
| V5-03 NexIP 密码轮换 | **BLOCKED-USER** |
| V5-05 真实 V4 回滚往返 | **WAITING-USER**（隔离回滚已测；需生产授权） |
| V5-07 13/13 仍 exit 1 | **VERIFIED-CLOSED**（旧套件废弃；新 harness 退出码自验） |
| V5-08 FT11/FT14 | **VERIFIED-CLOSED**（注入覆盖；见 TEST-MATRIX） |

## E. 关闭规则

只有“独立失败测试先证明缺陷 → 修复 → 同一测试转绿 + 独立复审确认”才可标 VERIFIED-CLOSED。
F11 代码层已独立确认关闭；生产部署仍未完成。
不得以源码存在某行、静态阅读或主代理自评作为关闭依据。