using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

public class ClassifierTests
{
    [Fact]
    public void User_off_is_not_a_repair()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            UserTurnedProxyOff = true,
            ProxyEnabled = false,
            UiEnabled = false,
            PacConfigured = false,
            CoreRunning = false,
            MixedPortOpen = false,
            FirstHopOpen = false
        });
        Assert.Equal(FaultClass.UserOff, result.Class);
        Assert.False(result.RecommendRestore);
    }

    [Fact]
    public void Saved_and_windows_mismatch_is_drift()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            ProxyEnabled = false,
            UiEnabled = true,
            PacConfigured = false,
            ProxyTargetsExpected = true,
            CoreRunning = false,
            MixedPortOpen = true,
            MixedIpv4CoreOwned = true,
            FirstHopExpected = true,
            FirstHopOpen = false
        });
        Assert.Equal(FaultClass.ProxyDrift, result.Class);
    }

    [Fact]
    public void Core_down_when_listener_process_is_down()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            ProxyEnabled = true,
            UiEnabled = true,
            PacConfigured = false,
            ProxyTargetsExpected = true,
            CoreRunning = false,
            MixedPortOpen = true,
            MixedIpv4CoreOwned = true,
            FirstHopExpected = true,
            FirstHopOpen = false
        });
        Assert.Equal(FaultClass.CoreDown, result.Class);
    }

    [Fact]
    public void First_hop_down_is_separate_from_the_core()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            ProxyEnabled = true,
            UiEnabled = true,
            PacConfigured = false,
            ProxyTargetsExpected = true,
            CoreRunning = true,
            MixedPortOpen = true,
            MixedIpv4CoreOwned = true,
            FirstHopExpected = true,
            FirstHopOpen = false
        });
        Assert.Equal(FaultClass.FirstHopDown, result.Class);
    }

    [Fact]
    public void Aligned_is_not_application_success()
    {
        var result = FaultClassifier.Classify(new FaultObservation
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
        });
        Assert.Equal(FaultClass.Aligned, result.Class);
        Assert.False(result.ApplicationSuccess);
    }

    [Fact]
    public void Pac_without_a_clear_path_is_unknown()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            ProxyEnabled = false,
            UiEnabled = false,
            PacConfigured = true
        });
        Assert.Equal(FaultClass.Unknown, result.Class);
    }

    [Theory]
    [InlineData("检查我的代理为什么没有正常工作。")]
    [InlineData("StarSky 已经重新开启，但 Clash 没有流量。")]
    [InlineData("检查我的电脑网络配置是否正常。")]
    [InlineData("检查网络故障并提供恢复方案。")]
    [InlineData("全面检查我的网络")]
    [InlineData("检查网络")]
    [InlineData("StarSky 停止运行了")]
    [InlineData("Clash 没有流量")]
    [InlineData("检查异常并提供恢复方案")]
    public void Diagnose_sentences_are_recognized(string text)
    {
        Assert.True(RequestRouter.IsDiagnoseRequest(text));
        Assert.Equal(RequestIntent.Diagnose, RequestRouter.Route(text));
        Assert.Equal("diagnose", RequestRouter.IntentToken(RequestRouter.Route(text)));
    }

    [Fact]
    public void A_setup_sentence_is_not_a_fault()
    {
        Assert.False(RequestRouter.IsDiagnoseRequest("帮我准备代理设置"));
        Assert.Equal(RequestIntent.Unspecified, RequestRouter.Route("帮我准备代理设置"));
    }

    [Fact]
    public void Keep_original_configuration_is_no_modify()
    {
        const string text = "保持原配置，不擅自修改";
        Assert.False(RequestRouter.IsDiagnoseRequest(text));
        Assert.True(RequestRouter.IsNoModifyRequest(text));
        Assert.Equal(RequestIntent.NoModify, RequestRouter.Route(text));
        Assert.Equal("no-modify", RequestRouter.IntentToken(RequestIntent.NoModify));
        Assert.Equal(RequestIntent.NoModify, RequestRouter.Route("全面检查我的网络，保持原配置，不擅自修改"));
        Assert.False(RequestRouter.IsDiagnoseRequest("全面检查我的网络，保持原配置，不擅自修改"));
        Assert.Equal(RequestIntent.NoModify, RequestRouter.Route("检查网络，但保留现有配置"));
        Assert.Equal(RequestIntent.NoModify, RequestRouter.Route("只读检查我的网络，保持现有配置"));
    }

    [Theory]
    [InlineData(1, "127.0.0.1:18080", "127.0.0.1:18080")]
    [InlineData(1, "10.1.2.3:7897", "TARGET_OTHER")]
    [InlineData(0, "127.0.0.1:7897", "OFF")]
    public void Proxy_text_keeps_any_loopback_port(int enable, string server, string expected) =>
        Assert.Equal(expected, NetworkReader.FormatProxyServer(enable, server));

    [Fact]
    public void Multiple_core_listeners_follow_the_selected_port()
    {
        var listeners = new ListenerFact[]
        {
            new(7897, "verge-mihomo", true),
            new(18080, "verge-mihomo", true)
        };
        Assert.Equal(18080, NetworkReader.ChooseCore(listeners, "127.0.0.1:18080")?.Port);
        Assert.Null(NetworkReader.ChooseCore(listeners, "127.0.0.1:9"));
    }

    [Fact]
    public void User_off_blocks_an_enabling_snapshot_and_rollback_restores()
    {
        var proxy = new IsolatedProxy { UserOff = true };
        Assert.Equal(32, proxy.ApplySnapshot(true, "127.0.0.1:9"));
        Assert.False(proxy.Enabled);
        proxy.Rollback();
        Assert.False(proxy.Enabled);
    }

    [Fact]
    public void Alert_gate_is_silent_until_the_key_changes()
    {
        var gate = new AlertGate();
        Assert.False(gate.ShouldNotify("Aligned|127.0.0.1:7897"));
        Assert.False(gate.ShouldNotify("Aligned|127.0.0.1:7897"));
        Assert.True(gate.ShouldNotify("ProxyDrift|127.0.0.1:11119"));
        Assert.False(gate.ShouldNotify("ProxyDrift|127.0.0.1:11119"));
    }

    [Fact]
    public void Stale_paused_or_demo_samples_are_dropped()
    {
        Assert.False(SampleGate.Accept(1, 2, false, false));
        Assert.False(SampleGate.Accept(1, 1, true, false));
        Assert.False(SampleGate.Accept(1, 1, false, true));
        Assert.True(SampleGate.Accept(4, 4, false, false));
    }

    [Fact]
    public void Expired_or_failed_monitor_samples_are_not_shown_as_healthy()
    {
        var sample = new ChannelSample("upstream", "上游", DateTimeOffset.Now.AddMinutes(-5),
            TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180), EvidenceState.Verified, "old", null);
        Assert.Equal(EvidenceState.Unknown, sample.Display(DateTimeOffset.Now, false));
        Assert.Equal(EvidenceState.Fault, sample.Display(DateTimeOffset.Now, true));
    }

    [Fact]
    public void Repeated_failures_and_flaps_are_counted_separately()
    {
        var streak = new FaultStreak();
        Assert.Equal("new", streak.Observe("down"));
        Assert.Equal("repeat", streak.Observe("down"));
        Assert.Equal(2, streak.Consecutive);
        Assert.Equal("recovered", streak.Observe(null));
        Assert.Equal(1, streak.Flaps);
        Assert.Equal("new", streak.Observe("down"));
        Assert.Equal(2, streak.Flaps);
    }

    [Fact]
    public void Listener_up_and_upstream_down_does_not_restart_the_client()
    {
        var text = ClientLayers.Decide(true, true, false, false);
        Assert.Contains("不会重启", text);
        Assert.Contains("不等于加速", text);
    }

    [Fact]
    public async Task Wrong_authorization_does_not_start_the_rollback_script()
    {
        var run = await IsolatedRecovery.ExecuteAsync("no", CancellationToken.None);
        Assert.False(run.ScriptStarted);
        Assert.Equal(-1, run.TransactionExit);
    }

    [Fact]
    public async Task Isolated_rollback_returns_32_and_leaves_the_live_proxy()
    {
        var before = NetworkReader.LiveProxyStamp();
        var run = await IsolatedRecovery.ExecuteAsync(IsolatedRecovery.AuthorizationText, CancellationToken.None);
        Assert.True(run.ScriptStarted, run.Detail);
        Assert.Equal(32, run.TransactionExit);
        Assert.True(run.LiveUnchanged);
        Assert.True(run.ProfileRestored);
        Assert.True(run.JournalClear);
        Assert.Contains("enabled=0", run.Writes);
        Assert.DoesNotContain("enabled=1", run.Writes);
        Assert.True(run.CompleteSuccess, run.Detail);
        Assert.Equal(before, NetworkReader.LiveProxyStamp());
    }

    [Fact]
    public async Task Cancelled_recovery_does_not_start_or_count_as_success()
    {
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        var run = await IsolatedRecovery.ExecuteAsync(IsolatedRecovery.AuthorizationText, cancel.Token);
        Assert.False(run.ScriptStarted);
        Assert.True(run.Cancelled);
        Assert.False(run.CompleteSuccess);
    }

    [Fact]
    public void Exit_code_alone_is_not_recovery_success()
    {
        var onlyCode = new RecoveryResult(false, true, false, false, 0, 32, 32, false, false, false, true,
            RecoveryResult.IsolationLabel, "", "只有退出码");
        Assert.False(onlyCode.WithVerdict().CompleteSuccess);
        Assert.False(RecoveryTrust.WritesMatchScenario("enabled=0 server=old:8080\nenabled=1 server=old:8080"));
        Assert.False(RecoveryTrust.WritesMatchScenario("enabled=0"));
        Assert.False(RecoveryTrust.WritesMatchScenario("prefix enabled=0 server=old:8080"));
        Assert.True(RecoveryTrust.WritesMatchScenario("enabled=0 server=old:8080\r\n"));
        Assert.False(RecoveryTrust.IsStrictChild(@"C:\Temp", @"C:\TempEvil"));
        Assert.True(RecoveryTrust.IsStrictChild(@"C:\Temp", @"C:\Temp\child"));
        Assert.False(RecoveryTrust.IsStrictChild(@"C:\Temp", @"C:\Temp\..\Windows"));
    }

    [Fact]
    public void Trusted_engine_and_script_match_the_reviewed_hashes()
    {
        // F69/F70: recovery must resolve from the packaged engine\ folder beside the
        // binary, not from a repository checkout above it.
        var package = EnginePackage.Resolve();
        Assert.True(package.Ok, package.Detail);
        Assert.NotNull(IsolatedRecovery.FindScript());
        Assert.NotNull(IsolatedRecovery.FindEngineRoot());
        Assert.EndsWith(EnginePackage.DirectoryName, package.EngineRoot);
        Assert.Equal(
            Path.Combine(package.EngineRoot!, EnginePackage.ScriptRelative),
            package.ScriptPath);
        Assert.Equal(3, package.Files.Count);
    }

    [Fact]
    public void Both_off_without_a_record_is_not_confirmed_intent()
    {
        var result = FaultClassifier.Classify(new FaultObservation
        {
            ProxyEnabled = false,
            UiEnabled = false,
            PacConfigured = false,
            CoreRunning = false
        });
        Assert.Equal(FaultClass.ObservedOff, result.Class);
        Assert.False(result.RecommendRestore);
    }
}
