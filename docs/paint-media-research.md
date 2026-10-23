# Paint that behaves like paint: where the wet and thick brushes fall short, and what to do

The engine's ordinary brushes are right. Oil, Acrylic, Watercolor and the other paint
brushes are not yet: they are built from the same stamp engine with effects applied to
each dab or at pen-up, and that is why they read as filters over a stroke rather than as
paint. This is a survey of what the field does, measured against what we have, and a
plan.

## What we have (see `drawing-engine-plan.md`, step 5)

- **Oil, Acrylic.** A bristle tip stamped along the path, the bristle grain multiplied
  in, "wash" accumulation (dabs build to the stroke's opacity and stop), colour mixed
  into the layer as pigments (Kubelka–Munk over seven base pigments, a port of
  spectral.js, MIT), and a height map: every dab adds coverage × thickness, so the
  bristle grain stands up as ridges. The display lights height from a fixed top-left
  light with a glint.
- **Watercolor.** The same stamp with soft dabs, glaze mixing (multiply), and at merge
  time a "wet" pass over the stroke's accumulated coverage: a crisp boundary roughened
  by the paper, a darker rim just inside it, a lighter middle, and granulation from the
  paper's valleys.
- **Smudge.** The one brush that carries paint: lays down what it carries, picks up what
  is under it (colour and thickness), in a small carry texture that moves with the dab.
  With *Add brush colour* between 0 and 1 it is a wet paint brush.

The golden renders show the result ([brush-oil](../ArtsyTests/Golden/brush-oil.png),
[brush-watercolor](../ArtsyTests/Golden/brush-watercolor.png),
[thick-paint-relief](../ArtsyTests/Golden/thick-paint-relief.png)): an oil stroke is a
uniform blue ribbon with faint streaks, the same from start to end; the relief looks
right only where two strokes cross; a wash is a flat tint with noise and a thin rim.

## Why it does not feel like real media

Five things real paint does that these brushes never do:

1. **Nothing changes along a stroke.** The brush never runs out, never picks up what
   it crosses (only Smudge does), never splays or skips. Every dab is the same stamp,
   so a long oil stroke is a ribbon. A real stroke starts loaded and wet, thins, drags
   the colour it crossed into its tail, and breaks up over the canvas tooth as it dries
   and the pressure eases.
2. **Nothing happens after the pen lifts.** No drying, no flow, no bloom. A wash is one
   pass with a rim; a second wash over it glazes, whether the first is wet or dry.
   Watercolour's character is what happens in the minute after the stroke.
3. **Thickness is a copy of coverage.** Ridges come from the grain texture, not from
   paint being pushed: a dab pressed into existing paint should displace it to its rim,
   leave grooves along its direction, and a stroke should end in a ridge where the
   paint stopped. The light is one fixed lamp with no shadowing, and oil and acrylic
   shine the same.
4. **The brush never gets dirty.** Mixing happens between the stroke colour and the
   layer at each dab, which is right as far as it goes; but the brush carries no paint,
   so colour cannot be pulled through from one patch to the next except with Smudge.
5. **The canvas is a multiply, not a surface.** Grain darkens or lightens coverage;
   it does not decide where thin paint sits (on the tooth) or where water pools (in
   the valleys), and light pressure does not skip.

## What the field does

**Products.**

- **Rebelle 8** (Escape Motions, 2025) is the reference for the natural-media feel.
  Its new bristle engine models each bristle as a particle, so pressure fans the brush
  out and light pressure narrows and curls it; dry-brushing comes from that. Thick
  paint is lit by "RealShader": strokes treated as geometry with an environment map or
  HDRI light, "SoftShadows" in the crevices as paint builds up, and reflectivity maps
  per layer (pearlescent paint). Watercolour is a fluid simulation (Navier–Stokes), with
  the controls that matter: absorbency (how fast paper takes the wash), re-wet (how a
  new stroke meets the wet paint under it: low blends softly, high re-wets and makes
  hard edges), edge darkening on drying, diffusion speed, texture influence, granulation
  that appears as the painting dries, canvas tilt, a blow tool, drips (DropEngine), and
  "dry the layer" to stop it. Pigment mixing is Mixbox. Custom granulation maps.
- **Adobe Fresco** ships "live brushes" for oil and watercolour; the research behind
  them was Wetbrush (below), the product is a stamp engine with physics-driven effects
  near the stroke. A competitor's critique (Expresii) says its watercolour spreads as
  expanding waves confined to the stroke, which gives "turtle-back" patterns and no
  large-area flow; its oils mix on the canvas, which is what people like about it.
- **Expresii** (Nelson Chu's Moxi engine) is the other end: full computational fluid
  dynamics for water and ink with global flow, a physically deforming 3D brush that can
  be loaded with several colours along the tuft. Ink and watercolour only.
- **Corel Painter** (Thick Paint, Artists' Oils) is the loaded-brush school: a paint
  load that runs out ("infinite paint" off), resaturation (how much fresh colour comes
  back during a stroke), bleed (how much the stroke mixes with what is on the canvas),
  viscosity (how fast it runs out), trail-off, bristle density, a palette knife that
  scrapes with a load of zero. **ArtRage** is the same idea done simply and well: it
  tracks how much paint there is and how wet it is per pixel, with a thinners setting
  per tool, and a knife that pushes ridges.
- **Procreate** stays a stamp engine with "Wet Mix" (charge, pull, dilution, grade):
  the brush carries a charge of colour that dilutes as it pulls what it crosses. No
  drying, no flow, no thickness; widely liked for the feel of the pull.

**Papers.**

- **Curtis et al. 1997, "Computer-Generated Watercolor"** is still the model: a
  shallow-water layer over the paper (water height and velocity), a pigment layer that
  moves with the water and is adsorbed by and desorbed from the paper, a capillary
  layer for backruns, wet-area masks, paper height as slope and as granulation valleys;
  edge darkening falls out of pigment migrating to the receding wet boundary as water
  evaporates; rendered by Kubelka–Munk per glaze. Later work put it on the GPU in real
  time (a Texas A&M thesis; "Real-Time Watercolor Simulation with Fluid Vorticity
  Within Brush Stroke" with pigment as particles on the GPU).
- **Chu & Tai 2005, MoXi** does ink on absorbent paper with the lattice Boltzmann
  method, cheaper and more stable than Navier–Stokes on a grid; Expresii grew from it.
- **DiVerdi et al. 2012–13, "Painting with Polygons"** (Adobe) is a procedural, vector
  watercolour: each mark is a polygon that deforms over time, with a rasterised wetness
  map, feathering into wet paper, and edge darkening as uneven evaporation. Cheap at
  print resolution. **Patented** (US 8,917,283, active), so not a route for us.
- **Baxter et al. 2004, IMPaSTo** is the thick-paint model everyone builds on: paint as
  height-field layers (one wet, any number dry), bidirectional transfer between brush
  and canvas, pigment mixing by Kubelka–Munk, real-time on the GPU of the day.
- **Chen et al. 2015, Wetbrush** (Adobe, Ohio State; SIGGRAPH Asia) simulates the brush
  at the bristle level and the paint as a hybrid of particles near the brush and a
  density field away from it, all in CUDA. The result is the most convincing oil ever
  shown on a screen, and too heavy for a laptop at canvas resolution; Fresco is its
  shadow.
- **Stuyck et al. 2017, "Real-Time Oil Painting on Mobile Hardware"** adapts the
  shallow-water equations to oil paint on an iPad: paint with height and pigment in a
  multi-layered structure, from thick paint that keeps its shape to runny paint that
  follows the tablet's tilt, lit from the device's orientation. The proof that a
  Curtis-style sim is affordable on a tablet for oil as well as water.
- **Mixbox (Sochorová & Jamriška 2021)** is pigment mixing in a latent Kubelka–Munk
  space, used by Rebelle; still CC BY-NC, commercial licences on request. Our
  spectral.js port does the same job under MIT, less tuned.
- **Frontier.** NVIDIA's Neural Brushstroke Engine (SIGGRAPH Asia 2022) learns a brush
  from ~200 example images and paints interactively — on a server. "Painting with 3D
  Gaussian Splat Brushes" (SIGGRAPH 2025) paints with real captured brush marks. Both
  point the same way: real marks, captured, rather than simulated. Neither runs on a
  Mac in a paint app today; the capture idea does (we import ABR and Procreate tips).

## The proposal

Keep the stamp engine, which is right for everything else, and give the paint brushes
the four things above in the order that each pays the most for its cost. Everything
below is a paper's method, not anyone's code; Krita's and Mixbox's code stay out.

### 1. A loaded brush (medium)

Every paint brush carries paint, as Smudge does: a carry texture per stroke, filled at
pen-down with the brush colour times its *load*. Each dab lays down a share of what it
carries and picks up a share of what is under it, both mixed as pigments; the carry
thins by *depletion* per diameter travelled and refills by *resaturation*; *bleed* is
how much of what is picked up goes into what is laid next. Oil: high load, low
depletion, some bleed — the colour it crosses streaks into its tail. Acrylic: faster
depletion. Dry brush: low load, so the stroke breaks up over the tooth before it ends.

This is Painter's and ArtRage's model and IMPaSTo's transfer step, and most of the
machinery is in `SmudgeRenderer` already (the carry, the deposit, the pickup, pigment
mixing in both). What is new: a load that starts full of the brush colour and runs
down; per-bristle variation in the carry (bristles run dry at different rates); the
stamp path using it for Oil and Acrylic by default, with Brush Studio controls (Load,
Depletion, Resaturation, Bleed). The tail stays provisional as now; the carry's state
is part of the stroke.

**Done** (`drawing-engine-plan.md`, step 7). Two things it taught: the pickup has to
read the layer alone, not the stroke so far, or the brush picks up its own paint and
nothing else; and symmetry copies of a stroke whose colour changes along it have to be
drawn dab by dab, or the result depends on how the dabs fell into frames.

### 2. Thick paint that is pushed, and lit like a surface (medium)

- **Displacement.** A dab's height is not added; it is conserved. Where the brush
  presses into paint already there, paint moves from under the dab to its rim and
  behind it in the stroke's direction, so strokes end in a ridge and a second stroke
  ploughs a furrow through the first. Per dab: read the height under the dab, keep a
  share, push the rest to the rim with a kernel shaped by the tip and the direction.
- **Grooves.** A procedural bristle profile across the dab, aligned with the stroke
  (ridges a few pixels apart, varying with the bristle grain), on top of the tip's
  shape; today the grain's multiply is the only groove.
- **Light.** Replace the one lamp with a hemisphere light plus a key light, normals
  from the height map at the display's own scale (done), occlusion from the height's
  curvature (crevices darker: Rebelle's SoftShadows, cheaply), and a specular term
  with roughness per brush: oil glossy, acrylic satin, gouache matte. Exports the
  same.
- **The knife.** A brush that lays nothing and pushes a lot: load 0, displacement 1.

**Done** (`drawing-engine-plan.md`, step 8). What changed from the plan: the push is
per dab from a copy of the patch under it, with the band outside the tip gaining
exactly what the tip lost, biased ahead; the share is per diameter of path, like the
loaded brush's, so spacing does not change it. Grooves come from the bristle grain
attached to the stroke rather than a profile of their own, so they line up with the
colour streaks. The finish is one slider for the painting (matte to gloss) rather than
a roughness per brush; that can follow once wetness gives paint a state. Two lessons:
occlusion needs to look a few texels out, not one, to shade the foot of a ridge; and a
glossy exponent the height field's slopes never hit exactly shows nothing — 64 is as
tight as it can usefully go.

### 3. Wet and dry (medium)

A wetness map per layer (one more half-float texture, like the height map), written by
wet brushes, drying over seconds at a rate the paper sets. Strokes into wet paint blend
and bleed (the carry of step 1 picks up more where it is wet); into dry paint they
glaze or cover. Watercolour gets Rebelle's *re-wet* control and the difference between
wet-into-wet and a glaze; oil gets a working time after which it no longer drags
(ArtRage's wetness). Drying runs as a small compute pass over the wet tiles only, on
frames the display would otherwise skip, and stops when nothing is wet; a "dry the
layer" button and a drying-time setting. Saved in the document? No: a document opens
dry.

**Done** (`drawing-engine-plan.md`, step 9). What changed from the plan: the wet map
holds the time until which paint stays wet rather than an amount, so there is no drying
pass at all — wetness is read off the clock wherever it is needed, and idle frames stay
idle. Re-wet became "blends when wet" on the wash: how much a wash laid into wet paint
mixes as pigment and keeps its edge soft, instead of glazing. Oil's working time is its
wetness times the drying time; Acrylic's is shorter. Smudge and the knife still move
dry paint, on purpose. A water brush and edge darkening on drying wait for step 4.

### 4. Water that moves (large)

The Curtis model, bounded: shallow water (height, velocity) and pigment concentration
on the wet tiles of the layer, advected and diffused a few steps per frame while wet,
with evaporation, the paper's height as slope and absorbency, pigment deposited as water
goes and gathered at the receding edge (edge darkening falls out instead of being
painted on), granulation in the valleys, backruns where a wet stroke meets a drying one,
and tilt from a control (not the Mac's orientation). At half the canvas resolution on
8192², full on 2048². The merge-time "wet" pass of today becomes the sim's initial
condition and goes away. This is the Rebelle-class feature and the one that most
changes what the pen feels; it is also the one to tune by hand longest.

### 5. Bristles (medium)

The tip as a bundle: N bristle sub-dabs whose positions fan out with pressure, separate
with speed, bend with tilt and rotate with the stroke, each carrying its own share of
the load (so a brush loaded with two colours at the edges paints both). Light pressure
leaves the valleys of the paper untouched. Rebelle 8's headline; our scatter and
second-tip machinery is most of the way to it, and the carry of step 1 gives each
bristle its own paint.

### What stays, and small things

- Pigment mixing stays spectral.js (MIT). Expose tinting strength per colour (black is
  too weak today). Mixbox would be a licence negotiation for a marginal gain.
- The display's relief is already lit at the right scale when zoomed out (fourth pen
  session).
- Each step gets goldens of its own scenes and a benchmark line, and the brush-feel
  check is on the pen: these are the brushes whose success is in the hand.

Sizes are relative; steps 1 and 2 are a week each of the kind the engine steps took,
3 half that, 4 three times that, 5 a week.

## Decisions

1. **Order.** The plan says 1, 2, 3, 4, 5: the loaded brush changes every paint stroke
   at once and is mostly existing machinery; thick paint next because Oil is the brush
   named; wetness before water because water needs it and it already gives
   wet-into-wet; bristles last because the carry has to exist first.
2. **How far to take water.** Step 3 alone gives wet-into-wet blends and drying without
   a fluid; step 4 is the fluid. Build 3, paint with it, then decide 4.
3. **Drying time.** Real (seconds, with a slider) or on demand only (a "dry" button and
   nothing moves on its own)? Rebelle does both; the plan says both.

## Risks

- **Performance at 8192².** Steps 1, 2 and 5 are per-dab work in the dirty regions and
  cost what Smudge costs (0.7 ms a frame at 2048² for a fast stroke). Steps 3 and 4 run
  outside strokes on wet tiles; the budget is the idle frames we now skip, and the tile
  bound keeps a canvas-wide wash from costing a canvas-wide sim for long.
- **Patents.** DiVerdi's polygon watercolour is patented; the raster shallow-water
  model is Curtis 1997 and prior art, shipped by several products. Adobe also holds a
  2012 patent on "realistic real-time simulation of natural media paints"; the plan
  stays with the published 1997 and 2004 models and their textbook numerics.
- **Tuning.** Every one of these has a dozen constants that only look right by hand.
  The preview pad and the goldens catch regressions; the pen sessions decide the feel.
- **Documents.** Height is saved; wetness is not; carried paint is per stroke. Nothing
  here changes the file format.

## Sources

- Rebelle 8: <https://digitalproduction.com/2025/10/08/rebelle-8-digital-paintings-physical-upgrade/>,
  <https://www.escapemotions.com/products/rebelle/about>,
  <https://escapemotions.com/products/rebelle/manual/interface/panel-visual-settings>,
  <https://www.escapemotions.com/blog/10-years-of-rebelle-interview-with-developers>
- Fresco: <https://helpx.adobe.com/fresco/using/live-brushes.html>,
  <https://www.expresii.com/blog/adobes-claim-on-frescos-live-brushes>
- Painter: <https://product.corel.com/help/Painter/540213829/Main/EN/Win-Documentation/Corel-Painter-Thick-Paint-Brush-controls.html>,
  <https://product.corel.com/help/Painter/540111155/Corel-Painter-en/Corel-Painter-Artists-Oils-controls.html>
- Procreate Wet Mix: <https://help.procreate.com/procreate/handbook/brushes/brush-studio>
- Curtis et al. 1997: <https://grail.cs.washington.edu/projects/watercolor/paper_small.pdf>;
  GPU thesis: <https://core.ac.uk/download/pdf/4269029.pdf>
- Chu & Tai 2005 (MoXi): <https://isgwww.cs.uni-magdeburg.de/~stefans/npr/entry-Chu-2005-MRT.html>
- DiVerdi et al.: <https://research.adobe.com/publication/a-procedural-watercolor-engine>,
  patent <https://patents.google.com/patent/US8917283>
- IMPaSTo 2004: <https://gamma.cs.unc.edu/IMPASTO/publications/Baxter-IMPaSTo_Web-NPAR04.pdf>
- Wetbrush 2015: <https://sa2015.siggraph.org/en/attendees/technical-papers/event/techpapers/306.html>,
  <https://developer.nvidia.com/blog/worlds-first-real-time-3d-oil-painting-simulator/>
- Stuyck et al. 2017: <https://diglib.eg.org/handle/10.1111/cgf12995>
- Mixbox: <https://github.com/scrtwpns/mixbox>
- Neural Brushstroke Engine 2022: <https://research.nvidia.com/labs/toronto-ai/brushstroke_engine>;
  Splat brushes 2025: <https://github.com/nv-tlabs/SplatPainting>
