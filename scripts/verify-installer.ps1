# Static verification of installer/setup.iss without requiring Inno Setup
# to be installed locally. Confirms:
#   1. All [Files] Source: paths resolve to artifacts that exist after a
#      build (or are stub references the build step will produce).
#   2. setup.iss contains the structural directives that the grilled
#      design requires (dual-mode privileges, three [Tasks], HKCU Run
#      registry entry, uninstall taskkill, settings.json [Code]).
#   3. build-installer.ps1 references mtx_event_hook.exe.
#
# A "real" verification compiles the .iss with ISCC.exe and runs the
# installer; that lives on the release host and is out of scope here.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot
$iss   = Join-Path $root 'installer\setup.iss'
$psBld = Join-Path $root 'installer\build-installer.ps1'
if (-not (Test-Path $iss))   { throw "missing $iss" }
if (-not (Test-Path $psBld)) { throw "missing $psBld" }

$issText = Get-Content $iss -Raw
$bldText = Get-Content $psBld -Raw
$verdict = $true

function Assert-Match {
    param([string]$Haystack, [string]$Pattern, [string]$Label)
    if ($Haystack -match $Pattern) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
    } else {
        Write-Host "FAIL: $Label (pattern: $Pattern)" -ForegroundColor Red
        $script:verdict = $false
    }
}

Write-Host "T1: dual-mode privileges" -ForegroundColor Yellow
Assert-Match $issText 'PrivilegesRequired\s*=\s*lowest'              "PrivilegesRequired=lowest"
Assert-Match $issText 'PrivilegesRequiredOverridesAllowed\s*=\s*dialog' "PrivilegesRequiredOverridesAllowed=dialog"

Write-Host ""
Write-Host "T2: [Tasks] checkboxes from grilled design" -ForegroundColor Yellow
Assert-Match $issText 'Name:\s*"streamall"'      "Task: streamall (default_enabled_for_new_cameras bootstrap)"
Assert-Match $issText 'Name:\s*"autostart"'      "Task: autostart (HKCU\Run)"
Assert-Match $issText 'Name:\s*"firewall"'       "Task: firewall (mediamtx :8554)"

Write-Host ""
Write-Host "T3: HKCU Run registry entry (Tasks: autostart)" -ForegroundColor Yellow
Assert-Match $issText 'Root:\s*HKCU;\s*Subkey:\s*"Software\\Microsoft\\Windows\\CurrentVersion\\Run"' "HKCU Run subkey present"
Assert-Match $issText 'ValueName:\s*"WebcamStreamer"' "ValueName: WebcamStreamer"
Assert-Match $issText 'Tasks:\s*autostart'    "registry entry bound to autostart task"

Write-Host ""
Write-Host "T4: mtx_event_hook.exe bundled" -ForegroundColor Yellow
Assert-Match $issText 'mtx_event_hook\.exe'     "Slice B helper exe is in [Files]"
Assert-Match $bldText 'mtx_event_hook\.exe'     "build-installer.ps1 sanity-checks for helper exe"

Write-Host ""
Write-Host "T5: uninstall taskkill cascade (no 'please exit' prompt)" -ForegroundColor Yellow
Assert-Match $issText 'taskkill\.exe.*WebcamStreamerUi\.exe' "UninstallRun kills WebcamStreamerUi"
Assert-Match $issText 'taskkill\.exe.*supervisor\.exe'       "UninstallRun kills supervisor"
Assert-Match $issText 'taskkill\.exe.*mediamtx\.exe'         "UninstallRun kills mediamtx"
Assert-Match $issText 'taskkill\.exe.*ffmpeg\.exe'           "UninstallRun kills ffmpeg"

Write-Host ""
Write-Host "T6: uninstall wipes per-user state" -ForegroundColor Yellow
Assert-Match $issText '\{app\}\\probes'           "UninstallDelete removes probes/"
Assert-Match $issText '\{app\}\\settings\.json'   "UninstallDelete removes settings.json"

Write-Host ""
Write-Host "T7: [Code] writes settings.json based on streamall task" -ForegroundColor Yellow
Assert-Match $issText 'CurStepChanged'              "Pascal CurStepChanged hook"
Assert-Match $issText "WizardIsTaskSelected\('streamall'\)" "Reads streamall task selection"
Assert-Match $issText 'default_enabled_for_new_cameras'     "Writes default_enabled_for_new_cameras key"

Write-Host ""
Write-Host "T8: source artifacts referenced by [Files] exist post-build" -ForegroundColor Yellow
# We don't FORCE a build here -- a fresh clone may not have built yet.
# But if the build has been run, the artifacts should be present.
$built = $true
$artifacts = @(
    "$root\supervisor\build\Release\supervisor.exe",
    "$root\supervisor\build\Release\mtx_event_hook.exe",
    "$root\third_party\mediamtx\mediamtx.exe",
    "$root\third_party\ffmpeg\ffmpeg.exe",
    "$root\config\mediamtx.yml",
    "$root\LICENSE",
    "$root\README.md",
    "$root\THIRD_PARTY_NOTICES.md"
)
foreach ($a in $artifacts) {
    if (Test-Path $a) {
        Write-Host "  PASS: $a" -ForegroundColor Green
    } else {
        Write-Host "WARN: $a missing (run scripts\setup-deps.ps1 and build supervisor + UI)" -ForegroundColor Yellow
        $built = $false
    }
}

Write-Host ""
if ($verdict) {
    if ($built) { Write-Host "OVERALL: PASS" -ForegroundColor Green }
    else        { Write-Host "OVERALL: PASS (with build warnings -- re-run after building)" -ForegroundColor Yellow }
    exit 0
} else {
    Write-Host "OVERALL: FAIL" -ForegroundColor Red
    exit 1
}
