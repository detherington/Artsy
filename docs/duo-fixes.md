# Three things seen on the iPhone Duo

On 2026-10-29, with build 6 on the iPhone Duo, Darrell sent two screenshots and three
findings: jagged edges on lines zoomed in on a 4096 × 4096 canvas; two nearly parallel
lines with the same brush, one from the Pencil and one from a finger, that did not look
like the same brush; and a crash on opening a Huge canvas from the start screen.

## 1. Jagged edges: the inking brushes had no antialiasing

The ribbon shaders, which draw Hard Round, Technical Pen, Calligraphy, Ink Brush,
Fineliner, Ballpoint, Gel Pen, Sumi-e and the eraser, cut a brush of hardness 0.99 or
more off at the edge with a step function: no antialiasing at all, so every edge was a
staircase of full and empty pixels, plain to see on a large canvas zoomed in and there at
1:1 too. The stamp brushes already softened a hard edge over one pixel. A softer ribbon
had the brush's own falloff, which for a thin line or a nearly hard brush was still less
than a pixel.

`ribbonAlpha` in Shaders.metal now gives the ribbon and its round caps at least one pixel
of antialiasing however hard the brush (`fwidth` of the cross-stroke distance, as the
stamp does), and the stamp's soft disc gets the same floor. A hard brush's edge is where
it was; the pixel it crosses is now covered by the share of it the stroke takes.

`CompositingTests.testHardEdgesAreAntialiased`: a Technical Pen, a Hard Round and a
Calligraphy line at a slant leave pixels of partial coverage all along their edges. The
goldens for the inking brushes change at their edges and were re-recorded after viewing.

## 2. The Pencil on the Duo reports a constant force, not none

The USB-C Pencil has no force sensor. The view had taken a Pencil for one with pressure
if its landing sample read any force at all, on the assumption that a Pencil without a
sensor reads zero. The screenshot says otherwise: the Pencil's stroke with the Oil brush
is sparse and dry, the finger's dense, and the Oil brush dry-brushes at a light touch, so
the Pencil was being drawn at a small constant pressure. A finger's pressure comes from
speed and sits near full when slow.

`PencilForce` in the engine now tells the two apart by what a session sees: a stroke has
pressure of its own once the Pencil's force has been seen to vary, or when its landing
sample's force is an estimate an update is expected to, which a sensor's is. Until then
the pressure comes from speed at a pen's pace, and a stroke that began so switches to the
Pencil's own the moment the force varies (the first stroke of a session with a Pencil that
has a sensor, at its first sample or two). A force that reads the same through thirty
samples in a row says there is no sensor, whatever later landing samples claim; a force
seen to vary is never taken for that. The Soft curve such a stroke starts with is taken
back if the pen turns out to press. The pen-up line in the diagnostics log now carries the
force range a Pencil stroke read ("force 1.00–1.00 of 4.17"), so the next export from the
Duo says what its Pencil reports.

`PenWithoutPressureTests`: a constant force never gives pressure, an estimate expecting
an update does, a varying force does and switches the stroke, a late variation wins over
a steady run, a force of nothing says nothing; and the Soft curve is taken back when the
pen turns out to press, while a curve chosen for the pen stands.

## 3. A Huge canvas on the Duo was killed for its memory

The device's largest canvas came from the GPU's recommended working set, which on a Mac
is what the GPU can hold and on a phone is most of its memory, far past what iOS lets an
app take before it kills it. So the start screen offered Huge (8192 × 8192, 3.8 GB of
textures) and the app died making it; and "Same as last" would have offered it again.

`TextureManager.budget(workingSet:available:physical:)` now takes the smaller of the
GPU's working set and three quarters of what the system says is left to the app
(`os_proc_available_memory`, iOS only), so the canvas, its layers and the undo history
stay under the limit with room for the rest. A phone with 4 GB left offers Large and not
Huge. The start screen leaves out a last size the device cannot take; the iOS app refuses
a new canvas or a document larger than the device takes with a word ("A 8192 × 8192
canvas is more than this device takes: up to 5120 × 5120.") rather than attempting it;
and the diagnostics summary logs the budget, the largest canvas and what is left to the
app.

`ScaleTests.testTheBudgetStaysUnderWhatTheAppMayTake`;
`RecentCanvasesTests.testTheStartScreenOffersThisScreensPixels` gains the dropped last
size.

## Checked on 2026-10-29

- The whole Mac suite: 324 tests, 3 skipped, 0 failures, on the branch `duo-fixes`.
- Goldens: 30 tiles re-recorded after viewing their diffs, every one of them an inking
  brush's edge or what followed from one (the smudge and the knife dragging the paint
  bands' edges, the eraser's rim, the symmetry copies, the everything document's
  ellipse), with the pencil's lightest dabs a touch softer where a dab is under two
  pixels. Soft Round, Watercolor, the soft brushes over dark and the lit relief are
  untouched. Two property tests that compare frame cadences now allow a few 8-bit levels
  on two pixels, which is what a 16-bit blend of antialiased edge pixels comes to; and
  one test that read a pixel 7 px off a line whose antialiased edge is at 7.9 reads it at
  6 px.
- The iOS app builds. On the iPhone Duo simulator the summary line reads "canvas budget
  6144 MB, largest canvas 7424 a side, 0 MB left to the app" (the simulator says nothing
  about what is left), so even there Huge is no longer offered. The Duo itself, which
  does say, will log its own budget and largest canvas; and its pen-up lines will say
  what its Pencil reports ("force …–… of …"), which is the fact the second fix rests on.
  The simulator has no Pencil, so that fix is checked by its tests alone until a
  diagnostics export from the Duo comes.
