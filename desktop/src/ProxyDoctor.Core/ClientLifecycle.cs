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
