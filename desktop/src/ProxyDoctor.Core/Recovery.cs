using System.Diagnostics;
using System.Text.Json;

namespace ProxyDoctor;

public sealed record RecoveryResult(
    bool CompleteSuccess,
    bool ScriptStarted,
    bool Cancelled,
    bool TimedOut,
    int ProcessExit,
    int TransactionExit,
    int ExpectedTransactionExit,
    bool ProfileRestored,
    bool WritesMatch,
    bool JournalClear,
    bool LiveUnchanged,
    string Isolation,
    string Writes,
    string Detail)
{
    public const string IsolationLabel = "V4_TEST_MODE 是进程内逻辑隔离，不是操作系统强制沙箱。";
    public const string ScopeLabel = "LiveUnchanged 只比较开始和结束两次读取的 ProxyEnable 与 ProxyServer。它不能证明这两次读取之间没有写入。";
    public string EvidenceScope { get; init; } = ScopeLabel;

    /// <summary>Engine resolution outcome, so a refusal says which check failed instead of only "not found".</summary>
    public string Engine { get; init; } = "";

    /// <summary>What the person authorized: the bound target and how the grant was given.</summary>
    public string Target { get; init; } = "";
    public string GrantedBy { get; init; } = "";

    /// <summary>True when nothing ran because no valid, target-bound authorization was given.</summary>
    public bool AuthorizationRefused { get; init; }

    /// <summary>Always the isolated rehearsal; the production write path does not exist yet.</summary>
    public string Mode { get; init; } = RecoveryConsent.ModeLabel;
    public string ProductionWrite { get; init; } = "not-implemented";

    public static RecoveryResult Refused(string detail) => new(
        false, false, false, false, 0, -1, RecoveryTrust.ExpectedTransactionExit,
        false, false, false, true, IsolationLabel, "", detail);

    /// <summary>A refusal before any script ran because the grant was missing, malformed or stale.</summary>
    public static RecoveryResult NotAuthorized(string detail) => Refused(detail) with { AuthorizationRefused = true };

    public RecoveryResult WithVerdict() => this with { CompleteSuccess = RecoveryTrust.IsComplete(this) };
}

public static class IsolatedRecovery
{
    public const string ManualGuidance =
        "没有找到适用于当前 StarSky 版本的官方重连接口。进程存在、本地端口存在、客户端显示加速、上游可通，是四件不同的事。重启进程或重新打开加速都不等于流量已经恢复。Clash 的外部控制器属于正在使用的客户端，这次不调用。你可以自己确认系统代理仍是选中的本机地址，并在客户端里查看日志。程序不会代你重启，也不会打开你已经关闭的客户端。";

    public static string Preview(FaultClass fault, bool userOff, bool processPresent, bool portPresent, bool? upstreamOk, string? target = null)
    {
        var brief = RecoveryConsent.Describe(target);
        var lines = new List<string>
        {
            "预览。还没有启动恢复脚本。",
            "当前分类：" + fault + "。",
            ClientLayers.Decide(processPresent, portPresent, upstreamOk, userOff),
            ManualGuidance,
            RecoveryResult.IsolationLabel,
            "授权后只运行哈希相符的 rollback-v4.ps1 和 V4.ps1。工作目录必须落在临时目录内，并且不能是重解析点。",
            "这次场景的预期事务退出码是 32。单独的退出码不是成功。还要同时看到配置哈希恢复、隔离写入只有 enabled=0、事务日志清除，以及当前用户代理指纹不变。"
        };
        lines.AddRange(brief.Lines);
        return string.Join(Environment.NewLine, lines);
    }

    /// <summary>
    /// Root that contains <c>proxy_v4\</c>. In a published install this is
    /// <c>AppContext.BaseDirectory\engine\</c>; there is no parent-directory fallback
    /// in a Release build.
    /// </summary>
    public static string? FindEngineRoot() => EnginePackage.Resolve().EngineRoot;

    /// <summary>The reviewed wrapper script, always inside the validated engine folder.</summary>
    public static string? FindScript() => EnginePackage.Resolve().ScriptPath;

    /// <summary>
    /// Runs the reviewed wrapper only after a person supplied a grant bound to this
    /// operation and this target. A missing, malformed or stale grant is a refusal and
    /// starts nothing, so read-only diagnosis remains the only thing that can happen.
    /// </summary>
    public static async Task<RecoveryResult> ExecuteAsync(RecoveryApproval? approval, CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
            return RecoveryResult.NotAuthorized("已取消。没有启动脚本。") with { Cancelled = true };
        if (approval is null || !approval.IsWellFormed)
            return RecoveryResult.NotAuthorized("没有收到与本次操作绑定的授权短语或确认框结果。没有启动脚本。");
        var current = RecoveryConsent.ReadTarget();
        if (!string.Equals(approval.Target, current, StringComparison.Ordinal))
            return RecoveryResult.NotAuthorized(
                "授权时目标是 " + approval.Target + "，现在是 " + current + "。目标变了，这次授权不再适用。没有启动脚本。")
                with { Target = current, GrantedBy = approval.GrantedBy };
        var package = EnginePackage.Resolve();
        if (!package.Ok || package.EngineRoot is null || package.ScriptPath is null)
            return RecoveryResult.Refused("恢复引擎被拒绝：" + package.Detail) with
            {
                Engine = package.Detail,
                Target = current,
                GrantedBy = approval.GrantedBy
            };
        var engine = package.EngineRoot;
        var script = package.ScriptPath;
        var engineDetail = package.Detail;
        var approvedTarget = current;
        var grantedBy = approval.GrantedBy;

        var before = NetworkReader.LiveProxyStamp();
        var work = Path.Combine(Path.GetFullPath(Path.GetTempPath()), "proxy-doctor-recovery-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            if (RecoveryTrust.IsReparsePoint(work) || !RecoveryTrust.ContainedAfterResolve(Path.GetTempPath(), work))
                return RecoveryResult.Refused("临时目录没有通过包含关系和重解析点检查。没有启动脚本。") with
                {
                    LiveUnchanged = true,
                    Engine = engineDetail,
                    Target = approvedTarget,
                    GrantedBy = grantedBy
                };

            var shell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            var start = new ProcessStartInfo(shell)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            foreach (var key in start.Environment.Keys.Where(item =>
                         item.StartsWith("V4_", StringComparison.OrdinalIgnoreCase) ||
                         item.Equals("PROXY_DOCTOR_ENGINE", StringComparison.OrdinalIgnoreCase) ||
                         item.Equals("PSModulePath", StringComparison.OrdinalIgnoreCase)).ToArray())
                start.Environment.Remove(key);
            start.Environment["V4_TEST_MODE"] = "1";
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-ExecutionPolicy");
            start.ArgumentList.Add("Bypass");
            start.ArgumentList.Add("-File");
            start.ArgumentList.Add(script);
            start.ArgumentList.Add("-EngineRoot");
            start.ArgumentList.Add(engine);
            start.ArgumentList.Add("-WorkRoot");
            start.ArgumentList.Add(work);
            start.ArgumentList.Add("-ExpectedRollbackSha");
            start.ArgumentList.Add(RecoveryTrust.RollbackSha256);
            start.ArgumentList.Add("-ExpectedLibrarySha");
            start.ArgumentList.Add(RecoveryTrust.LibrarySha256);

            using var process = Process.Start(start) ?? throw new InvalidOperationException("powershell did not start");
            var stdout = Task.Run(() => process.StandardOutput.ReadToEnd());
            var stderr = Task.Run(() => process.StandardError.ReadToEnd());
            var timedOut = false;
            var cancelled = false;
            var deadline = DateTime.UtcNow.AddSeconds(90);
            while (!process.HasExited)
            {
                if (cancellationToken.IsCancellationRequested) { cancelled = true; break; }
                if (DateTime.UtcNow >= deadline) { timedOut = true; break; }
                await Task.Delay(200, CancellationToken.None).ConfigureAwait(false);
            }
            if (cancelled || timedOut)
            {
                try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
            }
            try { Task.WaitAll([stdout, stderr], 2000); } catch { /* pipes closed */ }
            var after = NetworkReader.LiveProxyStamp();
            var resultPath = Path.Combine(work, "result.json");
            if (!File.Exists(resultPath))
            {
                var why = cancelled ? "已取消，并结束了隔离进程。" : timedOut ? "隔离脚本超过 90 秒，已结束进程。" : "脚本没有留下结果。";
                return new RecoveryResult(false, true, cancelled, timedOut, process.HasExited ? process.ExitCode : -1,
                    40, RecoveryTrust.ExpectedTransactionExit, false, false, false, before == after,
                    RecoveryResult.IsolationLabel, "", why)
                {
                    Engine = engineDetail,
                    Target = approvedTarget,
                    GrantedBy = grantedBy
                };
            }
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(resultPath, CancellationToken.None));
            var root = document.RootElement;
            var writes = root.TryGetProperty("writes", out var writesElement) ? writesElement.GetString() ?? "" : "";
            return new RecoveryResult(
                false,
                true,
                cancelled,
                timedOut,
                process.HasExited ? process.ExitCode : -1,
                root.GetProperty("exitCode").GetInt32(),
                RecoveryTrust.ExpectedTransactionExit,
                root.TryGetProperty("profileRestored", out var restored) && restored.GetBoolean(),
                RecoveryTrust.WritesMatchScenario(writes),
                root.TryGetProperty("journalRemains", out var journal) && !journal.GetBoolean(),
                before == after,
                RecoveryResult.IsolationLabel,
                writes,
                root.TryGetProperty("detail", out var detail) ? detail.GetString() ?? "" : "")
            {
                Engine = engineDetail,
                Target = approvedTarget,
                GrantedBy = grantedBy
            }.WithVerdict();
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch { /* evidence already read */ }
        }
    }
}
