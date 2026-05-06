# Downloads MediaMTX + FFmpeg into third_party/
# Idempotent: skips downloads if binaries already exist.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speed up Invoke-WebRequest

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
        Write-Host "[mediamtx] already present at $mtxExe — skip" -ForegroundColor DarkGray
        return
    }
    Write-Host "[mediamtx] querying latest release..." -ForegroundColor Cyan
    $api = 'https://api.github.com/repos/bluenviron/mediamtx/releases/latest'
    $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -Headers @{ 'User-Agent' = 'webcam-streamer-setup' }
    $asset = $rel.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "No Windows amd64 zip in latest mediamtx release" }
    $zip = Join-Path $tmp $asset.name
    Write-Host "[mediamtx] downloading $($asset.name) ..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Write-Host "[mediamtx] extracting to $mtxDir" -ForegroundColor Cyan
    Expand-Archive -Path $zip -DestinationPath $mtxDir -Force
    if (-not (Test-Path $mtxExe)) { throw "mediamtx.exe not found after extract" }
    Write-Host "[mediamtx] OK: $(& $mtxExe --version 2>&1 | Select-Object -First 1)" -ForegroundColor Green
}

function Get-FFmpeg {
    if (Test-Path $ffExe) {
        Write-Host "[ffmpeg] already present at $ffExe — skip" -ForegroundColor DarkGray
        return
    }
    # gyan.dev "release-essentials" includes libx264, libx265, nvenc/qsv/amf hooks via runtime-loaded DLLs
    $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    $zip = Join-Path $tmp 'ffmpeg-release-essentials.zip'
    if (-not (Test-Path $zip)) {
        Write-Host "[ffmpeg] downloading from gyan.dev (essentials, ~80 MB)..." -ForegroundColor Cyan
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
    Write-Host "[nlohmann/json] downloading single-header release..." -ForegroundColor Cyan
    $url = 'https://github.com/nlohmann/json/releases/latest/download/json.hpp'
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
