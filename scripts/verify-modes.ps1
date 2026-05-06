# Test multiple encoding modes against MediaMTX -> WebEye-style pull.
# For each mode: publish for a few seconds, pull via ffmpeg, count frames, report.

[CmdletBinding()]
param(
    [string]$CameraName = 'Logitech BRIO',
    [int]$Width  = 1280,
    [int]$Height = 720,
    [int]$Fps    = 30,
    [int]$PullSec = 3
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$ff        = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
$mtxExe    = Join-Path $root 'third_party\mediamtx\mediamtx.exe'
$mtxYml    = Join-Path $root 'config\mediamtx.yml'

$rtspPub  = 'rtsp://publisher:publisher@127.0.0.1:8554/webcam0'
$rtspView = 'rtsp://viewer:viewer@127.0.0.1:8554/webcam0'

function Test-Mode {
    param(
        [string]$Label,
        [string[]]$EncodeArgs   # e.g. @('-c:v','copy') or @('-c:v','libx264','-preset','ultrafast',...)
    )

    Write-Host ""
    Write-Host "=== mode: $Label ===" -ForegroundColor Cyan

    # Start mediamtx fresh
    $mtxOut = Join-Path $env:TEMP "vm-mtx-$Label.out.log"
    $mtxErr = Join-Path $env:TEMP "vm-mtx-$Label.err.log"
    $mtxP = Start-Process -FilePath $mtxExe -ArgumentList @($mtxYml) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $mtxOut -RedirectStandardError $mtxErr
    Start-Sleep 1

    # Publisher
    $pubArgs = @('-hide_banner','-loglevel','warning',
        '-f','dshow','-vcodec','mjpeg','-video_size',"${Width}x${Height}",'-framerate',"$Fps",
        '-i',"`"video=$CameraName`"") + $EncodeArgs + @(
        '-an','-f','rtsp','-rtsp_transport','tcp', $rtspPub)
    $pubOut = Join-Path $env:TEMP "vm-pub-$Label.out.log"
    $pubErr = Join-Path $env:TEMP "vm-pub-$Label.err.log"
    $pubP = Start-Process -FilePath $ff -ArgumentList $pubArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $pubOut -RedirectStandardError $pubErr
    Start-Sleep 3
    if ($pubP.HasExited) {
        Write-Host "  publisher died. last lines:" -ForegroundColor Red
        Get-Content $pubErr | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" }
        Stop-Process -Id $mtxP.Id -Force -EA 0
        return [pscustomobject]@{ mode=$Label; ok=$false; reason='publisher_died'; frames=0 }
    }

    # Pull and count frames via ffmpeg (-progress pipe:1 to a file)
    $pullErr = Join-Path $env:TEMP "vm-pull-$Label.err.log"
    $pullPrg = Join-Path $env:TEMP "vm-pull-$Label.progress.log"
    $pullArgs = @('-hide_banner','-loglevel','info','-rtsp_transport','tcp',
        '-i', $rtspView, '-t', "$PullSec", '-an', '-f','null','-',
        '-progress', $pullPrg)
    $pullP = Start-Process -FilePath $ff -ArgumentList $pullArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $env:TEMP "vm-pull-$Label.out.log") `
        -RedirectStandardError $pullErr
    $pullP.WaitForExit()
    $pullExit = $pullP.ExitCode

    $frames = 0
    if (Test-Path $pullPrg) {
        $progressLines = Get-Content $pullPrg
        foreach ($line in $progressLines) {
            if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
        }
    }

    # Cleanup
    if (-not $pubP.HasExited) { Stop-Process -Id $pubP.Id -Force -EA 0 }
    Stop-Process -Id $mtxP.Id -Force -EA 0
    Start-Sleep 1

    $ok = ($pullExit -eq 0 -and $frames -ge 1)
    if (-not $ok) {
        Write-Host "  FAIL pullExit=$pullExit frames=$frames" -ForegroundColor Red
        Write-Host "  pull stderr (last 6):" -ForegroundColor DarkGray
        Get-Content $pullErr -ErrorAction SilentlyContinue | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    } else {
        $obs = [math]::Round($frames / $PullSec, 1)
        Write-Host "  OK frames=$frames over ${PullSec}s (~$obs fps)" -ForegroundColor Green
    }
    return [pscustomobject]@{ mode=$Label; ok=$ok; pullExit=$pullExit; frames=$frames }
}

$results = @()
$results += Test-Mode -Label 'mjpeg-copy'    -EncodeArgs @('-c:v','copy')
$results += Test-Mode -Label 'mjpeg-reencode' -EncodeArgs @('-c:v','mjpeg','-q:v','4')
$results += Test-Mode -Label 'h264-libx264' -EncodeArgs @(
    '-c:v','libx264','-preset','ultrafast','-tune','zerolatency',
    '-pix_fmt','yuv420p','-g','60','-bf','0','-x264-params','keyint=60:scenecut=0')

Write-Host ""
Write-Host "==== summary ====" -ForegroundColor Yellow
$results | Format-Table -AutoSize
