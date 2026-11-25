using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ProxyDoctor.Desktop;

public partial class MainWindow : Window
{
    private readonly ShellViewModel _model = new();

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _model;
        _model.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ShellViewModel.Dark))
                ApplyTheme(_model.Dark);
            if (args.PropertyName == nameof(ShellViewModel.Section))
                ShowSection(_model.Section);
        };
        Loaded += async (_, _) =>
        {
            _model.StartMonitor();
            Closed += (_, _) => _model.StopMonitor();
            await _model.DiagnoseCommand.ExecuteAsync(null);
            if (App.CapturePath is null) return;
            await Dispatcher.InvokeAsync(SaveCapture, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            System.Windows.Application.Current.Shutdown();
        };
    }

    private void ApplyTheme(bool dark)
    {
        var dictionaries = System.Windows.Application.Current.Resources.MergedDictionaries;
        dictionaries.Clear();
        dictionaries.Add(new ResourceDictionary
        {
            Source = new Uri(dark ? "Themes/Dark.xaml" : "Themes/Light.xaml", UriKind.Relative)
        });
    }

    private void ShowSection(string section)
    {
        OverviewPage.Visibility = section is "overview" or "monitor" ? Visibility.Visible : Visibility.Collapsed;
        PrivacyPage.Visibility = section == "privacy" ? Visibility.Visible : Visibility.Collapsed;
        RecoveryPage.Visibility = section == "recovery" ? Visibility.Visible : Visibility.Collapsed;
        EventsPage.Visibility = section == "events" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SaveCapture()
    {
        var path = App.CapturePath;
        if (string.IsNullOrWhiteSpace(path)) return;
        var width = Math.Max(1, (int)ActualWidth);
        var height = Math.Max(1, (int)ActualHeight);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}
