#!/usr/bin/env bash
# =============================================================
#  wifi-watchdog.sh  —  Pi Zero 2 WH Wi-Fi watchdog daemon
#  Installed to /usr/local/lib/pizero/wifi-watchdog.sh
#  Runs as a systemd service (pizero-hotspot.service) on boot.
#
#  State machine:
#
#    BOOT
#      └─ wait HOTSPOT_TIMEOUT seconds for home WiFi
#           ├─ WiFi OK  → NORMAL mode (periodic health check)
#           └─ No WiFi  → start hotspot → HOTSPOT mode
#
#    NORMAL mode  (check every RUNNING_CHECK_INTERVAL seconds)
#      └─ WiFi lost → start hotspot → HOTSPOT mode
#
#    HOTSPOT mode  (try home network every RECHECK_INTERVAL seconds)
#      └─ Home network back → stop hotspot → NORMAL mode
#
#  Key design decisions from hardware research:
#  - AP/STA concurrency: uap0 virtual interface for AP,
#    wlan0 stays managed by NM throughout (never disconnected)
#  - "has WiFi" = has IP *and* can reach the gateway
#    (just having an IP is not enough — NM can assign one and
#    still have no route)
#  - nmcli --terse output only — human-readable output changes
#    between versions and must never be parsed
#  - No set -euo pipefail — must run forever; any error is
#    logged and the loop continues
# =============================================================

PHYS_IFACE="wlan0"
AP_IFACE="uap0"
HOTSPOT_IP="${HOTSPOT_IP:-10.42.0.1}"
HOTSPOT_TIMEOUT="${HOTSPOT_TIMEOUT:-60}"
RECHECK_INTERVAL=30       # seconds between home-network retries in hotspot mode
RUNNING_CHECK_INTERVAL=45 # seconds between WiFi health checks in normal mode
GATEWAY_PING_TIMEOUT=3    # seconds for gateway ping timeout

START_SCRIPT="/usr/local/lib/pizero/hotspot-start.sh"
STOP_SCRIPT="/usr/local/lib/pizero/hotspot-stop.sh"

HOTSPOT_ACTIVE=false
CONSECUTIVE_FAILURES=0    # track repeated hotspot start failures
MAX_FAILURES=5            # reboot after this many consecutive failures

# ── Logging ───────────────────────────────────────────────────
jlog()  {
    local msg="[wifi-watchdog] $(date '+%H:%M:%S') $*"
    echo "$msg" | systemd-cat -t pizero-wifi-watchdog -p info    2>/dev/null
    echo "$msg"
}
jwarn() {
    local msg="[wifi-watchdog] $(date '+%H:%M:%S') WARN: $*"
    echo "$msg" | systemd-cat -t pizero-wifi-watchdog -p warning 2>/dev/null
    echo "$msg"
}
jerr()  {
    local msg="[wifi-watchdog] $(date '+%H:%M:%S') ERR: $*"
    echo "$msg" | systemd-cat -t pizero-wifi-watchdog -p err     2>/dev/null
    echo "$msg" >&2
}

# ── has_normal_wifi ───────────────────────────────────────────
# Returns 0 (true) only when BOTH conditions are met:
#   1. wlan0 has an IP address that is not the hotspot IP
#   2. The default gateway is reachable via ping
#
# Checking just for an IP is insufficient — NM can assign
# an IP while the AP is still associating, or DHCP can succeed
# on a captive portal that intercepts all traffic.
has_normal_wifi() {
    # Check 1: does wlan0 have an IP?
    local ip
    ip=$(ip -4 addr show "$PHYS_IFACE" 2>/dev/null \
         | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || true)
    if [[ -z "$ip" || "$ip" == "$HOTSPOT_IP" ]]; then
        return 1
    fi

    # Check 2: can we reach the default gateway?
    local gw
    gw=$(ip route show dev "$PHYS_IFACE" 2>/dev/null \
         | awk '/default/{print $3}' | head -1 || true)
    if [[ -z "$gw" ]]; then
        # No default route on wlan0 yet
        return 1
    fi

    ping -c1 -W"$GATEWAY_PING_TIMEOUT" -I "$PHYS_IFACE" "$gw" \
        &>/dev/null 2>&1
}

# ── nm_wifi_state ─────────────────────────────────────────────
# Returns the NM connection state of wlan0 as a string.
# Uses --terse to get machine-readable output that doesn't
# change between NM versions.
nm_wifi_state() {
    nmcli -t -f GENERAL.STATE dev show "$PHYS_IFACE" 2>/dev/null \
        | cut -d: -f2 || echo "unknown"
}

# ── start_hotspot ─────────────────────────────────────────────
start_hotspot() {
    if $HOTSPOT_ACTIVE; then
        return 0
    fi
    jwarn "Starting fallback hotspot..."
    if bash "$START_SCRIPT"; then
        HOTSPOT_ACTIVE=true
        CONSECUTIVE_FAILURES=0
        jlog "Hotspot active on ${AP_IFACE}"
    else
        jerr "hotspot-start.sh failed"
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        HOTSPOT_ACTIVE=false
        jlog "Consecutive start failures: ${CONSECUTIVE_FAILURES}/${MAX_FAILURES}"

        # Safety valve: if hotspot can never start, reboot after
        # MAX_FAILURES attempts. This handles hardware wedge states.
        if [[ $CONSECUTIVE_FAILURES -ge $MAX_FAILURES ]]; then
            jerr "Too many consecutive hotspot failures — rebooting in 30s"
            jerr "Check: journalctl -t hostapd -t pizero-hotspot --no-pager -n 50"
            sleep 30
            systemctl reboot 2>/dev/null || reboot 2>/dev/null || true
        fi
    fi
}

# ── stop_hotspot ──────────────────────────────────────────────
stop_hotspot() {
    if ! $HOTSPOT_ACTIVE; then
        return 0
    fi
    jlog "Stopping hotspot (home network restored)..."
    bash "$STOP_SCRIPT" 2>/dev/null || true
    HOTSPOT_ACTIVE=false
}

# ── Sanity checks ─────────────────────────────────────────────
for script in "$START_SCRIPT" "$STOP_SCRIPT"; do
    if [[ ! -x "$script" ]]; then
        jerr "Script not found or not executable: $script"
        jerr "Run: sudo bash ~/provision/scripts/install.sh"
        exit 1
    fi
done
for conf in /etc/hostapd/pizero-fallback.conf \
             /etc/dnsmasq.d/pizero-hotspot.conf; do
    if [[ ! -f "$conf" ]]; then
        jerr "Config missing: $conf"
        jerr "Run: sudo bash ~/provision/scripts/install.sh"
        exit 1
    fi
done

# Ensure rfkill is not blocking us at start
rfkill unblock wifi 2>/dev/null || true

jlog "Watchdog started"
jlog "  Interface:    ${PHYS_IFACE} (STA) / ${AP_IFACE} (AP virtual)"
jlog "  Timeout:      ${HOTSPOT_TIMEOUT}s"
jlog "  Hotspot IP:   ${HOTSPOT_IP}"
jlog "  NM state:     $(nm_wifi_state)"

# ── Phase 1: Boot — wait for home WiFi ───────────────────────
# Give NM time to connect to the configured home network.
# Poll every 5 s up to HOTSPOT_TIMEOUT.
jlog "Phase 1: Waiting up to ${HOTSPOT_TIMEOUT}s for home WiFi..."
elapsed=0
while [[ $elapsed -lt $HOTSPOT_TIMEOUT ]]; do
    if has_normal_wifi; then
        local_ip=$(ip -4 addr show "$PHYS_IFACE" 2>/dev/null \
                   | awk '/inet /{print $2}' | head -1 || echo "?")
        jlog "Home WiFi connected: ${local_ip} (NM state: $(nm_wifi_state))"
        break
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
    jlog "  Waiting... ${elapsed}/${HOTSPOT_TIMEOUT}s  NM: $(nm_wifi_state)"
done

if ! has_normal_wifi; then
    jwarn "No home WiFi after ${HOTSPOT_TIMEOUT}s — raising hotspot"
    start_hotspot
fi

# ── Phase 2: Main monitoring loop ────────────────────────────
# Runs forever. Systemd Restart=always handles unexpected exits.
jlog "Phase 2: Entering monitoring loop..."
while true; do

    if $HOTSPOT_ACTIVE; then
        # ── Hotspot mode ──────────────────────────────────────
        # Wait, then try to reconnect to home network.
        sleep "$RECHECK_INTERVAL"
        jlog "Hotspot mode: checking for home network (NM: $(nm_wifi_state))..."

        # wlan0 was never taken away from NM — it may have already
        # reconnected on its own during AP/STA concurrency.
        # Check before doing anything disruptive.
        if has_normal_wifi; then
            local_ip=$(ip -4 addr show "$PHYS_IFACE" 2>/dev/null \
                       | awk '/inet /{print $2}' | head -1 || echo "?")
            jlog "Home network found (already connected: ${local_ip}) — dropping hotspot"
            stop_hotspot
        else
            # Stop hotspot temporarily, give NM a chance to connect
            bash "$STOP_SCRIPT" 2>/dev/null || true
            HOTSPOT_ACTIVE=false

            # Wait up to 15 s for NM to establish connection
            recheck_i=0
            while [[ $recheck_i -lt 3 ]]; do
                sleep 5
                has_normal_wifi && break
                recheck_i=$(( recheck_i + 1 ))
            done

            if has_normal_wifi; then
                local_ip=$(ip -4 addr show "$PHYS_IFACE" 2>/dev/null \
                           | awk '/inet /{print $2}' | head -1 || echo "?")
                jlog "Home network restored: ${local_ip}"
                CONSECUTIVE_FAILURES=0
            else
                jwarn "Home network still unavailable — re-raising hotspot"
                start_hotspot
            fi
        fi

    else
        # ── Normal mode ───────────────────────────────────────
        # Periodically verify the home WiFi is still healthy.
        sleep "$RUNNING_CHECK_INTERVAL"

        if ! has_normal_wifi; then
            jwarn "WiFi health check failed (NM: $(nm_wifi_state))"

            # Give NM one more chance to self-heal before going to hotspot
            jlog "Waiting 15s for NM to self-recover..."
            sleep 15

            if has_normal_wifi; then
                jlog "WiFi recovered on its own"
            else
                jwarn "WiFi still down — raising hotspot"
                start_hotspot
            fi
        fi
    fi

done
