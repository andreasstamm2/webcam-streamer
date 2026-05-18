#pragma once
#include <windows.h>
#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace ws {

class JobObject;

struct ProcessConfig {
    std::wstring              exe_path;
    std::vector<std::wstring> args;
    std::wstring              friendly_name;
    // If set, the child's stdout (and stderr, merged) is redirected to a
    // pipe and this callback fires once per terminated line on a background
    // thread. Used today to scrape MediaMTX's auth-failed log entries; can
    // be reused for any process whose stdout is interesting to parse.
    std::function<void(const std::string& line)> on_stdout_line;
};

// Single child process owned by the supervisor and assigned to a job object.
// Not thread-safe; use from one orchestration thread.
class SupervisedProcess {
public:
    SupervisedProcess(ProcessConfig cfg, JobObject& job);
    ~SupervisedProcess();

    SupervisedProcess(const SupervisedProcess&)            = delete;
    SupervisedProcess& operator=(const SupervisedProcess&) = delete;

    bool Start();
    void Stop();
    bool IsRunning() const;
    DWORD GetExitCode() const;

    const std::wstring& Name() const { return cfg_.friendly_name; }
    DWORD               Pid()  const { return pid_; }

private:
    void StdoutReaderLoop();

    ProcessConfig     cfg_;
    JobObject&        job_;
    HANDLE            proc_   = nullptr;
    HANDLE            thread_ = nullptr;
    DWORD             pid_    = 0;

    // Stdout capture (only created if cfg_.on_stdout_line is set).
    HANDLE            stdout_read_   = nullptr;
    HANDLE            stdout_write_  = nullptr;
    std::thread       stdout_reader_;
    std::atomic<bool> stdout_stop_{false};
};

}
