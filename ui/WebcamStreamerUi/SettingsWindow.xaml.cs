using System.Diagnostics;
using System.Windows;

namespace WebcamStreamerUi;

public partial class SettingsWindow : Window
{
    private bool _suspendApply;       // prevents Settings_Changed re-entry during init

    public SettingsWindow()
    {
        InitializeComponent();
        Loaded += (_, _) => LoadCurrent();
    }

    private void LoadCurrent()
    {
        _suspendApply = true;
        try
        {
            var settings = App.Instance?.Settings ?? new HostSettings();
            NotificationsBox.IsChecked    = settings.NotificationsEnabled;
            DefaultEnabledBox.IsChecked   = settings.DefaultEnabledForNewCameras;
            AutostartBox.IsChecked        = AutostartHelper.IsEnabled();
        }
        finally { _suspendApply = false; }
    }

    private async void Settings_Changed(object sender, RoutedEventArgs e)
    {
        if (_suspendApply) return;
        var app = App.Instance;
        if (app == null) return;
        try
        {
            // Apply each toggle. The host's tray icon mirrors NotificationsEnabled.
            bool notifications = NotificationsBox.IsChecked == true;
            bool defaultEnable = DefaultEnabledBox.IsChecked == true;
            bool autostart     = AutostartBox.IsChecked == true;

            if (app.Settings.NotificationsEnabled != notifications ||
                app.Settings.DefaultEnabledForNewCameras != defaultEnable)
            {
                app.Settings.NotificationsEnabled        = notifications;
                app.Settings.DefaultEnabledForNewCameras = defaultEnable;
                app.Settings.Save();
                if (app.Ipc != null)
                {
                    try { await app.Ipc.CallAsync("reload-settings"); }
                    catch (Exception ex) { Debug.WriteLine("reload-settings: " + ex.Message); }
                }
            }

            // Autostart: write/remove the HKCU\...\Run entry. We point it at
            // the host exe (the current process). Path is captured at the
            // moment the user ticks the box; if the exe moves, the user
            // will need to retick.
            if (autostart != AutostartHelper.IsEnabled())
            {
                if (autostart)
                {
                    var exe = Process.GetCurrentProcess().MainModule?.FileName
                              ?? AppContext.BaseDirectory;
                    AutostartHelper.Enable(exe);
                }
                else
                {
                    AutostartHelper.Disable();
                }
            }
            StatusText.Text = "Settings applied.";
        }
        catch (Exception ex)
        {
            StatusText.Text = "Settings save failed: " + ex.Message;
        }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
