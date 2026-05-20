<#
.SYNOPSIS
    Ensure a specific Inno Setup version is installed under <repo>/tools.

.DESCRIPTION
    Downloads the official Inno Setup installer from the upstream's
    GitHub Releases and runs it silently into a versioned subdirectory
    of <repo>/tools/inno-setup-<version>. Idempotent: skips the download
    if ISCC.exe is already present at that path.

    Both the local installer-build script and the CI release workflow
    use this so the two paths are guaranteed to invoke the same Inno
    Setup binary. v0.3.0 .. v0.3.5 all failed because the
    Chocolatey-distributed Inno Setup on the GitHub Actions runner was
    significantly older than the locally-installed one and its Pascal
    Script engine rejected modern symbols (const-in-function,
    Randomize, GetTickCount). Centralising the install removes that
    drift class.

    Allows an INNO_SETUP_EXE env var override for developers who want
    to point at a hand-installed Inno Setup elsewhere on their box.

.PARAMETER Version
    Inno Setup release to install (e.g. "6.7.2"). The URL pattern on
    jrsoftware's GitHub Releases uses underscores in the tag and dots
    in the filename: is-X_Y_Z / innosetup-X.Y.Z.exe.

.PARAMETER Quiet
    Suppress informational output. Used by check-build-env.ps1 when
    it just wants the path.

.OUTPUTS
    The full path to ISCC.exe. Also sets:
      - $env:ISCC_PATH        for the rest of the local build session
      - $env:GITHUB_ENV       ISCC_PATH=...  when running in CI
#>
[CmdletBinding()]
param(
    [string]$Version = '6.7.2',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$Msg) if (-not $Quiet) { Write-Host $Msg -ForegroundColor Cyan } }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

# Env override for developers with a hand-installed Inno Setup. Honour
# it even if the version doesn't match our pin -- it's an explicit
# opt-out.
if ($env:INNO_SETUP_EXE -and (Test-Path $env:INNO_SETUP_EXE)) {
    Write-Info "Using INNO_SETUP_EXE override: $env:INNO_SETUP_EXE"
    $env:ISCC_PATH = $env:INNO_SETUP_EXE
    if ($env:GITHUB_ENV) { "ISCC_PATH=$env:INNO_SETUP_EXE" | Out-File -FilePath $env:GITHUB_ENV -Append }
    return $env:INNO_SETUP_EXE
}

$tagUnderscored = $Version -replace '\.', '_'
$url            = "https://github.com/jrsoftware/issrc/releases/download/is-$tagUnderscored/innosetup-$Version.exe"
$toolsDir       = Join-Path $repoRoot 'tools'
$innoDir        = Join-Path $toolsDir "inno-setup-$Version"
$iscc           = Join-Path $innoDir 'ISCC.exe'

if (Test-Path $iscc) {
    Write-Info "Inno Setup $Version already installed at $innoDir"
} else {
    Write-Info "Installing Inno Setup $Version -> $innoDir"
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $installerExe = Join-Path $toolsDir "innosetup-$Version-installer.exe"
    Write-Info "  downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $installerExe -UseBasicParsing
    # Silent install flags (https://jrsoftware.org/ishelp/index.php?topic=setupcmdline):
    #   /VERYSILENT       no UI
    #   /SUPPRESSMSGBOXES skip leftover dialogs
    #   /SP-              don't show the "this will install..." prompt
    #   /NORESTART        never reboot
    #   /DIR=...          install location (avoids polluting Program Files)
    $p = Start-Process -FilePath $installerExe `
        -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/SP-','/NORESTART',"/DIR=$innoDir" `
        -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Inno Setup installer exited with code $($p.ExitCode)" }
    Remove-Item $installerExe -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $iscc)) {
        throw "ISCC.exe not found at $iscc after install"
    }
}

$env:ISCC_PATH = $iscc
if ($env:GITHUB_ENV) {
    "ISCC_PATH=$iscc" | Out-File -FilePath $env:GITHUB_ENV -Append
}
Write-Info "ISCC: $iscc"
return $iscc
