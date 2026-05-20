using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;      // Mutex, EventWaitHandle
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

    // Single-instance guard. The supervisor's named pipe is system-wide and
    // single-server, so two concurrent UIs would race: the second's
    // supervisor can't create the pipe, and the UI eventually times out
    // with "IPC connect failed". We avoid that by holding a session-scoped
    // named mutex for the lifetime of the first UI, and using a named
    // EventWaitHandle as a "please show your window" doorbell for follow-up
    // launches (Start Menu / desktop shortcut while we're tray-resident).
    //
    // Names are session-scoped (Local\) on purpose: the app is per-user and
    // creating Global\ kernel objects requires SeCreateGlobalPrivilege,
    // which a standard user lacks. Two users on the same machine each get
    // their own first instance; if their sessions then collide on the
    // supervisor pipe itself, the second user's supervisor will fail to
    // start and that case still needs the existing error path. Worth it
    // for the common single-user double-click scenario.
    private const string SingleInstanceMutexName = @"Local\WebcamStreamer.Host.Mutex";
    private const string ShowWindowEventName     = @"Local\WebcamStreamer.Host.ShowWindow";
    private Mutex?           _instanceMutex;
    private EventWaitHandle? _showWindowEvent;
    private Thread?          _showWindowListener;
    private volatile bool    _shuttingDown;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // --- single-instance check (do this BEFORE any side effects like
        // spawning the supervisor or registering the tray icon). ---
        _instanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName,
                                   out bool createdNew);
        if (!createdNew)
        {
            // Someone else owns the mutex. Knock on their doorbell, then
            // exit without doing any other startup work. If the running
            // instance is still very early in its startup it may not have
            // created the event yet -- in that race we just exit silently,
            // since the user's launch attempt at least proved the first
            // instance is alive and they'll see its window shortly.
            try
            {
                using var ev = EventWaitHandle.OpenExisting(ShowWindowEventName);
                ev.Set();
            }
            catch (WaitHandleCannotBeOpenedException) { /* race; ignore */ }
            catch (Exception ex) { Debug.WriteLine("doorbell signal: " + ex.Message); }

            // We never owned the mutex, so do not release it.
            _instanceMutex.Dispose();
            _instanceMutex = null;
            Shutdown(0);
            return;
        }

        // First instance. Create the doorbell event and the listener that
        // turns each "ring" into a Dispatcher-thread ShowMainWindow().
        _showWindowEvent = new EventWaitHandle(false, EventResetMode.AutoReset,
                                               ShowWindowEventName);
        _showWindowListener = new Thread(ShowWindowListenerLoop)
        {
            IsBackground = true,
            Name = "show-window-listener",
        };
        _showWindowListener.Start();

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

    // Background worker that waits on the cross-process "show window"
    // doorbell and turns each signal into a Dispatcher-marshalled
    // ShowMainWindow(). Exits when the event is disposed during shutdown.
    private void ShowWindowListenerLoop()
    {
        var ev = _showWindowEvent;
        if (ev == null) return;
        while (!_shuttingDown)
        {
            try
            {
                if (!ev.WaitOne()) break;
                if (_shuttingDown) break;
                Dispatcher.BeginInvoke(() =>
                {
                    try { ShowMainWindow(); }
                    catch (Exception ex) { Debug.WriteLine("show-on-doorbell: " + ex.Message); }
                });
            }
            catch (ObjectDisposedException) { break; }
            catch (AbandonedMutexException)  { break; }
        }
    }

    private void DisposeSingleInstanceGuard()
    {
        _shuttingDown = true;
        try { _showWindowEvent?.Set(); }  catch { /* may already be disposed */ }
        try { _showWindowEvent?.Dispose(); } catch { }
        _showWindowEvent = null;

        try { _instanceMutex?.ReleaseMutex(); } catch { /* not owned or already released */ }
        try { _instanceMutex?.Dispose(); } catch { }
        _instanceMutex = null;
    }

    private void ExitApp()
    {
        try { _ = Ipc?.CallAsync("shutdown"); } catch { /* may not respond */ }
        _tray?.Dispose();
        Ipc?.Dispose();
        Launcher?.Dispose();   // closes Job Object handle -> KILL_ON_JOB_CLOSE
        DisposeSingleInstanceGuard();
        Shutdown(0);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        Ipc?.Dispose();
        Launcher?.Dispose();
        DisposeSingleInstanceGuard();
        base.OnExit(e);
    }
}
