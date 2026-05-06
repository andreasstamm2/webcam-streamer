# Tiny named-pipe client for the supervisor's IPC.
#
# Usage:
#   .\ipc-client.ps1 -Method list-cameras
#   .\ipc-client.ps1 -Method get-status
#   .\ipc-client.ps1 -Method restart-camera -ParamsJson '{"name":"HP 5MP Camera"}'
#   .\ipc-client.ps1 -ListenSec 5         # connect and listen for events

[CmdletBinding()]
param(
    [string]$Method,
    [string]$ParamsJson = '{}',
    [int]$Id = 1,
    [int]$ListenSec = 0,
    [string]$PipeName = 'webcam-streamer-supervisor',
    [int]$ConnectTimeoutMs = 3000
)

$ErrorActionPreference = 'Stop'

$client = New-Object System.IO.Pipes.NamedPipeClientStream(
    '.', $PipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::None)
$client.Connect($ConnectTimeoutMs)

$reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
$writer = New-Object System.IO.StreamWriter($client, [System.Text.Encoding]::UTF8)
$writer.NewLine = "`n"
$writer.AutoFlush = $true

function Send-Request {
    param([int]$Id, [string]$Method, [string]$ParamsJson)
    $obj = [ordered]@{
        type   = 'req'
        id     = $Id
        method = $Method
        params = (ConvertFrom-Json $ParamsJson)
    }
    $line = $obj | ConvertTo-Json -Compress -Depth 6
    Write-Host "-> $line" -ForegroundColor DarkCyan
    $writer.WriteLine($line)
}

function Read-OneMessage {
    param([int]$TimeoutMs = 5000)
    $task = $reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) { return $null }
    return $task.Result
}

if ($Method) {
    Send-Request -Id $Id -Method $Method -ParamsJson $ParamsJson
    $resp = Read-OneMessage 5000
    if ($null -eq $resp) {
        Write-Host "(timeout waiting for response)" -ForegroundColor Yellow
    } else {
        Write-Host "<- $resp" -ForegroundColor Green
        try {
            $obj = ConvertFrom-Json $resp
            if ($obj.type -eq 'resp') {
                Write-Host ("ok={0}" -f $obj.ok)
                if ($obj.ok -and $obj.result) {
                    Write-Host "result:"
                    ($obj.result | ConvertTo-Json -Depth 6) -split "`n" | ForEach-Object { Write-Host "  $_" }
                } elseif (-not $obj.ok) {
                    Write-Host "error: $($obj.error)" -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "(could not parse as json: $_)" -ForegroundColor Yellow
        }
    }
}

if ($ListenSec -gt 0) {
    Write-Host ""
    Write-Host "[listening for events for ${ListenSec}s ...]" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($ListenSec)
    while ((Get-Date) -lt $deadline) {
        $msg = Read-OneMessage 500
        if ($msg) {
            Write-Host "<- $msg" -ForegroundColor Magenta
        }
    }
}

$client.Dispose()
