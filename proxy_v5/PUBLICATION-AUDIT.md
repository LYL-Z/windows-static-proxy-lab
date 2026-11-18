# PUBLICATION-AUDIT

| 检查 | 方法 | 结果 |
|---|---|---|
| 提交内容含代理密码 | 逐文件 `git show HEAD:<file>` 比对 | **0** |
| 含账号用户名 | 同上 | **0** |
| 含 GitHub token 形态 | 正则 `gh[pos]_...` | **0** |
| 含 DPAPI 密文 | 正则 UUID 形态串 | **0** |
| 含私人邮箱 | 正则 qq/163/126/gmail | **0** |
| 备份 / Shell 历史 / settings.json | 已在首提交前排除 | 见 SECURITY-NOTES.md |

## 仍未脱离公开范围的信息（需用户确认）
- 静态 IP `72.245.197.103` 与第一跳出口 IP；
- 脚本内绝对路径 `D:\claude防封\...`；
- Windows 版本、Clash/Mihomo 版本、端口与进程名。

## 建议（未执行）
- 引入 Gitleaks 或 `git-secrets` 做 CI 级扫描；本项目已用等价逻辑本地扫描，但**未接入工具链**。
- 若确认 IP 属敏感，可改写为 `<STATIC_IP>` 后重新发布（需用户批准，**不擅自 rewrite 历史**）。