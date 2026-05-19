using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;

namespace WebcamStreamerUi;

public sealed class MainViewModel : INotifyPropertyChanged
{
    // ConnectionStatus is shown only on error (the happy "ipc connected"
    // state was just noise -- if the supervisor is up and IPC is fine,
    // the rest of the UI is the evidence). On disconnect we surface a
    // red message so the user knows the camera state may be stale.
    private string _connectionStatus = "";
    private bool   _connectionError;
    private bool   _mediaMtxRunning;

    public ObservableCollection<CameraInfo> Cameras { get; } = new();

    public string ConnectionStatus
    {
        get => _connectionStatus;
        set => Set(ref _connectionStatus, value);
    }

    public bool ConnectionError
    {
        get => _connectionError;
        set => Set(ref _connectionError, value);
    }

    // Drives a green/red dot next to "mediamtx" in the status bar. PID and
    // restart counts were dropped from the user-facing status -- they're
    // implementation detail and not actionable.
    public bool MediaMtxRunning
    {
        get => _mediaMtxRunning;
        set => Set(ref _mediaMtxRunning, value);
    }

    // Current viewer credentials, shadowed from whatever the supervisor
    // reports per-row. Bound to the Security section TextBox + reveal-
    // on-type password input. Editing here doesn't persist anywhere by
    // itself; the Security section's Apply button is what calls
    // set-viewer-credentials.
    private string _viewerUser = "";
    private string _viewerPass = "";
    public string ViewerUser     { get => _viewerUser; set => Set(ref _viewerUser, value); }
    public string ViewerPassword { get => _viewerPass; set => Set(ref _viewerPass, value); }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? prop = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));
        return true;
    }

    /// <summary>Reconcile from a list-cameras / get-status payload. Runs on UI thread.</summary>
    public void ApplyCameraList(JsonElement cameras)
    {
        if (cameras.ValueKind != JsonValueKind.Array) return;

        // Build map of existing rows by name.
        var existing = Cameras.ToDictionary(c => c.Name);
        var seen = new HashSet<string>();

        foreach (var el in cameras.EnumerateArray())
        {
            string name = el.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "";
            if (string.IsNullOrEmpty(name)) continue;
            seen.Add(name);

            if (existing.TryGetValue(name, out var row))
            {
                row.UpdateFromJson(el);
            }
            else
            {
                var row2 = new CameraInfo();
                row2.UpdateFromJson(el);
                Cameras.Add(row2);
            }
        }

        // Remove rows for cams that disappeared from the snapshot.
        for (int i = Cameras.Count - 1; i >= 0; i--)
        {
            if (!seen.Contains(Cameras[i].Name)) Cameras.RemoveAt(i);
        }

        // Promote viewer credentials from whichever row arrived so the
        // Security section sees them. They're identical across rows
        // (global supervisor setting echoed per-row), so the first row
        // wins.
        if (Cameras.Count > 0)
        {
            var first = Cameras[0];
            if (!string.IsNullOrEmpty(first.ViewerUser)     && first.ViewerUser     != ViewerUser)     ViewerUser     = first.ViewerUser;
            if (!string.IsNullOrEmpty(first.ViewerPassword) && first.ViewerPassword != ViewerPassword) ViewerPassword = first.ViewerPassword;
        }
    }

    public void ApplyMediaMtx(JsonElement mediamtx)
    {
        // Only the running flag matters to the user; pid + restarts are
        // diagnostic detail surfaced in supervisor.log if needed.
        MediaMtxRunning = mediamtx.TryGetProperty("running", out var r) && r.GetBoolean();
    }

    /// <summary>Apply an incoming camera-state-changed event payload to the matching row.</summary>
    public void ApplyCameraStateEvent(JsonElement data)
    {
        string name = data.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "";
        if (string.IsNullOrEmpty(name)) return;
        var row = Cameras.FirstOrDefault(c => c.Name == name);
        if (row != null) row.UpdateFromJson(data);
    }
}
