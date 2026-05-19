using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace WebcamStreamerUi;

// One advertised input format from the supervisor's ffmpeg -list_options
// enumeration. Either Codec (when Kind == "compressed", e.g. "mjpeg") or
// PixFmt (when Kind == "raw", e.g. "yuyv422") is set.
public sealed record AdvertisedFormat(string Kind, string Codec, string PixFmt,
                                       int Width, int Height,
                                       double MinFps, double MaxFps);

// One row in the camera DataGrid. Implements INotifyPropertyChanged so
// live updates from camera-state-changed events flow into the UI.
public sealed class CameraInfo : INotifyPropertyChanged
{
    private string _name = "";
    private string _path = "";
    private string _mode = "";
    private int    _width;
    private int    _height;
    private int    _fps;
    private string _resolution = "";
    private bool   _running;
    private bool   _present = true;
    private bool   _enabled = true;
    private uint   _pid;
    private int    _restarts;
    private int    _viewerCount;
    private string _viewerUser = "";
    private string _viewerPass = "";
    private List<AdvertisedFormat> _advertisedFormats = new();

    public string Name        { get => _name;        set => Set(ref _name,        value); }
    public string Path        { get => _path;        set => Set(ref _path,        value); }
    public string Mode        { get => _mode;        set => Set(ref _mode,        value); }
    public int    Width       { get => _width;       set { if (Set(ref _width,  value)) Resolution = $"{_width}x{_height}"; } }
    public int    Height      { get => _height;      set { if (Set(ref _height, value)) Resolution = $"{_width}x{_height}"; } }
    public int    Fps         { get => _fps;         set => Set(ref _fps,         value); }
    public string Resolution  { get => _resolution;  set => Set(ref _resolution,  value); }
    public bool   Running     { get => _running;     set => Set(ref _running,     value); }
    public bool   Present     { get => _present;     set => Set(ref _present,     value); }
    public bool   Enabled     { get => _enabled;     set => Set(ref _enabled,     value); }
    public uint   Pid         { get => _pid;         set => Set(ref _pid,         value); }
    public int    Restarts    { get => _restarts;    set => Set(ref _restarts,    value); }
    public int    ViewerCount { get => _viewerCount; set => Set(ref _viewerCount, value); }
    // Current viewer credentials echoed by the supervisor (global config,
    // sent per-row for ease of binding to FullUrl). Updating these makes
    // FullUrl recompute, so the per-row "Copy" button always reflects the
    // currently-applied password.
    public string ViewerUser     { get => _viewerUser; set => Set(ref _viewerUser, value); }
    public string ViewerPassword { get => _viewerPass; set => Set(ref _viewerPass, value); }

    // All formats this cam advertises via DirectShow, as reported by the
    // supervisor's `ffmpeg -list_options` at discovery time. Drives the
    // per-cam Resolution dropdown (filtered by current Mode below).
    public IReadOnlyList<AdvertisedFormat> AdvertisedFormats => _advertisedFormats;

    // Drives the STREAMING vs. ENABLED distinction in the status pill. XAML
    // MultiDataTrigger can't compare integers, so we expose a bool the
    // bindings can consume directly.
    public bool   HasViewers  => _viewerCount > 0;

    // Resolutions the cam actually advertises for whichever input format
    // the currently-selected Mode uses. Empty when we don't yet have
    // advertised_formats (e.g. supervisor still enumerating); the UI falls
    // back to the static Resolutions.All list in that case.
    //
    // Mapping (must stay in lockstep with camera_config.cpp::BuildFFmpegArgs
    // and probe-camera.ps1):
    //   passthrough_mjpeg, transcode_mjpeg_to_h264 -> need compressed/mjpeg
    //   passthrough_h264                            -> need compressed/h264
    //   transcode_raw_to_h264, transcode_raw_to_mjpeg -> need raw
    public IReadOnlyList<string> AvailableResolutions
    {
        get
        {
            if (_advertisedFormats.Count == 0) return Array.Empty<string>();
            string mode = _mode ?? "";
            Func<AdvertisedFormat, bool> pred = mode switch
            {
                "passthrough_mjpeg"        => f => f.Kind == "compressed" && f.Codec == "mjpeg",
                "transcode_mjpeg_to_h264"  => f => f.Kind == "compressed" && f.Codec == "mjpeg",
                "passthrough_h264"         => f => f.Kind == "compressed" && f.Codec == "h264",
                "transcode_raw_to_h264"    => f => f.Kind == "raw",
                "transcode_raw_to_mjpeg"   => f => f.Kind == "raw",
                _                          => _ => true,   // unknown: show everything
            };
            return _advertisedFormats
                .Where(pred)
                .Select(f => $"{f.Width}x{f.Height}")
                .Distinct()
                .OrderBy(s =>
                {
                    var parts = s.Split('x');
                    return int.Parse(parts[0]) * 10000 + int.Parse(parts[1]);
                })
                .ToList();
        }
    }

    // Per-row RTSP URL with current viewer credentials baked in. User and
    // password are URL-encoded so any character a user might pick (after
    // editing the generated value in the Security section) stays
    // syntactically valid. If creds haven't arrived yet (initial race),
    // fall back to placeholder so the UI doesn't show ":@host".
    public string FullUrl
    {
        get
        {
            string u = string.IsNullOrEmpty(_viewerUser) ? "viewer" : Uri.EscapeDataString(_viewerUser);
            string p = string.IsNullOrEmpty(_viewerPass) ? "viewer" : Uri.EscapeDataString(_viewerPass);
            return $"rtsp://{u}:{p}@127.0.0.1:8554{_path}";
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? prop = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(prop));
        if (prop == nameof(Path))           PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullUrl)));
        if (prop == nameof(ViewerUser))     PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullUrl)));
        if (prop == nameof(ViewerPassword)) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(FullUrl)));
        if (prop == nameof(ViewerCount))    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(HasViewers)));
        // Changing the Mode changes which advertised formats are eligible
        // for the Resolution dropdown -- re-raise so the combo refreshes.
        if (prop == nameof(Mode))           PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AvailableResolutions)));
        return true;
    }

    public void UpdateFromJson(JsonElement el)
    {
        if (el.TryGetProperty("name",         out var n))  Name        = n.GetString() ?? "";
        if (el.TryGetProperty("path",         out var p))  Path        = p.GetString() ?? "";
        if (el.TryGetProperty("mode",         out var m))  Mode        = m.GetString() ?? "";
        if (el.TryGetProperty("width",        out var w))  Width       = w.GetInt32();
        if (el.TryGetProperty("height",       out var h))  Height      = h.GetInt32();
        if (el.TryGetProperty("fps",          out var fp)) Fps         = fp.GetInt32();
        if (el.TryGetProperty("running",      out var r))  Running     = r.GetBoolean();
        if (el.TryGetProperty("present",      out var pr)) Present     = pr.GetBoolean();
        if (el.TryGetProperty("enabled",      out var en)) Enabled     = en.GetBoolean();
        if (el.TryGetProperty("pid",          out var pi)) Pid         = pi.GetUInt32();
        if (el.TryGetProperty("restarts",     out var rs)) Restarts    = rs.GetInt32();
        if (el.TryGetProperty("viewer_count", out var vc)) ViewerCount    = vc.GetInt32();
        if (el.TryGetProperty("viewer_user", out var vu))  ViewerUser     = vu.GetString() ?? "";
        if (el.TryGetProperty("viewer_pass", out var vp))  ViewerPassword = vp.GetString() ?? "";
        if (el.TryGetProperty("advertised_formats", out var af) && af.ValueKind == JsonValueKind.Array)
        {
            var parsed = new List<AdvertisedFormat>(af.GetArrayLength());
            foreach (var item in af.EnumerateArray())
            {
                parsed.Add(new AdvertisedFormat(
                    Kind:   item.TryGetProperty("kind",    out var k)  ? (k.GetString() ?? "") : "",
                    Codec:  item.TryGetProperty("codec",   out var c)  ? (c.GetString() ?? "") : "",
                    PixFmt: item.TryGetProperty("pix_fmt", out var pf) ? (pf.GetString() ?? "") : "",
                    Width:  item.TryGetProperty("width",   out var fw) ? fw.GetInt32() : 0,
                    Height: item.TryGetProperty("height",  out var fh) ? fh.GetInt32() : 0,
                    MinFps: item.TryGetProperty("min_fps", out var mn) ? mn.GetDouble() : 0,
                    MaxFps: item.TryGetProperty("max_fps", out var mx) ? mx.GetDouble() : 0));
            }
            // Only replace + signal if the list actually changed; avoids
            // tearing the bound dropdown on every list-cameras refresh.
            if (!FormatListsEqual(_advertisedFormats, parsed))
            {
                _advertisedFormats = parsed;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AdvertisedFormats)));
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AvailableResolutions)));
            }
        }
    }

    private static bool FormatListsEqual(IReadOnlyList<AdvertisedFormat> a, IReadOnlyList<AdvertisedFormat> b)
    {
        if (a.Count != b.Count) return false;
        for (int i = 0; i < a.Count; i++) if (!Equals(a[i], b[i])) return false;
        return true;
    }
}
