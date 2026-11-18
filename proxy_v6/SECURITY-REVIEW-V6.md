# SECURITY-REVIEW — V6.0

最后更新：2026-11-18T05:54-08:00

## 1. 扫描
| 项 | 结果 |
|---|---|
| Gitleaks 8.30.1 工作树 | 0 findings |
| Gitleaks 全历史（6 commits / 587 unique blobs） | 0 findings |
| 合成 canary 验证 | github-pat / generic-api-key 可检出；扫描有效 |
| DPAPI blob / GitHub token / 私钥 / 真实代理凭据 | 0 命中 |
| 测试夹具合成凭据 | 仅 fixture-* / canary，无真实值 |

## 2. 当前控制
- C-02 已移除命令行密码，改 `-CredentialFile`；旧拼写墓碑拒绝；测试 INF-APPLY-INIT-02/03。
- C-04 增加 owner SID 校验；C-08 增加 URL/JSON/API key 脱敏。
- 生产写门闩：Set/Clear/Start/Stop 需要 `Enable-V4ProductionWrites`；测试模式默认拒绝，只有 test registry writer 可写 mock。
- 配置 ACL：config dir + settings 读取时校验；不对宽 ACL 静默使用。
- 快照 ACL：复制前加固目录；backup 根目录加固；恢复后凭据文件重新加固。
- 日志/证据 ACL：evidence 目录/文件加固；repo/evidence/reviews 384+ 对象已加固（repo-acl.json）。
- 脱敏：password/pass/secret/token/username/user/authorization/cookie（含 JSON key）、Basic、Bearer、URL userinfo、空格值。
- DPAPI：同用户作用域；settings 原子写；明文 username 与快照明文是残余风险。

## 3. C 项裁定
| 项 | 状态 |
|---|---|
| C-01 快照明文凭据 | **PARTIAL/ACCEPTED-RISK**：ACL 先加固；未加密、未定保留期；需用户接受 |
| C-02 -StaticPass 命令行 | **CLOSED**：改 `-CredentialFile`；旧 `-StaticPass`/`-StaticPassFile` 墓碑拒绝；INF-APPLY-INIT-02/03 |
| C-03 FT12 改真实 hosts | **CLOSED**：旧套件退役为安全转发器 |
| C-04 ACL 早退 | **CLOSED**：规则/SID/FullControl + owner SID 校验 |
| C-05 ACL 失败静默 | **CLOSED**：settings/snapshot/managed profile 失败即错误 |
| C-06 settings 暴露窗口 | **MITIGATED**：目录先加固 + 原子写 |
| C-07 明文临时/运行时 | **MITIGATED**：stage/evidence ACL；runtime 被应用重写仍可能回落 |
| C-08 脱敏缺口 | **CLOSED**：URL userinfo、JSON key、API key、Cookie；INF-REDACT-02/03 |
| C-09 evidence 日志 ACL | **CLOSED**：目录/文件加固 |
| C-10 DPAPI 失败 state 崩溃 | **CLOSED**：结构化 FAILED JSON + exit 3 |
| C-11 嵌套 .gitignore | **CLOSED**：**/config/settings.json、**/config/.lock |
| C-12 公开 PII/IP/路径 | **WAITING-USER** |
| C-13 manifest 无签名 | **ACCEPTED-RISK**（本地备份信任边界） |
| C-14 依赖无哈希 | **ACCEPTED-RISK/LOW** |
| C-15 文档过度声明 | **CLOSED**：README/SECURITY-NOTES/USER-GUIDE 更新 |

## 4. R2C 项
- R2C-01 脚本树 ACL：**MITIGATED**（repo/proxy_v4/proxy_v6/.git 已加固）。
- R2C-03 settings ACL 不复核：**FIXED**（INF-SETTINGS-04）。
- R2C-04 恢复不加固：**FIXED**（INF-SNAP-08）。
- R2C-05 harness 证据 ACL：**MITIGATED**（目录加固；后续证据继承）。
- R2C-06 PII 扩大：**WAITING-USER**。
- R2C-07 证据绑定旧 HEAD/dirty：**FINAL FIX PENDING**（干净树重跑后提交）。
- R2C-08 脱敏缺口：**FIXED**。

## 5. F11（CRITICAL）
主代理临时探针在测试模式下调用 `Set-V4SystemProxy -Server 'x'`，当时无生产写门闩，真实写入 HKCU，造成 05:28–05:35 断网。已恢复网络并加入生产写门闩 + test writer + FT16–21。F11 待独立复审确认，不得以“网络已恢复”关闭。

## 6. R3 残余
- R3-01：旧 `proxy_diag`/`proxy_v2`/`proxy_v3` 入口仍可直接写 HKCU；V4/V6 已加门闩，旧入口未改（需用户决定是否冻结/删除）。
- R3-02：系统代理两次写已加本地补偿（失败恢复旧值）；仍非跨进程原子。
- R2A-06：journal commit phase OPEN。
- C-12：公开 IP/路径/用户名等待用户决定。