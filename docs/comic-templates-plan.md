# Comic page templates

A canvas made for a printed comic page: the size of the page with its bleed, and the
page's frame drawn over the canvas, so the artist can see where the printer cuts and
where lettering and faces are safe. The first format is the standard US comic book
page; the second a manga page (B5), and beside them a webtoon strip, which is a size
for the screen with no page to frame. Others (European album, digest) can follow.

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
and on any device that takes a canvas of that many pixels (see "Fitting a device").

## The manga page

A page as a Japanese magazine prints it, and as Clip Studio's comic setup and the
common manuscript templates lay it out:

| | millimetres | pixels at 400 dpi |
|---|---|---|
| Full bleed (the canvas) | 188 × 263 | 2961 × 4142 |
| Trim (B5) | 182 × 257 | 2866 × 4047, about 47 px in from each edge |
| Inner frame (the safe area) | 150 × 220 | 2362 × 3465, about 299 px in at the sides, 339 at the head and foot |

The bleed is 3 mm (Clip Studio offers 3 or 5). The inner frame (基本枠) is where the
panels sit; it is not the same distance in on every side, so `PageFrame` gained an
initialiser from the trim's and safe area's sizes, each centred, and `printPage` now
takes the safe area as a size (the US page's is 6⅛ × 9¹¹⁄₁₆ inches, the same frame as
before). One template gives the B5 inner frame as 152 × 227 mm; printers' own sheets
win, and the numbers are one line.

400 dpi as the US page. Publishers ask 600 for black-and-white manga; a 600-dpi page is
4441 × 6213, 27.6 megapixels, which most iPads would not offer, so that is a choice to
make per artist rather than the preset's.

## The webtoon strip

1600 × 7680, no frame. WEBTOON shows a strip 800 pixels across and takes uploads of up
to 800 × 1,280 each; the strip is drawn at twice that width, to halve on export, and is
three of those uploads tall at that scale. It stops at 7,680 because no side may pass
8,192 (`LayerStack.maxCanvasSide`); a longer episode is several canvases.

## Fitting a device

A device's cap was its largest square canvas, `LayerStack.largestCanvasSide`, applied
to the longest side: a 1600 × 7680 strip, 12.3 megapixels, was refused by a device with
a 4 GB budget, whose square is 5,888 a side (34.7 megapixels). The memory goes by the pixel, and that side
is itself a square root of pixels, so a canvas now fits when it has no more pixels than
that square and no side past 8,192 (`LayerStack.fits`). The start screen's tiles, the
New Canvas panel's presets and the iPad's check before making or opening a canvas use
it; squares fit exactly as before. The Custom fields still clamp each side to the
square's side.

## What it is

- **`PageFrame`** (engine, `CanvasGuides.swift`): the trim and safe-area rectangles in
  canvas pixels, and whether they are shown. It lives in `CanvasGuides.page`, so it saves
  with the document's guides; an older document has no key for it and opens with none.
- **The presets** (`CanvasSizePreset.usComic`, `.mangaB5`, `.webtoon`, shared UI): a
  print format built from its sizes in inches (`millimetres(...)` converts) and a
  resolution, so the next format is one line. It sits in the preset list,
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

- More formats: European album, digest, magazine; the manga tankōbon (B6, or 5 × 7½
  inches in the US editions); a 600-dpi manga page for black and white.
- Webtoon: marks at each upload slice, and an export that slices.
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

## Status (2026-11-15, branch `manga-webtoon`)

- Manga B5 and Webtoon presets, `PageFrame(canvasSize:trim:safe:)`, and `LayerStack.fits`
  in the start screen, the New Canvas panel and the iPad's size check. Four new tests
  (the manga page's frame, the webtoon's strip, the formats on the start screen by
  pixels, `fits` itself); the full Mac suite runs 345 with only the known
  `ShellTests.testAPenHeldStillIsARightClick` failing.
- Seen on the Mac: all three formats on the start screen, and the New Canvas panel
  growing to its fifth row of presets (360 × 535) with nothing cut off.
- Seen on the iPad Pro 13-inch simulator, whose cap is 7,424 a side: the Manga B5 and
  Webtoon tiles (the strip would have been left out by the old longest-side rule); a
  manga canvas with its inner frame deeper at the head and foot than at the sides; a
  webtoon canvas with no frame, which takes a stroke.
