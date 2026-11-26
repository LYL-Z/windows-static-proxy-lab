namespace ProxyDoctor;

public sealed record ChannelSample(
    string Id,
    string Name,
    DateTimeOffset SampledAt,
    TimeSpan Interval,
    TimeSpan Ttl,
    EvidenceState State,
    string Evidence,
    string? Failure)
{
    public bool Expired(DateTimeOffset now) => now - SampledAt > Ttl;

    public EvidenceState Display(DateTimeOffset now, bool monitorFaulted)
    {
        if (monitorFaulted) return EvidenceState.Fault;
        if (Expired(now)) return EvidenceState.Unknown;
        return State;
    }
}

public static class SampleGate
{
    public static bool Accept(int seenEpoch, int currentEpoch, bool paused, bool demo) =>
        seenEpoch == currentEpoch && !paused && !demo;
}

public sealed class FaultStreak
{
    public int Consecutive { get; private set; }
    public int Flaps { get; private set; }
    public string? Last { get; private set; }
    private bool _seen;

    public string Observe(string? failure)
    {
        if (_seen && Last != failure) Flaps++;
        _seen = true;
        if (failure is null)
        {
            Consecutive = 0;
            Last = null;
            return "recovered";
        }
        if (Last == failure)
        {
            Consecutive++;
            return "repeat";
        }
        Consecutive = 1;
        Last = failure;
        return "new";
    }
}

public static class ClientLayers
{
    public static string Decide(bool processPresent, bool portPresent, bool? upstreamOk, bool userOff)
    {
        if (userOff)
            return "已记录用户关闭。不启动客户端，也不打开系统代理。";
        if (processPresent && portPresent && upstreamOk == false)
            return "进程和本地端口都在，这次上游请求失败。不会重启 StarSky 或 Clash。重启进程不等于加速已经恢复。";
        if (!processPresent)
            return "客户端进程不在。没有可调用的官方自动重连接口。不会把启动进程写成加速已恢复。";
        if (!portPresent)
            return "进程还在，但没有确认本地监听。缺少监听不能从一次不完整的 netstat 推断出来。";
        if (upstreamOk is null)
            return "进程和端口在，上游还没有本次采样。本地监听正常不等于上游可用。";
        return "进程、端口和这次上游请求都有结果。这仍不能证明某个应用已经恢复。";
    }
}
