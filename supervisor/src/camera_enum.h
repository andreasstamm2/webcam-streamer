#pragma once
#include <string>
#include <vector>
#include <filesystem>

namespace ws {

// One DirectShow video device.
struct CameraDevice {
    std::wstring friendly_name;   // e.g. "Logitech BRIO"
    std::wstring alt_name;        // DirectShow device path; carries the USB
                                  // vendor/product/serial. Empty if ffmpeg's
                                  // output didn't include an "Alternative
                                  // name" line for this device.
    std::string  vid_pid;         // "vvvv:pppp" lowercased hex derived from
                                  // alt_name (e.g. "046d:085e" for a Logitech
                                  // BRIO). Empty if alt_name isn't a USB
                                  // PnP path or pattern didn't match.
};

// Enumerate DirectShow video input devices visible to FFmpeg.
// Filters out obvious virtual cams.
std::vector<CameraDevice> EnumerateCameras(const std::filesystem::path& ffmpegExe);

// Slugify a camera name for use in filenames (e.g. "HP 5MP Camera" -> "HP-5MP-Camera").
std::wstring SlugifyName(std::wstring_view name);

// Extract "vvvv:pppp" (lowercased hex) from a DirectShow Alternative-name
// device path that includes a `vid_XXXX&pid_YYYY` segment. Returns empty
// string if the pattern isn't found. Exposed so callers (and tests) can
// re-derive vid_pid from a stored alt_name without re-enumerating.
std::string ExtractVidPid(std::wstring_view alt_name);

}  // namespace ws
