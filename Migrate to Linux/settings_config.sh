#!/usr/bin/env bash
#
# settings_config.sh
# -----------------------------------------------------------------------------
# MAPPING FILE between the settings extracted by windows_settings_extract.ps1
# (stored in windows_configs.csv) and the Linux shell commands to apply them.
#
# This file is SOURCED by apply_settings.sh. It provides:
#   1. Category-level setup/teardown functions.
#   2. A mapping table that translates each ConfigKey → Linux command.
#
# DO NOT run this file directly — use apply_settings.sh.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# STANDARDISED OUTPUT HELPERS
# Each _apply_* function MUST use these so apply_settings.sh gets structured
# success/error output (stdout = result, stderr = error detail).
# ---------------------------------------------------------------------------
_cfg_ok()    { printf '\033[32m  [OK]\033[0m    %s\n' "$1"; }
_cfg_info()  { printf '\033[2m  [INFO]\033[0m  %s\n' "$1"; }
_cfg_error() { printf '\033[1;31m  [ERROR]\033[0m %s\n' "$1" >&2; }

# Like grep -q but also captures the failure reason for _cfg_error.
# Usage: _check_svc EXISTS svc_name  → prints ok or error
_check_svc() {
    local what="$1" svc="$2"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        _cfg_ok "$what: $svc"
        return 0
    else
        _cfg_info "$what: $svc (not present — nothing to do)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# POWER SETTINGS — Lid-close action
#
# Windows values map to /etc/systemd/logind.conf directives:
#   do nothing       -> ignore
#   sleep            -> suspend
#   hibernate        -> hibernate
#   shut down        -> poweroff
#   turn off display -> lock
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
    _cfg_info "Windows value '$windows_value' → logind action '$action' (key=$logind_key)"

    # 1) Write to /etc/systemd/logind.conf
    if sed -i "/^${logind_key}=/d" /etc/systemd/logind.conf 2>/dev/null; then
        _cfg_ok "removed existing ${logind_key}= lines from logind.conf"
    else
        _cfg_info "no existing ${logind_key}= lines to remove in logind.conf"
    fi

    if echo "${logind_key}=${action}" >> /etc/systemd/logind.conf; then
        _cfg_ok "wrote ${logind_key}=${action} → /etc/systemd/logind.conf"
    else
        _cfg_error "failed to write ${logind_key}=${action} to /etc/systemd/logind.conf"
        any_error=1
    fi

    # 2) Drop-in for logind.conf.d (more robust against distro upgrades)
    mkdir -p /etc/systemd/logind.conf.d
    if printf '[Login]\n%s=%s\n' "$logind_key" "$action" > "/etc/systemd/logind.conf.d/50-migrate-lid.conf" 2>/dev/null; then
        _cfg_ok "wrote drop-in /etc/systemd/logind.conf.d/50-migrate-lid.conf"
    else
        _cfg_error "failed to write /etc/systemd/logind.conf.d/50-migrate-lid.conf"
        any_error=1
    fi

    # 3) Restart logind to pick up the change
    if systemctl restart systemd-logind 2>/dev/null; then
        _cfg_ok "restarted systemd-logind"
    else
        _cfg_error "failed to restart systemd-logind (the change will apply after reboot)"
        any_error=1
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# DISPLAY SETTINGS — Resolution & Scaling
#
# Note: Exact resolution replication may not be possible on a different machine.
# These commands set a reasonable default based on what was extracted.
# ---------------------------------------------------------------------------
_apply_display_resolution() {
    local resolution="$1"   # e.g. "1920x1080"
    local any_error=0

    if [ -z "$resolution" ] || [ "$resolution" = "unknown" ]; then
        _cfg_info "no resolution extracted from Windows — using auto-detect"
        return 0
    fi

    local width="${resolution%x*}"
    local height="${resolution#*x}"

    if [ -z "$width" ] || [ -z "$height" ]; then
        _cfg_error "unparseable resolution string '$resolution'"
        return 1
    fi

    _cfg_info "Windows was using ${width}x${height}"

    # Find the primary display
    local display
    display="$(xrandr --listmonitors 2>/dev/null | awk 'NR==2 {print $NF}')"
    if [ -z "$display" ]; then
        _cfg_error "xrandr not available or no monitors detected"
        return 1
    fi
    _cfg_ok "primary display detected: $display"

    # Check if this exact mode exists
    if xrandr 2>/dev/null | grep -q "${width}x${height}"; then
        if xrandr --output "$display" --mode "${width}x${height}" 2>/dev/null; then
            _cfg_ok "set resolution: ${display} → ${width}x${height}"
        else
            _cfg_error "xrandr failed to set ${width}x${height} on $display"
            return 1
        fi
    else
        _cfg_error "mode ${width}x${height} not available on this display; keeping current resolution"
        return 1
    fi

    return $any_error
}

_apply_display_scaling() {
    local scaling_pct="$1"   # e.g. "125%" or "100%"
    local raw="${scaling_pct//%/}"
    local any_error=0

    if [ -z "$raw" ] || [ "$raw" = "unknown" ]; then
        raw=100
        _cfg_info "no scaling extracted from Windows — defaulting to 100%"
    fi

    # Convert percentage to a scale factor (e.g. 125% -> 1.25)
    local scale_factor
    scale_factor="$(awk "BEGIN {printf \"%.2f\", ${raw}/100}")"

    # For integer scaling (100%, 200%), use integer value
    if [ "$raw" -eq 100 ]; then
        scale_factor=1
    elif [ "$raw" -eq 200 ]; then
        scale_factor=2
    fi

    _cfg_info "Windows was at ${scaling_pct} → scale factor ${scale_factor}"

    if ! command -v gsettings >/dev/null 2>&1; then
        _cfg_error "gsettings not available — cannot set display scaling"
        return 1
    fi

    # text-scaling-factor (font scaling) — only if >100%
    if [ "$raw" -gt 100 ]; then
        if gsettings set org.gnome.desktop.interface text-scaling-factor "$scale_factor" 2>/dev/null; then
            _cfg_ok "set GNOME text-scaling-factor to ${scale_factor}"
        else
            _cfg_error "failed to set GNOME text-scaling-factor"
            any_error=1
        fi

        # Integer scaling factor for the display
        if gsettings writable org.gnome.desktop.interface scaling-factor 2>/dev/null; then
            local int_scale=1
            [ "$raw" -ge 175 ] && int_scale=2
            [ "$raw" -ge 250 ] && int_scale=3
            [ "$raw" -ge 350 ] && int_scale=4
            if gsettings set org.gnome.desktop.interface scaling-factor "$int_scale" 2>/dev/null; then
                _cfg_ok "set GNOME scaling-factor to ${int_scale}"
            else
                _cfg_error "failed to set GNOME scaling-factor"
                any_error=1
            fi
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
    local windows_layout="$1"       # e.g. "English (United States) (en-US)"
    local input_languages="$2"      # comma-separated language tags, e.g. "en-US, fa-IR"
    local any_error=0

    _cfg_info "Windows layout: $windows_layout"
    [ -n "$input_languages" ] && _cfg_info "Windows input methods: $input_languages"

    # Map common Windows language tags to XKB layouts
    _map_lang_to_xkb() {
        local tag="$1"
        case "$(echo "$tag" | tr '[:upper:]' '[:lower:]')" in
            en-us|en-gb|en) echo "us"    ;;
            fa-ir|fa)       echo "ir"    ;;
            de-de|de)       echo "de"    ;;
            fr-fr|fr)       echo "fr"    ;;
            es-es|es)       echo "es"    ;;
            it-it|it)       echo "it"    ;;
            ja-jp|ja)       echo "jp"    ;;
            ko-kr|ko)       echo "kr"    ;;
            pt-br|pt)       echo "br"    ;;
            ru-ru|ru)       echo "ru"    ;;
            zh-cn|zh)       echo "cn"    ;;
            ar-sa|ar)       echo "ara"   ;;
            tr-tr|tr)       echo "tr"    ;;
            *)              echo "us"    ;;  # fallback
        esac
    }

    local layouts=()
    if [ -n "$input_languages" ]; then
        IFS=',' read -ra TAGS <<< "$input_languages"
        for tag in "${TAGS[@]}"; do
            tag="$(echo "$tag" | xargs)"  # trim whitespace
            local xkb
            xkb="$(_map_lang_to_xkb "$tag")"
            if ! printf '%s\n' "${layouts[@]}" | grep -qF "$xkb"; then
                layouts+=("$xkb")
            fi
        done
    fi

    # If we got no layouts from input languages, try parsing the culture string
    if [ ${#layouts[@]} -eq 0 ] && [ -n "$windows_layout" ]; then
        local tag
        tag="$(echo "$windows_layout" | grep -oP '\([^)]+\)' | tr -d '()')"
        if [ -z "$tag" ]; then
            tag="$(echo "$windows_layout" | awk '{print $NF}')"
        fi
        local xkb
        xkb="$(_map_lang_to_xkb "$tag")"
        layouts+=("$xkb")
    fi

    [ ${#layouts[@]} -eq 0 ] && layouts=("us")

    # Build the layout string (e.g. "us,ir")
    local layout_str
    layout_str="$(IFS=','; echo "${layouts[*]}")"

    _cfg_info "mapped to XKB layouts: $layout_str"

    # Apply via localectl (system-wide)
    if command -v localectl >/dev/null 2>&1; then
        if localectl set-x11-keymap "$layout_str" 2>/dev/null; then
            _cfg_ok "localectl set-x11-keymap $layout_str"
        else
            _cfg_error "localectl set-x11-keymap $layout_str failed"
            any_error=1
        fi
    else
        _cfg_error "localectl not available — cannot set keyboard layout system-wide"
        any_error=1
    fi

    # Also try setxkbmap for the current session
    if command -v setxkbmap >/dev/null 2>&1; then
        if setxkbmap "$layout_str" 2>/dev/null; then
            _cfg_ok "setxkbmap $layout_str (current session)"
        else
            _cfg_error "setxkbmap $layout_str failed"
            any_error=1
        fi
    else
        _cfg_info "setxkbmap not available (Wayland session?) — skipping"
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# KEYBOARD — Shortcuts (informational — print Windows → GNOME mappings)
# ---------------------------------------------------------------------------
_apply_keyboard_shortcuts() {
    local shortcuts_note="$1"

    _cfg_info "Windows shortcuts detected:"
    local printed=0
    while IFS=';' read -ra entries; do
        for entry in "${entries[@]}"; do
            entry="$(echo "$entry" | xargs)"
            [ -n "$entry" ] && _cfg_info "  $entry" && printed=1
        done
    done <<< "$shortcuts_note"

    # Print common GNOME equivalent shortcuts as a reference
    _cfg_ok "common Linux equivalents:"
    echo "    Win+E (File Explorer)    → Super+E  (GNOME Files)"
    echo "    Win+L (Lock Screen)      → Super+L  (lock screen)"
    echo "    Win+D (Show Desktop)     → Super+D  or Ctrl+Super+D"
    echo "    Win+R (Run dialog)       → Alt+F2   (Run command)"
    echo "    Alt+Tab (Switch windows) → Alt+Tab  (same)"
    echo "    Ctrl+Shift+Esc (Task Mgr)→ Ctrl+Alt+Delete → System Monitor"
    echo "    Win+Shift+S (Screenshot) → PrtSc   or Shift+PrtSc"
    echo "    Copy/Paste/Cut/Undo      → Ctrl+C/V/X/Z (same on Linux)"

    return 0
}

# ---------------------------------------------------------------------------
# TELEMETRY — Disable
# ---------------------------------------------------------------------------
_apply_disable_telemetry() {
    local windows_level="$1"
    local any_error=0

    _cfg_info "Windows telemetry level was: $windows_level"
    _cfg_info "disabling Linux telemetry/data-collection..."

    # Stop and disable known telemetry/data-collection services.
    local services=(
        "whoopsie"
        "apport"
        "apt-daily-upgrade.timer"
        "apt-daily.timer"
        "motd-news.timer"
        "packagekit"
    )

    for svc in "${services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
            systemctl stop "$svc" 2>/dev/null || true
            if systemctl disable "$svc" 2>/dev/null && systemctl mask "$svc" 2>/dev/null; then
                _cfg_ok "disabled & masked: $svc"
            else
                _cfg_error "failed to mask: $svc"
                any_error=1
            fi
        else
            _cfg_info "not present: $svc (skip)"
        fi
    done

    # Disable Ubuntu Pro/ESM nag messages
    if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
        if sed -i 's/^/#/' /etc/apt/apt.conf.d/20apt-esm-hook.conf 2>/dev/null; then
            _cfg_ok "disabled Ubuntu Pro ESM hook messages"
        else
            _cfg_error "failed to comment out /etc/apt/apt.conf.d/20apt-esm-hook.conf"
            any_error=1
        fi
    else
        _cfg_info "no ESM hook file — skip"
    fi

    # Disable crash reporting (apport)
    if [ -f /etc/default/apport ]; then
        if sed -i 's/^enabled=1/enabled=0/' /etc/default/apport 2>/dev/null; then
            _cfg_ok "disabled apport crash reporting (enabled=0)"
        else
            _cfg_error "failed to set enabled=0 in /etc/default/apport"
            any_error=1
        fi
    else
        _cfg_info "apport not installed — skip"
    fi

    # Suppress MOTD news
    if [ -f /etc/default/motd-news ]; then
        if sed -i 's/^ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null; then
            _cfg_ok "disabled MOTD news (ENABLED=0)"
        else
            _cfg_error "failed to set ENABLED=0 in /etc/default/motd-news"
            any_error=1
        fi
    else
        _cfg_info "motd-news config not found — skip"
    fi

    # Remove optional telemetry packages if installed
    local pkg_list=("ubuntu-report" "popularity-contest")
    for pkg in "${pkg_list[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            if DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" 2>/dev/null; then
                _cfg_ok "purged package: $pkg"
            else
                _cfg_error "failed to purge: $pkg"
                any_error=1
            fi
        else
            _cfg_info "package not installed: $pkg (skip)"
        fi
    done

    _cfg_ok "telemetry/services disabled"
    return $any_error
}

# ---------------------------------------------------------------------------
# LOCATION — Disable / Limit
# ---------------------------------------------------------------------------
_apply_limit_location() {
    local windows_state="$1"
    local any_error=0

    _cfg_info "Windows location service was: $windows_state"
    _cfg_info "disabling location services on Linux..."

    # Stop and disable geoclue (GNOME location service)
    if systemctl list-unit-files 2>/dev/null | grep -q "geoclue"; then
        systemctl stop geoclue 2>/dev/null || true
        if systemctl disable geoclue 2>/dev/null && systemctl mask geoclue 2>/dev/null; then
            _cfg_ok "disabled & masked: geoclue"
        else
            _cfg_error "failed to mask geoclue"
            any_error=1
        fi
    else
        _cfg_info "geoclue not installed — skip"
    fi

    # Disable location in GNOME settings via gsettings
    if command -v gsettings >/dev/null 2>&1; then
        if gsettings set org.gnome.system.location enabled false 2>/dev/null; then
            _cfg_ok "set org.gnome.system.location enabled=false"
        else
            _cfg_error "failed gsettings set org.gnome.system.location enabled false"
            any_error=1
        fi
    else
        _cfg_info "gsettings not available — skip GNOME location setting"
    fi

    # Wi-Fi MAC randomization for privacy
    if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
        if ! grep -q "wifi.scan-rand-mac-address" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
            if printf '[device]\nwifi.scan-rand-mac-address=yes\n' >> /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
                _cfg_ok "enabled Wi-Fi MAC randomization in NetworkManager"
            else
                _cfg_error "failed to write wifi.scan-rand-mac-address to NetworkManager.conf"
                any_error=1
            fi
        else
            _cfg_ok "Wi-Fi MAC randomization already enabled"
        fi
    else
        _cfg_info "NetworkManager.conf not found — skip Wi-Fi MAC randomization"
    fi

    _cfg_ok "location services disabled"
    return $any_error
}

# ---------------------------------------------------------------------------
# AUTO-UPDATE SERVICE FILES — Install system_update.service + .timer
#
# The source files live relative to this repository:
#   Scheduled systemd Automatic Update/Debian/service files/
# ---------------------------------------------------------------------------
_apply_auto_update_services() {
    local trigger="$1"  # always "system_update" from the PS1 script
    local any_error=0

    _cfg_info "installing system_update.service + system_update.timer"

    # Determine the repo root:
    #   apply_settings.sh is at:     Migrate to Linux/Linux Mint (Ubuntu)/apply_settings.sh
    #   service files are at:        Scheduled systemd Automatic Update/Debian/service files/
    # So from apply_settings.sh, the relative path is: ../../"Scheduled systemd Automatic Update"/Debian/"service files"
    local script_dir repo_root service_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/../.." && pwd)"
    service_dir="${repo_root}/Scheduled systemd Automatic Update/Debian/service files"

    if [ ! -d "$service_dir" ]; then
        _cfg_error "service files directory not found: $service_dir"
        return 1
    fi
    _cfg_ok "found service files directory: $service_dir"

    local services=("system_update.service" "system_update.timer")

    for svc in "${services[@]}"; do
        local src="${service_dir}/${svc}"
        local dst="/etc/systemd/system/${svc}"

        if [ ! -f "$src" ]; then
            _cfg_error "source file not found: $src"
            any_error=1
            continue
        fi

        if cp "$src" "$dst" 2>/dev/null && chmod 0644 "$dst" 2>/dev/null; then
            _cfg_ok "copied $svc → /etc/systemd/system/"
        else
            _cfg_error "failed to copy $svc to /etc/systemd/system/"
            any_error=1
            continue
        fi
    done

    if systemctl daemon-reload 2>/dev/null; then
        _cfg_ok "systemd daemon-reload"
    else
        _cfg_error "systemctl daemon-reload failed"
        any_error=1
    fi

    if systemctl enable system_update.timer 2>/dev/null; then
        _cfg_ok "enabled system_update.timer"
    else
        _cfg_error "failed to enable system_update.timer"
        any_error=1
    fi

    if systemctl start system_update.timer 2>/dev/null; then
        _cfg_ok "started system_update.timer"
    else
        _cfg_error "failed to start system_update.timer (may start on next reboot)"
        any_error=1
    fi

    return $any_error
}

# ---------------------------------------------------------------------------
# DISPATCH TABLE — maps CSV ConfigKey to apply function
#
# Format: "Category|ConfigKey" -> function_to_call
# The apply function receives the WindowsValue + optional extra column.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # These are all used programmatically by apply_settings.sh
declare -A SETTINGS_DISPATCH=(
    ["Power|lid_close_on_ac"]          ="_apply_power_lid"
    ["Power|lid_close_on_battery"]     ="_apply_power_lid"
    ["Display|resolution"]             ="_apply_display_resolution"
    ["Display|scaling"]                ="_apply_display_scaling"
    ["Keyboard|layout"]                ="_apply_keyboard_layout"
    ["Keyboard|shortcuts_note"]        ="_apply_keyboard_shortcuts"
    ["Telemetry|telemetry_level"]      ="_apply_disable_telemetry"
    ["Telemetry|location_service"]     ="_apply_limit_location"
    ["AutoUpdate|install_service_files"]="_apply_auto_update_services"
)

# Mapping of which logind key each power ConfigKey corresponds to
declare -A POWER_LOGIND_KEY=(
    ["lid_close_on_ac"]="HandleLidSwitchExternalPower"
    ["lid_close_on_battery"]="HandleLidSwitch"
)
