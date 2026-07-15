<#
    Install.ps1 (generic template - do not hardcode a customer name here)
    Deploys lockscreen and/or desktop wallpaper via the Windows
    PersonalizationCSP registry (HKLM), so it applies to all logged-in users
    without needing to run in per-user context.

    Uses ONLY HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP
    - an earlier version of this tool also wrote to the ADMX-backed
    HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization key, but
    real-device testing found that writing to both locations at once
    prevented the image from actually rendering on Windows 11 Pro, while
    PersonalizationCSP alone worked reliably. This script cleans up any
    stale values a previous version left in the old location.

    Everything customer/version-specific (CustomerName, Version, Mode, image
    file names) comes from config.json next to this script - this script
    itself is identical across every customer and every version. -Mode on the
    command line overrides config.json's Mode, so the same package can be
    deployed as a "lockscreen only", "background only" or "lockscreen +
    background" app in Intune just by changing the Install command line.
#>

[CmdletBinding()]
param(
    [ValidateSet('LockscreenOnly', 'BackgroundOnly', 'Both')]
    [string]$Mode,

    [string]$ConfigPath
)

# If launched as a 32-bit process on a 64-bit OS, relaunch as 64-bit first.
# Unlike the old ADMX-backed "Policies" key, PersonalizationCSP is a plain
# registry key - a 32-bit process would get silently redirected to
# WOW6432Node, so the wallpaper settings (and our own tracking key) would be
# written somewhere Windows and Detect.ps1/Uninstall.ps1 never look.
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and (Test-Path "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe")) {
    $relaunchArgs = @{}
    if ($Mode) { $relaunchArgs['Mode'] = $Mode }
    if ($ConfigPath) { $relaunchArgs['ConfigPath'] = $ConfigPath }
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @relaunchArgs
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}

# Set/remove a registry value and log exactly what changed, so Install.log
# shows precisely which registry values this run touched without needing to
# separately inspect the registry to reconstruct what happened.
function Set-LoggedRegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$PropertyType)
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force | Out-Null
    Write-Output "  [Registry set]     $Path\$Name = $Value"
}

function Remove-LoggedRegistryValue {
    param([string]$Path, [string]$Name)
    $existed = $null -ne (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($existed) {
        Write-Output "  [Registry removed] $Path\$Name"
    }
}

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

    if (-not $config.CustomerName) {
        throw "config.json is missing CustomerName"
    }

    $effectiveMode = if ($Mode) { $Mode } else { $config.Mode }
    if ($effectiveMode -notin @('LockscreenOnly', 'BackgroundOnly', 'Both')) {
        throw "Invalid Mode '$effectiveMode'. Expected 'LockscreenOnly', 'BackgroundOnly' or 'Both'."
    }
    $wantsLockscreen = $effectiveMode -in @('LockscreenOnly', 'Both')
    $wantsBackground = $effectiveMode -in @('BackgroundOnly', 'Both')

    # Namespaced under the customer's own name (not a fixed vendor name) since
    # this package is deployed to many different customers' machines.
    $InstallRoot    = Join-Path $env:ProgramData (Join-Path $config.CustomerName 'WallpaperDeployment')
    $ImageRoot      = Join-Path $InstallRoot 'Images'
    $LogPath        = Join-Path $InstallRoot 'Install.log'
    # Standalone "Personalization CSP" - what actually renders reliably on
    # Windows 11 Pro per real-device testing. This is the only key this
    # version writes to.
    $RegPersonalizationCspKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    # ADMX-backed "Policy CSP - Personalization" - used by an earlier version
    # of this tool. No longer written to; kept here only so we can clean up
    # stale values a previous install left behind (see migration step below).
    $RegLegacyPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    $RegTrackingKey = "HKLM:\SOFTWARE\$($config.CustomerName)\WallpaperDeployment"

    # -Force: fine if C:\ProgramData\<CustomerName> already exists from another app.
    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogPath -Append | Out-Null

    Write-Output "Customer: $($config.CustomerName)  Version: $($config.Version)  Mode: $effectiveMode"

    New-Item -Path $ImageRoot -ItemType Directory -Force | Out-Null

    New-Item -Path $RegPersonalizationCspKey -Force | Out-Null

    # One-time migration: remove any values a previous version of this tool
    # left under the legacy ADMX-backed key, since keeping both populated is
    # what was observed to break rendering.
    if (Test-Path $RegLegacyPolicyKey) {
        Write-Output "Cleaning up legacy Policy CSP registry values (no longer used):"
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImagePath'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImageUrl'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImageStatus'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImagePath'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImageUrl'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImageStatus'
    }

    # --- Lockscreen (only when Mode = LockscreenOnly or Both) ---
    $lockDest = $null
    if ($wantsLockscreen) {
        $lockSource = Join-Path $PSScriptRoot "Images\$($config.LockscreenImage)"
        if (-not (Test-Path $lockSource)) {
            throw "Lockscreen image not found: $lockSource"
        }
        $lockDest = Join-Path $ImageRoot $config.LockscreenImage
        Copy-Item -Path $lockSource -Destination $lockDest -Force

        Write-Output "Setting lockscreen wallpaper: $lockDest"
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImagePath'   -Value $lockDest -PropertyType String
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageUrl'    -Value $lockDest -PropertyType String
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageStatus' -Value 1         -PropertyType DWord
    }
    else {
        # Mode switched away from a lockscreen mode on redeploy: clear any previously set lockscreen policy.
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImagePath'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageUrl'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageStatus'
    }

    # --- Background/desktop wallpaper (only when Mode = BackgroundOnly or Both) ---
    $desktopDest = $null
    if ($wantsBackground) {
        $desktopSource = Join-Path $PSScriptRoot "Images\$($config.DesktopImage)"
        if (-not (Test-Path $desktopSource)) {
            throw "Background image not found: $desktopSource (required when Mode = BackgroundOnly or Both)"
        }
        $desktopDest = Join-Path $ImageRoot $config.DesktopImage
        Copy-Item -Path $desktopSource -Destination $desktopDest -Force

        Write-Output "Setting background wallpaper: $desktopDest"
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImagePath'   -Value $desktopDest -PropertyType String
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageUrl'    -Value $desktopDest -PropertyType String
        Set-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageStatus' -Value 1            -PropertyType DWord

        # Registry values alone don't repaint an already-open desktop session -
        # this forces Explorer to reload and redraw the background immediately
        # for any currently logged-on user, instead of waiting for their next
        # sign-in.
        try {
            RUNDLL32.EXE USER32.DLL, UpdatePerUserSystemParameters 1, True
            Write-Output "  Refreshed desktop background for logged-on users"
        } catch {
            Write-Output "  Warning: desktop refresh call failed: $($_.Exception.Message)"
        }
    }
    else {
        # Mode switched away from a background mode on redeploy: clear any previously set background policy.
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImagePath'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageUrl'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageStatus'
    }

    # --- Tracking key used by Detect.ps1 and Uninstall.ps1 ---
    New-Item -Path $RegTrackingKey -Force | Out-Null
    Set-LoggedRegistryValue -Path $RegTrackingKey -Name 'Version' -Value $config.Version -PropertyType String
    Set-LoggedRegistryValue -Path $RegTrackingKey -Name 'Mode'    -Value $effectiveMode   -PropertyType String
    if ($wantsLockscreen) {
        Set-LoggedRegistryValue -Path $RegTrackingKey -Name 'LockscreenImage' -Value $lockDest -PropertyType String
    } else {
        Remove-LoggedRegistryValue -Path $RegTrackingKey -Name 'LockscreenImage'
    }
    if ($wantsBackground) {
        Set-LoggedRegistryValue -Path $RegTrackingKey -Name 'DesktopImage' -Value $desktopDest -PropertyType String
    } else {
        Remove-LoggedRegistryValue -Path $RegTrackingKey -Name 'DesktopImage'
    }
    Set-LoggedRegistryValue -Path $RegTrackingKey -Name 'InstalledOn' -Value (Get-Date -Format 'o') -PropertyType String

    Write-Output "Install complete."
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}
catch {
    Write-Output "Install failed: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
