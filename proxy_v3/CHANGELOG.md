# 变更记录（CHANGELOG）

## V3.0 — 2026-11-18 03:00–04:00

**新增**
- `proxy_v3\state.ps1` —— 五态状态机（HEALTHY / DEGRADED / FAILED / RECOVERING / UNKNOWN），只读，退出码可脚本化。
- `proxy_v3\invoke-faultinjection.ps1` —— 故障注入测试台（FI1–FI5），**5/5 通过**，证据 `evidence\fault-injection.json`。
- `proxy_v3\tools\stun_probe.py` —— UDP/STUN 出口探测（解释 WebRTC 与 HTTPS 出口不一致）。
- `proxy_v3\tools\udp_relay_test.py` —— 验证 UDP 是否真的经 Clash 中继（结论：没走静态 IP）。
- `proxy_v3\tools\proto_probe.py` —— ALPN/HTTP2 与 SOCKS5 UDP ASSOCIATE 能力探测。
- `proxy_v3\tools\monitor-longrun.py` —— 长稳监测，**区分首试成功率与重试后成功率**、连续失败长度、按小时分布、可续跑。
- 文档：`REPORT-V3` / `INDEPENDENT-REVIEW` / `NETWORK-MATRIX` / `IP-DUE-DILIGENCE` / `SECURITY-REVIEW` / `ACCOUNT-SECURITY` / `PROVIDER-QUESTIONS` / `LONG-RUN-STATUS` / `USER-GUIDE-V3` / 本文件。
- `lib\Common.ps1` 复制为 V3 自带副本（V3 自包含，不改动 V2 历史）。

**修复（P0 安全）**
- PowerShell 历史中的 1 次明文密码 → 备份后打码（1 → 0）。
- 3 个 V1 参考副本中的明文密码 → 改为 `<REDACTED-ROTATE-ME>`。
- 两棵备份树 ACL 收紧（`icacls /inheritance:r`，仅 当前用户/SYSTEM/Administrators）。
- 全树复扫：文档/日志/脚本中的明文暴露 = **0**。

**修复（工具/测试）**
- 故障注入 FI2 的**测试自身缺陷**：在持有独占句柄时读取文件导致误判 → 改为先释放句柄再读。修正后 5/5 通过。

**结论性发现**
- **UDP 不走静态 IP**：直连 STUN 与经 Clash 中继的 STUN **都**得到 `142.111.173.93`。这是 WebRTC/QUIC 与 HTTPS 出口不一致的根因。
- **WinHTTP 为 Direct**：只用 WinHTTP 的应用完全绕过代理。
- HTTP/2 可用（ALPN `h2`）；HTTP/3 本机 curl 无法测试；主机无全局 IPv6。

## V2.0 — 2026-11-18 02:00–02:35

- 事务式 `apply-v2.ps1` / `rollback-v2.ps1` / 只读 `status.ps1`。
- 动态发现安装目录、配置目录、当前 profile、mihomo 控制管道（不再硬编码）。
- 快照 + SHA256 校验回滚；ACL 收紧（含一次锁死事故与修复）。
- 300 次验收 **300/300**，p50 2678 ms，p95 3201 ms；三窗口对照；连接复用 0.35 s。
- 故障恢复 4/4；真实回滚往返。
- 定位 P1 根因：Clash 进程退出 + StarSky 重占系统代理。

## V1.0 — 2026-11-17 23:50 – 2026-11-18 01:45

- 分阶段协议探测（TCP → SOCKS5 → CONNECT → TLS），`close_latency.py` 用 1×RTT 判定"谁关闭连接"。
- 证明：中国大陆来源接入被服务端立即关闭；美国来源正常。
- 建立 `dialer-proxy` 双跳（StarSky → NexIP），验收 20/20、11.3 分钟。
- 首次发现：Clash 处于"直连"模式、系统代理被三方争夺。
