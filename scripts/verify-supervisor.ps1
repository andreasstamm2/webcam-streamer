# Smoke-test the supervisor binary, multi-camera version:
#   0. kill any straggler mediamtx/ffmpeg processes from prior runs
#   1. launch supervisor.exe
#   2. parse its stdout to discover which RTSP paths it advertised
#   3. for each path: pull a few seconds of frames and count
#   4. kill supervisor, verify children die (job object)

[CmdletBinding()]
param(
    [int]$BootSec  = 5,
    [int]$PullSec  = 3
)

$ErrorActionPreference = 'Stop'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$ff          = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'

if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built: $supervisor" }

# --- 0. cleanup -----
$stragglers = Get-Process -Name 'mediamtx','ffmpeg' -ErrorAction SilentlyContinue
if ($stragglers) {
    Write-Host "[verify] killing $(($stragglers).Count) straggler process(es)..." -ForegroundColor Yellow
    $stragglers | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

$out = Join-Path $env:TEMP 'supervisor.verify.out.log'
$err = Join-Path $env:TEMP 'supervisor.verify.err.log'

# --- 1. launch supervisor -----
Write-Host "[verify] launching supervisor.exe..." -ForegroundColor Cyan
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $out -RedirectStandardError $err

Start-Sleep -Seconds $BootSec

if ($svP.HasExited) {
    Write-Host "supervisor exited early (code $($svP.ExitCode)). last stdout:" -ForegroundColor Red
    if (Test-Path $out) { Get-Content $out | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" } }
    exit 1
}

Write-Host "--- supervisor stdout (last 30 lines) ---" -ForegroundColor DarkGray
if (Test-Path $out) { Get-Content $out | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" } }

# --- 2. discover advertised RTSP paths from supervisor log -----
$paths = @()
if (Test-Path $out) {
    foreach ($line in Get-Content $out) {
        # supervisor logs like: "  rtsp://viewer:viewer@<host>:8554/webcam0  (Logitech BRIO, mode=...)"
        if ($line -match 'rtsp://viewer:viewer@<host>:8554(/[\w]+)\s+\(([^,]+),\s*mode=([^\)]+)\)') {
            $paths += [pscustomobject]@{
                path = $Matches[1]
                cam  = $Matches[2]
                mode = $Matches[3]
            }
        }
    }
}
if ($paths.Count -eq 0) {
    Write-Host "could not discover any RTSP paths from supervisor log" -ForegroundColor Red
    Stop-Process -Id $svP.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- 3. pull from each path -----
$results = @()
foreach ($p in $paths) {
    $url = "rtsp://viewer:viewer@127.0.0.1:8554$($p.path)"
    Write-Host ""
    Write-Host "[verify] pulling ${PullSec}s from $($p.path) ($($p.cam), $($p.mode))..." -ForegroundColor Cyan
    $pullPrg = Join-Path $env:TEMP "verify-pull-$($p.path -replace '/','').progress.log"
    $pullErr = Join-Path $env:TEMP "verify-pull-$($p.path -replace '/','').err.log"
    if (Test-Path $pullPrg) { Remove-Item $pullPrg -Force }

    $pullArgs = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
        '-i', $url, '-t', "$PullSec", '-an', '-f','null','-',
        '-progress', $pullPrg)
    $pullP = Start-Process -FilePath $ff -ArgumentList $pullArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $env:TEMP "verify-pull.out.log") `
        -RedirectStandardError $pullErr
    $pullP.WaitForExit()
    $pullExit = $pullP.ExitCode

    $frames = 0
    if (Test-Path $pullPrg) {
        foreach ($line in Get-Content $pullPrg) {
            if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
        }
    }
    $obs = if ($frames -gt 0) { [math]::Round($frames / $PullSec, 1) } else { 0 }
    $row = [pscustomobject]@{
        path     = $p.path
        cam      = $p.cam
        mode     = $p.mode
        ok       = ($pullExit -eq 0 -and $frames -ge 1)
        frames   = $frames
        obs_fps  = $obs
        pullExit = $pullExit
    }
    $results += $row
    if ($row.ok) {
        Write-Host ("  PASS: $frames frames in ${PullSec}s (~$obs fps)") -ForegroundColor Green
    } else {
        Write-Host ("  FAIL: pullExit=$pullExit frames=$frames") -ForegroundColor Red
        if (Test-Path $pullErr) { Get-Content $pullErr | Select-Object -Last 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    }
}

# --- 4. teardown + verify job-object kills children -----
Start-Sleep -Seconds 1
$childMtx = @(Get-Process -Name 'mediamtx' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$childFf  = @(Get-Process -Name 'ffmpeg'  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

Write-Host ""
Write-Host "[verify] stopping supervisor (PID $($svP.Id))..." -ForegroundColor Cyan
Stop-Process -Id $svP.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$mtxAfter = @(Get-Process -Name 'mediamtx' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$ffAfter  = @(Get-Process -Name 'ffmpeg'  -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

$mtxSurvived = @($mtxAfter | Where-Object { $childMtx -contains $_ })
$ffSurvived  = @($ffAfter  | Where-Object { $childFf  -contains $_ })

# --- summary -----
Write-Host ""
Write-Host "==== summary ====" -ForegroundColor Yellow
$results | Format-Table -AutoSize
$verdict = $true
foreach ($r in $results) { if (-not $r.ok) { $verdict = $false } }

if ($mtxSurvived.Count -gt 0) {
    Write-Host "  FAIL: $($mtxSurvived.Count) mediamtx survived after supervisor kill" -ForegroundColor Red
    $verdict = $false
} else {
    Write-Host "  PASS: mediamtx died with supervisor" -ForegroundColor Green
}
if ($ffSurvived.Count -gt 0) {
    Write-Host "  FAIL: $($ffSurvived.Count) ffmpeg survived after supervisor kill" -ForegroundColor Red
    $verdict = $false
} else {
    Write-Host "  PASS: ffmpeg died with supervisor" -ForegroundColor Green
}

if ($verdict) { Write-Host "  OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "  OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
