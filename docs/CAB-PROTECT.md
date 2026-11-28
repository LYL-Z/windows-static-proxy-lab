# CAB 保护边界

本文件只根据已读代码和已有记录说明失败关闭的覆盖范围。它不授权新增、修改或删除任何生产防火墙规则，也不授权关闭 Defender，或改动代理、DNS、IPv6、TUN、路由和启动项。

相关记录：[集成验收](CAB-INTEGRATION.md) · [AppContainer 结果](V69-CONTAINER.md) · [验收矩阵](V69-ACCEPTANCE.md) · [操作边界](V69-OPERATOR.md)

## 作业对象守卫覆盖什么

实现在 `proxy_v6/tests/repro/v69-failclose/failclose.py`。`guard` 命令创建一个匿名 Windows Job，设置并回读 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`，然后以挂起方式启动一个回环发送进程，把它放进这个作业，确认该子进程在作业内、守卫进程自己不在作业内，再恢复线程。守卫持有作业句柄。

因此，这套守卫覆盖的是**它放进该作业的进程**。套件汇总里的覆盖声明是 `processes started inside this job only`。文件开头同样写明：这里不改防火墙、路由、DNS，也不处理守卫没有启动的进程。

守卫在测试目录内的锁文件上取得独占锁。第二个 `guard` 重试一次后仍拿不到锁，就以退出码 2 发出 `lock_busy` 并返回；它在创建作业和子进程之前退出。先启动的那个子进程继续向 `127.0.0.1` 发送。

同一文件里的四个作业场景是 `listener_close`、`guard_killed`、`user_disabled`、`second_guard`。[集成验收](CAB-INTEGRATION.md) 把这四项记为覆盖该作业创建的测试进程，整机持久阻断和生产故障仍待验。本文件没有重跑这套实进程套件：它没有不启动进程的 self-test 入口。

## 它不构成整机断网开关

作业外的进程继续使用自己的网络。测试里的 `unguarded` 发送端由套件直接启动，不加入作业；健康监听关闭或守卫被结束后，场景仍要求它继续送达标记。已经在运行的浏览器、Clash、StarSky 和其他桌面程序都不在这个作业里。[验收矩阵](V69-ACCEPTANCE.md) 记录隔离 Chrome 的直连对照在代理故障期间仍能到达接收端，进程级守卫没有保护当时已经运行的浏览器。

守卫进程自身被明确排除在作业之外。健康信号关闭的是守卫启动的作业成员，不是本机出站。套件使用的是回环 TCP 标记，不测量公网、UDP、IPv6、DNS 或生产应用故障。

同一文件后部的 AppContainer 场景是另一件事。它给一个临时探测程序零项网络能力，结果对象里的范围是 `this process only`。接收端收到该进程的数据则判 `FAILED`；`connect` 返回 Winsock 10013、进程退出码也是 10013、对照成功且接收端为零，才判 `BLOCKED`；超时或 10060 保持 `UNKNOWN`。这不是整机防火墙，也不是作业终止。[AppContainer 结果](V69-CONTAINER.md) 写明：公网出口、任意桌面应用及其全部子进程、代理链、系统级防火墙规则，以及故障时的整机断网，都要单独验收。

`Offline.wsb` 只描述一个从启动起关闭网络的 Windows Sandbox 访客。宿主里原有的浏览器和桌面应用仍按各自配置联网，该配置也不提供宿主应用故障时的自动切换。本轮只运行了它的内存自检：

```powershell
python proxy_v6/tests/repro/v69-container/check_offline.py --self-test
```

静态配置为 PASS，九个异常输入全部 REJECTED，系统目录中没有 `WindowsSandbox.exe`，退出码 2，`sandboxRuntime` 为 NOT_TESTED。这次自检只读相邻配置并在内存中拒绝变体，没有启动访客，也没有触碰防火墙。

Clash 代理组去掉 DIRECT，只表示匹配到该代理组的流量没有组内直连回退。它不覆盖不走系统代理的程序、UDP、DNS，或被关闭、被改写的系统代理。见 `skills/windows-proxy-doctor/references/reliability-gaps.md`。

## 进程终止、测试模式逻辑、操作系统网络拒绝

这三件事的结果不同。

**进程终止**发生在作业守卫的 `armed` 路径。回环健康监听关闭后，守卫调用 `TerminateJobObject`，子进程预期退出码是 3，守卫自身退出码是 0，事件动作为 `terminate`。另一条路径是守卫进程被 `TerminateProcess` 结束（预期退出码 9）：它持有的作业句柄随之关闭，`KILL_ON_JOB_CLOSE` 结束同一作业里的进程，子进程预期退出码是 0。两条路径都是进程退出。该进程的套接字随进程消失；作业外的发送端仍可继续连接接收端。安静窗口里，作业内新标记应为 0，作业外新标记应继续增加。

**测试模式逻辑**不安装网络过滤，也不把一次健康信号变成断网。

- 守卫的 `user-disabled` 模式看到同一个健康监听关闭后，发出 `action` 为 `ignore`，不调用 `TerminateJobObject`。通过条件是关闭之后子进程、守卫和作业外对照都还活着，并且作业内发送端又送达至少两个标记。这是守卫内部的分支：监听关闭期间网络路径保持可用。守卫返回时仍会关闭作业句柄，句柄上的 kill-on-close 限制还在；该场景的通过条件只断言忽略窗口内继续发送。
- `proxy_v4/lib/V4.ps1` 在 `V4_TEST_MODE=1` 时走测试模式。`Start-V4Clash` 和 `Stop-V4Clash` 直接返回 true，不启动、不结束真实客户端；`Get-V4AppPids` 返回空列表。没有测试用注册表写入器时，系统代理写入会抛出 “V4 test mode blocks a real system-proxy write”。`Enable-V4ProductionWrites` 在测试模式返回 false。测试模式通过，只说明真实启停或真实代理写入被跳过或拒绝。它不能当作进程已被终止，也不能当作套接字已被操作系统拒绝。

**操作系统网络拒绝**是套接字在进程仍可运行时收到拒绝。`proxy_v6/tests/repro/v69-program-block/program_block.py` 的覆盖声明是一个临时可执行文件、仅 TCP、远端 `127.0.0.1`。脚本把“退出码 10013 且接收端没有数据”记为 `NETWORK_BLOCK`；超时或 10060 记为 `UNKNOWN`；接收端仍收到数据则是 `FAILED`。文件自己写明这不是整机断网开关。[验收矩阵](V69-ACCEPTANCE.md) 记录当时创建该规则被拒绝，规则没有留下，已有沙箱规则数量没有变化。那次拒绝访问不是整机保护已经生效。本轮没有运行该脚本。

AppContainer 的 10013 也只在上面的单进程条件下记为 `BLOCKED`。对照进程同样得到 10013 时，[AppContainer 结果](V69-CONTAINER.md) 把它记为主机回环条件，不能单独证明 AppContainer 策略或整机防火墙已经生效。

## 新的生产防火墙规则未获授权

本文件不授权新增生产防火墙规则，也不授权删除或停用现有规则。

[集成验收](CAB-INTEGRATION.md) 要求防火墙、DNS、TUN、IPv6、启动项和客户端重启各自单独授权。[操作边界](V69-OPERATOR.md) 写明本候选的实验和诊断不需要修改宿主防火墙；全机出站阻断会同时影响国内网站和局域网。[验收矩阵](V69-ACCEPTANCE.md) 的 `PRODUCTION_GATE` 仍是 `WAITING_USER`，并为“给指定测试程序添加再删除一条出站阻止”单独列为尚未授权的操作。需求原文的工程边界同样要求：未批准时不修改防火墙，不关闭 Defender。

因此，指定程序的出站阻止实验和生产用的整机失败关闭都还没有授权。已有的 `codex_sandbox_offline_block_*` 规则保持不动。
