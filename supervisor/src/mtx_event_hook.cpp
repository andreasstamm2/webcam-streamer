// mtx_event_hook.cpp
//
// Tiny helper binary invoked by MediaMTX's runOnRead / runOnUnread hooks.
// Reads the MTX_* environment variables MediaMTX sets per hook invocation,
// connects to \\.\pipe\webcam-streamer-events (the supervisor's one-way
// events pipe), writes one JSON line describing the event, exits.
//
// Best-effort: if the supervisor isn't up or the pipe isn't available, we
// exit silently. The hook is informational, not part of the streaming path.
//
// Usage:   mtx_event_hook.exe {read|unread}

#include <windows.h>
#include <string>

namespace {

std::string GetEnv(const char* name) {
    char buf[1024];
    DWORD n = GetEnvironmentVariableA(name, buf, (DWORD)sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return {};
    return std::string(buf, n);
}

// Minimal JSON string escape: quote + backslash. MediaMTX's MTX_* vars are
// limited to ASCII-printable paths/IPs/usernames in practice; we don't need
// the full control-char escape table.
std::string JsonEsc(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    for (char c : s) {
        if (c == '"' || c == '\\') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    const char* event_type = (argc >= 2) ? argv[1] : "read";

    std::string path        = GetEnv("MTX_PATH");
    std::string reader_type = GetEnv("MTX_READER_TYPE");
    // MediaMTX 1.18.x exposes the reader as a single MTX_READER_ID = "ip:port"
    // string (it does NOT split into separate IP/port env vars). Earlier docs
    // suggested MTX_READER_IP/PORT but those are not actually set today --
    // keep them as best-effort fallbacks for future MediaMTX versions.
    std::string reader_id   = GetEnv("MTX_READER_ID");
    std::string reader_ip   = GetEnv("MTX_READER_IP");
    std::string reader_port = GetEnv("MTX_READER_PORT");
    std::string reader_user = GetEnv("MTX_READER_USER");
    std::string query       = GetEnv("MTX_QUERY");

    // If MTX_READER_ID is set ("ip:port") but the split vars aren't, derive
    // them. Split on the LAST colon to handle IPv6 (e.g. "[::1]:51234").
    if (reader_ip.empty() && !reader_id.empty()) {
        auto pos = reader_id.find_last_of(':');
        if (pos != std::string::npos) {
            reader_ip   = reader_id.substr(0, pos);
            reader_port = reader_id.substr(pos + 1);
            // Strip brackets around IPv6 literals: "[::1]" -> "::1".
            if (reader_ip.size() >= 2 && reader_ip.front() == '[' && reader_ip.back() == ']') {
                reader_ip = reader_ip.substr(1, reader_ip.size() - 2);
            }
        } else {
            reader_ip = reader_id;
        }
    }

    std::string line = "{";
    line += "\"event\":\""        + JsonEsc(event_type)   + "\",";
    line += "\"path\":\""         + JsonEsc(path)         + "\",";
    line += "\"reader_id\":\""    + JsonEsc(reader_id)    + "\",";
    line += "\"reader_ip\":\""    + JsonEsc(reader_ip)    + "\",";
    line += "\"reader_port\":\""  + JsonEsc(reader_port)  + "\",";
    line += "\"reader_user\":\""  + JsonEsc(reader_user)  + "\",";
    line += "\"reader_type\":\""  + JsonEsc(reader_type)  + "\",";
    line += "\"query\":\""        + JsonEsc(query)        + "\"";
    line += "}\n";

    const wchar_t* pipe_name = L"\\\\.\\pipe\\webcam-streamer-events";

    // Best-effort connect with a short retry loop -- the supervisor may
    // momentarily be between Accept() and the next CreateNamedPipe instance.
    HANDLE pipe = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 20; ++attempt) {
        pipe = CreateFileW(pipe_name, GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) break;
        DWORD err = GetLastError();
        if (err == ERROR_PIPE_BUSY) {
            WaitNamedPipeW(pipe_name, 100);
            continue;
        }
        if (err == ERROR_FILE_NOT_FOUND) {
            // Pipe doesn't exist yet -- supervisor probably isn't up.
            Sleep(50);
            continue;
        }
        break;
    }
    if (pipe == INVALID_HANDLE_VALUE) {
        // Supervisor probably not running; silently drop the event.
        return 0;
    }

    DWORD written = 0;
    WriteFile(pipe, line.data(), (DWORD)line.size(), &written, nullptr);
    FlushFileBuffers(pipe);
    CloseHandle(pipe);
    return 0;
}
