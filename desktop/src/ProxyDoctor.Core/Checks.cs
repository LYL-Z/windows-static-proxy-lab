namespace ProxyDoctor;

public sealed record CheckResult(
    string Id,
    string Name,
    string Purpose,
    string Method,
    EvidenceState State,
    string Detail,
    DateTimeOffset SampledAt,
    bool NeedsAuthorization);

public static class CheckRunner
{
    public static IReadOnlyList<string> Ids { get; } =
        ["selection", "listeners", "ipv4", "ipv6", "https", "claude-status"];

    public static async Task<IReadOnlyList<CheckResult>> RunAll(CancellationToken cancellationToken)
    {
        var results = new List<CheckResult>();
        foreach (var id in Ids)
        {
            cancellationToken.ThrowIfCancellationRequested();
            results.Add(await RunOne(id, cancellationToken));
        }
        return results;
    }

    public static async Task<CheckResult> RunOne(string id, CancellationToken cancellationToken)
    {
        var at = DateTimeOffset.Now;
        return id switch
        {
            "selection" => Selection(at),
            "listeners" => Listeners(at),
            "ipv4" => FromCapability("ipv4", "IPv4 回环", "确认本机 IPv4 回环还能交换数据。", LiveChecks.Loopback("IPv4 回环", System.Net.Sockets.AddressFamily.InterNetwork), at),
            "ipv6" => FromCapability("ipv6", "IPv6 回环", "记录 IPv6 回环是交换成功、明确拒绝还是超时。", LiveChecks.Loopback("IPv6 回环", System.Net.Sockets.AddressFamily.InterNetworkV6), at),
            "https" => await Https(at, cancellationToken),
            "claude-status" => await Claude(at, cancellationToken),
            _ => new CheckResult(id, id, "未知项目", "未执行", EvidenceState.Unknown, "没有这项检查。", at, false)
        };
    }

    private static CheckResult Selection(DateTimeOffset at)
    {
        var selection = NetworkReader.DescribeSelection();
        var state = selection is "UNKNOWN" ? EvidenceState.Unknown : EvidenceState.Verified;
        return new CheckResult("selection", "系统代理", "读取当前用户的代理开关，不修改它。",
            "读取 HKCU Internet Settings 的 ProxyEnable 和 ProxyServer。", state,
            selection + "。非本机回环地址会显示为 TARGET_OTHER。", at, false);
    }

    private static CheckResult Listeners(DateTimeOffset at)
    {
        var rows = NetworkReader.ReadListeners();
        var detail = rows.Count == 0
            ? "没有读到代理相关的回环 LISTENING 记录。空结果不能当成端口已经关闭。"
            : string.Join("；", rows.Select(item => item.Port + " " + item.ProcessName))
              + "。另有 " + NetworkReader.OtherLoopbackListenerCount() + " 个非代理回环监听，未列出名称。";
        return new CheckResult("listeners", "回环监听", "看本机回环上谁在监听，不用固定端口猜测角色。",
            "netstat -ano -p tcp，只保留 LISTENING 或侦听，再按 PID 取进程名。",
            rows.Count == 0 ? EvidenceState.Unknown : EvidenceState.Verified, detail, at, false);
    }

    private static async Task<CheckResult> Https(DateTimeOffset at, CancellationToken cancellationToken)
    {
        var probes = await HttpsProbe.SampleAsync(cancellationToken);
        var first = probes.FirstOrDefault();
        var detail = first is null
            ? "没有采样。"
            : first.StatusCode is null
                ? first.Target + " " + (first.Error ?? "无状态码") + "，" + first.ElapsedMs + " ms"
                : first.Target + " HTTP " + first.StatusCode + "，" + first.ElapsedMs + " ms";
        return new CheckResult("https", "HTTPS", "看默认代理路径能否拿到响应头。一次 200 不是整机保护。",
            "HttpClient 默认代理，只读响应头。", first?.StatusCode is null ? EvidenceState.Unknown : EvidenceState.Verified,
            detail, at, false);
    }

    private static async Task<CheckResult> Claude(DateTimeOffset at, CancellationToken cancellationToken)
    {
        var probe = await LiveChecks.ClaudeStatusAsync(cancellationToken);
        var detail = probe.StatusCode is null
            ? (probe.Error ?? "没有读到状态") + "，" + probe.ElapsedMs + " ms"
            : "HTTP " + probe.StatusCode + "，" + (probe.Error ?? "无描述") + "，" + probe.ElapsedMs + " ms";
        return new CheckResult("claude-status", "Claude 官方状态", "读取公开状态接口。这不是账户资格，也不是防封结果。",
            "GET https://status.claude.com/api/v2/status.json",
            probe.StatusCode is null ? EvidenceState.Unknown : EvidenceState.Verified, detail, at, false);
    }

    private static CheckResult FromCapability(string id, string name, string purpose, CapabilityFact fact, DateTimeOffset at) =>
        new(id, name, purpose, "本进程发起一次回环 TCP，并在同一进程接收。", fact.State, fact.Detail, at, false);
}

public sealed class AlertGate
{
    private string? _last;

    public bool ShouldNotify(string key)
    {
        if (_last is null)
        {
            _last = key;
            return false;
        }
        if (_last == key) return false;
        _last = key;
        return true;
    }
}
