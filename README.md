# Wallpaper Package Generator for Intune

Generate Intune Win32 app packages that deploy a lockscreen image, a desktop
background image, or both, enforced for every user on the device — with a
CLI and a GUI, for any number of customers, no internet access required.

![Wallpaper Package Generator GUI](docs/gui-screenshot.png)

## What it does

- Deploys the lockscreen image, the desktop background image, or both —
  your choice per package (`LockscreenOnly` / `BackgroundOnly` / `Both`).
- Applies to **every logged-in user** on the device via the Windows
  `Personalization` policy (`HKLM`), not a per-user setting — no user
  context needed at install time.
- **Multi-customer by design**: nothing is hardcoded. Customer name,
  version, mode and image files are all supplied per run, and the install
  location/registry path are namespaced under the customer's own name.
- **Versioned**: bump the version and re-run to publish an update: the
  generated detection script only reports "installed" for that exact
  version, so Intune knows to push the new one.
- Runs fully offline — no network access, no external dependencies beyond
  PowerShell itself.
- Two front-ends, one implementation: a command-line generator you can
  script, and a Windows Forms GUI that's a thin wrapper around it (no
  duplicated logic to keep in sync).

## How it works

The image(s) are deployed via the Windows **Personalization** policy
(`HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization`) — the same
registry location Group Policy and the Personalization CSP both use. Because
it's a machine-wide (`HKLM`) policy, the install script runs as SYSTEM (as
Intune Win32 apps do by default) and the image applies to every user who
logs onto the device, without needing to run in a per-user context.

Setting `*ImageStatus = 1` also **enforces** the image — users won't be able
to change it from Settings. That's expected/standard for this deployment
method.

## Requirements

- **Windows 10/11 Pro, Enterprise, or Education.** Windows Home does not
  honor this policy at all, regardless of what's in the registry — see
  [Troubleshooting](#troubleshooting).
- PowerShell 5.1+ to run the generator/GUI, and to run on the target device.
- [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
  (`IntuneWinAppUtil.exe`) to package the generated folder into `.intunewin`.
- An Intune/Endpoint Manager admin role to create the Win32 app.

## Project layout

```
IntuneWallpaperDeployment/
  New-WallpaperPackage.ps1      # CLI generator (shell, no GUI)
  New-WallpaperPackageGui.ps1   # GUI front-end for the same generator
  Templates/                     # generic script templates - edit these to
                                  # change behavior for ALL customers/packages
    Install.ps1
    Uninstall.ps1
    Detect.ps1.template
  Packages/                      # generator output (git-ignored), one folder
                                  # per customer:
    <CustomerName>/
      Package-v<Version>/
        Install.ps1
        Uninstall.ps1
        Detect.ps1
        config.json
        Images/
```

`Packages/` is where generated output lands and is excluded via
`.gitignore` — it's customer-specific data, not part of the tool.

## Quick start

Both tools run fully offline. They produce identical output — use whichever
you prefer.

### GUI

```powershell
.\New-WallpaperPackageGui.ps1
```

Enter the customer name and version, pick the mode with the radio buttons
(the image fields enable/disable to match), browse for the image file(s)
with a live thumbnail preview, then click **Generate Package**. The log
panel shows the generator's own output, and **Open Output Folder** jumps
straight to the result.

### CLI

**Interactive** — prompts for anything not supplied, re-prompts on invalid
input:

```powershell
.\New-WallpaperPackage.ps1
```

**Non-interactive** — for scripting or repeatable runs:

```powershell
# Lockscreen only
.\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.0 -Mode LockscreenOnly `
    -LockscreenImagePath C:\Art\Contoso-Lockscreen.png

# Background image only
.\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.0 -Mode BackgroundOnly `
    -DesktopImagePath C:\Art\Contoso-Desktop.png

# Both
.\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.1 -Mode Both `
    -LockscreenImagePath C:\Art\lock.png -DesktopImagePath C:\Art\desktop.png
```

| Parameter | Required | Notes |
|---|---|---|
| `-CustomerName` | yes | Used in the `ProgramData` folder name and registry path. Characters invalid in a file/registry name are stripped automatically (with a warning). |
| `-Version` | yes | Dot-separated numbers, e.g. `1.0`, `2.1.3`. |
| `-Mode` | yes | `LockscreenOnly`, `BackgroundOnly` or `Both`. |
| `-LockscreenImagePath` | only if `-Mode LockscreenOnly` or `Both` | Path to the lockscreen image (png/jpg/jpeg/bmp/gif). |
| `-DesktopImagePath` | only if `-Mode BackgroundOnly` or `Both` | Path to the background/desktop image. |
| `-OutputRoot` | no | Where `Packages\` gets created. Defaults to the folder this script lives in. |
| `-Force` | no | Skip the overwrite confirmation if the package folder already exists. |

Supplying an image path the chosen mode doesn't need is ignored (with a
warning), not an error.

Both tools copy the image(s) into `Images\` under a standardized name
(`<CustomerName>-Lockscreen-v<Version>.<ext>` /
`<CustomerName>-Desktop-v<Version>.<ext>`), write `config.json`, drop in the
generic `Install.ps1`/`Uninstall.ps1`, and generate `Detect.ps1` from the
template with `CustomerName`/`Version` baked in.

### Choosing the mode later / per group

`Install.ps1` also accepts `-Mode` on its own command line, overriding
`config.json`. So you can generate one package and deploy it as separate
Intune apps with different Install commands, e.g. if some groups should
only get the lockscreen update:

```
powershell.exe -ExecutionPolicy Bypass -File Install.ps1 -Mode LockscreenOnly
powershell.exe -ExecutionPolicy Bypass -File Install.ps1 -Mode BackgroundOnly
powershell.exe -ExecutionPolicy Bypass -File Install.ps1 -Mode Both
```

## Deploying to Intune

### 1. Package as `.intunewin`

```powershell
IntuneWinAppUtil.exe -c "Packages\<CustomerName>\Package-v<Version>" -s "Install.ps1" -o "Packages\<CustomerName>\Package-v<Version>\Output"
```

(Both tools print this exact command, with paths filled in, when they
finish.)

### 2. Create the Win32 app in Intune

Intune admin center → **Apps** → **Windows** → **Add** → **Windows app
(Win32)**.

**Program**
| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall.ps1` |
| Install behavior | System |

**Requirements**
- Minimum OS: Windows 10 1607 or later (adjust per your fleet)

**Detection rules**
- Rule format: **Use a custom detection script**
- Script file: `Detect.ps1` from the generated package folder

**Assignments**
- Assign to the desired device/user groups as **Required**.

### 3. Publishing a new version

Run the generator again with the new version and image — e.g.:

```powershell
.\New-WallpaperPackage.ps1 -CustomerName Contoso -Version 1.1 -Mode LockscreenOnly `
    -LockscreenImagePath C:\Art\Contoso-Lockscreen-v1.1.png
```

This produces a new `Packages\Contoso\Package-v1.1\` folder with `Detect.ps1`
baked to expect `Version = "1.1"`. Then either:

- Package it and, in the existing Intune app's **App info**, upload the new
  `Install.intunewin` to replace the package content and update the
  detection script to the new `Detect.ps1`, or
- Publish it as a new app and use Intune's **Supersedence** feature to
  replace the old version on assigned devices (cleaner rollback path).

Because `Detect.ps1` checks `Version` against the tracking registry key
(`HKLM\SOFTWARE\<CustomerName>\WallpaperDeployment`), any device still on the
old version is evaluated as "not installed" and Intune reinstalls with the
new package.

## Notes

- **Per-customer isolation**: install location is
  `%ProgramData%\<CustomerName>\WallpaperDeployment\`, and tracking state is
  `HKLM\SOFTWARE\<CustomerName>\WallpaperDeployment`. If that
  `ProgramData\<CustomerName>` folder already exists (e.g. from another app
  for the same customer), that's fine — creation uses `-Force` and only adds
  a `WallpaperDeployment` subfolder.
- Install/uninstall logs are written next to the cached images as
  `Install.log` / `Uninstall.log` for troubleshooting via Intune's app
  install status / IME logs.
- To change install/uninstall/detection *behavior* for every future package
  (all customers), edit the files under `Templates\` — don't hand-edit a
  generated package folder, since the next regeneration will overwrite it.

## Troubleshooting

**Lock screen still shows the Windows default after install succeeds and
the registry values look correct.**

1. Check Windows activation: **Settings → System → Activation**. An
   unactivated Windows installation blocks personalization (including a
   policy-enforced lock screen image) even when the registry values are
   set correctly — this is the most common cause. Activate and retry.
2. Verify by actually locking the screen (**Win+L**), not just by looking at
   the **Settings → Personalization → Lock screen** preview, which can be
   stale.
3. If the background type control in that Settings page isn't greyed out
   (forced to "Picture"), Windows isn't recognizing the policy yet — confirm
   you're on Pro/Enterprise/Education and that the values are under `HKLM`
   (not `HKCU`).
4. If it's greyed out/forced but still shows the wrong image even after
   activation, try a full reboot — Windows can cache a pre-rendered copy of
   the lock screen background and only regenerate it on certain triggers
   (sign-in, lock, or a Group Policy refresh), not on a raw registry write.

**GUI shows a `ValidateSet`/parameter error when generating.**

Make sure `New-WallpaperPackageGui.ps1` and `New-WallpaperPackage.ps1` are
from the same version of this repo — the GUI calls the CLI script by name
and passes parameters by name (hashtable splatting), so mismatched versions
of the two files can disagree on parameter names.
