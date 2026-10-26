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
  raw or PackBits; each sampled tip becomes a brush, named as the file names it) and
  Procreate `.brush` and `.brushset` files (shape, grain and a dual brush's second
  shape; each becomes a brush, named and set up as its archive says: spacing, scatter,
  rotation, jitter, pressure, size, grain depth). Neither format is published; the
  readers follow what GIMP, Krita and the Procreate community worked out.

  Checked against files from the wild (a 31-tip Photoshop 7 set from Krita's test data,
  a CC0 Procreate set of six inkers, a single `.brush`; none redistributable here, so
  `BrushImportTests.testRealBrushFilesFromDisk` runs over whatever directory
  `ARTSY_REAL_BRUSHES` names and writes each brush's stroke out to look at). What that
  found and fixed: sampled tips store coverage, white paints — the reader had them
  inverted, so every tip painted its whole square; a real `.brush` keeps `Signature`
  and `QuickLook` folders beside its files, which the reader took for the brush folders
  and found no brush; a set keeps each brush's defaults in a `Reset` folder and a dual
  brush's second half in `Sub01`, which became brushes of their own; names live in the
  `desc` section of an `.abr` and in `Brush.archive`; a shape can sit on a dark-grey
  rather than black background, which painted a faint square around every dab. Spacing
  is read as the square root of `plotSpacing` (a 5% brush stores 0.0025) and size as
  nijiGPen reads it; both are readings of an unpublished format.

- **Second tip.** A stamp brush can mask each dab with a second tip (chalk, bristle or an
  imported image) at its own size and random rotation: wherever the second tip is clear
  the dab is too, which breaks a plain tip up into texture. In the Brush Studio under
  "Second tip".

### 5. Wet media (large) — done, untested by hand

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
  - Each dab is three small encoders in strict order (copy the patch under the dab, lay
    down, pick up). A fast stroke with the 36 px built-in (~11 dabs a frame) costs 0.7 ms
    a frame at 2048², against 0.3 ms for an ordinary stroke; a 200 px smudge, 0.3 ms
    (`testSmudgeFrameCost`).
  - A smudge with *Add brush colour* between 0 and 1 is a wet paint brush: it lays its own
    colour and drags what is there along with it.

- **Pigment mixing** (`BrushDescriptor.mixesPigments`; Brush Studio → Stroke → "Mix
  colours like paint"; on for Oil, Acrylic and Smudge). The stroke's colour mixes with
  the paint under it as pigments do — Kubelka-Munk over a reflectance curve made of seven
  base pigments, a port of spectral.js's GLSL ([Spectral.h](../Artsy/Metal/Spectral.h),
  MIT) — so yellow over blue makes green instead of grey. It reproduces spectral.js's
  own example to within 3/255.
  - Coverage still adds up as for any stroke; only the colour of the overlap differs. The
    share of the new paint is its alpha's share of the result's, with spectral.js's
    weighting (share squared, times luminance) — which is what makes a 10% black over
    white come out 10% grey rather than a dark smear, as plain Kubelka-Munk would.
  - The seven pigments do not reproduce a colour exactly, so each end's error is carried
    across the mix: paint over nothing, or over its own colour, is unchanged to 1e-4.
  - The canvas holds Display P3 components as the display shows them, gamma-encoded
    (the picker gives P3 components and the drawable is P3; nothing in between decodes),
    and the model works in linear sRGB: colours are decoded and converted on the way in,
    converted and encoded on the way out. Kubelka-Munk's inverse is written in a form
    that does not cancel in single precision (black has a K/S near 10¹⁵).
  - Applied in three places: the live composite of the stroke over its layer, the merge
    at pen-up (through the scratch texture, since it reads the layer), and a smudge's
    deposit (both the brush colour into the carried paint and the carried paint into
    the layer). Dulling's average is still an average of light.
  - A mix costs ~40 × (7 + 3) multiply-adds per pixel, on dirty regions only.

- **Washes: glazing, wet edges, granulation.** `mixing` is now a three-way choice —
  light (the usual average), pigment, or *glaze*: the stroke multiplies what is under it,
  as a transparent wash does, and never lightens it. A brush with `wet` settings dries
  as a wash at merge time, on the stroke's accumulated coverage rather than per dab:
  - *Edges*: the soft outer falloff becomes a crisp boundary, roughened by the paper,
    with a darker rim just inside it where the pigment gathered, and a lighter middle
    it left. A pixel's rim is capped at a few times its own coverage, so a faint stroke
    gets a faint rim rather than a dark outline.
  - *Granulation*: pigment settles into the paper's valleys — the canvas-fixed paper
    texture from step 3, so the same paper shows through every wash.
  - All of it runs in the live composite and in the pen-up merge, through the same
    shader (`mergeStroke` in Shaders.metal), so the preview is what you get.
  - **Watercolor** is a stamp brush on these settings (wash accumulation, glaze, edges
    0.6, granulation 0.5, drier when fast). The ribbon watercolor shader is retired;
    a brush file naming it opens as a plain ribbon. Brush Studio: Stroke → Colour
    mixing, and a Wet section.
  - Pipeline creation now fails loudly when a shader function is missing; a missing
    fragment function used to build a pipeline that silently drew nothing.

- **Impasto.** A stamp brush with `impasto` settings (Oil, Acrylic; Brush Studio → Thick
  paint) lays thickness as well as colour: every dab adds height to the layer's height
  map, shaped by the tip and its grain, so bristle streaks stand up as ridges. The
  display lights it from the top left (diffuse plus a glint on ridges), with the strength
  in Settings → Thick Paint → Relief; exports show it the same way. One pass of a stroke
  builds about 1; what is lit saturates softly, so paint piled high reads as thick
  rather than as a cliff.
  - Height is a half-float texture per layer (`Layer.heightTexture`), made when thick
    paint first touches the layer; the composite's height adds the visible layers' up.
  - Dabs' height goes straight into the layer as they settle, like a smudge; the undo
    step takes it from a copy made at pen-down. The eraser takes thickness away. Undo,
    whole-stack snapshots, the move and transform tools, selection cut/move/clear,
    merge down and flatten all carry it; `.artsy` documents save it as a 16-bit grey
    PNG per layer (thickness 0...8).
  - Smudge brushes carry thickness along with colour (a second carry per mirror, on the
    layer's height map), and a dragged selection's preview shows its relief where it is.

Still to do:

- Smudge samples the active layer only ("sample all layers" is not offered).
- Pigment mixing follows spectral.js's weighting; black is a weak pigment there (its
  luminance is ~0), which is tempered only by the squared share. Tinting strength per
  colour is not exposed.
- The wash look (rim darkness, granulation strength, the boundary's roughness) is tuned
  from test renders of straight strokes; wet-into-wet (a wash diffusing into a wet one)
  is not modelled — a second wash over a dried one glazes it.

### 6. Scale (large, optional) — done, untested by hand

Done:

- **More layers, bounded by memory.** Up to 32 layers; a canvas gets fewer when more
  would not fit half of the GPU's recommended working set (`LayerStack.layerLimit`: a
  layer costs 8 bytes a pixel, 10 with thick paint). An 8192² canvas gets 12 on a
  16 GB budget, 3 on 4 GB. The layer panel and the error message follow the limit.
- **Undo history under a cap.** The budget of 25 whole-stack snapshots is now also
  capped at a quarter of the GPU's working set, whatever the canvas. And whole-stack
  snapshots share layers: every layer is copied, then compared on the GPU with the
  previous whole-stack snapshot's copy, and layers found unchanged drop their copy and
  point at the previous one. Most actions change one layer or none, so a history of
  whole-stack steps costs little more than the layers that actually changed. The
  comparison runs after the copies, off the main thread, so saving a snapshot still
  does not block.
- A **memory readout** in the status bar: layers, undo history and scratch textures.
- A **Huge (8192²)** preset.
- **16-bit PNG export** (File → Export PNG (16-bit)…), through the same lit display pass
  as the 8-bit one. Both are now tagged Display P3, the colour space the canvas is
  drawn in; they were tagged sRGB, which shifted colours in exported files.
- **Not done: tiled or sparse layers.** A spike with Metal sparse heaps on an M4 Pro
  showed the heap committing its whole size at creation, one mapped tile reporting the
  entire texture as used, and a clear writing through to "unmapped" pixels — no memory
  saving and not the semantics a tiled layer would need. Real tiling (every pipeline
  compositing from tiles) is a rewrite of the engine for a benefit that only shows at
  8192² with many mostly-empty layers; the memory-bounded limits above cover that case
  honestly instead.

- **Hold-to-snap shapes.** Draw a rough line, circle, ellipse, rectangle, triangle or
  other simple polygon and keep the pen down and still for 0.6 s: the stroke becomes the
  shape, drawn with the same brush at the stroke's usual pressure (`ShapeRecognizer`;
  Settings → Shapes). Move on and it goes back to what was drawn, continued; lift and it
  stays. The status bar names the shape while it is held.
  - Recognition: a light smoothing takes the tremor out; a stroke that runs nearly
    straight from start to end is a line; one that comes back to its start is resampled
    into a ring and simplified, and the vertices the path really turns at (40° or more)
    are its corners — three to six, with the ring following their polygon, make a
    polygon (a near-rectangle is squared up and fitted to the ring); otherwise an
    ellipse is fitted (axes from the ring's spread, radii by least squares) and accepted
    if the ring sits on it. Anything else is left alone, which is most strokes.
  - The engine draws the snapped path in place of the stroke: the stroke textures are
    started over, and thick paint already laid goes back to the layer's state at
    pen-down. Smudge brushes, which have already changed the layer, do not snap.

- **Guides.** View → Guides: a grid (⌘' to show; spacing 16–256 px; snap to it or not)
  and loose horizontal and vertical guide lines added through the middle of the view,
  ⌘-dragged into place and dropped off the canvas to remove. The pen snaps to a guide
  within 8 screen points, whatever the zoom: a guide holds the coordinate across it and
  leaves the other free, like a ruler; the grid holds both; guides win over the grid.
  Drawn by the overlay, so they turn and zoom with the canvas; saved with the document.
  (`CanvasGuides`; snapping in `CanvasViewModel`, before smoothing.)

Step 6 is done, which closes the plan as written. Not done: tiled layers (see above,
on evidence), and the hardware pen session that has been owed since step 1.

### 7. The loaded brush (medium) — done, untested by hand

The first step of `paint-media-research.md`: a paint brush that carries paint, laid down
as it goes and run out of, picking up what it crosses and coming back to its own colour.
Oil and Acrylic are loaded; the rest are as they were.

- **The carry.** A stamp brush with `StampSettings.load` has a carry texture per
  symmetry copy, mapped to the dab as a smudge's is (`PaintRenderer`, named
  `LoadedBrushRenderer` until step 8 gave it thick paint to do as well): a texel per
  canvas pixel of the brush at its full size, up to 256², holding premultiplied colour
  whose alpha is how much paint that bristle has. Filled at pen-down with the brush
  colour at its *load*, less along some bristles by *uneven bristles* (a profile across
  the brush from the bristle grain, the same every stroke, like the grain). Dabs are
  drawn from it: `stampFragment` with `usesCarry` takes the carry's colour and scales the
  dab's coverage by the bristle's load, so a bristle out of paint leaves nothing; the
  height stamp scales thickness by it the same way. Oil's and Acrylic's thickness went
  up a quarter to stay thick with the average bristle.
- **The transfer.** Every quarter diameter of path, after the dabs since the last one are
  drawn, a kernel brings the carry up to date for the dab there, per texel: what was laid
  has left (*runs out*: a share per diameter, by the tip's coverage and the pressure),
  what was crossed comes up (*picks up*: more paint on the bristle, its colour mixed in,
  as pigments if the brush mixes them), and the brush's own colour seeps back
  (*refills*). What comes up is read from the layer alone — the paint there before this
  stroke — not from the stroke so far, which is the brush's own paint just laid; the
  first version read both and picked up almost nothing but itself.
- **The same stroke however the samples fall into frames.** The transfers happen at path
  distances, so a frame boundary cannot move one; a group of dabs the frame cut short is
  drawn, and its transfer waits for the dab past the quarter. Symmetry copies of a loaded
  stroke differ in colour along it, so where they overlap the order they blend in has to
  be the same whatever the grouping: a loaded brush draws dab by dab, each copy in turn,
  instead of a copy at a time (`IncrementalRenderingTests` with Oil in quad symmetry).
- **Brush Studio** has a "Loaded brush" section: load, runs out, refills, picks up,
  uneven bristles, all per diameter. Oil: 100%, 12%, 6%, 50%, 60%. Acrylic: 100%, 25%,
  10%, 40%, 50%.
- **Cost.** A fast Oil stroke on 8192² with twelve layers: 4.2 ms a frame from 3.5
  (`testLargeCanvasCosts`), the carry's passes being a render pass per group of dabs and
  a dispatch per copy per transfer. The carries are 256² half-float, made once.
- **Tests** (`LoadedBrushTests`): the brush runs out along a stroke and not without
  depletion; red crossed comes along in the tail and not without pickup; refilling
  brings the colour back; uneven bristles leave streaks; the result does not depend on
  how samples fall into frames. The goldens for Oil, Acrylic, the relief scene and the
  everything document were re-recorded after viewing: streaks along the strokes, and the
  blue zigzag through orange coming out green, which is the point.

Still to do: a loaded brush's pickup mixes as pigments every quarter diameter, and over
its own colour that drifts by a step in 255 along a stroke (the merge carries its error
across; the carry does not). Watercolor is not loaded yet; that waits for wetness (step 3
of the research). The look is tuned from test renders and the preview pad: the amount
Oil picks up, and how fast it comes back, want a pen.

### 8. Thick paint pushed, and lit like a surface (medium) — done, untested by hand

The second step of `paint-media-research.md`. Until now thick paint only added up: every
dab put its height on top of whatever was there, and the display lit the result with one
lamp. Now a dab pushes the paint it presses into, bristles cut grooves, the light has a
sky and crevices, and there is a knife.

- **The push.** Per dab, on the layer's height map (`impastoPushKernel`, run by
  `ImpastoPusher` from a copy of the patch under the dab, as a smudge's deposit reads a
  copy): inside the tip a share of the height is taken away; in a band outside the tip,
  three tenths of the dab's size wide, it is put back along the ray from the dab's centre,
  falling off across the band, with the sums arranged so the band gains what the tip
  lost (`testPushingMovesPaintWithoutMakingOrLosingIt`: the same total within 15%). More
  goes ahead of the brush than behind (1.6 to 0.4), so a stroke drives a wave before it
  and ends in a ridge past its last dab, and a second stroke ploughs a furrow through the
  first with the ploughed paint piled beside it. The share is the brush's *squeeze*, per
  diameter of path like the loaded brush's shares (`ImpastoPusher.share(squeeze:spacing:)`
  takes it to a share per dab), so the spacing does not change the result; it also scales
  with the dab's opacity, so a light touch pushes less. A stroke pushes its own paint too:
  what the dab before laid, the next one presses into, which is where the raised edges
  of a thick stroke come from. Oil squeezes half per diameter, Acrylic 35%.
- **Grooves.** The height stamp cuts the bristle grain into what a dab leaves,
  attached to the stroke the way stroke grain is (`in.along`), so the grooves run with
  the stroke and bend with it, and for Oil and Acrylic, whose colour is grained the same
  way, they line up with the colour streaks. The bristle grain is bound for the height
  pass whatever the brush's own grain. Oil 40%, Acrylic 30%.
- **The light.** The display's relief lighting now has a key light from the top left and
  the sky all round (a slope facing away from the key is shaded, not black), occlusion
  where the paint is higher all round — looked for a texel out and four out, so a furrow
  darkens and so does the paper at the foot of a thick stroke — and a finish: the
  specular exponent runs from 6 (a broad faint sheen over everything, matte) to 64 (a
  tight bright glint on the slopes that face the light, gloss) with the Finish slider in
  Settings next to Relief, exports the same (`AppPreferences.paintGloss`). The research
  asked for roughness per brush; one finish for the painting is enough for now, and a
  per-brush one can come when the wet step gives paint a state. Cost: the display pass on
  the 8192² canvas fitted to the window is 1.14 ms with relief, from about 1.
- **The knife.** A built-in Palette Knife: a `knife` tip (a thin bar across the stroke,
  nearly the dab's width, hard-edged), a smearing smudge with no colour of its own, and
  an impasto that lays nothing and squeezes 90% per diameter. The smudge drags the paint
  and its thickness along as it did; the push, run by the smudge renderer after each
  deposit and before the pickup, scrapes what is under the blade out to its ends. In the
  preview pad it smears the bands; on thick paint it leaves a clean path with the paint
  piled at the edges (`testTheKnifePushesPaintAboutWithoutAddingAny`).
- **One renderer for paint.** `LoadedBrushRenderer` became `PaintRenderer`: any stamp
  brush with a load or an impasto (not a smudge, not an eraser) sends its settled dabs
  through it, in the quarter-diameter groups the carry needs. Per group: the colour from
  the carry (a loaded brush), then dab by dab the push and the height. Dab by dab matters:
  the first version pushed a whole group and then laid it, so a group a frame cut in two
  came out different from one it did not (`EveryBrushTests` caught it on Oil at 0.024);
  now each dab presses into the one before whatever the grouping.
- **Dabs know their heading.** `Dab.heading` is the stroke's direction at the dab, set by
  the placer; the tip's angle is not it (a tip that does not follow the direction, or one
  turned by tilt, still pushes paint the way the hand is going). Mirrors turn it as they
  turn the tip.
- **Cost.** A fast Oil stroke on 8192² with twelve layers: 4.6 ms a frame from 4.2
  (`testLargeCanvasCosts`), the push being a blit and a dispatch per dab per copy over the
  dab and its band. Undo and the pen-up are as they were.
- **Tests** (`ThickPaintTests`): a furrow and a ridge from a crossing stroke, against the
  same strokes without squeeze; the ridge past a stroke's end; paint moved not made;
  grooves across the stroke; the paper at the foot of a stroke in its shadow; gloss glints
  harder than matte and matte has the broader sheen (measured over the paint alone, on a
  dark colour so nothing clips); the knife scrapes and piles without adding paint. The
  goldens for the relief scene and the everything document were re-recorded after
  viewing (the differences lie within the Oil and Acrylic strokes), and the knife's
  preview tile recorded fresh.

What it taught: four neighbour samples at one texel cannot see the foot of a ridge —
occlusion needs a wider look than the slope does; and a glint with a high exponent is
rarely hit exactly by a discrete height field, so "glossy" has to stop at an exponent
the slopes can reach (96 showed almost nothing; 64 shows). The push is subtle at the
default relief of 1: the slider goes to 2, and the squeeze, grooves and finish want a
pen, as the loaded brush's shares do.

### 9. Wet and dry (medium) — done, untested by hand

The third step of `paint-media-research.md`: paint that is wet for a while after it is
laid, and does different things wet and dry. Until now a second wash glazed the first
whether it was wet or dry, and Oil picked up whatever it crossed, ink included.

- **A wet map per layer** (`Layer.wetTexture`, half-float, the size of the layer, made
  when a wet brush first touches it, as the height map is). It does not hold an amount
  of wetness but a time: the moment, in seconds since the layer's wet epoch, until which
  the paint there stays wet. Nothing runs to dry it. Whoever asks how wet a pixel is
  reads the time off the clock (`wetness()` in Shaders.metal): fully wet until half of
  what it was given has gone, then drying off over the rest. The research planned a
  drying pass over wet tiles on idle frames; this costs nothing on idle frames, needs no
  tile bookkeeping, and a change to the drying time takes effect on the next read. The
  epoch is the renderer's clock when the map was made; once the layer has dried all over
  and the count has run past 1024 s, the map is cleared and counts from now again, so the
  half-float times stay within a second (two seconds after an hour of unbroken wetness,
  which is as coarse as they get).
- **Laying wet paint.** A brush has a *wetness*, 0...1 (`BrushDescriptor.wetness`;
  Brush Studio → Wet → Stays wet): its share of the drying time in Settings (Wet Paint →
  Drying time, 5 s to 10 min, 60 s to start). At pen-up, after the stroke has merged,
  its coverage goes onto the wet map with a max blend (`wetStrokeFragment`): paint that
  was wetter keeps its time. Oil 100%, Watercolor 100%, Acrylic 40%; everything else 0,
  so ink never wets the paper. The undo step keeps the stroke's rectangle of the wet map
  along with its pixels and height, and puts it back (or, for a stroke that was the
  first to wet the layer, dries the rectangle); the epoch travels with it, and a
  snapshot from an older epoch is not restored.
- **What wet paint does.** A loaded brush picks up only what is wet: the transfer kernel
  reads the wet map under each bristle and scales the pickup by it, so Oil drags fresh
  Oil along and leaves dry paint, and ink, where it is — ArtRage's working time. A wash
  laid into wet paint (`Wet.blendsWhenWet`, Brush Studio → Wet → Blends when wet)
  blends with it as pigment instead of glazing over it, and keeps its edge soft there:
  the crisp boundary and the rim fade with the wetness under the stroke. Over dry paint
  it glazes with a crisp edge as before. The live composite reads the map the same way
  as the merge, so the preview is what you get.
- **Seeing and stopping it.** View → Show Wet Paint (⌥⌘W) tints the active layer's wet
  paint blue, fading as it dries (the display redraws four times a second while the
  layer is wet, and not otherwise); Edit → Dry Layer dries the active layer at once, as
  does clearing it. Nothing is saved: a document opens dry, as the research said.
- **Not done.** Smudge and the knife move paint wet or dry: they are tools, and dry
  paint that cannot be smudged would surprise. A selection moved or transformed leaves
  its wetness where it was; a layer merged down or duplicated takes the lower layer's or
  none. Edge darkening as a wash dries, and a water brush that only wets the paper, wait
  for the water step.
- **Cost.** One small pass per wet stroke at pen-up, over its rectangle; one more texture
  read in the merge and the transfer. The frame while drawing on 8192² with twelve layers is as it was
  (4.5 ms, `testLargeCanvasCosts`); the pen-up of a canvas-spanning Oil stroke there went
  from 48–62 ms to 53–117 ms across runs, the spread being the first wet stroke on a
  layer, which makes and clears the 128 MB map and copies the stroke's rectangle of it
  for undo. The wet map is 2 bytes a pixel per layer that has been wet.
- **Tests** (`WetDryTests`): paint stays wet for the brush's share of the drying time and
  dries on schedule, a fast-drying brush for its share, ink never; Dry Layer dries at
  once; a loaded brush picks up wet red and not dried or never-wet red; a blue wash into
  a wet yellow one blends to a saturated green with a soft edge and no rim, and over the
  dried one glazes grey with a rim; undo puts back how wet the paint was; Show Wet Paint
  tints wet paint and not dry; the settings survive the brush file and an older file
  reads as dry. The loaded-brush fixture now lays its red block wet, since that is what
  the brush picks up. The watercolor and acrylic preview tiles were re-recorded after
  viewing: the watercolor's crossing stroke feathers into the wet zigzag instead of
  glazing it hard-edged; the acrylic's crossings pick up a little less from its
  faster-drying paint.

### 10. Water that moves (large) — done, untested by hand

The fourth step of `paint-media-research.md`: a wash as water on the paper that spreads,
runs, pools and dries, carrying its pigment. Curtis et al. 1997, bounded to a rectangle
of the layer and to what a laptop can run every frame.

- **The water on a layer** (`LayerWater`, run by `WaterRenderer`): on the rectangle of
  the layer that water has been laid on, grown as strokes land and with a margin the
  water may bloom into, textures at the canvas's resolution (half above 4096²): free
  water and how wet the paper is (rg16 unorm), the pigment in the water (rgba16 unorm)
  and the pigment settled since the water came (rgba32 float, premultiplied), and, at the layer's own
  resolution, the dry paint that was there before. The layer's own pixels always show
  the look — settled pigment glazed over the dry paint, suspended pigment over that,
  rewritten every frame the water moves — so the composite, thumbnails, saving, export
  and undo see what the painter sees and know nothing of the water.
- **A step** (120 a second; a frame runs what the clock owes, up to 16): a flux kernel
  works out what leaves each texel for its four neighbours — downhill, the surface being
  the water on the paper's height tilted by the canvas tilt, and into paper that is not
  yet wet, which draws water from a wet neighbour — never more than most of what is
  there, so the step is stable; a gather kernel moves the water and its pigment, wets
  the paper under free water, dries the free water off (five times faster where it is
  thin, so a wash dries from its edge in and the water behind flows out to the edge) and
  the paper's wetness over the drying time, settles pigment out (a share per step in
  deep water, much more as the water thins, all of it when it is gone, more in the
  paper's valleys) and lifts a little settled pigment back up where there is free water.
  Pigment moves at four tenths of the water's rate (the paper hinders it) and cannot
  enter paper that is not yet half wet through, which is what pins a wash's edge: the
  water wets the paper ahead, the pigment follows to the line and piles up as the water
  there thins. The paper's relief, read at a coarser scale than the stamps' grain so the
  granulation is blotches rather than speckle, is scaled by the brush's granulation: at 0
  the paper is flat; at 1 the last water, and the pigment with it, sits in the valleys.
- **A stroke** (a brush with `BrushDescriptor.water`; Watercolor, and a new **Water**
  brush that lays no colour) goes into the water at pen-up instead of merging: its
  pigment into the suspended pigment, mixed in as pigment where there is some, and water
  over the whole footprint the brush touched (nearly as much at a soft edge as in the
  middle; it is the pigment that thins), by the brush's *amount*. The undo step holds
  the layer's pixels from before, as for any stroke; an undo during the flow puts them
  back and settles the water. Any other brush at pen-down, and any writing of the
  layer's pixels outside a stroke (a fill, a paste, a transform, an undo, Dry Layer),
  settles the water: the look stands, the water is forgotten. The water is forgotten
  too once it has had three drying times to dry.
- **Settings.** Brush Studio → Water: amount, flow (how readily it spreads), settling
  (low lets the pigment travel to the edges, high keeps it where the stroke put it),
  granulation. Settings → Wet Paint: the drying time (which the water shares with the
  wet map), and the canvas tilt, two sliders and Level, which the water runs with. The
  preview pad dries its wash at once (a ten-second drying time, run to completion), so
  the tile shows how a wash ends up; the Water brush's tile gets wet Watercolor bands to
  push about, as Smudge gets bands of paint.
- **What did not survive contact.** Water the paper took up as a sink: the thin edge of
  a soft stroke drank what would have carried the front on, and nothing bloomed. The
  paper's wetness is now a state the free water sets, not a quantity it consumes, as
  Curtis's capillary layer is the wet-area mask. Thin-water evaporation strong enough
  to darken the edge killed the advancing front; the edge darkens instead because the
  paper at the front is drinking and the pigment arriving there settles as the water
  thins. Settled pigment that could never move again made a water drop into a wash do
  nothing; lifting fixed it and let the per-step deposit pass go. Explicit diffusion on
  a grid spreads as the square root of time and cannot exceed a fifth of a difference
  per step and stay stable, so the bloom is modest — half a dozen pixels past a wet
  stroke in a few seconds — and more comes from more steps, not a bigger coefficient.
  Pigment that moved as freely as the water smeared every wash into a blur; the
  mobility and the wetting-front gate are what keep a body and an edge. The edge is
  still the weak point: it is there in the numbers (the rim test) and only just to the
  eye at the defaults; a lower Settling makes more of it, and it wants the pen.
- **Not done.** The region's edge is a wall (a margin of 64 layer pixels beyond the
  strokes). Smudge and the knife on a flowing layer settle it. The merge-time wash of
  step 5 stays for brushes with `wet` and no `water`. Watercolor no longer has `wet`:
  its edges come from the water. Velocity, backruns as Curtis has them (a capillary
  layer that spreads on its own), and drips wait.
- **Cost.** A canvas-spanning Watercolor stroke on 2048² (a 1.1 Mtexel region, two
  steps a frame at 60 frames a second): 1.3 ms a frame while it flows
  (`testWaterFrameCost`), nothing once it has dried. Memory while a layer's water is
  on it: 48 bytes a texel of the region plus 8 a layer pixel for the dry paint, at the
  canvas's resolution up to 4096² and half beyond, freed when the water is forgotten.
- **Tests** (`WaterTests`): a wet stroke's water spreads beyond it, with pigment, and
  dries off, after which nothing moves; pigment is moved, not made or lost; pigment
  rides out to the edge, more the more the water moves; more settles in the paper's
  valleys with granulation and none without; a wash runs downhill with the tilt; clean
  water into a drying wash lightens where it lands; undo during the flow puts the layer
  back and stops it; another brush settles the water and stays; Dry Layer stops it;
  the settings survive the brush file. The watercolor tile, the Water tile, the soft
  brushes over dark paint and the everything document were re-recorded after viewing.
- **What the first wash on the pen found (0.8.13).** A Watercolor stroke dried to a
  far paler colour than it was painted, within seconds of the lift, and the lift itself
  was seamless (live and committed pixels identical). Three causes, measured on a
  50 px wash: a quarter of the pigment was lost to rounding, since the water textures
  were half floats and each step moved a few ten-thousandths, below the half-float
  spacing near 0.5 (and at the 60 s drying time deep water could not evaporate at all,
  only drain); the glaze drew settled and suspended pigment as two layers over each
  other, which read up to 8% lighter while the pigment was half settled; and the
  pigment's mobility of 0.4 for every wash carried a third of the middle's depth out
  to the rim and a 10 px halo. Now: water and pigment in unorm16 (1.5e-5 steps, and
  nothing in them exceeds 1), the settled pigment in float since it is read and
  written in place, one pigment layer in the glaze, and mobility 0.4 × the brush's
  flow, so a plain wash (flow 0.5) dries keeping 84% of its middle with a rim 11%
  darker and a full-flow wash blooms as before. `testAWashKeepsItsPigmentAsItDries`
  holds the pigment constant through the drying, in the water's textures and in the
  layer, and the middle above 80%. The rim test uses a full-flow wash now, where the
  mechanism shows at its strongest.

### 11. Bristles (medium) — done, untested by hand

The fifth and last step of `paint-media-research.md`: the tip as a bundle of bristles.

- **The bundle** (`StampSettings.Bristles`; `bristleBundle` in Shaders.metal): clumps of
  bristles across the dab, each a streak along it with its own width and length, at
  homes in the dab's space — evenly spaced, each a little off its place; the same every
  stroke until step 12 laid them out afresh — within the tip's disc, so a stroke's ends are
  round if ragged. A clump is soft at its sides and just wider than the spacing, so a
  stroke pressed normally is solid with the tone dipping where clumps meet. Nothing
  about dab placement changed: the bundle is drawn in the fragment, a pixel taking the
  clump that covers it most, so it costs a loop over the clumps per pixel and no more
  instances.
- **What moves it.** At a light touch the bundle narrows about its middle (*fan*: a
  light touch brings the bristles towards a point); at speed the clumps thin apart
  (*parting*: a fast stroke breaks into streaks; full at 1500 px/s); the dab's pressure
  and speed go with it as two floats on the stamp instance, from the path, which now
  carries its speed on every point. *Dry brush*: a light touch reaches only the peaks of
  the paper's tooth (the canvas-fixed paper, whatever the brush's own grain), pressed
  fully it reaches the valleys too — the height-grain rule, on paint brushes. Tilt
  already stretches the dab along the lean, and the bundle with it.
- **Each clump keeps its own paint.** A pixel reads a loaded brush's carry at its clump's
  home, not at the pixel, so a clump that has run dry or picked up red stays that clump
  wherever the fan has put it. The carry's "uneven bristles" already vary the load by
  row, which is by clump. The transfer kernel's touch and the thick paint's push use the
  bundle too (the transfer at the home layout; the push at the dab's own fan and
  parting), so bristles that did not touch neither deplete nor pick up, and the ridges a
  thick stroke pushes up are the clumps'.
- **Oil and Acrylic** have bundles (12 and 10 clumps); their stroke-attached bristle
  grain is halved, since the bundle now carries most of the streaking. Brush Studio has
  a Bristles section: clumps, fan, parting, dry brush.
- **What it took.** Clumps as dots a few pixels across covered each pixel with a
  handful of dabs instead of twenty, and thickness and colour collapsed to a tenth: a
  bristle mark is a streak the length of the dab. Random homes left white gaps, and a
  stroke read as a rake; fully overlapping clumps saturated to a flat disc and nothing
  parted. Even spacing, a width just over the spacing and soft sides are the middle.
- **Cost.** The loop over the clumps is per pixel of each dab and nothing else changed:
  a fast Oil stroke on 8192² with twelve layers is 4.2 ms a frame, as it was
  (`testLargeCanvasCosts`).
- **Not done.** A brush loaded with two colours at the edges (the carry can hold it; the
  loading is a colour-picker feature). Bristles bending with tilt beyond the stretch the
  dab already gets. Clumps that cross one another.
- **Tests** (`BristleTests`): streaks across the stroke and the same streaks 60 px on; a
  light touch narrows the bundle and a bundle that does not fan stays wide; a fast
  stroke breaks into streaks and a bundle that does not part is the same at any speed;
  a light touch leaves the paper's valleys, pressed hard it fills them, and without dry
  brush it fills them at any touch; the settings survive the brush file and old files
  have none. The impasto tests use a bristle-free Oil, since they are about thickness
  carrying through. The oil and acrylic tiles, the relief scene and the everything
  document were re-recorded after viewing.

### 12. Living marks (small) — done, untested by hand

The first two of the six options in `paint-media-research.md`, "Living marks": the pen
found oil and acrylic reading as pre-baked stamps. What made them so: twelve clumps at
the same homes in every stroke, a bristle-streak image that tiled along the path, and
grooves that pressed the same image into the height, so two strokes were copies and a
straight stroke one texture extruded.

- **Variation in the bundle** (`bristleBundle`): the clump homes are hashed with the
  stroke's seed, so no two strokes share a layout; along a stroke the tuft sways as a
  whole (7% of the dab, over six and a half diameters) and each clump a little on its
  own (2.5%), so now and then two cross or part, and each swells and thins (±15%); two
  stray hairs sit at the bundle's full width whatever the touch, there for a stretch
  and gone for one, so they stand apart when a light touch narrows the bundle. A clump
  is always wide enough to reach three quarters of the way to its neighbour, wherever
  both have got to, so a gap through the stroke comes from parting at speed and never
  from the wandering: the first version let clumps wander on their own by an eighth of
  the dab, and oil read as a comb. The carry is read at a clump's home, not where it
  has wandered to, so each clump keeps its paint. The push kernel sees the bundle where
  it is at that dab; the carry's home layout has no wander and no strays. The seed
  rides on the dab (`Dab.strokeSeed`, a thirteenth float on the stamp instance), the
  same one the placer's jitter uses, so a replay and the goldens get the same marks.
- **Splay with memory** (`DabPlacer`): the fan follows the pressure up at once and down
  slowly, decaying over about a diameter of travel, so a bundle pressed hard stays
  splayed for a moment after the touch eases.
- **Procedural streaks** (`bristleStreaks`): the bristle grain is value noise on a hashed
  lattice, fine across the stroke and slow along it with breaks, drifting sideways as
  the stroke goes on, seeded per stroke, streakier the faster the stroke (by the parting)
  — in place of the image, which tiled. The grooves in thick paint come from the same
  function at the brush's grain scale, so colour streaks and grooves line up. Its spread
  is calibrated to the image's ranked heights (0.26 against 0.29, 6% at the ends). The
  image stays for the loaded brush's dip pattern only.
- **Cost.** A 3000 px oil stroke at 60 px through the harness: 184 ms before, 190
  after (acrylic 186). The loop runs per pixel, per clump, under twenty overlapping
  dabs at a spacing of 0.05, so what it does counts: one hash per clump split into
  bytes rather than seven, three sines, and no arrays — a version that kept the clumps'
  positions in per-pixel arrays, so each could see its neighbour, spilled and doubled
  the stroke's cost (392 ms); carrying the neighbour over in registers costs nothing.
- **Tests** (`BristleTests`): the profile across the stroke has changed a little a
  diameter on (0.10 mean difference), twice that many diameters on, and another
  stroke's is its own from the start; stray hairs show in 66 of 160 columns at a light
  touch while the bundle stays narrow; the splay holds at three quarters of its width
  a fifth of a diameter after the touch eases and is under 70% three diameters on; the
  streaks average 0.52 with a spread of 0.25 and three quarters of their pixels differ
  between strokes. The older bundle test now asks for mostly the same streaks two dabs
  on, and the light-touch test measures the bundle's own band rather than the stray
  beside it. The relief test compares the lit and shaded halves on average, since a
  groove can make one column on the lit side as dark as the shaded edge.

### 13. Pencil grades (small) — done, untested by hand

More pencils, asked for as HB, 2B and the rest: not as more cards, but as a grade that
is a live control on a graphite brush, the way its size is.

- **The grade** (`PencilGrade`, `BrushDescriptor.graded(_:)`): 4H to 8B as a softness
  from 0 to 1, with the seven the panel offers (2H, H, HB, B, 2B, 4B, 6B) as named
  points; the brush's own values are its HB, and the grade scales them: how much
  graphite a dab sheds (`flow`: 0.4× at 2H, 1.4× at 6B), how far a touch and a full
  press reach into the paper (the pressure's opacity range, which for a height-grain
  brush is also its reach: 0.7× and 0.9× at 2H, 1.6× and 1.15× at 6B), the pressure
  the valleys take (`grain.depth`: as HB at 2H, 0.7× at 6B), the point's width (0.75×
  to 1.5×), the edge (crisper to softer) and how uneven the deposit is (0.6× to 1.8×).
  The first mapping capped a hard grade's opacity at half and got a 2H that barely
  marked the paper at full pressure (0.13 coverage), because in this engine the
  pressure's opacity is the reach: a hard lead digs in as well as any and sheds less,
  so the cap moved to the deposit. Measured on a 12 px Pencil pressed fully: 2H 0.38,
  HB 0.73, 6B 0.86; 6B at a light touch 0.56, so the soft grade keeps its range.
- **Where it lives.** `CanvasViewModel.pencilGrade`, remembered per brush like size
  and smoothing, and across launches in the preferences (`AppPreferences.pencilGrades`,
  HB kept as the absence of an entry); `strokeBrush` is the current brush at its grade,
  and it is what the renderer and the stroke's dynamics read. A recording keeps the
  grade (`RecordedStroke.grade`); an older recording plays at HB. `remembersGrades`
  is off for tests and previews, so neither reads nor writes the preferences. The
  brush panel's quick settings show a Grade row of pills for a graphite brush
  (`BrushDescriptor.graphite`: the Pencil and the Graphite Stick; a toggle in the
  Studio's Shape section makes any brush one); the Studio's pad draws at the current
  grade; the panel's tiles are the brushes at HB.
- **Not done.** Graphite's sheen at heavy pressure (a gloss contribution from the
  stroke, as thick paint has); soft grades smudging more readily (a friability the
  Smudge brush would read); Conté and charcoal as hard, medium and soft on the same
  control; a blending stump as a Smudge preset.
- **Tests** (`PencilGradeTests`, `ShellTests`, `BrushGoldenTests`): HB is the brush and a
  brush that is not graphite has no grade; the knobs move the right way from grade to
  grade; the darkness numbers above; the grade is kept per brush and across launches
  and a recording round-trips it; a tap on a pill sets the grade; a golden strip of the
  seven grades, pressed from a touch to full, viewed before it was recorded.

## At the limits: 8192² with 12 layers

Measured after step 6 opened these limits up (`testLargeCanvasCosts`, debug build, M4 Pro):

| | before | after |
|---|---|---|
| Idle frame (nothing changed) | 107 ms | 0.03 ms |
| Frame while drawing | 3.3 ms | 2.5 ms |
| Stroke commit, GPU | 68 ms | 10 ms (6 of it the thumbnail) |
| Undo step for a selection, GPU | 1.56 s | 2.7 ms |
| Undo step for a fill, GPU | 2.25 s | 19 ms |
| History after those two steps | 6.3 GB | 0.5 GB |

Two changes made the difference:

- **Idle frames skip the composite.** The view runs at 120 fps whether or not anything
  changes, and every frame rebuilt the composite from all the layers. Now the renderer
  keeps the composite when the scene (layer list and settings), the view model's
  content version (bumped by `markDirty` and by every tool that writes pixels) and the
  stroke state are unchanged. (Until the fourth pen session it also rebuilt it once a
  second regardless, in case a change went unnoted; none did, and at 8192² each rebuild
  was 60–110 ms of GPU.) Between strokes, a frame that would show the same picture
  again — nothing recomposited, the view not moved — is not drawn at all.
- **Undo snapshots copy only what the action will change.** `saveUndoSnapshot` takes a
  scope: `.nothing` for a selection or a change to the layer list, `.layer(x)` for a
  fill, transform, cut, shape or move, `.everything` only when the caller cannot say.
  Layers outside the scope are referenced, not copied: when the step is undone every
  later change to them has been undone first, so their textures are in the right state
  — including a deleted layer's, which the snapshot keeps alive. The redo step made by
  an undo copies exactly the layers the undo restored.

## Coverage beyond the steps

Three suites run the whole engine rather than one feature at a time:

- **Every brush** (`EveryBrushTests`): for each of the 21 built-ins, on a layer with paint
  to act on — the result does not depend on how samples fall into frames; undo and redo
  restore colour and thickness exactly; mid-stroke, the regions recomposited frame by
  frame equal a full recomposite (through the display, so thickness too) on a blended
  layer with symmetry; and symmetry changes both halves about equally.
- **A random session** (`StressTests`): three seeded sessions of 220 steps each — every
  brush and tool, layer add/remove/move/hide/opacity/blend, selection moves, transforms,
  clears, merges, shifts, undo and redo — checking after each that no stroke is left
  open, the active layer is in range, the history is within its limits and memory is
  bounded, and mid-stroke that the picture equals a full recomposite.
- **The everything document** (`DocumentGoldenTests`): a canvas using every feature —
  wash, oil, smudge, a multiply layer, a held shape, a hidden layer, guides, a background
  — rendered through the display against a golden, then saved, loaded and rendered again
  within 8-bit-on-disk tolerance.

## Review pass

With the steps done, the engine was read through in five parts — undo and snapshots, the
renderer and compositing, the shaders and what feeds them, stroke input and geometry, and
the document format with the tools — looking for defects rather than style, and every
finding traced in the code before it was acted on. What that turned up, fixed, in rough
order of harm:

- **Opening a document lost its thickness and guides.** The app's File ▸ Open had its own
  loader, older than `CanvasDocument.load`, which the tests exercise. Impasto relief and
  guides survived a save and load in the tests and vanished in the app. There is one
  loader now.
- **Saving could lose or misattach pixels.** Saving during a transform wrote the layer
  without the pixels the tool was holding; a save after a layer lost its thickness, or was
  deleted, left the old height file in place for whichever layer took that index next
  time; a save was written in place, so a failure part way left a mixed document. Tools
  commit before a save or export; a save now writes a fresh bundle on the document's
  volume and swaps it in whole, or leaves the old one untouched.
- **Undo could resurrect an undone stroke.** When a referenced layer's texture object
  differed from the live one (a layer deleted and brought back from a copy), restoring
  swapped the old object back in — which no later undo had written to. A referenced
  layer that exists is left alone; references only rebuild layers that are gone.
- **Tools that race.** A bucket fill read the layer, worked on a background thread and
  wrote the whole texture back, so a stroke made meanwhile was overwritten and an undo
  meanwhile was inverted. It now lands through a mask of the pixels it reached, and only
  if its own undo step is still there to take it back. Cancelling a transform popped
  whatever undo step was on top, not necessarily its own; a step saved since (a layer
  deleted mid-transform) was lost and the layer orphaned. Steps are named now. Keyboard
  shortcuts and undo were live while the pen was down — a tool key orphaned the stroke, a
  brush key changed it halfway, an undo mid-stroke corrupted a smudge's or thick paint's
  undo step — and wait for pen-up.
- **Layer settings and the layer list.** Visibility, blend mode and opacity edits were
  not undo steps, yet an unrelated undo reverted them; reordering saved its step after
  the reorder, so undo did nothing; the AI image import saved no step and was dropped by
  the next unrelated undo; layer locks were ignored by Move Selection, Delete Selection
  and Shape; cut of a whole layer kept its thickness; new layers were never cleared and
  could show whatever a freed texture had held; merge and flatten ignored blend modes;
  a device reporting no memory budget got two layers.
- **Colour.** Layer files, thumbnails, the clipboard and pastes were tagged sRGB while
  holding Display P3 components, so images from and to other apps were shifted — and an
  opened image was converted into P3 and then back. Everything is P3 now; a layer file
  from an older document is read as the components it holds, whatever its profile says.
- **Shaders and brushes.** A smudge brush whose image tip was missing sampled the paper
  as its tip; an eraser with wet settings previewed as a wash; thick paint laid full
  thickness at any opacity (Oil at 95% now lays 5% less, hence two re-recorded goldens);
  the pigment mix could exceed white by ~1%; a calligraphy nib was not mirrored under
  symmetry; a snapped shape was drawn at a fixed 1000 px/s so velocity brushes drew it
  thin; an airbrush held still snapped instead of spraying; a transform preview dropped
  the content's relief; a tool writing pixels mid-stroke (a fill finishing) was not shown
  until pen-up; thumbnails were made on the main thread behind the frame in flight.
- **Untrusted files.** A damaged `.abr` looped forever; a `.brush` ZIP could claim
  gigabytes; a brush file could say spacing 0 and trap on a tap; sampled tips between
  4096 and 8192 px imported but never loaded; a document could say any canvas size.

Each fix has a test beside the ones already there (`DocumentTests` is new); 205 in all.

Left as they are, noted:

- Saving reads every layer back at once, so at the 8192² × 12 limit it wants 6 GB of
  shared textures beside the layers. A per-layer readback would halve the peak.
- A smudge dab much larger than its 256-texel carry under-samples the layer, which can
  shimmer along a wide smear.
- Stroke recordings do not capture guides or the shape-snap preference, so a replay with
  either set differently renders differently; the tests set both.
- The remaining review items are UI-level and were fixed without end-to-end tests: the
  layer panel's undo steps, the AI and stock-image imports' steps.

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

### Bringing a session back from another Mac

The app keeps a diagnostics log for each launch in
`~/Library/Application Support/Artsy/Diagnostics/`: what it ran on (app, macOS, Mac, GPU
and its memory, screens, the settings that shape a stroke), every pen that comes near
with the ids it reports, each stroke's sample count and rate, pressure and tilt ranges,
hold time and whether it snapped, each commit's CPU time, frame encode times summarised
every five seconds, undo steps saved and taken, documents opened and saved with timings,
fills, imports, and every error shown. Stroke recording is on by default in builds from
0.7.0 (Help ▸ Diagnostics ▸ Record Strokes turns it off). Help ▸ Diagnostics ▸ Export
Diagnostics… copies the logs, the stroke recordings and the brush library into one
folder to send back; the recordings replay here through `BrushGoldenTests`, the log says
what the engine did around them.

### What the first session on a real pen showed

Artsy 0.7.0 on a Mac mini M4 (macOS 27.0) with an XP-Pen tablet (vendor 10429), 35
strokes over two minutes with Hard Round, Chalk, Sumi-e, the eraser end, Pastel,
Calligraphy and Ink Brush, saved as a 2048² document; nothing with wet media or thick
paint yet.

- **The engine draws the same picture here.** The recording replayed through the
  harness matches the document's drawing layer to within 0.3% of pixels, all on stroke
  edges (8-bit on disk, antialiasing), once replayed at the session's zoom. Adaptive
  smoothing depends on the zoom, which recordings did not keep; they do now.
- **A fifth of the pen samples were repeats** — of the view model's own making, as the
  fourth session found. The explanation given here at the time, that AppKit delivered a
  second copy of every few samples 20–25 ms late, was wrong, and two releases built on
  it filtered the view's input for copies that never came. The repeats were rest
  samples: each frame the renderer tells the stroke the pen is still there, so that a
  resting pen's smoothing catches up and an airbrush keeps spraying, and it decided the
  pen was resting when its last sample was older than 4 ms. The tablet's samples reach
  the app 20–70 ms after their timestamps (the driver's latency), so by age every
  sample looked like a rest, and every frame of a moving stroke got one: a fifth of the
  samples at 250 a second and 60 frames. The stroke path absorbed them as rests, so
  brush velocity and the geometry were unharmed, but the smoother runs before that and
  goes by timestamps — the rest stood the pen still for a frame, then the next real
  sample, stamped before the rest, ran its clock backwards (clamped to a millisecond, so
  its speed read as thousands of pixels a second and smoothing let go for a sample).
  The tablet's real rate is the 250 a second the log counts; the recordings from 0.7.0
  to 0.7.2 carry the rests, and replay with them.
- **Pressure never reached 0.87.** A third of all samples sit at 0.6–0.7; the pen's
  top tenth is unused. Hard Round at 12 px drew at little over half width most of the
  time. The Soft pressure curve (saved for that pen in the curve editor) or a per-pen
  pressure range set by calibration would give the whole brush; not done, since it
  changes the feel and is a choice to make with the pen in hand.
- **Timings.** Frames idle at 0.04 ms encode and draw at 0.1–0.3 ms; one 85 ms frame in
  the first second of drawing (first-stroke allocations), none after. Commits 0.1–0.9 ms.
  Save 0.17 s. The displays run at 60 Hz, so the 120 fps view draws 60.
- **The eraser end** was recognised through proximity and erased; tilt is reported
  (up to 0.57) and reaches tilt dynamics.

The second session, the same day, drew a document over two launches: Ink Brush,
Sumi-e, Hard Round and sixteen Oil strokes, saved; reopened (the open path kept its
thickness), ten Watercolor strokes, two shapes, an opacity change, an added layer and a
fill mostly undone, saved again. Both recordings chained onto one canvas here match the
saved layer to 0.11% of pixels, the rest being the one shape kept. No error in four
launches; every tool's undo step appears in the log as designed; a fill on 2048² landed
in 0.04 s. The pen reached 0.96 this time. Each session has one 40–90 ms frame at the
first use of something: the first stroke, the first thick stroke (the layer's height map
is made then), the first chalk or watercolour stroke (the paper grain and tips were
generated on the CPU then; they are made at launch now). The frame log now says when
its slowest frame was and whether a stroke was on, to pin what is left. Hours of idle
time in the background show 10–90 ms frames at a few frames a second — App Nap, not
drawing.

The third session ran 0.7.1 on an 8192² canvas: twenty strokes with Hard Round,
Graphite Stick, Pencil, Conté, Ink Brush, Sumi-e, Calligraphy and Acrylic, the Soft
pressure curve from the tenth stroke on, saved in 3.7 s. The replay here matches the
saved layer to 103 pixels in 67 million, now that every stroke carries its zoom.

- **0.7.1's repeat filter never matched.** The recording still had 18% repeats. The
  filter compared positions and pressure exactly, and a copy differs from its original
  by rounding (the two kinds of event convert their positions separately). It takes a
  tolerance now, catches copies that come as mouse drags as well as tablet events, and
  the stroke line in the log counts the repeats it dropped, so the next session shows it
  working or not. The lesson taken: the test that covered it had passed without proving
  anything, since the stroke path absorbs repeats anyway; it asserts on the count now.
  (The next session showed it not working: it dropped nothing, and the fourth session
  found why — there were no repeats to drop.)
- **35–50 frames a second on 8192², idle as well as drawing**, where 2048² ran at 60.
  The display pass alone measures 3 ms fitted here (M4 Pro; relief 3.0, flat 2.5, 1:1
  0.3), so that is not it. The fallback recomposite ran four times a second, at 8192² a
  20–40 ms job each time that holds the next frames behind it; it runs once a second
  now. The frame log carries each frame's GPU time from the command buffers themselves
  from here on, so the next session says what the rest is.
- Pressure reached 0.97, and the Soft curve is on for that pen. The first thick stroke
  logged its height map being made (8192², no slow frame with it).

The fourth session ran 0.7.2: a 2048² document of Hard Round, Ink Brush and Sumi-e
strokes, then an 8192² one of eleven strokes across the whole canvas, each saved. Both
replay here to within 11 pixels in 4 million and 57 in 67 million.

- **The repeats were the app's own rest samples.** 0.7.2's filter dropped nothing — no
  stroke line said otherwise — yet the recording still had a fifth of its samples
  repeated, each right after its original with a timestamp 23–70 ms later. The one path
  that bypasses the filter is `holdStroke`, which the renderer calls every frame to tell
  a stroke its pen is resting, and it decided that by age: a sample older than 4 ms. On
  that Mac every sample is, since the tablet's samples arrive 20–70 ms after their
  timestamps. So every frame of a moving stroke got a rest, stamped with the frame's
  time, and the next real sample, stamped earlier, ran the smoother's clock backwards.
  A rest is now a frame that no sample arrived before, and it is stamped on the pen's
  clock, a frame on from the last sample, so the clock only runs forwards. The stroke
  line in the log counts the rest samples a stroke got (none while moving, from now
  on); the filter in the view is gone with its test, and the test that covers rests
  feeds its samples late, as the tablet does.
- **8192² on the M4: 5 ms a frame idle, 60–110 ms once a second, and at every pen-up.**
  The GPU times said what the third session could not. With nothing happening, the
  display pass took 5.4 ms a frame (0.6 ms on 2048²), and once a second a frame took
  60–110 ms — the fallback rebuild of the whole composite — so 41–52 frames a second
  with the pen on the desk, and a hitch every second while panning. At pen-up the same
  rebuild ran again, for every stroke, because a stroke's commit bumps the content
  version. Three changes. The fallback is gone: no change went unnoted in four
  sessions, and the one case that needed it, a tool's preview painted into the
  composite, is handled by name. The frame after pen-up recomposites where the stroke
  was. And the composite keeps mip levels (six for 8192²), brought up to date where it
  changes, a 2×2 box per level, a third of a region's area over all of them; the
  display pass reads the level near the view's size instead of one texel in eleven of
  level 0. Fitted to a window, an 8192² canvas now shows every stroke averaged rather
  than whichever texels the sampling landed on, and thick paint is lit from the slope
  across one screen pixel, brought back to a slope per texel, so it looks the same
  zoomed out as at 1:1 with detail finer than a pixel averaged away.
- **Frames with nothing new are not drawn.** The view asks for 120 a second; between
  strokes, one that would show the same composite at the same view is skipped before a
  drawable is taken,
  and the frame line counts them ("N skipped"). A view left alone still reports, with
  "0 frames".
- Saves: 2048² in 0.12 s, 8192² in 2.2 s, off the main thread.

On the M4 Pro here (`testLargeCanvasCosts`, 8192² with twelve layers, debug build): the
frame after pen-up 12 ms, against 123 ms for the whole composite; a drawing frame 3.5 ms
with the levels kept up; the display pass fitted to a 2304×1296 view 1.5 ms with relief
and 1.3 ms flat, from 3.0 and 2.5 (0.46 ms at 1:1). The M4, with less cache, will say
how much of its 5.4 ms that took away.

The fifth session ran 0.7.3 on three documents: 2048² with Hard Round, Ink Brush and
Sumi-e; 8192² with six strokes across the whole canvas; 4096² with seventy-four
Watercolor, Acrylic and Oil strokes, thick paint and all. Drawing "felt a lot smoother
and more natural". The replays match to 18 pixels in 4 million, 45 in 67 million, and
none in 17 million.

- **Rest samples: none to three a stroke**, from a fifth of all samples; a dab held
  still got four. The tablet's rate reads 200–215 a second now; the 250 the earlier
  sessions logged counted the rests, which the smoother had moved a little from the
  sample before them so the path took them for samples (and never for rests: every
  stroke "held 0.00 s"). The first session's guess of 200 was right.
- **A few samples a document are still stamped before the one before them** (ten in
  2,400, by 2–28 ms). The tablet delivers in bursts: a frame passes with nothing, a
  rest is stamped a frame on, then the burst arrives stamped from before the rest. The
  smoother took such a sample as a thousandth of a second (the pen a thousand times
  faster, and the smoothing letting go of it); it takes it as a sample's time on now.
  The rests themselves are a frame of hold on the path, which rounds to nothing.
- **GPU, from the frame lines.** 2048²: 1.3–1.6 ms a frame while drawing, and idle
  "1 frames in 5.0 s, 288 skipped". 8192²: 2.5–3.0 ms a frame while drawing, from
  5.4–9; idle "0 frames in 5.0 s, 300 skipped"; the first stroke on a fresh document
  122 ms (allocations and the first whole composite), and pen-up on a stroke 11,000–
  15,000 px long across the whole canvas 50–120 ms still, the stroke's bounds being
  the canvas. 4096² with wet and thick paint: 1.3–2.0 ms a frame, and a 20–90 ms
  frame about every other five seconds that the log could not pin — a whole composite
  is 25 ms there. The frame line now says what its slowest GPU frame did ("whole
  composite, idle", "3 regions, 0.42 Mpx, while drawing", "display only"), to tell the
  renderer's own work from a GPU shared with four displays.
- If those turn out to be pen-up frames on big strokes: recomposite the stroke's
  footprint — the tiles it touched — rather than its bounds.

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
