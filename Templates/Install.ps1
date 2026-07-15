<#
    Install.ps1 (generic template - do not hardcode a customer name here)
    Deploys lockscreen and/or desktop wallpaper via the Windows Personalization
    policy (HKLM), so it applies to all logged-in users without needing to run
    in per-user context.

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

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
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
    $RegPolicyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    $RegTrackingKey = "HKLM:\SOFTWARE\$($config.CustomerName)\WallpaperDeployment"

    # -Force: fine if C:\ProgramData\<CustomerName> already exists from another app.
    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogPath -Append | Out-Null

    Write-Output "Customer: $($config.CustomerName)  Version: $($config.Version)  Mode: $effectiveMode"

    New-Item -Path $ImageRoot -ItemType Directory -Force | Out-Null

    New-Item -Path $RegPolicyKey -Force | Out-Null

    # --- Lockscreen (only when Mode = LockscreenOnly or Both) ---
    $lockDest = $null
    if ($wantsLockscreen) {
        $lockSource = Join-Path $PSScriptRoot "Images\$($config.LockscreenImage)"
        if (-not (Test-Path $lockSource)) {
            throw "Lockscreen image not found: $lockSource"
        }
        $lockDest = Join-Path $ImageRoot $config.LockscreenImage
        Copy-Item -Path $lockSource -Destination $lockDest -Force

        New-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImagePath'   -Value $lockDest -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageUrl'    -Value $lockDest -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageStatus' -Value 1         -PropertyType DWord  -Force | Out-Null
        Write-Output "Lockscreen wallpaper set: $lockDest"
    }
    else {
        # Mode switched away from a lockscreen mode on redeploy: clear any previously set lockscreen policy.
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImagePath'   -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageUrl'    -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageStatus' -ErrorAction SilentlyContinue
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

        New-ItemProperty -Path $RegPolicyKey -Name 'DesktopImagePath'   -Value $desktopDest -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageUrl'    -Value $desktopDest -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageStatus' -Value 1            -PropertyType DWord  -Force | Out-Null
        Write-Output "Background wallpaper set: $desktopDest"
    }
    else {
        # Mode switched away from a background mode on redeploy: clear any previously set background policy.
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImagePath'    -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageUrl'     -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageStatus'  -ErrorAction SilentlyContinue
    }

    # --- Tracking key used by Detect.ps1 and Uninstall.ps1 ---
    New-Item -Path $RegTrackingKey -Force | Out-Null
    New-ItemProperty -Path $RegTrackingKey -Name 'Version' -Value $config.Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegTrackingKey -Name 'Mode'    -Value $effectiveMode   -PropertyType String -Force | Out-Null
    if ($wantsLockscreen) {
        New-ItemProperty -Path $RegTrackingKey -Name 'LockscreenImage' -Value $lockDest -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $RegTrackingKey -Name 'LockscreenImage' -ErrorAction SilentlyContinue
    }
    if ($wantsBackground) {
        New-ItemProperty -Path $RegTrackingKey -Name 'DesktopImage' -Value $desktopDest -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $RegTrackingKey -Name 'DesktopImage' -ErrorAction SilentlyContinue
    }
    New-ItemProperty -Path $RegTrackingKey -Name 'InstalledOn' -Value (Get-Date -Format 'o') -PropertyType String -Force | Out-Null

    Write-Output "Install complete."
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}
catch {
    Write-Output "Install failed: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
