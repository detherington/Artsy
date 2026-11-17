# Speed lines and focus lines

The comic effects drawn as many tapered lines:
- **Focus lines** run in from the edges toward the subject and stop short of it, which
  draws the eye there and gives a moment its punch.
- **Speed lines** run side by side in one direction, which shows motion.

Unlike the guides, these are drawn into the picture. Each set goes on a layer of its own,
so it can be erased into, faded, or put behind a figure.

## What the artist does

- In the Add panel, taps **Focus lines** or **Speed lines** (on the Mac, also Edit ▸
  Focus Lines… / Speed Lines…). The Add panel closes. The lines appear over the canvas
  as a preview in the current colour, round a clear area in the middle of the screen,
  and their panel takes the canvas's top-right corner.
- **The clear area** is an ellipse with the ellipse template's handles:
  - a square at its centre moves it;
  - a ring at the end of its long axis turns it and sets its length;
  - a ring on its short axis sets its width.

  Focus lines run in to its edge, a little short or a little past it, line by line.
  Speed lines run along its long axis, so turning it turns them, and stop at its edge
  so the subject stays clear.
- **The panel:**
  - focus or speed, changeable at any time;
  - **lines**: how many, − and + in steps of 20, from 20 to 400;
  - **width**: how wide the widest line is, − and + a quarter at a time;
  - **variety**: how much line differs from line in length, width and spacing, − and +
    by a tenth, from none to all;
  - **shuffle**: the same settings dealt again;
  - for speed lines, **keep clear**: whether they stop at the clear area or run through
    it;
  - **make**, and **cancel**.
- **Make** draws the lines onto a new layer, "Focus lines" or "Speed lines", above the
  current one, in the current colour, as one undo step. With a selection (Mac), the lines
  are kept inside it, so a selected panel gets its own.
- On the Mac, Return makes them and Escape cancels.

## The lines

- **Focus lines:** one per share of the circle round the clear area's centre, the angle
  jittered by variety. Each is a wedge: wide where it leaves the canvas and pointed at its
  inner end. The inner end is on the clear area's edge, pulled back toward the canvas's
  edge by up to 60% of the run with full variety: most a little, a few a long way, as
  inked ones are. Its width is cut by up to 70% with variety.
- **Speed lines:** spread evenly across the canvas square to their direction, the spacing
  jittered by variety. Each is a spindle, pointed at both ends and widest in the middle,
  between 35% and 100% of the canvas's length that way (shorter with variety), placed at
  random along it. Where one would cross the clear area, the parts outside it become
  spindles of their own.
- All of it comes from a seed through a small fixed random generator, so a preview and
  the layer made from it are the same lines, and shuffle deals new ones.
- The geometry is plain shapes in canvas pixels, y up. The overlays draw them as the
  preview, and Core Graphics fills them into the layer's image.

## How it is built

- **`ComicLines`** (engine, `Drawing/ComicLines.swift`): the kind, the clear area (an
  `EllipseGuide`), count, width, variety, keep clear and the seed. It can make the
  shapes for a canvas, draw them into an image, and add that image as a layer (as
  `PanelLayout` does for panels).
- **Laying them out** uses the drawing guides' editing:
  - `editingGuide` is `.lines` while `comicLines` (not saved) holds them;
  - the handle calls move the clear area;
  - `startLines`, `makeLines` and `cancelLines` on the view model.
- **The preview** is drawn by both overlays from shared marks (`ComicLinesStyle`): the
  lines in the current colour, a little faint, kept to the canvas, and the clear area
  dashed, with its handles.
- Defaults: focus lines 120 at 0.6% of the canvas's short side, speed lines 80 at 0.5%,
  variety 50%.

## Status (2026-11-16, branch `rulers-and-ellipses`, after the ruler and ellipse)

- **`ComicLinesTests` (6)**, in both the engine package and the Mac target:
  - focus lines run from beyond the edge to the clear area's edge, aimed at its centre,
    pulled back no more than variety allows, and with variety off, exactly to the edge
    and all as wide;
  - the same seed gives the same lines, and shuffle gives others;
  - speed lines run along the clear area's axis across the whole canvas, with no stubs
    and none crossing the clear area, though some do once keep clear is off;
  - the settings' steps stay in range;
  - making them adds a layer named for them above the current one, in the current colour,
    with ink at the edges and none in the clear area, and one undo takes it back;
  - a selection in one corner gets lines and the rest of the canvas none;
  - laying them out through the view model: placed on the screen, the clear area moved
    by its handle, the guides' handles out of reach, the document not marked changed,
    the kind changed keeping the rest, and cancelling.
- **`GuidesTests`** gains a Mac overlay test for the preview: red lines at the edge, the
  clear area clear, its handle white, and nothing once let go.
- Seen on the iPad simulator:
  - the Add panel's Focus lines and Speed lines rows;
  - the preview of each, round the dashed clear area, with the panel;
  - switching kind;
  - variety raised to 70%;
  - each made onto a third layer, matching its preview, with the log noting the undo
    step "Add Focus lines" or "Add Speed lines" and the lines drawn;
  - both undone.

  The first preview spilled past the canvas and its focus lines all ended at much the
  same distance from the clear area. The preview is now clipped, and the ends pull back
  by a share of the run.
- The engine package on the iPad simulator: 344 tests, 3 skipped, none failing. On the
  Mac, `GuidesTests` and `ComicLinesTests` pass (26).
- Both apps build. The Mac app was not tried by hand, and the rest of the Mac suite has
  not run.

## Not yet

- Lines along a curve, and lines bunched into groups.
- White-edged lines over a dark picture.
- Clipping to a panel on iPad, which has no selection yet.
