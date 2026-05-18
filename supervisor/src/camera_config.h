#pragma once
#include <string>
#include <vector>

namespace ws {

enum class Mode {
    PassthroughMjpeg,
    PassthroughH264,
    TranscodeMjpegToH264,
    TranscodeRawToH264,
    TranscodeRawToMjpeg,
    Unknown,
};

const char* ModeName(Mode m);
Mode        ModeFromString(std::string_view s);

struct CameraConfig {
    std::wstring friendly_name;   // e.g. "Logitech BRIO"
    std::wstring rtsp_path;       // e.g. "/webcam0"
    Mode         mode = Mode::PassthroughMjpeg;
    int          width = 1280;
    int          height = 720;
    // MJPEG passthrough at 30fps is bursty (~30-50 Mbps). ffplay struggles to
    // drain TCP-interleaved RTP that fast; MediaMTX drops the tail of each
    // frame -> green bottom. 15fps halves the bandwidth and tracks well.
    // For H.264 transcode, ffplay can handle 30fps fine -- we keep 15 for
    // consistency and because 15fps is plenty for monitoring.
    int          fps = 30;
    // Whether the supervisor should spawn an ffmpeg publisher for this cam.
    // Independent of Mode: Mode is "what shape of ffmpeg args"; enabled is
    // "do we run ffmpeg at all". A cam publishes iff `present && enabled`.
    // Source priority: override file > settings.json default > true.
    bool         enabled = true;
};

// Build the FFmpeg argv for one camera publishing into MediaMTX.
std::vector<std::wstring> BuildFFmpegArgs(const CameraConfig& cam,
                                           const std::wstring& publisher_url);

}  // namespace ws
