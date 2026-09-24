#!/usr/bin/env bash
# =============================================================
#  pizero-confirm.sh  —  "the new WiFi/SSH config works, don't
#  roll it back." Run this after logging in successfully once
#  install.sh has applied network/SSH changes (bootstrap.ps1
#  does this automatically after it reconnects post-reboot).
# =============================================================
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must be run as root: sudo pizero-confirm" >&2
    exit 1
fi

SNAP_DIR="/etc/pizero/rollback-snapshot"

systemctl disable --now pizero-rollback.timer 2>/dev/null || true
rm -rf "$SNAP_DIR"
rm -f /etc/pizero/rollback-reboot

echo "Confirmed — rollback timer disarmed, snapshot removed."
