#!/bin/bash
# Builds RufusMac.app with nothing but the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="RufusMac.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.0"

echo ":: compilando ($TARGET)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
    -swift-version 5 \
    -target "$TARGET" \
    -O \
    -framework AppKit \
    -framework SwiftUI \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/RufusMac"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo ":: firmando (ad-hoc)"
codesign --force --sign - "$APP" 2>/dev/null || echo "   (sin firma, no es crítico)"

echo ":: listo -> $(pwd)/$APP"
echo "   ábrela con:  open $APP"
