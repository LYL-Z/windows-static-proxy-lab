# USER-GUIDE — V6.0（中文）

## 1. 当前生产状态
- Windows 系统代理：**关闭**（ProxyEnable=0，ProxyServer 保留 127.0.0.1:7897）。
- 直连验证：百度 HTTP/HTTPS、Google、ipify 均 200。
- Clash 7897 仍监听；经 Clash 访问 Google/ipify 可用，百度返回 502（链路把国内也发往美国静态代理）。
- 不要在未确认前重新开启系统代理；如需静态链，先加 `GEOIP,CN,DIRECT` 并验证。

## 2. 安全使用
1. 本仓库脚本只用于用户自己的 Windows 主机；不要在生产网络未备份时运行 apply。
2. **不要直接运行测试**来验证生产网络；V6 测试全部使用 `V4_TEST_MODE=1` + TEMP，且生产写门闩默认关闭。
3. `-StaticPass` 会进入命令行/Shell 历史；优先用 `-Init` 从当前 Clash profile 迁移。若必须显式传参，事后清理历史。
4. 快照（backup）含明文代理凭据；ACL 已加固但未加密；不要把 backup 上传网盘/工单。
5. 配置 `settings.json` 含 DPAPI 密文和明文 username；只允许当前用户读取。
6. 任何真实 apply 前先运行 `apply-v4.ps1 -DryRun`；失败时看 `config\transaction.json`，不要手工删除。

## 3. 常用命令（真实执行前先备份）
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\apply-v4.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\apply-v4.ps1 -Init
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\apply-v4.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\rollback-v4.ps1 -List
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\rollback-v4.ps1

## 4. 测试（隔离）
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\Run-Tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v6\tests\self\SelfTest.ps1
- 退出码：0 通过；1 失败；2 零执行；3 框架异常；4 证据写失败。
- 测试不会写真实 HKCU；没有 test registry writer 的写请求会被拒绝。
- 若测试时出现任何 HKCU/WinHTTP 变化，立即停止并报告（FT21 专门检查）。

## 5. 故障恢复
- 如果浏览器 ERR_PROXY_CONNECTION_FAILED：先读 HKCU ProxyEnable/ProxyServer；若值异常，关闭系统代理即可恢复直连。
- 如果 Clash 7897 无监听：关闭系统代理，检查 Clash 核心/端口，再决定是否重启。
- 不要为修复代理而改路由、TUN、IPv6、StarSky 配置；先保留可上网状态。

## 6. 已知残余
- 真实 apply/rollback/重启/睡眠/24h/72h 未执行（DEFERRED-BY-USER）。
- NexIP 密码未轮换（BLOCKED-USER）。
- 快照明文凭据、公开仓库 IP/路径/用户名范围：待用户确认。
- journal 无 commit 阶段；崩溃后保守要求回滚（R2A-06）。
