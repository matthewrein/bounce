# Slab Bounce test bed

Synthetic phone-camera clips of the slab, fed to `index.html` through Chrome's fake camera, scored
against ground truth. Everything runs headless in this folder.

```
cd tests
npm install                       # three.js (the renderer); Playwright's Chromium must already be installed
node render.js                    # render all clips into out/clips/ (cached; --force to redo, --filter to pick)
node run.js --label base          # score index.html on every clip, save out/results/base.json
node compare.js base next         # clip-by-clip regressions and improvements between two runs
```

## What gets rendered (`scene.js`, `clips.js`)

A three.js scene in headless Chrome (SwiftShader WebGL): a 7 in cement slab, 0.9 in thick, top gently
curved and edge slightly chamfered, sitting tilted on a faceted black base, on a floor, plus an optional
35 mm chrome ball (it reflects the actual scene through a cube camera) held in a pinch grip or dropped.

Clips are 720x1280 portrait at 30 fps with a 72.5 deg vertical lens (what the real phone's lens setting
self-calibrated to). Each clip varies some of: distance 3-5 ft, slab tilt 0-18 deg and its heading,
camera height and pitch, aim off-centre, roll, floor (gridded mat, wood, concrete, plain, carpet, near
black), light level and direction (including raking light that leaves one slab side with almost no
contrast), hand shake (slow sway plus tremor), motion blur (sub-frame rendering over the exposure time),
auto-exposure lag and deliberate drift, sensor noise with in-camera denoise smear in low light, JPEG
compression, radial lens distortion and a lens-angle mismatch, slab aspect 1.03 and stronger curvature,
a ball held at 1-3 ft or dropped, a ball held off the slab, round distractors (tins, coins, stickers, a
chrome ball on the floor), and clips with no slab (clutter, a grey rectangle on a black pad, the black
base alone).

Ground truth per frame (`gt.json`): slab corner pixels (the virtual sharp top corners; the plane through
them defines the true normal), slab normal and gravity in camera coordinates, true tilt, distance, ball
centre and radius in pixels, whether it is held and over the slab, and its drop height (straight down
from the ball to the plane through the corners, minus its radius). Motion-sensor samples at 60 Hz
(W3C DeviceMotionEvent conventions, device axes = camera axes): accelerationIncludingGravity (including
the hand's own acceleration and a small fixed calibration error), acceleration, rotationRate; one clip
uses the opposite sign convention and omits `acceleration`.

Textures are procedural by default (grey speckled cement, a lighter porous cut edge, scratched black
base, floors). `node render.js --private` swaps in crops of the private reference photos if they exist
in `tests/private/textures/`; those renders go to `tests/private/clips/` and must never be committed.

## How a clip is run (`run.js`, `harness.js`)

Chrome is launched with `--use-file-for-fake-video-capture=clip.mjpeg`, so `getUserMedia` and the app's
`<video>` work as on a phone. In the default **step** mode the page's `requestAnimationFrame` is driven
by the runner at 60 Hz ticks (each 30 fps frame is seen for two ticks, as on the phone), and at draw time
the video is swapped for the exact clip frame for that tick, so runs are frame-exact and repeatable.
A devicemotion event with the matching sample is dispatched before each tick. After every tick the runner
reads `window.slabDiagnostics()` - the same JSON the Copy diagnostics button produces.

`--mode live` instead lets the fake camera play in real time with the app's own animation loop; each
processed frame is identified by thumbnail matching. Use it to check real-time behaviour (frame drops,
frame times); decisions are made on step mode.

`--stills` also runs the private reference photos through the app's "Use a photo" path and scores the
outline against hand-marked corners in `tests/private/stills.json` (private).

## Metrics (`score.js`)

Per clip and overall:

- **lock%**: share of frames with the whole slab in view where the shown outline is within
  max(6 px, 12% of a side) of the true corners. **ttl**: seconds from the slab coming into view to the
  first correct lock. **FL**: false locks - an outline shown with no slab in view (after a 0.5 s hold) or
  more than 25% of a side away from it.
- **cErr**: mean corner error (px) once settled (0.5 s after locking).
- **tilt**: median angle (deg) between the app's slab normal and the true one; **p90**; **tRd**: error of
  the tilt reading itself (angle from level, which also carries the motion sensor's error).
- **jit**: wobble of the normal while the phone is held still - the spread of (app normal - true normal),
  so real hand motion doesn't count; **tJit**: spread of the tilt reading while still.
- **ball%**: share of frames with the ball held over the slab (and the slab locked) where the app's ball
  is on the true ball; **bFP**: false ball detections (events); **drop**: median drop-height error (in).
- **msS / msT**: app processing time per frame while searching / tracking (measured inside the app, on
  this machine's CPU - compare runs with each other, not with the phone).
