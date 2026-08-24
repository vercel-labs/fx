#!/usr/bin/env pwsh
# fx installer for Windows
#
# Usage:
#   iwr -useb https://fx.sh/setup.ps1 | iex
#   .\setup.ps1 -Version v0.3.0
#   .\setup.ps1 -InstallDir C:\Tools\fx -Verbose
#   .\setup.ps1 -WhatIf
#
# Mirrors the upstream Unix installer at https://fx.sh/setup.sh.
# Differences: ZIP archive (PowerShell Expand-Archive has no external
# dependencies), SHA-256 verification (Unix flow does not verify), and
# persistent user PATH via SetEnvironmentVariable instead of shell rc files.

<#
.SYNOPSIS
    Downloads and installs fx from the Vercel CDN onto Windows.

.DESCRIPTION
    Mirrors the upstream Unix installer at https://fx.sh/setup.sh. Detects the
    latest stable version from the CDN, downloads fx-windows-x86_64.zip,
    verifies its SHA-256 against the sidecar checksum, extracts fx.exe to the
    install directory, and prepends that directory to the user PATH.

.PARAMETER Version
    Pin a specific version (e.g. v0.3.0). Defaults to the latest published.

.PARAMETER Channel
    Release channel. Currently only 'stable' is supported.

.PARAMETER InstallDir
    Target directory for fx.exe. Defaults to $env:LOCALAPPDATA\fx\bin,
    overridable via the FX_INSTALL_DIR environment variable.

.PARAMETER NoPathUpdate
    Skip the user PATH mutation. fx.exe is still placed in -InstallDir but the
    directory is not added to PATH.

.PARAMETER SkipVerify
    Skip SHA-256 checksum verification.

.PARAMETER Help
    Print this help block. Aliases: -h, -?.

.EXAMPLE
    .\setup.ps1
    Install the latest stable fx to the default location.

.EXAMPLE
    .\setup.ps1 -Version v0.3.0
    Install a pinned version.

.EXAMPLE
    .\setup.ps1 -InstallDir C:\Tools\fx -Verbose
    Install to a custom directory with verbose output.

.EXAMPLE
    iwr -useb https://fx.sh/setup.ps1 | iex
    Install via the one-liner published on fx.sh.

.NOTES
    PowerShell 5 or later is required. Only x86_64 is supported for v1; aarch64
    is deferred and tracked under WINDOWS_SUPPORT_PLAN.md.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$Version,

    [ValidateSet('stable', 'dev')]
    [string]$Channel = 'stable',

    [string]$InstallDir,

    [switch]$NoPathUpdate,

    [switch]$SkipVerify,

    # Print usage and exit. -h is a built-in PowerShell switch on advanced
    # functions when added via Alias; -? uses the Alias attribute because
    # '?' is not a legal parameter identifier.
    [Alias('h', '?')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    @'
NAME
    setup.ps1 - fx installer for Windows

SYNOPSIS
    Downloads and installs fx from the Vercel CDN.

USAGE
    iwr -useb https://fx.sh/setup.ps1 | iex
    .\setup.ps1 [-Version <vX.Y.Z>] [-Channel <stable|dev>] [-InstallDir <path>]
                [-NoPathUpdate] [-SkipVerify] [-WhatIf] [-Verbose]
    .\setup.ps1 -h | -?

DESCRIPTION
    Mirrors the upstream Unix installer at https://fx.sh/setup.sh. Detects the
    latest stable version from the CDN, downloads fx-windows-x86_64.zip, verifies
    its SHA-256 against the sidecar checksum, extracts fx.exe to the install
    directory, and prepends that directory to the user PATH.

PARAMETERS
    -Version      Pin a specific version (e.g. v0.3.0). Defaults to latest.
    -Channel      Release channel. Currently only 'stable' is supported.
    -InstallDir   Target directory for fx.exe. Defaults to $env:LOCALAPPDATA\fx\bin,
                  overridable via the FX_INSTALL_DIR environment variable.
    -NoPathUpdate Skip the user PATH mutation. fx.exe will still be placed in
                  -InstallDir but the directory will not be added to PATH.
    -SkipVerify   Skip SHA-256 checksum verification.
    -WhatIf       Show what the script would do without making changes.
    -Verbose      Print detailed progress information.
    -h, -?        Print this help block.

ENVIRONMENT
    FX_INSTALL_DIR         Override the install directory.
    FX_INSTALL_CDN_BASE    Override the CDN base URL (for E2E tests).

EXAMPLES
    .\setup.ps1
        Install the latest stable fx to the default location.

    .\setup.ps1 -Version v0.3.0
        Install a pinned version.

    .\setup.ps1 -InstallDir C:\Tools\fx -Verbose
        Install to a custom directory with verbose output.

    iwr -useb https://fx.sh/setup.ps1 | iex
        Install via the one-liner published on fx.sh.
'@ | Write-Host
    return
}

# ---------------------------------------------------------------------------
# Constants and environment
# ---------------------------------------------------------------------------

$script:CdnBase = if ($env:FX_INSTALL_CDN_BASE) { $env:FX_INSTALL_CDN_BASE } else { 'https://releases.fx.sh' }
$script:Platform = 'windows-x86_64'
$script:ArchiveName = "fx-$($script:Platform).zip"
$script:MaxDownloadBytes = 200MB
$script:MaxLatestBytes = 128
$script:MaxChecksumBytes = 4096

if (-not $InstallDir) {
    if ($env:FX_INSTALL_DIR) {
        $InstallDir = $env:FX_INSTALL_DIR
    } elseif ($env:LOCALAPPDATA) {
        $InstallDir = Join-Path $env:LOCALAPPDATA 'fx\bin'
    } else {
        $InstallDir = Join-Path $env:USERPROFILE '.fx\bin'
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status {
    param([string]$Message)
    Write-Host "==> " -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Failure {
    param([string]$Message)
    Write-Host "error: " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Format-VersionDisplay {
    param([string]$RawVersion)
    if ($RawVersion.StartsWith('v')) { return $RawVersion.Substring(1) }
    return $RawVersion
}

function Test-FxPrereqs {
    if ($env:OS -ne 'Windows_NT') {
        throw 'fx Windows installer must run on Windows.'
    }

    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ($arch -ne [System.Runtime.InteropServices.Architecture]::X64) {
        throw "fx Windows installer currently supports x86_64 only (detected $arch). aarch64 is not yet published; tracked under WINDOWS_SUPPORT_PLAN.md."
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5 or later is required (detected $($PSVersionTable.PSVersion))."
    }
}

function Get-LatestVersion {
    [CmdletBinding()]
    param()

    $url = "$($script:CdnBase)/latest.txt"
    Write-Verbose "Fetching latest version from $url"

    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
    $raw = ($response | Out-String).Trim()
    if ($raw.Length -gt $script:MaxLatestBytes) {
        throw "latest.txt response exceeded $($script:MaxLatestBytes) bytes; aborting."
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'latest.txt returned an empty version.'
    }

    $firstLine = ($raw -split "(`r`n|`n)")[0].Trim()
    if ($firstLine -notmatch '^v?\d+\.\d+\.\d+') {
        throw "latest.txt did not contain a semver version (got '$firstLine')."
    }
    return $firstLine
}

function Get-ArchiveUrl {
    param([string]$ResolvedVersion)
    "$($script:CdnBase)/$ResolvedVersion/$($script:ArchiveName)"
}

function Get-ChecksumUrl {
    param([string]$ArchiveUrl)
    "$ArchiveUrl.sha256"
}

function Save-Archive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Url,
        [string]$Destination
    )

    if ($PSCmdlet.ShouldProcess($Url, 'Download archive')) {
        Write-Verbose "Downloading $Url -> $Destination"
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
    }
}

function Get-ExpectedChecksum {
    [CmdletBinding()]
    param([string]$ChecksumUrl)

    Write-Verbose "Fetching checksum from $ChecksumUrl"
    $response = Invoke-WebRequest -Uri $ChecksumUrl -UseBasicParsing -TimeoutSec 30
    $raw = ($response | Out-String)
    if ($raw.Length -gt $script:MaxChecksumBytes) {
        throw "Checksum response exceeded $($script:MaxChecksumBytes) bytes; aborting."
    }

    $trimmed = $raw.Trim()
    $hex = ($trimmed -split '\s+')[0]
    if ($hex -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Checksum sidecar did not contain a 64-char hex digest (got '$trimmed')."
    }
    return $hex.ToLowerInvariant()
}

function Test-ArchiveChecksum {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ArchivePath,
        [string]$ExpectedHex
    )

    Write-Verbose "Computing SHA-256 of $ArchivePath"
    $actual = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actual -ne $ExpectedHex) {
        throw @"
SHA-256 mismatch:
  expected: $ExpectedHex
  actual:   $actual
The download may be corrupted. Re-run the installer; if it persists, verify
the published artifact for $script:Platform at $($script:CdnBase).
"@
    }

    Write-Verbose "Checksum OK ($actual)"
}

function Expand-FxArchive {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    if (-not (Test-Path $Destination)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create install directory')) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
    }

    $existingFx = Join-Path $Destination 'fx.exe'
    if (Test-Path $existingFx) {
        if ($PSCmdlet.ShouldProcess($existingFx, 'Remove previous fx.exe')) {
            Remove-Item -Path $existingFx -Force
        }
    }

    Write-Verbose "Extracting $ArchivePath -> $Destination"
    if ($PSCmdlet.ShouldProcess($ArchivePath, 'Expand-Archive')) {
        Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
    }

    $finalFx = Join-Path $Destination 'fx.exe'
    if (-not (Test-Path $finalFx)) {
        # Some packagers wrap the binary in a top-level folder (fx/fx.exe).
        $nested = Get-ChildItem -Path $Destination -Recurse -Filter 'fx.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nested) {
            if ($PSCmdlet.ShouldProcess($nested.FullName, 'Flatten nested fx.exe')) {
                Move-Item -Path $nested.FullName -Destination $finalFx -Force
                # Clean up the now-empty wrapper directory if it was added by us.
                $wrapper = Split-Path -Parent $nested.FullName
                if ($wrapper -ne $Destination) {
                    Remove-Item -Path $wrapper -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            throw "Extraction succeeded but fx.exe was not found under $Destination."
        }
    }
}

function Test-PathContains {
    param([string]$Needle, [string]$Haystack)
    if ([string]::IsNullOrEmpty($Haystack)) { return $false }
    $segments = $Haystack.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    foreach ($segment in $segments) {
        if ($segment.TrimEnd('\') -ieq $Needle.TrimEnd('\')) { return $true }
    }
    return $false
}

function Add-InstallDirToUserPath {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$PathEntry)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains -Needle $PathEntry -Haystack $current) {
        Write-Verbose "User PATH already contains $PathEntry"
        return
    }

    $newPath = if ([string]::IsNullOrEmpty($current)) {
        $PathEntry
    } else {
        "$PathEntry;$current"
    }

    if ($PSCmdlet.ShouldProcess($PathEntry, 'Prepend to user PATH')) {
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }

    # Update the current process PATH so the verification step works without
    # requiring the user to open a new shell.
    if (-not (Test-PathContains -Needle $PathEntry -Haystack $env:Path)) {
        $env:Path = "$PathEntry;$env:Path"
    }
}

function Show-Completion {
    param(
        [string]$ResolvedVersion,
        [string]$FxExePath
    )

    $displayVersion = Format-VersionDisplay -RawVersion $ResolvedVersion
    Write-Host ''
    Write-Status "installed fx $displayVersion"
    Write-Host "  binary:   $FxExePath"

    $inPathNow = Test-PathContains -Needle $InstallDir -Haystack $env:Path
    if (-not $inPathNow) {
        Write-Host ''
        Write-Host 'Restart your shell (or open a new PowerShell window) so fx is on PATH, then run:'
        Write-Host "  fx --version" -ForegroundColor Gray
    } else {
        Write-Host ''
        Write-Host 'fx is now on PATH. To make this permanent across shells, open a new PowerShell window.'
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    Test-FxPrereqs
    Write-Verbose "CDN base: $($script:CdnBase)"
    Write-Verbose "Install dir: $InstallDir"

    $resolvedVersion = if ($Version) {
        Write-Verbose "Using pinned version: $Version"
        $Version
    } elseif ($Channel -eq 'dev') {
        throw 'The -Channel dev flow is not yet implemented for the Windows installer. Track WINDOWS_SUPPORT_PLAN.md.'
    } else {
        Get-LatestVersion
    }

    if ($resolvedVersion -notmatch '^v?\d+\.\d+\.\d+') {
        throw "Version '$resolvedVersion' is not a valid semver tag (expected vX.Y.Z)."
    }

    $archiveUrl = Get-ArchiveUrl -ResolvedVersion $resolvedVersion
    $checksumUrl = Get-ChecksumUrl -ArchiveUrl $archiveUrl
    Write-Verbose "Archive: $archiveUrl"
    Write-Verbose "Checksum: $checksumUrl"

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fx-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $archivePath = Join-Path $tmpDir $script:ArchiveName

    try {
        Save-Archive -Url $archiveUrl -Destination $archivePath

        if (-not $SkipVerify) {
            $expected = Get-ExpectedChecksum -ChecksumUrl $checksumUrl
            Test-ArchiveChecksum -ArchivePath $archivePath -ExpectedHex $expected
        } else {
            Write-Verbose 'Skipping checksum verification (-SkipVerify).'
        }

        Expand-FxArchive -ArchivePath $archivePath -Destination $InstallDir
    }
    finally {
        if (Test-Path $tmpDir) {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $fxExe = Join-Path $InstallDir 'fx.exe'

    if (-not $NoPathUpdate) {
        Add-InstallDirToUserPath -PathEntry $InstallDir
    } else {
        Write-Verbose 'Skipping user PATH update (-NoPathUpdate).'
    }

    Show-Completion -ResolvedVersion $resolvedVersion -FxExePath $fxExe

    if (-not $SkipVerify -and (Test-Path $fxExe)) {
        Write-Host ''
        Write-Status 'verifying install'
        & $fxExe --version
    }
}
catch {
    Write-Failure $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
