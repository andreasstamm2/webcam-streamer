#include "camera_probe.h"
#include "camera_enum.h"
#include "logging.h"
#include "strings.h"

#include <fstream>
#include <sstream>
#include <iterator>

namespace ws {

std::optional<ProbeResult> LoadProbeResult(const std::filesystem::path& probesDir,
                                            std::wstring_view cam_name) {
    auto slug = SlugifyName(cam_name);
    auto path = probesDir / (slug + L".summary.txt");
    if (!std::filesystem::exists(path)) return std::nullopt;

    std::ifstream in(path);
    if (!in) return std::nullopt;

    ProbeResult r;
    r.source_path = path.wstring();

    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        auto k = line.substr(0, eq);
        auto v = line.substr(eq + 1);
        if (k == "recommended") {
            r.recommended = ModeFromString(v);
        }
    }
    return r;
}

std::optional<CameraOverride> LoadOverride(const std::filesystem::path& probesDir,
                                            std::wstring_view cam_name) {
    auto slug = SlugifyName(cam_name);
    auto path = probesDir / (slug + L".override.txt");
    if (!std::filesystem::exists(path)) return std::nullopt;
    std::ifstream in(path);
    if (!in) return std::nullopt;
    CameraOverride o;
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        auto k = line.substr(0, eq);
        auto v = line.substr(eq + 1);
        try {
            if (k == "mode")        { Mode m = ModeFromString(v); if (m != Mode::Unknown) o.mode = m; }
            else if (k == "width")  o.width  = std::stoi(v);
            else if (k == "height") o.height = std::stoi(v);
            else if (k == "fps")    o.fps    = std::stoi(v);
        } catch (...) { /* skip malformed line */ }
    }
    return o;
}

bool SaveOverride(const std::filesystem::path& probesDir,
                   std::wstring_view cam_name,
                   const CameraOverride& update) {
    auto slug = SlugifyName(cam_name);
    std::error_code ec;
    std::filesystem::create_directories(probesDir, ec);
    auto path = probesDir / (slug + L".override.txt");

    // Merge: read existing, overlay update, write back.
    CameraOverride merged;
    if (auto existing = LoadOverride(probesDir, cam_name)) merged = *existing;
    if (update.mode)   merged.mode   = update.mode;
    if (update.width)  merged.width  = update.width;
    if (update.height) merged.height = update.height;
    if (update.fps)    merged.fps    = update.fps;

    std::ofstream out(path, std::ios::trunc);
    if (!out) return false;
    out << "camera=" << WideToUtf8(cam_name) << "\n";
    if (merged.mode)   out << "mode="   << ModeName(*merged.mode) << "\n";
    if (merged.width)  out << "width="  << *merged.width   << "\n";
    if (merged.height) out << "height=" << *merged.height  << "\n";
    if (merged.fps)    out << "fps="    << *merged.fps     << "\n";
    return out.good();
}

std::optional<nlohmann::json> LoadProbeJson(const std::filesystem::path& probesDir,
                                             std::wstring_view cam_name) {
    auto slug = SlugifyName(cam_name);
    auto path = probesDir / (slug + L".json");
    if (!std::filesystem::exists(path)) return std::nullopt;
    std::ifstream in(path);
    if (!in) return std::nullopt;
    std::string s((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    try { return nlohmann::json::parse(s); }
    catch (...) { return std::nullopt; }
}

}  // namespace ws
