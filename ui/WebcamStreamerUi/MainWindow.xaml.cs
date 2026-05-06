using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace WebcamStreamerUi;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm = new();
    private SupervisorLauncher? _launcher;
    private IpcClient? _ipc;
    private DispatcherTimer? _pollTimer;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = _vm;
        Loaded   += MainWindow_Loaded;
        Closing  += MainWindow_Closing;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        var exePath = SupervisorLauncher.LocateSupervisorExe();
        if (exePath == null)
        {
            MessageBox.Show(this,
                "Could not find supervisor.exe. Build it via:\n\n" +
                "  cd supervisor && cmake --build build --config Release\n\n" +
                "Looked relative to: " + AppContext.BaseDirectory,
                "supervisor.exe missing",
                MessageBoxButton.OK, MessageBoxImage.Error);
            Application.Current.Shutdown(2);
            return;
        }

        _vm.ConnectionStatus = $"launching supervisor: {exePath}";

        _launcher = new SupervisorLauncher(exePath);
        _launcher.StdoutLine += (_, line) => Debug.WriteLine("[sup] " + line);
        _launcher.StderrLine += (_, line) => Debug.WriteLine("[sup-err] " + line);
        _launcher.Exited += (_, code) =>
            Dispatcher.BeginInvoke(() => _vm.ConnectionStatus = $"supervisor exited (code {code})");

        try
        {
            _launcher.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Failed to start supervisor:\n" + ex.Message,
                            "launch failed", MessageBoxButton.OK, MessageBoxImage.Error);
            Application.Current.Shutdown(3);
            return;
        }

        // Connect IPC. The supervisor takes a moment to set up the pipe;
        // ConnectAsync's timeout handles the small race.
        _ipc = new IpcClient();
        _ipc.EventReceived += OnIpcEvent;
        _ipc.Disconnected  += (_, why) =>
            Dispatcher.BeginInvoke(() => _vm.ConnectionStatus = "ipc disconnected: " + why);
        _ipc.PumpError     += (_, why) => Debug.WriteLine("[ipc] " + why);

        try
        {
            // Retry briefly, since the supervisor opens its pipe a beat after launch.
            for (int attempt = 0; attempt < 20; attempt++)
            {
                try { await _ipc.ConnectAsync(500); break; }
                catch (TimeoutException) when (attempt < 19) { await Task.Delay(250); }
            }
            _vm.ConnectionStatus = "ipc connected";
        }
        catch (Exception ex)
        {
            _vm.ConnectionStatus = "ipc connect failed: " + ex.Message;
            return;
        }

        await RefreshAsync();

        // Background poll every 2s so PID / restart counts stay live even if
        // we miss the (rare) state-changed events.
        _pollTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _pollTimer.Tick += async (_, __) => await RefreshAsync();
        _pollTimer.Start();
    }

    private void OnIpcEvent(object? sender, EventArrived ev)
    {
        Dispatcher.BeginInvoke(async () =>
        {
            switch (ev.Name)
            {
                case "camera-state-changed":
                    _vm.ApplyCameraStateEvent(ev.Data);
                    break;
                case "mediamtx-state-changed":
                    // Event payload only carries {running}; refresh fetches
                    // the richer pid/restarts info that ApplyMediaMtx renders.
                    await RefreshAsync();
                    break;
                case "cameras-changed":
                    // Plug or unplug detected on the supervisor side. Re-sync
                    // the whole list so additions/removals are reflected.
                    _vm.ApplyCameraList(ev.Data);
                    break;
                case "probe-started":
                    {
                        if (ev.Data.TryGetProperty("camera", out var camName))
                        {
                            var nm = camName.GetString() ?? "";
                            var row = _vm.Cameras.FirstOrDefault(c => c.Name == nm);
                            if (row != null) row.ProbeStatus = "probing...";
                        }
                        break;
                    }
                case "probe-completed":
                    {
                        if (ev.Data.TryGetProperty("camera", out var camName))
                        {
                            var nm = camName.GetString() ?? "";
                            var row = _vm.Cameras.FirstOrDefault(c => c.Name == nm);
                            if (row != null)
                            {
                                bool ok = ev.Data.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
                                if (ok)
                                {
                                    string rec = ev.Data.TryGetProperty("recommended", out var rEl)
                                        ? (rEl.GetString() ?? "?")
                                        : "?";
                                    row.ProbeStatus = $"recommended: {rec}";
                                }
                                else
                                {
                                    string err = ev.Data.TryGetProperty("error", out var eEl)
                                        ? (eEl.GetString() ?? "")
                                        : "failed";
                                    row.ProbeStatus = "FAILED: " + err;
                                }
                            }
                        }
                        // Refresh after probe so any updated recommendation shows up.
                        await RefreshAsync();
                        break;
                    }
            }
        });
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

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

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

    private async void Probe_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: CameraInfo cam } || _ipc == null) return;
        try
        {
            cam.ProbeStatus = "starting probe...";
            await _ipc.CallAsync("probe-camera", new { name = cam.Name });
            // probe-started / probe-completed events drive the UI from here on.
        }
        catch (Exception ex)
        {
            cam.ProbeStatus = "probe call failed: " + ex.Message;
        }
    }

    private async void ModeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is not ComboBox { Tag: CameraInfo cam } cb) return;
        if (_ipc == null) return;
        if (e.AddedItems.Count == 0) return;
        var picked = e.AddedItems[0] as string;
        if (string.IsNullOrEmpty(picked)) return;

        // Skip if this fired because cam.Mode was just refreshed from the
        // server (binding update), not because the user picked something.
        if (picked == cam.Mode) return;

        try
        {
            await _ipc.CallAsync("set-mode", new { name = cam.Name, mode = picked });
            // The supervisor emits camera-state-changed; cam.Mode will refresh
            // through the IPC pump. ProbeStatus is independent of mode change.
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "set-mode failed:\n" + ex.Message,
                            "IPC error", MessageBoxButton.OK, MessageBoxImage.Warning);
            // Force a refresh so ComboBox snaps back to actual mode.
            await RefreshAsync();
        }
    }

    private async void Shutdown_Click(object sender, RoutedEventArgs e)
    {
        if (_ipc == null) return;
        try
        {
            await _ipc.CallAsync("shutdown");
        }
        catch { /* supervisor may exit before responding cleanly; ignored */ }
        Close();
    }

    private void MainWindow_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        _pollTimer?.Stop();
        _ipc?.Dispose();
        _launcher?.Dispose();   // closes Job Object handle -> KILL_ON_JOB_CLOSE
    }
}
