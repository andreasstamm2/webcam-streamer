using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;

namespace WebcamStreamerUi;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private string _connectionStatus = "disconnected";
    private string _mediaMtxStatus = "mediamtx: unknown";

    public ObservableCollection<CameraInfo> Cameras { get; } = new();

    public string ConnectionStatus
    {
        get => _connectionStatus;
        set => Set(ref _connectionStatus, value);
    }

    public string MediaMtxStatus
    {
        get => _mediaMtxStatus;
        set => Set(ref _mediaMtxStatus, value);
    }

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
    }

    public void ApplyMediaMtx(JsonElement mediamtx)
    {
        bool running = mediamtx.TryGetProperty("running", out var r) && r.GetBoolean();
        uint pid     = mediamtx.TryGetProperty("pid", out var p) ? p.GetUInt32() : 0;
        int  restarts = mediamtx.TryGetProperty("restarts", out var rs) ? rs.GetInt32() : 0;
        MediaMtxStatus = $"mediamtx: {(running ? "running" : "down")} (pid {pid}, restarts {restarts})";
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
