#pragma once
#include "camera_config.h"
#include "nlohmann/json.hpp"
#include <filesystem>
#include <optional>
#include <string>

namespace ws {

struct ProbeResult {
    Mode         recommended = Mode::Unknown;
    std::wstring source_path;   // path of summary file we read; empty if defaults
};

// Read the probe summary text file for `cam_name` from `probesDir`.
// Format (one key=value per line):
//   recommended=passthrough_mjpeg
//   passthrough_mjpeg=ok|fail|na
//   ...
// Returns std::nullopt if the file doesn't exist.
std::optional<ProbeResult> LoadProbeResult(const std::filesystem::path& probesDir,
                                            std::wstring_view cam_name);

// Per-camera override. Each field is optional; missing fields fall back to
// the probe recommendation (for mode) or the CameraConfig defaults
// (for resolution/fps). Persisted in probesDir/<slug>.override.txt.
struct CameraOverride {
    std::optional<Mode> mode;
    std::optional<int>  width;
    std::optional<int>  height;
    std::optional<int>  fps;
};

// Read full override (mode + optional resolution + optional fps).
std::optional<CameraOverride> LoadOverride(const std::filesystem::path& probesDir,
                                            std::wstring_view cam_name);

// Merge-and-write: reads any existing override, replaces only the fields
// present in `update`, writes back. Returns false on I/O error.
bool SaveOverride(const std::filesystem::path& probesDir,
                  std::wstring_view cam_name,
                  const CameraOverride& update);

// Read the rich JSON probe report (advertised_formats, pipelines).
// Returns the parsed JSON or std::nullopt if the file doesn't exist / is invalid.
std::optional<nlohmann::json> LoadProbeJson(const std::filesystem::path& probesDir,
                                             std::wstring_view cam_name);

}  // namespace ws
