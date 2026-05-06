#include "job_object.h"
#include "logging.h"
#include <stdexcept>

namespace ws {

JobObject::JobObject() {
    handle_ = CreateJobObjectW(nullptr, nullptr);
    if (!handle_) throw std::runtime_error("CreateJobObject failed");

    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    if (!SetInformationJobObject(handle_,
                                  JobObjectExtendedLimitInformation,
                                  &info, sizeof(info))) {
        CloseHandle(handle_);
        handle_ = nullptr;
        throw std::runtime_error("SetInformationJobObject failed");
    }

    if (!AssignProcessToJobObject(handle_, GetCurrentProcess())) {
        // Likely already in another job (e.g. Visual Studio debugger).
        // Not fatal: children added to *this* job will still die with us.
        Warn("AssignProcessToJobObject(self) failed; debugger nesting?");
    }
}

JobObject::~JobObject() {
    if (handle_) CloseHandle(handle_);
}

bool JobObject::Assign(HANDLE process) {
    return AssignProcessToJobObject(handle_, process) != 0;
}

}
