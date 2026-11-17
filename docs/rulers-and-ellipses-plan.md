# Rulers and ellipse templates

A ruler and an ellipse template over the canvas, like the ones on a drawing board: a pen
laid against the edge runs along it. They are drawing guides, like perspective: drawn
over the picture, never into it, saved with the document, moved by handles in an
editor of their own.

## What the artist does

- In the Adjust panel, under **Drawing guides** (the section perspective is in), taps
  **Ruler** or **Ellipse**. The first time, one is laid out in the middle of the screen:
  - the ruler across the middle, three fifths of the screen wide;
  - the ellipse in the middle, two fifths of the screen wide, at 30° (see below).

  The Adjust panel closes and the guide's own panel takes the canvas's top-right corner,
  as perspective's does. On the Mac this is also View ▸ Guides ▸ Edit Ruler / Edit
  Ellipse.
- **Moving the ruler:** a round handle at each end moves that end, which turns and
  lengthens the ruler. A square in the middle moves the whole ruler.
- **Moving the ellipse:**
  - a square at the centre moves it;
  - a round handle at the end of its long axis turns it and sets its length;
  - one at the end of its short axis sets how wide it is across.

  Its two axes show faintly while it is edited.
- A press anywhere else does nothing while editing, so nothing gets drawn by accident.
  Two fingers (iPad), or Space or ⌥ with a drag (Mac), still move the view. On the Mac,
  ⌘-dragging a handle moves it without opening the editor, as for the vanishing points.
- **The ruler's panel:**
  - its angle on the canvas (0° level, 90° upright);
  - **straighten**: turns it about its middle to the nearest 15°;
  - **snap**: strokes run along it (on to begin with);
  - **remove** and **done**.
- **The ellipse's panel:**
  - its degree, as an ellipse template marks its sizes: the angle a circle is seen at
    for it to look like this ellipse, from 5° (nearly flat) to 90° (a circle). **−** and
    **+** change it by 5°, keeping the long axis;
  - **straighten**: turns its long axis to the nearest 15°;
  - **every size**: off, only a stroke laid against its outline follows it. On, a stroke
    anywhere follows the ellipse of the same shape and angle through where it lands,
    like a template's row of sizes (wheels, rims, a cylinder's rings);
  - **snap**, **remove** and **done**.
- After editing, the guides stay over the canvas in violet. The Adjust panel's rows show
  or hide each one and turn its snap on or off, as for perspective.
- **Drawing against them** with the brush or eraser:
  - **The ruler:** a stroke that lands within about 16 screen points of the ruler starts
    on it and runs along its line, past its ends too, until the pen lifts.
  - **The ellipse:** a stroke that lands within the same reach of its outline runs round
    it. With every size on, a stroke landing anywhere else runs round the ellipse of its
    shape through that point.
  - If a stroke lands within reach of both, the nearer one takes it.
  - Otherwise perspective holds the stroke as before, if it is on.
  - Pressure and tilt still count. Holding the pen still to snap to a shape is off for
    such a stroke.

## How it is built

- **`RulerGuide`** and **`EllipseGuide`** (engine, `Drawing/Ruler.swift`,
  `Drawing/EllipseGuide.swift`): canvas pixels, y up, with whether each is shown and
  snaps. They are kept in `CanvasGuides.ruler` and `CanvasGuides.ellipse`, both
  optional, so older documents decode with none. Each can say:
  - how far a point is from it;
  - where a point goes on it: square onto the ruler's line, or the nearest point on the
    ellipse;
  - its handles, which one a press is near, and how to move it.

  The ellipse's nearest point is a few rounds of a quarter-ellipse iteration, exact to
  well under a pixel.
- **`HeldStroke`** replaces the perspective-only hold. It is chosen once, where the stroke
  lands, after any guide-line or grid snap:
  - a ruler or ellipse within reach, the nearer;
  - else the ellipse at every size;
  - else perspective.

  Each sample is placed on it. For the ellipse, the smoothed sample is placed on it again,
  since smoothing a curve cuts inside it. Predicted touches are placed the same way, and
  so is the catch-up point when the pen lifts.
- **Editing** is one mode for all three drawing guides: `editingGuide` (perspective,
  ruler or ellipse, not saved) in place of `isEditingPerspective`. The platforms pass
  canvas points to one set of handle calls, and the handles picked are those of the guide
  being edited (on the Mac's ⌘-press, any shown guide's). Edits mark the document changed
  and take no undo step, like the other guides.
- **Drawn** by the Mac's overlay and the iPad's marks overlay from the same paths and
  handles, in the shared `RulerStyle`: violet lines, white handles ringed in violet, a
  square for moving the whole guide.

## Status (2026-11-16, branch `rulers-and-ellipses`)

- **`RulerAndEllipseTests` (11)**, in both the engine package and the Mac target:
  - the ruler's projection, angle, distance and straightening, and its handles;
  - the ellipse's nearest point, checked on it and against 20,000 points round long,
    tall, round and very flat ellipses;
  - the ellipse's frame, scale and distance;
  - its degree steps, handles and straightening;
  - a wandering stroke drawn exactly along the ruler, past its end;
  - a wandering stroke drawn exactly round the ellipse, no ink 5.5 px outside or inside
    it, so smoothing cut no corner; with the snap off the wander shows;
  - which guide takes a stroke;
  - the view model starting a stroke on the ruler and keeping predicted touches on it
    and on an every-size ellipse;
  - editing through the view model;
  - saving, with nothing written when there is none.
- **`PerspectiveTests`** moved to the shared editing calls; all 10 pass.
- **`GuidesTests`** gains a Mac overlay test: the ruler and ellipse in violet, the other
  sizes only with every size on, and handles only on the guide being edited.
- The engine package on the iPad simulator: 338 tests, 3 skipped, none failing.
- On the Mac, `GuidesTests`, `PerspectiveTests` and `RulerAndEllipseTests` pass (40
  tests). The rest of the Mac suite, ShellTests among them, has not run.
- **Seen on the iPad simulator:**
  - the Adjust panel's Drawing guides rows ("22°, move", "35°, move", Show and Snap);
  - the ruler laid out, an end dragged to turn it to 22°, the panel's angle following,
    done;
  - a pencil stroke wobbling up to 10 points off drawn straight along the ruler and on
    past its end (logged "along the ruler");
  - the ellipse laid out at 30°, moved, + to 35°, turned by its axis ring;
  - a wobbling stroke drawn round three quarters of it, on its outline (logged "round
    the ellipse");
  - every size on, with its fainter half-size and 1.5× ellipses, and a stroke started
    inside drawn round the 0.70× ellipse (logged "round the ellipse at 0.70×");
  - both removed and the strokes undone, Canvas 3 blank again.
- Both apps build. The Mac app was not tried by hand.

## Not yet

- More than one ruler or ellipse at a time.
- A ruler that holds every stroke parallel to it, and one that bends (a French curve).
- An ellipse laid into the perspective (fitted to a square in it).
- Undo for guide edits.
