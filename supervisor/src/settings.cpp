#include "settings.h"
#include "logging.h"
#include "nlohmann/json.hpp"

#include <fstream>
#include <random>
#include <sstream>

namespace ws {

Settings LoadSettings(const std::filesystem::path& data_root) {
    Settings s;
    auto path = data_root / "settings.json";
    if (!std::filesystem::exists(path)) return s;
    std::ifstream in(path);
    if (!in) {
        Warn("settings.json exists but could not be opened: " + path.string());
        return s;
    }
    std::stringstream buf;
    buf << in.rdbuf();
    try {
        auto j = nlohmann::json::parse(buf.str());
        if (auto it = j.find("default_enabled_for_new_cameras");
            it != j.end() && it->is_boolean()) {
            s.default_enabled_for_new_cameras = it->get<bool>();
        }
        if (auto it = j.find("viewer_user");
            it != j.end() && it->is_string()) {
            s.viewer_user = it->get<std::string>();
        }
        if (auto it = j.find("viewer_pass");
            it != j.end() && it->is_string()) {
            s.viewer_pass = it->get<std::string>();
        }
    } catch (const std::exception& e) {
        Warn(std::string("settings.json parse error (using defaults): ") + e.what());
    }
    return s;
}

bool SaveSettings(const std::filesystem::path& data_root, const Settings& s) {
    // Read-modify-write: load the raw JSON first so we preserve any keys
    // the WPF host wrote that the supervisor doesn't know about
    // (notifications_enabled today, possibly others in the future). Only
    // touch the fields we own.
    auto path = data_root / "settings.json";
    nlohmann::json j = nlohmann::json::object();
    if (std::filesystem::exists(path)) {
        std::ifstream in(path);
        if (in) {
            std::stringstream buf;
            buf << in.rdbuf();
            try { j = nlohmann::json::parse(buf.str()); }
            catch (...) { j = nlohmann::json::object(); }
            if (!j.is_object()) j = nlohmann::json::object();
        }
    }

    j["default_enabled_for_new_cameras"] = s.default_enabled_for_new_cameras;
    j["viewer_user"]                     = s.viewer_user;
    j["viewer_pass"]                     = s.viewer_pass;

    std::error_code ec;
    std::filesystem::create_directories(data_root, ec);
    std::ofstream out(path, std::ios::trunc);
    if (!out) {
        Error("could not write settings.json: " + path.string());
        return false;
    }
    out << j.dump(2);
    return true;
}

std::string GenerateRandomCredential(int len) {
    // URL-safe alphabet (RFC 3986 unreserved subset + a couple of safe
    // specials). Avoiding ':' '/' '@' '?' '#' '[' ']' keeps the rtsp URL
    // syntactically valid without percent-encoding -- the "Copy URL"
    // button can emit user/pass verbatim.
    static const char kAlphabet[] =
        "abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789"
        "-._~";
    static const int kAlphaLen = (int)(sizeof(kAlphabet) - 1);
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> dist(0, kAlphaLen - 1);
    std::string out;
    out.reserve(len);
    for (int i = 0; i < len; ++i) out.push_back(kAlphabet[dist(gen)]);
    return out;
}

}  // namespace ws
