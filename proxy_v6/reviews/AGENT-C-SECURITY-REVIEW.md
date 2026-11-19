# AGENT-C 软件与数据安全评审

**对象**：proxy_v4/apply-v4.ps1、rollback-v4.ps1、state-v4.ps1、lib/V4.ps1、tests/faultinject-v4.ps1
**基线**：36222c92c829a2ef08b71af2a3a3ff9a3c44b396（v5/short-run-hardening，5 个提交，90 个 tracked 文件）
**评审类型**：独立软件与数据安全评审；前序代理的结论不作为证据。
**结论**：发现 15 项：3 高 / 8 中 / 4 低。最高风险是 C-01：备份快照以明文保存代理凭据，ACL 在复制完成后才尽力施加且失败被静默忽略。V4 基线不能以“13/13 故障注入通过”作为安全发布依据。

## 1. 审计范围、方法与边界

- 目标为 HEAD 基线。评审期间发现另一个进程在工作树中修改了 proxy_v4/apply-v4.ps1、lib/V4.ps1、rollback-v4.ps1、state-v4.ps1 并新增 proxy_v6/；本报告的代码行号与结论均针对 HEAD 36222c9，不针对这些并发修改。
- 静态审阅全部上述源码与相关文档；动态测试使用 git show HEAD:... 把库导出到 %TEMP% 的独立沙箱，未修改生产文件。
- 未执行真实 apply/rollback/state，未触碰 HKCU、系统代理、Clash 进程、hosts、计划任务、网络或凭据。
- 没有运行仓库自带 faultinject-v4.ps1：其 FT12 对真实 C:\Windows\System32\drivers\etc\hosts 调用 Protect-V4Acl，且测试会写生产 config\.lock（见 C-03）。对该套件的结论来自源码，不来自执行。
- 动态测试只用合成 canary（如合成 canary（值不保留）），不读取、不打印、不保存真实密码、用户名或 DPAPI blob。
- 所有 ACL/DPAPI/脱敏/暂存文件结论均有 proxy_v6/evidence/agent-c-security-tests.json 记录；密钥/PII 扫描见 agent-c-gitleaks.json 与 agent-c-secret-pii-scan.json。
- 扫描工具：gitleaks 8.30.1（--redact，默认规则，JSON 报告不保留原始 secret）；另有自写正则扫描覆盖 DPAPI 头、GitHub token、私钥、IPv4、路径、邮箱、凭据形态。

## 2. 发现总表

| ID | 严重度 | 发现 | 主要证据（HEAD 行号） | 状态 |
|---|---|---|---|---|
| C-01 | **高** | 快照/备份目录以明文保存代理密码、订阅 profile 与运行时 secret；复制完成后才调用 ACL，失败被忽略；备份根目录从不加固 | lib/V4.ps1:230-264（复制 244/252，manifest 261，ACL 262）；:443-444；:472；apply-v4.ps1:116 | 未修复 |
| C-02 | **高** | -StaticPass 以明文进入命令行/Shell 历史；安全文档却称“不接受密码参数”，用户指南也没有警告 | apply-v4.ps1:17,38,58；SECURITY-AUDIT-V4.md:7；USER-GUIDE-V4.md 无相关警告 | 未修复 |
| C-03 | **高** | 故障注入 FT12 对真实 hosts 文件执行 DACL 改写；以管理员身份运行会改写系统文件 ACL。套件还写生产锁、启动真实 state 子进程 | tests/faultinject-v4.ps1:108；:12；:59-62；:86,93 | 未修复（未执行） |
| C-04 | 中 | Protect-V4Acl 的早退条件只看“DACL 已保护 + 当前用户有任意 ACE”，会保留 Everyone/Users/Authenticated Users 或只读 ACE；不校验 owner/FullControl | lib/V4.ps1:125-149（早退 133，owner 144） | 部分缓解 |
| C-05 | 中 | ACL 失败被所有调用方忽略；settings written (credential stored DPAPI-encrypted) 和 DONE 在 ACL 失败时仍记录成功；读取/state 不复核 ACL | lib/V4.ps1:120-121,262；apply-v4.ps1:166-168；lib/V4.ps1:506-542 | 未修复 |
| C-06 | 中 | settings 先写文件、后加固目录；崩溃窗口存在。DPAPI 是用户作用域且无附加熵，同用户进程可解密；username 明文 | lib/V4.ps1:110-121；:65-77；:115；真实仓库父 ACL 宽于用户 | 部分缓解（依赖 ACL） |
| C-07 | 中 | 生成的 managed profile/runtime 与 TEMP/.v4stage 暂存文件含明文密码/secret，ACL 只在整条链路成功后才施加；应用重写文件会重置 ACL；失败路径保留明文文件 | lib/V4.ps1:398-452,454-486,289-311；apply-v4.ps1:145-167；动态测试“重写后 protected=false” | 未修复 |
| C-08 | 中 | 日志脱敏覆盖不足：带空格的引号密码只遮第一个 token，短 Basic、URL userinfo、pass:/secret:/Bearer、<4 字符 secret 均不遮；FT15 只测两例 | lib/V4.ps1:33-42；tests/faultinject-v4.ps1:123-129；测试结果 7 项泄漏 | 未修复 |
| C-09 | 中 | evidence/log 文件无显式 ACL；真实仓库 proxy_v4/evidence 继承 Authenticated Users:Modify、Users:ReadAndExecute；日志含 IP/本地路径/PID，且无清理策略 | lib/V4.ps1:44-59；真实 ACL 测量；本地 15 个 ignored 日志 | 未修复 |
| C-10 | 中 | DPAPI 跨用户/跨机器/损坏 blob 时抛错；Get-V4Settings -ErrorAction SilentlyContinue 不能抑制 throw，state-v4.ps1 直接退出 1 且不输出 JSON；apply 只报 unexpected | lib/V4.ps1:96-108,508；state-v4.ps1:14；沙箱实测 exit 1 | 未修复 |
| C-11 | 中 | .gitignore 只忽略根目录 config/settings.json 与 config/.lock；proxy_v4/config/settings.json、proxy_v4/config/.lock 不被忽略，误 git add 会提交 DPAPI blob 与明文 username | .gitignore:1-5；git check-ignore 实测嵌套路径无匹配 | 未修复 |
| C-12 | 低 | 发布面：HEAD 含 18 个唯一公网 IPv4（530 次、36 个文件）、46 处绝对项目路径（19 文件）、2 处 Windows 用户目录路径；6 处机构支持邮箱、0 私人邮箱；本地 ignored 日志另有 1 个公网 IP/336 次 | agent-c-secret-pii-scan.json；SECURITY-NOTES.md:18 已承认 IP | 已披露/建议复核 |
| C-13 | 低 | 快照 manifest 的 SHA256 没有签名/MAC；对 backup 有写权限者可同时改文件与 manifest，-SnapshotDir 还接受任意路径，恢复链路可被投喂 | lib/V4.ps1:266-286；rollback-v4.ps1:36 | 部分接受 |
| C-14 | 低 | 无第三方 PowerShell 模块/npm/pip 包（已核对），但 mihomo/curl 无哈希/签名校验；curl.exe、powershell 走 PATH；Get-V4Paths 信任进程路径 | lib/V4.ps1:81-93,220,319,357；tests/faultinject-v4.ps1:86；DEPENDENCY-LOCK.md:5-12 | 低风险/待改进 |
| C-15 | 低 | 安全文档过度声明：不接受密码参数 与 -StaticPass 矛盾；ACL 幂等、必须含 owner ACE 与实测早退/未设 owner 不符 | SECURITY-AUDIT-V4.md:7,9；lib/V4.ps1:125-149 | 未修复（文档） |

## 3. DPAPI 与 settings.json 静态暴露

### 3.1 实际形态

隔离沙箱中 Protect-V4Secret 对合成密码的输出：

- 524 个十六进制字符；
- 前缀 01000000，头 d08c9ddf，符合 DPAPI user-scope blob；
- Unprotect-V4Secret 往返一致；
- 篡改一个 hex 字符后抛 CryptographicException，错误消息不含 canary；
- ConvertFrom-SecureString 未使用 -Key，即没有附加熵。任何以当前用户身份运行的进程，只要能读到文件，就能解密；管理员可重置 ACL 读取 blob，但要取得用户 DPAPI 明文仍需该用户上下文。

因此“DPAPI 加密”主要把风险从“其他本地用户可读明文”降低到“同用户进程/用户上下文可解”，它不能替代 ACL，也不能替代快照的明文治理。

### 3.2 写入与暴露窗口

Save-V4Settings 的顺序是：

1. Write-V4File 写 config\settings.json（lib/V4.ps1:119，其中含明文 username 与 DPAPI 密文）；
2. 才调用 Protect-V4Acl -Path $script:ConfigDir（:120）；
3. 无论 ACL 返回值如何，立即记录 settings written (credential stored DPAPI-encrypted)（:121）。

真实仓库 publish/proxy_v4/config 当前 AreAccessRulesProtected=false，继承 Authenticated Users:Modify 与 Users:ReadAndExecute（只读测量）。若进程在 1 与 2 之间被杀、磁盘满、或 Set-Acl 失败，文件会保持宽 ACL；由于第 3 步不检查返回值，日志仍显示 OK。settings 文件本身也没有被单独保护；即使目录之前被加固，只要文件后来被替换/复制并带宽 ACL，Protect-V4Acl 的目录早退也不会修复子项。

username 是明文（:115）；DPAPI 只覆盖 passwordDpapi。因此“凭据存储为 DPAPI 密文”的表述应限定为“仅密码”。

### 3.3 失败模式

| 场景 | 实测结果 | 影响 |
|---|---|---|
| settings 不存在 | Get-V4Settings -ErrorAction SilentlyContinue 仍抛出 settings.json not found | state-v4.ps1 直接 exit 1，无 JSON（沙箱实测） |
| DPAPI blob 被篡改 | CryptographicException / ArgumentException，-ErrorAction SilentlyContinue 不抑制 | state 崩溃；apply 落到 unexpected exit 1 |
| settings 被复制到另一用户/机器 | DPAPI user scope 解密失败（同一错误类别） | 无明确“重新 -Init”提示，故障码不是 11 |
| 目录 ACL 失败 | Protect-V4Acl 返回 false，但调用方忽略 | 无告警，日志仍成功 |

C-10 的关键不是“失败不安全”（它确实 fail-closed），而是失败不可诊断：状态检查本应报告 UNKNOWN/DEGRADED，却只打印 PowerShell 堆栈；这会让操作者绕过检查，而不是修复 DPAPI/ACL。

## 4. Protect-V4Acl 正确性、幂等性与锁死风险

隔离测试（%TEMP%，当前用户非提权）结果：

| 场景 | Protect-V4Acl 返回 | 结果 |
|---|---|---|
| 普通目录首次加固 | true | AreAccessRulesProtected=true；仅 CURRENT_USER / SYSTEM / ADMINISTRATORS FullControl |
| 再次调用 | true | 早退；CURRENT_USER FullControl 只有 1 条，幂等正常 |
| 先建子文件再加固父目录 | true | 子文件继承新 ACE，旧宽 ACE 消失；正常 |
| 已保护 DACL 含 CURRENT_USER + USERS ReadAndExecute | true | 早退，USERS 仍保留 |
| 未保护 DACL 含显式 Deny | true | 重建后 Deny ACE 被移除（本测试场景正常） |
| 文件级加固后删除/重建 | true | 新文件 protected=false，重新继承父 ACL；加固不持久 |
| owner | 不变 | 不调用 SetOwner；owner 为其他账户时不检测 |

结论：

- C-04 的早退条件 if ($acl.AreAccessRulesProtected -and $hasMe) { return $true } 只检查“DACL 受保护”和“当前用户有任意 ACE”。它不区分 Allow/Deny、不检查是否 FullControl、不检查是否存在 Everyone/Users/Authenticated Users、不检查 SYSTEM/Administrators ACE、也不检查 owner。一个曾经错误地留下 Users:Read 的目录，后续每次调用都会“成功”但永远不修复。
- 函数本身不会主动添加 Everyone/Users/Authenticated Users；风险来自保留既有的宽 ACE，不是新增。
- 锁死风险：函数在 ownerAdded 为 false 时不持久化 DACL（:144），这是正确的防锁死保护。但 $ownerAdded = $true 只表示打算添加，不检查 AddAccessRule 的返回值；极小概率下若 Add 返回 false 而原 ACE 已被移除，仍可能持久化一个没有当前用户的 DACL。
- 不设置 owner：如果目录被其他账户拥有，该 owner 仍保留隐式 READ_CONTROL/WRITE_DAC 能力，可以重新改 ACL；“已保护”不等于“只有当前用户/SYSTEM/管理员能控制”。
- 锁死风险评估：函数不会主动添加 Deny/Everyone，ownerAdded 检查降低了“移除全部 ACE 后未加回自己”的风险；真正的锁死面是既有 DACL（早退保留 Deny/只读）和 owner 非当前用户，而不是本函数新建的 ACE。
- C-05：Save-V4Settings、New-V4Snapshot、apply 全部把返回值丢弃或 | Out-Null；Write-V4Log 'DONE' 不区分 ACL 成败。安全控制失败而无告警，属于“控制存在但不生效”的典型缺陷。


## 5. 快照、备份与生成 profile

New-V4Snapshot（lib/V4.ps1:230-264）在停止应用后复制：

- clash-verge.yaml（运行时配置，含 secret: 与 proxies: 明文 password）；
- config.yaml、verge.yaml、profiles.yaml；
- profiles\*.yaml（订阅 profile，可能含订阅 URL/令牌）；
- manifest.json（哈希与系统代理记录）。

然后才 Protect-V4Acl -Path $dir（:262），且忽略返回值。备份根目录 $BackupDir 在模块加载时创建（:28-30），从不加固；快照没有加密、没有保留期限、没有清理策略，凭据轮换后旧密码仍留在旧快照。

这就是 C-01：

- 复制过程中以及复制完成到 ACL 生效之间，目录/文件继承父目录 ACL；在真实仓库中父目录含 Authenticated Users:Modify、Users:ReadAndExecute。
- 若进程被杀、磁盘满或 Set-Acl 失败，快照永久保留宽 ACL；而 apply 日志仍写 snapshot -> ...（apply-v4.ps1:117）。
- 即使 ACL 成功，快照仍是明文凭据库；把它复制到 U 盘、同步盘、备份或工单附件，ACL 不会跟随，风险立即变成“明文泄露”。
- 生成物中的明文来自 Build-V4Profile：password: "$($S.password)"（:444）与 Build-V4Runtime 的 secret: $Secret（:472）。
- C-07：apply 只在链路验证、系统代理设置成功后才对 v4-managed.yaml 和 runtime 文件调用 Protect-V4Acl（apply-v4.ps1:166-167）；失败路径会保留含密码的 managed profile。Clash 启动时重新生成 runtime，会重置文件 ACL（测试已复现重写后 protected=false），所以 runtime 的加固是瞬态的。
- C-13：manifest.json 的 SHA256 只能发现意外损坏，不能防篡改；能写 backup 的攻击者可同时改文件和 manifest，rollback -SnapshotDir 还接受任意目录，恢复链路没有签名/路径白名单。

### 5.1 临时暂存与 .bak

- apply 在 %TEMP%\v4-<guid> 写 p.yaml/r.yaml（含明文 password 与 runtime secret），finally 删除；进程被杀/断电会留下，且没有 ACL 加固（apply-v4.ps1:102-110）。
- Set-V4Atomic 在目标目录创建 .v4stage-<guid>.yaml（验证时含明文）与 .bak 旧文件；成功/失败通常清理，但异常终止会留下；动态测试确认 .v4stage 为 protected=false，目标目录在 appdata（lib/V4.ps1:289-311）。
- 这些临时文件不进入 git（*.bak 被忽略，TEMP 在仓库外），但 ACL 继承父目录，属于本地明文暴露；与 C-07 同一治理面。

## 6. 日志、脱敏、证据文件

### 6.1 文件权限

Start-V4Log（lib/V4.ps1:53-59）只在 evidence\ 下创建 .log，没有任何 Protect-V4Acl。真实仓库 proxy_v4/evidence 的 ACL 是继承的 Authenticated Users:Modify、Users:ReadAndExecute，因此日志对任何已认证本地用户可读（还可被修改）。日志包含：出口 IP、绝对快照路径、PID、时间、模式；虽非密码，但属于网络/主机指纹，且没有轮转/清理。

本地 ignored 日志（proxy_v2/test-results/*.log、proxy_v4/evidence/*.log 共 15 个）没有被 git 跟踪，这是好事；但它们仍在磁盘上，含 1 个唯一公网 IPv4（336 次）和 9 处用户目录路径。SECURITY-NOTES.md 关于“发布前移除日志”的说法对 git 成立，对本地残留不成立。

### 6.2 脱敏覆盖（合成 canary）

Get-V4Redacted（lib/V4.ps1:33-42）实测：

| 输入形态 | 是否遮住 | 说明 |
|---|---|---|
| 已 Register-V4Secret 的密码/用户名 | 是 | 字面量替换，长度 ≥4 |
| Basic YWJjOmRlZg==（长） | 是 | 8+ 字符 base64 |
| password: "alpha beta gamma" | **否** | 正则到空格即停，beta gamma 残留 |
| Basic dTpw（短） | **否** | 少于 8 字符不匹配 |
| socks5://user:pass@host | **否** | 不识别 URL userinfo |
| pass: / secret: / Bearer token | **否** | 未注册且无对应模式 |
| 长度 <4 的 secret | **否** | 明确跳过短 secret |
| 公网 IPv4 | 否 | 预期，但会进日志 |

FT15（tests/faultinject-v4.ps1:123-129）只验证“注册 secret + 长 Basic”两例，因此 13/13 全绿不能证明脱敏充分。当前调用点大多只记录 exit code/固定文案，缺口是潜在而非已证实的泄漏；但异常消息、未来日志字段或第三方输出一旦包含这些形态，防线会失效。

## 7. Git 历史、tracked 树与发布面

### 7.1 gitleaks

- 工具：gitleaks 8.30.1，默认规则，--redact，JSON 不保留原始报告。
- gitleaks git <repo> --log-opts=--all：5 个提交，0 findings。
- gitleaks dir <repo>：工作树（含 ignored 本地日志），0 findings。
- 合成高熵 token 验证：检出 1 条 github-pat，说明扫描器有效。
- 证据：proxy_v6/evidence/agent-c-gitleaks.json。

### 7.2 自定义扫描（gitleaks 默认规则不覆盖）

- DPAPI blob：0。
- GitHub token：0。
- 私钥头：0。
- 真实代理用户名/密码字面量：0；唯一命中的凭据形态是 proxy_v4/tests/faultinject-v4.ps1:124 的合成测试常量（值不保留），不是真实凭据。
- 历史：5 个提交/95 个 unique blob；从未跟踪 settings.json、backup/、*.log、*.bak、ConsoleHost_history*；没有删除文件，因此不存在“历史里曾提交后删除”的隐藏面。
- 提交作者：5 个提交全部使用 GitHub noreply，无个人邮箱。
- 邮箱：6 处机构支持地址（anthropic.com/服务商域名），0 处私人邮箱；未保存地址值。
- HEAD tracked 树：18 个唯一公网 IPv4、530 次、36 个文件；46 处绝对项目路径（19 文件）；2 处 Windows 用户目录路径（proxy_diag/apply-chain.ps1:9、proxy_diag/rollback.ps1:10，用户名不展开）。
- 本地 ignored 日志：1 个唯一公网 IP、336 次；9 处用户目录路径、20 处项目路径，未进 git。
- 证据：proxy_v6/evidence/agent-c-secret-pii-scan.json。

发布判断：仓库本身没有发现密码/token/私钥，这点应肯定；但“没有 tracked secret”不等于“运行时没有明文凭据”——C-01/C-07/C-09 都是本地数据面问题。IP/路径属于已披露的网络事实；SECURITY-NOTES.md:18 已承认端点 IP，但 18 个唯一 IP 与 46 处绝对路径的规模应让发布方再次决定是否接受。

### 7.3 .gitignore

.gitignore:1-5：

- backup/：匹配任意层级，快照被忽略（实测通过）。
- *.log、*.bak：任意层级，日志/备份文件被忽略（实测通过）。
- config/settings.json：只匹配根目录 config/settings.json；proxy_v4/config/settings.json 不匹配。
- config/.lock：同样只匹配根目录；proxy_v4/config/.lock 不匹配。
- tracked 敏感文件当前只有 proxy_v4/config/owner.json（无密码）；没有任何 settings/backup/log。

因此 C-11 是“未来误提交”风险：用户在 publish/proxy_v4 里运行 apply -Init 后，settings 会以 untracked 状态出现，git add -A 会把它（DPAPI blob + username）加入提交。修复应改为 **/config/settings.json、**/config/.lock 或 settings.json 通配。

## 8. 测试隔离、故障注入与供应链

### 8.1 故障注入不是隔离的

tests/faultinject-v4.ps1 第 12 行直接 dot-source 生产 ..\lib\V4.ps1，因此：

- $script:Root 指向生产 proxy_v4；模块加载会创建 config/、backup/。
- FT04/FT10 的 Enter-V4Lock 使用生产 config\.lock（:59-62,100-103），会在真实目录写 PID 锁，并可能与真实 apply/rollback 竞争。
- FT08/FT09 启动真实 state-v4.ps1（:86,93）；若 Clash 处于健康状态，state 会做 first-hop TCP 与外部 IP 请求，测试并非纯“只读路径/端口”。
- FT12（:108）对 C:\Windows\System32\drivers\etc\hosts 调用 Protect-V4Acl。非提权时通常 Set-Acl 失败并返回 false，看似无害；但以管理员运行会真正重建 hosts DACL（移除继承 ACE，添加当前用户/SYSTEM/Administrators FullControl）。这不是“失败注入”，而是真实系统安全配置修改。
- 因此 C-03 为高：该测试套件不应在真实主机上以提权方式运行；发布前应把 ACL 失败探针改成临时目录/只读路径，并把 lock/config 根重定向到临时目录。
- 由于工作树中另一代理已在加入 V4_TEST_MODE/V4_TEST_ROOT（未提交，未评审），本结论只针对 HEAD；合并后应重跑。

### 8.2 供应链

- 未发现 Import-Module、#Requires -Modules、Install-Module、Invoke-WebRequest、Invoke-Expression、npm/pip 依赖；所有 Python 仅标准库。DEPENDENCY-LOCK.md:12 这一点基本成立。
- 但 mihomo/clash-verge 来自本地安装目录，curl.exe/powershell 通过 PATH 解析（lib/V4.ps1:357、tests:86），没有签名/哈希校验；Get-V4Paths 优先信任 Get-Process clash-verge 的进程路径（:84-88）。在“同用户已被攻陷”前提下这不是新增边界，但属于可改进的完整性控制（C-14，低）。
- Add-Type 仅编译 wininet P/Invoke，无外部代码；可接受。

## 9. 文档准确性

SECURITY-AUDIT-V4.md 的两处声明需要修正：

1. 第 7 行“不接受密码参数；迁移时可显式传入（会进入命令历史，已在文档警告）”——代码明确有 -StaticPass（apply-v4.ps1:17,38），且我没有在 USER-GUIDE-V4.md 或该审计文档找到具体警告；建议删除参数，改为 Read-Host -AsSecureString 或环境变量/凭据管理器读取，并在文档中明确“不要通过命令行传密码”。
2. 第 9 行“快照目录 Protect-V4Acl（幂等、必须含 owner ACE）”——实测幂等性只在“首次成功重建”后成立；早退会保留宽 ACE，owner 从不校验，失败被忽略。

这不是文字洁癖：安全文档的过度声明会直接导致用户按错误假设操作（例如把快照当成“已受 ACL 保护”）。C-15 记录为低严重度文档缺陷。

## 10. 独立测试结果摘要

| 测试 | 结果 | 证据 |
|---|---|---|
| ACL 首次加固 / 子项继承 / 二次幂等 | 通过 | agent-c-security-tests.json acl.basic |
| ACL 早退保留 USERS | **失败**（返回 true，USERS ReadAndExecute 仍在） | acl.earlyReturn |
| 显式 Deny 移除 | 通过（Deny ACE 0 条） | acl.denyRule |
| 文件加固后重写 | **失败**（新文件 protected=false） | acl.fileLevel |
| owner 校验 | 未执行（函数不设置 owner） | acl.owner |
| DPAPI 往返 / blob 形态 | 通过（524 hex，01000000/d08c9ddf） | dpapi |
| 损坏 blob / 缺失 settings 的 state 行为 | **失败**（exit 1，无 JSON） | dpapi |
| settings 明文密码 | 0（仅 DPAPI 密文；username 明文） | settingsAtRest |
| 脱敏 7 类缺口 | **失败** | redaction |
| 日志 ACL | **未加固**（protected=false） | logging |
| 暂存 .v4stage 明文/清理 | 明文存在；成功/失败后无残留 | staging |
| 真实 apply/rollback/state | 未执行 | notExecuted |
| 自带 faultinject | 未执行（FT12 真实 hosts） | notExecuted |

## 11. 优先级建议

**P0（发布前必须处理或由用户明确书面接受）**

1. C-01：快照要么加密（DPAPI/凭据管理器包裹），要么不落盘明文；至少把 ACL 加固放在复制之前（先建 0700 语义目录，再写文件），检查返回值并失败即中止；备份根目录也要加固；增加保留期限/清理。
2. C-02：移除 -StaticPass（及 -StaticUser 的命令行密码组合），改为安全提示输入；文档改为“禁止命令行传密码”。
3. C-03：FT12 改为临时目录探针；故障注入 harness 用 V4_TEST_MODE/临时根隔离 config/backup/lock，禁止对 hosts 等系统路径调用 Protect-V4Acl。

**P1（尽快）**

4. C-04/C-05：早退条件改为“当前用户 FullControl + SYSTEM/Administrators + 无 Everyone/Users/Authenticated Users 宽 ACE”；校验 owner；所有调用方检查返回值并记录 WARN/ERROR；state 增加 ACL 检查。
5. C-07：生成 profile/runtime 前创建受保护目录/文件；失败路径清理含密码的 managed profile；每次启动后重新加固 runtime。
6. C-09：evidence 目录/日志文件显式 ACL；日志轮转/清理；或把日志移出仓库到受保护目录。
7. C-10：捕获 DPAPI 解密异常，返回专门错误码/UNKNOWN 状态并提示重新 -Init；不要让 state 打印堆栈后 exit 1。
8. C-11：修正 .gitignore 为 **/config/settings.json、**/config/.lock，并在 CI/发布脚本中运行 git ls-files 敏感路径检查。

**P2（记录/接受）**

9. C-08：扩展 Get-V4Redacted（URL userinfo、pass|pwd|secret|token、Bearer、带空格引号值、短 Basic），并让 FT15 使用表驱动用例。
10. C-12：发布方复核 18 个公网 IP、46 处绝对路径、2 处用户目录是否接受；本地 ignored 日志在上传/打包前清理。
11. C-13/C-14：如威胁模型包含“同机其他用户可写备份/安装目录”，再引入 manifest MAC/签名与二进制哈希；否则记录为接受风险。
12. C-15：修正安全文档；在 README 中明确“DPAPI 仅保护密码，不保护快照明文”。

未执行：凭据轮换、真实 apply/rollback、hosts ACL 测试、跨用户 DPAPI 试验、V6 合并后的复测。不得在报告中写“已修复/已验证”；以上均为待处理项。

## 12. 复现要点（不接触真实系统）

1. git show HEAD:proxy_v4/lib/V4.ps1 导出到 %TEMP%\agentc-security\lib\V4.ps1，dot-source；
2. 在 %TEMP% 下创建目录，调用 Protect-V4Acl 并用 Get-Acl 检查 ACE；早退场景先构造“protected + CURRENT_USER + USERS”DACL；
3. 调用 Save-V4Settings 使用合成 host/user/password，检查 settings.json 不含明文密码、ACL 是否仅当前用户/SYSTEM/Administrators；
4. 用损坏的 passwordDpapi 和缺失 settings 运行 state-v4.ps1 的沙箱副本，记录 exit code 与是否输出 JSON；
5. 用 Get-V4Redacted 跑表中 8 类合成输入；
6. Set-V4Atomic 的 validator 内检查 .v4stage-* 内容/ACL，验证成功与失败后的清理；
7. gitleaks 命令见 agent-c-gitleaks.json 的 command 字段；原始 JSON 报告已删除，只保留计数/规则 ID。

## 13. 证据文件

- proxy_v6/evidence/agent-c-gitleaks.json：gitleaks 版本、命令、history/worktree 0 findings、合成 canary 验证。
- proxy_v6/evidence/agent-c-secret-pii-scan.json：HEAD/历史/本地 ignored 的 DPAPI、token、私钥、邮箱、IP、路径计数与文件位置；不含值。
- proxy_v6/evidence/agent-c-security-tests.json：ACL、DPAPI、settings、脱敏、日志、暂存、state 失败的隔离测试结果；不含真实凭据。
- 本报告：proxy_v6/reviews/AGENT-C-SECURITY-REVIEW.md。

## 14. 限制

- 未做跨用户 DPAPI 解密（没有第二个账户），跨机器失败是根据 user-scope DPAPI 语义与损坏 blob 行为推断；
- 沙箱 %TEMP% 的基础 ACL 比真实 publish 仓库窄；真实仓库 ACL 已单独只读测量；
- gitleaks 默认规则不覆盖 DPAPI/IP/路径 PII，因此使用自定义正则；两者都不能证明“绝对没有 secret”，只能证明本次扫描范围内未命中；
- 评审期间工作树被并发修改，未评审 V6 改动；合并后应重新跑 ACL/DPAPI/发布扫描；
- 本报告没有执行任何真实系统修改，也没有轮换任何凭据。

**总体判断：安全 Gate = NOT PASS。** 最高风险 C-01（快照明文凭据 + 后置 ACL + 静默失败）；C-02/C-03 紧随其后。13/13 故障注入和“DPAPI 加密”不能覆盖上述数据面风险。
