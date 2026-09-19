#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEME="SDCardImporter"
APP_NAME="SD Card Importer"
BUNDLE_ID="com.xetera.sdcardimporter"
TEAM_ID="FLDWQ2AC5Y"
REPO="Xetera/sdcard-importer"
NOTARY_PROFILE="sdcard-notary"
SPARKLE_VERSION="2.10.0"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: ./release.sh <version>   e.g. ./release.sh 1.1.0" >&2
    exit 1
fi

BUILD_NUMBER="$(date +%Y%m%d%H%M)"
WORK="$ROOT/.build/release"
ARCHIVE="$WORK/$SCHEME.xcarchive"
EXPORT_DIR="$WORK/export"
DMG_DIR="$WORK/dmg"
ARCHIVES="$WORK/archives"
DMG="$ARCHIVES/SDCardImporter-$VERSION.dmg"
APPCAST="$ARCHIVES/appcast.xml"
TOOLS="$ROOT/.build/sparkle-tools"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require xcodebuild
require xcrun
require gh
require hdiutil

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "no 'Developer ID Application' certificate in keychain." >&2
    echo "create one: Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" >&2
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notary profile '$NOTARY_PROFILE' not found. create it with:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id $TEAM_ID --password <app-specific-password>" >&2
    exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "working tree is dirty; commit or stash before releasing." >&2
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$DMG_DIR" "$ARCHIVES"

echo "==> fetching sparkle tools"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
    mkdir -p "$TOOLS"
    curl -sL -o "$WORK/sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    tar -xf "$WORK/sparkle.tar.xz" -C "$TOOLS"
fi

echo "==> archiving $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
    -project "$ROOT/SDCardImporter.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
    | grep -E "error:|ARCHIVE" || true

[[ -d "$ARCHIVE" ]] || { echo "archive failed" >&2; exit 1; }

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "==> exporting"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$WORK/ExportOptions.plist" \
    | grep -E "error:|EXPORT" || true

APP="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "export failed" >&2; exit 1; }

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" | sed 's/^/  /'

echo "==> building dmg"
cp -R "$APP" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
        break
    fi
    if [[ $attempt -eq 3 ]]; then
        echo "hdiutil create failed after 3 attempts" >&2
        exit 1
    fi
    echo "  hdiutil busy, retrying ($attempt/3)"
    sleep 3
done
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

echo "==> notarizing (this can take a few minutes)"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "notarization failed. for details run:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
fi

echo "==> stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> generating appcast"
curl -sfL -o "$APPCAST" \
    "https://github.com/$REPO/releases/latest/download/appcast.xml" || rm -f "$APPCAST"

"$TOOLS/bin/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    -o "$APPCAST" \
    "$ARCHIVES"

echo "==> publishing release v$VERSION"
git -C "$ROOT" tag -a "v$VERSION" -m "v$VERSION"
git -C "$ROOT" push origin "v$VERSION"

gh release create "v$VERSION" \
    --repo "$REPO" \
    --title "v$VERSION" \
    --generate-notes \
    "$DMG" \
    "$APPCAST"

echo
echo "released v$VERSION"
echo "  dmg:     $DMG"
echo "  appcast: https://github.com/$REPO/releases/latest/download/appcast.xml"
