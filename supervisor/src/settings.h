#pragma once
#include <filesystem>
#include <string>

namespace ws {

// Persistent app-wide settings. File: <data_root>/settings.json.
//
// Two parties touch this file:
//   - The WPF host app, which owns most writes (notifications, autostart,
//     default-enabled-for-new-cameras, and now viewer credentials).
//   - The supervisor, which previously only read. As of v0.3 it also
//     writes IFF viewer_user / viewer_pass are empty on startup (the
//     "first run" case for installs that pre-date the credentials feature)
//     -- otherwise it leaves the file alone and the WPF Security section
//     drives changes via the set-viewer-credentials IPC.
struct Settings {
    // Initial `enabled` value for any camera the supervisor encounters
    // that has no prior override file.
    bool        default_enabled_for_new_cameras = true;

    // MediaMTX viewer credentials. The supervisor substitutes these into
    // the runtime mediamtx.yml at startup. Empty here = generate one on
    // first run and persist. The publisher account is hardcoded
    // (publisher/publisher, restricted to 127.0.0.1) and not surfaced.
    std::string viewer_user;
    std::string viewer_pass;
};

// Read settings.json. Returns defaults if the file is missing, unreadable,
// or malformed. Never throws.
Settings LoadSettings(const std::filesystem::path& data_root);

// Persist settings.json (merge with whatever the WPF host wrote so we
// don't clobber notifications_enabled / default_enabled_for_new_cameras
// when bumping viewer credentials). Returns false on I/O error.
bool SaveSettings(const std::filesystem::path& data_root, const Settings& s);

// 8-char random user/pass from a URL-safe alphabet. Used for first-run
// generation when settings.json arrives without credentials (e.g. an
// upgrade from a pre-v0.3 install). The installer also generates these
// at install time via the Pascal script -- this is the safety net.
std::string GenerateRandomCredential(int len = 8);

}  // namespace ws
