# V6.0 最终交付状态（2026-11-18，生产部署后）

## 0. 结论
- **生产部署已执行**：实际运行目录现为 V6 代码 `4e72df9`（不是 baseline）。
- **当前网络状态：HEALTHY**：系统代理启用并指向本机 Clash mixed 端口；Clash UI 与实际一致；国内/国外站点经代理均可用；静态代理出口校验通过。
- **CODE/TEST**：最终 97/97 隔离测试通过（head=4e72df9, dirty=false, 0 skipped, 0 zero-assertion）；META 自验 7/7（harness 未变）。
- **真实回滚已执行**：发现并修复“回滚到 proxy-off 后 Clash 重启重新写回 on”的缺陷；修复后回滚到 off 成功，再 apply 恢复 HEALTHY。
- **未重启**：开机/睡眠/Wi-Fi 重连仍为 WAITING-USER；24h/72h 仍为 DEFERRED-BY-USER。
- **用户验收**：部署已执行，但 C-01/C-12 和最终使用确认仍待用户；不得把自动化测试当作第三方服务资格。

## 1. 精确对象
| 项 | 值 |
|---|---|
| 仓库 | <repo>（不公开绝对路径） |
| 分支 | v5/short-run-hardening |
| 最终 HEAD | `bf9984d`（证据/部署报告）；代码 `4e72df9` |
| 最终证据 | `proxy_v6/evidence/v6/final.json`：head=4e72df9, dirty=false, 97/97 |
| 生产目录 | <production-dir>（部署前 baseline 36222c9；已备份） |
| 部署备份 | <local-backup-dir>：91 文件，复制前后 manifest 差异 0 |
| PR #1 | Draft，未合并 main |

## 2. 部署验证
- DryRun：exit 0；first hop 200；暂存配置通过 mihomo -t；HKCU 未变。
- 真实 apply：exit 0；snapshot 创建；Clash 重启；系统代理启用；exit 校验通过。
- state-v4.ps1：HEALTHY；systemProxy=127.0.0.1:7897；uiSystemProxy=enabled；clashRunning=true；mixedPort=true；firstHopOk=true；exitViaChain=<static-exit>。
- 网络：经代理百度 200、Google 200、ipify 200；静态出口正确。
- 回滚：第一次回滚到 off 快照暴露 Clash 重启重新写回 on（R6-01）；已修复并加入“restart 后强制 off + 校验，失败 exit 41”。修复后回滚 exit 0、HKCU off；再 apply 恢复 HEALTHY。
- 安全：生产 config/settings、backup、evidence ACL 已加固；settings ACL 校验通过；未删除有效备份。

## 3. 十个 Gate
| Gate | 状态 | 证据/边界 |
|---|---|---|
| CODE_SAFETY | **CONDITIONAL** | 97/97；C-02/F11/R2A-01 已确认；C-01 明文快照仍为 HIGH 残余；R2A-06/R3-01/R3-02 等披露 |
| TEST_ISOLATION | **PASS（V6）/ PARTIAL（整体）** | FT16–FT21；测试前后 HKCU/WinHTTP 一致；旧 diag/v2/v3 入口仍可直写 HKCU |
| CONFIG_INTEGRITY | **PASS（生产本轮）** | DryRun/apply/state/rollback 均成功；配置保留 |
| PRODUCTION_DEPLOYMENT | **DEPLOYED & VERIFIED** | 生产文件与 V6 4e72df9 匹配；真实 apply/rollback 完成 |
| CURRENT_NETWORK_STATE | **HEALTHY** | 代理启用、UI 一致、百度/Google 200、静态出口正确 |
| USER_ACCEPTANCE | **PENDING FINAL CONFIRMATION** | 部署已获授权并执行；最终使用确认与 C-01/C-12 待用户 |
| BOOT_LIFECYCLE | **PARTIAL / WAITING-USER** | 未重启；已发现 Clash 登录任务，未发现 V4 自动启动；StarSky 顺序未验证 |
| CREDENTIAL_SECURITY | **PARTIAL / BLOCKED** | settings DPAPI + ACL；C-01 快照仍明文（ACL 保护）；NexIP 轮换 BLOCKED-USER |
| PUBLICATION_SECURITY | **PARTIAL** | 本报告已脱敏；gitleaks 精确 allowlist 后 0；C-12 范围待用户 |
| SERVICE_ELIGIBILITY | **NOT_ASSESSED** | 出口 IP/延迟不等于第三方资格 |

## 4. 启动与依赖
- 存在 Clash Verge 登录启动计划任务；未发现 V4 自动启动任务。
- StarSky 无独立启动任务；若 Clash 先于 StarSky，首跳可能暂不可用，state 会报 first hop down。
- 未执行真实重启、睡眠、Wi-Fi 重连；这些操作需用户配合。
- 未关闭防火墙/Defender/证书验证。

## 5. 剩余阻塞/披露
- C-01：快照明文凭据仍存在（ACL 已加固，未加密）。
- C-12：公开 IP/路径/用户名范围仍需用户最终确认；本报告使用占位符。
- R2A-06：journal 提交阶段（MED，fail-closed）。
- R3-01：旧 proxy_diag/v2/v3 直写 HKCU；事务门闩覆盖面（MED）。
- R3-02：系统代理写补偿非跨进程原子（LOW）。
- R6-01：回滚后 app 重新写回 proxy-on，已修复并用真实回滚验证。
- 凭据轮换、真实重启/睡眠/Wi-Fi、24h/72h：BLOCKED/USER 或 DEFERRED。
