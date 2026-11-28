# CAB 保护边界

本文件根据 `proxy_v6/tests/repro/v69-failclose/failclose.py` 的实现，以及 2026-11-28 在 `cab/d-protect`（基线 `f2454c0`）上的一次本地重跑，记录进程级失败关闭实际覆盖的范围。它不授权新增、修改或删除防火墙规则，也不授权关闭 Defender，或改动代理、DNS、IPv6、TUN、路由和启动项。

不能把它写成整机断网开关。套件打印的覆盖声明是 `processes started inside this job only`。

相关记录：[集成验收](CAB-INTEGRATION.md) · [AppContainer 结果](V69-CONTAINER.md) · [验收矩阵](V69-ACCEPTANCE.md) · [操作边界](V69-OPERATOR.md)

## 本次重跑

在工作树根目录执行，未调用防火墙 cmdlet：

```powershell
python proxy_v6/tests/repro/v69-failclose/failclose.py
```

进程退出码 **2**。汇总状态 `UNKNOWN`，回环地址 `127.0.0.1`。四个作业场景为 `PASS`，同文件里的 AppContainer 场景为 `UNKNOWN`，所以汇总不是通过。`rollup` 只有在四个作业场景都是 `PASS`、且 AppContainer 场景恰好是 `BLOCKED` 时才返回退出码 0；任一作业场景为 `FAILED` 或 AppContainer 为 `FAILED` 时返回 1；其余非通过状态返回 2。

| 场景 | 状态 | 本次观察到的结果 |
| --- | --- | --- |
| `listener_close` | PASS | 守卫退出码 0，作业内子进程退出码 3，健康事件 `terminate`。安静窗口内作业内新标记 0，作业外新标记 9。 |
| `guard_killed` | PASS | 守卫退出码 9，子进程退出码 0 且已结束。作业内新标记 0，作业外新标记 10。 |
| `user_disabled` | PASS | 健康事件 `action` 为 `ignore`。关闭后作业内又送达 2 个标记，子进程、守卫、作业外对照都还活着。随后放开守卫标准输入，观察到子进程退出码 0 且已结束；该事后观察不参与本场景的通过条件。 |
| `second_guard` | PASS | 第二个守卫退出码 2，事件 `lock_busy` 且 `attempts` 为 2，没有 `ready`。第一个子进程和守卫仍活着，作业内标记继续增加（增量 4）。 |
| `appcontainer` | UNKNOWN | 受限探测的令牌是 AppContainer（`appcontainer` 为 1），阶段 `connect`，Winsock 10060，进程退出码 10060，接收端没有 `appcontainer` 标记。不受限对照退出码 0，阶段 `ok`，Winsock 0，接收端收到对照标记。 |

10060 在判定函数里与超时、退出码 72、缺少结果一样，保持 `UNKNOWN`。`BLOCKED` 还要求阶段是 `connect`、Winsock 与进程退出码都是 10013、对照成功，并且接收端没有该进程的数据。这次超时不能改写成操作系统已经拒绝该套接字，也不能改写成整机出站已被切断。

收尾时，套件只结束了它自己启动且映像匹配的作业外对照进程（退出码 74），`orphans` 为空。当前用户的 AppContainer 映射里没有名称含 `FailClose` 的配置。测试目录、探测程序和结果文件上没有留下 `S-1-15-2-` 访问项。脚本会在同目录生成 `loopback_probe.exe` 和 `runtime\`；这些是运行产物，不纳入本次提交。

同一次只读预检：

```powershell
python proxy_v6/tests/repro/v69-container/check_offline.py --self-test
```

退出码 **2**。`Offline.wsb` 静态配置为 PASS，九个内存中的异常输入全部 REJECTED，系统目录没有 `WindowsSandbox.exe`，`sandboxRuntime` 为 NOT_TESTED。预检没有启动访客，也没有改防火墙。

`proxy_v6/tests/repro/v69-program-block/program_block.py` 会创建并删除一条防火墙规则，本轮没有运行。

## 作业对象覆盖什么

`guard` 创建一个匿名作业（`CreateJobObjectW` 的名称为空），只设置 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`，并用 `QueryInformationJobObject` 回读。标志没有置上就关闭句柄并失败。随后以 `CREATE_SUSPENDED` 启动一个发送进程，`AssignProcessToJobObject` 之后检查该子进程在作业内、守卫进程自己不在这个作业内，再 `ResumeThread`。分配失败时，守卫把这个尚未恢复的子进程以退出码 74 结束。守卫在 `finally` 里关闭自己持有的作业句柄。

发送端只连接 `127.0.0.1` 上的套件接收端，并重复发送 `guarded` 加 32 位标记。接收端丢掉非回环对端，以及角色不在允许集合中的行。作业外对照由套件直接启动，角色是 `unguarded`，不加入作业。

健康信号是守卫连到 `127.0.0.1` 上另一个监听套接字。对端关闭或读失败后：

- `armed` 调用 `TerminateJobObject`，退出码常量是 3，然后守卫以 0 返回。`listener_close` 还要求安静窗口里作业内新标记为 0、作业外新标记至少增加 2。
- 套件用 `TerminateProcess` 把守卫打成退出码 9。进程消亡后操作系统关闭它的句柄，kill-on-close 结束作业内进程。`guard_killed` 要求子进程退出码为 0 且不再存活，作业外对照继续送达标记。
- `user-disabled` 发出 `ignore`，不调用 `TerminateJobObject`，并阻塞在标准输入。通过条件只看这个窗口：子进程、守卫、作业外对照都存活，作业内至少再送达两个标记。守卫随后返回时仍执行同一个 `CloseHandle`。本次重跑看到子进程因此结束，但代码没有把这个事后结果写成通过条件。

锁文件必须位于该测试目录内。`LockFileEx` 独占锁失败后等待 50 毫秒再试一次，两次都失败就以退出码 2 返回。第二个守卫在创建作业和子进程之前退出，所以它不会替换或结束第一个子进程。

生产脚本和桌面程序没有调用这个再现脚本。`CreateJobObjectW` 与 `TerminateJobObject` 的调用只写在 `failclose.py`。

## 这次实验没有覆盖的范围

- 作业外的进程继续使用自己的网络。四个作业场景都要求作业内标记停止新增之后，`unguarded` 仍继续送达；本次均已观察到。已经在运行的浏览器、Clash、StarSky 和其他桌面程序不会被放进这个作业。[验收矩阵](V69-ACCEPTANCE.md) 记录隔离 Chrome 的直连对照在代理故障期间仍能到达接收端。
- 守卫进程被显式排除在自己的作业之外。结束作业成员不会凭作业成员身份结束守卫。
- 只设置了 kill-on-close 这一项作业限制。代码没有测试孙进程、脱离作业、嵌套作业，也没有测试别的进程另持一份作业句柄。句柄仍被别处持有时，关闭守卫自己的那一份不会触发 kill-on-close；这条路径没有用例。
- 作业是匿名的，不写入启动项，重启后不存在。
- 触发器是套件自己的回环 TCP 关闭，不是生产代理故障检测，也不转发用户流量。发送端不测量公网、UDP、IPv6 或 DNS。
- 锁只拒绝使用同一锁文件的第二个守卫。它不停止已经运行的子进程，也不作用到测试目录之外。
- AppContainer 场景单独编译 `loopback_probe.c`，创建一个名为 `V69.FailClose.` 加随机后缀的临时配置，网络能力数量为 0，只让该进程对 `127.0.0.1` 做 TCP bind/connect/send/recv。结果对象的范围字段是 `this process only`。接收端若收到它的标记则判 `FAILED`。本次是 `connect` / 10060 / 接收端 0 次，状态保持 `UNKNOWN`。它不约束其他进程，也不代替 [另一套 IPv4/IPv6 TCP/UDP 实验](V69-CONTAINER.md)；那套实验本轮没有重跑。
- `Offline.wsb` 描述的是访客从启动起关闭网络。宿主里原有的程序仍按各自配置联网。本次只做了上面的静态预检，访客运行仍是 NOT_TESTED。
- Clash 代理组去掉 DIRECT，只去掉该组内部的直连回退。`skills/windows-proxy-doctor/references/reliability-gaps.md` 写明：它不覆盖不走系统代理的程序、UDP、DNS，以及被关闭或改写的系统代理。

## 进程终止、测试模式、套接字拒绝是三件不同的事

**进程终止**是上面的作业路径。`armed` 在健康监听关闭后结束作业内进程；杀死守卫则靠最后一份作业句柄关闭。两种都是那些进程退出。套接字随进程消失。作业外发送端仍可连接接收端。

**测试模式**不安装网络过滤。`proxy_v4/lib/V4.ps1` 在 `V4_TEST_MODE=1` 时，`Start-V4Clash` 和 `Stop-V4Clash` 直接返回 true，不启动、不结束真实客户端；`Get-V4AppPids` 返回空列表。没有安装测试注册表写入器时，系统代理写入抛出 “V4 test mode blocks a real system-proxy write and no test registry writer is installed”。`Enable-V4ProductionWrites` 在测试模式返回 false。这些分支通过，只说明真实启停或真实代理写入被跳过或拒绝。

**套接字拒绝**是进程仍在时 Winsock 返回拒绝。`program_block.py` 的覆盖声明是一个临时可执行文件、仅 TCP、远端 `127.0.0.1`。它把“退出码 10013 且接收端没有数据”记为 `NETWORK_BLOCK`；接收端仍收到数据则是 `FAILED`；10060、退出码 4，或其他非零退出且接收端没有数据，记为 `UNKNOWN`。文件写明这不是整机断网开关。该脚本会调用 `New-NetFirewallRule` 和 `Remove-NetFirewallRule`，所以本轮没有运行。[验收矩阵](V69-ACCEPTANCE.md) 记录此前创建该规则被拒绝，规则没有留下，已有沙箱规则数量没有变化。那次拒绝访问不是整机保护已经生效。

AppContainer 只有在单进程、对照成功、`connect` 的 10013 且接收端为零时才记 `BLOCKED`。对照进程同样得到 10013 时，[AppContainer 结果](V69-CONTAINER.md) 把它记为主机回环条件，不能单独证明该策略或整机防火墙已经生效。

## 新的生产防火墙规则未获授权

[集成验收](CAB-INTEGRATION.md) 要求防火墙、DNS、TUN、IPv6、启动项和客户端重启各自单独授权。[操作边界](V69-OPERATOR.md) 写明本候选的实验和诊断不需要修改宿主防火墙；全机出站阻断会同时影响国内网站和局域网。[验收矩阵](V69-ACCEPTANCE.md) 的 `PRODUCTION_GATE` 仍是 `WAITING_USER`。指定程序的出站阻止实验和生产用的整机失败关闭都还没有授权。已有的 `codex_sandbox_offline_block_*` 规则保持不动。
