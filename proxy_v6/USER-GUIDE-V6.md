# USER-GUIDE — V6.0（中文）

## 1. 查看当前状态

在实际部署目录使用 Windows PowerShell 运行 `state-v4.ps1`。
用 `windowsTargetsClash` 检查 Windows 手动代理是否指向预期监听端口，
用 `chainStatus` 检查经该监听端口的 HTTPS 出口。即使 Windows 指向其他代理，也会独立验证链路。
当仅验证了代理规则命中的 IPv4 HTTPS 流量时，应用自身网络、DNS、UDP 和 WebRTC 的覆盖范围需要分别核实。

路由判断可以在 Mihomo 的只读连接视图中核对实际命中规则与代理链。`GEOIP,CN,DIRECT`
按目标地址匹配。一条 HTTPS 出口探测仅说明该目标的路径。
`udpProxied` 是托管 SOCKS5 节点的配置值，`udpDataPlane` 显示数据面测试状态。
SOCKS5 的 UDP ASSOCIATE 回复、实际 UDP 往返、Chrome WebRTC 候选各自提供不同证据。

## 2. 安全使用
1. 本仓库脚本只用于用户自己的 Windows 主机；不要在生产网络未备份时运行 apply。
2. **不要直接运行测试**来验证生产网络；V6 测试全部使用 `V4_TEST_MODE=1` + TEMP，且生产写门闩默认关闭。
3. `-Init` 不接受命令行密码；显式迁移使用 `-CredentialFile <受保护文件>`。旧的 `-StaticPass`/`-StaticPassFile` 会被墓碑参数拒绝。优先从当前 Clash profile 迁移；不要用 argv/Shell 历史传密码。
   凭据文件需先加固 ACL：`. .\proxy_v4\lib\V4.ps1; Protect-V4Acl -Path .\credential.txt`（或等价的 `icacls` 规则）。未加固文件会被拒绝并提示 `ACL is not hardened`。
4. 快照（backup）含明文代理凭据；ACL 已加固但未加密；不要把 backup 上传网盘/工单。
5. 配置 `settings.json` 含 DPAPI 密文和明文 username；只允许当前用户读取。
6. 任何真实 apply 前先运行 `apply-v4.ps1 -DryRun`；失败时看 `config\transaction.json`，不要手工删除。

## 3. 常用命令（真实执行前先备份）
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\apply-v4.ps1 -DryRun
    powershell -NoProfile -ExecutionPolicy Bypass -File proxy_v4\state-v4.ps1 -Samples 4 -IntervalSeconds 5
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
- 查看 `firstHopStatus` 和 `recoveryAction`。Clash 尚未就绪时先检查核心与监听。首跳 TCP 不可用、CONNECT 超时或握手回复异常时，优先检查首跳进程和网络。存在待处理事务、托管标记缺失或代理意图不明时，先核对状态。
- 显示 `CONSIDER_MANUAL_REPAIR` 时，检查是否有其他客户端正在写入 Windows 代理。备份并取得授权后，可运行 `apply-v4.ps1 -Repair`。脚本要求 Clash 已保存启用系统代理且托管配置可核实，并在修改前复核静态 HTTPS 出口。修改后复测浏览器的国内和国际访问以及出口。
- 开机或节点切换后采样可记录依赖何时恢复。自动恢复需要真实生命周期证据，前台检查不会接管 Windows 代理。
- 回滚在锁内优先选择待处理事务指向的快照，并沿用记录的 `-KeepSystemProxy` 意图。可显式指定经过校验的快照。恢复时原样保留文件字节，包括 BOM。若应用尚未监听，或重启后系统代理的启用状态、目标发生漂移，回滚返回非零并保留事务记录。先核对应用和 Windows 最终状态，再决定是否重试。
- `-Samples` 在一次前台运行中有限次复核，适合观察依赖启动或节点变更。等待时间从上一轮结束计起。JSON 多样本模式每行一个对象，退出码代表末次采样；交付证据时应脱敏。
- `-DryRun` 在受限临时目录生成候选文件并验证，不写项目日志或锁。它会探测首跳，核心也可能尝试下载缺失的地理数据。

## 6. 已知残余
- 真实 apply/rollback/重启/睡眠/Wi-Fi 未执行（**WAITING-USER**）；24h/72h DEFERRED-BY-USER。
- NexIP 密码未轮换（BLOCKED-USER）。
- 快照明文凭据、公开仓库 IP/路径/用户名范围：待用户确认。
- journal 无 commit 阶段；崩溃后保守要求回滚（R2A-06）。
