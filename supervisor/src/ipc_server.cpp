#include "ipc_server.h"
#include "logging.h"
#include "strings.h"

#include <chrono>
#include <thread>

namespace ws {

namespace {

// Read until '\n'. Returns empty string on disconnect/error.
// Buffered: a 4 KB chunk per ReadFile syscall instead of one byte at a time
// (large IPC payloads like list-advertised-formats can be tens of KB).
// State is per-connection-call; the AcceptLoop only ever has one ReadLine
// in flight, so a function-local buffer is wrong -- we need state across
// calls within the same connection. Done via a small reader struct.
class LineReader {
public:
    explicit LineReader(HANDLE pipe) : pipe_(pipe) {}

    // Returns next line (without trailing CR/LF). Empty on disconnect or error.
    std::string Next() {
        std::string line;
        for (;;) {
            // Refill buffer if drained.
            if (pos_ >= len_) {
                DWORD n = 0;
                BOOL ok = ReadFile(pipe_, buf_, (DWORD)sizeof(buf_), &n, nullptr);
                if (!ok || n == 0) return {};
                len_ = (size_t)n;
                pos_ = 0;
            }
            // Scan up to next '\n' within the buffer.
            while (pos_ < len_) {
                char c = buf_[pos_++];
                if (c == '\n') return line;
                if (c == '\r') continue;
                line.push_back(c);
                if (line.size() > 256 * 1024) return {};   // sanity guard
            }
        }
    }

private:
    HANDLE pipe_;
    char   buf_[4096]{};
    size_t pos_ = 0;
    size_t len_ = 0;
};

}  // namespace

IpcServer::IpcServer(std::wstring pipe_name, Handler h)
    : pipe_name_(std::move(pipe_name)), handler_(std::move(h)) {}

IpcServer::~IpcServer() { Stop(); }

void IpcServer::Start() {
    if (thread_.joinable()) return;
    thread_ = std::thread([this] { AcceptLoop(); });
}

void IpcServer::Stop() {
    if (!thread_.joinable()) return;
    stop_.store(true);

    // Closing the pipe handle from another thread does NOT reliably unblock
    // a synchronous ConnectNamedPipe already in flight. CancelSynchronousIo
    // explicitly aborts any pending blocking I/O on the target thread; the
    // canceled call returns with ERROR_OPERATION_ABORTED and AcceptLoop
    // observes stop_ on its next predicate check.
    HANDLE th = (HANDLE)thread_.native_handle();
    if (th) CancelSynchronousIo(th);

    // Belt-and-suspenders: close any open pipe handle so future I/O fails fast.
    {
        std::lock_guard<std::mutex> g(pipe_mutex_);
        if (pipe_ != INVALID_HANDLE_VALUE) {
            if (client_connected_) DisconnectNamedPipe(pipe_);
            CloseHandle(pipe_);
            pipe_ = INVALID_HANDLE_VALUE;
            client_connected_ = false;
        }
    }
    thread_.join();
}

bool IpcServer::WritePipe(const std::string& bytes) {
    std::lock_guard<std::mutex> wg(write_mutex_);
    HANDLE p;
    {
        std::lock_guard<std::mutex> pg(pipe_mutex_);
        if (!client_connected_ || pipe_ == INVALID_HANDLE_VALUE) return false;
        p = pipe_;
    }
    DWORD nw = 0;
    return WriteFile(p, bytes.data(), (DWORD)bytes.size(), &nw, nullptr) &&
           nw == bytes.size();
}

void IpcServer::PublishEvent(std::string_view name, const nlohmann::json& data) {
    nlohmann::json ev = {
        {"type", "event"},
        {"name", std::string(name)},
        {"data", data},
    };
    auto s = ev.dump();
    s.push_back('\n');
    (void)WritePipe(s);  // dropped silently if no client; documented best-effort
}

void IpcServer::AcceptLoop() {
    while (!stop_.load()) {
        HANDLE p = CreateNamedPipeW(
            pipe_name_.c_str(),
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            1,                          // single concurrent instance
            64 * 1024, 64 * 1024,       // out/in buffer sizes
            0,                          // default 50ms NMPWAIT_USE_DEFAULT_WAIT
            nullptr);
        if (p == INVALID_HANDLE_VALUE) {
            DWORD err = GetLastError();
            Error("ipc: CreateNamedPipe failed err=" + std::to_string(err));
            std::this_thread::sleep_for(std::chrono::seconds(1));
            continue;
        }
        {
            std::lock_guard<std::mutex> g(pipe_mutex_);
            if (stop_.load()) { CloseHandle(p); return; }
            pipe_ = p;
        }

        Info("ipc: waiting for client on " + WideToUtf8(pipe_name_));
        BOOL connected = ConnectNamedPipe(p, nullptr) ? TRUE :
                         (GetLastError() == ERROR_PIPE_CONNECTED);
        if (stop_.load()) {
            std::lock_guard<std::mutex> g(pipe_mutex_);
            if (pipe_ != INVALID_HANDLE_VALUE) {
                CloseHandle(pipe_);
                pipe_ = INVALID_HANDLE_VALUE;
            }
            return;
        }
        if (!connected) {
            DWORD err = GetLastError();
            Warn("ipc: ConnectNamedPipe failed err=" + std::to_string(err));
            std::lock_guard<std::mutex> g(pipe_mutex_);
            CloseHandle(pipe_);
            pipe_ = INVALID_HANDLE_VALUE;
            continue;
        }

        {
            std::lock_guard<std::mutex> g(pipe_mutex_);
            client_connected_ = true;
        }
        Info("ipc: client connected");

        // Per-connection request loop. LineReader keeps its 4 KB buffer
        // alive across requests on the same connection.
        LineReader reader(p);
        while (!stop_.load()) {
            std::string line = reader.Next();
            if (line.empty()) break;  // disconnect or error

            int           rq_id = 0;
            std::string   error_text;
            nlohmann::json req_obj;
            try {
                req_obj = nlohmann::json::parse(line);
            } catch (std::exception& e) {
                error_text = std::string("bad-json: ") + e.what();
            }

            IpcResponse rs;
            if (!error_text.empty()) {
                rs.ok    = false;
                rs.error = error_text;
            } else {
                IpcRequest rq;
                rq_id      = req_obj.value("id", 0);
                rq.id      = rq_id;
                rq.method  = req_obj.value("method", std::string{});
                rq.params  = req_obj.value("params", nlohmann::json::object());
                try {
                    rs = handler_(rq);
                } catch (std::exception& e) {
                    rs.ok    = false;
                    rs.error = std::string("handler-exception: ") + e.what();
                }
            }

            nlohmann::json resp = {
                {"type", "resp"},
                {"id",   rq_id},
                {"ok",   rs.ok},
            };
            if (rs.ok) resp["result"] = rs.result;
            else        resp["error"]  = rs.error;
            auto out = resp.dump();
            out.push_back('\n');
            if (!WritePipe(out)) break;  // pipe broken
        }

        Info("ipc: client disconnected");
        {
            std::lock_guard<std::mutex> g(pipe_mutex_);
            client_connected_ = false;
            if (pipe_ != INVALID_HANDLE_VALUE) {
                DisconnectNamedPipe(pipe_);
                CloseHandle(pipe_);
                pipe_ = INVALID_HANDLE_VALUE;
            }
        }
    }
}

}  // namespace ws
