# ADR 0002 — "Stream all webcams by default" installer choice persists as hot-plug policy

**Date**: 2026-05-17
**Status**: Accepted

## Context

The installer offers a checkbox "Stream all webcams by default". The straightforward reading is that it only bootstraps the `enabled` flag of cameras enumerated at first run. But the supervisor also detects hot-plug events at runtime (`supervisor/src/main.cpp:490-538`); we had to decide what `enabled` value a freshly-discovered camera gets after that first run.

Three candidates were considered:
- (a) Hot-plugged cams always default to `enabled=false` (privacy-first; opt-in).
- (b) Hot-plugged cams always default to `enabled=true` (matches today's behavior).
- (c) Persist the installer choice as a policy that also governs hot-plug.

## Decision

Adopt (c). The installer's "Stream all webcams by default" checkbox is persisted to a settings key — `default_enabled_for_new_cameras: bool` — that is also applied when a new camera appears at runtime.

The setting is surfaced (read-write) in the WPF window under "Defaults", so a user can flip it after install without reinstalling.

## Consequences

**Accepted costs**
- One extra piece of persistent state in the supervisor's settings file.
- The supervisor must read this setting when constructing a new `CamSlot` for a hot-plugged camera (the path in `main.cpp:521-538`).

**Benefits**
- The installer checkbox does what the label says: "all webcams" includes future ones, not just today's set.
- Users who explicitly want privacy-on-hot-plug get it (uncheck the box at install, leave it unchecked). Users who want "always on" get it (check the box, leave it). No surprise either way.
- Reversible — surfaced in the UI as a normal setting.

## Reversibility

If we later decide privacy-first is the right hot-plug default unconditionally, we can demote this setting to a one-time bootstrap by ignoring it after first run. The persisted key stays; the supervisor just stops reading it on hot-plug. Cheap.
