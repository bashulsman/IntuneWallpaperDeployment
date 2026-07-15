<#
    Diagnose-LockScreen.ps1
    Read-only diagnostic for "lock screen registry is correct but the image
    never renders". Run elevated on the affected machine and share the
    output. Does not change anything.
#>

Write-Host "=== Standalone Personalization CSP (what this tool writes - should be populated) ===" -ForegroundColor Cyan
Write-Host "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP') {
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -ErrorAction SilentlyContinue |
        Select-Object LockScreenImagePath, LockScreenImageUrl, LockScreenImageStatus, DesktopImagePath, DesktopImageUrl, DesktopImageStatus |
        Format-List
} else {
    Write-Host "Key does not exist - this tool has not (successfully) installed on this device yet."
}

Write-Host "=== Legacy ADMX-backed Policy CSP (no longer used - should be EMPTY) ===" -ForegroundColor Cyan
Write-Host "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"
$legacy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue |
    Select-Object LockScreenImagePath, LockScreenImageUrl, LockScreenImageStatus, DesktopImagePath, DesktopImageUrl, DesktopImageStatus
$legacy | Format-List
if ($legacy.LockScreenImageStatus -or $legacy.DesktopImageStatus) {
    Write-Host "WARNING: This key is populated. Real-device testing found having BOTH this key and PersonalizationCSP populated at once prevents the image from rendering. Redeploy with the current version of this tool to clean it up (or another Device Restrictions/Settings Catalog profile may be writing here - check Intune)." -ForegroundColor Red
}

Write-Host "=== Our tool's tracking key(s) under HKLM:\SOFTWARE\<CustomerName>\WallpaperDeployment ===" -ForegroundColor Cyan
Get-ChildItem 'HKLM:\SOFTWARE' -ErrorAction SilentlyContinue | ForEach-Object {
    $trackingPath = "HKLM:\SOFTWARE\$($_.PSChildName)\WallpaperDeployment"
    if (Test-Path $trackingPath) {
        Write-Host "--- $trackingPath ---"
        Get-ItemProperty $trackingPath | Format-List
    }
}

function Test-ImageFile {
    param([string]$Label, [string]$Path)
    Write-Host "=== $Label image file check ===" -ForegroundColor Cyan
    if (-not $Path) {
        Write-Host "No value set in PersonalizationCSP."
        return
    }
    Write-Host "Path from registry: $Path"
    if (Test-Path $Path) {
        Get-Item $Path | Select-Object FullName, Length, LastWriteTime
        try {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($Path)
            Write-Host "Image loads OK: $($img.Width)x$($img.Height), format $($img.RawFormat)"
            $img.Dispose()
        } catch {
            Write-Host "IMAGE FAILED TO LOAD: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host "ACL:"
        (Get-Acl $Path).Access | Format-Table IdentityReference, FileSystemRights, AccessControlType -AutoSize
    } else {
        Write-Host "FILE DOES NOT EXIST AT THAT PATH" -ForegroundColor Red
    }
}

$cspValues = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -ErrorAction SilentlyContinue
Test-ImageFile -Label 'Lockscreen' -Path $cspValues.LockScreenImagePath
Test-ImageFile -Label 'Desktop background' -Path $cspValues.DesktopImagePath

Write-Host "=== MDM / Intune enrollment status ===" -ForegroundColor Cyan
dsregcmd /status | Select-String "AzureAdJoined|EnterpriseJoined|DomainJoined|MDMUrl"

Write-Host "=== Any MDM-delivered Personalization policy (separate from our tool) ===" -ForegroundColor Cyan
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers' -ErrorAction SilentlyContinue | ForEach-Object {
    $personalizationPath = Join-Path $_.PSPath 'default\Personalization'
    if (Test-Path $personalizationPath) {
        Write-Host "--- Found MDM Personalization policy under provider $($_.PSChildName) ---" -ForegroundColor Yellow
        Get-ItemProperty $personalizationPath -ErrorAction SilentlyContinue | Format-List
    }
}

Write-Host "=== Lock screen render cache (per-SID) ===" -ForegroundColor Cyan
Get-ChildItem "$env:ProgramData\Microsoft\Windows\SystemData" -Recurse -Filter "LockScreen_*" -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, LastWriteTime

Write-Host "=== Windows build / edition ===" -ForegroundColor Cyan
Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber
