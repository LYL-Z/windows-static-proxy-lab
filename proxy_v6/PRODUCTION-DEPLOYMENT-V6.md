# V6 生产部署报告（2026-11-18）

## 结论
- V6 已部署到实际运行目录，当前状态 **HEALTHY**。
- 系统代理：**启用**，指向本机 Clash mixed 端口；Clash UI 与实际状态一致。
- 国内/国外网站均通过 Clash 规则验证：百度 200、Google 200；静态代理出口已验证。
- 真实回滚已执行并验证；发现并修复“回滚到 off 后 Clash 重启重新写回 on”的缺陷。
- 生产配置、备份、settings ACL 已保护；未改 StarSky、路由、TUN、IPv6、防火墙。

## 部署对象
| 项 | 值 |
|---|---|
| 生产目录 | <production-dir>（不公开绝对路径） |
| 部署前版本 | baseline 36222c9 |
| 部署后代码 | publish HEAD 4e72df9（含 e5af8e1 国内直连规则、4e72df9 回滚修复） |
| 部署文件 | apply-v4.ps1、rollback-v4.ps1、state-v4.ps1、lib/V4.ps1；旧 faultinject 替换为安全转发器 |
| 生产配置 | 保留原 settings.json；仅加固 ACL，未改凭据/用户配置 |
| 备份 | <local-backup-dir>；91 个文件，复制前后 manifest 差异 0 |
| 回滚文件 | 已核对 baseline/V6 回滚脚本与备份清单；真实回滚通过 |

## 执行证据
1. **DryRun**：exit 0；first hop 200；暂存配置通过 mihomo -t；HKCU 未变。
2. **真实 apply**：exit 0；snapshot 创建；Clash 重启；系统代理启用；自带 exit 校验通过。
3. **状态**：state-v4.ps1 -Json → state=HEALTHY、mode=NEXIP、systemProxy=127.0.0.1:7897、uiSystemProxy=enabled、clashRunning=true、mixedPort=true、firstHopOk=true、exitViaChain=<static-exit>。
4. **真实回滚**：
   - 第一次回滚到 ProxyEnable=0 快照时，Clash 重启后把 HKCU 重新写回 on；已定位并修复（回滚在 restart 后强制 Clear 并校验，失败则 exit 41）。
   - 修复后回滚：exit 0，HKCU ProxyEnable=0，日志 "system proxy held off after restart"。
   - 随后重新 apply，最终恢复 HEALTHY。
5. **网络兼容性**：经系统代理/Clash：百度 200、Google 200、ipify 200；静态出口正确（不公开 IP）。
6. **安全存储**：生产 config/settings、backup、evidence 全量 ACL 加固；settings ACL 校验通过；未删除有效备份。
7. **明文快照**：仍为明文（C-01），已 ACL 保护并披露；未擅自删除或上传。

## 启动/依赖检查
- 存在 **Clash Verge** 登录启动计划任务；未发现 V4 自动启动任务。
- StarSky 无独立启动任务/未验证登录顺序；若 Clash 先于 StarSky 启动，首跳可能暂不可用，V6 state 会报 first hop down。
- 未执行真实重启；开机/睡眠/Wi-Fi 重连仍为 **WAITING-USER**。
- 未关闭防火墙/Defender/证书验证。

## 当前 Gate
- CODE_SAFETY：97/97（head=4e72df9, dirty=false）；C-01 明文快照仍为残余。
- TEST_ISOLATION：V6 harness PASS；旧 diag/v2/v3 入口仍为残余（R3-01）。
- CONFIG_INTEGRITY：生产验证 PASS（DryRun/apply/state/rollback）。
- PRODUCTION_DEPLOYMENT：**DEPLOYED & VERIFIED（本轮）**。
- CURRENT_NETWORK_STATE：**HEALTHY**（实际流量经 Clash；国内直连规则生效）。
- USER_ACCEPTANCE：待用户确认。
- BOOT_LIFECYCLE：PARTIAL / WAITING-USER（未重启）。
- CREDENTIAL_SECURITY：C-02 closed in code；C-01 明文快照 ACL 保护；轮换 BLOCKED-USER。
- PUBLICATION_SECURITY：新报告已脱敏；C-12 仍需最终确认。
- SERVICE_ELIGIBILITY：NOT_ASSESSED。

## 剩余阻塞
- C-01 快照明文（ACL 已加固；未加密）。
- C-12 公开信息范围（本报告已用占位符）。
- R2A-06 journal commit phase、R3-01 旧入口、R3-02 非跨进程原子等残余。
- 开机/睡眠/Wi-Fi 重连、24h/72h 长稳未执行；凭据轮换需用户。
- 浏览器扩展离线，未做浏览器 UI 自动化；系统代理/WinINet 与 curl 已实测。
