#include "camera_formats.h"
#include "run_command.h"
#include "logging.h"
#include "strings.h"

#include <regex>
#include <sstream>
#include <set>
#include <tuple>

namespace ws {

namespace {

// Matches the two ffmpeg -list_options line shapes. Anchored on the first
// space-separated token (vcodec=... or pixel_format=...) followed by the
// "min s=WxH fps=N max s=WxH fps=N" tail.
//
// Real-world lines have a "[dshow @ 0x...]" prefix at default loglevel; we
// match anywhere on the line so the prefix doesn't matter.
const std::regex kCompressedRe(
    R"(vcodec=(\S+)\s+min\s+s=(\d+)x(\d+)\s+fps=([\d.]+)\s+max\s+s=(\d+)x(\d+)\s+fps=([\d.]+))");
const std::regex kRawRe(
    R"(pixel_format=(\S+)\s+min\s+s=(\d+)x(\d+)\s+fps=([\d.]+)\s+max\s+s=(\d+)x(\d+)\s+fps=([\d.]+))");

}  // namespace

std::vector<AdvertisedFormat>
EnumerateFormats(const std::filesystem::path& ffmpegExe, const std::wstring& cam_name) {
    // Quote the device name so cams with spaces ("HP 5MP Camera") work.
    auto r = RunCommand(ffmpegExe.wstring(),
                         { L"-hide_banner",
                           L"-f", L"dshow",
                           L"-list_options", L"true",
                           L"-i", L"video=" + cam_name },
                         15000);

    // ffmpeg always exits non-zero on -list_options. We don't check exit_code;
    // we just parse stderr.
    std::vector<AdvertisedFormat> out;
    std::istringstream iss(r.stderr_text);
    for (std::string line; std::getline(iss, line); ) {
        std::smatch m;
        if (std::regex_search(line, m, kCompressedRe)) {
            AdvertisedFormat f;
            f.kind    = "compressed";
            f.codec   = m[1].str();
            f.width   = std::stoi(m[2].str());
            f.height  = std::stoi(m[3].str());
            f.min_fps = std::stod(m[4].str());
            f.max_fps = std::stod(m[7].str());
            out.push_back(std::move(f));
        } else if (std::regex_search(line, m, kRawRe)) {
            AdvertisedFormat f;
            f.kind    = "raw";
            f.pix_fmt = m[1].str();
            f.width   = std::stoi(m[2].str());
            f.height  = std::stoi(m[3].str());
            f.min_fps = std::stod(m[4].str());
            f.max_fps = std::stod(m[7].str());
            out.push_back(std::move(f));
        }
    }

    // ffmpeg often repeats the same (kind, codec/pix_fmt, w, h) at multiple
    // fps caps. Dedupe so the UI dropdown isn't littered with copies.
    std::sort(out.begin(), out.end(), [](const AdvertisedFormat& a, const AdvertisedFormat& b) {
        return std::tie(a.kind, a.codec, a.pix_fmt, a.width, a.height) <
               std::tie(b.kind, b.codec, b.pix_fmt, b.width, b.height);
    });
    out.erase(std::unique(out.begin(), out.end(),
        [](const AdvertisedFormat& a, const AdvertisedFormat& b) {
            return a.kind == b.kind && a.codec == b.codec && a.pix_fmt == b.pix_fmt &&
                   a.width == b.width && a.height == b.height;
        }), out.end());

    if (out.empty()) {
        Debug("ffmpeg -list_options for '" + WideToUtf8(cam_name) +
              "': 0 formats parsed (stderr " + std::to_string(r.stderr_text.size()) +
              " bytes). First 400 chars:");
        Debug(r.stderr_text.substr(0, 400));
    } else {
        Info("cam '" + WideToUtf8(cam_name) + "' advertises " +
             std::to_string(out.size()) + " distinct (kind,codec,resolution) tuples");
    }
    return out;
}

}  // namespace ws
