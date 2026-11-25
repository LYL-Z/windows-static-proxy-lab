# V6.9 验收矩阵

本地分支 `v69/isolated-privacy`，继承提交 `05072a3`。本文件补上 README 已经指向、但此前没有落盘的验收矩阵。生产代理、防火墙、客户端开关和路由都没有在本轮修改。

八项原文保存在需求分支，不在这里改写。工程实施只覆盖通用网络隐私、授权范围内的可靠性、浏览数据管理和故障恢复。账号处置规避、所在地伪装、指纹欺骗和身份验证规避不在实施范围内。

## 八项要求

| # | 原文要求的工程对应 | 状态 | 证据与边界 |
| --- | --- | --- | --- |
| 1 | 代理意外断开后的失败关闭 | PARTIAL | 新增进程级守卫：健康监听关闭或守卫进程被结束时，作业内的子进程停止向回环接收端发送，作业外的对照进程继续发送。用户关闭模式下子进程继续发送。第二守卫抢不到锁。零网络能力的 AppContainer 在 connect 阶段超时（10060），接收端 0 次，记为 UNKNOWN。覆盖范围只有守卫启动的进程。隔离 Chrome 的直连对照仍然可达。没有部署整机防火墙阻断。 |
| 2 | 经确认的站点数据清理 | PARTIAL | 临时资料里，选定主机的合成 Cookie 和 localStorage 可被 Clear-Site-Data 清除，对照主机保留。常见 Flash 遗留目录未找到。不把清理说成消除设备身份或账号关联，也不自动清理真实个人资料。 |
| 3 | DNS 不绕过已声明的路径 | PARTIAL | 隔离 DNS 查询、否定应答和代理侧解析均有接收端计数。受控 DoH 能区分缓存命中和再次查询。Windows 默认解析器与 Chrome 内建 DoH 为 NOT_TESTED。 |
| 4 | IPv6 不形成未经验证的公网出口 | PARTIAL | 分阶段探测：IPv4 TCP/UDP 回环回显 PASS。IPv6 TCP 在 connect 得到 10013，接收端没有载荷，记为 BLOCKED。IPv6 UDP 在 recv 超时，没有 Winsock 错误，记为 UNKNOWN。10013 不是整机保护已经生效。公网 IPv6 仍是此前快照：全局地址 0、默认路由 0。过滤组件未定位，沙箱规则未停用。 |
| 5 | WebRTC 不使用未声明的地址 | PARTIAL | 临时 Chrome 的默认实验能完成 UDP 数据通道，限制非代理 UDP 的实验没有收集到候选，STUN 接收端为 0。该开关只作用于临时进程，没有写入日常浏览器。TURN、真实通话和生产页面为 NOT_TESTED。 |
| 6 | DNS、IPv6、WebRTC 同时保持可解释 | PARTIAL | 三项分别保留自己的状态。没有一项“全部干净”的合并结论。 |
| 7 | 正常访问保持可用，异常时不把未知路径当成已验证 | PARTIAL | 系统代理仍启用且指向 `127.0.0.1:7897`，未启用自动配置脚本。百度与 GitHub 的 HTTPS 状态码均为 200。让某个服务看到指定地区或住宅地址不在实施范围内；物理位置是否符合服务条款也不能由出口地址代替。 |
| 8 | 已知代理故障可以诊断并有限恢复 | PARTIAL | 快照回滚在用户已经关闭代理时退出 32，不把代理重新打开。事务在重启前把这个决定写入日志；续跑和不同目标的竞争已注入。失败恢复如果被重启重新打开同一代理，会再关掉。`171d060` 的完整回归是 114/114，退出码 0，跳过 0。生产目录仍是 `854b6d6`，没有部署。 |

## 验收门

| 门 | 状态 | 说明 |
| --- | --- | --- |
| CONTINUITY_GATE | PASS | 接管 `05072a3` 及未提交的文档。未执行 reset、clean 或覆盖。修改前副本在本地 `outputs/2026-11-24-V6.9-takeover/pre-edit`。 |
| CODE_GATE | PARTIAL | 新增进程级失败关闭、套接字分阶段探测、只读故障分类，并修正三处事务收尾。独立审查指出的回执和保留代理选择问题已有定向测试。快照回滚重新打开代理的问题尚未改。 |
| NETWORK_GATE | PASS | 只读复测时百度与 GitHub 均为 200，系统代理目标未变。范围限于这两次 HTTPS 状态码。 |
| PRIVACY_GATE | PARTIAL | 已测路径、明确拒绝、未知路径和未测生产路径分开记录。不能把告警或单次出口查询当成阻断。 |
| RECOVERY_GATE | PARTIAL | 隔离恢复用例通过。真实 StarSky 自停、重启和睡眠未在本轮复现。 |
| TRANSACTION_GATE | PASS | `171d060` 完整回归 114/114，含 INF-ROLLBACK-08/09/10。证据目录 `proxy_v6/evidence/v6/20261125-012826-235`。Git 记录该次工作树 dirty，原因是未跟踪的本地证据和编译产物，不是已跟踪源码改动。 |
| SKILL_GATE | PARTIAL | “检查我的代理为什么没有正常工作”进入 Diagnose，再由 `Get-ProxyDoctorFaultClass` 分类。夹具 21/21。版本号仍是 2.0.0 RC2。没有默认管理员权限，也没有自动修复。 |
| PUBLICATION_GATE | PARTIAL | Draft PR #4 基于 PR #1 的当前头，尚未合并。历史材料里的终点地址仍按既有审计处理。本轮没有把凭据写入仓库。 |
| PRODUCTION_GATE | WAITING_USER | 未授权改写生产配置、防火墙、TUN、DNS 或 IPv6 栈。 |

## 本轮没有关闭的问题

- IPv6 TCP 回环返回 10013。三条已启用的 `codex_sandbox_offline_block_*` 出站阻止规则覆盖 `::1`，但 IPv4 回环和经代理的外部 HTTPS 仍然成功，所以还不能确定拒绝来源。规则未改动。
- IPv6 UDP 回环超时，不能解释成已经阻断。
- sing-tun 适配器处于连接状态，wintun 驱动正在运行，而 Clash 保存的 tun 开关为关闭。归属进程未绑定，所以没有改动它。
- 隔离浏览器的直连对照在代理故障期间仍能到达接收端。进程级守卫没有保护已经在运行的浏览器。整机失败关闭需要单独授权。
- 指定测试程序的出站阻止没有做成。当前令牌创建防火墙规则被拒绝，规则没有留下，沙箱规则数量没有变化。这不是整机保护验收。
- 故障期间的生产应用、系统 DNS、浏览器 DoH、代理 UDP 和真实 WebRTC 通话仍未验收。

## 尚未授权的操作

这些操作可以回滚，但现在不做：

1. 停用 `codex_sandbox_offline_block_loopback_tcp` 和 `codex_sandbox_offline_block_loopback_udp`，复测 `::1` 的 connect 与 recv，再按结果恢复。
2. 为指定测试程序添加并删除一条出站阻止，用来验证整机失败关闭。不改现有三条沙箱规则，不关闭 Defender。
3. 在生产目录替换 `apply-v4.ps1`、`rollback-v4.ps1`、`state-v4.ps1` 和 `lib\V4.ps1`。替换前保留四个文件的哈希，失败时按同一组文件换回。
4. 重启 StarSky、Clash，或修改系统代理、TUN、DNS、IPv6 和启动项。

只读分类命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\proxy_v6\tests\repro\V69Lifecycle.ps1
```

分类自检命令：

```powershell
python .\proxy_v6\tests\repro\V69Protocols.py --self-test
```
