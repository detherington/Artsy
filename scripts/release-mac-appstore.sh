#!/usr/bin/env bash
# Artsy for the Mac App Store: bump the version, archive the sandboxed AppStore
# configuration (no Sparkle), sign in the cloud and upload to App Store Connect, where
# the build goes to TestFlight for Mac once Apple has processed it.
#
# The Developer ID build with Sparkle is scripts/release.sh; both share the Mac's
# Info.plist, so their build numbers are one sequence.
#
# Usage:
#   scripts/release-mac-appstore.sh 0.9.0
#
# Assumes:
#   • An App Store Connect API key in ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID, with the
#     App Manager role or above, so xcodebuild can sign in the cloud (-allowProvisioningUpdates):
#     the Mac App Distribution and Mac Installer Distribution certificates stay with Apple
#   • The app record for com.artsy.app in App Store Connect has the macOS platform added
#     (once, by hand: the app's page → the platform list's plus button → macOS); the Mac
#     and iOS apps are then one universal purchase
#
# After this finishes:
#   1. App Store Connect → TestFlight → macOS shows the build after processing
#   2. The store version's page takes the build, Mac screenshots (1280×800 or larger,
#      16:10) and the listing, then goes to review
set -euo pipefail

VERSION="${1:?usage: release-mac-appstore.sh <version> (e.g. 0.9.0)}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the App Store Connect API key (.p8)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

PROJECT="Artsy.xcodeproj"
SCHEME="Artsy App Store"
PLIST="Artsy/App/Info.plist"
ARCHIVE="$(pwd)/build/mac-appstore/Artsy.xcarchive"
EXPORT="$(pwd)/build/mac-appstore/export"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

say() { echo -e "\033[1;34m▶ $*\033[0m"; }

# 1. The version and a build number one up, in the Mac's Info.plist (as release.sh does)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
say "Version $VERSION, build $BUILD"

# 2. Archive the AppStore configuration, signed in the cloud. Apple silicon only, as the
#    Developer ID build is: the engine's Float16 pixels have no x86_64, and the engine
#    package takes its architectures from the command line, not the project
say "Archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration AppStore -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" archive ARCHS=arm64 "${AUTH[@]}" 2>&1 | grep -E "error:|ARCHIVE" | tail -5
[ -d "$ARCHIVE" ] || { echo "no archive"; exit 1; }

# 3. Nothing of Sparkle may be in the archive: the store refuses self-updating apps
APP="$ARCHIVE/Products/Applications/Artsy.app"
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] || /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "Sparkle is in the archive; the AppStore configuration should exclude it"; exit 1
fi
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" || { echo "the archive is not sandboxed"; exit 1; }

# 4. Export for App Store Connect and upload in the same step
say "Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions-mac.plist \
  -exportPath "$EXPORT" "${AUTH[@]}" 2>&1 | grep -E "error:|EXPORT|Upload" | tail -5

say "Done: Artsy $VERSION ($BUILD) for Mac is on its way to TestFlight. Commit the version bump in $PLIST."
