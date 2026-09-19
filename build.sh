#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="SDCardImporter"
CONFIG="Release"
APP_NAME="SD Card Importer"
DERIVED="$ROOT/.build/xcode"
BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
INSTALL_DIR="/Applications/$APP_NAME.app"
EXT_ID="com.xetera.sdcardimporter.badges"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

xcodebuild \
    -project "$ROOT/SDCardImporter.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build 2>&1 | tail -20

echo
echo "=== signature ==="
codesign -dvv "$BUILT" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/  /'
codesign --verify --deep --verbose=2 "$BUILT" 2>&1 | sed 's/^/  /'

echo
echo "built: $BUILT"

if [[ "${1:-}" == "--install" ]]; then
    pkill -f "$INSTALL_DIR/Contents/MacOS/" 2>/dev/null || true

    if [[ -d "$INSTALL_DIR" ]]; then
        pluginkit -e ignore -i "$EXT_ID" >/dev/null 2>&1 || true
        pluginkit -r "$INSTALL_DIR/Contents/PlugIns/BadgeExtension.appex" >/dev/null 2>&1 || true
    fi
    pkill -f "BadgeExtension.appex/Contents/MacOS/" 2>/dev/null || true
    sleep 1

    rm -rf "$INSTALL_DIR"
    cp -R "$BUILT" "$INSTALL_DIR"

    "$LSREG" -f "$INSTALL_DIR" >/dev/null 2>&1 || true
    pluginkit -a "$INSTALL_DIR/Contents/PlugIns/BadgeExtension.appex" >/dev/null 2>&1 || true
    pluginkit -e use -i "$EXT_ID" >/dev/null 2>&1 || true

    open "$INSTALL_DIR"
    sleep 2

    echo "installed: $INSTALL_DIR"
    echo "--- extension registration ---"
    pluginkit -m -v -p com.apple.FinderSync 2>&1 | sed 's/^/  /'
    echo
    echo "enable 'Launch at login' from the menu bar icon"
fi
