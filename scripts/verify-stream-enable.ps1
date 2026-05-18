# Verify Slice A: per-camera enabled flag, set-stream-enabled IPC method,
# settings.json reader + reload-settings IPC method.
#
# Contract under test:
#   1. list-cameras rows include `enabled` field, default true.
#   2. set-stream-enabled {name, enabled:false} stops the ffmpeg publisher,
#      persists enabled=false to <slug>.override.txt, fires camera-state-changed,
#      and reports running=false on the next list-cameras.
#   3. set-stream-enabled {name, enabled:true} restarts the publisher.
#   4. reload-settings is a recognized IPC method.
#   5. settings.json with default_enabled_for_new_cameras=false is honored at
#      startup: a camera that has no .override.txt comes up disabled.

[CmdletBinding()]
param(
    [int]$BootSec = 5
)

$ErrorActionPreference = 'Continue'
$root        = Split-Path -Parent $PSScriptRoot
$supervisor  = Join-Path $root 'supervisor\build\Release\supervisor.exe'
$settingsPath = Join-Path $root 'settings.json'
$probesDir    = Join-Path $root 'probes'
$overridePath = $null   # set inside phase 1 try; nullable so finally is safe
if (-not (Test-Path $supervisor)) { throw "supervisor.exe not built" }

# Kill stragglers (canonical project hygiene).
@(Get-Process -Name 'supervisor','mediamtx','ffmpeg' -EA 0) | Stop-Process -Force -EA 0
Start-Sleep 1

# Save and remove pre-existing settings.json so each test segment controls state.
$settingsBackup = $null
if (Test-Path $settingsPath) {
    $settingsBackup = Get-Content $settingsPath -Raw
    Remove-Item $settingsPath -Force
}

# Save and remove pre-existing per-cam override files. A prior failed run
# could have left enabled=false in one of them; we need a known clean
# initial state for phase 1. Restored at script exit.
$overrideBackups = @{}
if (Test-Path $probesDir) {
    Get-ChildItem -Path $probesDir -Filter '*.override.txt' -EA 0 | ForEach-Object {
        $overrideBackups[$_.FullName] = Get-Content $_.FullName -Raw
        Remove-Item $_.FullName -Force
    }
}

# IPC plumbing identical to verify-ipc-extras.ps1.
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
function Wait-Response {
    param($ipc, [int]$Id, [int]$TimeoutMs = 5000)
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
function Invoke-Ipc {
    param($ipc, [int]$Id, [string]$Method, $Params = @{}, [int]$TimeoutMs = 5000)
    $line = (@{ type='req'; id=$Id; method=$Method; params=$Params } | ConvertTo-Json -Compress -Depth 6)
    Write-Host "-> $line" -ForegroundColor DarkCyan
    $ipc.writer.WriteLine($line)
    return Wait-Response $ipc -Id $Id -TimeoutMs $TimeoutMs
}

function Start-Supervisor {
    param([string]$Tag)
    $out = Join-Path $env:TEMP "sup.$Tag.out.log"
    $err = Join-Path $env:TEMP "sup.$Tag.err.log"
    Write-Host "[verify-stream-enable] launching supervisor ($Tag)..." -ForegroundColor Cyan
    $p = Start-Process -FilePath $supervisor -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    Start-Sleep -Seconds $BootSec
    return $p
}

function Stop-Supervisor {
    param($ipc, $proc)
    if ($ipc) {
        Invoke-Ipc $ipc -Id 9999 -Method 'shutdown' | Out-Null
        $ipc.client.Dispose()
    }
    for ($i=0; $i -lt 30 -and -not $proc.HasExited; $i++) { Start-Sleep -Milliseconds 200 }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -EA 0 }
}

$verdict = $true

# ============================================================================
# PHASE 1: enabled field default + set-stream-enabled round-trip
# Pre-condition: no settings.json (so default_enabled_for_new_cameras
# is treated as true).
# ============================================================================
$svP = Start-Supervisor -Tag 'enable1'
try {
    $ipc = Connect-Ipc

    # ---- T1: list-cameras row has `enabled` field, defaulting to true ----
    Write-Host ""
    Write-Host "T1: list-cameras includes enabled=true by default" -ForegroundColor Yellow
    $r1 = Invoke-Ipc $ipc -Id 1 -Method 'list-cameras'
    if (-not ($r1.ok -and $r1.result.Count -ge 1)) {
        Write-Host "FAIL: no cameras to test" -ForegroundColor Red
        Stop-Supervisor $ipc $svP; exit 1
    }
    $cam = $r1.result[0].name
    $slug = ($cam -replace '[^a-zA-Z0-9]+', '-').TrimEnd('-')
    $overridePath = Join-Path $probesDir "$slug.override.txt"
    $hasEnabled = $r1.result[0].PSObject.Properties.Name -contains 'enabled'
    if (-not $hasEnabled) {
        Write-Host "FAIL: list-cameras row has no 'enabled' field" -ForegroundColor Red
        $verdict = $false
    } elseif ($r1.result[0].enabled -ne $true) {
        Write-Host "FAIL: enabled default is $($r1.result[0].enabled), expected true" -ForegroundColor Red
        $verdict = $false
    } else {
        Write-Host "  PASS: cam '$cam' enabled=true by default" -ForegroundColor Green
    }

    # ---- T2: set-stream-enabled false stops the publisher ----
    Write-Host ""
    Write-Host "T2: set-stream-enabled {enabled:false} stops the ffmpeg publisher" -ForegroundColor Yellow
    $script:capturedEvents.Clear()
    $r2 = Invoke-Ipc $ipc -Id 2 -Method 'set-stream-enabled' `
              -Params @{name=$cam; enabled=$false}
    if (-not ($r2.ok -and $r2.result.enabled -eq $false)) {
        Write-Host "FAIL: set-stream-enabled rejected or wrong echo: $($r2.error)" -ForegroundColor Red
        $verdict = $false
    }

    $stateChanged = $script:capturedEvents | Where-Object {
        $_.name -eq 'camera-state-changed' -and $_.data.name -eq $cam -and $_.data.enabled -eq $false
    }
    if ($stateChanged) {
        Write-Host "  PASS: camera-state-changed event fired with enabled=false" -ForegroundColor Green
    } else {
        Write-Host "FAIL: no camera-state-changed event with enabled=false" -ForegroundColor Red
        $verdict = $false
    }

    # Override file should now contain enabled=false.
    if (Test-Path $overridePath) {
        $contents = Get-Content $overridePath -Raw
        if ($contents -match 'enabled=false') {
            Write-Host "  PASS: override file persists enabled=false" -ForegroundColor Green
        } else {
            Write-Host "FAIL: override file lacks enabled=false: $contents" -ForegroundColor Red
            $verdict = $false
        }
    } else {
        Write-Host "FAIL: override file not created at $overridePath" -ForegroundColor Red
        $verdict = $false
    }

    # list-cameras should reflect new state.
    Start-Sleep -Seconds 2
    $r3 = Invoke-Ipc $ipc -Id 3 -Method 'list-cameras'
    $row = $r3.result | Where-Object { $_.name -eq $cam }
    if ($row.enabled -eq $false -and $row.running -eq $false) {
        Write-Host "  PASS: list-cameras shows enabled=false running=false" -ForegroundColor Green
    } else {
        Write-Host "FAIL: list-cameras shows enabled=$($row.enabled) running=$($row.running), expected both false" -ForegroundColor Red
        $verdict = $false
    }

    # ---- T3: set-stream-enabled true brings it back ----
    Write-Host ""
    Write-Host "T3: set-stream-enabled {enabled:true} restarts the publisher" -ForegroundColor Yellow
    $r4 = Invoke-Ipc $ipc -Id 4 -Method 'set-stream-enabled' `
              -Params @{name=$cam; enabled=$true}
    if (-not ($r4.ok -and $r4.result.enabled -eq $true)) {
        Write-Host "FAIL: re-enable rejected: $($r4.error)" -ForegroundColor Red
        $verdict = $false
    }
    Start-Sleep -Seconds 3
    $r5 = Invoke-Ipc $ipc -Id 5 -Method 'list-cameras'
    $row = $r5.result | Where-Object { $_.name -eq $cam }
    if ($row.enabled -eq $true -and $row.running -eq $true) {
        Write-Host "  PASS: cam re-enabled and running" -ForegroundColor Green
    } else {
        Write-Host "FAIL: after re-enable: enabled=$($row.enabled) running=$($row.running)" -ForegroundColor Red
        $verdict = $false
    }

    # ---- T4: reload-settings IPC method exists ----
    Write-Host ""
    Write-Host "T4: reload-settings is a recognized IPC method" -ForegroundColor Yellow
    $r6 = Invoke-Ipc $ipc -Id 6 -Method 'reload-settings'
    if ($r6.ok) {
        Write-Host "  PASS: reload-settings returned ok" -ForegroundColor Green
    } else {
        Write-Host "FAIL: reload-settings rejected: $($r6.error)" -ForegroundColor Red
        $verdict = $false
    }

    Stop-Supervisor $ipc $svP
} finally {
    if ($svP -and -not $svP.HasExited) { Stop-Process -Id $svP.Id -Force -EA 0 }
    # Remove the override file we created so phase 2 sees a clean slate.
    if ($overridePath) { Remove-Item $overridePath -Force -EA 0 }
}

# ============================================================================
# PHASE 2: settings.json default_enabled_for_new_cameras governs startup
# Pre-condition: settings.json has default_enabled_for_new_cameras=false;
# the target camera has no .override.txt (deleted above).
# ============================================================================
'{"notifications_enabled":true,"default_enabled_for_new_cameras":false}' |
    Set-Content -Path $settingsPath -NoNewline

$svP2 = Start-Supervisor -Tag 'enable2'
try {
    $ipc2 = Connect-Ipc
    Write-Host ""
    Write-Host "T5: settings.json default_enabled_for_new_cameras=false honored at startup" -ForegroundColor Yellow
    $r7 = Invoke-Ipc $ipc2 -Id 1 -Method 'list-cameras'
    $row = $r7.result | Where-Object { $_.name -eq $cam }
    if ($row.enabled -eq $false -and $row.running -eq $false) {
        Write-Host "  PASS: cam '$cam' came up disabled, no ffmpeg publisher" -ForegroundColor Green
    } else {
        Write-Host "FAIL: cam came up enabled=$($row.enabled) running=$($row.running), expected both false" -ForegroundColor Red
        $verdict = $false
    }
    Stop-Supervisor $ipc2 $svP2
} finally {
    if ($svP2 -and -not $svP2.HasExited) { Stop-Process -Id $svP2.Id -Force -EA 0 }
}

# ---- Cleanup ----
Remove-Item $settingsPath -Force -EA 0
if ($overridePath) { Remove-Item $overridePath -Force -EA 0 }
if ($settingsBackup) { Set-Content -Path $settingsPath -Value $settingsBackup -NoNewline }
foreach ($kv in $overrideBackups.GetEnumerator()) {
    Set-Content -Path $kv.Key -Value $kv.Value -NoNewline
}

Write-Host ""
if ($verdict) { Write-Host "OVERALL: PASS" -ForegroundColor Green; exit 0 }
else          { Write-Host "OVERALL: FAIL" -ForegroundColor Red;   exit 1 }
