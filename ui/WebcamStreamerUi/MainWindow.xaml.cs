using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace WebcamStreamerUi;

// The WPF main window. After the Slice D refactor it does NOT own the
// supervisor or the IPC connection -- App.OnStartup() does. The window is
// a view that App shows on demand (tray menu "Advanced Settings..."), and
// closing it hides instead of exits the process.
public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;
    private readonly IpcClient?    _ipc;
    private DispatcherTimer?       _pollTimer;
    // Suppresses Settings_Changed_Inline re-entry while we initialise the
    // three checkboxes from disk on window load.
    private bool                   _settingsLoading;

    public MainWindow()
    {
        InitializeComponent();
        // Share App's ViewModel + IpcClient so the tray and the window
        // see the same rows.
        _vm  = (Application.Current as App)?.Vm ?? new MainViewModel();
        _ipc = (Application.Current as App)?.Ipc;
        DataContext = _vm;
        Loaded  += MainWindow_Loaded;
        Closing += MainWindow_Closing;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        // Populate the inline Settings section checkboxes from the host
        // settings before the IPC refresh kicks off; the boxes' Checked /
        // Unchecked handlers persist edits live, so we suppress those
        // during the initial set.
        LoadSettingsIntoCheckboxes();

        if (_ipc == null) return;
        // Initial pull (in case the user opens the window before the App's
        // first refresh propagated to all bindings).
        await RefreshAsync();
        // Safety-net poll: live IPC events drive every UI update during
        // normal operation, but a missed event (pump glitch, supervisor
        // restart, etc.) would leave the grid stale. A quiet 5s sweep
        // backstops that without the user needing a Refresh button.
        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _pollTimer.Tick += async (_, __) => await RefreshAsync();
        _pollTimer.Start();
    }

    private void LoadSettingsIntoCheckboxes()
    {
        _settingsLoading = true;
        try
        {
            var s = App.Instance?.Settings ?? new HostSettings();
            OptNotifications.IsChecked   = s.NotificationsEnabled;
            OptAutostart.IsChecked       = AutostartHelper.IsEnabled();
            OptStreamByDefault.IsChecked = s.DefaultEnabledForNewCameras;
        }
        finally { _settingsLoading = false; }
    }

    private async void Settings_Changed_Inline(object sender, RoutedEventArgs e)
    {
        // Mirrors the (retired) standalone SettingsWindow logic: each
        // checkbox click live-applies. Notifications + default-enabled go
        // through settings.json + a reload-settings IPC; autostart writes
        // a HKCU\...\Run entry pointing at the current host exe.
        if (_settingsLoading) return;
        var app = App.Instance;
        if (app == null) return;
        try
        {
            bool notifications = OptNotifications.IsChecked   == true;
            bool autostart     = OptAutostart.IsChecked       == true;
            bool defaultEnable = OptStreamByDefault.IsChecked == true;

            if (app.Settings.NotificationsEnabled        != notifications ||
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
                // The tray's Notifications menu item also tracks this
                // flag; keep them in sync without having to round-trip
                // through the dialog.
                App.Instance?.SyncTrayNotificationToggle(notifications);
            }

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
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Could not save settings:\n" + ex.Message,
                "Webcam Streamer", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task RefreshAsync()
    {
        if (_ipc == null) return;
        try
        {
            var resp = await _ipc.CallAsync("get-status");
            if (resp.TryGetProperty("ok", out var ok) && ok.GetBoolean() &&
                resp.TryGetProperty("result", out var result))
            {
                if (result.TryGetProperty("cameras", out var cams))
                    _vm.ApplyCameraList(cams);
                if (result.TryGetProperty("mediamtx", out var mtx))
                    _vm.ApplyMediaMtx(mtx);
            }
        }
        catch (Exception ex)
        {
            _vm.ConnectionStatus = "refresh failed: " + ex.Message;
            _vm.ConnectionError  = true;
        }
    }

    private void About_Click(object sender, RoutedEventArgs e)
    {
        // Delegate to the host so the About dialog is owned by the same
        // single-instance App that owns the tray icon. Mirror of the
        // tray's "About..." menu item.
        App.Instance?.ShowAboutWindow();
    }

    private async void Restart_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: CameraInfo cam } || _ipc == null) return;
        try
        {
            await _ipc.CallAsync("restart-camera", new { name = cam.Name });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "restart-camera failed:\n" + ex.Message,
                            "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void ApplyCredentials_Click(object sender, RoutedEventArgs e)
    {
        if (_ipc == null) return;
        var user = _vm.ViewerUser?.Trim() ?? "";
        var pass = _vm.ViewerPassword ?? "";
        if (string.IsNullOrEmpty(user) || string.IsNullOrEmpty(pass))
        {
            MessageBox.Show(this,
                "Username and password must both be non-empty.",
                "Webcam Streamer", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        try
        {
            // set-viewer-credentials restarts mediamtx server-side, which
            // briefly kicks any connected viewer. The subsequent
            // cameras-changed event re-pushes every row (with the new
            // creds baked into FullUrl).
            await _ipc.CallAsync("set-viewer-credentials",
                                 new { user, pass },
                                 timeoutMs: 15000);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                "Could not apply new credentials:\n" + ex.Message,
                "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
            await RefreshAsync();
        }
    }

    private void CopyUrl_Click(object sender, RoutedEventArgs e)
    {
        // One-click copy of the per-row RTSP URL. Clipboard.SetText can
        // occasionally throw under heavy clipboard contention (another app
        // holding it open); catch + show a small message rather than
        // crashing the host.
        if (sender is not Button { Tag: CameraInfo cam }) return;
        try
        {
            // Fully qualified: this project enables UseWindowsForms (for
            // NotifyIcon), so `Clipboard` is ambiguous with
            // System.Windows.Forms.Clipboard. We want the WPF one.
            System.Windows.Clipboard.SetText(cam.FullUrl);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Could not copy URL:\n" + ex.Message,
                            "Clipboard error", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async void EnableToggle_Click(object sender, RoutedEventArgs e)
    {
        // One button that flips between Deactivate (when enabled) and
        // Activate (when disabled). Backed by set-stream-enabled on the
        // supervisor, which kills the publisher when disabling and rebuilds
        // it from a fresh SupervisedProcess when enabling. The button's
        // label is driven by the bound CameraInfo.Enabled via a style
        // trigger in MainWindow.xaml -- no manual swap needed here.
        if (sender is not Button { Tag: CameraInfo cam } || _ipc == null) return;
        bool wanted = !cam.Enabled;
        try
        {
            await _ipc.CallAsync("set-stream-enabled",
                                  new { name = cam.Name, enabled = wanted });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this,
                $"could not {(wanted ? "activate" : "deactivate")} {cam.Name}:\n{ex.Message}",
                "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
            await RefreshAsync();
        }
    }

    private async void ResolutionCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox { Tag: CameraInfo cam } || _ipc == null) return;
        if (e.AddedItems.Count == 0) return;
        var picked = e.AddedItems[0] as string;
        if (string.IsNullOrEmpty(picked)) return;
        if (picked == cam.Resolution) return;

        var parts = picked.Split('x');
        if (parts.Length != 2 ||
            !int.TryParse(parts[0], out int w) ||
            !int.TryParse(parts[1], out int h)) return;

        try
        {
            await _ipc.CallAsync("set-mode",
                new { name = cam.Name, mode = cam.Mode, width = w, height = h });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "set-mode (resolution) failed:\n" + ex.Message,
                            "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
            await RefreshAsync();
        }
    }

    private async void ModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox { Tag: CameraInfo cam } cb) return;
        if (_ipc == null) return;
        if (e.AddedItems.Count == 0) return;
        // The combo now binds to ModeOption records (Display + Value); the
        // wire payload still uses the Value side, so the supervisor's
        // set-mode handler doesn't need to change.
        var picked = (e.AddedItems[0] as ModeOption)?.Value;
        if (string.IsNullOrEmpty(picked)) return;
        if (picked == cam.Mode) return;

        try
        {
            await _ipc.CallAsync("set-mode", new { name = cam.Name, mode = picked });
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "set-mode failed:\n" + ex.Message,
                            "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
            await RefreshAsync();
        }
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // Close-to-tray: hide instead of dispose. App owns the lifetime.
        _pollTimer?.Stop();
        _pollTimer = null;
        if (Application.Current.ShutdownMode != ShutdownMode.OnExplicitShutdown) return;
        e.Cancel = true;
        Hide();
    }
}
