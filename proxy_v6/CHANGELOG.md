# CHANGELOG — V6.0

## V6.0 — 2026-11-18（短周期工程加固）

### 修复
- F07：事务引擎；快照失败/首写/二写/三写失败；恢复双失败；系统代理、owner、进程状态恢复；journal。
- F08：profiles.yaml 块级解析；缺失 updated、相似/重复 UID、CRLF、注释、current 位置；10 用例。
- F09：锁先于 Init；settings 原子写 + ACL；loser 锁所有权；真实 apply 持锁套件。
- F10：恢复日志全 best-effort；恢复失败返回 40；owner/代理恢复委托失败也 40。
- R2A-01：rollback 仅在持锁且已进入 restore 后才补救启动；锁忙 exit 33。
- R2A-02：rollback 使用 settings.mixedPort。
- R2A-03：拒绝零条目/不覆盖 profiles.yaml 的快照清单。
- R2A-04：恢复后凭据文件重新加固 ACL。
- R2A-05：profiles.yaml 在停应用后重读（ProfileTextBuilder）。
- R2A-07：零断言测试判失败；父用例执行断言。
- R2C-03：Get-V4Settings 校验 config/settings ACL。
- R2C-08：脱敏覆盖 JSON key、URL userinfo、空格值、Bearer/Basic/Cookie/API key。
- F12：状态输出 uiSystemProxy；UI 与 HKCU 不一致时 DEGRADED + 明确 reason（INF-F12-01）；不自动改生产网络。
- C-02：移除 `-StaticPass`，改为 `-StaticPassFile`；命令行不再含密码。
- 旧 faultinject-v4.ps1 退役为安全转发器（原 FT12 会改真实 hosts ACL）。

### F11 — 生产状态污染（CRITICAL）
- 05:02:37 主代理临时探针在测试模式下调用 Set-V4SystemProxy -Server 'x'；当时无生产写门闩，真实写入 HKCU，导致 05:28–05:35 全浏览器断网。QQ 不走系统代理故正常。
- 责任代码/操作已确认；05:34 改 127.0.0.1:7897，05:35 关闭系统代理恢复上网。
- 修复：生产写门闩、test registry writer、test-mode Start/Stop no-op、FT16–FT21 回归、禁止 ad-hoc 探针。
- 当前系统代理关闭；百度/Google/ipify 直连 200。F11 保持 FIXED-PENDING-INDEPENDENT-REVIEW。

### 测试
- 92/92 隔离用例；META 7/7；零跳过；零断言判失败。
- 生产副作用检查：全量前后 HKCU ProxyEnable/ProxyServer 一致；WinHTTP 一致。
- Gitleaks 工作树/历史 0 findings。

### 未执行/阻塞
- 真实 apply/rollback/boot/睡眠/Wi-Fi/24h/72h：DEFERRED-BY-USER。
- NexIP 密码轮换：BLOCKED-USER。
- C-01 快照仍为明文凭据（ACL 已加固）；C-12 IP/路径/用户名公开范围待用户决定。
- R2A-06 journal commit phase：OPEN。
### 最终提交
- abe0eaa：第一轮 V6 修复与 75 用例。
- c562c18：F11 生产事故、隔离门闩、R2A/R2C 修复与 92 用例。
- d5f2134：rollback 仅在快照清单验证通过后才允许补救启动。
- b9bb9a0：干净树证据（d5f2134, 92/92）。
- 0268e17：C-02 -StaticPassFile、F12 UI/实际状态报告、ACL owner、脱敏、系统代理写补偿（94 用例）。
- 1c7fdad：最终证据（final.json head=0268e17, dirty=false, 94/94）。
- ebbf2e6：干净 selftest 证据（head=0268e17, dirty=false, 7/7）。
- 分支 v5/short-run-hardening 已推送；PR #1 保持 Draft，未合并 main。