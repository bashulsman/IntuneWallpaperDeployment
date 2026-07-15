<#
    Uninstall.ps1 (generic template - do not hardcode a customer name here)
    Removes the Personalization policy values this app set, the cached
    image files, and the tracking registry key. CustomerName comes from
    config.json next to this script, same as Install.ps1.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath
)

# See Install.ps1 for why: avoids our tracking key silently landing under
# WOW6432Node if launched as a 32-bit process on a 64-bit OS.
if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and (Test-Path "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe")) {
    $relaunchArgs = @{}
    if ($ConfigPath) { $relaunchArgs['ConfigPath'] = $ConfigPath }
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @relaunchArgs
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
}

# Mirrors Install.ps1's helper: logs exactly which registry value was
# removed (only if it actually existed), so Uninstall.log shows precisely
# what changed.
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

    $InstallRoot    = Join-Path $env:ProgramData (Join-Path $config.CustomerName 'WallpaperDeployment')
    $LogPath        = Join-Path $InstallRoot 'Uninstall.log'
    # Legacy key from an earlier version of this tool - cleaned up here too
    # in case this device still has values from before the switch to
    # PersonalizationCSP-only (see Install.ps1 for why).
    $RegLegacyPolicyKey       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    $RegPersonalizationCspKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    $RegTrackingKey           = "HKLM:\SOFTWARE\$($config.CustomerName)\WallpaperDeployment"

    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogPath -Append | Out-Null

    if (Test-Path $RegTrackingKey) {
        Write-Output "Removing Personalization registry values:"
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImagePath'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImageUrl'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'LockScreenImageStatus'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImagePath'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImageUrl'
        Remove-LoggedRegistryValue -Path $RegLegacyPolicyKey -Name 'DesktopImageStatus'

        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImagePath'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageUrl'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'LockScreenImageStatus'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImagePath'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageUrl'
        Remove-LoggedRegistryValue -Path $RegPersonalizationCspKey -Name 'DesktopImageStatus'

        Remove-Item -Path $RegTrackingKey -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "  [Registry removed] $RegTrackingKey (tracking key)"
        Write-Output "Removed Personalization policy values and tracking key."
    }
    else {
        Write-Output "Tracking key not found, nothing to remove from registry."
    }

    $ImageRoot = Join-Path $InstallRoot 'Images'
    if (Test-Path $ImageRoot) {
        Remove-Item -Path $ImageRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed cached wallpaper images."
    }

    Write-Output "Uninstall complete."
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}
catch {
    Write-Output "Uninstall failed: $($_.Exception.Message)"
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
