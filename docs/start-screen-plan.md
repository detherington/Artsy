# The start screen

Where each app lands at launch, and where it goes back to when nothing is open. Today
the Mac launches into the New Canvas panel (or straight to a default canvas, by
preference) and quits when its last window closes; iPad and iPhone launch into the
system document browser, a Files window with an Artsy title. Neither shows the work
in progress, and neither gets a first stroke down in one tap.

## What it should do

One screen, `StartView`, in the shared UI folder so both apps draw it, in the chrome's
dark palette. Three things on it, in this order of weight:

1. **Recent canvases**, a grid of thumbnails. Every `.artsy` package already carries a
   `thumbnail.png` (the flattened canvas over white, at most 512 px a side, written on
   every save), so the grid costs nothing to make. Each tile: the thumbnail at its own
   aspect, the name, the size in pixels, when it was last opened. Tap to open. A long
   press or secondary click: Reveal in Finder / Files, Rename, Remove from recents.
   A canvas that has moved or gone shows dimmed with "not found" and can be removed.
2. **New canvas**, a row of size tiles that open a canvas in one tap: the size used
   last first ("Same as last", with its pixels), then the presets the device takes
   (Medium, HD Landscape, A4 at 300 dpi…), each tile drawn at its aspect, and
   "Custom…" opening the existing `NewCanvasView` with the width and height fields.
3. **Open…** (the open panel on the Mac, the document browser on iPad and iPhone, which
   is where iCloud Drive and other providers stay reachable) and **From a photo…**,
   a canvas at the photo's size with the photo as its first layer, from Photos or a
   file. The photo route is a later step; the import it needs is checked first.

Empty, the screen says so once ("Your canvases will appear here") under the New row.

### The Mac

A window, not a panel: "Start", 860 × 600, resizable, opened at launch unless files
were double-clicked or the "skip the dialog" preference is on (which still goes
straight to a canvas at the default size, as now). Closing the last canvas window
brings Start back instead of quitting; closing Start quits, as the empty app does
today. File ▸ New Canvas… keeps opening the size dialog; a new Window ▸ Start (⇧⌘N)
shows the screen with canvases open. The File menu also gains Open Recent, the
standard submenu, fed from the same list, since the app has never had one.

### iPad and iPhone

Start is the root screen, in place of the document browser. A canvas opens over it
full screen as now and closing it comes back here. New canvases are written to the
app's own Documents folder, named "Canvas 1", "Canvas 2"…, and so appear in Files
under On My iPad ▸ Artsy without the browser's "where shall I put it" step; Rename on
the tile renames the file. Browse… presents the document browser for opening or
importing from iCloud Drive and other providers; a document opened that way is kept
in the list by a security-scoped bookmark, as `PaintingSession` already holds its
scope while open. On the phone the New row scrolls sideways and the grid is two
across. An iCloud container for the app's own folder, so the Mac and the iPad see one
set of canvases, is a step of its own (an entitlement on both apps and a migration).

### The list behind it

`RecentCanvases` in the engine's utilities: an ordered list of entries (a bookmark,
the name, the pixel size, the last-opened date), at most 40, in Application Support
as JSON, resolved lazily so a missing file dims rather than fails. Written whenever a
document is opened, created or saved; read by Start and the Mac's Open Recent.

## Steps

1. `RecentCanvases` and `StartView` with the recents grid and the New row, tested
   with a temporary store (entries added, ordered, capped, a missing file dimmed, a
   thumbnail read).
2. The Mac: the Start window at launch and after the last canvas closes, Window ▸
   Start, File ▸ Open Recent, the list fed from open, create and save.
3. iPad and iPhone: Start as the root, the browser behind Browse…, new canvases in
   Documents with Rename, bookmarks for documents from elsewhere; the phone layout.
4. From a photo…, once the image import is checked.

## Checked on 2026-10-27

Steps 1 to 4 built on the branch `start-screen`.

- **The list.** `RecentCanvases` in the engine's utilities: entries with a bookmark
  (security-scoped on the Mac), the path when last seen, the name, the pixels and the
  date; `note` on open, create and save; `moved` for a rename; `url(of:)` reads only, so
  a tile can ask off the main thread. Tests in `RecentCanvasesTests`: newest first, one
  entry a document, capped, back after a relaunch, a deleted document's URL and
  thumbnail nil, a renamed one keeping its place.
- **The screen.** `StartView` in the shared UI folder, the same file in both apps. Its
  test puts it in a window at 860 and at 360 wide and renders the layer tree (a hosting
  view's `cacheDisplay` misses the thumbnail image; `layer.render(in:)` has it): the
  size tiles' swatches and the package's red thumbnail are on the screen, and nothing
  red with an empty list.
- **The Mac.** The Start window at launch (unless files were double-clicked or the
  skip preference is on), back when the last canvas closes and not while quitting,
  closed when a canvas opens from it; Window ▸ Start (⇧⌘N); File ▸ Open Recent with
  Clear Menu; the dialog's Cancel and the open panel's Cancel land on Start when
  nothing is open; a recent opened from the list under a security scope that is
  dropped when its window closes, for the App Store build. The Mac suite: 293 tests,
  3 skipped, 0 failures. The window was launched and seen only through its tests and
  the iPad's identical view: this Mac has no screen-recording permission for a capture.
- **iPad.** On the iPad Pro 11-inch (M5) simulator: the screen as the root with the
  sizes, the empty state and Browse…; "Same as last" made "Canvas 1" in Documents and
  opened it in one tap; the bar menu's "Start" (was "Documents") came back to the screen
  with the canvas's thumbnail, its pixels and "1 second ago"; the list survived a
  relaunch; a long press gave Show in Files, Rename… and Remove from Recents; Browse…
  presented the Files browser with a Close button that came back to Start. Not tried:
  Rename's alert, Show in Files, a document picked in the browser, the phone layout
  on a device (the 360-wide render test covers its row and grid).
- **From a photo…** (step 4). `PhotoCanvas` in the engine: the photo decoded through
  ImageIO's thumbnail path with its orientation applied, so a phone's portrait shot
  comes up upright, and held to the device's largest canvas without ever being
  scaled up; a canvas of its size (at least 64 a side); the photo as a layer just
  above the background, fit to the canvas, with the layer that was active moved up
  and left as the one to draw on. The renderer's fit-to-canvas fill now takes a
  `CGImage`, and its `Data` version decodes through the same oriented path, which
  also rights the iPad's Import Image. On the Mac the button opens the image panel
  and the window takes the file's name; on iPad and iPhone it is a menu, Photos…
  (the photo picker) and Files… (the document picker, as a copy). A photo's size is
  not remembered as "Same as last". Tests in `PhotoCanvasTests`: a JPEG tagged with
  orientation 6 comes out turned, its red corner where it should be, held to 150 a
  side when asked and never grown, 64 at least, junk data nil; placed on a harness
  canvas it is layer 1 of Background, photo, Layer 1 with the drawing layer active
  and empty and the photo's corners the right colours. Seen on the iPad simulator:
  Photos… over the start screen, a 1668 × 2420 screenshot picked, a canvas of that
  size with the photo upright and three layers. Not tried: Files… and the Mac panel.

## This screen (2026-10-29)

Darrell asked for a canvas at the resolution of the device the app is on, as one of
the sizes at launch. The New row gains **This screen** after "Same as last" and before
the presets: the pixels of the display the app is on, the way the device is held, so an
iPad in landscape offers a landscape canvas and a phone a portrait one, and a canvas
made from it fills the screen 1:1. On the Mac it is the display the Start window is on
at its own scale (a 3072 × 1728 display at 2x offers 6144 × 3456), and it follows the
window to another display. On iPad and iPhone it is the window scene's screen at its
native scale, which on a foldable is the display that is open; before the view is in a
window, the scene's. `StartView` takes `screenPixels`, a closure asked whenever the
screen draws, so a turn or a fold is followed; nil (the tests, or no screen) offers no
tile. The tile is left out when the device cannot take the size or when the size used
last already is the screen's, as a preset that repeats the last size is.

Checked: `RecentCanvasesTests.testTheStartScreenOffersThisScreensPixels` (the tile's
place and pixels, the way the screen is turned, none without a screen, none past the
device's largest side, none when the last size is the screen's). Seen on the iPhone Duo
simulator.

## Full screen (2026-10-29)

Darrell wants a full-screen drawing surface, quickly and easily, on every device; the
screen-sized canvas was partly for that. The **This screen** tile is now **Full screen**,
its swatch carrying the full-screen arrows: a canvas of the screen's pixels, opened as
the screen. The interface is away from the first frame (the pill stays in the corner;
Tab or its button bring the bar and rail back), and the canvas is fitted edge to edge
rather than inside the 90 % margin, so each canvas pixel is a screen pixel. On the Mac
the window goes full screen on the display the Start window is on, the canvas fitted
once the window has become the screen and fitted to the window again when Esc leaves
full screen; it is not added to the tabs of other canvases. On iPad and iPhone the
canvas lies under every edge of the screen while the interface is hidden (the home
indicator's and a notch's too), the home indicator fades, and the first swipe up from
the bottom edge is the canvas's, the second the system's.

In the engine, `CanvasTransform.zoomToFit` takes `share`: 0.9 for the margin, 1 for
edge to edge. `CanvasViewModel.viewFit` says which a canvas gets whenever it is fitted
(the first frame, ⌘0, a reset of the view, a fold or a turn on iOS), and `fillScreen()`
sets it with the interface hidden; the Mac's `MainLayout` now starts the way the view
model says rather than always with the chrome up. When the last canvas was the screen's,
Full screen stands first in the New row in place of "Same as last", which would have made
the same canvas without opening it as the screen.

Checked on 2026-10-29: `CanvasTransformTests.testFittingEdgeToEdgeCoversTheViewPixelForPixel`
(a 2752 × 2064 canvas in a 1376 × 1032 view lands its corners on the view's at scale 0.5;
turned, it is fitted by its height and centred; the margin fit still takes nine tenths);
`ShellTests.testACanvasOpenedAsTheScreenStartsWithoutChromeAndFitsEdgeToEdge` (the layout
starts with the rail and bar away and the pill up, the canvas the whole window; ⌘0 and a
reset of the view fit edge to edge; Tab brings the chrome back);
`RecentCanvasesTests.testTheStartScreenOffersFullScreenAtThisScreensPixels` (the tile's
place and pixels, none without a screen or past the device's largest side, first in place
of "Same as last" when that was the screen's). The whole Mac suite: 326 tests, 3 skipped,
0 failures. The iOS app builds; on the iPhone Duo simulator the tile reads "Full screen
1398 × 2034" and stands first (the last canvas was the screen's), a tap opens white canvas
from edge to edge with only the pill and a "33%" zoom HUD (one canvas pixel per screen
pixel at 3x), a stroke paints, and the pill's arrows bring the bar and tool strip back.
The Mac's full-screen window itself (the transition and the fit on entering) is not
exercised by a test and awaits a look in hand. Two of the shell tests that measure
frames after an animated chrome change fail while the Mac's display is asleep, since
Core Animation does not advance then; they pass the moment it is woken.

### The pill folded (2026-10-30)

Darrell's full-screen canvas on the Duo still had the pill across its corner, the brush's
name, the colour and the arrows, over the drawing. With the interface hidden the pill now
starts folded to a disc, `Chrome.target` across, translucent (the chrome's background at
0.3 with a faint white ring, so it is found on a light canvas and a dark one) and carrying
the colour in use as a dot. A tap on the disc opens it into the pill, which is as it was:
the brush, the colour and the way back to the interface. A stroke folds the pill to the
disc again, and a tap on the canvas is a stroke; the interface coming back or going away
folds it too, so a canvas always starts with the disc. Both fold and unfold through a
0.2 s scale from the corner. (A tap on the pill between its buttons was to fold it as
well, but the gaps are 8 pt and the tap took the brush button on the Duo both times, so
that path is not offered.)

The state is the view model's `isPillOpen`, folded by `beginStroke` and whenever
`isChromeHidden` changes, so the Mac and iOS share it and a test can see it. The view is
`ChromePillView` in Artsy/UI, the same on both apps.

Checked on 2026-10-30: `CanvasViewModelTests.testThePillFoldsUnderAStrokeAndWithTheInterface`
(folded after `fillScreen`; a stroke folds it; the interface coming back folds it, and it is
folded when the interface goes again), and
`ShellTests.testACanvasOpenedAsTheScreenStartsWithoutChromeAndFitsEdgeToEdge` now sees the
pill's hosting view at the disc's 44 × 44 in the corner, a click on the disc open it to over
200 pt wide, a stroke fold it, and Tab fold it with the chrome's return; with
`ARTSY_SNAPSHOT_DIR` it writes pill-folded.png and pill-open.png, which show the grey disc
with the colour's dot and the pill as it was. The whole Mac suite: 327 tests, 3 skipped,
0 failures. On the iPhone Duo simulator a Full screen canvas comes up with the disc in the
corner, a tap on it opens the pill (Pencil, the swatch, the arrows), a stroke paints and
folds it to the disc, and a tap on the disc opens it again.

## The backdrop, 2026-10-30

The screen redrawn around the canvas opened last, on the branch `start-screen-backdrop`,
after three mocked-up directions (a gallery shelf, a studio sidebar, this one).

- **The canvas opened last** fills the screen as a backdrop: its thumbnail, blurred,
  dimmed and faded into the ground from the top down, so the colours of the work in
  progress set the screen's. It stands first as a Continue card: the picture at its
  aspect, its name large, its pixels and when, an Open pill. The card opens it; a
  secondary click or a long press gives the same menu as the tiles. With no canvas yet
  a few loose strokes stand in for the backdrop and a welcome line for the card.
- **The sizes** are pills in rows that wrap (`FlowLayout`, in `StartView.swift`),
  the first in the accent, each with a glyph at its aspect and roughly its scale; on
  a phone one row that scrolls sideways, as before. The list is the same `sizes`.
- **Recent** is the canvases after the card's, as thumbnails at their own aspect, in
  rows that wrap; with one canvas in the list the section is away. A gone document
  dims with "not found", one without a readable thumbnail says "no preview", as before.
- **Open… / Browse… and From a photo…** sit top right beside the card on the Mac,
  in the title row on iPad, and at the foot on a phone.
- Seen on the iPhone 18 Pro and iPad Pro 13-inch simulators, and the Mac through its
  render test at 880, 520 and 360 wide with the list, with one canvas and with
  nothing. `RecentCanvasesTests`: the screen test's white count is now the pills'
  glyphs and the words, far fewer than the old tiles' swatches.
