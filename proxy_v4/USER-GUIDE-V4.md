# USER-GUIDE-V4

## 日常

```powershell
# 状态（只读）
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\state-v4.ps1

# 应用（StarSky 需在"加速中"）
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\apply-v4.ps1

# 回滚
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\rollback-v4.ps1 -List
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\rollback-v4.ps1
```

## 首次/重装

```powershell
powershell -ExecutionPolicy Bypass -File D:\claude防封\proxy_v4\apply-v4.ps1 -Init
```
（从当前 Clash 配置一次性迁移到 `config\settings.json`，密码以 DPAPI 加密保存）

## 退出码

`apply-v4`：0 成功 / 11 设置 / 20 第一跳 / 30 启动超时 / 31 链路验证 / 32 系统代理 / 33 锁占用 / 40 还原失败
`rollback-v4`：0 / 40 失败 / 41 系统代理未能保持
`state-v4`：0 HEALTHY / 2 DEGRADED / 3 FAILED

## 权限与风险

- 全部以**当前用户**运行，不需要管理员；不写 HKLM、不改任务计划、不动防火墙。
- 唯一系统改动是 HKCU 的 WinINET 代理与 Clash 配置文件。
- `settings.json` 含 DPAPI 密文，泄漏后仅同用户可解；仍建议限制目录访问。
- **不要**把 `proxy_v4` 放到共享/同步盘。

## 故障顺序

1. `state-v4.ps1` 看状态与 reasons
2. StarSky 是否加速中（`Test-NetConnection 127.0.0.1 -Port 11119`）
3. `apply-v4.ps1` 重新应用
4. 仍失败 → `rollback-v4.ps1`
5. 仍异常 → `tests\faultinject-v4.ps1` 定位层级

## V6 安全警告

- `-Init` 已不接受命令行密码；显式迁移改用 `-CredentialFile <受保护文件>`。旧的 `-StaticPass`/`-StaticPassFile` 会被拒绝。优先从当前 Clash profile 迁移。
- `backup/` 快照含明文代理凭据；ACL 已加固但未加密，不要上传或共享。
- 真实 apply 前先 `-DryRun`；失败时不要手工删除 `config\transaction.json`，先看 ISSUE-LEDGER/R2A-06。
