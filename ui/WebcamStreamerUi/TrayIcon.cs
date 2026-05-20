using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Drawing;
using System.Windows.Forms;

namespace WebcamStreamerUi;

// Notification-area icon + context menu.
//
// Menu (built per ADR-locked design in CONTEXT.md):
//   WebcamStreamer            (disabled header)
//   ---
//   [x] Notifications         (toggles HostSettings.NotificationsEnabled + persists)
//   ---
//   Cameras
//     [x] Logitech BRIO   /webcam0
//     [ ] HP 5MP Camera   /webcam1
//   ---
//   Advanced Settings...      (shows MainWindow)
//   ---
//   Exit                      (confirmation prompt -> Application.Current.Shutdown)
//
// Left-click on the icon opens the same menu (per Q9.1).
// Tooltip is dynamic: "{enabled} of {total} cameras enabled, {viewers} viewers".
// Both numbers derive from CameraInfo rows so the tooltip can never disagree
// with the DataGrid status pill or the per-camera submenu.
public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon         _icon;
    private readonly ContextMenuStrip   _menu;
    private readonly ToolStripMenuItem  _notifyToggle;
    private readonly ToolStripMenuItem  _camerasItem;
    private readonly HostSettings       _settings;
    private readonly ObservableCollection<CameraInfo> _cameras;

    public event EventHandler? AdvancedSettingsClicked;
    public event EventHandler? AboutClicked;
    public event EventHandler<bool>? NotificationsToggled;     // arg = new state
    public event EventHandler<(string CameraName, bool Enabled)>? CameraEnableChanged;
    public event EventHandler? ExitRequested;

    public TrayIcon(HostSettings settings, ObservableCollection<CameraInfo> cameras)
    {
        _settings = settings;
        _cameras  = cameras;

        _menu = new ContextMenuStrip();

        var header = new ToolStripMenuItem("WebcamStreamer") { Enabled = false };
        _menu.Items.Add(header);
        _menu.Items.Add(new ToolStripSeparator());

        _notifyToggle = new ToolStripMenuItem("Notifications")
        {
            Checked      = settings.NotificationsEnabled,
            CheckOnClick = true,
        };
        _notifyToggle.CheckedChanged += (_, _) =>
        {
            NotificationsToggled?.Invoke(this, _notifyToggle.Checked);
        };
        _menu.Items.Add(_notifyToggle);
        _menu.Items.Add(new ToolStripSeparator());

        _camerasItem = new ToolStripMenuItem("Cameras");
        _menu.Items.Add(_camerasItem);
        _menu.Items.Add(new ToolStripSeparator());

        // "Settings..." was retired in v0.3.1: the same settings are
        // available in the collapsible "Settings" section of the main
        // window, which "Advanced Settings..." opens. One entry point
        // is enough.
        var advanced = new ToolStripMenuItem("Advanced Settings...");
        advanced.Click += (_, _) => AdvancedSettingsClicked?.Invoke(this, EventArgs.Empty);
        _menu.Items.Add(advanced);
        _menu.Items.Add(new ToolStripSeparator());

        var about = new ToolStripMenuItem("About...");
        about.Click += (_, _) => AboutClicked?.Invoke(this, EventArgs.Empty);
        _menu.Items.Add(about);
        _menu.Items.Add(new ToolStripSeparator());

        var exit = new ToolStripMenuItem("Exit");
        exit.Click += (_, _) =>
        {
            var r = MessageBox.Show(
                "Exiting will stop all webcam streams. Continue?",
                "WebcamStreamer",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question,
                System.Windows.MessageBoxResult.No);
            if (r == System.Windows.MessageBoxResult.Yes) ExitRequested?.Invoke(this, EventArgs.Empty);
        };
        _menu.Items.Add(exit);

        _icon = new NotifyIcon
        {
            Icon              = LoadAppIcon(),
            ContextMenuStrip  = _menu,
            Visible           = true,
            Text              = "WebcamStreamer",
        };

        // Left click also opens the menu (Q9.1).
        _icon.MouseUp += (s, e) =>
        {
            if (e.Button == MouseButtons.Left)
            {
                // ContextMenuStrip's Show() needs a screen location; query
                // the cursor since NotifyIcon doesn't expose a screen rect.
                _menu.Show(Cursor.Position);
            }
        };

        // Keep tray menu in sync as cameras change in the VM.
        _cameras.CollectionChanged += (_, _) =>
            _icon.GetType().GetMethod("OnMouseMove", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        // Above line is a no-op placeholder; actual rebuild driven by host
        // via RefreshCameras().
        RefreshCameras();
        UpdateTooltip();
    }

    public void RefreshCameras()
    {
        _camerasItem.DropDownItems.Clear();
        bool any = false;
        foreach (var cam in _cameras)
        {
            if (!cam.Present) continue;                  // hide unplugged (Q9.3)
            any = true;
            var item = new ToolStripMenuItem(string.IsNullOrWhiteSpace(cam.Path)
                                              ? cam.Name
                                              : $"{cam.Name}   {cam.Path}")
            {
                Checked      = cam.Enabled,
                CheckOnClick = true,
                Tag          = cam.Name,
            };
            item.CheckedChanged += (s, _) =>
            {
                if (s is ToolStripMenuItem mi && mi.Tag is string nm)
                    CameraEnableChanged?.Invoke(this, (nm, mi.Checked));
            };
            _camerasItem.DropDownItems.Add(item);
        }
        if (!any)
        {
            var none = new ToolStripMenuItem("(no cameras detected)") { Enabled = false };
            _camerasItem.DropDownItems.Add(none);
        }
        UpdateTooltip();
    }

    public void SyncNotificationToggle(bool enabled)
    {
        if (_notifyToggle.Checked != enabled) _notifyToggle.Checked = enabled;
    }

    private void UpdateTooltip()
    {
        // Count plugged-in cameras, regardless of running state. "Enabled"
        // reflects user intent: a re-enabled cam must show up in the
        // numerator even if its publisher is mid-restart. The viewer total
        // sums the supervisor's per-cam counts, so the tooltip can't drift
        // from the DataGrid (no UI-side tally).
        int total   = _cameras.Count(c => c.Present);
        int enabled = _cameras.Count(c => c.Present && c.Enabled);
        int viewers = _cameras.Sum(c => c.ViewerCount);
        // NotifyIcon.Text has a 127-character ceiling on modern Windows.
        var s = $"WebcamStreamer\n{enabled} of {total} cameras enabled\n{viewers} viewers";
        if (s.Length > 127) s = s.Substring(0, 127);
        _icon.Text = s;
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }

    // Load app.ico from the embedded WPF resource. Falls back to the
    // generic system icon if the resource isn't available (e.g. someone
    // ran the bare DLL without the .ico bundled). The icon object is
    // small enough that we don't worry about lifetimes -- it lives as
    // long as the NotifyIcon does.
    private static Icon LoadAppIcon()
    {
        try
        {
            var info = System.Windows.Application.GetResourceStream(
                new Uri("/app.ico", UriKind.Relative));
            if (info != null)
            {
                using var s = info.Stream;
                return new Icon(s);
            }
        }
        catch { /* fall through */ }
        return SystemIcons.Application;
    }
}

// CameraInfo.Enabled lives in CameraInfo.cs (added in Slice A). This file
// only assumes the property exists.
