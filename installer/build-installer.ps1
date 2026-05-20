<#
.SYNOPSIS
    One-shot installer build for webcam_streamer.

.DESCRIPTION
    Publishes the WPF UI as a self-contained single-file exe, ensures the
    C++ supervisor is built in Release, verifies third-party binaries are
    present, then invokes Inno Setup to produce the installer.

    Output: installer\output\WebcamStreamerSetup-vX.Y.Z.exe

.PARAMETER Version
    Semantic version string (without leading "v"). Embedded in the
    installer filename and metadata.

.PARAMETER IsccPath
    Explicit path to ISCC.exe to use. If omitted, the script auto-pins
    a known-good Inno Setup version under <repo>\tools via
    scripts\install-inno-setup.ps1 (download on first run, cached
    afterwards). Set $env:INNO_SETUP_EXE to point at a hand-installed
    Inno Setup if you'd rather use that.
#>
param(
    [string]$Version  = "0.1.0",
    [string]$IsccPath = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Write-Host "Repo root: $RepoRoot"

# --- Pin Inno Setup (shared with CI) ----------------------------------------
# install-inno-setup.ps1 downloads the official Inno Setup binary on
# first use and caches it under <repo>\tools, eliminating the
# local-vs-CI drift that broke v0.3.0..v0.3.5. Honours -IsccPath and
# $env:INNO_SETUP_EXE overrides for devs who prefer a hand-installed
# Inno Setup.
if ($IsccPath) {
    if (-not (Test-Path $IsccPath)) { throw "Inno Setup compiler not found at '$IsccPath'." }
} else {
    $IsccPath = & "$PSScriptRoot\..\scripts\install-inno-setup.ps1"
}

foreach ($p in @(
    "$RepoRoot\third_party\ffmpeg\ffmpeg.exe",
    "$RepoRoot\third_party\mediamtx\mediamtx.exe",
    "$RepoRoot\third_party\mediamtx\LICENSE",
    "$RepoRoot\config\mediamtx.yml",
    "$RepoRoot\LICENSE",
    "$RepoRoot\THIRD_PARTY_NOTICES.md"
)) {
    if (-not (Test-Path $p)) {
        throw "Missing required file: $p. Run scripts\setup-deps.ps1 first."
    }
}

# --- 1. Build supervisor (C++) ----------------------------------------------

Write-Host "`n[1/3] Building supervisor (Release)..." -ForegroundColor Cyan
Push-Location "$RepoRoot\supervisor"
try {
    if (-not (Test-Path "build")) {
        cmake -S . -B build -G "Visual Studio 17 2022" -A x64
        if ($LASTEXITCODE -ne 0) { throw "CMake configure failed." }
    }
    cmake --build build --config Release
    if ($LASTEXITCODE -ne 0) { throw "Supervisor build failed." }
} finally {
    Pop-Location
}

if (-not (Test-Path "$RepoRoot\supervisor\build\Release\supervisor.exe")) {
    throw "supervisor.exe not produced."
}
if (-not (Test-Path "$RepoRoot\supervisor\build\Release\mtx_event_hook.exe")) {
    throw "mtx_event_hook.exe not produced (Slice B helper exe -- second CMake target)."
}

# --- 2. Publish WPF UI (self-contained) -------------------------------------

Write-Host "`n[2/3] Publishing WPF UI (self-contained single-file)..." -ForegroundColor Cyan
$publishDir = "$RepoRoot\ui\WebcamStreamerUi\publish"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

dotnet publish "$RepoRoot\ui\WebcamStreamerUi" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:Version=$Version `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:PublishReadyToRun=true `
    -o $publishDir

if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }
if (-not (Test-Path "$publishDir\WebcamStreamerUi.exe")) {
    throw "WebcamStreamerUi.exe not produced."
}

# --- 3. Run Inno Setup ------------------------------------------------------

Write-Host "`n[3/3] Building installer (Inno Setup)..." -ForegroundColor Cyan
& $IsccPath "/DAppVersion=$Version" "$PSScriptRoot\setup.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed." }

$installer = "$PSScriptRoot\output\WebcamStreamerSetup-v$Version.exe"
if (-not (Test-Path $installer)) {
    throw "Installer not produced at expected path: $installer"
}

$size = [math]::Round((Get-Item $installer).Length / 1MB, 1)
Write-Host "`nInstaller built: $installer ($size MB)" -ForegroundColor Green
