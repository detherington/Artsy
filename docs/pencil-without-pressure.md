# A pencil without pressure

The iPhone Duo pairs only with the USB-C Apple Pencil, by cable; the first and second
generation and the Pro do not pair with it. Support arrived in iOS 27.2, about
2026-10-26. That Pencil reports tilt but no force: `UITouch.force` is 0 and no force
estimate is expected, so Artsy marks the stroke as having no pressure and takes its
pressure from speed, as it does for a finger or a mouse. On 2026-10-28 Darrell found the
Pencil on his Duo drew very faint.

## Why it was faint

The speed curve was a hand's: full when still, 0.2 at 2,500 points a second, falling away
faster at first. A pen is held like a pen and moves two or three times faster than a
finger, so quick handwriting sat at the light end:

| Hand speed | Pressure |
|---|---|
| 500 pt/s | 0.77 |
| 1000 pt/s | 0.57 |
| 1500 pt/s | 0.40 |
| 2000 pt/s | 0.27 |

On top, every brush's tilt dynamics lower opacity as the pen leans, to 0.55 of full for the
Pencil brush when flat, since a lighter mark stood for the lighter touch of a pen laid on
its side. A Pencil held like a pen leans, so a quick stroke was light twice over. With the
speed substitute off, the Pencil's pressure was 0 divided by the device's maximum: nothing.

Other apps with a pen that cannot press: Affinity takes pressure from velocity for a mouse
or finger; Notability's Pencil tool thickens with tilt; Procreate ties tilt to size and
opacity per brush and has a global pressure curve; Clip Studio lets each brush parameter
follow pressure, tilt, velocity or chance, and carries a free tilt-only pen for this
Pencil; Apple's Notes and Freeform draw at the tool's weight.

## Plan

1. **A pen's pace.** `StrokeInput` names what is drawing: a pen, a pen without pressure, or
   a hand (finger, mouse, trackpad). `PressureFromSpeed.Pace` holds the speed curve's two
   numbers; the hand's are the old ones, the pen's are lightest 0.5 at 4,000 points a
   second, so handwriting at 1,000 to 2,000 keeps 0.8 to 0.65 of its weight. The iOS view
   passes `.penWithoutPressure` for a Pencil that reports no force, and such a Pencil's
   samples carry the finger's constant 0.7 rather than 0, so the substitute off draws a
   plain line. The recording keeps the input, and older recordings replay by `hasPressure`.
2. **Leaning widens, does not fade.** For a pen without pressure the brush's tilt dynamics
   are taken `withoutFading`: the same size scale and aspect, opacity scale 1.
3. **The Soft curve to start.** A pen without pressure beginning a stroke with the Linear
   curve, when no curve has been chosen for this pen, switches the view model to Soft. A
   curve picked in the panel is saved for the pen and stands, Linear included.

The Settings note under "Press harder when slow" says so. The diagnostics line at pen-up
reads "pressure from a pen's speed, pencil" for such a stroke.

## Checked on 2026-10-28

Six new tests in `PenWithoutPressureTests`: the pen's pace is full when still, 0.5 at
4,000 points a second and no lighter, falls monotonically, and keeps at least 0.1 more
than the hand's from 500 to 4,000 points a second, above 0.8 at 1,000 and 0.65 at 2,000
where the hand is under 0.3; a stroke begun as a pen without pressure takes the pen's pace
and one begun as a hand the hand's, while a pen's own pressure is left alone; leaning a pen
without pressure widens the Pencil brush's mark more than 1.5 times and lengthens the dab
with the opacity unchanged, while the same lean fades a pen with pressure as before; the
Soft curve arrives for a pen without pressure only when the curve is Linear and none was
chosen for the pen, and a curve picked in the panel stands, Linear included; the recording
says which input drew the stroke, turns to a pen when force arrives, decodes without the
field as a pen or a hand by `hasPressure`, and round-trips; and on the canvas a 200-pixel
line in 0.12 s is more than 1.5 times heavier from a pen without pressure than from a
finger. The Mac suite passes, 316 tests with 3 skipped; the iOS app builds.

Not yet checked: the Duo itself. The simulator has no Pencil, so the pen-up lines of a
diagnostics export from the Duo ("pressure a–b, tilt t, … pressure from a pen's speed,
pencil") are what will say whether the weight is right in the hand.
