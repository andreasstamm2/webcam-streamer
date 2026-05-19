namespace WebcamStreamerUi;

// User-facing display ("transcode MJPEG->H.264") + the wire value the
// supervisor's set-mode IPC expects ("transcode_mjpeg_to_h264"). The two
// pass-through modes and the raw-to-mjpeg mode are deliberately hidden:
// they are documented-broken (passthrough on real cams) or pointless
// (raw_to_mjpeg defeats the purpose of transcoding). The supervisor
// silently coerces unsupported override-file values to MJPEG->H.264 on
// load.
public sealed record ModeOption(string Display, string Value);

public static class Modes
{
    public static IReadOnlyList<ModeOption> All { get; } = new[]
    {
        new ModeOption("transcode MJPEG->H.264", "transcode_mjpeg_to_h264"),
        new ModeOption("transcode RAW->H.264",   "transcode_raw_to_h264"),
    };

    // Lookups by either side, for binding the ComboBox SelectedItem to the
    // CameraInfo.Mode wire string.
    public static ModeOption? ByValue(string value) =>
        All.FirstOrDefault(m => m.Value == value);
}

// Common cam resolutions. Operator picks one; tool sends as set-mode params
// with width/height. Cam must actually advertise the chosen mode-format at
// the chosen resolution; otherwise ffmpeg fails to open input and the cam
// goes into restart-loop -- in that case revert via the Mode dropdown.
public static class Resolutions
{
    public static IReadOnlyList<string> All { get; } = new[]
    {
        "320x240",
        "640x360",
        "640x480",
        "960x540",
        "1280x720",
        "1920x1080",
    };
}
