#include "known_cameras.h"
#include "logging.h"
#include "nlohmann/json.hpp"

#include <fstream>

namespace ws {

bool KnownCameraDb::Load(const std::filesystem::path& jsonPath) {
    entries_.clear();
    if (!std::filesystem::exists(jsonPath)) {
        Info("known-cameras: no DB at " + jsonPath.string() + " (0 entries)");
        return true;   // not an error; just an empty DB
    }
    std::ifstream in(jsonPath);
    if (!in) {
        Warn("known-cameras: could not open " + jsonPath.string());
        return false;
    }
    nlohmann::json j;
    try { in >> j; }
    catch (const std::exception& e) {
        Warn("known-cameras: invalid JSON in " + jsonPath.string() + ": " + e.what());
        return false;
    }
    auto cams = j.find("cameras");
    if (cams == j.end() || !cams->is_object()) {
        Warn("known-cameras: missing or non-object 'cameras' field");
        return false;
    }
    for (auto& [key, val] : cams->items()) {
        // key is "vvvv:pppp" lowercased hex; tolerate uppercase by normalising.
        std::string k = key;
        for (auto& c : k) c = (char)std::tolower((unsigned char)c);
        KnownCamera kc;
        kc.label  = val.value("label",  std::string{});
        kc.mode   = ModeFromString(val.value("mode", std::string{"transcode_mjpeg_to_h264"}));
        kc.width  = val.value("width",  1280);
        kc.height = val.value("height", 720);
        kc.fps    = val.value("fps",    30);
        if (kc.mode == Mode::Unknown) {
            Warn("known-cameras: '" + k + "' has unknown mode; skipping");
            continue;
        }
        entries_[k] = std::move(kc);
    }
    Info("known-cameras: loaded " + std::to_string(entries_.size()) +
         " entries from " + jsonPath.string());
    return true;
}

std::optional<KnownCamera> KnownCameraDb::Lookup(const std::string& vid_pid) const {
    auto it = entries_.find(vid_pid);
    if (it == entries_.end()) return std::nullopt;
    return it->second;
}

}  // namespace ws
