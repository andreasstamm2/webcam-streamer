# Installer

This folder produces the offline `WebcamStreamerSetup-vX.Y.Z.exe` installer.

## What's in the box

The installer bundles **everything** needed to run, so end users do not
have to download anything separately and the install works fully offline:

- `WebcamStreamerUi.exe` — the WPF UI, published self-contained with the
  .NET 9 runtime embedded (no need to install .NET separately).
- `supervisor.exe` — the C++ process supervisor.
- `mediamtx.exe` + `config\mediamtx.yml` — the RTSP server and its config.
- `ffmpeg.exe`, `ffprobe.exe` — the gyan.dev GPL build of FFmpeg.
- `LICENSE`, `THIRD_PARTY_NOTICES.md`, `mediamtx-LICENSE.txt` — legal text.

It also:

- Installs to `C:\Program Files\WebcamStreamer\` (requires admin).
- Creates Start Menu + optional desktop shortcuts.
- Adds a Windows Firewall inbound rule for TCP `8554` (RTSP), pinned to
  the bundled `mediamtx.exe` only.
- Registers an uninstaller in **Add or Remove Programs**.

## Prerequisites (build host)

1. **Inno Setup 6.2+** — https://jrsoftware.org/isdl.php  
   Default install path is fine; if you put it elsewhere, pass
   `-IsccPath` to the build script.
2. **Visual Studio 2022 with Desktop C++** — for the supervisor build.
3. **.NET 9 SDK** — https://dotnet.microsoft.com/download/dotnet/9.0
4. Third-party binaries downloaded — run `..\scripts\setup-deps.ps1`
   once.

## Build

From the repo root in a developer PowerShell:

```powershell
.\installer\build-installer.ps1 -Version 0.1.0
```

This will, in order:

1. Build `supervisor.exe` in Release with CMake/MSVC.
2. `dotnet publish` the UI as a self-contained, single-file, ReadyToRun
   exe into `ui\WebcamStreamerUi\publish\`.
3. Run Inno Setup against `setup.iss` and produce
   `installer\output\WebcamStreamerSetup-v0.1.0.exe`.

A typical full build takes 1–3 minutes; the output installer is roughly
~140 MB (FFmpeg accounts for most of that).

## Versioning

The version string is *only* passed via `-Version` (or `/DAppVersion=` if
you call ISCC manually). It controls:

- The installer filename.
- The version shown in **Add or Remove Programs**.
- The `VersionInfoVersion` baked into the installer's PE metadata.

Bump it in lockstep with the git tag you cut for the release
(`git tag v0.1.0 ...`).

## Before the first public release

Open `setup.iss` and:

- Replace the `AppId` GUID with one you generate **once** (in the Inno
  Setup Compiler: Tools → Generate GUID). After your first release this
  GUID must NEVER change — it's how Windows recognises upgrades vs. side-
  by-side installs of the same product.
- Replace the `AppURL` placeholder with the actual GitHub URL.

## Code signing (optional)

The script is structured to support code signing — see the commented-out
`SignTool=` directive in `setup.iss`. Without a signing certificate, the
installer triggers Windows SmartScreen on first run; users have to click
**More info → Run anyway**. With a standard OV cert this warning subsides
after a few hundred downloads build reputation; with an EV cert it goes
away immediately.

## CI integration

A GitHub Actions workflow (`.github/workflows/release.yml`, future work)
should run this script on every `v*` tag push and attach the resulting
`.exe` to the corresponding GitHub Release.
