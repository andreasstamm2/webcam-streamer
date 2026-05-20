<#
.SYNOPSIS
    Print the versions of every tool the webcam_streamer release build
    depends on; flag drift from the expected pins.

.DESCRIPTION
    Catches "it builds on my machine but not on GitHub" before a tag
    push. Compares observed versions to the pins declared in
    scripts/setup-deps.ps1, scripts/install-inno-setup.ps1, and
    .github/workflows/release.yml. Exit code is 0 when everything
    matches, 1 otherwise. Output is colorised but always
    human-readable.

    Tools checked:
      * Inno Setup (ISCC.exe)
      * .NET SDK
      * CMake + MSVC (cl.exe via vswhere if not on PATH)
      * MediaMTX (third_party/mediamtx/mediamtx.exe)
      * FFmpeg   (third_party/ffmpeg/ffmpeg.exe)
      * nlohmann/json single-header
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$root  = Resolve-Path (Join-Path $PSScriptRoot '..')
$drift = 0

function Write-Header { Write-Host "`n=== webcam_streamer build environment ===" -ForegroundColor Cyan }
function Write-Row {
    param([string]$Name, [string]$Observed, [string]$Expected)
    $ok = ($Observed -eq $Expected) -or ([string]::IsNullOrEmpty($Expected))
    $marker = if ($ok) { '[OK]   ' } else { '[DRIFT]' }
    $colour = if ($ok) { 'Green' }   else { 'Yellow' }
    $line = "{0,-7} {1,-16} : {2}" -f $marker, $Name, $Observed
    if (-not $ok) { $line += "   (expected $Expected)" }
    Write-Host $line -ForegroundColor $colour
    if (-not $ok) { $script:drift++ }
}
function Write-Missing {
    param([string]$Name, [string]$Hint)
    Write-Host ("[MISS]  {0,-16} : not found.  {1}" -f $Name, $Hint) -ForegroundColor Red
    $script:drift++
}

# --- Pins must match scripts/setup-deps.ps1 + install-inno-setup.ps1
#     + .github/workflows/release.yml. Keep these in lockstep.
$EXPECT_INNO     = '6.7.2'
$EXPECT_DOTNET   = '9.0.308'
$EXPECT_MEDIAMTX = '1.18.2'
$EXPECT_FFMPEG   = '8.1.1'
$EXPECT_NLOHMANN = '3.12.0'

Write-Header

# --- Inno Setup -------------------------------------------------------------
# ISCC.exe has no file-version metadata and its /? banner doesn't carry
# the patch version ("Inno Setup 6 Command-Line Compiler"), so we can't
# probe the exe directly. Instead we trust install-inno-setup.ps1's
# directory naming convention -- it installs into
# tools\inno-setup-X.Y.Z\, so the parent dir name IS the version. If
# INNO_SETUP_EXE is set we look at the supplied path and accept it.
try {
    $iscc = & "$PSScriptRoot\install-inno-setup.ps1" -Quiet
    if ($iscc -and (Test-Path $iscc)) {
        $parent = Split-Path -Leaf (Split-Path -Parent $iscc)
        if ($parent -match '^inno-setup-([0-9.]+)$') {
            Write-Row 'Inno Setup' $matches[1] $EXPECT_INNO
        } elseif ($env:INNO_SETUP_EXE) {
            Write-Row 'Inno Setup' "(env override at $iscc)" $EXPECT_INNO
        } else {
            Write-Row 'Inno Setup' "(unknown version at $iscc)" $EXPECT_INNO
        }
    } else {
        Write-Missing 'Inno Setup' "Run scripts\install-inno-setup.ps1"
    }
} catch {
    Write-Missing 'Inno Setup' $_.Exception.Message
}

# --- .NET SDK ---------------------------------------------------------------
$dn = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dn) {
    $v = & dotnet --version 2>&1
    Write-Row '.NET SDK' "$v" $EXPECT_DOTNET
} else {
    Write-Missing '.NET SDK' "Install via https://dotnet.microsoft.com/download/dotnet/9.0"
}

# --- CMake ------------------------------------------------------------------
$cm = Get-Command cmake -ErrorAction SilentlyContinue
if ($cm) {
    $v = (& cmake --version 2>&1 | Select-Object -First 1)
    if ($v -match 'cmake version ([0-9.]+)') { Write-Row 'CMake' $matches[1] '' }
    else                                     { Write-Row 'CMake' "$v" '' }
} else {
    Write-Missing 'CMake' "Install Visual Studio 2022 with C++ workload, or 'winget install Kitware.CMake'"
}

# --- MSVC (cl.exe) ----------------------------------------------------------
# cl.exe usually isn't on PATH; we'd need to source vcvarsall.bat. Settle for
# detecting Visual Studio installs via vswhere.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsv = & $vswhere -latest -property installationVersion 2>&1
    Write-Row 'Visual Studio' "$vsv" ''
} else {
    Write-Missing 'Visual Studio' "Install VS 2022 with the 'Desktop development with C++' workload"
}

# --- Third-party binaries fetched by setup-deps.ps1 -------------------------
$mtx = Join-Path $root 'third_party\mediamtx\mediamtx.exe'
if (Test-Path $mtx) {
    # MediaMTX prints its version on the first line of --version output.
    $line = & $mtx --version 2>&1 | Select-Object -First 1
    # Match patterns like "v1.18.2" or "1.18.2".
    if ("$line" -match 'v?([0-9]+\.[0-9]+\.[0-9]+)') { Write-Row 'MediaMTX' $matches[1] $EXPECT_MEDIAMTX }
    else                                              { Write-Row 'MediaMTX' "$line" $EXPECT_MEDIAMTX }
} else {
    Write-Missing 'MediaMTX' "Run scripts\setup-deps.ps1"
}

$ff = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
if (Test-Path $ff) {
    $line = & $ff -version 2>&1 | Select-Object -First 1
    if ("$line" -match 'ffmpeg version ([0-9.]+)') { Write-Row 'FFmpeg' $matches[1] $EXPECT_FFMPEG }
    else                                            { Write-Row 'FFmpeg' "$line" $EXPECT_FFMPEG }
} else {
    Write-Missing 'FFmpeg' "Run scripts\setup-deps.ps1"
}

$json = Join-Path $root 'supervisor\third_party\nlohmann\json.hpp'
if (Test-Path $json) {
    # Header carries its version inside a triple-macro; extract.
    $content = Get-Content $json -TotalCount 100
    $major = ($content | Where-Object { $_ -match '#define NLOHMANN_JSON_VERSION_MAJOR (\d+)' } | ForEach-Object { $matches[1] } | Select-Object -First 1)
    $minor = ($content | Where-Object { $_ -match '#define NLOHMANN_JSON_VERSION_MINOR (\d+)' } | ForEach-Object { $matches[1] } | Select-Object -First 1)
    $patch = ($content | Where-Object { $_ -match '#define NLOHMANN_JSON_VERSION_PATCH (\d+)' } | ForEach-Object { $matches[1] } | Select-Object -First 1)
    if ($major) { Write-Row 'nlohmann/json' "$major.$minor.$patch" $EXPECT_NLOHMANN }
    else        { Write-Row 'nlohmann/json' '(version probe failed)' $EXPECT_NLOHMANN }
} else {
    Write-Missing 'nlohmann/json' "Run scripts\setup-deps.ps1"
}

Write-Host ''
if ($drift -eq 0) {
    Write-Host "Environment matches pins. Safe to build for release." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$drift drift item(s) detected. Local + CI builds may diverge." -ForegroundColor Yellow
    Write-Host "Reconcile by:  bumping pins in scripts/setup-deps.ps1," -ForegroundColor Yellow
    Write-Host "               scripts/install-inno-setup.ps1," -ForegroundColor Yellow
    Write-Host "               .github/workflows/release.yml," -ForegroundColor Yellow
    Write-Host "               and this file (the EXPECT_* block)." -ForegroundColor Yellow
    exit 1
}
