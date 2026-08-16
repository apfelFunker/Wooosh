#!/bin/bash
#
# Stoppt und entfernt DiskWarden. Logs und Statistik bleiben erhalten,
# sofern nicht --purge übergeben wird.

set -euo pipefail

LABEL="com.juliuspaetzke.diskwarden"
INSTALL_DIR="$HOME/Library/Application Support/DiskWarden"
LOG_DIR="$HOME/Library/Logs/DiskWarden"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

echo "==> Stoppe Agent"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Entferne Binary"
rm -rf "$INSTALL_DIR/bin"

if [ "${1:-}" = "--purge" ]; then
	echo "==> Entferne Konfiguration, Statistik und Logs"
	rm -rf "$INSTALL_DIR" "$LOG_DIR"
else
	echo "    Konfiguration und Logs bleiben erhalten (--purge entfernt sie)."
fi

echo "DiskWarden entfernt."
