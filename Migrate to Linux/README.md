# Migrate to Linux — Software, Settings & Driver Migration

Tooling to **inventory everything installed on a Windows PC**, rate each app for Linux compatibility, install all keepers unattended — **plus extract common Windows settings (power, display, keyboard, telemetry) and apply them on Linux, plus inventory every device driver and install the Linux equivalents (downloading firmware straight from the manufacturer via fwupd/LVFS)**.

One command runs the whole migration: [`Linux Mint (Ubuntu)/execute_all.sh`](Linux%20Mint%20%28Ubuntu%29/execute_all.sh) makes the three stage scripts executable and runs them in order — **settings → apps → drivers** — with a continue-on-error policy.

## Files

### Windows-side (run on Windows, in `Migrate to Linux/`)

| File | What it is |
|------|------------|
| [`detect_installed_windows_software.ps1`](detect_installed_windows_software.ps1) | PowerShell script: scans installed software, rates Linux compatibility, writes CSV. |
| [`installed_windows_software.csv`](installed_windows_software.csv) | Generated report (9 columns, one row per app). |
| [`detect_installed_drivers.ps1`](detect_installed_drivers.ps1) | PowerShell script: inventories **every device driver** (`Win32_PnPSignedDriver`), maps each to its Linux driver/module, writes CSV. |
| [`installed_windows_drivers.csv`](installed_windows_drivers.csv) | Generated driver report (12 columns, one row per device). |
| [`windows_settings_extract.ps1`](windows_settings_extract.ps1) | PowerShell script: extracts power/lid, display, keyboard, telemetry, and auto-update settings, writes `windows_configs.csv`. |
| [`windows_configs.csv`]() | Generated settings CSV (produced by `windows_settings_extract.ps1`). |
| [`instructions.txt`](instructions.txt) | Self-contained spec to **reproduce** all artifacts from scratch with fresh data. |

### Linux-side (run on the target machine, in `<Target OS>/`)

| File | What it is |
|------|------------|
| `Linux Mint (Ubuntu)/execute_all.sh` | **One-shot orchestrator** — `chmod +x`'s the three scripts and runs them in order (settings → apps → drivers), continue-on-error. |
| `Linux Mint (Ubuntu)/install_must_have_software.sh` | Unattended **root installer** — installs every app flagged `Must be included on Linux = yes`. |
| `Linux Mint (Ubuntu)/install_device_drivers.sh` | Unattended **root driver installer** — detects hardware live (lspci/lsusb/DMI), installs the matching Linux drivers, and pulls firmware from the manufacturer via fwupd/LVFS. |
| `Linux Mint (Ubuntu)/apply_settings.sh` | **Self-contained** settings runner — reads `../windows_configs.csv` and applies each setting via its built-in apply functions + dispatch table (no separate config file). |

### Directory layout

```text
Migrate to Linux/
├─ detect_installed_windows_software.ps1   # Windows: software inventory + Linux rating
├─ installed_windows_software.csv          # generated software report
├─ detect_installed_drivers.ps1            # Windows: device-driver inventory + Linux mapping
├─ installed_windows_drivers.csv           # generated driver report
├─ windows_settings_extract.ps1            # Windows: settings scraper
├─ windows_configs.csv                     # generated settings CSV
├─ settings_config.txt                     # human-readable mapping reference
├─ instructions.txt                        # reproducibility spec
├─ README.md
└─ Linux Mint (Ubuntu)/                    # one folder per target OS
   ├─ execute_all.sh                       # one-shot: settings → apps → drivers (continue-on-error)
   ├─ install_must_have_software.sh        # unattended software installer
   ├─ install_device_drivers.sh            # unattended driver installer (live detection + fwupd/LVFS)
   └─ apply_settings.sh                    # self-contained settings runner (functions + dispatch + runner)
```

Each subdirectory is named after a **target OS**; add a new target by creating a
folder and generating the scripts in it (see [`instructions.txt`](instructions.txt)).

---

## Workflow 0 — Run everything at once (recommended)

On the target Linux machine, after copying the three generated CSVs into
`Migrate to Linux/`, run the single orchestrator as root:

```bash
cd "Migrate to Linux/Linux Mint (Ubuntu)"
sudo ./execute_all.sh
```

It makes the three stage scripts executable and runs them **in order — settings →
apps → drivers — with a continue-on-error policy** (a failure in one stage is
recorded but never stops the others). Each stage keeps its own clean UI and logs;
`execute_all.sh` prints a per-stage OK/FAILED summary at the end and exits non-zero
if any stage failed. Prefer the individual workflows below when you want to run
just one stage.

## Workflow 1 — Migrate installed software

1. **Generate the report** — run `detect_installed_windows_software.ps1` on the Windows PC.
2. **Review** `installed_windows_software.csv` — especially the `Must be included on Linux` column.
3. **Install on Linux** — run `install_must_have_software.sh` as root.

## Workflow 2 — Migrate Windows settings

1. **Extract settings** — run `windows_settings_extract.ps1` on the Windows PC:
   ```powershell
   powershell -ExecutionPolicy Bypass -File windows_settings_extract.ps1
   ```
   This produces `windows_configs.csv`.
2. **Copy** `windows_configs.csv` to the `Migrate to Linux/` directory on the Linux machine.
3. **Apply** — from the distro directory, run as root:
   ```bash
   cd "Migrate to Linux/Linux Mint (Ubuntu)"
   sudo ./apply_settings.sh
   ```
   This reads `../windows_configs.csv` and applies (**to all users** — see note below):
   - **Power:** lid-close action (battery & AC) → `logind.conf`
   - **Display:** resolution → `xrandr`, scaling → system-wide dconf default
   - **Keyboard:** layout → `localectl` + `setxkbmap`, shortcut reference
   - **Telemetry:** disable `whoopsie`, `apport`, `apt-daily.timer`, `motd-news.timer`, etc.
   - **Location:** disable `geoclue`, MAC randomization, GNOME location (system-wide)
   - **Screen:** lock-screen / blank timeout → system-wide dconf (`"never"` disables lock & blanking)
   - **Auto-update:** install `system_update.service` + `system_update.timer` from the repo

   > **Applied to all users.** GNOME/desktop keys (scaling, location, lock-screen
   > timeout) are written as **system-wide dconf defaults** in `/etc/dconf/db/local.d`
   > — not `gsettings set` as root (which only touches root's own profile). Together
   > with the system-wide `logind`/`systemd`/`localectl`/APT changes, every setting
   > applies to **every user** on the machine (current and future) on next login.

## Workflow 3 — Migrate device drivers

1. **Generate the report** — run `detect_installed_drivers.ps1` on the Windows PC:
   ```powershell
   powershell -ExecutionPolicy Bypass -File detect_installed_drivers.ps1
   ```
   This enumerates every signed PnP driver (`Win32_PnPSignedDriver`) and writes
   `installed_windows_drivers.csv`, classifying each device for Linux.
2. **Copy** `installed_windows_drivers.csv` to the `Migrate to Linux/` directory on the Linux machine (optional — the installer also detects hardware live).
3. **Install on Linux** — from the distro directory, run as root:
   ```bash
   cd "Migrate to Linux/Linux Mint (Ubuntu)"
   sudo ./install_device_drivers.sh
   ```
   The installer **detects the hardware live** (lspci/lsusb/lscpu/DMI — the
   authoritative source, since Windows device names don't map cleanly to Linux
   modules), cross-references the CSV, then installs only what's needed:
   - **GPU:** NVIDIA proprietary driver (via `ubuntu-drivers`); AMD/Intel in-kernel + Mesa/VA-API.
   - **Network:** Realtek `r8168`/`r8125-dkms`, Broadcom `broadcom-sta-dkms`, Realtek USB-Wi-Fi DKMS; everything else is in-kernel + `linux-firmware`.
   - **CPU:** `intel-microcode` / `amd64-microcode`.
   - **Printers/scanners:** CUPS driverless + HPLIP (HP) + SANE.
   - **Fingerprint:** `fprintd` + `libfprint`.
   - **Manufacturer firmware:** `fwupd` + LVFS — downloads & flashes UEFI/SSD/dock/peripheral firmware straight from Lenovo/Dell/HP/Intel/etc.
   - **Optional vendor installers:** NVIDIA `.run` (nvidia.com) / AMDGPU-PRO (amd.com) via a skippable prompt at the end.

---

## Quick start — Software inventory

```powershell
# From the Migrate to Linux/ folder, in PowerShell 5.1 or PowerShell 7+:
.\detect_installed_windows_software.ps1
```

No administrator rights required.

### Options

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-OutputPath <path>` | `installed_windows_software.csv` (beside the script) | Where to write the CSV. |
| `-MustIncludeThreshold <int>` | `70` | Minimum *Alternative Competency* (%) for **Must be included on Linux = yes**. |
| `-IncludeSystemComponents` | off | Keep redistributables, runtimes and drivers. |
| `-IncludeStoreApps <bool>` | `$true` | Include filtered Microsoft Store/UWP apps. |
| `-Online` | off | Query repology.org live for unknown apps. |

### The CSV columns (software inventory)

| Column | Source | Meaning |
|--------|--------|---------|
| **Name** | from PC | Human-friendly product name. |
| **Version** | from PC | Installed version. |
| **Publisher** | from PC | Vendor. |
| **Source** | from PC | `Win32` (registry) or `Store` (UWP/Appx). |
| **Linux Availability** | curated | Flags: Available on Linux, Native Alternative, Available as WebApp, etc. |
| **Best Linux Alternative** | curated | The best Linux option. Free alt appended if paid. |
| **Alternative Competency** | curated | Rough % vs Windows (≥100 = Linux is better). |
| **Pricing model** | curated | Free (FOSS), Free, Freemium, Shareware, or Paid. |
| **Must be included on Linux** | derived | `yes` / `no` — computed from competency threshold. |

### The CSV columns (settings migration — `windows_configs.csv`)

| Column | Source | Meaning |
|--------|--------|---------|
| **Category** | from PC | `Power`, `Display`, `Keyboard`, `Telemetry`, `AutoUpdate`, `Screen`. |
| **ConfigKey** | from PC | Specific setting key (e.g. `lid_close_on_ac`, `resolution`, `lock_screen_timeout`). |
| **WindowsValue** | from PC | The extracted value (e.g. `sleep`, `1920x1080`, `10 min` / `never`). |
| **LinuxCommand** | from PC | Input language tags for keyboard mapping (optional). |
| **Notes** | from PC | Human-readable note about the Linux mapping. |

### The CSV columns (driver inventory — `installed_windows_drivers.csv`)

Generate with `.\detect_installed_drivers.ps1` (no admin rights). Switches:
`-IncludeVirtualDevices` keeps `ROOT\`/`SW\`/`SWD\` software devices;
`-IncludeMicrosoftInbox` keeps generic Microsoft in-box drivers that need no Linux action.

| Column | Source | Meaning |
|--------|--------|---------|
| **Device Name** | from PC | The PnP device's friendly name. |
| **Device Class** | from PC | PnP class (`Display`, `Net`, `Bluetooth`, `Printer`, …). |
| **Manufacturer** | from PC | Device manufacturer. |
| **Driver Version** | from PC | Installed driver version. |
| **Driver Date** | from PC | Driver date (`yyyy-MM-dd`). |
| **Driver Provider** | from PC | Who signs/provides the driver (NVIDIA, Microsoft, …). |
| **Hardware ID** | from PC | Bus ID (`PCI\VEN_10DE&DEV_…` / `USB\VID_…&PID_…`) — the reliable key to the silicon. |
| **Linux Driver Status** | curated | Flags: In-Kernel, Generic Driver, Firmware Required, Kernel Module (DKMS), Proprietary Driver, Vendor Driver, Not Applicable, Needs Review. |
| **Linux Driver / Module** | curated | The kernel module or package (`amdgpu`, `iwlwifi`, `nvidia-driver-NNN`, `r8168-dkms`, `hplip`, …). |
| **Vendor Download** | curated | Manufacturer's Linux driver page, filled only when a vendor download is needed. |
| **Notes** | curated | Short note about the Linux situation. |
| **Must install on Linux** | derived | `yes` when the device needs an actively-installed driver (proprietary / DKMS / vendor); `no` when the in-box kernel + base `linux-firmware` already cover it. |

---

## How the Linux ratings are sourced

Recommendations are **researched from the web** and baked into the `$LinuxKB` array in
`detect_installed_windows_software.ps1`. To adjust a rating or add a new app, edit that
table and re-run. The optional `-Online` mode fills *unknown* apps via the Repology API.

For drivers, the mapping lives in the `$DriverKB` rule table in
`detect_installed_drivers.ps1`. Each device is classified from its **PnP class** and
the **PCI/USB vendor ID** embedded in its Hardware ID (first matching rule wins). To
re-rate a device or add a new chip, edit that table and re-run.

---

## Settings migration — structured output

When `apply_settings.sh` runs, every `_apply_*` function produces structured lines:

```
[INFO]  Windows 'sleep' → logind HandleLidSwitch=suspend
[OK]    removed old HandleLidSwitch= from logind.conf
[OK]    wrote HandleLidSwitch=suspend → /etc/systemd/logind.conf
[OK]    wrote /etc/systemd/logind.conf.d/50-migrate-lid.conf
[OK]    restarted systemd-logind

[INFO]  disabling Linux telemetry...
[OK]    disabled & masked: whoopsie
[INFO]  not present: apport
[OK]    disabled ESM hook
[OK]    purged: ubuntu-report

[ERROR] xrandr not available or no monitors
```

A summary prints at the end showing OK / Failed / Info-only counts.

---

## Installing on Linux — Software

```bash
# For Linux Mint / Ubuntu:
sudo ./"Linux Mint (Ubuntu)/install_must_have_software.sh"
```

The installer is **unattended and idempotent**, with a clean progress display,
auto-detection of the target machine (codename + architecture), and two log files.

**PaperCut (hard-coded — the native client, never a substitute).** PaperCut's Linux
client (Print Deploy / User Client) is served by **your own PaperCut server**, which is
the trusted first-party source for it. Set `PAPERCUT_SERVER` (host) and optionally
`PAPERCUT_PORT` (default `9174`) at the top of the script — or as env vars — to install
it **unattended**:

```bash
sudo PAPERCUT_SERVER=printdeploy.example.com ./install_must_have_software.sh
```

If `PAPERCUT_SERVER` is not set (or the auto-download fails), the installer **defers to
the manual prompt at the end** and asks for the Linux client `.tar.gz` downloaded from
your server's client page (`https://<server>:9174`). Either way the **native PaperCut
client is installed — CUPS is never substituted**.

At the end of the automated installation, the script **prompts** the user to import
fonts from a directory. The font import mechanism:

1. Asks for a directory path containing font files (read from `/dev/tty`).
2. Recursively finds all font files in that directory (supports **all common font formats**:
   `.ttf`, `.otf`, `.ttc`, `.woff`, `.woff2`, `.pfa`, `.pfb`, `.afm`, `.pfm`, `.dfont`,
   `.otb`, `.bdf`, `.pcf`, `.gsf`, `.otc`, `.abf`, `.chr`, `.fnt`, `.mxf` —
   covering Windows, macOS, and Linux font types).
3. Copies them to `/usr/local/share/fonts/user-import/`.
4. Runs `fc-cache` to rebuild the font cache so applications (including Wine) see them.
5. Records the result (OK/SKIP/FAIL) in the results log.

Error handling:
- Non-existent or unreadable directory → reprompt or type `skip`.
- Directory contains no matching font files → warn and reprompt.
- Individual file copy failures → skip that file, continue with the rest.
- No tty (non-interactive environment) → skip silently.

---

## Installing on Linux — Settings

```bash
# For Linux Mint / Ubuntu:
cd "Linux Mint (Ubuntu)"
sudo ./apply_settings.sh
```

Runs as root. Prints structured output per setting, and **applies every setting to
all users** (GNOME keys via system-wide dconf defaults; the rest are system-wide by
nature). A reboot / re-login is recommended afterwards (display scaling, lock-screen
timeout, logind changes).

---

## Installing on Linux — Drivers

```bash
# For Linux Mint / Ubuntu:
cd "Linux Mint (Ubuntu)"
sudo ./install_device_drivers.sh
```

Runs as root with the same clean UI, spinner, and two log files as the software
installer. It **detects hardware live** and only installs what's actually present,
so it is safe to run on any machine — absent hardware is recorded as *skipped*, not
failed. Highlights:

- **In-kernel by default:** most devices (Intel/Atheros/MediaTek Wi-Fi, Bluetooth,
  audio, webcams, NVMe, USB, HID) need nothing beyond the kernel + `linux-firmware`.
- **Actively installed when needed:** NVIDIA proprietary driver, Realtek/Broadcom
  DKMS modules, CPU microcode, HPLIP, fprintd.
- **Manufacturer firmware:** `fwupd` refreshes the **LVFS** remote and flashes UEFI/
  SSD/dock firmware uploaded and signed by the vendors themselves.
- **Secure Boot aware:** warns when MOK enrollment is needed for DKMS/NVIDIA modules.
- **Optional vendor `.run`/PRO installers** are offered last via a skippable prompt.

A **reboot is strongly recommended** after a driver run (GPU/DKMS modules,
microcode, firmware flash).

---

## Reproducing everything from scratch

[`instructions.txt`](instructions.txt) is a self-contained specification: an AI engine
can read it alone and regenerate all PowerShell scripts, the CSVs, and each target-OS
installer with freshly-researched data. It includes **PART D — Settings Migration Spec**
and **PART E — Device Driver Migration Spec** (plus the `execute_all.sh` orchestrator).

## Caveats

- **Competency is a deliberate rough estimate** for planning, not a benchmark.
- Ratings reflect the Linux landscape as of **June 2026** and will drift.
- Display resolution may not be replicable on different hardware.
- The per-distro scripts (`execute_all.sh`, `install_*`, `apply_settings.sh`) live
  **per distro directory** (e.g. `Linux Mint (Ubuntu)/`) — each target OS gets its
  own copy. `apply_settings.sh` is now a single self-contained file (the former
  `settings_config.sh` has been merged into it).
- **Drivers are detected live on Linux**, not transcribed from Windows: the
  `installed_windows_drivers.csv` is a cross-reference, while `lspci`/`lsusb`/DMI on
  the actual machine are authoritative (Windows device names don't map cleanly to
  Linux modules).

## Requirements

**Windows (inventory + settings extract):**
- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access only for `-Online` mode

**Linux (installers + settings apply):**
- Linux Mint or Ubuntu (APT base), run as **root**
- Internet access for repo/vendor/firmware downloads
- For settings: `xrandr`, `gsettings`, `localectl`, `systemctl` (all standard)
- For drivers: `pciutils`, `usbutils`, `ubuntu-drivers-common`, `dkms`, `fwupd`
  (the installer pulls these itself); kernel headers for the running kernel
