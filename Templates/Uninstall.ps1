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

    $InstallRoot    = Join-Path $env:ProgramData (Join-Path $config.CustomerName 'WallpaperDeployment')
    $LogPath        = Join-Path $InstallRoot 'Uninstall.log'
    $RegPolicyKey   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    $RegTrackingKey = "HKLM:\SOFTWARE\$($config.CustomerName)\WallpaperDeployment"

    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $LogPath -Append | Out-Null

    if (Test-Path $RegTrackingKey) {
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImagePath'    -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageUrl'     -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'LockScreenImageStatus'  -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImagePath'       -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageUrl'        -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RegPolicyKey -Name 'DesktopImageStatus'     -ErrorAction SilentlyContinue

        Remove-Item -Path $RegTrackingKey -Recurse -Force -ErrorAction SilentlyContinue
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
