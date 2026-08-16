#!/bin/bash
#
# Baut Wooosh.app als Universal Binary und packt sie als ZIP für ein
# GitHub-Release. Ergebnis liegt in ./dist.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DIST="$DIR/dist"
APP="$DIST/Wooosh.app"

echo "==> Wooosh $VERSION"

if ! command -v xcodegen >/dev/null; then
	echo "xcodegen fehlt: brew install xcodegen" >&2
	exit 1
fi

echo "==> Icon aus ../Icon übernehmen"
rm -rf Resources/schild.icon
cp -R ../Icon/schild.icon Resources/

echo "==> Projekt erzeugen"
xcodegen generate >/dev/null

echo "==> Bauen (arm64 + x86_64)"
rm -rf "$DIST" .build
xcodebuild \
	-project Wooosh.xcodeproj \
	-scheme Wooosh \
	-configuration Release \
	-derivedDataPath .build \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	build >/dev/null

mkdir -p "$DIST"
cp -R .build/Build/Products/Release/Wooosh.app "$APP"

echo "==> Architekturen"
lipo -info "$APP/Contents/MacOS/Wooosh"

# Ad-hoc-Signatur. Ohne "Developer ID Application"-Zertifikat ist keine
# Notarisierung möglich; siehe README, Abschnitt Verteilung.
echo "==> Ad hoc signieren"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

# ditto statt zip: erhält Ressourcen-Forks und Signatur unbeschädigt.
echo "==> Packen"
ZIP="$DIST/Wooosh-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ""
echo "Fertig: $ZIP"
shasum -a 256 "$ZIP"
