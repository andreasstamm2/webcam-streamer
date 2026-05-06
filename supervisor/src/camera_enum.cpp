#include "camera_enum.h"
#include "run_command.h"
#include "logging.h"
#include "strings.h"

#include <regex>
#include <algorithm>
#include <cwctype>

namespace ws {

namespace {

// FFmpeg writes device list to stderr in this shape (one entry per device):
//   [in#0 @ 0x...] "Logitech BRIO" (video)
//   [in#0 @ 0x...]   Alternative name "@device_pnp_..."
// In ffmpeg >= ~7 the explicit "DirectShow video devices" header is no longer
// emitted at default loglevel. The "(video)" / "(audio)" / "(none)" suffix is
// unambiguous, so we match on that directly.
std::vector<std::wstring> ParseFfmpegDshowList(const std::string& stderr_text) {
    static const std::regex device(R"(\"([^\"]+)\"\s*\(video\))");
    std::vector<std::wstring> out;
    std::istringstream iss(stderr_text);
    for (std::string line; std::getline(iss, line); ) {
        std::smatch m;
        if (std::regex_search(line, m, device)) {
            out.push_back(Utf8ToWide(m[1].str()));
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

std::vector<std::wstring> EnumerateCameras(const std::filesystem::path& ffmpegExe) {
    auto r = RunCommand(ffmpegExe.wstring(),
                         { L"-hide_banner", L"-f", L"dshow",
                           L"-list_devices", L"true", L"-i", L"dummy" },
                         15000);
    // ffmpeg always exits non-zero on -list_devices (it's printing then erroring),
    // so don't treat that as failure. Just parse stderr.
    auto names = ParseFfmpegDshowList(r.stderr_text);
    if (names.empty()) {
        Debug("ffmpeg -list_devices stderr (" +
              std::to_string(r.stderr_text.size()) + " bytes), first 800 chars:");
        Debug(r.stderr_text.substr(0, 800));
    }

    std::vector<std::wstring> filtered;
    for (auto& n : names) {
        if (IsBlacklisted(n)) {
            Info("skipping virtual cam: " + WideToUtf8(n));
            continue;
        }
        filtered.push_back(n);
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
