# Comic page templates

A canvas made for a printed comic page: the size of the page with its bleed, and the
page's frame drawn over the canvas, so the artist can see where the printer cuts and
where lettering and faces are safe. The first format is the standard US comic book
page; others (manga B5, European album, digest, webtoon strip) can follow as presets.

## The US comic page

The size Marvel, DC and Image print a single issue at, and the one the common art
templates rule:

| | inches | pixels at 400 dpi |
|---|---|---|
| Full bleed (the canvas) | 6.875 × 10.4375 | 2750 × 4175 |
| Trim (where it is cut) | 6.625 × 10.1875 | 2650 × 4075, 50 px in from each edge |
| Safe area (live area) | 6.125 × 9.6875 | 2450 × 3875, 150 px in from each edge |

The bleed is ⅛ inch past the trim on every side, and the safe area ¼ inch inside it.
Some printers trim at 6.625 × 10.25; the difference is 25 px of height at this
resolution, and the frame is easy to change per preset.

400 dpi, between the 300 a printer asks for in colour and the 600 inked line art is
often drawn at: 11.5 megapixels, less than the Large preset, so it opens on every Mac
and on iPads with the memory for a 4,175-pixel side (`LayerStack.largestCanvasSide`
leaves it out on a device that cannot take it, as with Huge).

## What it is

- **`PageFrame`** (engine, `CanvasGuides.swift`): the trim and safe-area rectangles in
  canvas pixels, and whether they are shown. It lives in `CanvasGuides.page`, so it saves
  with the document's guides; an older document has no key for it and opens with none.
- **The preset** (`CanvasSizePreset.usComic`, shared UI): built from the format in
  inches and a resolution, so the next format is one line. It sits in the preset list,
  so the start screen's tiles, the New Canvas panel and the default-size setting all
  offer it with nothing more.
- **A new canvas at a print format's size gets its frame** (`CanvasSizePreset.page(for:)`),
  wherever the size came from: a tile, the panel, "Same as last", the default size, or
  Custom typed to the same pixels. One rule in the two places a blank canvas is made
  (`AppDelegate.createNewCanvas` on the Mac, `PaintingSession(.blank)` on iPad and
  iPhone) instead of a template threaded through every route to them.
- **Drawn over the canvas, never into it**: the bleed past the trim under a light veil,
  the trim as a solid blue line, the safe area dashed, one point wide at any zoom. On
  the Mac in `SelectionOverlayView` with the guides; on iPad and iPhone in shape layers
  over the Metal view (`PageFrameOverlay`), the first overlay there. Exports and the
  thumbnail are the full bleed, which is what a printer wants.
- **Shown or hidden** from View ▸ Guides ▸ Show Page Frame on the Mac and a Page frame
  row in the Adjust panel's Guides section, both only on a canvas that has one.
- **Not snapped to.** The guide lines catch the pen within a few points; a frame that is
  always there would kink every stroke painted across the page's edges.

## Later

- More formats: manga (B5 with its own trim and safe), European album, digest, magazine,
  a webtoon strip (800 px wide, tall).
- Panel layouts: a page of panel borders drawn on a layer of their own, with gutters.
- Export trimmed to the page as well as with its bleed.

## Status (2026-11-15, branch `comic-templates`)

- Built for the Mac and for the iPad simulator. Five new tests in `GuidesTests` (the
  preset's pixels and frame, the frame for a size, the start screen's tile where it
  fits, the overlay drawing and hiding the frame, guides from before the frame) and the
  document round trip now carries a frame: all pass.
- Full Mac suite: 342 tests, one failure, `ShellTests.testAPenHeldStillIsARightClick`,
  which fails the same way on `main` (the lift after a held pen taps the row), so it is
  not this change.
- Seen on the Mac: a US Comic canvas opens with the veil, the trim and the dashed safe
  area.
- Seen on the iPad Pro 13-inch simulator: the US Comic tile on the start screen; a new
  canvas from it and from Same as last both open with the frame; a saved one reopens
  with it; the frame stays on the canvas through a pinch and a turn; the Adjust panel's
  Page frame row hides and shows it. Two things this found and fixed: the overlay drew
  at one to one, huge, over the start screen while the canvas faded in, before the
  renderer's first frame fitted it (it now waits for `CanvasRenderer.hasInitializedTransform`,
  which is set just before that first fit so the fit is what the overlay sees); and
  zoomed in, its lines ran over the tool rail (the overlay now clips to its bounds).
