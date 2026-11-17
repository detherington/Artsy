# Hand-drawn balloons

A balloon whose body the artist draws, a loop round where the words will go, which the
app keeps as drawn, wobbles and all. It becomes an ordinary balloon to edit: words typed
into it, moved, restyled, and given the same tail as any other, with its tip, its base
diamond, its pin and its tail shapes. For dialogue, thoughts, shouts and sound effects,
and captions.

## What the artist does

- With the **Letter** tool, draws the balloon's outline on the page in one stroke, round
  where the words go. A tap still places a balloon of the panel's shape, as before. A
  press on empty page with a balloon picked up puts it down; a drag from there draws.
  - The stroke shows as it is drawn.
  - When the pen lifts, a closed loop (or one whose ends come near each other) becomes a
    balloon of the panel's kind, with the outline as drawn. A stroke that doesn't close,
    or is too small to hold a word, makes nothing.
  - **Sound effects**: drawing with the sound kind chosen makes a shout balloon (a burst
    or shout drawn by hand, with a tail). A tapped sound effect stays bare words.
- **A drawn tail**: a point drawn sticking out of the loop, in the same stroke, is taken
  for the tail. It comes off the outline, and the tool's tail goes in its place: its tip
  where the drawn point was, its base as wide as the drawn one where it met the body.
  From then on it is the usual tail (dragged by its tip, widened by its diamond, pinned,
  or made curved, straight, bubbles or lightning). With no point drawn, a balloon that
  speaks gets its tail down and to the left, clear of the body, as a tapped one does.
  Captions have no tail, so a point drawn on one stays part of its outline.
- **The words** wrap to fit inside the outline as drawn. The balloon keeps the size it
  was drawn at. If the words outgrow it, it stretches to hold them, keeping its wobbles,
  and shrinks back to the drawn size, no smaller, as they are cut. The width handle still
  sets where they wrap.
- **The line, fill and tail** come from the panel's look rows as for any balloon: heavy,
  dashed, double, wavy or electric lines; white, cream, yellow, blue, pink or black fills.
  The outline is drawn in the line, so its weight is even. The wobble is the hand's.
- **The shape row** shows a drawn balloon's own outline as its shape, picked. Choosing
  another shape there gives it that shape instead, as one step to undo.
- Moving, restyling (speech, thought, shout, caption), deleting, undo, saving: as for
  any balloon.

## How it is built

- **`DrawnOutline`** (engine, `Lettering/DrawnBalloon.swift`): the outline round the
  balloon's middle, in units of the ellipse inside it, every point on or outside that
  unit ellipse; and that ellipse's radii as drawn, in canvas pixels. `Balloon.drawn`
  holds one, saved only when set, so older documents and builds read as before.
- **Fitting** (`BalloonSketch.fit`) turns the drawn points into a balloon's parts:
  1. The loop is closed where its ends come nearest each other within their first and
     last quarters, trimming an overshoot or bridging a gap up to a quarter of its size.
     Too far apart, or under two and a half lettering sizes across, and it is no balloon.
  2. Resampled evenly, then smoothed lightly. The pen's jitter goes; wobbles a lettering
     size or more across stay.
  3. **A drawn tail**, for the kinds with one: the point of the loop farthest out from
     its middle, measured against an ellipse fitted to the loop, if it is half as far out
     again as the loop's median. Walking from it to where the loop comes back within an
     eighth of that median gives the tail's base. It counts if it is longer than it is
     wide and at least a lettering size and a half long. The tip is the farthest drawn
     point, before any smoothing. The base's width becomes the look's tail base. The
     points between the base's ends come out, and the loop is resampled across the gap.
  4. The middle is the outline's area centroid. Its shape's spread gives the ellipse's
     proportions, and the ellipse is scaled until it touches the outline from inside: the
     ellipse inside it. An outline that pinches in to under a third of its spread there
     is no balloon.
- **Drawing it**: the layout maps the outline onto the ellipse its words need, or the
  drawn one if larger, axis by axis. It draws a smooth closed curve through the points
  (Catmull–Rom as Béziers). That ellipse is the one the tail grows from, so the base's
  ends sit inside the body and the tail joins it as one outline, as for every shape.
  Wavy and electric lines reshape it like any outline. Hit testing and handles come from
  the same layout.
- **The tool**: a press on empty page starts a sketch, kept on the view model
  (`balloonSketch`) for the overlays to draw. It is a tap if the press goes under ten
  screen points in all, and a tap places a balloon when it lifts (it used to place on the
  press). Otherwise lifting fits the sketch, and a fit is placed as one step to undo, "Draw
  Balloon", on the lettering layer as any balloon is, picked up with the keyboard asked
  for.

## Tests to write

- A wobbly loop with overlapping ends fits: its middle, the ellipse inside it touching it
  and inside every point, the wobble kept.
- A loop with a small gap closes; an open arc and a tiny loop do not.
- A loop with a drawn point gives a tail at the point, a base as wide as drawn, and an
  outline without the point; a caption keeps the point in its outline.
- The layout: the body is the drawn shape at the drawn size, words inside it; more words
  stretch it; fewer don't shrink it below drawn; the tail reaches its tip, and the base
  diamond and pin work on it.
- Saving: a drawn outline read back; a balloon without one writes nothing new.
- The tool: a loop drawn on empty page places a drawn balloon as one step, picked up; a
  tap places a plain one on lifting; an open scribble places nothing; drawing with sound
  makes a shout; choosing a shape replaces the drawn outline.

## Status (2026-11-16, branch `hand-drawn-balloons`)

- **`DrawnBalloonTests` (6)**, in both the engine package and the Mac target, cover the
  tests listed above:
  - the wobbly loop's ellipse inside touching it, and its outline within 2.5 px of the
    pen;
  - a seventh-of-a-turn gap closing;
  - the drawn point's tip within 6 px and its base 1 to 3.5 sizes;
  - the body at the drawn size with no words, stretched by a dozen lines and holding
    them, and the tail reaching its tip with a base diamond;
  - the tool: one step, tap on lift, scribble, sound as shout, and shape replacing.
- Tapping now places on the lift. The lettering, look and drawn font tests that pressed
  without lifting now lift. The engine package on the iPad simulator: 333 tests,
  3 skipped, none failing.
- **Seen on the iPad simulator:**
  - the panel's hint;
  - a wobbly loop with a point drawn in one stroke, made a speech balloon (logged "its
    tail drawn, base 2.5 sizes"), picked up, with the keyboard up and its own outline
    picked in the shape row;
  - words typed wrapping inside it at the drawn size;
  - the tail's tip dragged from the lower left to below, the base keeping 82 px, the
    body closing smoothly where the drawn point had been;
  - undone, and Canvas 3 put back to two layers.

  The first two tries left kinks where the point met the loop: the cut stopped too soon,
  and a straight bridge sat inside the body. The cut now runs on to where the loop is
  back at its usual reach and a little beyond. The gap is bridged along the loop's
  ellipse, so the tail leaves a smooth stretch of outline.
- On the Mac, the full suite passes: 440 tests, 3 skipped, none failing.
- Both apps build. The Mac app has not been tried by hand.

## Not yet

- The pen's pressure as the line's weight, for a truly inked line.
- A tail drawn as a separate stroke, and two balloons drawn joined.
- Redrawing part of an outline.
