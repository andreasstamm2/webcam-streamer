#pragma once
#include <string>
#include <vector>
#include <filesystem>

namespace ws {

// Enumerate DirectShow video input devices visible to FFmpeg.
// Returns friendly names (e.g. "Logitech BRIO"). Filters out obvious virtual cams.
std::vector<std::wstring> EnumerateCameras(const std::filesystem::path& ffmpegExe);

// Slugify a camera name for use in filenames (e.g. "HP 5MP Camera" -> "HP-5MP-Camera").
std::wstring SlugifyName(std::wstring_view name);

}  // namespace ws
