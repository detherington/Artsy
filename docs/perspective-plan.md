# Perspective guides

One-, two- and three-point perspective over the canvas. These are guides like the grid
and guide lines: drawn over the picture, never into it, saved with the document. A
stroke can lock onto them, so lines drawn toward a vanishing point run to it, and a
background's buildings, streets and rooms come out in perspective without a ruler.

## What the artist does

- In the Adjust panel, under Guides, taps **Perspective**. If the canvas has no
  perspective yet, two-point perspective appears: a horizon across the middle of the
  screen and a vanishing point near each side. The Adjust panel closes and the
  perspective panel takes the canvas's top-right corner. On the Mac this is also View ▸
  Guides ▸ Edit Perspective.
- While editing, round handles mark the vanishing points and a square marks the middle of
  the horizon. Dragging a point moves it, off the canvas too (zoom out to reach one far
  out). Dragging the square moves the horizon, both points with it, up or down. A press
  anywhere else does nothing, so nothing gets drawn by accident. Two fingers (iPad), or
  Space or ⌥ with a drag (Mac), still move the view.
- The perspective panel holds:
  - **points**: 1, 2 or 3. One point keeps its horizon level. Two points share the
    horizon through them. A third sits above or below, where the verticals meet.
  - **snap**: strokes lock onto the perspective (on to begin with).
  - **level**: puts the second point level with the first, so the horizon is flat.
  - **remove**: takes the perspective away.
  - **done**: ends editing.
- After editing, the lines stay over the canvas, faint, one colour per vanishing point.
  The Adjust panel's rows show or hide them (**Show perspective**) and turn the snap on
  or off (**Snap to perspective**). Hiding the lines also stops the snap. On the Mac,
  ⌘-dragging a point moves it without opening the editor, as ⌘ picks up a guide line.
- **Drawing in perspective** with the brush or eraser: the stroke starts where the pen
  lands. Once the pen has moved about 10 points on the screen, the stroke picks whichever
  perspective line through its start runs closest to the way the pen is going, and stays
  on that line until the pen lifts. The pen can go back and forth along it, and pressure
  and tilt still count. The lines on offer are:
  - one point: toward the point, level with the horizon, and upright;
  - two points: toward either point, and upright (square to the horizon);
  - three points: toward any of the three.
  A tap, or a stroke that never travels that far, stays a dot where the pen landed.

## How it is built

- **`PerspectiveGuide`** (engine, `Drawing/Perspective.swift`): the vanishing points in
  canvas pixels, y up, plus whether the lines are shown and whether they snap. Kept in
  `CanvasGuides.perspective`, which is optional, so documents from before decode with
  none. It can say:
  - which lines a stroke from a point may run along;
  - which of those is nearest a direction;
  - where its handles are, and which one a press is near;
  - how to move a handle;
  - the rays to draw for each point, clipped to a rectangle: spread across the canvas
    as the point sees it, or all round when the point is on it;
  - the horizon line.
- **`PerspectiveStroke`**: one stroke's lock. It starts at the stroke's first sample,
  after any guide-line or grid snap, so a stroke can start on a guide. It keeps later
  samples at that start until they have gone the lock distance (in screen points over
  the zoom), then picks a line and projects every sample onto it. Predicted touches are
  projected the same way without choosing a line. Smoothing runs after the projection,
  and an average of points on one line stays on it. Holding the pen still to snap to a
  shape is off for the stroke, since its line is already straight.
- **Editing** is a mode on the view model (`isEditingPerspective`, not saved; since the
  ruler and ellipse, `editingGuide`, shared with them: see `rulers-and-ellipses-plan.md`). The Mac's
  canvas and the iPad's pass it canvas points on down, drag and up, as they do for the
  Letter tool. A drag changes the guides at once, so the overlays follow it. Edits change
  no pixels, so like the guide lines they take no undo step, but they do mark the
  document changed.
- **Drawn** by the Mac's overlay and the iPad's marks overlay, from the same rays and
  handles, in the shared `PerspectiveStyle`. The iPad overlay now also draws the grid and
  guide lines. It drew neither before, although strokes snapped to them.
- **The grid** was white at 18% on both, so it did not show on white paper. Each line is
  now a dark line a point wide over a light one two points wide (the shared `GridStyle`):
  grey on light paper, pale on dark, both edges on mid tones.

## Status (2026-11-16, branch `perspective-guides`)

- **`PerspectiveTests` (10)**, run in the engine package on the iPad simulator. They
  cover:
  - the lines each kind offers, with none toward a point the stroke starts on;
  - the pen's way choosing the nearest line, in either direction along it;
  - a stroke waiting for 10 screen points (less of the canvas when zoomed in) and then
    keeping to its line;
  - a wandering stroke toward a point drawing exactly along the line to it (no ink
    5.5 px off it, where the wander shows with the snap off), and a leaning stroke held
    upright;
  - predicted touches following the line;
  - only a shown, snapping guide holding a stroke;
  - a stroke that starts by a guide line starting on it;
  - the rays crossing the canvas from a point off it and from one on it, and the
    horizon across it;
  - the handles moving the points and the horizon, levelling, and changing between 1,
    2 and 3 points;
  - editing through the view model: laid out on the screen, picking up and dragging a
    point and the horizon, a press elsewhere picking up nothing, the reach in screen
    points, hidden guides having no handles, removing;
  - saving, with nothing written for a canvas without perspective.
- **`GuidesTests`** gains a Mac overlay test for the rays' colours, the horizon, and
  handles only while editing, and the grid test now checks a grid line shows over white
  and over black.
- **The Mac suite** (2026-11-16): 434 tests, 3 skipped, 0 failures, before the grid
  change; `GuidesTests` (18) again after it, passing.
- **Seen on the iPad simulator:**
  - the Adjust panel's Perspective row closing the panel and laying out two points with
    their handles, horizon square and panel;
  - both points dragged off the canvas, their rays then fanning across it, and the
    horizon reaching out to them while editing;
  - level and done;
  - a wobbly stroke drawn as a straight line toward the left point (logged "in
    perspective: toward point 1");
  - a leaning stroke drawn exactly upright (logged "upright");
  - the Adjust rows ("2-point, move", Show and Snap);
  - reopening the editor keeping the points, and remove.
  - The iPad now draws guide lines (a teal vertical guide was seen), and the grid, which
    shows grey on white paper and pale over a blue fill.
- Both apps build. The Mac app was not tried by hand.

## Not yet

- A tilted horizon in one-point perspective (it stays level with the canvas).
- Curvilinear (four- and five-point) perspective, and ellipses in perspective.
- Perspective guides that belong to one layer or one panel, rather than to the canvas.
- Moving the horizon with a two-finger twist, and undo for guide edits.
