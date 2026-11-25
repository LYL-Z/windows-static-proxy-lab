using System.Collections.ObjectModel;
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

    private readonly AlertGate _alerts = new();
    public ObservableCollection<CheckRow> Checks { get; } = new();
    public event Action<string>? AlertRequested;

    private readonly PeriodicTimer _timer = new(TimeSpan.FromSeconds(20));
    private readonly PeriodicTimer _upstreamTimer = new(TimeSpan.FromSeconds(90));
    private readonly CancellationTokenSource _monitorStop = new();
    private readonly FaultStreak _upstreamStreak = new();
    private ChannelSample? _localSample;
    private ChannelSample? _upstreamSample;
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
        Advice = "等待新的采样。";
        Sampled = false;
        OnPropertyChanged(nameof(ModeLabel));
    }

    partial void OnPausedChanged(bool value) => OnPropertyChanged(nameof(ModeLabel));

    public void StartMonitor()
    {
        Monitor = "监测运行中。本地状态每 20 秒读一次。上游 HTTPS 每 90 秒单独采样，失败会单独告警。";
        _ = Task.Run(async () =>
        {
            try
            {
                while (await _timer.WaitForNextTickAsync(_monitorStop.Token))
                {
                    if (Paused || Demo) continue;
                    if (Interlocked.Exchange(ref _busyGate, 1) == 1) continue;
                    try
                    {
                        var report = DiagnosticEngine.ReadLocal(persistEvent: false);
                        var key = report.Fault.Class + "|" + report.ProxySelection;
                        var notify = _alerts.ShouldNotify(key);
                        var seen = Volatile.Read(ref _epoch);
                        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                        {
                            if (!SampleGate.Accept(seen, Volatile.Read(ref _epoch), Paused, Demo)) return;
                            Apply(report, replaceRemote: false);
                            NoteLocal(report);
                            if (notify) AlertRequested?.Invoke("状态变为 " + report.Fault.Class + "。这是 20 秒轮询，不是瞬时发现。监听正常不等于上游可用。");
                        });
                    }
                    catch (OperationCanceledException) { break; }
                    catch (Exception ex)
                    {
                        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                        {
                            Monitor = "监测失败：" + ex.GetType().Name + "。上一次完整检查已保留，但不能当成当前正常。";
                            _localSample = FailedChannel("local", "本地心跳", TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(60), ex.GetType().Name);
                            RenderChannels();
                        });
                    }
                    finally { Interlocked.Exchange(ref _busyGate, 0); }
                }
            }
            catch (OperationCanceledException) { }
        });
        _ = Task.Run(async () =>
        {
            try
            {
                while (await _upstreamTimer.WaitForNextTickAsync(_monitorStop.Token))
                {
                    if (Paused || Demo) continue;
                    if (Interlocked.Exchange(ref _busyGate, 1) == 1) continue;
                    try
                    {
                        var started = DateTimeOffset.Now;
                        var check = await CheckRunner.RunOne("https", _monitorStop.Token);
                        var failed = check.State != EvidenceState.Verified;
                        var kind = _upstreamStreak.Observe(failed ? check.Detail : null);
                        var seen = Volatile.Read(ref _epoch);
                        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                        {
                            if (!SampleGate.Accept(seen, Volatile.Read(ref _epoch), Paused, Demo)) return;
                            _upstreamSample = new ChannelSample("upstream", "上游 HTTPS", check.SampledAt,
                                TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180), check.State,
                                check.Detail + "。采样耗时计入检查结果。", failed ? check.Detail : null);
                            UpstreamLine = check.State + "  " + check.SampledAt.ToString("HH:mm:ss") + "  " + check.Detail
                                + "。连续失败 " + _upstreamStreak.Consecutive + "，抖动 " + _upstreamStreak.Flaps + "，这次是 " + kind + "。";
                            RenderChannels();
                            if (failed && kind == "new")
                            {
                                Monitor = "上游通道失败。本地监听即使仍在，也不能显示成正常。相同失败不会每个周期重复通知。";
                                AlertRequested?.Invoke("上游 HTTPS 失败。这不是本地心跳。90 秒采样看不到更短的中断。");
                            }
                            else if (failed)
                            {
                                Monitor = "上游通道仍失败。这是重复失败，不再重复通知。本地监听不能显示成正常。";
                            }
                            else Monitor = "上游通道 " + check.SampledAt.ToString("HH:mm:ss") + " 有响应。一次响应不是应用已恢复。从发起到返回约 " + (DateTimeOffset.Now - started).TotalMilliseconds.ToString("0") + " ms。";
                        });
                    }
                    catch (OperationCanceledException) { break; }
                    catch (Exception ex)
                    {
                        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                        {
                            Monitor = "上游监测失败：" + ex.GetType().Name + "。不能把上一次成功当成当前正常。";
                            _upstreamSample = FailedChannel("upstream", "上游 HTTPS", TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180), ex.GetType().Name);
                            RenderChannels();
                        });
                    }
                    finally { Interlocked.Exchange(ref _busyGate, 0); }
                }
            }
            catch (OperationCanceledException) { }
        });
    }

    public void StopMonitor()
    {
        _monitorStop.Cancel();
        _timer.Dispose();
        _upstreamTimer.Dispose();
    }

    [RelayCommand]
    private void Show(string section) => Section = section;

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
            var report = demo ? DiagnosticEngine.Demo() : DiagnosticEngine.ReadLocal();
            var checks = demo ? Array.Empty<CheckResult>() : await CheckRunner.RunAll(CancellationToken.None);
            if (!SampleGate.Accept(seen, Volatile.Read(ref _epoch), false, false) || Demo != demo) return;
            Apply(report, replaceRemote: true);
            ReplaceChecks(checks);
            if (!Demo)
            {
                Probes = string.Join("\n", checks.Where(item => item.Id is "https" or "claude-status" or "dns" or "doh")
                    .Select(item => item.Name + "  " + item.Detail));
                Capabilities = string.Join("\n", checks.Select(item => item.State + "  " + item.Name + "：" + item.Detail));
                var https = checks.FirstOrDefault(item => item.Id == "https");
                if (https is not null)
                {
                    var failed = https.State != EvidenceState.Verified;
                    _upstreamStreak.Observe(failed ? https.Detail : null);
                    _upstreamSample = new ChannelSample("upstream", "上游 HTTPS", https.SampledAt, TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180), https.State, https.Detail, failed ? https.Detail : null);
                    UpstreamLine = https.State + "  " + https.SampledAt.ToString("HH:mm:ss") + "  " + https.Detail;
                }
                NoteLocal(report);
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
        var process = !Demo && Clients.Contains("StarSky", StringComparison.OrdinalIgnoreCase);
        var port = !Demo && Listeners.Contains("verge-mihomo", StringComparison.OrdinalIgnoreCase);
        bool? upstream = _upstreamSample is null ? null : _upstreamSample.State == EvidenceState.Verified;
        RecoveryLog = IsolatedRecovery.Preview(
            Enum.TryParse<FaultClass>(Status, out var fault) ? fault : FaultClass.Unknown,
            IntentStore.Read() == true, process, port, upstream);
        Section = "recovery";
    }

    [RelayCommand]
    private async Task RunIsolatedRecoveryAsync()
    {
        if (Busy || Interlocked.Exchange(ref _busyGate, 1) == 1) return;
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
        try
        {
            var result = await CheckRunner.RunOne(id, CancellationToken.None);
            var row = new CheckRow(result.Id, result.Name, result.State + "  " + result.SampledAt.ToString("HH:mm:ss"), result.Method + " " + result.Detail);
            var index = Checks.ToList().FindIndex(item => item.Id == id);
            if (index >= 0) Checks[index] = row;
            else Checks.Add(row);
            if (id == "https")
            {
                UpstreamLine = result.State + "  " + result.SampledAt.ToString("HH:mm:ss") + "  " + result.Detail;
                _upstreamSample = new ChannelSample("upstream", "上游 HTTPS", result.SampledAt, TimeSpan.FromSeconds(90), TimeSpan.FromSeconds(180), result.State, result.Detail, result.State == EvidenceState.Verified ? null : result.Detail);
                RenderChannels();
            }
            EventLog.Append("重测 " + result.Name + "：" + result.State + "。");
        }
        finally
        {
            Busy = false;
            Interlocked.Exchange(ref _busyGate, 0);
        }
    }

    [RelayCommand]
    private async Task RecordOffAsync()
    {
        IntentStore.Write(true);
        EventLog.Append("用户在本程序里记录了关闭代理的意图。没有改 Windows 代理。");
        await DiagnoseAsync();
    }

    [RelayCommand]
    private async Task ClearIntentAsync()
    {
        IntentStore.Clear();
        EventLog.Append("用户清除了本程序里的关闭记录。没有改 Windows 代理。");
        await DiagnoseAsync();
    }

    private void Apply(DiagnosticReport report, bool replaceRemote)
    {
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
        if (!replaceRemote) return;
        Probes = string.Join("\n", report.Probes.Select(item =>
            item.StatusCode is null
                ? $"{item.Target}  {item.PathLabel}  {item.Error ?? "无状态码"}"
                : $"{item.Target}  HTTP {item.StatusCode}  {item.ElapsedMs} ms  {item.PathLabel}"));
        Capabilities = string.Join("\n", report.Capabilities.Select(item => $"{item.State}  {item.Name}：{item.Detail}"));
        Events = string.Join("\n", report.Events);
    }

    private void ReplaceChecks(IReadOnlyList<CheckResult> checks)
    {
        Checks.Clear();
        foreach (var item in checks)
            Checks.Add(new CheckRow(item.Id, item.Name, item.State + "  " + item.SampledAt.ToString("HH:mm:ss"), item.Method + " " + item.Detail));
    }

    private void NoteLocal(DiagnosticReport report)
    {
        var failed = report.Capabilities.Any(item => item.Name == "本地心跳" && item.State == EvidenceState.Unknown);
        _localSample = new ChannelSample("local", "本地心跳", report.SampledAt, TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(60),
            failed ? EvidenceState.Unknown : EvidenceState.Partial,
            report.Fault.Class + " " + report.ProxySelection, failed ? "监听读取不完整" : null);
        RenderChannels();
    }

    private static ChannelSample FailedChannel(string id, string name, TimeSpan interval, TimeSpan ttl, string failure) =>
        new(id, name, DateTimeOffset.Now, interval, ttl, EvidenceState.Fault, failure, failure);

    private void RenderChannels()
    {
        var now = DateTimeOffset.Now;
        string Line(ChannelSample? sample) => sample is null
            ? "尚无采样"
            : sample.Display(now, false) + "  " + sample.SampledAt.ToString("HH:mm:ss")
              + "  间隔 " + sample.Interval.TotalSeconds.ToString("0") + " 秒，有效 "
              + sample.Ttl.TotalSeconds.ToString("0") + " 秒。 " + sample.Evidence;
        Channels = "本地心跳  " + Line(_localSample) + "\n上游 HTTPS  " + Line(_upstreamSample)
            + "\n协议检查只在人工点击时采样，不借用本地心跳的时间。";
    }

    private static string FormatRun(RecoveryResult run)
    {
        if (!run.ScriptStarted) return run.Detail;
        return string.Join(Environment.NewLine,
        [
            run.CompleteSuccess ? "隔离事务证据齐全。" : "证据不齐全，不能记成恢复成功。",
            run.Isolation,
            "事务退出码 " + run.TransactionExit + "，预期 " + run.ExpectedTransactionExit + "。进程退出码 " + run.ProcessExit + "。",
            run.LiveUnchanged ? "执行前后，当前用户的 ProxyEnable 和 ProxyServer 相同。" : "执行前后，当前用户的代理指纹不同。",
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

public sealed record CheckRow(string Id, string Name, string State, string Detail);
