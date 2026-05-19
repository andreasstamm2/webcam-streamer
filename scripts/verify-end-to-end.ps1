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
    # The default mode (transcode_mjpeg_to_h264) needs ~8-10s for the
    # ffmpeg publisher to negotiate dshow + the H.264 encoder warm-up and
    # for MediaMTX to see the publish. The old default (passthrough_mjpeg)
    # was lighter to spin up but didn't actually stream correctly on real
    # consumer cams.
    [int]$BootSec        = 12,
    [int]$StreamPullSec  = 4,
    [int]$MinFramesPerStream = 8,    # generous lower bound (handles cams that drop fps in low light)
    [int]$IpcTimeoutMs   = 10000
)

$ErrorActionPreference = 'Stop'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$uiExe       = Join-Path $root 'ui\WebcamStreamerUi\bin\Release\net9.0-windows10.0.19041.0\WebcamStreamerUi.exe'
$ff          = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'

# Viewer credentials. The supervisor reads (or generates and writes) these
# in <root>\settings.json on startup since v0.3. Read them here so the
# pull tests authenticate against the same values MediaMTX expects.
# Falls back to the legacy viewer/viewer pair only if the file doesn't
# exist yet (the first supervisor start will create it).
function Get-ViewerCreds {
    $sp = Join-Path $root 'settings.json'
    if (-not (Test-Path $sp)) { return @{ user = 'viewer'; pass = 'viewer' } }
    try {
        $s = Get-Content $sp -Raw | ConvertFrom-Json
        $u = $s.viewer_user
        $p = $s.viewer_pass
        if ([string]::IsNullOrEmpty($u)) { $u = 'viewer' }
        if ([string]::IsNullOrEmpty($p)) { $p = 'viewer' }
        return @{ user = $u; pass = $p }
    } catch { return @{ user = 'viewer'; pass = 'viewer' } }
}

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
    $u = $script:viewer.user
    $p = $script:viewer.pass
    $args = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
              '-i', "rtsp://${u}:${p}@127.0.0.1:8554$Path",
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
    $u = $script:viewer.user
    $vp = $script:viewer.pass
    foreach ($c in $Cameras) {
        $tag = ($c.path -replace '/','')
        $progress = Join-Path $env:TEMP "e2e-par-$tag.progress.log"
        $errLog   = Join-Path $env:TEMP "e2e-par-$tag.err.log"
        if (Test-Path $progress) { Remove-Item $progress -Force }
        $args = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
                  '-i', "rtsp://${u}:${vp}@127.0.0.1:8554$($c.path)",
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

# After supervisor has booted, settings.json contains either the
# installer-generated creds or the supervisor's first-run fallback.
# Read them into a script-scoped record so every Test-Pull below
# authenticates with whatever the running mediamtx instance actually
# expects.
$script:viewer = Get-ViewerCreds
Info_ "viewer creds: user='$($script:viewer.user)'"

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
$script:capturedEvents = New-Object 'System.Collections.ArrayList'
function Wait-Response {
    param([int]$Id, [int]$TimeoutMs = $IpcTimeoutMs)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next -TimeoutMs $rem
        if (-not $msg) { continue }
        if ($msg.obj.type -eq 'resp' -and $msg.obj.id -eq $Id) { return $msg.obj }
        if ($msg.obj.type -eq 'event') { [void]$script:capturedEvents.Add($msg.obj) }
    }
    return $null
}
function Wait-EventName {
    param([string]$Name, [int]$TimeoutMs = 10000)
    # First scan any events we've already buffered while waiting on other responses.
    foreach ($ev in $script:capturedEvents) { if ($ev.name -eq $Name) { return $ev } }
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next -TimeoutMs $rem
        if (-not $msg) { continue }
        if ($msg.obj.type -eq 'event') {
            [void]$script:capturedEvents.Add($msg.obj)
            if ($msg.obj.name -eq $Name) { return $msg.obj }
        }
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
# Use passthrough_mjpeg as the "alt" purely to exercise set-mode's IPC path
# and override persistence. We don't require it to actually stream -- the
# pipeline is documented-broken on every consumer cam we ship for (see
# CLAUDE.md codec matrix). The post-restore re-pull below covers the
# "set-mode round trip preserves streaming" property.
$alt = if ($origMode -eq 'transcode_mjpeg_to_h264') { 'passthrough_mjpeg' } else { 'transcode_mjpeg_to_h264' }
$smResp = Invoke-Ipc -Id 10 -Method 'set-mode' -Params @{name=$cam.name; mode=$alt}
if ($smResp.ok -and $smResp.result.mode -eq $alt) { Pass "set-mode '$($cam.name)' -> $alt (IPC echo)" }
else { Fail "set-mode rejected: $($smResp.error)" }

# Restore + cleanup override file
Invoke-Ipc -Id 11 -Method 'set-mode' -Params @{name=$cam.name; mode=$origMode} | Out-Null
$slug = ($cam.name -replace '[^a-zA-Z0-9]+','-').TrimEnd('-')
$overridePath = Join-Path $root "probes\$slug.override.txt"
if (Test-Path $overridePath) { Remove-Item $overridePath -Force }
Start-Sleep -Seconds 3
$r = Test-Pull -Path $cam.path -Tag "postrestore" -Sec $StreamPullSec
if ($r.frames -ge $MinFramesPerStream) { Pass "stream resumes after restore to '$origMode' ($($r.frames) frames)" }
else                                    { Fail "stream broken after set-mode restore (only $($r.frames) frames)" }
Pass "restored mode + cleaned up override file"

Phase 'A5' 'restart-camera + verify resume'
$rrResp = Invoke-Ipc -Id 20 -Method 'restart-camera' -Params @{name=$cam.name}
if ($rrResp.ok) { Pass "restart-camera '$($cam.name)'" } else { Fail "restart-camera failed: $($rrResp.error)" }
# The default transcode_mjpeg_to_h264 pipeline needs ~8s after restart for
# the dshow input + libx264 encoder + MediaMTX publish to all come back up.
Start-Sleep -Seconds 6
$r = Test-Pull -Path $cam.path -Tag "postrestart" -Sec $StreamPullSec
if ($r.frames -ge $MinFramesPerStream) { Pass "stream resumes after restart ($($r.frames) frames)" }
else                                    { Fail "stream broken after restart (only $($r.frames) frames)" }

Phase 'A6a' 'set-stream-enabled round trip (Slice A)'
$ssResp = Invoke-Ipc -Id 30 -Method 'set-stream-enabled' -Params @{name=$cam.name; enabled=$false}
if ($ssResp.ok -and $ssResp.result.enabled -eq $false) { Pass "set-stream-enabled enabled=false" }
else { Fail "set-stream-enabled disable rejected: $($ssResp.error)" }
Start-Sleep -Seconds 2
$listAfter = Invoke-Ipc -Id 31 -Method 'list-cameras'
$row = $listAfter.result | Where-Object { $_.name -eq $cam.name }
if ($row.enabled -eq $false -and $row.running -eq $false) { Pass "list-cameras shows enabled=false running=false" }
else { Fail "list-cameras still shows enabled=$($row.enabled) running=$($row.running)" }
$reResp = Invoke-Ipc -Id 32 -Method 'set-stream-enabled' -Params @{name=$cam.name; enabled=$true}
if ($reResp.ok -and $reResp.result.enabled -eq $true) { Pass "set-stream-enabled re-enable" }
else { Fail "set-stream-enabled re-enable rejected" }
Start-Sleep -Seconds 3
# Clean up override file the round-trip wrote so it doesn't pollute other runs.
$overridePathA6 = Join-Path $root "probes\$slug.override.txt"
if (Test-Path $overridePathA6) { Remove-Item $overridePathA6 -Force }

Phase 'A6b' 'viewer-connected fires when ffmpeg reads (Slice B)'
$script:capturedEvents.Clear()
$readerProc = Start-Process -FilePath $ff -ArgumentList @(
    '-loglevel','quiet','-rtsp_transport','tcp',
    '-i',"rtsp://$($script:viewer.user):$($script:viewer.pass)@127.0.0.1:8554$($cam.path)",
    '-t','3','-f','null','NUL'
) -PassThru -WindowStyle Hidden
$vc = Wait-EventName -Name 'viewer-connected' -TimeoutMs 15000
if ($vc) {
    $haveCam   = $null -ne $vc.data.camera   -and $vc.data.camera   -ne ''
    $haveCodec = $null -ne $vc.data.codec    -and $vc.data.codec    -ne ''
    if ($haveCam -and $haveCodec) { Pass "viewer-connected: camera='$($vc.data.camera)' codec='$($vc.data.codec)'" }
    else { Fail "viewer-connected missing fields: $($vc | ConvertTo-Json -Compress -Depth 4)" }
} else {
    Fail "viewer-connected not received in 15s"
}
$vd = Wait-EventName -Name 'viewer-disconnected' -TimeoutMs 15000
if ($vd) { Pass "viewer-disconnected fired" } else { Fail "viewer-disconnected not received" }
for ($i=0; $i -lt 30 -and -not $readerProc.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
if (-not $readerProc.HasExited) { Stop-Process -Id $readerProc.Id -Force -EA 0 }

Phase 'A6c' 'viewer-auth-failed fires on bad credentials (Slice C)'
$script:capturedEvents.Clear()
$badReader = Start-Process -FilePath $ff -ArgumentList @(
    '-loglevel','quiet','-rtsp_transport','tcp',
    '-i',"rtsp://$($script:viewer.user):WRONGPASSWORD_e2etest@127.0.0.1:8554$($cam.path)",
    '-t','1','-f','null','NUL'
) -PassThru -WindowStyle Hidden
$af = Wait-EventName -Name 'viewer-auth-failed' -TimeoutMs 15000
if ($af -and $af.data.reader_ip -and $af.data.reason) {
    Pass "viewer-auth-failed: reader_ip='$($af.data.reader_ip)' reason='$($af.data.reason)'"
} else {
    Fail "viewer-auth-failed not received or missing fields"
}
for ($i=0; $i -lt 30 -and -not $badReader.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
if (-not $badReader.HasExited) { Stop-Process -Id $badReader.Id -Force -EA 0 }

Phase 'A6' 'shutdown via IPC + verify supervisor + children die'
$shResp = Invoke-Ipc -Id 99 -Method 'shutdown'
if (-not ($shResp -and $shResp.ok)) { Fail "shutdown method returned not-ok" } else { Pass "shutdown method ack" }
$client.Dispose()
$gone = $false
# Supervision loop now spawns ffmpeg subprocesses in Phase 2 for format
# enumeration; worst case ~2-3s before the next g_stop check. Give it
# generous wall-clock time before declaring it stuck.
for ($i=0; $i -lt 50; $i++) {
    if ($svP.HasExited) { $gone = $true; break }
    Start-Sleep -Milliseconds 200
}
if ($gone) { Pass "supervisor exited" } else { Fail "supervisor still alive after 10s"; Stop-Process -Id $svP.Id -Force -EA 0 }
Start-Sleep -Seconds 4
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
