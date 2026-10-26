#!/usr/bin/env bash
# Artsy for iPad and iPhone: bump the version, archive, sign and upload to App Store
# Connect, where the build goes to TestFlight once Apple has processed it.
#
# Usage:
#   scripts/release-ios.sh 0.9.0
#
# Assumes:
#   • An App Store Connect API key in ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID, with the
#     App Manager role or above, so xcodebuild can sign in the cloud: no distribution
#     certificate or profile on this Mac, Apple keeps them (-allowProvisioningUpdates)
#   • The app record for com.artsy.app exists in App Store Connect (made once, by hand)
#   • The first run registers the bundle identifier's iOS capabilities with the portal
#
# After this finishes:
#   1. App Store Connect → TestFlight shows the build after processing (minutes to an hour)
#   2. Add testers under Internal Testing; a build submitted for review goes through
#      App Store → the version's page
set -euo pipefail

VERSION="${1:?usage: release-ios.sh <version> (e.g. 0.9.0)}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH to the App Store Connect API key (.p8)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

PROJECT="Artsy.xcodeproj"
SCHEME="ArtsyiOS"
ARCHIVE="$(pwd)/build/ios/Artsy.xcarchive"
EXPORT="$(pwd)/build/ios/export"
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

say() { echo -e "\033[1;34m▶ $*\033[0m"; }

# 1. The version and a build number one up, in the iOS target's settings (the Mac's
#    live in its Info.plist and are the Mac release script's)
BUILD=$(( $(grep -m1 "CURRENT_PROJECT_VERSION = " "$PROJECT/project.pbxproj" | sed 's/[^0-9]//g') + 1 ))
say "Version $VERSION, build $BUILD"
sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PROJECT/project.pbxproj"

# 2. Archive for devices, signed in the cloud
say "Archiving"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" archive "${AUTH[@]}" 2>&1 | grep -E "error:|ARCHIVE" | tail -5
[ -d "$ARCHIVE" ] || { echo "no archive"; exit 1; }

# 3. Export for App Store Connect and upload in the same step
say "Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions-ios.plist \
  -exportPath "$EXPORT" "${AUTH[@]}" 2>&1 | grep -E "error:|EXPORT|Upload" | tail -5

say "Done: Artsy $VERSION ($BUILD) is on its way to TestFlight. Commit the version bump in $PROJECT."
