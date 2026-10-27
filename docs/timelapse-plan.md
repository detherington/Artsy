# Time-lapse recording

What Procreate gives creators: every change to the canvas becomes a frame of a video
that lives inside the document, recorded by default from the first stroke; under Actions
▸ Video there is a Time-lapse Recording toggle, a Replay to watch it in the app, and
Export Time-lapse Video at full length or cut to 30 seconds, for sharing. The video is
of the canvas only, never the interface. The same for Artsy, on the Mac and on iPad and
iPhone, with the engine doing the recording so both apps get it from one place.

## Design

- **A frame per settled change.** The renderer keeps a mipmapped composite of the
  canvas and knows when it is brought up to date after a stroke commits, a fill lands,
  a layer changes, a transform is applied, an image is placed, or an undo or redo
  runs (`compositedContentVersion` moving, with no stroke in progress). At that moment
  `TimelapseRecorder` draws the composite's mip level nearest the recording size into
  a BGRA8 texture that backs a `CVPixelBuffer` (through a `CVMetalTextureCache`) and
  hands the buffer to an `AVAssetWriter` as the next frame, 1/30 s after the last.
  HEVC, H.264 where HEVC is not offered. Nothing is read back to the CPU and nothing
  waits: the pass rides the frame's command buffer and the append runs on the
  writer's queue. The recording size is the canvas held to 1,920 px on its longest
  side by default, with 4K as the other choice in Settings; a frame costs one small
  draw and an encoder append, so a hatching hand at ten strokes a second is fine.
- **In the document.** `Document.artsy/timelapse/` holds segments `0001.mov`,
  `0002.mov`… and `timelapse.json` (recording size, frames per segment, total, the
  toggle). An `AVAssetWriter` cannot reopen a file, so every opening of the document
  starts a new segment and finishes it on close, on going to the background, and
  before every save. A save writes a fresh package and swaps it in
  (`replaceItemAt`), so the save stages the segments by hard link where the staging
  folder shares the volume, and copies them otherwise; the segment being written is
  finished before the swap and a new one begun after. Delete Time-lapse removes the
  folder. Documents from before have none and record from their next opening.
- **On by default**, per document, as in Procreate; the toggle is kept in the
  manifest, the default for new documents in Settings. The Time-lapse menu shows the
  recording's length and size ("3 min 20 s, 212 MB"), since the package grows: 1080p
  HEVC runs about a megabyte a second of video, and a frame is 1/30 s, so a thousand
  strokes make 33 seconds and some 35 MB. An iCloud document uploads that growth.
- **Replay and export.** Replay: an `AVMutableComposition` of the segments in a
  `VideoPlayer` sheet. Export: Full length (every frame at 30 fps) or 30 seconds (the
  composition's time scaled, so a ten-minute recording plays twenty times faster),
  through `AVAssetExportSession` at the recording size; on the Mac to a file through
  the save panel, on iPad and iPhone to Photos or the share sheet.
- **Where it shows.** The Mac: a Time-lapse submenu under File (Record Time-lapse as
  a checkbox, Replay…, Export…, Delete…), and the same items in the bar's ≡ menu on
  both platforms. Settings ▸ Time-lapse: record new canvases, recording size.
- **Edge cases.** An undo is a frame, as it is in Procreate. A segment that fails to
  write is dropped with a diagnostics line and recording goes on in a new one. The
  writer's pixel buffer pool holds three frames; a frame that finds the pool empty is
  skipped, never waited for. A canvas whose size changes starts a new segment at the
  new size, and the export's video composition renders at the last size.

## Steps

1. `TimelapseRecorder` in the engine: the capture pass, the writer, segments and the
   manifest in the package, the hook in the renderer after a settled change, the
   per-document toggle, and the save carrying the folder over. Tests with the
   harness: N strokes give N frames; a fill, a layer change and an undo one each; a
   second opening a second segment; a save keeps them; the manifest's counts; the
   recording size from the canvas.
2. Replay and export: the composition over the segments, Full length and 30 seconds,
   the export session; a test that 300 frames export to 10 s at full length and that
   a longer recording's 30-second cut is 30 s.
3. The menus and the player sheet on both platforms, Photos and the share sheet on
   iPad, the save panel on the Mac, the Settings pane, the length and size shown,
   Delete.
4. Checked by hand: a session recorded on the iPad simulator and on the Mac, saved,
   reopened, replayed and exported, the video watched.

Steps 1 and 2 are about a day each, step 3 half a day.

## Checked on 2026-10-27

Step 1 built on the branch `timelapse`.

- **The recorder.** `TimelapseRecorder` in the engine's Canvas folder, owned by the
  renderer. `encodeFrame` now composites and then, with no stroke in progress and no
  transform or paste preview up, hands the composite to the recorder, which draws it
  through the display pass into a BGRA8 texture backed by a pooled `CVPixelBuffer`
  (`CVMetalTextureCache`), the canvas filling the frame, and appends the buffer to the
  segment's `AVAssetWriter` from the command buffer's completion, a thirtieth of a
  second on from the last frame. A content-version change is always a frame; the
  composite moving on its own (water) no more often than every quarter second; at
  most three frames in flight, a frame that finds no room is skipped. HEVC where the
  writer takes it, H.264 otherwise, at four bits a pixel a second (about 15 Mbit/s at
  1080p). Segments are written in two-second fragments, so one cut short still plays.
- **In the document.** `timelapse/0001.mov`… and `timelapse.json` with the frame
  size, the frames per second, the document's own recording switch and each
  segment's frame count; a segment with no frames is dropped when it finishes. The
  save finishes the segment in hand, waits for it, and stages the folder into the
  fresh package by hard link (copy across volumes); after the swap the recorder
  writes its next segment in the document. An unsaved Mac canvas records into a
  temporary folder that the first save carries in and that goes when the canvas is
  closed unsaved. Opening a document attaches a recorder when it has recorded before
  (keeping its switch, on or off) or, never having recorded, when Settings says new
  documents do; the frame's longest side is a setting too, 1,920 or 3,840.
- **Tests** in `TimelapseTests`: the frame size held to the longest side, never grown,
  even and at least 16; three strokes and a change give four frames and two quiet
  frames none, the segment a 240 × 160 video of 4/30 s; a save carries the folder in,
  the next stroke starts a second segment, the next save keeps both, and the document
  opened again knows both and writes a third; recording off takes nothing, begins no
  segment, and stays off when the document is opened again. The Mac suite passes.
- **On the iPad Pro 11-inch (M5) simulator.** A new 2,048 canvas, three strokes,
  back to Start: the package holds `timelapse/0001.mov` of 17 KB and the manifest;
  read back, the segment is 1920 × 1920, hvc1, 0.133 s at 30 fps, four frames: the
  blank canvas as opened, then one a stroke.
- **Not done yet.** Replay and export (step 2), the menus and settings (step 3). The
  iPad's recording switch has no control yet; it records by default. The Mac's
  Settings window does not show the two preferences yet.

## Checked on 2026-10-27, step 2

Replay and export built on the branch `timelapse`.

- **The movie.** `TimelapseMovie` in the engine's Canvas folder: the manifest's segments
  with frames, in order, on one track of an `AVMutableComposition`, a segment that
  cannot be read left out with a diagnostics line. Full length is every frame a
  thirtieth of a second; a cut (`.seconds(30)` for the menu's 30 seconds) scales the
  composition's time when the recording is longer, so a ten-minute recording plays
  twenty times faster, and a recording shorter than the cut plays whole. An
  `AVVideoComposition` at 30 frames a second and the recording's frame size keeps the
  frames that land on a thirtieth, one instruction over the whole movie when every
  segment is the frame's size and one a segment, scaled to fit and centred, when one
  was recorded at another size. `playerItem()` is for the player sheet; `export(to:)`
  writes an H.264 MP4 at the frame size through `AVAssetExportSession`, the kind every
  player and site takes, with a progress callback and cancellation through the task.
  `TimelapseRecorder.movie(length:)` finishes the segment in hand first, so every frame
  is on disk, and the next change starts a new segment; `frames` and `duration` on the
  recorder count the segment in hand too, for the menu's length.
- **Step 1 corrected.** The frame size changes between openings when the 1080p/4K
  setting does, and the recorder had then started a fresh manifest over the old
  segments, the next segment named `0001.mov` again; it now keeps the segments and
  takes the new size, the movie fitting the old ones in. A segment's last frame lasted
  as long as the previous one, so a segment of one frame, a document opened and closed,
  had no length; the writer's session now ends a frame on, and a one-frame segment is
  a thirtieth of a second. The count of frames in flight was kept on the main queue,
  which a busy main thread could hold up until frames were skipped; it is under a lock.
  A frame still on the GPU when the segment finished was skipped, so the last stroke
  before a save or a close never reached the file though the manifest counted it; the
  frame is now appended from the GPU's own completion and the finish waits, up to a
  second, for frames in flight. An empty segment is cancelled rather than finished
  and dropped.
- **Tests** in `TimelapseTests`: a one-frame segment lasts a thirtieth; a frame committed
  and the segment finished before the GPU has run it is in the file; 300 changes over
  two segments play 10 s at full length, export to a 96 × 64 MP4 of 10 s and 300 frames
  with the progress reaching 1, cut to 2 s export 60 frames at 30 a second, a 30-second
  cut of a 10-second recording is 10 s, and the change after a replay goes into a third
  segment; a segment recorded with the frame held to 96 is kept when the document is
  opened with the setting raised, and the movie and its export are at the new 192 × 128
  with five frames; a folder with no recording has no movie. The Mac suite passes, 304
  tests with 3 skipped; the iOS app builds.
- **Not done yet.** The menus, the player sheet, Photos and the share sheet, the save
  panel and Settings (step 3); the hand check (step 4).

## Checked on 2026-10-27, step 3

The menus, the player, export to a file, Photos and the share sheet, Settings and
Delete, built on the branch `timelapse`.

- **The ≡ menu** on both platforms has a Time-lapse submenu (`TimelapseMenu` in the
  bottom bar's file): Record Time-lapse as a checkmark, Replay…, Export Full Length…,
  Export 30 Seconds…, Delete Time-lapse… in red, and a line with the recording's length
  and size, "3 min 20 s, 212 MB", the frames instead under a second, or "Nothing
  recorded yet". The recorder is observable and the renderer nudges the view model when
  one is attached, so the submenu's line and switch are fresh each time it opens: a
  SwiftUI menu's items are built when the view renders, not when the menu opens, and
  the first version showed the size from the first opening. The Mac's File menu has the
  same submenu, filled in as it opens like Open Recent.
- **The switch** turned on for a canvas with no recorder starts one, into the document's
  folder when the canvas has a URL and a temporary folder otherwise, that the next save
  carries in (`CanvasDocument.setTimelapseRecording`). Delete asks, then takes the
  segments away and keeps the switch; recording goes on into a first segment again.
- **Replay** is `TimelapsePlayerView` in the shared UI: an AVKit player with the
  movie's length, frames and size over it, an Export menu for the two lengths, and
  Done. The Mac shows it in a window sized to the frame, up to 960 wide; iPad in a form
  sheet over the canvas. A full-length replay of segments all at the frame size plays the
  composition without the video composition; a cut or a mixed-size recording carries it.
  The simulator's player cannot run a video composition at all (AVFoundation -11800
  with nothing underneath), though its export and the Mac's player can, which is how
  that split was found; it decodes HEVC fine.
- **Export** finishes the segment in hand, loads the movie at the chosen length and
  writes the MP4 with a progress sheet and Cancel (`TimelapseExportView`): on the Mac
  through the save panel to a file named "Canvas Time-lapse.mp4" or "… 30 s.mp4"; on
  iPad and iPhone into a folder of its own and then the share sheet, whose Save Video
  puts it in Photos and whose Save to Files, Mail and the rest are there too, with the
  photo-library usage line in the iOS Info.plist for it. An export that fails says so in
  an alert; a cancelled one says nothing.
- **Settings ▸ Time-lapse**, a fourth tab on both platforms: Record new canvases, and
  the frame size as 1080p or 4K, with what each costs.
- **On the iPad simulator**: the submenu with "6 frames, 36 KB" fresh after a replay, the
  checkmark on, Export Full Length… bringing up the share sheet with "Canvas 3
  Time-lapse, Video · 13 KB" and Save Video, a new canvas's three strokes replayed in the
  sheet, the HEVC recording from step 1 replayed too, and the Settings tab.
- **Also fixed.** A temporary recorder that a save had carried into the document still
  removed the document's time-lapse folder when the canvas closed, since the folder was
  the one it had been told was temporary; `moved(to:)` now clears that. The start
  screen listed the same document once per container path, since iOS moves the app's
  container when the app is updated (the simulator does on every install); a note now
  matches an entry by its bookmark when the path has changed, with a test that moves
  a document's folder.
- **Tests** added: Delete takes the segments and keeps the switch, the switch turned on
  with no recorder starts one, a segment a crash left without its count still plays,
  lengths described as the menu shows them, the summary under a second, the temporary
  recorder leaving the document's folder, and the moved document in the recents. The
  Mac suite passes, 310 tests with 3 skipped; the iOS app builds.
- **Not done yet.** The hand check on the Mac (step 4): the File menu, the player window,
  the save panel and the Settings window have only been compiled, not driven. A real
  iPad has not been tried; the simulator cannot show whether the 30-second cut's video
  composition plays in the sheet there, only that it exports.
