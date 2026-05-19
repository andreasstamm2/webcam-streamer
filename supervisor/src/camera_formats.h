#pragma once
#include <filesystem>
#include <string>
#include <vector>

namespace ws {

// One row from `ffmpeg -list_options` for a DirectShow video device.
// FFmpeg emits two distinct line shapes per cam:
//   vcodec=mjpeg     min s=1280x720 fps=5 max s=1280x720 fps=30
//   pixel_format=yuyv422 min s=1280x720 fps=5 max s=1280x720 fps=30
// "compressed" = the first shape (codec is mjpeg/h264/...);
// "raw"        = the second shape (pix_fmt is yuyv422/nv12/...).
// One of {codec, pix_fmt} is set, the other is empty.
struct AdvertisedFormat {
    std::string kind;       // "compressed" or "raw"
    std::string codec;      // when kind=="compressed"
    std::string pix_fmt;    // when kind=="raw"
    int         width  = 0;
    int         height = 0;
    double      min_fps = 0;
    double      max_fps = 0;
};

// Run `ffmpeg -hide_banner -f dshow -list_options true -i video=<name>` and
// parse the advertised format table. ffmpeg exits non-zero on -list_options
// (it prints, then errors); we ignore the exit code and parse stderr.
// Takes ~0.5--1.5s per camera; intended to be called once per cam on initial
// enumeration and on each hot-add (in a worker thread if it would block the
// supervision loop).
std::vector<AdvertisedFormat> EnumerateFormats(const std::filesystem::path& ffmpegExe,
                                                const std::wstring&         cam_name);

}  // namespace ws
