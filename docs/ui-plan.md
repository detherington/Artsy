# Artsy's interface, rebuilt for the pen

The drawing engine is where it needs to be (`drawing-engine-plan.md`). The interface
around it is not: it was built for a mouse and a keyboard, and the pen sessions showed
it. This is the plan for replacing it, from the shell inward.

## What is there now

The window is three strips around the canvas, all SwiftUI in `NSHostingView`s, laid out
by `AppDelegate.buildLayout`:

- **A 48 px tool strip on the left.** Eight tool buttons (32 px) with the selection and
  shape modes as 14 px sub-buttons under them; two 20 px colour swatches; a brush-size
  dot; then the brush list — nineteen brushes as 18 px icons in 36×30 buttons, numbered
  1–9, in a `ScrollView`.
- **A 260 px "Inspector" on the right.** Five disclosure sections: Brush (size, opacity,
  pressure curve, smoothing), Symmetry, Layers (rows 24 px tall; blend mode, opacity),
  AI Generate, Stock Images. A "condensed" mode shrinks it to a 48 px icon bar whose
  icons open the same sections as popovers; Tab hides it.
- **A 24 px status bar** of 11 px text: tool, brush, size, zoom, layer, canvas size,
  memory.
- **Popovers** for colour (a 180×160 saturation square, 18 px hue strip, 18–20 px
  swatches, a hex field) and, in condensed mode, for the sections.
- **Separate windows** for the Brush Studio (every setting, as a grouped form) and
  Settings (API keys, tablet, general). A New Canvas dialog.
- **Distraction-free mode** (F): a borderless full-screen canvas with no controls.
- **Keyboard and gestures:** letter keys for tools, `[ ]` for size, 1–5 for brushes,
  Tab for the panel, space to pan, trackpad pinch, rotate and scroll; Return, Escape,
  Delete for transforms and selections.

What the pen runs into:

- **Nothing scrolls under a pen.** `ScrollView` scrolls on scroll-wheel events; a pen
  drag is a mouse drag, which selects. The brush list, the Inspector and every popover
  are stuck wherever the wheel last left them.
- **Targets are mouse-sized.** 14 px mode buttons, 18 px swatches, 10 px chevrons,
  24 px layer rows, 9–11 px type. Procreate's and Fresco's are 44 pt; the pen needs
  that, and so does a 1024×600 pen display (one is attached to the test Mac).
- **The things a painter changes every minute are the furthest away.** Size and
  opacity are sliders in a section of the Inspector; colour is a popover from a 20 px
  swatch at the bottom of the tool strip; the brush is an 18 px icon in a list that
  does not scroll. The Inspector is organised by implementation (sections), not by
  reach.
- **Three ways to hide chrome** (condense, Tab, F) and none of them leaves the pen a
  way back to the brush or colour.
- **Occasional things sit beside constant ones.** AI generation and stock images have
  the same standing as Layers.

## Principles

1. **The canvas is the app.** Chrome is thin, and can go away. Nothing permanent takes
   more than 56 pt of the width, and on a small pen display the whole of it folds to
   two bars.
2. **Everything reachable with the pen alone.** Targets of at least 40 pt; every list
   scrolls by dragging; nothing that needs a hover, a scroll wheel, a right-click or a
   modifier key to find. The keyboard and menus stay for those who have them — it is a
   Mac app — but nothing depends on them.
3. **Brush, size, opacity, colour: one tap, and adjustable without leaving the
   canvas.** These four are in the bar, always, as controls big enough to drag.
4. **Panels are pop-ups, not furniture.** A panel opens over the canvas from the button
   that names it, sized for the pen, and closes on a tap outside or the first stroke.
   The one exception is Layers, which can dock on a big display.
5. **Disclosure by use, not by module.** A brush's settings live with the brush; the
   Studio is one tap further for the rest. Symmetry, guides and the view live together.
   AI and stock images, imports and exports live under one "Add" button.
6. **One visual language.** Dark chrome, one accent, 13 pt minimum for text, 44 pt
   rows, the same spacing everywhere; icons from one set.

## The layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ≡  Untitled ▾        [ ⌇ Sumi-e ▾ ] [ size ───●─── 24 ] [ opacity ──●─ 80% ] ● │ Layers ⧉ Adjust ⊕ Add  ⤢ │
├────┬─────────────────────────────────────────────────────────────────────────┤
│ ✎  │                                                                           │
│ ◫  │                                                                           │
│ ◉  │                                                                           │
│ ⌖  │                                                                           │
│ ▭  │                                canvas                                     │
│ ◇  │                                                                           │
│ ⤡  │                                                                           │
│    │                                                                           │
│ ↶  │                                                                           │
│ ↷  │                                                                           │
└────┴─────────────────────────────────────────────────────────────────────────┘
```

- **Top bar, 44 pt.** Left: a menu button and the document's name (New, Open, Save,
  Export under it, duplicated in the menu bar). Centre, the quick controls: the brush
  (its stroke preview and name; tap for the brush panel), size and opacity as drag
  pills that show the value and the brush circle on the canvas while dragging, and the
  colour (tap for the colour panel; the swatch itself shows foreground over
  background). Right: Layers (with the count), Adjust (symmetry, guides, grid, view
  rotation and flip, canvas background), Add (AI, stock images, import image, import
  brushes), and Hide chrome.
- **Left rail, 56 pt.** Tools as 44 pt buttons: brush, eraser, fill, eyedropper,
  select, shape, transform. A tool with modes (select, shape) shows them in a pop-up
  from a second tap or a long press. Undo and redo at the bottom, since they are the
  most-pressed buttons in any painting app and a pen has no ⌘Z.
- **Pan** is a gesture (space, the middle button, two fingers) and the pen's side
  button where the driver offers it; it stops being a tool in the rail.
- **No status bar.** Zoom shows as a transient label when it changes; canvas size and
  memory move to the document menu and Help ▸ Diagnostics.
- **Hide chrome** (Tab, or the button) hides bar and rail; a small pill with the brush
  and colour stays in a corner, so the pen has a way back. Full screen is the same
  thing in a full-screen window; distraction-free mode merges into it.

### The panels

All of them: 320–360 pt wide, rows and buttons 44 pt, drag to scroll, close on tap
outside or when a stroke starts, keyboard-navigable.

- **Brush.** A category strip (Sketching, Inking, Painting, Erasers, Imported) over a
  grid of brush cards, each a real stroke preview (`BrushPreview` renders them already)
  with the name under it; the current brush marked. Below the grid, the current brush's
  own settings: size, opacity, smoothing, pressure curve, and a Studio button for the
  rest. Long-press a card for duplicate, delete, reset, export.
- **Colour.** A 260 pt saturation square with a hue ring or strip, the current and
  previous colour side by side, 32 pt swatches (recent, then a palette the user can
  edit), the eyedropper, and HSB or hex fields for the keyboard. Alt-tap on the canvas
  still picks a colour.
- **Layers.** Rows 48 pt tall: thumbnail, name, visibility, lock; blend mode and
  opacity for the selected layer above the list; add, duplicate, merge down, delete as
  buttons; drag to reorder (SwiftUI's drag already takes the pen). On a display wider
  than 1600 pt it can dock to the right as a 300 pt panel instead of popping up.
- **Adjust.** Symmetry (off, horizontal, vertical, quad, radial N as 44 pt buttons),
  guides and grid, rotate and flip the view, canvas background, reset view.
- **Add.** AI generate and stock images as sheets (their current views, restyled),
  import an image, import brushes.
- **Brush Studio and Settings** stay windows, restyled to the same language, reached
  from the brush panel and the app menu.

### Sizes

The pen display attached to the test Mac is 1024×600. On it the bar's quick controls
collapse to icons with the value under them, the rail stays, and panels take the
height they need. On the 2304×1296 displays there is room for the full bar and a
docked Layers panel. One layout, two breakpoints, rather than a separate tablet mode.

## Building it

Order chosen so each step leaves the app usable, and so the parts the pen most needs
come first.

0. **Drag-to-scroll everywhere, now.** An `NSScrollView` that turns a mouse drag into
   scrolling (with a tap threshold, momentum, and taps still landing on rows), wrapped
   for SwiftUI, in place of every `ScrollView` in the app. This alone fixes the brush
   list and the Inspector in the current chrome, and every panel in the new one uses
   it. Small; could ship before anything else.
1. **The shell.** Top bar, left rail, canvas, hide-chrome, the end of the status bar
   and of the condensed and distraction-free variants. The old Inspector's sections
   keep working behind the new buttons until each panel replaces them. Medium.
2. **The brush panel**, with previews and per-brush settings; the tool strip's brush
   list retires. Medium to large: the grid, the previews cached per brush and size,
   categories, the long-press menu.
3. **The colour panel.** Medium.
4. **The layers panel** and its docked form. Medium.
5. **Adjust and Add.** Small to medium; mostly moving existing views into pop-ups.
6. **Studio and Settings** restyled; a shortcut sheet (⌘/). Small.
7. **The small-display breakpoint**, with the pen display in hand. Small to medium.

Each step is its own branch and PR, with the view tests extended: the existing
`CanvasViewTests` drive a real `CanvasView` with synthetic pen events, and the same
can drive the new chrome — tap a rail button, open a panel, scroll it with a drag,
pick a brush — so the pen path is tested, not just the mouse path.

## Decisions to make first

1. **Which display is the painting display**: the 1024×600 pen display or the
   2304×1296 screens? It decides the breakpoint that gets built first.
2. **Pop-ups or panels.** Pop-ups from the bar (Procreate's way) are this plan's
   default; a permanently docked right panel (Fresco, Photoshop) is the alternative,
   or a dock that only Layers uses on wide displays. Pop-ups cost one tap to see
   layers; a dock costs 300 pt of canvas.
3. **Bar on top or at the bottom.** On a landscape pen display the bar is better at the
   bottom, nearer the hand; on a desktop it reads better on top. The plan says top, and
   makes it a setting if the small display wants otherwise.
4. **AI and stock images under Add**, one tap further than today. Yes unless they are
   used every session.
5. **Keep the tool keys and number keys as they are**, and add nothing the pen cannot
   do without them. Yes.

## Risks

- **SwiftUI on macOS and the pen.** Drag-to-scroll is not something SwiftUI's
  `ScrollView` offers on the Mac; hence the AppKit scroll view. Pop-ups as `NSPopover`
  close on a click outside, which is what the pen needs. Sliders: SwiftUI's take a pen
  drag fine; the quick-control pills are custom, since they show the value and the
  brush circle while dragging.
- **Stroke previews** for nineteen built-in brushes plus imports, at several sizes, take
  a moment each on the GPU; rendered once and cached on disk, keyed by brush and
  version.
- **Two layouts, one code path.** The breakpoints are the same views with different
  sizes and a collapsed bar, not two apps; the risk is the bar's centre at 1024 pt wide.
