#!/usr/bin/env bash
#
# settings_config.sh
# -----------------------------------------------------------------------------
# Linux Mint (Ubuntu) — mapping between windows_configs.csv config keys
# and the Linux shell commands to apply them.
#
# This file is SOURCED by apply_settings.sh (same directory). It provides:
#   1. Structured output helpers (_cfg_ok / _cfg_info / _cfg_error).
#   2. Per-category _apply_* functions.
#   3. A dispatch table (SETTINGS_DISPATCH) that maps "Category|ConfigKey" → function.
#
# DO NOT run this file directly — use apply_settings.sh.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# STANDARDISED OUTPUT HELPERS
# Each _apply_* function MUST use these so the terminal gets structured
# success/error output: stdout = result, stderr = error detail.
# ---------------------------------------------------------------------------
_cfg_ok()    { printf '\033[32m  [OK]\033[0m    %s\n' "$1"; }
_cfg_info()  { printf '\033[2m  [INFO]\033[0m  %s\n' "$1"; }
_cfg_error() { printf '\033[1;31m  [ERROR]\033[0m %s\n' "$1" >&2; }

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

    local scale_factor
    scale_factor="$(awk "BEGIN {printf \"%.2f\", ${raw}/100}")"
    [ "$raw" -eq 100 ] && scale_factor=1
    [ "$raw" -eq 200 ] && scale_factor=2

    _cfg_info "Windows was at ${scaling_pct} → scale factor ${scale_factor}"

    if ! command -v gsettings >/dev/null 2>&1; then
        _cfg_error "gsettings not available"
        return 1
    fi

    if [ "$raw" -gt 100 ]; then
        if gsettings set org.gnome.desktop.interface text-scaling-factor "$scale_factor" 2>/dev/null; then
            _cfg_ok "set GNOME text-scaling-factor=${scale_factor}"
        else
            _cfg_error "failed to set text-scaling-factor"
            any_error=1
        fi

        if gsettings writable org.gnome.desktop.interface scaling-factor 2>/dev/null; then
            local int_scale=1
            [ "$raw" -ge 175 ] && int_scale=2
            [ "$raw" -ge 250 ] && int_scale=3
            [ "$raw" -ge 350 ] && int_scale=4
            if gsettings set org.gnome.desktop.interface scaling-factor "$int_scale" 2>/dev/null; then
                _cfg_ok "set GNOME scaling-factor=${int_scale}"
            else
                _cfg_error "failed to set scaling-factor"
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

    if command -v localectl >/dev/null 2>&1; then
        if localectl set-x11-keymap "$layout_str" 2>/dev/null; then
            _cfg_ok "localectl set-x11-keymap $layout_str"
        else
            _cfg_error "localectl failed"
            any_error=1
        fi
    else
        _cfg_error "localectl not available"
        any_error=1
    fi

    if command -v setxkbmap >/dev/null 2>&1; then
        if setxkbmap "$layout_str" 2>/dev/null; then
            _cfg_ok "setxkbmap $layout_str (current session)"
        else
            _cfg_error "setxkbmap failed"
            any_error=1
        fi
    else
        _cfg_info "setxkbmap not available (Wayland?) — skip"
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

    if command -v gsettings >/dev/null 2>&1; then
        if gsettings set org.gnome.system.location enabled false 2>/dev/null; then
            _cfg_ok "gsettings location enabled=false"
        else
            _cfg_error "gsettings location set failed"
            any_error=1
        fi
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
# We're at: <repo_root>/Migrate to Linux/Linux Mint (Ubuntu)/settings_config.sh
# So go up 3 levels from our dir to reach repo_root.
# ---------------------------------------------------------------------------
_apply_auto_update_services() {
    local trigger="$1"  # "system_update"
    local any_error=0

    _cfg_info "installing system_update.service + system_update.timer"

    # settings_config.sh is sourced from the distro dir, so ${BASH_SOURCE[0]}
    # may be relative. Use a resolved path.
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
# DISPATCH TABLE — "Category|ConfigKey" → apply function
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
declare -A SETTINGS_DISPATCH=(
    ["Power|lid_close_on_ac"]              ="_apply_power_lid"
    ["Power|lid_close_on_battery"]         ="_apply_power_lid"
    ["Display|resolution"]                 ="_apply_display_resolution"
    ["Display|scaling"]                    ="_apply_display_scaling"
    ["Keyboard|layout"]                    ="_apply_keyboard_layout"
    ["Keyboard|shortcuts_note"]            ="_apply_keyboard_shortcuts"
    ["Telemetry|telemetry_level"]          ="_apply_disable_telemetry"
    ["Telemetry|location_service"]         ="_apply_limit_location"
    ["AutoUpdate|install_service_files"]   ="_apply_auto_update_services"
)

# Mapping of which logind key each power ConfigKey corresponds to
# shellcheck disable=SC2034
declare -A POWER_LOGIND_KEY=(
    ["lid_close_on_ac"]="HandleLidSwitchExternalPower"
    ["lid_close_on_battery"]="HandleLidSwitch"
)
