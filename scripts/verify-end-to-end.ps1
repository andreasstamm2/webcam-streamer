# End-to-end test of the full stack.
#
# Section A (supervisor-driven, IPC-rich):
#   - launch supervisor.exe directly
#   - connect via named-pipe IPC
#   - enumerate cameras via list-cameras
#   - in parallel: spawn ffmpeg consumers for every /webcamN, count frames
#   - round-trip set-mode -> re-consume -> verify still streaming
#   - restart-camera -> re-consume -> verify resumes
#   - shutdown via IPC, verify supervisor + mediamtx + ffmpeg children all die
#
# Section B (UI-driven, stream-only):
#   - launch WebcamStreamerUi.exe (which spawns its own supervisor)
#   - the UI owns the single IPC client slot, so this section consumes the
#     RTSP streams from outside without IPC and verifies frames flow
#   - kill UI, verify the entire process tree dies (Job Object cascade)
#
# This is the canonical regression test for the whole product.

[CmdletBinding()]
param(
    [int]$BootSec        = 6,
    [int]$StreamPullSec  = 4,
    [int]$MinFramesPerStream = 8,    # generous lower bound (handles cams that drop fps in low light)
    [int]$IpcTimeoutMs   = 10000
)

$ErrorActionPreference = 'Stop'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$uiExe       = Join-Path $root 'ui\WebcamStreamerUi\bin\Release\net9.0-windows\WebcamStreamerUi.exe'
$ff          = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'

if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built: $supervisor" }
if (-not (Test-Path $uiExe))      { throw "UI not built: $uiExe" }
if (-not (Test-Path $ff))         { throw "ffmpeg not present (run setup-deps.ps1)" }

function Phase($n, $title) { Write-Host ""; Write-Host "=== PHASE $n -- $title ===" -ForegroundColor Cyan }
function Pass($msg)        { Write-Host "  PASS: $msg" -ForegroundColor Green }
function Fail($msg)        { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:verdict = $false }
function Info_($msg)       { Write-Host "  $msg" -ForegroundColor DarkGray }

$script:verdict = $true

# ----- helper: pull a stream with ffmpeg, count frames -------------------------
function Test-Pull {
    param([string]$Path, [string]$Tag, [int]$Sec = 4)
    $progress = Join-Path $env:TEMP "e2e-$Tag.progress.log"
    $errLog   = Join-Path $env:TEMP "e2e-$Tag.err.log"
    if (Test-Path $progress) { Remove-Item $progress -Force }
    $args = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
              '-i', "rtsp://viewer:viewer@127.0.0.1:8554$Path",
              '-t', "$Sec", '-an', '-f','null','-', '-progress', $progress)
    $p = Start-Process -FilePath $ff -ArgumentList $args -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $env:TEMP "e2e-$Tag.out.log") `
        -RedirectStandardError  $errLog
    $p.WaitForExit(($Sec + 5) * 1000) | Out-Null
    $frames = 0
    if (Test-Path $progress) {
        foreach ($line in Get-Content $progress) {
            if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
        }
    }
    return [pscustomobject]@{ frames = $frames; errLog = $errLog; path = $Path }
}

# ----- helper: parallel pulls ---------------------------------------------------
function Test-PullParallel {
    param([array]$Cameras, [int]$Sec)
    $jobs = @()
    foreach ($c in $Cameras) {
        $tag = ($c.path -replace '/','')
        $progress = Join-Path $env:TEMP "e2e-par-$tag.progress.log"
        $errLog   = Join-Path $env:TEMP "e2e-par-$tag.err.log"
        if (Test-Path $progress) { Remove-Item $progress -Force }
        $args = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
                  '-i', "rtsp://viewer:viewer@127.0.0.1:8554$($c.path)",
                  '-t', "$Sec", '-an', '-f','null','-', '-progress', $progress)
        $p = Start-Process -FilePath $ff -ArgumentList $args -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $env:TEMP "e2e-par-$tag.out.log") `
            -RedirectStandardError  $errLog
        $jobs += [pscustomobject]@{ cam = $c; proc = $p; progress = $progress; err = $errLog }
        Info_ "started consumer for $($c.path) (PID $($p.Id))"
    }
    foreach ($j in $jobs) { $j.proc.WaitForExit(($Sec + 5) * 1000) | Out-Null }
    foreach ($j in $jobs) {
        $frames = 0
        if (Test-Path $j.progress) {
            foreach ($line in Get-Content $j.progress) {
                if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
            }
        }
        $j | Add-Member -MemberType NoteProperty -Name frames -Value $frames -PassThru | Out-Null
    }
    return $jobs
}

# ============================================================================
# Section A: supervisor-driven
# ============================================================================
Phase 0 'cleanup stragglers'
@(Get-Process -Name 'WebcamStreamerUi','supervisor','mediamtx','ffmpeg' -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1
$leftover = @(Get-Process -Name 'WebcamStreamerUi','supervisor','mediamtx','ffmpeg' -EA 0)
if ($leftover.Count -ne 0) { Fail "couldn't kill stragglers"; exit 1 }
Pass "no stragglers"

Phase 'A1' 'launch supervisor.exe directly (no UI)'
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $env:TEMP 'e2e.sup.out.log') `
    -RedirectStandardError  (Join-Path $env:TEMP 'e2e.sup.err.log')
Start-Sleep -Seconds $BootSec
if ($svP.HasExited) { Fail "supervisor exited unexpectedly"; exit 1 }
Pass "supervisor running (PID $($svP.Id))"

Phase 'A2' 'connect IPC and enumerate cameras'
$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'webcam-streamer-supervisor',
    [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
$client.Connect(3000)
$reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
$writer = New-Object System.IO.StreamWriter($client, [System.Text.Encoding]::UTF8)
$writer.NewLine = "`n"; $writer.AutoFlush = $true
Pass "named-pipe connected"

# Single-task pump (StreamReader does not allow overlapping ReadLineAsync).
$script:pendingTask = $null
function Read-Next {
    param([int]$TimeoutMs = 1000)
    if (-not $script:pendingTask) { $script:pendingTask = $reader.ReadLineAsync() }
    if (-not $script:pendingTask.Wait($TimeoutMs)) { return $null }
    $line = $script:pendingTask.Result; $script:pendingTask = $null
    if ($null -eq $line) { return $null }
    return @{ raw = $line; obj = ($line | ConvertFrom-Json) }
}
function Wait-Response {
    param([int]$Id, [int]$TimeoutMs = $IpcTimeoutMs)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next -TimeoutMs $rem
        if (-not $msg) { continue }
        if ($msg.obj.type -eq 'resp' -and $msg.obj.id -eq $Id) { return $msg.obj }
        # events ignored in this script
    }
    return $null
}
function Invoke-Ipc {
    param([int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = $IpcTimeoutMs)
    $req = [ordered]@{ type='req'; id=$Id; method=$Method; params=$Params }
    $writer.WriteLine(($req | ConvertTo-Json -Compress -Depth 6))
    return Wait-Response -Id $Id -TimeoutMs $TimeoutMs
}

$listResp = Invoke-Ipc -Id 1 -Method 'list-cameras'
if (-not ($listResp -and $listResp.ok -and $listResp.result.Count -ge 1)) {
    Fail "list-cameras returned no cameras"; exit 1
}
$cams = $listResp.result
Pass "$($cams.Count) camera(s) enumerated"
foreach ($c in $cams) { Info_ ("  '{0}' @ {1}  mode={2}  running={3}" -f $c.name, $c.path, $c.mode, $c.running) }

Phase 'A3' 'pull every /webcamN with ffmpeg consumers in parallel'
$jobs = Test-PullParallel -Cameras $cams -Sec $StreamPullSec
foreach ($j in $jobs) {
    $obs = if ($j.frames -gt 0) { [math]::Round($j.frames / $StreamPullSec, 1) } else { 0 }
    if ($j.frames -ge $MinFramesPerStream) {
        Pass ("'{0}' on {1}: {2} frames in {3}s (~{4} fps, mode={5})" -f $j.cam.name, $j.cam.path, $j.frames, $StreamPullSec, $obs, $j.cam.mode)
    } else {
        Fail ("'{0}' on {1}: only {2} frames in {3}s (mode={4})" -f $j.cam.name, $j.cam.path, $j.frames, $StreamPullSec, $j.cam.mode)
        if (Test-Path $j.err) { Get-Content $j.err | Select-Object -Last 4 | ForEach-Object { Info_ "    $_" } }
    }
}

Phase 'A4' 'set-mode round trip on first cam'
$cam = $cams[0]
$origMode = $cam.mode
$alt = if ($origMode -eq 'transcode_mjpeg_to_h264') { 'passthrough_mjpeg' } else { 'transcode_mjpeg_to_h264' }
$smResp = Invoke-Ipc -Id 10 -Method 'set-mode' -Params @{name=$cam.name; mode=$alt}
if ($smResp.ok -and $smResp.result.mode -eq $alt) { Pass "set-mode '$($cam.name)' -> $alt" }
else { Fail "set-mode rejected: $($smResp.error)" }
Start-Sleep -Seconds 3
$r = Test-Pull -Path $cam.path -Tag "postmode" -Sec $StreamPullSec
if ($r.frames -ge $MinFramesPerStream) { Pass "stream still flows after set-mode ($($r.frames) frames, mode=$alt)" }
else                                    { Fail "stream broken after set-mode (only $($r.frames) frames)" }

# Restore + cleanup override file
Invoke-Ipc -Id 11 -Method 'set-mode' -Params @{name=$cam.name; mode=$origMode} | Out-Null
$slug = ($cam.name -replace '[^a-zA-Z0-9]+','-').TrimEnd('-')
$overridePath = Join-Path $root "probes\$slug.override.txt"
if (Test-Path $overridePath) { Remove-Item $overridePath -Force }
Pass "restored mode + cleaned up override file"

Phase 'A5' 'restart-camera + verify resume'
$rrResp = Invoke-Ipc -Id 20 -Method 'restart-camera' -Params @{name=$cam.name}
if ($rrResp.ok) { Pass "restart-camera '$($cam.name)'" } else { Fail "restart-camera failed: $($rrResp.error)" }
Start-Sleep -Seconds 2
$r = Test-Pull -Path $cam.path -Tag "postrestart" -Sec $StreamPullSec
if ($r.frames -ge $MinFramesPerStream) { Pass "stream resumes after restart ($($r.frames) frames)" }
else                                    { Fail "stream broken after restart (only $($r.frames) frames)" }

Phase 'A6' 'shutdown via IPC + verify supervisor + children die'
$shResp = Invoke-Ipc -Id 99 -Method 'shutdown'
if (-not ($shResp -and $shResp.ok)) { Fail "shutdown method returned not-ok" } else { Pass "shutdown method ack" }
$client.Dispose()
$gone = $false
for ($i=0; $i -lt 30; $i++) {
    if ($svP.HasExited) { $gone = $true; break }
    Start-Sleep -Milliseconds 200
}
if ($gone) { Pass "supervisor exited" } else { Fail "supervisor still alive after 6s"; Stop-Process -Id $svP.Id -Force -EA 0 }
Start-Sleep -Seconds 2
$tree = @{
    sup = @(Get-Process -Name 'supervisor' -EA 0).Count
    mtx = @(Get-Process -Name 'mediamtx'   -EA 0).Count
    ff  = @(Get-Process -Name 'ffmpeg'     -EA 0).Count
}
if ($tree.sup -gt 0) { Fail "supervisor survived" }       else { Pass "supervisor gone" }
if ($tree.mtx -gt 0) { Fail "mediamtx survived" }          else { Pass "mediamtx gone" }
if ($tree.ff  -gt 0) { Fail "ffmpeg child(ren) survived" } else { Pass "all ffmpegs gone" }

# ============================================================================
# Section B: UI-driven (no IPC; UI owns the pipe)
# ============================================================================
Phase 'B1' 'launch WebcamStreamerUi.exe (full stack)'
$uiP = Start-Process -FilePath $uiExe -PassThru
Start-Sleep -Seconds $BootSec
if ($uiP.HasExited) { Fail "UI exited (code $($uiP.ExitCode))"; exit 1 }
Pass "UI running (PID $($uiP.Id))"
$ut = @{
    ui = @(Get-Process -Name 'WebcamStreamerUi' -EA 0).Count
    sp = @(Get-Process -Name 'supervisor'       -EA 0).Count
    mt = @(Get-Process -Name 'mediamtx'         -EA 0).Count
    ff = @(Get-Process -Name 'ffmpeg'           -EA 0).Count
}
Info_ ("process tree: ui={0} supervisor={1} mediamtx={2} ffmpeg={3}" -f $ut.ui, $ut.sp, $ut.mt, $ut.ff)
if ($ut.sp -lt 1 -or $ut.mt -lt 1 -or $ut.ff -lt 1) { Fail "UI did not spawn full tree" }
else { Pass "UI spawned supervisor + mediamtx + ffmpeg" }

Phase 'B2' 'consume /webcam0 from the UI-spawned supervisor'
# We don't know the cam list (UI owns IPC), but /webcam0 is always the first one.
$r = Test-Pull -Path "/webcam0" -Tag "ui-consumer" -Sec $StreamPullSec
$obs = if ($r.frames -gt 0) { [math]::Round($r.frames / $StreamPullSec, 1) } else { 0 }
if ($r.frames -ge $MinFramesPerStream) { Pass "ffmpeg consumer pulled $($r.frames) frames in ${StreamPullSec}s (~${obs} fps)" }
else                                    { Fail "no frames from /webcam0 (got $($r.frames))" }

Phase 'B3' 'kill UI + verify Job Object cascade tears down everything'
Stop-Process -Id $uiP.Id -Force -EA 0
Start-Sleep -Seconds 3
$ut = @{
    ui = @(Get-Process -Name 'WebcamStreamerUi' -EA 0).Count
    sp = @(Get-Process -Name 'supervisor'       -EA 0).Count
    mt = @(Get-Process -Name 'mediamtx'         -EA 0).Count
    ff = @(Get-Process -Name 'ffmpeg'           -EA 0).Count
}
Info_ ("after kill: ui={0} supervisor={1} mediamtx={2} ffmpeg={3}" -f $ut.ui, $ut.sp, $ut.mt, $ut.ff)
if ($ut.ui -gt 0) { Fail "UI survived" }       else { Pass "UI gone" }
if ($ut.sp -gt 0) { Fail "supervisor survived" } else { Pass "supervisor gone (Job Object)" }
if ($ut.mt -gt 0) { Fail "mediamtx survived" }   else { Pass "mediamtx gone" }
if ($ut.ff -gt 0) { Fail "ffmpeg survived" }     else { Pass "ffmpeg gone" }

# ----- final verdict ----------------------------------------------------------
Write-Host ""
if ($script:verdict) {
    Write-Host "=== END-TO-END: PASS ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== END-TO-END: FAIL ===" -ForegroundColor Red
    exit 1
}
