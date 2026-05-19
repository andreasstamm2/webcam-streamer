using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Navigation;

namespace WebcamStreamerUi;

// Modal "About" dialog. Read-only. Reachable from the tray menu and from
// the MainWindow toolbar. All version info is read from assembly metadata
// at runtime so this dialog never drifts from the actual .csproj <Version>.
public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();
        VersionText.Text = "Version " + GetDisplayVersion();
    }

    // Prefer the InformationalVersion attribute (set from <Version> in the
    // csproj). Strip any "+commitsha" suffix MSBuild adds when SourceLink is
    // enabled. Fall back to the file version, then to "—" if nothing is set.
    private static string GetDisplayVersion()
    {
        var asm = Assembly.GetExecutingAssembly();
        var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(info))
        {
            int plus = info.IndexOf('+');
            return plus > 0 ? info.Substring(0, plus) : info;
        }
        var fv = asm.GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version;
        return string.IsNullOrWhiteSpace(fv) ? "—" : fv!;
    }

    // Hyperlinks in WPF do nothing on click unless we explicitly hand the
    // URI to the shell. UseShellExecute=true is required for non-file URIs
    // (http, mailto) on .NET Core / 5+.
    private void Hyperlink_RequestNavigate(object sender, RequestNavigateEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Could not open link:\n" + e.Uri + "\n\n" + ex.Message,
                "Webcam Streamer",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        e.Handled = true;
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
