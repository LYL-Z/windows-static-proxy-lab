using System.Text.Json;
using ProxyDoctor;
using Xunit;

namespace ProxyDoctor.Core.Tests;

public class MonitorEngineTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 25, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Default_channels_keep_their_own_intervals()
    {
        var engine = new MonitorEngine();
        var local = engine.Read(MonitorEngine.LocalChannelId, T0);
        var upstream = engine.Read(MonitorEngine.UpstreamChannelId, T0);
        var protocol = engine.Read(MonitorEngine.ProtocolChannelId, T0);

        Assert.Equal(TimeSpan.FromSeconds(20), local.Interval);
        Assert.Equal(TimeSpan.FromSeconds(60), local.Ttl);
        Assert.Equal(TimeSpan.FromSeconds(90), upstream.Interval);
        Assert.Equal(TimeSpan.FromSeconds(180), upstream.Ttl);
        Assert.Equal(TimeSpan.Zero, protocol.Interval);
        Assert.Equal(MonitorEngine.ProtocolFreshness, protocol.Ttl);
        Assert.True(MonitorEngine.LocalHeartbeat.Periodic);
        Assert.True(MonitorEngine.UpstreamHttps.Periodic);
        Assert.False(MonitorEngine.Protocol.Periodic);
        Assert.Equal(EvidenceState.Unknown, local.DisplayState);
        Assert.Null(local.SampledAt);
        Assert.Null(upstream.SampledAt);
        Assert.Null(protocol.SampledAt);
    }

    [Fact]
    public void Local_heartbeat_is_not_upstream_success()
    {
        var engine = Running();
        var local = engine.Record(MonitorEngine.LocalChannelId, Healthy("本地监听在"), T0);

        Assert.True(local.Accepted);
        Assert.False(local.Notify);
        Assert.Equal(MonitorTransition.Steady, local.Transition);
        Assert.False(engine.UpstreamIsSuccessful(T0));

        var snapshot = engine.Snapshot(T0);
        var localRow = snapshot.Channels[0];
        var upstreamRow = snapshot.Channels[1];
        Assert.Equal(EvidenceState.Partial, localRow.DisplayState);
        Assert.Equal(T0, localRow.SampledAt);
        Assert.Equal(EvidenceState.Unknown, upstreamRow.DisplayState);
        Assert.Null(upstreamRow.SampledAt);
        Assert.Null(upstreamRow.Failure);
        Assert.NotEqual(localRow.Evidence, upstreamRow.Evidence);
    }

    [Fact]
    public void Fresh_local_sample_does_not_clear_or_revive_upstream()
    {
        var engine = ShortClock();
        engine.Start(T0);
        engine.Record(MonitorEngine.UpstreamChannelId, Failed("上游超时"), T0);
        var later = T0.AddSeconds(31);
        engine.Record(MonitorEngine.LocalChannelId, Healthy("本地仍在"), later);

        var upstream = engine.Read(MonitorEngine.UpstreamChannelId, later);
        Assert.Equal(T0, upstream.SampledAt);
        Assert.True(upstream.Expired);
        Assert.Equal(EvidenceState.Unknown, upstream.DisplayState);
        Assert.Equal(EvidenceState.Fault, upstream.RecordedState);
        Assert.Equal("上游超时", upstream.Failure);
        Assert.False(engine.UpstreamIsSuccessful(later));
        Assert.Equal(1, upstream.ConsecutiveFailures);
    }

    [Fact]
    public void Local_heartbeat_sample_does_not_refresh_the_upstream_channel()
    {
        var engine = Running();
        engine.Record(MonitorEngine.UpstreamChannelId, Verified("HTTP 204"), T0);
        var heartbeatAt = T0.AddSeconds(10);
        var local = engine.Record(MonitorEngine.LocalChannelId, Healthy("本地心跳"), heartbeatAt);

        Assert.True(local.Accepted);
        Assert.Equal(MonitorEngine.LocalChannelId, engine.Events[^1].ChannelId);
        Assert.Contains("本地心跳", engine.Events[^1].Detail);

        var upstream = engine.Read(MonitorEngine.UpstreamChannelId, heartbeatAt);
        Assert.Equal(T0, upstream.SampledAt);
        Assert.NotEqual(heartbeatAt, upstream.SampledAt);
        Assert.Equal(EvidenceState.Verified, upstream.RecordedState);
        Assert.Equal(EvidenceState.Verified, upstream.DisplayState);
        Assert.Null(upstream.Failure);
        Assert.False(upstream.Expired);
        Assert.Equal(TimeSpan.FromMilliseconds(40), upstream.Latency);
        Assert.Equal("HTTP 204", upstream.Evidence);
        Assert.True(engine.UpstreamIsSuccessful(heartbeatAt));

        var localRow = engine.Read(MonitorEngine.LocalChannelId, heartbeatAt);
        Assert.Equal(heartbeatAt, localRow.SampledAt);
        Assert.Equal("本地心跳", localRow.Evidence);
        Assert.Equal(TimeSpan.FromMilliseconds(3), localRow.Latency);
    }

    [Fact]
    public void Sample_at_ttl_is_kept_and_the_next_tick_expires()
    {
        var engine = ShortClock();
        engine.Start(T0);
        engine.Record(MonitorEngine.UpstreamChannelId, Verified("HTTP 204"), T0);

        var atTtl = engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(30));
        Assert.False(atTtl.Expired);
        Assert.Equal(EvidenceState.Verified, atTtl.DisplayState);
        Assert.True(engine.UpstreamIsSuccessful(T0.AddSeconds(30)));

        var past = engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(30).AddTicks(1));
        Assert.True(past.Expired);
        Assert.Equal(EvidenceState.Unknown, past.DisplayState);
        Assert.Equal(EvidenceState.Verified, past.RecordedState);
        Assert.False(engine.UpstreamIsSuccessful(T0.AddSeconds(30).AddTicks(1)));
    }

    [Fact]
    public void Repeat_stays_quiet_until_the_failure_changes_or_recovers()
    {
        var engine = Running();
        var first = engine.Record(MonitorEngine.UpstreamChannelId, Failed("down"), T0);
        var repeat = engine.Record(MonitorEngine.UpstreamChannelId, Failed("down"), T0.AddSeconds(90));
        Assert.Equal(T0.AddSeconds(90), engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(90)).SampledAt);
        var changed = engine.Record(MonitorEngine.UpstreamChannelId, Failed("reset"), T0.AddSeconds(180));
        var recovered = engine.Record(MonitorEngine.UpstreamChannelId, Verified("HTTP 204"), T0.AddSeconds(270));
        var still = engine.Record(MonitorEngine.UpstreamChannelId, Verified("HTTP 204"), T0.AddSeconds(360));

        Assert.Equal(MonitorTransition.NewFailure, first.Transition);
        Assert.True(first.Notify);
        Assert.Equal(MonitorTransition.RepeatFailure, repeat.Transition);
        Assert.False(repeat.Notify);
        Assert.Equal(2, repeat.ConsecutiveFailures);
        Assert.Equal(MonitorTransition.NewFailure, changed.Transition);
        Assert.True(changed.Notify);
        Assert.Equal(MonitorTransition.Recovered, recovered.Transition);
        Assert.True(recovered.Notify);
        Assert.Equal(0, recovered.ConsecutiveFailures);
        Assert.Equal(MonitorTransition.Steady, still.Transition);
        Assert.False(still.Notify);
        Assert.Equal(T0.AddSeconds(360), engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(360)).SampledAt);
    }

    [Fact]
    public void Flaps_count_changes_rather_than_repeats()
    {
        var engine = Running();
        Assert.Equal(0, engine.Record(MonitorEngine.UpstreamChannelId, Failed("down"), T0).Flaps);
        var repeat = engine.Record(MonitorEngine.UpstreamChannelId, Failed("down"), T0.AddSeconds(1));
        Assert.Equal(2, repeat.ConsecutiveFailures);
        Assert.Equal(0, repeat.Flaps);
        Assert.Equal(1, engine.Record(MonitorEngine.UpstreamChannelId, Verified("up"), T0.AddSeconds(2)).Flaps);
        var again = engine.Record(MonitorEngine.UpstreamChannelId, Failed("down"), T0.AddSeconds(3));
        Assert.Equal(2, again.Flaps);
        Assert.Equal(2, engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(3)).Flaps);
    }

    [Fact]
    public void Event_list_drops_the_oldest_after_200()
    {
        var engine = Running();
        for (var i = 0; i < 250; i++)
        {
            engine.Record(MonitorEngine.UpstreamChannelId, Failed("f" + i), T0.AddSeconds(i));
        }

        var events = engine.Events;
        Assert.Equal(MonitorEngine.MaxEvents, events.Count);
        Assert.Equal(200, events.Count);
        Assert.Equal(52, events[0].Sequence);
        Assert.Equal(251, events[^1].Sequence);
        Assert.Equal(events[^1].Sequence - events[0].Sequence, events.Count - 1);
        Assert.Contains("f249", events[^1].Detail);
        Assert.DoesNotContain(events, item => item.Kind == MonitorEngine.EventStart);
        Assert.All(events, item => Assert.Equal(MonitorEngine.UpstreamChannelId, item.ChannelId));
    }

    [Fact]
    public void Log_rotation_keeps_the_newest_window_through_a_250_event_burst()
    {
        const int burst = 250;
        var engine = Running();
        for (var i = 0; i < burst - 1; i++)
            engine.Record(MonitorEngine.UpstreamChannelId, Failed("f" + i), T0.AddSeconds(i));

        var events = engine.Events;
        Assert.Equal(burst, events[^1].Sequence);
        Assert.Equal(MonitorEngine.MaxEvents, events.Count);
        Assert.Equal(burst - MonitorEngine.MaxEvents + 1, events[0].Sequence);
        Assert.Equal("NewFailure f49", events[0].Detail);
        Assert.Equal(T0.AddSeconds(49), events[0].At);
        Assert.Equal("NewFailure f248", events[^1].Detail);
        Assert.DoesNotContain(events, item => item.Detail == "NewFailure f48");
        Assert.DoesNotContain(events, item => item.Kind == MonitorEngine.EventStart);
        for (var i = 1; i < events.Count; i++)
        {
            Assert.Equal(events[i - 1].Sequence + 1, events[i].Sequence);
            Assert.True(events[i].At >= events[i - 1].At);
        }

        var tail = engine.Record(MonitorEngine.UpstreamChannelId, Failed("tail"), T0.AddSeconds(burst));
        events = engine.Events;
        Assert.True(tail.Accepted);
        Assert.Equal(MonitorEngine.MaxEvents, events.Count);
        Assert.Equal(52, events[0].Sequence);
        Assert.Equal("NewFailure f50", events[0].Detail);
        Assert.Equal("NewFailure tail", events[^1].Detail);
        Assert.Equal(burst + 1, events[^1].Sequence);
        Assert.DoesNotContain(events, item => item.Detail == "NewFailure f49");

        var upstream = engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(burst));
        Assert.Equal(T0.AddSeconds(burst), upstream.SampledAt);
        Assert.Equal("tail", upstream.Failure);
        Assert.Equal(EvidenceState.Fault, upstream.RecordedState);
        Assert.Equal(1, upstream.ConsecutiveFailures);
        Assert.Equal(249, upstream.Flaps);
        Assert.False(upstream.Expired);
        Assert.False(engine.UpstreamIsSuccessful(T0.AddSeconds(burst)));
    }

    [Fact]
    public void Event_file_rotates_to_200_lines_and_reloads_the_same_window()
    {
        var directory = Path.Combine(Path.GetTempPath(), "proxy-doctor-monitor-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "events.jsonl");
        try
        {
            var engine = Running();
            engine.Record(MonitorEngine.LocalChannelId, Healthy("本地心跳"), T0);
            Assert.Null(engine.Read(MonitorEngine.UpstreamChannelId, T0).SampledAt);
            Assert.False(engine.UpstreamIsSuccessful(T0));

            for (var i = 0; i < 250; i++)
                engine.Record(MonitorEngine.UpstreamChannelId, Failed("f" + i), T0.AddSeconds(i + 1));

            Assert.Throws<ArgumentException>(() => engine.SaveEvents(" "));
            Assert.Throws<ArgumentException>(() => engine.LoadEvents(""));
            engine.SaveEvents(path);

            var lines = File.ReadAllLines(path);
            Assert.Equal(MonitorEngine.MaxEvents, lines.Length);
            Assert.Equal(engine.Events.Count, lines.Length);
            Assert.Equal("NewFailure f50", engine.Events[0].Detail);
            Assert.Equal(engine.Events[0].Sequence, JsonSerializer.Deserialize<MonitorEvent>(lines[0])!.Sequence);
            Assert.Equal(engine.Events[^1].Sequence, JsonSerializer.Deserialize<MonitorEvent>(lines[^1])!.Sequence);
            Assert.DoesNotContain(lines, line => line.Contains("本地心跳", StringComparison.Ordinal));
            Assert.False(File.Exists(path + ".tmp"));

            var restored = new MonitorEngine();
            Assert.Throws<FileNotFoundException>(() => restored.LoadEvents(path + ".missing"));
            restored.LoadEvents(path);
            Assert.Equal(engine.Events, restored.Events);
            Assert.Equal(MonitorRunState.Stopped, restored.RunState);
            Assert.Null(restored.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(300)).SampledAt);
            Assert.Equal(EvidenceState.Unknown, restored.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(300)).DisplayState);
            Assert.False(restored.UpstreamIsSuccessful(T0.AddSeconds(300)));

            var older = new string[50];
            for (var i = 0; i < older.Length; i++)
            {
                older[i] = JsonSerializer.Serialize(new MonitorEvent(
                    i + 1, T0, MonitorEngine.EventSample, MonitorEngine.LocalChannelId, "old " + i));
            }
            File.WriteAllLines(path, older.Concat(lines));
            Assert.Equal(250, File.ReadAllLines(path).Length);

            var capped = new MonitorEngine();
            capped.LoadEvents(path);
            Assert.Equal(MonitorEngine.MaxEvents, capped.Events.Count);
            Assert.Equal(restored.Events, capped.Events);
            Assert.DoesNotContain(capped.Events, item => item.Detail.StartsWith("old ", StringComparison.Ordinal));
            Assert.Null(capped.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(300)).SampledAt);
            Assert.False(capped.UpstreamIsSuccessful(T0.AddSeconds(300)));

            var continued = capped.Events[^1].Sequence;
            capped.Start(T0.AddHours(1));
            Assert.Equal(MonitorEngine.MaxEvents, capped.Events.Count);
            Assert.Equal(continued + 1, capped.Events[^1].Sequence);
            Assert.Equal(MonitorEngine.EventStart, capped.Events[^1].Kind);
            Assert.NotEqual(MonitorEngine.UpstreamChannelId, capped.Events[^1].ChannelId);

            engine.Record(MonitorEngine.LocalChannelId, Healthy("窗口之后的心跳"), T0.AddSeconds(251));
            Assert.Equal(T0.AddSeconds(250), engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(251)).SampledAt);
            Assert.Equal("f249", engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(251)).Failure);
            engine.SaveEvents(path);
            var rotated = File.ReadAllLines(path);
            Assert.Equal(MonitorEngine.MaxEvents, rotated.Length);
            var reloaded = new MonitorEngine();
            reloaded.LoadEvents(path);
            Assert.Equal(engine.Events, reloaded.Events);
            Assert.Equal("NewFailure f51", reloaded.Events[0].Detail);
            Assert.Contains("窗口之后的心跳", reloaded.Events[^1].Detail);
            Assert.Equal(MonitorEngine.LocalChannelId, reloaded.Events[^1].ChannelId);
            Assert.Null(reloaded.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(300)).SampledAt);
            Assert.False(reloaded.UpstreamIsSuccessful(T0.AddSeconds(300)));
        }
        finally
        {
            if (Directory.Exists(directory))
                Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void Pause_and_stop_are_explicit_and_reject_later_samples()
    {
        var engine = new MonitorEngine();
        Assert.Equal(MonitorRunState.Stopped, engine.RunState);
        engine.Pause(T0);
        Assert.Equal(MonitorRunState.Stopped, engine.RunState);
        Assert.Empty(engine.Events);

        engine.Start(T0);
        engine.Record(MonitorEngine.LocalChannelId, Healthy("一次心跳"), T0);
        engine.Pause(T0.AddSeconds(1));
        var paused = engine.Record(MonitorEngine.LocalChannelId, Healthy("暂停期间的心跳"), T0.AddSeconds(2));
        engine.Pause(T0.AddSeconds(3));
        engine.Stop(T0.AddSeconds(4));
        var stopped = engine.Record(MonitorEngine.UpstreamChannelId, Verified("停止后的上游"), T0.AddSeconds(5));
        engine.Stop(T0.AddSeconds(6));

        Assert.False(paused.Accepted);
        Assert.False(paused.Notify);
        Assert.Equal(MonitorTransition.Ignored, paused.Transition);
        Assert.False(stopped.Accepted);
        Assert.Equal(MonitorRunState.Stopped, engine.RunState);
        Assert.Equal(T0, engine.Read(MonitorEngine.LocalChannelId, T0.AddSeconds(5)).SampledAt);
        Assert.Equal("一次心跳", engine.Read(MonitorEngine.LocalChannelId, T0.AddSeconds(5)).Evidence);
        Assert.Null(engine.Read(MonitorEngine.UpstreamChannelId, T0.AddSeconds(5)).SampledAt);
        Assert.False(engine.UpstreamIsSuccessful(T0.AddSeconds(5)));
        Assert.Equal(
            [MonitorEngine.EventStart, MonitorEngine.EventSample, MonitorEngine.EventPause, MonitorEngine.EventStop],
            engine.Events.Select(item => item.Kind).ToArray());

        engine.Start(T0.AddSeconds(7));
        Assert.Equal(MonitorRunState.Running, engine.RunState);
        Assert.Equal(2, engine.Events.Count(item => item.Kind == MonitorEngine.EventStart));
    }

    [Fact]
    public void Latency_is_the_timespan_supplied_by_the_caller()
    {
        var engine = Running();
        var latency = TimeSpan.FromMilliseconds(87);
        var result = engine.Record(
            MonitorEngine.UpstreamChannelId,
            new MonitorSample(EvidenceState.Verified, "HTTP 204", null, latency),
            T0);

        Assert.Equal(latency, result.Latency);
        Assert.Equal(latency, engine.Read(MonitorEngine.UpstreamChannelId, T0).Latency);
        Assert.Equal(TimeSpan.FromMilliseconds(4), engine.Record(
            MonitorEngine.ProtocolChannelId,
            new MonitorSample(EvidenceState.Partial, "手工协议", null, TimeSpan.FromMilliseconds(4)),
            T0.AddMilliseconds(4)).Latency);
        Assert.Equal(latency, engine.Read(MonitorEngine.UpstreamChannelId, T0).Latency);
    }

    [Fact]
    public void Polling_note_says_detection_is_not_instant()
    {
        var engine = Running();
        Assert.Contains("Polling is not instant detection", MonitorEngine.PollingIsNotInstantDetection);
        Assert.Contains("不是瞬时发现", MonitorEngine.PollingIsNotInstantDetection);
        Assert.Contains("本地心跳", MonitorEngine.PollingIsNotInstantDetection);
        Assert.Equal(MonitorEngine.PollingIsNotInstantDetection, engine.Snapshot(T0).PollingNote);
        Assert.Contains(MonitorEngine.PollingIsNotInstantDetection, engine.Events[0].Detail);
    }

    [Fact]
    public void Protocol_and_upstream_do_not_share_a_clock_or_streak()
    {
        var engine = Running();
        var protocolAt = T0.AddMinutes(3);
        engine.Record(MonitorEngine.ProtocolChannelId, Verified("协议有响应"), protocolAt);
        var upstream = engine.Record(MonitorEngine.UpstreamChannelId, Failed("上游失败"), T0.AddSeconds(90));
        var protocolAgain = engine.Record(MonitorEngine.ProtocolChannelId, Failed("协议失败"), protocolAt.AddMinutes(1));

        var protocol = engine.Read(MonitorEngine.ProtocolChannelId, protocolAt.AddMinutes(1));
        var upstreamRow = engine.Read(MonitorEngine.UpstreamChannelId, protocolAt.AddMinutes(1));
        Assert.Equal(protocolAt.AddMinutes(1), protocol.SampledAt);
        Assert.Equal(T0.AddSeconds(90), upstreamRow.SampledAt);
        Assert.Equal(TimeSpan.Zero, protocol.Interval);
        Assert.Equal(TimeSpan.FromSeconds(90), upstreamRow.Interval);
        Assert.Equal(1, protocol.ConsecutiveFailures);
        Assert.Equal(1, upstream.ConsecutiveFailures);
        Assert.Equal(MonitorTransition.NewFailure, protocolAgain.Transition);
        Assert.True(protocolAgain.Notify);
        Assert.False(engine.UpstreamIsSuccessful(protocolAt.AddMinutes(1)));
    }

    [Fact]
    public void Unknown_channel_is_rejected()
    {
        var engine = Running();
        Assert.Throws<ArgumentException>(() => engine.Read("other", T0));
        Assert.Throws<ArgumentException>(() => engine.Record("other", Healthy("x"), T0));
        Assert.Throws<ArgumentOutOfRangeException>(() => engine.Record(
            MonitorEngine.LocalChannelId,
            new MonitorSample(EvidenceState.Partial, "x", null, TimeSpan.FromMilliseconds(-1)),
            T0));
    }

    private static MonitorEngine Running()
    {
        var engine = new MonitorEngine();
        engine.Start(T0);
        return engine;
    }

    private static MonitorEngine ShortClock() => new(
    [
        new MonitorChannelDefinition("local", "本地心跳", TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(30)),
        new MonitorChannelDefinition("upstream", "上游 HTTPS", TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(30)),
        new MonitorChannelDefinition("protocol", "协议检查", TimeSpan.Zero, TimeSpan.FromSeconds(30))
    ]);

    private static MonitorSample Healthy(string evidence) =>
        new(EvidenceState.Partial, evidence, null, TimeSpan.FromMilliseconds(3));

    private static MonitorSample Verified(string evidence) =>
        new(EvidenceState.Verified, evidence, null, TimeSpan.FromMilliseconds(40));

    private static MonitorSample Failed(string failure) =>
        new(EvidenceState.Fault, failure, failure, TimeSpan.FromMilliseconds(90));
}
