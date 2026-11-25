using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace ProxyDoctor;

public static class IntentStore
{
    private static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProxyDoctor", "intent.json");

    public static bool? Read()
    {
        try
        {
            if (!File.Exists(PathName)) return null;
            using var document = JsonDocument.Parse(File.ReadAllText(PathName));
            if (!document.RootElement.TryGetProperty("userTurnedProxyOff", out var value)) return null;
            return value.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null
            };
        }
        catch
        {
            return null;
        }
    }

    public static void Write(bool userTurnedProxyOff)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.WriteAllText(PathName, JsonSerializer.Serialize(new
        {
            userTurnedProxyOff,
            recordedAt = DateTimeOffset.Now
        }));
    }

    public static void Clear()
    {
        if (File.Exists(PathName)) File.Delete(PathName);
    }
}

public static class EventLog
{
    private static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProxyDoctor", "events.jsonl");

    public static void Append(string message)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.AppendAllText(PathName, JsonSerializer.Serialize(new { at = DateTimeOffset.Now, message }) + Environment.NewLine);
        var lines = File.ReadAllLines(PathName);
        if (lines.Length > 200)
            File.WriteAllLines(PathName, lines[^200..]);
    }

    public static IReadOnlyList<string> Recent()
    {
        if (!File.Exists(PathName)) return [];
        return File.ReadAllLines(PathName).Reverse().Take(12).ToArray();
    }
}

public static class LiveChecks
{
    public static CapabilityFact Loopback(string name, AddressFamily family)
    {
        var started = DateTimeOffset.Now;
        try
        {
            using var server = new Socket(family, SocketType.Stream, ProtocolType.Tcp);
            server.Bind(new IPEndPoint(family == AddressFamily.InterNetwork ? IPAddress.Loopback : IPAddress.IPv6Loopback, 0));
            server.Listen(1);
            var port = ((IPEndPoint)server.LocalEndPoint!).Port;
            using var client = new Socket(family, SocketType.Stream, ProtocolType.Tcp);
            var connect = client.BeginConnect(server.LocalEndPoint!, null, null);
            if (!connect.AsyncWaitHandle.WaitOne(1500))
            {
                return new CapabilityFact(name, EvidenceState.Unknown,
                    $"{started:HH:mm:ss} connect 超时。接收端没有完成交换。超时不是已确认的阻断。");
            }
            client.EndConnect(connect);
            client.Send(new byte[] { 1 });
            using var accepted = server.Accept();
            var buffer = new byte[1];
            var got = accepted.Receive(buffer) == 1 && buffer[0] == 1;
            return got
                ? new CapabilityFact(name, EvidenceState.Verified, $"{started:HH:mm:ss} 回环 TCP 交换完成，端口 {port}。这只覆盖这次测试套接字。")
                : new CapabilityFact(name, EvidenceState.Fault, $"{started:HH:mm:ss} 连接建立但载荷不一致。");
        }
        catch (SocketException ex)
        {
            var state = ex.SocketErrorCode == SocketError.AccessDenied ? EvidenceState.Partial : EvidenceState.Unknown;
            return new CapabilityFact(name, state,
                $"{started:HH:mm:ss} 套接字错误 {ex.ErrorCode}。{(ex.SocketErrorCode == SocketError.AccessDenied ? "这是一次明确拒绝，不是整机保护验收。" : "没有把这次失败写成阻断。")}");
        }
    }

    public static async Task<ProbeFact> ClaudeStatusAsync(CancellationToken cancellationToken)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            using var response = await client.GetAsync("https://status.claude.com/api/v2/status.json", cancellationToken);
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            using var document = JsonDocument.Parse(body);
            var description = document.RootElement.GetProperty("status").GetProperty("description").GetString();
            return new ProbeFact("https://status.claude.com/api/v2/status.json", (int)response.StatusCode,
                watch.ElapsedMilliseconds, description, "官方状态接口，不是账户资格");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException)
        {
            return new ProbeFact("https://status.claude.com/api/v2/status.json", null, watch.ElapsedMilliseconds,
                ex.GetType().Name, "官方状态接口，不是账户资格");
        }
    }
}

public static class RecoveryDrill
{
    public static IReadOnlyList<string> Run()
    {
        var log = new List<string>();
        var enabled = false;
        log.Add("演练开始。这个状态只存在于本次内存里，没有写入 Windows。");
        if (!enabled)
            log.Add("当前演练代理是关闭的。按用户关闭处理，不执行打开。");
        enabled = false;
        var after = enabled;
        log.Add(after ? "演练失败：代理被打开了。" : "复测：代理仍是关闭的。");
        log.Add("撤销：没有需要撤销的系统改动。");
        return log;
    }
}
