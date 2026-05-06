#pragma once
#include <string>
#include <string_view>

namespace ws {

enum class Level { Debug, Info, Warn, Error };

void Log(Level lvl, std::string_view msg);

inline void Debug(std::string_view m) { Log(Level::Debug, m); }
inline void Info (std::string_view m) { Log(Level::Info,  m); }
inline void Warn (std::string_view m) { Log(Level::Warn,  m); }
inline void Error(std::string_view m) { Log(Level::Error, m); }

}
