# 手动步骤

StarSky 已经停止加速、Clash 仍在监听时，按下面的顺序做。重启不是加速已经恢复的证明。这里没有自动重连：`ClientLifecycle.ManualSteps` 只按状态返回这些句子，不启动进程，不连接端口，不调用正在运行的控制器，也不改当前用户代理。

这份文件是这批句子的逐条说明；同样的句子由桌面程序渲染在「客户端」页的「手动步骤」卡片里（`ShellViewModel` 读取 `ClientLifecycle.ManualSteps(state)`，状态取 Clash 核心的进程、`MixedPortOpen` 和这次上游）。[CLIENT-LIMITS.md](CLIENT-LIMITS.md) 不再复述这些句子，只保留分类规则和外部材料边界。

依据已经读过的文件：

- `desktop/CLIENT-LIMITS.md`：分类只用进程、监听、界面文案、这次上游和用户是否关闭。手动恢复清单由用户自己核对，分类器不执行。同一文件写明没有 StarSky 或 magicspeed 的受支持重连 API，本构建不调用正在运行的 mihomo external-controller。
- `desktop/src/ProxyDoctor.Core/ClientLifecycle.cs`：`ListenerUpstreamUnknown` 与 `ListenerUpstreamFailed` 都要求进程和监听都在。界面是否显示加速不单独构成状态。
- `desktop/src/ProxyDoctor.Core/LiveDiagnosis.cs`：`MixedPortOpen` 只表示 `verge-mihomo` 或 `mihomo` 仍在监听；`FirstHopOpen` 只表示 `magicspeed` 仍在监听。
- `desktop/src/ProxyDoctor.Desktop/ShellViewModel.cs`：`RenderClientLine` 把 `ManualSteps` 的结果写进 `ClientSteps`；上游取监测的 `upstream` 通道，没有新鲜采样时按未知处理。
- `desktop/src/ProxyDoctor.Core/Recovery.cs`：可以自己确认系统代理仍选中本机地址，并查看客户端日志。程序不代为重启，也不打开已经关闭的客户端。
- `desktop/src/ProxyDoctor.Core/Monitor.cs`：进程和本地端口都在、这次上游失败时，不重启 StarSky 或 Clash。
- `desktop/USER-GUIDE.md`：回滚成功不表示 StarSky 加速已经恢复。

## StarSky 已停止加速，Clash 仍在监听

Clash 仍在监听只说明本地监听还在。没有新的上游结果时用 `ListenerUpstreamUnknown`。这次上游失败时用 `ListenerUpstreamFailed`，此时 `ClientLifecycle.ManualSteps` 会多返回第 4 句。重试由你自己决定，重试本身不是加速已经恢复的证明。

1. 不要调用正在运行的 external-controller，也不要发送 POST /restart。Clash 仍在监听只说明本地监听还在。重启不是加速已经恢复的证明。
2. 在 StarSky 自己的界面里查看节点和日志，并由你自己决定是否重试。重试不是加速已经恢复的证明；界面文案不能代替这次上游。
3. 加速若是你自己关的，就保持关闭，不要重新打开。只查看系统代理是否仍选中本机正在监听的地址，不要修改它。然后重新检查真实应用路径。只有新的上游结果说明这一次是否可达。
4. 仅当状态是 `ListenerUpstreamFailed`：这次上游已经失败。本地监听仍在，不能把这次上游失败写成已经恢复。上游失败不能靠重启写成已经恢复。

## 其余状态

这些句子就是 `ClientLifecycle.ManualSteps` 的返回值，程序按状态原样显示。每一条都写明重启不是加速已经恢复的证明。

- `UserOff`：保持关闭。不要启动进程，也不要重新打开加速。重启不是加速已经恢复的证明。
- `ProcessDown`：由你自己打开已经安装的客户端。进程出现之后，还要另看本地监听和这次上游。启动进程不是加速已经恢复的证明。重启不是加速已经恢复的证明。
- `ProcessUpNoListener`：在该客户端自己的界面里查看加速开关和它显示的本地端口。界面上的“正在加速”和一次上游结果都不能补上监听。重启不是加速已经恢复的证明。
- `ListenerUpstreamOk`：只保留这一次上游可达的结论。重启不是加速已经恢复的证明。界面显示正在加速也不能延长这一次结果。
