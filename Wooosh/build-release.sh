#!/bin/bash
#
# Builds Wooosh.app as a universal binary, signs it with Developer ID,
# notarises it and staples the ticket. The result lands in ./dist.
#
# Set this first — the team ID deliberately does not live in the repository:
#
#   export DEVELOPMENT_TEAM=XXXXXXXXXX
#
# (Apple Developer -> Membership details -> Team ID.)
#
# Once per machine, so that notarising runs without asking:
#
#   xcrun notarytool store-credentials "wooosh-notary" \
#       --apple-id YOUR@APPLE.ID --team-id $DEVELOPMENT_TEAM
#
# That asks for an app-specific password (appleid.apple.com -> Sign-In and
# Security -> App-Specific Passwords) and keeps it in the keychain. Without the
# profile the script still builds a signed app, but skips notarising and says
# so plainly.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

TEAM_ID="${DEVELOPMENT_TEAM:-}"
NOTARY_PROFILE="wooosh-notary"

if [ -z "$TEAM_ID" ]; then
	cat >&2 <<'EOF'
DEVELOPMENT_TEAM is not set.

  export DEVELOPMENT_TEAM=XXXXXXXXXX

The team ID is in Apple Developer under "Membership details". It is not kept in
the repository, so that a fork cannot sign with it by accident.
EOF
	exit 1
fi
VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')

DIST="$DIR/dist"
APP="$DIST/Wooosh.app"
ZIP="$DIST/Wooosh-$VERSION.zip"
DMG="$DIST/Wooosh-$VERSION.dmg"

echo "==> Wooosh $VERSION"

command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }

echo "==> Taking the icon from ../Icon"
rm -rf Resources/schild.icon
cp -R ../Icon/schild.icon Resources/

echo "==> Generating the project"
xcodegen generate >/dev/null

echo "==> Archiving (arm64 + x86_64)"
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

# Signing happens on export, not on build: with automatic signing, Xcode
# refuses a manually set Developer ID identity. The export re-signs the archive
# with "Developer ID Application".
echo "==> Exporting with Developer ID"
# The team ID is filled in only here, so that it appears nowhere in the repo.
sed "s/__TEAM_ID__/$TEAM_ID/" ExportOptions.plist > .build/ExportOptions.plist
xcodebuild -exportArchive \
	-archivePath .build/Wooosh.xcarchive \
	-exportOptionsPlist .build/ExportOptions.plist \
	-exportPath .build/export \
	-allowProvisioningUpdates >/dev/null

mkdir -p "$DIST"
cp -R .build/export/Wooosh.app "$APP"

echo "==> Checking"
lipo -info "$APP/Contents/MacOS/Wooosh"

# Into a variable, not through a pipe: `grep -q` leaves on its first match,
# codesign gets SIGPIPE, and `set -o pipefail` would take that for an error —
# the check would fail precisely when it holds.
SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
echo "$SIGNATURE" | grep -E "^Authority=Developer ID|^TeamIdentifier"

case "$SIGNATURE" in
	*"Authority=Developer ID Application"*) ;;
	*) echo "Not signed with Developer ID." >&2; exit 1 ;;
esac

# Notarising requires the hardened runtime. Without it the upload is accepted
# and turned down minutes later — stopping here is cheaper.
case "$SIGNATURE" in
	*"(runtime)"*) ;;
	*) echo "Hardened runtime missing — notarising would fail." >&2; exit 1 ;;
esac

echo "==> Packing"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# What a download hands you: the app, and the folder it belongs in. Nothing
# more is needed, and nothing more can go wrong.
echo "==> Building the disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Wooosh.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Wooosh $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# An image that is not signed itself is stopped by Gatekeeper when it opens —
# even when the app inside is notarised. So the image is signed as well.
echo "==> Signing the image"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"
codesign -dv --verbose=2 "$DMG" 2>&1 | grep -E "^Authority=Developer ID|^TeamIdentifier"

# --- Notarisierung -----------------------------------------------------------

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
	cat >&2 <<EOF

──────────────────────────────────────────────────────────────────────
  Notarising skipped — no credentials stored

  The app is signed with Developer ID, but it is not notarised.
  Gatekeeper keeps blocking it.

  Set it up once:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id YOUR@APPLE.ID --team-id $TEAM_ID

  Then run this script again.
──────────────────────────────────────────────────────────────────────

EOF
	echo "Done (not notarised): $DMG"
	shasum -a 256 "$DMG"
	exit 0
fi

echo "==> Notarising (usually 1 to 5 minutes)"
if ! xcrun notarytool submit "$DMG" \
	--keychain-profile "$NOTARY_PROFILE" \
	--wait 2>&1 | tee .build/notary.log; then
	echo "Notarising failed — see .build/notary.log" >&2
	exit 1
fi

if ! grep -q "status: Accepted" .build/notary.log; then
	echo "Notarising was not accepted. Details:" >&2
	SUBMISSION=$(grep -m1 "id:" .build/notary.log | awk '{print $2}')
	[ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" \
		--keychain-profile "$NOTARY_PROFILE" >&2
	exit 1
fi

# The ticket is stapled to app and image, so both start at once even offline.
# Then pack again — the old zip still holds the app without its ticket.
echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper's verdict"
spctl -a -vv "$APP" 2>&1 | tail -3
# For an image, Gatekeeper judges by other rules than for an app.
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | tail -2
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"

echo ""
echo "Done: $DMG"
shasum -a 256 "$DMG" "$ZIP"
