using System.IO;
using System.Text.Json;

namespace WebcamStreamerUi;

// Persistent host-app settings. Lives at <data-root>/settings.json. The
// supervisor reads the same file -- we own writes, the supervisor only
// reads. After writing, we send `reload-settings` over IPC so the
// supervisor picks up the new value for hot-plug decisions.
public sealed class HostSettings
{
    public bool   NotificationsEnabled        { get; set; } = true;
    public bool   DefaultEnabledForNewCameras { get; set; } = true;
    // MediaMTX viewer credentials. Empty here = not yet generated; the
    // installer writes them on post-install and the supervisor falls back
    // to generating them at first run when missing. The WPF Security
    // section edits these via the set-viewer-credentials IPC method.
    public string ViewerUser                   { get; set; } = "";
    public string ViewerPassword               { get; set; } = "";

    // Mirror of what the WPF host writes to disk. Fields here MUST match
    // the keys the C++ supervisor's settings.cpp looks for.
    private sealed class Schema
    {
        public bool?  notifications_enabled              { get; set; }
        public bool?  default_enabled_for_new_cameras    { get; set; }
        public string? viewer_user                       { get; set; }
        public string? viewer_pass                       { get; set; }
    }

    public static string DataRoot
    {
        get
        {
            // For now the data root is the supervisor's project root: the
            // directory that contains supervisor/build/Release/supervisor.exe
            // when found via SupervisorLauncher.LocateSupervisorExe(). Slice F
            // (installer) will switch this to %LOCALAPPDATA%\WebcamStreamer.
            var exe = SupervisorLauncher.LocateSupervisorExe();
            if (exe == null) return AppContext.BaseDirectory;
            // exe = <root>\supervisor\build\Release\supervisor.exe -- go up 3.
            var d = new DirectoryInfo(exe).Parent;       // Release
            d = d?.Parent;                                // build
            d = d?.Parent;                                // supervisor
            d = d?.Parent;                                // <root>
            return d?.FullName ?? AppContext.BaseDirectory;
        }
    }

    public static string SettingsPath => Path.Combine(DataRoot, "settings.json");

    public static HostSettings Load()
    {
        var path = SettingsPath;
        if (!File.Exists(path)) return new HostSettings();
        try
        {
            var json = File.ReadAllText(path);
            var s = JsonSerializer.Deserialize<Schema>(json);
            return new HostSettings
            {
                NotificationsEnabled        = s?.notifications_enabled              ?? true,
                DefaultEnabledForNewCameras = s?.default_enabled_for_new_cameras    ?? true,
                ViewerUser                  = s?.viewer_user                        ?? "",
                ViewerPassword              = s?.viewer_pass                        ?? "",
            };
        }
        catch
        {
            // Bad / partial file: fall back to defaults. We deliberately do
            // NOT delete the file -- the user may have hand-edited it; we
            // shouldn't destroy their work on a parse hiccup.
            return new HostSettings();
        }
    }

    public void Save()
    {
        var schema = new Schema
        {
            notifications_enabled              = NotificationsEnabled,
            default_enabled_for_new_cameras    = DefaultEnabledForNewCameras,
            viewer_user                        = ViewerUser,
            viewer_pass                        = ViewerPassword,
        };
        var json = JsonSerializer.Serialize(schema,
                       new JsonSerializerOptions { WriteIndented = true });
        Directory.CreateDirectory(DataRoot);
        File.WriteAllText(SettingsPath, json);
    }
}
