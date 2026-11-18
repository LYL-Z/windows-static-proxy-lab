# ROUND2-SECURITY-REVIEW

**对象**：commit `abe0eaa4b29f9d40b8157420d96fa09013d165da`（HEAD at dispatch）
**基线**：`36222c92c829a2ef08b71af2a3a3ff9a3c44b396`（只用于对比；其既有复审报告按“不可信输入”处理）
**评审类型**：独立第二轮软件与数据安全复审；不采信主代理或前序代理的自评。
**结论**：**安全 Gate = NOT PASS**。本轮提出 15 项 R2C：**2 高 / 6 中 / 7 低**。C-01..C-15 中 **3 项已关闭、7 项部分关闭、5 项未关闭**。
**最高剩余风险**：**R2C-01 安装/脚本树未受 ACL 保护**（环境前提，可被其他本地认证用户改写代码，从而绕过本轮所有 ACL/DPAPI 控制）；紧随其后是 **C-01 快照/备份长期保存明文凭据**与 **C-02 `-StaticPass` 命令行暴露**。

## 1. 范围、方法与边界

- 静态审阅 `proxy_v4/lib/V4.ps1`、`apply-v4.ps1`、`rollback-v4.ps1`、`state-v4.ps1`、`.gitignore`、V4/V5/V6 安全与发布文档、`proxy_v6/tests/` 及提交内证据。
- 代码与证据均以 `git archive abe0eaa` 导出的树为准。评审期间工作树被另一进程并发修改（`proxy_v6/evidence/v6/full.json` 被删除、出现未跟踪 `final.json`），因此不把工作树内容当作被审代码。
- 动态测试只在 `%TEMP%` 的独立测试根中执行：`V4_TEST_MODE=1`、`V4_TEST_ROOT=<temp>`，不读取/不写入真实 `proxy_v4/config`、appdata、HKCU、Clash、注册表、计划任务或凭据。
- 未执行真实 apply/rollback/state；未执行 `proxy_v4/tests/faultinject-v4.ps1`（其已废弃并重定向）；未做凭据轮换、系统 ACL 修改、历史改写或模块安装。
- 允许并实际运行的隔离套件：
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1 -Filter 'INF-*' -OutFile <temp>`
  以及 `-Filter 'F09-SUITE'`；均以 `-OutFile` 指向 TEMP，不写仓库证据。
- 扫描工具：gitleaks 8.30.1，`dir` 与 `git --log-opts=--all`，全部 `--redact`；原始报告只落 TEMP，且不保留 secret 值。另有自定义正则扫描覆盖 DPAPI、token、私钥、邮箱、IPv4、Windows 用户目录路径和凭据形态。
- 报告不打印真实密码、用户名、DPAPI 密文、公网 IP 值或邮箱值；只给计数、文件/行号和类别。

## 2. R2C 发现总表

| ID | 严重度 | 发现 | 主要证据 | 状态 |
|---|---|---|---|---|
| R2C-01 | **高** | 安装/脚本树可被 `Authenticated Users` 修改；脚本执行前无完整性校验，ACL/DPAPI 可被改写代码绕过 | `git archive` 树、真实 ACL 测量：`publish`、`proxy_v4`、`lib`、`apply-v4.ps1` 均 `AreAccessRulesProtected=false` 且含 `S-1-5-11 Modify`；`apply-v4.ps1:23`、`rollback:12`、`state:12` 直接 dot-source | OPEN（环境前提；文档未警告） |
| R2C-02 | **高** | `-StaticPass` 以明文进入命令行/进程列表/PSReadLine 历史；`SECURITY-AUDIT-V4.md:7` 仍称“不接受密码参数”且声称已有警告，实际没有 | `apply-v4.ps1:19,49-58`；`V4.ps1:498`；`SECURITY-AUDIT-V4.md:7`；`USER-GUIDE-V4.md` 无警告 | OPEN |
| R2C-03 | 中 | 读取路径不复核/修复 settings 与 config ACL；旧版本遗留的宽 ACL 不会被自动收敛 | 隔离测试：向 settings 注入 Everyone 后 `Get-V4Settings` 不修复；重新保存才修复。真实 `proxy_v4/config` 当前 `protected=false`（有 `Authenticated Users:Modify`） | OPEN |
| R2C-04 | 中 | `Restore-V4Files` 还原含明文凭据的 profile/runtime 时不重新加固目标 ACL；回滚/失败恢复可把明文文件留在宽 ACL 下 | 隔离测试：目标文件带 Everyone Read，还原后仍 Everyone Read；`V4.ps1:868-893` 只调用 `Set-V4Atomic`，无 `Protect-V4Acl` | OPEN |
| R2C-05 | 中 | V6 harness 证据目录/文件无显式 ACL；默认写入仓库 `proxy_v6/evidence/`，证据含测试输出和本地路径 | `Harness.ps1:36-47`、`:584`；真实 `proxy_v6/evidence`、`v6`、`final.json` 均 `protected=false` 且含 `Authenticated Users:Modify` | OPEN |
| R2C-06 | 中 | 公开树 PII 面扩大：新证据含 47 处/41 个文件的 Windows 用户目录路径（1 个用户名）；项目绝对路径增加 41 处/11 文件；`SECURITY-NOTES.md` 未披露用户名 | 自定义 HEAD 扫描：user path 49 处/43 文件（基线 2/2），project path 95 处/30 文件（基线 54/19）；位置集中在 `proxy_v6/evidence/selftest/` 与 `proxy_v6/evidence/v6/full.json` | OPEN（需发布方决定） |
| R2C-07 | 中 | 提交内证据与 `abe0eaa` 不对应：`full.json`、selftest 均记录 `git.head=36222c9`、`dirty=true`；harness 只记录 dirty，不阻止在脏树上出 PASS | `proxy_v6/evidence/v6/full.json`（75/75、head 36222c9、dirty true）；`evidence/selftest/canonical/selftest.json`（head 36222c9、dirty true）；`Harness.ps1:374-393` | OPEN |
| R2C-08 | 中 | 脱敏仍有缺口：JSON 引号键（`"password":"..."`、`"token":"..."`）不遮；SOCKS URL 的 userinfo 只遮 password、用户名仍可见；未加引号的 `user: a b` 只遮第一个 token；测试断言过弱 | `V4.ps1:50-61`；隔离测试 4 类泄漏；`Run-InfraCase.ps1:577-592` 只断言 `user:pass` 不存在；`Harness.ps1:73-81` 同样缺 JSON 键 | OPEN / 部分修复 |
| R2C-09 | 低 | `Test-V4AclHardened` 不校验 owner、不校验继承标志；`Protect-V4Acl` 从不设置 owner；非继承型 DACL 可被早退判定为“已加固”；添加当前用户 ACE 失败时仍可能持久化 DACL | `V4.ps1:529-575`；隔离测试：仅当前用户 FullControl、无继承的受保护目录被返回 true；子文件 ACL 出现额外 logon SID | OPEN |
| R2C-10 | 低 | 锁的陈旧回收/释放存在 TOCTOU：读完再 `Remove-Item`，中间可被另一进程替换，可能删除新持有者的锁 | `V4.ps1:638-641`（Enter）、`:656-663`（Exit）；未动态复现，代码路径确认 | SUSPECTED |
| R2C-11 | 低 | `.gitignore` 未覆盖 `**/config/transaction.json`；崩溃后该文件含绝对快照路径/PID，误 `git add -A` 会公开路径 | `.gitignore:1-8`；`git check-ignore` 对 transaction.json 不匹配；`V4.ps1:161-194` | OPEN |
| R2C-12 | 低 | 测试隔离依赖环境变量，不是强边界：`V4_TEST_APPDATA/RUNTIME/INSTALL/CORE` 可指向真实路径，测试/子进程不清理继承的 `V4_TEST_*` | `V4.ps1:300-317`；`TestSupport.ps1:92-151`；`Run-InfraCase.ps1` 只设置部分变量 | OPEN |
| R2C-13 | 低 | 供应链完整性未闭环：无第三方 PS/npm/pip 依赖，但 mihomo/curl 无哈希/签名校验；`Get-V4Paths` 信任运行中 `clash-verge` 的进程路径；curl 走 PATH | `V4.ps1:300-331,735,944-954,990-1003`；`DEPENDENCY-LOCK.md` | OPEN（低，需接受或改进） |
| R2C-14 | 低 | 安全/发布文档仍过度声明或状态不一致：`-StaticPass` 矛盾、owner ACE 声明不实、README 声称 credential redaction PASS、RELEASE-GATE 声称 HIGH 全部关闭；V6 Gate/Docs 仍写 0/12、P1 进行中 | `SECURITY-AUDIT-V4.md:7,9`；`README.md:34`；`RELEASE-GATE.md:5`；`proxy_v6/RELEASE-GATE-V6.md:4`；`proxy_v6/TASK-STATE.md:23-33` | OPEN |
| R2C-15 | 低 | 日志失败时 fail-open：`Start-V4Log` 失败只返回 false，apply 仅打印 WARN，rollback 直接忽略；无事件日志/回退，日志无轮转/保留 | `V4.ps1:72-91`；`apply-v4.ps1:26-27`；`rollback-v4.ps1:13`；`Write-V4Log:63-70` | OPEN |

## 3. C-01..C-15 关闭裁定

| ID | 裁定 | 依据（当前代码/隔离验证） |
|---|---|---|
| C-01 | **部分关闭** | `New-V4SnapshotFiles:756-757` 在复制前加固快照目录；`New-V4Snapshot:805` 加固 backup 根；失败会抛出而非忽略。快照复制文件实测只继承 SYSTEM/Administrators/当前用户，无 Everyone。但快照/备份仍长期保存**明文**代理密码、runtime `secret` 和全部订阅 profile；无加密、无保留期限/清理；复制到非 NTFS/同步盘即失去 ACL 保护。 |
| C-02 | **未关闭** | `-StaticPass` 仍在 `apply-v4.ps1:19`，进入命令历史/进程命令行；文档仍称“不接受密码参数”，也没有用户指南警告。见 R2C-02。 |
| C-03 | **已关闭** | `proxy_v4/tests/faultinject-v4.ps1:3-19` 已改为安全重定向到 V6 `Run-Tests.ps1`，不再对真实 hosts 调用 ACL；V6 套件用 `V4_TEST_MODE`/TEMP，`INF-GUARD-01` 4/4 阻断真实 HKCU/进程操作。未执行 deprecated 入口。 |
| C-04 | **部分关闭** | 早退条件已改为“DACL protected + 每个 ACE 为 Allow + SID ∈ {当前用户,SYSTEM,Administrators} + FullControl + 含当前用户”（`V4.ps1:529-548`），Everyone/Users 会被重建。但仍不校验/设置 owner、不校验继承标志；非继承型 DACL 可早退成功。见 R2C-09。 |
| C-05 | **部分关闭** | 写路径已 fail-closed：Save 目录/文件加固失败抛 12；快照失败抛错；事务中 `ProtectAcl` 失败抛 12（`V4.ps1:378,386,805`；`Invoke-V4ApplyTransaction:238-241`）。但读路径 `Get-V4Settings` 与 state 不校验 ACL；旧宽 ACL 不会自愈。见 R2C-03。 |
| C-06 | **部分关闭** | `Save-V4SettingsObject` 先加固 config 目录再写，写后加固 settings 文件；启动阶段无明文窗口。但 settings 文件是“先写后加固”；DPAPI 仍是 user-scope、无附加熵，username 明文；同用户进程可解密。 |
| C-07 | **部分关闭** | TEMP staging 目录在写 p.yaml/r.yaml 前加固（`apply:106-115`）；但 appdata 内的 `.v4stage-*.tmp` 仍是普通继承 ACL；目标 profile/runtime 在链验证后才加固；崩溃可留下明文；还原路径不加固（R2C-04）；Clash 重写 runtime 会重置 ACL。 |
| C-08 | **部分关闭** | 已支持 password/passwd/pwd/pass/secret、username/user、token、Basic、Bearer、URL userinfo，带空格引号值也能整行遮；短 Basic（4 字符）已覆盖。但 JSON 引号键、URL 用户名、未引号多 token、2 字符未注册 secret 仍泄漏；测试只覆盖弱断言。见 R2C-08。 |
| C-09 | **部分关闭** | V4 `Start-V4Log` 现在先加固 evidence 目录再建日志，并对日志文件再加固；隔离测试 `INF-LOG-02` 通过。但真实 `proxy_v4/evidence` 的旧日志仍是宽 ACL，直到下一次运行；V6 harness 证据不加固；无轮转/清理。见 R2C-05/R2C-15。 |
| C-10 | **已关闭** | 损坏 DPAPI blob 的隔离测试：`state-v4.ps1` exit 3、输出可解析 JSON、state=FAILED、reason 含 settings/credential、无 PowerShell 堆栈；`Get-V4Settings` 将解密失败映射为 fault 11。 |
| C-11 | **已关闭** | `.gitignore` 现有 `**/config/settings.json`、`**/config/.lock`、`backup/`、`**/backup/`、`*.log`、`*.bak`；`git check-ignore` 对嵌套 settings/.lock 命中；tracked 树/历史无 settings、backup、log、lock。残余 `transaction.json` 见 R2C-11。 |
| C-12 | **未关闭（发布面反而扩大）** | 18 个唯一公网 IPv4/530 次/36 文件与基线相同；但 Windows 用户目录路径从 2 处/2 文件增至 49 处/43 文件（1 个用户名），项目绝对路径从 54/19 增至 95/30；6 处机构邮箱、0 私人邮箱。新证据未做路径脱敏。见 R2C-06。 |
| C-13 | **未关闭（低）** | 快照 manifest 仍是 SHA256 而非签名/MAC；`-SnapshotDir` 仍接受任意路径。缓解：`Test-V4SnapshotManifest` 已限制文件名/路径遍历并逐文件校验；恢复目标限制在 appdata/profiles。可接受但需明确威胁模型。 |
| C-14 | **未关闭（低）** | 无第三方 PowerShell 模块/npm/pip（已复核 Python 仅标准库、无 Import-Module/Install-Module）；但 mihomo/curl 无哈希/签名校验，`Get-V4Paths` 信任进程路径，`curl.exe` 走 PATH。见 R2C-13。 |
| C-15 | **未关闭** | `SECURITY-AUDIT-V4.md:7` 的“不接受密码参数/已在文档警告”不实；`:9` 的“必须含 owner ACE”不实；README 的 credential redaction PASS 过度；RELEASE-GATE 的 HIGH 全关闭与两轮复审结论冲突；V6 Gate/Docs 仍为 0/12/进行中。见 R2C-14。 |

**计数**：已关闭 3（C-03/C-10/C-11）；部分关闭 7（C-01/C-04/C-05/C-06/C-07/C-08/C-09）；未关闭 5（C-02/C-12/C-13/C-14/C-15）。

## 4. 关键发现详情

### R2C-01（高，OPEN，环境前提）
真实 ACL 测量（只读）显示 `publish`、`proxy_v4`、`proxy_v4/lib` 与 `apply-v4.ps1` 都是 `AreAccessRulesProtected=false`，含 `S-1-5-11 Authenticated Users Modify` 和 `S-1-5-32-545 Users ReadAndExecute`。脚本直接 dot-source 同目录的 V4.ps1，执行前没有文件哈希/签名校验。

后果：任何其他本地认证用户都可改写 `V4.ps1`/apply 脚本；下一次 operator 运行时，恶意代码以 operator 身份读取 DPAPI 明文、快照明文和系统代理。此时把 config/backup/evidence 加固到“仅当前用户/SYSTEM/Administrators”并不能保护秘密，因为保护秘密的代码本身可被替换。

这是环境前提，不是 `abe0eaa` 引入的代码缺陷；但本轮 C-01/C-06 的 ACL 结论只有在安装树也受保护时才成立。若威胁模型明确只有“单用户、无其他本地账号/服务”，可降为低并书面接受；否则必须先限制安装树 ACL（例如只授予当前用户/SYSTEM/Administrators），并在文档中写明。报告不执行该 ACL 修改。

### R2C-02（高，OPEN）
`apply-v4.ps1:19` 保留 `[string]$StaticPass`；`-Init` 显式迁移路径把它放入进程命令行（`apply:49-58`），并可能进入 PSReadLine `ConsoleHost_history`。同用户进程可读命令行；shell 历史是明文文件。当前 `SECURITY-AUDIT-V4.md:7` 声称“不接受密码参数；迁移时可显式传入（会进入命令历史，已在文档警告）”，但代码有参数，且 `USER-GUIDE-V4.md` 没有任何警告。

建议：删除 `-StaticPass`，改用 `Read-Host -AsSecureString`、`Get-Credential` 或 Windows 凭据管理器；若必须非交互，至少从受保护的环境/文件读取并明确警告不要写入历史；同步修正文档。

### R2C-03（中，OPEN）
隔离测试步骤：`Save-V4Settings` 创建 config/settings（两者均 protected，仅当前用户/SYSTEM/Administrators）；随后给 settings 加 Everyone Read；调用 `Get-V4Settings` 成功读取，ACL 仍含 Everyone。再次 `Save-V4Settings` 才修复。`Get-V4Settings:355-373` 只读 JSON/解密，不调用 `Protect-V4Acl`；`state-v4.ps1:16` 也不检查。

真实 `proxy_v4/config` 当前是宽 ACL（有 settings 时会是旧版本遗留的宽 ACL）。apply 读取旧 settings 时不会先收敛，只会在下一次 Save 时修复。建议：apply 在锁内、读 settings 前对 config 目录和 settings 文件执行加固并检查返回值；state 至少输出 `aclOk=false`，不修改。

### R2C-04（中，OPEN）
隔离测试：appdata 的 `profiles/v4-managed.yaml` 与 `clash-verge.yaml` 含 Everyone Read；快照创建成功；修改后 `Restore-V4Files` 返回 ok=true；还原后的两个目标仍含 Everyone Read。原因：`Restore-V4Files:868-893` 只调用 `Set-V4Atomic`；`Set-V4Atomic:910-942` 使用 `File.Replace` 时会保留目标原 ACL，且从不调用 `Protect-V4Acl`。`rollback-v4.ps1:38` 与 apply 失败恢复 `Invoke-V4Recovery:125-128` 都走这条路径。

后果：回滚/失败恢复可能把含明文密码的 managed profile、含 runtime `secret` 的 runtime 文件留在宽 ACL 下，且脚本随后启动 Clash。建议：对凭据承载文件在还原后强制 `Protect-V4Acl` 并校验；失败则回滚/退出 40；增加“目标 ACL 宽”隔离测试。

### R2C-05（中，OPEN）
`Harness.ps1` 的 `Write-HarnessJsonFile:36-47` 直接 `WriteAllText`，没有 ACL 加固；默认 `OutFile` 在 `proxy_v6/evidence/v6/`（`:584`）。真实 `proxy_v6/evidence`、`proxy_v6/evidence/v6` 和未跟踪 `final.json` 均为 `protected=false`，含 `Authenticated Users:Modify`/`Users:ReadAndExecute`。证据含测试输出、绝对路径和本地用户名。建议：证据写到受限目录（TEMP/用户独占），或对 evidence 目录/文件显式加固；提交前做路径脱敏；增加清理/保留策略。这与 C-09 的 V4 日志修复是两套代码路径，不能互相覆盖。

### R2C-06（中，OPEN，发布决策）
HEAD 树（abe0eaa）自定义扫描：
- Windows 用户目录路径：49 处、43 文件、1 个用户名；基线 2 处/2 文件；新增 47 处/41 文件，集中在 `proxy_v6/evidence/selftest/` 与 `proxy_v6/evidence/v6/full.json`。
- 项目绝对路径（`D:\claude防封`）：95 处/30 文件；基线 54/19。
- 盘符路径行：653 行/367 文件（多数为证据 JSON）。
- 公网 IPv4：18 个唯一/530 次/36 文件，与基线相同；`SECURITY-NOTES.md` 只概括承认“静态端点 IP”，`proxy_v5/PUBLICATION-AUDIT.md` 明示了一个 IP。
- 邮箱：6 处机构地址、0 私人地址；`Run-InfraCase.ps1:584` 的 `user:pass@example.com` 是测试 URL，被正则误计为邮箱。
- 本地 ignored 文件：26 个，gitleaks 0；5 个唯一 IPv4/741 次、7 处用户路径、14 处项目路径、0 个凭据形态文件。

新证据把本地用户名和主机路径写入公开 Git 历史，且 `SECURITY-NOTES.md` 未披露用户名。历史改写需用户明确批准，本报告不执行。建议发布前把证据中的用户目录/项目路径替换为占位符，或由用户书面接受；若重写历史，另行批准。

### R2C-07（中，OPEN）
`proxy_v6/evidence/v6/full.json` 在提交中记录：`git.head=36222c9`、`dirty=true`、75/75、outcome=PASS；`evidence/selftest/canonical/selftest.json` 同样记录 `head=36222c9`、`dirty=true`。这些证据生成于基线/脏工作树，不能证明 `abe0eaa`。`Harness.ps1:374-393` 只记录 dirty，不将其作为失败条件；测试可在未提交代码上出 PASS。

本轮独立运行（HEAD=abe0eaa）INF 39/39、F09 1/1 均为 exit 0，但我的输出只落 TEMP；提交内证据仍需在干净树、精确 commit 上重跑并替代。建议：Release Gate 要求 `git.dirty=false` 且 `head=目标 commit`；否则证据标记 STALE/不接受。

### R2C-08（中，OPEN/部分）
隔离测试（合成值）：
| 输入形态 | 结果 |
|---|---|
| `password: "alpha beta gamma"` | 遮住（整行 ***） |
| `pass: abc` / `secret=xyz` / 4 字符 Basic / 3 字符已注册 secret | 遮住 |
| `socks5://user:pass@host` | 变为 `socks5://user:***`，**用户名仍可见** |
| `user: alpha beta` | 变为 `user: *** beta`，第二个 token 仍可见 |
| `{"password":"..."}`、`"password": "..."`、`{"token":"..."}` | **完全不遮** |
| `<3 字符且未注册` | 不遮（低风险） |

`INF-REDACT-02` 只断言 `user:pass` 不存在，因此 `user:***` 通过；没有 JSON 键用例。`Protect-HarnessText` 有同样的 JSON 缺口。建议：先做 URL userinfo 正则再执行 user/username 正则；支持 JSON 引号键；把 URL 用户名也当作敏感；表驱动测试覆盖上述全部形态。

### 低风险项（R2C-09..R2C-15）
- **R2C-09**：`Test-V4AclHardened` 不看 owner/继承；隔离测试构造“仅当前用户 FullControl、无继承”的受保护目录，`Protect-V4Acl` 返回 true 并早退。owner 非当前用户时，owner 仍可重写 DACL。建议增加 owner 校验/设置和继承标志检查；若无法设置 owner 则至少报告 WARN。
- **R2C-10**：`Enter-V4Lock` 的陈旧锁删除和 `Exit-V4Lock` 的删除都是“读—比较—删”，不是原子 compare-and-delete；竞争窗口内可能删掉新锁。未动态复现，标 SUSPECTED。建议改为保持 `FileStream` 独占句柄（`FileShare.None`）或命名 mutex，退出时释放/关闭。
- **R2C-11**：`.gitignore` 未覆盖 `**/config/transaction.json`；崩溃后 journal 含快照绝对路径/PID。建议加入忽略规则；不要忽略已跟踪的 `owner.json`（无密码）。
- **R2C-12**：测试隔离靠 `V4_TEST_*` 环境变量；`Get-V4Paths` 接受任意 `V4_TEST_APPDATA/RUNTIME/INSTALL/CORE`，fixture 清理不完整。若调用者 shell 继承真实路径，测试可能写真实 appdata 后才在 Start/Stop guard 失败。建议 fixture 入口清空/白名单所有 `V4_TEST_*`，并断言路径位于 `V4_TEST_ROOT` 下。
- **R2C-13**：无第三方模块/包（已复核），但 mihomo/curl 无哈希/签名；`Get-V4Paths` 会信任运行中的 `clash-verge` 进程路径；`curl.exe` 走 PATH。低风险，建议记录接受或校验二进制/固定绝对路径。
- **R2C-14**：文档过度声明/状态不一致，详见 §6；安全 Gate 不能引用这些文档作为证据。
- **R2C-15**：日志失败 fail-open；`Start-V4Log` 失败时 apply 仅 WARN，rollback 静默；无事件日志/轮转。建议至少在状态证据中记录 `logOk=false`，并在文档中说明审计日志不可用。

## 5. 独立验证证据

### 5.1 gitleaks 8.30.1
| 扫描 | 结果 |
|---|---|
| `git archive abe0eaa` 精确树（`gitleaks dir`，--redact） | **0 findings**（1.26 MB） |
| 当前工作树（`gitleaks dir`，--redact） | **0 findings**（工作树被并发修改，仅作参考） |
| 历史（`gitleaks git --log-opts=--all`，--redact） | **0 findings**；6 commits；587 个唯一 blob |
| 合成 canary（TEMP 随机 token） | 检出 **2** 条（`github-pat`、`generic-api-key`），`--redact` 生效，值未保留 |

未发现 DPAPI blob、GitHub token、私钥头、真实代理口令/用户名。唯一 DPAPI 头形态出现在 `proxy_v6/evidence/agent-c-secret-pii-scan.json:21`，是**扫描模式字符串**，不是 blob。合成凭据只出现在测试 fixture（`proxy_v6/tests/cases/fixtures/Run-InfraCase.ps1`、`proxy_v6/tests/repro/Repro-F09.ps1`），不是真实凭据。

### 5.2 ACL / DPAPI / 脱敏隔离结果
| 测试 | 结果 |
|---|---|
| 快照目录加固后再复制；源文件带 Everyone Read | 快照目录 protected；复制文件只继承 SYSTEM/Administrators/当前用户，**无 Everyone**；文件本身 `protected=false` 但 ACE 集受限 |
| Save settings | config 与 settings 均 protected；无 Everyone |
| settings 被注入 Everyone 后读取 | `Get-V4Settings` 不修复；重新 Save 才修复 |
| `Start-V4Log` | evidence 目录与日志文件均 protected；无 Everyone |
| 宽 ACL 目标 + `Set-V4Atomic` 的 stage | stage `.v4stage-*.tmp` `protected=false`（继承目标目录 ACL）；正常路径会清理 |
| 宽 ACL 目标 + `Restore-V4Files` | 还原后目标仍 Everyone Read（R2C-04） |
| 非继承型受保护目录 | `Protect-V4Acl` 早退返回 true（R2C-09） |
| 不存在的路径 | `Protect-V4Acl` 返回 false（调用方应据此失败） |
| 损坏 DPAPI blob + state-v4 -Json | exit 3；JSON 可解析；state=FAILED；reason 含 settings/credential；无堆栈 |
| 脱敏常见形态 | 引号密码、短 Basic、secret=、URL password、3 字符注册 secret 均遮 |
| 脱敏 JSON/URL 用户名/多 token | 仍泄漏（R2C-08） |

证据文件：`proxy_v6/evidence/v6/round2-security-evidence.json`（不含真实值）。

### 5.3 测试
| 命令 | 结果 |
|---|---|
| `Run-Tests.ps1 -Filter 'INF-*' -OutFile <TEMP>` | **39/39 PASS，exit 0**；evidence 记录 HEAD=abe0eaa |
| `Run-Tests.ps1 -Filter 'F09-SUITE'` | **1/1 PASS，exit 0**；HEAD=abe0eaa |
| `faultinject-v4.ps1` | **未执行**（已废弃，重定向到 V6） |
| 真实 apply/rollback/state | **未执行** |

INF 套件的覆盖包括：ACL 首次/二次/Everyone 移除、日志 ACL、settings DPAPI/ACL、Snapshot 路径遍历/哈希、Atomic 清理、锁 token/陈旧、Journal、YAML 注入、test-mode guard、DryRun 无副作用。它**不覆盖**：settings 读取 ACL 修复、rollback 还原 ACL、JSON 脱敏、URL 用户名、`-StaticPass`、harness 证据 ACL、证据 dirty/commit 绑定、锁 TOCTOU。

## 6. 发布面与文档准确性

- **IP/路径/邮箱**：18 个唯一公网 IPv4/530 次/36 文件（与基线相同）；6 处机构邮箱、0 私人邮箱；新增 47 处用户目录路径/41 文件；95 处项目绝对路径/30 文件。`SECURITY-NOTES.md` 承认“静态端点 IP”和脚本绝对路径，但未披露用户名；`PUBLICATION-AUDIT.md` 已明示静态 IP。历史改写未获授权，本报告不执行。
- `SECURITY-AUDIT-V4.md:7` 与 `-StaticPass` 矛盾；`:9` 的 owner ACE 不实；`:8` 脱敏描述未覆盖 JSON/URL 用户名。
- `README.md:34` 声称 “PASS on ... credential redaction”；在 R2C-08 未关闭前不成立。
- `proxy_v4/RELEASE-GATE.md:5` 声称 “HIGH 缺陷全部关闭/第三方复审确认”，与两轮复审的 C-01/C-02 及其它 HIGH 项冲突；该文档还引用已废弃的 faultinject。
- `proxy_v6/RELEASE-GATE-V6.md:4` 仍写 0/12；`TASK-STATE.md:23-33` 仍写 P1 进行中；但提交内 `full.json` 声称 75/75。状态文件与证据不一致，不能用于最终验收。
- `faultinject-v4.ps1` 头注释写 “74 isolated cases”，实际 available=75；`USER-GUIDE-V4.md` 仍把 faultinject 当诊断步骤。
- `REPORT-V4.md:28` 含真实出口 IP，`:32/35` 的 13/13 与“exit 表达式”说法已过时；不应作为 abe0eaa 证据。
- `CONFIG-INTEGRITY.md:7` “不解析 YAML”与 `Get-V4Socks5Candidates` 的迁移正则不一致（文档后文已承认 profiles.yaml 文本修改，属表述问题）。

## 7. 供应链

- 未发现 `Import-Module`、`#Requires -Modules`、`Install-Module`、npm/pip 依赖；Python 仅标准库；`Add-Type` 只有 wininet P/Invoke。`DEPENDENCY-LOCK.md` 的“无第三方模块/包”基本成立。
- 但 mihomo/clash 与 `curl.exe` 无哈希/签名校验；`Get-V4Paths` 优先 Program Files，找不到时信任运行中 `clash-verge` 的进程路径；`curl.exe` 通过 PATH。低风险，建议固定绝对路径/校验版本或记录为接受。
- gitleaks 是本次评审工具（winget 安装），不是仓库依赖；未安装任何新模块到仓库。

## 8. 验收结论与阻断项

**安全 Gate：NOT PASS。** 本轮没有发现新的“可直接远程利用”漏洞，但仍有高风险本地数据面/环境面和证据完整性问题。

**P0（发布前必须处理或用户书面接受）**
1. **R2C-01**：限制安装/脚本树 ACL，或明确接受“单用户、无其他本地账号/服务”的威胁模型；否则 ACL/DPAPI 保护可被代码替换绕过。
2. **C-02/R2C-02**：移除 `-StaticPass`（或改为安全输入）并修正文档；这是仍未关闭的 HIGH。
3. **C-01**：快照/备份要么加密/封装，要么明确接受“本地明文 + ACL”并增加保留/清理；不要复制非必要订阅 profile。
4. **R2C-03/R2C-04**：读路径复核/修复 ACL；回滚/失败恢复对凭据文件重新加固。
5. **R2C-05/R2C-07**：harness 证据 ACL；Release Gate 要求 clean tree + 精确 commit，重跑并替换 36222c9/dirty 证据。
6. **R2C-06**：发布前决定是否脱敏用户名/路径；不得在未获批准时改写历史。
7. **R2C-08**：修复 JSON 键/URL 用户名/多 token 脱敏，并补表驱动测试。

**P1（尽快）**
8. R2C-09 owner/继承校验；R2C-10 锁原子性；R2C-11 .gitignore journal；R2C-12 测试环境清理；R2C-15 日志可观测性；R2C-13 供应链完整性；R2C-14 文档纠正。

**若用户明确接受**“单用户环境 + 本地明文快照 + 公开 PII + 低风险供应链”，可把 Gate 降为“有条件接受”，但必须在发布文档中逐条记录；当前没有这样的书面接受。

**未执行**：凭据轮换（V5-03 仍 BLOCKED-USER）、真实 apply/rollback、真实系统 ACL 修改、历史改写、跨用户 DPAPI 试验。不得在报告中写“已轮换/已验证真实回滚”。

## 9. 限制

- 工作树在评审期间被并发修改（`full.json` 删除、`final.json` 未跟踪）；所有代码/证据结论以 `git archive abe0eaa` 为准，未把并发工作树当作被审对象。
- 未做跨用户/跨机器 DPAPI 解密（无第二账户）；根据 user-scope DPAPI 语义与损坏 blob 行为推断。
- 未执行真实 apply/rollback/state；未运行废弃 faultinject；未跑完整 F07/F08/F10 套件（仅 INF/F09）；真实 appdata/系统 ACL 与 TEMP 不同。
- 锁 TOCTOU 为代码路径判定，未动态复现；ACL owner 场景无法在本机安全构造“其他 owner”目录。
- gitleaks 默认规则不覆盖 DPAPI/IP/路径 PII；自定义正则不能证明“绝对没有 secret”，只能证明本次扫描范围未命中。
- 未轮换凭据、未改历史、未改系统设置；报告不包含真实密码、用户名、DPAPI 密文、公网 IP 或邮箱值。

---

**独立判断**：abe0eaa 对 C-03/C-10/C-11 的关闭有实证，对 C-01/C-04..C-09 有实质改进，但不能据此宣布安全 Gate 通过。最高剩余风险是安装/脚本树完整性（R2C-01）与快照/命令行的明文凭据（C-01/C-02）；在 R2C-03/R2C-04/R2C-05/R2C-07/R2C-08 关闭前，最终验收不应采信提交内 75/75 或旧 RELEASE-GATE 的自评。
