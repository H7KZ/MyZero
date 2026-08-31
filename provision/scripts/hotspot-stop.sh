#!/usr/bin/env bash
# =============================================================
#  hotspot-stop.sh  —  Tear down the Pi Zero 2 WH fallback AP
#  Installed to /usr/local/lib/pizero/hotspot-stop.sh
#
#  Stops hostapd and dnsmasq, deletes the uap0 virtual
#  interface, then lets NetworkManager reconnect wlan0 to
#  the home network. wlan0 was never disconnected — NM kept
#  managing it throughout the AP/STA concurrency session.
#
#  NO set -euo pipefail — must complete all steps even if
#  earlier ones fail.
# =============================================================

PHYS_IFACE="wlan0"
AP_IFACE="uap0"
PID_HOSTAPD="/run/pizero-hostapd.pid"
PID_DNSMASQ="/run/pizero-dnsmasq.pid"
RUNTIME_HOSTAPD="/run/pizero-hostapd-runtime.conf"
RUNTIME_DNSMASQ="/run/pizero-dnsmasq-runtime.conf"

jlog() {
    local msg="[hotspot-stop] $(date '+%H:%M:%S') $*"
    echo "$msg" | systemd-cat -t pizero-hotspot -p info 2>/dev/null
    echo "$msg"
}
jwarn() {
    local msg="[hotspot-stop] $(date '+%H:%M:%S') WARN: $*"
    echo "$msg" | systemd-cat -t pizero-hotspot -p warning 2>/dev/null
    echo "$msg"
}

jlog "Stopping fallback AP..."

# ── Step 1: Stop hostapd ──────────────────────────────────────
if [[ -f "$PID_HOSTAPD" ]]; then
    local_pid=$(cat "$PID_HOSTAPD" 2>/dev/null || true)
    if [[ -n "$local_pid" ]]; then
        jlog "Stopping hostapd (PID ${local_pid})..."
        kill "$local_pid" 2>/dev/null || true
        # Wait up to 5 s for hostapd to exit
        local i=0
        while kill -0 "$local_pid" 2>/dev/null && [[ $i -lt 10 ]]; do
            sleep 0.5; i=$(( i + 1 ))
        done
        kill -9 "$local_pid" 2>/dev/null || true
    fi
    rm -f "$PID_HOSTAPD"
fi
pkill -f "hostapd.*pizero" 2>/dev/null || true

# ── Step 2: Stop dnsmasq ─────────────────────────────────────
if [[ -f "$PID_DNSMASQ" ]]; then
    local_pid=$(cat "$PID_DNSMASQ" 2>/dev/null || true)
    if [[ -n "$local_pid" ]]; then
        jlog "Stopping dnsmasq (PID ${local_pid})..."
        kill "$local_pid" 2>/dev/null || true
        sleep 1
        kill -9 "$local_pid" 2>/dev/null || true
    fi
    rm -f "$PID_DNSMASQ"
fi
pkill -f "dnsmasq.*pizero" 2>/dev/null || true

# ── Step 3: Remove the virtual AP interface ──────────────────
# IMPORTANT: iw dev uap0 del must be called, not just ip link del.
# Leaving a zombie virtual interface causes iw to refuse to create
# a new one on the next hotspot-start, failing with EBUSY.
if ip link show "$AP_IFACE" &>/dev/null 2>&1; then
    jlog "Removing virtual interface ${AP_IFACE}..."
    ip link set "$AP_IFACE" down 2>/dev/null || true
    sleep 1
    iw dev "$AP_IFACE" del 2>/dev/null || true
    if ip link show "$AP_IFACE" &>/dev/null 2>&1; then
        jwarn "${AP_IFACE} still present after iw del — forcing with ip link del"
        ip link delete "$AP_IFACE" 2>/dev/null || true
    fi
else
    jlog "${AP_IFACE} not present (already removed)"
fi

# ── Step 4: Clean up runtime config files ────────────────────
rm -f "$RUNTIME_HOSTAPD" "$RUNTIME_DNSMASQ" 2>/dev/null || true

# ── Step 5: wlan0 — re-enable power management if desired ────
# We disabled PM in hotspot-start for stability. Restore it now
# so NM's power profile settings take effect again.
# (NM will re-apply its own powersave setting on reconnect.)
# NOTE: We do NOT touch NM's management of wlan0 here — it was
# never disconnected during AP/STA concurrency. NM should already
# be maintaining or re-establishing the home WiFi connection.
jlog "wlan0 remains under NetworkManager — no action needed"

# If wlan0 is not connected, prompt NM to reconnect
NM_STATE=$(nmcli -t -f GENERAL.STATE dev show "$PHYS_IFACE" 2>/dev/null \
           | cut -d: -f2 || echo "")
if [[ "$NM_STATE" != *"connected"* ]]; then
    jlog "wlan0 not connected — asking NM to scan and reconnect..."
    nmcli device connect "$PHYS_IFACE" 2>/dev/null || true
fi

jlog "Fallback AP is DOWN — ${AP_IFACE} removed, ${PHYS_IFACE} under NM"
exit 0
