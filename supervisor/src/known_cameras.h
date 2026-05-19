#pragma once
#include "camera_config.h"
#include <filesystem>
#include <optional>
#include <string>
#include <unordered_map>

namespace ws {

// One known-good camera profile. Source: config/known-cameras.json, keyed
// by USB "vendor:product" (lowercased 4-digit hex, e.g. "046d:085e"). The
// supervisor applies this when discovering a cam with no user override.
struct KnownCamera {
    std::string  label;       // human-readable, e.g. "Logitech BRIO" -- for logs
    Mode         mode = Mode::TranscodeMjpegToH264;
    int          width  = 1280;
    int          height = 720;
    int          fps    = 30;
};

class KnownCameraDb {
public:
    // Load from `jsonPath` (typically `<root>/config/known-cameras.json`).
    // Missing file is not an error -- the DB simply contains zero entries
    // and Lookup() returns nullopt for everything. Parse errors are logged
    // and treated as missing.
    bool Load(const std::filesystem::path& jsonPath);

    // Lookup by "vvvv:pppp" (case-sensitive lowercased hex). Returns
    // std::nullopt if no entry matches.
    std::optional<KnownCamera> Lookup(const std::string& vid_pid) const;

    size_t Size() const { return entries_.size(); }

private:
    std::unordered_map<std::string, KnownCamera> entries_;
};

}  // namespace ws
