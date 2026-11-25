using System.Diagnostics;
using Microsoft.Win32;

namespace ProxyDoctor;

public sealed record ListenerFact(int Port, string ProcessName, bool Loopback);

public sealed record ProbeFact(string Target, int? StatusCode, long ElapsedMs, string? Error, string PathLabel);

public sealed record CapabilityFact(string Name, EvidenceState State, string Detail);

public sealed record DiagnosticReport
{
    public required DateTimeOffset SampledAt { get; init; }
    public required bool Demo { get; init; }
    public required FaultObservation Observation { get; init; }
    public required FaultResult Fault { get; init; }
    public required string ProxySelection { get; init; }
    public required bool AutomaticProxySet { get; init; }
    public required IReadOnlyList<ListenerFact> Listeners { get; init; }
    public required IReadOnlyList<string> RunningClients { get; init; }
    public required IReadOnlyList<ProbeFact> Probes { get; init; }
    public required IReadOnlyList<CapabilityFact> Capabilities { get; init; }
    public required IReadOnlyList<string> Events { get; init; }
}

public static class CapabilityCatalog
{
    public static IReadOnlyList<CapabilityFact> Current() =>
    [
        new("进程级失败关闭", EvidenceState.Partial, "实验室里的作业守卫只覆盖它自己启动的进程。这台电脑没有把它安装成系统保护。"),
        new("整机网络阻断", EvidenceState.NotVerified, "给单个测试程序加出站规则时被拒绝访问。没有留下规则，也不能当成整机保护。"),
        new("DNS / DoH", EvidenceState.NotVerified, "这次桌面检查没有重跑隔离 DNS 或 DoH 实验。"),
        new("IPv6", EvidenceState.Partial, "此前回环 TCP 在 connect 得到拒绝访问，UDP 超时。过滤来源仍未知。公网路径没有在本次检查中复测。"),
        new("UDP / WebRTC", EvidenceState.NotVerified, "本次检查没有采集浏览器候选地址或 UDP 回包。"),
        new("浏览数据", EvidenceState.NotVerified, "清理站点数据需要你在浏览器里确认范围。清理不能当成消除设备身份。")
    ];
}

public static class NetworkReader
{
    public static FaultObservation ReadObservation()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
        if (key is null)
            return new FaultObservation { InvalidEvidence = true };

        var enable = key.GetValue("ProxyEnable");
        bool? proxyEnabled = enable is int number ? number == 1 : null;
        var server = key.GetValue("ProxyServer") as string;
        var auto = key.GetValue("AutoConfigURL") as string;
        var listeners = ReadListeners();
        var coreListener = listeners.FirstOrDefault(item => item.ProcessName.Equals("verge-mihomo", StringComparison.OrdinalIgnoreCase));
        var corePort = coreListener is not null;
        var coreOwned = corePort;
        var hopOpen = listeners.Any(item => item.ProcessName.Equals("magicspeed", StringComparison.OrdinalIgnoreCase));
        var targets = coreListener is not null && string.Equals(server?.Trim(), "127.0.0.1:" + coreListener.Port, StringComparison.Ordinal);
        var clients = ReadClients();
        var hopExpected = hopOpen || clients.Any(name =>
            name.Equals("magicspeed", StringComparison.OrdinalIgnoreCase) ||
            name.Equals("StarSky", StringComparison.OrdinalIgnoreCase));
        var coreRunning = clients.Any(name => name.Equals("verge-mihomo", StringComparison.OrdinalIgnoreCase));

        return new FaultObservation
        {
            ProxyEnabled = proxyEnabled,
            UiEnabled = ReadClashUiEnabled(),
            PacConfigured = !string.IsNullOrWhiteSpace(auto),
            ProxyTargetsExpected = proxyEnabled == true ? targets : null,
            CoreRunning = coreRunning,
            MixedPortOpen = corePort,
            MixedIpv4CoreOwned = coreOwned,
            FirstHopExpected = hopExpected,
            FirstHopOpen = hopOpen,
            UserTurnedProxyOff = IntentStore.Read()
        };
    }

    public static string DescribeSelection()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
        if (key?.GetValue("ProxyEnable") is not int enable)
            return "UNKNOWN";
        if (enable == 0) return "OFF";
        var server = (key.GetValue("ProxyServer") as string)?.Trim();
        if (server is "127.0.0.1:7897" or "127.0.0.1:11119") return server;
        return "TARGET_OTHER";
    }

    public static bool AutomaticProxySet()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
        return !string.IsNullOrWhiteSpace(key?.GetValue("AutoConfigURL") as string);
    }

    public static IReadOnlyList<string> ReadClients()
    {
        string[] names = ["StarSky", "magicspeed", "clash-verge", "verge-mihomo"];
        return names.Where(name => Process.GetProcessesByName(name).Length > 0).ToArray();
    }

    public static IReadOnlyList<ListenerFact> ReadListeners()
    {
        var owners = ReadLoopbackOwners();
        return owners
            .Where(item => IsProxyProcess(item.ProcessName))
            .Select(item => new ListenerFact(item.Port, item.ProcessName, true))
            .Distinct()
            .ToArray();
    }

    private static bool? ReadClashUiEnabled()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "io.github.clash-verge-rev.clash-verge-rev",
            "verge.yaml");
        if (!File.Exists(path)) return null;
        foreach (var line in File.ReadLines(path))
        {
            var text = line.Trim();
            if (text.StartsWith("enable_system_proxy:", StringComparison.Ordinal))
            {
                if (text.EndsWith("true", StringComparison.OrdinalIgnoreCase)) return true;
                if (text.EndsWith("false", StringComparison.OrdinalIgnoreCase)) return false;
            }
        }
        return null;
    }

    public static int OtherLoopbackListenerCount()
    {
        return ReadLoopbackOwners().Count(item => !IsProxyProcess(item.ProcessName));
    }

    private static bool IsProxyProcess(string name) =>
        name.Equals("verge-mihomo", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("mihomo", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("magicspeed", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("clash-verge", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("StarSky", StringComparison.OrdinalIgnoreCase);

    private static IEnumerable<(int Port, string ProcessName)> ReadLoopbackOwners()
    {
        var start = new ProcessStartInfo("netstat", "-ano -p tcp")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var process = Process.Start(start);
        if (process is null) yield break;
        var read = process.StandardOutput.ReadToEndAsync();
        if (!process.WaitForExit(4000))
        {
            try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
        }
        if (!read.Wait(1000)) yield break;
        var output = read.Result;
        foreach (var line in output.Split('\n'))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 5 || !parts[0].Equals("TCP", StringComparison.OrdinalIgnoreCase)) continue;
            if (!parts[^2].Equals("LISTENING", StringComparison.OrdinalIgnoreCase) &&
                !parts[^2].Contains("侦听", StringComparison.Ordinal)) continue;
            var local = parts[1];
            var loopback = local.StartsWith("127.0.0.1:", StringComparison.Ordinal) ||
                           local.StartsWith("[::1]:", StringComparison.Ordinal);
            if (!loopback) continue;
            var portText = local.StartsWith("[", StringComparison.Ordinal)
                ? local.Split(':')[^1]
                : local.Split(':')[^1];
            if (!int.TryParse(portText, out var port)) continue;
            if (!int.TryParse(parts[^1], out var pid)) continue;
            string name;
            try { name = Process.GetProcessById(pid).ProcessName; }
            catch { name = "unknown"; }
            yield return (port, name);
        }
    }
}

public static class HttpsProbe
{
    public static async Task<IReadOnlyList<ProbeFact>> SampleAsync(CancellationToken cancellationToken)
    {
        string[] targets = ["https://www.baidu.com", "https://github.com"];
        var results = new List<ProbeFact>();
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = true, Proxy = HttpClient.DefaultProxy })
        {
            Timeout = TimeSpan.FromSeconds(12)
        };
        foreach (var target in targets)
        {
            var watch = Stopwatch.StartNew();
            try
            {
                using var response = await client.GetAsync(target, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
                results.Add(new ProbeFact(target, (int)response.StatusCode, watch.ElapsedMilliseconds, null, "HttpClient 默认代理"));
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
            {
                results.Add(new ProbeFact(target, null, watch.ElapsedMilliseconds, ex.GetType().Name, "HttpClient 默认代理"));
            }
        }
        return results;
    }
}

public static class DiagnosticEngine
{
    public static DiagnosticReport ReadLocal()
    {
        var observation = NetworkReader.ReadObservation();
        var fault = FaultClassifier.Classify(observation);
        return Build(false, observation, fault, NetworkReader.DescribeSelection(), NetworkReader.AutomaticProxySet(),
            NetworkReader.ReadListeners(), NetworkReader.ReadClients(),
            [],
            [new CapabilityFact("本地心跳", EvidenceState.Verified, $"{DateTimeOffset.Now:HH:mm:ss} 只读了代理开关、进程和回环监听。这次心跳没有做外部 HTTPS，也没有做回环交换。")]);
    }

    public static async Task<DiagnosticReport> ReadLiveAsync(CancellationToken cancellationToken)
    {
        var observation = NetworkReader.ReadObservation();
        var fault = FaultClassifier.Classify(observation);
        var probes = new List<ProbeFact>(await HttpsProbe.SampleAsync(cancellationToken))
        {
            await LiveChecks.ClaudeStatusAsync(cancellationToken)
        };
        var capabilities = new List<CapabilityFact>
        {
            LiveChecks.Loopback("IPv4 回环", System.Net.Sockets.AddressFamily.InterNetwork),
            LiveChecks.Loopback("IPv6 回环", System.Net.Sockets.AddressFamily.InterNetworkV6),
            new("DNS / DoH", EvidenceState.NotVerified, $"{DateTimeOffset.Now:HH:mm:ss} 这次没有向受控解析器发送查询，不能判断系统或浏览器的解析路径。"),
            new("WebRTC", EvidenceState.NotVerified, $"{DateTimeOffset.Now:HH:mm:ss} 这次没有启动浏览器，也没有接收端计数。"),
            new("整机网络阻断", EvidenceState.NotVerified, "没有在本次检查中安装防火墙规则。进程守卫不是整机阻断。")
        };
        return Build(false, observation, fault, NetworkReader.DescribeSelection(), NetworkReader.AutomaticProxySet(),
            NetworkReader.ReadListeners(), NetworkReader.ReadClients(), probes, capabilities);
    }

    public static DiagnosticReport Demo()
    {
        var observation = new FaultObservation
        {
            ProxyEnabled = true,
            UiEnabled = true,
            PacConfigured = false,
            ProxyTargetsExpected = true,
            CoreRunning = true,
            MixedPortOpen = true,
            MixedIpv4CoreOwned = true,
            FirstHopExpected = true,
            FirstHopOpen = true
        };
        return Build(true, observation, FaultClassifier.Classify(observation), "127.0.0.1:7897", false,
            [new ListenerFact(7897, "verge-mihomo", true), new ListenerFact(11119, "magicspeed", true)],
            ["StarSky", "clash-verge", "verge-mihomo", "magicspeed"],
            [new ProbeFact("https://www.baidu.com", null, 0, null, "演示，未发送请求")],
            [new CapabilityFact("演示", EvidenceState.NotVerified, "演示模式不代表这台电脑完成了检测。")]);
    }

    private static DiagnosticReport Build(bool demo, FaultObservation observation, FaultResult fault, string selection,
        bool automatic, IReadOnlyList<ListenerFact> listeners, IReadOnlyList<string> clients, IReadOnlyList<ProbeFact> probes,
        IReadOnlyList<CapabilityFact> capabilities)
    {
        var line = $"{DateTimeOffset.Now:HH:mm:ss} 完成一次只读采样。分类 {fault.Class}。";
        if (!demo) EventLog.Append(line);
        var events = new List<string> { line };
        events.AddRange(EventLog.Recent());
        if (fault.Class == FaultClass.Aligned)
            events.Add("本地选择与监听一致。应用路径仍未验证。");
        if (!demo)
            events.Add("本次没有修改系统代理、防火墙或客户端。");
        return new DiagnosticReport
        {
            SampledAt = DateTimeOffset.Now,
            Demo = demo,
            Observation = observation,
            Fault = fault,
            ProxySelection = selection,
            AutomaticProxySet = automatic,
            Listeners = listeners,
            RunningClients = clients,
            Probes = probes,
            Capabilities = capabilities,
            Events = events
        };
    }
}
