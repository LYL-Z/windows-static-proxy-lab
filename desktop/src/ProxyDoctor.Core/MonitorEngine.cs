namespace ProxyDoctor;

public enum MonitorRunState
{
    Stopped,
    Running,
    Paused
}

public enum MonitorTransition
{
    Ignored,
    Steady,
    NewFailure,
    RepeatFailure,
    Recovered
}

public sealed record MonitorChannelDefinition(string Id, string Name, TimeSpan Interval, TimeSpan Ttl)
{
    public bool Periodic => Interval > TimeSpan.Zero;
}

public sealed record MonitorSample(
    EvidenceState State,
    string Evidence,
    string? Failure,
    TimeSpan Latency);

public sealed record MonitorChannelSnapshot(
    string Id,
    string Name,
    DateTimeOffset? SampledAt,
    TimeSpan Interval,
    TimeSpan Ttl,
    EvidenceState RecordedState,
    EvidenceState DisplayState,
    string Evidence,
    string? Failure,
    bool Expired,
    int ConsecutiveFailures,
    int Flaps,
    TimeSpan? Latency);

public sealed record MonitorEvent(
    long Sequence,
    DateTimeOffset At,
    string Kind,
    string ChannelId,
    string Detail);

public sealed record MonitorSampleResult(
    bool Accepted,
    bool Notify,
    MonitorTransition Transition,
    int ConsecutiveFailures,
    int Flaps,
    TimeSpan Latency);

public sealed record MonitorSnapshot(
    MonitorRunState RunState,
    IReadOnlyList<MonitorChannelSnapshot> Channels,
    string PollingNote);

/// <summary>
/// In-memory channel monitor. Polling is not instant detection: the caller supplies
/// the measured latency, and this type does not schedule timers or open sockets.
/// A local heartbeat never writes the upstream channel.
/// </summary>
public sealed class MonitorEngine
{
    public const int MaxEvents = 200;
    public const string EventStart = "start";
    public const string EventPause = "pause";
    public const string EventStop = "stop";
    public const string EventSample = "sample";
    public const string LocalChannelId = "local";
    public const string UpstreamChannelId = "upstream";
    public const string ProtocolChannelId = "protocol";

    /// <summary>
    /// Polling is not instant detection. Outages shorter than a channel interval are invisible.
    /// </summary>
    public const string PollingIsNotInstantDetection =
        "Polling is not instant detection. 周期轮询不是瞬时发现。比通道间隔更短的中断看不到。本地心跳正常不等于上游 HTTPS 成功。";

    public static readonly TimeSpan ProtocolFreshness = TimeSpan.FromMinutes(15);

    public static MonitorChannelDefinition LocalHeartbeat { get; } =
        new(LocalChannelId, "本地心跳", TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(60));

    public static MonitorChannelDefinition UpstreamHttps { get; } =
        new(UpstreamChannelId, "上游 HTTPS", TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180));

    public static MonitorChannelDefinition Protocol { get; } =
        new(ProtocolChannelId, "协议检查", TimeSpan.Zero, ProtocolFreshness);

    public static IReadOnlyList<MonitorChannelDefinition> DefaultChannels { get; } =
        [LocalHeartbeat, UpstreamHttps, Protocol];

    private readonly object _gate = new();
    private readonly Dictionary<string, Slot> _slots = new(StringComparer.Ordinal);
    private readonly List<string> _order = [];
    private readonly Queue<MonitorEvent> _events = new();
    private MonitorRunState _runState = MonitorRunState.Stopped;
    private long _sequence;

    public MonitorEngine() : this(DefaultChannels) { }

    public MonitorEngine(IReadOnlyList<MonitorChannelDefinition> channels)
    {
        ArgumentNullException.ThrowIfNull(channels);
        if (channels.Count == 0)
            throw new ArgumentException("At least one channel is required.", nameof(channels));
        foreach (var channel in channels)
        {
            if (string.IsNullOrWhiteSpace(channel.Id))
                throw new ArgumentException("A channel needs an id.", nameof(channels));
            if (channel.Ttl <= TimeSpan.Zero)
                throw new ArgumentOutOfRangeException(nameof(channels), "TTL must be greater than zero.");
            if (channel.Interval < TimeSpan.Zero)
                throw new ArgumentOutOfRangeException(nameof(channels), "Interval cannot be negative.");
            if (_slots.ContainsKey(channel.Id))
                throw new ArgumentException("Duplicate channel id: " + channel.Id, nameof(channels));
            _slots.Add(channel.Id, new Slot(channel));
            _order.Add(channel.Id);
        }
    }

    public MonitorRunState RunState
    {
        get { lock (_gate) return _runState; }
    }

    public IReadOnlyList<MonitorEvent> Events
    {
        get { lock (_gate) return _events.ToArray(); }
    }

    public void Start(DateTimeOffset at) => ChangeRunState(MonitorRunState.Running, EventStart, at, "监测运行。 " + PollingIsNotInstantDetection);

    public void Pause(DateTimeOffset at)
    {
        lock (_gate)
        {
            if (_runState != MonitorRunState.Running) return;
            _runState = MonitorRunState.Paused;
            Append(at, EventPause, "", "监测已暂停。");
        }
    }

    public void Stop(DateTimeOffset at) => ChangeRunState(MonitorRunState.Stopped, EventStop, at, "监测已停止。");

    public MonitorSampleResult Record(string channelId, MonitorSample sample, DateTimeOffset sampledAt)
    {
        ArgumentNullException.ThrowIfNull(sample);
        if (sample.Latency < TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(sample), "Measured latency cannot be negative.");
        lock (_gate)
        {
            var slot = Require(channelId);
            if (_runState != MonitorRunState.Running)
            {
                return new MonitorSampleResult(false, false, MonitorTransition.Ignored,
                    slot.Streak.Consecutive, slot.Streak.Flaps, sample.Latency);
            }

            var wasFailing = slot.Streak.Last is not null;
            var observed = slot.Streak.Observe(sample.Failure);
            var transition = Map(observed, wasFailing, sample.Failure);
            var notify = transition is MonitorTransition.NewFailure or MonitorTransition.Recovered;
            slot.Sample = new ChannelSample(
                slot.Definition.Id,
                slot.Definition.Name,
                sampledAt,
                slot.Definition.Interval,
                slot.Definition.Ttl,
                sample.State,
                sample.Evidence,
                sample.Failure);
            // Caller measured this. The engine does not time a poll and does not contact upstream.
            slot.Latency = sample.Latency;
            Append(sampledAt, EventSample, slot.Definition.Id, transition + " " + (sample.Failure ?? sample.Evidence));
            return new MonitorSampleResult(true, notify, transition, slot.Streak.Consecutive, slot.Streak.Flaps, sample.Latency);
        }
    }

    public MonitorChannelSnapshot Read(string channelId, DateTimeOffset now)
    {
        lock (_gate) return SnapshotOf(Require(channelId), now);
    }

    public MonitorSnapshot Snapshot(DateTimeOffset now)
    {
        lock (_gate)
        {
            var channels = new MonitorChannelSnapshot[_order.Count];
            for (var i = 0; i < _order.Count; i++)
                channels[i] = SnapshotOf(_slots[_order[i]], now);
            return new MonitorSnapshot(_runState, channels, PollingIsNotInstantDetection);
        }
    }

    public bool UpstreamIsSuccessful(DateTimeOffset now)
    {
        var upstream = Read(UpstreamChannelId, now);
        return upstream.DisplayState == EvidenceState.Verified && upstream.Failure is null && !upstream.Expired;
    }

    private void ChangeRunState(MonitorRunState next, string kind, DateTimeOffset at, string detail)
    {
        lock (_gate)
        {
            if (_runState == next) return;
            _runState = next;
            Append(at, kind, "", detail);
        }
    }

    private MonitorChannelSnapshot SnapshotOf(Slot slot, DateTimeOffset now)
    {
        var definition = slot.Definition;
        if (slot.Sample is null)
        {
            return new MonitorChannelSnapshot(
                definition.Id, definition.Name, null, definition.Interval, definition.Ttl,
                EvidenceState.Unknown, EvidenceState.Unknown, "尚无采样", null, false,
                slot.Streak.Consecutive, slot.Streak.Flaps, null);
        }

        var sample = slot.Sample;
        return new MonitorChannelSnapshot(
            sample.Id, sample.Name, sample.SampledAt, sample.Interval, sample.Ttl,
            sample.State, sample.Display(now, monitorFaulted: false), sample.Evidence, sample.Failure,
            sample.Expired(now), slot.Streak.Consecutive, slot.Streak.Flaps, slot.Latency);
    }

    private Slot Require(string channelId)
    {
        if (string.IsNullOrWhiteSpace(channelId) || !_slots.TryGetValue(channelId, out var slot))
            throw new ArgumentException("Unknown monitor channel: " + channelId, nameof(channelId));
        return slot;
    }

    private void Append(DateTimeOffset at, string kind, string channelId, string detail)
    {
        _sequence++;
        _events.Enqueue(new MonitorEvent(_sequence, at, kind, channelId, detail));
        while (_events.Count > MaxEvents)
            _events.Dequeue();
    }

    private static MonitorTransition Map(string observed, bool wasFailing, string? failure)
    {
        if (failure is null && !wasFailing) return MonitorTransition.Steady;
        return observed switch
        {
            "new" => MonitorTransition.NewFailure,
            "repeat" => MonitorTransition.RepeatFailure,
            "recovered" => MonitorTransition.Recovered,
            _ => throw new InvalidOperationException("Unexpected streak result: " + observed)
        };
    }

    private sealed class Slot(MonitorChannelDefinition definition)
    {
        public MonitorChannelDefinition Definition { get; } = definition;
        public ChannelSample? Sample { get; set; }
        public TimeSpan? Latency { get; set; }
        public FaultStreak Streak { get; } = new();
    }
}
