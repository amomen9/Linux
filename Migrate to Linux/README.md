**[برای نسخه فارسی اینجا کلیک کنید!](README_fa.md)**

# Migrate to Linux - Software, Settings, and Driver Migration

## Introduction

Moving from Windows to Linux usually means hours of hunting down "what was I even running?", guessing at Linux equivalents, copying settings by hand, and praying your hardware works. **This project does all of that for you.**

It is a complete, **automated Windows → Linux migration kit** that:

- **Inventories every app installed on your Windows PC** and rates each one for Linux: is it native, is there a great alternative, how good is that alternative, is it free, and is it worth installing.
- **Installs all the keepers on Linux unattended** - native packages, Flatpaks, Docker images, vendor `.deb`s, and even the original Windows apps under Wine where that is the best option.
- **Extracts your common Windows settings** (power/lid behaviour, display resolution & scaling, keyboard layout, telemetry, auto-update) and **re-applies them on Linux for every user**.
- **Inventories every device driver** and **installs the Linux equivalents**, pulling firmware straight from the manufacturer via `fwupd`/LVFS.

Everything in this folder is already generated for **this machine**, so in most cases you just **copy it to your new Linux box and run one command** - no AI, no manual research required.

```bash
cd "Migrate to Linux/Execute on Linux!"
sudo ./execute_all.sh        # drivers → apps → settings, continue-on-error
./execute_all.sh --dry-run   # or preview the whole plan first, changing nothing (no root needed)
```

---

## How this compares to similar projects

Several tools touch the same problem from different angles. Here is how this kit relates to them:

| Project | What it does | Link |
| --- | --- | --- |
| **Operese** | In-place Windows 10 → **Kubuntu only** conversion of files/settings (written in Rust); app migration is explicitly unfinished. Converts the partition in place. | <https://codeberg.org/Operese/operese> |
| **WinApps** | Does not migrate - it **runs** the real Windows apps (Office/Adobe) inside a Windows VM and surfaces them on the Linux desktop over RDP. | <https://github.com/winapps-org/winapps> |
| **AlternativeTo** | A manual directory for looking up Linux equivalents; no detection, no automation. | <https://alternativeto.net> |
| **Ubuntu wiki: software-alternatives-migration** | A documented concept / checklist, not a working tool. | <https://wiki.ubuntu.com/software-alternatives-migration> |

**What makes this project different**

- **Cross-distro by design** - it detects apt/dnf/zypper/pacman at runtime and runs unchanged on Debian/Ubuntu, Fedora, openSUSE and Arch. Operese is Kubuntu-only; WinApps targets Ubuntu/Fedora.
- **Alternatives-first and curated** - a JSON manifest rates every Windows app and offers **multiple ranked Linux alternatives, each with a competency score**, preferring native Linux apps (Flatpak-first) rather than running the Windows binaries (WinApps) or doing only best-guess app migration (Operese).
- **Detect-on-Windows → generate self-contained scripts → run on Linux** - a clean offline split; the generated installer is unattended, idempotent, reports per app, and includes a manual-download workflow. No other tool here uses this generate-then-run model.
- **Breadth beyond apps** - it also migrates settings, installs device drivers, can rebuild Docker components, and offers an **opt-in Wine path** for Windows-only apps (auto-download where a trusted URL exists, otherwise it prompts for the installer) - a hybrid between Operese (migrate) and WinApps (emulate).
- **Trade-off** - by default it installs Linux-native replacements rather than converting the machine in place or running the actual Windows binaries, so it avoids their fragility but relies on good alternatives, with Wine as the fallback.

In one line: **Operese migrates a machine, WinApps emulates apps, AlternativeTo is a lookup - this project is a cross-distro, curated *recommend-and-install* engine that turns a Windows software inventory into a reproducible native-Linux setup, with Wine as an opt-in fallback.**

---

## How to use it - Workflows

> **You do NOT need an AI agent for normal use.** The scripts and the pre-generated
> CSVs in this folder are ready to run as-is. Just follow the workflows below.
>
> An AI agent (which reads [`instructions.txt`](documents/instructions.txt)) is only needed for a
> few **optional, one-off** tasks that are specific to *your* case:
> - **Regenerating the reports/installer from scratch** with freshly-researched data for a **different Windows PC** than the one captured here.
> - **Adding a new target OS/distro** (e.g. Fedora, Arch) - generating a fresh set of installer scripts for it.
> - **Refreshing the Linux app ratings and driver mappings** with the latest web research.
>
> Generating the reports on Windows (Workflows 1-3, step 1) and running the installers
> on Linux never require an AI agent.

There are two phases:

1. **On Windows** - run `.\run_project.ps1`: it inventories the PC (writing the CSV reports) **and generates the self-contained Linux installer scripts** into `Execute on Linux!/`. *Skip this if you are migrating the machine these files were generated on - everything is already here.*
2. **On Linux** - copy this `Migrate to Linux/` folder over and run the installers as root. The generated scripts are self-contained (the app list, settings and device reference are baked in at generation time), so no CSVs are read at runtime.

### Workflow 0 - Run everything at once (recommended)

**Windows side:** open a PowerShell terminal in the `Migrate to Linux/` folder and run:

```powershell
.\run_project.ps1
```

This runs the three detection scripts in order - **config → software → drivers** -
writing the three CSV files, then runs the generator that builds the self-contained
installer set in `Execute on Linux!/`. See [run_project.ps1](#run_projectps1---windows-orchestrator)
for the full parameter list.

**Linux side:** copy the `Migrate to Linux/` folder (or just the generated
`Execute on Linux!/`) to the target machine, then run the single orchestrator as root:

```bash
cd "Migrate to Linux/Execute on Linux!"
sudo ./execute_all.sh
```

It makes the three stage scripts executable and runs them **in order - drivers →
apps → settings - with a continue-on-error policy** (a failure in one stage is
recorded but never stops the others). Each stage keeps its own clean UI and logs;
`execute_all.sh` prints a per-stage OK/FAILED summary at the end and exits non-zero
if any stage failed. Prefer the individual workflows below when you want to run
just one stage.

### Preview without changing anything (dry-run)

Run any installer in **report-only mode** to see exactly what *would* happen - per app, and whether it would install natively, via Wine, or as a manual download - without touching the system:

```bash
./execute_all.sh --dry-run        # also accepts --report-only or -n, or set MIGRATE_DRY_RUN=yes
```

Dry-run needs no root, makes no changes and writes nothing - it just prints the plan and exits. Only the application plan is simulated; the driver, settings and Docker stages (which make system changes) are skipped.

### Workflow 1 - Migrate installed software

1. **Generate the report** *(Windows; skip if already present)* - run `submodules/B_detect_installed_windows_software.ps1` (or just `.\run_project.ps1`) on the Windows PC.
2. **Review** `documents/B_installed_windows_software.csv` - especially the `Must be included on Linux` and `Can be synched to Linux alternative` columns.
3. **Install on Linux** - run `Execute on Linux!/install_must_have_software.sh` as root (the app list is baked into the generated script).

### Workflow 2 - Migrate Windows settings

1. **Extract settings** *(Windows; skip if already present)* - run `submodules/C_detect_windows_settings.ps1` (or `.\run_project.ps1`) on the Windows PC:

   ```powershell
   powershell -ExecutionPolicy Bypass -File submodules/C_detect_windows_settings.ps1
   ```

   This produces `documents/C_windows_configs.csv`, which the generator bakes into `apply_settings.sh`.
2. **Copy** the `Execute on Linux!/` folder to the Linux machine (the settings are already baked into `apply_settings.sh` - no CSV needs to travel with it).
3. **Apply** - from that folder, run as root:

   ```bash
   cd "Migrate to Linux/Execute on Linux!"
   sudo ./apply_settings.sh
   ```

   It applies the captured settings (**to all users** - see note below):

   - **Power:** lid-close action (battery & AC) → `logind.conf`
   - **Display:** resolution → `xrandr`, scaling → system-wide dconf default
   - **Keyboard:** layout → `localectl` + `setxkbmap`, shortcut reference
   - **Telemetry:** disable `whoopsie`, `apport`, `apt-daily.timer`, `motd-news.timer`, etc.
   - **Location:** disable `geoclue`, MAC randomization, GNOME location (system-wide)
   - **Screen:** lock-screen / blank timeout → system-wide dconf (`"never"` disables lock & blanking)
   - **Auto-update:** install `system_update.service` + `system_update.timer` from the repo

   > **Applied to all users.** GNOME/desktop keys (scaling, location, lock-screen
   > timeout) are written as **system-wide dconf defaults** in `/etc/dconf/db/local.d`
   > - not `gsettings set` as root (which only touches root's own profile). Together
   > with the system-wide `logind`/`systemd`/`localectl`/APT changes, every setting
   > applies to **every user** on the machine (current and future) on next login.
   >

### Workflow 3 - Migrate device drivers

1. **Generate the report** *(Windows; skip if already present)* - run `submodules/A_detect_installed_drivers.ps1` (or `.\run_project.ps1`) on the Windows PC:
   ```powershell
   powershell -ExecutionPolicy Bypass -File submodules/A_detect_installed_drivers.ps1
   ```

   This enumerates every signed PnP driver (`Win32_PnPSignedDriver`) and writes
   `documents/A_installed_windows_drivers.csv`, classifying each device for Linux.
2. **No copy needed** - the driver installer detects hardware live on Linux and carries the detected Windows-device list baked in as a reference. Just copy the `Execute on Linux!/` folder over.
3. **Install on Linux** - from that folder, run as root:
   ```bash
   cd "Migrate to Linux/Execute on Linux!"
   sudo ./install_device_drivers.sh
   ```

   The installer **detects the hardware live** (lspci/lsusb/lscpu/DMI - the
   authoritative source, since Windows device names don't map cleanly to Linux
   modules), cross-references the CSV, then installs only what's needed:- **GPU:** NVIDIA proprietary driver (via `ubuntu-drivers`); AMD/Intel in-kernel + Mesa/VA-API.
   - **Network:** Realtek `r8168`/`r8125-dkms`, Broadcom `broadcom-sta-dkms`, Realtek USB-Wi-Fi DKMS; everything else is in-kernel + `linux-firmware`.
   - **CPU:** `intel-microcode` / `amd64-microcode`.
   - **Printers/scanners:** CUPS driverless + HPLIP (HP) + SANE.
   - **Fingerprint:** `fprintd` + `libfprint`.
   - **Manufacturer firmware:** `fwupd` + LVFS - downloads & flashes UEFI/SSD/dock/peripheral firmware straight from Lenovo/Dell/HP/Intel/etc.
   - **Optional vendor installers:** NVIDIA `.run` (nvidia.com) / AMDGPU-PRO (amd.com) via a skippable prompt at the end.

---

## Files

### Windows-side (run on Windows, in `Migrate to Linux/`)

| File                                                                                    | What it is                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`run_project.ps1`](run_project.ps1)                                                    | **Windows orchestrator** - runs the three detection scripts (steps 1-3) then the generator (step 4). Forwards parameters to the sub-scripts. |
| [`submodules/`](submodules/)                                                            | Detection scripts (A/B/C), the generator `D_compile_and_generate_shell_script.ps1`, the universal `templates/` (`_common.sh` + `*.sh.tmpl`), and `docker_discovery.sh` / `docker_discovery.ps1`. |
| [`Supported Distributions.txt`](Supported%20Distributions.txt)                          | Distro-family groupings (apt/dnf/zypper/pacman) and supported CPU architectures (x86_64/aarch64). |
| [`Additional_Manual_Linux_Software_Requirments.csv`](Additional_Manual_Linux_Software_Requirments.csv) | **Hand-curated** list of hardcoded applications included regardless of the Windows CSV - apps absent from the Windows PC and apps whose install logic goes beyond the CSV (Wine installs, multi-package splits like PowerToys, web-app shortcuts). |
| [`documents/B_applications.json`](documents/B_applications.json)                         | The manifest: every app's Linux alternatives plus the per-distro `install{}` descriptor (method, flatpakId, native names per family, arch) the generator reads. |
| [`documents/B_installed_windows_software.csv`](documents/B_installed_windows_software.csv) | Generated software report (one row per app). |
| [`documents/A_installed_windows_drivers.csv`](documents/A_installed_windows_drivers.csv) | Generated driver report (12 columns, one row per device). |
| [`documents/C_windows_configs.csv`](documents/C_windows_configs.csv)                     | Generated settings CSV (produced by `C_detect_windows_settings.ps1`). |
| [`documents/instructions.txt`](documents/instructions.txt)                              | Self-contained spec to **reproduce** all artifacts from scratch with fresh data. |

### Linux-side (run on the target machine, in `Execute on Linux!/`)

These four scripts are **generated** and **universal** - one set runs on every
supported distribution. They detect the distro family (apt/dnf/zypper/pacman) and
CPU architecture (x86_64/aarch64) at runtime and install everything **Flatpak-first**
with native fallbacks. See [`Supported Distributions.txt`](Supported%20Distributions.txt).

| File                                              | What it is                                                                                                                                   |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `Execute on Linux!/execute_all.sh`                | **One-shot orchestrator** - asks **up front** which stages to run (drivers / apps / settings) and whether to *"Migrate docker components?"* (only if a `docker_rebuild.sh` snapshot exists); runs them **unattended**; then handles manual-download apps **last** (type the installer's path in single quotes, or `skip`/`skip all`, with red errors + retry on a bad path). Also supports `--dry-run`. |
| `Execute on Linux!/install_must_have_software.sh` | Unattended **root installer** - installs every app flagged `Must be included on Linux = yes`, Flatpak-first with per-family native fallback. |
| `Execute on Linux!/install_device_drivers.sh`     | **Root driver installer** - firmware, GPU drivers, printing/scanning, plus a reference list of the Windows devices detected.                 |
| `Execute on Linux!/apply_settings.sh`             | **Settings runner** - applies the captured Windows settings (scaling, lock, layout, privacy, lid) to GNOME/Cinnamon; KDE/others noted.      |

### run_project.ps1 - Windows orchestrator

A wrapper that runs the three detection scripts and then the generator in one shot.
It lives in `Migrate to Linux/`; the sub-scripts live in `submodules/`.

```powershell
.\run_project.ps1
```

This runs in order:
1. `submodules/C_detect_windows_settings.ps1` → `documents/C_windows_configs.csv`
2. `submodules/B_detect_installed_windows_software.ps1` → `documents/B_installed_windows_software.csv`
3. `submodules/A_detect_installed_drivers.ps1` → `documents/A_installed_windows_drivers.csv`
4. `submodules/D_compile_and_generate_shell_script.ps1` → the universal installer set in `Execute on Linux!/`

Steps 1-3 need no administrator rights. If a step fails the pipeline stops unless
`-ContinueOnError` is passed. Use `-SkipDetection` to regenerate the scripts from
existing CSVs, or `-SkipGenerator` to only run detection.

#### Options

| Parameter                       | Default | Purpose                                                                      |
| ------------------------------- | ------- | ---------------------------------------------------------------------------- |
| `-OutputDir <path>`             | documents/ | Directory where the three CSV files are written.                         |
| `-ContinueOnError`              | off     | Skip failed steps instead of stopping the pipeline.                          |
| `-SkipDetection`                | off     | Skip steps 1-3; regenerate the installer scripts from existing CSVs.         |
| `-SkipGenerator`                | off     | Skip step 4; only run detection.                                            |
| `-MustIncludeThreshold <int>`   | 70      | Forwarded to B script - minimum competency for "Must be included on Linux".  |
| `-IncludeSystemComponents`      | off     | Forwarded to B script - keep redistributables / runtimes / drivers.          |
| `-IncludeStoreApps <bool>`      | $true   | Forwarded to B script - include filtered Store/UWP apps.                     |
| `-Online`                       | off     | Forwarded to B script - query repology.org live for unknown apps.            |
| `-IncludeVirtualDevices`        | off     | Forwarded to A script - keep ROOT\ and SW\ virtual devices.                  |
| `-IncludeMicrosoftInbox`        | off     | Forwarded to A script - keep generic Microsoft in-box drivers.               |

### Directory layout

```text
Migrate to Linux/
├─ run_project.ps1                         # Windows: orchestrator (detection 1-3 + generator 4)
├─ Additional_Manual_Linux_Software_Requirments.csv  # hand-curated hardcoded apps beyond the CSV
├─ Supported Distributions.txt             # distro-family groupings + supported CPU architectures
├─ README.md
├─ README_fa.md                            # Persian translation of this file
│
├─ submodules/                             # Windows detection scripts + the generator
│  ├─ A_detect_installed_drivers.ps1
│  ├─ B_detect_installed_windows_software.ps1
│  ├─ C_detect_windows_settings.ps1
│  ├─ D_compile_and_generate_shell_script.ps1   # builds the universal installer set
│  ├─ docker_discovery.sh / .ps1           # snapshot Docker -> cross-platform rebuild script
│  └─ templates/                           # _common.sh engine + the four *.sh.tmpl templates
│
├─ documents/                              # generated data + the manifest
│  ├─ A_installed_windows_drivers.csv
│  ├─ B_installed_windows_software.csv
│  ├─ B_applications.json                  # manifest with per-distro install{} descriptors
│  ├─ C_windows_configs.csv
│  ├─ settings_config.txt
│  └─ instructions.txt                     # reproducibility spec
│
├─ Execute on Linux!/                      # GENERATED: one universal set for ALL distros
│  ├─ execute_all.sh                       # orchestrator: drivers -> apps -> settings
│  ├─ install_must_have_software.sh        # Flatpak-first installer, per-family native fallback
│  ├─ install_device_drivers.sh            # firmware / GPU / printing + device report
│  ├─ apply_settings.sh                    # Windows settings -> Linux desktop
│  └─ docker_rebuild.sh                    # only if Docker was installed on the Windows source
│
└─ History/                                # archived previous versions + retired_distro_folders/
```

The generated scripts in `Execute on Linux!/` are **universal**: they detect the
distribution family and CPU architecture at runtime, so the same set runs on every
distro listed in [`Supported Distributions.txt`](Supported%20Distributions.txt) - no
per-distro folders needed.

---

## Quick start - Run all Windows scripts

```powershell
# From the Migrate to Linux/ folder, in PowerShell 5.1 or PowerShell 7+:
.\run_project.ps1
```

This runs config → software → drivers in sequence. No administrator rights required.

### Options - Software inventory (standalone script)

| Parameter                       | Default                                                | Purpose                                                                              |
| ------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `-OutputPath <path>`          | `B_installed_windows_software.csv` (beside the script) | Where to write the CSV.                                                              |
| `-MustIncludeThreshold <int>` | `70`                                                 | Minimum*Alternative Competency* (%) for **Must be included on Linux = yes**. |
| `-IncludeSystemComponents`    | off                                                    | Keep redistributables, runtimes and drivers.                                         |
| `-IncludeStoreApps <bool>`    | `$true`                                              | Include filtered Microsoft Store/UWP apps.                                           |
| `-Online`                     | off                                                    | Query repology.org live for unknown apps.                                            |

### The CSV columns (software inventory)

| Column                                    | Source  | Meaning                                                                                                |
| ----------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------- |
| **Name**                            | from PC | Human-friendly product name.                                                                          |
| **Version**                         | from PC | Installed version.                                                                                    |
| **Publisher**                       | from PC | Vendor.                                                                                               |
| **Source**                          | from PC | `Win32` (registry) or `Store` (UWP/Appx).                                                         |
| **Linux Availability**              | curated | Flags: Available on Linux, Native Alternative, Available as WebApp, etc.                               |
| **Best Linux Alternative**          | curated | The best Linux option. Free alt appended if paid.                                                     |
| **Alternative Competency**          | curated | Rough % vs Windows (≥100 = Linux is better).                                                          |
| **Pricing model**                   | curated | Free (FOSS), Free, Freemium, Shareware, or Paid.                                                       |
| **Must be included on Linux**       | derived | `yes` / `no` - computed from competency threshold.                                                |
| **Can be synched to Linux alternative** | curated | Whether the app's data auto-syncs into the Linux alternative by signing in (cloud): `Yes` or `No, manual transfer`. |
| **Linux Alternative Type**          | curated | How the alternative is delivered - WebApp, Native (Flatpak/APT/Docker), Wine, etc.; this drives the generated installer's method. |
| **Download URL**                    | curated | The official download or web-app URL for the chosen Linux alternative. |

### The CSV columns (settings migration - `C_windows_configs.csv`)

| Column                 | Source  | Meaning                                                                                  |
| ---------------------- | ------- | ---------------------------------------------------------------------------------------- |
| **Category**     | from PC | `Power`, `Display`, `Keyboard`, `Telemetry`, `AutoUpdate`, `Screen`.         |
| **ConfigKey**    | from PC | Specific setting key (e.g.`lid_close_on_ac`, `resolution`, `lock_screen_timeout`). |
| **WindowsValue** | from PC | The extracted value (e.g.`sleep`, `1920x1080`, `10 min` / `never`).              |
| **LinuxCommand** | from PC | Input language tags for keyboard mapping (optional).                                     |
| **Notes**        | from PC | Human-readable note about the Linux mapping.                                             |

### The CSV columns (driver inventory - `A_installed_windows_drivers.csv`)

Generate with `.\A_detect_installed_drivers.ps1` (no admin rights). Switches:
`-IncludeVirtualDevices` keeps `ROOT\`/`SW\`/`SWD\` software devices;
`-IncludeMicrosoftInbox` keeps generic Microsoft in-box drivers that need no Linux action.

| Column                          | Source  | Meaning                                                                                                                                                             |
| ------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Device Name**           | from PC | The PnP device's friendly name.                                                                                                                                     |
| **Device Class**          | from PC | PnP class (`Display`, `Net`, `Bluetooth`, `Printer`, …).                                                                                                   |
| **Manufacturer**          | from PC | Device manufacturer.                                                                                                                                                |
| **Driver Version**        | from PC | Installed driver version.                                                                                                                                           |
| **Driver Date**           | from PC | Driver date (`yyyy-MM-dd`).                                                                                                                                       |
| **Driver Provider**       | from PC | Who signs/provides the driver (NVIDIA, Microsoft, …).                                                                                                              |
| **Hardware ID**           | from PC | Bus ID (`PCI\VEN_10DE&DEV_…` / `USB\VID_…&PID_…`) - the reliable key to the silicon.                                                                        |
| **Linux Driver Status**   | curated | Flags: In-Kernel, Generic Driver, Firmware Required, Kernel Module (DKMS), Proprietary Driver, Vendor Driver, Not Applicable, Needs Review.                         |
| **Linux Driver / Module** | curated | The kernel module or package (`amdgpu`, `iwlwifi`, `nvidia-driver-NNN`, `r8168-dkms`, `hplip`, …).                                                       |
| **Vendor Download**       | curated | Manufacturer's Linux driver page, filled only when a vendor download is needed.                                                                                     |
| **Notes**                 | curated | Short note about the Linux situation.                                                                                                                               |
| **Must install on Linux** | derived | `yes` when the device needs an actively-installed driver (proprietary / DKMS / vendor); `no` when the in-box kernel + base `linux-firmware` already cover it. |

---

### The Additional_Manual_Linux_Software_Requirments.csv columns

This is a **hand-curated** file - it is NOT machine-generated by any PowerShell script.
It documents every application that the Linux installer installs through **hardcoded
logic** rather than through a simple "install the alternative listed in the CSV" path.
These fall into three groups:

| Group                                                  | Examples                                                                                              | Why hardcoded                                                                                                                                                                      |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Apps absent from the Windows PC**              | Telegram, Terminator, WindTerm, WinDirStat                                                            | These are useful additions that your Windows machine may not have installed. They're always included.                                                                              |
| **Apps needing custom install logic**            | Notepad++ (Wine + native), PowerToys (10 packages), WinRAR (Wine + native), IDM (Wine + native)       | These cannot be expressed as a single `apt install` command. They require Wine, multi-package splits, or special post-install steps.                                             |
| **Apps whose alternative IS the hardcoded path** | Adobe Acrobat Pro → Stirling PDF, Advanced IP Scanner → Angry IP Scanner, Grammarly → LanguageTool | The installer installs the ALTERNATIVE itself (not a native Linux version of the Windows app), and this alternative needs its own custom install logic (Docker, .deb, .zip, etc.). |

| Column                                       | Source  | Meaning                                                                             |
| -------------------------------------------- | ------- | ----------------------------------------------------------------------------------- |
| **Name**                               | curated | Human-readable name of the original Windows app or hardcoded inclusion.             |
| **Category**                           | curated | Functional category (PDF, Network, Editor, Utilities, etc.).                        |
| **Windows App?**                       | curated | Whether this app exists/doesn't on Windows, and whether it's a hardcoded inclusion. |
| **In B_installed_windows_software.csv?** | curated | Whether a corresponding row appears in the machine-generated CSV.                   |
| **Linux Package(s)**                   | curated | The exact Linux package(s) installed - may be APT, Flatpak, Docker, .deb, or Wine. |
| **Source / URL**                       | curated | The official source or download URL for the Linux package.                          |
| **Notes**                              | curated | Why this is hardcoded, what special logic the installer applies.                    |
| **Can be synched to Linux alternative** | curated | Whether the app's data auto-syncs into the Linux alternative by signing in (cloud): `Yes` or `No, manual transfer`. |
| **Linux Alternative Type**             | curated | How the alternative is delivered (WebApp, Native (Flatpak/APT/Docker), Wine, etc.). |
| **Download URL**                       | curated | The official download or web-app URL for the Linux package. |

---

## How the Linux ratings are sourced

Recommendations are **researched from the web** and stored in the
`documents/B_applications.json` manifest, which `submodules/B_detect_installed_windows_software.ps1`
looks up offline for every installed app (each entry also carries the per-distro
`install{}` descriptor the generator uses). To adjust a rating or add a new app, edit
that JSON manifest and re-run; apps missing from it are flagged `Needs Review`. The
optional `-Online` mode fills *unknown* apps via the Repology API.

For drivers, the mapping lives in the `$DriverKB` rule table in
`submodules/A_detect_installed_drivers.ps1`. Each device is classified from its **PnP class** and
the **PCI/USB vendor ID** embedded in its Hardware ID (first matching rule wins). To
re-rate a device or add a new chip, edit that table and re-run.

---

## Update the manifest with AI

When you run `run_project.ps1`, any installed Windows app that is **not found in the
manifest** (`documents/B_applications.json`) is printed as a yellow **warning** listing
the unmatched app names (and the same list is shown again at the start of
`execute_all.sh` on Linux). Those apps get no Linux equivalent until you add them.

You don't have to write the manifest entries by hand. Open this project in any
AI coding agent (Claude Code, etc.) and paste the prompt below verbatim - it will run the
detector, read the warning list, and fill in the missing entries (plus refresh the
existing ones) with current data:

```text
Make a test-run of run_project.ps1 and see the list of applications that will be given as a warning for not being found on the manifest. Add them to the manifest with the latest avaiable data from the internet in manifest entries format. Also in the end, update the already existing application list with respect to the latest available versions, best alternatives, download link, and everything else that can be updated. Strictly do not change anything else
```

After the agent finishes, re-run `run_project.ps1` and use the regenerated
`Execute on Linux!` scripts.

> Note: the `installedVersion` / `installedEdition` fields on each entry are **dynamic** -
> the toolkit refreshes them from your actual Windows install on every run, so you don't
> need to maintain them. Everything else in an entry is static curated data.

---

## Settings migration - structured output

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

**Firewall rules with Windows service-keyword ports.** Some Windows firewall rules use named ports (e.g. `PlayToDiscovery`, `mDNS`, `WSDEVENTS`, `RPC-EPMap`) instead of numbers. Known keywords are translated to their real port (e.g. `PlayToDiscovery`→3702, `mDNS`→5353); any keyword without a portable Linux equivalent is **skipped with a note** rather than reported as a failure.

---

## Installing on Linux - Software

```bash
# On any supported distro (Debian/Ubuntu, Fedora, openSUSE, Arch):
sudo ./"Execute on Linux!/install_must_have_software.sh"
```

The installer is **unattended and idempotent**, with a clean progress display,
auto-detection of the target machine (codename + architecture), and two log files.
For downloads, a **live hash-bar progress indicator** is shown (`curl -#`).
For installations, only **installation progress** is displayed (no verbosity):
apt shows its live percentage via `APT::Status-Fd`, flatpak uses `--show-progress`,
and installers without a progress API (Wine, .deb scripts) show a non-interactive
elapsed-time counter instead of verbose output.

On failure, the script **prints the downloaded file's path and the exact manual
install command** so the user can retry. All downloads go to
`/opt/migrate-downloads/`, which is set **mode 0777 and owned by the invoking
non-root user** so files can be inspected or manually installed.

**PaperCut (hard-coded - the native client, never a substitute).** PaperCut's Linux
client (Print Deploy / User Client) is served by **your own PaperCut server**, which is
the trusted first-party source for it. Set `PAPERCUT_SERVER` (host) and optionally
`PAPERCUT_PORT` (default `9174`) at the top of the script - or as env vars - to install
it **unattended**:

```bash
sudo PAPERCUT_SERVER=printdeploy.example.com ./install_must_have_software.sh
```

If `PAPERCUT_SERVER` is not set (or the auto-download fails), the installer **defers to
the manual prompt at the end** and asks for the Linux client `.tar.gz` downloaded from
your server's client page (`https://<server>:9174`). Either way the **native PaperCut
client is installed - CUPS is never substituted**.

At the end of the automated installation, the script **prompts** the user to import
fonts from a directory. The font import mechanism:

1. Asks for a directory path containing font files (read from `/dev/tty`).
2. Recursively finds all font files in that directory (supports **all common font formats**:
   `.ttf`, `.otf`, `.ttc`, `.woff`, `.woff2`, `.pfa`, `.pfb`, `.afm`, `.pfm`, `.dfont`,
   `.otb`, `.bdf`, `.pcf`, `.gsf`, `.otc`, `.abf`, `.chr`, `.fnt`, `.mxf` -
   covering Windows, macOS, and Linux font types).
3. Copies them to `/usr/local/share/fonts/user-import/`.
4. Runs `fc-cache` to rebuild the font cache so applications (including Wine) see them.
5. Records the result (OK/SKIP/FAIL) in the results log.

Error handling:

- Non-existent or unreadable directory → reprompt or type `skip`.
- Directory contains no matching font files → warn and reprompt.
- Individual file copy failures → skip that file, continue with the rest.
- No tty (non-interactive environment) → skip silently.

### Custom post-install commands

Any app can carry **custom commands that run right after it installs**, declared once in the manifest as an `install.postInstall` array (a list of shell snippets). The generator emits them and the installer runs them **as the logged-in desktop user** (so `gsettings`/`dconf` and other per-user settings take effect) **only when the app was actually installed this run** - a failing command is reported but never fails the install. For example, **CopyQ** uses this to bind **Win+V (Super+V)** as the shortcut that opens its clipboard-history viewer, reproducing the Windows clipboard‑history key.

### Natively-available apps and always-included helpers

- **Apps Microsoft (and others) also ship for Linux** install as the **same app, natively** - e.g. **Microsoft SQL Server**: if it ran on the **host OS** on Windows it is installed natively from Microsoft's official repo (`mssql-server`, x86_64, Ubuntu/RHEL/SLES); if it ran as a **Docker container** it is recreated as a container by the Docker rebuild step. The two paths can't double‑install because they're chosen by how the app was detected.
- **Linux-only helpers you always want** can be marked `"forceInclude": true` in the manifest so they install **even though no matching Windows app exists to detect**. **CopyQ** (the clipboard manager that replaces the Windows Win+V history) is included this way.
- **Apps with an official install script** (manifest method `script`) install **automatically** instead of falling back to a manual prompt — e.g. **Ollama** via `https://ollama.com/install.sh`. The script is downloaded first (so an error/HTML page is never piped to a shell) and then run.

### Windows-only apps under Wine (the Windows emulator)

For apps with no native Linux build, the installer can **also install the original Windows program under Wine** if you answer **yes** to the last setup question, *"Install the non-cross-platform Windows applications under the Windows emulator (wine) too?"*

- Where a trusted official installer URL is recorded in the manifest (the `windowsInstaller` field; currently **Notepad++** and **WinRAR**), it is **downloaded and run automatically**. Otherwise you are asked for the installer path - type it **in single quotes**, a full path or one relative to your `~/Downloads` (any extension: `.exe`, `.msi`, `.bat`, …) - or `skip` / `skip all`.
- Each Wine app gets its **own isolated Wine prefix**, its **font/DPI scaled to 2.5×** for readability, and `.desktop` launchers for any Start-Menu shortcuts the installer creates.
- **32-bit apps just work.** A 32-bit-only Windows installer (e.g. µTorrent) is given its own **32-bit (`win32`) Wine prefix** instead of the default 64-bit one — a 64-bit prefix's WoW64 fails to load 32-bit `kernel32` (`c0000135`) on several distros even with `wine32` installed. 64-bit apps are unaffected, and upgrades keep their existing prefix as-is.
- **A crashing installer doesn't lose the app.** Under Wine many installers exit with an error by crashing on a *final* step (a missing Gecko/HTML pane, a "run now" launch) **after** the program is already installed. If the installer errors but the app's files/shortcut are present, it's recorded as **installed‑but‑unverified** (with launchers created) instead of failed — a true failure (nothing installed) still reports the error and how to reproduce it.
- **Installs never hang the script.** Many Windows installers auto-launch the app (or a tray/updater) when they finish, which used to keep the script stuck inside Wine. The installer now runs in the background with a timeout (`MIGRATE_WINE_INSTALL_TIMEOUT`, default 600s) and then runs `wineserver -k` to close anything left running, so it always continues. If a *"Setup finished / Run now"* window appears, just **close it** to move on immediately. (Because each app has its own prefix that's cleared after install, Wine also won't hit Windows' *"another setup is already running"* error.)
- **Re-runs don't re-install (and don't bloat the UI).** If an app is already installed in its prefix, a later run **skips** re-installing it. The DPI is always an **absolute** 2.5× (96→240), never multiplied by the current value, so it never accumulates; the growth some apps showed (e.g. IDM's toolbar) came from re-running the first-launch appearance setup every time. With `MIGRATE_UPDATE_EXISTING=yes` the app is **upgraded in place** — the prefix (and your data/settings) is kept and only the program binaries are refreshed; the **first-install appearance setup (DPI/window/tuning) is not redone**, so an upgrade preserves exactly what you have and can't bloat. If a prefix was already bloated by earlier runs, delete it once (`~/.local/share/wineprefixes/<app>`) to reinstall it clean.
- **First-launch appearance tuning** (interactive): right after a Wine app installs, the installer **launches it once so you can see it**, then walks you through its **visual settings** - **font scaling (DPI)** and **window size** - prompting for each with its current value (press Enter to keep it; bad input is rejected in red and re-asked). It then **closes the app, applies your values, relaunches it**, and asks whether the look is right: **`y`** = yes, **`r`** = start over, or **`a`** = yes and **apply the same settings to every later Wine install** automatically. (Skipped automatically when there is no interactive terminal, keeping the 2.5× default.)
- It is independent of the alternatives count: with alternatives **> 0** you get the Linux alternative(s) **and** the Wine version; with **0** you get **only** the Wine version. (That is why the "how many best alternatives" question says *"excluding wine"*.)

### Manual downloads - the installer-path prompt

Apps with no automatic installer are handled at the end. The installer tells you what to download, then asks for the file: type its path **in single quotes** - a full path, or one relative to your `~/Downloads` - or `skip` (this app) / `skip all` (every remaining manual app). The file is installed by its extension (`.deb`, `.rpm`, `.sh`, `.run`, `.AppImage`, `.tar.gz`, …), and the prompt shows the **Linux alternative's** name (what is being installed), not the original Windows app.

### Post-install verification and the uninstall script

- **Verification:** after each install the engine re-checks that the package / Flatpak / Snap is actually present; if it cannot confirm, the app is reported as **`UNVERIFIED`** ("installed but unverified") rather than as a false success, so problems show up in the summary.
- **Uninstall:** everything installed is recorded and an **`uninstall_migrated_apps.sh`** is written to your home folder. Review it, then `sudo bash ~/uninstall_migrated_apps.sh` to undo the run - native packages, Flatpaks and Snaps are removed automatically; file and Wine installs get a manual note.

---

## Installing on Linux - Settings

```bash
# On any supported distro:
cd "Execute on Linux!"
sudo ./apply_settings.sh
```

Runs as root. Prints structured output per setting, and **applies every setting to
all users** (GNOME keys via system-wide dconf defaults; the rest are system-wide by
nature). A reboot / re-login is recommended afterwards (display scaling, lock-screen
timeout, logind changes).

---

## Installing on Linux - Drivers

```bash
# On any supported distro:
cd "Execute on Linux!"
sudo ./install_device_drivers.sh
```

Runs as root with the same clean UI, spinner, and two log files as the software
installer. It **detects hardware live** and only installs what's actually present,
so it is safe to run on any machine - absent hardware is recorded as *skipped*, not
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

## Reproducing everything from scratch (AI agent)

[`instructions.txt`](documents/instructions.txt) is a self-contained specification: an AI engine
can read it alone and regenerate all PowerShell scripts, the CSVs, and each target-OS
installer with freshly-researched data. It includes **PART D - Settings Migration Spec**
and **PART E - Device Driver Migration Spec** (plus the `execute_all.sh` orchestrator).
This is the **only** part of the project that benefits from an AI agent - everyday use
(running the scripts and installers) does not.

## Continuous integration (CI)

A GitHub Actions workflow ([`.github/workflows/distro-dry-run.yml`](../.github/workflows/distro-dry-run.yml)) guards the "one script set runs unchanged on every distro" promise automatically: on each change it regenerates the installer scripts, then in a clean container for **each** package-manager family (apt / dnf / zypper / pacman) it syntax-checks every script and runs the installer in `--dry-run`. Per-distro regressions surface in CI instead of on a user's machine.

---

## Caveats

- **Competency is a deliberate rough estimate** for planning, not a benchmark.
- Ratings reflect the Linux landscape as of **June 2026** and will drift.
- The Wine **`windowsInstaller`** URLs in the manifest are **version-pinned** to a current release (no vendor offers a stable "latest" link), so they need an occasional bump when the app updates; if a URL ever 404s, the installer falls back to asking you for the file.
- Display resolution may not be replicable on different hardware.
- The installer scripts (`execute_all.sh`, `install_*`, `apply_settings.sh`) are
  **generated once** into `Execute on Linux!/` and are **universal** - the same set
  runs on every supported distro (each detects the family + CPU architecture at
  runtime). There are no longer per-distro folders.
- **Drivers are detected live on Linux**, not transcribed from Windows: the
  `A_installed_windows_drivers.csv` is a cross-reference, while `lspci`/`lsusb`/DMI on
  the actual machine are authoritative (Windows device names don't map cleanly to
  Linux modules).

## Requirements

**Windows (inventory + settings extract):**

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access only for `-Online` mode

**Linux (installers + settings apply):**

- Any supported distribution - Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`),
  openSUSE (`zypper`) or Arch (`pacman`); run as **root**
- Internet access for Flatpak/repo/vendor/firmware downloads
- For settings: `gsettings`, `localectl`, `systemctl` (all standard)
- The installer bootstraps Flatpak + Flathub itself and pulls any extra tools it
  needs from your distro's base repos

---

## Why migrate? Linux vs Windows

A balanced look at what you gain - and what you give up - so you can decide with
eyes open.

### Advantages of Linux over Windows

- **Free and open source** - no licence fees, no activation, source is auditable.
- **No forced telemetry or ads** - no Recall, no Start-menu ads, no account
  requirement; privacy is the default.
- **Lighter and faster** - runs well on old/low-RAM hardware; less background bloat.
- **Updates on your terms** - no surprise reboots; you choose when to update, and
  updates rarely break the machine.
- **One package manager for everything** - install/update all software with a single
  command instead of hunting installers across the web.
- **Stability and uptime** - servers run for years without reboots; far less
  "reinstall to fix it."
- **Powerful, scriptable shell** - bash/zsh + coreutils make automation trivial.
- **Free of vendor lock-in** - open formats, no forced cloud, easy to dual-boot or
  move between distros.
- **Security** - granular permissions, fast patching, much smaller malware target.
- **Total customisation** - swap desktops (GNOME/KDE/Xfce/…), tweak anything.
- **Longevity** - a 10-year-old PC stays useful; no artificial "your CPU isn't
  supported" cut-offs.

### Advantages of Windows over Linux (the honest list)

- **Commercial software** - Adobe Creative Cloud, Microsoft Office (full), many CAD,
  finance and engineering suites are Windows-only.
- **Gaming** - the largest native catalogue; anti-cheat in some online games blocks
  Proton/Wine; some titles never work.
- **Hardware/peripheral support** - vendor drivers, fingerprint readers, some
  printers/scanners and exotic gadgets often ship Windows-only.
- **Pro device ecosystems** - many music/recording, broadcast and lab tools assume
  Windows (or macOS).
- **Familiarity & support** - most workplaces, classrooms and help desks assume
  Windows; more "click here" tutorials exist.
- **Plug-and-play GPU/Optimus** - laptop GPU switching and vendor control panels are
  smoother out of the box.
- **Enterprise management** - Active Directory / Group Policy / Intune integration.

### For computer scientists & developers

- **The platform you deploy to** - servers, containers and the cloud are Linux; dev
  on the same OS removes "works on my machine" gaps.
- **First-class toolchains** - gcc/clang, gdb/valgrind/perf/strace, make/cmake, and
  package-manager-installed headers without hunting for SDKs.
- **Native containers** - Docker/Podman run on the kernel directly (no VM tax),
  faster builds and lower memory than Docker Desktop on Windows.
- **WSL not needed** - you already have the real thing; no translation layer, no path
  or line-ending friction.
- **Reproducible environments** - apt/dnf + venv/conda + Nix/containers make setups
  scriptable and shareable.
- **Everything is a file / great IPC** - pipes, sockets, `/proc`, `/sys`,
  systemd - ideal for understanding and instrumenting systems.
- **SSH/remote-first** - effortless headless servers, tmux, remote dev over SSH.
- **Research & HPC** - the default for clusters, CUDA/ROCm, scientific stacks
  (NumPy/PyTorch/TensorFlow) and schedulers (Slurm).

### For getting the most out of your hardware

- **Lower idle overhead** - less RAM/CPU spent on the OS, more left for your work.
- **Fine-grained control** - CPU governors (`cpupower`/TLP), I/O schedulers, kernel
  parameters, `nice`/`ionice`, cgroups to cap or prioritise processes.
- **Real observability** - `htop`, `btop`, `perf`, `iotop`, `nvtop`, `powertop`,
  `sensors` expose exactly what the hardware is doing.
- **Tunable graphics & thermals** - MangoHud/GOverlay, CoolerControl, custom fan
  curves, undervolting.
- **No bloatware/background services** - install only what you need; nothing phones
  home.
- **Lightweight desktops** - Xfce/LXQt/i3/Sway sip resources on modest machines.
- **Filesystems for power users** - Btrfs/ZFS snapshots, compression, RAID.
- **Old hardware stays useful** - no hard CPU/TPM cut-offs; revive machines Windows
  has abandoned.

---

## When there's no good Linux alternative

Some Windows apps and games have no strong native replacement. Pick a fallback by
how much native performance and integration you need. Roughly: **PWA < Wine/Bottles
< container < VM < GPU-passthrough VM < dual-boot**, trading convenience for fidelity.

| Strategy | Best for | Performance | Ease of use | Pros | Cons |
| --- | --- | --- | --- | --- | --- |
| **Web app / PWA** (browser app-mode, the installer's `--webapp`) | Apps with a good web version (Teams, WhatsApp, Office.com, Excalidraw) | Good (it's the website) | ★★★★★ | No install, auto-updates, cross-platform, zero maintenance | Needs internet; limited OS integration & offline/local-file access |
| **Wine** (raw) | Small, well-behaved Windows apps | Near-native CPU; GPU varies | ★★ | No VM overhead; runs many `.exe` directly | Fiddly per-app tweaks; many apps break; no official support |
| **Bottles / Lutris** (Wine wrapper) | Windows apps & older games, managed prefixes | Near-native CPU | ★★★★ | Flatpak install, per-app "bottles", presets, dependency installer | Still Wine underneath - not everything works; x86-only |
| **Proton / Steam Play** | Games (esp. on Steam) | Near-native (often 90-100%) | ★★★★ | One toggle in Steam; huge compatibility (see ProtonDB) | Some anti-cheat titles blocked; non-Steam games need effort |
| **Cloud gaming / remote** (GeForce NOW, Xbox Cloud, Parsec, Moonlight) | AAA games, occasional Windows access | Depends on network/latency | ★★★★ | No local GPU needed; runs anything server-side | Subscription/another PC; latency; needs strong connection |
| **Type-2 VM** (GNOME Boxes, VirtualBox, VMware Workstation) | Office/CAD/dev tools needing real Windows | Good for desktop apps; weak 3D | ★★★ | Full real Windows, snapshots, isolated, no reboot | Heavy RAM/disk; poor GPU performance; licence needed |
| **GPU-passthrough VM** ("VMVisor": KVM/QEMU + VFIO) | GPU/3D apps & gaming at near-native speed | Excellent (≈95-99%) | ★ | Near-bare-metal Windows with a dedicated GPU | Needs 2 GPUs (or iGPU+dGPU), IOMMU, significant setup |
| **Dual-boot** | Anything that must be 100% native (anti-cheat, pro hardware) | Native (100%) | ★★ | Full performance & compatibility | Reboot to switch; partitioning; bootloader upkeep |
| **Container** (Docker/Podman) | Server/CLI/dev software (DBs, Stirling-PDF, LanguageTool) | Native (Linux apps) | ★★★ | Lightweight, reproducible, no GUI baggage | Linux-native only (not for Windows GUI apps); not for GUI desktop apps |
| **Second machine / RDP** | Rare, must-have Windows-only workloads | Native on the other box | ★★★ | Keep one Windows box; access remotely (RDP/Parsec) | Cost of a second machine; remote-only |

Rule of thumb: try **native alternative → Flatpak → PWA → Bottles/Proton →
container → VM → GPU-passthrough/dual-boot**, stopping at the first that meets your
performance and integration needs.
