using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Text.Json;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using ProxyDoctor;

namespace ProxyDoctor.Desktop;

public partial class ShellViewModel : ObservableObject
{
    [ObservableProperty] private string _section = "overview";
    [ObservableProperty] private bool _dark;
    [ObservableProperty] private bool _demo;
    [ObservableProperty] private bool _busy;
    [ObservableProperty] private string _status = "尚未采样";
    [ObservableProperty] private string _summary = "按“只读检查”读取这台电脑的当前代理状态。绿色只会出现在有证据的项目上。";
    [ObservableProperty] private string _proxy = "—";
    [ObservableProperty] private string _clients = "—";
    [ObservableProperty] private string _listeners = "—";
    [ObservableProperty] private string _probes = "尚未请求";
    [ObservableProperty] private string _capabilities = "";
    [ObservableProperty] private string _events = "";
    [ObservableProperty] private string _advice = "还没有诊断结果。";
    [ObservableProperty] private bool _sampled;
    [ObservableProperty] private bool _paused;
    [ObservableProperty] private string _monitor = "监测尚未开始";
    [ObservableProperty] private string _recoveryLog = "还没有预览。授权之前不会运行恢复脚本。";
    [ObservableProperty] private string _channels = "本地心跳、上游和协议检查还没有各自的采样。";
    [ObservableProperty] private string _upstreamLine = "上游通道还没有采样。本地监听正常不等于上游可用。";
    [ObservableProperty] private string _clientLine = "还没有把进程、监听和上游放在一起看。";

    public ObservableCollection<CheckRow> Checks { get; } = new();
    public event Action<string>? AlertRequested;

    private readonly Dispatcher _dispatcher = Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly CancellationTokenSource _monitorStop = new();
    private MonitorEngine _monitorEngine = new();
    private DiagnosticReport? _latestLocal;
    private int _monitorStarted;
    private int _networkChangePending;
    private int _busyGate;
    private int _epoch;

    public string ModeLabel => Demo ? "演示数据，不是这台电脑的实时结果" : Paused ? "实时只读，监测已暂停" : "实时只读，每 20 秒采样";

    partial void OnDemoChanged(bool value)
    {
        Interlocked.Increment(ref _epoch);
        Status = "模式已切换";
        Summary = value ? "演示数据，不是这台电脑的实时结果。上一次实时结果已清除。" : "已离开演示。上一次结果已清除。";
        Proxy = Clients = Listeners = Probes = Capabilities = Events = "—";
        Checks.Clear();
        _latestLocal = null;
        _monitorEngine = new MonitorEngine();
        if (Volatile.Read(ref _monitorStarted) == 1 && !value && !Paused)
            _monitorEngine.Start(DateTimeOffset.Now);
        RenderChannels();
        Advice = "等待新的采样。";
        Sampled = false;
        ClientLine = value
            ? "演示数据不判断这台电脑的客户端。进程和端口来自固定样例。"
            : "已离开演示。上一次客户端结论已清除。";
        OnPropertyChanged(nameof(ModeLabel));
    }

    public string PauseLabel => Paused ? "继续监测" : "暂停监测";

    partial void OnPausedChanged(bool value)
    {
        Interlocked.Increment(ref _epoch);
        if (!Demo && Volatile.Read(ref _monitorStarted) == 1)
        {
            if (value) _monitorEngine.Pause(DateTimeOffset.Now);
            else _monitorEngine.Start(DateTimeOffset.Now);
        }
        PersistEvent(value ? "监测已暂停。" : "监测已继续。");
        RenderChannels();
        OnPropertyChanged(nameof(ModeLabel));
        OnPropertyChanged(nameof(PauseLabel));
    }

    partial void OnSectionChanged(string value)
    {
        if (value is "overview" or "checks" or "monitor" or "privacy" or "clients" or "recovery" or "events")
            return;
        Section = "overview";
    }

    public void StartMonitor()
    {
        if (Interlocked.CompareExchange(ref _monitorStarted, 1, 0) != 0) return;
        if (!Paused && !Demo) _monitorEngine.Start(DateTimeOffset.Now);
        _refresh.Tick += RefreshMonitor;
        _refresh.Start();
        NetworkChange.NetworkAddressChanged += NetworkAddressChanged;
        _ = PollAsync(MonitorEngine.LocalHeartbeat, SampleLocalAsync);
        _ = PollAsync(MonitorEngine.UpstreamHttps, SampleHttpsAsync);
        Monitor = "本地每 20 秒采样。地址变化会提示补测。上游 HTTPS 每 90 秒采样。协议检查按需执行。";
        PersistEvent("监测已开始。");
    }

    public void StopMonitor()
    {
        if (Interlocked.CompareExchange(ref _monitorStarted, 2, 1) != 1) return;
        Interlocked.Increment(ref _epoch);
        NetworkChange.NetworkAddressChanged -= NetworkAddressChanged;
        _refresh.Stop();
        _refresh.Tick -= RefreshMonitor;
        _monitorEngine.Stop(DateTimeOffset.Now);
        _monitorStop.Cancel();
        PersistEvent("监测已停止。");
    }

    private void NetworkAddressChanged(object? sender, EventArgs e) =>
        Interlocked.Exchange(ref _networkChangePending, 1);

    private async void RefreshMonitor(object? sender, EventArgs e)
    {
        RenderChannels();
        if (Paused || Demo || Busy || Volatile.Read(ref _monitorStarted) != 1 ||
            Interlocked.Exchange(ref _networkChangePending, 0) == 0) return;
        await SampleLocalAsync();
    }

    private async Task PollAsync(MonitorChannelDefinition channel, Func<Task> sample)
    {
        using var timer = new PeriodicTimer(channel.Interval);
        try
        {
            while (await timer.WaitForNextTickAsync(_monitorStop.Token))
                await sample();
        }
        catch (OperationCanceledException) when (_monitorStop.IsCancellationRequested) { }
    }

    private bool CanPublish(int epoch) => Volatile.Read(ref _monitorStarted) == 1 &&
        SampleGate.Accept(epoch, Volatile.Read(ref _epoch), Paused, Demo);

    private async Task SampleLocalAsync() =>
        await SampleAsync(MonitorEngine.LocalChannelId, async (epoch, watch) =>
        {
            var report = await Task.Run(() => DiagnosticEngine.ReadLocal(persistEvent: false), _monitorStop.Token);
            if (!CanPublish(epoch)) return;
            Apply(report, replaceRemote: false);
            NoteLocal(report, watch.Elapsed);
        });

    private async Task SampleHttpsAsync() =>
        await SampleAsync(MonitorEngine.UpstreamChannelId, async (epoch, watch) =>
        {
            var check = await CheckRunner.RunOne("https", _monitorStop.Token);
            if (CanPublish(epoch)) NoteHttps(check, watch.Elapsed);
        });

    private async Task SampleAsync(string channel, Func<int, Stopwatch, Task> sample)
    {
        var epoch = Volatile.Read(ref _epoch);
        if (!CanPublish(epoch) || Interlocked.Exchange(ref _busyGate, 1) == 1) return;
        var watch = Stopwatch.StartNew();
        try { await sample(epoch, watch); }
        catch (OperationCanceledException) when (_monitorStop.IsCancellationRequested) { }
        catch (Exception ex)
        {
            if (CanPublish(epoch))
                Record(channel, new MonitorSample(EvidenceState.Fault, "采样失败", ex.GetType().Name, watch.Elapsed), DateTimeOffset.Now);
        }
        finally { Interlocked.Exchange(ref _busyGate, 0); }
    }

    [RelayCommand]
    private void Show(string section) => Section = section;

    [RelayCommand]
    private void TogglePause() => Paused = !Paused;

    [RelayCommand]
    private void RefreshEvents() => Events = FormatEvents(EventLog.Recent());

    [RelayCommand]
    private async Task DiagnoseAsync()
    {
        if (Busy || Interlocked.Exchange(ref _busyGate, 1) == 1) return;
        Busy = true;
        Status = "正在读取";
        var seen = Volatile.Read(ref _epoch);
        var demo = Demo;
        try
        {
            var watch = Stopwatch.StartNew();
            var report = demo ? DiagnosticEngine.Demo() : await Task.Run(() => DiagnosticEngine.ReadLocal(), _monitorStop.Token);
            var localLatency = watch.Elapsed;
            var checks = demo ? Array.Empty<CheckResult>() :
                await Task.Run(() => CheckRunner.RunAll(_monitorStop.Token), _monitorStop.Token);
            if (!SampleGate.Accept(seen, Volatile.Read(ref _epoch), false, false) || Demo != demo) return;
            Apply(report, replaceRemote: true);
            ReplaceChecks(checks);
            if (!Demo)
            {
                Probes = string.Join("\n", checks.Where(item => item.Id is "https" or "claude-status" or "dns" or "doh")
                    .Select(item => item.Name + "  " + item.Detail));
                Capabilities = string.Join("\n", checks.Select(item => item.State + "  " + item.Name + "：" + item.Detail));
                var https = checks.FirstOrDefault(item => item.Id == "https");
                if (https is not null && https.Elapsed is { } elapsed) NoteHttps(https, elapsed);
                NoteLocal(report, localLatency);
                Record(MonitorEngine.ProtocolChannelId, new MonitorSample(EvidenceState.Partial,
                    "协议样本请逐项查看。", null, watch.Elapsed - localLatency), DateTimeOffset.Now);
            }
        }
        catch (Exception ex)
        {
            Status = "读取失败";
            Summary = ex.GetType().Name;
            Advice = "这次读取没有完成。系统设置没有被修改。";
        }
        finally
        {
            Busy = false;
            Interlocked.Exchange(ref _busyGate, 0);
        }
    }

    [RelayCommand]
    private void PreviewRecovery()
    {
        var process = !Demo && _latestLocal?.Observation.CoreRunning == true;
        var port = !Demo && _latestLocal?.Observation.MixedPortOpen == true;
        RecoveryLog = IsolatedRecovery.Preview(
            Enum.TryParse<FaultClass>(Status, out var fault) ? fault : FaultClass.Unknown,
            IntentStore.Read() == true, process, port, null);
        Section = "recovery";
    }

    [RelayCommand]
    private async Task RunIsolatedRecoveryAsync()
    {
        if (Demo || Busy || Interlocked.Exchange(ref _busyGate, 1) == 1) return;
        Busy = true;
        Interlocked.Increment(ref _epoch);
        Section = "recovery";
        RecoveryLog = "正在临时目录里运行 rollback-v4.ps1。当前 Windows 代理不会被写入。";
        try
        {
            var run = await IsolatedRecovery.ExecuteAsync(IsolatedRecovery.AuthorizationText, _monitorStop.Token);
            RecoveryLog = FormatRun(run);
            EventLog.Append(run.ScriptStarted
                ? "隔离回滚退出 " + run.TransactionExit + "。当前 Windows 代理" + (run.LiveUnchanged ? "未变" : "指纹发生变化") + "。"
                : "恢复没有启动。");
            Events = string.Join("\n", EventLog.Recent());
        }
        catch (Exception ex)
        {
            RecoveryLog = "隔离恢复没有完成：" + ex.GetType().Name + "。";
        }
        finally
        {
            Busy = false;
            Interlocked.Exchange(ref _busyGate, 0);
        }
    }

    [RelayCommand]
    private async Task RecheckAsync(string id)
    {
        if (Demo || Busy || string.IsNullOrWhiteSpace(id)) return;
        if (Interlocked.Exchange(ref _busyGate, 1) == 1) return;
        Busy = true;
        var epoch = Volatile.Read(ref _epoch);
        var watch = Stopwatch.StartNew();
        try
        {
            var result = await Task.Run(() => CheckRunner.RunOne(id, _monitorStop.Token), _monitorStop.Token);
            if (!SampleGate.Accept(epoch, Volatile.Read(ref _epoch), false, Demo)) return;
            var row = new CheckRow(result.Id, result.Name, result.State.ToString(), result.State + "  " + result.SampledAt.ToString("HH:mm:ss"), result.Method + " " + result.Detail, result.Purpose);
            var index = Checks.ToList().FindIndex(item => item.Id == id);
            if (index >= 0) Checks[index] = row;
            else Checks.Add(row);
            if (id == "selection")
                Proxy = result.State + "  " + result.SampledAt.ToString("HH:mm:ss") + "  " + result.Detail;
            if (id == "listeners")
                Listeners = result.State + "  " + result.SampledAt.ToString("HH:mm:ss") + "  " + result.Detail;
            if (id == "https") NoteHttps(result, result.Elapsed ?? watch.Elapsed);
            if (id is "ipv4" or "ipv6" or "udp" or "dns" or "doh" or "webrtc")
                Record(MonitorEngine.ProtocolChannelId,
                    new MonitorSample(result.State, result.Name + "。逐项证据见检查页。", null, watch.Elapsed), result.SampledAt);
            PersistEvent("重测 " + result.Name + " " + result.State + "。");
            RenderClientLine();
        }
        catch (OperationCanceledException) when (_monitorStop.IsCancellationRequested) { }
        catch (Exception ex) { PersistEvent("检查失败 " + ex.GetType().Name + "。"); }
        finally
        {
            Busy = false;
            Interlocked.Exchange(ref _busyGate, 0);
        }
    }

    [RelayCommand]
    private async Task RecordOffAsync()
    {
        if (Demo) return;
        IntentStore.Write(true);
        EventLog.Append("用户在本程序里记录了关闭代理的意图。没有改 Windows 代理。");
        await DiagnoseAsync();
    }

    [RelayCommand]
    private async Task ClearIntentAsync()
    {
        if (Demo) return;
        IntentStore.Clear();
        EventLog.Append("用户清除了本程序里的关闭记录。没有改 Windows 代理。");
        await DiagnoseAsync();
    }

    private void Apply(DiagnosticReport report, bool replaceRemote)
    {
        _latestLocal = report.Demo ? null : report;
        Sampled = true;
        Status = report.Fault.Class.ToString();
        Advice = report.Fault.Advice;
        Summary = report.Demo
            ? "下面的卡片是固定演示数据。"
            : $"采样时间 {report.SampledAt:HH:mm:ss}。分类只说明本地监听和系统选择，不证明上游或应用路径。";
        Proxy = report.ProxySelection + (report.AutomaticProxySet ? "，自动配置已设置" : "，未发现自动配置脚本");
        Clients = report.RunningClients.Count == 0 ? "没有发现 StarSky 或 Clash 进程" : string.Join("、", report.RunningClients);
        Listeners = report.Listeners.Count == 0
            ? "没有发现代理回环监听"
            : string.Join("；", report.Listeners.Select(item => $"{item.Port} {item.ProcessName}"));
        if (!replaceRemote)
        {
            RenderClientLine();
            return;
        }
        Probes = string.Join("\n", report.Probes.Select(item =>
            item.StatusCode is null
                ? $"{item.Target}  {item.PathLabel}  {item.Error ?? "无状态码"}"
                : $"{item.Target}  HTTP {item.StatusCode}  {item.ElapsedMs} ms  {item.PathLabel}"));
        Capabilities = string.Join("\n", report.Capabilities.Select(item => $"{item.State}  {item.Name}：{item.Detail}"));
        Events = FormatEvents(report.Events);
        RenderClientLine();
    }

    private void ReplaceChecks(IReadOnlyList<CheckResult> checks)
    {
        Checks.Clear();
        foreach (var item in checks)
            Checks.Add(new CheckRow(item.Id, item.Name, item.State.ToString(), item.State + "  " + item.SampledAt.ToString("HH:mm:ss"), item.Method + " " + item.Detail, item.Purpose));
    }

    private void NoteLocal(DiagnosticReport report, TimeSpan elapsed)
    {
        var fault = report.Fault.Class;
        var failure = fault is FaultClass.ProxyDrift or FaultClass.CoreDown or FaultClass.FirstHopDown or FaultClass.Unknown;
        var state = fault switch
        {
            FaultClass.ProxyDrift or FaultClass.CoreDown or FaultClass.FirstHopDown => EvidenceState.Fault,
            FaultClass.Unknown => EvidenceState.Unknown,
            _ => EvidenceState.Partial
        };
        Record(MonitorEngine.LocalChannelId, new MonitorSample(state, fault.ToString(),
            failure ? fault.ToString() : null, elapsed), report.SampledAt);
    }

    private void NoteHttps(CheckResult result, TimeSpan elapsed) =>
        Record(MonitorEngine.UpstreamChannelId, new MonitorSample(result.State, result.Detail,
            result.State == EvidenceState.Verified ? null : "HTTPS " + result.State, elapsed), result.SampledAt);

    private void Record(string channel, MonitorSample sample, DateTimeOffset at)
    {
        var outcome = _monitorEngine.Record(channel, sample, at);
        RenderChannels();
        if (!outcome.Notify) return;
        var name = _monitorEngine.Read(channel, at).Name;
        var message = outcome.Transition == MonitorTransition.Recovered
            ? name + " 已收到新的采样。请核对具体应用。"
            : name + " 出现异常 " + sample.Failure + "。";
        Monitor = message;
        PersistEvent(message);
        AlertRequested?.Invoke(message);
    }

    private void PersistEvent(string message)
    {
        if (Demo) return;
        try
        {
            EventLog.Append(message);
            Events = FormatEvents(EventLog.Recent());
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException or TimeoutException)
        {
            Events = "本机事件记录不可用 " + ex.GetType().Name + "。";
        }
    }

    private void RenderChannels()
    {
        var snapshot = _monitorEngine.Snapshot(DateTimeOffset.Now);
        string Line(MonitorChannelSnapshot sample) => sample.SampledAt is not { } at
            ? sample.Name + "  尚无采样"
            : $"{sample.Name}  {(sample.Expired ? "已过期" : sample.DisplayState.ToString())}  {at:HH:mm:ss}  "
              + $"{sample.Latency?.TotalMilliseconds:0} ms  有效 {sample.Ttl.TotalSeconds:0} 秒  "
              + (sample.Expired ? "等待新的采样。" : sample.Evidence)
              + $"  连续失败 {sample.ConsecutiveFailures}  状态变化 {sample.Flaps}";
        Channels = string.Join("\n", snapshot.Channels.Select(Line));
        UpstreamLine = Line(snapshot.Channels.Single(item => item.Id == MonitorEngine.UpstreamChannelId));
        RenderClientLine();
    }

    private void RenderClientLine()
    {
        if (Demo)
        {
            ClientLine = "演示数据不判断这台电脑的客户端。进程和端口来自固定样例。";
            return;
        }
        if (_latestLocal is not { } report ||
            DateTimeOffset.Now - report.SampledAt > MonitorEngine.LocalHeartbeat.Ttl)
        {
            ClientLine = "还没有采样。只读检查之后才会比较进程、监听和上游。";
            return;
        }
        var observation = report.Observation;
        var hopRunning = report.RunningClients.Any(item => item is "StarSky" or "magicspeed");
        var userOff = observation.UserTurnedProxyOff == true;
        string Describe(string name, bool running, bool? listening) =>
            listening is null && !userOff
                ? name + " 监听证据不完整。"
                : name + " " + ClientLifecycle.Classify(running, listening == true, null, null, userOff).State;
        ClientLine = Describe("StarSky", hopRunning, observation.FirstHopOpen) + "\n"
            + Describe("Clash 核心", observation.CoreRunning == true, observation.MixedPortOpen) + "\n"
            + "默认路径 HTTPS 单独显示。要恢复加速，请先在客户端界面确认状态，随后重新检查真实应用路径。";
    }

    private static string FormatEvents(IEnumerable<string> lines)
    {
        var formatted = new List<string>();
        foreach (var line in lines)
        {
            var text = FormatEventLine(line);
            if (text.Length > 0) formatted.Add(text);
        }
        return formatted.Count == 0 ? "还没有写入本机会话记录。" : string.Join("\n", formatted);
    }

    private static string FormatEventLine(string line)
    {
        var text = line.Trim();
        if (text.Length == 0) return "";
        if (!text.StartsWith('{')) return text;
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("message", out var messageValue) ||
                messageValue.ValueKind != JsonValueKind.String) return "";
            var message = messageValue.GetString();
            if (string.IsNullOrWhiteSpace(message)) return "";
            if (root.TryGetProperty("at", out var atValue)
                && atValue.ValueKind == JsonValueKind.String
                && DateTimeOffset.TryParse(atValue.GetString(), out var when))
                return when.ToLocalTime().ToString("HH:mm:ss") + "  " + message;
            return message;
        }
        catch (JsonException)
        {
            return "";
        }
    }

    private static string FormatRun(RecoveryResult run)
    {
        if (!run.ScriptStarted) return run.Detail;
        return string.Join(Environment.NewLine,
        [
            run.CompleteSuccess ? "隔离事务证据齐全。" : "证据不齐全，不能记成恢复成功。",
            run.Isolation,
            "事务退出码 " + run.TransactionExit + "，预期 " + run.ExpectedTransactionExit + "。进程退出码 " + run.ProcessExit + "。",
            run.LiveUnchanged ? "开始和结束时，当前用户的 ProxyEnable 和 ProxyServer 相同。" : "开始和结束时，当前用户的代理指纹不同。",
            run.EvidenceScope,
            run.ProfileRestored ? "隔离配置文件已按快照哈希恢复。" : "隔离配置文件没有恢复到快照哈希。",
            run.JournalClear ? "事务日志已清除。" : "事务日志还在或没有读到这项证据。",
            run.WritesMatch ? "隔离写入符合这次场景。" : "隔离写入不符合这次场景。",
            "隔离写入：" + (string.IsNullOrWhiteSpace(run.Writes) ? "没有" : run.Writes.Trim()),
            (run.Cancelled ? "执行被取消。" : "") + (run.TimedOut ? "执行超时。" : ""),
            "脚本尾部：" + run.Detail,
            IsolatedRecovery.ManualGuidance
        ]);
    }
}

public sealed record CheckRow(string Id, string Name, string Evidence, string State, string Detail, string Purpose);
