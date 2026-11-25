namespace ProxyDoctor;

public enum FaultClass
{
    UserOff,
    ObservedOff,
    ProxyDrift,
    CoreDown,
    FirstHopDown,
    Aligned,
    Unknown
}

public enum EvidenceState
{
    Verified,
    Partial,
    Fault,
    Unknown,
    NotVerified
}

public sealed record FaultObservation
{
    public bool? UserTurnedProxyOff { get; init; }
    public bool? ProxyEnabled { get; init; }
    public bool? UiEnabled { get; init; }
    public bool? PacConfigured { get; init; }
    public bool? ProxyTargetsExpected { get; init; }
    public bool? CoreRunning { get; init; }
    public bool? MixedPortOpen { get; init; }
    public bool? MixedIpv4CoreOwned { get; init; }
    public bool? FirstHopExpected { get; init; }
    public bool? FirstHopOpen { get; init; }
    public bool InvalidEvidence { get; init; }
}

public sealed record FaultResult(FaultClass Class, string Advice)
{
    public bool RecommendRestore => false;
    public bool ApplicationSuccess => false;
}

public static class FaultClassifier
{
    public static FaultResult Classify(FaultObservation observation)
    {
        if (observation.InvalidEvidence)
            return Unknown();
        if (observation.UserTurnedProxyOff == true)
            return UserOff();
        if (observation.PacConfigured is not false)
            return Unknown();
        if (observation.ProxyEnabled is null || observation.UiEnabled is null)
            return Unknown();
        if (observation.ProxyEnabled == false && observation.UiEnabled == false)
        {
            if (observation.UserTurnedProxyOff == false)
                return new FaultResult(FaultClass.ProxyDrift, "Windows 和客户端保存的选择都已关闭，但记录并不是用户主动关闭。确认是谁改的，再决定是否修改。");
            if (observation.UserTurnedProxyOff != true)
                return new FaultResult(FaultClass.ObservedOff, "系统代理和客户端保存的开关都是关闭的。没有用户主动关闭的记录，所以不会自动打开，也不会把这次观察写成已确认意图。");
            return UserOff();
        }
        if (observation.ProxyEnabled != observation.UiEnabled || observation.ProxyTargetsExpected == false)
            return new FaultResult(FaultClass.ProxyDrift, "Windows 当前选择和客户端保存的选择不一致。确认目标后再修改。");
        if (observation.ProxyTargetsExpected is not true)
            return Unknown();
        if (observation.CoreRunning == false || observation.MixedPortOpen == false)
            return new FaultResult(FaultClass.CoreDown, "本地代理核心或它的监听端口没有就绪。先看这个进程和端口，不要先改 Windows 代理。");
        if (observation.CoreRunning is not true || observation.MixedPortOpen is not true || observation.MixedIpv4CoreOwned is not true)
            return Unknown();
        if (observation.FirstHopExpected == false || observation.FirstHopOpen == true)
            return new FaultResult(FaultClass.Aligned, "本地代理选择和监听一致。这不能证明某个应用已经走通这条路径。");
        if (observation.FirstHopOpen == false)
            return new FaultResult(FaultClass.FirstHopDown, "核心在监听，首跳没有在监听。先分开检查首跳，不要把它当成核心故障。");
        return Unknown();
    }

    private static FaultResult UserOff() =>
        new(FaultClass.UserOff, "代理是关闭的。保持关闭，不要自动重新打开。");

    private static FaultResult Unknown() =>
        new(FaultClass.Unknown, "现有证据还不能归入已知故障。不要根据这一项去改系统设置。");
}

public enum RequestIntent
{
    Unspecified,
    Diagnose,
    NoModify
}

public static class RequestRouter
{
    public static RequestIntent Route(string? text)
    {
        if (IsNoModifyRequest(text)) return RequestIntent.NoModify;
        if (IsDiagnoseRequest(text)) return RequestIntent.Diagnose;
        return RequestIntent.Unspecified;
    }

    public static string IntentToken(RequestIntent intent) => intent switch
    {
        RequestIntent.Diagnose => "diagnose",
        RequestIntent.NoModify => "no-modify",
        _ => "unspecified"
    };

    public static bool IsNoModifyRequest(string? text)
    {
        var value = (text ?? "").Trim();
        return value.Contains("保持原配置", StringComparison.Ordinal)
            && value.Contains("不擅自修改", StringComparison.Ordinal);
    }

    public static bool IsDiagnoseRequest(string? text)
    {
        var value = (text ?? "").Trim();
        if (value.Length == 0 || IsNoModifyRequest(value)) return false;
        if (value.Contains("代理", StringComparison.Ordinal) &&
            (value.Contains("没有正常工作", StringComparison.Ordinal) ||
             value.Contains("不正常工作", StringComparison.Ordinal) ||
             value.Contains("无法正常工作", StringComparison.Ordinal) ||
             value.Contains("不能正常工作", StringComparison.Ordinal)))
            return true;
        if (value.Contains("StarSky", StringComparison.OrdinalIgnoreCase) &&
            value.Contains("Clash", StringComparison.OrdinalIgnoreCase) &&
            value.Contains("已经重新开启", StringComparison.Ordinal) &&
            value.Contains("没有流量", StringComparison.Ordinal))
            return true;
        if (value.Contains("电脑网络配置是否正常", StringComparison.Ordinal))
            return true;
        if (value.Contains("网络故障", StringComparison.Ordinal) && value.Contains("恢复方案", StringComparison.Ordinal))
            return true;
        if (value.Contains("全面检查", StringComparison.Ordinal) && value.Contains("我的网络", StringComparison.Ordinal))
            return true;
        if (value.Contains("StarSky", StringComparison.OrdinalIgnoreCase) && value.Contains("停止运行", StringComparison.Ordinal))
            return true;
        if (value.Contains("Clash", StringComparison.OrdinalIgnoreCase) && value.Contains("没有流量", StringComparison.Ordinal))
            return true;
        if (value.Contains("检查异常", StringComparison.Ordinal) && value.Contains("恢复方案", StringComparison.Ordinal))
            return true;
        return false;
    }
}
