# V6.9 验收矩阵

本地分支 `v69/isolated-privacy`，继承提交 `05072a3`。本文件补上 README 已经指向、但此前没有落盘的验收矩阵。生产代理、防火墙、客户端开关和路由都没有在本轮修改。

八项原文保存在需求分支，不在这里改写。工程实施只覆盖通用网络隐私、授权范围内的可靠性、浏览数据管理和故障恢复。账号处置规避、所在地伪装、指纹欺骗和身份验证规避不在实施范围内。

## 八项要求

| # | 原文要求的工程对应 | 状态 | 证据与边界 |
| --- | --- | --- | --- |
| 1 | 代理意外断开后的失败关闭 | PARTIAL | 新增进程级守卫：健康监听关闭或守卫进程被结束时，作业内的子进程停止向回环接收端发送，作业外的对照进程继续发送。用户关闭模式下子进程继续发送。第二守卫抢不到锁。零网络能力的 AppContainer 在 connect 阶段超时（10060），接收端 0 次，记为 UNKNOWN。覆盖范围只有守卫启动的进程。隔离 Chrome 的直连对照仍然可达。没有部署整机防火墙阻断。本地重跑（退出码 2、汇总 UNKNOWN、四个作业场景 PASS）详见下文「进程失败关闭的本地重跑」。 |
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

## 进程失败关闭的本地重跑

本节把 `cab/d-protect` 的独立文档并进来，不再另建一份边界文件。依据是 `proxy_v6/tests/repro/v69-failclose/failclose.py` 的实现，以及 2026-11-28 在基线 `f2454c0` 上的一次本地重跑。它不授权新增、修改或删除防火墙规则，也不授权关闭 Defender，或改动代理、DNS、IPv6、TUN、路由和启动项。不能把它写成整机断网开关：套件打印的覆盖声明是 `processes started inside this job only`。

在工作树根目录执行，未调用防火墙 cmdlet：

```powershell
python proxy_v6/tests/repro/v69-failclose/failclose.py
```

进程退出码 **2**。汇总状态 `UNKNOWN`，回环地址 `127.0.0.1`。四个作业场景为 `PASS`，同文件里的 AppContainer 场景为 `UNKNOWN`，所以汇总不是通过。`rollup` 只有在四个作业场景都是 `PASS`、且 AppContainer 场景恰好是 `BLOCKED` 时才返回 0；任一作业场景为 `FAILED` 或 AppContainer 为 `FAILED` 时返回 1；其余非通过状态返回 2。

| 场景 | 状态 | 本次观察到的结果 |
| --- | --- | --- |
| `listener_close` | PASS | 守卫退出码 0，作业内子进程退出码 3，健康事件 `terminate`。安静窗口内作业内新标记 0，作业外新标记 9。 |
| `guard_killed` | PASS | 守卫退出码 9，子进程退出码 0 且已结束。作业内新标记 0，作业外新标记 10。 |
| `user_disabled` | PASS | 健康事件 `action` 为 `ignore`。关闭后作业内又送达 2 个标记，子进程、守卫、作业外对照都还活着。随后放开守卫标准输入，观察到子进程退出码 0 且已结束；该事后观察不参与本场景的通过条件。 |
| `second_guard` | PASS | 第二个守卫退出码 2，事件 `lock_busy` 且 `attempts` 为 2，没有 `ready`。第一个子进程和守卫仍活着，作业内标记继续增加（增量 4）。 |
| `appcontainer` | UNKNOWN | 受限探测的令牌是 AppContainer（`appcontainer` 为 1），阶段 `connect`，Winsock 10060，进程退出码 10060，接收端没有 `appcontainer` 标记。不受限对照退出码 0，阶段 `ok`，Winsock 0，接收端收到对照标记。 |

10060 在判定函数里与超时、退出码 72、缺少结果一样，保持 `UNKNOWN`。`BLOCKED` 还要求阶段是 `connect`、Winsock 与进程退出码都是 10013、对照成功，并且接收端没有该进程的数据。这次超时不能改写成操作系统已经拒绝该套接字，也不能改写成整机出站已被切断。

收尾时，套件只结束了它自己启动且映像匹配的作业外对照进程（退出码 74），`orphans` 为空。当前用户的 AppContainer 映射里没有名称含 `FailClose` 的配置。测试目录、探测程序和结果文件上没有留下 `S-1-15-2-` 访问项。脚本会在同目录生成 `loopback_probe.exe` 和 `runtime\`；这些是运行产物，不纳入提交。

同一次只读预检 `python proxy_v6/tests/repro/v69-container/check_offline.py --self-test` 退出码 **2**：`Offline.wsb` 静态配置为 PASS，九个内存中的异常输入全部 REJECTED，系统目录没有 `WindowsSandbox.exe`，`sandboxRuntime` 为 NOT_TESTED。预检没有启动访客，也没有改防火墙。`proxy_v6/tests/repro/v69-program-block/program_block.py` 会创建并删除一条防火墙规则，本轮没有运行。

作业对象的范围：`guard` 创建一个匿名作业（`CreateJobObjectW` 名称为空），只设置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`，并用 `QueryInformationJobObject` 回读；标志没置上就关闭句柄并失败。随后以 `CREATE_SUSPENDED` 启动发送进程，`AssignProcessToJobObject` 之后检查该子进程在作业内、守卫进程自己不在这个作业内，再 `ResumeThread`。分配失败时，守卫把这个尚未恢复的子进程以退出码 74 结束。健康信号是守卫连到 `127.0.0.1` 上另一个监听套接字：`armed` 在健康监听关闭后调用 `TerminateJobObject`，`guard_killed` 靠守卫进程消亡后最后一份作业句柄关闭触发 kill-on-close，`user_disabled` 只发 `ignore` 并阻塞在标准输入。锁文件必须位于该测试目录内，`LockFileEx` 独占锁失败后等待 50 毫秒再试一次，两次都失败就以退出码 2 返回。生产脚本和桌面程序没有调用这个再现脚本；`CreateJobObjectW` 与 `TerminateJobObject` 的调用只写在 `failclose.py`。

这次实验没有覆盖的范围：

- 作业外的进程继续使用自己的网络。四个作业场景都要求作业内标记停止新增之后 `unguarded` 仍继续送达，本次均已观察到。已经在运行的浏览器、Clash、StarSky 和其他桌面程序不会被放进这个作业。
- 守卫进程被显式排除在自己的作业之外；结束作业成员不会凭作业成员身份结束守卫。
- 只设置了 kill-on-close 一项作业限制。代码没有测试孙进程、脱离作业、嵌套作业，也没有测试别的进程另持一份作业句柄；句柄仍被别处持有时，关闭守卫自己的那一份不会触发 kill-on-close，这条路径没有用例。
- 作业是匿名的，不写入启动项，重启后不存在。
- 触发器是套件自己的回环 TCP 关闭，不是生产代理故障检测，也不转发用户流量；发送端不测量公网、UDP、IPv6 或 DNS。
- AppContainer 场景单独编译 `loopback_probe.c`，创建一个名为 `V69.FailClose.` 加随机后缀的临时配置，网络能力数量为 0，只让该进程对 `127.0.0.1` 做 TCP bind/connect/send/recv；结果对象的范围字段是 `this process only`。它不约束其他进程，也不代替 [AppContainer 结果](V69-CONTAINER.md) 里那套 IPv4/IPv6 TCP/UDP 实验，那套本轮没有重跑。
- `Offline.wsb` 描述的是访客从启动起关闭网络，宿主里原有的程序仍按各自配置联网；本次只做了静态预检，访客运行仍是 NOT_TESTED。
- Clash 代理组去掉 DIRECT 只去掉该组内部的直连回退；`skills/windows-proxy-doctor/references/reliability-gaps.md` 写明它不覆盖不走系统代理的程序、UDP、DNS，以及被关闭或改写的系统代理。

进程终止、测试模式、套接字拒绝是三件不同的事。**进程终止**是上面的作业路径：`armed` 在健康监听关闭后结束作业内进程，杀死守卫则靠最后一份作业句柄关闭；两种都是那些进程退出，套接字随进程消失，作业外发送端仍可连接接收端。**测试模式**不安装网络过滤：`proxy_v4/lib/V4.ps1` 在 `V4_TEST_MODE=1` 时 `Start-V4Clash` 和 `Stop-V4Clash` 直接返回 true，`Get-V4AppPids` 返回空列表，没有安装测试注册表写入器时系统代理写入抛出拒绝，`Enable-V4ProductionWrites` 返回 false；这些分支通过只说明真实启停或真实代理写入被跳过或拒绝。**套接字拒绝**是进程仍在时 Winsock 返回拒绝：`program_block.py` 的覆盖声明是一个临时可执行文件、仅 TCP、远端 `127.0.0.1`，它把“退出码 10013 且接收端没有数据”记为 `NETWORK_BLOCK`，接收端仍收到数据则是 `FAILED`，10060、退出码 4 或其他非零退出且接收端没有数据记为 `UNKNOWN`；该脚本会调用 `New-NetFirewallRule` 和 `Remove-NetFirewallRule`，所以本轮没有运行。AppContainer 只有在单进程、对照成功、`connect` 的 10013 且接收端为零时才记 `BLOCKED`；对照进程同样得到 10013 时，[AppContainer 结果](V69-CONTAINER.md) 把它记为主机回环条件，不能单独证明该策略或整机防火墙已经生效。

新的生产防火墙规则未获授权：[集成验收](CAB-INTEGRATION.md) 要求防火墙、DNS、TUN、IPv6、启动项和客户端重启各自单独授权；[操作边界](V69-OPERATOR.md) 写明本候选的实验和诊断不需要修改宿主防火墙，全机出站阻断会同时影响国内网站和局域网。`PRODUCTION_GATE` 仍是 `WAITING_USER`。指定程序的出站阻止实验和生产用的整机失败关闭都还没有授权；已有的 `codex_sandbox_offline_block_*` 规则保持不动。

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
