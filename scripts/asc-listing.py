#!/usr/bin/env python3
"""Writes Artsy's App Store listing into App Store Connect, through the API: what
docs/app-store-listing.md says, for both platforms of the one record. Safe to run again;
each step writes the same values. What the API cannot set, the App Privacy answers and
the review contact's phone number, stays a hand step, and the script says so.

    scripts/asc-listing.py            write everything
    scripts/asc-listing.py --show     only print what is there
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc

SITE = "https://artsydraw.com"
SUPPORT = f"{SITE}/support"
PRIVACY = f"{SITE}/privacy"
EMAIL = "support@artsydraw.com"
COPYRIGHT = "2026 Darrell Etherington"
SUBTITLE = "Paints like the real thing"
KEYWORDS = {
    "IOS": "sketch,paint,drawing,pencil,watercolor,oil,brush,canvas,art,sketchbook,layers,ipad",
    "MAC_OS": "sketch,paint,drawing,pencil,watercolor,oil,brush,canvas,art,sketchbook,layers,mac",
}
DESCRIPTION = {
    "IOS": """Artsy is a sketchbook and a paint box. Its pencils come in grades from 2H to 6B and answer to how you hold the Pencil and how fast you move it; its watercolour runs with the lean of the paper; its oils and acrylics keep their bristle marks and their thickness. Every brush is a living mark, not a stamp.

Draw with the Apple Pencil, with its pressure and tilt, or with a finger. Layers with blend modes, undo without limit, symmetry and guides, a colour panel built for a pen, and a time-lapse of every painting. Documents live in Files and iCloud Drive, in a format the Mac app shares.

Bring your own keys for AI generation (OpenAI or Google) and stock photos (Unsplash), or ignore them: nothing leaves your device unless you ask.

Made for iPad Pro and the Apple Pencil, and for iPhone. One purchase covers the Mac too.""",
    "MAC_OS": """Artsy is a sketchbook and a paint box. Its pencils come in grades from 2H to 6B and answer to the pressure and tilt of a tablet pen or the speed of the mouse; its watercolour runs with the lean of the paper; its oils and acrylics keep their bristle marks and their thickness. Every brush is a living mark, not a stamp.

Draw with a tablet pen, with its pressure and tilt, or with the mouse and trackpad. Layers with blend modes, undo without limit, symmetry and guides, a colour panel built for a pen, keyboard shortcuts for everything, and a time-lapse of every painting. Documents are ordinary files, in a format the iPad app shares through iCloud Drive.

Bring your own keys for AI generation (OpenAI or Google) and stock photos (Unsplash), or ignore them: nothing leaves your Mac unless you ask.

Requires a Mac with Apple silicon. One purchase covers iPad and iPhone too.""",
}
PROMOTIONAL = "Pencils in every grade, watercolour that runs, oils that keep their bristle marks."
REVIEW_NOTES = ("The AI and stock image features need the reviewer's own API keys (OpenAI, Google or Unsplash), "
                "entered in Settings; the app works fully without them. There are no accounts and no sign-in. "
                "Documents are files: the Mac saves them where you choose, iPad and iPhone keep them in Files.")
CATEGORIES = ("GRAPHICS_AND_DESIGN", "PRODUCTIVITY")
AGE_RATING = {
    # The questionnaire, every answer the lowest: a sketchbook with none of it
    "alcoholTobaccoOrDrugUseOrReferences": "NONE", "contests": "NONE", "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE", "horrorOrFearThemes": "NONE", "matureOrSuggestiveThemes": "NONE",
    "medicalOrTreatmentInformation": "NONE", "profanityOrCrudeHumor": "NONE",
    "sexualContentGraphicAndNudity": "NONE", "sexualContentOrNudity": "NONE",
    "violenceCartoonOrFantasy": "NONE", "violenceRealistic": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "gambling": False, "lootBox": False, "unrestrictedWebAccess": False, "messagingAndChat": False,
    "userGeneratedContent": False, "advertising": False, "healthOrWellnessTopics": False,
    "parentalControls": False, "socialMedia": False, "socialMediaAgeRestricted": False, "ageAssurance": False,
    "kidsAgeBand": None, "ageRatingOverrideV2": "NONE",
}

failures = []


def step(name, work):
    try:
        result = work()
        print(f"✓ {name}" + (f": {result}" if result else ""))
    except SystemExit as error:
        failures.append(name)
        print(f"✗ {name}\n  {str(error).strip()[:600]}")


def rel(kind, id):
    return {"data": {"type": kind, "id": id}}


def main(show_only):
    app = asc.app()
    app_id = app["id"]
    print(f"{app['attributes']['name']} ({app_id})")

    info = asc.get(f"/v1/apps/{app_id}/appInfos")["data"][0]
    info_id = info["id"]
    info_loc = next(l for l in asc.get(f"/v1/appInfos/{info_id}/appInfoLocalizations")["data"] if l["attributes"]["locale"] == "en-US")
    versions = {v["attributes"]["platform"]: v for v in asc.get(f"/v1/apps/{app_id}/appStoreVersions")["data"]}

    if show_only:
        print("subtitle:", info_loc["attributes"].get("subtitle"), "| privacy:", info_loc["attributes"].get("privacyPolicyUrl"))
        for platform, v in versions.items():
            loc = asc.get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"][0]["attributes"]
            build = asc.get(f"/v1/appStoreVersions/{v['id']}/build", **{"fields[builds]": "version"}).get("data") or {}
            print(f"{platform} {v['attributes']['versionString']} {v['attributes'].get('appVersionState')} build {build.get('attributes', {}).get('version')}"
                  f"\n  support {loc.get('supportUrl')} | marketing {loc.get('marketingUrl')} | keywords {loc.get('keywords')}"
                  f"\n  description {(loc.get('description') or '')[:60]!r}")
        return

    # The record
    step("content rights: no third-party content",
         lambda: asc.patch(f"/v1/apps/{app_id}", {"data": {"type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}) and "")
    step("categories: Graphics & Design, Productivity",
         lambda: asc.patch(f"/v1/appInfos/{info_id}", {"data": {"type": "appInfos", "id": info_id, "relationships": {
             "primaryCategory": rel("appCategories", CATEGORIES[0]), "secondaryCategory": rel("appCategories", CATEGORIES[1])}}}) and "")
    step("subtitle and privacy policy URL",
         lambda: asc.patch(f"/v1/appInfoLocalizations/{info_loc['id']}", {"data": {"type": "appInfoLocalizations", "id": info_loc["id"],
               "attributes": {"subtitle": SUBTITLE, "privacyPolicyUrl": PRIVACY}}}) and "")
    age = asc.get(f"/v1/appInfos/{info_id}/ageRatingDeclaration")["data"]
    step("age rating: 4+, every answer none",
         lambda: asc.patch(f"/v1/ageRatingDeclarations/{age['id']}", {"data": {"type": "ageRatingDeclarations", "id": age["id"], "attributes": AGE_RATING}}) and "")

    # Each platform's version
    for platform, v in versions.items():
        vid = v["id"]
        locs = asc.get(f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]
        loc = next(l for l in locs if l["attributes"]["locale"] == "en-US")
        step(f"{platform}: description, keywords, URLs",
             lambda: asc.patch(f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {
                 "description": DESCRIPTION[platform], "keywords": KEYWORDS[platform], "supportUrl": SUPPORT, "marketingUrl": SITE,
                 "promotionalText": PROMOTIONAL}}}) and "")
        step(f"{platform}: copyright",
             lambda: asc.patch(f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {"copyright": COPYRIGHT}}}) and "")
        builds = asc.get("/v1/builds", **{"filter[app]": app_id, "filter[preReleaseVersion.platform]": platform, "filter[processingState]": "VALID",
                                        "sort": "-uploadedDate", "limit": 1, "fields[builds]": "version"})["data"]
        if builds:
            step(f"{platform}: the build, {builds[0]['attributes']['version']}",
                 lambda: asc.patch(f"/v1/appStoreVersions/{vid}/relationships/build", rel("builds", builds[0]["id"])) and "")
        detail = asc.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail").get("data")
        attributes = {"contactFirstName": "Darrell", "contactLastName": "Etherington", "contactEmail": EMAIL,
                      "contactPhone": os.environ.get("ARTSY_REVIEW_PHONE", ""), "demoAccountRequired": False, "notes": REVIEW_NOTES}
        if not attributes["contactPhone"] and not detail:
            print(f"– {platform}: review contact and notes wait for a phone number (ARTSY_REVIEW_PHONE in the environment; App Store Connect requires one)")
            continue
        if not attributes["contactPhone"]:
            del attributes["contactPhone"]
        if detail:
            step(f"{platform}: review contact and notes",
                 lambda: asc.patch(f"/v1/appStoreReviewDetails/{detail['id']}", {"data": {"type": "appStoreReviewDetails", "id": detail["id"], "attributes": attributes}}) and "")
        else:
            step(f"{platform}: review contact and notes",
                 lambda: asc.post("/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": attributes,
                       "relationships": {"appStoreVersion": rel("appStoreVersions", vid)}}}) and "")

    # Free, everywhere
    def price():
        try:
            asc.get(f"/v1/apps/{app_id}/appPriceSchedule")
            return "already set"
        except SystemExit:
            pass
        free = asc.get(f"/v1/apps/{app_id}/appPricePoints", **{"filter[territory]": "USA", "limit": 1})["data"][0]
        assert free["attributes"]["customerPrice"] == "0.0", free["attributes"]
        schedule = {"type": "appPriceSchedules", "relationships": {
            "app": rel("apps", app_id), "baseTerritory": rel("territories", "USA"),
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}}
        manual = {"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                  "relationships": {"appPricePoint": rel("appPricePoints", free["id"])}}
        asc.post("/v1/appPriceSchedules", {"data": schedule, "included": [manual]})
        return "free"
    step("price: free", price)

    def availability():
        try:
            asc.get(f"/v1/apps/{app_id}/appAvailabilityV2")
            return "already set"
        except SystemExit:
            pass
        territories = [t["id"] for t in asc.get("/v1/territories", limit=200)["data"]]
        asc.post("/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"app": rel("apps", app_id),
                              "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": "${" + t + "}"} for t in territories]}}},
            "included": [{"type": "territoryAvailabilities", "id": "${" + t + "}", "attributes": {"available": True},
                          "relationships": {"territory": rel("territories", t)}} for t in territories]})
        return f"{len(territories)} territories"
    step("availability: every territory", availability)

    print()
    if failures:
        print("Did not go through:", ", ".join(failures))
    print("By hand in App Store Connect: App Privacy → Data Not Collected; then Add for Review.")


if __name__ == "__main__":
    main("--show" in sys.argv)
