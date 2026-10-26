# Artsy on iPad and iPhone

A plan for shipping Artsy as one app for iPad and iPhone beside the Mac app, written
2026-10-25 after a survey of what in the codebase is engine and what is Mac. Nothing
here is built yet.

## What the survey found

Lines by layer, and how much of each leans on AppKit:

| Layer | Lines | Files | Touch AppKit | What touches it |
|---|---|---|---|---|
| Metal (shaders, renderers, textures) | 4,321 | 9 | none | — |
| Brushes | 2,508 | 10 | 2 | `NSImage` in texture import, `NSEvent` in dynamics |
| Drawing (paths, smoothing, recording) | 1,516 | 9 | 1 | `TabletEventHandler` (the Mac's pen input) |
| Layers | 300 | 2 | 1 | one `NSImage` |
| Canvas (view, renderer, document, model) | 5,672 | 13 | 10 | `CanvasView` (1,479 lines of `NSEvent`, cursors, sounds), cursors, clipboard, `NSBitmapImageRep` in the document and exporter |
| Utilities | 1,236 | 5 | 2 | `NSBitmapImageRep`, `NSScreen` |
| UI (chrome, panels, Studio, Settings) | 5,361 | 22 | 13 | 19 of 22 are SwiftUI; the AppKit is `PenScrollView`, `TiltPad`, hosting, colour conversions |
| App (delegate, menus, windows) | 1,143 | 3 | 3 | all of it |
| AI and stock images | 1,069 | 9 | none | `URLSession`, keys in the keychain |
| Tests | 8,250 | 36 | 8 | the shell and view tests; 28 files are engine tests on `EngineHarness` |

So the engine — the stamp and ribbon renderers, loaded brushes, thick paint, wet and
dry, water, bristles, living marks, pencil grades, layers, the document format, undo,
the view model — is portable as it stands, apart from a handful of image and storage
calls. Metal specifics: `.managed` storage is macOS-only and is used in three places
(shared textures for readback, the transform session, selection moves); iOS uses
`.shared` there. The pixel formats in use (half float, unorm16, 32-bit float targets,
read-write textures) are on every A-series and M-series iPad and recent iPhones. The
canvas view is already an `MTKView`, which exists on both platforms; what does not
port is its 1,479 lines of `NSEvent` handling.

What has no counterpart and must be rebuilt:

- **Pen input.** `TabletEventHandler` reads `NSEvent` pressure, tilt, rotation,
  proximity and the pointing device. On iPad the same facts come from `UITouch`:
  force, altitude and azimuth, coalesced and predicted touches, estimated properties
  that are corrected a frame later, the Pencil's double-tap and squeeze, hover on
  newer iPads, and palm rejection. A `PencilInput` adapter feeds the same
  `StrokePoint`s; the pressure curve, smoothing and rest handling stay as they are.
  On iPhone there is no Pencil: a finger has no pressure or tilt, which the engine
  already handles as a mouse does (the easing without pressure).
- **The canvas view.** A `UIView` over the same `MTKView` and renderer: the Pencil
  draws, one finger pans, two fingers pinch and rotate, with the gesture
  disambiguation Procreate's users expect. No cursors; haptics in place of sounds.
- **The shell.** `AppDelegate`'s menus, windows, panels and dialogs become a SwiftUI
  `App` with a `DocumentGroup` or a document browser, the Mac menus as iPad menu bar
  commands for a hardware keyboard, and the Studio, Settings and Shortcuts as sheets.
  Open, save, import and export go through the document picker.
- **The chrome's AppKit.** `PenScrollView` exists because a Mac scroll view does not
  scroll under a pen drag; on iOS `ScrollView` scrolls under a finger and the Pencil
  alike, and a long press is a system context menu, so the panels drop to plain
  SwiftUI. `TiltPad` becomes a `UIView`. Hosting and colour conversions have UIKit
  twins.
- **Distribution.** No Sparkle: the App Store and TestFlight. `scripts/release.sh`
  stays the Mac's; an archive-and-upload script joins it, and the App Store Connect
  key already in the environment serves it.
- **The phone.** A third breakpoint beside the painting display and the small display
  of `ui-plan.md`: finger-first, the bar collapsed, panels as sheets. The UI plan's
  principles (the canvas is the app, everything reachable with a pen, panels as
  pop-ups) carry to the iPad without change.

Constraints to design around: an iPhone has a fraction of a Mac's memory, so the
canvas size caps and the water simulation's half-resolution threshold need per-device
values (the view model's memory estimate is the hook); thermal limits mean the stroke
cost measurements should be repeated on the slowest supported device.

## Ways to structure it

1. **One project, shared files, two app targets.** The Mac app as it is; an iOS
   target that includes the engine files; `#if os(macOS)` around the twenty-odd
   AppKit touches; the chrome split by platform at the layout. Fastest start. The
   cost is file-membership bookkeeping in the project file and `#if` sprawl unless
   the boundary is policed by hand.
2. **The engine as a Swift package.** `ArtsyEngine` (Metal, Brushes, Drawing, Layers,
   the renderer, document and view model, Utilities minus AppKit) and `ArtsyChrome`
   (the SwiftUI panels and the Studio), consumed by a Mac app and an iOS app that each
   own their canvas view, input and shell. The boundary is enforced by the compiler:
   nothing in the package can import AppKit. The engine tests move with it and run on
   an iPad simulator with the same harness. The cost is one restructuring step up
   front, including the shader library as a package resource.
3. **Mac Catalyst.** Rewrite the chrome for iPad and run that on the Mac. It would
   throw away the Mac's pen path (`NSEvent` tablet input is not available to a
   Catalyst app) and the Mac-specific chrome. Not a route.

The recommendation is 2, done as the first step so that every later step is written
against the boundary rather than retrofitted to it.

## Steps

0. **A pressure substitute for pressureless pens** (decision 3), on the Mac first
   where it can be tried with a mouse, since it belongs to the stroke path rather
   than to any platform. Small. **Done** (2026-10-25, branch `pressure-from-speed`):
   `PressureFromSpeed` in the engine's stroke input. When a stroke reports no pressure
   (a mouse or trackpad on the Mac, the USB-C Pencil on the Duo) and the preference is
   on (Settings → Tablet → "Press harder when slow", on by default), each sample's
   pressure comes from its speed: full when still, 0.2 at 2,500 canvas pixels a
   second, falling away faster at first (a walking pace of 500 px/s presses about
   0.8), the speed smoothed over 80 ms so the pressure does not flicker, the first
   sample counted as slow since the pen has just landed. The pressure curve applies
   on top as for a real pen; a recording keeps the raw samples, so a replay derives
   the same pressure again; pens with pressure are untouched. Measured with the
   Pencil at 12 px on the Mac: the same line drawn over two seconds covers more than
   half again what it covers drawn in a tenth, and with the substitute off, or with a
   pen's own pressure, the two are equal. The mouse-strokes golden was re-recorded
   after viewing: waves at a walking pace a touch firmer, fast flicks lighter and
   thinner, clicks pressing fully. Tilt is left to the brushes' own tilt dynamics.
1. **The engine as a package, and the engine tests on iPad.** Move the engine layers
   into `ArtsyEngine`; replace `NSImage` and `NSBitmapImageRep` with `CGImage` and
   ImageIO (five sites); `.managed` becomes a platform choice in the texture manager;
   `TabletEventHandler`, cursors and sounds stay in the Mac app behind small
   protocols. Then an iOS test target that runs the 28 engine test files on an iPad
   simulator: the goldens included, which is the proof that the port draws the same
   picture. Medium. **Done** (2026-10-25, branch `engine-package`): 43 files, 13,500
   lines, moved with their history into `Packages/ArtsyEngine`, a local Swift package
   the Mac app and its tests depend on; the Mac app keeps 42 files and 10,000 lines
   (the canvas view, cursors, selection overlay, clipboard, tablet input, the chrome,
   the AI and stock views, the app). Nothing in the package imports AppKit, UIKit or
   SwiftUI. What had to change in the engine: texture import, thumbnails (now
   `CGImage`), image placement and export go through ImageIO; the shader library loads
   from the package's bundle; `.managed` storage is only for Intel Macs; the document
   load is split into `read`, `populate` and a headless `load` that makes its own
   renderer, with the Mac's view-making `open` in the app; the view model asks the
   platform for the pen's key and the diagnostics for its own lines (two hooks the Mac
   sets at launch) rather than knowing the tablet handler or `NSScreen`. The API was
   opened with the compiler as the guide, from the access errors round by round, plus
   the brush model, the view model, preferences, layers, library and renderer
   wholesale, since the chrome binds nearly all of them: 700 public declarations, with
   memberwise initialisers written for the structs the app constructs. The engine tests
   are the same files through a symlink into the package's test target, with the eight
   AppKit test files excluded and the app import conditional; on an iPad Pro 13-inch
   (M5) simulator all 195 pass, goldens included, in 104 s. Two things the simulator
   taught: it reports a GPU working set of zero, which the undo manager took as its
   snapshot budget and dropped every step (now a quarter of physical memory when the
   GPU says nothing), and the diagnostics line named macOS by hand.
2. **A canvas on iPad.** The iOS app with one document and nothing else: the canvas
   view, Pencil input with pressure, tilt, prediction and estimate updates, the
   gestures, the bottom bar with brush, size, opacity and colour. The pen notes come
   from here. Large. **Done** (2026-10-25, branch `ipad-canvas`), the first slice:
   an `ArtsyiOS` target (iPad and iPhone, iOS 17, the same bundle identifier as the
   Mac so the App Store sells one app) of four files and 430 lines over the engine
   package, its sources a synchronised folder so nothing is registered by hand. The
   canvas is an `MTKView` with the engine's renderer as its delegate exactly as on the
   Mac; touches are handed to the engine in the Mac's y-up view space, so the one
   `CanvasTransform` serves both platforms and the picture needs no flip. The Pencil
   draws, its force as pressure, its altitude and azimuth as the two tilt components
   (`PencilTilt`, a pure helper with tests), its roll on a Pencil Pro as rotation,
   every coalesced sample taken; a stroke counts as having pressure only when the
   Pencil reports force, so the USB-C Pencil and a finger get their pressure from
   speed (step 0) without anything else knowing. One finger draws; two fingers pan,
   pinch and turn through UIKit's recognisers, fingers only, so a resting hand never
   moves the canvas under the pen. The bar along the bottom: the brush as a menu of
   the library by category, size and opacity, the colour picker, undo and redo, and
   the grade row when the brush is graphite. The one document is
   `Documents/Untitled.artsy`, opened at launch through the headless `load` and saved
   when the app goes to the background under a background task, since without one
   the suspension won the race and a relaunch came up blank. Verified on the iPad Pro
   13-inch (M5) simulator: a finger stroke logs as "pressure from speed, finger" and
   draws where the finger went; undo and redo; pinch and turn; the brush menu; the
   strokes back after a relaunch. The tilt tests pass on the simulator and the Mac
   suite's 285 tests pass unchanged. Left for the pen in hand: predicted touches and
   the Pencil's late-arriving force and azimuth (estimated-property updates), which
   the simulator cannot exercise; the phone layout is step 4; the icon, step 5.
3. **The rest of the painting app.** Documents through the document browser and
   iCloud Drive (the `.artsy` package is shared with the Mac as it is); layers,
   Adjust and Add; the Studio, Settings and Shortcuts as sheets; the keyboard
   commands for an iPad with a keyboard; import and export; the AI and stock views
   with their keys. Medium to large. In three slices, each its own branch:
   - **3a. The chrome shared.** **Done** (2026-10-26, branch `ipad-chrome`): the
     Mac's SwiftUI chrome is compiled into both apps rather than written twice. The
     `Artsy/UI`, `Artsy/AI` and `Artsy/Unsplash` folders are synchronised groups of
     both targets (31 explicit file entries left the project file, 128 lines), with
     three Mac-only files kept out of the iOS target: the window layout, the pen
     scroll view and the tilt pad's NSView. What the chrome needed to compile on
     both: a `Platform` file (the toolkit's image behind one name, a browser for a
     link, an error to show, the system's window colours, a checkbox that is a switch
     where there are none); the colour panel's maths in pure HSB rather than through
     `NSColor`, which the colour tests pass unchanged; the screen sampler kept to the
     Mac; the three places that reached the app delegate for the canvas now reach it
     through `ChromeActions` (the AI and stock panels take the renderer from the
     actions, and a transform in progress lands through a hook the Mac sets at
     launch); the rail's app actions a logged no-op on iPad until the sheets come;
     the pressure-curve editor asking the engine's pen-key hook rather than the Mac's
     tablet handler; a dozen `#if os` lines across eight files. iPad's own twins are
     60 lines: a drag scroll that is a plain `ScrollView`, since iOS scrolls under the
     Pencil and a finger alike, and a tilt pad drawn in SwiftUI with a drag, sharing
     the Mac pad's geometry. `CanvasScreen` lays out the rail, bar, dock (on a
     screen at least 1,600 pt wide, which no iPad is), pill and zoom HUD in SwiftUI
     and builds the actions from the session: undo, redo, zoom, rotate, flip, guides.
     The rail on iPad shows the tools the canvas there takes: brush, eraser, fill and
     eyedropper, the last two ported from the Mac canvas (the 1×1 readback of the
     composite; the background fill guarded by its undo step); selection, shape and
     transform wait for their overlay. Verified on the iPad Pro 13-inch (M5)
     simulator, each panel opened and used: brushes (tiles, grade, pressure), layers,
     Adjust (the pad dragged to "→ 74% ↑ 57%" and levelled), Add (AI and stock),
     Colour (a palette pick turning the bar's swatch red), the chrome hidden to the
     pill and back, a fill landing red and undone, the eyedropper reading white; the
     Mac suite's 285 tests pass. Two things iPad taught: a popover asked for below a
     bar at the bottom of the screen opens off the screen, since iPad does not flip
     it as the Mac does, so the bar's panels ask for above (`Chrome.barPopoverEdge`);
     and the Add panel takes a couple of seconds to appear on the simulator, the AI
     keys being read from the keychain as it opens. Guides are kept but not drawn on
     iPad yet, and the panels' key notes are the Mac's until the keyboard commands.
   - **3b. Documents.** **Done** (2026-10-26, branch `ipad-documents`): the system's
     document browser is the app's root, over iCloud Drive, On My iPad and any other
     provider, and the canvas screen is presented over it for the document picked.
     The app declares the `.artsy` package as its own document type (the Mac's
     declarations in an `Info.plist` merged into the generated one), supports the
     browser and opening in place, and exposes its folder in Files. A new document
     comes from the browser's plus button through the Mac's new-canvas view as a
     sheet, written blank at the chosen size into a temporary folder and moved by the
     browser to where the user put it, then opened from there like any other. A
     session is one open document: the URL's security scope held while it is open,
     saved to its URL when it closes, every half minute between strokes when it has
     been drawn on, when the app goes to the background, and on "Save now" in the
     bar's document menu, which on iPad is "Documents" (back to the browser) and
     "Save now". A save marks the canvas clean only if nothing changed while it was
     in flight. The engine's document reads and the replacement at the end of a save
     are under file coordination now, on both platforms, so a document in a
     provider's folder is read after the provider has finished with it and replaced
     whole. Verified on the simulator: a document created at 1,920×1,080 through the
     sheet, named "Untitled 2" by the browser beside the step-2 document, drawn on,
     closed through the menu (saved in 0.08 s), listed in Recents, reopened with its
     stroke; a stroke then autosaved three seconds later when the timer came round.
     Two things to check on a device: the browser shows the package's size as
     exabytes on the simulator (104 KB on disk), and it ignores the dark style asked
     of it on this OS. The browser shows a generic icon for the package; a Quick Look
     thumbnail extension could show the document's own thumbnail (step 5). The app's
     own iCloud container is not set up; the browser reaches iCloud Drive without it.
   - **3c. Sheets and the rest.** Studio, Settings and Shortcuts as sheets; the
     keyboard commands; import and export through the share sheet and the document
     picker; the AI and stock keys in Settings.
4. **The phone layout.** The third breakpoint, finger-first; canvas size caps by
   device. Medium.
5. **Shipping.** Bundle identifiers, the App Store listing, an archive-and-upload
   script, TestFlight for the pen sessions, then review. Small to medium, plus
   Apple's time.

Each step is its own branch and PR, with the engine tests the net for every one.

## Decisions taken (2026-10-25)

1. **One universal app** under the Artsy name.
2. **The floor is iPad Pro and up, and the iPhone Duo.** The Duo is the phone target
   because it takes a Pencil: Apple's specifications list the Apple Pencil (USB-C) for
   both of its displays, the 7.6-inch inner folding OLED (1878 by 2670, 430 ppi) and
   the 5.4-inch outer (1398 by 2034, 460 ppi), on the A20 Pro, with Pencil support
   arriving in iOS 27.2 at the end of October 2026. The USB-C Pencil gives tilt and no
   pressure, and Apple's footnote says hover is not supported on the Duo; there is no
   squeeze, barrel roll or haptic either, so every quick control is on screen.
3. **Sketching and painting both, with a pressure substitute.** Without pressure the
   engine already runs a stroke as it does for a mouse: constant full pressure with
   eased ends. That leaves the paint brushes laying down at full press, with speed and
   tilt for expression (ten brushes carry velocity or tilt dynamics), which is usable.
   It is the dry media that lose the most: pencil, chalk and conté get their character
   from pressure deciding how far into the paper's tooth a mark reaches, and at
   constant pressure every mark reaches the same depth. So the Duo needs a pressure
   substitute before sketching feels right, and with one, painting works too: a
   pressure derived from speed (slow presses harder, a fast hatch is light) and tilt
   (the side of the lead), fed through the same pressure curve, chosen per input
   device. Small, in the stroke path, testable against the pen's recordings.
4. **The engine package first.**
5. The first TestFlight build: painting and documents; AI and stock images follow.
6. Documents on iCloud Drive as now, the same `.artsy` package on both.
