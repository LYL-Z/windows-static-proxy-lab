using System.Text.Json;
using ProxyDoctor;

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
    }, new JsonSerializerOptions { WriteIndented = true }));
    return engine.Ok ? 0 : 2;
}

if (args.Contains("--isolated-recovery"))
{
    Console.Error.WriteLine("Usage: --isolated-recovery exits 0 only when CompleteSuccess is true; otherwise 2.");
    var run = await IsolatedRecovery.ExecuteAsync(IsolatedRecovery.AuthorizationText, CancellationToken.None);
    Console.WriteLine(JsonSerializer.Serialize(run, new JsonSerializerOptions { WriteIndented = true }));
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
Console.WriteLine(JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }));
return report.Fault.Class == FaultClass.Unknown ? 2 : 0;
