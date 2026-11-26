# 安全审查（SECURITY-REVIEW）

审查时间：2026-11-18 03:13–03:25。范围：凭据、配置文件、备份、脚本、日志、浏览器扩展元数据。

## 1. 凭据的现实

Mihomo 的 `socks5` 节点**只能**以明文保存用户名密码。这是内核配置格式决定的，无法在"继续使用该代理"的前提下消除。因此本地必然存在明文副本，能做的是**收敛暴露面**，不是假装它不存在。

## 2. P0 审计结果（已处置）

扫描范围：`C:\CAB-Lab\` 下全部 `.md/.txt/.json/.jsonl/.log/.ps1/.py`，外加 PowerShell 历史、配置目录、备份目录。
（比对方式：把已知密码读入内存做精确子串匹配，**只输出文件路径与计数，不输出明文**。）

### 2.1 发现

| # | 发现 | 严重度 | 说明 |
|---|---|---|---|
| 1 | **17 个文件**含明文密码 | 高 | V1 参考副本 3 个 + V1 备份 2 个 + V2 快照 12 个 |
| 2 | **PowerShell 历史含 1 次密码** | **高** | `ConsoleHost_history.txt` 中被记录过一次 |
| 3 | 备份目录 ACL 未收紧 | 中 | `proxy_v2\backup`、`proxy_diag\backup` 仍继承 `Authenticated Users`/`Users` |
| 4 | 配置目录 ACL 已收紧 | 低（正面） | `LWMoQxn0PeIP.yaml`、`clash-verge.yaml` 均为 `protected=True`，仅 3 个主体 |

### 2.2 处置

| 动作 | 结果 |
|---|---|
| 历史文件：先备份，再把密码替换为 `<REDACTED-ROTATE-ME>` | 出现次数 **1 → 0**；原始命令形状保留 |
| V1 参考副本（`US-Static-fixed.yaml`、`clash-verge.WORKING.yaml`、`profile.WORKING.yaml`）改为占位符 | 4 处已替换；这些文件不参与任何回滚 |
| 两个备份树用 `icacls /inheritance:r` 收紧到 当前用户/SYSTEM/Administrators | `protected=True`，各 3 条规则 |
| 复扫 | **文档/日志/脚本中的明文暴露 = 0** |

### 2.3 有意保留的残余风险

- **V2 快照里的 YAML 仍含明文密码**——因为 `rollback-v2.ps1` 依赖它们还原可用配置。删除或打码会让回滚失效。已用 ACL 限制访问，并在 `LONG-RUN-STATUS.md` 记录为已知残余风险。
- 任何以当前用户身份运行的进程、以及本机管理员，**仍能读到**这些文件。
- **唯一根本解法是重置密码**（见 §5）。

## 3. 一次真实事故的复盘（V2 遗留，本轮已复核）

V2 首版 `Protect-PrivatePath` 对**文件**使用了目录专用的继承标志 `ContainerInherit,ObjectInherit`。
`FileSystemAccessRule` 构造抛异常且被 `catch` 吞掉 → **当前用户的 ACE 没加上**，ACL 只剩 SYSTEM 与 Administrators → 非管理员会话立即失去读权限（`ReadAllText: Access is denied`）。

修复：`icacls /reset` 恢复继承 → 改函数按文件/目录分别取标志 → `Set-Acl` 后**回读文件自检**，失败返回 `$false`。

本轮复核：两个配置文件的 ACL 均为 `protected=True` 且包含当前用户 FullControl，可正常读取 → **已验证修复**。

教训（写进代码规范）：**任何降权操作必须带可读性自检**。

## 4. 浏览器扩展（元数据审计）

只读取了 `manifest.json` 的**名称与权限声明**；**没有**读取 Cookie、密码库、历史记录、页面内容或任何令牌。

共 **7 个不同扩展**（跨 7 个 Chrome 配置），其中 4 个声明了高权限：

| 扩展 ID | MV | 权限数 | 敏感权限 | 名称 |
|---|---|---|---|---|
| `hehggadaopoa` | 3 | 18 | `debugger, downloads, history, nativeMessaging, scripting, tabs` | ChatGPT |
| `ajnnogdfpilb` | 3 | 8 | `tabs, scripting, debugger, nativeMessaging` | 本地化名 |
| `nbmnklcgnddb` | 3 | 9 | `debugger, nativeMessaging, tabs, scripting` | 本地化名 |
| `bhghoamapcdp` | 3 | 5 | `scripting` | 本地化名 |
| `ghbmnnjooekp` | 3 | 4 | —— | 本地化名 |
| `cejckpjfigeh` | 3 | 1 | —— | 本地化名 |
| `nmmhkkegccag` | 2 | 6 | —— | 本地化名 |

**怎么解读**：`debugger` + `nativeMessaging` 组合意味着该扩展可附加到标签页调试协议并能与本机原生程序通信，属于**最高权限档**。这不代表它恶意——很多生产力/自动化扩展确实需要——但它意味着：**一旦该扩展被投毒或供应链攻击，攻击者获得的能力接近本地程序**。

建议（未执行，需用户确认）：
1. 逐个核对来源是否为 Chrome 应用商店官方条目、开发者是否为可信方；
2. 停用手头不用的扩展，尤其是 `debugger` 类；
3. 不要为任何扩展授予"读取所有网站数据"而它并不需要；
4. 与支付/账号相关的操作使用干净配置。

## 5. 必须由用户完成的动作（P0）

1. **到 NexIP 后台重置代理密码**（这是唯一能真正消除已暴露凭据的动作）。
2. 重置后执行 `apply-v2.ps1 -Mode NEXIP -AcknowledgeCredentialAccess` 写回本地（或由我协助）。
3. 确认重置密码**不会导致 IP 变更**（已列入 `PROVIDER-QUESTIONS.md` 第 10 问）。
4. 复核 7 个浏览器扩展的必要性。

## 6. 未做的事（边界）

- 未读取、复制或导出任何 Cookie、会话令牌、保存的密码；
- 未上传任何私密数据到第三方检测服务（所有 IP 信誉查询只用了公开 IP 这一项事实）；
- 未伪造身份、时区、地理位置或设备指纹；
- 未关闭 Defender/防火墙。
