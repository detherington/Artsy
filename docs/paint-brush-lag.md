# Lag on the paint brushes

On 2026-10-29 Darrell found the paint brushes lagging the pen, worst at large sizes, on
the iPad Pro and the iPhone Duo alike, with or without pressure. The Mac's own diagnostics
log from 2026-10-08 already had the shape of it: with Oil at 145 px on an M4, frames took
0.15 ms to encode on the CPU but the GPU's 95th percentile was 15 ms and its worst frame
229 ms, while drawing. The GPU, not the input path, was behind.

## Where the time went

A benchmark (`StrokeBenchmarkTests.testPaintBrushFrameCost`, `BENCHMARK paint-frame`
lines) draws a fast stroke, 25 px a frame at 120 frames a second, over paint on a 2048²
canvas and times the GPU per frame, for Oil as it is and Oil with its push, its thickness
and its load taken away in turn. On the M4, median GPU milliseconds a frame before the fix:

| Brush | 60 px | 150 px | 300 px | 500 px |
|---|---|---|---|---|
| Oil | 2.2 | 3.5 | 4.7 | 5.9 (p95 11.2) |
| Oil without its push | 0.5 | 0.4 | 0.5 | 0.6 |
| Oil without thickness | 0.4 | 0.3 | 0.4 | 0.5 |
| Oil colour only | 0.2 | 0.2 | 0.3 | 0.5 |
| Acrylic | 1.5 | 3.3 | 4.4 | 5.4 |
| Palette Knife | 0.4 | 0.2 | 0.2 | 0.3 |
| Soft Round | 0.1 | 0.1 | 0.1 | 0.2 |

The push was the whole of it: thick paint pushed out from under each dab to a band at its
rim (`impastoPushKernel`). For every pixel of the band it integrated along the ray from the
dab's centre, 64 steps, what the texels under the tip lost, and at each step evaluated the
tip's coverage, which for a bristle brush is a bundle of ten or twelve clumps, each a hash
and a handful of sines. Band pixels grow with the square of the size, so a 500 px Oil dab
ran to some fifteen billion operations, several a frame. The knife pushes too but its tip
is an image, one sample a step, which is why it stayed cheap. An iPad's GPU is the M4's
near enough; the Duo's is a few times slower, so the same stroke there took tens of
milliseconds a frame.

## What changed

1. **The rays once, not per pixel.** `impastoRayKernel` integrates the ray sum for
   `rayCount` directions round the dab, eight per pixel of the dab's size up to 4,096
   (`ImpastoPusher.rayCount(forSize:)`), into a small private buffer; the push kernel reads
   the two directions either side of a band pixel's and mixes them. Everything else about
   the push is as it was: what is lost under the tip, the falloff across the band, the
   forward bias. The sums are the same integrals, sampled a little more finely in angle
   than the band's outer pixels. The thick-paint tests and the goldens for Oil, Acrylic,
   the Palette Knife and the lit relief pass unchanged. The copy of the patch under each
   dab, which the push used to read while it wrote, went too: the rays are integrated
   from the height map before the push writes it, and the push reads only the pixel it
   writes, so a dab is one compute encoder instead of a blit and a compute encoder.
2. **Predicted touches for the tail (iOS).** UIKit says with each touch event where the
   pen is expected to be at the next frame. `PaintingView` hands those to
   `CanvasViewModel.predictStroke`, which readies them like real samples (pressure from
   speed, the guides, a preview through the smoother that leaves it where it was) without
   moving anything on. `StrokePath.points(predicting:)` gives the points the stroke would
   have through them: the settled points as they are, the provisional segment reshaped by
   the first prediction, the segments on through the rest. The renderer draws the tail
   through those and only the tail; the tail is wiped and redrawn every frame, so a wrong
   guess costs one frame and nothing is committed on its word. A resting pen clears the
   prediction. The Mac has no prediction to offer and is unchanged. This is the frame of
   lag every brush had on the iPad and the Duo, pressure or not, and what Procreate and
   the others do.

After the change, on the M4, median GPU milliseconds a frame:

| Brush | 60 px | 150 px | 300 px | 500 px |
|---|---|---|---|---|
| Oil | 1.6 | 1.3 | 0.8 | 1.1 (p95 1.4) |
| Acrylic | 1.0 | 0.8 | 0.7 | 1.0 |
| Palette Knife | 0.4 | 0.2 | 0.2 | 0.3 |

Oil at 500 px went from 5.9 ms to 1.1, Acrylic from 5.4 to 1.0; the frame no longer grows
with the brush. On a 4096² canvas the numbers are the same (Oil 1.6, 1.2 and 1.2 at 60,
150 and 500 px), so a dab's passes cost by the dab, not the canvas. What is left at small
sizes is the per-dab work itself: a push and a thickness pass per dab, ten or so dabs a
frame at 60 px, about a tenth of a millisecond each.

## Checked on 2026-10-29

- `testPaintBrushFrameCost`: the tables above, before and after.
- `ThickPaintTests`, `ImpastoTests`, `BrushGoldenTests` (Oil, Acrylic, Palette Knife and
  `thick-paint-relief` tiles unchanged), `EveryBrushTests`, `SmudgeBrushTests`,
  `LoadedBrushTests`: all pass after the push change; the whole Mac suite, 319 tests with
  3 skipped, passes after everything.
- The iOS app builds, and on the iPhone Duo simulator an Oil stroke drawn with a finger
  goes through the prediction path and logs as before ("Oil 30 px: 21 samples … pressure
  from speed, finger"). The simulator has no Pencil and its GPU is the Mac's, so the feel
  and the frame times on the iPad Pro and the Duo themselves are still to be checked in
  the hand: a diagnostics export from either will show the frame lines' GPU p95 while
  drawing, which on the Mac log had been 15 ms.
- New tests: `StrokePathTests.testPredictedSamplesExtendThePointsWithoutChangingThePath`
  (the path is unchanged, the settled points stay, the tail reaches the last prediction,
  the reshaped provisional segment is what the path settles to when that sample comes, and
  a tap predicts on from itself); `StrokeSmoothingTests.testPreviewingLeavesTheSmootherWhereItWas`
  (every mode: the preview is what the filter would do, and the filter does just that
  after); `CanvasViewModelTests.testPredictedTouchesDrawTheTailAheadAndCommitNothing`
  (the tail shows through the prediction and no further, a resting pen clears it, nothing
  of it lands, and the layer is pixel for pixel the one drawn without any prediction).
