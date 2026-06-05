# Migrate to Linux — Software Audit & Settings Migration

Tooling to **inventory everything installed on a Windows PC**, rate each app for Linux compatibility, install all keepers unattended — **plus extract common Windows settings (power, display, keyboard, telemetry) and apply them on Linux**.

## Files

### Windows-side (run on Windows, in `Migrate to Linux/`)

| File | What it is |
|------|------------|
| [`detect_installed_windows_software.ps1`](detect_installed_windows_software.ps1) | PowerShell script: scans installed software, rates Linux compatibility, writes CSV. |
| [`installed_windows_software.csv`](installed_windows_software.csv) | Generated report (9 columns, one row per app). |
| [`windows_settings_extract.ps1`](windows_settings_extract.ps1) | PowerShell script: extracts power/lid, display, keyboard, telemetry, and auto-update settings, writes `windows_configs.csv`. |
| [`windows_configs.csv`]() | Generated settings CSV (produced by `windows_settings_extract.ps1`). |
| [`instructions.txt`](instructions.txt) | Self-contained spec to **reproduce** all artifacts from scratch with fresh data. |

### Linux-side (run on the target machine, in `<Target OS>/`)

| File | What it is |
|------|------------|
| `Linux Mint (Ubuntu)/install_must_have_software.sh` | Unattended **root installer** — installs every app flagged `Must be included on Linux = yes`. |
| `Linux Mint (Ubuntu)/settings_config.sh` | Per-distro settings apply functions + dispatch table (sourced by `apply_settings.sh`). |
| `Linux Mint (Ubuntu)/apply_settings.sh` | Main runner: reads `../windows_configs.csv`, applies each setting via the dispatch table. |

### Directory layout

```text
Migrate to Linux/
├─ detect_installed_windows_software.ps1   # Windows: inventory + Linux rating
├─ installed_windows_software.csv          # generated report
├─ windows_settings_extract.ps1            # Windows: settings scraper
├─ windows_configs.csv                     # generated settings CSV
├─ settings_config.txt                     # human-readable mapping reference
├─ instructions.txt                        # reproducibility spec
├─ README.md
└─ Linux Mint (Ubuntu)/                    # one folder per target OS
   ├─ install_must_have_software.sh        # unattended software installer
   ├─ settings_config.sh                   # per-distro settings apply functions
   └─ apply_settings.sh                    # settings migration runner
```

Each subdirectory is named after a **target OS**; add a new target by creating a
folder and generating the scripts in it (see [`instructions.txt`](instructions.txt)).

---

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
   This reads `../windows_configs.csv` and applies:
   - **Power:** lid-close action (battery & AC) → `logind.conf`
   - **Display:** resolution → `xrandr`, scaling → `gsettings`
   - **Keyboard:** layout → `localectl` + `setxkbmap`, shortcut reference
   - **Telemetry:** disable `whoopsie`, `apport`, `apt-daily.timer`, `motd-news.timer`, etc.
   - **Location:** disable `geoclue`, MAC randomization
   - **Auto-update:** install `system_update.service` + `system_update.timer` from the repo

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
| **Category** | from PC | `Power`, `Display`, `Keyboard`, `Telemetry`, `AutoUpdate`. |
| **ConfigKey** | from PC | Specific setting key (e.g. `lid_close_on_ac`, `resolution`). |
| **WindowsValue** | from PC | The extracted value (e.g. `sleep`, `1920x1080`). |
| **LinuxCommand** | from PC | Input language tags for keyboard mapping (optional). |
| **Notes** | from PC | Human-readable note about the Linux mapping. |

---

## How the Linux ratings are sourced

Recommendations are **researched from the web** and baked into the `$LinuxKB` array in
`detect_installed_windows_software.ps1`. To adjust a rating or add a new app, edit that
table and re-run. The optional `-Online` mode fills *unknown* apps via the Repology API.

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

Runs as root. Prints structured output per setting. A reboot is recommended
afterwards (display scaling, logind changes).

---

## Reproducing everything from scratch

[`instructions.txt`](instructions.txt) is a self-contained specification: an AI engine
can read it alone and regenerate all PowerShell scripts, the CSVs, and each target-OS
installer with freshly-researched data. It now includes **PART D — Settings Migration Spec**.

## Caveats

- **Competency is a deliberate rough estimate** for planning, not a benchmark.
- Ratings reflect the Linux landscape as of **June 2026** and will drift.
- Display resolution may not be replicable on different hardware.
- The settings migration scripts (`settings_config.sh`, `apply_settings.sh`) live
  **per distro directory** (e.g. `Linux Mint (Ubuntu)/`) — each target OS gets its own copy.

## Requirements

**Windows (inventory + settings extract):**
- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access only for `-Online` mode

**Linux (installer + settings apply):**
- Linux Mint or Ubuntu (APT base), run as **root**
- Internet access for repo/vendor downloads
- For settings: `xrandr`, `gsettings`, `localectl`, `systemctl` (all standard)
