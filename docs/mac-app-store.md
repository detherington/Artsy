# Artsy on the Mac App Store

The Mac app has two builds of one bundle identifier. The Developer ID build is the one
that has always shipped: `scripts/release.sh`, the Release configuration, unsandboxed,
Sparkle for updates, a notarized DMG and the appcast. The App Store build is new
(2026-10-26): the AppStore configuration, sandboxed, no Sparkle, uploaded by
`scripts/release-mac-appstore.sh` and updated by the store. Because the bundle ID is
`com.artsy.app` on the Mac as on iPad and iPhone, the Mac app is the macOS platform of
the one App Store record: one listing, one price, one purchase for both. The two Mac
builds cannot sit on one Mac cleanly, since Launch Services sees one app.

## The AppStore configuration

A third build configuration beside Debug and Release, a copy of Release with:

- **At the project:** `ARCHS = arm64`. The app is Apple silicon only, as the Developer
  ID build already is: the engine's pixels are `Float16`, which Swift has no x86_64 for.
  The engine package takes its architectures from the build command rather than the
  project, so the release script also passes `ARCHS=arm64`; archiving from Xcode wants
  the "Any Mac (Apple Silicon)" destination.
- **On the Mac app:** `Artsy/App/Artsy-AppStore.entitlements` (the sandbox, user-selected
  files read and write, outgoing connections); automatic signing with the team;
  `EXCLUDED_SOURCE_FILE_NAMES = Sparkle.framework`, which keeps the framework out of
  linking and embedding; `SWIFT_ACTIVE_COMPILATION_CONDITIONS = APP_STORE`, under which
  `AppDelegate` compiles out the Sparkle import, the updater and "Check for Updates…".
- **A script phase, last on the Mac app,** "Strip Sparkle keys for the App Store": under
  the AppStore configuration it deletes the four `SU…` keys from the built Info.plist,
  so nothing in the bundle names an update feed. The other configurations are untouched.
- **Two resources in the Mac app:** `Artsy/Resources/PrivacyInfo.xcprivacy` (the same
  three required-reason APIs as the iOS manifest) and
  `Artsy/Resources/container-migration.plist` (below).
- **Two shared schemes:** "Artsy App Store", which runs, profiles and archives the
  AppStore configuration, and "Artsy", written out as Xcode had been generating it,
  because a target with a shared scheme gets no generated one.

The Mac Info.plist also gained `LSApplicationCategoryType` (Graphics & Design, which
the store requires) and `ITSAppUsesNonExemptEncryption = false` (no compliance question
on upload). Both builds carry them; neither minds.

## The sandbox

Nothing in the Mac code needs to be outside it. Every open, save, import and export goes
through the system panels, dropped and double-clicked files arrive with access, there is
no Open Recent and no remembered document path, tablet input is plain `NSEvent`, pen
scrolling sends its synthesized events to the app itself, and OpenAI, Gemini and Unsplash
are ordinary HTTPS calls. Brushes, textures, stroke recordings, the diagnostics log and
the preferences land in the container, where Application Support and Preferences resolve.

`container-migration.plist` moves `~/Library/Application Support/Artsy` and
`~/Library/Preferences/com.artsy.app.plist` into the container the first time the
sandboxed build runs, so a Developer ID user who switches keeps their brushes. It is a
move, not a copy (Apple offers no copy), so the Developer ID build loses them; migration
happens only when the container is first created, and deleting
`~/Library/Containers/com.artsy.app` makes it happen again.

Two things look different sandboxed. Help ▸ Show Brush Folder and Show Diagnostics Folder
reveal paths inside the container. And the store build is signed by a different
certificate from the Developer ID build, so the login keychain may ask once before it
hands over API keys the other build stored, or the user enters them again in Settings.

## Shipping

Once, by hand, in App Store Connect: open the app record and add the macOS platform
(the platform list's plus button). The Mac listing wants its own screenshots at 16:10,
1280×800, 1440×900, 2560×1600 or 2880×1800, and says "Requires a Mac with Apple silicon".

Then `scripts/release-mac-appstore.sh <version>`: it bumps the version and build number
in `Artsy/App/Info.plist` (shared with `release.sh`, so the two Mac builds are one
sequence), archives the AppStore configuration for arm64 with cloud signing through the
App Store Connect key in the environment, refuses an archive that still has Sparkle or
lacks the sandbox entitlement, and exports with upload. TestFlight → macOS shows the
build after processing. The Mac's version string is its own within the record; it need
not match iOS's.

## Checked on 2026-10-26

- The Developer ID build (Debug, build-for-testing) with the Mac suite: 286 tests, 3
  skipped, 0 failures. The Release build still embeds Sparkle and keeps its keys. It
  needed `ARCHS=arm64` too: since the engine became a package (2026-10-25, after the
  0.8.14 DMG), a Release build without it compiled the engine for x86_64 and failed on
  `Float16`, so `release.sh` now passes it, and the DMG stays Apple silicon only as it was.
- The AppStore product, built locally with ad hoc signing: no `Sparkle.framework`, no
  Sparkle in the link list, no `SU…` keys, the category set, the sandbox and file and
  network entitlements, arm64 only, both resources present, the engine compiled with
  `-O`, no "Check for Updates" string, the script phase run.
- The sandboxed build run once on this Mac, with the home Library data backed up first:
  it launched, macOS made the container and the migration moved the brush library,
  Diagnostics, Stroke Recordings and the preferences plist (19 keys) into it; a copy of
  a document opened through Launch Services and composited; the sandbox log showed one
  denial, `iokit-open-user-client AppleNVMeEANUC`, which the GPU driver provokes in every
  sandboxed Metal app and which is harmless, and no file or network denial; no crash.
  Afterwards the data went back where it was. The container's contents came out, but
  neither Terminal nor a scripted Finder may delete `~/Library/Containers/com.artsy.app`
  itself, so its metadata file remains on this Mac; delete that folder in Finder by hand
  before the store build first runs here, or the migration will not run again.
- The script's first run, the same day, after the macOS platform was added to the record
  by hand (App Store Connect gave it version 1.0 without asking, as it had iOS): Artsy
  0.9.0 build 28 archived, signed in the cloud, its Sparkle and sandbox checks passed, and
  uploaded as a package in one step. Cloud signing made the Mac distribution and installer
  certificates on its own.
- Not checked, because it needs hands: the open and save panels, exports and imports,
  drag and drop, the AI and Unsplash panels, and the keychain prompt under the sandbox;
  TestFlight on another Mac.
