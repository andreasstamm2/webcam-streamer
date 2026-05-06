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
