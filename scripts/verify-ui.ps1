# Smoke-test the WPF UI:
#   0. clean stragglers
#   1. launch WebcamStreamerUi.exe
#   2. wait for it to spawn supervisor (visible in process tree)
#   3. verify supervisor + mediamtx + ffmpeg all running
#   4. kill the UI process
#   5. verify everything below it died (the UI's own Job Object behavior)

[CmdletBinding()]
param([int]$BootSec = 8)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$uiExe = Join-Path $root 'ui\WebcamStreamerUi\bin\Release\net9.0-windows\WebcamStreamerUi.exe'
if (-not (Test-Path $uiExe)) { throw "WebcamStreamerUi.exe not built: $uiExe" }

# 0. cleanup
@(Get-Process -Name 'WebcamStreamerUi','supervisor','mediamtx','ffmpeg' -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1

Write-Host "[verify-ui] launching WebcamStreamerUi.exe..." -ForegroundColor Cyan
$uiP = Start-Process -FilePath $uiExe -PassThru
Start-Sleep -Seconds $BootSec

# Snapshot what we expect to see while UI is up
$ui   = @(Get-Process -Name 'WebcamStreamerUi' -EA 0)
$sup  = @(Get-Process -Name 'supervisor'       -EA 0)
$mtx  = @(Get-Process -Name 'mediamtx'         -EA 0)
$fff  = @(Get-Process -Name 'ffmpeg'           -EA 0)

Write-Host ("  WebcamStreamerUi : {0} process(es)" -f $ui.Count)
Write-Host ("  supervisor       : {0} process(es)" -f $sup.Count)
Write-Host ("  mediamtx         : {0} process(es)" -f $mtx.Count)
Write-Host ("  ffmpeg           : {0} process(es)" -f $fff.Count)

$verdict = $true
if ($ui.Count  -lt 1) { Write-Host "FAIL: UI exited unexpectedly"     -ForegroundColor Red; $verdict = $false }
if ($sup.Count -lt 1) { Write-Host "FAIL: supervisor not running"     -ForegroundColor Red; $verdict = $false }
if ($mtx.Count -lt 1) { Write-Host "FAIL: mediamtx not running"       -ForegroundColor Red; $verdict = $false }
if ($fff.Count -lt 1) { Write-Host "FAIL: no ffmpeg children running" -ForegroundColor Red; $verdict = $false }

# Sanity-pull one frame from /webcam0 to confirm the streaming chain still works through the UI-launched supervisor
if ($verdict) {
    $ff = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
    $pullPrg = Join-Path $env:TEMP 'verify-ui-pull.progress.log'
    if (Test-Path $pullPrg) { Remove-Item $pullPrg -Force }
    & $ff -hide_banner -loglevel warning -rtsp_transport tcp `
        -i 'rtsp://viewer:viewer@127.0.0.1:8554/webcam0' `
        -t 2 -an -f null - -progress $pullPrg 2>&1 | Out-Null
    $frames = 0
    if (Test-Path $pullPrg) {
        foreach ($line in Get-Content $pullPrg) {
            if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
        }
    }
    if ($frames -ge 1) {
        Write-Host ("  PASS: pulled $frames frames from /webcam0 (~{0} fps)" -f ([math]::Round($frames/2,1))) -ForegroundColor Green
    } else {
        Write-Host "FAIL: stream not viable (0 frames in 2s)" -ForegroundColor Red
        $verdict = $false
    }
}

# 4. kill UI
Write-Host ""
Write-Host "[verify-ui] killing UI process (PID $($uiP.Id))..." -ForegroundColor Cyan
Stop-Process -Id $uiP.Id -Force -EA 0
Start-Sleep -Seconds 3

# 5. verify children died
$ui2  = @(Get-Process -Name 'WebcamStreamerUi' -EA 0)
$sup2 = @(Get-Process -Name 'supervisor'       -EA 0)
$mtx2 = @(Get-Process -Name 'mediamtx'         -EA 0)
$fff2 = @(Get-Process -Name 'ffmpeg'           -EA 0)

Write-Host ("  after kill: ui={0} supervisor={1} mediamtx={2} ffmpeg={3}" -f $ui2.Count, $sup2.Count, $mtx2.Count, $fff2.Count)

if ($ui2.Count  -gt 0) { Write-Host "FAIL: UI still alive"         -ForegroundColor Red; $verdict = $false }
else                    { Write-Host "  PASS: UI gone"             -ForegroundColor Green }
if ($sup2.Count -gt 0) { Write-Host "FAIL: supervisor survived"    -ForegroundColor Red; $verdict = $false }
else                    { Write-Host "  PASS: supervisor died"     -ForegroundColor Green }
if ($mtx2.Count -gt 0) { Write-Host "FAIL: mediamtx survived"      -ForegroundColor Red; $verdict = $false }
else                    { Write-Host "  PASS: mediamtx died"       -ForegroundColor Green }
if ($fff2.Count -gt 0) { Write-Host "FAIL: ffmpeg survived"        -ForegroundColor Red; $verdict = $false }
else                    { Write-Host "  PASS: ffmpeg died"         -ForegroundColor Green }

Write-Host ""
if ($verdict) { Write-Host "OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
