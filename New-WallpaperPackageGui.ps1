<#
    New-WallpaperPackageGui.ps1
    Windows Forms front-end for New-WallpaperPackage.ps1. Offline, no
    internet access required. This is a thin wrapper: all the actual
    validation/generation logic lives in New-WallpaperPackage.ps1 (the CLI
    tool), which this GUI calls with -Force after confirming inputs and any
    overwrite itself, so it never blocks on a console prompt.
#>

# Windows Forms needs an STA thread. powershell.exe defaults to STA, but
# pwsh (PowerShell 7) defaults to MTA, so relaunch under the same host with
# -STA if we're not already running in it.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $hostExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$GeneratorScript = Join-Path $PSScriptRoot 'New-WallpaperPackage.ps1'
if (-not (Test-Path $GeneratorScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Can't find New-WallpaperPackage.ps1 next to this GUI script:`n$GeneratorScript",
        'Wallpaper Package Generator', 'OK', 'Error') | Out-Null
    exit 1
}

$IntuneWinAppUtilPath = Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe'
$IntuneWinAppUtilDownloadUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool'
$script:IntuneWinAppUtilFound = Test-Path -Path $IntuneWinAppUtilPath -PathType Leaf

$validImageExtensions = @('.png', '.jpg', '.jpeg', '.bmp', '.gif')
$invalidCharPattern = '[' + [Regex]::Escape(([IO.Path]::GetInvalidFileNameChars() -join '')) + ']'
$script:lastGeneratedFolder = $null

function Get-SanitizedCustomerName {
    param([string]$Name)
    return ($Name.Trim() -replace $invalidCharPattern, '-')
}

function Set-PreviewImage {
    param([System.Windows.Forms.PictureBox]$PictureBox, [string]$Path)
    if ($PictureBox.Image) {
        $PictureBox.Image.Dispose()
        $PictureBox.Image = $null
    }
    if ($Path -and (Test-Path -Path $Path -PathType Leaf)) {
        try {
            $bytes = [IO.File]::ReadAllBytes($Path)
            $ms = New-Object System.IO.MemoryStream(, $bytes)
            $temp = [System.Drawing.Image]::FromStream($ms)
            $PictureBox.Image = New-Object System.Drawing.Bitmap($temp)
            $temp.Dispose()
            $ms.Dispose()
        } catch {
            $PictureBox.Image = $null
        }
    }
}

# ---------------------------------------------------------------------------
# Form layout
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Wallpaper Package Generator'
$form.Size = New-Object System.Drawing.Size(650, 720)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$labelFont = New-Object System.Drawing.Font('Segoe UI', 9)
$hintFont  = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)

# --- Customer name ---
$lblCustomer = New-Object System.Windows.Forms.Label
$lblCustomer.Text = 'Customer name:'
$lblCustomer.Location = New-Object System.Drawing.Point(15, 18)
$lblCustomer.Size = New-Object System.Drawing.Size(120, 20)
$lblCustomer.Font = $labelFont

$txtCustomer = New-Object System.Windows.Forms.TextBox
$txtCustomer.Location = New-Object System.Drawing.Point(145, 15)
$txtCustomer.Size = New-Object System.Drawing.Size(200, 22)

$lblCustomerPreview = New-Object System.Windows.Forms.Label
$lblCustomerPreview.Location = New-Object System.Drawing.Point(355, 18)
$lblCustomerPreview.Size = New-Object System.Drawing.Size(270, 20)
$lblCustomerPreview.Font = $hintFont
$lblCustomerPreview.ForeColor = [System.Drawing.Color]::DimGray

$txtCustomer.Add_TextChanged({
    $sanitized = Get-SanitizedCustomerName -Name $txtCustomer.Text
    if ($sanitized -and $sanitized -ne $txtCustomer.Text.Trim()) {
        $lblCustomerPreview.Text = "Will use: $sanitized"
    } else {
        $lblCustomerPreview.Text = ''
    }
})

# --- Version ---
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = 'Version:'
$lblVersion.Location = New-Object System.Drawing.Point(15, 50)
$lblVersion.Size = New-Object System.Drawing.Size(120, 20)
$lblVersion.Font = $labelFont

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Location = New-Object System.Drawing.Point(145, 47)
$txtVersion.Size = New-Object System.Drawing.Size(100, 22)

$lblVersionHint = New-Object System.Windows.Forms.Label
$lblVersionHint.Text = 'e.g. 1.0'
$lblVersionHint.Location = New-Object System.Drawing.Point(255, 50)
$lblVersionHint.Size = New-Object System.Drawing.Size(120, 20)
$lblVersionHint.Font = $hintFont
$lblVersionHint.ForeColor = [System.Drawing.Color]::DimGray

# --- Mode ---
$grpMode = New-Object System.Windows.Forms.GroupBox
$grpMode.Text = 'Mode'
$grpMode.Location = New-Object System.Drawing.Point(15, 80)
$grpMode.Size = New-Object System.Drawing.Size(610, 50)

$rbLockscreen = New-Object System.Windows.Forms.RadioButton
$rbLockscreen.Text = 'Lockscreen only'
$rbLockscreen.Location = New-Object System.Drawing.Point(15, 20)
$rbLockscreen.Size = New-Object System.Drawing.Size(150, 22)
$rbLockscreen.Checked = $true

$rbBackground = New-Object System.Windows.Forms.RadioButton
$rbBackground.Text = 'Background image only'
$rbBackground.Location = New-Object System.Drawing.Point(180, 20)
$rbBackground.Size = New-Object System.Drawing.Size(170, 22)

$rbBoth = New-Object System.Windows.Forms.RadioButton
$rbBoth.Text = 'Both'
$rbBoth.Location = New-Object System.Drawing.Point(360, 20)
$rbBoth.Size = New-Object System.Drawing.Size(100, 22)

$grpMode.Controls.AddRange(@($rbLockscreen, $rbBackground, $rbBoth))

# --- Lockscreen image ---
$lblLockscreen = New-Object System.Windows.Forms.Label
$lblLockscreen.Text = 'Lockscreen image:'
$lblLockscreen.Location = New-Object System.Drawing.Point(15, 145)
$lblLockscreen.Size = New-Object System.Drawing.Size(120, 20)
$lblLockscreen.Font = $labelFont

$txtLockscreen = New-Object System.Windows.Forms.TextBox
$txtLockscreen.Location = New-Object System.Drawing.Point(145, 142)
$txtLockscreen.Size = New-Object System.Drawing.Size(340, 22)
$txtLockscreen.ReadOnly = $true

$btnBrowseLockscreen = New-Object System.Windows.Forms.Button
$btnBrowseLockscreen.Text = 'Browse...'
$btnBrowseLockscreen.Location = New-Object System.Drawing.Point(490, 141)
$btnBrowseLockscreen.Size = New-Object System.Drawing.Size(90, 24)

$picLockscreen = New-Object System.Windows.Forms.PictureBox
$picLockscreen.Location = New-Object System.Drawing.Point(145, 170)
$picLockscreen.Size = New-Object System.Drawing.Size(160, 90)
$picLockscreen.BorderStyle = 'FixedSingle'
$picLockscreen.SizeMode = 'Zoom'

# --- Background image ---
$lblDesktop = New-Object System.Windows.Forms.Label
$lblDesktop.Text = 'Background image:'
$lblDesktop.Location = New-Object System.Drawing.Point(15, 275)
$lblDesktop.Size = New-Object System.Drawing.Size(120, 20)
$lblDesktop.Font = $labelFont

$txtDesktop = New-Object System.Windows.Forms.TextBox
$txtDesktop.Location = New-Object System.Drawing.Point(145, 272)
$txtDesktop.Size = New-Object System.Drawing.Size(340, 22)
$txtDesktop.ReadOnly = $true
$txtDesktop.Enabled = $false

$btnBrowseDesktop = New-Object System.Windows.Forms.Button
$btnBrowseDesktop.Text = 'Browse...'
$btnBrowseDesktop.Location = New-Object System.Drawing.Point(490, 271)
$btnBrowseDesktop.Size = New-Object System.Drawing.Size(90, 24)
$btnBrowseDesktop.Enabled = $false

$picDesktop = New-Object System.Windows.Forms.PictureBox
$picDesktop.Location = New-Object System.Drawing.Point(145, 300)
$picDesktop.Size = New-Object System.Drawing.Size(160, 90)
$picDesktop.BorderStyle = 'FixedSingle'
$picDesktop.SizeMode = 'Zoom'

# --- Output folder ---
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = 'Output folder:'
$lblOutput.Location = New-Object System.Drawing.Point(15, 405)
$lblOutput.Size = New-Object System.Drawing.Size(120, 20)
$lblOutput.Font = $labelFont

$txtOutputRoot = New-Object System.Windows.Forms.TextBox
$txtOutputRoot.Location = New-Object System.Drawing.Point(145, 402)
$txtOutputRoot.Size = New-Object System.Drawing.Size(340, 22)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text = 'Browse...'
$btnBrowseOutput.Location = New-Object System.Drawing.Point(490, 401)
$btnBrowseOutput.Size = New-Object System.Drawing.Size(90, 24)

$lblOutputHint = New-Object System.Windows.Forms.Label
$lblOutputHint.Text = "Leave blank to use '$PSScriptRoot\Packages'"
$lblOutputHint.Location = New-Object System.Drawing.Point(145, 426)
$lblOutputHint.Size = New-Object System.Drawing.Size(460, 18)
$lblOutputHint.Font = $hintFont
$lblOutputHint.ForeColor = [System.Drawing.Color]::DimGray

# --- Generate button ---
$btnGenerate = New-Object System.Windows.Forms.Button
$btnGenerate.Text = 'Generate Package'
$btnGenerate.Location = New-Object System.Drawing.Point(15, 455)
$btnGenerate.Size = New-Object System.Drawing.Size(160, 32)
$btnGenerate.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = 'Open Output Folder'
$btnOpenFolder.Location = New-Object System.Drawing.Point(185, 455)
$btnOpenFolder.Size = New-Object System.Drawing.Size(160, 32)
$btnOpenFolder.Enabled = $false

$btnCreateIntunewin = New-Object System.Windows.Forms.Button
$btnCreateIntunewin.Text = 'Create .intunewin'
$btnCreateIntunewin.Location = New-Object System.Drawing.Point(355, 455)
$btnCreateIntunewin.Size = New-Object System.Drawing.Size(160, 32)
$btnCreateIntunewin.Enabled = $false

$lnkDownloadTool = New-Object System.Windows.Forms.LinkLabel
$lnkDownloadTool.Text = 'IntuneWinAppUtil.exe not found here - click to download it'
$lnkDownloadTool.Location = New-Object System.Drawing.Point(355, 489)
$lnkDownloadTool.Size = New-Object System.Drawing.Size(260, 16)
$lnkDownloadTool.Font = $hintFont
$lnkDownloadTool.Visible = -not $script:IntuneWinAppUtilFound

# --- Log panel ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Log:'
$lblLog.Location = New-Object System.Drawing.Point(15, 513)
$lblLog.Size = New-Object System.Drawing.Size(120, 20)
$lblLog.Font = $labelFont

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 535)
$txtLog.Size = New-Object System.Drawing.Size(605, 130)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtLog.Anchor = 'Top,Bottom,Left,Right'

$form.Controls.AddRange(@(
    $lblCustomer, $txtCustomer, $lblCustomerPreview,
    $lblVersion, $txtVersion, $lblVersionHint,
    $grpMode,
    $lblLockscreen, $txtLockscreen, $btnBrowseLockscreen, $picLockscreen,
    $lblDesktop, $txtDesktop, $btnBrowseDesktop, $picDesktop,
    $lblOutput, $txtOutputRoot, $btnBrowseOutput, $lblOutputHint,
    $btnGenerate, $btnOpenFolder, $btnCreateIntunewin, $lnkDownloadTool,
    $lblLog, $txtLog
))

# ---------------------------------------------------------------------------
# Behavior
# ---------------------------------------------------------------------------

function Update-ModeUI {
    $wantsLockscreen = $rbLockscreen.Checked -or $rbBoth.Checked
    $wantsBackground = $rbBackground.Checked -or $rbBoth.Checked

    $txtLockscreen.Enabled = $wantsLockscreen
    $btnBrowseLockscreen.Enabled = $wantsLockscreen
    $picLockscreen.Enabled = $wantsLockscreen

    $txtDesktop.Enabled = $wantsBackground
    $btnBrowseDesktop.Enabled = $wantsBackground
    $picDesktop.Enabled = $wantsBackground
}

$rbLockscreen.Add_CheckedChanged({ Update-ModeUI })
$rbBackground.Add_CheckedChanged({ Update-ModeUI })
$rbBoth.Add_CheckedChanged({ Update-ModeUI })

$btnBrowseLockscreen.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtLockscreen.Text = $dlg.FileName
        Set-PreviewImage -PictureBox $picLockscreen -Path $dlg.FileName
    }
})

$btnBrowseDesktop.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp;*.gif|All files|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtDesktop.Text = $dlg.FileName
        Set-PreviewImage -PictureBox $picDesktop -Path $dlg.FileName
    }
})

$btnBrowseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtOutputRoot.Text = $dlg.SelectedPath
    }
})

$btnOpenFolder.Add_Click({
    if ($script:lastGeneratedFolder -and (Test-Path $script:lastGeneratedFolder)) {
        Start-Process explorer.exe $script:lastGeneratedFolder
    }
})

$lnkDownloadTool.Add_LinkClicked({
    Start-Process $IntuneWinAppUtilDownloadUrl
})

function Write-Log {
    param([string]$Text)
    $txtLog.AppendText($Text + [Environment]::NewLine)
}

# Create .intunewin is only ever enabled when the tool is present AND a
# package has actually been generated - the "not found" link is the only
# thing shown otherwise, so clicking a live-but-pointless button never happens.
function Update-CreateIntunewinUI {
    $btnCreateIntunewin.Enabled = $script:IntuneWinAppUtilFound -and [bool]$script:lastGeneratedFolder -and (Test-Path $script:lastGeneratedFolder)
}

$btnCreateIntunewin.Add_Click({
    if (-not $script:lastGeneratedFolder -or -not (Test-Path $script:lastGeneratedFolder)) {
        [System.Windows.Forms.MessageBox]::Show('Generate a package first.', 'Wallpaper Package Generator', 'OK', 'Warning') | Out-Null
        return
    }

    $outputDir = Join-Path $script:lastGeneratedFolder 'Output'
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null

    Write-Log "--- Creating .intunewin package ---"
    $form.Cursor = 'WaitCursor'
    $btnCreateIntunewin.Enabled = $false
    try {
        # -q (quiet): without it, IntuneWinAppUtil.exe waits for a keypress
        # after finishing, which would hang this GUI forever since there's
        # no console attached to send one.
        $output = & $IntuneWinAppUtilPath -c $script:lastGeneratedFolder -s 'Install.ps1' -o $outputDir -q 2>&1
        Write-Log ($output | Out-String).TrimEnd()

        $expectedIntunewin = Join-Path $outputDir 'Install.intunewin'
        if (Test-Path $expectedIntunewin) {
            [System.Windows.Forms.MessageBox]::Show("Created:`n$expectedIntunewin", 'Wallpaper Package Generator', 'OK', 'Information') | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('IntuneWinAppUtil.exe did not produce the expected .intunewin file - see the log.', 'Wallpaper Package Generator', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        $form.Cursor = 'Default'
        Update-CreateIntunewinUI
    }
})

$btnGenerate.Add_Click({
    $btnOpenFolder.Enabled = $false

    $customerName = Get-SanitizedCustomerName -Name $txtCustomer.Text
    if (-not $customerName) {
        [System.Windows.Forms.MessageBox]::Show('Enter a customer name.', 'Wallpaper Package Generator', 'OK', 'Warning') | Out-Null
        return
    }

    $version = $txtVersion.Text.Trim()
    if ($version -notmatch '^\d+(\.\d+)+$') {
        [System.Windows.Forms.MessageBox]::Show("Version must be dot-separated numbers, e.g. '1.0' or '2.1.3'.", 'Wallpaper Package Generator', 'OK', 'Warning') | Out-Null
        return
    }

    if ($rbLockscreen.Checked) { $mode = 'LockscreenOnly' }
    elseif ($rbBackground.Checked) { $mode = 'BackgroundOnly' }
    else { $mode = 'Both' }
    $wantsLockscreen = $mode -in @('LockscreenOnly', 'Both')
    $wantsBackground = $mode -in @('BackgroundOnly', 'Both')

    if ($wantsLockscreen) {
        $lockPath = $txtLockscreen.Text.Trim()
        if (-not $lockPath -or -not (Test-Path -Path $lockPath -PathType Leaf) -or ([IO.Path]::GetExtension($lockPath).ToLowerInvariant() -notin $validImageExtensions)) {
            [System.Windows.Forms.MessageBox]::Show('Choose a valid lockscreen image file.', 'Wallpaper Package Generator', 'OK', 'Warning') | Out-Null
            return
        }
    }

    if ($wantsBackground) {
        $desktopPath = $txtDesktop.Text.Trim()
        if (-not $desktopPath -or -not (Test-Path -Path $desktopPath -PathType Leaf) -or ([IO.Path]::GetExtension($desktopPath).ToLowerInvariant() -notin $validImageExtensions)) {
            [System.Windows.Forms.MessageBox]::Show('Choose a valid background image file.', 'Wallpaper Package Generator', 'OK', 'Warning') | Out-Null
            return
        }
    }

    $outputRoot = $txtOutputRoot.Text.Trim()
    if (-not $outputRoot) {
        $outputRoot = Join-Path $PSScriptRoot 'Packages'
    }

    # Mirrors New-WallpaperPackage.ps1's own path-building logic, so this
    # matches exactly where the generator will write the package.
    $expectedPackageFolder = Join-Path (Join-Path $outputRoot $customerName) "Package-v$version"
    if (Test-Path (Join-Path $expectedPackageFolder 'config.json')) {
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Package already exists at:`n$expectedPackageFolder`n`nOverwrite it?",
            'Wallpaper Package Generator', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') {
            Write-Log "Cancelled - '$expectedPackageFolder' was not changed."
            return
        }
    }

    # Hashtable splatting (binds by name) - NOT array splatting, which binds
    # purely positionally and would silently misalign onto the wrong parameters.
    $genParams = @{
        CustomerName = $customerName
        Version      = $version
        Mode         = $mode
        OutputRoot   = $outputRoot
        Force        = $true
    }
    if ($wantsLockscreen) { $genParams['LockscreenImagePath'] = $lockPath }
    if ($wantsBackground) { $genParams['DesktopImagePath'] = $desktopPath }

    Write-Log "--- Generating: $customerName v$version ($mode) ---"
    $form.Cursor = 'WaitCursor'
    $btnGenerate.Enabled = $false
    try {
        $output = & $GeneratorScript @genParams 2>&1
        Write-Log ($output | Out-String).TrimEnd()

        if ($LASTEXITCODE -eq 0) {
            $script:lastGeneratedFolder = $expectedPackageFolder
            $btnOpenFolder.Enabled = $true
            Update-CreateIntunewinUI
            [System.Windows.Forms.MessageBox]::Show("Package generated:`n$expectedPackageFolder", 'Wallpaper Package Generator', 'OK', 'Information') | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('Package generation failed - see the log for details.', 'Wallpaper Package Generator', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        $form.Cursor = 'Default'
        $btnGenerate.Enabled = $true
    }
})

Update-ModeUI
Update-CreateIntunewinUI
[void]$form.ShowDialog()
