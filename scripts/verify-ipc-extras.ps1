# Test the step-6 IPC additions: set-mode, list-advertised-formats, probe-camera, cameras-changed event.
#
# Skips the (slow ~35s) probe-camera test by default; pass -SkipProbe:$false to include it.

[CmdletBinding()]
param(
    [int]$BootSec = 5,
    [bool]$SkipProbe = $true
)

$ErrorActionPreference = 'Stop'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built" }

@(Get-Process -Name 'supervisor','mediamtx','ffmpeg' -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1

$out = Join-Path $env:TEMP 'sup.extras.out.log'
Write-Host "[verify-extras] launching supervisor..." -ForegroundColor Cyan
$svP = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $out -RedirectStandardError (Join-Path $env:TEMP 'sup.extras.err.log')
Start-Sleep -Seconds $BootSec

$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'webcam-streamer-supervisor',
    [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::None)
$client.Connect(3000)
$reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
$writer = New-Object System.IO.StreamWriter($client, [System.Text.Encoding]::UTF8)
$writer.NewLine = "`n"; $writer.AutoFlush = $true

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
    param([int]$Id, [int]$TimeoutMs = 5000, [scriptblock]$OnEvent = $null)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $rem = [int][math]::Max(50, ($deadline - (Get-Date)).TotalMilliseconds)
        $msg = Read-Next -TimeoutMs $rem; if (-not $msg) { continue }
        $o = $msg.obj
        if ($o.type -eq 'resp' -and $o.id -eq $Id) {
            Write-Host "<- $($msg.raw)" -ForegroundColor Green
            return $o
        } elseif ($o.type -eq 'event') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
            if ($OnEvent) { & $OnEvent $o }
        }
    }
    return $null
}
function Invoke-Ipc {
    param([int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = 5000, [scriptblock]$OnEvent = $null)
    $line = (@{ type='req'; id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Compress -Depth 6)
    Write-Host "-> $line" -ForegroundColor DarkCyan
    $writer.WriteLine($line)
    return Wait-Response -Id $Id -TimeoutMs $TimeoutMs -OnEvent $OnEvent
}

$verdict = $true

# Discover a cam name
$r1 = Invoke-Ipc -Id 1 -Method 'list-cameras'
if (-not ($r1.ok -and $r1.result.Count -ge 1)) {
    Write-Host "FAIL: no cameras to test against" -ForegroundColor Red
    $client.Dispose(); Stop-Process -Id $svP.Id -Force -EA 0; exit 1
}
$cam = $r1.result[0].name
$origMode = $r1.result[0].mode
Write-Host "Test camera: '$cam' (current mode=$origMode)" -ForegroundColor Cyan

# 1. list-advertised-formats
Write-Host ""
Write-Host "TEST list-advertised-formats" -ForegroundColor Yellow
$r2 = Invoke-Ipc -Id 2 -Method 'list-advertised-formats' -Params @{name=$cam}
if (-not ($r2.ok -and $r2.result.Count -ge 1)) {
    Write-Host "FAIL: no advertised formats returned" -ForegroundColor Red; $verdict = $false
} else {
    $kinds = ($r2.result | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Host "  PASS: $($r2.result.Count) formats ($kinds)" -ForegroundColor Green
}

# 2. set-mode (round-trip: set to a different mode, verify, restore original)
Write-Host ""
Write-Host "TEST set-mode" -ForegroundColor Yellow
$alt = if ($origMode -eq 'transcode_mjpeg_to_h264') { 'passthrough_mjpeg' } else { 'transcode_mjpeg_to_h264' }
$r3 = Invoke-Ipc -Id 3 -Method 'set-mode' -Params @{name=$cam; mode=$alt}
if (-not ($r3.ok -and $r3.result.mode -eq $alt)) {
    Write-Host "FAIL: set-mode to '$alt' rejected: $($r3.error)" -ForegroundColor Red; $verdict = $false
}

# Verify override file was written
$slug = ($cam -replace '[^a-zA-Z0-9]+', '-').TrimEnd('-')
$overridePath = Join-Path $root "probes\$slug.override.txt"
if (Test-Path $overridePath) {
    $contents = Get-Content $overridePath -Raw
    if ($contents -match "mode=$alt") {
        Write-Host "  PASS: override file written: $overridePath" -ForegroundColor Green
    } else {
        Write-Host "FAIL: override file content unexpected: $contents" -ForegroundColor Red; $verdict = $false
    }
} else {
    Write-Host "FAIL: override file not created: $overridePath" -ForegroundColor Red; $verdict = $false
}

# Verify list-cameras shows the new mode
$r4 = Invoke-Ipc -Id 4 -Method 'list-cameras'
$row = $r4.result | Where-Object { $_.name -eq $cam }
if ($row.mode -eq $alt) {
    Write-Host "  PASS: list-cameras now reports mode=$alt" -ForegroundColor Green
} else {
    Write-Host "FAIL: list-cameras still reports mode=$($row.mode), expected $alt" -ForegroundColor Red; $verdict = $false
}

# Restore original mode + clean up override file
Invoke-Ipc -Id 5 -Method 'set-mode' -Params @{name=$cam; mode=$origMode} | Out-Null
Remove-Item $overridePath -Force -EA 0

# 3. probe-camera (optional - slow)
if (-not $SkipProbe) {
    Write-Host ""
    Write-Host "TEST probe-camera (~35s)" -ForegroundColor Yellow
    $script:gotProbeCompleted = $false
    Invoke-Ipc -Id 6 -Method 'probe-camera' -Params @{name=$cam} -TimeoutMs 5000 -OnEvent { } | Out-Null
    # Now wait up to 90s for probe-completed event
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $script:gotProbeCompleted -and (Get-Date) -lt $deadline) {
        $msg = Read-Next 1000
        if ($msg -and $msg.obj.type -eq 'event' -and $msg.obj.name -eq 'probe-completed') {
            Write-Host "<- $($msg.raw)" -ForegroundColor Magenta
            $script:gotProbeCompleted = $true
        } elseif ($msg) {
            Write-Host "<- $($msg.raw)" -ForegroundColor DarkGray
        }
    }
    if ($script:gotProbeCompleted) { Write-Host "  PASS: probe-completed event received" -ForegroundColor Green }
    else { Write-Host "FAIL: probe-completed not received in 90s" -ForegroundColor Red; $verdict = $false }
}

# Cleanup
Invoke-Ipc -Id 99 -Method 'shutdown' | Out-Null
$client.Dispose()
for ($i=0; $i -lt 30 -and -not $svP.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
if (-not $svP.HasExited) { Stop-Process -Id $svP.Id -Force -EA 0 }

Write-Host ""
if ($verdict) { Write-Host "OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
