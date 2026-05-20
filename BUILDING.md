# Building webcam_streamer

This document captures the **pinned tool versions** every release build
targets. Local builds and the GitHub Actions release workflow both use
these exact pins so the two paths produce equivalent installers. See
the v0.3.0..v0.3.6 commit trail for what went wrong when they drifted.

If you're setting up a fresh dev machine, install the items in
**Required tools** below, then run `scripts/check-build-env.ps1` —
green means you're ready to build a release. Drift output indicates
exactly which pin doesn't match what you have.

## Required tools (pinned)

| Tool | Version | How CI installs it | How to install locally |
|---|---|---|---|
| **Inno Setup** | **6.7.2** | `scripts/install-inno-setup.ps1` downloads `innosetup-6.7.2.exe` from `github.com/jrsoftware/issrc/releases` into `tools/inno-setup-6.7.2/` | Same — `scripts/install-inno-setup.ps1` (run once; cached). Or install Inno Setup 6.7.2 by hand and set `$env:INNO_SETUP_EXE`. |
| **.NET SDK** | **9.0.308** | `actions/setup-dotnet@v4` with `dotnet-version: 9.0.308` | Install from https://dotnet.microsoft.com/download/dotnet/9.0 (pick the 9.0.308 SDK installer or newer; bump pins if newer). |
| **CMake** | 3.31+ | Bundled with the `windows-latest` runner image | Install Visual Studio 2022 with the C++ workload (includes CMake), or `winget install Kitware.CMake`. |
| **Visual Studio 2022 / MSVC** | 17.x | Bundled with the runner image; activated via `ilammy/msvc-dev-cmd@v1` | Install Visual Studio 2022 Community with the **Desktop development with C++** workload. |
| **MediaMTX** | **v1.18.2** | `scripts/setup-deps.ps1` downloads `mediamtx_v1.18.2_windows_amd64.zip` from `github.com/bluenviron/mediamtx` into `third_party/mediamtx/` | Same — `scripts/setup-deps.ps1` (idempotent). |
| **FFmpeg** | **8.1.1** | `scripts/setup-deps.ps1` downloads `ffmpeg-8.1.1-essentials_build.zip` from `github.com/GyanD/codexffmpeg` into `third_party/ffmpeg/` | Same. |
| **nlohmann/json** | **v3.12.0** | `scripts/setup-deps.ps1` downloads `json.hpp` into `supervisor/third_party/nlohmann/` | Same. |

## Verifying the environment

```powershell
.\scripts\check-build-env.ps1
```

Exits 0 when everything matches the pins. Drift output looks like:

```
[DRIFT] .NET SDK         : 9.0.308   (expected 9.0.314)
```

— meaning the pin is 9.0.314 but you have 9.0.308 installed.

## Building a local installer

```powershell
.\scripts\setup-deps.ps1            # once per checkout (idempotent)
.\installer\build-installer.ps1 -Version 0.3.7
```

The build-installer script:

1. Calls `install-inno-setup.ps1` to ensure the pinned Inno Setup is
   under `tools\` (cached after first run).
2. Builds the C++ supervisor in Release.
3. Publishes the WPF UI self-contained.
4. Invokes ISCC to produce `installer\output\WebcamStreamerSetup-vX.Y.Z.exe`.

If you have a pre-existing Inno Setup install you'd rather use, set
`$env:INNO_SETUP_EXE` to its full path before running. Otherwise
build-installer.ps1 uses the pinned one under `tools\`.

## Bumping a pinned version

Pinned versions live in **five** places that must stay in lockstep:

| File | What it pins |
|---|---|
| `scripts/install-inno-setup.ps1` | `-Version` default for Inno Setup |
| `scripts/setup-deps.ps1` | `$MEDIAMTX_VERSION`, `$FFMPEG_VERSION`, `$NLOHMANN_VERSION` |
| `.github/workflows/release.yml` | `dotnet-version` for the .NET SDK |
| `scripts/check-build-env.ps1` | `$EXPECT_*` constants (the drift detector) |
| `BUILDING.md` (this file) | the human-readable table above |

Bump procedure:

1. Update the relevant pin(s) in those files.
2. Wipe the affected dirs locally (`third_party\mediamtx\`, `tools\inno-setup-OLD\`, etc.) so `setup-deps.ps1` / `install-inno-setup.ps1` re-download.
3. Run `scripts\check-build-env.ps1` — must be green.
4. Run `installer\build-installer.ps1 -Version X.Y.Z` to sanity-check the local build.
5. Commit + tag + push; the release workflow uses the new pin automatically.

## Architectural background: why so much pinning

In v0.3.0..v0.3.5 the release workflow was using `choco install innosetup`
which silently shipped an Inno Setup old enough that its Pascal Script
engine rejected modern symbols (local `const`, `Randomize`,
`GetTickCount`). Locally the dev had a current Inno Setup, so the
local builds worked; CI builds failed in dialect-specific ways. The
v0.3.6 fix pinned Inno Setup to a specific upstream binary. The v0.3.7
pass extended the same logic to every other tool/asset the build
depends on. See ADR notes in CONTEXT.md (local) for the broader rationale.
