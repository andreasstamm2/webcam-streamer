#pragma once
#include <string>
#include <vector>

namespace ws {

struct CommandResult {
    bool        ok        = false;   // true iff process started AND exit_code == 0
    int         exit_code = -1;      // -1 if process didn't start
    std::string stdout_text;
    std::string stderr_text;
};

// Synchronously run a command, capturing stdout and stderr.
// `timeout_ms` is total wall-clock; 0 = wait forever.
CommandResult RunCommand(const std::wstring&              exe,
                         const std::vector<std::wstring>& args,
                         unsigned                         timeout_ms = 0);

}  // namespace ws
