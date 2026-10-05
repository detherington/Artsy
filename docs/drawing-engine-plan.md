# Drawing engine plan

Goal: make drawing and painting the first-class feature of Artsy. Written 2026-10-05 from a
code audit of v0.6.1 plus outside research; step 1 was done the same day.

**Direction:** keep the current ribbon renderer for inking pens, and build a stamp (dab)
engine beside it for everything meant to be paint or dry media. Fix feel and correctness
first, because those affect every brush.

## Where the engine stood at v0.6.1

- **An inking renderer with painting-brush names.** Every brush is a triangle-strip ribbon
  with a procedural cross-section, chosen by brush name in `BrushDescriptor.shaderType`.
  No dabs, tip or grain textures, build-up, or colour mixing.
- **Most brush parameters did nothing.** `flow`, `buildUp`, `spacing`, tilt, velocity,
  per-brush `smoothing` and `baseSize` were never read; the Opacity slider never reached
  the renderer. *(Fixed in step 1.)*
- **Soft brushes composited incorrectly.** Stroke shaders returned straight alpha into a
  premultiplied pipeline, so soft edges added their full colour to whatever was beneath.
  The white canvas hid it for dark colours. *(Fixed in step 1.)*
- **Per-frame cost grows with stroke length.** The whole stroke is re-interpolated twice and
  re-tessellated every frame. See the baseline below.
- **Undo copies every layer at every pen-down.** 32 MB per layer at 2048², up to 25 steps.
- **Input is thinner than the pen provides.** Event coalescing is on by default,
  `tabletPoint(with:)` is ignored (pressure-only samples arrive there), smoothing defaults
  to off, pressure is never smoothed, and tilt, rotation and velocity are captured but unused.
- **View gaps.** No brush-size cursor; `CanvasTransform.rotation` exists but is not applied.

## Choices

| Decision | Chosen | Alternatives and why not |
|---|---|---|
| Rendering core | Instanced stamp engine; ribbon kept for inking | Ciallo-style analytic stamps: reference code is GPL/AGPL and it cannot do smudge. Embedding libmypaint: permissive (ISC) but a CPU tile engine that does not fit the Metal pipeline. |
| Blending space | Keep gamma-encoded compositing; mix paint in pigment space | Full linear: cleaner mixes, but changes how every soft brush looks and differs from Photoshop's default. |
| Pigment mixing | Port spectral.js (MIT, ships GLSL) to Metal | Mixbox: ships a Metal shader but is CC BY-NC with unpublished commercial pricing. Oklab: cheap, but blue and yellow still do not make green. |
| Watercolour and oil | Stamp-engine effects: smudge, wet edges, paper granulation, height-map impasto | Fluid simulation (Rebelle, Fresco): a product in itself. |
| Undo and memory | Save only the stroke's dirty rectangle of the active layer | Tiled or sparse layers now: a larger refactor that only pays off beyond 4096² or 8 layers. |
| Frame loop | Render on input plus a short tail, then idle | `CAMetalDisplayLink`: only if measured latency still needs it. |

## Steps

Sizes are relative to each other.

### 1. Safety net and correctness (small) — done

- **Test harness.** `ArtsyTests/EngineHarness.swift` drives the real `CanvasViewModel` and
  `CanvasRenderer` without a window. See [Testing the engine](#testing-the-engine).
- **Alpha.** Stroke shaders return premultiplied colour. Layer opacity scales colour as well
  as alpha. Blend modes leave the source unchanged where there is no backdrop (multiply,
  overlay and darken used to turn it black). The display shader and eyedropper treat the
  composite as premultiplied.
- **Opacity slider.** Applied when the stroke buffer is merged (and previewed), so it caps
  the whole stroke and self-overlaps do not darken. For the eraser it scales how much is removed.
- **Brush sizes.** Picking a brush sets the size slider to that brush's `baseSize` the first
  time, and to the size it was left at afterwards. The eraser keeps its own size.
- **Dead parameters removed.** `tipTextureName`, `tipShape`, `minSize`, `tiltEnabled`,
  `velocityEnabled`, `spacing`, `smoothing`, `blendMode`, `flow`, `buildUp`, the pressure
  flow range, and the unused textured-tip shader and pipeline. The values they held were
  never exercised; `git show f8b934c:Artsy/Brushes/BrushDescriptor.swift` has them if the
  intent is useful when re-authoring brushes in step 3.
- **Stroke history removed.** `strokeHistory` kept every stroke's points for the life of the
  canvas and nothing read it. `Stroke` and `rerenderLayer` went with it.
- **Pen-up fix.** Samples that arrived after the last displayed frame were never drawn, so
  strokes ended up to a frame short. `finalizeStroke()` now draws them before merging.

### 2. Feel (medium)

- Full-rate input: coalescing off during strokes; `tabletPoint` funnelled with mouse events.
  **Start with a hardware test** — see the first risk below.
- Render only the new part of the stroke each frame; cache the layers below and above the
  active one. Target: the frame-cost benchmark is flat across stroke lengths.
- Stabilisation: on by default, per-brush amount, pressure smoothed with position, catch-up
  to the pen on lift, start and end taper. Centripetal Catmull-Rom instead of uniform.
- Brush-size outline cursor.
- Dirty-rectangle undo instead of whole-stack snapshots.
- Found during step 1, to fix here:
  - The in-progress stroke is previewed with normal blending at full layer opacity, then
    merged into the layer, so on a layer with reduced opacity or a blend mode it changes
    appearance at pen-up.
  - Every stroke end reads the whole layer back to the CPU to rebuild a 64 px thumbnail.

### 3. Stamp engine (large)

- Instanced dabs with tip textures, spacing, and flow versus opacity (wash and build-up modes).
- Scatter and jitter; tilt, rotation and velocity dynamics; moving and static grain.
- Route the eraser through the stroke buffer. Today it draws straight into the layer in
  overlapping increments, which shows as beading at partial opacity (visible in
  `Golden/eraser.png`).
- Re-author pencil, chalk, pastel, airbrush, marker, acrylic and oil on stamps.
- Select the shader by a field on the brush, not by its name.

### 4. Brush Studio and canvas handling (medium)

- Data-driven brush format and an editor with a live preview pad.
- Custom pressure-curve editor; per-pen settings keyed on `NSEvent.uniqueID`.
- Canvas rotation and flip.
- Import of tip and grain images (PNG, GIMP `.gbr`; then Photoshop `.abr` and Procreate
  `.brush` shape and grain).

### 5. Wet media (large)

Smudge (dulling first, then smearing), wet-mix controls, a per-brush pigment-mixing toggle,
wet edges, paper granulation, impasto height map with lighting.

### 6. Scale (large, optional)

Tiled layers, more than 8 layers, larger canvases, 16-bit export, hold-to-snap shapes, guides.

## Baseline measurements

M4 Pro, optimised build, 2048² canvas, Soft Round at 24 px, two layers unless noted.
From `StrokeBenchmarkTests` on 2026-10-05, before any step 2 work.

| Stroke path so far | Main-thread encode | Whole frame incl. GPU |
|---|---|---|
| 2,000 px | 0.39 ms | 2.31 ms |
| 10,000 px | 1.29 ms | 3.03 ms |
| 30,000 px | 3.63 ms | 5.71 ms |
| 60,000 px | 7.33 ms | 9.32 ms |

A 120 Hz frame is 8.3 ms. A second run was within 10% of these.

| Undo snapshot at pen-down | Call | Until GPU copies finish | Memory per undo step |
|---|---|---|---|
| 2 layers | 0.3 ms | 3–16 ms | 64 MB |
| 8 layers | 0.5–0.8 ms | 30–63 ms | 256 MB |

The GPU figures for the snapshot varied that much across three runs; treat them as a range.

## Testing the engine

Run everything:

    xcodebuild test -project Artsy.xcodeproj -scheme Artsy -destination 'platform=macOS'

Xcode needs its Metal Toolchain component to compile `Shaders.metal`
(`xcodebuild -downloadComponent MetalToolchain`). The app is launched as the test host but
opens no windows.

- **`CompositingTests`** — numeric checks on alpha, opacity and blend modes.
- **`BrushGoldenTests`** — renders fixed strokes with every brush, plus eraser, opacity,
  symmetry, smoothing and blend-mode scenes, and compares with `ArtsyTests/Golden/*.png`.
  A mismatch writes the render and a difference map to `ArtsyTests/Golden/failures/`.
  After an intended change, re-record by prefixing the command with
  `TEST_RUNNER_ARTSY_RECORD_GOLDENS=1` and review the changed PNGs in the diff.
  The grain shaders hash pixel positions through `sin`, so goldens are only expected to
  match on the GPU family they were recorded on (Apple M4 Pro).
- **`CanvasViewTests`** — synthetic mouse events through a real `CanvasView`, including undo.
- **`StrokeBenchmarkTests`** — prints `BENCHMARK` lines; the doc comment has the command
  for an optimised run.

**Replaying real pen input.** Synthetic strokes cannot stand in for a hand. To capture real ones:

    defaults write com.artsy.app recordStrokes -bool YES

Each canvas then writes its raw input to
`~/Library/Application Support/Artsy/Stroke Recordings/`. Copy a file into
`ArtsyTests/Recordings/` and `BrushGoldenTests.testRecordedSessions` replays it and keeps a
golden for it. Turn recording off with `defaults delete com.artsy.app recordStrokes`.

## Risks to check early

- **macOS input rate.** Developers report macOS 26.2 downsampling mouse events to the
  display refresh rate (<https://developer.apple.com/forums/thread/811024>). Nobody has
  confirmed whether tablet events are affected or whether disabling coalescing restores the
  full rate. The recorder above shows the sample rate actually received.
- **Pigment mixing in P3.** spectral.js works in sRGB only and needs adapting.
- **Brush imports.** The `.abr` parsers found are GPL (Krita, abrupng), so a permissive one
  would have to be written. Procreate's `.brush` is reverse-engineered with no spec, and
  paid packs often forbid redistribution.

## Open decisions

1. Will Artsy ever be sold? That decides whether Mixbox is an option at all.
2. Which tablets are available to test with?
3. Keep Intel support? Sparse textures in step 6 are Apple-silicon only.

## Sources

- Coalescing and tablet events: <https://developer.apple.com/documentation/appkit/nsevent/ismousecoalescingenabled>,
  <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTabletEvents/HandlingTabletEvents.html>
- Frame pacing: <https://developer.apple.com/documentation/quartzcore/cametaldisplaylink>, <https://zed.dev/blog/120fps>
- Stamp model: <https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings>,
  <https://docs.krita.org/en/reference_manual/brushes/brush_settings/opacity_and_flow.html>
- Stabilisers: <https://docs.krita.org/en/reference_manual/tools/freehand_brush.html>, <https://lazynezumi.com/smoothing>
  (Krita is GPL: reimplement from the documented behaviour, do not copy source.)
- GPU stamp strokes: <https://shenciao.github.io/brush-rendering-tutorial/>
- Pigment mixing: <https://github.com/rvanwijnen/spectral.js>, <https://github.com/scrtwpns/mixbox>
- Smudge: <https://docs.krita.org/en/reference_manual/brushes/brush_engines/color_smudge_engine.html>
- Blending space: <https://docs.krita.org/en/general_concepts/colors/linear_and_gamma.html>, <https://bottosson.github.io/posts/colorwrong/>
- Tiles and undo: <https://community.kde.org/Krita/Transactions_Design>,
  <https://developer.apple.com/documentation/metal/assigning-memory-to-sparse-textures>
