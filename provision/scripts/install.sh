#!/usr/bin/env bash
# =============================================================
#  install.sh  —  Pi Zero 2 WH Setup & Optimization
#  v5.0.0
#
#  USAGE:
#    sudo bash scripts/install.sh [--dry-run] [--no-reboot]
#
#  Edit pizero.conf first. This script reads everything from it.
#  Safe to re-run — all operations are idempotent.
# =============================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="/usr/local/lib/pizero"
CONF_INSTALL="/etc/pizero"

# Source shared library
source "${SCRIPT_DIR}/lib.sh"

readonly VERSION="5.0.0"
readonly LOG_DIR="/var/log/pizero"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly CONFIG_TXT="/boot/firmware/config.txt"
readonly CMDLINE_TXT="/boot/firmware/cmdline.txt"

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(eval echo "~${REAL_USER}")"
BACKUP_DIR="${REAL_HOME}/pizero-backups/$(date +%Y%m%d-%H%M%S)"

FLAG_DRY_RUN=false
FLAG_NO_REBOOT=false
REBOOT_REQUIRED=false

# ── Argument parsing ──────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --dry-run)    FLAG_DRY_RUN=true ;;
        --no-reboot)  FLAG_NO_REBOOT=true ;;
        --help|-h)
            echo "Usage: sudo bash scripts/install.sh [--dry-run] [--no-reboot]"
            echo "Edit pizero.conf first, then run this script."
            exit 0 ;;
        *)  echo "Unknown option: $arg — use --help" >&2; exit 1 ;;
    esac
done

# dry-run guard: call as  dry "description" || return 0
# at the top of any function to skip its body in dry-run mode
dry() {
    if $FLAG_DRY_RUN; then
        log_skip "(dry-run) would run: $*"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────
setup_logging() {
    mkdir -p "$LOG_DIR"
    # tee to both terminal and log file
    exec > >(tee -a "$LOG_FILE") 2>&1
}

banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════════════════╗
  ║          Pi Zero 2 WH — Setup & Optimizer  v5.0.0              ║
  ║          RP3A0 · Cortex-A53 · 512 MB · Debian 13 Trixie       ║
  ╚══════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

# ─────────────────────────────────────────────────────────────
step_preflight() {
    section "PREFLIGHT"
    require_root

    # Architecture
    local arch; arch=$(uname -m)
    [[ "$arch" == "aarch64" ]] && log_ok "Architecture: aarch64" \
        || log_warn "Architecture: ${arch} (expected aarch64)"

    # Board
    local model=""
    [[ -f /proc/device-tree/model ]] && model=$(tr -d '\0' < /proc/device-tree/model)
    log_info "Board: ${model:-unknown}"

    # OS
    local codename=""
    [[ -f /etc/os-release ]] && codename=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    [[ "$codename" == "trixie" ]] && log_ok "Debian 13 Trixie" \
        || log_warn "OS: ${codename} (expected trixie — some steps may differ)"

    # config.txt
    [[ -f "$CONFIG_TXT" ]] && log_ok "config.txt: ${CONFIG_TXT}" \
        || { log_error "config.txt not found at ${CONFIG_TXT}"; exit 1; }

    # Disk space
    local avail; avail=$(df / --output=avail -BM | tail -1 | tr -dc '0-9')
    log_info "Free disk: ${avail} MB"
    [[ "$avail" -lt 500 ]] && log_warn "Low disk space (< 500 MB)"

    # RAM
    log_info "RAM: $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"

    # Throttle
    if command -v vcgencmd &>/dev/null; then
        local t; t=$(vcgencmd get_throttled 2>/dev/null || echo "unavailable")
        [[ "$t" == "throttled=0x0" ]] && log_ok "Power supply: healthy" \
            || log_warn "Throttle flags: ${t} — check power supply"
    fi

    # Internet
    if ping -c1 -W3 8.8.8.8 &>/dev/null; then
        log_ok "Internet: reachable"
    else
        log_warn "Internet: unreachable — package installation will fail"
    fi

    log_info "Log: ${LOG_FILE}"
}

# ─────────────────────────────────────────────────────────────
step_backup() {
    section "BACKUPS"
    $FLAG_DRY_RUN && { log_skip "Dry run — no backups"; return; }

    mkdir -p "$BACKUP_DIR"

    local files=(
        "$CONFIG_TXT"
        "$CMDLINE_TXT"
        "/etc/fstab"
        "/etc/hosts"
        "/etc/nsswitch.conf"
        "/etc/rpi/swap.conf"
        "/etc/NetworkManager/NetworkManager.conf"
    )
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak"
            log_ok "Backed up: $f"
        fi
    done

    # Backup any existing sysctl drop-ins
    if [[ -d /etc/sysctl.d ]]; then
        mkdir -p "${BACKUP_DIR}/sysctl.d"
        cp -a /etc/sysctl.d/ "${BACKUP_DIR}/sysctl.d/" 2>/dev/null || true
        log_ok "Backed up: /etc/sysctl.d/"
    fi

    dpkg --get-selections > "${BACKUP_DIR}/packages.txt" 2>/dev/null && \
        log_ok "Backed up package list"

    systemctl list-unit-files > "${BACKUP_DIR}/unit-files.txt" 2>/dev/null && \
        log_ok "Backed up systemd unit list"

    chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/pizero-backups/" 2>/dev/null || true
    log_info "Backup location: ${BACKUP_DIR}"
}

# ─────────────────────────────────────────────────────────────
step_update() {
    section "STEP 1: SYSTEM UPDATE"
    dry "system update" || return 0

    log_action "Updating package index..."
    apt-get update -y 2>&1 | tail -3
    log_ok "Package index updated"

    log_action "Upgrading packages..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>&1 \
        | grep -v "automatically installed" \
        | grep -v "apt autoremove" \
        | tail -5
    log_ok "System upgraded"

    # Firmware
    if dpkg -l raspi-firmware 2>/dev/null | grep -qE "^ii"; then
        apt-get install --only-upgrade -y raspi-firmware 2>&1 \
            | grep -v "automatically installed" | tail -2
        log_ok "Firmware package checked"
    fi

    # Kernel
    local kpkg
    kpkg=$(dpkg -l 2>/dev/null | grep -oP 'linux-image-rpi-\S+' | head -1 || true)
    if [[ -n "$kpkg" ]]; then
        apt-get install --only-upgrade -y "$kpkg" 2>&1 \
            | grep -v "automatically installed" | tail -2
        log_ok "Kernel package checked: ${kpkg}"
    fi

    REBOOT_REQUIRED=true
}

# ─────────────────────────────────────────────────────────────
step_packages() {
    section "STEP 2: PACKAGES"
    dry "install packages" || return 0

    log_action "Installing required packages..."
    apt_ensure \
        hostapd dnsmasq \
        avahi-daemon libnss-mdns \
        iw wireless-tools \
        iproute2 \
        htop iotop ncdu tmux git curl wget rsync vim-tiny \
        sysstat lsof dnsutils net-tools \
        fail2ban earlyoom log2ram \
        e2fsprogs

    # hostapd and dnsmasq must NOT auto-start — managed by our watchdog
    systemctl disable hostapd 2>/dev/null || true
    systemctl disable dnsmasq  2>/dev/null || true
    systemctl stop   hostapd   2>/dev/null || true
    systemctl stop   dnsmasq   2>/dev/null || true
    # Mask system dnsmasq so it never conflicts with hotspot dnsmasq instance
    systemctl mask dnsmasq 2>/dev/null || true
    log_ok "hostapd/dnsmasq: disabled and masked (managed by watchdog only)"

    log_ok "All packages installed"
}

# ─────────────────────────────────────────────────────────────
step_wifi() {
    section "STEP 3: WI-FI"
    dry "configure wifi" || return 0

    # ── Regulatory domain ────────────────────────────────────
    log_action "Setting Wi-Fi regulatory domain: ${WIFI_COUNTRY}"
    if command -v raspi-config &>/dev/null; then
        raspi-config nonint do_wifi_country "${WIFI_COUNTRY}" 2>/dev/null \
            && log_ok "Regulatory domain: ${WIFI_COUNTRY}" \
            || log_warn "raspi-config failed — setting via iw"
    fi
    # Also set via iw as fallback
    iw reg set "${WIFI_COUNTRY}" 2>/dev/null || true

    # ── NetworkManager global config ─────────────────────────
    log_action "Installing NetworkManager global config..."
    mkdir -p /etc/NetworkManager/conf.d/
    cp -f "${PKG_DIR}/templates/nm-global.conf" \
          /etc/NetworkManager/conf.d/pizero.conf
    log_ok "NetworkManager: powersave disabled, fixed MAC"

    # ── NetworkManager connection keyfile ────────────────────
    log_action "Writing home WiFi connection: ${WIFI_SSID}"
    local nm_dir="/etc/NetworkManager/system-connections"
    local nm_file="${nm_dir}/pizero-home.nmconnection"
    mkdir -p "$nm_dir"

    # Preserve UUID across re-runs so NM doesn't treat it as a new profile
    local uuid=""
    if [[ -f "$nm_file" ]]; then
        uuid=$(grep "^uuid=" "$nm_file" 2>/dev/null | cut -d= -f2 || true)
    fi
    if [[ -z "$uuid" ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
               || python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
               || echo "$(date +%s)-$(($RANDOM))-pizero-home")
    fi

    local key_mgmt="WPA-PSK"
    [[ "${WIFI_SECURITY:-wpa2}" == "wpa3" ]] && key_mgmt="SAE"
    log_info "Security: ${key_mgmt} (${WIFI_SECURITY:-wpa2})"

    # Substitute template variables — no heredoc, no expansion surprises
    sed \
        -e "s|%%UUID%%|${uuid}|g" \
        -e "s|%%SSID%%|${WIFI_SSID}|g" \
        -e "s|%%KEY_MGMT%%|${key_mgmt}|g" \
        -e "s|%%PSK%%|${WIFI_PASSWORD}|g" \
        "${PKG_DIR}/templates/nm-connection.conf" \
        > "$nm_file"
    chmod 600 "$nm_file"
    log_ok "NM connection written: ${nm_file}"

    # ── brcmfmac driver options ──────────────────────────────
    log_action "Installing brcmfmac driver config..."
    cp -f "${PKG_DIR}/configs/pizero-brcmfmac.conf" \
          /etc/modprobe.d/pizero-brcmfmac.conf
    log_ok "brcmfmac: roamoff=1 (roaming disabled)"

    # ── Reload NM ────────────────────────────────────────────
    if systemctl is-active NetworkManager &>/dev/null; then
        systemctl reload NetworkManager 2>/dev/null \
            || systemctl restart NetworkManager 2>/dev/null \
            || true
        log_ok "NetworkManager reloaded"
    fi

    REBOOT_REQUIRED=true
    log_info "WiFi will connect to '${WIFI_SSID}' after reboot"
}

# ─────────────────────────────────────────────────────────────
step_system() {
    section "STEP 4: SYSTEM IDENTITY"
    dry "configure system identity" || return 0

    # ── Hostname ─────────────────────────────────────────────
    local cur_hostname; cur_hostname=$(hostname)
    if [[ "$cur_hostname" != "${PI_HOSTNAME}" ]]; then
        hostnamectl set-hostname "${PI_HOSTNAME}"
        # /etc/hosts: update or add 127.0.1.1 entry
        if grep -q "^127\.0\.1\.1" /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${PI_HOSTNAME}/" /etc/hosts
        else
            echo "127.0.1.1	${PI_HOSTNAME}" >> /etc/hosts
        fi
        log_ok "Hostname: ${PI_HOSTNAME} (was: ${cur_hostname})"
        REBOOT_REQUIRED=true
    else
        log_info "Hostname already: ${PI_HOSTNAME}"
    fi

    # ── Timezone ─────────────────────────────────────────────
    if [[ -n "${TIMEZONE:-}" ]]; then
        if timedatectl set-timezone "${TIMEZONE}" 2>/dev/null; then
            log_ok "Timezone: ${TIMEZONE}"
        else
            log_warn "Could not set timezone '${TIMEZONE}' — check /usr/share/zoneinfo/"
        fi
    fi

    # ── avahi / mDNS ─────────────────────────────────────────
    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl start  avahi-daemon 2>/dev/null || true
    log_ok "avahi-daemon: running (${PI_HOSTNAME}.local available)"

    # Ensure mdns4_minimal in nsswitch.conf
    if [[ -f /etc/nsswitch.conf ]] \
       && grep -q "^hosts:" /etc/nsswitch.conf \
       && ! grep -q "mdns4_minimal" /etc/nsswitch.conf; then
        sed -i '/^hosts:/ s/dns/mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf
        log_ok "nsswitch.conf: mdns4_minimal added"
    else
        log_info "nsswitch.conf: .local resolution already configured"
    fi

    # ── SSH hardening ─────────────────────────────────────────
    mkdir -p /etc/ssh/sshd_config.d/
    cp -f "${PKG_DIR}/configs/pizero-sshd.conf" \
          /etc/ssh/sshd_config.d/pizero.conf
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null \
            || systemctl reload ssh 2>/dev/null \
            || true
        log_ok "SSH: hardening config applied"
    else
        log_warn "SSH config failed validation — reverting"
        rm -f /etc/ssh/sshd_config.d/pizero.conf
    fi

    # ── SSH public key ────────────────────────────────────────
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        local ak="${REAL_HOME}/.ssh/authorized_keys"
        mkdir -p "${REAL_HOME}/.ssh"
        chmod 700 "${REAL_HOME}/.ssh"
        if ! grep -qF "${SSH_PUBLIC_KEY}" "$ak" 2>/dev/null; then
            echo "${SSH_PUBLIC_KEY}" >> "$ak"
            chmod 600 "$ak"
            chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.ssh/"
            log_ok "SSH public key added to ${ak}"
        else
            log_info "SSH public key already present"
        fi
    else
        log_info "No SSH public key configured (password auth active)"
    fi
}

# ─────────────────────────────────────────────────────────────
step_performance() {
    section "STEP 5: PERFORMANCE"
    dry "apply performance tuning" || return 0

    # ── Disable SD card swap ──────────────────────────────────
    if systemctl is-active dphys-swapfile &>/dev/null 2>&1; then
        systemctl stop    dphys-swapfile
        systemctl disable dphys-swapfile
        systemctl mask    dphys-swapfile
        log_ok "dphys-swapfile: disabled (ZRAM takes over)"
    else
        log_info "SD card swap: not active"
    fi

    # ── Kernel sysctl ─────────────────────────────────────────
    log_action "Installing kernel parameters..."
    cp -f "${PKG_DIR}/configs/99-pizero-sysctl.conf" \
          /etc/sysctl.d/99-pizero.conf

    # Load conntrack module so those keys exist immediately
    modprobe nf_conntrack 2>/dev/null || true
    echo "nf_conntrack" > /etc/modules-load.d/pizero-nf_conntrack.conf

    # Load BBR
    echo "tcp_bbr" > /etc/modules-load.d/pizero-tcp_bbr.conf
    modprobe tcp_bbr 2>/dev/null || true

    # Append kernel-optional keys only if /proc/sys path exists
    local sc="/etc/sysctl.d/99-pizero.conf"
    echo "" >> "$sc"
    echo "# Optional keys (probed at install time)" >> "$sc"
    probe_sysctl "$sc" "kernel.sched_autogroup_enabled"     "0"
    probe_sysctl "$sc" "kernel.kptr_restrict"               "2"
    probe_sysctl "$sc" "kernel.dmesg_restrict"              "1"
    probe_sysctl "$sc" "kernel.perf_event_paranoid"         "3"
    probe_sysctl "$sc" "net.core.bpf_jit_harden"           "2"
    probe_sysctl "$sc" "kernel.unprivileged_bpf_disabled"   "1"
    probe_sysctl "$sc" "kernel.printk"                      "3 3 3 3"

    # Probe conntrack (available now that module is loaded)
    probe_sysctl "$sc" "net.netfilter.nf_conntrack_max"                     "8192"
    probe_sysctl "$sc" "net.netfilter.nf_conntrack_tcp_timeout_established" "3600"
    probe_sysctl "$sc" "net.netfilter.nf_conntrack_tcp_timeout_time_wait"   "30"

    sysctl --system 2>&1 | grep -v "No such file" | grep -v "^$" | tail -5
    log_ok "Kernel parameters applied"

    # ── Transparent huge pages ────────────────────────────────
    mkdir -p /etc/tmpfiles.d/
    cat > /etc/tmpfiles.d/pizero-thp.conf << 'THPEOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
THPEOF
    log_ok "THP: madvise (opt-in only)"

    # ── I/O scheduler ─────────────────────────────────────────
    cp -f "${PKG_DIR}/configs/60-pizero-ioscheduler.rules" \
          /etc/udev/rules.d/60-pizero-ioscheduler.rules
    # Apply immediately without reboot
    for mmcblk in /sys/block/mmcblk*/queue/scheduler; do
        [[ -f "$mmcblk" ]] && echo "mq-deadline" > "$mmcblk" 2>/dev/null || true
    done
    log_ok "I/O scheduler: mq-deadline"

    # ── CPU governor ─────────────────────────────────────────
    local gov="schedutil"
    local avail_govs=""
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]] \
        && avail_govs=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors)
    echo "$avail_govs" | grep -q "schedutil" || gov="ondemand"

    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$f" ]] && echo "$gov" > "$f" 2>/dev/null || true
    done
    cat > /etc/udev/rules.d/61-pizero-cpu-governor.rules << EOF
KERNEL=="cpu*", SUBSYSTEM=="cpu", ATTR{cpufreq/scaling_governor}="${gov}"
EOF
    log_ok "CPU governor: ${gov}"

    # ── fstab: noatime + lazytime + commit=600 ────────────────
    if grep -qE "^PARTUUID[^[:space:]]*[[:space:]]+/[[:space:]].*ext4" /etc/fstab; then
        if ! grep -qE "^PARTUUID[^[:space:]]*[[:space:]]+/[[:space:]].*noatime" /etc/fstab; then
            sed -i -E \
                '/^PARTUUID[^[:space:]]*[[:space:]]+\/[[:space:]].*ext4/ s/defaults/defaults,noatime,lazytime,commit=600/' \
                /etc/fstab
            log_ok "fstab: noatime,lazytime,commit=600 on root"
            REBOOT_REQUIRED=true
        else
            log_info "fstab: root already has noatime"
        fi
        # Add lazytime if noatime present but lazytime missing
        if grep -qE "^PARTUUID[^[:space:]]*[[:space:]]+/[[:space:]].*noatime" /etc/fstab \
           && ! grep -qE "^PARTUUID[^[:space:]]*[[:space:]]+/[[:space:]].*lazytime" /etc/fstab; then
            sed -i -E \
                '/^PARTUUID[^[:space:]]*[[:space:]]+\/[[:space:]].*ext4/ s/noatime/noatime,lazytime/' \
                /etc/fstab
            log_ok "fstab: lazytime added"
        fi
    fi

    # ── fstab: tmpfs for /tmp /var/tmp ───────────────────────
    local fstab_add=""
    for mp_sz in "/tmp:64M" "/var/tmp:32M"; do
        local mnt="${mp_sz%%:*}" sz="${mp_sz##*:}"
        if ! grep -qE "^tmpfs[[:space:]]+${mnt}[[:space:]]" /etc/fstab 2>/dev/null; then
            fstab_add+="tmpfs ${mnt} tmpfs defaults,noatime,nosuid,nodev,size=${sz} 0 0\n"
        fi
    done
    if [[ -n "$fstab_add" ]]; then
        { echo ""; echo "# pizero tmpfs mounts"; echo -e "${fstab_add}"; } >> /etc/fstab
        log_ok "fstab: tmpfs for /tmp (64M) and /var/tmp (32M)"
        REBOOT_REQUIRED=true
    else
        log_info "fstab: tmpfs already configured"
    fi

    # ── ext4 reserved blocks 5% → 1% ─────────────────────────
    if command -v tune2fs &>/dev/null && [[ -b /dev/mmcblk0p2 ]]; then
        local reserved total pct
        reserved=$(tune2fs -l /dev/mmcblk0p2 2>/dev/null | awk '/Reserved block count/{print $4}' || echo 0)
        total=$(tune2fs    -l /dev/mmcblk0p2 2>/dev/null | awk '/Block count:/{print $3}'          || echo 1)
        pct=$(( reserved * 100 / total ))
        if [[ "$pct" -gt 1 ]]; then
            tune2fs -m 1 /dev/mmcblk0p2 2>/dev/null \
                && log_ok "ext4: reserved blocks ${pct}% → 1%" \
                || log_warn "ext4: could not reduce reserved blocks"
        else
            log_info "ext4: reserved blocks ≤1% already"
        fi
    fi

    # ── GPU memory ────────────────────────────────────────────
    local gpu=64
    [[ "${HEADLESS:-no}" == "yes" ]] && gpu=16
    set_config_txt "gpu_mem" "$gpu"
    log_ok "config.txt: gpu_mem=${gpu}"
    REBOOT_REQUIRED=true

    # ── Overclock ─────────────────────────────────────────────
    case "${OVERCLOCK:-none}" in
        safe)
            log_warn "Overclock: 1.2 GHz — heatsink required!"
            grep -q "^\[pi02\]" "$CONFIG_TXT" || printf '\n[pi02]\n' >> "$CONFIG_TXT"
            set_config_txt "arm_freq"    "1200"
            set_config_txt "over_voltage" "2"
            set_config_txt "core_freq"   "500"
            log_ok "Overclock: 1200 MHz applied"
            REBOOT_REQUIRED=true
            ;;
        power)
            log_info "Underclock: 700 MHz low-power mode"
            grep -q "^\[pi02\]" "$CONFIG_TXT" || printf '\n[pi02]\n' >> "$CONFIG_TXT"
            set_config_txt "arm_freq"     "700"
            set_config_txt "arm_freq_min" "700"
            set_config_txt "over_voltage" "-4"
            log_ok "Underclock: 700 MHz applied"
            REBOOT_REQUIRED=true
            ;;
        none|*)
            log_info "Overclock: none (stock 1000 MHz)"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
step_headless() {
    [[ "${HEADLESS:-no}" != "yes" ]] && return 0
    section "STEP 6: HEADLESS TUNING"
    dry "headless config" || return 0

    log_warn "Headless mode — HDMI/audio/BT disabled. Never connect a monitor."

    # config.txt keys
    grep -q "^\[pi02\]" "$CONFIG_TXT" \
        || printf '\n[pi02]\n# pizero headless settings\n' >> "$CONFIG_TXT"

    set_config_txt "gpu_mem"              "16"
    set_config_txt "hdmi_blanking"        "2"
    set_config_txt "hdmi_ignore_hotplug"  "1"
    set_config_txt "hdmi_ignore_edid"     "0xa5000080"
    set_config_txt "hdmi_ignore_cec"      "1"
    set_config_txt "enable_tvout"         "0"
    set_config_txt "disable_fw_kms_setup" "1"
    set_config_txt "camera_auto_detect"   "0"
    set_config_txt "display_auto_detect"  "0"
    set_config_txt "boot_delay"           "0"
    set_config_txt "initial_turbo"        "60"
    set_config_txt "disable_splash"       "1"
    set_config_txt "avoid_warnings"       "1"
    set_config_txt "dtparam=audio"        "off"
    set_config_txt "dtparam=act_led_trigger" "none"

    ensure_config_line "dtoverlay=disable-bt"
    ensure_config_line "dtparam=watchdog=on"
    ensure_config_line "dtoverlay=rng"

    # CMA: 256 MB → 32 MB
    if grep -q "^dtoverlay=cma" "$CONFIG_TXT"; then
        sed -i 's|^dtoverlay=cma.*|dtoverlay=cma,cma-32|' "$CONFIG_TXT"
    else
        echo "dtoverlay=cma,cma-32" >> "$CONFIG_TXT"
    fi
    log_ok "CMA: reduced to 32 MB (~224 MB freed)"

    # systemd hardware watchdog
    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/pizero-watchdog.conf << 'WDEOF'
[Manager]
RuntimeWatchdogSec=10s
RebootWatchdogSec=2min
WatchdogDevice=/dev/watchdog0
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
WDEOF
    log_ok "systemd watchdog: 10 s runtime, 2 min reboot"

    # cmdline.txt
    if [[ -f "$CMDLINE_TXT" ]]; then
        local cmdline changed=false
        cmdline=$(cat "$CMDLINE_TXT")
        for param in "quiet" "loglevel=3" "logo.nologo" "audit=0" \
                     "transparent_hugepage=madvise" "vt.global_cursor_default=0"; do
            echo "$cmdline" | grep -qw "$param" || { cmdline="${cmdline} ${param}"; changed=true; }
        done
        if $changed; then
            echo "$cmdline" | tr -s ' ' | sed 's/^ //;s/ $//' > "$CMDLINE_TXT"
            log_ok "cmdline.txt: quiet boot params added"
        else
            log_info "cmdline.txt: headless params already present"
        fi
    fi

    log_ok "Headless tuning complete"
    REBOOT_REQUIRED=true
}

# ─────────────────────────────────────────────────────────────
step_services() {
    section "STEP 7: SERVICE PRUNING"
    dry "prune services" || return 0

    # Services to disable (exists + enabled → disable)
    local -a disable=(
        "man-db.timer"
        "apt-daily.timer"
        "apt-daily-upgrade.timer"
        "e2scrub_all.timer"
        "e2scrub_reap.service"
        "NetworkManager-wait-online.service"
        "ModemManager.service"
        "triggerhappy.service"
    )
    # Services to mask (prevent manual start too)
    local -a mask=(
        "plymouth-start.service"
        "plymouth-quit-wait.service"
    )
    # Always-keep list (informational only)
    local -a keep=(
        "ssh.service             — remote access"
        "avahi-daemon.service    — .local mDNS"
        "fstrim.timer            — SD card TRIM"
        "systemd-timesyncd.service — NTP"
        "NetworkManager.service  — WiFi"
    )

    for entry in "${keep[@]}"; do
        log_info "Keeping: ${entry}"
    done
    echo ""

    for svc in "${disable[@]}"; do
        if systemctl list-unit-files "$svc" &>/dev/null 2>&1; then
            if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
                systemctl stop    "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                log_ok "Disabled: ${svc}"
            else
                log_skip "Already off: ${svc}"
            fi
        else
            log_skip "Not found:   ${svc}"
        fi
    done

    for svc in "${mask[@]}"; do
        if systemctl list-unit-files "$svc" &>/dev/null 2>&1; then
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask    "$svc" 2>/dev/null || true
            log_ok "Masked: ${svc}"
        else
            log_skip "Not found: ${svc}"
        fi
    done

    # fstrim timer — enable only if SD supports DISCARD
    local discard_max
    discard_max=$(cat /sys/block/mmcblk0/queue/discard_max_bytes 2>/dev/null || echo "0")
    if [[ "$discard_max" != "0" ]]; then
        systemctl enable fstrim.timer 2>/dev/null || true
        log_ok "fstrim.timer: enabled (SD supports DISCARD)"
    else
        log_info "fstrim.timer: SD does not report DISCARD support"
    fi

    # Purge ModemManager if installed
    if dpkg -l modemmanager 2>/dev/null | grep -qE "^ii"; then
        apt-get remove --purge -y modemmanager 2>&1 | tail -2
        log_ok "ModemManager: purged"
    fi

    local running
    running=$(systemctl list-units --type=service --state=running --no-pager --no-legend | wc -l)
    log_info "Running services after pruning: ${running}"
}

# ─────────────────────────────────────────────────────────────
step_tools() {
    section "STEP 8: TOOL CONFIGURATION"
    dry "configure tools" || return 0

    # ── log2ram ───────────────────────────────────────────────
    if [[ -f /etc/log2ram.conf ]]; then
        sed -i 's/^SIZE=.*/SIZE=40M/'   /etc/log2ram.conf
        sed -i 's/^MAIL=.*/MAIL=false/' /etc/log2ram.conf 2>/dev/null || true
        log_ok "log2ram: 40 MB RAM disk"
    fi

    # ── earlyoom ─────────────────────────────────────────────
    cp -f "${PKG_DIR}/configs/earlyoom" /etc/default/earlyoom
    systemctl enable earlyoom 2>/dev/null || true
    systemctl restart earlyoom 2>/dev/null || true
    log_ok "earlyoom: enabled (kill at 10% free memory)"

    # ── fail2ban ─────────────────────────────────────────────
    mkdir -p /etc/fail2ban/jail.d/
    cat > /etc/fail2ban/jail.d/pizero.conf << 'F2BEOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 10
bantime  = 600
findtime = 600
F2BEOF
    systemctl enable  fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
    log_ok "fail2ban: SSH jail active"

    # ── journald ─────────────────────────────────────────────
    mkdir -p /etc/systemd/journald.conf.d/
    cp -f "${PKG_DIR}/configs/pizero-journald.conf" \
          /etc/systemd/journald.conf.d/pizero.conf
    systemctl restart systemd-journald 2>/dev/null || true
    log_ok "journald: volatile storage, 8 MB max"
}

# ─────────────────────────────────────────────────────────────
step_hotspot() {
    section "STEP 9: WI-FI HOTSPOT FALLBACK"
    dry "install hotspot" || return 0

    # ── Verify AP/STA concurrency capability ─────────────────
    # The CYW43438 supports simultaneous AP + managed (STA) mode
    # via a virtual interface. Verify the kernel/driver exposes
    # this before proceeding so we fail clearly, not cryptically.
    log_action "Checking AP/STA concurrency support..."
    local iw_combos
    iw_combos=$(iw list 2>/dev/null | grep -A5 "valid interface combinations" || true)
    if echo "$iw_combos" | grep -q "AP" && echo "$iw_combos" | grep -q "managed"; then
        log_ok "AP/STA concurrency supported (uap0 virtual interface will work)"
    else
        log_warn "Could not confirm AP/STA support from 'iw list'"
        log_warn "Hotspot will still be installed — may need reboot to activate driver"
        log_warn "After reboot check: iw list | grep -A8 'valid interface combinations'"
    fi

    # ── Runtime config directory ──────────────────────────────
    mkdir -p "$CONF_INSTALL"

    # hotspot.env is sourced by the systemd EnvironmentFile= directive.
    # All variables the runtime scripts need must be here.
    # Format: KEY=VALUE  (no export, no quotes — systemd handles parsing)
    cat > "${CONF_INSTALL}/hotspot.env" << EOF
HOTSPOT_IP=${HOTSPOT_IP}
HOTSPOT_TIMEOUT=${HOTSPOT_TIMEOUT}
HOTSPOT_CHANNEL=${HOTSPOT_CHANNEL}
HOTSPOT_SSID=${HOTSPOT_SSID}
PI_HOSTNAME=${PI_HOSTNAME}
WIFI_COUNTRY=${WIFI_COUNTRY}
EOF
    chmod 600 "${CONF_INSTALL}/hotspot.env"
    log_ok "hotspot.env: ${CONF_INSTALL}/hotspot.env"

    # ── hostapd config from template ─────────────────────────
    # Note: interface= and channel= will be patched at runtime by
    # hotspot-start.sh to use uap0 and the synced channel.
    # This installed file is the "base" config only.
    sed \
        -e "s|%%HOTSPOT_SSID%%|${HOTSPOT_SSID}|g" \
        -e "s|%%HOTSPOT_PASSWORD%%|${HOTSPOT_PASSWORD}|g" \
        -e "s|%%HOTSPOT_CHANNEL%%|${HOTSPOT_CHANNEL}|g" \
        "${PKG_DIR}/templates/hostapd.conf" \
        > /etc/hostapd/pizero-fallback.conf
    chmod 600 /etc/hostapd/pizero-fallback.conf
    log_ok "hostapd base config: /etc/hostapd/pizero-fallback.conf"

    # On Debian, /etc/default/hostapd must have DAEMON_CONF set even
    # when hostapd is invoked directly (not via systemd service).
    # Without this, some versions of hostapd refuse to start.
    if [[ -f /etc/default/hostapd ]]; then
        sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/pizero-fallback.conf"|' \
            /etc/default/hostapd
        # If the line didn't exist, add it
        grep -q "^DAEMON_CONF=" /etc/default/hostapd \
            || echo 'DAEMON_CONF="/etc/hostapd/pizero-fallback.conf"' \
               >> /etc/default/hostapd
        log_ok "/etc/default/hostapd: DAEMON_CONF set"
    fi

    # ── dnsmasq config from template ─────────────────────────
    # interface= and dhcp-range= are patched at runtime by hotspot-start.sh.
    mkdir -p /etc/dnsmasq.d/
    sed \
        -e "s|%%HOTSPOT_IP%%|${HOTSPOT_IP}|g" \
        -e "s|%%PI_HOSTNAME%%|${PI_HOSTNAME}|g" \
        "${PKG_DIR}/templates/dnsmasq-hotspot.conf" \
        > /etc/dnsmasq.d/pizero-hotspot.conf
    log_ok "dnsmasq base config: /etc/dnsmasq.d/pizero-hotspot.conf"

    # ── Install runtime scripts ───────────────────────────────
    mkdir -p "$INSTALL_DIR"
    for f in hotspot-start.sh hotspot-stop.sh wifi-watchdog.sh; do
        if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
            log_error "Missing script: ${SCRIPT_DIR}/${f}"
            exit 1
        fi
        cp -f "${SCRIPT_DIR}/${f}" "${INSTALL_DIR}/${f}"
        chmod 755 "${INSTALL_DIR}/${f}"
        log_ok "Installed: ${INSTALL_DIR}/${f}"
    done

    # ── Convenience symlinks ──────────────────────────────────
    ln -sf "${INSTALL_DIR}/hotspot-start.sh"  /usr/local/bin/pizero-hotspot-start
    ln -sf "${INSTALL_DIR}/hotspot-stop.sh"   /usr/local/bin/pizero-hotspot-stop
    ln -sf "${INSTALL_DIR}/wifi-watchdog.sh"  /usr/local/bin/pizero-wifi-watchdog
    log_ok "Symlinks: pizero-hotspot-start / pizero-hotspot-stop"

    # ── Copy package config to system ────────────────────────
    # Install pizero.conf to /etc/pizero/ so the system always has
    # a reference copy of what was used during install.
    cp -f "${PKG_DIR}/pizero.conf" "${CONF_INSTALL}/pizero.conf.installed"
    chmod 600 "${CONF_INSTALL}/pizero.conf.installed"

    # ── systemd unit ─────────────────────────────────────────
    cp -f "${PKG_DIR}/systemd/pizero-hotspot.service" \
          /etc/systemd/system/pizero-hotspot.service
    systemctl daemon-reload
    systemctl enable pizero-hotspot.service
    log_ok "pizero-hotspot.service: enabled (starts on boot)"

    # Copy README for the Documentation= link in the service file
    [[ -f "${PKG_DIR}/README.md" ]] \
        && cp -f "${PKG_DIR}/README.md" "${CONF_INSTALL}/README.md" \
        || true

    # ── Summary ──────────────────────────────────────────────
    echo ""
    log_info "━━━ FALLBACK HOTSPOT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "  Architecture: AP/STA concurrency"
    log_info "    wlan0 = stays connected to home WiFi (managed by NM)"
    log_info "    uap0  = virtual AP interface for the hotspot"
    log_info "    Both share the same radio channel (CYW43438 hardware limit)"
    log_info ""
    log_info "  SSID:         ${HOTSPOT_SSID}"
    log_info "  Password:     ${HOTSPOT_PASSWORD}"
    log_info "  IP:           ${HOTSPOT_IP}"
    log_info "  Timeout:      ${HOTSPOT_TIMEOUT}s after boot with no home WiFi"
    log_info ""
    log_info "  SSH in:       ssh ${REAL_USER}@${HOTSPOT_IP}"
    log_info "  mDNS:         ssh ${REAL_USER}@${PI_HOSTNAME}.local"
    log_info ""
    log_info "  Service:      sudo systemctl status pizero-hotspot"
    log_info "  Watchdog log: sudo journalctl -t pizero-wifi-watchdog -f"
    log_info "  Force AP on:  sudo pizero-hotspot-start"
    log_info "  Force AP off: sudo pizero-hotspot-stop"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    REBOOT_REQUIRED=true
}

# ─────────────────────────────────────────────────────────────
step_clapper() {
    [[ "${INSTALL_CLAPPER:-no}" != "yes" ]] && return 0
    section "STEP 10: CLAPPER (clap → Wake-on-LAN)"
    dry "install clapper" || return 0

    local bin_src="${PKG_DIR}/bin/clapper"
    local bin_dst="/home/${REAL_USER}/clapper"

    # ── Binary ───────────────────────────────────────────────────
    if [[ ! -f "$bin_src" ]]; then
        log_warn "clapper binary not found at ${bin_src}"
        log_warn "Cross-compile it first:  make build  (on your dev machine)"
        log_warn "Then copy to:            provision/bin/clapper"
    else
        cp -f "$bin_src" "$bin_dst"
        chmod 755 "$bin_dst"
        chown "${REAL_USER}:${REAL_USER}" "$bin_dst"
        log_ok "Binary deployed: ${bin_dst}"
    fi

    # ── systemd service ──────────────────────────────────────────
    cp -f "${PKG_DIR}/systemd/clapper.service" \
          /etc/systemd/system/clapper.service
    systemctl daemon-reload
    systemctl enable clapper.service
    log_ok "clapper.service: enabled"

    if [[ -f "$bin_dst" ]]; then
        systemctl restart clapper.service 2>/dev/null || true
        log_ok "clapper.service: started"
    else
        log_warn "Service enabled but not started — deploy binary first, then:"
        log_warn "  sudo systemctl start clapper"
    fi
}

# ─────────────────────────────────────────────────────────────
step_pcctl() {
    [[ "${INSTALL_PCCTL:-no}" != "yes" ]] && return 0
    section "STEP 11: PCCTL (remote PC power control)"
    dry "install pcctl" || return 0

    local bin_src="${PKG_DIR}/bin/pcctl"
    local bin_dst="/home/${REAL_USER}/pcctl"

    # ── Binary ───────────────────────────────────────────────────
    if [[ ! -f "$bin_src" ]]; then
        log_warn "pcctl binary not found at ${bin_src}"
        log_warn "Cross-compile it first:  make build  (on your dev machine)"
        log_warn "Then copy to:            provision/bin/pcctl"
    else
        cp -f "$bin_src" "$bin_dst"
        chmod 755 "$bin_dst"
        chown "${REAL_USER}:${REAL_USER}" "$bin_dst"
        log_ok "Binary deployed: ${bin_dst}"
    fi

    # ── SSH key for the power-down commands ──────────────────────
    # Generated here rather than shipped, so the private half never leaves the
    # Pi. Its public half goes to the PC's Setup-RemotePower.ps1.
    local key="/home/${REAL_USER}/.ssh/id_pcctl"
    if [[ -f "$key" ]]; then
        log_skip "SSH key already present: ${key}"
    elif ! command -v ssh-keygen >/dev/null 2>&1; then
        # Not fatal: waking needs no key at all, only sleep/shutdown do.
        log_warn "ssh-keygen not found — install openssh-client and re-run to enable sleep/shutdown"
    else
        sudo -u "${REAL_USER}" mkdir -p "/home/${REAL_USER}/.ssh"
        chmod 700 "/home/${REAL_USER}/.ssh"
        sudo -u "${REAL_USER}" ssh-keygen -t ed25519 -N "" -C "pcctl@${PI_HOSTNAME}" -f "$key" >/dev/null
        log_ok "Generated ${key}"
    fi

    if [[ -f "${key}.pub" ]]; then
        log_info "Public key for the PC's Setup-RemotePower.ps1 -PublicKey:"
        echo ""
        cat "${key}.pub"
        echo ""
    fi

    # ── systemd service ──────────────────────────────────────────
    cp -f "${PKG_DIR}/systemd/pcctl.service" \
          /etc/systemd/system/pcctl.service
    systemctl daemon-reload
    systemctl enable pcctl.service
    log_ok "pcctl.service: enabled"

    if [[ -f "$bin_dst" ]]; then
        systemctl restart pcctl.service 2>/dev/null || true
        log_ok "pcctl.service: started"
    else
        log_warn "Service enabled but not started — deploy binary first, then:"
        log_warn "  sudo systemctl start pcctl"
    fi
}

# ─────────────────────────────────────────────────────────────
step_cleanup() {
    section "STEP 12: CLEANUP"
    dry "cleanup" || return 0

    local before
    before=$(df / --output=avail -BM | tail -1 | tr -dc '0-9')

    apt-get clean -y
    apt-get autoclean -y
    apt-get autoremove --purge -y 2>&1 \
        | grep -v "automatically installed" \
        | grep -v "apt autoremove" \
        | tail -5
    log_ok "APT cache cleaned"

    # Vacuum journal
    journalctl --vacuum-time=7d --vacuum-size=16M 2>&1 | tail -2
    log_ok "Journal vacuumed"

    # Temp files
    find /tmp    -mindepth 1 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true
    rm -f /var/cache/man/* 2>/dev/null || true
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null || true
    log_ok "Temp and old log files cleaned"

    local after saved
    after=$(df / --output=avail -BM | tail -1 | tr -dc '0-9')
    saved=$(( after - before ))
    [[ "$saved" -gt 0 ]] \
        && log_ok "Freed ~${saved} MB of disk space" \
        || log_info "No additional space freed"
}

# ─────────────────────────────────────────────────────────────
step_health() {
    section "HEALTH REPORT"

    echo -e "  ${BOLD}Hardware${NC}"
    echo -e "  ├─ Board:    $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo 'unknown')"
    echo -e "  ├─ Kernel:   $(uname -r)"
    if command -v vcgencmd &>/dev/null; then
        echo -e "  ├─ Temp:     $(vcgencmd measure_temp 2>/dev/null | sed 's/temp=//')"
        echo -e "  ├─ Clock:    $(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{printf "%.0f MHz", $2/1000000}')"
        local thr; thr=$(vcgencmd get_throttled 2>/dev/null || echo 'N/A')
        [[ "$thr" == "throttled=0x0" ]] \
            && echo -e "  ├─ Power:    ${GREEN}OK — ${thr}${NC}" \
            || echo -e "  ├─ Power:    ${YELLOW}${thr} — check PSU${NC}"
    fi

    echo -e "\n  ${BOLD}Memory${NC}"
    local mt ma mp cma
    mt=$(awk '/MemTotal/{printf "%.0f",  $2/1024}' /proc/meminfo)
    ma=$(awk '/MemAvailable/{printf "%.0f", $2/1024}' /proc/meminfo)
    mp=$(( (mt - ma) * 100 / mt ))
    cma=$(awk '/CmaTotal/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo "N/A")
    echo -e "  ├─ Total:    ${mt} MB"
    echo -e "  ├─ Free:     ${ma} MB  (${mp}% used)"
    echo -e "  ├─ CMA:      ${cma} MB"
    swapon --show --noheadings 2>/dev/null | while IFS= read -r l; do
        echo -e "  ├─ Swap:     ${l}"; done

    echo -e "\n  ${BOLD}Storage${NC}"
    df -h / /boot/firmware 2>/dev/null \
        | awk 'NR>1{printf "  ├─ %-18s %s used / %s total (%s)\n",$6,$3,$2,$5}'

    echo -e "\n  ${BOLD}Network${NC}"
    local iface
    iface=$(iw dev 2>/dev/null | awk '/Interface/{print $2}' | head -1 || true)
    if [[ -n "${iface:-}" ]]; then
        local ssid sig
        ssid=$(iw dev "$iface" link 2>/dev/null | awk '/SSID/{print $2}' || echo "?")
        sig=$(iw dev  "$iface" link 2>/dev/null | awk '/signal/{print $2,$3}' || echo "?")
        echo -e "  ├─ wlan0:    ${ssid:-disconnected}  ${sig}"
    fi
    local myip
    myip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    echo -e "  ├─ IP:       ${myip}"

    # Show hotspot (uap0) status
    local hs_state
    hs_state=$(systemctl is-active pizero-hotspot.service 2>/dev/null || echo "not installed")
    echo -e "  ├─ Hotspot service: ${hs_state}"
    if ip link show uap0 &>/dev/null 2>&1; then
        local uap_ip
        uap_ip=$(ip -4 addr show uap0 2>/dev/null | awk '/inet /{print $2}' | head -1 || echo "no IP")
        echo -e "  ├─ uap0 (AP): UP  ${uap_ip}"
    else
        echo -e "  ├─ uap0 (AP): not active"
    fi

    echo -e "\n  ${BOLD}Services${NC}"
    local run fail
    run=$(systemctl list-units  --type=service --state=running --no-pager --no-legend | wc -l)
    fail=$(systemctl list-units --type=service --state=failed  --no-pager --no-legend | wc -l)
    echo -e "  ├─ Running: ${run}"
    [[ "$fail" -gt 0 ]] \
        && echo -e "  ├─ ${RED}Failed:  ${fail}${NC}" \
        || echo -e "  ├─ Failed:  ${GREEN}${fail}${NC}"
    if [[ "$fail" -gt 0 ]]; then
        systemctl list-units --type=service --state=failed --no-pager --no-legend \
            | while IFS= read -r l; do echo -e "  │  ${RED}↳ ${l}${NC}"; done
    fi

    echo -e "\n  ${BOLD}SD Card${NC}"
    [[ -f /sys/block/mmcblk0/device/name ]] \
        && echo -e "  ├─ Card:    $(cat /sys/block/mmcblk0/device/name)"
    if [[ -f /sys/block/mmcblk0/device/pre_eol_info ]]; then
        local eol; eol=$(cat /sys/block/mmcblk0/device/pre_eol_info)
        case "$eol" in
            0x01) echo -e "  ├─ Health:  ${GREEN}Normal${NC}" ;;
            0x02) echo -e "  ├─ Health:  ${YELLOW}Warning — consider replacing${NC}" ;;
            0x03) echo -e "  ├─ Health:  ${RED}Urgent — replace SD card${NC}" ;;
            *)    echo -e "  ├─ Health:  ${eol}" ;;
        esac
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────
main() {
    setup_logging
    banner
    load_config

    $FLAG_DRY_RUN && echo -e "  ${YELLOW}${BOLD}*** DRY RUN — no changes will be made ***${NC}\n"

    local t0; t0=$(date +%s)

    step_preflight
    step_backup
    step_update
    step_packages
    step_wifi
    step_system
    step_performance
    step_headless
    step_services
    step_tools
    step_hotspot
    step_clapper
    step_pcctl
    step_cleanup
    step_health

    local elapsed=$(( $(date +%s) - t0 ))
    section "DONE"
    echo -e "  ${GREEN}${BOLD}Installation complete.${NC}"
    echo ""
    echo -e "  Duration: $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
    echo -e "  Log:      ${LOG_FILE}"
    echo -e "  Backups:  ${BACKUP_DIR}"
    echo ""

    if $REBOOT_REQUIRED && ! $FLAG_DRY_RUN; then
        echo -e "  ${YELLOW}${BOLD}⚡ REBOOT REQUIRED for all changes to take effect.${NC}"
        echo ""
        if ! $FLAG_NO_REBOOT; then
            read -rp "  Reboot now? [y/N] " r
            if [[ "${r,,}" == "y" ]]; then
                log_info "Rebooting in 5 seconds..."
                sleep 5
                reboot
            else
                log_info "Reboot skipped — run: sudo reboot"
            fi
        else
            log_info "Reboot skipped (--no-reboot) — run: sudo reboot"
        fi
    fi
}

main
