using System.Diagnostics;
using System.Text.Json;

namespace ProxyDoctor;

public sealed record RecoveryRun(
    bool ScriptStarted,
    int ProcessExit,
    int TransactionExit,
    bool LiveUnchanged,
    bool ProfileRestored,
    bool JournalRemains,
    string Writes,
    string Detail);

public static class IsolatedRecovery
{
    public const string AuthorizationText = "授权隔离事务，不修改当前 Windows";

    public static string Preview(FaultClass fault, bool userOff, bool processPresent, bool portPresent, bool? upstreamOk)
    {
        var layers = ClientLayers.Decide(processPresent, portPresent, upstreamOk, userOff);
        return string.Join(Environment.NewLine,
        [
            "预览。还没有启动恢复脚本。",
            "当前分类：" + fault + "。",
            layers,
            "本仓库的客户端实验没有覆盖真实 StarSky。Clash 的外部控制器属于正在使用的客户端，这次不调用。",
            "授权后会把 proxy_v4\\rollback-v4.ps1 复制到临时目录，强制 V4_TEST_MODE=1，跑完再删除临时目录。",
            "预期：快照要求打开代理，而隔离选择是关闭。客户端回写同一个地址后，脚本只把它清掉，退出码 32。",
            "这个按钮不写当前用户的 Internet Settings，不重启 StarSky 或 Clash，不改防火墙、DNS、IPv6、TUN 或路由。",
            "确认文字：" + AuthorizationText
        ]);
    }

    public static string? FindEngineRoot()
    {
        var fromEnv = Environment.GetEnvironmentVariable("PROXY_DOCTOR_ENGINE");
        if (!string.IsNullOrWhiteSpace(fromEnv) &&
            File.Exists(Path.Combine(fromEnv, "proxy_v4", "rollback-v4.ps1")))
            return fromEnv;
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "proxy_v4", "rollback-v4.ps1")))
                return dir.FullName.TrimEnd('\\', '/');
        }
        return null;
    }

    public static string? FindScript()
    {
        var beside = Path.Combine(AppContext.BaseDirectory, "scripts", "Invoke-IsolatedRecovery.ps1");
        if (File.Exists(beside)) return beside;
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "desktop", "scripts", "Invoke-IsolatedRecovery.ps1");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    public static async Task<RecoveryRun> ExecuteAsync(string authorization, CancellationToken cancellationToken)
    {
        if (!string.Equals(authorization, AuthorizationText, StringComparison.Ordinal))
        {
            return new RecoveryRun(false, 0, -1, true, false, false, "", "授权文字不匹配。没有启动脚本。");
        }
        var engine = FindEngineRoot();
        var script = FindScript();
        if (engine is null || script is null)
        {
            return new RecoveryRun(false, 0, -1, true, false, false, "", "没有找到 proxy_v4 或隔离脚本。没有启动恢复。");
        }
        var before = NetworkReader.LiveProxyStamp();
        var work = Path.Combine(Path.GetTempPath(), "proxy-doctor-recovery-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            var start = new ProcessStartInfo("powershell.exe")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-ExecutionPolicy");
            start.ArgumentList.Add("Bypass");
            start.ArgumentList.Add("-File");
            start.ArgumentList.Add(script.TrimEnd('\\', '/'));
            start.ArgumentList.Add("-EngineRoot");
            start.ArgumentList.Add(engine.TrimEnd('\\', '/'));
            start.ArgumentList.Add("-WorkRoot");
            start.ArgumentList.Add(work.TrimEnd('\\', '/'));
            start.Environment["V4_TEST_MODE"] = "1";
            using var process = Process.Start(start) ?? throw new InvalidOperationException("powershell did not start");
            var stdout = Task.Run(() => process.StandardOutput.ReadToEnd());
            var stderr = Task.Run(() => process.StandardError.ReadToEnd());
            var exited = await Task.Run(() => process.WaitForExit(90000)).ConfigureAwait(false);
            if (!exited)
            {
                try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
            }
            try { Task.WaitAll([stdout, stderr], 2000); } catch { /* pipes already closed */ }
            var after = NetworkReader.LiveProxyStamp();
            var resultPath = Path.Combine(work, "result.json");
            if (!File.Exists(resultPath))
            {
                var why = exited ? "脚本没有留下结果。" : "隔离脚本超过 90 秒，已结束进程。";
                return new RecoveryRun(true, exited ? process.ExitCode : -1, 40, before == after, false, false, "", why);
            }
            using var document = JsonDocument.Parse(File.ReadAllText(resultPath));
            var root = document.RootElement;
            return new RecoveryRun(
                true,
                exited ? process.ExitCode : -1,
                root.GetProperty("exitCode").GetInt32(),
                before == after,
                root.TryGetProperty("profileRestored", out var restored) && restored.GetBoolean(),
                root.TryGetProperty("journalRemains", out var journal) && journal.GetBoolean(),
                root.TryGetProperty("writes", out var writes) ? writes.GetString() ?? "" : "",
                root.TryGetProperty("detail", out var detail) ? detail.GetString() ?? "" : "");
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch { /* evidence already read */ }
        }
    }
}
