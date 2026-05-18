#pragma once
#include <filesystem>

namespace ws {

// Persistent app-wide settings, owned by the host app on disk.
// File: <data_root>/settings.json. Missing file / missing key = sensible
// default. The supervisor reads this file at startup (and on demand via the
// `reload-settings` IPC method); it never writes to it.
struct Settings {
    // Initial `enabled` value for any camera the supervisor encounters
    // that has no prior override file. Set by the installer's
    // "Stream all webcams by default" checkbox, editable later from
    // the WPF UI. Default true (matches pre-Slice-A behaviour: every
    // camera publishes unconditionally).
    bool default_enabled_for_new_cameras = true;
};

// Read settings.json from `data_root/settings.json`. Returns sensible
// defaults if the file is missing, unreadable, or malformed. Never throws.
Settings LoadSettings(const std::filesystem::path& data_root);

}  // namespace ws
