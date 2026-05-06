#include "logging.h"
#include <chrono>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>

namespace ws {

namespace {

std::mutex& LogMutex() {
    static std::mutex m;
    return m;
}

const char* LevelStr(Level l) {
    switch (l) {
        case Level::Debug: return "DBG";
        case Level::Info:  return "INF";
        case Level::Warn:  return "WRN";
        case Level::Error: return "ERR";
    }
    return "?  ";
}

bool& DebugEnabled() { static bool b = true; return b; }

}  // namespace

void Log(Level lvl, std::string_view msg) {
    if (lvl == Level::Debug && !DebugEnabled()) return;
    auto now = std::chrono::system_clock::now();
    auto t   = std::chrono::system_clock::to_time_t(now);
    auto ms  = std::chrono::duration_cast<std::chrono::milliseconds>(
                   now.time_since_epoch()) % 1000;

    std::tm tm{};
    localtime_s(&tm, &t);

    std::ostringstream out;
    out << std::put_time(&tm, "%H:%M:%S") << '.'
        << std::setw(3) << std::setfill('0') << ms.count() << ' '
        << LevelStr(lvl) << ' ' << msg << '\n';

    std::lock_guard<std::mutex> g(LogMutex());
    std::cout << out.str() << std::flush;
}

}  // namespace ws
