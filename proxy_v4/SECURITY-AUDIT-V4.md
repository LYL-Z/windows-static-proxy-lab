# SECURITY-AUDIT-V4

| 项 | 结果 |
|---|---|
| 明文密码存在于文档/日志/脚本 | **0**（全树复扫） |
| 凭据存储 | settings.json 内 **DPAPI 密文**；仅生成配置时短暂明文 |
| 命令行参数 | 不接受密码参数；迁移时可显式传入（会进入命令历史，已在文档警告） |
| 日志脱敏 | `Get-V4Redacted`：已知秘密 + `password=` + `Basic <b64>`（FT15 PASS） |
| 备份 ACL | 快照目录 `Protect-V4Acl`（幂等、必须含 owner ACE） |
| 旧凭据 | **仍有效，未轮换** → 唯一剩余高风险 |
| 浏览器扩展 | 7 个，4 个持 debugger/nativeMessaging；仅元数据，未读 Cookie/令牌 |

## 结论

本机侧暴露面已收敛到"必要的明文配置 + 受 ACL 保护的快照"。**彻底解决只能靠轮换**。