using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace WebcamStreamerUi;

// One row in the camera DataGrid. Implements INotifyPropertyChanged so
// live updates from camera-state-changed events flow into the UI.
public sealed class CameraInfo : INotifyPropertyChanged
{
    private string _name = "";
    private string _path = "";
    private string _mode = "";
    private bool   _running;
    private bool   _present = true;
    private uint   _pid;
    private int    _restarts;
    private string _probeStatus = "";

    public string Name        { get => _name;        set => Set(ref _name,        value); }
    public string Path        { get => _path;        set => Set(ref _path,        value); }
    public string Mode        { get => _mode;        set => Set(ref _mode,        value); }
    public bool   Running     { get => _running;     set => Set(ref _running,     value); }
    public bool   Present     { get => _present;     set => Set(ref _present,     value); }
    public uint   Pid         { get => _pid;         set => Set(ref _pid,         value); }
    public int    Restarts    { get => _restarts;    set => Set(ref _restarts,    value); }
    public string ProbeStatus { get => _probeStatus; set => Set(ref _probeStatus, value); }

    public string FullUrl => $"rtsp://viewer:viewer@127.0.0.1:8554{_path}";

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? prop = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));
        if (prop == nameof(Path)) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullUrl)));
        return true;
    }

    public void UpdateFromJson(JsonElement el)
    {
        if (el.TryGetProperty("name",     out var n)) Name     = n.GetString() ?? "";
        if (el.TryGetProperty("path",     out var p)) Path     = p.GetString() ?? "";
        if (el.TryGetProperty("mode",     out var m)) Mode     = m.GetString() ?? "";
        if (el.TryGetProperty("running",  out var r)) Running  = r.GetBoolean();
        if (el.TryGetProperty("present",  out var pr)) Present = pr.GetBoolean();
        if (el.TryGetProperty("pid",      out var pi)) Pid     = pi.GetUInt32();
        if (el.TryGetProperty("restarts", out var rs)) Restarts = rs.GetInt32();
    }
}
