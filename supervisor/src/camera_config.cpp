#include "camera_config.h"

namespace ws {

const char* ModeName(Mode m) {
    switch (m) {
        case Mode::PassthroughMjpeg:     return "passthrough_mjpeg";
        case Mode::PassthroughH264:      return "passthrough_h264";
        case Mode::TranscodeMjpegToH264: return "transcode_mjpeg_to_h264";
        case Mode::TranscodeRawToH264:   return "transcode_raw_to_h264";
        case Mode::TranscodeRawToMjpeg:  return "transcode_raw_to_mjpeg";
        case Mode::Unknown:              return "unknown";
    }
    return "unknown";
}

Mode ModeFromString(std::string_view s) {
    if (s == "passthrough_mjpeg")       return Mode::PassthroughMjpeg;
    if (s == "passthrough_h264")        return Mode::PassthroughH264;
    if (s == "transcode_mjpeg_to_h264") return Mode::TranscodeMjpegToH264;
    if (s == "transcode_raw_to_h264")   return Mode::TranscodeRawToH264;
    if (s == "transcode_raw_to_mjpeg")  return Mode::TranscodeRawToMjpeg;
    return Mode::Unknown;
}

std::vector<std::wstring> BuildFFmpegArgs(const CameraConfig& cam,
                                           const std::wstring& publisher_url) {
    auto wstr = [](int x) { return std::to_wstring(x); };
    std::vector<std::wstring> args = {
        L"-hide_banner", L"-loglevel", L"warning",
        L"-f", L"dshow",
    };

    // Per-mode input format selection.
    switch (cam.mode) {
        case Mode::PassthroughMjpeg:
        case Mode::TranscodeMjpegToH264:
            args.insert(args.end(), { L"-vcodec", L"mjpeg" });
            break;
        case Mode::PassthroughH264:
            args.insert(args.end(), { L"-vcodec", L"h264" });
            break;
        case Mode::TranscodeRawToH264:
        case Mode::TranscodeRawToMjpeg:
            args.insert(args.end(), { L"-pixel_format", L"yuyv422" });
            break;
        case Mode::Unknown:
            // Sensible fallback.
            args.insert(args.end(), { L"-vcodec", L"mjpeg" });
            break;
    }

    args.insert(args.end(), {
        L"-video_size", wstr(cam.width) + L"x" + wstr(cam.height),
        L"-framerate",  wstr(cam.fps),
        L"-i",          L"video=" + cam.friendly_name,
    });

    // Per-mode output codec selection.
    switch (cam.mode) {
        case Mode::PassthroughMjpeg:
        case Mode::PassthroughH264:
            args.insert(args.end(), { L"-c:v", L"copy" });
            break;
        case Mode::TranscodeMjpegToH264:
        case Mode::TranscodeRawToH264:
            args.insert(args.end(), {
                L"-c:v", L"libx264",
                L"-preset", L"ultrafast",
                L"-tune",   L"zerolatency",
                L"-pix_fmt", L"yuv420p",
                L"-g",      L"60",
                L"-bf",     L"0",
            });
            break;
        case Mode::TranscodeRawToMjpeg:
            args.insert(args.end(), {
                L"-c:v", L"mjpeg", L"-q:v", L"4", L"-pix_fmt", L"yuvj422p",
            });
            break;
        case Mode::Unknown:
            args.insert(args.end(), { L"-c:v", L"copy" });
            break;
    }

    // -max_packet_size limits the RTP packet payload. Without this, ffmpeg
    // emits ~1460-byte RTP packets, which MediaMTX then re-fragments to fit
    // its ~1440-byte limit -- and its re-fragmentation does NOT correctly
    // update the JPEG-over-RTP fragment-offset header (RFC 2435), so the
    // consumer reassembles only the first fragment per frame and the rest
    // of the JPEG is missing. Result: top of frame correct, rest green.
    // Setting 1200 keeps us well under MediaMTX's threshold so it never
    // re-fragments. Harmless for H.264 modes; required for MJPEG passthrough.
    args.insert(args.end(), {
        L"-an",
        L"-max_packet_size", L"1200",
        L"-f", L"rtsp", L"-rtsp_transport", L"tcp",
        publisher_url + cam.rtsp_path,
    });
    return args;
}

}  // namespace ws
