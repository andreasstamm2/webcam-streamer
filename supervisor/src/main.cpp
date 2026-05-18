// Supervisor v2: enumerate cams + probe-driven mode + IPC named pipe.
//
//   - Spawns mediamtx + one ffmpeg per detected camera under a Job Object.
//   - Exposes \\.\pipe\webcam-streamer-supervisor for control.
//   - Publishes camera-state-changed events on transitions.

#include "logging.h"
#include "job_object.h"
#include "process_supervisor.h"
#include "strings.h"
#include "camera_enum.h"
#include "camera_config.h"
#include "camera_probe.h"
#include "ipc_server.h"
#include "settings.h"

#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")

#include "run_command.h"

#include <atomic>
#include <chrono>
#include <filesystem>
#include <thread>
#include <memory>
#include <set>
#include <vector>
#include <algorithm>
#include <mutex>

namespace fs = std::filesystem;
using namespace std::chrono_literals;
using namespace ws;
using nlohmann::json;

static std::atomic<bool> g_stop{false};

static BOOL WINAPI ConsoleCtrl(DWORD signal) {
    if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT ||
        signal == CTRL_CLOSE_EVENT) {
        Info("shutdown signal received");
        g_stop.store(true);
        return TRUE;
    }
    return FALSE;
}

static fs::path FindProjectRoot() {
    wchar_t buf[MAX_PATH];
    if (GetEnvironmentVariableW(L"SUPERVISOR_ROOT", buf, MAX_PATH) > 0) {
        return fs::path(buf);
    }
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    fs::path p = fs::path(buf).parent_path();
    // Walk up looking for the runtime third_party (mediamtx/ffmpeg). The
    // supervisor's own `third_party` (nlohmann/json) sits one level deeper,
    // so we must match on the runtime marker, not just any `third_party` dir.
    for (int i = 0; i < 8; ++i) {
        if (fs::exists(p / "third_party" / "mediamtx" / "mediamtx.exe")) return p;
        if (!p.has_parent_path() || p.parent_path() == p) break;
        p = p.parent_path();
    }
    return p;
}

static bool WaitForRtspReady(int port, std::chrono::milliseconds timeout) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return false;
    auto deadline = std::chrono::steady_clock::now() + timeout;
    bool ready = false;
    while (!ready && !g_stop && std::chrono::steady_clock::now() < deadline) {
        SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
        if (s != INVALID_SOCKET) {
            sockaddr_in addr{};
            addr.sin_family = AF_INET;
            addr.sin_port = htons((u_short)port);
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
            if (connect(s, (sockaddr*)&addr, sizeof(addr)) == 0) ready = true;
            closesocket(s);
        }
        if (!ready) std::this_thread::sleep_for(100ms);
    }
    WSACleanup();
    return ready;
}

struct Backoff {
    std::chrono::steady_clock::time_point last_start{};
    std::chrono::milliseconds              delay{1000};
    int                                    restarts{0};
};

struct CamSlot {
    CameraConfig                       cfg;
    std::unique_ptr<SupervisedProcess> proc;
    Backoff                            backoff;
    bool                               last_running = false;  // for state-change events
    bool                               present      = true;   // false = unplugged; supervision skips restarts
};

static void StartWithBackoff(SupervisedProcess& p, Backoff& b) {
    if (g_stop) return;
    auto now = std::chrono::steady_clock::now();
    if (b.restarts > 0) {
        if (now - b.last_start > 60s) {
            b.delay = 1000ms;
            b.restarts = 0;
        }
        if (b.restarts > 0) {
            Info("backoff " + std::to_string(b.delay.count()) + "ms before restart of " +
                 WideToUtf8(p.Name()) + " (attempt " + std::to_string(b.restarts + 1) + ")");
            auto deadline = std::chrono::steady_clock::now() + b.delay;
            while (!g_stop && std::chrono::steady_clock::now() < deadline) {
                std::this_thread::sleep_for(100ms);
            }
            b.delay = std::min<std::chrono::milliseconds>(b.delay * 2, 30000ms);
        }
    }
    if (g_stop) return;
    b.last_start = std::chrono::steady_clock::now();
    b.restarts++;
    if (!p.Start()) {
        Error("failed to start " + WideToUtf8(p.Name()));
    }
}

// Build the JSON description of one camera slot. Caller must hold state_mutex.
static json CamToJson(const CamSlot& s) {
    return {
        {"name",     WideToUtf8(s.cfg.friendly_name)},
        {"path",     WideToUtf8(s.cfg.rtsp_path)},
        {"mode",     ModeName(s.cfg.mode)},
        {"width",    s.cfg.width},
        {"height",   s.cfg.height},
        {"fps",      s.cfg.fps},
        {"running",  s.proc && s.proc->IsRunning()},
        {"present",  s.present},
        {"enabled",  s.cfg.enabled},
        {"pid",      s.proc ? (uint32_t)s.proc->Pid() : 0},
        {"restarts", s.backoff.restarts},
    };
}

// All camera slots as a JSON array (used by list-cameras, get-status, and
// the cameras-changed event payload). Caller must hold state_mutex.
static json AllCamsJson(const std::vector<CamSlot>& slots) {
    json arr = json::array();
    for (const auto& s : slots) arr.push_back(CamToJson(s));
    return arr;
}

// Build the ffmpeg-publisher ProcessConfig for one camera. Pure helper -- no
// state. Centralises the publisher-name and arg-building for all three
// creation sites (initial setup, set-mode/restart-camera rebuild, hot-add
// from re-enumeration).
static ProcessConfig MakeFFmpegProcessConfig(const std::filesystem::path& ffExe,
                                              const CameraConfig& cc,
                                              const std::wstring& publisher) {
    return ProcessConfig{
        .exe_path      = ffExe.wstring(),
        .args          = BuildFFmpegArgs(cc, publisher),
        .friendly_name = L"ffmpeg(" + cc.friendly_name + L")",
    };
}

int wmain() {
    SetConsoleCtrlHandler(ConsoleCtrl, TRUE);

    fs::path root = FindProjectRoot();
    Info("project root: " + root.string());

    fs::path mtxExe    = root / "third_party" / "mediamtx" / "mediamtx.exe";
    fs::path ffExe     = root / "third_party" / "ffmpeg"   / "ffmpeg.exe";
    fs::path mtxYml    = root / "config"      / "mediamtx.yml";
    fs::path probesDir = root / "probes";

    for (const auto& p : {mtxExe, ffExe, mtxYml}) {
        if (!fs::exists(p)) {
            Error("missing required file: " + p.string());
            return 2;
        }
    }

    // Load app-wide settings (default_enabled_for_new_cameras lives here).
    // The host app owns the file; we just read it. Lives in `root` for now;
    // the installer will route this to %LOCALAPPDATA%\WebcamStreamer via
    // SUPERVISOR_ROOT in a later slice.
    Settings settings = LoadSettings(root);
    Info("settings: default_enabled_for_new_cameras=" +
         std::string(settings.default_enabled_for_new_cameras ? "true" : "false"));

    Info("enumerating cameras...");
    auto cams = EnumerateCameras(ffExe);
    if (cams.empty()) {
        Error("no cameras detected by ffmpeg dshow enumeration");
        return 3;
    }

    // Resolve full per-cam config from override file > probe recommendation > defaults.
    auto resolveCameraConfig = [&](std::wstring_view name, CameraConfig& cc) {
        auto ov = LoadOverride(probesDir, name);

        // Mode: override beats probe-recommended beats default.
        if (ov && ov->mode) cc.mode = *ov->mode;
        else if (auto p = LoadProbeResult(probesDir, name);
                  p && p->recommended != Mode::Unknown) cc.mode = p->recommended;
        else {
            cc.mode = Mode::PassthroughMjpeg;
            Warn("cam '" + WideToUtf8(name) +
                 "' has no probe summary; defaulting to passthrough_mjpeg");
        }

        // Resolution / fps overrides (rare; HP-RAW@640x480 is the canonical case).
        if (ov) {
            if (ov->width)  cc.width  = *ov->width;
            if (ov->height) cc.height = *ov->height;
            if (ov->fps)    cc.fps    = *ov->fps;
        }

        // Enabled flag: override beats settings.json default (which beats
        // the CameraConfig built-in default of true). A camera with no
        // override file and no settings.json gets enabled=true (matches
        // pre-Slice-A behaviour).
        if (ov && ov->enabled) cc.enabled = *ov->enabled;
        else                   cc.enabled = settings.default_enabled_for_new_cameras;
    };

    std::vector<CameraConfig> camConfigs;
    int idx = 0;
    for (const auto& name : cams) {
        CameraConfig cc;
        cc.friendly_name = name;
        cc.rtsp_path     = L"/webcam" + std::to_wstring(idx++);
        resolveCameraConfig(name, cc);
        Info("cam '" + WideToUtf8(name) + "' -> path " + WideToUtf8(cc.rtsp_path) +
             " mode=" + ModeName(cc.mode) +
             " " + std::to_string(cc.width) + "x" + std::to_string(cc.height) +
             "@" + std::to_string(cc.fps));
        camConfigs.push_back(std::move(cc));
    }

    JobObject job;

    ProcessConfig mtxCfg{
        .exe_path      = mtxExe.wstring(),
        .args          = { mtxYml.wstring() },
        .friendly_name = L"mediamtx",
    };
    auto mtx = std::make_unique<SupervisedProcess>(mtxCfg, job);
    Backoff bMtx;
    StartWithBackoff(*mtx, bMtx);

    if (!WaitForRtspReady(8554, 10s)) {
        Error("mediamtx did not become ready on :8554 within 10s");
        return 4;
    }
    Info("mediamtx ready on :8554");

    const std::wstring publisher = L"rtsp://publisher:publisher@127.0.0.1:8554";

    std::vector<CamSlot> slots;
    slots.reserve(camConfigs.size());
    for (auto& cc : camConfigs) {
        CamSlot s;
        s.cfg  = cc;
        s.proc = std::make_unique<SupervisedProcess>(
                     MakeFFmpegProcessConfig(ffExe, cc, publisher), job);
        slots.push_back(std::move(s));
    }
    // Only start the ffmpeg publishers for ENABLED cameras. Disabled cams
    // keep their SupervisedProcess object (so set-stream-enabled true later
    // can just Start() it) but never spawn ffmpeg.
    for (auto& s : slots) {
        if (s.cfg.enabled) StartWithBackoff(*s.proc, s.backoff);
        else               Info("cam '" + WideToUtf8(s.cfg.friendly_name) +
                                "' is disabled; not publishing.");
    }

    Info("supervisor running. Streams:");
    for (auto& s : slots) {
        if (!s.cfg.enabled) {
            Info("  (disabled) " + WideToUtf8(s.cfg.friendly_name));
            continue;
        }
        Info("  rtsp://viewer:viewer@<host>:8554" + WideToUtf8(s.cfg.rtsp_path) +
             "  (" + WideToUtf8(s.cfg.friendly_name) + ", mode=" + ModeName(s.cfg.mode) + ")");
    }

    // ----- IPC server -----
    std::mutex state_mutex;     // protects `slots` from concurrent IPC handler access
    auto rebuildSlot = [&](CamSlot& s) {
        s.proc = std::make_unique<SupervisedProcess>(
                     MakeFFmpegProcessConfig(ffExe, s.cfg, publisher), job);
        s.backoff = Backoff{};
    };

    IpcServer ipc(L"\\\\.\\pipe\\webcam-streamer-supervisor",
        [&](const IpcRequest& rq) -> IpcResponse {
            IpcResponse rs;
            const auto& m = rq.method;
            std::lock_guard<std::mutex> g(state_mutex);

            if (m == "list-cameras") {
                rs.ok = true;
                rs.result = AllCamsJson(slots);
            } else if (m == "get-status") {
                rs.ok = true;
                rs.result = {
                    {"mediamtx",   {
                        {"running", mtx->IsRunning()},
                        {"pid",     (uint32_t)mtx->Pid()},
                        {"restarts", bMtx.restarts},
                    }},
                    {"cameras", AllCamsJson(slots)},
                };
            } else if (m == "restart-camera") {
                std::string nm = rq.params.value("name", std::string{});
                if (nm.empty()) {
                    rs.ok = false; rs.error = "missing param 'name'";
                } else {
                    bool found = false;
                    auto wname = Utf8ToWide(nm);
                    for (auto& s : slots) {
                        if (s.cfg.friendly_name == wname) {
                            found = true;
                            s.proc->Stop();
                            rebuildSlot(s);
                            StartWithBackoff(*s.proc, s.backoff);
                            // The main loop won't observe the down/up flap
                            // since this handler runs synchronously, so emit
                            // the event ourselves to keep clients in sync.
                            ipc.PublishEvent("camera-state-changed", CamToJson(s));
                            s.last_running = s.proc->IsRunning();
                            break;
                        }
                    }
                    if (!found) { rs.ok = false; rs.error = "unknown camera: " + nm; }
                    else        { rs.ok = true;  rs.result = "restarted"; }
                }
            } else if (m == "set-mode") {
                std::string nm   = rq.params.value("name", std::string{});
                std::string mode = rq.params.value("mode", std::string{});
                Mode parsed = ModeFromString(mode);

                // Build the override once; reuse for both in-memory cfg
                // mutation and disk persistence. Missing/0 fields stay nullopt
                // so SaveOverride preserves any prior value.
                CameraOverride upd;
                upd.mode = parsed;
                if (int v = rq.params.value("width",  0); v > 0) upd.width  = v;
                if (int v = rq.params.value("height", 0); v > 0) upd.height = v;
                if (int v = rq.params.value("fps",    0); v > 0) upd.fps    = v;

                if (nm.empty() || parsed == Mode::Unknown) {
                    rs.ok = false;
                    rs.error = "params {name, mode} required (mode in passthrough_mjpeg|passthrough_h264|"
                               "transcode_mjpeg_to_h264|transcode_raw_to_h264|transcode_raw_to_mjpeg); "
                               "optional: width, height, fps";
                } else {
                    auto wname = Utf8ToWide(nm);
                    auto it = std::find_if(slots.begin(), slots.end(),
                        [&](const CamSlot& s) { return s.cfg.friendly_name == wname; });
                    if (it == slots.end()) {
                        rs.ok = false; rs.error = "unknown camera: " + nm;
                    } else {
                        auto& s = *it;
                        s.cfg.mode = parsed;
                        if (upd.width)  s.cfg.width  = *upd.width;
                        if (upd.height) s.cfg.height = *upd.height;
                        if (upd.fps)    s.cfg.fps    = *upd.fps;
                        SaveOverride(probesDir, wname, upd);
                        s.proc->Stop();
                        rebuildSlot(s);
                        StartWithBackoff(*s.proc, s.backoff);
                        ipc.PublishEvent("camera-state-changed", CamToJson(s));
                        s.last_running = s.proc->IsRunning();
                        // Echo effective values so the client sees what's actually running.
                        rs.ok = true;
                        rs.result = {
                            {"mode",   ModeName(s.cfg.mode)},
                            {"width",  s.cfg.width},
                            {"height", s.cfg.height},
                            {"fps",    s.cfg.fps},
                        };
                    }
                }
            } else if (m == "list-advertised-formats") {
                std::string nm = rq.params.value("name", std::string{});
                if (nm.empty()) {
                    rs.ok = false; rs.error = "missing param 'name'";
                } else {
                    auto wname = Utf8ToWide(nm);
                    auto js = LoadProbeJson(probesDir, wname);
                    if (!js) {
                        rs.ok = false;
                        rs.error = "no probe JSON found for '" + nm +
                                   "'; run probe-camera first";
                    } else {
                        rs.ok = true;
                        rs.result = js->value("advertised_formats", json::array());
                    }
                }
            } else if (m == "probe-camera") {
                std::string nm = rq.params.value("name", std::string{});
                if (nm.empty()) {
                    rs.ok = false; rs.error = "missing param 'name'";
                } else {
                    // Spawn the probe asynchronously; the IPC thread must not
                    // block for ~30s. Worker thread emits 'probe-completed'
                    // when done.
                    auto wname = Utf8ToWide(nm);
                    auto slug  = SlugifyName(wname);
                    auto reportPath = (probesDir / (slug + L".json")).wstring();
                    auto scriptPath = (root / "scripts" / "probe-camera.ps1").wstring();
                    ipc.PublishEvent("probe-started", json{{"camera", nm}});
                    std::thread([&ipc, scriptPath, wname, reportPath, probesDir, nm]() {
                        // Run powershell -File <script> -CameraName <name> -ReportPath <path>
                        auto r = RunCommand(L"powershell.exe", {
                            L"-NoProfile",
                            L"-ExecutionPolicy", L"Bypass",
                            L"-File",         scriptPath,
                            L"-CameraName",   wname,
                            L"-ReportPath",   reportPath,
                        }, 180000);  // 3 min hard cap

                        json ev;
                        ev["camera"] = nm;
                        ev["ok"]     = r.ok;
                        if (!r.ok) {
                            ev["error"] = "probe-camera.ps1 exit=" + std::to_string(r.exit_code) +
                                          ": " + r.stderr_text.substr(0, 400);
                        } else {
                            // Read recommendation from the freshly-written summary.
                            auto upd = LoadProbeResult(probesDir, wname);
                            if (upd) ev["recommended"] = ModeName(upd->recommended);
                        }
                        ipc.PublishEvent("probe-completed", ev);
                    }).detach();
                    rs.ok = true;
                    rs.result = {{"started", true}};
                }
            } else if (m == "set-stream-enabled") {
                std::string nm = rq.params.value("name", std::string{});
                if (nm.empty() || !rq.params.contains("enabled") ||
                    !rq.params["enabled"].is_boolean()) {
                    rs.ok = false;
                    rs.error = "params {name: string, enabled: bool} required";
                } else {
                    auto wname = Utf8ToWide(nm);
                    auto it = std::find_if(slots.begin(), slots.end(),
                        [&](const CamSlot& cs) { return cs.cfg.friendly_name == wname; });
                    if (it == slots.end()) {
                        rs.ok = false; rs.error = "unknown camera: " + nm;
                    } else {
                        auto& s = *it;
                        bool want = rq.params["enabled"].get<bool>();
                        // Persist first so a crash between persistence and
                        // process change leaves a consistent state on disk.
                        CameraOverride upd;
                        upd.enabled = want;
                        SaveOverride(probesDir, wname, upd);
                        s.cfg.enabled = want;

                        if (want) {
                            // Re-enable: build a fresh SupervisedProcess (the
                            // previous one may carry exit state). Skip the
                            // start if the camera is currently unplugged --
                            // the supervision loop's hot-plug path will start
                            // it when it returns.
                            if (s.present) {
                                s.proc->Stop();
                                rebuildSlot(s);
                                StartWithBackoff(*s.proc, s.backoff);
                            }
                        } else {
                            // Disable: kill the publisher. Keep the
                            // SupervisedProcess object around so subsequent
                            // re-enable can rebuild from a known state.
                            s.proc->Stop();
                        }

                        ipc.PublishEvent("camera-state-changed", CamToJson(s));
                        s.last_running = s.proc->IsRunning();

                        rs.ok = true;
                        rs.result = {
                            {"name",    nm},
                            {"enabled", want},
                        };
                    }
                }
            } else if (m == "reload-settings") {
                // Re-read settings.json and re-broadcast as a settings event
                // so future hot-plug uses the new default. Existing cams
                // keep their current `enabled` -- this method does NOT
                // retroactively change cams' state.
                Settings fresh = LoadSettings(root);
                settings = fresh;
                Info("settings reloaded: default_enabled_for_new_cameras=" +
                     std::string(settings.default_enabled_for_new_cameras ? "true" : "false"));
                rs.ok = true;
                rs.result = {
                    {"default_enabled_for_new_cameras",
                     settings.default_enabled_for_new_cameras},
                };
            } else if (m == "shutdown") {
                g_stop.store(true);
                rs.ok = true;
                rs.result = "shutting down";
            } else {
                rs.ok = false;
                rs.error = "unknown method: " + m;
            }
            return rs;
        });
    ipc.Start();
    Info("ipc: serving on \\\\.\\pipe\\webcam-streamer-supervisor");
    Info("Ctrl-C to stop.");

    // ----- supervision loop -----
    // Track running-state per slot to publish state-change events.
    {
        std::lock_guard<std::mutex> g(state_mutex);
        for (auto& s : slots) s.last_running = s.proc->IsRunning();
    }

    // Allocate the next free /webcamN path, scanning current slots so reused
    // indices come back when an absent cam returns.
    auto allocPath = [&]() {
        for (int i = 0; ; ++i) {
            std::wstring p = L"/webcam" + std::to_wstring(i);
            bool taken = false;
            for (auto& s : slots) if (s.cfg.rtsp_path == p) { taken = true; break; }
            if (!taken) return p;
        }
    };

    auto lastEnum = std::chrono::steady_clock::now();

    while (!g_stop) {
        std::this_thread::sleep_for(500ms);

        // Phase 1: short-lock supervision tick (mediamtx + per-slot ffmpeg).
        {
            std::lock_guard<std::mutex> g(state_mutex);

            if (!mtx->IsRunning()) {
                Warn("mediamtx exited code=" + std::to_string(mtx->GetExitCode()));
                mtx->Stop();
                StartWithBackoff(*mtx, bMtx);
                WaitForRtspReady(8554, 10s);
                ipc.PublishEvent("mediamtx-state-changed",
                                 json{{"running", mtx->IsRunning()}});
            }

            for (auto& s : slots) {
                if (!s.present || !s.cfg.enabled) {
                    // Disabled or unplugged: ensure ffmpeg is dead and
                    // do not auto-restart. last_running is kept in sync so
                    // the next transition (re-enable or re-plug) fires a
                    // state-change event.
                    if (s.last_running) {
                        s.last_running = false;
                        ipc.PublishEvent("camera-state-changed", CamToJson(s));
                    }
                    continue;
                }
                bool running_now = s.proc->IsRunning();
                if (!running_now) {
                    Warn(WideToUtf8(s.proc->Name()) + " exited code=" +
                         std::to_string(s.proc->GetExitCode()));
                    s.proc->Stop();
                    StartWithBackoff(*s.proc, s.backoff);
                    running_now = s.proc->IsRunning();
                }
                if (running_now != s.last_running) {
                    ipc.PublishEvent("camera-state-changed", CamToJson(s));
                    s.last_running = running_now;
                }
            }
        }

        // Phase 2: periodic re-enumeration for plug/unplug detection.
        // EnumerateCameras spawns ffmpeg as a subprocess (~1s); we run it
        // WITHOUT state_mutex held so IPC handlers stay responsive. Apply
        // the diffs in a short re-locked section.
        auto now = std::chrono::steady_clock::now();
        if (now - lastEnum > 10s) {
            lastEnum = now;
            auto current = EnumerateCameras(ffExe);   // unlocked; ~1s

            std::lock_guard<std::mutex> g(state_mutex);
            std::set<std::wstring> currentSet(current.begin(), current.end());
            std::set<std::wstring> knownSet;
            for (auto& s : slots) knownSet.insert(s.cfg.friendly_name);

            bool listChanged = false;

            for (auto& s : slots) {
                bool isPresent = currentSet.count(s.cfg.friendly_name) > 0;
                if (s.present && !isPresent) {
                    Info("camera disappeared: " + WideToUtf8(s.cfg.friendly_name));
                    s.present = false;
                    s.proc->Stop();
                    listChanged = true;
                } else if (!s.present && isPresent) {
                    Info("camera reappeared: " + WideToUtf8(s.cfg.friendly_name));
                    s.present = true;
                    if (s.cfg.enabled) {
                        rebuildSlot(s);
                        StartWithBackoff(*s.proc, s.backoff);
                    } else {
                        Info("  (kept disabled per user setting)");
                    }
                    listChanged = true;
                }
            }

            for (auto& name : current) {
                if (knownSet.count(name)) continue;
                CamSlot s;
                s.cfg.friendly_name = name;
                s.cfg.rtsp_path     = allocPath();
                resolveCameraConfig(name, s.cfg);
                s.present = true;
                Info("camera added: " + WideToUtf8(name) + " -> path " +
                     WideToUtf8(s.cfg.rtsp_path) + " mode=" + ModeName(s.cfg.mode) +
                     " " + std::to_string(s.cfg.width) + "x" + std::to_string(s.cfg.height) +
                     "@" + std::to_string(s.cfg.fps) +
                     " enabled=" + (s.cfg.enabled ? "true" : "false"));
                s.proc = std::make_unique<SupervisedProcess>(
                             MakeFFmpegProcessConfig(ffExe, s.cfg, publisher), job);
                slots.push_back(std::move(s));
                if (s.cfg.enabled) {
                    StartWithBackoff(*slots.back().proc, slots.back().backoff);
                }
                listChanged = true;
            }

            if (listChanged) ipc.PublishEvent("cameras-changed", AllCamsJson(slots));
        }
    }

    Info("stopping ipc...");
    ipc.Stop();
    Info("stopping children...");
    for (auto& s : slots) s.proc->Stop();
    mtx->Stop();
    Info("supervisor exit.");
    return 0;
}
