# ADR 0001 — Supervisor stays a user-session child, not a Windows Service

**Date**: 2026-05-17
**Status**: Accepted

## Context

When planning the installer + tray + notifications package, "start service on Windows start" was a top-line user requirement. The natural literal reading is a Windows Service. But:

- The current architecture (process model A3, locked in the original design interrogation) has the WPF UI own the supervisor via a Job Object with `KILL_ON_JOB_CLOSE`.
- A Windows Service runs in session 0, where DirectShow capture is not reliably available — vendor camera filters and per-session helper services routinely break dshow capture from session 0, and `-list_devices` succeeding does not imply `-i video=…` will succeed.
- A service install requires UAC; the user wants both per-user (no elevation) and per-machine install paths.
- A service forces multi-client IPC (today's pipe is single-client by design) and cross-session pipe ACLs.

## Decision

The supervisor stays a user-session process. A new **tray host** process owns the Job Object containing the supervisor; the WPF window becomes a transient view spawned by the tray host.

"Start on Windows start" is implemented as **start on user logon** via a per-user Scheduled Task (or Startup-folder shortcut). On the single-user streaming PC this is indistinguishable from boot-time start for practical purposes.

## Consequences

**Accepted costs**
- Cameras only start streaming after a user logs in. If the PC reboots at 3 AM and nobody logs in, no streams come up until logon.
- The Job-Object-owning process is now the tray host, not the WPF window. The current `SupervisorLauncher.cs` logic moves into the tray app; the WPF window stops owning the supervisor.

**Benefits**
- No session 0 dshow risk.
- No admin requirement for the default install.
- IPC stays single-client (tray host is the only client; WPF window talks to the supervisor *through* the tray host, or shares its in-memory state).
- Existing verify scripts continue to work — `supervisor.exe` still runs as a normal console process.

**Reversibility**
- Migrating to a Windows Service later (true A1) is still possible: the supervisor's `wmain` would gain a `SERVICE_TABLE_ENTRY` branch; the tray host would become a pure client. The IPC pipe is already the right abstraction.
