# ADR 0003 — Viewer-connection events flow through a helper exe + dedicated named pipe; auth failures via MediaMTX stdout scraping

**Date**: 2026-05-17
**Status**: Accepted

## Context

We want toast notifications for two viewer-side events:

1. **Success**: a viewer (VLC, WebEye, ffplay) successfully connected to a camera stream. Notification carries camera name, format/codec, reader IP, reader user.
2. **Failure**: an authentication attempt failed (wrong credentials). Notification carries the reason.

MediaMTX exposes these signals heterogeneously:

- For **successful reader connect/disconnect**, MediaMTX provides per-path `runOnRead` / `runOnUnread` hooks that spawn an arbitrary command with `MTX_*` environment variables (path, reader IP, reader port, reader user, protocol). The command is a separate child process whose stdout does **not** flow back into MediaMTX's stdout.
- For **failed authentication**, MediaMTX provides no hook at all. The only signal is a line in MediaMTX's own stdout log.
- For **state snapshots**, MediaMTX also exposes an HTTP API (`apiAddress`), which the supervisor could poll instead of using `runOnRead`.

## Decision

**Successful viewer connects** are pushed to the supervisor via a small purpose-built helper binary plus a dedicated event named pipe:

- **`mtx_event_hook.exe`** — a static, single-source-file C++ binary built alongside the supervisor. MediaMTX's `mediamtx.yml` registers it as the `runOnRead` and `runOnUnread` command. On invocation it reads the `MTX_*` env vars, opens `\\.\pipe\webcam-streamer-events` in write mode, writes one UTF-8 JSON line `{type: "viewer-connected" | "viewer-disconnected", path, reader_ip, reader_port, reader_user, protocol}`, then exits.
- **The events pipe** is created by the supervisor at startup, separate from the existing control pipe `\\.\pipe\webcam-streamer-supervisor`. It accepts many short connections; readers don't speak back. ACL is current-user-only.
- The supervisor consumes each line, joins it with its own per-path knowledge (camera friendly name, current Mode) to enrich the payload, and republishes it on the control pipe as a `viewer-connected` / `viewer-disconnected` IPC event for the host app to render as a toast.

**Failed authentication** is detected by scraping MediaMTX's own stdout:

- The supervisor already runs MediaMTX as a child process. It additionally captures the child's stdout stream, pattern-matches lines for auth-failure signatures, and emits a `viewer-auth-failed` IPC event with `{reader_ip, reason}`.
- The exact regex is pinned to a known MediaMTX version range.

To keep the stdout-scrape robust against MediaMTX version drift:

- **`scripts/setup-deps.ps1` pins MediaMTX to a specific release**, instead of "latest". Today the script grabs the latest GitHub release; that becomes a hard-coded version string (chosen at implementation time from the 1.18.x line).
- A small `scripts/verify-mediamtx-logs.ps1` (to be written alongside the implementation) deliberately authenticates with wrong credentials against a fresh MediaMTX and asserts that the supervisor's regex matches. Run as part of the canonical regression set.

## Alternatives considered

- **HTTP API polling** — supervisor polls `/v3/paths/list` every 200-500 ms and diffs the reader set. Rejected because: (a) auth failures still require stdout scraping, so the supervisor needs that plumbing anyway; (b) polling has a non-zero idle cost when nothing is happening; (c) latency bounded by poll interval rather than ~10 ms via push. The HTTP API may still be enabled later for the WPF window's "current viewers" snapshot view.
- **Loopback TCP** instead of a named pipe — rejected because the events channel benefits from named pipes' free localhost-only scope, per-user ACL, no firewall dialog, no port-allocation problem, and symmetry with the existing control pipe.
- **`runOnRead` writing to MediaMTX's stdout** (original sketch) — does not work; `runOnRead`'s child stdout is not captured by MediaMTX.

## Consequences

**New artifacts**
- `mtx_event_hook.exe` — one more binary in the install bundle. Built from the supervisor's CMake project as a second target.
- A second named pipe (`\\.\pipe\webcam-streamer-events`) and a small accept-loop in the supervisor.
- A stdout reader thread on the MediaMTX child process, plus an auth-failure regex.
- `scripts/verify-mediamtx-logs.ps1` — new regression check.

**Brittleness mitigations**
- Pinned MediaMTX version (no automatic upgrade).
- Regex tested in CI-equivalent verify script. Bumping MediaMTX is a deliberate action that includes re-running this verify.

**Reversibility**
- If MediaMTX later adds a `runOnAuthFail` hook (or webhook variant), we drop the stdout scrape and route auth failures through the helper exe too. Trivial change in `mediamtx.yml` + delete the regex.
- If the helper-exe spawn cost ever matters (it won't for our viewer counts), the HTTP API poller is the replacement, and the supervisor's diff logic for emitting per-viewer events stays the same.
