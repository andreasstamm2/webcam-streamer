#pragma once
#include <windows.h>
#include <string>
#include <vector>

namespace ws {

class JobObject;

struct ProcessConfig {
    std::wstring              exe_path;
    std::vector<std::wstring> args;
    std::wstring              friendly_name;
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
    ProcessConfig cfg_;
    JobObject&    job_;
    HANDLE        proc_   = nullptr;
    HANDLE        thread_ = nullptr;
    DWORD         pid_    = 0;
};

}
