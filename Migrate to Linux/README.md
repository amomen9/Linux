# Migrate to Linux — Installed Software Audit

Tooling to inventory **everything installed on a Windows PC** and decide, app by app,
how to carry it over to Linux: whether it runs natively, what the best Linux alternative
is, how good that option is, what it costs, and whether it's worth installing at all —
then **install all the keepers on the target Linux machine, unattended**.

## Files

| File | What it is |
|------|------------|
| [`detect_installed_windows_software.ps1`](detect_installed_windows_software.ps1) | PowerShell script that scans the Windows PC and generates the CSV. |
| [`installed_windows_software.csv`](installed_windows_software.csv) | The generated report (9 columns, one row per app). |
| [`Linux Mint (Ubuntu)/install_must_have_software.sh`](Linux%20Mint%20(Ubuntu)/install_must_have_software.sh) | Unattended **root installer** for Linux Mint / Ubuntu that installs every app flagged `Must be included on Linux = yes`. |
| [`instructions.txt`](instructions.txt) | Self-contained spec to **reproduce** the script, CSV and per-OS installer from scratch with fresh data. |
| `installed_windows_software.repology-cache.json` | Created only when run with `-Online`; caches Repology lookups. Safe to delete. |

### Directory layout

```text
Migrate to Linux/
├─ detect_installed_windows_software.ps1   # Windows inventory + Linux rating
├─ installed_windows_software.csv          # generated report
├─ instructions.txt                        # reproducibility spec
├─ README.md
└─ Linux Mint (Ubuntu)/                     # one folder per target OS
   └─ install_must_have_software.sh         # generated unattended installer
```

Each subdirectory is named after a **target OS**; add a new target by creating a
folder and generating an installer in it (see [`instructions.txt`](instructions.txt)).

## End-to-end workflow

1. **Generate the report** — run the PowerShell script on the Windows PC (below).
2. **Review** `installed_windows_software.csv` — especially the `Must be included on Linux` column.
3. **Install on Linux** — copy the matching `<Target OS>/install_must_have_software.sh`
   to the new machine and run it as root (see [Installing on Linux](#installing-on-linux)).

## Quick start

```powershell
# From this folder, in PowerShell 5.1 or PowerShell 7+:
.\detect_installed_windows_software.ps1
```

No administrator rights are required. The script reads the registry and the current
user's Store packages (both read-only) and writes the CSV next to itself.

### Options

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-OutputPath <path>` | `installed_windows_software.csv` (beside the script) | Where to write the CSV. |
| `-MustIncludeThreshold <int>` | `70` | Minimum *Alternative Competency* (%) for **Must be included on Linux = yes**. |
| `-IncludeSystemComponents` | off | Keep redistributables, runtimes and drivers (normally filtered out). |
| `-IncludeStoreApps <bool>` | `$true` | Include filtered Microsoft Store / UWP apps. |
| `-Online` | off | For apps not in the built-in knowledge base, query [repology.org](https://repology.org) live to detect Linux packaging. |

```powershell
# Be stricter about what "must" be installed, and resolve unknown apps online:
.\detect_installed_windows_software.ps1 -Online -MustIncludeThreshold 80
```

## What the script does

1. **Collects** installed software from four sources:
   - `HKLM` 64-bit, `HKLM` 32-bit (`Wow6432Node`) and **`HKCU`** uninstall keys (Win32 apps),
   - `Get-AppxPackage` (Microsoft Store / UWP apps).
2. **Removes noise** so only software you actually use remains:
   - Windows updates / hotfixes / KBs / security updates / service packs,
   - sub-components parented to another product,
   - (unless `-IncludeSystemComponents`) redistributables, runtimes, drivers and SDK/installer fragments,
   - hardware/OS UWP junk (video & image extensions, speech packs, vendor control panels, runtimes).
3. **Cleans & de-duplicates** names: makes Store package IDs human-friendly
   (`Microsoft.WindowsCalculator` → `Windows Calculator`), strips architecture suffixes,
   and merges cosmetic Win32/Store duplicates while keeping genuinely distinct versions
   (e.g. three separate Python installs stay as three rows).
4. **Rates each app** against Linux using the built-in knowledge base, then writes the CSV.

## The CSV columns

| Column | Source | Meaning |
|--------|--------|---------|
| **Name** | from PC | Human-friendly product name. |
| **Version** | from PC | Installed version. |
| **Publisher** | from PC | Vendor. |
| **Source** | from PC | `Win32` (registry) or `Store` (UWP/Appx). |
| **Linux Availability** | curated | One or more flags (see below). |
| **Best Linux Alternative** | curated | The current best Linux option when not natively available. **If the recommended option is `Paid`, the best *free* alternative is appended too** (`…; free alternative: …`). |
| **Alternative Competency** | curated | Rough estimate of how the Linux app/alternative performs vs the Windows original. `100%` = on par, `<100%` = weaker, `>100%` = Linux option is better. Filled for natively-available apps too. |
| **Pricing model** | curated | Pricing of the recommended Linux option: `Free (FOSS)`, `Free`, `Freemium`, `Shareware` or `Paid`. |
| **Must be included on Linux** | derived | `yes` / `no` — see logic below. |

The first four columns are read **live from the machine** and are never hand-authored.
The four "curated" columns come from the knowledge base in the script; "Must be included"
is computed from the competency figures.

### Linux Availability flags

A row can carry several flags. They are always normalised to this fixed order:

1. `Available on Linux` — the same app has a native Linux build.
2. `Not Available` — no native Linux build of this exact app.
3. `Native Alternative` — a strong native Linux replacement exists (named in *Best Linux Alternative*).
4. `Available as WebApp` — usable in the browser / as a PWA.
5. `Linux Docker` — can run on Linux via a Docker container.
6. `Windows Emulator (Wine/Proton)` — runs under Wine / Proton / Bottles.

`Needs Review` appears when the script has no entry for an app (re-run with `-Online`
to try to resolve it automatically).

### "Must be included on Linux" logic

Computed by the script (not hand-set). A row is `yes` when **all** of these hold:

- it is *installable* on Linux — its availability includes `Available on Linux` or `Native Alternative` (web-only and not-available apps are `no`, since there's nothing to install);
- its **Alternative Competency** ≥ `-MustIncludeThreshold` (default 70%);
- it is the **single most competent build** of that product — duplicate installs of the
  same product (e.g. several Python versions, or the Win32 + Store copy of one app)
  collapse to one `yes`, picking the highest-competency / Win32 entry.

Lower the threshold to flag more apps, raise it to flag only the strongest options.

## How the Linux ratings are sourced (and how to change them)

Live, per-app scraping of "the best alternative" from PowerShell isn't reliable (there's
no free alternatives API and HTML scraping breaks constantly), so the recommendations are
**researched from the web (June 2026)** and baked into a single editable table — the
`$LinuxKB` array near the top-middle of the script. Each entry looks like:

```powershell
@{ P='Internet Download Manager';
   S='Not Available; Native Alternative';
   A='uGet (closest match) or Free Download Manager / JDownloader 2 / XDM; aria2 for CLI';
   C=85;
   Pr='Free (FOSS)' }
```

- `P` — regex matched against the app name (first match wins; list specific patterns first).
- `S` — the availability flags.
- `A` — the best alternative text.
- `C` — competency percentage (integer; may exceed 100).
- `Pr` — pricing model.
- `F` — *(optional)* the best **free** alternative; appended to `A` automatically when `Pr='Paid'`.

To adjust a rating or add a new app, edit that table and re-run — the machine columns are
regenerated and your curated values flow straight into the CSV. **Do not hand-edit the
machine columns in the CSV**; they are overwritten on every run.

The optional `-Online` mode fills *unknown* apps by querying the Repology API, which
reports how many Linux repositories package a given project.

## Installing on Linux

Once you have the CSV, install the keepers on the target machine with the matching
installer. For **Linux Mint / Ubuntu**:

```bash
sudo ./"Linux Mint (Ubuntu)/install_must_have_software.sh"
```

The installer is **unattended and idempotent**. It:

- installs the Linux counterpart of every row flagged `Must be included on Linux = yes`
  — the native app where available, otherwise the recommended alternative;
- prefers the distro's **native APT repos**, falling back to **vendor repos / `.deb`s**
  (Chrome, Edge, VS Code, Docker, **PostgreSQL via the official postgresql.org PGDG repo**,
  pgAdmin, DBeaver, AnyDesk, Proton VPN, Discord, Zoom, Parsec, GitKraken, …) and then
  **Flatpak** only where neither is clean (RealVNC, Teams, WhatsApp, LocalSend, …);
- installs build dependencies package managers won't pull (kernel headers, `dkms`,
  `gcc`/`make` for VMware's modules; a JRE for LanguageTool);
- runs the **update** path for anything already installed;
- handles **login-gated / manual downloads last** (VMware Workstation, SpotPlayer,
  Gurobi, and RStudio if its direct URL fails): it prompts you to drop the file in a
  named location and type `yes` (or `skip`), looping until the file is present;
- prints an OK / failed / skipped / manual summary at the end.

> Run it as **root**. A reboot afterwards is recommended (kernel modules, the `docker`
> group, and newly-enabled services).

## Reproducing everything from scratch

[`instructions.txt`](instructions.txt) is a self-contained specification: an AI engine
(or a person) can read it alone — without the original chat — and regenerate the
PowerShell script, the CSV and each target-OS installer with freshly-researched data.
The intended loop is: AI writes the `.ps1` → **you run it once** on the Windows PC → you
hand back the CSV → AI writes the installer for each target-OS subfolder.

## Caveats

- **Competency is a deliberate rough estimate** for planning, not a benchmark.
- Ratings reflect the Linux landscape as of **June 2026** and will drift over time.
- Anything left as `Needs Review` (e.g. ambiguous names) needs a human decision.
- The report describes *one machine*; re-run it on each PC you want to migrate.

## Requirements

**Inventory script (Windows):**

- Windows 10/11
- Windows PowerShell 5.1 or PowerShell 7+
- Internet access only for the optional `-Online` mode

**Installer (target machine):**

- Linux Mint or Ubuntu (APT base), run as **root**
- Internet access (downloads from the configured repos/vendors)
