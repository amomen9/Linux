**[برای نسخه فارسی اینجا کلیک کنید!](README_fa.md)**

# Migrate to macOS - Software, Settings, and Driver Migration

## Introduction

Moving from Windows to macOS usually means hours of hunting down "what was I even running?", guessing at macOS equivalents, copying settings by hand, and praying your hardware works. **This project does all of that for you.**

It is a complete, **automated Windows → macOS migration kit** that:

- **Inventories every app installed on your Windows PC** and rates each one for macOS: is it native, is there a great alternative, how good is that alternative, is it free, and is it worth installing.
- **Installs all the keepers on macOS unattended** - Homebrew Casks, Homebrew formulae, Mac App Store apps (via `mas`), vendor `.dmg`/`.pkg` downloads, Docker images, and even the original Windows apps under Wine where that is the best option. **Where the app you already use ships a native Mac build - Microsoft Office, Adobe Creative Cloud, WhatsApp, AutoCAD, Parallels - that build is installed, not a substitute.**
- **Extracts ~26 categories of Windows settings** - power/lid, display resolution & scaling, keyboard layout + repeat, mouse/touchpad, accessibility, telemetry/location, timezone & NTP, locale, proxy, theme/accent/night-light, lock-screen timeout, auto-update, **hosts, printers, Wi-Fi networks and firewall rules**, plus post-install items (taskbar/Start-menu/desktop shortcuts, startup items, services, scheduled tasks, default browser, **your `~/.ssh`, Contacts and wallpaper**) - and **re-applies them on macOS for every user**. Secrets (Wi-Fi passwords, SSH keys, Contacts) travel inside one OpenSSL-encrypted bundle guarded by a single transfer password.
- **Inventories every device driver** and reports exactly how macOS handles each device: Apple ships almost every driver inside the OS, so the report highlights only the peripherals that genuinely need a vendor driver (USB-serial bridges, tablets, older printers) and the PC-only hardware that has no Mac counterpart at all.

Everything in this folder is already generated for **this machine**, so in most cases you just **copy it to your new Mac and run one command** - no AI, no manual research required.

```bash
cd "migrate_to_mac-os/Execute on macOS!"
sudo ./execute_all.sh        # drivers → apps → settings, continue-on-error
./execute_all.sh --dry-run   # or preview the whole plan first, changing nothing (no root needed)
```

---

## How this compares to similar projects

Several tools touch the same problem from different angles. Here is how this kit relates to them:

| Project                                                | What it does                                                                                                                                                          | Link                                                                                                            |
| ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| **Operese**                                      | In-place Windows 10 →**Kubuntu only** conversion of files/settings (written in Rust); app migration is explicitly unfinished. Converts the partition in place. | [https://codeberg.org/Operese/operese](https://codeberg.org/Operese/operese)                                       |
| **WinApps**                                      | Does not migrate - it**runs** the real Windows apps (Office/Adobe) inside a Windows VM and surfaces them on the Mac over RDP.                         | [https://github.com/winapps-org/winapps](https://github.com/winapps-org/winapps)                                   |
| **AlternativeTo**                                | A manual directory for looking up macOS equivalents; no detection, no automation.                                                                                     | [https://alternativeto.net](https://alternativeto.net)                                                             |
| **Apple Migration Assistant**                    | Copies files, accounts and some settings from a Windows PC to a Mac - but it does **not** install your applications or their Mac equivalents.                                        |
| **Ubuntu wiki: software-alternatives-migration** | A documented concept / checklist, not a working tool.                                                                                                                 | [https://wiki.ubuntu.com/software-alternatives-migration](https://wiki.ubuntu.com/software-alternatives-migration) |

**What makes this project different**

- **Cross-version and cross-architecture by design** - ONE generated script set detects the running macOS release (Catalina 10.15 through Tahoe 26 and newer) and the CPU architecture (Apple Silicon `arm64` / Intel `x86_64`, Rosetta-aware) at runtime, and installs Rosetta 2 on demand for Intel-only software.
- **Native-first, then alternatives** - a JSON manifest rates every Windows app and offers **multiple ranked macOS options, each with a competency score**. The vendor's own macOS build always comes first when one exists (that is the big difference from the Linux edition of this kit); substitutes and web apps follow behind it, and Homebrew Cask is the delivery channel.
- **Detect-on-Windows → generate self-contained scripts → run on macOS** - a clean offline split; the generated installer is unattended, idempotent, reports per app, and includes a manual-download workflow. No other tool here uses this generate-then-run model.
- **Breadth beyond apps** - it also migrates settings, installs device drivers, can rebuild Docker components, and offers an **opt-in Wine path** for Windows-only apps (auto-download where a trusted URL exists, otherwise it prompts for the installer) - a hybrid between Operese (migrate) and WinApps (emulate).
- **Trade-off** - by default it installs macOS-native replacements rather than converting the machine in place or running the actual Windows binaries, so it avoids their fragility but relies on good alternatives, with Wine as the fallback.

In one line: **Migration Assistant copies your files, WinApps emulates apps, AlternativeTo is a lookup - this project is a cross-version, cross-architecture, curated *recommend-and-install* engine that turns a Windows software inventory into a reproducible native-macOS setup, with Wine/CrossOver as an opt-in fallback.**

---

## How to use it - Workflows

> **You do NOT need an AI agent for normal use.** The scripts and the pre-generated
> CSVs in this folder are ready to run as-is. Just follow the workflows below.
>
> An AI agent (which reads [`instructions.txt`](documents/instructions.txt)) is only needed for a
> few **optional, one-off** tasks that are specific to *your* case:
>
> - **Regenerating the reports/installer from scratch** with freshly-researched data for a **different Windows PC** than the one captured here.
> - **Adding a new target OS** - generating a fresh set of installer scripts for it.
> - **Refreshing the macOS app ratings and driver mappings** with the latest web research.
>
> Generating the reports on Windows (Workflows 1-3, step 1) and running the installers
> on macOS never require an AI agent.

There are two phases:

1. **On Windows** - run `.\run_project.ps1`: it inventories the PC (writing the CSV reports) **and generates the self-contained macOS installer scripts** into `Execute on macOS!/`. *Skip this if you are migrating the machine these files were generated on - everything is already here.*
2. **On macOS** - copy this `Migrate to macOS/` folder over and run the installers as root. The generated scripts are self-contained (the app list, settings and device reference are baked in at generation time), so no CSVs are read at runtime.

### Workflow 0 - Run everything at once (recommended)

**Windows side:** open a PowerShell terminal in the `Migrate to macOS/` folder and run:

```powershell
.\run_project.ps1
```

This runs the three detection scripts in order - **config → software → drivers** -
writing the three CSV files, then runs the generator that builds the self-contained
installer set in `Execute on macOS!/`. See [run_project.ps1](#run_projectps1---windows-orchestrator)
for the full parameter list.

**macOS side:** copy the `Migrate to macOS/` folder (or just the generated
`Execute on macOS!/`) to the target machine, then run the single orchestrator as root:

```bash
cd "migrate_to_mac-os/Execute on macOS!"
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
2. **Review** `documents/B_installed_windows_software.csv` - especially the `Must be included on macOS` and `Can be synched to macOS alternative` columns.
3. **Install on macOS** - run `Execute on macOS!/install_must_have_software.sh` as root (the app list is baked into the generated script).

### Workflow 2 - Migrate Windows settings

1. **Extract settings** *(Windows; skip if already present)* - run `submodules/C_detect_windows_settings.ps1` (or `.\run_project.ps1`) on the Windows PC:

   ```powershell
   powershell -ExecutionPolicy Bypass -File submodules/C_detect_windows_settings.ps1
   ```

   This produces `documents/C_windows_configs.csv`, which the generator bakes into `apply_settings.sh`.
2. **Copy** the `Execute on macOS!/` folder to the Mac (the settings are already baked into `apply_settings.sh` - no CSV needs to travel with it).
3. **Apply** - from that folder, run as root:

   ```bash
   cd "migrate_to_mac-os/Execute on macOS!"
   sudo ./apply_settings.sh
   ```

   It applies the captured settings (**to all users** - see note below). `apply_settings.sh`
   runs in **two phases** - `pre` (before apps install) and `post` (after) - so settings
   that depend on the apps existing (shortcuts, default browser) come last. `execute_all.sh`
   sequences both phases for you. The full category set:

   **Pre-phase (applied before apps):**

   - **Power:** sleep timeouts → `pmset -c` / `pmset -b`; lid behaviour → `pmset lidwake`
   - **Display:** resolution → `displayplacer`; scaling → reported (macOS scales the whole UI, so it is a per-display choice in System Settings)
   - **Keyboard:** input sources → `com.apple.HIToolbox`; key-repeat delay/rate → `InitialKeyRepeat` / `KeyRepeat` (Windows ms converted to macOS 15 ms ticks)
   - **Mouse / Trackpad:** pointer size, speed, acceleration, button swap, double-click interval, tap-to-click, natural-scroll → `defaults`
   - **Accessibility:** sticky/slow/mouse keys, increase-contrast, Zoom → `com.apple.universalaccess`
   - **Telemetry:** turn off Apple diagnostics submission, Siri data sharing and personalised ads
   - **Location:** Location Services off (reported when System Integrity Protection blocks the write)
   - **Screen:** screen-saver idle time → `com.apple.screensaver`; lock delay → `sysadminctl -screenLock` (`"never"` disables the password requirement)
   - **Time:** timezone → `systemsetup -settimezone`; non-Microsoft NTP server → `systemsetup -setnetworktimeserver`
   - **Locale:** `AppleLocale` + `AppleLanguages`
   - **Proxy:** `networksetup -setwebproxy` / `-setsecurewebproxy` / `-setautoproxyurl`, plus `~/.zprofile` exports for CLI tools
   - **Appearance:** dark/light (`AppleInterfaceStyle`), accent colour (`AppleAccentColor`), Night Shift
   - **Hosts:** custom `/etc/hosts` entries merged in (then `dscacheutil -flushcache`)
   - **Printers:** network/shared printers → CUPS (`lpadmin`) - CUPS *is* macOS printing, so nothing to install
   - **Static IP/DNS:** recorded as a **manual note** (never auto-applied, so it can't break your network)
   - **Wi-Fi:** known networks + passwords → `networksetup -addpreferredwirelessnetworkatindex` + the System keychain (passwords decrypted from the transfer bundle)
   - **Firewall:** program-scoped Windows rules → the **macOS Application Firewall** (`socketfilterfw`), which is program-scoped by design; port rules → a dedicated **pf anchor** at `/etc/pf.anchors/migrate_to_macos`

   **Post-phase (applied after apps, unpacks the encrypted bundle first):**

   - **Shortcuts:** taskbar / Start-menu pins → **Dock** items; Desktop pins → Desktop aliases
   - **Startup items:** user → macOS **login items**; machine-wide → a **LaunchDaemon**
   - **Services / Scheduled tasks:** re-created as **launchd** jobs when they resolve to an installed app
   - **Default browser:** `defaultbrowser` (once the equivalent is installed)
   - **`~/.ssh`** (keys, perms 600/700), **Contacts** (staged for Contacts.app import), **wallpaper** (`osascript`) → restored from the encrypted bundle
   - **Fonts:** interactive import into `~/Library/Fonts`

   > **Scope on macOS.** Windows settings are split into per-user preferences and
   > machine-wide ones. Per-user keys are written with `defaults` **as the logged-in
   > user** (through `launchctl asuser`, so they land in the real GUI session rather
   > than root's own domain), while `systemsetup`, `pmset`, `networksetup`, `pfctl`,
   > `socketfilterfw`, `lpadmin` and `/etc/hosts` are system-wide and therefore apply
   > to every account on the Mac.
   >

### Workflow 3 - Migrate device drivers

1. **Generate the report** *(Windows; skip if already present)* - run `submodules/A_detect_installed_drivers.ps1` (or `.\run_project.ps1`) on the Windows PC:

   ```powershell
   powershell -ExecutionPolicy Bypass -File submodules/A_detect_installed_drivers.ps1
   ```

   This enumerates every signed PnP driver (`Win32_PnPSignedDriver`) and writes
   `documents/A_installed_windows_drivers.csv`, classifying each device for macOS.
2. **No copy needed** - the driver installer detects hardware live on macOS and carries the detected Windows-device list baked in as a reference. Just copy the `Execute on macOS!/` folder over.
3. **Install on macOS** - from that folder, run as root:

   ```bash
   cd "migrate_to_mac-os/Execute on macOS!"
   sudo ./install_device_drivers.sh
   ```

   **macOS ships its own drivers.** Apple writes, signs and updates the graphics,
   Wi-Fi, Bluetooth, audio, storage and input drivers inside the OS and delivers them
   through Software Update, so unlike the Linux edition there is almost nothing to
   install. The stage **detects the Mac's hardware live** (`system_profiler`,
   `networksetup`, `kmutil`), cross-references the Windows CSV, and then:

   - **Apple-supplied drivers & firmware:** lists what Software Update has pending and offers to install it (`softwareupdate -ia`).
   - **Rosetta 2:** installed on Apple Silicon so Intel-only apps (and Wine) run.
   - **Graphics:** reported only - the driver is part of macOS. NVIDIA cards are **not supported** on macOS at all; AMD (incl. eGPU on Intel Macs) and Apple Silicon GPUs are in-OS.
   - **Kernel / system extensions:** lists the third-party kexts and DriverKit extensions already loaded, each of which needs approval in System Settings > Privacy & Security.
   - **Printing/scanning:** CUPS and AirPrint are built in; SANE is offered only for a scanner with no macOS driver.
   - **Peripherals macOS does NOT cover:** offered **only when the device is actually attached** - FTDI / CH34x / CP210x / PL2303 USB-serial bridges, Wacom tablets, pro audio interfaces.

---

## Files

### Windows-side (run on Windows, in `Migrate to macOS/`)

| File                                                                                                  | What it is                                                                                                                                                                                                                                               |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`run_project.ps1`](run_project.ps1)                                                                   | **Windows orchestrator** - runs the three detection scripts (steps 1-3), the generator (step 4), Supported Versions and Architectures (5) and the optional user/app data backup (6). Forwards parameters to the sub-scripts. `--data-backup` auto-confirms step 6; `--data-backup-only` runs only step 6.        |
| [`submodules/`](submodules/)                                                                           | Detection scripts (A/B/C), the generator`D_compile_and_generate_shell_script.ps1`, the universal `templates/` (`_common.sh` + `*.sh.tmpl`), and `docker_discovery.sh` / `docker_discovery.ps1`.                                              |
| [`Supported Versions and Architechtures.txt`](Supported%20Versions%20and%20Architechtures.txt)         | Supported macOS releases (Tahoe 26 → Catalina 10.15) ranked newest-first with a "best for" note, the supported CPU architectures (Apple Silicon `arm64` / Intel `x86_64` / Rosetta 2), per-app minimum-macOS constraints, and the per-channel coverage (Cask / formula / Mac App Store / MacPorts). Auto-generated from the manifest. |
| [`Additional_Manual_macOS_Software_Requirments.csv`](Additional_Manual_macOS_Software_Requirments.csv) | **Hand-curated** list of hardcoded applications included regardless of the Windows CSV - apps absent from the Windows PC and apps whose install logic goes beyond the CSV (Wine installs, multi-package splits like PowerToys, web-app shortcuts). |
| [`documents/B_applications.json`](documents/B_applications.json)                                       | The manifest: every app's macOS options - the vendor's own Mac build first - plus the `install{}` descriptor (`method`, `caskId`, `masId`, `builtinApp`, `native.brew`/`native.port`, `arch`, `minOS`) the generator reads.                        |
| [`documents/B_installed_windows_software.csv`](documents/B_installed_windows_software.csv)             | Generated software report (one row per app).                                                                                                                                                                                                             |
| [`documents/A_installed_windows_drivers.csv`](documents/A_installed_windows_drivers.csv)               | Generated driver report (12 columns, one row per device).                                                                                                                                                                                                |
| [`documents/C_windows_configs.csv`](documents/C_windows_configs.csv)                                   | Generated settings CSV (produced by`C_detect_windows_settings.ps1`).                                                                                                                                                                                   |
| [`documents/instructions.txt`](documents/instructions.txt)                                             | Self-contained spec to**reproduce** all artifacts from scratch with fresh data.                                                                                                                                                                    |

### macOS-side (run on the target machine, in `Execute on macOS!/`)

These four scripts are **generated** and **universal** - one set runs on every
supported macOS release. They detect the macOS version (`sw_vers`) and CPU
architecture (`uname -m`, Rosetta-aware) at runtime and install everything
**Cask-first**, with Homebrew formulae, the Mac App Store and direct `.dmg`/`.pkg`
downloads as fallbacks. See
[`Supported Versions and Architechtures.txt`](Supported%20Versions%20and%20Architechtures.txt).

| File                                                | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Execute on macOS!/execute_all.sh`                | **One-shot orchestrator** - asks **up front** which stages to run (drivers / apps / settings) and whether to *"Migrate docker components?"* (only if a `docker_rebuild.sh` snapshot exists); runs them **unattended**; then handles manual-download apps **last** (type the installer's path in single quotes, or `skip`/`skip all`, with red errors + retry on a bad path). Also supports `--dry-run`. |
| `Execute on macOS!/install_must_have_software.sh` | Unattended **root installer** - installs every app flagged `Must be included on macOS = yes`, Cask-first with Homebrew-formula / Mac App Store / direct-download fallbacks. Installs Homebrew (and the Xcode Command Line Tools) itself if the Mac does not have it yet. |
| `Execute on macOS!/install_device_drivers.sh`     | **Root driver stage** - Apple driver/firmware updates, Rosetta 2, a hardware and kernel-extension report, printing/scanning, the vendor drivers macOS does not include, plus a reference list of the Windows devices detected. |
| `Execute on macOS!/apply_settings.sh`             | **Settings runner** - applies the captured Windows settings (display, lock, keyboard, mouse/trackpad, privacy, power, Wi-Fi, firewall, printers, Dock/login items, launchd jobs) with `defaults`, `pmset`, `systemsetup`, `networksetup`, `socketfilterfw`, `pfctl` and `launchctl`. |

### run_project.ps1 - Windows orchestrator

A wrapper that runs the three detection scripts and then the generator in one shot.
It lives in `Migrate to macOS/`; the sub-scripts live in `submodules/`.

```powershell
.\run_project.ps1
```

This runs in order:

1. `submodules/C_detect_windows_settings.ps1` → `documents/C_windows_configs.csv`
2. `submodules/B_detect_installed_windows_software.ps1` → `documents/B_installed_windows_software.csv`
3. `submodules/A_detect_installed_drivers.ps1` → `documents/A_installed_windows_drivers.csv`
4. `submodules/D_compile_and_generate_shell_script.ps1` → the universal installer set in `Execute on macOS!/`
5. Generates `Supported Versions and Architechtures.txt` dynamically from the manifest.
6. **User & application data backup** *(optional)* - offers (y/n, 15s timeout, default **yes**)
   to run `submodules/E_backup_user&application_data.ps1`, which packs your important user +
   application data into one password-protected archive on your Desktop. See
   [Step 6 - data backup & restore](#step-6---user--application-data-backup--restore).

Steps 1-3 need no administrator rights. If a step fails the pipeline stops unless
`-ContinueOnError` is passed. Use `-SkipDetection` to regenerate the scripts from
existing CSVs, or `-SkipGenerator` to only run detection. Use `-DataBackup`
(`--data-backup`) to run the full pipeline but auto-confirm the step-6 backup prompts, or
`-DataBackupOnly` (`--data-backup-only`) to skip detection/generation and **only** create
the data backup, non-interactively, in the default location.

#### Options

| Parameter                       | Default    | Purpose                                                                     |
| ------------------------------- | ---------- | --------------------------------------------------------------------------- |
| `-OutputDir <path>`           | documents/ | Directory where the three CSV files are written.                            |
| `-ContinueOnError`            | off        | Skip failed steps instead of stopping the pipeline.                         |
| `-SkipDetection`              | off        | Skip steps 1-3; regenerate the installer scripts from existing CSVs.        |
| `-SkipGenerator`              | off        | Skip step 4; only run detection.                                            |
| `-DataBackup` / `--data-backup` | off      | Run the **full** pipeline, but auto-confirm the step-6 backup: the "Back up now?" question is answered **yes with no timeout wait**, and E_'s low-disk-space confirmation is auto-answered yes too. Every other prompt (e.g. the password) is normal. |
| `-DataBackupOnly` / `--data-backup-only` | off | Skip detection + generation; **only** create the data backup (step 6) in the default location (Desktop) with no prompts at all - not even the low-space one. Encrypts if `-EncPwd`/`--enc_pwd` is given, else unencrypted. |
| `-ArchiveFormat` / `--archive-format` | `zip` | Backup archive format: `zip` (AES-256 zip via 7-Zip, default), `7z` (AES-256 7z with encrypted headers), or `enctar` (tar+gzip+OpenSSL). The required tool is auto-installed when needed (Windows: winget → Chocolatey → standalone 7-Zip download; macOS: Homebrew's `sevenzip`/`p7zip`). An **internet connection is required only if a tool must be installed**. If the tool for the chosen format truly can't be obtained automatically, the script says so **at the very start and exits** (suggesting: install it, pick another format, or drop the password so no encryption/tool is needed - an unencrypted `zip` needs no external tool at all). |
| `-EncPwd <secret>` / `--enc_pwd` | (prompt) | Transfer password used to encrypt exported secrets **and** the data backup. When given, the interactive password prompt is skipped. |
| `-MustIncludeThreshold <int>` | 70         | Forwarded to B script - minimum competency for "Must be included on macOS". |
| `-IncludeSystemComponents`    | off        | Forwarded to B script - keep redistributables / runtimes / drivers.         |
| `-IncludeStoreApps <bool>`    | $true      | Forwarded to B script - include filtered Store/UWP apps.                    |
| `-Online`                     | off        | Forwarded to B script - query repology.org live for unknown apps.           |
| `-IncludeVirtualDevices`      | off        | Forwarded to A script - keep ROOT\ and SW\ virtual devices.                 |
| `-IncludeMicrosoftInbox`      | off        | Forwarded to A script - keep generic Microsoft in-box drivers.              |

### Directory layout

```text
Migrate to macOS/
├─ run_project.ps1                         # Windows: orchestrator (detection 1-3 + generator 4)
├─ Additional_Manual_macOS_Software_Requirments.csv  # hand-curated hardcoded apps beyond the CSV
├─ Supported Versions and Architechtures.txt  # macOS releases (newest first, + "best for"), CPU architectures, minOS + channel coverage
├─ README.md
├─ README_fa.md                            # Persian translation of this file
│
├─ submodules/                             # Windows detection scripts + the generator
│  ├─ A_detect_installed_drivers.ps1
│  ├─ B_detect_installed_windows_software.ps1
│  ├─ C_detect_windows_settings.ps1
│  ├─ D_compile_and_generate_shell_script.ps1   # builds the universal installer set
│  ├─ E_backup_user&application_data.ps1   # step 6: packs important user+app data -> Desktop archive
│  ├─ docker_discovery.sh / .ps1           # snapshot Docker -> cross-platform rebuild script
│  └─ templates/                           # _common.sh engine + *.sh.tmpl (incl. restore_user_and_application_data)
│
├─ documents/                              # generated data + the manifest
│  ├─ A_installed_windows_drivers.csv
│  ├─ B_installed_windows_software.csv
│  ├─ B_applications.json                  # manifest with macOS-native-first install{} descriptors (cask / mas / brew / builtin)
│  ├─ D_data_migration.json                # step 6: what user/app data to back up + how to restore it
│  ├─ C_windows_configs.csv
│  ├─ settings_config.txt
│  └─ instructions.txt                     # reproducibility spec
│
├─ Execute on macOS!/                      # GENERATED: one universal set for ALL macOS versions + architectures
│  ├─ execute_all.sh                       # orchestrator: drivers -> apps -> settings
│  ├─ install_must_have_software.sh        # Cask-first installer, formula / Mac App Store / direct-download fallback
│  ├─ install_device_drivers.sh            # firmware / GPU / printing + device report
│  ├─ apply_settings.sh                    # Windows settings -> Mac
│  ├─ submodules/                          # generated stage scripts + restore_user_and_application_data.sh + D_data_migration.json
│  └─ docker_rebuild.sh                    # only if Docker was installed on the Windows source
│
└─ History/                                # archived previous versions of the generated scripts
```

The generated scripts in `Execute on macOS!/` are **universal**: they detect the
macOS release and CPU architecture at runtime, so the same set runs on every version
listed in [`Supported Versions and Architechtures.txt`](Supported%20Versions%20and%20Architechtures.txt) -
no per-version folders needed.

---

## Step 6 - user & application data backup & restore

Beyond apps, drivers and settings, the toolkit can carry your **important user files and
application data** across. It is data-driven by
[`documents/D_data_migration.json`](documents/D_data_migration.json).

**On Windows** (`submodules/E_backup_user&application_data.ps1`, offered at the end of
`run_project.ps1`):

- Collects the **static** important parts of your profile (`Desktop`, `Documents`,
  `Pictures`, `Music`, `Videos`, `Downloads`, `.gitconfig`, `.config`, …) plus **per-app**
  data described in the manifest (VS Code, `.claude`, Obsidian, PostgreSQL configs, Wine
  apps, …), matched by tight include/exclude regex.
- **Never backs up cloud-restorable data.** Anything under a cloud-sync root (OneDrive,
  Dropbox, Google Drive, iCloud, Box, …), any file flagged **online-only**, and **all
  browser profile data** are excluded - whether or not they are downloaded locally -
  because the service restores them on its own. `~/.ssh` and Contacts are excluded here too
  (they already travel in the encrypted settings archive) but are still listed for you.
- Packs everything into **one archive on your Desktop**, using the **same transfer password**
  as the rest of the toolkit. The format is chosen with `--archive-format`:
  - **`zip`** (default) - AES-256 encrypted ZIP, created via 7-Zip in a single compress+encrypt pass.
  - **`7z`** - AES-256 7z with **encrypted file names** (headers), also single-pass via 7-Zip.
  - **`enctar`** - `tar` + `gzip` (medium) + OpenSSL AES-256-CBC/PBKDF2 (streamed, so a 32-bit
    OpenSSL works on multi-GB data too).
  7-Zip (Windows) / p7zip (macOS) is **auto-installed when needed**. No password → an
  unencrypted archive (your choice). Live progress bars, size and free-space pre-checks (with a
  confirmation if it looks tight or exceeds 50 GB), and a neat `<source> --> <macOS target>`
  table are shown. Temp leftovers from this and any previous/aborted run are auto-cleaned; only
  the final archive + a `.log` remain on the Desktop.

**On macOS** (`submodules/restore_user_and_application_data.sh`, called by `execute_all.sh`
after settings, self-gating with an archive-path prompt / `s` to skip):

- Decrypts and, per application scope, applies a decision table keyed on
  `safe_to_transfer_to_corresponding_paths_for_macos` × the (4/10) "same/latest" answer:
  `yes` → restore to the corresponding macOS path; `yes-after-rewrite` → rewrite text
  configs (Windows→macOS paths, always keeping a `.bak`) then restore; `same version` →
  restore only if you chose "same"; `no` → place in a **deviated directory** of your choice.
- Static profile data always restores into your home. At the end it tells you where the
  deviated directory is and **warns you to promote that data by hand at your own risk and
  test each affected app afterwards** (a correct copy/rewrite never guarantees the app
  accepts the migrated state).

**Automatic / non-interactive backup:**
`.\run_project.ps1 --data-backup` runs the full pipeline and auto-confirms the two step-6
questions (backup + low-space) - yes, with no timeout wait - leaving other prompts normal.
`.\run_project.ps1 --data-backup-only` (optionally `--enc_pwd SECRET`) skips
detection/generation and creates just the archive in the default location with no prompts at all.

---

## Quick start - Run all Windows scripts

```powershell
# From the Migrate to macOS/ folder, in PowerShell 5.1 or PowerShell 7+:
.\run_project.ps1
```

This runs config → software → drivers in sequence. No administrator rights required.

### Options - Software inventory (standalone script)

| Parameter                       | Default                                                  | Purpose                                                                              |
| ------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `-OutputPath <path>`          | `B_installed_windows_software.csv` (beside the script) | Where to write the CSV.                                                              |
| `-MustIncludeThreshold <int>` | `70`                                                   | Minimum*Alternative Competency* (%) for **Must be included on macOS = yes**. |
| `-IncludeSystemComponents`    | off                                                      | Keep redistributables, runtimes and drivers.                                         |
| `-IncludeStoreApps <bool>`    | `$true`                                                | Include filtered Microsoft Store/UWP apps.                                           |
| `-Online`                     | off                                                      | Query repology.org live for unknown apps.                                            |

### The CSV columns (software inventory)

| Column                                        | Source  | Meaning                                                                                                                           |
| --------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **Name**                                | from PC | Human-friendly product name.                                                                                                      |
| **Version**                             | from PC | Installed version.                                                                                                                |
| **Publisher**                           | from PC | Vendor.                                                                                                                           |
| **Source**                              | from PC | `Win32` (registry) or `Store` (UWP/Appx).                                                                                     |
| **macOS Availability**                  | curated | Flags: Available on macOS, Native Alternative, Available as WebApp, etc.                                                          |
| **Best macOS Alternative**              | curated | The best macOS option. Free alt appended if paid.                                                                                 |
| **Alternative Competency**              | curated | Rough % vs Windows (≥100 = macOS is better).                                                                                     |
| **Pricing model**                       | curated | Free (FOSS), Free, Freemium, Shareware, or Paid.                                                                                  |
| **Must be included on macOS**           | derived | `yes` / `no` - computed from competency threshold.                                                                            |
| **Can be synched to macOS alternative** | curated | Whether the app's data auto-syncs into the macOS alternative by signing in (cloud):`Yes` or `No, manual transfer`.            |
| **macOS Alternative Type**              | curated | How the alternative is delivered - Native (Homebrew Cask), Native (Homebrew formula), Native (Mac App Store), Native (built into macOS), WebApp, Docker container, Wine/CrossOver; this drives the generated installer's method. |
| **Download URL**                        | curated | The official download or web-app URL for the chosen macOS alternative.                                                            |

### The CSV columns (settings migration - `C_windows_configs.csv`)

| Column                 | Source  | Meaning                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Category**     | from PC | One of ~26:`Power`, `Display`, `Keyboard`, `Mouse`, `Touchpad`, `Accessibility`, `Telemetry`, `Screen`, `Time`, `Locale`, `Proxy`, `Appearance`, `DefaultApps`, `Hosts`, `Printers`, `NetConfig`, `Wifi`, `Firewall`, `AutoUpdate`, `Shortcuts`, `Startup`, `Services`, `ScheduledTasks`, `SSH`, `Contacts`, `Wallpaper`. |
| **ConfigKey**    | from PC | Specific setting key (e.g.`lid_close_on_ac`, `resolution`, `lock_screen_timeout`, `wifi_profile`, `fw_rule`).                                                                                                                                                                                                                                                       |
| **WindowsValue** | from PC | The extracted value (e.g.`sleep`, `1920x1080`, `10 min` / `never`). Multi-field categories (Wi-Fi, firewall, shortcuts) pipe-pack their fields.                                                                                                                                                                                                                       |
| **macOSCommand** | from PC | Input language tags for keyboard mapping (optional).                                                                                                                                                                                                                                                                                                                          |
| **Notes**        | from PC | Human-readable note about the macOS mapping.                                                                                                                                                                                                                                                                                                                                  |
| **Phase**        | from PC | `pre` (applied before apps install) or `post` (after - needs the apps/desktop to exist).                                                                                                                                                                                                                                                                                  |
| **Scope**        | from PC | `System` (machine-wide) or `User` (GNOME keys, written as system-wide dconf defaults so they reach every user).                                                                                                                                                                                                                                                           |

### The CSV columns (driver inventory - `A_installed_windows_drivers.csv`)

Generate with `.\A_detect_installed_drivers.ps1` (no admin rights). Switches:
`-IncludeVirtualDevices` keeps `ROOT\`/`SW\`/`SWD\` software devices;
`-IncludeMicrosoftInbox` keeps generic Microsoft in-box drivers that need no macOS action.

| Column                          | Source  | Meaning                                                                                                                                                             |
| ------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Device Name**           | from PC | The PnP device's friendly name.                                                                                                                                     |
| **Device Class**          | from PC | PnP class (`Display`, `Net`, `Bluetooth`, `Printer`, …).                                                                                                   |
| **Manufacturer**          | from PC | Device manufacturer.                                                                                                                                                |
| **Driver Version**        | from PC | Installed driver version.                                                                                                                                           |
| **Driver Date**           | from PC | Driver date (`yyyy-MM-dd`).                                                                                                                                       |
| **Driver Provider**       | from PC | Who signs/provides the driver (NVIDIA, Microsoft, …).                                                                                                              |
| **Hardware ID**           | from PC | Bus ID (`PCI\VEN_10DE&DEV_…` / `USB\VID_…&PID_…`) - the reliable key to the silicon.                                                                         |
| **macOS Driver Status**   | curated | Flags: In-OS, Generic Driver, Vendor Driver, Not Supported, Not Applicable, Needs Review.                                                                           |
| **macOS Driver / Module** | curated | The macOS driver family or package (`IO80211Family`, `AppleHDA`, `IOUSBHostFamily`, AirPrint/CUPS, `ftdi-vcp-driver`, …).                                |
| **Vendor Download**       | curated | Manufacturer's macOS driver page, filled only when a vendor download is needed.                                                                                     |
| **Notes**                 | curated | Short note about the macOS situation.                                                                                                                               |
| **Must install on macOS** | derived | `yes` only when a vendor kext / DriverKit system extension / vendor installer is genuinely required; `no` when macOS already drives it, or when the device is PC-only and has no Mac counterpart at all. |

---

### The Additional_Manual_macOS_Software_Requirments.csv columns

This is a **hand-curated** file - it is NOT machine-generated by any PowerShell script.
It documents every application that the macOS installer installs through **hardcoded
logic** rather than through a simple "install the alternative listed in the CSV" path.
These fall into three groups:

| Group                                                  | Examples                                                                                              | Why hardcoded                                                                                                                                                                      |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Apps absent from the Windows PC**              | Telegram, Terminator, WindTerm, WinDirStat                                                            | These are useful additions that your Windows machine may not have installed. They're always included.                                                                              |
| **Apps needing custom install logic**            | Notepad++ (Wine + native), PowerToys (10 packages), WinRAR (Wine + native), IDM (Wine + native)       | These cannot be expressed as a single`apt install` command. They require Wine, multi-package splits, or special post-install steps.                                              |
| **Apps whose alternative IS the hardcoded path** | Advanced IP Scanner → Angry IP Scanner, Grammarly → LanguageTool, PowerToys → Rectangle + Raycast | The installer installs the ALTERNATIVE itself (used when the Windows app has no Mac build), and this alternative needs its own custom install logic (multi-package splits, Docker, manual downloads). |

| Column                                         | Source  | Meaning                                                                                                                |
| ---------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Name**                                 | curated | Human-readable name of the original Windows app or hardcoded inclusion.                                                |
| **Category**                             | curated | Functional category (PDF, Network, Editor, Utilities, etc.).                                                           |
| **Windows App?**                         | curated | Whether this app exists/doesn't on Windows, and whether it's a hardcoded inclusion.                                    |
| **In B_installed_windows_software.csv?** | curated | Whether a corresponding row appears in the machine-generated CSV.                                                      |
| **macOS Package(s)**                     | curated | The exact macOS package(s) installed - a Homebrew Cask, a Homebrew formula, a Mac App Store id, a built-in Apple app, Docker, or Wine.  |
| **Source / URL**                         | curated | The official source or download URL for the macOS package.                                                             |
| **Notes**                                | curated | Why this is hardcoded, what special logic the installer applies.                                                       |
| **Can be synched to macOS alternative**  | curated | Whether the app's data auto-syncs into the macOS alternative by signing in (cloud):`Yes` or `No, manual transfer`. |
| **macOS Alternative Type**               | curated | How the alternative is delivered (Native (Homebrew Cask/formula/Mac App Store/built into macOS), WebApp, Docker, Wine). |
| **Download URL**                         | curated | The official download or web-app URL for the macOS package.                                                            |

---

## How the macOS ratings are sourced

Recommendations are **researched from the web** and stored in the
`documents/B_applications.json` manifest, which `submodules/B_detect_installed_windows_software.ps1`
looks up offline for every installed app (each entry also carries the macOS
`install{}` descriptor the generator uses). To adjust a rating or add a new app, edit
that JSON manifest and re-run; apps missing from it are flagged `Needs Review`. The
optional `-Online` mode fills *unknown* apps via the Repology API.

For drivers, the mapping lives in the `$DriverKB` rule table in
`submodules/A_detect_installed_drivers.ps1`. Each device is classified from its **PnP class** and
the **PCI/USB vendor ID** embedded in its Hardware ID (first matching rule wins). To
re-rate a device or add a new chip, edit that table and re-run.

---

## ==Update the ma==nifest with AI

When you run `run_project.ps1`, any installed Windows app that is **not found in the
manifest** (`documents/B_applications.json`) is printed as a yellow **warning** listing
the unmatched app names (and the same list is shown again at the start of
`execute_all.sh` on macOS). Those apps get no macOS equivalent until you add them.

You don't have to write the manifest entries by hand. Open this project in any
AI coding agent (Claude Code, etc.) and paste the prompt below verbatim - it will run the
detector, read the warning list, and fill in the missing entries (plus refresh the
existing ones) with current data:

```text
Make a test-run of run_project.ps1 and see the list of applications that will be given as a warning for not being found on the manifest "Migrate to macOS\documents\B_applications.json".
Add them to the manifest with the latest avaiable data from the internet in manifest entries properties (also include "install" property) and format. 
Also in the end, update the already existing application list of the manifest with respect to the latest available versions,
best alternatives, download link, and everything else that can be updated. Strictly do not change anything else
```

After the agent finishes, re-run `run_project.ps1` and use the regenerated
`Execute on macOS!` scripts.

> Note: the `installedVersion` / `installedEdition` fields on each entry are **dynamic** -
> the toolkit refreshes them from your actual Windows install on every run, so you don't
> need to maintain them. Everything else in an entry is static curated data.

---

## Settings migration - structured output

When `apply_settings.sh` runs, every `_apply_*` function produces structured lines:

```
[INFO]  Windows 'sleep' → pmset -c sleep 20 / pmset -b sleep 10
[OK]    applied: sleep on power adapter = 20 min
[OK]    applied: sleep on battery = 10 min
[OK]    applied: lid -> sleep on close, wake on open

[INFO]  disabling macOS telemetry...
[OK]    applied: DiagnosticMessagesHistory.plist AutoSubmit = 0
[OK]    applied: com.apple.assistant.support Siri Data Sharing Opt-In Status = 2
[INFO]  skipped: com.apple.AdLib allowApplePersonalizedAdvertising (already set (false))

[ERROR] displayplacer could not set 2560x1440 (the mode may be unsupported on this display)
```

A summary prints at the end showing OK / Failed / Info-only counts.

**Firewall rules with Windows service-keyword ports.** Some Windows firewall rules use named ports (e.g. `PlayToDiscovery`, `mDNS`, `WSDEVENTS`, `RPC-EPMap`) instead of numbers. Known keywords are translated to their real port (e.g. `PlayToDiscovery`→3702, `mDNS`→5353); any keyword without a portable macOS equivalent is **skipped with a note** rather than reported as a failure.

**Program-scoped firewall rules → the macOS Application Firewall.** A Windows rule can be bound to a specific `.exe` (or a service), and some rules allow a program on *any* port. On macOS that is the **native** shape of a firewall rule: the Application Firewall (`socketfilterfw`) allows or blocks **per application**, so these rules - which on Linux needed a third-party tool - are recreated directly against the installed `.app`. Plain **port** rules go into a dedicated **pf anchor** at `/etc/pf.anchors/migrate_to_macos`, referenced from `/etc/pf.conf`, validated with `pfctl -n` before it is loaded, and removable by deleting that one file.

---

## Transfer password & encrypted personal data

Your **secrets never travel in clear text.** A single **transfer password** (OpenSSL
AES-256-CBC / PBKDF2) protects everything sensitive the migration carries:

- **Wi-Fi pre-shared keys** - encrypted inline in `C_windows_configs.csv`.
- **Your `~/.ssh` (private keys included), Contacts folder and desktop wallpaper** -
  staged, `tar`'d, and encrypted into **one** file,
  `Execute on macOS!/migrated_user_data.tar.enc`. The clear-text staging directory is
  then **deleted**, so no unencrypted personal data is ever left on disk.

**On Windows:** `run_project.ps1` shows the project banner and asks for the password
**once, up front** (15-second timeout), then hands it to the settings detector. If you
skip it (or OpenSSL/`tar` aren't available), Wi-Fi is exported **without** passwords and
the personal-data bundle is simply **not created** - nothing is left in the clear. For
unattended runs, pass `-EncPwd "secret"` (aliases: `-enc_pwd`, `--enc_pwd=secret`).
OpenSSL is located on `PATH`, in Git-for-Windows, or installed via `winget` on demand.

**On macOS:** `execute_all.sh` asks for the same password **once, up front**, and
**verifies it actually decrypts the bundle** so a typo is caught immediately instead of
failing halfway through. If OpenSSL is missing it offers to install it (without it, your
sensitive data can't be restored). For unattended runs, pass `--dec_pwd "secret"` (or
`--dec_pwd=secret`). The bundle is unpacked during the **post** settings phase, restoring
`~/.ssh` (with `600`/`700` perms), `~/Documents/Migrated Contacts` and the wallpaper; Wi-Fi keys are
decrypted as each network is added with `networksetup` and stored in the System keychain.

> The **same** password must be used on both sides. Fonts are deliberately **not**
> bundled (they would bloat the archive) - the software installer asks for a font
> directory instead.

---

## Installing on macOS - Software

```bash
# On any supported macOS release (Catalina 10.15 → Tahoe 26 and newer), Apple Silicon or Intel:
sudo ./"Execute on macOS!/install_must_have_software.sh"
```

The installer is **unattended and idempotent**, with a clean progress display,
auto-detection of the target machine (macOS release codename + architecture), and two
log files. For downloads, a **live hash-bar progress indicator** is shown (`curl -#`).
For installations, only **installation progress** is displayed (no verbosity): Homebrew
prints its own per-package progress, and installers without a progress API (Wine,
`.pkg` scripts) show a non-interactive elapsed-time counter instead of verbose output.

Homebrew refuses to run as root, so every `brew` call is dropped back to the logged-in
user automatically. If Homebrew (or the Xcode Command Line Tools) is missing, the
installer sets it up first.

On failure, the script **prints the downloaded file's path and the exact manual
install command** so the user can retry. All downloads go to
`/opt/migrate-downloads/`, which is set **mode 0777 and owned by the invoking
non-root user** so files can be inspected or manually installed.

**PaperCut (hard-coded - the native client, never a substitute).** PaperCut's macOS
client (Print Deploy / User Client) is served by **your own PaperCut server**, which is
the trusted first-party source for it. Set `PAPERCUT_SERVER` (host) and optionally
`PAPERCUT_PORT` (default `9174`) at the top of the script - or as env vars - to install
it **unattended**:

```bash
sudo PAPERCUT_SERVER=printdeploy.example.com ./install_must_have_software.sh
```

If `PAPERCUT_SERVER` is not set (or the auto-download fails), the installer **defers to
the manual prompt at the end** and asks for the macOS client `.tar.gz` downloaded from
your server's client page (`https://<server>:9174`). Either way the **native PaperCut
client is installed - CUPS is never substituted**.

At the end of the automated installation, the script **prompts** the user to import
fonts from a directory. The font import mechanism:

1. Asks for a directory path containing font files (read from `/dev/tty`).
2. Recursively finds all font files in that directory (supports **all common font formats**:
   `.ttf`, `.otf`, `.ttc`, `.woff`, `.woff2`, `.pfa`, `.pfb`, `.afm`, `.pfm`, `.dfont`,
   `.otb`, `.bdf`, `.pcf`, `.gsf`, `.otc`, `.abf`, `.chr`, `.fnt`, `.mxf` -
   covering Windows, macOS, and macOS font types).
3. Copies them to `/usr/local/share/fonts/user-import/`.
4. Runs `fc-cache` to rebuild the font cache so applications (including Wine) see them.
5. Records the result (OK/SKIP/FAIL) in the results log.

Error handling:

- Non-existent or unreadable directory → reprompt or type `skip`.
- Directory contains no matching font files → warn and reprompt.
- Individual file copy failures → skip that file, continue with the rest.
- No tty (non-interactive environment) → skip silently.

### Custom post-install commands

Any app can carry **custom commands that run right after it installs**, declared once in the manifest as an `install.postInstall` array (a list of shell snippets). The generator emits them and the installer runs them **as the logged-in desktop user** (so `defaults` and other per-user settings take effect in the real GUI session) **only when the app was actually installed this run** - a failing command is reported but never fails the install. For example, **CopyQ** uses this to launch itself once after installing, with a note telling you to bind **Command+Shift+V** as the clipboard-history shortcut - the macOS answer to Windows' **Win+V**.

### Natively-available apps and always-included helpers

- **Apps Microsoft (and others) also ship for macOS** install as the **same app, natively** - e.g. **Microsoft SQL Server**: if it ran on the **host OS** on Windows it is installed natively from Microsoft's official repo (`mssql-server`, x86_64, Ubuntu/RHEL/SLES); if it ran as a **Docker container** it is recreated as a container by the Docker rebuild step. The two paths can't double‑install because they're chosen by how the app was detected.
- **macOS-only helpers you always want** can be marked `"forceInclude": true` in the manifest so they install **even though no matching Windows app exists to detect**. **CopyQ** (the clipboard manager that replaces the Windows Win+V history) is included this way.
- **Apps with an official install script** (manifest method `script`) install **automatically** instead of falling back to a manual prompt — e.g. **Ollama** via `https://ollama.com/install.sh`. The script is downloaded first (so an error/HTML page is never piped to a shell) and then run.

### Windows-only apps under Wine (the Windows emulator)

For apps with no native macOS build, the installer can **also install the original Windows program under Wine** if you answer **yes** to the last setup question, *"Install the non-cross-platform Windows applications under the Windows emulator (wine) too?"*

- Where a trusted official installer URL is recorded in the manifest (the `windowsInstaller` field; currently **Notepad++** and **WinRAR**), it is **downloaded and run automatically**. Otherwise you are asked for the installer path - type it **in single quotes**, a full path or one relative to your `~/Downloads` (any extension: `.exe`, `.msi`, `.bat`, …) - or `skip` / `skip all`.
- Each Wine app gets its **own isolated Wine prefix**, its **font/DPI scaled to 2.5×** for readability, and a small **`.app` bundle in `~/Applications`** for every Start-Menu shortcut the installer creates - so the Windows apps show up in Launchpad and Spotlight like native ones. Wine itself is the `wine-stable` Cask; on Apple Silicon **Rosetta 2 is installed automatically** because Wine is an x86_64 build.
- **32-bit apps are detected up front, not failed halfway.** macOS removed the 32-bit runtime in Catalina, so Wine on a Mac cannot run a 32-bit-only Windows installer at all. The installer inspects the executable (PE header / MSI Template field) before it starts and reports the app with the actual answer - **CrossOver** (which ships its own 32-bit layer) or a Windows VM - instead of letting Wine fail with a cryptic `c0000135`. 64-bit apps are unaffected.
- **A crashing installer doesn't lose the app.** Under Wine many installers exit with an error by crashing on a *final* step (a missing Gecko/HTML pane, a "run now" launch) **after** the program is already installed. If the installer errors but the app's files/shortcut are present, it's recorded as **installed‑but‑unverified** (with launchers created) instead of failed — a true failure (nothing installed) still reports the error and how to reproduce it.
- **Installs never hang the script.** Many Windows installers auto-launch the app (or a tray/updater) when they finish, which used to keep the script stuck inside Wine. The installer now runs in the background with a timeout (`MIGRATE_WINE_INSTALL_TIMEOUT`, default 600s) and then runs `wineserver -k` to close anything left running, so it always continues. If a *"Setup finished / Run now"* window appears, just **close it** to move on immediately. (Because each app has its own prefix that's cleared after install, Wine also won't hit Windows' *"another setup is already running"* error.)
- **Re-runs don't re-install (and don't bloat the UI).** If an app is already installed in its prefix, a later run **skips** re-installing it. The DPI is always an **absolute** 2.5× (96→240), never multiplied by the current value, so it never accumulates; the growth some apps showed (e.g. IDM's toolbar) came from re-running the first-launch appearance setup every time. With `MIGRATE_UPDATE_EXISTING=yes` the app is **upgraded in place** — the prefix (and your data/settings) is kept and only the program binaries are refreshed; the **first-install appearance setup (DPI/window/tuning) is not redone**, so an upgrade preserves exactly what you have and can't bloat. If a prefix was already bloated by earlier runs, delete it once (`~/.local/share/wineprefixes/<app>`) to reinstall it clean.
- **First-launch appearance tuning** (interactive): right after a Wine app installs, the installer **launches it once so you can see it**, then walks you through its **visual settings** - **font scaling (DPI)** and **window size** - prompting for each with its current value (press Enter to keep it; bad input is rejected in red and re-asked). It then **closes the app, applies your values, relaunches it**, and asks whether the look is right: **`y`** = yes, **`r`** = start over, or **`a`** = yes and **apply the same settings to every later Wine install** automatically. (Skipped automatically when there is no interactive terminal, keeping the 2.5× default.)
- It is independent of the alternatives count: with alternatives **> 0** you get the macOS alternative(s) **and** the Wine version; with **0** you get **only** the Wine version. (That is why the "how many best alternatives" question says *"excluding wine"*.)

### Manual downloads - the installer-path prompt

Apps with no automatic installer are handled at the end. The installer tells you what to download, then asks for the file: type its path **in single quotes** - a full path, or one relative to your `~/Downloads` - or `skip` (this app) / `skip all` (every remaining manual app). The file is installed by its extension (`.dmg` is mounted and its `.app` copied to `/Applications`, `.pkg` runs through `installer`, `.zip`/`.tar.gz` are unpacked and their bundle installed, `.sh` is executed), Gatekeeper's quarantine flag is cleared, and the prompt shows the **macOS alternative's** name (what is being installed), not the original Windows app.

### Post-install verification and the uninstall script

- **Verification:** after each install the engine re-checks that the Cask / formula / Mac App Store app is actually present; if it cannot confirm, the app is reported as **`UNVERIFIED`** ("installed but unverified") rather than as a false success, so problems show up in the summary. An app you had already dragged into `/Applications` by hand is detected too, so it is skipped instead of reinstalled.
- **Uninstall:** everything installed is recorded and an **`uninstall_migrated_apps.sh`** is written to your home folder. Review it, then `bash ~/uninstall_migrated_apps.sh` (as your normal user - Homebrew must not run under sudo) to undo the run: Casks are removed with `brew uninstall --cask --zap`, formulae with `brew uninstall`; Mac App Store apps, file and Wine installs get a manual note.

---

## Installing on macOS - Settings

```bash
# On any supported macOS release, Apple Silicon or Intel:
cd "Execute on macOS!"
sudo ./apply_settings.sh
```

Runs as root. Prints structured output per setting, and **applies every setting to
all users** (GNOME keys via system-wide dconf defaults; the rest are system-wide by
nature). A reboot / re-login is recommended afterwards (display scaling, lock-screen
timeout, logind changes).

---

## Installing on macOS - Drivers

```bash
# On any supported macOS release, Apple Silicon or Intel:
cd "Execute on macOS!"
sudo ./install_device_drivers.sh
```

Runs as root with the same clean UI, spinner, and two log files as the software
installer. It **detects hardware live** and only installs what's actually present,
so it is safe to run on any machine - absent hardware is recorded as *skipped*, not
failed. Highlights:

- **In the OS by default:** Apple ships the drivers for graphics, Wi-Fi, Bluetooth,
  audio, webcams, NVMe, USB and HID inside macOS, so almost every device needs nothing.
- **Actively installed when needed:** USB-serial bridges (FTDI, CH34x, CP210x, PL2303),
  Wacom tablets and pro audio interfaces - each offered **only when the device is
  actually attached**.
- **Manufacturer firmware:** delivered by Apple through **Software Update**; the stage
  lists what is pending and offers to install it.
- **Rosetta 2** is installed on Apple Silicon so Intel-only software still runs.
- **Not supported, and said so:** NVIDIA GPUs and PC fingerprint readers have no macOS
  driver at all - they are reported as `Not Supported` rather than silently skipped.

A **reboot is recommended** after a driver run that installed a kernel extension - and
remember that a new kext must be **approved in System Settings > Privacy & Security**
before macOS will load it.

---

## Reproducing everything from scratch (AI agent)

[`instructions.txt`](documents/instructions.txt) is a self-contained specification: an AI engine
can read it alone and regenerate all PowerShell scripts, the CSVs, and each target-OS
installer with freshly-researched data. It includes **PART D - Settings Migration Spec**
and **PART E - Device Driver Migration Spec** (plus the `execute_all.sh` orchestrator).
This is the **only** part of the project that benefits from an AI agent - everyday use
(running the scripts and installers) does not.

## Continuous integration (CI)

A GitHub Actions workflow guards the "one script set runs unchanged on every macOS version" promise automatically: on each change it regenerates the installer scripts, then on the `macos-14` (Apple Silicon) and `macos-13` (Intel) runners it syntax-checks every script with the **bash 3.2 that ships with macOS** and runs the installer in `--dry-run`. Regressions surface in CI instead of on a user's Mac.

---

## Caveats

- **Competency is a deliberate rough estimate** for planning, not a benchmark.
- Ratings reflect the macOS landscape as of **June 2026** and will drift.
- The Wine **`windowsInstaller`** URLs in the manifest are **version-pinned** to a current release (no vendor offers a stable "latest" link), so they need an occasional bump when the app updates; if a URL ever 404s, the installer falls back to asking you for the file.
- Display resolution may not be replicable on different hardware.
- The installer scripts (`execute_all.sh`, `install_*`, `apply_settings.sh`) are
  **generated once** into `Execute on macOS!/` and are **universal** - the same set
  runs on every supported macOS release (each detects the version + CPU architecture at
  runtime). There are no per-version folders.
- **Hardware is detected live on the Mac**, not transcribed from Windows: the
  `A_installed_windows_drivers.csv` is a cross-reference, while `system_profiler`,
  `networksetup` and `kmutil` on the actual Mac are authoritative (Windows device names
  do not map onto Apple's driver families).
- **Homebrew Cask tokens drift.** A cask can be renamed or removed upstream; when one
  no longer exists the installer falls back to the vendor's download page instead of
  failing silently. Entries flagged `review: true` in the manifest are the ones to
  verify first on a real Mac.

## Requirements

**Windows (inventory + settings extract):**

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access only for `-Online` mode

**macOS (installers + settings apply):**

- Any supported macOS release (newest first) - Tahoe (26), Sequoia (15), Sonoma (14),
  Ventura (13), Monterey (12), Big Sur (11) or Catalina (10.15), on **Apple Silicon**
  (`arm64`) or **Intel** (`x86_64`); run as **root** (`sudo ./execute_all.sh`)
- Internet access for Homebrew / Mac App Store / vendor downloads
- For settings: `defaults`, `pmset`, `systemsetup`, `networksetup`, `launchctl`,
  `pfctl`, `socketfilterfw`, `lpadmin` - all part of macOS
- The installer bootstraps **Homebrew** (and the Xcode Command Line Tools) itself,
  adds `mas` when a Mac App Store app is needed, and installs Rosetta 2 on Apple
  Silicon when an Intel-only app or Wine requires it
- Everything is written for the **bash 3.2** and the BSD userland macOS ships, so no
  GNU coreutils are required

---

## Why migrate? macOS vs Windows

A balanced look at what you gain - and what you give up - so you can decide with
eyes open.

### Advantages of macOS over Windows

- **Free and open source** - no licence fees, no activation, source is auditable.
- **No forced telemetry or ads** - no Recall, no Start-menu ads, no account
  requirement; privacy is the default.
- **Lighter and faster** - runs well on old/low-RAM hardware; less background bloat.
- **Updates on your terms** - no surprise reboots; you choose when to update, and
  updates rarely break the machine.
- **One package manager for everything** - Homebrew installs and updates all of it
  with a single command instead of hunting installers across the web.
- **Stability and uptime** - servers run for years without reboots; far less
  "reinstall to fix it."
- **Powerful, scriptable shell** - bash/zsh + coreutils make automation trivial.
- **A certified UNIX with a real GUI** - zsh, coreutils, ssh, Python and the whole
  developer toolchain are there natively, with a commercially supported desktop on top
  (this is the trade Linux cannot offer).
- **Security by default** - System Integrity Protection, Gatekeeper, XProtect, app
  sandboxing, FileVault and the Secure Enclave are all on out of the box.
- **First-class commercial software** - Microsoft Office, Adobe Creative Cloud,
  AutoCAD, DaVinci Resolve, Logic Pro and Final Cut Pro all ship native Mac builds,
  which is exactly why this edition installs the real application instead of a
  substitute wherever one exists.
- **Hardware/software integration** - Apple Silicon's performance-per-watt, Retina
  colour management, Continuity/Handoff/AirDrop with an iPhone or iPad, and Time
  Machine backups that just work.

### Advantages of Windows over macOS (the honest list)

- **Commercial software** - Adobe Creative Cloud, Microsoft Office (full), many CAD,
  finance and engineering suites are Windows-only.
- **Gaming** - the largest native catalogue; anti-cheat in many online games blocks
  Wine/CrossOver and Apple's Game Porting Toolkit; some titles never work.
- **Hardware/peripheral support** - PC fingerprint readers, NVIDIA GPUs, internal
  expansion cards and exotic gadgets have no macOS driver at all; upgrades and repairs
  on a Mac are limited.
- **Price and configurability** - you cannot build your own Mac, and RAM/SSD are not
  user-upgradable on Apple Silicon.
- **Pro device ecosystems** - many music/recording, broadcast and lab tools assume
  Windows (or macOS).
- **Familiarity & support** - most workplaces, classrooms and help desks assume
  Windows; more "click here" tutorials exist.
- **Plug-and-play GPU/Optimus** - laptop GPU switching and vendor control panels are
  smoother out of the box.
- **Enterprise management** - Active Directory / Group Policy / Intune integration.

### For computer scientists & developers

- **The platform you deploy to** - servers, containers and the cloud are macOS; dev
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

## When there's no good macOS alternative

Some Windows apps and games have no strong native replacement. Pick a fallback by
how much native performance and integration you need. Roughly: **PWA < Wine/CrossOver
< container < VM < cloud/second machine**, trading convenience for fidelity. (Note that
Boot Camp does **not** exist on Apple Silicon - a VM is the dual-boot replacement.)

| Strategy                                                                     | Best for                                                               | Performance                    | Ease of use | Pros                                                              | Cons                                                                   |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------ | ----------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **Web app / PWA** (browser app-mode, the installer's `--webapp`)     | Apps with a good web version (Teams, WhatsApp, Office.com, Excalidraw) | Good (it's the website)        | ★★★★★  | No install, auto-updates, cross-platform, zero maintenance        | Needs internet; limited OS integration & offline/local-file access     |
| **Wine** (raw)                                                         | Small, well-behaved Windows apps                                       | Near-native CPU; GPU varies    | ★★        | No VM overhead; runs many`.exe` directly                        | Fiddly per-app tweaks; many apps break; no official support            |
| **CrossOver** (commercial Wine)                                        | Windows apps & older games, managed bottles                            | Near-native CPU                | ★★★★    | Paid but supported; its own 32-bit layer; Game Porting Toolkit backend | Still Wine underneath - not everything works; x86-only (Rosetta)   |
| **Game Porting Toolkit / Whisky**                                      | Windows games on Apple Silicon                                         | Varies (Metal translation)     | ★★★      | Apple's own D3D→Metal layer; runs some AAA titles                 | Developer-oriented; anti-cheat titles blocked; patchy compatibility  |
| **Cloud gaming / remote** (GeForce NOW, Xbox Cloud, Parsec, Moonlight) | AAA games, occasional Windows access                                   | Depends on network/latency     | ★★★★    | No local GPU needed; runs anything server-side                    | Subscription/another PC; latency; needs strong connection              |
| **Type-2 VM** (Parallels Desktop, VMware Fusion, UTM)                  | Office/CAD/dev tools needing real Windows                              | Good for desktop apps; weak 3D | ★★★★    | Full real Windows (ARM edition on Apple Silicon), snapshots, Coherence puts apps in the Dock | Heavy RAM/disk; weak 3D; licence needed; x86-only apps run emulated |
| **GPU-passthrough VM**                                                 | GPU/3D apps at near-native speed                                       | n/a on Apple Silicon           | -           | Possible only on older Intel Mac Pro hardware                     | Apple Silicon has no PCIe GPU passthrough; not an option on modern Macs |
| **Boot Camp** (Intel Macs only)                                        | Anything that must be 100% native (anti-cheat, pro hardware)           | Native (100%)                  | ★★        | Full performance & compatibility                                  | **Intel Macs only** - Apple Silicon cannot boot Windows at all         |
| **Container** (Docker Desktop / colima)                                | Server/CLI/dev software (databases, SQL Server, LanguageTool)          | Near-native (runs in a light VM)| ★★★      | Lightweight, reproducible, no GUI baggage                         | Linux containers only (not Windows GUI apps); amd64 images need Rosetta emulation |
| **Second machine / RDP**                                               | Rare, must-have Windows-only workloads                                 | Native on the other box        | ★★★      | Keep one Windows box; access remotely (RDP/Parsec)                | Cost of a second machine; remote-only                                  |

Rule of thumb on a Mac: try **the vendor's own Mac build → a native alternative →
PWA → Wine/CrossOver → container → VM (Parallels/UTM) → cloud or a second machine**,
stopping at the first that meets your performance and integration needs. On macOS the
first step succeeds far more often than it does on Linux, which is why this edition
puts it at the front of every list.
