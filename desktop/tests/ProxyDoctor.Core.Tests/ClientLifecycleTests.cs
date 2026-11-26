using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

public class ClientLifecycleTests
{
    [Fact]
    public void User_off_does_not_start_even_when_the_path_looks_healthy()
    {
        var verdict = ClientLifecycle.Classify(
            processPresent: true,
            listenerPresent: true,
            uiSaysAccelerating: true,
            upstreamOk: true,
            userTurnedOff: true);

        Assert.Equal(ClientLifecycleState.UserOff, verdict.State);
        Assert.Contains("不要启动", verdict.Guidance);
        AssertLimit(verdict.Guidance);
    }

    [Fact]
    public void User_off_still_wins_when_the_process_is_down()
    {
        var verdict = ClientLifecycle.Classify(false, false, null, null, true);
        Assert.Equal(ClientLifecycleState.UserOff, verdict.State);
        Assert.Contains("不要启动", verdict.Guidance);
    }

    [Fact]
    public void Missing_process_stays_down_even_if_a_listener_is_reported()
    {
        var verdict = ClientLifecycle.Classify(false, true, true, true, false);
        Assert.Equal(ClientLifecycleState.ProcessDown, verdict.State);
        Assert.Contains("进程不在", verdict.Guidance);
        Assert.Contains("报告有监听", verdict.Guidance);
        AssertLimit(verdict.Guidance);
    }

    [Fact]
    public void Process_without_a_listener_is_not_upgraded_by_ui_or_upstream()
    {
        var verdict = ClientLifecycle.Classify(true, false, true, true, false);
        Assert.Equal(ClientLifecycleState.ProcessUpNoListener, verdict.State);
        Assert.Contains("没有确认", verdict.Guidance);
        Assert.Contains("界面显示正在加速", verdict.Guidance);
    }

    [Fact]
    public void Listener_without_an_upstream_sample_stays_unknown()
    {
        var verdict = ClassifyReady(uiSaysAccelerating: false, upstreamOk: null);
        Assert.Equal(ClientLifecycleState.ListenerUpstreamUnknown, verdict.State);
        Assert.Contains("还未知", verdict.Guidance);
        Assert.Contains("没有显示正在加速", verdict.Guidance);
    }

    [Fact]
    public void Listener_with_a_failed_upstream_is_not_a_restart_success()
    {
        var verdict = ClassifyReady(uiSaysAccelerating: null, upstreamOk: false);
        Assert.Equal(ClientLifecycleState.ListenerUpstreamFailed, verdict.State);
        Assert.Contains("上游失败", verdict.Guidance);
        Assert.Contains("是否显示加速还未知", verdict.Guidance);
        Assert.Contains("重启不是已恢复的加速", verdict.Guidance);
    }

    [Fact]
    public void Listener_and_upstream_ok_is_only_this_sample()
    {
        var verdict = ClassifyReady(uiSaysAccelerating: true, upstreamOk: true);
        Assert.Equal(ClientLifecycleState.ListenerUpstreamOk, verdict.State);
        Assert.Contains("这一次上游可达", verdict.Guidance);
        Assert.Contains("界面文案不能代替", verdict.Guidance);
        AssertLimit(verdict.Guidance);
    }

    [Theory]
    [InlineData(false, false, false)]
    [InlineData(false, true, false)]
    [InlineData(true, false, false)]
    [InlineData(true, true, true)]
    public void The_same_inputs_always_return_the_same_verdict(bool processPresent, bool listenerPresent, bool userTurnedOff)
    {
        var first = ClientLifecycle.Classify(processPresent, listenerPresent, null, null, userTurnedOff);
        var second = ClientLifecycle.Classify(new ClientLifecycleObservation(processPresent, listenerPresent, null, null, userTurnedOff));
        Assert.Equal(first, second);
    }

    [Fact]
    public void States_cover_the_six_required_distinctions()
    {
        var names = Enum.GetNames<ClientLifecycleState>();
        Assert.Equal(
            new[]
            {
                nameof(ClientLifecycleState.UserOff),
                nameof(ClientLifecycleState.ProcessDown),
                nameof(ClientLifecycleState.ProcessUpNoListener),
                nameof(ClientLifecycleState.ListenerUpstreamUnknown),
                nameof(ClientLifecycleState.ListenerUpstreamFailed),
                nameof(ClientLifecycleState.ListenerUpstreamOk)
            },
            names);
    }

    private static ClientLifecycleVerdict ClassifyReady(bool? uiSaysAccelerating, bool? upstreamOk) =>
        ClientLifecycle.Classify(true, true, uiSaysAccelerating, upstreamOk, false);

    private static void AssertLimit(string guidance)
    {
        Assert.Contains("重启不是已恢复的加速", guidance);
        Assert.Contains("没有找到 StarSky 或 magicspeed 受支持的重连 API", guidance);
        Assert.Contains("https://wiki.metacubex.one/en/api/", guidance);
        Assert.Contains("https://wiki.metacubex.one/en/config/general/", guidance);
        Assert.Contains("https://github.com/clash-verge-rev/clash-verge-rev/discussions/6951", guidance);
        Assert.Contains("https://clash-verge-rev.github.io/faq/other.html", guidance);
        Assert.Contains("external-controller", guidance);
        Assert.Contains("GET /version", guidance);
        Assert.Contains("POST /restart", guidance);
        Assert.Contains("本构建不调用正在运行的控制器", guidance);
    }
}
