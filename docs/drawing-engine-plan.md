# Drawing engine plan

Goal: make drawing and painting the first-class feature of Artsy. Written 2026-10-05 from a
code audit of v0.6.1 plus outside research. Steps 1 to 4 are merged or in review; step 5 is next.

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

### 2. Feel (medium) — done, untested with a pen

Done:

- **Incremental strokes.** `StrokePath` settles each segment once the next pen sample has
  arrived. `CanvasRenderer` draws settled points into the stroke texture once and redraws
  only the unsettled tail (a second texture) each frame, then recomposites just the
  rectangles that changed. A frame now costs the same however long the stroke is.
- **Preview equals result.** The stroke is merged into the active layer's colour inside the
  compositing shader, before that layer's opacity and blend mode, so nothing changes at pen-up.
- **Eraser through the stroke buffer** (pulled forward from step 3, because the old path
  could not be made incremental). Its coverage is subtracted when it merges, which removes
  the beading. The eraser now erases fully at any pressure; before, it only seemed to
  because the overlapping increments compounded. The Opacity slider erases partially.
- **Dirty-rectangle undo.** A stroke saves the rectangle it touched on its layer, at pen-up.
  Other actions still snapshot the whole stack; both kinds share one history.
- **Input.** Mouse coalescing is off while a stroke is in progress. `tabletPoint(with:)`
  feeds the stroke, so pressing harder without moving grows the mark (it keeps the firmest
  pressure seen at a spot). Tested with synthesized tablet events only — see the first risk.
- **Brush cursor.** A ring the size of the tip on screen, following brush size and zoom;
  a crosshair below 6 pt or above 512 pt.

- **Stabilisation.**
  - Smoothing is on by default (Adaptive), and the chosen mode is remembered across launches.
  - Each brush has its own amount, starting from the brush's `smoothing` value.
  - The adaptive filter measures speed in screen points, so it behaves the same at any zoom.
    At half strength its cutoff is about 7 Hz at rest and 20 Hz at 500 pt/s (4 pt of lag).
  - Pressure is low-passed along with position (5–40 ms time constant by strength).
  - At pen-up the stroke is taken to where the pen actually lifted (Adaptive and Moving
    Avg). The lazy brush deliberately ends where the string left it.
  - Splines are centripetal Catmull-Rom, which does not overshoot when samples are
    unevenly spaced; the uniform form overshot a tight corner by 6 px in the test case.
- **Mouse and trackpad strokes ease in and out.** They have no pressure, so the engine
  ramps pressure up over the first few brush widths and down over the last, live while
  drawing. Each brush responds through its own dynamics; one that ignores pressure
  (Technical Pen) is unchanged. Clicks and short flicks still reach full width.
  Settings → Tablet has the switch.
- **Thumbnails** are shrunk on the GPU in 4× steps and only the small result is read back.
- **Undo depth** is a memory budget: history may use what 25 whole-stack snapshots would,
  up to 200 steps. Strokes go much deeper than before; whole-stack actions keep their 25.

Still to do:

- **Hardware check of the input rate** — see the first risk below. Draw with stroke
  recording on and look at the spacing of the sample times.
- **Tune with a pen.** The smoothing amounts, the pressure time constant and the ease
  length (2.5 brush widths, 8–160 px) are reasoned defaults, not ones anyone has drawn with.

### 3. Stamp engine (large) — done, apart from Watercolor and a dual tip

Done:

- **Two ways to draw a stroke**, chosen by `BrushDescriptor.rendering` rather than by the
  brush's name: `.ribbon` (pens and inks, plus the old watercolour, acrylic and oil
  shaders for now) and `.stamp`.
- **Dabs.** `DabPlacer` lays copies of the tip along the path at a fraction of the dab's
  diameter, with per-dab size, opacity and angle jitter and scatter. Jitter comes from the
  dab's index and a per-stroke seed, so a replay gets the same dabs. Dabs are drawn as
  instanced quads and blend source-over into the stroke texture.
- **Incremental like ribbons.** Dabs on settled path are laid once; the rest are redrawn
  each frame from a copy of the placer. The tail layers over the committed dabs when the
  stroke is composited (ribbons still take the maximum).
- **Wash and build-up.** A wash builds towards the stroke's opacity and stops there, so
  going back over it without lifting adds nothing. A build-up brush has no cap.
- **Paper grain** fixed to the canvas, so every stroke meets the same tooth. `multiply`
  tints the dab; `height` lets light pressure reach only the paper's peaks and firmer
  pressure fill the valleys, which is what makes graphite and chalk look dry. The grain
  texture is generated (tileable gradient noise, heights spread evenly) rather than shipped.
- **Tips**: a round tip with the brush's hardness, and a generated chalk tip.
- **A tap leaves a dot** as dense as the middle of a stroke, since one dab of a low-flow
  brush is nearly invisible.
- **Re-authored on stamps:** Soft Round and Airbrush (plain dabs; wash and build-up),
  Pencil and Graphite Stick (height grain), Conté and Chalk (chalk tip, height grain),
  Pastel (chalk tip, multiply grain), Marker (flat wash with faint streaks), Acrylic and
  Oil (ragged bristle tip; streaks that run along the stroke and bend with it).
- **Stroke-attached grain.** Grain can be fixed to the canvas (paper, every stroke meets the
  same tooth) or run along the stroke (bristle streaks). Both textures are generated.
- **A resting pen.** Each frame with the pen down and no new input, the view feeds the
  stroke a sample at the pen's position (`holdStroke`). Smoothing catches up to a resting
  pen, and a brush with a `holdRate` (the Airbrush) keeps laying dabs where it rests. Rests
  are timed from the samples, not the frames, and recorded like any other input, so a
  replay rests for just as long and lays the same dabs whenever frames happen to run.
- **Dynamics.** `TiltDynamics`: as the pen leans towards flat, the mark broadens, pales and
  elongates along the lean (the dry media shade with their side). `VelocityDynamics`: a
  loaded brush thins as it is swept faster (Ink Brush, Sumi-e; Watercolor also dries).
  Barrel rotation turns stamp tips and the calligraphy nib. Speed is smoothed so a jittery
  clock does not flicker the width. The tilt direction convention is unverified with a pen.

Still to do:

- Watercolor is the last ribbon with its own shader. It is best redone together with
  step 5's wet edges and diffusion. Acrylic and Oil are flat paint until step 5 adds
  smudge and impasto.
- Tips and grain from image files (with step 4's import).
- The values in the re-authored brushes and the dynamics are a first pass judged from
  test renders. Tilt in particular needs a pen: the direction convention is a guess.

### 4. Brush Studio and canvas handling (medium) — done, untested by hand

Done:

- **Brush files.** A brush is JSON: `{"format": 1, "brush": <BrushDescriptor>}`, saved as
  `.artsybrush`. Tips and grain textures are named in plain strings (`"chalk"`,
  `"image:scan.png"`). The type is declared, so a brush file opens from the Finder.
- **A brush library.** `BrushLibrary` keeps the user's brushes as one file each in
  `~/Library/Application Support/Artsy/Brushes/`, with their images in `Textures/`. The
  palette and the default-brush setting list built-ins and user brushes together.
- **Brush menu:** Brush Studio, Duplicate, Delete, Import, Export, Import Tip or Grain
  Image, Show Brushes Folder.
- **Image tips and grain.** A `.stamp` brush can use `image:<name>` for its tip (alpha is
  the shape; a flat image's darkness is) or grain (brightness is height). PNG, JPEG, TIFF
  and GIMP `.gbr` are imported; a missing image falls back to a round tip or paper.
- **Canvas rotation and flip**, view only: two-finger twist, View → Rotate Canvas
  Left/Right (⌥⌘[ ⌥⌘]) to 15° marks, Reset Rotation (⌥⌘0), Flip Canvas View (⌥⌘F). The
  status bar shows both. Strokes land under the pen whatever the view is doing.

- **Brush Studio** (Brush → Brush Studio…, ⇧⌘B): a panel that edits the canvas's current
  brush with a live preview drawn by the engine in the current colour. Every change goes
  to the canvas and the library at once; the first change to a built-in brush makes a
  copy and switches to it. It covers shape (ribbon or dabs, tip, spacing, flow,
  accumulation, resting spray), grain, jitter, pressure, tilt, speed and stroke settings.

- **Pressure curve editor.** The brush panel's pressure control is a thumbnail of the curve;
  it opens an editor with two draggable handles and the Linear/Soft/Firm presets.
- **Per-pen curves.** A proximity event names the pen (`NSEvent.uniqueID`); the curve you
  set is saved for that pen and comes back whenever it is picked up. Without a pen the
  "default" curve applies. Tested with synthesized proximity events only.

- **Imports.** Brush → Import Brush… takes Photoshop `.abr` files (versions 1, 2 and 6,
  raw or PackBits; each sampled tip becomes a brush) and Procreate `.brush` and
  `.brushset` files (shape and grain; each becomes a brush). Settings, dynamics and
  names in those formats are not read. Neither format is published; the readers follow
  what GIMP, Krita and the Procreate community worked out, and were tested only on files
  built from those descriptions, not on real exports.

- **Second tip.** A stamp brush can mask each dab with a second tip (chalk, bristle or an
  imported image) at its own size and random rotation: wherever the second tip is clear
  the dab is too, which breaks a plain tip up into texture. In the Brush Studio under
  "Second tip".

### 5. Wet media (large) — in progress

Done:

- **Smudge.** A stamp brush can move the paint under it instead of adding its own
  (`StampSettings.smudge`; built-in "Smudge"; Brush Studio → Smudge). The brush carries
  paint: for every dab it lays down what it carries, then picks up what is under it. The
  carried paint lives in a small texture mapped to the dab's quad, so moving the dab moves
  the paint. Laying it down blends the layer towards it — alpha included, with dual-source
  blending — so paint dragged off an edge thins that edge.
  - *Smearing* keeps the paint's layout, a texel per canvas pixel (256 at most), and drags
    it along. *Dulling* keeps one colour, the tip-weighted average under the dab, and
    softens without dragging.
  - *Carry/strength* is defined at a quarter diameter and scaled to the brush's spacing,
    so it reads the same whatever the spacing: smeared paint fades by `strength⁴` per
    diameter travelled (1 carries for ever); dulling blends in `1 − (1 − strength)⁴` per
    diameter. *Add brush colour* mixes the brush's colour into what is laid down; at 100%
    it paints like any other brush.
  - A smudge draws straight into the layer, as the path settles (no provisional tail), and
    the changed regions are recomposited like any stroke's. The layer is copied at
    pen-down (one canvas-size texture, made on first use) and the undo step is cut from
    that copy at pen-up, so undo costs what any stroke's does.
  - Each dab is two small render passes in strict order, so a frame costs two encoders per
    dab laid; at the built-in's spacing that is a few per frame.

Still to do:

- Wet-mix controls, a per-brush pigment-mixing toggle (spectral.js port), wet edges,
  paper granulation, impasto height map with lighting; redo Watercolor on them.
- Smudge samples the active layer only ("sample all layers" is not offered).

### 6. Scale (large, optional)

Tiled layers, more than 8 layers, larger canvases, 16-bit export, hold-to-snap shapes, guides.

## Measurements

M4 Pro, optimised build, 2048² canvas, Soft Round at 24 px. From `StrokeBenchmarkTests`,
2026-10-05.

One frame while a stroke is in progress (main-thread encode / whole frame including GPU):

| Stroke path so far | v0.6.1 + step 1 | After incremental strokes |
|---|---|---|
| 2,000 px | 0.39 / 2.31 ms | 0.05 / 0.42 ms |
| 10,000 px | 1.29 / 3.03 ms | 0.05 / 0.26 ms |
| 30,000 px | 3.63 / 5.71 ms | 0.05 / 0.27 ms |
| 60,000 px | 7.33 / 9.32 ms | 0.05 / 0.27 ms |

A 120 Hz frame is 8.3 ms.

Undo cost of one 600 px stroke:

| | v0.6.1 + step 1 | After dirty-rectangle undo |
|---|---|---|
| 2 layers | 64 MB, copied at pen-down | 0.12 MB, about 1 ms at pen-up |
| 8 layers | 256 MB, copied at pen-down | 0.12 MB, about 1.2 ms at pen-up |

A whole-stack snapshot (still used by layer changes, fills, pastes and selections) took
3–17 ms of GPU time with 2 layers and 30–63 ms with 8 across runs; treat those as a range.

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
