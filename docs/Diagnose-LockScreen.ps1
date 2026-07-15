<#
    Diagnose-LockScreen.ps1
    Read-only diagnostic for "lock screen registry is correct but the image
    never renders". Run elevated on the affected machine and share the
    output. Does not change anything.
#>

Write-Host "=== Personalization policy (HKLM) ===" -ForegroundColor Cyan
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue |
    Select-Object LockScreenImagePath, LockScreenImageUrl, LockScreenImageStatus, DesktopImagePath, DesktopImageUrl, DesktopImageStatus |
    Format-List

Write-Host "=== Our tool's tracking key(s) under HKLM:\SOFTWARE\<CustomerName>\WallpaperDeployment ===" -ForegroundColor Cyan
Get-ChildItem 'HKLM:\SOFTWARE' -ErrorAction SilentlyContinue | ForEach-Object {
    $trackingPath = "HKLM:\SOFTWARE\$($_.PSChildName)\WallpaperDeployment"
    if (Test-Path $trackingPath) {
        Write-Host "--- $trackingPath ---"
        Get-ItemProperty $trackingPath | Format-List
    }
}

Write-Host "=== Lockscreen image file check ===" -ForegroundColor Cyan
$imgPath = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -ErrorAction SilentlyContinue).LockScreenImagePath
if ($imgPath) {
    Write-Host "Path from registry: $imgPath"
    if (Test-Path $imgPath) {
        Get-Item $imgPath | Select-Object FullName, Length, LastWriteTime
        try {
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($imgPath)
            Write-Host "Image loads OK: $($img.Width)x$($img.Height), format $($img.RawFormat)"
            $img.Dispose()
        } catch {
            Write-Host "IMAGE FAILED TO LOAD: $($_.Exception.Message)" -ForegroundColor Red
        }
        Write-Host "ACL:"
        (Get-Acl $imgPath).Access | Format-Table IdentityReference, FileSystemRights, AccessControlType -AutoSize
    } else {
        Write-Host "FILE DOES NOT EXIST AT THAT PATH" -ForegroundColor Red
    }
} else {
    Write-Host "No LockScreenImagePath value found in registry." -ForegroundColor Red
}

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
