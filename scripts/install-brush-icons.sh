#!/usr/bin/env bash
# Regenerate brush icons from scripts/brush-icons.txt
#
# Fetches icons from the Iconify API (~150 libraries, ~200,000 icons, all free).
# Reads the mapping file, downloads each SVG, rasterizes at @1x/@2x/@3x via
# a small Swift rasterizer, and installs template imagesets into the asset
# catalog.
#
# Mapping file format (one entry per line):
#   <brush-key>    <prefix>/<icon-name>
#
# Example:
#   pencil         mdi/pencil
#   airbrush       fluent/spray-24-filled
#   calligraphy    game-icons/quill-ink
#
# Browse all icons at https://icon-sets.iconify.design/ — click an icon,
# the ID above the preview is "<prefix>:<name>" (we use "/" in the file).
#
# To change an icon: edit scripts/brush-icons.txt, then rerun this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP_FILE="$REPO_ROOT/scripts/brush-icons.txt"
ASSETS="$REPO_ROOT/Artsy/Resources/Assets.xcassets"
TMP_SVG_DIR="/tmp/iconify-icons"
RASTERIZER="$(mktemp /tmp/svg_to_png_XXXX.swift)"

mkdir -p "$TMP_SVG_DIR"

cat > "$RASTERIZER" <<'SWIFT'
import AppKit
import Foundation

let srcURL = URL(fileURLWithPath: CommandLine.arguments[1])
let dstDir = URL(fileURLWithPath: CommandLine.arguments[2])
let baseSize = Int(CommandLine.arguments[3]) ?? 20

guard let src = NSImage(contentsOf: srcURL) else { exit(1) }
try? FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

for scale in [1, 2, 3] {
    let px = baseSize * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: px, height: px).fill()
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    let suffix = scale == 1 ? "" : "@\(scale)x"
    let out = dstDir.appendingPathComponent("icon\(suffix).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: out)
}
SWIFT

count=0
errors=0

while IFS= read -r line; do
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue

    # Columns: <brush-key> <prefix>/<name>
    read -r key iconref _rest <<< "$line"

    # Split prefix/name (iconref uses "/" as separator; Iconify API uses same)
    prefix="${iconref%%/*}"
    name="${iconref#*/}"

    if [ -z "$prefix" ] || [ -z "$name" ] || [ "$prefix" = "$iconref" ]; then
        echo "  ✗ $key: malformed iconref '$iconref' (expected <prefix>/<name>)"
        errors=$((errors + 1))
        continue
    fi

    asset_name="brush-${key}"
    imgset="$ASSETS/${asset_name}.imageset"
    svg_path="$TMP_SVG_DIR/${key}.svg"

    url="https://api.iconify.design/${prefix}/${name}.svg"
    if ! curl -fsSL -o "$svg_path" "$url"; then
        echo "  ✗ $key: couldn't fetch $url"
        errors=$((errors + 1))
        continue
    fi
    # Iconify returns 404 as plain text — validate that we got an SVG
    if ! head -c 200 "$svg_path" | grep -q "<svg"; then
        echo "  ✗ $key: '$iconref' not found on Iconify (bad prefix or name)"
        errors=$((errors + 1))
        continue
    fi

    rm -rf "$imgset"
    mkdir -p "$imgset"
    swift "$RASTERIZER" "$svg_path" "$imgset" 20 2>/dev/null

    mv "$imgset/icon.png"    "$imgset/${asset_name}.png"
    mv "$imgset/icon@2x.png" "$imgset/${asset_name}@2x.png"
    mv "$imgset/icon@3x.png" "$imgset/${asset_name}@3x.png"

    cat > "$imgset/Contents.json" <<EOF
{
  "images" : [
    { "filename" : "${asset_name}.png",    "idiom" : "universal", "scale" : "1x" },
    { "filename" : "${asset_name}@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "${asset_name}@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
EOF

    printf "  ✓ %-18s → %s/%s\n" "$key" "$prefix" "$name"
    count=$((count + 1))
done < "$MAP_FILE"

rm -f "$RASTERIZER"
echo ""
echo "Installed $count brush icons ($errors errors)."
echo "Rebuild the app to see the new icons."
