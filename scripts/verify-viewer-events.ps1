# Verify Slice B: viewer-connected / viewer-disconnected IPC events fired
# via MediaMTX runOnRead/runOnUnread -> mtx_event_hook.exe -> events pipe ->
# supervisor -> control pipe.
#
# Contract under test:
#   1. mtx_event_hook.exe builds and is bundled next to supervisor.exe.
#   2. Supervisor generates mediamtx.runtime.yml with the absolute hook path.
#   3. When a viewer (ffmpeg, here) authenticates and reads a path, the
#      supervisor publishes a `viewer-connected` IPC event with
#      {camera, path, codec, width, height, reader_ip, reader_user}.
#   4. When the viewer disconnects, the supervisor publishes
#      `viewer-disconnected` with the same shape.

[CmdletBinding()]
param(
    [int]$BootSec = 5
)

$ErrorActionPreference = 'Continue'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$hookExe     = Join-Path $root 'supervisor\build\Release\mtx_event_hook.exe'
$ffmpegExe   = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'

if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built" }
if (-not (Test-Path $hookExe))    { throw "mtx_event_hook.exe not built (run cmake --build supervisor\build --config Release)" }
if (-not (Test-Path $ffmpegExe))  { throw "ffmpeg.exe not present in third_party (run scripts\setup-deps.ps1)" }

@(Get-Process -Name 'supervisor','mediamtx','ffmpeg','mtx_event_hook' -EA 0) |
    Stop-Process -Force -EA 0
Start-Sleep 1

# IPC plumbing (same shape as verify-stream-enable.ps1).
function Connect-Ipc {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'webcam-streamer-supervisor',
        [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
    $c.Connect(3000)
    $r = New-Object System.IO.StreamReader($c, [System.Text.Encoding]::UTF8)
    $w = New-Object System.IO.StreamWriter($c, [System.Text.Encoding]::UTF8)
    $w.NewLine = "`n"; $w.AutoFlush = $true
    return @{ client=$c; reader=$r; writer=$w; pending=$null }
}
function Read-Next {
    param($ipc, [int]$TimeoutMs = 1000)
    if (-not $ipc.pending) { $ipc.pending = $ipc.reader.ReadLineAsync() }
    if (-not $ipc.pending.Wait($TimeoutMs)) { return $null }
    $line = $ipc.pending.Result; $ipc.pending = $null
    if ($null -eq $line) { return $null }
    return @{ raw = $line; obj = ($line | ConvertFrom-Json) }
}

$script:capturedEvents = New-Object 'System.Collections.ArrayList'
function Wait-EventName {
    param($ipc, [string]$Name, [int]$TimeoutMs = 15000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next $ipc -TimeoutMs $rem; if (-not $msg) { continue }
        $o = $msg.obj
        if ($o.type -eq 'event') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
            [void]$script:capturedEvents.Add($o)
            if ($o.name -eq $Name) { return $o }
        } elseif ($o.type -eq 'resp') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Green
        }
    }
    return $null
}
function Invoke-Ipc {
    param($ipc, [int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = 5000)
    $line = (@{ type='req'; id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Compress -Depth 6)
    Write-Host "-> $line" -ForegroundColor DarkCyan
    $ipc.writer.WriteLine($line)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next $ipc -TimeoutMs $rem; if (-not $msg) { continue }
        $o = $msg.obj
        if ($o.type -eq 'resp' -and $o.id -eq $Id) {
            Write-Host "<- $($msg.raw)" -ForegroundColor Green
            return $o
        } elseif ($o.type -eq 'event') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
            [void]$script:capturedEvents.Add($o)
        }
    }
    return $null
}

$out = Join-Path $env:TEMP 'sup.viewerevt.out.log'
$err = Join-Path $env:TEMP 'sup.viewerevt.err.log'
Write-Host "[verify-viewer-events] launching supervisor..." -ForegroundColor Cyan
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $out -RedirectStandardError $err
Start-Sleep -Seconds $BootSec

$verdict = $true

try {
    $ipc = Connect-Ipc

    # Find a cam that is enabled + running.
    $r1 = Invoke-Ipc $ipc -Id 1 -Method 'list-cameras'
    $cam = $r1.result | Where-Object { $_.enabled -and $_.running } | Select-Object -First 1
    if (-not $cam) {
        Write-Host "FAIL: no enabled+running camera to test against" -ForegroundColor Red
        $verdict = $false
    } else {
        $rtspPath = $cam.path.TrimStart('/')
        $rtspUrl  = "rtsp://viewer:viewer@127.0.0.1:8554/$rtspPath"
        Write-Host "Test camera: '$($cam.name)' path=$($cam.path)" -ForegroundColor Cyan

        # ---- T1: launch an ffmpeg reader and observe viewer-connected ----
        Write-Host ""
        Write-Host "T1: viewer-connected fires when ffmpeg starts reading" -ForegroundColor Yellow
        # Run reader as a job so we don't block; ffmpeg writes to stderr.
        # Capture stderr explicitly (-RedirectStandardError) for diagnostics;
        # stdout is left attached (null muxer outputs to '-' but writes nothing).
        $readerArgs = @(
            '-loglevel', 'warning',
            '-rtsp_transport', 'tcp',
            '-i', $rtspUrl,
            '-t', '4',                  # read for 4 seconds
            '-f', 'null', 'NUL'
        )
        $readerErr = Join-Path $env:TEMP 'sup.viewerevt.reader.err.log'
        Set-Content -Path $readerErr -Value '' -Force   # truncate
        $readerP = Start-Process -FilePath $ffmpegExe -ArgumentList $readerArgs `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardError $readerErr
        Write-Host "  reader pid=$($readerP.Id)" -ForegroundColor DarkGray

        $connected = Wait-EventName $ipc -Name 'viewer-connected' -TimeoutMs 15000
        if ($connected) {
            $d = $connected.data
            $haveCamera   = $null -ne $d.camera   -and $d.camera   -ne ''
            $haveCodec    = $null -ne $d.codec    -and $d.codec    -ne ''
            $haveReaderIp = $null -ne $d.reader_ip -and $d.reader_ip -ne ''
            if ($haveCamera -and $haveCodec -and $haveReaderIp) {
                Write-Host "  PASS: viewer-connected carries camera='$($d.camera)', codec='$($d.codec)', reader_ip='$($d.reader_ip)'" -ForegroundColor Green
            } else {
                Write-Host "FAIL: viewer-connected missing required fields: $($connected | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
                $verdict = $false
            }
        } else {
            Write-Host "FAIL: no viewer-connected event in 15s" -ForegroundColor Red
            $verdict = $false
        }

        # ---- T2: when ffmpeg ends, expect viewer-disconnected ----
        Write-Host ""
        Write-Host "T2: viewer-disconnected fires when reader exits" -ForegroundColor Yellow
        # Wait for ffmpeg to finish (-t 4 plus a bit of slack).
        for ($i=0; $i -lt 80 -and -not $readerP.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
        if (-not $readerP.HasExited) { Stop-Process -Id $readerP.Id -Force -EA 0 }

        $disconnected = Wait-EventName $ipc -Name 'viewer-disconnected' -TimeoutMs 15000
        if ($disconnected) {
            Write-Host "  PASS: viewer-disconnected fired" -ForegroundColor Green
        } else {
            Write-Host "FAIL: no viewer-disconnected event in 15s" -ForegroundColor Red
            $verdict = $false
        }
    }
} finally {
    if ($ipc) {
        Invoke-Ipc $ipc -Id 9999 -Method 'shutdown' | Out-Null
        $ipc.client.Dispose()
    }
    for ($i=0; $i -lt 30 -and -not $svP.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
    if (-not $svP.HasExited) { Stop-Process -Id $svP.Id -Force -EA 0 }
}

Write-Host ""
if ($verdict) { Write-Host "OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
