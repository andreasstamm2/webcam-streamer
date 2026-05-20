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
    //
    // Subtlety: the MainWindow runs a 5-second poll that re-pulls
    // get-status, and the supervisor also emits cameras-changed events.
    // Both paths flow back into ApplyCameraList -> credential promotion.
    // If we just assigned ViewerUser/ViewerPassword unconditionally there,
    // the user's half-typed entry would get clobbered every ~5s. We
    // therefore raise _credentialsDirty as soon as the user edits either
    // field (the binding calls the setter), and skip the promotion while
    // dirty. The flag is cleared after a successful Apply, so the next
    // round-trip resyncs to what the supervisor now stores.
    private string _viewerUser = "";
    private string _viewerPass = "";
    private bool   _credentialsDirty;
    public string ViewerUser
    {
        get => _viewerUser;
        set { if (Set(ref _viewerUser, value)) _credentialsDirty = true; }
    }
    public string ViewerPassword
    {
        get => _viewerPass;
        set { if (Set(ref _viewerPass, value)) _credentialsDirty = true; }
    }

    // Seeds the bound credentials from a supervisor snapshot WITHOUT
    // flipping the dirty flag. No-ops once the user has started editing,
    // so the 5-second poll cannot clobber an in-progress entry.
    public void SeedViewerCredentialsFromSupervisor(string user, string pass)
    {
        if (_credentialsDirty) return;
        if (!string.IsNullOrEmpty(user) && user != _viewerUser)
        {
            _viewerUser = user;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ViewerUser)));
        }
        if (!string.IsNullOrEmpty(pass) && pass != _viewerPass)
        {
            _viewerPass = pass;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ViewerPassword)));
        }
    }

    // Call after a successful set-viewer-credentials so the next refresh
    // resyncs from the supervisor (which now stores what we just typed).
    public void MarkCredentialsApplied() => _credentialsDirty = false;

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
        // wins. The seed path skips the assignment if the user is
        // currently editing -- see SeedViewerCredentialsFromSupervisor.
        if (Cameras.Count > 0)
        {
            var first = Cameras[0];
            SeedViewerCredentialsFromSupervisor(first.ViewerUser, first.ViewerPassword);
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
