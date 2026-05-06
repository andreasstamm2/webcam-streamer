#include "run_command.h"
#include "logging.h"
#include "strings.h"

#include <windows.h>
#include <vector>

namespace ws {

namespace {

std::wstring Quote(const std::wstring& s) {
    bool needs = s.empty() ||
                 s.find_first_of(L" \t\"") != std::wstring::npos;
    if (!needs) return s;
    std::wstring out = L"\"";
    size_t bs = 0;
    for (wchar_t c : s) {
        if (c == L'\\') { ++bs; }
        else if (c == L'"') {
            out.append(bs * 2 + 1, L'\\'); out.push_back(L'"'); bs = 0;
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
    for (auto& a : args) { cmd += L' '; cmd += Quote(a); }
    return cmd;
}

// Drain a pipe handle into a string. Returns when the pipe is closed.
void DrainPipe(HANDLE pipe, std::string& out) {
    char buf[4096];
    DWORD n = 0;
    while (ReadFile(pipe, buf, sizeof(buf), &n, nullptr) && n > 0) {
        out.append(buf, n);
    }
}

}  // namespace

CommandResult RunCommand(const std::wstring& exe,
                          const std::vector<std::wstring>& args,
                          unsigned timeout_ms) {
    CommandResult r;

    SECURITY_ATTRIBUTES sa{};
    sa.nLength        = sizeof(sa);
    sa.bInheritHandle = TRUE;

    HANDLE outR = nullptr, outW = nullptr;
    HANDLE errR = nullptr, errW = nullptr;
    if (!CreatePipe(&outR, &outW, &sa, 0)) {
        Error("CreatePipe(stdout) failed err=" + std::to_string(GetLastError()));
        return r;
    }
    SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);
    if (!CreatePipe(&errR, &errW, &sa, 0)) {
        Error("CreatePipe(stderr) failed err=" + std::to_string(GetLastError()));
        CloseHandle(outR); CloseHandle(outW);
        return r;
    }
    SetHandleInformation(errR, HANDLE_FLAG_INHERIT, 0);

    std::wstring cmdline = BuildCommandLine(exe, args);
    std::vector<wchar_t> buf(cmdline.begin(), cmdline.end());
    buf.push_back(0);

    STARTUPINFOW si{}; si.cb = sizeof(si);
    si.dwFlags    = STARTF_USESTDHANDLES;
    si.hStdOutput = outW;
    si.hStdError  = errW;
    si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
    PROCESS_INFORMATION pi{};

    BOOL ok = CreateProcessW(exe.c_str(), buf.data(),
                              nullptr, nullptr, TRUE,
                              CREATE_NO_WINDOW, nullptr, nullptr,
                              &si, &pi);
    // We must close write ends in the parent to receive EOF on reads.
    CloseHandle(outW);
    CloseHandle(errW);
    if (!ok) {
        DWORD err = GetLastError();
        Error("CreateProcess(" + WideToUtf8(exe) + ") failed err=" + std::to_string(err));
        CloseHandle(outR);
        CloseHandle(errR);
        return r;
    }

    // Drain stderr in a separate thread; read stdout in this one.
    std::string serr;
    HANDLE drainThread = CreateThread(nullptr, 0,
        [](LPVOID p) -> DWORD {
            auto* pair = static_cast<std::pair<HANDLE, std::string*>*>(p);
            DrainPipe(pair->first, *pair->second);
            return 0;
        },
        new std::pair<HANDLE, std::string*>(errR, &serr),
        0, nullptr);

    DrainPipe(outR, r.stdout_text);
    if (drainThread) {
        WaitForSingleObject(drainThread, INFINITE);
        CloseHandle(drainThread);
    }
    r.stderr_text = std::move(serr);

    DWORD wait_ms = (timeout_ms == 0) ? INFINITE : timeout_ms;
    DWORD wait_rc = WaitForSingleObject(pi.hProcess, wait_ms);
    if (wait_rc == WAIT_TIMEOUT) {
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, 1000);
        Warn("RunCommand(" + WideToUtf8(exe) + ") timed out after " + std::to_string(timeout_ms) + "ms");
    }

    DWORD ec = 0;
    GetExitCodeProcess(pi.hProcess, &ec);
    r.exit_code = (int)ec;
    r.ok        = (wait_rc == WAIT_OBJECT_0 && ec == 0);

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(outR);
    CloseHandle(errR);
    return r;
}

}  // namespace ws
