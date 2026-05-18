using Microsoft.Win32;

namespace WebcamStreamerUi;

// Per-user autostart via HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
// The same registry value the installer writes; we update it at runtime so
// the WPF "Start on Windows logon" checkbox is reversible without
// reinstalling.
//
// Per ADR 0001 we run in the user session, so HKCU is the right hive --
// no admin needed.
public static class AutostartHelper
{
    private const string RunKey   = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WebcamStreamer";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
        return key?.GetValue(ValueName) != null;
    }

    public static void Enable(string exePath)
    {
        // "Start in the user's normal logon shell" -- minimised would be
        // arguments territory; the host app is tray-only by default, so
        // a plain invocation is fine.
        var quoted = $"\"{exePath}\"";
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        key.SetValue(ValueName, quoted, RegistryValueKind.String);
    }

    public static void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
