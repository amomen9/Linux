#!/usr/bin/env bash
#
# apply_settings.sh
# -----------------------------------------------------------------------------
# Reads C_windows_configs.csv (produced by ../C_detect_windows_settings.ps1) and
# applies the extracted Windows settings to Linux.
#
# Run as root:   sudo ./apply_settings.sh
#
# Design:
#   * SELF-CONTAINED — the per-setting apply functions and the dispatch table
#     live in THIS file (previously split into settings_config.sh, now merged).
#   * Parses C_windows_configs.csv from the parent directory.
#   * For each CSV row, looks up the dispatch table and calls the right
#     function with the appropriate arguments.
#   * Fully unattended — no interactive prompts.
#   * Prints a summary at the end showing what was applied.
#
# Settings applied:
#   1. Power: lid-close action on battery and AC (→ logind.conf)
#   2. Display: resolution (→ xrandr) & scaling (→ system-wide dconf)
#   3. Keyboard: layout and shortcut reference (→ localectl + setxkbmap)
#   4. Telemetry + location: disable all known telemetry/geolocation services
#   5. Auto-update: install system_update.service + system_update.timer from repo
#   6. Screen: lock-screen / blank timeout (→ system-wide dconf; "never" disables it)
#
# ALL-USERS GUARANTEE:
#   Every setting is applied so it affects EVERY user on the machine, not just root:
#     * logind.conf, systemd units, localectl, APT config, NetworkManager.conf,
#       service masking  → system-wide by nature.
#     * GNOME/desktop keys (scaling, location, lock-screen timeout) → written as
#       SYSTEM-WIDE dconf defaults in /etc/dconf/db/local.d (via _dconf_system_set),
#       NOT `gsettings set` as root (which would only touch root's own profile).
#       These take effect for every user (current + future) on their next login.
# -----------------------------------------------------------------------------

# Keep pipefail OFF so individual function failures don't kill the loop.
# Functions return non-zero to signal failure, which we check explicitly.
set -u

# ----------------------------- runner helpers --------------------------------
OK=(); FAIL=(); INFO=()

mark_ok()   { OK+=("$1");   printf '       \033[32mok:\033[0m %s\n' "$1"; }
mark_fail() { FAIL+=("$1"); printf '       \033[1;31mFAIL:\033[0m %s\n' "$1"; }
mark_info() { INFO+=("$1"); printf '       \033[2m%s\033[0m\n' "$1"; }

die() {
    printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2
    exit 1
}

# Trim leading/trailing whitespace.
_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# Parse ONE RFC4180-style CSV line into the global array CSV_FIELDS, honouring
# double-quoted fields that contain commas and "" escapes. The previous `cut -d,`
# approach mis-split quoted fields like "en-US, fa" (dropping the 2nd language) and
# truncated Notes containing commas — this parser does not.
CSV_FIELDS=()
parse_csv_line() {
    local line="${1%$'\r'}"          # strip a trailing CR (PowerShell writes CRLF)
    CSV_FIELDS=()
    local field="" in_q=0 i ch nx n=${#line}
    for (( i=0; i<n; i++ )); do
        ch="${line:i:1}"
        if [ "$in_q" -eq 1 ]; then
            if [ "$ch" = '"' ]; then
                nx="${line:i+1:1}"
                if [ "$nx" = '"' ]; then field+='"'; i=$((i+1)); else in_q=0; fi
            else
                field+="$ch"
            fi
        else
            case "$ch" in
                '"') in_q=1 ;;
                ',') CSV_FIELDS+=("$field"); field="" ;;
                *)   field+="$ch" ;;
            esac
        fi
    done
    CSV_FIELDS+=("$field")
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '\033[1;31mThis script must run as root. Use: sudo %s\033[0m\n' "$0" >&2
        exit 1
    fi
}

# =============================================================================
# SETTINGS APPLY FUNCTIONS  (merged in from the former settings_config.sh)
# =============================================================================

# ---------------------------------------------------------------------------
# STANDARDISED OUTPUT HELPERS
# Each _apply_* function uses these so the terminal gets structured
# success/error output: stdout = result, stderr = error detail.
# ---------------------------------------------------------------------------
_cfg_ok()    { printf '\033[32m  [OK]\033[0m    %s\n' "$1"; }
_cfg_info()  { printf '\033[2m  [INFO]\033[0m  %s\n' "$1"; }
_cfg_error() { printf '\033[1;31m  [ERROR]\033[0m %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# SYSTEM-WIDE dconf (ALL USERS)
# Write a GNOME/desktop key as a system-wide DEFAULT so it applies to EVERY user
# on the machine — not just root. This uses the dconf "local" system database
# (/etc/dconf/db/local.d), the documented mechanism for machine-wide GNOME
# defaults. Doing `gsettings set ...` as root would only change root's own
# profile and would NOT reach the actual users, so we never do that.
#
# Each (schema,key) pair gets its own small keyfile that we rewrite wholesale
# every run (idempotent); dconf merges them all on `dconf update`.
# ---------------------------------------------------------------------------
_DCONF_DB_DIR="/etc/dconf/db/local.d"
_DCONF_PROFILE="/etc/dconf/profile/user"

_dconf_system_set() {  # _dconf_system_set SCHEMA_PATH KEY GVARIANT_VALUE
    local schema="$1" key="$2" value="$3"

    # Ensure the dconf CLI exists (install best-effort; it's standard on GNOME).
    if ! command -v dconf >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y dconf-cli >/dev/null 2>&1 || true
    fi
    if ! command -v dconf >/dev/null 2>&1; then
        _cfg_error "dconf not available — cannot set ${schema}/${key} for all users"
        return 1
    fi

    mkdir -p "$_DCONF_DB_DIR" "$(dirname "$_DCONF_PROFILE")"

    # Make sure every user's dconf reads the system 'local' db (idempotent;
    # append rather than clobber any existing custom profile).
    if [ ! -f "$_DCONF_PROFILE" ]; then
        printf 'user-db:user\nsystem-db:local\n' > "$_DCONF_PROFILE"
    elif ! grep -q '^system-db:local' "$_DCONF_PROFILE" 2>/dev/null; then
        printf 'system-db:local\n' >> "$_DCONF_PROFILE"
    fi

    # Deterministic filename per (schema,key) so re-runs overwrite, not duplicate.
    local fname keyfile
    fname="$(printf '%s_%s' "$schema" "$key" | tr '/ ' '__' | tr -cd 'A-Za-z0-9_.-')"
    keyfile="${_DCONF_DB_DIR}/50-migrate-${fname}"
    printf '[%s]\n%s=%s\n' "$schema" "$key" "$value" > "$keyfile"

    if dconf update 2>/dev/null; then
        return 0
    else
        # A single malformed keyfile makes `dconf update` recompile-fail for the
        # WHOLE db, which would cascade to every later key. Remove the one we just
        # wrote and recompile so the rest of the run still succeeds.
        rm -f "$keyfile" 2>/dev/null || true
        dconf update 2>/dev/null || true
        _cfg_error "dconf update failed for ${schema}/${key} (reverted this key)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# POWER SETTINGS — Lid-close action (battery / AC)
#
# Windows value  →  logind action
#   do nothing      → ignore
#   sleep           → suspend
#   hibernate       → hibernate
#   shut down       → poweroff
#   turn off display → lock
# ---------------------------------------------------------------------------
_apply_power_lid() {
    local windows_value="$1"   # e.g. "sleep", "do nothing"
    local logind_key="$2"      # "HandleLidSwitch" or "HandleLidSwitchExternalPower"
    local any_error=0

    local action
    case "$windows_value" in
        "do nothing")       action="ignore"    ;;
        "sleep")            action="suspend"   ;;
        "hibernate")        action="hibernate" ;;
        "shut down")        action="poweroff"  ;;
        "turn off display") action="lock"      ;;
        *)                  action="suspend"   ;;  # safe default
    esac
    _cfg_info "Windows '$windows_value' → logind ${logind_key}=${action}"

    # Remove any existing uncommented directive from logind.conf
    if sed -i "/^${logind_key}=/d" /etc/systemd/logind.conf 2>/dev/null; then
        _cfg_ok "removed old ${logind_key}= from logind.conf"
    else
        _cfg_info "no existing ${logind_key}= in logind.conf"
    fi

    if echo "${logind_key}=${action}" >> /etc/systemd/logind.conf; then
        _cfg_ok "wrote ${logind_key}=${action} → /etc/systemd/logind.conf"
    else
        _cfg_error "failed to write ${logind_key}=${action} to logind.conf"
        any_error=1
    fi

    # Drop-in (survives distro upgrades)
    mkdir -p /etc/systemd/logind.conf.d
    if printf '[Login]\n%s=%s\n' "$logind_key" "$action" > "/etc/systemd/logind.conf.d/50-migrate-lid.conf" 2>/dev/null; then
        _cfg_ok "wrote /etc/systemd/logind.conf.d/50-migrate-lid.conf"
    else
        _cfg_error "failed to write drop-in"
        any_error=1
    fi

    if systemctl restart systemd-logind 2>/dev/null; then
        _cfg_ok "restarted systemd-logind"
    else
        _cfg_error "failed to restart systemd-logind (applies after reboot)"
        any_error=1
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# DISPLAY SETTINGS — Resolution & Scaling
# ---------------------------------------------------------------------------
_apply_display_resolution() {
    local resolution="$1"
    local any_error=0

    if [ -z "$resolution" ] || [ "$resolution" = "unknown" ]; then
        _cfg_info "no resolution extracted — using auto-detect"
        return 0
    fi

    local width="${resolution%x*}"
    local height="${resolution#*x}"
    if [ -z "$width" ] || [ -z "$height" ]; then
        _cfg_error "unparseable resolution '$resolution'"
        return 1
    fi

    _cfg_info "Windows was using ${width}x${height}"

    local display
    display="$(xrandr --listmonitors 2>/dev/null | awk 'NR==2 {print $NF}')"
    if [ -z "$display" ]; then
        _cfg_error "xrandr not available or no monitors"
        return 1
    fi
    _cfg_ok "primary display: $display"

    if xrandr 2>/dev/null | grep -q "${width}x${height}"; then
        if xrandr --output "$display" --mode "${width}x${height}" 2>/dev/null; then
            _cfg_ok "set resolution: ${display} → ${width}x${height}"
        else
            _cfg_error "xrandr failed to set ${width}x${height} on $display"
            return 1
        fi
    else
        _cfg_error "mode ${width}x${height} not available; keeping current"
        return 1
    fi

    return $any_error
}

_apply_display_scaling() {
    local scaling_pct="$1"
    local raw="${scaling_pct//%/}"
    local any_error=0

    if [ -z "$raw" ] || [ "$raw" = "unknown" ]; then
        raw=100
        _cfg_info "no scaling extracted — defaulting to 100%"
    fi

    # IMPORTANT: force the C locale so the decimal separator is a DOT, not a comma.
    # On locales like fa_IR/de_DE, awk prints "1,50", which is an invalid GVariant
    # double — `dconf update` then fails to compile the whole local.d db, cascading
    # the failure to every other dconf key in the run. "%.2f" always yields a valid
    # double (e.g. 1.50, 2.00), so no integer overrides are needed.
    local scale_factor
    scale_factor="$(LC_ALL=C awk "BEGIN {printf \"%.2f\", ${raw}/100}")"

    _cfg_info "Windows was at ${scaling_pct} → scale factor ${scale_factor} (applied for all users)"

    if [ "$raw" -gt 100 ]; then
        # Fractional text scaling for every user (system-wide dconf default).
        if _dconf_system_set "org/gnome/desktop/interface" "text-scaling-factor" "$scale_factor"; then
            _cfg_ok "set text-scaling-factor=${scale_factor} (all users)"
        else
            _cfg_error "failed to set text-scaling-factor"
            any_error=1
        fi

        # Integer window scaling (HiDPI) for every user.
        local int_scale=1
        [ "$raw" -ge 175 ] && int_scale=2
        [ "$raw" -ge 250 ] && int_scale=3
        [ "$raw" -ge 350 ] && int_scale=4
        if _dconf_system_set "org/gnome/desktop/interface" "scaling-factor" "uint32 ${int_scale}"; then
            _cfg_ok "set scaling-factor=${int_scale} (all users)"
        else
            _cfg_error "failed to set scaling-factor"
            any_error=1
        fi
    else
        _cfg_ok "scaling is 100% — no change needed"
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# KEYBOARD — Layout
# ---------------------------------------------------------------------------
_apply_keyboard_layout() {
    local windows_layout="$1"
    local input_languages="$2"
    local any_error=0

    _cfg_info "Windows layout: $windows_layout"
    [ -n "$input_languages" ] && _cfg_info "Windows input methods: $input_languages"

    _map_lang_to_xkb() {
        case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
            en-us|en-gb|en) echo "us"  ;; fa-ir|fa) echo "ir" ;;
            de-de|de)       echo "de"  ;; fr-fr|fr) echo "fr" ;;
            es-es|es)       echo "es"  ;; it-it|it) echo "it" ;;
            ja-jp|ja)       echo "jp"  ;; ko-kr|ko) echo "kr" ;;
            pt-br|pt)       echo "br"  ;; ru-ru|ru) echo "ru" ;;
            zh-cn|zh)       echo "cn"  ;; ar-sa|ar) echo "ara" ;;
            tr-tr|tr)       echo "tr"  ;; *)        echo "us" ;;
        esac
    }

    local layouts=()
    if [ -n "$input_languages" ]; then
        IFS=',' read -ra TAGS <<< "$input_languages"
        for tag in "${TAGS[@]}"; do
            tag="$(echo "$tag" | xargs)"
            local xkb; xkb="$(_map_lang_to_xkb "$tag")"
            if ! printf '%s\n' "${layouts[@]}" | grep -qF "$xkb"; then
                layouts+=("$xkb")
            fi
        done
    fi

    if [ ${#layouts[@]} -eq 0 ] && [ -n "$windows_layout" ]; then
        local tag
        tag="$(echo "$windows_layout" | grep -oP '\([^)]+\)' | tr -d '()')"
        [ -z "$tag" ] && tag="$(echo "$windows_layout" | awk '{print $NF}')"
        layouts+=("$(_map_lang_to_xkb "$tag")")
    fi
    [ ${#layouts[@]} -eq 0 ] && layouts=("us")

    local layout_str; layout_str="$(IFS=','; echo "${layouts[*]}")"
    _cfg_info "mapped to XKB: $layout_str"

    # Apply system-wide (ALL USERS). Prefer localectl; if it fails (no
    # systemd-localed, headless VM, D-Bus issues) write the very files localectl
    # would have written, so the layout still reaches every user.
    local applied=0
    if command -v localectl >/dev/null 2>&1 && localectl set-x11-keymap "$layout_str" 2>/dev/null; then
        _cfg_ok "localectl set-x11-keymap $layout_str (all users)"
        applied=1
    else
        _cfg_info "localectl unavailable/failed — writing keyboard config files directly"
        # /etc/default/keyboard — read by console-setup and Xorg (system-wide).
        if [ -f /etc/default/keyboard ] && grep -q '^XKBLAYOUT=' /etc/default/keyboard 2>/dev/null; then
            if sed -i "s|^XKBLAYOUT=.*|XKBLAYOUT=\"$layout_str\"|" /etc/default/keyboard 2>/dev/null; then
                _cfg_ok "updated XKBLAYOUT in /etc/default/keyboard (all users)"; applied=1
            else _cfg_error "failed to update /etc/default/keyboard"; fi
        else
            if printf 'XKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' "$layout_str" > /etc/default/keyboard 2>/dev/null; then
                _cfg_ok "wrote /etc/default/keyboard (all users)"; applied=1
            else _cfg_error "failed to write /etc/default/keyboard"; fi
        fi
        # /etc/X11/xorg.conf.d/00-keyboard.conf — system-wide X keyboard layout.
        mkdir -p /etc/X11/xorg.conf.d 2>/dev/null
        if printf 'Section "InputClass"\n        Identifier "system-keyboard"\n        MatchIsKeyboard "on"\n        Option "XkbLayout" "%s"\nEndSection\n' "$layout_str" > /etc/X11/xorg.conf.d/00-keyboard.conf 2>/dev/null; then
            _cfg_ok "wrote /etc/X11/xorg.conf.d/00-keyboard.conf (all users)"; applied=1
        else
            _cfg_info "could not write xorg.conf.d keyboard file (non-fatal)"
        fi
    fi
    [ "$applied" -eq 1 ] || any_error=1

    # Best-effort: also apply to the CURRENT X session for immediacy. This is not
    # counted as a failure — it can't work on Wayland or a headless/root session.
    if command -v setxkbmap >/dev/null 2>&1 && setxkbmap "$layout_str" 2>/dev/null; then
        _cfg_ok "setxkbmap $layout_str (current session)"
    else
        _cfg_info "setxkbmap not applied to this session (Wayland/headless/root) — takes effect on next login"
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# KEYBOARD — Shortcuts (informational only)
# ---------------------------------------------------------------------------
_apply_keyboard_shortcuts() {
    local shortcuts_note="$1"

    _cfg_info "Windows shortcuts detected:"
    while IFS=';' read -ra entries; do
        for entry in "${entries[@]}"; do
            entry="$(echo "$entry" | xargs)"
            [ -n "$entry" ] && _cfg_info "  $entry"
        done
    done <<< "$shortcuts_note"

    _cfg_ok "common Linux shortcut equivalents:"
    echo "    Win+E (File Explorer)    → Super+E"
    echo "    Win+L (Lock)             → Super+L"
    echo "    Win+D (Desktop)          → Super+D"
    echo "    Win+R (Run)              → Alt+F2"
    echo "    Alt+Tab (Switch)         → Alt+Tab (same)"
    echo "    Ctrl+Shift+Esc (TaskMgr) → Ctrl+Alt+Del"
    echo "    Win+Shift+S (Screenshot) → PrtSc"
    echo "    Copy/Paste/Cut/Undo      → Ctrl+C/V/X/Z (same)"
    return 0
}

# ---------------------------------------------------------------------------
# TELEMETRY — Disable all known telemetry/data-collection services
# ---------------------------------------------------------------------------
_apply_disable_telemetry() {
    local windows_level="$1"
    local any_error=0

    _cfg_info "Windows telemetry was: $windows_level"
    _cfg_info "disabling Linux telemetry..."

    local svc
    for svc in whoopsie apport apt-daily-upgrade.timer apt-daily.timer motd-news.timer packagekit; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            systemctl stop "$svc" 2>/dev/null || true
            if systemctl disable "$svc" 2>/dev/null && systemctl mask "$svc" 2>/dev/null; then
                _cfg_ok "disabled & masked: $svc"
            else
                _cfg_error "failed to mask: $svc"
                any_error=1
            fi
        else
            _cfg_info "not present: $svc"
        fi
    done

    if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
        sed -i 's/^/#/' /etc/apt/apt.conf.d/20apt-esm-hook.conf 2>/dev/null \
            && _cfg_ok "disabled ESM hook" \
            || { _cfg_error "failed to disable ESM hook"; any_error=1; }
    fi

    if [ -f /etc/default/apport ]; then
        sed -i 's/^enabled=1/enabled=0/' /etc/default/apport 2>/dev/null \
            && _cfg_ok "disabled apport (enabled=0)" \
            || { _cfg_error "failed to disable apport"; any_error=1; }
    fi

    if [ -f /etc/default/motd-news ]; then
        sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null \
            && _cfg_ok "disabled MOTD news" \
            || { _cfg_error "failed to disable MOTD news"; any_error=1; }
    fi

    for pkg in ubuntu-report popularity-contest; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" 2>/dev/null \
                && _cfg_ok "purged: $pkg" \
                || { _cfg_error "failed to purge: $pkg"; any_error=1; }
        fi
    done

    return $any_error
}

# ---------------------------------------------------------------------------
# LOCATION — Disable / limit location services
# ---------------------------------------------------------------------------
_apply_limit_location() {
    local windows_state="$1"
    local any_error=0

    _cfg_info "Windows location service: $windows_state"

    if systemctl list-unit-files 2>/dev/null | grep -q "geoclue"; then
        systemctl stop geoclue 2>/dev/null || true
        if systemctl disable geoclue 2>/dev/null && systemctl mask geoclue 2>/dev/null; then
            _cfg_ok "disabled & masked: geoclue"
        else
            _cfg_error "failed to mask geoclue"
            any_error=1
        fi
    else
        _cfg_info "geoclue not installed"
    fi

    # Disable GNOME location services for EVERY user (system-wide dconf default).
    if _dconf_system_set "org/gnome/system/location" "enabled" "false"; then
        _cfg_ok "location services disabled for all users (dconf)"
    else
        _cfg_error "failed to disable location via dconf"
        any_error=1
    fi

    if [ -f /etc/NetworkManager/NetworkManager.conf ] && ! grep -q "wifi.scan-rand-mac-address" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
        printf '[device]\nwifi.scan-rand-mac-address=yes\n' >> /etc/NetworkManager/NetworkManager.conf 2>/dev/null \
            && _cfg_ok "Wi-Fi MAC randomization on" \
            || { _cfg_error "failed to enable MAC randomization"; any_error=1; }
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# AUTO-UPDATE — Install system_update.service + system_update.timer
#
# Source: <repo_root>/Scheduled systemd Automatic Update/Debian/service files/
# This file lives at: <repo_root>/Migrate to Linux/Linux Mint (Ubuntu)/apply_settings.sh
# So go up 3 levels from our dir to reach repo_root.
# ---------------------------------------------------------------------------
_apply_auto_update_services() {
    local trigger="$1"  # "system_update"
    local any_error=0

    _cfg_info "installing system_update.service + system_update.timer"

    local mydir repo_root service_dir
    mydir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # mydir = .../Migrate to Linux/Linux Mint (Ubuntu)
    repo_root="$(cd "$mydir/../.." && pwd)"
    service_dir="${repo_root}/Scheduled systemd Automatic Update/Debian/service files"

    if [ ! -d "$service_dir" ]; then
        _cfg_error "service files dir not found: $service_dir"
        return 1
    fi
    _cfg_ok "source dir: $service_dir"

    local svc
    for svc in system_update.service system_update.timer; do
        local src="${service_dir}/${svc}"
        local dst="/etc/systemd/system/${svc}"

        if [ ! -f "$src" ]; then
            _cfg_error "source not found: $src"
            any_error=1
            continue
        fi

        if cp "$src" "$dst" 2>/dev/null && chmod 0644 "$dst" 2>/dev/null; then
            _cfg_ok "copied: $svc"
        else
            _cfg_error "copy failed: $svc"
            any_error=1
        fi
    done

    systemctl daemon-reload 2>/dev/null && _cfg_ok "daemon-reload" \
        || { _cfg_error "daemon-reload failed"; any_error=1; }

    systemctl enable system_update.timer 2>/dev/null && _cfg_ok "enabled system_update.timer" \
        || { _cfg_error "enable failed"; any_error=1; }

    systemctl start system_update.timer 2>/dev/null && _cfg_ok "started system_update.timer" \
        || { _cfg_error "start failed (retry after reboot)"; any_error=1; }

    return $any_error
}

# ---------------------------------------------------------------------------
# SCREEN — Lock-screen / blank timeout (applied to ALL users via dconf)
#
# Windows value  →  Linux action
#   "<N> min"        → blank after N*60s, lock enabled       (for every user)
#   "never" / 0      → DISABLE screen blanking AND locking   (for every user)
# This mirrors a Windows box that has no lock-screen timeout: on Linux the lock
# and the blank are turned off for everyone.
# ---------------------------------------------------------------------------
_apply_lock_screen_timeout() {
    local value="$1"
    local any_error=0

    _cfg_info "Windows screen-lock timeout: $value (applied for all users)"

    # Parse a leading number of minutes; anything non-numeric / never / 0 => disable.
    local secs=0
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        ""|never|0|0*min|unknown|disabled|none|off) secs=0 ;;
        *)
            local mins; mins="$(printf '%s' "$value" | grep -oE '[0-9]+' | head -1)"
            [ -n "$mins" ] || mins=0
            secs=$(( mins * 60 ))
            ;;
    esac

    if [ "$secs" -le 0 ]; then
        _cfg_info "→ DISABLING screen lock & blanking for all users"
        _dconf_system_set "org/gnome/desktop/session"     "idle-delay"              "uint32 0" \
            && _cfg_ok "idle-delay=0 (never blank) — all users"          || any_error=1
        _dconf_system_set "org/gnome/desktop/screensaver" "lock-enabled"            "false" \
            && _cfg_ok "screensaver lock-enabled=false — all users"      || any_error=1
        _dconf_system_set "org/gnome/desktop/screensaver" "idle-activation-enabled" "false" \
            && _cfg_ok "screensaver idle-activation=false — all users"   || any_error=1
    else
        _cfg_info "→ lock after ${secs}s for all users"
        _dconf_system_set "org/gnome/desktop/session"     "idle-delay"   "uint32 ${secs}" \
            && _cfg_ok "idle-delay=${secs}s — all users"                 || any_error=1
        _dconf_system_set "org/gnome/desktop/screensaver" "lock-enabled" "true" \
            && _cfg_ok "screensaver lock-enabled=true — all users"       || any_error=1
        _dconf_system_set "org/gnome/desktop/screensaver" "lock-delay"   "uint32 0" \
            && _cfg_ok "lock-delay=0 (lock immediately on blank) — all users" || any_error=1
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# DISPATCH TABLE — "Category|ConfigKey" → apply function
# NOTE: associative-array literals need [key]=value with NO spaces around '='.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
declare -A SETTINGS_DISPATCH=(
    ["Power|lid_close_on_ac"]="_apply_power_lid"
    ["Power|lid_close_on_battery"]="_apply_power_lid"
    ["Display|resolution"]="_apply_display_resolution"
    ["Display|scaling"]="_apply_display_scaling"
    ["Keyboard|layout"]="_apply_keyboard_layout"
    ["Keyboard|shortcuts_note"]="_apply_keyboard_shortcuts"
    ["Telemetry|telemetry_level"]="_apply_disable_telemetry"
    ["Telemetry|location_service"]="_apply_limit_location"
    ["AutoUpdate|install_service_files"]="_apply_auto_update_services"
    ["Screen|lock_screen_timeout"]="_apply_lock_screen_timeout"
)

# Mapping of which logind key each power ConfigKey corresponds to
# shellcheck disable=SC2034
declare -A POWER_LOGIND_KEY=(
    ["lid_close_on_ac"]="HandleLidSwitchExternalPower"
    ["lid_close_on_battery"]="HandleLidSwitch"
)

# ----------------------------- header ----------------------------------------
require_root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CSV_FILE="${PARENT_DIR}/C_windows_configs.csv"

echo ""
echo "=============================================================================="
echo "  apply_settings.sh — Windows → Linux settings migration"
echo "=============================================================================="
echo ""
echo "  Script dir : $SCRIPT_DIR"
echo "  CSV file   : $CSV_FILE"
echo ""

# ----------------------------- validate inputs -------------------------------
if [ ! -f "$CSV_FILE" ]; then
    printf '\n\033[1;33mC_windows_configs.csv not found at:\033[0m\n  %s\n\n' "$CSV_FILE"
    printf 'To generate it:\n'
    printf '  1. On your Windows machine, open PowerShell and run:\n'
    printf '       powershell -ExecutionPolicy Bypass -File C_detect_windows_settings.ps1\n'
    printf '  2. Copy the resulting C_windows_configs.csv to:\n'
    printf '       %s\n\n' "$PARENT_DIR"
    exit 1
fi

# Sanity-check the (in-file) dispatch table loaded correctly.
if [ ${#SETTINGS_DISPATCH[@]} -eq 0 ]; then
    die "SETTINGS_DISPATCH table is empty — the script is corrupted."
fi
echo "Loaded ${#SETTINGS_DISPATCH[@]} built-in config mappings."
echo ""

# ----------------------------- parse & apply CSV -----------------------------
echo "Reading settings from C_windows_configs.csv..."
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

    # Parse CSV row fields by column index (quote-aware: keeps commas inside fields).
    parse_csv_line "$line"
    category="$(_trim   "${CSV_FIELDS[${col_idx[Category]}]:-}")"
    config_key="$(_trim "${CSV_FIELDS[${col_idx[ConfigKey]}]:-}")"
    win_value="${CSV_FIELDS[${col_idx[WindowsValue]}]:-}"
    lin_cmd="${CSV_FIELDS[${col_idx[LinuxCommand]}]:-}"
    notes="${CSV_FIELDS[${col_idx[Notes]}]:-}"

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
        echo "  Skipping — add a mapping in the SETTINGS_DISPATCH table if needed."
        echo ""
        continue
    fi

    # Call the apply function.  Stdout/stderr from the function flows directly to the terminal.
    # We capture its exit code without set -e aborting the script on non-zero return.
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
echo "  ALL USERS: GNOME settings (scaling, location, lock-screen timeout) were"
echo "             written as system-wide dconf defaults in /etc/dconf/db/local.d,"
echo "             so they apply to every user on the next login. logind/systemd/"
echo "             localectl/APT changes are system-wide by nature."
echo "  NOTE: A reboot (or at least re-login) is recommended to fully apply"
echo "        display scaling, lock-screen timeout, logind.conf changes, and groups."
echo ""

exit $((${#FAIL[@]} > 0 ? 1 : 0))
