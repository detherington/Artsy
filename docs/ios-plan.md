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
   pressure comes from its speed: full when still, 0.2 at 2,500 screen points a
   second, falling away faster at first (a walking pace of 500 pt/s presses about
   0.8), the speed smoothed over 80 ms so the pressure does not flicker, the landing
   sample and a rest before the first movement counted as still, the first movement
   setting the speed outright. Screen points, through the zoom, since 2026-10-26: in
   canvas pixels a finger on a phone was always sprinting and every stroke came out
   light after a hard landing (`drawing-engine-plan.md` § 14). The pressure curve applies
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
   One of those arrived on 2026-10-26, before any Pencil was in hand: whether a stroke
   has pressure had been read off its landing sample's force alone, and Apple says a
   Pencil's force "is estimated at first, and may not always be updated", so a Pencil
   Pro landing at an estimated zero would have drawn its whole stroke from speed, as
   if it were the USB-C Pencil. `PaintingView.strokeHasPressure(beginning:)` now says
   a Pencil stroke has pressure if its landing sample reads a force, if an update to
   that force is expected (`estimatedPropertiesExpectingUpdates`), or if this Pencil
   has reported force before in the session; the USB-C Pencil reads zero and expects
   no update, so it still draws from speed. A stroke that began without pressure and
   then reports some switches to the Pencil's own (`CanvasViewModel.strokeReportsPressure`,
   also from `touchesEstimatedPropertiesUpdated`), and the recording follows. The
   updates are still not applied to samples already drawn. Untested on a Pencil.
   The document browser stopped being the root on 2026-10-27: the start screen is
   (`docs/start-screen-plan.md`), with the browser behind Browse… for documents
   elsewhere, and new canvases written to the app's own Documents folder.
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
   - **3c. Sheets and the rest.** **Done** (2026-10-26, branch `ipad-sheets`): the
     Mac's app-level actions, which its chrome asks for by selector name, are answered
     on iPad by the app model (`ArtsyiOS/AppActions.swift`) with sheets, pickers and
     the share sheet over the canvas screen. The Studio, Settings (the AI and stock
     keys included) and Keyboard Shortcuts are the Mac's views as form sheets, dark,
     with a little room under the top edge where the Mac had a title bar; the bar's
     document menu on iPad lists the exports, Settings and Shortcuts beside Documents
     and Save now. Export PNG, PNG 16-bit and JPEG write the lit canvas to a scratch
     folder and offer it through the share sheet, a popover from the menu's corner of
     the bar; a brush exports the same way. Import an image is the Photos picker, the
     picked photo a new layer fitted to the canvas with its undo step; import brushes
     and tip or grain images are the document picker handing over copies, into the
     library as on the Mac. The keys an iPad with a keyboard sends are the Mac's,
     `ArtsyiOS/KeyCommands.swift`, as key commands on the canvas screen's controller:
     the tool keys (which wait for a stroke to end), size and opacity, the colours,
     the nine brushes, Tab for the chrome, and the ⌘ keys for undo, zoom, rotation,
     flip, grid, save, documents, exports, Studio, Settings and Shortcuts. One thing
     iPad taught: a panel's row closes the panel only on the next layout pass, and a
     sheet or picker put up on the panel in the meantime goes down with it (the Photos
     picker's view service was torn down the instant it came up), so every
     presentation waits for the panel to go first. Verified on the simulator: E switching to the
     eraser from the keyboard; Settings, Shortcuts and the Studio as sheets; Export
     PNG offering "Untitled 2, PNG Image, 78 KB" in the share sheet; a photo placed as
     a layer. The Shortcuts sheet still lists the Mac's keys, S, U, T, H, Space and
     ⌥-click among them, which iPad does not answer yet.
4. **The phone layout.** The third breakpoint, finger-first; canvas size caps by
   device. Medium. **Done** (2026-10-26, branch `phone-layout`): two breakpoints
   below the painting display's, by the screen's width, in the chrome's state beside
   the dock's. Under 1,000 pt (an iPad in portrait, a phone) the bar is the compact
   one: the document menu as its icon with a dot for unsaved changes, the brush as
   its stroke alone, size and opacity as buttons showing their values that open the
   drag pill in a popover (kept a popover on a phone, not the sheet it would become),
   the colour, and the panel buttons as icons without labels. Under 700 pt (a phone)
   there is no rail: the tools sit in a strip over the top of the canvas with undo
   and redo, finger-sized at 40 pt as the bar's buttons are there, and the panels
   that open from the bar take the panel's colour as the sheets they become on a
   compact screen. The Mac keeps the full bar whatever its window's width until the
   pen display is in hand (UI plan step 7). Settings, Shortcuts and the Studio fill
   the sheet they are given on iPad and iPhone rather than the Mac's fixed window
   sizes. A fold, an unfold or a turn fits the canvas again: the painting view
   watches its width and refits when it changes by a quarter or more, which the rail
   and bar coming and going do not. The new-canvas sheet offers nothing larger than
   the device takes: `LayerStack.largestCanvasSide(memoryBudget:)` gives the side at
   which two layers, the composite with its mip levels, the scratch and the stroke
   textures fit in half the GPU's working set, rounded down to 256, 1,024 at the
   least and the format's 8,192 at most (5,888 for a 4 GB working set, 2,816 for
   1 GB; tested); presets beyond it are not offered and a custom size is clamped,
   with "Up to N × N on this device" said. What the iPhone Duo simulator taught: it
   has two displays, 1,398×2,034 and 2,007×2,853 at 460 ppi, and runs the app on the
   inner one at 669×917 pt (3x), which is regular in width, so the bar's panels stay
   popovers there; the simulator offers no fold, so the outer display's 466×678 pt
   is untested, and the layout was sized for it on paper (the compact bar at 40 pt
   targets is 424 pt wide). Verified on the Duo simulator: the phone layout with
   the strip and compact bar, the size popover, the Layers panel, a stroke, and the
   turn to landscape.
5. **Shipping.** Bundle identifiers, the App Store listing, an archive-and-upload
   script, TestFlight for the pen sessions, then review. Small to medium, plus
   Apple's time. **Built** (2026-10-26, branch `ios-shipping`), with the steps that
   are App Store Connect's own left to do by hand. The app has its icon: the Mac
   icon's artwork, which sits in a rounded rectangle with a transparent margin,
   cropped inside that shape and flattened to the opaque 1,024-pixel square iOS
   wants (a small Swift tool in the scratchpad did it; the result is in the asset
   catalogue as the universal iOS icon). Its launch screen is the chrome's dark grey
   through a colour in the catalogue rather than the generated white. Its plist
   declares the category (Graphics & Design), that it needs Metal, and that it uses
   no encryption of its own, so no compliance question per build. A privacy manifest
   names the three required-reason APIs the app touches, each with its reason: user
   defaults for the preferences, file timestamps for the brush library's order, the
   system clock for the stroke timings; nothing is collected and nothing tracks.
   `scripts/release-ios.sh <version>` bumps the version and build number in the iOS
   target's settings, archives for devices, signs in the cloud with the App Store
   Connect API key already in the environment (no distribution certificate or profile
   on the Mac; `-allowProvisioningUpdates` has Apple keep them) and uploads through
   `-exportArchive` with `scripts/ExportOptions-ios.plist`, where the build goes to
   TestFlight once processed. `docs/app-store-listing.md` holds the listing's words
   (name, subtitle, description, keywords, category, the privacy questionnaire's
   answer), the screenshot sizes to make from the simulator, the TestFlight and review
   notes, and the three things done once in App Store Connect by hand: the app record
   for `com.artsy.app`, a home on the web for `docs/privacy-policy.md` (GitHub Pages
   from `docs/` would do), and the API key's role. A trial of the script's archive step from here succeeded: automatic provisioning
   registered the bundle identifier's iOS side with the portal and signed the archive
   with the Apple Development identity and a team profile it made. The export and
   upload, which make the cloud-managed distribution certificate and profile on the
   account and send the build up, are the script's first run in Darrell's hands, once
   the app record exists. Not in this step: screenshots for the listing, which want a
   real painting on the canvas, and the review itself.

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

## The panels fit what holds them (2026-10-30)

Darrell found the brush settings, and the other panels, larger than the pop-up holding
them, cut off at the corners. The five panels that open from the bar (Brushes, Colour,
Layers, Adjust, Add) had fixed frames, 340 by 520 to 640 pt, right for a Mac popover,
which is as large as its content, and wrong wherever the holder is smaller: a popover on
a short screen (the Duo's inner display on its side is 669 pt tall) is trimmed by UIKit
and its rounded corners cut the content; the sheet a popover becomes on a phone is the
screen, 402 pt tall on an iPhone on its side, where a 600-pt panel lost its header above
and its settings below; and in a taller sheet the panel sat in the middle with its
scrolling part still cut at the fixed frame's bottom.

`panelFrame(width:height:)` in Artsy/UI/Platform.swift replaces the five frames: fixed on
the Mac, and on iPad and iPhone an ideal size with no maximum, which a popover takes when
the screen has the room and trims when it has not, and which a sheet fills. The panel is
then never larger than what holds it; its scrolling part gives way. The Colour panel's
square and hue strip, which sit outside the scrolling part because they take the pen's
drag, give up height down to 120 pt where the panel is short, so the fields and the
palette keep room of their own; at full height they are the 260 pt they were.

Checked on 2026-10-30: iPad Pro 13-inch simulator, the Brushes popover the same 340 by
600 as before; iPhone 18 Pro simulator on its side, the Brushes sheet with its header,
its categories and its grid from edge to edge and the quick settings scrolling below
(before: the header and the grade row cut off), and the Colour sheet with the square at
130 pt and the fields and palette in view (before: the square at 260 left them 8 pt);
iPhone 18 Pro upright, the Colour sheet filling the page sheet; iPhone Duo simulator
(the 466 by 678 pt display), Brushes, Colour, Layers, Adjust and Add each filling the
sheet inside the screen's safe area, the Smooth and Amount rows of the brush settings
now reachable. The whole Mac suite, where the panels keep their fixed frames: 327 tests,
3 skipped, 0 failures.

**The compact bar fits too (2026-10-30).** Seen on the way: on the 402-pt-wide iPhone
upright the compact bar was wider than the screen, the Hide button off its right edge
and Add half cut; the whole bar wants about 460 pt. The bar now picks, by
`ViewThatFits`, the full compact bar where it fits and otherwise the same bar without
the Size and Opacity buttons, whose sliders are in the Brushes panel's quick settings;
the way to hide the interface stays at the right end, since a phone has no Tab. The
Duo's outer display gets the shorter bar as well: its status column on the right is a
safe-area inset, and inside it the bar has 375 pt, where before Add and Hide sat under
the column; the inner display, 669 pt, keeps every button.
`ShellTests.testTheCompactBarDropsTheQuickValuesWhereTheyDoNotFit` clicks Hide at the
right end of a 402-pt bar and a 466-pt one. Checked on the iPhone 18 Pro simulator
upright (the bar ends with Hide inside the screen, and Hide hides the interface) and the
Duo (the shorter bar). The whole Mac suite: 328 tests, 3 skipped, 0 failures.

**A way out of a sheet (2026-10-30).** Darrell found no obvious way to dismiss a panel on
the closed Duo: a panel opened from the bar becomes a sheet there, filling the screen,
and the swipe down that dismisses it is not something the sheet shows. The bar's, the
pill's and the swatch's panels now open through `panelPopover`, which knows from the
presenting view's size class whether the popover is becoming a sheet (a popover's own
contents are compact either way) and, when it is, hands the panel a dismissal through
the environment; `PanelHeader` then carries a Done button after whatever else is in its
right end (Studio…, the eyedropper), and a popover, which a tap outside dismisses, gets
none. The sheet also shows the system's grabber at its top, the hint for the swipe.
Checked on 2026-10-30: `ShellTests.testThePanelHeaderShowsDoneOnlyForASheet` (a click at the
header's right end dismisses when the environment carries a dismissal and does nothing
when it does not); the whole Mac suite, 329 tests, 3 skipped, 0 failures; on the Duo
simulator the Layers, Brushes (beside Studio…) and Colour (beside the eyedropper) sheets
each show the grabber and Done, and Done closes them; on the iPad Pro simulator the Layers
popover has neither.
