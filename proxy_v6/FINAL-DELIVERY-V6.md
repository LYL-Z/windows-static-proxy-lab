# V6.0 最终交付状态（2026-11-18）

## 0. 结论先行
- **代码/隔离测试**：V6 代码在 `D:\claude防封\publish`，HEAD `dbbd259`，代码提交 `79198fd`；隔离测试 **97/97 PASS**（final.json head=79198fd, dirty=false, 0 skipped, 0 zero-assertion）；META 7/7。
- **生产部署**：**未部署**。实际运行目录 `D:\claude防封\proxy_v4` 的 apply/rollback/state/lib 与 baseline `36222c9` 逐字节一致；与仓库 V6 均不同。
- **当前网络**：可用，但**不是 V4/Clash 静态链在承载浏览器流量**。HKCU ProxyEnable=0；Clash UI 保存 enable_system_proxy=true；浏览器走 StarSky 直连（出口 54.202.22.253）；显式经 127.0.0.1:7897 的出口是 72.245.197.103。
- **F12**：A+C（F11 应急恢复保留 ProxyEnable=0 + UI/实际不一致），不是新的测试污染。状态应报 DEGRADED/FAILED，不能报 HEALTHY。
- **用户验收**：未授予。C-01/C-12/生产部署/真实 apply 等仍需用户授权。

## 1. 真实工作区比对（只读）
| 位置 | 版本/状态 |
|---|---|
| `D:\claude防封\proxy_v4`（实际运行） | apply `711b13b965`、rollback `96b690ee8e`、state `328dfc8fcd`、lib `74c436bfdb`、faultinject `87267b05a5`；全部等于 baseline `36222c9` |
| `D:\claude防封\publish`（开发/发布） | HEAD `dbbd259`；V6 代码提交 `79198fd`；对应 blob 均不同（apply `86f7e1a023`、rollback `21346cd467`、state `9e5c1e7518`、lib `51503e1cb4`） |
| GitHub `v5/short-run-hardening` | 已推送至 `dbbd259`；PR #1 仍为 Draft |
| 生产配置 | `config\settings.json` 存在（933B）；文件 DACL `protected=False`，仅 SYSTEM/Administrators/当前用户；V6 的 ACL 门禁会拒绝该状态，部署前必须加固/重新 Init |
| 生产备份 | `backup\20261118-042834/043519/044034`，含快照；未打印内容，C-01 明文风险仍在 |
| 启动项 | 未发现 proxy/clash/V4 相关 Win32 启动项；boot 生命周期未实测 |

**结论：GitHub/publish 的 V6 修复没有部署到实际运行目录；不能把 PR 上的 97/97 当作生产已升级。**

## 1b. 独立复审最终结论
- final-acceptance DELTA2（对象 code 79198fd / evidence 32d8abc）：**SHORT_RUN_ACCEPTED（有条件）**；无条件发布仍 **NOT_READY**。
- C-02：旧 `-StaticPass`/`-StaticPassFile` 在 CWD 有同名文件时也 exit 11 并输出 removal 文案 → **CLOSED（可审计）**。
- F12：publish 路径无 settings → **FAILED + UI reason**；生产目录有 settings（933B）但仍是 baseline，实际只读判定为 **DEGRADED**（HKCU off/UI on/浏览器走 StarSky），不是 HEALTHY。
- 新 HIGH：无。security DELTA2 亦独立确认 C-02/F12/C-04/C-08，未发现新 HIGH；R5-01（整文件路径 allowlist 会抑制未来 secret）已收窄为仅精确 regex `abcdef123456`，重扫 HEAD/工作树/历史 0。
- 条件：C-01/C-12 用户书面处置；V6 未部署生产；残余需接受或修复；真实 apply/rollback/boot 等 WAITING-USER。
- 独立复审确认的残余（按名称，避免编号混淆）：
  - R2A-06：journal 无提交阶段（MED，fail-closed）。
  - 安全 R3-01：旧 proxy_diag/v2/v3 入口仍可直写 HKCU（MED）。
  - 事务 R3-01：生产写门闩只覆盖注册表/进程入口，ACL 写入器、Start-V4ClashCore -Launch、settings/owner/journal 未在门闩内（MED）。
  - R3-02：系统代理写入补偿仅覆盖进程内异常，非跨进程原子（LOW）。
  - R3D-04：C-04 owner 无负向用例（LOW）；R3D-05：写补偿无失败用例（LOW）。
  - R5D-01：凭据文件 ACL 加固此前只有“<受保护文件>”文字，现已补 Protect-V4Acl 示例（LOW，已文档修复）。
  - R5-01：gitleaks 曾整文件路径 allowlist，现已改为仅精确合成字面量，重扫 0（已修复）。
  - C-01/C-12、NexIP 轮换仍为 BLOCKED/USER 项。

## 2. 十个 Gate（证据/状态）
| Gate | 状态 | 证据与边界 |
|---|---|---|
| CODE_SAFETY | **CONDITIONAL / PARTIAL** | 97/97 隔离测试；round3 对 d5f2134 无新 HIGH；C-02 旧参数前缀问题已在 79198fd 用墓碑参数修复（INF-APPLY-INIT-02/03），但该最终 delta 尚未获独立复审签字；C-01 明文快照仍为 HIGH 残余 |
| TEST_ISOLATION | **PASS（V6 harness）/ PARTIAL（整体）** | F11 根因已定位并修复；FT16–FT21；tests 前后 HKCU/WinHTTP 一致；old proxy_diag/v2/v3 仍可直写 HKCU（R3-01），不属于 V6 harness |
| CONFIG_INTEGRITY | **PASS（隔离）/ NOT VERIFIED（生产）** | 事务/journal/快照/恢复测试通过；生产仍是 baseline，未做真实事务 |
| PRODUCTION_DEPLOYMENT | **NOT_DEPLOYED** | 生产 5 个核心文件 = 36222c9；publish V6 = 79198fd；无部署记录 |
| CURRENT_NETWORK_STATE | **DEGRADED（可用，不是 HEALTHY）** | HKCU 0/127.0.0.1:7897；UI on；直连 54.202.22.253；Clash 7897 显式出口 72.245.197.103；7897/11119 监听正常；生产 settings 存在但 baseline |
| USER_ACCEPTANCE | **NOT_GRANTED** | 用户未接受 C-01/C-12，也未批准部署/真实 apply/恢复方案 |
| BOOT_LIFECYCLE | **WAITING-USER / NOT RUN** | 开机、睡眠、Wi-Fi 重连未实测；此前误标 DEFERRED，现纠正 |
| CREDENTIAL_SECURITY | **PARTIAL / BLOCKED** | C-02 代码已移除命令行密码；C-01 快照明文凭据未加密；NexIP 轮换 BLOCKED-USER；生产 settings ACL 未受保护 |
| PUBLICATION_SECURITY | **PARTIAL** | gitleaks 8.30.1 + .gitleaks.toml：工作树/历史 0；历史合成 fixture 命中已窄 allowlist 披露；C-12 公网 IP/路径/用户名范围 WAITING-USER |
| SERVICE_ELIGIBILITY | **NOT_ASSESSED / OUT_OF_SCOPE** | 出口 IP/延迟不等于第三方服务资格；本轮不做规避地区/账户限制 |

## 3. F12 候选恢复方案（未执行）
### A. 保持现状（推荐直到授权）
- 操作：不改任何东西。
- 影响：所有站点可用；浏览器走 StarSky 直连；不经过 V4 静态链。
- 验证：HKCU ProxyEnable=0；直连/Google/Baidu 200；Clash 仅显式代理可用。
- 回滚：无需。

### B. 只同步 UI（低风险）
- 操作：在 Clash Verge 把“系统代理”开关关闭（只改应用配置/UI，不动 HKCU）。
- 影响：UI 与 HKCU 一致；浏览器路径不变。
- 验证：verge.yaml enable_system_proxy=false；HKCU 仍 0；网站可用。
- 回滚：重新打开 UI 开关（不会自动改 HKCU，除非应用执行系统代理写入）。

### C. 让浏览器走 V4/Clash（需授权）
- C1 直接打开系统代理：浏览器走 7897；当前规则 MATCH,PROXY 会让 Baidu 也走美国链，预计 502/慢，不推荐。
- C2 先给 V4-Managed 增加 `GEOIP,CN,DIRECT`（以及必要国内域名）再重载，验证 Baidu/Google 均 200 后再开启系统代理；需要修改生产 Clash profile。
- 影响：短时网络中断；错误规则可能导致国内站点不可用。
- 回滚：立即 ProxyEnable=0；恢复旧 profile/订阅。
- 验证：HKCU=127.0.0.1:7897；Baidu/Google 200；出口 72.245.197.103；UI 与 HKCU 一致。

### D. 部署 V6 到生产目录（需授权）
- 前置：备份 `D:\claude防封\proxy_v4`；保护 `config\settings.json` DACL；确认 settings/backup 不丢。
- 步骤：复制 V6 脚本/库；运行 `apply-v4.ps1 -DryRun`；再真实 apply；验证 state/日志；失败用 rollback。
- 影响：生产脚本替换、可能重启 Clash；需要维护窗口。
- 回滚：恢复备份目录 + 关闭系统代理；保留旧 baseline 副本。

## 4. 一次性授权清单（需用户明确批准）
1. 是否批准把 V6 代码部署到 `D:\claude防封\proxy_v4`（先备份，再 DryRun/apply）。
2. 是否批准真实 apply/rollback 测试（维护窗口，含断网回退）。
3. F12 选择：A 保持直连 / B 只同步 UI / C 改规则并开系统代理 / D 部署 V6。
4. C-01：接受“ACL 保护的明文快照”，还是要求加密/清理后才继续。
5. C-12：公开 IP/路径/用户名范围接受、脱敏，还是不公开。
6. NexIP 凭据轮换（BLOCKED-USER）。
7. 开机/睡眠/Wi-Fi 重连验收窗口。
8. 24h/72h 长稳仍 DEFERRED-BY-USER（不是永久取消，另行安排）。

## 5. 明确未做
- 未执行真实生产 apply/rollback/state；未改 HKCU/路由/TUN/IPv6/StarSky/Clash；未部署 V6 到生产目录；未轮换凭据；未做 boot/sleep/Wi-Fi/24h/72h；未做第三方服务资格判断。