# Probe a single camera for:
#   1. Advertised input formats (codec, resolution, fps) from `ffmpeg -list_options`
#   2. End-to-end viability of the 5 meaningful pipelines (publish -> pull, count frames)
# Emits a JSON report on stdout. Exits 0 if probe ran, non-zero on internal error.
# Individual pipeline failures are reported in the JSON, not via exit code.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CameraName,
    [int]$TestWidth  = 1280,
    [int]$TestHeight = 720,
    [int]$TestFps    = 30,
    [int]$PublishSettleSec = 3,
    [int]$PullSec    = 3,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$ff        = Join-Path $root 'third_party\ffmpeg\ffmpeg.exe'
$mtxExe    = Join-Path $root 'third_party\mediamtx\mediamtx.exe'
$mtxYml    = Join-Path $root 'config\mediamtx.yml'

$rtspPub  = 'rtsp://publisher:publisher@127.0.0.1:8554/probe'
$rtspView = 'rtsp://viewer:viewer@127.0.0.1:8554/probe'

# ----- 1. enumerate advertised formats ----------------------------------------
function Get-AdvertisedFormats {
    param([string]$Cam)
    $raw = & $ff -hide_banner -f dshow -list_options true -i "video=$Cam" 2>&1
    $entries = @()
    foreach ($line in $raw) {
        # vcodec=mjpeg  min s=1280x720 fps=5 max s=1280x720 fps=30
        if ($line -match 'vcodec=(\S+)\s+min s=(\d+)x(\d+) fps=([\d\.]+) max s=(\d+)x(\d+) fps=([\d\.]+)') {
            $entries += [pscustomobject]@{
                kind      = 'compressed'
                codec     = $Matches[1]
                width     = [int]$Matches[2]; height    = [int]$Matches[3]
                min_fps   = [double]$Matches[4]; max_fps = [double]$Matches[7]
            }
        }
        # pixel_format=yuyv422 min s=1280x720 fps=5 max s=1280x720 fps=30
        elseif ($line -match 'pixel_format=(\S+)\s+min s=(\d+)x(\d+) fps=([\d\.]+) max s=(\d+)x(\d+) fps=([\d\.]+)') {
            $entries += [pscustomobject]@{
                kind      = 'raw'
                pix_fmt   = $Matches[1]
                width     = [int]$Matches[2]; height    = [int]$Matches[3]
                min_fps   = [double]$Matches[4]; max_fps = [double]$Matches[7]
            }
        }
    }
    return $entries | Sort-Object @{e={$_.kind}}, @{e={$_.codec}}, @{e={$_.pix_fmt}}, @{e={$_.width}}, @{e={$_.height}} -Unique
}

# ----- 2. run a single pipeline test ------------------------------------------
function Test-Pipeline {
    param(
        [string]$Label,
        # ffmpeg input args before the cam (e.g. -vcodec mjpeg, or -pixel_format yuyv422)
        [string[]]$InputCodecArgs,
        # ffmpeg output args (e.g. -c:v copy, or -c:v libx264 ...)
        [string[]]$EncodeArgs,
        # what the receiver should see; informational only
        [string]$ExpectedCodec
    )

    $mtxOut = Join-Path $env:TEMP "probe-mtx.out.log"
    $mtxErr = Join-Path $env:TEMP "probe-mtx.err.log"
    $mtxP = Start-Process -FilePath $mtxExe -ArgumentList @($mtxYml) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $mtxOut -RedirectStandardError $mtxErr
    Start-Sleep 1

    $pubArgs = @('-hide_banner','-loglevel','warning') + $InputCodecArgs + @(
        '-video_size', "${TestWidth}x${TestHeight}",
        '-framerate', "$TestFps",
        '-i', "`"video=$CameraName`""
    ) + $EncodeArgs + @('-an','-f','rtsp','-rtsp_transport','tcp', $rtspPub)

    $pubErr = Join-Path $env:TEMP "probe-pub.err.log"
    $pubP = Start-Process -FilePath $ff -ArgumentList $pubArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $env:TEMP "probe-pub.out.log") `
        -RedirectStandardError $pubErr
    Start-Sleep $PublishSettleSec

    $pubErrTail = if (Test-Path $pubErr) { ((Get-Content $pubErr) | Select-Object -Last 4) -join "`n" } else { '' }

    if ($pubP.HasExited) {
        Stop-Process -Id $mtxP.Id -Force -EA 0
        return [pscustomobject]@{
            label    = $Label
            ok       = $false
            stage    = 'publish'
            reason   = ($pubErrTail -split "`r?`n" | Select-Object -Last 2) -join ' | '
            frames   = 0
            expected = $ExpectedCodec
        }
    }

    $pullPrg = Join-Path $env:TEMP "probe-pull.progress.log"
    $pullErr = Join-Path $env:TEMP "probe-pull.err.log"
    if (Test-Path $pullPrg) { Remove-Item $pullPrg -Force }

    $pullArgs = @('-hide_banner','-loglevel','warning','-rtsp_transport','tcp',
        '-i', $rtspView, '-t', "$PullSec", '-an', '-f','null','-',
        '-progress', $pullPrg)
    $pullP = Start-Process -FilePath $ff -ArgumentList $pullArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $env:TEMP "probe-pull.out.log") `
        -RedirectStandardError $pullErr
    $pullP.WaitForExit()
    $pullExit = $pullP.ExitCode

    $frames = 0
    if (Test-Path $pullPrg) {
        foreach ($line in Get-Content $pullPrg) {
            if ($line -match '^frame=(\d+)\s*$') { $frames = [int]$Matches[1] }
        }
    }

    if (-not $pubP.HasExited) { Stop-Process -Id $pubP.Id -Force -EA 0 }
    Stop-Process -Id $mtxP.Id -Force -EA 0
    Start-Sleep 1

    $ok = ($pullExit -eq 0 -and $frames -ge 1)
    if ($ok) {
        return [pscustomobject]@{
            label    = $Label; ok = $true; stage = 'ok'; reason = ''
            frames   = $frames
            obs_fps  = [math]::Round($frames / $PullSec, 1)
            expected = $ExpectedCodec
        }
    } else {
        $reason = if ($pullExit -ne 0) { 'pull_failed' } else { 'no_frames' }
        $tail = if (Test-Path $pullErr) { (Get-Content $pullErr | Select-Object -Last 2) -join ' | ' } else { '' }
        return [pscustomobject]@{
            label = $Label; ok = $false; stage = 'pull'; reason = "${reason}: $tail"
            frames = $frames; expected = $ExpectedCodec
        }
    }
}

# ----- 3. orchestrate ---------------------------------------------------------
$advertised = Get-AdvertisedFormats -Cam $CameraName
$camAdvertisesMjpeg = ($advertised | Where-Object { $_.kind -eq 'compressed' -and $_.codec -eq 'mjpeg' }).Count -gt 0
$camAdvertisesH264  = ($advertised | Where-Object { $_.kind -eq 'compressed' -and $_.codec -eq 'h264' }).Count  -gt 0
$camAdvertisesRaw   = ($advertised | Where-Object { $_.kind -eq 'raw' }).Count -gt 0

$pipelines = @()

# 1. Passthrough · MJPEG
if ($camAdvertisesMjpeg) {
    $pipelines += Test-Pipeline -Label 'passthrough_mjpeg' `
        -InputCodecArgs @('-f','dshow','-vcodec','mjpeg') `
        -EncodeArgs     @('-c:v','copy') `
        -ExpectedCodec  'mjpeg'
} else {
    $pipelines += [pscustomobject]@{ label='passthrough_mjpeg'; ok=$false; stage='not_applicable'; reason='cam does not advertise MJPEG'; frames=0; expected='mjpeg' }
}

# 2. Passthrough · H.264
if ($camAdvertisesH264) {
    $pipelines += Test-Pipeline -Label 'passthrough_h264' `
        -InputCodecArgs @('-f','dshow','-vcodec','h264') `
        -EncodeArgs     @('-c:v','copy') `
        -ExpectedCodec  'h264'
} else {
    $pipelines += [pscustomobject]@{ label='passthrough_h264'; ok=$false; stage='not_applicable'; reason='cam does not advertise H.264 (UVC 1.5 extension)'; frames=0; expected='h264' }
}

# 3. Transcode · RAW -> MJPEG
if ($camAdvertisesRaw) {
    $pipelines += Test-Pipeline -Label 'transcode_raw_to_mjpeg' `
        -InputCodecArgs @('-f','dshow','-pixel_format','yuyv422') `
        -EncodeArgs     @('-c:v','mjpeg','-q:v','4','-pix_fmt','yuvj422p') `
        -ExpectedCodec  'mjpeg'
} else {
    $pipelines += [pscustomobject]@{ label='transcode_raw_to_mjpeg'; ok=$false; stage='not_applicable'; reason='cam does not advertise raw (yuyv422/nv12)'; frames=0; expected='mjpeg' }
}

# 4. Transcode · RAW -> H.264
if ($camAdvertisesRaw) {
    $pipelines += Test-Pipeline -Label 'transcode_raw_to_h264' `
        -InputCodecArgs @('-f','dshow','-pixel_format','yuyv422') `
        -EncodeArgs     @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-pix_fmt','yuv420p','-g','60','-bf','0') `
        -ExpectedCodec  'h264'
} else {
    $pipelines += [pscustomobject]@{ label='transcode_raw_to_h264'; ok=$false; stage='not_applicable'; reason='cam does not advertise raw (yuyv422/nv12)'; frames=0; expected='h264' }
}

# 5. Transcode · MJPEG -> H.264
if ($camAdvertisesMjpeg) {
    $pipelines += Test-Pipeline -Label 'transcode_mjpeg_to_h264' `
        -InputCodecArgs @('-f','dshow','-vcodec','mjpeg') `
        -EncodeArgs     @('-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-pix_fmt','yuv420p','-g','60','-bf','0') `
        -ExpectedCodec  'h264'
} else {
    $pipelines += [pscustomobject]@{ label='transcode_mjpeg_to_h264'; ok=$false; stage='not_applicable'; reason='cam does not advertise MJPEG'; frames=0; expected='h264' }
}

# Pick a recommended mode in priority order.
#   1. passthrough_mjpeg    — lowest CPU, best quality, smallest interop surface (when it works)
#   2. passthrough_h264     — same but H.264 output (rare hardware)
#   3. transcode_mjpeg_to_h264 — universal fallback, low USB load
#   4. transcode_raw_to_h264   — quality-first fallback
#   5. transcode_raw_to_mjpeg  — currently broken in ffmpeg; effectively never picked
$priority = @('passthrough_mjpeg','passthrough_h264','transcode_mjpeg_to_h264','transcode_raw_to_h264','transcode_raw_to_mjpeg')
$recommended = 'none'
foreach ($mode in $priority) {
    $row = $pipelines | Where-Object { $_.label -eq $mode }
    if ($row -and $row.ok) { $recommended = $mode; break }
}

$report = [pscustomobject]@{
    schema_version = 1
    timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
    camera         = $CameraName
    test_resolution = "${TestWidth}x${TestHeight}@${TestFps}"
    recommended    = $recommended
    advertised_formats = $advertised
    pipelines       = $pipelines
}
$json = $report | ConvertTo-Json -Depth 6

if ($ReportPath) {
    Set-Content -LiteralPath $ReportPath -Value $json -Encoding UTF8

    # Plain-text summary the C++ supervisor can read without a JSON parser.
    $summaryPath = [System.IO.Path]::ChangeExtension($ReportPath, '.summary.txt')
    $lines = @("recommended=$recommended", "camera=$CameraName", "test_resolution=${TestWidth}x${TestHeight}@${TestFps}")
    foreach ($p in $pipelines) {
        $state = if ($p.ok) { 'ok' } elseif ($p.stage -eq 'not_applicable') { 'na' } else { 'fail' }
        $lines += "$($p.label)=$state"
    }
    Set-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8
}
Write-Output $json
