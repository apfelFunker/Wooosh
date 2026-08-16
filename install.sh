#!/bin/bash
#
# Baut DiskWarden, installiert ihn und startet ihn als LaunchAgent.
# Idempotent — erneutes Ausführen aktualisiert eine bestehende Installation.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.juliuspaetzke.diskwarden"
INSTALL_DIR="$HOME/Library/Application Support/DiskWarden"
BIN_DIR="$INSTALL_DIR/bin"
BINARY="$BIN_DIR/diskwarden"
LOG_DIR="$HOME/Library/Logs/DiskWarden"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

echo "==> Baue Release-Binary"
cd "$REPO_DIR"
swift build -c release

echo "==> Installiere nach $BIN_DIR"
mkdir -p "$BIN_DIR" "$LOG_DIR" "$AGENT_DIR"

# Läuft der Agent bereits, muss er vor dem Überschreiben gestoppt werden.
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	echo "    stoppe laufende Instanz"
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	sleep 1
fi

install -m 755 "$REPO_DIR/.build/release/DiskWarden" "$BINARY"

# Ad-hoc-Signatur: ohne sie verliert das Binary bei jedem Ersetzen seine
# TCC-Zustimmungen und macOS fragt erneut nach Zugriffsrechten.
echo "==> Signiere ad hoc"
codesign --force --sign - "$BINARY"

echo "==> Schreibe LaunchAgent"
sed -e "s|__BINARY__|$BINARY|g" \
    -e "s|__LOGDIR__|$LOG_DIR|g" \
    "$REPO_DIR/Resources/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [ ! -f "$INSTALL_DIR/config.json" ]; then
	echo "==> Lege Standard-Konfiguration an"
	"$BINARY" --write-config
fi

echo "==> Starte Agent"
# Position im Log merken. Alles davor stammt aus früheren Läufen — auch aus
# einem manuellen --dry-run von eben — und darf die Zugriffsprüfung unten
# nicht beeinflussen.
LOG="$LOG_DIR/diskwarden.log"
LOG_OFFSET=1
[ -f "$LOG" ] && LOG_OFFSET=$(( $(wc -l < "$LOG") + 1 ))

launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl enable "$DOMAIN/$LABEL"

sleep 2
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	echo "Agent konnte nicht gestartet werden — siehe $LOG_DIR" >&2
	exit 1
fi

# Der Agent sweept ~5 s nach dem Start. Erst danach steht im Log, was er
# tatsächlich sehen konnte — und nur das zählt. Ein --check-access hier im
# Terminal wäre wertlos: die Shell hat Full Disk Access in der Regel schon,
# der launchd-Prozess erbt ihn aber nicht.
echo "==> Warte auf ersten Sweep"
agent_log() { [ -f "$LOG" ] && tail -n "+$LOG_OFFSET" "$LOG"; }

for _ in $(seq 1 40); do
	if agent_log 2>/dev/null | grep -q "Sweep fertig"; then break; fi
	sleep 1
done

echo ""
if agent_log 2>/dev/null | grep -q "Full Disk Access"; then
	cat <<'EOF'
──────────────────────────────────────────────────────────────────────
  Ein Schritt fehlt noch: Full Disk Access

  Der Agent läuft, kann aber ~/Library/Caches/CloudKit nicht lesen —
  macOS blockiert den Zugriff mit "Operation not permitted". Genau dort
  liegt der mit Abstand größte Posten.

  LaunchAgents erben die Rechte der Shell nicht, deshalb muss das Binary
  einmalig selbst freigegeben werden:

    1. Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff
    2. "+" klicken
    3. Im Dateidialog ⇧⌘G drücken und einfügen:

EOF
	echo "       $BIN_DIR"
	cat <<'EOF'

    4. "diskwarden" auswählen und den Schalter aktivieren

  Danach greift es automatisch. Prüfen mit:
EOF
	echo "    launchctl kickstart -k $DOMAIN/$LABEL"
	echo "    tail -f $LOG"
	echo "──────────────────────────────────────────────────────────────────────"
	echo ""
	read -r -p "Einstellungen jetzt öffnen? [j/N] " answer
	case "$answer" in
		[jJyY]*) open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" ;;
	esac
else
	echo "Alle aktiven Ziele erreichbar."
fi

echo ""
echo "DiskWarden läuft und startet ab jetzt bei jedem Login."
echo ""
echo "  Status:   $BINARY --status"
echo "  Ziele:    $BINARY --report"
echo "  Warum:    $BINARY --explain"
echo "  Zugriff:  $BINARY --check-access"
echo "  Log:      tail -f $LOG_DIR/diskwarden.log"
echo "  Stoppen:  $REPO_DIR/uninstall.sh"
