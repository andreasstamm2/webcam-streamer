#pragma once
#include <windows.h>

namespace ws {

// Win32 Job Object with KILL_ON_JOB_CLOSE so children die when supervisor dies.
class JobObject {
public:
    JobObject();
    ~JobObject();

    JobObject(const JobObject&)            = delete;
    JobObject& operator=(const JobObject&) = delete;

    bool   Assign(HANDLE process);
    HANDLE Handle() const { return handle_; }

private:
    HANDLE handle_ = nullptr;
};

}
