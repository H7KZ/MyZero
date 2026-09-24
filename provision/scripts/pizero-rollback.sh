#!/usr/bin/env bash
# =============================================================
#  pizero-rollback.sh  —  restores NM + sshd config from the
#  snapshot taken by install.sh before it changed them.
#
#  Run automatically by the pizero-rollback.timer/.service if
#  nobody runs `sudo pizero-confirm` within ROLLBACK_MINUTES of
#  install.sh applying network/SSH changes. This is the safety
#  net for "the new WiFi config or SSH hardening locked me out."
# =============================================================
set -uo pipefail

SNAP_DIR="/etc/pizero/rollback-snapshot"
LOG_TAG="pizero-rollback"

log() { logger -t "$LOG_TAG" "$*"; echo "[$LOG_TAG] $*"; }

if [[ ! -d "$SNAP_DIR" ]]; then
    log "No snapshot present — nothing to roll back (already confirmed or never armed)."
    exit 0
fi

log "Rolling back NetworkManager + sshd config to pre-install state..."

if [[ -d "${SNAP_DIR}/system-connections" ]]; then
    rm -rf /etc/NetworkManager/system-connections
    cp -a "${SNAP_DIR}/system-connections" /etc/NetworkManager/system-connections
    log "Restored NetworkManager system-connections"
fi

if [[ -f "${SNAP_DIR}/pizero.conf" ]]; then
    cp -a "${SNAP_DIR}/pizero.conf" /etc/ssh/sshd_config.d/pizero.conf
    log "Restored sshd_config.d/pizero.conf"
elif [[ -f "${SNAP_DIR}/no-sshd-conf" ]]; then
    rm -f /etc/ssh/sshd_config.d/pizero.conf
    log "Removed sshd_config.d/pizero.conf (none existed before install)"
fi

systemctl restart NetworkManager 2>/dev/null || true
if sshd -t 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
fi

# Disarm — the rollback already ran, don't let it fire again next boot.
systemctl disable --now pizero-rollback.timer 2>/dev/null || true
rm -rf "$SNAP_DIR"

log "Rollback complete."

if [[ -f /etc/pizero/rollback-reboot ]]; then
    rm -f /etc/pizero/rollback-reboot
    log "Rebooting to apply rolled-back config..."
    reboot
fi
