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
    public void Diagnose_sentences_are_recognized(string text) =>
        Assert.True(RequestRouter.IsDiagnoseRequest(text));

    [Fact]
    public void A_setup_sentence_is_not_a_fault() =>
        Assert.False(RequestRouter.IsDiagnoseRequest("帮我准备代理设置"));

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
