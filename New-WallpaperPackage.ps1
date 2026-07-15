<#
    New-WallpaperPackage.ps1
    Offline generator for the KNMT-style wallpaper Intune package. Prompts for
    (or accepts as parameters) customer name, version, mode, and wallpaper
    image locations, then generates a ready-to-package folder containing
    Install.ps1, Uninstall.ps1, Detect.ps1, config.json and the copied images.

    This script needs no internet access and does not itself build the
    .intunewin file - it produces the folder you point IntuneWinAppUtil.exe
    at. See README.md for that step.

    Examples:
      # Fully interactive - prompts for everything
      .\New-WallpaperPackage.ps1

      # Fully non-interactive
      .\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.0 -Mode LockscreenOnly `
          -LockscreenImagePath C:\Art\Contoso-Lockscreen.png

      # Background/desktop wallpaper only
      .\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.0 -Mode BackgroundOnly `
          -DesktopImagePath C:\Art\Contoso-Desktop.png

      # Both wallpapers
      .\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.1 -Mode Both `
          -LockscreenImagePath C:\Art\lock.png -DesktopImagePath C:\Art\desktop.png
#>

[CmdletBinding()]
param(
    [string]$CustomerName,

    [string]$Version,

    [ValidateSet('LockscreenOnly', 'BackgroundOnly', 'Both')]
    [string]$Mode,

    [string]$LockscreenImagePath,

    [string]$DesktopImagePath,

    [string]$OutputRoot,

    # Overwrite an existing package folder without asking for confirmation.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Everything below is wrapped in try/catch with an explicit exit code, so
# callers (including the GUI, which checks $LASTEXITCODE) can reliably tell
# success from failure - a script that merely runs off the end without
# calling exit leaves $LASTEXITCODE untouched.
try {

# ---------------------------------------------------------------------------
# 1. Collect and validate inputs (prompting interactively for anything missing
#    or invalid, so the tool works both as a wizard and as a scriptable call).
# ---------------------------------------------------------------------------

while (-not $CustomerName) {
    $CustomerName = Read-Host "Customer name (used in the ProgramData folder / registry path, e.g. 'Contoso')"
}
$CustomerName = $CustomerName.Trim()
$invalidCharPattern = '[' + [Regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join '')) + ']'
$sanitizedCustomer = ($CustomerName -replace $invalidCharPattern, '-')
if ($sanitizedCustomer -ne $CustomerName) {
    Write-Warning "Customer name contains characters that aren't safe in a file/registry path; using '$sanitizedCustomer' instead of '$CustomerName'."
}
$CustomerName = $sanitizedCustomer
if (-not $CustomerName) {
    throw "Customer name is empty after removing invalid characters."
}

while ($true) {
    if (-not $Version) { $Version = Read-Host "Version (e.g. 1.0)" }
    if ($Version -match '^\d+(\.\d+)+$') { break }
    Write-Warning "Version must be dot-separated numbers, e.g. '1.0' or '2.1.3'. Got: '$Version'"
    $Version = $null
}

while ($true) {
    if (-not $Mode) { $Mode = Read-Host "Mode - 'LockscreenOnly', 'BackgroundOnly' or 'Both'" }
    if ($Mode -in @('LockscreenOnly', 'BackgroundOnly', 'Both')) { break }
    Write-Warning "Mode must be 'LockscreenOnly', 'BackgroundOnly' or 'Both'. Got: '$Mode'"
    $Mode = $null
}
$wantsLockscreen = $Mode -in @('LockscreenOnly', 'Both')
$wantsBackground = $Mode -in @('BackgroundOnly', 'Both')

$validImageExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.gif')

function Resolve-ImagePath {
    param([string]$Path, [string]$PromptText)
    while ($true) {
        if (-not $Path) { $Path = Read-Host $PromptText }
        $resolved = $null
        try { $resolved = (Resolve-Path -Path $Path -ErrorAction Stop).ProviderPath } catch {}
        if ($resolved -and (Test-Path -Path $resolved -PathType Leaf)) {
            $ext = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
            if ($ext -in $validImageExtensions) { return $resolved }
            Write-Warning "'$resolved' doesn't look like an image (expected one of: $($validImageExtensions -join ', '))."
        }
        else {
            Write-Warning "File not found: $Path"
        }
        $Path = $null
    }
}

if ($wantsLockscreen) {
    $LockscreenImagePath = Resolve-ImagePath -Path $LockscreenImagePath -PromptText "Path to the lockscreen wallpaper image"
}
elseif ($LockscreenImagePath) {
    Write-Warning "Mode is '$Mode' - the supplied -LockscreenImagePath will be ignored."
    $LockscreenImagePath = $null
}

if ($wantsBackground) {
    $DesktopImagePath = Resolve-ImagePath -Path $DesktopImagePath -PromptText "Path to the background/desktop wallpaper image"
}
elseif ($DesktopImagePath) {
    Write-Warning "Mode is '$Mode' - the supplied -DesktopImagePath will be ignored."
    $DesktopImagePath = $null
}

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $PSScriptRoot 'Packages'
}

# ---------------------------------------------------------------------------
# 2. Locate the generic templates this generator stamps out per customer.
# ---------------------------------------------------------------------------

$TemplatesRoot = Join-Path $PSScriptRoot 'Templates'
$InstallTemplate   = Join-Path $TemplatesRoot 'Install.ps1'
$UninstallTemplate = Join-Path $TemplatesRoot 'Uninstall.ps1'
$DetectTemplate    = Join-Path $TemplatesRoot 'Detect.ps1.template'

foreach ($t in @($InstallTemplate, $UninstallTemplate, $DetectTemplate)) {
    if (-not (Test-Path $t)) { throw "Template not found: $t (expected alongside this script under Templates\)" }
}

# ---------------------------------------------------------------------------
# 3. Build the output package folder.
# ---------------------------------------------------------------------------

$PackageFolder = Join-Path (Join-Path $OutputRoot $CustomerName) "Package-v$Version"
$ImagesFolder  = Join-Path $PackageFolder 'Images'

if ((Test-Path (Join-Path $PackageFolder 'config.json')) -and -not $Force) {
    $answer = Read-Host "Package already exists at '$PackageFolder'. Overwrite? (y/N)"
    if ($answer -notmatch '^(?i)y(es)?$') {
        Write-Output "Cancelled - nothing was changed."
        exit 0
    }
}

New-Item -Path $ImagesFolder -ItemType Directory -Force | Out-Null

# --- Copy images under standardized, customer/version-stamped names ---
$lockscreenFileName = $null
if ($wantsLockscreen) {
    $lockExt = [IO.Path]::GetExtension($LockscreenImagePath)
    $lockscreenFileName = "$CustomerName-Lockscreen-v$Version$lockExt"
    Copy-Item -Path $LockscreenImagePath -Destination (Join-Path $ImagesFolder $lockscreenFileName) -Force
}

$desktopFileName = $null
if ($wantsBackground) {
    $desktopExt = [IO.Path]::GetExtension($DesktopImagePath)
    $desktopFileName = "$CustomerName-Desktop-v$Version$desktopExt"
    Copy-Item -Path $DesktopImagePath -Destination (Join-Path $ImagesFolder $desktopFileName) -Force
}

# --- config.json ---
$config = [ordered]@{
    CustomerName    = $CustomerName
    Version         = $Version
    Mode            = $Mode
    LockscreenImage = $lockscreenFileName
    DesktopImage    = $desktopFileName
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $PackageFolder 'config.json') -Encoding utf8

# --- Install.ps1 / Uninstall.ps1: copied as-is, they're generic ---
Copy-Item -Path $InstallTemplate   -Destination (Join-Path $PackageFolder 'Install.ps1')   -Force
Copy-Item -Path $UninstallTemplate -Destination (Join-Path $PackageFolder 'Uninstall.ps1') -Force

# --- Detect.ps1: generated from the template with CustomerName/Version baked in ---
(Get-Content -Path $DetectTemplate -Raw) `
    -replace '\{\{CUSTOMER_NAME\}\}', $CustomerName `
    -replace '\{\{VERSION\}\}', $Version |
    Set-Content -Path (Join-Path $PackageFolder 'Detect.ps1') -Encoding utf8

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------

$imageFiles = @()
if ($lockscreenFileName) { $imageFiles += "Images\$lockscreenFileName" }
if ($desktopFileName)    { $imageFiles += "Images\$desktopFileName" }

Write-Output ""
Write-Output "Package generated: $PackageFolder"
Write-Output "  Customer : $CustomerName"
Write-Output "  Version  : $Version"
Write-Output "  Mode     : $Mode"
Write-Output "  Files    : Install.ps1, Uninstall.ps1, Detect.ps1, config.json, $($imageFiles -join ', ')"
Write-Output ""
Write-Output "Next step - package it with the Win32 Content Prep Tool:"
Write-Output "  IntuneWinAppUtil.exe -c `"$PackageFolder`" -s `"Install.ps1`" -o `"$PackageFolder\Output`""
Write-Output ""
Write-Output "Intune app settings:"
Write-Output "  Install command   : powershell.exe -ExecutionPolicy Bypass -File Install.ps1"
Write-Output "  Uninstall command : powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1"
Write-Output "  Install behavior  : System"
Write-Output "  Detection rule    : Custom detection script -> Detect.ps1 (from this package folder)"

exit 0
}
catch {
    Write-Output "Package generation failed: $($_.Exception.Message)"
    exit 1
}
