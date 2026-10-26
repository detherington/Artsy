# Artsy on the App Store

What the App Store listing for iPad and iPhone says, and the steps around it that are
done by hand in App Store Connect. The build itself comes from `scripts/release-ios.sh`.

## Before the first upload, once

1. **The app record.** App Store Connect → My Apps → + → New App: iOS, name "Artsy",
   primary language English, bundle ID `com.artsy.app` (registered on the portal on
   2026-10-26 as a universal App ID, through the App Store Connect API; an archive's
   automatic provisioning only takes a wildcard profile and registers nothing), SKU
   `artsy-ios`. Full access.
2. **The privacy policy URL.** The listing needs one. `docs/privacy-policy.md` is the
   text; it needs a home on the web, which the repository's GitHub Pages can be
   (Settings → Pages, from `docs/`), giving
   `https://detherington.github.io/Artsy/privacy-policy`.
3. **The API key's role.** The App Store Connect API key in the environment must have
   the App Manager role (or above) for cloud signing to make the distribution
   certificate and profile on its own.

## The listing

- **Name:** Artsy
- **Subtitle:** A sketchbook that paints like the real thing
- **Category:** Graphics & Design (secondary: Productivity)
- **Age rating:** 4+ (no user-generated content shared, no web access beyond the
  optional services)
- **Price:** free, for the TestFlight period
- **Description:**

  > Artsy is a sketchbook and a paint box. Its pencils come in grades from 2H to 6B and
  > answer to how you hold the Pencil and how fast you move it; its watercolour runs
  > with the lean of the paper; its oils and acrylics keep their bristle marks and
  > their thickness. Every brush is a living mark, not a stamp.
  >
  > Draw with the Apple Pencil, with its pressure and tilt, or with a finger. Layers
  > with blend modes, undo without limit, symmetry and guides, a colour panel built for
  > a pen. Documents live in Files and iCloud Drive, in a format the Mac app shares.
  >
  > Bring your own keys for AI generation (OpenAI or Google) and stock photos
  > (Unsplash), or ignore them: nothing leaves your device unless you ask.
  >
  > Made for iPad Pro and the Apple Pencil, and for iPhone.

- **Keywords:** sketch,paint,drawing,pencil,watercolor,oil,brush,canvas,art,procreate,layers,ipad
- **Support URL:** https://github.com/detherington/Artsy
- **Marketing URL:** none yet
- **Privacy policy URL:** see above
- **App privacy (the questionnaire):** Data not collected. The optional AI and stock
  services are third parties the user sends to under their own keys; the questionnaire
  asks about data the developer collects, which is none.
- **Export compliance:** the app declares `ITSAppUsesNonExemptEncryption = false`
  (HTTPS only), so no compliance questions per build.

## Screenshots

Required at least for the 13-inch iPad (2064×2752 or 2752×2064) and the 6.9-inch iPhone
(1320×2868 or 2868×1320); the Duo's sizes once App Store Connect lists them. The
simulator's screenshots are the right pixel sizes: the iPad Pro 13-inch (M5) in
landscape with a painting on the canvas and the chrome up; the brush panel open; the
colour panel; Layers. Three to five of each.

## TestFlight

1. Run `scripts/release-ios.sh <version>`; the build appears under TestFlight once
   processed. The first build of a version needs the compliance answer only if the
   plist key above were missing.
2. Internal Testing: a group with the Apple ID of each tester; up to 100 internal
   testers need no review. The pen sessions go here.
3. Test notes for the build: what to try (the pencil grades, pressure from speed with
   the USB-C Pencil, tilt, documents in iCloud Drive) and where the diagnostics log is.

## Review

- **Review notes:** "The AI and stock image features need the reviewer's own API keys
  (OpenAI, Google or Unsplash) entered in Settings; the app works fully without them."
- **Demo account:** none, there are no accounts.
- **Sign-in:** none.
