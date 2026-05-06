cmake_minimum_required(VERSION 3.20)
project(webcam_streamer_supervisor LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(MSVC)
    add_compile_options(/W4 /permissive- /utf-8)
endif()

add_executable(supervisor
    src/main.cpp
    src/logging.cpp
    src/job_object.cpp
    src/process_supervisor.cpp
    src/strings.cpp
    src/run_command.cpp
    src/camera_enum.cpp
    src/camera_config.cpp
    src/camera_probe.cpp
    src/ipc_server.cpp
)
target_include_directories(supervisor PRIVATE src third_party)
target_compile_definitions(supervisor PRIVATE
    UNICODE _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)
