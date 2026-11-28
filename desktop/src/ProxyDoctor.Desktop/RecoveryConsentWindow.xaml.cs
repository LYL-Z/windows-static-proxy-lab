using System.Windows;
using ProxyDoctor;

namespace ProxyDoctor.Desktop;

/// <summary>
/// F72: the only desktop place that can authorize an isolated exercise. It shows the
/// scope, affected resources, whether the system proxy is written and the rollback
/// method, and its confirm button is the grant. Closing or cancelling it grants nothing.
/// </summary>
public partial class RecoveryConsentWindow : Window
{
    public RecoveryConsentWindow(RecoveryConsentBrief brief)
    {
        InitializeComponent();
        DataContext = brief;
    }

    private void OnConfirm(object sender, RoutedEventArgs e) => DialogResult = true;
}
