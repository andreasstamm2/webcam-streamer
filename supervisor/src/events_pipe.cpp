#include "events_pipe.h"
#include "logging.h"
#include "strings.h"

#include <chrono>

namespace ws {

EventsPipeServer::EventsPipeServer(std::wstring pipe_name, LineHandler h)
    : pipe_name_(std::move(pipe_name)), handler_(std::move(h)) {}

EventsPipeServer::~EventsPipeServer() { Stop(); }

void EventsPipeServer::Start() {
    if (thread_.joinable()) return;
    thread_ = std::thread([this] { AcceptLoop(); });
}

void EventsPipeServer::Stop() {
    if (!thread_.joinable()) return;
    stop_.store(true);

    // Cancel any blocking ConnectNamedPipe / ReadFile in flight on the
    // accept thread (same idiom as ipc_server's Stop()).
    HANDLE th = (HANDLE)thread_.native_handle();
    if (th) CancelSynchronousIo(th);
    {
        std::lock_guard<std::mutex> g(mu_);
        if (current_pipe_ != INVALID_HANDLE_VALUE) {
            CloseHandle(current_pipe_);
            current_pipe_ = INVALID_HANDLE_VALUE;
        }
    }
    thread_.join();
}

void EventsPipeServer::AcceptLoop() {
    using namespace std::chrono_literals;
    Info("events-pipe: serving on " + WideToUtf8(pipe_name_));
    while (!stop_.load()) {
        HANDLE p = CreateNamedPipeW(
            pipe_name_.c_str(),
            PIPE_ACCESS_INBOUND,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            0, 4096,                       // out (unused, inbound-only) / in buffer
            0, nullptr);
        if (p == INVALID_HANDLE_VALUE) {
            DWORD err = GetLastError();
            Error("events-pipe: CreateNamedPipe failed err=" + std::to_string(err));
            std::this_thread::sleep_for(1s);
            continue;
        }
        {
            std::lock_guard<std::mutex> g(mu_);
            if (stop_.load()) { CloseHandle(p); return; }
            current_pipe_ = p;
        }

        BOOL connected = ConnectNamedPipe(p, nullptr) ? TRUE :
                         (GetLastError() == ERROR_PIPE_CONNECTED);
        if (stop_.load()) {
            std::lock_guard<std::mutex> g(mu_);
            if (current_pipe_ != INVALID_HANDLE_VALUE) {
                CloseHandle(current_pipe_);
                current_pipe_ = INVALID_HANDLE_VALUE;
            }
            return;
        }
        if (!connected) {
            std::lock_guard<std::mutex> g(mu_);
            CloseHandle(p);
            current_pipe_ = INVALID_HANDLE_VALUE;
            continue;
        }
        // Read one line. Helper writes <json>\n and disconnects.
        std::string line;
        char buf[256];
        bool got_newline = false;
        while (!got_newline && !stop_.load()) {
            DWORD n = 0;
            BOOL ok = ReadFile(p, buf, (DWORD)sizeof(buf), &n, nullptr);
            if (!ok || n == 0) break;
            for (DWORD i = 0; i < n; ++i) {
                char c = buf[i];
                if (c == '\n') { got_newline = true; break; }
                if (c == '\r') continue;
                line.push_back(c);
                if (line.size() > 64 * 1024) { got_newline = true; break; }  // sanity
            }
        }

        if (!line.empty()) {
            try {
                auto j = nlohmann::json::parse(line);
                handler_(j);
            } catch (const std::exception& e) {
                Warn(std::string("events-pipe: bad JSON from hook: ") + e.what());
            }
        }

        DisconnectNamedPipe(p);
        {
            std::lock_guard<std::mutex> g(mu_);
            if (current_pipe_ != INVALID_HANDLE_VALUE) {
                CloseHandle(current_pipe_);
                current_pipe_ = INVALID_HANDLE_VALUE;
            }
        }
    }
}

}  // namespace ws
