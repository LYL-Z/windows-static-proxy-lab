using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Data;
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
        };
        Loaded += async (_, _) =>
        {
            _model.StartMonitor();
            Closed += (_, _) => _model.StopMonitor();
            await _model.DiagnoseCommand.ExecuteAsync(null);
            if (App.Recover)
                await _model.RunIsolatedRecoveryCommand.ExecuteAsync(null);
            if (App.Section is not null)
                _model.Section = App.Section;
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

    private void SaveCapture()
    {
        var path = App.CapturePath;
        if (string.IsNullOrWhiteSpace(path)) return;
        var width = Math.Max(1, (int)ActualWidth);
        var height = Math.Max(1, (int)ActualHeight);
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = File.Create(path);
        encoder.Save(stream);
    }
}

public sealed class SectionVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        string.Equals(value as string, parameter as string, StringComparison.Ordinal)
            ? Visibility.Visible
            : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class SectionTitleConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "overview" => "概览",
            "checks" => "检查",
            "monitor" => "监测",
            "privacy" => "隐私",
            "clients" => "客户端",
            "recovery" => "恢复",
            "events" => "事件",
            "guide" => "开始使用",
            _ => "概览"
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class SectionMatchConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        if (values.Length < 2) return false;
        return string.Equals(values[0]?.ToString(), values[1]?.ToString(), StringComparison.Ordinal);
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

public sealed class InverseBooleanConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is not true;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is not true;
}

public sealed class IdleLiveConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        var busy = values.Length > 0 && values[0] is true;
        var demo = values.Length > 1 && values[1] is true;
        return !busy && !demo;
    }

    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
