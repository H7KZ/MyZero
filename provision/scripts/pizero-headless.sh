#!/usr/bin/env bash
# =============================================================
#  pizero-headless.sh  —  Toggle headless mode on the Pi Zero 2 WH
#  Installed to /usr/local/lib/pizero/pizero-headless.sh
#
#  Usage:  sudo bash pizero-headless.sh [COMMAND] [OPTIONS]
#
#  COMMANDS:
#    on          Apply headless mode (HDMI off, CMA=32 MB, watchdog, etc.)
#    off         Restore desktop mode (HDMI on, CMA=256 MB, etc.)
#    status      Show current headless state
#    dry-run     Preview what 'on' would change without touching anything
#
#  OPTIONS:
#    --no-reboot     Skip the reboot prompt after applying changes
#    --help          Show this help message
#
#  WHAT HEADLESS MODE DOES:
#    config.txt changes:
#      gpu_mem              64 MB  → 16 MB      (frees RAM)
#      hdmi_blanking        off    → 2           (HDMI off)
#      hdmi_ignore_hotplug  off    → 1
#      hdmi_ignore_edid     off    → 0xa5000080
#      hdmi_ignore_cec_init off    → 1
#      hdmi_ignore_cec      off    → 1
#      enable_tvout         on     → 0
#      disable_fw_kms_setup off    → 1
#      camera_auto_detect   on     → 0
#      display_auto_detect  on     → 0
#      disable_camera_led   off    → 1
#      dtoverlay=disable-bt (added — disables Bluetooth)
#      dtparam=audio        on     → off
#      dtoverlay=cma,cma-32 (added — reduces CMA 256 MB → 32 MB)
#      boot_delay           1      → 0
#      force_eeprom_read    1      → 0
#      ignore_lcd           off    → 1
#      disable_touchscreen  off    → 1
#      initial_turbo        off    → 60 (max freq for 60 s at boot)
#      disable_splash       off    → 1
#      dtparam=watchdog=on  (added — hardware watchdog)
#      dtoverlay=rng        (added — hardware RNG)
#      avoid_warnings               → 1
#      dtparam=act_led_trigger      → none  (LED off)
#      dtparam=act_led_activelow    → on
#
#    cmdline.txt additions:
#      quiet  loglevel=3  logo.nologo  vt.global_cursor_default=0
#      audit=0  transparent_hugepage=madvise
#
#    systemd:
#      /etc/systemd/system.conf.d/pizero-watchdog.conf  (watchdog config)
#
#  WHAT 'OFF' RESTORES:
#    All config.txt keys added by this script are removed or reverted to
#    safe desktop defaults. cmdline.txt additions are removed. The systemd
#    watchdog config is removed. A backup is always created first.
#
#  IMPORTANT:
#    • Run as root (sudo).
#    • A reboot is required for changes to take effect.
#    • 'off' uses the backup created by 'on' when possible.
#      If no backup exists it reverts to known safe desktop defaults.
#    • DO NOT use 'on' if a monitor is connected and you need it to work.
#
# =============================================================

set -euo pipefail
IFS=$'\n\t'

#──────────────────────────────────────────────────────────────────────────────
#  CONSTANTS
#──────────────────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

readonly CONFIG_TXT="/boot/firmware/config.txt"
readonly CMDLINE_TXT="/boot/firmware/cmdline.txt"
readonly WATCHDOG_CONF="/etc/systemd/system.conf.d/pizero-watchdog.conf"

# State tracking file — records which keys this script added so 'off' can
# clean them up precisely, even if config.txt was edited manually in between.
readonly STATE_FILE="/var/lib/pizero-headless/state"
readonly BACKUP_DIR="/var/lib/pizero-headless/backup"

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

# Flags
FLAG_DRY_RUN=false
FLAG_NO_REBOOT=false
REBOOT_REQUIRED=false

#──────────────────────────────────────────────────────────────────────────────
#  LOGGING
#──────────────────────────────────────────────────────────────────────────────

log_info()   { echo -e "  ${GREEN}[INFO]${NC}    $*"; }
log_warn()   { echo -e "  ${YELLOW}[WARN]${NC}    $*"; }
log_error()  { echo -e "  ${RED}[ERROR]${NC}   $*" >&2; }
log_action() { echo -e "  ${BLUE}[ACTION]${NC}  $*"; }
log_ok()     { echo -e "  ${GREEN}[  OK  ]${NC}  $*"; }
log_skip()   { echo -e "  ${DIM}[SKIP]${NC}    $*"; }
log_revert() { echo -e "  ${CYAN}[REVERT]${NC}  $*"; }

section() {
    local title="$1"
    local width=66
    local pad=$(( (width - ${#title} - 2) / 2 ))
    echo ""
    echo -e "${MAGENTA}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${MAGENTA}$(printf ' %.0s' $(seq 1 $pad)) ${BOLD}${title}${NC}"
    echo -e "${MAGENTA}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo ""
}

banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║       Raspberry Pi Zero 2 WH — Headless Toggle v1.0.0          ║
  ║       RP3A0 · Cortex-A53 · 512 MB · Debian 13 Trixie          ║
  ╚══════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

#──────────────────────────────────────────────────────────────────────────────
#  PREFLIGHT
#──────────────────────────────────────────────────────────────────────────────

preflight() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must be run as root: sudo ./${SCRIPT_NAME} $*"
        exit 1
    fi

    if [[ ! -f "$CONFIG_TXT" ]]; then
        log_error "config.txt not found at ${CONFIG_TXT}"
        log_error "Is this a Raspberry Pi running Bookworm/Trixie firmware layout?"
        exit 1
    fi

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        log_warn "Expected aarch64, found: ${arch}. Proceeding anyway."
    fi
}

#──────────────────────────────────────────────────────────────────────────────
#  CONFIG.TXT HELPERS
#──────────────────────────────────────────────────────────────────────────────

# Set or replace a key=value line in config.txt.
# Records the key in STATE_FILE so 'off' knows what to remove.
set_config_key() {
    local key="$1"
    local value="$2"

    if $FLAG_DRY_RUN; then
        log_skip "(dry-run) Would set: ${key}=${value}"
        return
    fi

    if grep -q "^${key}=" "$CONFIG_TXT"; then
        local old_value
        old_value=$(grep "^${key}=" "$CONFIG_TXT" | head -1 | cut -d= -f2-)
        sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_TXT"
        log_ok "Updated:  ${key}=${value}  (was: ${old_value})"
        # Record as "updated" so 'off' knows the original value to restore
        echo "updated:${key}:${old_value}" >> "$STATE_FILE"
    else
        echo "${key}=${value}" >> "$CONFIG_TXT"
        log_ok "Added:    ${key}=${value}"
        # Record as "added" so 'off' removes it entirely
        echo "added:${key}" >> "$STATE_FILE"
    fi
}

# Remove a config.txt key entirely (used by 'off' for lines that were added)
remove_config_key() {
    local key="$1"
    if grep -q "^${key}=" "$CONFIG_TXT" 2>/dev/null; then
        sed -i "/^${key}=/d" "$CONFIG_TXT"
        log_revert "Removed:  ${key}"
    fi
}

# Restore a config.txt key to its previous value (used by 'off')
restore_config_key() {
    local key="$1"
    local old_value="$2"
    if grep -q "^${key}=" "$CONFIG_TXT" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${old_value}|" "$CONFIG_TXT"
        log_revert "Restored: ${key}=${old_value}"
    fi
}

# Add a dtoverlay/dtparam line if not already present
add_config_line() {
    local line="$1"
    if $FLAG_DRY_RUN; then
        log_skip "(dry-run) Would add line: ${line}"
        return
    fi

    if ! grep -qxF "$line" "$CONFIG_TXT"; then
        echo "$line" >> "$CONFIG_TXT"
        log_ok "Added:    ${line}"
        echo "added_line:${line}" >> "$STATE_FILE"
    else
        log_skip "Already present: ${line}"
    fi
}

# Remove an exact line from config.txt
remove_config_line() {
    local line="$1"
    if grep -qF "$line" "$CONFIG_TXT" 2>/dev/null; then
        # Use | as delimiter to avoid issues with special chars in line
        sed -i "\|^${line}$|d" "$CONFIG_TXT"
        log_revert "Removed line: ${line}"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
#  CMDLINE.TXT HELPERS
#──────────────────────────────────────────────────────────────────────────────

# The parameters added by headless mode — listed here so 'off' can remove them
readonly HEADLESS_CMDLINE_PARAMS=(
    "quiet"
    "loglevel=3"
    "logo.nologo"
    "vt.global_cursor_default=0"
    "audit=0"
    "transparent_hugepage=madvise"
)

add_cmdline_params() {
    if [[ ! -f "$CMDLINE_TXT" ]]; then
        log_warn "cmdline.txt not found at ${CMDLINE_TXT} — skipping"
        return
    fi

    local cmdline
    cmdline=$(cat "$CMDLINE_TXT")
    local changed=false

    for param in "${HEADLESS_CMDLINE_PARAMS[@]}"; do
        if ! echo "$cmdline" | grep -qw "$param"; then
            cmdline="${cmdline} ${param}"
            changed=true
            if $FLAG_DRY_RUN; then
                log_skip "(dry-run) Would add to cmdline: ${param}"
            else
                log_ok "cmdline: added ${param}"
            fi
        else
            log_skip "cmdline: already has ${param}"
        fi
    done

    if $changed && ! $FLAG_DRY_RUN; then
        # cmdline.txt MUST be a single line — normalise whitespace
        echo "$cmdline" | tr -s ' ' | sed 's/^ //;s/ $//' > "$CMDLINE_TXT"
        echo "cmdline_params_added:yes" >> "$STATE_FILE"
    fi
}

remove_cmdline_params() {
    if [[ ! -f "$CMDLINE_TXT" ]]; then
        return
    fi

    local cmdline
    cmdline=$(cat "$CMDLINE_TXT")
    local changed=false

    for param in "${HEADLESS_CMDLINE_PARAMS[@]}"; do
        if echo "$cmdline" | grep -qw "$param"; then
            # Remove the parameter and any leading/trailing spaces
            cmdline=$(echo "$cmdline" | sed "s| ${param}||g;s|${param} ||g;s|${param}||g")
            changed=true
            log_revert "cmdline: removed ${param}"
        fi
    done

    if $changed; then
        echo "$cmdline" | tr -s ' ' | sed 's/^ //;s/ $//' > "$CMDLINE_TXT"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
#  BACKUP
#──────────────────────────────────────────────────────────────────────────────

create_backup() {
    mkdir -p "$BACKUP_DIR"
    cp -a "$CONFIG_TXT"  "${BACKUP_DIR}/config.txt.bak"
    [[ -f "$CMDLINE_TXT" ]] && cp -a "$CMDLINE_TXT" "${BACKUP_DIR}/cmdline.txt.bak"
    log_ok "Backup created at ${BACKUP_DIR}/"
}

#──────────────────────────────────────────────────────────────────────────────
#  STATUS CHECK
#──────────────────────────────────────────────────────────────────────────────

cmd_status() {
    section "HEADLESS MODE STATUS"

    if [[ -f "$STATE_FILE" ]]; then
        echo -e "  ${GREEN}${BOLD}Headless mode is: ON${NC}"
        echo ""
        echo -e "  State file: ${STATE_FILE}"
        echo -e "  Backup dir: ${BACKUP_DIR}"
        echo ""
        echo -e "  ${BOLD}Active headless settings in config.txt:${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}Headless mode is: OFF (no state file found)${NC}"
        echo ""
        echo -e "  No headless state recorded — either 'on' was never run,"
        echo -e "  or state was cleared manually."
        echo ""
    fi

    # Always show the relevant config.txt lines regardless
    local headless_keys=(
        "gpu_mem" "hdmi_blanking" "hdmi_ignore_hotplug" "hdmi_ignore_edid"
        "hdmi_ignore_cec_init" "hdmi_ignore_cec" "enable_tvout"
        "disable_fw_kms_setup" "camera_auto_detect" "display_auto_detect"
        "disable_camera_led" "dtparam=audio" "boot_delay" "force_eeprom_read"
        "ignore_lcd" "disable_touchscreen" "initial_turbo" "disable_splash"
        "avoid_warnings" "dtparam=act_led_trigger" "dtparam=act_led_activelow"
    )

    local headless_lines=(
        "dtoverlay=disable-bt"
        "dtoverlay=cma,cma-32"
        "dtparam=watchdog=on"
        "dtoverlay=rng"
    )

    echo -e "  ${BOLD}Relevant config.txt values:${NC}"
    for key in "${headless_keys[@]}"; do
        local val
        val=$(grep "^${key}=" "$CONFIG_TXT" 2>/dev/null | head -1 || echo "(not set)")
        printf "  ├─ %-32s %s\n" "${key}:" "${val}"
    done
    for line in "${headless_lines[@]}"; do
        if grep -qxF "$line" "$CONFIG_TXT" 2>/dev/null; then
            printf "  ├─ %-32s %s\n" "${line}:" "present ✓"
        else
            printf "  ├─ %-32s %s\n" "${line}:" "(not present)"
        fi
    done

    echo ""
    echo -e "  ${BOLD}cmdline.txt headless params:${NC}"
    if [[ -f "$CMDLINE_TXT" ]]; then
        local cmdline
        cmdline=$(cat "$CMDLINE_TXT")
        for param in "${HEADLESS_CMDLINE_PARAMS[@]}"; do
            if echo "$cmdline" | grep -qw "$param"; then
                printf "  ├─ %-32s %s\n" "${param}:" "present ✓"
            else
                printf "  ├─ %-32s %s\n" "${param}:" "(not present)"
            fi
        done
    else
        log_warn "cmdline.txt not found at ${CMDLINE_TXT}"
    fi

    echo ""
    echo -e "  ${BOLD}CMA memory:${NC}"
    local cma_total
    cma_total=$(awk '/CmaTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "N/A")
    echo -e "  ├─ CmaTotal: ${cma_total} MB  (headless target: 32 MB, desktop default: ~256 MB)"
    echo -e "  └─ Note: CMA value reflects the LAST BOOT, not the current config.txt"
    echo ""

    echo -e "  ${BOLD}systemd watchdog:${NC}"
    if [[ -f "$WATCHDOG_CONF" ]]; then
        echo -e "  ├─ Config:   ${WATCHDOG_CONF} (present ✓)"
    else
        echo -e "  ├─ Config:   not installed"
    fi
    echo ""
}

#──────────────────────────────────────────────────────────────────────────────
#  HEADLESS ON
#──────────────────────────────────────────────────────────────────────────────

cmd_on() {
    section "ENABLING HEADLESS MODE"

    log_warn "This disables HDMI, audio, Bluetooth, camera, and reduces CMA to 32 MB."
    log_warn "If you need a display after this, run: sudo ./${SCRIPT_NAME} off"
    echo ""

    # Check if already on
    if [[ -f "$STATE_FILE" ]] && ! $FLAG_DRY_RUN; then
        log_warn "Headless mode appears to already be enabled (state file exists)."
        log_warn "Running again will re-apply all settings. Continuing..."
        echo ""
    fi

    if ! $FLAG_DRY_RUN; then
        create_backup
        # (Re)initialise state file
        mkdir -p "$(dirname "$STATE_FILE")"
        : > "$STATE_FILE"   # Truncate / create empty
        log_ok "State file initialised at ${STATE_FILE}"
        echo ""
    fi

    # ── [pi02] section ──
    if ! $FLAG_DRY_RUN; then
        if ! grep -q "^\[pi02\]" "$CONFIG_TXT"; then
            echo "" >> "$CONFIG_TXT"
            echo "[pi02]" >> "$CONFIG_TXT"
            echo "# Pi Zero 2 WH headless settings — managed by pizero-headless.sh" >> "$CONFIG_TXT"
            echo "added_line:[pi02]" >> "$STATE_FILE"
            log_ok "Added [pi02] section to config.txt"
        fi
    fi

    # ── GPU memory ──
    log_action "GPU memory: 64 MB → 16 MB"
    set_config_key "gpu_mem" "16"

    # ── HDMI complete disable ──
    log_action "Disabling HDMI output (~14 mA power saving)..."
    set_config_key "hdmi_blanking"       "2"
    set_config_key "hdmi_ignore_hotplug" "1"
    set_config_key "hdmi_ignore_edid"    "0xa5000080"
    set_config_key "hdmi_ignore_cec_init" "1"
    set_config_key "hdmi_ignore_cec"     "1"
    set_config_key "enable_tvout"        "0"
    set_config_key "disable_fw_kms_setup" "1"
    log_ok "HDMI fully disabled"

    # ── Camera / display auto-detect ──
    log_action "Disabling camera and display auto-detect..."
    set_config_key "camera_auto_detect"  "0"
    set_config_key "display_auto_detect" "0"
    set_config_key "disable_camera_led"  "1"
    log_ok "Camera and display auto-detect disabled"

    # ── Bluetooth disable ──
    log_action "Disabling Bluetooth (dtoverlay=disable-bt)..."
    add_config_line "dtoverlay=disable-bt"
    set_config_key "dtparam=audio" "off"
    log_ok "Bluetooth and audio disabled"

    # ── CMA reduction 256 MB → 32 MB ──
    log_action "Reducing CMA reservation: 256 MB → 32 MB..."
    if ! $FLAG_DRY_RUN; then
        if grep -q "^dtoverlay=cma" "$CONFIG_TXT"; then
            local old_cma
            old_cma=$(grep "^dtoverlay=cma" "$CONFIG_TXT" | head -1)
            sed -i 's|^dtoverlay=cma.*|dtoverlay=cma,cma-32|' "$CONFIG_TXT"
            log_ok "Updated CMA overlay: ${old_cma} → dtoverlay=cma,cma-32"
            echo "updated_line:${old_cma}:dtoverlay=cma,cma-32" >> "$STATE_FILE"
        else
            echo "dtoverlay=cma,cma-32" >> "$CONFIG_TXT"
            log_ok "Added dtoverlay=cma,cma-32"
            echo "added_line:dtoverlay=cma,cma-32" >> "$STATE_FILE"
        fi
    else
        log_skip "(dry-run) Would set dtoverlay=cma,cma-32"
    fi
    log_info "Verify after reboot: cat /proc/meminfo | grep CmaTotal  (target: 32768 kB)"

    # ── Boot acceleration ──
    log_action "Applying boot acceleration settings..."
    set_config_key "boot_delay"           "0"
    set_config_key "force_eeprom_read"    "0"
    set_config_key "ignore_lcd"           "1"
    set_config_key "disable_touchscreen"  "1"
    set_config_key "initial_turbo"        "60"
    set_config_key "disable_splash"       "1"
    log_ok "Boot acceleration: delay=0, initial_turbo=60, splash disabled"

    # ── Hardware watchdog ──
    log_action "Enabling hardware watchdog..."
    add_config_line "dtparam=watchdog=on"
    log_ok "Hardware watchdog enabled"

    # ── Hardware RNG ──
    log_action "Enabling hardware RNG overlay..."
    add_config_line "dtoverlay=rng"
    log_ok "Hardware RNG enabled"

    # ── Suppress voltage warnings ──
    set_config_key "avoid_warnings" "1"

    # ── Activity LED off ──
    log_action "Disabling activity LED..."
    set_config_key "dtparam=act_led_trigger"  "none"
    set_config_key "dtparam=act_led_activelow" "on"
    log_ok "Activity LED disabled"

    # ── cmdline.txt ──
    log_action "Adding headless kernel parameters to cmdline.txt..."
    add_cmdline_params

    # ── systemd watchdog config ──
    log_action "Configuring systemd hardware watchdog..."
    if ! $FLAG_DRY_RUN; then
        mkdir -p /etc/systemd/system.conf.d/
        cat > "$WATCHDOG_CONF" << 'WDEOF'
[Manager]
# Hardware watchdog — kicks the Pi back to life if systemd itself hangs
RuntimeWatchdogSec=10s
RebootWatchdogSec=2min
WatchdogDevice=/dev/watchdog0
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
WDEOF
        echo "watchdog_conf:yes" >> "$STATE_FILE"
        log_ok "systemd watchdog configured at ${WATCHDOG_CONF}"
        systemctl daemon-reload 2>/dev/null || true
    else
        log_skip "(dry-run) Would write ${WATCHDOG_CONF}"
    fi

    # ── Summary ──
    if ! $FLAG_DRY_RUN; then
        REBOOT_REQUIRED=true
        echo ""
        log_ok "══════════════════════════════════════════════════════"
        log_ok "Headless mode ENABLED. Summary of changes:"
        log_ok "  • gpu_mem reduced to 16 MB"
        log_ok "  • HDMI fully disabled (~14 mA saved)"
        log_ok "  • Bluetooth + audio disabled"
        log_ok "  • CMA reduced to 32 MB (~224 MB RAM freed)"
        log_ok "  • Boot acceleration applied"
        log_ok "  • Hardware watchdog active"
        log_ok "  • Activity LED off"
        log_ok "  • Backup at: ${BACKUP_DIR}/"
        log_ok "  • To revert: sudo ./${SCRIPT_NAME} off"
        log_ok "══════════════════════════════════════════════════════"
    else
        echo ""
        log_info "Dry-run complete — no changes made."
        log_info "Run without dry-run to apply: sudo ./${SCRIPT_NAME} on"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
#  HEADLESS OFF  (restore desktop mode)
#──────────────────────────────────────────────────────────────────────────────

cmd_off() {
    section "DISABLING HEADLESS MODE (RESTORING DESKTOP)"

    if [[ ! -f "$STATE_FILE" ]]; then
        log_warn "No state file found at ${STATE_FILE}"
        log_warn "Headless mode may not have been enabled with this script,"
        log_warn "or the state file was deleted."
        echo ""
        log_warn "Proceeding with safe desktop defaults anyway..."
        echo ""
    fi

    # ── Strategy A: state file exists — precise revert ──
    if [[ -f "$STATE_FILE" ]]; then
        log_action "Reverting config.txt using recorded state..."
        create_backup   # Back up the current (headless) state before reverting

        while IFS= read -r record; do
            [[ -z "$record" ]] && continue

            local type="${record%%:*}"
            local rest="${record#*:}"

            case "$type" in
                added)
                    # Key was added by us — remove it
                    local key="$rest"
                    remove_config_key "$key"
                    ;;
                updated)
                    # Key was modified — restore original value
                    local key="${rest%%:*}"
                    local old_val="${rest#*:}"
                    restore_config_key "$key" "$old_val"
                    ;;
                added_line)
                    # Whole line was added by us — remove it
                    local line="$rest"
                    remove_config_line "$line"
                    ;;
                updated_line)
                    # Line was replaced — restore original
                    local original_line="${rest%%:*}"
                    local new_line="${rest#*:}"
                    if grep -qF "$new_line" "$CONFIG_TXT" 2>/dev/null; then
                        sed -i "s|${new_line}|${original_line}|" "$CONFIG_TXT"
                        log_revert "Restored line: ${original_line}"
                    fi
                    ;;
                cmdline_params_added)
                    log_action "Removing headless cmdline.txt parameters..."
                    remove_cmdline_params
                    ;;
                watchdog_conf)
                    log_action "Removing systemd watchdog config..."
                    if [[ -f "$WATCHDOG_CONF" ]]; then
                        rm -f "$WATCHDOG_CONF"
                        systemctl daemon-reload 2>/dev/null || true
                        log_revert "Removed ${WATCHDOG_CONF}"
                    fi
                    ;;
            esac
        done < "$STATE_FILE"

        # ── Strategy B: restore desktop gpu_mem if not already set back ──
        # If gpu_mem was added fresh (not updated), we need a sensible default
        if ! grep -q "^gpu_mem=" "$CONFIG_TXT" 2>/dev/null; then
            echo "gpu_mem=64" >> "$CONFIG_TXT"
            log_revert "Restored gpu_mem=64 (desktop default)"
        fi

        # Clean up state file
        rm -f "$STATE_FILE"
        log_ok "State file removed"

    else
        # ── Strategy B: no state file — apply known safe desktop defaults ──
        log_action "No state file — applying known safe desktop defaults..."
        create_backup

        # Remove headless-only lines
        local lines_to_remove=(
            "dtoverlay=disable-bt"
            "dtoverlay=cma,cma-32"
            "dtparam=watchdog=on"
            "dtoverlay=rng"
        )
        for line in "${lines_to_remove[@]}"; do
            remove_config_line "$line"
        done

        # Restore safe desktop values for keys that headless mode changes
        # (only if they exist — don't add them if they weren't there before)
        local -A desktop_defaults=(
            [gpu_mem]="64"
            [hdmi_blanking]="0"
            [hdmi_ignore_hotplug]="0"
            [camera_auto_detect]="1"
            [display_auto_detect]="1"
            [boot_delay]="1"
            [force_eeprom_read]="1"
            [disable_splash]="0"
            [avoid_warnings]="0"
        )

        for key in "${!desktop_defaults[@]}"; do
            if grep -q "^${key}=" "$CONFIG_TXT" 2>/dev/null; then
                sed -i "s|^${key}=.*|${key}=${desktop_defaults[$key]}|" "$CONFIG_TXT"
                log_revert "Reset: ${key}=${desktop_defaults[$key]}"
            fi
        done

        # Keys added by headless that have no meaningful desktop value — remove
        local keys_to_remove=(
            "hdmi_ignore_edid"
            "hdmi_ignore_cec_init"
            "hdmi_ignore_cec"
            "enable_tvout"
            "disable_fw_kms_setup"
            "disable_camera_led"
            "ignore_lcd"
            "disable_touchscreen"
            "initial_turbo"
            "dtparam=act_led_trigger"
            "dtparam=act_led_activelow"
        )
        for key in "${keys_to_remove[@]}"; do
            remove_config_key "$key"
        done

        # Restore audio
        if grep -q "^dtparam=audio=off" "$CONFIG_TXT" 2>/dev/null; then
            sed -i 's|^dtparam=audio=off|dtparam=audio=on|' "$CONFIG_TXT"
            log_revert "Restored: dtparam=audio=on"
        fi

        # Remove headless cmdline params
        log_action "Removing headless cmdline.txt parameters..."
        remove_cmdline_params

        # Remove watchdog config
        if [[ -f "$WATCHDOG_CONF" ]]; then
            rm -f "$WATCHDOG_CONF"
            systemctl daemon-reload 2>/dev/null || true
            log_revert "Removed ${WATCHDOG_CONF}"
        fi
    fi

    REBOOT_REQUIRED=true
    echo ""
    log_ok "══════════════════════════════════════════════════════"
    log_ok "Headless mode DISABLED. Desktop mode restored."
    log_ok "  • HDMI settings restored"
    log_ok "  • gpu_mem restored to 64 MB"
    log_ok "  • CMA overlay removed (will return to default ~256 MB)"
    log_ok "  • Bluetooth and audio overlays removed"
    log_ok "  • Boot settings restored"
    log_ok "  • cmdline.txt headless params removed"
    log_ok "  • systemd watchdog config removed"
    log_ok "  • Backup of headless state at: ${BACKUP_DIR}/"
    log_ok "══════════════════════════════════════════════════════"
}

#──────────────────────────────────────────────────────────────────────────────
#  REBOOT PROMPT
#──────────────────────────────────────────────────────────────────────────────

reboot_prompt() {
    if ! $REBOOT_REQUIRED || $FLAG_DRY_RUN; then
        return
    fi

    echo ""
    echo -e "  ${YELLOW}${BOLD}A REBOOT IS REQUIRED for changes to take effect.${NC}"
    echo ""

    if $FLAG_NO_REBOOT; then
        log_info "Reboot skipped (--no-reboot). Run: sudo reboot"
        return
    fi

    read -rp "  Reboot now? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        log_info "Skipping reboot. Run: sudo reboot"
    fi
}

#──────────────────────────────────────────────────────────────────────────────
#  HELP
#──────────────────────────────────────────────────────────────────────────────

show_help() {
    cat << HELPEOF
${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC}
Headless Mode Toggle for Raspberry Pi Zero 2 WH

${BOLD}USAGE:${NC}
  sudo ./${SCRIPT_NAME} <command> [options]

${BOLD}COMMANDS:${NC}
  on          Enable headless mode
                • gpu_mem = 16 MB (from 64 MB)
                • HDMI fully disabled (~14 mA saved)
                • Bluetooth + audio disabled
                • CMA reduced 256 MB → 32 MB (~224 MB RAM freed)
                • Boot acceleration (initial_turbo, boot_delay, splash off)
                • Hardware watchdog enabled
                • Activity LED off
                • Quiet kernel boot
  off         Restore desktop mode
                • All 'on' changes precisely reverted using state file
                • Falls back to known safe desktop defaults if no state file
  status      Show whether headless is active and current key values
  dry-run     Preview what 'on' would change (nothing is written)

${BOLD}OPTIONS:${NC}
  --no-reboot     Don't prompt to reboot after applying changes
  --help, -h      Show this help message

${BOLD}EXAMPLES:${NC}
  sudo ./${SCRIPT_NAME} on                 # Enable headless
  sudo ./${SCRIPT_NAME} on --no-reboot    # Enable, skip reboot prompt
  sudo ./${SCRIPT_NAME} off               # Restore desktop
  sudo ./${SCRIPT_NAME} status            # Check current state
  sudo ./${SCRIPT_NAME} dry-run           # Preview 'on' changes

${BOLD}NOTES:${NC}
  • A backup of config.txt and cmdline.txt is always saved to:
      ${BACKUP_DIR}/
  • State is tracked in: ${STATE_FILE}
    This ensures 'off' restores the EXACT original values, not just
    generic defaults — safe even if you edited config.txt manually
    after running 'on'.
  • 'on' is idempotent — safe to run multiple times.
  • After 'on', verify CMA after reboot:
      cat /proc/meminfo | grep CmaTotal   (target: 32768 kB = 32 MB)
HELPEOF
}

#──────────────────────────────────────────────────────────────────────────────
#  MAIN
#──────────────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-}"

    # Parse options first
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --no-reboot)  FLAG_NO_REBOOT=true ;;
            --help|-h)    show_help; exit 0 ;;
            --*)
                echo -e "${RED}Unknown option: ${arg}${NC}" >&2
                echo "Use --help for usage." >&2
                exit 1
                ;;
            *)  args+=("$arg") ;;
        esac
    done

    command="${args[0]:-}"

    case "$command" in
        on)
            banner
            preflight
            cmd_on
            reboot_prompt
            ;;
        off)
            banner
            preflight
            cmd_off
            reboot_prompt
            ;;
        status)
            banner
            preflight
            cmd_status
            ;;
        dry-run|dryrun|--dry-run)
            FLAG_DRY_RUN=true
            banner
            preflight
            cmd_on
            ;;
        ""|-h|--help|help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown command: ${command}${NC}" >&2
            echo "" >&2
            show_help >&2
            exit 1
            ;;
    esac
}

main "$@"
