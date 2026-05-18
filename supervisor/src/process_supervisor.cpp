#include "process_supervisor.h"
#include "job_object.h"
#include "logging.h"
#include "strings.h"
#include <vector>

namespace ws {

namespace {

// Quote an argument per CommandLineToArgvW rules.
std::wstring Quote(const std::wstring& s) {
    bool needs = s.empty() ||
                 s.find_first_of(L" \t\"") != std::wstring::npos;
    if (!needs) return s;
    std::wstring out = L"\"";
    size_t bs = 0;
    for (wchar_t c : s) {
        if (c == L'\\') {
            ++bs;
        } else if (c == L'"') {
            out.append(bs * 2 + 1, L'\\');
            out.push_back(L'"');
            bs = 0;
        } else {
            if (bs) out.append(bs, L'\\');
            bs = 0;
            out.push_back(c);
        }
    }
    if (bs) out.append(bs * 2, L'\\');
    out.push_back(L'"');
    return out;
}

std::wstring BuildCommandLine(const std::wstring& exe,
                               const std::vector<std::wstring>& args) {
    std::wstring cmd = Quote(exe);
    for (auto& a : args) {
        cmd += L' ';
        cmd += Quote(a);
    }
    return cmd;
}

}  // namespace

SupervisedProcess::SupervisedProcess(ProcessConfig cfg, JobObject& job)
    : cfg_(std::move(cfg)), job_(job) {}

SupervisedProcess::~SupervisedProcess() {
    Stop();
}

bool SupervisedProcess::Start() {
    if (proc_) Stop();

    std::wstring cmdline = BuildCommandLine(cfg_.exe_path, cfg_.args);
    std::vector<wchar_t> buf(cmdline.begin(), cmdline.end());
    buf.push_back(0);

    STARTUPINFOW         si{};  si.cb = sizeof(si);
    PROCESS_INFORMATION  pi{};
    BOOL                 inherit = FALSE;

    // If a stdout callback is configured, create an anonymous pipe and
    // redirect the child's stdout (+ stderr merged) into it. We then spawn
    // a reader thread that splits the stream into lines and calls back.
    if (cfg_.on_stdout_line) {
        SECURITY_ATTRIBUTES sa{};
        sa.nLength        = sizeof(sa);
        sa.bInheritHandle = TRUE;
        if (!CreatePipe(&stdout_read_, &stdout_write_, &sa, 64 * 1024)) {
            Error("CreatePipe(" + WideToUtf8(cfg_.friendly_name) +
                  ") failed: " + std::to_string(GetLastError()));
            return false;
        }
        // Read end is NOT inheritable (only the parent reads from it).
        SetHandleInformation(stdout_read_, HANDLE_FLAG_INHERIT, 0);
        si.dwFlags    |= STARTF_USESTDHANDLES;
        si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = stdout_write_;
        si.hStdError  = stdout_write_;   // merge stderr into the same line stream
        inherit = TRUE;
    }

    // CREATE_SUSPENDED so we can put it in the job before it runs.
    DWORD flags = CREATE_SUSPENDED;

    BOOL ok = CreateProcessW(
        cfg_.exe_path.c_str(),
        buf.data(),
        nullptr, nullptr, inherit,
        flags, nullptr, nullptr, &si, &pi);
    if (!ok) {
        DWORD err = GetLastError();
        Error("CreateProcess(" + WideToUtf8(cfg_.friendly_name) +
              ") failed: err=" + std::to_string(err));
        if (stdout_read_)  { CloseHandle(stdout_read_);  stdout_read_  = nullptr; }
        if (stdout_write_) { CloseHandle(stdout_write_); stdout_write_ = nullptr; }
        return false;
    }

    proc_ = pi.hProcess;
    thread_ = pi.hThread;
    pid_ = pi.dwProcessId;

    if (!job_.Assign(proc_)) {
        Warn("AssignProcessToJobObject(" + WideToUtf8(cfg_.friendly_name) +
             ") failed");
    }
    ResumeThread(thread_);

    // After the child has inherited its write end of the pipe, the parent
    // must close its own copy. Otherwise ReadFile won't see EOF when the
    // child exits.
    if (stdout_write_) {
        CloseHandle(stdout_write_);
        stdout_write_ = nullptr;
    }
    if (cfg_.on_stdout_line && stdout_read_) {
        stdout_stop_.store(false);
        stdout_reader_ = std::thread([this] { StdoutReaderLoop(); });
    }

    Info("started " + WideToUtf8(cfg_.friendly_name) +
         " pid=" + std::to_string(pid_));
    return true;
}

void SupervisedProcess::StdoutReaderLoop() {
    std::string carry;
    char buf[4096];
    while (!stdout_stop_.load()) {
        DWORD n = 0;
        BOOL ok = ReadFile(stdout_read_, buf, (DWORD)sizeof(buf), &n, nullptr);
        if (!ok || n == 0) break;          // EOF or error => child gone
        carry.append(buf, n);
        // Emit complete lines.
        size_t pos;
        while ((pos = carry.find('\n')) != std::string::npos) {
            std::string line = carry.substr(0, pos);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            try {
                cfg_.on_stdout_line(line);
            } catch (...) { /* swallow handler exceptions */ }
            carry.erase(0, pos + 1);
        }
    }
    // Flush any trailing fragment without a newline.
    if (!carry.empty()) {
        try { cfg_.on_stdout_line(carry); } catch (...) {}
    }
}

void SupervisedProcess::Stop() {
    if (!proc_) return;
    if (IsRunning()) {
        TerminateProcess(proc_, 1);
        WaitForSingleObject(proc_, 5000);
    }
    if (thread_) { CloseHandle(thread_); thread_ = nullptr; }
    if (proc_)   { CloseHandle(proc_);   proc_   = nullptr; }
    pid_ = 0;

    // Reader thread sees EOF once the write side of the pipe is gone (which
    // happens when the child process exits). Close our read handle to nudge
    // any blocked ReadFile, then join.
    if (stdout_reader_.joinable()) {
        stdout_stop_.store(true);
        if (stdout_read_) {
            CloseHandle(stdout_read_);
            stdout_read_ = nullptr;
        }
        stdout_reader_.join();
    } else if (stdout_read_) {
        CloseHandle(stdout_read_);
        stdout_read_ = nullptr;
    }
}

bool SupervisedProcess::IsRunning() const {
    if (!proc_) return false;
    DWORD ec = 0;
    if (!GetExitCodeProcess(proc_, &ec)) return false;
    return ec == STILL_ACTIVE;
}

DWORD SupervisedProcess::GetExitCode() const {
    DWORD ec = 0;
    if (proc_) GetExitCodeProcess(proc_, &ec);
    return ec;
}

}  // namespace ws
