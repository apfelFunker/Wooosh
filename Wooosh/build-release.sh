#!/bin/bash
#
# Baut Wooosh.app als Universal Binary, signiert sie mit Developer ID,
# notarisiert und heftet das Ticket an. Ergebnis liegt in ./dist.
#
# Einmalig vorab, damit die Notarisierung ohne Rückfrage läuft:
#
#   xcrun notarytool store-credentials "wooosh-notary" \
#       --apple-id DEINE@APPLE.ID --team-id 9FZVQ84P7B
#
# Das fragt nach einem app-spezifischen Passwort (appleid.apple.com →
# Anmeldung & Sicherheit → App-spezifische Passwörter) und legt es im
# Schlüsselbund ab. Fehlt das Profil, baut das Skript trotzdem eine signierte
# App, überspringt aber die Notarisierung und sagt das deutlich.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

TEAM_ID="9FZVQ84P7B"
NOTARY_PROFILE="wooosh-notary"
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

DIST="$DIR/dist"
APP="$DIST/Wooosh.app"
ZIP="$DIST/Wooosh-$VERSION.zip"

echo "==> Wooosh $VERSION"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen" >&2; exit 1; }

echo "==> Icon aus ../Icon übernehmen"
rm -rf Resources/schild.icon
cp -R ../Icon/schild.icon Resources/

echo "==> Projekt erzeugen"
xcodegen generate >/dev/null

echo "==> Archivieren (arm64 + x86_64)"
rm -rf "$DIST" .build
xcodebuild archive \
	-project Wooosh.xcodeproj \
	-scheme Wooosh \
	-configuration Release \
	-archivePath .build/Wooosh.xcarchive \
	-derivedDataPath .build/dd \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	-allowProvisioningUpdates >/dev/null

# Signiert wird beim Export, nicht beim Bauen: Xcode lehnt eine manuell
# gesetzte Developer-ID-Identität bei automatischer Signierung ab. Der Export
# signiert das Archiv mit "Developer ID Application" neu.
echo "==> Mit Developer ID exportieren"
xcodebuild -exportArchive \
	-archivePath .build/Wooosh.xcarchive \
	-exportOptionsPlist ExportOptions.plist \
	-exportPath .build/export \
	-allowProvisioningUpdates >/dev/null

mkdir -p "$DIST"
cp -R .build/export/Wooosh.app "$APP"

echo "==> Prüfen"
lipo -info "$APP/Contents/MacOS/Wooosh"

# In eine Variable, nicht in eine Pipe: `grep -q` steigt beim ersten Treffer
# aus, codesign bekommt SIGPIPE, und `set -o pipefail` würde das als Fehler
# werten — die Prüfung schlüge ausgerechnet dann fehl, wenn sie zutrifft.
SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
echo "$SIGNATURE" | grep -E "^Authority=Developer ID|^TeamIdentifier"

case "$SIGNATURE" in
	*"Authority=Developer ID Application"*) ;;
	*) echo "Nicht mit Developer ID signiert." >&2; exit 1 ;;
esac

# Notarisierung verlangt die Hardened Runtime. Ohne sie wird der Upload
# angenommen und erst Minuten später abgelehnt — hier abbrechen ist billiger.
case "$SIGNATURE" in
	*"(runtime)"*) ;;
	*) echo "Hardened Runtime fehlt — Notarisierung würde scheitern." >&2; exit 1 ;;
esac

echo "==> Packen"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# --- Notarisierung -----------------------------------------------------------

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	cat >&2 <<EOF

──────────────────────────────────────────────────────────────────────
  Notarisierung übersprungen — kein Zugang hinterlegt

  Die App ist mit Developer ID signiert, aber nicht notarisiert.
  Gatekeeper blockiert sie damit weiterhin.

  Einmalig einrichten:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id DEINE@APPLE.ID --team-id $TEAM_ID

  Danach dieses Skript erneut ausführen.
──────────────────────────────────────────────────────────────────────

EOF
	echo "Fertig (unnotarisiert): $ZIP"
	shasum -a 256 "$ZIP"
	exit 0
fi

echo "==> Notarisieren (dauert meist 1–5 Minuten)"
if ! xcrun notarytool submit "$ZIP" \
	--keychain-profile "$NOTARY_PROFILE" \
	--wait 2>&1 | tee .build/notary.log; then
	echo "Notarisierung fehlgeschlagen — siehe .build/notary.log" >&2
	exit 1
fi

if ! grep -q "status: Accepted" .build/notary.log; then
	echo "Notarisierung nicht angenommen. Details:" >&2
	SUBMISSION=$(grep -m1 "id:" .build/notary.log | awk '{print $2}')
	[ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" \
		--keychain-profile "$NOTARY_PROFILE" >&2
	exit 1
fi

# Das Ticket wird an die App geheftet, damit sie auch offline sofort startet.
# Danach neu packen — das alte ZIP enthält die App noch ohne Ticket.
echo "==> Ticket anheften"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper-Urteil"
spctl -a -vv "$APP" 2>&1 | tail -3
xcrun stapler validate "$APP"

echo ""
echo "Fertig: $ZIP"
shasum -a 256 "$ZIP"
