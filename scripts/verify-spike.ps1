# One-shot verification of the streaming chain.
#   start mediamtx + ffmpeg(passthrough) -> probe RTSP via ffprobe -> tear down -> report.
# Exits 0 on success, non-zero on failure. Prints stream metadata on success.

[CmdletBinding()]
param(
    [string]$CameraName = 'Logitech BRIO',
    [int]$Width  = 1280,
    [int]$Height = 720,
    [int]$Fps    = 30,
    [int]$ProbeWaitSeconds = 4
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$ffExe     = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
$ffprobe   = Join-Path $root 'third_party\ffmpeg\ffprobe.exe'
$mtxExe    = Join-Path $root 'third_party\mediamtx\mediamtx.exe'
$mtxYml    = Join-Path $root 'config\mediamtx.yml'

$mtxOut = Join-Path $env:TEMP 'mediamtx.verify.out.log'
$mtxErr = Join-Path $env:TEMP 'mediamtx.verify.err.log'
$ffOut  = Join-Path $env:TEMP 'ffmpeg.verify.out.log'
$ffErr  = Join-Path $env:TEMP 'ffmpeg.verify.err.log'

$mtxProc = $null
$ffProc  = $null

function Stop-Children {
    foreach ($p in @($ffProc, $mtxProc)) {
        if ($p -and -not $p.HasExited) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Write-Host "[verify] starting mediamtx..." -ForegroundColor Cyan
    $mtxProc = Start-Process -FilePath $mtxExe -ArgumentList @($mtxYml) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $mtxOut -RedirectStandardError $mtxErr
    Start-Sleep -Seconds 1
    if ($mtxProc.HasExited) {
        Write-Host "mediamtx exited immediately. stderr:" -ForegroundColor Red
        Get-Content $mtxErr -ErrorAction SilentlyContinue | Write-Host
        exit 2
    }

    $ffArgs = @(
        '-hide_banner','-loglevel','warning',
        '-f','dshow','-vcodec','mjpeg',
        '-video_size',"${Width}x${Height}",'-framerate',"$Fps",
        '-i',"`"video=$CameraName`"",
        '-c:v','copy','-an',
        '-f','rtsp','-rtsp_transport','tcp',
        'rtsp://publisher:publisher@127.0.0.1:8554/webcam0'
    )
    Write-Host "[verify] starting ffmpeg passthrough '$CameraName' @ ${Width}x${Height}/$Fps..." -ForegroundColor Cyan
    $ffProc = Start-Process -FilePath $ffExe -ArgumentList $ffArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $ffOut -RedirectStandardError $ffErr
    Start-Sleep -Seconds $ProbeWaitSeconds
    if ($ffProc.HasExited) {
        Write-Host "ffmpeg exited immediately. stderr:" -ForegroundColor Red
        Get-Content $ffErr -ErrorAction SilentlyContinue | Write-Host
        Stop-Children
        exit 3
    }

    Write-Host "[verify] probing RTSP via ffprobe..." -ForegroundColor Cyan
    $probeOut = & $ffprobe `
        -v error `
        -rtsp_transport tcp `
        -timeout 5000000 `
        -show_streams `
        -of json `
        'rtsp://viewer:viewer@127.0.0.1:8554/webcam0' 2>&1
    $probeExit = $LASTEXITCODE

    if ($probeExit -ne 0) {
        Write-Host "ffprobe failed (exit $probeExit). Output:" -ForegroundColor Red
        $probeOut | Write-Host
        Stop-Children
        exit 4
    }

    $info = $probeOut | ConvertFrom-Json
    $stream = $info.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if (-not $stream) {
        Write-Host "No video stream returned by ffprobe." -ForegroundColor Red
        $probeOut | Write-Host
        Stop-Children
        exit 5
    }

    Write-Host "[verify] pulling 2s of frames to confirm actual flow..." -ForegroundColor Cyan
    $pullSec = 2
    # -progress pipe:1 emits clean key=value lines on stdout.
    # We pipe to Out-String, grep frame=, take the final value.
    $progressOut = & $ffExe `
        -hide_banner -loglevel error -nostats `
        -rtsp_transport tcp `
        -i 'rtsp://viewer:viewer@127.0.0.1:8554/webcam0' `
        -t $pullSec -an -f null - `
        -progress pipe:1 2>$null
    $frames = 0
    foreach ($line in $progressOut) {
        if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
    }
    if ($frames -lt 1) {
        Write-Host "No frames pulled in $pullSec seconds." -ForegroundColor Red
        Stop-Children
        exit 6
    }
    $observedFps = [math]::Round($frames / $pullSec, 1)

    Write-Host ""
    Write-Host "VERIFY OK" -ForegroundColor Green
    Write-Host ("  codec       : {0}" -f $stream.codec_name)
    Write-Host ("  rtp clock   : {0} (90000 Hz is the standard JPEG/RTP clock)" -f $stream.r_frame_rate)
    Write-Host ("  frames in {0}s: {1}  (~{2} fps)" -f $pullSec, $frames, $observedFps)
    Write-Host ("  publisher   : ffmpeg dshow MJPEG passthrough '$CameraName' @ {0}x{1}/{2}" -f $Width, $Height, $Fps)
    Write-Host ("  rtsp        : rtsp://viewer:viewer@127.0.0.1:8554/webcam0")
    Write-Host ""
    Stop-Children
    exit 0
}
catch {
    Write-Host "verify-spike error: $_" -ForegroundColor Red
    Stop-Children
    exit 1
}
