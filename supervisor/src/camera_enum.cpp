#include "camera_enum.h"
#include "run_command.h"
#include "logging.h"
#include "strings.h"

#include <regex>
#include <algorithm>
#include <cwctype>

namespace ws {

namespace {

// FFmpeg writes device list to stderr in this shape (devices interleaved
// across video and audio sections at default loglevel since ffmpeg >= ~7):
//   [in#0 @ 0x...] "HP 5MP Camera"      (video)
//   [in#0 @ 0x...]   Alternative name   "@device_pnp_\\?\usb#vid_XXXX&pid_YYYY..."
//   [in#0 @ 0x...] "Microphone (HP)"    (audio)
//   [in#0 @ 0x...]   Alternative name   "@device_cm_{...}\wave_{...}"
//
// We push video devices to `out` but skip audio. The "Alternative name"
// line ALWAYS belongs to the most-recently-declared device of ANY kind --
// not just the most recent video. So we track `lastWasVideo`: only attach
// an alt_name when the previous device line was a video. Otherwise an
// audio device's wave_-suffixed alt_name would clobber the preceding
// camera's USB path and we'd lose the vid:pid extraction.
std::vector<CameraDevice> ParseFfmpegDshowList(const std::string& stderr_text) {
    static const std::regex devAnyRe (R"(\"([^\"]+)\"\s*\((video|audio|none)\))");
    static const std::regex altRe    (R"(Alternative name\s+\"([^\"]+)\")");
    std::vector<CameraDevice> out;
    bool lastWasVideo = false;
    std::istringstream iss(stderr_text);
    for (std::string line; std::getline(iss, line); ) {
        std::smatch m;
        if (std::regex_search(line, m, devAnyRe)) {
            std::string kind = m[2].str();
            if (kind == "video") {
                CameraDevice d;
                d.friendly_name = Utf8ToWide(m[1].str());
                out.push_back(std::move(d));
                lastWasVideo = true;
            } else {
                // audio/none: don't push, and don't let its alt_name attach
                // to the previous video device.
                lastWasVideo = false;
            }
        } else if (lastWasVideo && !out.empty() && std::regex_search(line, m, altRe)) {
            out.back().alt_name = Utf8ToWide(m[1].str());
            // First alt-name wins; ignore any subsequent alt-name lines
            // until the next device declaration. Defensive -- ffmpeg only
            // emits one alt-name per device today.
            lastWasVideo = false;
        }
    }
    return out;
}

bool IsBlacklisted(const std::wstring& name) {
    std::wstring lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                    [](wchar_t c) { return (wchar_t)std::towlower(c); });
    return lower.find(L"virtual") != std::wstring::npos;
}

}  // namespace

std::string ExtractVidPid(std::wstring_view alt_name) {
    // Pattern: "vid_XXXX&pid_YYYY" (4 hex digits each, case-insensitive).
    // The full DirectShow path looks like:
    //   @device_pnp_\\?\usb#vid_046d&pid_085e&mi_00#7&...&global
    // For non-USB cams (firewire, virtual) the pattern may not exist, in
    // which case we return an empty string and the caller falls through to
    // friendly-name-based logic.
    static const std::wregex pat(LR"([vV][iI][dD]_([0-9a-fA-F]{4})&[pP][iI][dD]_([0-9a-fA-F]{4}))");
    std::wsmatch m;
    std::wstring s(alt_name);
    if (!std::regex_search(s, m, pat)) return {};
    auto lower = [](std::wstring w) {
        std::transform(w.begin(), w.end(), w.begin(),
                       [](wchar_t c) { return (wchar_t)std::towlower(c); });
        return w;
    };
    std::wstring vp = lower(m[1].str()) + L":" + lower(m[2].str());
    return WideToUtf8(vp);
}

std::vector<CameraDevice> EnumerateCameras(const std::filesystem::path& ffmpegExe) {
    auto r = RunCommand(ffmpegExe.wstring(),
                         { L"-hide_banner", L"-f", L"dshow",
                           L"-list_devices", L"true", L"-i", L"dummy" },
                         15000);
    // ffmpeg always exits non-zero on -list_devices (it's printing then erroring),
    // so don't treat that as failure. Just parse stderr.
    auto devices = ParseFfmpegDshowList(r.stderr_text);
    if (devices.empty()) {
        Debug("ffmpeg -list_devices stderr (" +
              std::to_string(r.stderr_text.size()) + " bytes), first 800 chars:");
        Debug(r.stderr_text.substr(0, 800));
    }

    std::vector<CameraDevice> filtered;
    for (auto& d : devices) {
        if (IsBlacklisted(d.friendly_name)) {
            Info("skipping virtual cam: " + WideToUtf8(d.friendly_name));
            continue;
        }
        d.vid_pid = ExtractVidPid(d.alt_name);
        filtered.push_back(std::move(d));
    }
    return filtered;
}

std::wstring SlugifyName(std::wstring_view name) {
    std::wstring out;
    out.reserve(name.size());
    bool prevDash = false;
    for (wchar_t c : name) {
        bool alnum = (c >= L'a' && c <= L'z') ||
                     (c >= L'A' && c <= L'Z') ||
                     (c >= L'0' && c <= L'9');
        if (alnum) { out.push_back(c); prevDash = false; }
        else if (!prevDash) { out.push_back(L'-'); prevDash = true; }
    }
    while (!out.empty() && out.back() == L'-') out.pop_back();
    return out;
}

}  // namespace ws
