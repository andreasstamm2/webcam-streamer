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
#include "camera_formats.h"
#include "camera_probe.h"
#include "ipc_server.h"
#include "settings.h"
#include "events_pipe.h"
#include "known_cameras.h"

#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")

#include "run_command.h"

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sstream>
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
    // The supervision loop must not restart until this point. Set whenever
    // we start p; consulted by the loop BEFORE the next restart attempt.
    // Holding state_mutex during a multi-second sleep would block every
    // IPC handler (probe, restart, set-mode, ...) and was the cause of the
    // v0.2.0 "probe timed out" symptom whenever ffmpeg was flapping.
    std::chrono::steady_clock::time_point earliest_next{};
    std::chrono::milliseconds              delay{1000};
    int                                    restarts{0};
};

struct CamSlot {
    CameraConfig                       cfg;
    std::unique_ptr<SupervisedProcess> proc;
    Backoff                            backoff;
    bool                               last_running = false;  // for state-change events
    bool                               present      = true;   // false = unplugged; supervision skips restarts
    int                                viewer_count = 0;       // bumped by events-pipe runOnRead/Unread
    // Filled once at discovery (initial enum + hot-add) via `ffmpeg
    // -list_options`. Used by resolveCameraConfig to pick a working default
    // and surfaced in CamToJson so the UI can populate per-cam Resolution
    // dropdowns instead of a hardcoded list.
    std::vector<AdvertisedFormat>      formats;
    // Captured from `ffmpeg -list_devices` Alternative-name line. alt_name
    // is the full DirectShow PnP path; vid_pid is "vvvv:pppp" lowercased
    // hex (empty if not a USB device or extraction failed). Surfaced in
    // CamToJson so the UI / users can identify cams when adding entries to
    // config/known-cameras.json.
    std::wstring                       alt_name;
    std::string                        vid_pid;
};

// Start p now and update backoff bookkeeping. Never sleeps. Callers that
// want to throttle restart storms (the supervision loop) MUST check
// b.earliest_next before calling. IPC handlers and hot-plug paths call
// this directly because the user is asking for immediate action.
static void StartNoSleep(SupervisedProcess& p, Backoff& b) {
    if (g_stop) return;
    auto now = std::chrono::steady_clock::now();
    if (b.restarts > 0 && now - b.last_start > 60s) {
        // Process has been up >60s -- previous failure was a one-off.
        b.delay = 1000ms;
        b.restarts = 0;
    }
    b.last_start    = now;
    b.restarts++;
    b.earliest_next = now + b.delay;
    b.delay         = std::min<std::chrono::milliseconds>(b.delay * 2, 30000ms);
    if (!p.Start()) {
        Error("failed to start " + WideToUtf8(p.Name()));
    }
}

// Build the JSON description of one camera slot. Caller must hold state_mutex.
static json CamToJson(const CamSlot& s) {
    json formats = json::array();
    for (const auto& f : s.formats) {
        formats.push_back({
            {"kind",    f.kind},
            {"codec",   f.codec},
            {"pix_fmt", f.pix_fmt},
            {"width",   f.width},
            {"height",  f.height},
            {"min_fps", f.min_fps},
            {"max_fps", f.max_fps},
        });
    }
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
        {"viewer_count", s.viewer_count},
        {"advertised_formats", formats},
        {"alt_name", WideToUtf8(s.alt_name)},
        {"vid_pid",  s.vid_pid},
    };
}

// Pick a (mode, width, height) tuple that the camera actually advertises.
// Preferred path: MJPEG-source -> transcode_mjpeg_to_h264 (the v0.2.1
// universal-fallback default), since virtually every modern USB cam exposes
// MJPEG. If no MJPEG is offered, fall back to transcode_raw_to_h264 with the
// largest advertised raw resolution (capped at the preferred target). If we
// couldn't enumerate formats at all (the rare case), keep the preferred
// defaults so a brand-new cam still tries to publish rather than silently
// failing.
//
// Preferred resolution is **640x480**. The supervisor mostly powers monitoring
// use cases; 480p is more than enough, halves bandwidth vs. 720p, and is
// almost universally advertised by USB webcams. Users who want higher res
// pick it explicitly from the per-cam dropdown (or set an override file).
struct DefaultPick {
    Mode mode;
    int  width;
    int  height;
    int  fps;
};
static DefaultPick PickDefaultFromFormats(const std::vector<AdvertisedFormat>& formats) {
    constexpr int kPrefW = 640, kPrefH = 480;
    DefaultPick d{ Mode::TranscodeMjpegToH264, kPrefW, kPrefH, 30 };
    if (formats.empty()) return d;

    auto pickBest = [&](auto pred) -> std::optional<AdvertisedFormat> {
        // Pick exact 1280x720 if advertised; else the largest matching
        // resolution at or below 1280x720; else the largest one full stop.
        const AdvertisedFormat* exact   = nullptr;
        const AdvertisedFormat* leSized = nullptr;
        const AdvertisedFormat* largest = nullptr;
        for (const auto& f : formats) {
            if (!pred(f)) continue;
            if (f.width == kPrefW && f.height == kPrefH) { exact = &f; break; }
            if (f.width <= kPrefW && f.height <= kPrefH) {
                if (!leSized || (int64_t)f.width*f.height > (int64_t)leSized->width*leSized->height) {
                    leSized = &f;
                }
            }
            if (!largest || (int64_t)f.width*f.height > (int64_t)largest->width*largest->height) {
                largest = &f;
            }
        }
        if (exact)   return *exact;
        if (leSized) return *leSized;
        if (largest) return *largest;
        return std::nullopt;
    };

    if (auto m = pickBest([](const AdvertisedFormat& f) {
            return f.kind == "compressed" && f.codec == "mjpeg";
        })) {
        d.mode   = Mode::TranscodeMjpegToH264;
        d.width  = m->width;
        d.height = m->height;
        d.fps    = (m->max_fps > 0) ? (int)std::min(30.0, m->max_fps) : 30;
        return d;
    }
    if (auto m = pickBest([](const AdvertisedFormat& f) { return f.kind == "raw"; })) {
        d.mode   = Mode::TranscodeRawToH264;
        d.width  = m->width;
        d.height = m->height;
        d.fps    = (m->max_fps > 0) ? (int)std::min(30.0, m->max_fps) : 30;
        return d;
    }
    // No usable format found -- keep defaults; the publisher will fail to
    // start and the supervision loop will hold off with backoff.
    return d;
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

    // Locate mtx_event_hook.exe -- bundled next to supervisor.exe by both
    // the CMake build and the Inno installer. Generate a runtime mediamtx
    // config that substitutes the absolute hook path into the
    // runOnRead / runOnUnread template. MediaMTX runs the substituted file;
    // the template under config/ stays portable.
    fs::path hookExe;
    {
        wchar_t selfBuf[MAX_PATH];
        GetModuleFileNameW(nullptr, selfBuf, MAX_PATH);
        hookExe = fs::path(selfBuf).parent_path() / "mtx_event_hook.exe";
    }
    if (!fs::exists(hookExe)) {
        Error("missing required file: " + hookExe.string() +
              " (build the mtx_event_hook CMake target)");
        return 2;
    }

    fs::path runtimeMtxYml = root / "mediamtx.runtime.yml";
    {
        std::ifstream tin(mtxYml);
        if (!tin) {
            Error("could not read template " + mtxYml.string());
            return 2;
        }
        std::stringstream tbuf;
        tbuf << tin.rdbuf();
        std::string contents = tbuf.str();
        // Substitute placeholder. YAML wraps the path in double quotes; we
        // escape backslashes for the YAML double-quoted-scalar rule.
        std::string hookStr = hookExe.string();
        std::string escaped;
        escaped.reserve(hookStr.size() * 2);
        for (char c : hookStr) {
            if (c == '\\' || c == '"') escaped.push_back('\\');
            escaped.push_back(c);
        }
        // The YAML uses single-quoted strings around an inner double-quoted
        // path -- ' "C:\path\to\hook.exe" read '. Inside single quotes, YAML
        // is literal, so we ONLY need to escape the inner double-quoted
        // content for MediaMTX's command-line parsing (which we already do
        // by quoting the path). No YAML escape needed inside single quotes.
        // -> drop the escaping pass; just use the raw path. The template
        // uses '"__EVENT_HOOK__" read' (single-quoted YAML, inner double
        // quotes around the path so spaces work in the path).
        (void)escaped;
        size_t pos = 0;
        const std::string placeholder = "__EVENT_HOOK__";
        while ((pos = contents.find(placeholder, pos)) != std::string::npos) {
            contents.replace(pos, placeholder.size(), hookStr);
            pos += hookStr.size();
        }
        std::ofstream tout(runtimeMtxYml, std::ios::trunc);
        if (!tout) {
            Error("could not write runtime config " + runtimeMtxYml.string());
            return 2;
        }
        tout << contents;
    }
    Info("event hook: " + hookExe.string());
    Info("runtime mediamtx config: " + runtimeMtxYml.string());

    // Load app-wide settings (default_enabled_for_new_cameras lives here).
    // The host app owns the file; we just read it. Lives in `root` for now;
    // the installer will route this to %LOCALAPPDATA%\WebcamStreamer via
    // SUPERVISOR_ROOT in a later slice.
    Settings settings = LoadSettings(root);
    Info("settings: default_enabled_for_new_cameras=" +
         std::string(settings.default_enabled_for_new_cameras ? "true" : "false"));

    // Bundled DB of known-good profiles by USB vid:pid. Missing file =
    // empty DB; the fallback path (advertised-format smart pick) still
    // works. The supervisor only uses this when a freshly-discovered cam
    // has no user override file.
    KnownCameraDb knownDb;
    knownDb.Load(root / "config" / "known-cameras.json");

    Info("enumerating cameras...");
    auto cams = EnumerateCameras(ffExe);
    if (cams.empty()) {
        Error("no cameras detected by ffmpeg dshow enumeration");
        return 3;
    }
    for (const auto& d : cams) {
        // Log device identity so users can populate config/known-cameras.json
        // for cams they ship to others. vid_pid is empty for non-USB or
        // unrecognised PnP paths -- not an error.
        Info("cam '" + WideToUtf8(d.friendly_name) +
             "' vid_pid='" + d.vid_pid + "'" +
             (d.alt_name.empty() ? "" : " alt_name='" + WideToUtf8(d.alt_name) + "'"));
    }

    // Resolve full per-cam config. Priority:
    //   1. Override file (user explicitly picked this -- always wins).
    //   2. Known-cameras DB matched by USB vid:pid (we ship a known-good
    //      profile for this hardware).
    //   3. Format-based smart pick from `ffmpeg -list_options` (anything
    //      the cam actually advertises).
    //   4. CameraConfig defaults (transcode_mjpeg_to_h264 @ 640x480@30).
    // Probe-summary recommendations are deliberately ignored -- the
    // probe-camera.ps1 frame-count check has documented false positives
    // (CLAUDE.md codec matrix).
    auto resolveCameraConfig = [&](std::wstring_view                    name,
                                    const std::string&                   vid_pid,
                                    const std::vector<AdvertisedFormat>& formats,
                                    CameraConfig&                       cc) {
        auto ov = LoadOverride(probesDir, name);
        auto known = !vid_pid.empty() ? knownDb.Lookup(vid_pid) : std::nullopt;
        DefaultPick smart = PickDefaultFromFormats(formats);

        // Choose per-field with explicit fallthrough so a partial override
        // file can leave some fields to the DB / smart pick.
        if (ov && ov->mode)       cc.mode = *ov->mode;
        else if (known)           cc.mode = known->mode;
        else                      cc.mode = smart.mode;

        cc.width  = (ov && ov->width)  ? *ov->width
                    : (known ? known->width  : smart.width);
        cc.height = (ov && ov->height) ? *ov->height
                    : (known ? known->height : smart.height);
        cc.fps    = (ov && ov->fps)    ? *ov->fps
                    : (known ? known->fps    : smart.fps);

        if (known) {
            Info("cam '" + WideToUtf8(name) + "' matched known-cameras DB entry '" +
                 vid_pid + "' (" + known->label + ")");
        }

        // Enabled flag: override beats settings.json default. A camera with
        // no override file and no settings.json gets enabled=true.
        if (ov && ov->enabled) cc.enabled = *ov->enabled;
        else                   cc.enabled = settings.default_enabled_for_new_cameras;
    };

    // Enumerate advertised formats once per cam at startup. Each call is
    // ~1s so the loop adds 1-3s to startup -- acceptable since the
    // alternative is a hard-coded default that may not match the cam.
    // The format lists are stored on each CamSlot below and re-surfaced
    // every time list-cameras runs (no need to re-enumerate later).
    std::vector<std::vector<AdvertisedFormat>> formatsPerCam;
    formatsPerCam.reserve(cams.size());
    for (const auto& d : cams) {
        formatsPerCam.push_back(EnumerateFormats(ffExe, d.friendly_name));
    }

    std::vector<CameraConfig> camConfigs;
    {
        int idx = 0;
        for (size_t i = 0; i < cams.size(); ++i) {
            CameraConfig cc;
            cc.friendly_name = cams[i].friendly_name;
            cc.rtsp_path     = L"/webcam" + std::to_wstring(idx++);
            resolveCameraConfig(cams[i].friendly_name, cams[i].vid_pid,
                                formatsPerCam[i], cc);
            Info("cam '" + WideToUtf8(cams[i].friendly_name) + "' -> path " +
                 WideToUtf8(cc.rtsp_path) +
                 " mode=" + ModeName(cc.mode) +
                 " " + std::to_string(cc.width) + "x" + std::to_string(cc.height) +
                 "@" + std::to_string(cc.fps));
            camConfigs.push_back(std::move(cc));
        }
    }

    JobObject job;

    // Indirection: the mediamtx stdout scraper needs to publish events on
    // the IPC pipe, but IpcServer is constructed further down. We capture
    // `&ipc_ptr` by reference into the scraper lambda; once IpcServer is
    // built, we set ipc_ptr to point at it. Auth-failure log lines emitted
    // before that brief window get dropped (no harm; no client is connected
    // yet anyway).
    IpcServer* ipc_ptr = nullptr;

    // Regex for MediaMTX 1.18.x digest auth-failure log lines, of the form:
    //   2026/05/19 01:03:16 INF [RTSP] [conn 127.0.0.1:59328] closed: authentication failed: ...
    // Pinned to this version line via setup-deps.ps1's MediaMTX bundle.
    // If MediaMTX changes wording in a future release, the regex stops
    // matching -- visibility loss is the failure mode, not a crash.
    std::regex authFailRe(
        R"(\[RTSP\] \[conn ([^:\]]+):\d+\] closed: authentication failed)");

    ProcessConfig mtxCfg{
        .exe_path      = mtxExe.wstring(),
        .args          = { runtimeMtxYml.wstring() },   // substituted template
        .friendly_name = L"mediamtx",
        .on_stdout_line = [&ipc_ptr, authFailRe](const std::string& line) {
            // Always forward to our log so mediamtx output stays visible.
            Info(std::string("[mtx] ") + line);
            // Match auth-failure shape and emit a structured IPC event so
            // the host app can raise a toast. Best-effort: drops if ipc
            // isn't up yet.
            std::smatch m;
            if (ipc_ptr && std::regex_search(line, m, authFailRe)) {
                nlohmann::json out;
                out["reader_ip"] = m.str(1);
                out["reason"]    = "authentication failed";
                ipc_ptr->PublishEvent("viewer-auth-failed", out);
            }
        },
    };
    auto mtx = std::make_unique<SupervisedProcess>(mtxCfg, job);
    Backoff bMtx;
    StartNoSleep(*mtx, bMtx);

    if (!WaitForRtspReady(8554, 10s)) {
        Error("mediamtx did not become ready on :8554 within 10s");
        return 4;
    }
    Info("mediamtx ready on :8554");

    const std::wstring publisher = L"rtsp://publisher:publisher@127.0.0.1:8554";

    std::vector<CamSlot> slots;
    slots.reserve(camConfigs.size());
    for (size_t i = 0; i < camConfigs.size(); ++i) {
        CamSlot s;
        s.cfg      = camConfigs[i];
        s.formats  = formatsPerCam[i];
        s.alt_name = cams[i].alt_name;
        s.vid_pid  = cams[i].vid_pid;
        s.proc     = std::make_unique<SupervisedProcess>(
                         MakeFFmpegProcessConfig(ffExe, camConfigs[i], publisher), job);
        slots.push_back(std::move(s));
    }
    // Only start the ffmpeg publishers for ENABLED cameras. Disabled cams
    // keep their SupervisedProcess object (so set-stream-enabled true later
    // can just Start() it) but never spawn ffmpeg.
    for (auto& s : slots) {
        if (s.cfg.enabled) StartNoSleep(*s.proc, s.backoff);
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
        s.backoff      = Backoff{};
        // When the publisher process is rebuilt, MediaMTX may not deliver
        // unread events for the readers attached to the prior path. Reset
        // the count so the UI doesn't show ghost viewers.
        s.viewer_count = 0;
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
                            StartNoSleep(*s.proc, s.backoff);
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
                        StartNoSleep(*s.proc, s.backoff);
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
                                StartNoSleep(*s.proc, s.backoff);
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
    ipc_ptr = &ipc;   // unblocks the mediamtx-stdout auth-failure publisher
    ipc.Start();
    Info("ipc: serving on \\\\.\\pipe\\webcam-streamer-supervisor");

    // ----- Events pipe: mtx_event_hook.exe -> us -----
    // For each hook invocation, look up the path -> CamSlot, derive a friendly
    // payload (camera name, codec, resolution), and republish on the control
    // pipe as a `viewer-connected` / `viewer-disconnected` event.
    auto codecForMode = [](Mode m) -> const char* {
        switch (m) {
            case Mode::PassthroughH264:
            case Mode::TranscodeMjpegToH264:
            case Mode::TranscodeRawToH264:
                return "H.264";
            case Mode::PassthroughMjpeg:
            case Mode::TranscodeRawToMjpeg:
                return "MJPEG";
            default:
                return "unknown";
        }
    };

    EventsPipeServer events(L"\\\\.\\pipe\\webcam-streamer-events",
        [&](const nlohmann::json& msg) {
            std::string ev_type   = msg.value("event",       std::string{});
            std::string mtx_path  = msg.value("path",        std::string{});
            std::string reader_ip = msg.value("reader_ip",   std::string{});
            std::string user      = msg.value("reader_user", std::string{});

            json out;
            out["path"]        = "/" + mtx_path;
            out["reader_ip"]   = reader_ip;
            out["reader_user"] = user;
            std::wstring wpath = Utf8ToWide(mtx_path);
            const char* name = (ev_type == "read") ? "viewer-connected"
                              : (ev_type == "unread") ? "viewer-disconnected"
                              : nullptr;
            if (!name) {
                Warn("events-pipe: unknown event type '" + ev_type + "'");
                return;
            }
            // Mutate the matched slot's viewer_count and republish
            // camera-state-changed so every UI surface (DataGrid status pill,
            // tray tooltip, tray submenu) derives its visual from a single
            // authoritative count -- no UI-side tally that could drift.
            json stateEvent;
            bool haveStateEvent = false;
            {
                std::lock_guard<std::mutex> g(state_mutex);
                auto it = std::find_if(slots.begin(), slots.end(),
                    [&](const CamSlot& s) {
                        std::wstring w = s.cfg.rtsp_path;
                        if (!w.empty() && w.front() == L'/') w.erase(0, 1);
                        return w == wpath;
                    });
                if (it != slots.end()) {
                    out["camera"]     = WideToUtf8(it->cfg.friendly_name);
                    out["mode"]       = ModeName(it->cfg.mode);
                    out["codec"]      = codecForMode(it->cfg.mode);
                    out["width"]      = it->cfg.width;
                    out["height"]     = it->cfg.height;
                    if (ev_type == "read") it->viewer_count++;
                    else if (ev_type == "unread" && it->viewer_count > 0) it->viewer_count--;
                    stateEvent     = CamToJson(*it);
                    haveStateEvent = true;
                } else {
                    out["camera"]     = mtx_path;
                    out["mode"]       = "unknown";
                    out["codec"]      = "unknown";
                }
            }
            ipc.PublishEvent(name, out);
            if (haveStateEvent) ipc.PublishEvent("camera-state-changed", stateEvent);
            Info(std::string(name) + ": cam='" + out.value("camera", std::string{}) +
                 "' reader=" + reader_ip);
        });
    events.Start();

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

            auto now = std::chrono::steady_clock::now();

            if (!mtx->IsRunning()) {
                if (now >= bMtx.earliest_next) {
                    Warn("mediamtx exited code=" + std::to_string(mtx->GetExitCode()));
                    mtx->Stop();
                    StartNoSleep(*mtx, bMtx);
                    WaitForRtspReady(8554, 10s);
                    ipc.PublishEvent("mediamtx-state-changed",
                                     json{{"running", mtx->IsRunning()}});
                }
            }

            for (auto& s : slots) {
                if (!s.present || !s.cfg.enabled) {
                    // Disabled or unplugged: ensure ffmpeg is dead and
                    // do not auto-restart. last_running is kept in sync so
                    // the next transition (re-enable or re-plug) fires a
                    // state-change event.
                    if (s.last_running || s.viewer_count != 0) {
                        s.last_running = false;
                        s.viewer_count = 0;
                        ipc.PublishEvent("camera-state-changed", CamToJson(s));
                    }
                    continue;
                }
                bool running_now = s.proc->IsRunning();
                // Reset viewer_count when the publisher is down -- otherwise
                // the count would stick if MediaMTX failed to deliver unread
                // events for readers attached at the moment of crash.
                if (!running_now && s.viewer_count != 0) s.viewer_count = 0;
                if (!running_now && now >= s.backoff.earliest_next) {
                    // Backoff window elapsed -- attempt restart. StartNoSleep
                    // doubles the delay; if ffmpeg fails again immediately, the
                    // next attempt is deferred. The supervision loop never
                    // sleeps with state_mutex held, so IPC handlers stay
                    // responsive throughout a restart storm.
                    Warn(WideToUtf8(s.proc->Name()) + " exited code=" +
                         std::to_string(s.proc->GetExitCode()));
                    s.proc->Stop();
                    StartNoSleep(*s.proc, s.backoff);
                    running_now = s.proc->IsRunning();
                }
                if (running_now != s.last_running) {
                    ipc.PublishEvent("camera-state-changed", CamToJson(s));
                    s.last_running = running_now;
                }
            }
        }

        // Phase 2: periodic re-enumeration for plug/unplug detection.
        // EnumerateCameras + EnumerateFormats both spawn ffmpeg as a
        // subprocess (~1s each); we run them WITHOUT state_mutex held so
        // IPC handlers stay responsive even when a new cam is being
        // discovered. Mutations to `slots` happen in short re-locked
        // sections at the start (presence diffs) and end (appending new
        // cams with their freshly-enumerated formats).
        auto now = std::chrono::steady_clock::now();
        if (now - lastEnum > 10s) {
            lastEnum = now;
            auto current = EnumerateCameras(ffExe);   // unlocked; ~1s

            // Step 1: presence diff + collect new-device list. Short lock.
            std::vector<CameraDevice> newDevices;
            bool                      listChanged = false;
            {
                std::lock_guard<std::mutex> g(state_mutex);
                std::set<std::wstring> currentSet;
                for (auto& d : current) currentSet.insert(d.friendly_name);
                std::set<std::wstring> knownSet;
                for (auto& s : slots) knownSet.insert(s.cfg.friendly_name);

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
                            StartNoSleep(*s.proc, s.backoff);
                        } else {
                            Info("  (kept disabled per user setting)");
                        }
                        listChanged = true;
                    }
                }

                for (auto& d : current) {
                    if (!knownSet.count(d.friendly_name)) newDevices.push_back(d);
                }
            }

            // Step 2: enumerate formats for brand-new cams. Unlocked --
            // takes ~1s per cam; we'd block every IPC call if this ran
            // under state_mutex.
            std::vector<std::vector<AdvertisedFormat>> newFormats;
            newFormats.reserve(newDevices.size());
            for (auto& d : newDevices) {
                newFormats.push_back(EnumerateFormats(ffExe, d.friendly_name));
            }

            // Step 3: re-acquire lock, append new slots. Re-check knownSet
            // in case the unlocked window let another path add slots (the
            // IPC handlers can't add cams today, but defensive).
            if (!newDevices.empty() || listChanged) {
                std::lock_guard<std::mutex> g(state_mutex);
                std::set<std::wstring> knownSet;
                for (auto& s : slots) knownSet.insert(s.cfg.friendly_name);

                for (size_t i = 0; i < newDevices.size(); ++i) {
                    const auto& d = newDevices[i];
                    if (knownSet.count(d.friendly_name)) continue;
                    CamSlot s;
                    s.cfg.friendly_name = d.friendly_name;
                    s.cfg.rtsp_path     = allocPath();
                    s.formats           = newFormats[i];
                    s.alt_name          = d.alt_name;
                    s.vid_pid           = d.vid_pid;
                    resolveCameraConfig(d.friendly_name, d.vid_pid, s.formats, s.cfg);
                    s.present = true;
                    Info("camera added: " + WideToUtf8(d.friendly_name) +
                         " vid_pid='" + d.vid_pid + "' -> path " +
                         WideToUtf8(s.cfg.rtsp_path) + " mode=" + ModeName(s.cfg.mode) +
                         " " + std::to_string(s.cfg.width) + "x" + std::to_string(s.cfg.height) +
                         "@" + std::to_string(s.cfg.fps) +
                         " enabled=" + (s.cfg.enabled ? "true" : "false"));
                    s.proc = std::make_unique<SupervisedProcess>(
                                 MakeFFmpegProcessConfig(ffExe, s.cfg, publisher), job);
                    slots.push_back(std::move(s));
                    if (slots.back().cfg.enabled) {
                        StartNoSleep(*slots.back().proc, slots.back().backoff);
                    }
                    listChanged = true;
                }

                if (listChanged) ipc.PublishEvent("cameras-changed", AllCamsJson(slots));
            }
        }
    }

    Info("stopping ipc...");
    ipc.Stop();
    events.Stop();
    Info("stopping children...");
    for (auto& s : slots) s.proc->Stop();
    mtx->Stop();
    Info("supervisor exit.");
    return 0;
}
