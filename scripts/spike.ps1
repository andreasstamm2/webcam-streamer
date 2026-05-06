# Spike: validate the streaming chain end-to-end.
#   1. start mediamtx with config/mediamtx.yml
#   2. start ffmpeg capturing from a DirectShow webcam, MJPEG passthrough
#   3. push to rtsp://publisher:publisher@127.0.0.1:8554/webcam0
#   4. print the viewer URL; wait for Ctrl-C; tear down children
#
# Usage:
#   .\spike.ps1                                # auto-pick first cam ffmpeg sees
#   .\spike.ps1 -CameraName 'Logi BRIO'        # specific cam
#   .\spike.ps1 -ListCameras                   # just dump dshow devices and exit

[CmdletBinding()]
param(
    [string]$CameraName,
    [switch]$ListCameras,
    [int]$Width  = 1280,
    [int]$Height = 720,
    [int]$Fps    = 30
)

$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSScriptRoot
$ffExe  = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
$mtxExe = Join-Path $root 'third_party\mediamtx\mediamtx.exe'
$mtxYml = Join-Path $root 'config\mediamtx.yml'

foreach ($p in @($ffExe, $mtxExe, $mtxYml)) {
    if (-not (Test-Path $p)) { throw "Missing: $p (run setup-deps.ps1?)" }
}

# --- list-only mode -----------------------------------------------------------
if ($ListCameras) {
    Write-Host "DirectShow video devices visible to ffmpeg:" -ForegroundColor Cyan
    & $ffExe -hide_banner -f dshow -list_devices true -i dummy 2>&1 |
        Select-String -Pattern 'DirectShow video devices|"' |
        ForEach-Object { $_.Line }
    return
}

# --- pick a camera ------------------------------------------------------------
if (-not $CameraName) {
    $devLines = & $ffExe -hide_banner -f dshow -list_devices true -i dummy 2>&1
    $inVideo = $false
    foreach ($line in $devLines) {
        if ($line -match 'DirectShow video devices') { $inVideo = $true; continue }
        if ($line -match 'DirectShow audio devices') { $inVideo = $false; continue }
        if ($inVideo -and $line -match '"([^"]+)"' -and $line -notmatch 'Alternative name') {
            $CameraName = $Matches[1]
            break
        }
    }
    if (-not $CameraName) { throw "Could not auto-detect a camera. Run with -ListCameras." }
    Write-Host "Auto-picked camera: $CameraName" -ForegroundColor DarkGray
}

# --- launch mediamtx ----------------------------------------------------------
Write-Host "[mediamtx] starting..." -ForegroundColor Cyan
$mtxProc = Start-Process -FilePath $mtxExe -ArgumentList @($mtxYml) -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $env:TEMP 'mediamtx.out.log') `
    -RedirectStandardError  (Join-Path $env:TEMP 'mediamtx.err.log')
Start-Sleep -Seconds 1
if ($mtxProc.HasExited) {
    Get-Content (Join-Path $env:TEMP 'mediamtx.err.log') | Write-Host
    throw "mediamtx exited immediately"
}
Write-Host "[mediamtx] PID $($mtxProc.Id), listening on :8554" -ForegroundColor Green

# --- launch ffmpeg ------------------------------------------------------------
$ffmpegArgs = @(
    '-hide_banner',
    '-loglevel', 'warning',
    # input: dshow, prefer MJPEG at requested resolution/fps
    '-f', 'dshow',
    '-vcodec', 'mjpeg',
    '-video_size', "${Width}x${Height}",
    '-framerate', "$Fps",
    '-i', "`"video=$CameraName`"",
    # output: passthrough copy, RTSP push
    '-c:v', 'copy',
    '-an',
    '-f', 'rtsp',
    '-rtsp_transport', 'tcp',
    "rtsp://publisher:publisher@127.0.0.1:8554/webcam0"
)
Write-Host "[ffmpeg] starting MJPEG passthrough from '$CameraName' @ ${Width}x${Height}/${Fps}..." -ForegroundColor Cyan
$ffProc = Start-Process -FilePath $ffExe -ArgumentList $ffmpegArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $env:TEMP 'ffmpeg.out.log') `
    -RedirectStandardError  (Join-Path $env:TEMP 'ffmpeg.err.log')
Start-Sleep -Seconds 2
if ($ffProc.HasExited) {
    Get-Content (Join-Path $env:TEMP 'ffmpeg.err.log') | Write-Host
    Stop-Process -Id $mtxProc.Id -Force -ErrorAction SilentlyContinue
    throw "ffmpeg exited immediately"
}
Write-Host "[ffmpeg] PID $($ffProc.Id), publishing to /webcam0" -ForegroundColor Green

$lan = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^169\.254' } |
        Select-Object -First 1 -ExpandProperty IPAddress)

Write-Host ""
Write-Host "STREAM IS LIVE:" -ForegroundColor Green
Write-Host "  Local:   rtsp://viewer:viewer@127.0.0.1:8554/webcam0"
if ($lan) {
    Write-Host "  LAN:     rtsp://viewer:viewer@${lan}:8554/webcam0"
}
Write-Host ""
Write-Host "Test it:"
Write-Host "  ffplay  rtsp://viewer:viewer@127.0.0.1:8554/webcam0"
Write-Host "  vlc     rtsp://viewer:viewer@127.0.0.1:8554/webcam0"
Write-Host ""
Write-Host "Logs: $env:TEMP\mediamtx.{out,err}.log  $env:TEMP\ffmpeg.{out,err}.log"
Write-Host ""
Write-Host "Ctrl-C to stop." -ForegroundColor Yellow

try {
    while (-not $ffProc.HasExited -and -not $mtxProc.HasExited) {
        Start-Sleep -Seconds 1
    }
    Write-Host "A child exited; tearing down." -ForegroundColor Yellow
} finally {
    foreach ($p in @($ffProc, $mtxProc)) {
        if ($p -and -not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "[done] children stopped." -ForegroundColor DarkGray
}
