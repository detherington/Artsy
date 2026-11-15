# Lettering and balloons

The words of a comic, set on the page and kept editable: speech, thought and shout
balloons with tails that point at whoever is talking, caption boxes, and free sound
effects, on a layer of their own over the art.

## What the artist does

- Takes the **Letter** tool (the speech-bubble button in the rail; L on the Mac).
- Taps the page where a balloon goes: a balloon appears there in the style last used,
  with its tail down and to the left, and the lettering panel's text box takes the
  keyboard. Typing fills the balloon, which grows around the words.
- Drags a balloon to move it, its tail's tip to point it, and the handle on its right to
  change how wide the words run before they wrap.
- Taps a balloon to pick it up again; taps the page away from it to put it down; taps
  the page again for a new one.
- In the lettering panel (over the canvas's top-right corner while the tool is in use):
  the style (speech, thought, shout, caption, sound), the lettering face, the size, all
  capitals (on by default, as comics are lettered), the tail on or off, and delete.

## How it is built

- **`Balloon`** (engine, `Lettering/Balloon.swift`): a value, Codable, in canvas pixels
  with y up as the guides are: its centre, its words, the width they wrap at, the style,
  the face, the size, capitals, and the tail's tip (nil for none).
- **`BalloonLayout`**: everything drawn follows from a balloon by one function. The
  words set with Core Text at their wrap width; the body around them (an ellipse through
  the corners of the words' box and a margin for speech; a cloud of bumps for thought; a
  jagged star for a shout; a box for a caption; nothing for a sound effect); the tail, a
  curved wedge from the body's edge to the tip (three shrinking bubbles for thought),
  joined to the body as one outline (`CGPath.union`) so no line crosses where they meet.
  Hit testing and the handles come from the same layout.
- **Faces** are the system's, on both the Mac and iPad, so nothing is bundled or
  licensed: Chalkboard SE Bold for dialogue, Noteworthy Bold for a hand, Marker Felt Wide
  for shouts and effects, Avenir Next Condensed Demi Bold for clean captions. A lettering
  font of its own (an OFL face) can be added later.
- **The lettering layer**: a layer whose `lettering` holds its balloons. Its pixels are
  drawn from them and nothing else: white bodies, black outlines and words. It is created
  at the top of the stack, named "Lettering", and locked so a brush cannot paint into
  what the next change would redraw. Placing a balloon does not change the current
  layer, so drawing goes on where it was.
- **Drawn by region**: a change redraws only the rectangle the balloon was in and is in
  now (every balloon that touches it, clipped to it) and uploads that rectangle into the
  layer's texture, so dragging stays quick on a 600-dpi page; a full redraw is the same
  call with the whole canvas.
- **Saved** in the document's layer records, as the guides are: a document from before
  has none. The PNG of the layer is saved as for any layer, so another app sees it.
- **Undo**: a layer snapshot carries its balloons as it does its name and lock, so a
  step brings back both the words and the pixels. One gesture is one step: the step is
  saved on the first change, not on a tap that only picks a balloon up. Typing into one
  balloon is one step until something else is done.
- **The tool** is driven from the engine (`CanvasViewModel+Lettering.swift`): the Mac's
  canvas and the iPad's pass it canvas points on down, drag and up, as they do strokes.
  The selected balloon's box and handles are drawn by the Mac's overlay and the iPad's
  marks overlay.

## Shapes and styles (branch `balloon-looks`)

Each kind of balloon comes in more than one shape, and any balloon can be inked another
way: a whisper's dashes, a radio's zigzag, a narrator's yellow box, a monster's black
balloon with white words.

### What the artist does

- In the lettering panel, under the kinds, four rows choose the balloon's **look**, each
  choice a small picture of the balloon as it would be:
  - **shape**, by kind. Speech: oval, rounded, box, wobbly (drawn by hand). Thought:
    cloud, puffy, oval. Shout: burst, jagged (a rough edge, for anger), blast (uneven
    spikes, for an explosion). Caption: box, rounded, slanted, notched.
  - **line**: solid, heavy, dashed (a whisper), double, wavy (a weak or trembling
    voice), electric (a zigzag edge, for a radio, phone or robot), none.
  - **fill**: white, cream, yellow, blue, pink, black (its words then white).
  - **tail** (for the kinds with one): curved, straight, bubbles, lightning (a zigzag,
    for a voice from a speaker). Choosing one puts a tail on a balloon that had none.
  - **width**: the tail narrower or wider, 30% to 300% in steps of a quarter (its base,
    a lightning band, the bubbles' size). And, with a balloon picked up, **tip**: pins
    the tail's tip where it is on the page, on its speaker, so moving the balloon leaves
    the tip there and the tail stretches back to it; unpinned, the tip goes with the
    balloon as before. A pinned tip's round handle has a ring (iPad) or dot (Mac) in it,
    and is still dragged to point it.
- With a balloon picked up, a choice changes it as one step to undo. With none, it sets
  the next balloon of that kind: each kind keeps the look last given to one, so captions
  stay yellow while speech stays white.
- Changing a balloon's kind gives it that kind's shape and tail; its line and fill stay.

### How it is built

- **`BalloonLook`** (engine, `Lettering/BalloonLook.swift`): shape and tail shape
  (each nil for the kind's own), line and fill. A `Balloon` carries one; it is saved
  only where it is not the plain look, so documents from before read as they were and
  older builds ignore it. A shape the kind does not offer reads as the kind's own.
- **The shapes** are drawn by the same layout as before: the defaults (oval and curved
  tail, cloud and bubbles, burst and straight tail, box) are exactly the shapes balloons
  had, so nothing already lettered moves. Boxes and rounded boxes sit round the words
  with a margin; a slanted caption leans its sides; the irregular shapes (wobbly, jagged,
  blast) are seeded from the balloon's id, as the cloud is, so each keeps its own outline.
- **Tails** grow from the ellipse inside the body, as before, for any shape: the wedge,
  straight or curved; the bubbles from where the line to the tip leaves the body; the
  lightning a zigzag band that tapers to the tip.
- **Lines**: dashed, double and heavy are how the outline is stroked (double is a wide
  black stroke with a thin one in the fill over it). Wavy and electric reshape the
  body's outline before its tail joins it: the outline flattened, resampled evenly and
  moved in and out along its normals, a whole number of waves round each loop, sized by
  the line's width so they read at any size. None leaves the fill alone.
- **The panel's pictures** are drawn by the engine (`BalloonLayout.preview`), a balloon
  with no words fitted into the cell, laid out in points so its line is at least a point
  and a half, on a tile of paper so a black line shows on the dark panel; they show the
  real shapes in the current look. A choice edits the balloon's look as it is when
  tapped, not as the panel last drew it, so quick choices in a row each keep.
- **Tail width** is part of the look (`tailWidth`, saved when not 1): the base's spread
  round the ellipse, which the lightning band follows, and the bubbles' radii. **A pinned
  tip** is the balloon's (`tailPinned`, saved when set): a move of the body leaves its
  tip where it is.

## Status (2026-11-15, branch `balloon-looks`)

- `BalloonLookTests` (14): the plain look draws every kind exactly as main at dce006a
  did (path signatures measured there), so nothing lettered moves; every kind's every
  shape in every line holds its words, wide or in a tall narrow block; a shape a kind
  lacks reads as its own; the irregular shapes are each balloon's own; every tail of
  every shape reaches its speaker and stops there, none from a tip inside; lightning
  zigzags; widths scale the wedge, the lightning band and the bubbles; the lines (heavy
  twice as wide, double reaching further, wavy and electric moving the outline in and
  out); fills and white words in a black balloon, dashes with gaps, no line, read back
  from pixels; the panel's pictures; saving, the plain look saving nothing and an
  unknown shape reading as plain; each kind keeping its look for the next; changing kind
  keeping the ink; a pinned tip staying as the balloon moves, still pointed by its
  handle, pin and unpin as steps. With `LetteringTests` (12) all pass in the engine
  package on the iPad simulator.
- Contact sheets rendered of every shape, line, fill, tail and width; the first wobbly
  oval was too even and the first lightning tail crossed itself, both redrawn. Seen on
  the iPad simulator: the panel's rows, a balloon given a rounded shape, an electric
  line, a yellow fill and bubbles, and a pinned tip staying put as its balloon moved.
- A first reading of "pin a start point" pinned where the tail leaves the balloon; Darrell
  meant the tip, so that was taken out.

## Later

- An OFL lettering face bundled with the app.
- Balloons joined by a connector, double balloons.
- Sound effects in a colour with an outline; a drop shadow; fills in any colour.
- Text along a path for sound effects; bold and italic within a balloon.
- Moving lettering between pages, and exporting it as its own layer for a translator.

## Status (2026-11-15, branch `lettering`)

- Built for the Mac and iPad. `LetteringTests` (12): the faces resolve on the platform,
  a speech balloon holds its words and reaches its speaker, wrapping, each style's body,
  the thought cloud's irregular, repeatable scallops, capitals, Codable; the tool placing
  on a locked lettering layer at the top without changing the current layer, putting down
  and placing again, undo of placing (the layer goes with the first balloon), moving with
  the tail and one-step undo, the tail and width handles, picking up as no step, typing
  folded into one step, size and delete as steps; balloons saved and loaded with the
  document. All 12 pass on the Mac and in the engine package on the iPad simulator. The
  full Mac suite, after the cloud's redraw: 366 tests, only the known
  `ShellTests.testAPenHeldStillIsARightClick` failing.
- **The thought balloon** was first a ring of equal circles, which Darrell rightly called
  too symmetrical. It is now scallops of uneven widths and heights round a slightly
  irregular ellipse, each a cubic bulge meeting the next in an inward point, seeded from
  the balloon's id (`BalloonRandom`, SplitMix64 over an FNV hash of the UUID) so a balloon
  keeps its cloud on every launch; trailing ovals laid out by the room to the thinker:
  three, two smaller, or one.
- Seen on the iPad simulator: the tool in the rail, a balloon placed and typed into at
  once (the text box takes the keyboard 150 ms after the balloon appears; the canvas's
  single-key tool shortcuts stand down while a balloon is held), words wrapping, the style
  changed to shout and thought, the tail dragged, a saved balloon reopened. Rendered: all
  five styles. On the Mac, the tool, the panel and a placed balloon, before Darrell took
  over testing by hand.
