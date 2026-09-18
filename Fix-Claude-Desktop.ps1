<#
.SYNOPSIS
    Opens Claude Desktop with the original MSIX profile without rebooting.

.DESCRIPTION
    Some Windows installations fail to activate Claude Desktop through AppX
    with error 0x80070020. Starting Claude.exe without an explicit profile can
    create a second, empty profile under %APPDATA% and make Claude look newly
    installed.

    This script closes those processes, preserves any accidental duplicate by
    renaming it, and starts Claude.exe with --user-data-dir set to the existing
    MSIX profile. It does not delete or reset the original profile.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 60)]
    [int]$LaunchTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$logDirectory = Join-Path $env:LOCALAPPDATA 'ClaudeDesktopRepair'
$logFile = Join-Path $logDirectory 'repair.log'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-Status {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -LiteralPath $logFile -Value $line
}

try {
    $package = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        throw 'Claude Desktop is not installed for this Windows user.'
    }

    $claudeExe = Join-Path $package.InstallLocation 'app\Claude.exe'
    $originalProfile = Join-Path $env:LOCALAPPDATA (
        'Packages\{0}\LocalCache\Roaming\Claude' -f $package.PackageFamilyName
    )
    $duplicateProfile = Join-Path $env:APPDATA 'Claude'

    if (-not (Test-Path -LiteralPath $claudeExe -PathType Leaf)) {
        throw "Claude.exe was not found at $claudeExe"
    }
    if (-not (Test-Path -LiteralPath $originalProfile -PathType Container)) {
        throw "The original Claude profile was not found at $originalProfile"
    }

    Write-Status "Using the original profile: $originalProfile" Cyan
    Write-Status 'Closing all Claude Desktop processes...' Yellow

    $claudeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'claude.exe' })
    foreach ($process in $claudeProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $claudeProcesses = @(Get-Process -Name Claude -ErrorAction SilentlyContinue)
        foreach ($process in $claudeProcesses) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    } while ($claudeProcesses.Count -gt 0 -and (Get-Date) -lt $deadline)

    if (@(Get-Process -Name Claude -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'One or more Claude processes could not be closed.'
    }

    # Preserve, rather than delete, the accidental unpackaged profile created by
    # a direct launch without --user-data-dir.
    $existingDuplicateBackup = Get-ChildItem -LiteralPath (Split-Path -Parent $duplicateProfile) `
        -Directory -Filter 'Claude.duplicate-backup-*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ((Test-Path -LiteralPath $duplicateProfile -PathType Container) -and
        -not $existingDuplicateBackup) {
        $backupName = 'Claude.duplicate-backup-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        $backupPath = Join-Path (Split-Path -Parent $duplicateProfile) $backupName
        Write-Status "Preserving the duplicate profile as $backupPath" DarkYellow
        Move-Item -LiteralPath $duplicateProfile -Destination $backupPath -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $duplicateProfile -PathType Container) {
        Write-Status 'An inactive duplicate folder exists, but Claude will not use it.' DarkGray
    }

    $argument = '--user-data-dir="{0}"' -f $originalProfile
    Write-Status 'Launching Claude with its original profile...' Cyan
    $launchedProcess = Start-Process -FilePath $claudeExe -ArgumentList $argument -PassThru

    $escapedProfile = [regex]::Escape($originalProfile)
    $launchDeadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $profileProcess = $null
    do {
        Start-Sleep -Milliseconds 750
        $profileProcess = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ieq 'claude.exe' -and
                $_.CommandLine -match $escapedProfile
            } |
            Select-Object -First 1
        if ($profileProcess) { break }
    } while ((Get-Date) -lt $launchDeadline)

    if (-not $profileProcess) {
        throw 'Claude did not start with the original MSIX profile.'
    }

    Write-Status "Verified: Claude is using the original profile (PID $($profileProcess.ProcessId))." Green
    Write-Status 'No duplicate profile or new sign-in should be used.' Green
}
catch {
    Write-Status "Repair failed: $($_.Exception.Message)" Red
    Write-Status "Details were saved to $logFile" DarkYellow
    exit 1
}
