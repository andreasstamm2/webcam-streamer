#pragma once
#include <windows.h>

#include "nlohmann/json.hpp"

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

namespace ws {

struct IpcRequest {
    int            id = 0;
    std::string    method;
    nlohmann::json params;   // an object, possibly empty
};

struct IpcResponse {
    bool           ok = false;
    nlohmann::json result;   // any json value
    std::string    error;    // populated when ok == false
};

// Single-client newline-delimited-JSON pipe server.
//   - Server creates one pipe instance, accepts one client at a time.
//   - When client disconnects, server creates a fresh instance and waits again.
//   - Handler is invoked on the IPC thread; if it touches shared state, it must lock.
//   - PublishEvent may be called from any thread; serialized via write mutex.
class IpcServer {
public:
    using Handler = std::function<IpcResponse(const IpcRequest&)>;

    IpcServer(std::wstring pipe_name, Handler h);
    ~IpcServer();

    IpcServer(const IpcServer&)            = delete;
    IpcServer& operator=(const IpcServer&) = delete;

    void Start();
    void Stop();

    // Best-effort: drops if no client is connected.
    void PublishEvent(std::string_view name, const nlohmann::json& data);

private:
    void AcceptLoop();
    bool WritePipe(const std::string& bytes);  // takes write_mutex_

    std::wstring      pipe_name_;
    Handler           handler_;
    std::thread       thread_;
    std::atomic<bool> stop_{false};

    // Pipe state. pipe_mutex_ guards close-from-Stop racing with AcceptLoop;
    // write_mutex_ serialises all writes (responses + events).
    std::mutex pipe_mutex_;
    std::mutex write_mutex_;
    HANDLE     pipe_              = INVALID_HANDLE_VALUE;
    bool       client_connected_  = false;
};

}  // namespace ws
