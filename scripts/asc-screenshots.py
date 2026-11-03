#!/usr/bin/env python3
"""Uploads App Store screenshots through the App Store Connect API.

    scripts/asc-screenshots.py <folder>

The folder holds PNGs named by device and order: ipad-1-canvas.png, iphone-2-brushes.png,
mac-1-canvas.png. The device prefix picks the display type and the platform's version;
the number is the order on the page. Each device's set is replaced: screenshots already
in it are deleted first. The iPad is the 13-inch set (2064×2752), the iPhone the
6.9-inch set (1320×2868), the Mac 2880×1800.
"""
import hashlib, os, sys, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc

DEVICES = {
    "ipad": ("IOS", "APP_IPAD_PRO_3GEN_129"),
    "iphone": ("IOS", "APP_IPHONE_67"),
    "mac": ("MAC_OS", "APP_DESKTOP"),
}


def localization(app_id, platform):
    version = next(v for v in asc.get(f"/v1/apps/{app_id}/appStoreVersions")["data"] if v["attributes"]["platform"] == platform)
    return next(l for l in asc.get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"] if l["attributes"]["locale"] == "en-US")


def screenshot_set(loc_id, display_type):
    sets = asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == display_type:
            return s["id"]
    made = asc.post("/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
        "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}})
    return made["data"]["id"]


def clear(set_id):
    for shot in asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]:
        asc.delete(f"/v1/appScreenshots/{shot['id']}")


def upload(set_id, path):
    data = open(path, "rb").read()
    name = os.path.basename(path)
    made = asc.post("/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {"fileName": name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in made["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        request = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for header in op["requestHeaders"]:
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request) as response:
            response.read()
    asc.patch(f"/v1/appScreenshots/{made['id']}", {"data": {"type": "appScreenshots", "id": made["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    return made["id"]


def main(folder):
    app_id = asc.app()["id"]
    files = sorted(f for f in os.listdir(folder) if f.endswith(".png"))
    by_device = {}
    for f in files:
        device = f.split("-")[0]
        if device in DEVICES:
            by_device.setdefault(device, []).append(f)
    for device, names in by_device.items():
        platform, display_type = DEVICES[device]
        loc = localization(app_id, platform)
        set_id = screenshot_set(loc["id"], display_type)
        clear(set_id)
        for name in names:
            upload(set_id, os.path.join(folder, name))
            print(f"✓ {platform} {display_type}: {name}")
    print("Uploaded; App Store Connect processes them in a minute or two.")


if __name__ == "__main__":
    main(sys.argv[1])
