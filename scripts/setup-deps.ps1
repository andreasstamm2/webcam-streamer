# Downloads MediaMTX + FFmpeg + nlohmann/json into third_party/.
# Idempotent: skips downloads if binaries already exist.
#
# All three downloads are PINNED to specific upstream versions. Earlier
# revisions of this script pulled "latest" which made local-vs-CI drift
# possible and silent: an upstream patch in any of these tools would
# enter CI builds with no warning. To bump, change the X_VERSION block
# below and run setup-deps.ps1 again (it'll re-download because the
# expected paths reference the new version).

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speed up Invoke-WebRequest

# --- Pinned versions. Bump in lockstep with BUILDING.md and the
#     -p:Version embedded by the release workflow.
$MEDIAMTX_VERSION = '1.18.2'           # bluenviron/mediamtx GitHub Release tag (sans 'v')
$FFMPEG_VERSION   = '8.1.1'            # GyanD/codexffmpeg GitHub Release tag
$NLOHMANN_VERSION = '3.12.0'           # nlohmann/json GitHub Release tag (sans 'v')

$root        = Split-Path -Parent $PSScriptRoot
$thirdParty  = Join-Path $root 'third_party'
$mtxDir      = Join-Path $thirdParty 'mediamtx'
$ffDir       = Join-Path $thirdParty 'ffmpeg'
$ffExe       = Join-Path $ffDir 'ffmpeg.exe'
$mtxExe      = Join-Path $mtxDir 'mediamtx.exe'
$tmp         = Join-Path $env:TEMP 'webcam_streamer_setup'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Get-MediaMtx {
    if (Test-Path $mtxExe) {
        Write-Host "[mediamtx] already present at $mtxExe -- skip" -ForegroundColor DarkGray
        return
    }
    $assetName = "mediamtx_v${MEDIAMTX_VERSION}_windows_amd64.zip"
    $url       = "https://github.com/bluenviron/mediamtx/releases/download/v$MEDIAMTX_VERSION/$assetName"
    $zip       = Join-Path $tmp $assetName
    Write-Host "[mediamtx] downloading $url ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Write-Host "[mediamtx] extracting to $mtxDir" -ForegroundColor Cyan
    Expand-Archive -Path $zip -DestinationPath $mtxDir -Force
    if (-not (Test-Path $mtxExe)) { throw "mediamtx.exe not found after extract" }
    Write-Host "[mediamtx] OK: $(& $mtxExe --version 2>&1 | Select-Object -First 1)" -ForegroundColor Green
}

function Get-FFmpeg {
    if (Test-Path $ffExe) {
        Write-Host "[ffmpeg] already present at $ffExe -- skip" -ForegroundColor DarkGray
        return
    }
    # GyanD's codexffmpeg GitHub Releases host the same "essentials"
    # builds gyan.dev links at, but with a stable per-version URL --
    # whereas https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
    # rolls forward as the maintainer ships new releases.
    $assetName = "ffmpeg-$FFMPEG_VERSION-essentials_build.zip"
    $url       = "https://github.com/GyanD/codexffmpeg/releases/download/$FFMPEG_VERSION/$assetName"
    $zip       = Join-Path $tmp $assetName
    if (-not (Test-Path $zip)) {
        Write-Host "[ffmpeg] downloading $url (essentials, ~80 MB)..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }
    Write-Host "[ffmpeg] extracting..." -ForegroundColor Cyan
    $extractTmp = Join-Path $tmp 'ffmpeg_extract'
    if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    Expand-Archive -Path $zip -DestinationPath $extractTmp -Force
    # Archive structure: ffmpeg-<ver>-essentials_build\bin\ffmpeg.exe
    $bin = Get-ChildItem -Path $extractTmp -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $bin) { throw "ffmpeg.exe not found inside archive" }
    $srcBin = $bin.Directory.FullName
    # $ffDir must exist as a directory BEFORE the pipe-copy below -- otherwise
    # PowerShell treats it as a single destination filename, the first piped
    # FileInfo gets copied to that name, subsequent items overwrite it, and
    # ffmpeg.exe never lands at $ffDir\ffmpeg.exe. Locally the dir survives
    # from a prior run; on CI (clean checkout) it doesn't.
    New-Item -ItemType Directory -Force -Path $ffDir | Out-Null
    Get-ChildItem -Path $srcBin | Copy-Item -Destination $ffDir -Force
    if (-not (Test-Path $ffExe)) { throw "ffmpeg.exe not present after copy" }
    Write-Host "[ffmpeg] OK: $(& $ffExe -version 2>&1 | Select-Object -First 1)" -ForegroundColor Green
}

function Get-NlohmannJson {
    $jsonHeaderDir = Join-Path $root 'supervisor\third_party\nlohmann'
    $jsonHeader    = Join-Path $jsonHeaderDir 'json.hpp'
    if (Test-Path $jsonHeader) {
        Write-Host "[nlohmann/json] already present at $jsonHeader -- skip" -ForegroundColor DarkGray
        return
    }
    New-Item -ItemType Directory -Force -Path $jsonHeaderDir | Out-Null
    $url = "https://github.com/nlohmann/json/releases/download/v$NLOHMANN_VERSION/json.hpp"
    Write-Host "[nlohmann/json] downloading $url ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $jsonHeader -UseBasicParsing
    if (-not (Test-Path $jsonHeader)) { throw "json.hpp not present after download" }
    $sz = (Get-Item $jsonHeader).Length
    Write-Host "[nlohmann/json] OK: $sz bytes -> $jsonHeader" -ForegroundColor Green
}

Get-MediaMtx
Get-FFmpeg
Get-NlohmannJson

Write-Host ""
Write-Host "Done. Binaries:" -ForegroundColor Green
Write-Host "  $mtxExe"
Write-Host "  $ffExe"
Write-Host "  $(Join-Path $root 'supervisor\third_party\nlohmann\json.hpp')"
