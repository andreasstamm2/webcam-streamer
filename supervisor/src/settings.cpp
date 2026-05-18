#include "settings.h"
#include "logging.h"
#include "nlohmann/json.hpp"

#include <fstream>
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
    } catch (const std::exception& e) {
        Warn(std::string("settings.json parse error (using defaults): ") + e.what());
    }
    return s;
}

}  // namespace ws
