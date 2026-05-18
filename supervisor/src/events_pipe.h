#pragma once
#include <windows.h>

#include "nlohmann/json.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace ws {

// One-way pipe server for the viewer-events channel
// (\\.\pipe\webcam-streamer-events). Accepts a series of short connections
// from mtx_event_hook.exe; each connection writes one JSON line and closes.
// The supplied handler is invoked on the accept thread with the parsed JSON.
//
// This is intentionally distinct from the control pipe (IpcServer): the
// events pipe is inbound-only, has many short-lived clients, and never sends
// a response.
class EventsPipeServer {
public:
    using LineHandler = std::function<void(const nlohmann::json&)>;

    EventsPipeServer(std::wstring pipe_name, LineHandler h);
    ~EventsPipeServer();

    EventsPipeServer(const EventsPipeServer&)            = delete;
    EventsPipeServer& operator=(const EventsPipeServer&) = delete;

    void Start();
    void Stop();

private:
    void AcceptLoop();

    std::wstring      pipe_name_;
    LineHandler       handler_;
    std::thread       thread_;
    std::atomic<bool> stop_{false};

    std::mutex mu_;
    HANDLE     current_pipe_ = INVALID_HANDLE_VALUE;
};

}  // namespace ws
