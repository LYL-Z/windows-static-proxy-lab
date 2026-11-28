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
    /// <summary>
    /// The session log file name. Its lines are {at,message} objects and it is the only writer of
    /// this file; <see cref="MonitorEngine"/> owns <see cref="MonitorEngine.EventFileName"/> instead.
    /// </summary>
    public const string FileName = "events.jsonl";

    private static string PathName => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProxyDoctor", FileName);

    private static readonly Mutex Gate = new(false, "Local\\ProxyDoctorEvents");

    public static void Append(string message)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        Gate.WaitOne();
        try
        {
            var lines = File.Exists(PathName) ? File.ReadAllLines(PathName).ToList() : new List<string>();
            lines.Add(JsonSerializer.Serialize(new { at = DateTimeOffset.Now, message }));
            if (lines.Count > 200) lines.RemoveRange(0, lines.Count - 200);
            var temp = PathName + ".tmp";
            File.WriteAllLines(temp, lines);
            File.Move(temp, PathName, overwrite: true);
        }
        finally
        {
            Gate.ReleaseMutex();
        }
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

    public static CapabilityFact UdpLoopback()
    {
        var started = DateTimeOffset.Now;
        try
        {
            using var server = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            server.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            server.ReceiveTimeout = 1500;
            var port = ((IPEndPoint)server.LocalEndPoint!).Port;
            using var client = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            client.SendTo(new byte[] { 7 }, new IPEndPoint(IPAddress.Loopback, port));
            var buffer = new byte[1];
            var got = server.Receive(buffer);
            return got == 1 && buffer[0] == 7
                ? new CapabilityFact("UDP 回环", EvidenceState.Verified, $"{started:HH:mm:ss} 回环 UDP 收到 1 字节，端口 {port}。这只覆盖这次测试套接字，不是 WebRTC 保护。")
                : new CapabilityFact("UDP 回环", EvidenceState.Fault, $"{started:HH:mm:ss} UDP 载荷不一致。");
        }
        catch (SocketException ex)
        {
            return new CapabilityFact("UDP 回环", EvidenceState.Unknown,
                $"{started:HH:mm:ss} UDP 套接字错误 {ex.ErrorCode}。超时或拒绝都不是已确认的整机阻断。");
        }
    }
}

public sealed class IsolatedProxy
{
    public bool Enabled { get; private set; }
    public string Server { get; private set; } = "127.0.0.1:1";
    public bool UserOff { get; set; }
    private bool _savedEnabled;
    private string _savedServer = "";

    public int ApplySnapshot(bool snapshotEnabled, string snapshotServer)
    {
        _savedEnabled = Enabled;
        _savedServer = Server;
        if (!snapshotEnabled)
        {
            Enabled = false;
            return 0;
        }
        if (UserOff)
            return 32;
        Enabled = true;
        Server = snapshotServer;
        return 0;
    }

    public void Rollback()
    {
        Enabled = _savedEnabled;
        Server = _savedServer;
    }
}

public static class RecoveryDrill
{
    public static IReadOnlyList<string> Run()
    {
        var proxy = new IsolatedProxy { UserOff = true };
        var before = proxy.Enabled;
        var code = proxy.ApplySnapshot(true, "127.0.0.1:9");
        var after = proxy.Enabled;
        proxy.Rollback();
        return
        [
            "隔离恢复开始。没有写入 Windows 代理。",
            "执行前 Enabled=" + before + "，用户关闭记录=true。",
            "快照要求打开 127.0.0.1:9。退出码 " + code + "。执行后 Enabled=" + after + "。",
            after ? "复测失败：代理被打开了。" : "复测通过：用户关闭记录阻止了打开。",
            "回滚后 Enabled=" + proxy.Enabled + "。系统代理未被修改。"
        ];
    }
}
