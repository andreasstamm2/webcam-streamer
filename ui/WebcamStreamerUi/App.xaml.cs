using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;        // StartupEventArgs, ExitEventArgs, WindowState

namespace WebcamStreamerUi;

// Process-wide host. Owns the supervisor's lifetime (Job Object), the IPC
// connection, the tray icon, and the toast notifier. The WPF MainWindow
// is a view that this host shows on demand; closing it hides instead of
// quits.
public partial class App : System.Windows.Application
{
    // The Windows toast service identifies us by this AUMID. It also lives
    // in the Start Menu shortcut's PropertyStore (set by the installer in
    // Slice F). For unpackaged WPF apps, toasts silently no-op without
    // that shortcut -- not an error, just nothing happens.
    public const string Aumid = "WebcamStreamer.Host";

    [DllImport("shell32.dll", SetLastError = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(
        [MarshalAs(UnmanagedType.LPWStr)] string AppID);

    // Single-instance accessors so MainWindow can reach the shared state
    // without an IoC container.
    public static App?               Instance     { get; private set; }
    public  HostSettings             Settings     { get; private set; } = new();
    public  IpcClient?               Ipc          { get; private set; }
    public  MainViewModel            Vm           { get; } = new();
    public  SupervisorLauncher?      Launcher     { get; private set; }
    public  ToastNotifier?           Toasts       { get; private set; }

    private TrayIcon?   _tray;
    private MainWindow? _mainWindow;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Instance = this;

        SetCurrentProcessExplicitAppUserModelID(Aumid);

        Settings = HostSettings.Load();
        Toasts   = new ToastNotifier(Settings);

        // --- supervisor + IPC ---
        var exePath = SupervisorLauncher.LocateSupervisorExe();
        if (exePath == null)
        {
            MessageBox.Show(
                "Could not find supervisor.exe. Build it via:\n\n" +
                "  cd supervisor && cmake --build build --config Release\n\n" +
                "Looked relative to: " + AppContext.BaseDirectory,
                "supervisor.exe missing",
                MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(2);
            return;
        }

        Launcher = new SupervisorLauncher(exePath);
        Launcher.StdoutLine += (_, line) => Debug.WriteLine("[sup] "    + line);
        Launcher.StderrLine += (_, line) => Debug.WriteLine("[sup-err] " + line);
        Launcher.Exited     += (_, code) => Dispatcher.BeginInvoke(() =>
        {
            Vm.ConnectionStatus = $"supervisor exited (code {code})";
            Vm.ConnectionError  = true;
        });

        try
        {
            Launcher.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show("Failed to start supervisor:\n" + ex.Message,
                            "launch failed", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(3);
            return;
        }

        Ipc = new IpcClient();
        Ipc.EventReceived += OnIpcEvent;
        Ipc.Disconnected  += (_, why) =>
            Dispatcher.BeginInvoke(() =>
            {
                Vm.ConnectionStatus = "supervisor disconnected: " + why;
                Vm.ConnectionError  = true;
            });

        // Brief retry: supervisor opens its pipe a beat after launch.
        for (int attempt = 0; attempt < 20; attempt++)
        {
            try { await Ipc.ConnectAsync(500); break; }
            catch (TimeoutException) when (attempt < 19) { await Task.Delay(250); }
            catch (Exception ex)
            {
                MessageBox.Show("IPC connect failed:\n" + ex.Message,
                                "connect failed", MessageBoxButton.OK, MessageBoxImage.Error);
                Shutdown(4);
                return;
            }
        }
        // Drop the happy-path "ipc connected" message -- it's just noise.
        // The status bar stays empty unless something goes wrong.
        Vm.ConnectionStatus = "";
        Vm.ConnectionError  = false;

        // Pull initial state so the tray menu has cameras to show.
        await RefreshAsync();

        // --- tray icon ---
        _tray = new TrayIcon(Settings, Vm.Cameras);
        _tray.AdvancedSettingsClicked += (_, _) => ShowMainWindow();
        // The standalone Settings dialog was retired in v0.3 -- the same
        // toggles live in a collapsible section in the main window.
        // Tray "Settings..." now opens the main window directly so the
        // user lands on the right surface immediately.
        _tray.SettingsClicked         += (_, _) => ShowMainWindow();
        _tray.AboutClicked            += (_, _) => ShowAboutWindow();
        _tray.NotificationsToggled    += async (_, on) =>
        {
            Settings.NotificationsEnabled = on;
            try { Settings.Save(); } catch (Exception ex) { Debug.WriteLine("settings save: " + ex.Message); }
            try { if (Ipc != null) await Ipc.CallAsync("reload-settings"); } catch { }
        };
        _tray.CameraEnableChanged += async (_, payload) =>
        {
            if (Ipc == null) return;
            try
            {
                await Ipc.CallAsync("set-stream-enabled",
                    new { name = payload.CameraName, enabled = payload.Enabled });
            }
            catch (Exception ex) { Debug.WriteLine("set-stream-enabled: " + ex.Message); }
        };
        _tray.ExitRequested += (_, _) => ExitApp();

        // Keep tray cam-list in sync with VM changes (state-changed events
        // mutate the existing rows; cameras-changed adds/removes).
        Vm.Cameras.CollectionChanged += (_, _) => _tray?.RefreshCameras();
        foreach (var cam in Vm.Cameras) cam.PropertyChanged += (_, _) => _tray?.RefreshCameras();

        // --- first-launch UX: if no settings.json existed, show the
        // window once so the user sees what they got. Subsequent
        // autostarts stay tray-only.
        if (!System.IO.File.Exists(HostSettings.SettingsPath))
        {
            try { Settings.Save(); } catch { /* best-effort first-write */ }
            ShowMainWindow();
        }
    }

    private async Task RefreshAsync()
    {
        if (Ipc == null) return;
        try
        {
            var resp = await Ipc.CallAsync("get-status");
            if (resp.TryGetProperty("ok", out var ok) && ok.GetBoolean() &&
                resp.TryGetProperty("result", out var result))
            {
                if (result.TryGetProperty("cameras", out var cams)) Vm.ApplyCameraList(cams);
                if (result.TryGetProperty("mediamtx", out var mtx)) Vm.ApplyMediaMtx(mtx);
            }
        }
        catch (Exception ex)
        {
            Vm.ConnectionStatus = "refresh failed: " + ex.Message;
            Vm.ConnectionError  = true;
        }
    }

    private void OnIpcEvent(object? sender, EventArrived ev)
    {
        Dispatcher.BeginInvoke(() =>
        {
            switch (ev.Name)
            {
                case "camera-state-changed":
                    Vm.ApplyCameraStateEvent(ev.Data);
                    _tray?.RefreshCameras();
                    break;
                case "cameras-changed":
                    Vm.ApplyCameraList(ev.Data);
                    _tray?.RefreshCameras();
                    break;
                case "mediamtx-state-changed":
                    _ = RefreshAsync();
                    break;
                case "viewer-connected":
                    // No tray bookkeeping here -- the supervisor pairs the
                    // viewer event with a camera-state-changed (carrying
                    // viewer_count) which already drives the tooltip via
                    // CameraInfo PropertyChanged. Toasts still fire.
                    Toasts?.OnViewerConnected(ev.Data);
                    break;
                case "viewer-disconnected":
                    // No toast for disconnect (per Q12.1).
                    break;
                case "viewer-auth-failed":
                    Toasts?.OnViewerAuthFailed(ev.Data);
                    break;
            }
        });
    }

    public void ShowMainWindow()
    {
        if (_mainWindow == null)
        {
            _mainWindow = new MainWindow();
        }
        if (!_mainWindow.IsVisible) _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
            _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    // Public hook so the inline Settings section in MainWindow can keep
    // the tray menu's Notifications checkbox in sync after a flip.
    public void SyncTrayNotificationToggle(bool enabled)
        => _tray?.SyncNotificationToggle(enabled);

    // About dialog: read-only, modal. If the MainWindow happens to be
    // open we anchor on it so the dialog centers there; otherwise it
    // centers on the primary screen.
    public void ShowAboutWindow()
    {
        var owner = (_mainWindow != null && _mainWindow.IsVisible) ? _mainWindow : null;
        var w = new AboutWindow();
        if (owner != null)
        {
            w.Owner = owner;
            w.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        }
        else
        {
            w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        w.ShowDialog();
    }

    private void ExitApp()
    {
        try { _ = Ipc?.CallAsync("shutdown"); } catch { /* may not respond */ }
        _tray?.Dispose();
        Ipc?.Dispose();
        Launcher?.Dispose();   // closes Job Object handle -> KILL_ON_JOB_CLOSE
        Shutdown(0);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        Ipc?.Dispose();
        Launcher?.Dispose();
        base.OnExit(e);
    }
}
