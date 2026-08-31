#!/usr/bin/env bash
# =============================================================
#  lib.sh  —  Shared functions for all provision scripts
#  Source this file; never execute directly.
# =============================================================

# ── Terminal colors ───────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Disable colors when not a terminal (e.g. redirected to log file
# but still tee'd, so check the real tty)
[[ ! -t 1 ]] && RED='' GREEN='' YELLOW='' BLUE='' CYAN='' \
    MAGENTA='' BOLD='' DIM='' NC=''

# ── Logging ───────────────────────────────────────────────────
log_info()   { echo -e "  ${GREEN}[INFO]${NC}    $*"; }
log_warn()   { echo -e "  ${YELLOW}[WARN]${NC}    $*"; }
log_error()  { echo -e "  ${RED}[ERROR]${NC}   $*" >&2; }
log_action() { echo -e "  ${BLUE}[ACTION]${NC}  $*"; }
log_ok()     { echo -e "  ${GREEN}[  OK  ]${NC}  $*"; }
log_skip()   { echo -e "  ${DIM}[SKIP]${NC}    $*"; }

section() {
    local title="$1" width=66
    local pad=$(( (width - ${#title} - 2) / 2 ))
    echo ""
    echo -e "${MAGENTA}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${MAGENTA}$(printf ' %.0s' $(seq 1 $pad)) ${BOLD}${title}${NC}"
    echo -e "${MAGENTA}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo ""
}

# ── Root guard ────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must be run as root:  sudo bash $0"
        exit 1
    fi
}

# ── Config loader ─────────────────────────────────────────────
# Finds and sources pizero.conf; validates required keys.
# Sets CONF_DIR to the directory containing pizero.conf so
# other scripts can locate sibling files.
load_config() {
    local caller_dir
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" 2>/dev/null && pwd || pwd)"

    local search=(
        "${caller_dir}/../pizero.conf"   # scripts/ → parent
        "${caller_dir}/pizero.conf"      # same dir
        "/etc/pizero/pizero.conf"        # installed system-wide
        "${HOME}/pizero.conf"
    )

    local found=""
    for p in "${search[@]}"; do
        local resolved
        resolved="$(realpath "$p" 2>/dev/null || true)"
        if [[ -f "$resolved" ]]; then
            found="$resolved"
            break
        fi
    done

    if [[ -z "$found" ]]; then
        log_error "pizero.conf not found. Copy the template first:"
        log_error "  cp pizero.conf.example pizero.conf   # then edit it"
        log_error "Searched:"
        for p in "${search[@]}"; do log_error "  $p"; done
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$found"
    CONF_DIR="$(dirname "$found")"
    log_info "Config: ${found}"

    # Validate required fields
    local ok=true
    for key in WIFI_SSID WIFI_PASSWORD WIFI_COUNTRY PI_HOSTNAME TIMEZONE; do
        if [[ -z "${!key:-}" ]]; then
            log_error "pizero.conf: required field '${key}' is empty"
            ok=false
        fi
    done
    $ok || exit 1

    # Provide safe defaults for optional fields
    WIFI_SECURITY="${WIFI_SECURITY:-wpa2}"
    HOTSPOT_SSID="${HOTSPOT_SSID:-PiZero-Fallback}"
    HOTSPOT_PASSWORD="${HOTSPOT_PASSWORD:-raspberry}"
    HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
    HOTSPOT_CHANNEL="${HOTSPOT_CHANNEL:-6}"
    HOTSPOT_TIMEOUT="${HOTSPOT_TIMEOUT:-60}"
    HEADLESS="${HEADLESS:-no}"
    OVERCLOCK="${OVERCLOCK:-none}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
}

# ── APT install helper ────────────────────────────────────────
# Only installs packages not already at ^ii state.
apt_ensure() {
    local missing=()
    for pkg in "$@"; do
        dpkg -l "$pkg" 2>/dev/null | grep -qE "^ii" || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_action "Installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" 2>&1 \
            | grep -v "^The following packages" \
            | grep -v "^Use 'sudo apt" \
            | grep -v "were automatically installed" \
            | tail -5
    fi
}

# ── Probe and write sysctl key ────────────────────────────────
# Writes key=value to file only if /proc/sys path exists in
# this kernel build. Silent no-op otherwise.
probe_sysctl() {
    local file="$1" key="$2" value="$3"
    local proc_path="/proc/sys/$(echo "$key" | tr '.' '/')"
    if [[ -f "$proc_path" ]]; then
        echo "${key} = ${value}" >> "$file"
        log_ok "sysctl: ${key} = ${value}"
    else
        log_skip "sysctl: ${key} — not in this kernel build"
    fi
}

# ── config.txt key setter ─────────────────────────────────────
# Sets key=value in /boot/firmware/config.txt; adds if absent.
set_config_txt() {
    local key="$1" value="$2"
    local cfg="/boot/firmware/config.txt"
    if grep -q "^${key}=" "$cfg" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$cfg"
    else
        echo "${key}=${value}" >> "$cfg"
    fi
}

# ── config.txt line presence ─────────────────────────────────
# Adds a full line if not already present (for dtoverlay etc.)
ensure_config_line() {
    local line="$1"
    local cfg="/boot/firmware/config.txt"
    # -qxF: whole-line, fixed-string match (no regex — a literal `^` here would
    # never match, re-appending the line on every run).
    grep -qxF "$line" "$cfg" 2>/dev/null || echo "$line" >> "$cfg"
}
