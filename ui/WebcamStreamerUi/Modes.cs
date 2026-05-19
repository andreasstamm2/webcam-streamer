namespace WebcamStreamerUi;

// Canonical list of modes the supervisor accepts. Keep in sync with
// supervisor/src/camera_config.cpp (ModeFromString) and probe-camera.ps1.
public static class Modes
{
    public static IReadOnlyList<string> All { get; } = new[]
    {
        "passthrough_mjpeg",
        "passthrough_h264",
        "transcode_mjpeg_to_h264",
        "transcode_raw_to_h264",
        "transcode_raw_to_mjpeg",
    };
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
