# End-to-end verify of the supervisor's IPC.
#
# Architecture:
#   Single-task message pump. Always waits on the in-flight ReadLineAsync
#   before starting a new one (StreamReader does not allow overlapping reads).
#   Classifies each line as resp/event; routes responses by id, prints events.

[CmdletBinding()]
param([int]$BootSec = 5)

$ErrorActionPreference = 'Stop'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built" }

# 0. cleanup
@(Get-Process -Name 'supervisor','mediamtx','ffmpeg' -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1

$out = Join-Path $env:TEMP 'supervisor.ipc.out.log'
Write-Host "[verify-ipc] launching supervisor..." -ForegroundColor Cyan
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $out `
    -RedirectStandardError  (Join-Path $env:TEMP 'supervisor.ipc.err.log')
Start-Sleep -Seconds $BootSec
if ($svP.HasExited) {
    Write-Host "supervisor exited early. tail:" -ForegroundColor Red
    Get-Content $out -EA 0 | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
    exit 1
}

# Connect
$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'webcam-streamer-supervisor',
    [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
$client.Connect(3000)
$reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
$writer = New-Object System.IO.StreamWriter($client, [System.Text.Encoding]::UTF8)
$writer.NewLine = "`n"; $writer.AutoFlush = $true

# Single in-flight read task. Read-Next() returns the next message (parsed) or
# $null on timeout, while keeping the pump invariant intact.
$script:pendingTask = $null

function Read-Next {
    param([int]$TimeoutMs = 1000)
    if (-not $script:pendingTask) {
        $script:pendingTask = $reader.ReadLineAsync()
    }
    if (-not $script:pendingTask.Wait($TimeoutMs)) { return $null }
    $line = $script:pendingTask.Result
    $script:pendingTask = $null
    if ($null -eq $line) { return $null }   # stream EOF
    return @{ raw = $line; obj = ($line | ConvertFrom-Json) }
}

# Wait for a response with a matching id. Print events as they arrive. Returns
# the response object or $null on overall timeout. `OnEvent` is called for any
# events seen in the wait window.
function Wait-Response {
    param([int]$Id, [int]$TimeoutMs = 5000, [scriptblock]$OnEvent = $null)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $remaining = [int]([math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds))
        $msg = Read-Next -TimeoutMs $remaining
        if ($null -eq $msg) { continue }
        $o = $msg.obj
        if ($o.type -eq 'resp' -and $o.id -eq $Id) {
            Write-Host "<- $($msg.raw)" -ForegroundColor Green
            return $o
        } elseif ($o.type -eq 'event') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
            if ($OnEvent) { & $OnEvent $o }
        } else {
            Write-Host "<- (unexpected) $($msg.raw)" -ForegroundColor DarkYellow
        }
    }
    return $null
}

function Invoke-Ipc {
    param([int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = 5000, [scriptblock]$OnEvent = $null)
    $req = [ordered]@{ type='req'; id=$Id; method=$Method; params=$Params }
    $line = $req | ConvertTo-Json -Compress -Depth 6
    Write-Host "-> $line" -ForegroundColor DarkCyan
    $writer.WriteLine($line)
    return Wait-Response -Id $Id -TimeoutMs $TimeoutMs -OnEvent $OnEvent
}

$verdict = $true

# 1. list-cameras
$r1 = Invoke-Ipc -Id 1 -Method 'list-cameras'
if (-not ($r1 -and $r1.ok -and $r1.result.Count -ge 1)) {
    Write-Host "FAIL: list-cameras returned no cameras" -ForegroundColor Red; $verdict = $false
} else {
    Write-Host "  list-cameras: $(($r1.result | ForEach-Object { $_.name + '@' + $_.path }) -join ', ')"
}

# 2. get-status
$r2 = Invoke-Ipc -Id 2 -Method 'get-status'
if (-not ($r2 -and $r2.ok -and $r2.result.mediamtx.running)) {
    Write-Host "FAIL: get-status reports mediamtx not running" -ForegroundColor Red; $verdict = $false
}

# 3. restart-camera + check we receive the camera-state-changed event
if ($r1 -and $r1.result -and $r1.result.Count -ge 1) {
    $cam = $r1.result[0].name
    Write-Host ""
    Write-Host "Restarting camera '$cam'..." -ForegroundColor Cyan
    $script:gotEvent = $false
    $r3 = Invoke-Ipc -Id 3 -Method 'restart-camera' -Params @{name=$cam} -OnEvent {
        param($ev)
        if ($ev.name -eq 'camera-state-changed') { $script:gotEvent = $true }
    }
    if (-not ($r3 -and $r3.ok)) {
        Write-Host "FAIL: restart-camera returned error: $($r3.error)" -ForegroundColor Red; $verdict = $false
    }
    if ($script:gotEvent) {
        Write-Host "  PASS: received camera-state-changed event during restart" -ForegroundColor Green
    } else {
        Write-Host "  FAIL: no camera-state-changed event arrived" -ForegroundColor Red
        $verdict = $false
    }
}

# 4. shutdown via IPC
Write-Host ""
Write-Host "Asking supervisor to shut down via IPC..." -ForegroundColor Cyan
$r4 = Invoke-Ipc -Id 99 -Method 'shutdown'
if (-not ($r4 -and $r4.ok)) {
    Write-Host "FAIL: shutdown response not ok" -ForegroundColor Red; $verdict = $false
}
$client.Dispose()

# 5. wait for supervisor exit
$gone = $false
for ($i = 0; $i -lt 50; $i++) {
    if ($svP.HasExited) { $gone = $true; break }
    Start-Sleep -Milliseconds 200
}
if (-not $gone) {
    Write-Host "FAIL: supervisor did not exit after 'shutdown' method" -ForegroundColor Red
    Stop-Process -Id $svP.Id -Force -EA 0
    $verdict = $false
} else {
    Write-Host "  PASS: supervisor exited cleanly via IPC shutdown" -ForegroundColor Green
}

# 6. confirm children died
Start-Sleep 1
$mtx = @(Get-Process -Name 'mediamtx' -EA 0)
$fff = @(Get-Process -Name 'ffmpeg' -EA 0)
if ($mtx.Count -gt 0) { Write-Host "FAIL: mediamtx survived" -ForegroundColor Red; $verdict = $false }
else                   { Write-Host "  PASS: mediamtx died" -ForegroundColor Green }
if ($fff.Count -gt 0) { Write-Host "FAIL: ffmpeg survived" -ForegroundColor Red; $verdict = $false }
else                   { Write-Host "  PASS: ffmpeg died" -ForegroundColor Green }

Write-Host ""
if ($verdict) { Write-Host "OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
