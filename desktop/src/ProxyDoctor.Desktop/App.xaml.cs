using System.Windows;
using System.Windows.Forms;

namespace ProxyDoctor.Desktop;

public partial class App : System.Windows.Application
{
    private NotifyIcon? _tray;

    public static string? CapturePath { get; private set; }

    private void OnStartup(object sender, StartupEventArgs e)
    {
        for (var i = 0; i < e.Args.Length - 1; i++)
        {
            if (e.Args[i] == "--capture") CapturePath = e.Args[i + 1];
        }
        var window = new MainWindow();
        MainWindow = window;
        if (window.DataContext is ShellViewModel shell)
            shell.AlertRequested += message => _tray?.ShowBalloonTip(4000, "网络代理医生", message, ToolTipIcon.Warning);
        window.Show();
        _tray = new NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Shield,
            Visible = true,
            Text = "网络代理医生"
        };
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开", null, (_, _) => ShowMain());
        menu.Items.Add("只读诊断", null, async (_, _) =>
        {
            ShowMain();
            if (window.DataContext is ShellViewModel model)
                await model.DiagnoseCommand.ExecuteAsync(null);
        });
        menu.Items.Add("退出", null, (_, _) => Shutdown());
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => ShowMain();
        window.Closed += (_, _) => Shutdown();
    }

    private void ShowMain()
    {
        if (MainWindow is null) return;
        MainWindow.Show();
        MainWindow.WindowState = WindowState.Normal;
        MainWindow.Activate();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        base.OnExit(e);
    }
}
