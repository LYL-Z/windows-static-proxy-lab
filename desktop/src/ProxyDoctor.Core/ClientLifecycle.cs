namespace ProxyDoctor;

public enum ClientLifecycleState
{
    UserOff,
    ProcessDown,
    ProcessUpNoListener,
    ListenerUpstreamUnknown,
    ListenerUpstreamFailed,
    ListenerUpstreamOk
}

public readonly record struct ClientLifecycleObservation(
    bool ProcessPresent,
    bool ListenerPresent,
    bool? UiSaysAccelerating,
    bool? UpstreamOk,
    bool UserTurnedOff);

public sealed record ClientLifecycleVerdict(ClientLifecycleState State, string Guidance);

public static class ClientLifecycle
{
    public const string LimitNote =
        "重启不是已恢复的加速。没有找到 StarSky 或 magicspeed 受支持的重连 API。" +
        "已查阅 https://wiki.metacubex.one/en/api/ 、https://wiki.metacubex.one/en/config/general/ 、" +
        "https://github.com/clash-verge-rev/clash-verge-rev/discussions/6951 、" +
        "https://github.com/clash-verge-rev/clash-verge-rev/discussions/7417 、" +
        "https://clash-verge-rev.github.io/faq/other.html ，以及对 StarSky.exe 与 magicspeed.exe 的公开检索，没有该客户端的重连接口。" +
        "Clash 文档中的本地 API 是 mihomo external-controller（GET /version、POST /restart）。本构建不调用正在运行的控制器。";

    public static ClientLifecycleVerdict Classify(
        bool processPresent,
        bool listenerPresent,
        bool? uiSaysAccelerating,
        bool? upstreamOk,
        bool userTurnedOff)
    {
        var state = Resolve(processPresent, listenerPresent, upstreamOk, userTurnedOff);
        var guidance = Describe(state, processPresent, listenerPresent) + DescribeUi(uiSaysAccelerating) + LimitNote;
        return new ClientLifecycleVerdict(state, guidance);
    }

    public static ClientLifecycleVerdict Classify(ClientLifecycleObservation observation) =>
        Classify(
            observation.ProcessPresent,
            observation.ListenerPresent,
            observation.UiSaysAccelerating,
            observation.UpstreamOk,
            observation.UserTurnedOff);

    public static IReadOnlyList<string> ManualSteps(ClientLifecycleState state)
    {
        switch (state)
        {
            case ClientLifecycleState.UserOff:
                return One("保持关闭。不要启动进程，也不要重新打开加速。重启不是加速已经恢复的证明。");
            case ClientLifecycleState.ProcessDown:
                return One("由你自己打开已经安装的客户端。进程出现之后，还要另看本地监听和这次上游。启动进程不是加速已经恢复的证明。重启不是加速已经恢复的证明。");
            case ClientLifecycleState.ProcessUpNoListener:
                return One("在该客户端自己的界面里查看加速开关和它显示的本地端口。界面上的“正在加速”和一次上游结果都不能补上监听。重启不是加速已经恢复的证明。");
            case ClientLifecycleState.ListenerUpstreamUnknown:
                return ClashStillListening(false);
            case ClientLifecycleState.ListenerUpstreamFailed:
                return ClashStillListening(true);
            case ClientLifecycleState.ListenerUpstreamOk:
                return One("只保留这一次上游可达的结论。重启不是加速已经恢复的证明。界面显示正在加速也不能延长这一次结果。");
            default:
                return One("现有输入还不能归入已知状态。不要启动或重启客户端。重启不是加速已经恢复的证明。");
        }
    }

    private static IReadOnlyList<string> ClashStillListening(bool upstreamFailed)
    {
        var steps = new List<string>
        {
            "不要调用正在运行的 external-controller，也不要发送 POST /restart。Clash 仍在监听只说明本地监听还在。重启不是加速已经恢复的证明。",
            "在 StarSky 自己的界面里查看节点和日志，并由你自己决定是否重试。重试不是加速已经恢复的证明；界面文案不能代替这次上游。",
            "加速若是你自己关的，就保持关闭，不要重新打开。只查看系统代理是否仍选中本机正在监听的地址，不要修改它。然后重新检查真实应用路径。只有新的上游结果说明这一次是否可达。"
        };
        if (upstreamFailed)
            steps.Add("这次上游已经失败。本地监听仍在，不能把这次上游失败写成已经恢复。上游失败不能靠重启写成已经恢复。");
        return steps;
    }

    private static IReadOnlyList<string> One(string step) => new[] { step };

    private static ClientLifecycleState Resolve(
        bool processPresent,
        bool listenerPresent,
        bool? upstreamOk,
        bool userTurnedOff)
    {
        if (userTurnedOff)
            return ClientLifecycleState.UserOff;
        if (!processPresent)
            return ClientLifecycleState.ProcessDown;
        if (!listenerPresent)
            return ClientLifecycleState.ProcessUpNoListener;
        if (upstreamOk is null)
            return ClientLifecycleState.ListenerUpstreamUnknown;
        if (upstreamOk == false)
            return ClientLifecycleState.ListenerUpstreamFailed;
        return ClientLifecycleState.ListenerUpstreamOk;
    }

    private static string Describe(ClientLifecycleState state, bool processPresent, bool listenerPresent)
    {
        switch (state)
        {
            case ClientLifecycleState.UserOff:
                return "用户已关闭。不要启动客户端，也不要重新打开加速。";
            case ClientLifecycleState.ProcessDown:
                return listenerPresent
                    ? "进程不在。报告有监听也不能在进程缺失时单独成立。不要把启动进程写成加速已经恢复。"
                    : "进程不在。不要把启动进程写成加速已经恢复。";
            case ClientLifecycleState.ProcessUpNoListener:
                return "进程在，本地监听没有确认。没有监听就不能当成加速可用。上游结果和界面文案都不能补上监听。";
            case ClientLifecycleState.ListenerUpstreamUnknown:
                return "监听在，这次上游是否可用还未知。本地监听不等于上游可用。";
            case ClientLifecycleState.ListenerUpstreamFailed:
                return "监听在，这次上游失败。上游失败不能靠重启写成已经恢复。";
            case ClientLifecycleState.ListenerUpstreamOk:
                return "监听在，这次上游请求有结果。这只说明这一次上游可达。";
            default:
                return processPresent
                    ? "现有输入还不能归入已知状态。不要启动或重启客户端。"
                    : "进程不在。不要把启动进程写成加速已经恢复。";
        }
    }

    private static string DescribeUi(bool? uiSaysAccelerating)
    {
        if (uiSaysAccelerating == true)
            return "客户端界面显示正在加速。界面文案不能代替进程、监听或上游。";
        if (uiSaysAccelerating == false)
            return "客户端界面没有显示正在加速。";
        return "客户端界面是否显示加速还未知。";
    }
}
