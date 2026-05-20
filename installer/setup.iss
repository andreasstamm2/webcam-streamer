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
#define HookExe       RepoRoot + "\supervisor\build\Release\mtx_event_hook.exe"
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

; Dual-mode install: user picks per-user (default, no UAC, lands in
; %LOCALAPPDATA%\Programs\WebcamStreamer) or per-machine (UAC prompt,
; lands in Program Files). The privilege dialog appears early in the
; wizard. DefaultDirName={autopf}\WebcamStreamer resolves to the right
; root for whichever mode was picked.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

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
; "Stream all webcams by default" -- written into settings.json post-install
; via [Code]::CurStepChanged. The supervisor reads this on startup AND on
; hot-plug (see ADR 0002). User can flip it later from the WPF Settings
; dialog (Slice E).
Name: "streamall";   Description: "Stream all detected webcams by default"; GroupDescription: "Default behaviour:"; Flags: checkedonce

; "Start on Windows logon" -- HKCU\...\Run\WebcamStreamer pointing at the
; host exe. Per ADR 0001 we run in the user session, not as a Windows
; Service, so HKCU is correct. The WPF Settings dialog can toggle this
; later without reinstalling.
Name: "autostart";   Description: "Start automatically when I log in to Windows"; GroupDescription: "Default behaviour:"; Flags: checkedonce

Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

; Firewall rule for MediaMTX (RTSP port 8554). The rule lives in the
; system policy store, so creating it always requires Administrator.
; On a per-machine install the wizard is already elevated and no extra
; UAC popup appears. On a per-user install the [Code] handler escalates
; just this step via ShellExec('runas', ...) -- the user sees one UAC
; prompt scoped to the firewall change. If they decline, the rest of
; the install still completes.
Name: "firewall";    Description: "Allow Webcam Streamer through the Windows Firewall (RTSP port 8554) — requires Administrator approval"; GroupDescription: "Network:"; Flags: checkedonce

[Files]
; --- Main app: WPF UI (self-contained single-file publish) ---
; PublishSingleFile bundles native deps; everything in publish/ goes in.
Source: "{#UiPublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; --- C++ supervisor + helper exe (Slice B: runOnRead/runOnUnread hook) ---
Source: "{#SupervisorExe}";  DestDir: "{app}"; Flags: ignoreversion
Source: "{#HookExe}";        DestDir: "{app}"; Flags: ignoreversion

; --- MediaMTX (RTSP server) + its LICENSE for compliance ---
Source: "{#MediaMtxDir}\mediamtx.exe"; DestDir: "{app}\third_party\mediamtx"; Flags: ignoreversion
Source: "{#MediaMtxDir}\LICENSE";       DestDir: "{app}\third_party\mediamtx"; DestName: "mediamtx-LICENSE.txt"; Flags: ignoreversion

; --- FFmpeg (GPL build) ---
Source: "{#FfmpegDir}\ffmpeg.exe";  DestDir: "{app}\third_party\ffmpeg"; Flags: ignoreversion
Source: "{#FfmpegDir}\ffprobe.exe"; DestDir: "{app}\third_party\ffmpeg"; Flags: ignoreversion

; --- MediaMTX runtime config ---
Source: "{#ConfigDir}\mediamtx.yml"; DestDir: "{app}\config"; Flags: ignoreversion

; --- Known-camera DB (USB vid:pid -> mode/resolution). Empty by default;
; users (or future installer builds) add entries. Supervisor falls back to
; format-based smart pick if a cam isn't in the DB, so a missing/empty
; file isn't an error. ---
Source: "{#ConfigDir}\known-cameras.json"; DestDir: "{app}\config"; Flags: ignoreversion

; --- Legal text shipped with the install ---
Source: "{#RepoRoot}\LICENSE";               DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md";              DestDir: "{app}"; Flags: ignoreversion

[Dirs]
; The supervisor writes probe summaries and settings.json into {app} at
; runtime. Pre-create the probes dir AND grant users-modify on {app}
; itself so settings.json can be created/edited from the WPF UI even on
; a per-machine install (where {app} is Program Files and admin-only by
; default).
Name: "{app}";        Permissions: users-modify
Name: "{app}\probes"; Permissions: users-modify

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Per-user autostart entry. Tasks: autostart binds creation to the
; "Start automatically..." checkbox. uninsdeletevalue removes it on
; uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
  ValueType: string; ValueName: "WebcamStreamer"; \
  ValueData: """{app}\{#AppExeName}"""; \
  Flags: uninsdeletevalue; Tasks: autostart

[Run]
; The Windows Firewall rule (RTSP listener on TCP 8554 -- UDP is disabled
; in mediamtx.yml) is created from [Code]::ApplyFirewallRule via
; ShellExec('runas', ...) so it elevates correctly on per-user installs.
; See CurStepChanged below.

; Offer to launch immediately after install finishes.
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Auto-terminate the host + supervisor + its children BEFORE the
; uninstaller starts removing files (otherwise PendingFileRenameOperations
; turns into reboot-required prompts and orphan processes). Per the
; grilled design (Q11.1) this is opinionated -- no "please exit first"
; prompt. RunOnceId keeps these from re-running on uninstaller re-runs.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM WebcamStreamerUi.exe /T"; Flags: runhidden; RunOnceId: "KillUi"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM supervisor.exe /T";       Flags: runhidden; RunOnceId: "KillSup"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM mediamtx.exe /T";         Flags: runhidden; RunOnceId: "KillMtx"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM ffmpeg.exe /T";           Flags: runhidden; RunOnceId: "KillFf"

; The firewall rule is removed from [Code]::CurUninstallStepChanged via
; ShellExec('runas', ...) so the delete elevates on per-user uninstalls.

[UninstallDelete]
; Per-user state (probes + settings.json) is wiped on uninstall per the
; grilled design (Q11.2 -- clean-slate uninstall, no prompt). probes/ is
; runtime-generated; settings.json was created by the host app after
; install and isn't tracked by the manifest.
Type: filesandordirs; Name: "{app}\probes"
Type: files;          Name: "{app}\settings.json"
Type: files;          Name: "{app}\mediamtx.runtime.yml"

[Code]
// Section-level note: keep this Pascal Script trivial. The supervisor
// seeds viewer credentials on its first run when they're missing from
// settings.json (see settings.cpp::LoadSettings + the
// GenerateRandomCredential fallback in main.cpp), so we deliberately do
// NOT use Random/Randomize/GetTickCount or functions with local consts
// here -- the Chocolatey-distributed Inno Setup that the GitHub Actions
// runner used to install in v0.3.0..v0.3.4 was old enough to choke on
// any of those. We pin a modern Inno Setup binary in release.yml as a
// second line of defence, but keeping the script itself minimal is the
// durable fix.

// Create (or refresh) the Windows Firewall rule that lets MediaMTX
// listen on TCP 8554. The rule lives in the system policy store, so this
// always needs Administrator. ShellExec verb 'runas' elevates the child
// netsh.exe -- on a per-user install Windows shows one UAC prompt; on a
// per-machine install the parent installer is already elevated and the
// child inherits the token silently. If the user declines UAC the call
// fails; we surface an informational message but do NOT abort the
// install -- the rule can be added later from the WPF Settings dialog or
// by re-running setup.
procedure ApplyFirewallRule;
var
  ResultCode: Integer;
  MtxPath:    String;
  Params:     String;
  Ok:         Boolean;
begin
  MtxPath := ExpandConstant('{app}\third_party\mediamtx\mediamtx.exe');

  // Idempotent: delete any rule with our exact name first. We ignore the
  // result -- "no such rule" is the common case and not an error.
  ShellExec('runas', ExpandConstant('{sys}\netsh.exe'),
    'advfirewall firewall delete rule name="Webcam Streamer (RTSP)"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  Params := 'advfirewall firewall add rule name="Webcam Streamer (RTSP)"' +
            ' dir=in action=allow protocol=TCP localport=8554' +
            ' program="' + MtxPath + '" enable=yes';
  Ok := ShellExec('runas', ExpandConstant('{sys}\netsh.exe'),
          Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  // ShellExec returns False when the UAC prompt is declined (or netsh
  // could not be launched at all). ResultCode is netsh's exit code when
  // Ok=True; non-zero there means the rule was rejected by Windows.
  if (not Ok) or (ResultCode <> 0) then begin
    MsgBox('Could not add the Windows Firewall rule for RTSP port 8554. ' +
           'You can add it later from the Settings dialog of the Webcam' + #13#10 +
           'Streamer app, or by re-running this installer.',
           mbInformation, MB_OK);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  SettingsPath: String;
  Contents:     String;
  StreamAll:    Boolean;
begin
  if CurStep = ssPostInstall then begin
    SettingsPath := ExpandConstant('{app}\settings.json');
    // Preserve existing file on upgrade (user may have changed creds
    // post-install via the WPF Security section).
    if not FileExists(SettingsPath) then begin
      StreamAll := WizardIsTaskSelected('streamall');
      Contents :=
        '{' + #13#10 +
        '  "notifications_enabled": true,' + #13#10 +
        '  "default_enabled_for_new_cameras": ';
      if StreamAll then Contents := Contents + 'true'
      else              Contents := Contents + 'false';
      Contents := Contents + #13#10 + '}' + #13#10;
      SaveStringToFile(SettingsPath, Contents, False);
    end;

    if WizardIsTaskSelected('firewall') then
      ApplyFirewallRule;
  end;
end;

// Remove the firewall rule we may have created at install time. We try
// unconditionally -- the rule name is distinctive, and if it doesn't
// exist netsh just returns "no rules match". ShellExec 'runas' elevates
// on per-user uninstalls; on per-machine uninstall the call inherits the
// already-elevated token. If the user declines UAC the rule stays
// behind, which is harmless.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    ShellExec('runas', ExpandConstant('{sys}\netsh.exe'),
      'advfirewall firewall delete rule name="Webcam Streamer (RTSP)"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
