#!/bin/bash
# Compila e installa Mediateca.app (SwiftUI + AVKit, nessuna dipendenza esterna).
# La build avviene fuori da iCloud Drive: gli attributi estesi del provider
# impediscono la firma del bundle.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$HOME/Library/Caches/MediatecaBuild"
APP="$WORK/Mediateca.app"
DEST="${1:-$HOME/Applications}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "▸ pulizia"
rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ icona"
swift make_icon.swift "$WORK/Mediateca.iconset" >/dev/null
iconutil -c icns "$WORK/Mediateca.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK/Mediateca.iconset"

echo "▸ Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "▸ compilazione Swift"
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -O -whole-module-optimization \
  -parse-as-library \
  -framework AppKit -framework AVFoundation -framework AVKit \
  -o "$APP/Contents/MacOS/Mediateca" \
  Sources/*.swift

echo "▸ firma (ad-hoc)"
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "▸ installazione in $DEST"
mkdir -p "$DEST"
rm -rf "$DEST/Mediateca.app"
ditto "$APP" "$DEST/Mediateca.app"

echo "▸ registrazione presso il Finder"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST/Mediateca.app" 2>/dev/null || true

echo "✓ pronto: $DEST/Mediateca.app"
