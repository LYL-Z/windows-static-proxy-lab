namespace ProxyDoctor;

public sealed record CheckResult(
    string Id,
    string Name,
    string Purpose,
    string Method,
    EvidenceState State,
    string Detail,
    DateTimeOffset SampledAt,
    bool NeedsAuthorization)
{
    public TimeSpan? Elapsed { get; init; }
}

public static class CheckRunner
{
    public static IReadOnlyList<string> Ids { get; } =
        ["selection", "listeners", "ipv4", "ipv6", "udp", "dns", "doh", "https", "claude-status", "webrtc"];

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
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = id switch
        {
            "selection" => Selection(at),
            "listeners" => Listeners(at),
            "ipv4" => FromCapability("ipv4", "IPv4 回环", "确认本机 IPv4 回环还能交换数据。", LiveChecks.Loopback("IPv4 回环", System.Net.Sockets.AddressFamily.InterNetwork), at),
            "ipv6" => FromCapability("ipv6", "IPv6 回环", "记录 IPv6 回环是交换成功、明确拒绝还是超时。", LiveChecks.Loopback("IPv6 回环", System.Net.Sockets.AddressFamily.InterNetworkV6), at),
            "udp" => FromCapability("udp", "UDP 回环", "确认本机 UDP 回环还能收到测试字节。", LiveChecks.UdpLoopback(), at),
            "dns" => await Dns(at, cancellationToken),
            "doh" => await Doh(at, cancellationToken),
            "https" => await Https(at, cancellationToken),
            "claude-status" => await Claude(at, cancellationToken),
            "webrtc" => new CheckResult("webrtc", "WebRTC", "区分实验室、这台电脑和已部署保护。",
                "这次没有启动浏览器，也没有接收端计数。", EvidenceState.NotVerified,
                at.ToString("HH:mm:ss") + " 没有采集浏览器候选地址。固定说明不能当成已检测。", at, false),
            _ => new CheckResult(id, id, "未知项目", "未执行", EvidenceState.Unknown, "没有这项检查。", at, false)
        };
        cancellationToken.ThrowIfCancellationRequested();
        return result with { Elapsed = watch.Elapsed };
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
        var read = NetworkReader.ReadListeners();
        if (!read.Complete)
            return new CheckResult("listeners", "回环监听", "看本机回环上谁在监听，不用固定端口猜测角色。",
                "netstat -ano，读取 TCP 监听行，再按 PID 取进程名。",
                EvidenceState.Unknown, "读取超时或不完整。不能把缺少的行当成端口已关闭。", at, false);
        var detail = read.Rows.Count == 0
            ? "没有读到代理相关的回环 LISTENING 记录。空结果不能当成端口已经关闭。"
            : string.Join("；", read.Rows.Select(item => item.Port + " " + item.ProcessName))
              + "。另有 " + NetworkReader.OtherLoopbackListenerCount() + " 个非代理回环监听，未列出名称。";
        return new CheckResult("listeners", "回环监听", "看本机回环上谁在监听，不用固定端口猜测角色。",
            "netstat -ano，读取 TCP 监听行，再按 PID 取进程名。",
            EvidenceState.Verified, detail, at, false);
    }

    private static async Task<CheckResult> Https(DateTimeOffset at, CancellationToken cancellationToken)
    {
        var probes = await HttpsProbe.SampleAsync(cancellationToken);
        var detail = probes.Count == 0
            ? "没有采样。"
            : string.Join("；", probes.Select(item => item.StatusCode is null
                ? item.Target + " " + (item.Error ?? "无状态码") + "，" + item.ElapsedMs + " ms"
                : item.Target + " HTTP " + item.StatusCode + "，" + item.ElapsedMs + " ms"));
        var any = probes.Any(item => item.StatusCode is not null);
        var all = probes.Count > 0 && probes.All(item => item.StatusCode is >= 200 and <= 399);
        var state = all ? EvidenceState.Verified : any ? EvidenceState.Partial : EvidenceState.Unknown;
        return new CheckResult("https", "HTTPS", "分别记录每个目标。一个站点的响应不能代表其他站点或所有应用。",
            "HttpClient 默认代理，只读响应头。90 秒周期采样看不到更短的中断。", state,
            detail + "。这只说明这次默认代理路径，不是整机保护。", at, false);
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

    private static async Task<CheckResult> Dns(DateTimeOffset at, CancellationToken cancellationToken)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            var answers = await System.Net.Dns.GetHostAddressesAsync("example.com", cancellationToken);
            var evidence = ProtocolEvidence.Dns("Windows", "系统解析器", true, answers.Length > 0,
                false, null, false, watch.ElapsedMilliseconds);
            return new CheckResult("dns", "系统 DNS", "问系统解析器，不判断泄漏是否已经修复。",
                "Dns.GetHostAddresses(example.com)。这是当前电脑的实时解析，不是实验室结论，也不是生产保护。",
                evidence.Result == ProtocolClass.PathUnknown && answers.Length > 0 ? EvidenceState.Partial : EvidenceState.Unknown,
                at.ToString("HH:mm:ss") + " example.com 得到 " + answers.Length + " 个地址，" + watch.ElapsedMilliseconds + " ms。有应答只说明解析器可用，没有证明解析路径。",
                at, false);
        }
        catch (Exception ex) when (ex is System.Net.Sockets.SocketException or ArgumentException)
        {
            return new CheckResult("dns", "系统 DNS", "问系统解析器，不判断泄漏是否已经修复。",
                "Dns.GetHostAddresses(example.com)。", EvidenceState.Unknown,
                at.ToString("HH:mm:ss") + " " + ex.GetType().Name + "，" + watch.ElapsedMilliseconds + " ms。失败不是已确认的泄漏。",
                at, false);
        }
    }

    private static async Task<CheckResult> Doh(DateTimeOffset at, CancellationToken cancellationToken)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var client = new HttpClient(new SocketsHttpHandler { UseProxy = true, Proxy = HttpClient.DefaultProxy })
            {
                Timeout = TimeSpan.FromSeconds(8)
            };
            using var response = await client.GetAsync("https://dns.google/resolve?name=example.com&type=A", cancellationToken);
            var evidence = ProtocolEvidence.Doh("HttpClient", "公共 DoH 端点", true,
                (int)response.StatusCode, false, null, false, watch.ElapsedMilliseconds);
            return new CheckResult("doh", "DoH 端点", "看当前默认代理路径能否到达一个中性 DoH 端点。",
                "GET https://dns.google/resolve?name=example.com&type=A。不是浏览器 DoH 开关，也不是泄漏已修复。",
                response.IsSuccessStatusCode && evidence.Result == ProtocolClass.PathUnknown ? EvidenceState.Partial : EvidenceState.Unknown,
                at.ToString("HH:mm:ss") + " HTTP " + (int)response.StatusCode + "，" + watch.ElapsedMilliseconds + " ms。解析路径未知。",
                at, false);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            return new CheckResult("doh", "DoH 端点", "看当前默认代理路径能否到达一个中性 DoH 端点。",
                "GET https://dns.google/resolve?name=example.com&type=A。", EvidenceState.Unknown,
                at.ToString("HH:mm:ss") + " " + ex.GetType().Name + "，" + watch.ElapsedMilliseconds + " ms。",
                at, false);
        }
    }

    private static CheckResult FromCapability(string id, string name, string purpose, CapabilityFact fact, DateTimeOffset at) =>
        new(id, name, purpose, "本进程发起一次回环交换，并在同一进程接收。", fact.State, fact.Detail, at, false);
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
