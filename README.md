# Artsy

Native macOS sketchpad with Metal rendering, pressure-sensitive tablet support, AI image generation, and custom brushes.

## Features

- **Metal-powered rendering** — smooth, GPU-accelerated strokes with radial-distance round caps
- **Pressure-sensitive tablet support** — Wacom, Xencelabs, and compatible; auto pen/eraser flip detection
- **Brush engine** — Hard/Soft Round, Pencil, Ink, Marker, Watercolor, Acrylic, with per-brush pressure dynamics
- **Stroke smoothing** — One Euro filter, lazy-brush, and Catmull-Rom interpolation (adjustable)
- **Layers** — reorderable with drag-drop, blend modes, opacity, lock/visibility, per-layer thumbnails
- **Selection tools** — rectangle / ellipse / freeform marquees with marching ants + GPU cut/paste
- **Shape tool** — rectangle / ellipse / freeform with configurable stroke + fill
- **AI generation** — OpenAI Images + Google Gemini/Imagen, with custom style presets
- **Stock imagery** — Unsplash integration with search + fit-to-canvas import
- **Custom color picker** — SV square + hue slider + hex + eyedropper + recent colors
- **Display P3 color** throughout the pipeline
- **Configurable defaults** — canvas size, default brush, skip-on-launch dialog
- **Auto-updates** via Sparkle
- **Tabbed canvases** — multiple documents in a single window
- **Distraction-free mode** — fullscreen, no chrome

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac with Metal-capable GPU

## Install

Download the latest [DMG from Releases](https://github.com/detherington/Artsy/releases/latest) and drag `Artsy.app` to `/Applications`.

## Build from source

```
xcodebuild -project Artsy.xcodeproj -scheme Artsy -configuration Release build
```

## Release pipeline

Release script handles build + codesign + notarize + DMG + Sparkle appcast generation:

```
scripts/release.sh 0.3.0
```

Then commit `appcast.xml` + create a GitHub Release with the DMG as an asset.
