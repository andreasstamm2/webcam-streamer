using System.Text.Json;
using Microsoft.Toolkit.Uwp.Notifications;

namespace WebcamStreamerUi;

// Thin wrapper over CommunityToolkit.WinUI.Notifications. Composes the
// toast XML for our three viewer-event types and routes them through a
// single Show() call.
//
// Behaviour:
//  - If host.NotificationsEnabled is false, every Show() call is a no-op.
//  - For an unpackaged WPF app, the Windows toast service requires a
//    Start Menu shortcut whose PropertyStore.System.AppUserModel.ID
//    matches our AUMID. The installer (Slice F) stamps that shortcut;
//    in dev, without the shortcut, the toast API call SILENTLY does
//    nothing -- not an error path. Verifying toasts in CI is therefore
//    limited to "the code that builds + shows the toast was reached".
public sealed class ToastNotifier
{
    private readonly HostSettings _settings;

    public ToastNotifier(HostSettings settings) { _settings = settings; }

    public void OnViewerConnected(JsonElement data)
    {
        if (!_settings.NotificationsEnabled) return;
        string camera = StringOf(data, "camera", "(unknown camera)");
        string codec  = StringOf(data, "codec",  "");
        int    width  = IntOf   (data, "width",  0);
        int    height = IntOf   (data, "height", 0);
        string ip     = StringOf(data, "reader_ip", "(unknown)");

        var body = $"{codec} · {width}×{height} · viewer from {ip}";
        new ToastContentBuilder()
            .AddText($"{camera} is now being viewed")
            .AddText(body)
            .Show();
    }

    public void OnViewerAuthFailed(JsonElement data)
    {
        if (!_settings.NotificationsEnabled) return;
        string ip     = StringOf(data, "reader_ip", "(unknown)");
        string reason = StringOf(data, "reason",    "authentication failed");
        new ToastContentBuilder()
            .AddText("Failed connection attempt")
            .AddText($"{ip} tried to view a stream — {reason}")
            .Show();
    }

    private static string StringOf(JsonElement el, string key, string fallback)
    {
        if (el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String)
            return v.GetString() ?? fallback;
        return fallback;
    }
    private static int IntOf(JsonElement el, string key, int fallback)
    {
        if (el.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number &&
            v.TryGetInt32(out int n)) return n;
        return fallback;
    }
}
