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

    // CREATE_SUSPENDED so we can put it in the job before it runs.
    DWORD flags = CREATE_SUSPENDED;

    BOOL ok = CreateProcessW(
        cfg_.exe_path.c_str(),
        buf.data(),
        nullptr, nullptr, FALSE,
        flags, nullptr, nullptr, &si, &pi);
    if (!ok) {
        DWORD err = GetLastError();
        Error("CreateProcess(" + WideToUtf8(cfg_.friendly_name) +
              ") failed: err=" + std::to_string(err));
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

    Info("started " + WideToUtf8(cfg_.friendly_name) +
         " pid=" + std::to_string(pid_));
    return true;
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
