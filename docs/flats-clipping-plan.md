# Flats and clipping

How a comic page is coloured: flat colours filled region by region under the inks, then
shading kept inside those flats. Three tools for it.

## Fill from the inks

The bucket fill reads only the layer it fills. For flats it has to read the inks and
paint on another layer under them, so it gains three options (with the tolerance, in the
fill tool's settings):

- **Fill from**: this layer (as before), all visible layers (the picture as it looks), or
  the **reference layer**: a layer marked as the one fills read, in its options in the
  layers panel (one at a time). The inks are marked once; every fill on the flats layer
  reads them, and the colours already laid on the flats do not stop the next fill.
- **Close gaps**, 0 to 10 pixels: a line drawn with a break in it still holds the fill.
  The lines are thickened by that much before the region is found, so a gap up to twice
  as wide is shut; the region is then grown back by the same amount, but only where the
  original lines are not, so the fill reaches the lines and leaks at most that far into
  the gap.
- **Spread**, 0 to 8 pixels: the fill grows past the region's edge by that much, under
  the soft edge of the inks above it, so no pale halo shows between line and colour.

All of it is in the mask the fill already builds on the CPU (`BucketFill.performFill`),
so the GPU side is unchanged: the source texture read is whichever the option names, and
the mask is worked by `FillMask` (pure functions over a byte map: the region, the gap
closing by a separable max filter, the spread), which the tests drive directly.

The options were nowhere to be seen: the tolerance slider sat in a settings view nothing
showed (`BrushSettingsView`, left as it was). The Fill tool now has a panel of its own
over the canvas's top-right corner while it is in use, as the Letter tool does
(`Artsy/UI/FillPanel.swift`, both apps): what it reads (this layer, all layers,
reference, with a note naming the reference or saying none is marked), tolerance, gaps
and spread. Both apps' fill gestures call one engine function,
`CanvasViewModel.bucketFill(at:renderer:)`, which saves the undo step and passes the
options.

## Clipping masks

A layer **clipped** to the one below shows only where that layer has paint: the shading
on a clipping layer stays inside the flat under it. Several clipped layers in a row all
clip to the first unclipped layer beneath them (the base). The clipped layer keeps what
is drawn outside the base, hidden, as other painting apps do; unclipping shows it again.

The compositor draws each layer once, bottom to top. A clipped layer's pass binds its
base's texture too, and the shader multiplies the layer (with the stroke being drawn,
for the active layer) by the base's alpha before its opacity and blend mode. A base that
is hidden hides its clipped layers. The same goes for the thumbnail flattening, merging
down and flattening the stack. The bottom layer cannot be clipped.

## Alpha lock

A layer with its **alpha locked** keeps its transparency: paint changes the colour of
what is there and adds nothing where nothing is. On a flat, shading can be laid on
freely and stays inside it, on the same layer.

- The stroke preview already merges the stroke into the layer's pixel in a shader
  (`strokeOnto`); with the lock, the result keeps the layer pixel's alpha and its colour
  is the merged colour, so the preview shows exactly what the commit will do. The eraser
  does nothing on a locked layer.
- A normal stroke commits by fixed-function blending, which never sees the layer, so on
  a locked layer the commit goes through the shader merge instead, the same function as
  the preview.
- The fill writes its colour with the layer's alpha kept.
- Not yet: the smudge and the water brushes write the layer by their own paths and do not
  keep the lock.

## Saving, undo, the panel

`Layer` gains `isClipped`, `isAlphaLocked` and `isReference`; the document's layer
records and the undo snapshots carry them (an older document opens with all three off),
and duplicating copies them. The layers panel's options for the current layer (where the
blend mode and opacity are) gain three switches: clip to below, lock alpha, reference;
each is a step to undo. A clipped layer's row is indented with a bent arrow; alpha-locked
and reference layers carry a small mark beside their names.

## Status (2026-11-15, branch `flats-clipping`)

- Built for the Mac and iPad.
- `FlatsClippingTests` (14): gap closing on a mask (a break that leaks holds, the fill
  reaches the corners and no way into the break), spread; a fill on the flats reading
  the inks, a second fill replacing the first, reading its own layer, no reference
  marked, reading the picture as it looks; spread under the lines and a break closed on
  real layers; each clipped layer's base; a clipped layer showing only through its base,
  a second over it, released, at its base's opacity, hidden with it; a blend mode within
  the base; the thumbnail flatten, flatten all and merge down keeping the clipping; a
  stroke on an alpha-locked layer in preview and commit, the eraser taking nothing; a
  fill keeping the alpha; the three properties undone, redone, saved and loaded; the
  panel's switches (one reference at a time, the bottom layer never clipped, each a step).
  13 run in the engine package on the iPad simulator (the panel's needs the Mac app).
  The Mac suite on 2026-11-15 (after #88): the panel's test passes. The switches' row
  moved the layers panel's buttons and rows down 38 pt, which the older layers-panel
  ShellTest taps by position, so it tapped the switches; its offsets now count the row.
- Gap closing on a 4441 × 6213 page (the 600-dpi manga page), timed in a release build
  outside the app: about 0.14 s for gaps of 4 or 10 pixels on top of the fill itself.
  The grow back works outward from the region's edge; a pass over the whole canvas per
  pixel of gap would have been billions of checks.
- Seen on the iPad simulator: the fill panel over the canvas's corner with the Fill
  tool (labels fit); the layers panel's clip, lock alpha and reference switches; the
  reference mark on a row and the bent arrow on a clipped one; the note "Reads Panels."
  once the panel borders were marked; a fill on the layer under them, reading them,
  stopping at a panel's border; a layer clipped to that one, filled blue all over, the
  blue showing only inside that panel. Not seen on the Mac, where the same SwiftUI
  views are hosted (the fill panel in the canvas's top-right corner, as the lettering
  panel is).
- Merging a layer that is not clipped down into a clipped one makes it clipped, as it
  becomes part of that layer; merging a clipped layer into its base keeps only what
  showed.

## Not yet

- The smudge and water brushes ignore the alpha lock (they write the layer by their own
  paths).
- Thick paint (the impasto brushes): its height map is written by its own path as the
  stroke goes, so on a locked layer a thick stroke's colour stays on the paint but its
  thickness is laid off it too; and the relief composite (`accumulateHeight`) is not
  clipped, so a clipped layer's thick paint shows its relief outside the base. Neither
  matters for flats and cel shading; both want a clipped height pass.
- Fill options are not remembered between launches (the tolerance never was).
- A lasso fill (fill inside a drawn shape) and fill-by-dragging over several regions,
  the other flatting tools comic colourists use.
