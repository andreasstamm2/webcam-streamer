; =============================================================================
; webcam_streamer — Inno Setup script
;
; Produces a single offline installer that bundles:
;   * WebcamStreamerUi.exe       (self-contained, .NET runtime embedded)
;   * supervisor.exe             (C++ Release build)
;   * mediamtx.exe + config      (MediaMTX 1.18.x)
;   * ffmpeg.exe                 (gyan.dev "essentials" GPL build)
;   * LICENSE, THIRD_PARTY_NOTICES.md, mediamtx LICENSE
;
; Build:
;   1. From a developer PowerShell at the repo root, run:
;        installer\build-installer.ps1
;      That script publishes the WPF UI self-contained, ensures the
;      supervisor is built in Release, then invokes ISCC on this file.
;   2. Or, manually:
;        ISCC.exe /DAppVersion=0.1.0 installer\setup.iss
;
; Output:
;   installer\output\WebcamStreamerSetup-vX.Y.Z.exe
;
; Requires Inno Setup 6.2+ (https://jrsoftware.org/isdl.php).
; =============================================================================

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName       "Webcam Streamer"
#define AppPublisher  "webcam_streamer contributors"
#define AppURL        "https://github.com/REPLACE_ME/webcam_streamer"
#define AppExeName    "WebcamStreamerUi.exe"

; Repo-root-relative paths. ISCC's `SourceDir` is the directory containing
; this .iss file, so all source paths walk up one level.
#define RepoRoot      ".."
#define UiPublishDir  RepoRoot + "\ui\WebcamStreamerUi\publish"
#define SupervisorExe RepoRoot + "\supervisor\build\Release\supervisor.exe"
#define MediaMtxDir   RepoRoot + "\third_party\mediamtx"
#define FfmpegDir     RepoRoot + "\third_party\ffmpeg"
#define ConfigDir     RepoRoot + "\config"

[Setup]
; A stable GUID identifies the app across versions for upgrade/uninstall.
; Generate ONCE with the Inno Setup Compiler (Tools → Generate GUID), then
; never change it. The placeholder below MUST be replaced before first
; release.
AppId={{8F2B7A1E-3C4D-4E5F-9A6B-7C8D9E0F1A2B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}

DefaultDirName={autopf}\WebcamStreamer
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}

; License shown on the welcome page. Users must accept to continue.
LicenseFile={#RepoRoot}\LICENSE

; 64-bit only.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Per-machine install (writes to C:\Program Files). Requires elevation.
PrivilegesRequired=admin

OutputDir=output
OutputBaseFilename=WebcamStreamerSetup-v{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; Optional code-signing hook. To enable, install your signtool and pass
; /S"signtool=signtool.exe sign /a $f" on the ISCC command line. Until
; then, leave commented out — installs still work, just trigger SmartScreen.
;SignTool=signtool

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "firewall";    Description: "Allow Webcam Streamer through the Windows Firewall (RTSP port 8554)"; GroupDescription: "Network:"; Flags: checkedonce

[Files]
; --- Main app: WPF UI (self-contained single-file publish) ---
; PublishSingleFile bundles native deps; everything in publish/ goes in.
Source: "{#UiPublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- C++ supervisor ---
Source: "{#SupervisorExe}";  DestDir: "{app}"; Flags: ignoreversion

; --- MediaMTX (RTSP server) + its LICENSE for compliance ---
Source: "{#MediaMtxDir}\mediamtx.exe"; DestDir: "{app}\third_party\mediamtx"; Flags: ignoreversion
Source: "{#MediaMtxDir}\LICENSE";       DestDir: "{app}\third_party\mediamtx"; DestName: "mediamtx-LICENSE.txt"; Flags: ignoreversion

; --- FFmpeg (GPL build) ---
Source: "{#FfmpegDir}\ffmpeg.exe";  DestDir: "{app}\third_party\ffmpeg"; Flags: ignoreversion
Source: "{#FfmpegDir}\ffprobe.exe"; DestDir: "{app}\third_party\ffmpeg"; Flags: ignoreversion

; --- MediaMTX runtime config ---
Source: "{#ConfigDir}\mediamtx.yml"; DestDir: "{app}\config"; Flags: ignoreversion

; --- Legal text shipped with the install ---
Source: "{#RepoRoot}\LICENSE";               DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md";              DestDir: "{app}"; Flags: ignoreversion

[Dirs]
; The supervisor writes probe summaries here at runtime. Pre-create with
; user-writable ACLs because Program Files\* is admin-only by default.
Name: "{app}\probes"; Permissions: users-modify

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
; Windows Firewall rule (RTSP listener on TCP 8554 — UDP is disabled in
; mediamtx.yml). Idempotent: deletes any prior rule first.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Webcam Streamer (RTSP)"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Webcam Streamer (RTSP)"" dir=in action=allow protocol=TCP localport=8554 program=""{app}\third_party\mediamtx\mediamtx.exe"" enable=yes"; Flags: runhidden; Tasks: firewall

; Offer to launch immediately after install finishes.
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Remove the firewall rule we created.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Webcam Streamer (RTSP)"""; Flags: runhidden

[UninstallDelete]
; The probes directory contains runtime-generated files not tracked by
; the installer manifest — remove on uninstall so we leave a clean tree.
Type: filesandordirs; Name: "{app}\probes"
