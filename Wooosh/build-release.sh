#!/bin/bash
#
# Baut Wooosh.app als Universal Binary, signiert sie mit Developer ID,
# notarisiert und heftet das Ticket an. Ergebnis liegt in ./dist.
#
# Vorher setzen — die Team-ID steht bewusst nicht im Repo:
#
#   export DEVELOPMENT_TEAM=XXXXXXXXXX
#
# (Apple Developer → Membership details → Team ID.)
#
# Einmalig vorab, damit die Notarisierung ohne Rückfrage läuft:
#
#   xcrun notarytool store-credentials "wooosh-notary" \
#       --apple-id DEINE@APPLE.ID --team-id $DEVELOPMENT_TEAM
#
# Das fragt nach einem app-spezifischen Passwort (appleid.apple.com →
# Anmeldung & Sicherheit → App-spezifische Passwörter) und legt es im
# Schlüsselbund ab. Fehlt das Profil, baut das Skript trotzdem eine signierte
# App, überspringt aber die Notarisierung und sagt das deutlich.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

TEAM_ID="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="wooosh-notary"

if [ -z "$TEAM_ID" ]; then
	cat >&2 <<'EOF'
DEVELOPMENT_TEAM ist nicht gesetzt.

  export DEVELOPMENT_TEAM=XXXXXXXXXX

Die Team-ID steht in Apple Developer unter "Membership details". Sie liegt
nicht im Repo, damit ein Fork nicht versehentlich damit signiert.
EOF
	exit 1
fi
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

DIST="$DIR/dist"
APP="$DIST/Wooosh.app"
ZIP="$DIST/Wooosh-$VERSION.zip"
DMG="$DIST/Wooosh-$VERSION.dmg"

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
	DEVELOPMENT_TEAM="$TEAM_ID" \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	-allowProvisioningUpdates >/dev/null

# Signiert wird beim Export, nicht beim Bauen: Xcode lehnt eine manuell
# gesetzte Developer-ID-Identität bei automatischer Signierung ab. Der Export
# signiert das Archiv mit "Developer ID Application" neu.
echo "==> Mit Developer ID exportieren"
# Die Team-ID kommt erst hier dazu, damit sie nirgends im Repo steht.
sed "s/__TEAM_ID__/$TEAM_ID/" ExportOptions.plist > .build/ExportOptions.plist
xcodebuild -exportArchive \
	-archivePath .build/Wooosh.xcarchive \
	-exportOptionsPlist .build/ExportOptions.plist \
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

# Das Laufwerk, das man beim Laden bekommt: die App und der Ordner, in den sie
# gehört. Mehr braucht es nicht, und mehr kann auch nichts kaputtgehen.
echo "==> Laufwerksabbild bauen"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Wooosh.app"
ln -s /Applications "$STAGE/Programme"
rm -f "$DMG"
hdiutil create -volname "Wooosh $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Ein Abbild, das selbst nicht signiert ist, hält Gatekeeper beim Öffnen an —
# auch wenn die App darin notarisiert ist. Also wird auch das Abbild signiert.
echo "==> Abbild signieren"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"
codesign -dv --verbose=2 "$DMG" 2>&1 | grep -E "^Authority=Developer ID|^TeamIdentifier"

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
	echo "Fertig (unnotarisiert): $DMG"
	shasum -a 256 "$DMG"
	exit 0
fi

echo "==> Notarisieren (dauert meist 1–5 Minuten)"
if ! xcrun notarytool submit "$DMG" \
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

# Das Ticket wird an App und Abbild geheftet, damit beide auch offline sofort
# starten. Danach neu packen — das alte ZIP enthält die App noch ohne Ticket.
echo "==> Ticket anheften"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper-Urteil"
spctl -a -vv "$APP" 2>&1 | tail -3
# Für ein Abbild urteilt Gatekeeper nach anderen Regeln als für eine App.
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tail -2
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo ""
echo "Fertig: $DMG"
shasum -a 256 "$DMG" "$ZIP"
