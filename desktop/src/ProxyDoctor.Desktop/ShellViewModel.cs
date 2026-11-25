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

    private readonly PeriodicTimer _timer = new(TimeSpan.FromSeconds(20));
    private readonly CancellationTokenSource _monitorStop = new();
    private int _busyGate;

    public string ModeLabel => Demo ? "演示数据，不是这台电脑的实时结果" : Paused ? "实时只读，监测已暂停" : "实时只读，每 20 秒采样";

    partial void OnDemoChanged(bool value)
    {
        Status = "模式已切换";
        Summary = value ? "演示数据，不是这台电脑的实时结果。上一次实时结果已清除。" : "已离开演示。上一次结果已清除。";
        Proxy = Clients = Listeners = Probes = Capabilities = Events = "—";
        Advice = "等待新的采样。";
        Sampled = false;
        OnPropertyChanged(nameof(ModeLabel));
    }

    partial void OnPausedChanged(bool value) => OnPropertyChanged(nameof(ModeLabel));

    public void StartMonitor()
    {
        Monitor = "监测运行中。本地状态每 20 秒读一次；外部 HTTPS 不在每次心跳里重复。";
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
                        var report = DiagnosticEngine.ReadLocal();
                        System.Windows.Application.Current?.Dispatcher.Invoke(() => Apply(report));
                    }
                    catch (OperationCanceledException) { break; }
                    catch { /* the next tick records a fresh sample */ }
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
    }

    [RelayCommand]
    private void Show(string section) => Section = section;

    [RelayCommand]
    private async Task DiagnoseAsync()
    {
        if (Busy || Interlocked.Exchange(ref _busyGate, 1) == 1) return;
        Busy = true;
        Status = "正在读取";
        try
        {
            var report = Demo
                ? DiagnosticEngine.Demo()
                : await DiagnosticEngine.ReadLiveAsync(CancellationToken.None);
            Apply(report);
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
    private void Rehearse()
    {
        Events = string.Join("\n", RecoveryDrill.Run());
        Section = "recovery";
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

    private void Apply(DiagnosticReport report)
    {
        Sampled = true;
        Status = report.Fault.Class.ToString();
        Advice = report.Fault.Advice;
        Summary = report.Demo
            ? "下面的卡片是固定演示数据。"
            : $"采样时间 {report.SampledAt:HH:mm:ss}。分类只说明本地监听和系统选择，不证明应用路径。";
        Proxy = report.ProxySelection + (report.AutomaticProxySet ? "，自动配置已设置" : "，未发现自动配置脚本");
        Clients = report.RunningClients.Count == 0 ? "没有发现 StarSky 或 Clash 进程" : string.Join("、", report.RunningClients);
        Listeners = report.Listeners.Count == 0
            ? "没有发现回环监听"
            : string.Join("；", report.Listeners.Select(item => $"{item.Port} {item.ProcessName}"));
        Probes = string.Join("\n", report.Probes.Select(item =>
            item.StatusCode is null
                ? $"{item.Target}  {item.PathLabel}  {item.Error ?? "无状态码"}"
                : $"{item.Target}  HTTP {item.StatusCode}  {item.ElapsedMs} ms  {item.PathLabel}"));
        Capabilities = string.Join("\n", report.Capabilities.Select(item => $"{item.State}  {item.Name}：{item.Detail}"));
        Events = string.Join("\n", report.Events);
    }
}
