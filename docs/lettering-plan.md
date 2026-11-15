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

## Later

- An OFL lettering face bundled with the app.
- Balloons joined by a connector, double balloons, whisper (dashed) and radio (jagged
  tail) styles; captions in a colour.
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
