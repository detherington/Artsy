#!/usr/bin/env bash
# Artsy release pipeline — builds + signs + notarizes + creates DMG + produces appcast entry.
#
# Usage:
#   scripts/release.sh 0.3.0
#
# Assumes:
#   • Developer ID Application cert is in the login keychain
#   • Notary profile "notary" is stored via `xcrun notarytool store-credentials "notary"`
#   • Sparkle signing key is in the Keychain (generated via sparkle-tools/bin/generate_keys)
#
# After this finishes you still need to:
#   1. Create a GitHub Release for tag v$VERSION and upload the DMG
#   2. Commit the updated appcast.xml and push to main
set -euo pipefail

VERSION="${1:?usage: release.sh <version> (e.g. 0.3.0)}"

# Bootstrap Sparkle CLI tools if missing (sign_update, generate_keys, etc.)
if [ ! -x ./sparkle-tools/bin/sign_update ]; then
  echo "▶ Fetching Sparkle CLI tools..."
  mkdir -p sparkle-tools
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz" | tar -xJ -C sparkle-tools
fi
TEAM_ID="8B29CDK832"
IDENT="Developer ID Application: Darrell Etherington ($TEAM_ID)"
ENTS="Artsy/App/Artsy-Release.entitlements"
REPO_OWNER="detherington"
REPO_NAME="Artsy"
DMG_NAME="Artsy-${VERSION}.dmg"
DMG_PATH="$(pwd)/${DMG_NAME}"
APP_PATH="build/Build/Products/Release/Artsy.app"
BG_SRC_DIR="/tmp/artsy-dmg"
WORKDIR="$(pwd)/dmg_work"

say() { echo -e "\033[1;34m▶ $*\033[0m"; }

# 1. Bump version in Info.plist
say "Bumping version to $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Artsy/App/Info.plist
BUILD_NUM=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Artsy/App/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Artsy/App/Info.plist

# 2. Clean build Release
say "Building Release"
rm -rf build
xcodebuild -project Artsy.xcodeproj -scheme Artsy -configuration Release -derivedDataPath build clean build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO 2>&1 | grep -E "(error:|BUILD)" | tail -3

# 3. Sign Sparkle internals + framework + app with hardened runtime
say "Codesigning (hardened runtime + release entitlements)"
SP="$APP_PATH/Contents/Frameworks/Sparkle.framework"
find "$SP/Versions/B/" -type f \( -name "*.dylib" -o -perm +111 \) -print0 | while IFS= read -r -d '' f; do
  codesign --force --options runtime --timestamp --sign "$IDENT" "$f" >/dev/null
done
for xpc in "$SP/XPCServices"/*.xpc; do
  [ -d "$xpc" ] && codesign --force --options runtime --timestamp --sign "$IDENT" "$xpc" >/dev/null
done
[ -d "$SP/Updater.app" ] && codesign --force --options runtime --timestamp --sign "$IDENT" "$SP/Updater.app" >/dev/null
[ -f "$SP/Versions/B/Autoupdate" ] && codesign --force --options runtime --timestamp --sign "$IDENT" "$SP/Versions/B/Autoupdate" >/dev/null
codesign --force --options runtime --timestamp --sign "$IDENT" "$SP" >/dev/null
codesign --force --options runtime --timestamp --entitlements "$ENTS" --sign "$IDENT" "$APP_PATH" >/dev/null
codesign --verify --strict --deep "$APP_PATH"

# 4. Build DMG
say "Building DMG"
rm -rf "$WORKDIR" "$DMG_PATH"
mkdir -p "$WORKDIR/dmg_contents/.background"
cp -R "$APP_PATH" "$WORKDIR/dmg_contents/Artsy.app"
ln -s /Applications "$WORKDIR/dmg_contents/Applications"
[ -f "$BG_SRC_DIR/dmg_background_final.png" ] && cp "$BG_SRC_DIR/dmg_background_final.png" "$WORKDIR/dmg_contents/.background/background.png"
[ -f "$BG_SRC_DIR/dmg_background_final@2x.png" ] && cp "$BG_SRC_DIR/dmg_background_final@2x.png" "$WORKDIR/dmg_contents/.background/background@2x.png"

hdiutil detach /Volumes/Artsy 2>/dev/null || true
hdiutil create -volname "Artsy" -srcfolder "$WORKDIR/dmg_contents" -ov -format UDRW "$WORKDIR/temp.dmg" >/dev/null
hdiutil attach "$WORKDIR/temp.dmg" -readwrite -noverify >/dev/null

osascript <<APPLESCRIPT >/dev/null || true
tell application "Finder"
    tell disk "Artsy"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, 860, 600}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "Artsy.app" of container window to {160, 180}
        set position of item "Applications" of container window to {500, 180}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach /Volumes/Artsy >/dev/null
sleep 1
hdiutil convert "$WORKDIR/temp.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
codesign --sign "$IDENT" --timestamp "$DMG_PATH"

# 5. Notarize + staple
say "Submitting to Apple notary service (can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "notary" --wait
say "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
spctl -a -t open --context context:primary-signature -v "$DMG_PATH"

# 6. Sign DMG for Sparkle (EdDSA signature + file length)
say "Generating Sparkle signature"
SIG_OUTPUT=$(./sparkle-tools/bin/sign_update "$DMG_PATH")
# sign_update output format: sparkle:edSignature="XXX" length="YYY"
EDSIG=$(echo "$SIG_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | cut -d'"' -f2)
DMG_LENGTH=$(echo "$SIG_OUTPUT" | grep -oE 'length="[^"]+"' | cut -d'"' -f2)
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DMG_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/${DMG_NAME}"

# 7. Update appcast.xml — append new <item> before </channel>
say "Updating appcast.xml"
if [ ! -f appcast.xml ]; then
  cat > appcast.xml <<APPCAST_HEAD
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel>
    <title>Artsy</title>
    <link>https://github.com/${REPO_OWNER}/${REPO_NAME}</link>
    <description>Updates for Artsy</description>
    <language>en</language>
</channel>
</rss>
APPCAST_HEAD
fi

ITEM="    <item>
        <title>Version ${VERSION}</title>
        <pubDate>${PUB_DATE}</pubDate>
        <sparkle:version>${BUILD_NUM}</sparkle:version>
        <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure url=\"${DMG_URL}\" length=\"${DMG_LENGTH}\" type=\"application/octet-stream\" sparkle:edSignature=\"${EDSIG}\"/>
    </item>
</channel>"

# Replace the closing </channel> with the new item + </channel>
python3 - <<PY
import re
with open('appcast.xml', 'r') as f:
    content = f.read()
item = '''$ITEM'''
content = content.replace('</channel>', item, 1)
with open('appcast.xml', 'w') as f:
    f.write(content)
PY

say "Done."
echo ""
echo "Artifacts:"
echo "  • $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "  • appcast.xml  (updated)"
echo ""
echo "Next steps:"
echo "  1. git add appcast.xml Artsy/App/Info.plist && git commit -m \"Release v${VERSION}\" && git push"
echo "  2. gh release create v${VERSION} \"$DMG_PATH\" --title \"v${VERSION}\" --notes \"Release notes here\""
echo "     (or upload via github.com/${REPO_OWNER}/${REPO_NAME}/releases/new, tag v${VERSION})"
