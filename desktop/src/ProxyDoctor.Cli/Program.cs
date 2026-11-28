using System.Text.Json;
using ProxyDoctor;

var json = new JsonSerializerOptions { WriteIndented = true };

// F72: a refusal is a normal outcome and must stay JSON on stdout, so a caller can
// tell "no valid authorization" apart from "the isolated run failed".
int Refuse(string detail)
{
    var result = RecoveryResult.NotAuthorized(detail) with { Target = RecoveryConsent.ReadTarget() };
    Console.WriteLine(JsonSerializer.Serialize(result, json));
    return 2;
}

var sentenceAt = Array.IndexOf(args, "--sentences");
if (sentenceAt >= 0)
{
    var text = string.Join(' ', args.Skip(sentenceAt + 1));
    Console.WriteLine(RequestRouter.IntentToken(RequestRouter.Route(text)));
    return 0;
}

if (args.Contains("--engine-check"))
{
    Console.Error.WriteLine("Usage: --engine-check validates the packaged engine folder only; it starts no script.");
    var engine = EnginePackage.Resolve();
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        ok = engine.Ok,
        detail = engine.Detail,
        engineRoot = engine.EngineRoot,
        scriptPath = engine.ScriptPath,
        requiredEngineVersion = EnginePackage.RequiredEngineVersion,
        allowRepositorySearch = EnginePackage.AllowRepositorySearch,
        files = engine.Files.Select(item => new { item.Path, item.Sha256 })
    }, json));
    return engine.Ok ? 0 : 2;
}

// The canonical consent text. A caller (including the Skill entry) shows these lines
// verbatim before asking a person for the phrase; nothing is executed here.
if (args.Contains("--recovery-brief"))
{
    var brief = RecoveryConsent.Describe();
    Console.WriteLine(JsonSerializer.Serialize(new
    {
        mode = "isolated-rehearsal",
        productionWrite = "not-implemented",
        operation = RecoveryConsent.OperationName,
        target = brief.Target,
        phrase = brief.Phrase,
        scope = brief.Scope,
        affectedResources = brief.AffectedResources,
        writesSystemProxy = false,
        systemProxy = brief.SystemProxy,
        rollback = brief.Rollback,
        notImplemented = brief.NotImplemented,
        refusal = brief.Refusal,
        lines = brief.Lines
    }, json));
    return 0;
}

if (args.Contains("--isolated-recovery"))
{
    Console.Error.WriteLine("Usage: --isolated-recovery runs the isolated rehearsal only when a person types the bound confirmed phrase; it exits 0 only when CompleteSuccess is true, otherwise 2.");
    var brief = RecoveryConsent.Describe();
    foreach (var line in brief.Lines)
        Console.Error.WriteLine(line);

    // A one-key flag cannot stand in for a phrase bound to this operation and target.
    if (args.Contains("--yes") || args.Contains("-y") || args.Contains("--always"))
        return Refuse("一次性的 --yes 标志不能替代与本次操作绑定的确认短语。没有启动脚本。");

    Console.Error.Write("输入确认短语以授权这次隔离演练（直接回车表示拒绝）: ");
    Console.Error.Flush();
    var typed = Console.ReadLine();
    var approval = RecoveryApproval.FromPhrase(typed);
    if (approval is null)
        return Refuse(string.IsNullOrWhiteSpace(typed)
            ? "没有读到确认短语。没有启动脚本。"
            : "确认短语与本次操作或当前目标不符。没有启动脚本。");

    var run = await IsolatedRecovery.ExecuteAsync(approval, CancellationToken.None);
    Console.WriteLine(JsonSerializer.Serialize(run, json));
    return run.CompleteSuccess ? 0 : 2;
}

var demo = args.Contains("--demo");
var report = demo ? DiagnosticEngine.Demo() : await DiagnosticEngine.ReadLiveAsync(CancellationToken.None);
var payload = new
{
    demo = report.Demo,
    sampledAt = report.SampledAt,
    fault = report.Fault.Class.ToString(),
    advice = report.Fault.Advice,
    recommendRestore = report.Fault.RecommendRestore,
    applicationSuccess = report.Fault.ApplicationSuccess,
    proxy = report.ProxySelection,
    clients = report.RunningClients,
    listeners = report.Listeners.Select(item => new { item.Port, item.ProcessName }),
    probes = report.Probes.Select(item => new { item.Target, item.StatusCode, item.ElapsedMs, item.PathLabel, item.Error }),
    capabilities = report.Capabilities.Select(item => new { item.Name, state = item.State.ToString(), item.Detail })
};
Console.WriteLine(JsonSerializer.Serialize(payload, json));
return report.Fault.Class == FaultClass.Unknown ? 2 : 0;
