<#
.SYNOPSIS
    Opens Claude Desktop with its original MSIX profile without rebooting.

.DESCRIPTION
    Works around Claude Desktop launch failures such as "Another program is
    currently using this file" and AppX error 0x80070020.

    The script first performs a user-level cleanup and launches Claude with its
    original MSIX profile. If Windows still reports a sharing violation or no
    usable window appears, it requests administrator permission once, stops the
    packaged CoworkVMService and other Claude-specific lock holders, and retries.

    It does not change WindowsApps permissions or delete the original profile.
#>
[CmdletBinding()]
param(
    [ValidateRange(10, 60)]
    [int]$LaunchTimeoutSeconds = 30,

    # Internal mode used by the non-elevated parent process.
    [switch]$ElevatedCleanup
)

$ErrorActionPreference = 'Stop'
$repairStarted = Get-Date
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-ClaudeInstall {
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
    if (-not (Test-Path -LiteralPath $claudeExe -PathType Leaf)) {
        throw "Claude.exe was not found at $claudeExe"
    }
    if (-not (Test-Path -LiteralPath $originalProfile -PathType Container)) {
        throw "The original Claude profile was not found at $originalProfile"
    }

    return [pscustomobject]@{
        Package = $package
        ClaudeExe = $claudeExe
        OriginalProfile = $originalProfile
        DuplicateProfile = (Join-Path $env:APPDATA 'Claude')
    }
}

function Get-ClaudeLockHolder {
    param(
        [Parameter(Mandatory)] $Install,
        [switch]$IncludeService
    )

    $installPath = $Install.Package.InstallLocation.TrimEnd('\')
    $escapedFamily = [regex]::Escape($Install.Package.PackageFamilyName)

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.ExecutablePath
            $commandLine = $_.CommandLine
            $fromPackage = $path -and $path.StartsWith(
                $installPath,
                [StringComparison]::OrdinalIgnoreCase
            )
            $isNativeHost = $_.Name -ieq 'chrome-native-host.exe'
            $isNativeHostWrapper = $_.Name -ieq 'cmd.exe' -and
                $commandLine -match '(?i)chrome-native-host\.exe' -and
                $commandLine -match $escapedFamily
            $isCoworkService = $IncludeService -and $_.Name -ieq 'cowork-svc.exe'

            $fromPackage -or $isNativeHost -or $isNativeHostWrapper -or $isCoworkService
        }
}

function Stop-ClaudeLockHolder {
    param(
        [Parameter(Mandatory)] $Install,
        [switch]$IncludeService,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $holders = @(Get-ClaudeLockHolder -Install $Install -IncludeService:$IncludeService)
        foreach ($process in $holders) {
            Write-Status "Stopping lock holder PID $($process.ProcessId): $($process.Name)" DarkYellow
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        if ($holders.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return @(Get-ClaudeLockHolder -Install $Install -IncludeService:$IncludeService)
}

function Invoke-ElevatedCleanup {
    if (-not (Test-IsAdministrator)) {
        throw 'The lock-holder cleanup did not receive administrator permission.'
    }

    $install = Resolve-ClaudeInstall
    Write-Status 'Running elevated Claude lock-holder cleanup...' Yellow

    $service = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        Write-Status 'Stopping CoworkVMService...' DarkYellow
        Stop-Service -Name 'CoworkVMService' -Force -ErrorAction Stop
        (Get-Service -Name 'CoworkVMService').WaitForStatus(
            [ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(20)
        )
    }

    $remaining = @(Stop-ClaudeLockHolder -Install $install -IncludeService -TimeoutSeconds 20)
    $service = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne 'Stopped') {
        throw 'CoworkVMService restarted before its package lock was released.'
    }
    if ($remaining.Count -gt 0) {
        $details = [string]::Join(', ', @(
            $remaining | ForEach-Object { "PID $($_.ProcessId) ($($_.Name))" }
        ))
        throw "Claude lock holders are still running: $details"
    }

    Write-Status 'Elevated cleanup verified: Claude package lock holders are stopped.' Green
}

function Invoke-ClaudeLaunch {
    param(
        [Parameter(Mandatory)] $Install,
        [Parameter(Mandatory)] [int]$TimeoutSeconds
    )

    $argument = '--user-data-dir="{0}"' -f $Install.OriginalProfile
    try {
        Write-Status 'Launching Claude with its original profile...' Cyan
        $startedProcess = Start-Process -FilePath $Install.ClaudeExe `
            -ArgumentList $argument -PassThru -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            ErrorMessage = $_.Exception.Message
            NativeErrorCode = $_.Exception.NativeErrorCode
        }
    }

    $escapedProfile = [regex]::Escape($Install.OriginalProfile)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 750
        $mainProcess = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -ieq 'claude.exe' -and
                $_.CommandLine -match $escapedProfile -and
                $_.CommandLine -notmatch '(?i)\s--type='
            } |
            Select-Object -First 1

        if ($mainProcess) {
            $windowProcess = Get-Process -Id $mainProcess.ProcessId -ErrorAction SilentlyContinue
            if ($windowProcess -and $windowProcess.MainWindowHandle -ne 0 -and $windowProcess.Responding) {
                return [pscustomobject]@{
                    Success = $true
                    ProcessId = $mainProcess.ProcessId
                    WindowTitle = $windowProcess.MainWindowTitle
                }
            }
        }
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Success = $false
        ErrorMessage = 'Claude did not create a responsive window with the original profile.'
        NativeErrorCode = $null
    }
}

try {
    if ($ElevatedCleanup) {
        Invoke-ElevatedCleanup
        exit 0
    }

    $install = Resolve-ClaudeInstall
    Write-Status "Using the original profile: $($install.OriginalProfile)" Cyan
    Write-Status 'Closing Claude Desktop and its user-level helper processes...' Yellow

    $remaining = @(Stop-ClaudeLockHolder -Install $install -TimeoutSeconds 20)
    $nonServiceRemainder = @($remaining | Where-Object { $_.Name -ine 'cowork-svc.exe' })
    if ($nonServiceRemainder.Count -gt 0) {
        throw 'One or more Claude user-level helper processes could not be closed.'
    }

    # Preserve, rather than delete, the accidental unpackaged profile created by
    # a direct launch without --user-data-dir.
    $existingDuplicateBackup = Get-ChildItem `
        -LiteralPath (Split-Path -Parent $install.DuplicateProfile) `
        -Directory -Filter 'Claude.duplicate-backup-*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ((Test-Path -LiteralPath $install.DuplicateProfile -PathType Container) -and
        -not $existingDuplicateBackup) {
        $backupName = 'Claude.duplicate-backup-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        $backupPath = Join-Path (Split-Path -Parent $install.DuplicateProfile) $backupName
        Write-Status "Preserving the duplicate profile as $backupPath" DarkYellow
        Move-Item -LiteralPath $install.DuplicateProfile -Destination $backupPath -ErrorAction Stop
    }
    elseif (Test-Path -LiteralPath $install.DuplicateProfile -PathType Container) {
        Write-Status 'An inactive duplicate folder exists, but Claude will not use it.' DarkGray
    }

    $attempt = Invoke-ClaudeLaunch -Install $install -TimeoutSeconds $LaunchTimeoutSeconds
    if (-not $attempt.Success) {
        Write-Status "First launch failed: $($attempt.ErrorMessage)" Yellow
        Write-Status 'Requesting administrator permission to clear system-level Claude locks...' Yellow

        $elevatedArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ElevatedCleanup' -f $PSCommandPath
        $elevatedProcess = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
            -ArgumentList $elevatedArguments -Wait -PassThru -ErrorAction Stop
        if ($elevatedProcess.ExitCode -ne 0) {
            throw "Elevated cleanup failed with exit code $($elevatedProcess.ExitCode)."
        }

        # The package may have changed during an interrupted update, so resolve
        # its current executable and profile again before the retry.
        $install = Resolve-ClaudeInstall
        $attempt = Invoke-ClaudeLaunch -Install $install -TimeoutSeconds $LaunchTimeoutSeconds
    }

    if (-not $attempt.Success) {
        $appModelErrors = @(Get-WinEvent -FilterHashtable @{
                LogName = 'Microsoft-Windows-AppModel-Runtime/Admin'
                StartTime = $repairStarted
                Id = 208, 215
            } -ErrorAction SilentlyContinue)
        if ($appModelErrors.Count -gt 0) {
            throw 'Claude still failed after lock cleanup and Windows recorded another AppX container error. A Windows sign-out or restart may be required to release a leaked container.'
        }
        throw $attempt.ErrorMessage
    }

    Write-Status "Verified: Claude is using the original profile (PID $($attempt.ProcessId))." Green
    Write-Status "Verified responsive window: $($attempt.WindowTitle)" Green
    Write-Status 'Repair completed without creating a new login profile.' Green
}
catch {
    Write-Status "Repair failed: $($_.Exception.Message)" Red
    Write-Status "Details were saved to $logFile" DarkYellow
    exit 1
}
