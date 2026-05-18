# Verify Slice C: viewer-auth-failed IPC event when a reader presents bad
# credentials to MediaMTX.
#
# Mechanism (out of necessity -- MediaMTX exposes no hook for failed auth):
#   1. Supervisor captures MediaMTX child's stdout (process_supervisor's
#      on_stdout_line callback).
#   2. main.cpp regex-matches "[RTSP] [conn IP:PORT] closed: authentication
#      failed" lines and publishes `viewer-auth-failed` IPC events.
#
# Contract:
#   - We connect ffmpeg with deliberately wrong credentials.
#   - The supervisor must emit `viewer-auth-failed` carrying {reader_ip, reason}.

[CmdletBinding()]
param(
    [int]$BootSec = 5
)

$ErrorActionPreference = 'Continue'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$ffmpegExe   = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built" }
if (-not (Test-Path $ffmpegExe))  { throw "ffmpeg.exe missing (run scripts\setup-deps.ps1)" }

@(Get-Process supervisor,mediamtx,ffmpeg,mtx_event_hook -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1

# IPC plumbing (same shape as the other verify scripts).
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
function Wait-EventName {
    param($ipc, [string]$Name, [int]$TimeoutMs = 15000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next $ipc -TimeoutMs $rem; if (-not $msg) { continue }
        $o = $msg.obj
        if ($o.type -eq 'event') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
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
        }
    }
    return $null
}

$out = Join-Path $env:TEMP 'sup.authfail.out.log'
Write-Host "[verify-auth-fail] launching supervisor..." -ForegroundColor Cyan
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $out -RedirectStandardError (Join-Path $env:TEMP 'sup.authfail.err.log')
Start-Sleep -Seconds $BootSec

$verdict = $true

try {
    $ipc = Connect-Ipc
    $r1 = Invoke-Ipc $ipc -Id 1 -Method 'list-cameras'
    $cam = $r1.result | Where-Object { $_.enabled -and $_.running } | Select-Object -First 1
    if (-not $cam) {
        Write-Host "FAIL: no enabled+running camera" -ForegroundColor Red
        Stop-Process -Id $svP.Id -Force -EA 0
        exit 1
    }
    $rtspPath = $cam.path.TrimStart('/')

    Write-Host ""
    Write-Host "T1: viewer-auth-failed fires on bad credentials" -ForegroundColor Yellow
    # Spawn ffmpeg with WRONG password. Quietly. The connection will fail at
    # the auth stage and the supervisor's mediamtx scraper should see the
    # `closed: authentication failed` log line and emit the IPC event.
    $rtspBadUrl = "rtsp://viewer:WRONGPASSWORD@127.0.0.1:8554/$rtspPath"
    $readerErr  = Join-Path $env:TEMP 'sup.authfail.reader.err.log'
    Set-Content -Path $readerErr -Value '' -Force
    $readerP = Start-Process -FilePath $ffmpegExe -ArgumentList @(
        '-loglevel','quiet','-rtsp_transport','tcp','-i',$rtspBadUrl,
        '-t','1','-f','null','NUL'
    ) -PassThru -WindowStyle Hidden -RedirectStandardError $readerErr
    Write-Host "  reader pid=$($readerP.Id) (intentional bad creds)" -ForegroundColor DarkGray

    $authFail = Wait-EventName $ipc -Name 'viewer-auth-failed' -TimeoutMs 15000
    if ($authFail) {
        $d = $authFail.data
        $haveIp     = $null -ne $d.reader_ip -and $d.reader_ip -ne ''
        $haveReason = $null -ne $d.reason    -and $d.reason    -ne ''
        if ($haveIp -and $haveReason) {
            Write-Host "  PASS: viewer-auth-failed carries reader_ip='$($d.reader_ip)' reason='$($d.reason)'" -ForegroundColor Green
        } else {
            Write-Host "FAIL: viewer-auth-failed missing fields: $($authFail | ConvertTo-Json -Compress -Depth 4)" -ForegroundColor Red
            $verdict = $false
        }
    } else {
        Write-Host "FAIL: no viewer-auth-failed event in 15s" -ForegroundColor Red
        $verdict = $false
    }

    # Wait for ffmpeg to finish (it will, quickly -- auth failed).
    for ($i=0; $i -lt 30 -and -not $readerP.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
    if (-not $readerP.HasExited) { Stop-Process -Id $readerP.Id -Force -EA 0 }

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
