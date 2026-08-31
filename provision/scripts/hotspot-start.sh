#!/usr/bin/env bash
# =============================================================
#  hotspot-start.sh  —  Raise the Pi Zero 2 WH fallback AP
#  Installed to /usr/local/lib/pizero/hotspot-start.sh
#
#  Architecture (AP/STA Concurrency):
#    wlan0 (physical) → stays in managed/STA mode under NM
#    uap0  (virtual)  → we create this as the AP interface
#
#    The CYW43438 has ONE radio: both interfaces must share the
#    same channel. We detect wlan0's active channel and sync.
#
#    uap0 gets a locally-administered MAC (bit 1 of byte 0
#    flipped) to prevent IAID/DHCP conflicts with wlan0.
#
#  NO set -euo pipefail — must survive any transient error.
#
#  ROOT CAUSE OF country_code/COUNTRY_UPDATE FAILURE:
#    When hostapd sees country_code= in its config it signals
#    the driver to do a regulatory domain update. The driver
#    briefly tears down the interface (COUNTRY_UPDATE->DISABLED)
#    while reconfiguring RF params. If hostapd tries to set
#    beacons during that window it gets ENODEV and fails.
#
#    FIX: set the regulatory domain on the PHYSICAL interface
#    BEFORE creating uap0, wait for it to settle, then start
#    hostapd WITHOUT country_code in the config. The driver
#    already has the correct reg domain from the iw call.
# =============================================================

PHYS_IFACE="wlan0"
AP_IFACE="uap0"
HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
NETMASK="24"
CONF_HOSTAPD="/etc/hostapd/pizero-fallback.conf"
CONF_DNSMASQ="/etc/dnsmasq.d/pizero-hotspot.conf"
PID_HOSTAPD="/run/pizero-hostapd.pid"
PID_DNSMASQ="/run/pizero-dnsmasq.pid"
RUNTIME_HOSTAPD="/run/pizero-hostapd-runtime.conf"
RUNTIME_DNSMASQ="/run/pizero-dnsmasq-runtime.conf"
LOG_DNSMASQ="/run/pizero-dnsmasq.log"

# ── Logging ───────────────────────────────────────────────────
jlog() {
    local msg="[hotspot-start] $(date '+%H:%M:%S') $*"
    echo "$msg" | systemd-cat -t pizero-hotspot -p info 2>/dev/null
    echo "$msg"
}
jerr() {
    local msg="[hotspot-start] $(date '+%H:%M:%S') ERROR: $*"
    echo "$msg" | systemd-cat -t pizero-hotspot -p err 2>/dev/null
    echo "$msg" >&2
}

# ── Locally-administered MAC for uap0 ────────────────────────
# Flips bit 1 of byte 0 to mark as locally-administered and
# clears bit 0 (unicast). Prevents IAID conflict with wlan0.
_local_mac() {
    local mac
    mac=$(ip link show "$PHYS_IFACE" 2>/dev/null \
          | awk '/ether/{print $2}' | head -1)
    if [[ -z "$mac" ]]; then
        printf '02:%02x:%02x:%02x:%02x:%02x\n' \
            $(( RANDOM % 256 )) $(( RANDOM % 256 )) \
            $(( RANDOM % 256 )) $(( RANDOM % 256 )) \
            $(( RANDOM % 256 ))
        return
    fi
    local b0
    b0=$(printf '%d' "0x$(echo "$mac" | cut -d: -f1)")
    printf '%02x:%s\n' \
        "$(( (b0 | 0x02) & 0xFE ))" \
        "$(echo "$mac" | cut -d: -f2-)"
}

# ── Guard: already running? ───────────────────────────────────
if [[ -f "$PID_HOSTAPD" ]] \
&& kill -0 "$(cat "$PID_HOSTAPD" 2>/dev/null)" 2>/dev/null; then
    jlog "Already running (PID $(cat "$PID_HOSTAPD"))"
    exit 0
fi

jlog "Starting fallback AP (AP/STA concurrency on ${AP_IFACE})..."

# ── Step 1: rfkill unblock ────────────────────────────────────
jlog "rfkill: unblocking wifi..."
rfkill unblock wifi 2>/dev/null || true
rfkill unblock wlan 2>/dev/null || true
sleep 1

# ── Step 2: Validate config files ────────────────────────────
for conf in "$CONF_HOSTAPD" "$CONF_DNSMASQ"; do
    if [[ ! -f "$conf" ]]; then
        jerr "Config missing: $conf — run: sudo bash ~/provision/scripts/install.sh"
        exit 1
    fi
done

# ── Step 3: Kill stale processes and remove stale uap0 ───────
jlog "Cleaning up any stale state..."
for pid_file in "$PID_HOSTAPD" "$PID_DNSMASQ"; do
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        sleep 1
        rm -f "$pid_file"
    fi
done
pkill -f "hostapd.*pizero" 2>/dev/null || true
pkill -f "dnsmasq.*pizero" 2>/dev/null || true
sleep 1

if ip link show "$AP_IFACE" &>/dev/null 2>&1; then
    jlog "Removing stale ${AP_IFACE}..."
    ip link set "$AP_IFACE" down 2>/dev/null || true
    iw dev "$AP_IFACE" del 2>/dev/null || true
    sleep 1
fi

# ── Step 4: Set regulatory domain on PHYSICAL interface FIRST ─
# CRITICAL: This must happen BEFORE creating uap0 and BEFORE
# starting hostapd. Setting country_code inside hostapd.conf
# causes the driver to do COUNTRY_UPDATE while hostapd is
# initialising, making it fail with "Could not connect to
# kernel driver". By setting it here on wlan0 and waiting for
# the regulatory event to settle, the driver is stable before
# we even create uap0. hostapd config gets NO country_code.
COUNTRY_CODE="${WIFI_COUNTRY:-}"
if [[ -z "$COUNTRY_CODE" ]]; then
    # Try to read from the currently active regulatory domain
    COUNTRY_CODE=$(iw reg get 2>/dev/null \
                   | awk '/^country /{print $2}' \
                   | tr -d ':' | head -1 || true)
fi
# Don't use "00" (world domain) — it restricts channels
if [[ -n "$COUNTRY_CODE" && "$COUNTRY_CODE" != "00" ]]; then
    jlog "Setting regulatory domain: ${COUNTRY_CODE} (on ${PHYS_IFACE} before uap0 creation)"
    iw reg set "$COUNTRY_CODE" 2>/dev/null || true
    # Wait for the kernel regulatory update to fully settle.
    # The driver fires a REGDOM_CHANGE event; if we create uap0
    # before it completes, hostapd hits the COUNTRY_UPDATE race.
    sleep 3
    jlog "Regulatory domain set — proceeding to create ${AP_IFACE}"
else
    jlog "No country code set — using world regulatory domain"
fi

# ── Step 5: Detect wlan0's active channel ────────────────────
# CYW43438 has one radio: AP and STA must share a channel.
ACTIVE_CHANNEL=""
ACTIVE_CHANNEL=$(iw dev "$PHYS_IFACE" info 2>/dev/null \
                 | awk '/channel/{print $2}' | head -1 || true)

if ! [[ "$ACTIVE_CHANNEL" =~ ^[0-9]+$ ]] \
|| [[ "$ACTIVE_CHANNEL" -lt 1 ]] \
|| [[ "$ACTIVE_CHANNEL" -gt 14 ]]; then
    ACTIVE_CHANNEL="${HOTSPOT_CHANNEL:-6}"
    jlog "wlan0 not associated — using channel ${ACTIVE_CHANNEL}"
else
    jlog "Detected channel: ${ACTIVE_CHANNEL} (syncing AP to match wlan0)"
fi

# ── Step 6: Create virtual AP interface ──────────────────────
jlog "Creating ${AP_IFACE} from ${PHYS_IFACE}..."
if ! iw dev "$PHYS_IFACE" interface add "$AP_IFACE" type __ap; then
    jerr "Failed to create ${AP_IFACE}"
    jerr "Check: iw list | grep -A10 'valid interface combinations'"
    exit 1
fi
sleep 1

LOCAL_MAC=$(_local_mac)
jlog "${AP_IFACE} MAC: ${LOCAL_MAC}"
ip link set "$AP_IFACE" address "$LOCAL_MAC" 2>/dev/null || true
ip link set "$AP_IFACE" up
sleep 1
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "${HOTSPOT_IP}/${NETMASK}" dev "$AP_IFACE"

# Disable power management on both interfaces
iwconfig "$AP_IFACE"   power off 2>/dev/null || true
iwconfig "$PHYS_IFACE" power off 2>/dev/null || true
jlog "Power management disabled on ${AP_IFACE} and ${PHYS_IFACE}"

# ── Step 7: Build runtime hostapd config ─────────────────────
# Patch interface and channel. DO NOT include country_code here —
# the driver already has the correct reg domain from Step 4.
# Adding country_code causes the COUNTRY_UPDATE race that kills
# hostapd initialisation.
jlog "Building runtime hostapd config (iface=${AP_IFACE}, channel=${ACTIVE_CHANNEL})..."
sed \
    -e "s|^interface=.*|interface=${AP_IFACE}|" \
    -e "s|^channel=.*|channel=${ACTIVE_CHANNEL}|" \
    -e "/^country_code=/d" \
    "$CONF_HOSTAPD" > "$RUNTIME_HOSTAPD"
# (The sed removes any country_code line if it was accidentally
#  left in the installed config from a previous run)

# ── Step 8: Start hostapd ─────────────────────────────────────
jlog "Starting hostapd..."
hostapd -B "$RUNTIME_HOSTAPD" -P "$PID_HOSTAPD"
# Give hostapd time to associate with the driver and send beacons
sleep 3

if ! [[ -f "$PID_HOSTAPD" ]] \
|| ! kill -0 "$(cat "$PID_HOSTAPD" 2>/dev/null)" 2>/dev/null; then
    jerr "hostapd failed to start"
    jerr "Diagnose: journalctl -t hostapd --no-pager -n 30"
    jerr "Config:   cat ${RUNTIME_HOSTAPD}"
    ip link set "$AP_IFACE" down 2>/dev/null || true
    iw dev "$AP_IFACE" del  2>/dev/null || true
    exit 1
fi
jlog "hostapd running (PID $(cat "$PID_HOSTAPD"))"

# ── Step 9: Build runtime dnsmasq config ─────────────────────
DHCP_BASE=$(echo "$HOTSPOT_IP" | cut -d. -f1-3)
jlog "Building runtime dnsmasq config (subnet ${DHCP_BASE}.0/24)..."
sed \
    -e "s|^interface=.*|interface=${AP_IFACE}|" \
    -e "s|^dhcp-range=.*|dhcp-range=${DHCP_BASE}.10,${DHCP_BASE}.50,255.255.255.0,12h|" \
    "$CONF_DNSMASQ" > "$RUNTIME_DNSMASQ"

# ── Step 10: Start dnsmasq ────────────────────────────────────
jlog "Starting dnsmasq..."
dnsmasq \
    --conf-file="$RUNTIME_DNSMASQ" \
    --pid-file="$PID_DNSMASQ" \
    --log-facility="$LOG_DNSMASQ" \
    --except-interface=lo \
    --except-interface="$PHYS_IFACE" \
    --no-resolv
sleep 1

if ! [[ -f "$PID_DNSMASQ" ]] \
|| ! kill -0 "$(cat "$PID_DNSMASQ" 2>/dev/null)" 2>/dev/null; then
    jerr "dnsmasq failed to start"
    jerr "Log:      cat ${LOG_DNSMASQ}"
    jerr "Conflict? ss -tulnp | grep ':53 '"
    kill "$(cat "$PID_HOSTAPD" 2>/dev/null)" 2>/dev/null || true
    ip link set "$AP_IFACE" down 2>/dev/null || true
    iw dev "$AP_IFACE" del  2>/dev/null || true
    exit 1
fi
jlog "dnsmasq running (PID $(cat "$PID_DNSMASQ"))"

# ── Done ──────────────────────────────────────────────────────
SSID=$(grep "^ssid=" "$CONF_HOSTAPD" 2>/dev/null | cut -d= -f2 || echo "?")
jlog "══════════════════════════════════════════════════════"
jlog "Fallback hotspot is UP"
jlog "  Interface: ${AP_IFACE}  MAC: ${LOCAL_MAC}"
jlog "  SSID:      ${SSID}"
jlog "  Channel:   ${ACTIVE_CHANNEL}"
jlog "  IP:        ${HOTSPOT_IP}  (DHCP: ${DHCP_BASE}.10–${DHCP_BASE}.50)"
jlog "  SSH:       ssh pi@${HOTSPOT_IP}"
jlog "  mDNS:      ssh pi@$(hostname 2>/dev/null || echo raspberry).local"
jlog "══════════════════════════════════════════════════════"
exit 0
