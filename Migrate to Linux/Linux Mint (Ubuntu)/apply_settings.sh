#!/usr/bin/env bash
#
# apply_settings.sh
# -----------------------------------------------------------------------------
# Reads windows_configs.csv (produced by ../windows_settings_extract.ps1) and
# applies the extracted Windows settings to Linux.
#
# Run as root:   sudo ./apply_settings.sh
#
# Design:
#   * Sources settings_config.sh for the per-setting apply functions and the
#     dispatch table.
#   * Parses windows_configs.csv from the parent directory.
#   * For each CSV row, looks up the dispatch table and calls the right
#     function with the appropriate arguments.
#   * Fully unattended — no interactive prompts.
#   * Prints a summary at the end showing what was applied.
#
# Settings applied:
#   1. Power: lid-close action on battery and AC (→ logind.conf)
#   2. Display: resolution & scaling (→ xrandr + gsettings)
#   3. Keyboard: layout and shortcut reference (→ localectl + setxkbmap)
#   4. Telemetry + location: disable all known telemetry/geolocation services
#   5. Auto-update: install system_update.service + system_update.timer from repo
# -----------------------------------------------------------------------------

# Keep pipefail OFF so individual function failures don't kill the loop.
# Functions return non-zero to signal failure, which we check explicitly.
set -u

# ----------------------------- helpers ---------------------------------------
OK=(); FAIL=(); INFO=()

mark_ok()   { OK+=("$1");   printf '       \033[32mok:\033[0m %s\n' "$1"; }
mark_fail() { FAIL+=("$1"); printf '       \033[1;31mFAIL:\033[0m %s\n' "$1"; }
mark_info() { INFO+=("$1"); printf '       \033[2m%s\033[0m\n' "$1"; }

die() {
    printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '\033[1;31mThis script must run as root. Use: sudo %s\033[0m\n' "$0" >&2
        exit 1
    fi
}

# ----------------------------- header ----------------------------------------
require_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CSV_FILE="${PARENT_DIR}/windows_configs.csv"
SETTINGS_CONFIG="${SCRIPT_DIR}/settings_config.sh"

echo ""
echo "=============================================================================="
echo "  apply_settings.sh — Windows → Linux settings migration"
echo "=============================================================================="
echo ""
echo "  Script dir    : $SCRIPT_DIR"
echo "  CSV file      : $CSV_FILE"
echo "  Config source : $SETTINGS_CONFIG"
echo ""

# ----------------------------- validate inputs -------------------------------
if [ ! -f "$CSV_FILE" ]; then
    printf '\n\033[1;33mwindows_configs.csv not found at:\033[0m\n  %s\n\n' "$CSV_FILE"
    printf 'To generate it:\n'
    printf '  1. On your Windows machine, open PowerShell and run:\n'
    printf '       powershell -ExecutionPolicy Bypass -File windows_settings_extract.ps1\n'
    printf '  2. Copy the resulting windows_configs.csv to:\n'
    printf '       %s\n\n' "$PARENT_DIR"
    printf 'Alternatively, generate a sample CSV for testing with:\n'
    printf '  cd "%s"\n' "$PARENT_DIR"
    printf '  head -1 "%s" > windows_configs_sample.csv\n' "${SCRIPT_DIR}/../installed_windows_software.csv"
    printf '  echo ^"Power,lid_close_on_battery,sleep,,^" >> windows_configs_sample.csv\n\n'
    exit 1
fi

if [ ! -f "$SETTINGS_CONFIG" ]; then
    printf '\033[1;31msettings_config.sh not found at:\033[0m\n  %s\n' "$SETTINGS_CONFIG" >&2
    exit 1
fi

# Source the mapping/apply functions
# shellcheck source=settings_config.sh
source "$SETTINGS_CONFIG"

# Verify the dispatch table loaded correctly
if [ ${#SETTINGS_DISPATCH[@]} -eq 0 ]; then
    die "SETTINGS_DISPATCH table is empty after sourcing settings_config.sh — check the file."
fi

echo "Loaded ${#SETTINGS_DISPATCH[@]} config mappings from settings_config.sh"
echo ""

# ----------------------------- parse & apply CSV -----------------------------
echo "Reading settings from windows_configs.csv..."
echo ""

# Read header
IFS= read -r header_line < "$CSV_FILE" || die "Cannot read CSV header from $CSV_FILE"

# Remove BOM if present, strip quotes
header_line="${header_line#$'\xef\xbb\xbf'}"
header_line="${header_line//\"/}"

declare -A col_idx
i=0
IFS=',' read -ra headers <<< "$header_line"
for h in "${headers[@]}"; do
    h="$(echo "$h" | xargs)"   # trim
    col_idx["$h"]=$i
    ((i++))
done

# Validate required columns
required=("Category" "ConfigKey" "WindowsValue" "LinuxCommand" "Notes")
for col in "${required[@]}"; do
    if [ -z "${col_idx[$col]:-}" ]; then
        die "CSV missing required column '$col'. Found: ${headers[*]}"
    fi
done

# Build an indexed array of data lines so we don't depend on process substitution
data_lines=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    data_lines+=("$line")
done < <(tail -n +2 "$CSV_FILE")

if [ ${#data_lines[@]} -eq 0 ]; then
    printf '\033[1;33mWARNING: CSV has no data rows (only header found). Nothing to apply.\033[0m\n'
    echo "Make sure the CSV was generated correctly on the Windows machine."
    exit 0
fi

echo "Found ${#data_lines[@]} config rows to process."
echo ""

# Process each data row
row_num=1
for line in "${data_lines[@]}"; do
    row_num=$((row_num + 1))

    # Parse CSV row fields by column index
    category="$(echo   "$line" | cut -d',' -f$((col_idx["Category"] + 1))      | tr -d '"' | xargs)"
    config_key="$(echo "$line" | cut -d',' -f$((col_idx["ConfigKey"] + 1))     | tr -d '"' | xargs)"
    win_value="$(echo  "$line" | cut -d',' -f$((col_idx["WindowsValue"] + 1))  | tr -d '"')"
    lin_cmd="$(echo    "$line" | cut -d',' -f$((col_idx["LinuxCommand"] + 1))  | tr -d '"')"
    notes="$(echo      "$line" | cut -d',' -f$((col_idx["Notes"] + 1))         | tr -d '"')"

    echo "------------------------------------------------------------------------------"
    echo "[$category] $config_key"
    echo "  Windows value: $win_value"
    [ -n "$notes" ] && echo "  Notes: $notes"
    echo ""

    # Look up the dispatch table
    dispatch_key="${category}|${config_key}"
    func_name="${SETTINGS_DISPATCH[$dispatch_key]:-}"

    if [ -z "$func_name" ]; then
        mark_info "No Linux mapping defined for: $dispatch_key"
        echo "  Skipping — add a mapping in settings_config.sh if needed."
        echo ""
        continue
    fi

    # Call the apply function.  Stdout/stderr from the function flows directly to the terminal.
    # We use '|| true' on the function call to capture its exit code without
    # set -e aborting the script on non-zero return.
    rc=0
    if [[ "$func_name" == "_apply_power_lid" ]]; then
        logind_key="${POWER_LOGIND_KEY[$config_key]:-HandleLidSwitch}"
        rc=0; "$func_name" "$win_value" "$logind_key" || rc=$?
    elif [[ "$func_name" == "_apply_keyboard_layout" ]]; then
        rc=0; "$func_name" "$win_value" "$lin_cmd" || rc=$?
    else
        rc=0; "$func_name" "$win_value" || rc=$?
    fi

    if [ $rc -eq 0 ]; then
        mark_ok "$category / $config_key"
    else
        mark_fail "$category / $config_key"
    fi

    echo ""
done

# ----------------------------- summary ---------------------------------------
echo ""
echo "=============================================================================="
echo "  SUMMARY"
echo "=============================================================================="
echo ""
echo "  Applied successfully: ${#OK[@]}"
for item in "${OK[@]}"; do
    echo "    ✅ $item"
done
echo ""
if [ ${#FAIL[@]} -gt 0 ]; then
    echo "  Failed: ${#FAIL[@]}"
    for item in "${FAIL[@]}"; do
        echo "    ❌ $item"
    done
    echo ""
fi
if [ ${#INFO[@]} -gt 0 ]; then
    echo "  Info-only (no action taken): ${#INFO[@]}"
    for item in "${INFO[@]}"; do
        echo "    ℹ️  $item"
    done
    echo ""
fi

echo "  Done."
echo "  NOTE: A reboot (or at least re-login) is recommended to fully apply"
echo "        display scaling, logind.conf changes, and group memberships."
echo ""

exit $((${#FAIL[@]} > 0 ? 1 : 0))
