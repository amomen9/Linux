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
#   * Parses windows_configs.csv from the parent directory (where the PS1
#     writes it).
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

set -uo pipefail

# ----------------------------- helpers ---------------------------------------
OK=(); FAIL=(); INFO=()
mark_ok()   { OK+=("$1");   printf '       \033[32mok:\033[0m %s\n' "$1"; }
mark_fail() { FAIL+=("$1"); printf '       \033[1;31mFAIL:\033[0m %s\n' "$1"; }
mark_info() { INFO+=("$1"); printf '       \033[2m%s\033[0m\n' "$1"; }

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '\033[1;31mThis script must run as root. Use: sudo %s\033[0m\n' "$0"
        exit 1
    fi
}

# ----------------------------- header ----------------------------------------
require_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CSV_FILE="${PARENT_DIR}/windows_configs.csv"
SETTINGS_CONFIG="${PARENT_DIR}/settings_config.sh"

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
    echo "ERROR: windows_configs.csv not found at $CSV_FILE"
    echo ""
    echo "  Step 1: On your Windows machine, run in PowerShell:"
    echo "    .\\windows_settings_extract.ps1"
    echo "  Step 2: Copy the resulting windows_configs.csv to:"
    echo "    $PARENT_DIR/"
    echo "  Step 3: Run this script again."
    exit 1
fi

if [ ! -f "$SETTINGS_CONFIG" ]; then
    echo "ERROR: settings_config.sh not found at $SETTINGS_CONFIG"
    echo "  This file must be in the same directory as windows_settings_extract.ps1"
    exit 1
fi

# Source the mapping/apply functions
# shellcheck source=../settings_config.sh
source "$SETTINGS_CONFIG"

# ----------------------------- parse & apply CSV -----------------------------
echo "Reading settings from windows_configs.csv..."
echo ""

# Read the CSV header and find column indices.
# Expected columns: Category,ConfigKey,WindowsValue,LinuxCommand,Notes
# We parse by header name to be robust against column reordering.
IFS=',' read -r header_line < "$CSV_FILE"

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
for col in Category ConfigKey WindowsValue LinuxCommand Notes; do
    if [ -z "${col_idx[$col]:-}" ]; then
        echo "ERROR: CSV missing required column '$col'. Found: ${headers[*]}"
        exit 1
    fi
done

# Process each data row
row_num=1
while IFS= read -r line; do
    row_num=$((row_num + 1))
    [ -z "$line" ] && continue

    # Parse CSV row: handle quoted fields with commas inside them
    category="$(echo "$line" | cut -d',' -f$((col_idx["Category"] + 1)) | tr -d '"' | xargs)"
    config_key="$(echo "$line" | cut -d',' -f$((col_idx["ConfigKey"] + 1)) | tr -d '"' | xargs)"
    win_value="$(echo "$line" | cut -d',' -f$((col_idx["WindowsValue"] + 1)) | tr -d '"')"
    lin_cmd="$(echo "$line" | cut -d',' -f$((col_idx["LinuxCommand"] + 1)) | tr -d '"')"
    notes="$(echo "$line" | cut -d',' -f$((col_idx["Notes"] + 1)) | tr -d '"')"

    echo "------------------------------------------------------------------------------"
    echo "[$category] $config_key"
    echo "  Windows value: $win_value"
    [ -n "$notes" ] && echo "  Notes: $notes"

    # Look up the dispatch table
    dispatch_key="${category}|${config_key}"
    func_name="${SETTINGS_DISPATCH[$dispatch_key]:-}"

    if [ -z "$func_name" ]; then
        mark_info "No Linux mapping defined for: $dispatch_key"
        echo "  Skipping — add a mapping in settings_config.sh if needed."
        continue
    fi

    # Call the apply function.
    # Special handling for power: needs the logind key as second arg.
    if [[ "$func_name" == "_apply_power_lid" ]]; then
        logind_key="${POWER_LOGIND_KEY[$config_key]:-HandleLidSwitch}"
        if "$func_name" "$win_value" "$logind_key"; then
            mark_ok "$category / $config_key"
        else
            mark_fail "$category / $config_key"
        fi
    elif [[ "$func_name" == "_apply_keyboard_layout" ]]; then
        # Keyboard layout gets both WindowsValue (culture) and LinuxCommand (input languages)
        if "$func_name" "$win_value" "$lin_cmd"; then
            mark_ok "$category / $config_key"
        else
            mark_fail "$category / $config_key"
        fi
    else
        if "$func_name" "$win_value"; then
            mark_ok "$category / $config_key"
        else
            mark_fail "$category / $config_key"
        fi
    fi

    echo ""
done < <(tail -n +2 "$CSV_FILE")

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
