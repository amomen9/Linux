#!/usr/bin/env bash
#
# execute_all.sh
# -----------------------------------------------------------------------------
# Single entry point for the whole Linux Mint (Ubuntu) migration. It makes the
# three migration scripts in this directory executable, then runs them in order:
#
#     1. SETTINGS  ->  apply_settings.sh            (Windows settings -> Linux)
#     2. APPS      ->  install_must_have_software.sh (must-have software)
#     3. DRIVERS   ->  install_device_drivers.sh     (device drivers + firmware)
#
# POLICY: continue-on-error. A failure in any one script is recorded but does NOT
# stop the others — the run always reaches the driver stage and prints a summary.
#
# Run as root (the child scripts each require root):
#     sudo ./execute_all.sh
#
# Each child script has its own clean UI and its own log files; this orchestrator
# only sequences them and reports which stages succeeded or failed.
# -----------------------------------------------------------------------------

set -uo pipefail

# Colours (fall back to empty strings if not a tty).
if [ -t 1 ]; then
  C_HEAD=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_FAIL=$'\033[1;31m'; C_SKIP=$'\033[1;33m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_HEAD=''; C_OK=''; C_FAIL=''; C_SKIP=''; C_DIM=''; C_RST=''
fi

# Always operate from this script's own directory so the child scripts resolve
# their relative paths (e.g. ../windows_configs.csv, ../installed_*_drivers.csv).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || { echo "Cannot cd to script directory: $SCRIPT_DIR" >&2; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf '%sThis script must run as root. Use: sudo %s%s\n' "$C_FAIL" "$0" "$C_RST" >&2
    exit 1
  fi
}
require_root

# Ordered stages:  "Label|script_filename"
STAGES=(
  "Settings (Windows -> Linux)|apply_settings.sh"
  "Apps (must-have software)|install_must_have_software.sh"
  "Drivers (devices + firmware)|install_device_drivers.sh"
)

STAGE_NAMES=();  STAGE_STATUS=();  STAGE_RC=()
FAILURES=0;  MISSING=0

printf '\n%s========================================================%s\n' "$C_HEAD" "$C_RST"
printf '%s  Migrate to Linux — running ALL stages (continue-on-error)%s\n' "$C_HEAD" "$C_RST"
printf '%s  Order: settings  ->  apps  ->  drivers%s\n' "$C_HEAD" "$C_RST"
printf '%s========================================================%s\n' "$C_HEAD" "$C_RST"

start_ts=$(date +%s)

run_stage() {  # run_stage "Label" "script.sh"
  local label="$1" script="$2"
  STAGE_NAMES+=("$label")

  printf '\n%s==> [%s] %s%s\n' "$C_HEAD" "$script" "$label" "$C_RST"

  if [ ! -f "$script" ]; then
    printf '%s    SKIPPED — %s not found in %s%s\n' "$C_SKIP" "$script" "$SCRIPT_DIR" "$C_RST"
    STAGE_STATUS+=("MISSING"); STAGE_RC+=("-"); MISSING=$((MISSING+1))
    return 0
  fi

  # Make it executable (the user asked for this explicitly).
  chmod +x "$script" 2>/dev/null || true

  # Run it, inheriting this terminal so the child's clean UI shows through.
  # The leading "./" + continue-on-error: never abort the orchestrator on failure.
  local rc=0
  "./$script" || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf '%s    OK — %s completed (exit 0)%s\n' "$C_OK" "$script" "$C_RST"
    STAGE_STATUS+=("OK")
  else
    printf '%s    FAILED — %s exited %s (continuing to the next stage)%s\n' "$C_FAIL" "$script" "$rc" "$C_RST"
    STAGE_STATUS+=("FAILED"); FAILURES=$((FAILURES+1))
  fi
  STAGE_RC+=("$rc")
  return 0
}

for entry in "${STAGES[@]}"; do
  label="${entry%%|*}"
  script="${entry##*|}"
  run_stage "$label" "$script"
done

elapsed=$(( $(date +%s) - start_ts ))

# ----------------------------- summary ---------------------------------------
printf '\n%s========================== SUMMARY ==========================%s\n' "$C_HEAD" "$C_RST"
for i in "${!STAGE_NAMES[@]}"; do
  case "${STAGE_STATUS[$i]}" in
    OK)      col="$C_OK" ;;
    FAILED)  col="$C_FAIL" ;;
    *)       col="$C_SKIP" ;;
  esac
  printf '  %s%-8s%s  %s  %s(exit %s)%s\n' \
    "$col" "${STAGE_STATUS[$i]}" "$C_RST" "${STAGE_NAMES[$i]}" "$C_DIM" "${STAGE_RC[$i]}" "$C_RST"
done
printf '%s-------------------------------------------------------------%s\n' "$C_DIM" "$C_RST"
printf '  Stages: %s total | %s%s OK%s | %s%s failed%s | %s%s missing%s | %ss elapsed\n' \
  "${#STAGE_NAMES[@]}" \
  "$C_OK"   "$(( ${#STAGE_NAMES[@]} - FAILURES - MISSING ))" "$C_RST" \
  "$C_FAIL" "$FAILURES" "$C_RST" \
  "$C_SKIP" "$MISSING" "$C_RST" \
  "$elapsed"
printf '\n  Per-stage logs live next to each script (see their own summaries above).\n'
printf '  A REBOOT is recommended after a full run (drivers, microcode, services).\n'
printf '%s=============================================================%s\n' "$C_HEAD" "$C_RST"

# Exit non-zero if any stage failed, so callers/automation can detect it — but we
# still ran every stage (continue-on-error). Missing scripts do not count as fail.
[ "$FAILURES" -eq 0 ]
