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
        var picked = e.AddedItems[0] as string;
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
