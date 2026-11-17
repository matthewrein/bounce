# Improvement log

Every attempt is scored on all synthetic clips in step mode (frame-exact, repeatable) and compared clip by
clip with the previous accepted build (`node compare.js <before> <after>`). A change is kept only if no clip
gets worse beyond the noise allowances in `compare.js`; otherwise it is reverted or reworked. Frame times are
measured inside the app on this test machine's CPU (a 2.1 GHz x86 server core; the app's 2D canvas work runs on the CPU),
so they are only comparable between runs here, not with the phone.

The three reference photos are also run as stills; only their aggregate corner error (as % of the slab side)
is recorded here.

From b13 on, every build is run at two camera phases (the fake camera starting 0 or 1 display tick later) and the
numbers are averaged; see "Comparing builds" below.

Columns: lock = % of slab-in-view frames with a correct outline; never = clips that never lock; FL = false-lock
events; cErr = mean corner error px; tilt = median angle between app and true slab normal (deg, median over
clips of per-clip medians); worst = worst clip's median; >1.5 = clips whose median is 1.5 deg or more;
jit / tJit = median over clips of normal / tilt-reading wobble while held still (deg); ball = % of held-ball
frames detected; bFP = false ball events; msT / msS = mean ms per frame tracking / searching (* = measured alone on an
idle machine; other rows ran three clips at once and are only comparable with each other).

| build | lock | never | FL | cErr | tilt | worst | >1.5 | jit | tJit | ball | bFP | msT | msS | photos cErr % |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| b12 baseline (phase 0 only) | 81.3 | 4 | 6 | 4.72 | 5.13 | 13.37 | 34/43 | 0.366 | 0.562 | 3.7 | 0 | 23.2 | 72 | 1.3 / 0.5 / 0.2 |
| b12 baseline (2 phases) | 82.0 | 4 | 6 | 4.72 | 5.15 | 13.40 | 34/43 | 0.361 | 0.579 | 2.3 | 0 | 21.8 | 68 | 1.3 / 0.5 / 0.2 |
| b13 clean gravity (kept) | 82.0 | 4 | 6 | 4.72 | 5.15 | 13.40 | 34/43 | 0.361 | **0.219** | 2.3 | 0 | 23.5 | 74 | 1.3 / 0.5 / 0.2 |
| b14 gyro-steadied smoothing (kept; 49 clips) | 82.3 | 4 | 6 | 4.80 | 5.21 | 13.21 | 36/44 | **0.276** | **0.178** | 2.3 | 0 | 22.7 | 72 | 1.3 / 0.5 / 0.2 |
| b15 default (cut-edge correction off) = b14 | 82.3 | 4 | 6 | 4.80 | 5.21 | 13.21 | 36/44 | 0.276 | 0.178 | 2.3 | 0 | - | - | 1.3 / 0.5 / 0.2 |
| b16 ball: upper outline accepted (kept; 61 clips) | 84.3 | 4 | 6 | 4.78 | 5.2 | 13.2 | - | 0.300 | 0.172 | **20.7** | **0** | - | - | 1.3 / 0.5 / 0.2 |
| b18 (rotation rates shown with the engines' naming) | 84.7 | 4 | 6 | 4.78 | 5.22 | 13.3 | - | 0.359 | 0.218 | 21.9 | 0 | 12.8* | - | 1.3 / 0.5 / 0.2 |
| **b19 gyro guard (kept; 64 clips, engines' naming)** | **85.1** | 4 | **5.5** | 4.74 | 5.17 | 13.4 | - | **0.215** | **0.152** | **22.7** | **0** | 11.8* | - | 1.3 / 0.5 / 0.2 |
| b19 with "Correct for the slab's cut edge" on (64 clips) | 85.3 | 4 | 8 | **2.63** | **1.18** | 13.4 | 18/57 | 0.373 | 0.241 | 22.8 | 0 | - | - | 1.3 / 0.5 / 0.2 |
| b15 with "Correct for the slab's cut edge" on | 82.7 | 4 | 7 | **2.63** | **1.30** | 13.2 | 15/42 | 0.345 | 0.241 | 2.3 | 0 | - | - | 1.3 / 0.5 / 0.2 |

## b12 - baseline (instrumentation only)

b11 plus `window.slabDiagnostics`, per-frame processing time, and more decimals in the diagnostics.

What the baseline shows:

- **Tilt is biased by the slab's visible cut edge.** On every clip where the camera sees one of the slab's
  side faces (the usual oblique view), the outline's near side snaps to the bottom of that face (where the
  light cement meets the black base, the strongest edge) instead of the top edge. The fitted square is then
  taller than it should be and the normal is off by 4-7 deg (13 deg with a brightly lit side face). Clips
  where no side face is visible (near top-down view, overhead light that leaves the face dark) are at
  0.4-1.6 deg. The reference photos show the same light cut edge below the top face.
- **The held ball is almost never found** (3.7% of frames): a pinch grip hides 20-25% of the rim, and the
  detector needs 81% of it. The lower half of a mirror ball reflects the floor and has little contrast
  against it. No false ball detections on these clips (the real phone had 3 in 37 samples).
- **False locks** (6) are stale outlines: during a fast pan, the tracker loses the slab and holds the last
  outline for 12 frames; and the sweep can return a candidate found several frames earlier, so the first lock
  during a pan is already 70 px off.
- **Never locks**: a shadow of the arm across the slab (two clips), a shallow 30 deg view at 5 ft, a dim mat
  about as dark as the cement.
- **Wobble while still** is 0.37 deg (normal) / 0.56 deg (tilt reading), above the 0.3 deg target.
- **Frame time**: 23 ms tracking (p95 109 ms, from the slow colour fallback), 72 ms searching.

## Comparing builds: the tracker is chaotic, so compare two camera phases

The first attempts showed that the tracker is very sensitive to tiny input changes: running the *unchanged* b12
with the camera starting one display tick later (`run.js --phase 1`) moves 54 clip metrics beyond the strict
allowances (one clip loses lock for 38 ticks in one phase and not the other, and so on). Judging a change on a single
run would accept or reject it partly by luck. So from here on each build is run at phases 0 and 1,
`compare.js a+a_p1 b+b_p1` averages them, and each clip's own phase-to-phase spread is added to its allowance.
A clip whose run fails counts as worse.

## Attempt 1 (reverted, parked): prefer the top edge over the cut edge's bottom

Idea: on the sides where the slab's cut edge shows, the outline should follow the innermost straight edge (where the
top face ends) rather than the strongest one (where the light cut edge meets the black base).
Implemented as a search, inside each fitted side, for a weaker parallel edge: first per spoke (too insensitive: the
top/cut-edge step is about 8 grey levels against 70 for the base), then on gradient profiles averaged over the whole
side and every candidate line (finds it), gated to the sides whose cut face can be seen from the camera at a depth
consistent with a ~0.9 in slab, with hysteresis, and with a remembered band width per side.
Best version: median tilt error 5.13 -> 1.59 deg, corner error 4.72 -> 3.08 px, and the top-down photo's corner
error 1.3% -> 0.8% of the side. But wobble while still rose 0.37 -> 0.53 deg and some clips got worse (curved slab,
matched-tone mat, several jitter values): the inner edge is found on some frames and not others, and when it isn't,
the outline falls back to the outer edge or through the slow colour search, which knows nothing of the band.
Reverted; parked for after the smoothing work. Two bugs found on the way (sign of the profile alignment; scoring the
flank of the main edge as an inner edge) are fixed in the parked copy.

## Attempt 2 (reverted): innermost significant straight edge on every side

Same averaged-profile scoring, used for every side and replacing the original "first clear edge from the middle"
rule. Much worse: lock 82 -> 77%, false locks 7 -> 14, wobble 0.37 -> 0.95 deg, the angled photos' corner errors
up to 1.6% of the side. Shading and texture on the top face pass the significance test often enough to pull sides
inward. Reverted.

## Attempt 3 (reverted): keep one side's previous line when the outline fails the shape test

Meant to stop one bad side from throwing the tracker into the slow colour search. Made things worse
(overhead-light clip 0.6 -> 6.3 deg): a stale side can keep a wrong outline plausible, so it sticks. Reverted.

## b13 - clean gravity for the tilt reading, the drop and the bounce (kept)

`accelerationIncludingGravity` includes the hand's own acceleration (hand sway of a few mm at ~1 Hz is ~0.1-0.3 m/s^2,
i.e. 1-2 deg of error in "down"). When the browser also provides `acceleration` (iOS does), subtracting it leaves the
phone's own sensor-fused gravity. b13 uses that for the tilt reading, the ball's drop direction and the bounce; the
slab finder's weak "roughly level" prior and its tilt sanity check keep the old estimate, so the vision pipeline
behaves exactly as before (an earlier version that switched everything over perturbed the chaotic tracker and lost
lock in one clip in both phases). Diagnostics now include `sensor.gravityClean`.

Result (2 phases vs b12): tilt-reading wobble while still 0.579 -> 0.219 deg (median over clips; 35 clips better);
the one flagged regression is pan_out_back's tilt reading, 4.89 -> 5.28 deg. Checked directly: that clip's gravity
error drops 1.26 -> 0.36 deg (p90 4.06 -> 1.50); the old gravity's error happened to offset part of the vision
error (5.4 deg there). Kept. The clip with no `acceleration` (ios_sign_noacc_d4) is unchanged, as expected.

## Review of b13 (separate reviewer agent)

Checked WebKit and Chromium sources: on iOS, `acceleration` and `accelerationIncludingGravity` come from the same
CoreMotion sample, in the same units and sign, so their difference is CoreMotion's own gravity - the test bed models
iOS faithfully there. Risks found: on phones without a gyroscope WebKit sends `acceleration` as zeros and Chrome
synthesises it from a lightly smoothed accelerometer, which makes the "clean" gravity slightly worse than b12's; and
on Android the two readings can arrive up to a frame apart. The reviewer added two clips at the end of `clips.js`
(new options in `scene.js` `sensorQuirks()`; existing clips render identically): `android_lag_d4` (acceleration up
to 16 ms late, readings rounded to 0.1, stronger tremor) and `android_nogyro_d4` (Chrome's no-sensor fallback, no
gyro), and proposed a guard - use the clean gravity only with a gyroscope present and when the difference is about
one g (7-12.5 m/s^2). Adopted in b14: `android_nogyro_d4` then behaves exactly as b12, `android_lag_d4` keeps b13's
gain (gravity error 0.72 -> 0.33 deg).

## Attempt 4 (parked): slab thickness model for the top edge

After attempt 1, a model-based version: for each side whose cut face the camera can see, predict the band's width from
the pose and a thickness setting (new Tune slider, default 0.9 in); if it is dark just outside the side's edge (the
black base) and a faint parallel edge shows about one band-width inside, the side is moved in by the band (with a
per-side confidence and a learned width ratio while tracking). Best version: median tilt error 5.17 -> 1.33 deg
(e.g. 5.4 -> 0.5 deg at 4 ft, a 1.15 in slab 9.3 -> 2.9 deg), corner error 4.8 -> 2.7 px, photos unchanged. Not
accepted yet: wobble rose 0.36 -> 0.51 deg (the edge used as anchor alternates between the top edge and the cut
face's bottom) and the strongly curved slab got worse (0.7 -> 3.2 deg). Variants that went wrong on the way:
learning the thickness online (it drifted to 1.26x from spurious inner edges and over-corrected), anchoring on the
strongest edge (lost the photos: photo 3 not found), a hard dark/not-dark cut-off (sides flipped between two places).
Parked to be rebuilt on top of the gyro-steadied smoothing below.

## b14 - gyro-steadied smoothing (kept)

The outline and the slab normal are smoothed over frames in camera coordinates, so while the hand sways the
smoothed values lag behind the camera's turning: heavy smoothing lags, light smoothing passes noise. b14 turns the
previous outline, slab normal and slab position by the rotation the gyroscope measured since the last frame before
blending in the new measurement, then smooths a little more (0.05 instead of 0.08 per frame for corners, 0.08 instead
of 0.12 for the normal); the clean "down" is turned the same way before each new sample. The outline is only turned
for small turns (gyro under 8 deg/s, a hand holding the phone): in bigger, deliberate moves the phone also travels and
rotation alone predicts the wrong image motion. Directions are always turned.

Browsers may disagree on the sign of the rotation rates, so the app calibrates: it regresses the measured motion of the
outline's middle on the gyro-predicted motion and uses the gyro only once the gain settles near +1 (or near -1, in
which case the sign is flipped); otherwise it smooths as before. Diagnostics show `gyro: {sign, gain}`. The reviewer's
gravity guard is also in b14.

Bugs found while testing: rotation that accumulated while the slab wasn't tracked was applied in one go on relocking
(lost lock in pan_out_back); the outline was turned during an orbit (rotation plus travel) - both fixed above.
Turning only the normal but not gravity (or the reverse) made the tilt reading wobble more in two clips; fixed by
turning both consistently.

Result (2 phases vs b13, 49 clips): no clip worse, 53 metrics better. Median wobble while still 0.361 -> 0.276 deg
(normal) and 0.223 -> 0.178 deg (tilt reading), e.g. 4 ft mat clip 0.22 -> 0.13 deg. Tilt accuracy unchanged (still
biased by the cut edge; see attempt 4).

## b15 - the cut-edge correction as an opt-in setting (kept, off by default)

Attempt 4 rebuilt on top of b14, then tuned: the width of the band is learned only from edges seen *inside* the
side (seen from outside, the black base's own far edge looks just like the band's bottom and taught it a 1.3x
width), and a side's confidence fades three times faster when the inner edge stops showing.

With it on, against b14 (2 phases, 49 clips): median tilt error 5.21 -> **1.30 deg**, corner error 4.80 -> 2.63 px;
31 of 42 slab clips more than 0.3 deg better, clips under 1.5 deg go from 6 to 27 (e.g. 4 ft mat 5.4 -> 0.5,
a 1.15 in slab seen low 9.3 -> 2.9, panning clip 5.4 -> 0.9). But: wobble 0.276 -> 0.345 deg (normal) and
0.178 -> 0.241 deg (tilt reading); the strongly curved slab (0.25 in sag) 0.6 -> 3.4 deg; one more false-lock
event; 76 clip metrics flagged in all. Photos unchanged. By the "never make a clip worse" rule it cannot be the
default, so b15 ships it as a Tune switch, "Correct for the slab's cut edge (experimental)", off by default and
remembered on the phone, with a "Slab thickness" slider (default 0.9 in, also remembered). With it off, b15 matches
b14 on every accuracy metric of every clip. Diagnostics report `set.cutEdge`, `set.thick` and `thicknessSeen` (the
band width actually measured, in inches), so real footage can show whether the correction helps and whether the
thickness setting is right.

Why it isn't simply better: deciding which of two parallel straight edges is the top face's edge is ambiguous in
three situations the clips cover - a cut face in shadow (dark like the base), the black base's own edge just outside
the cut face, and a slab whose top edge bows (curved slab). Each fix for one moved error to another.

## b16 - find a held ball from its upper outline (kept)

Why the held ball was missed: the detector wanted 81% of the ball's outline. Held above the floor and seen from above,
a mirror ball's lower half reflects the very floor that lies behind it, so its outline there is all but invisible
(measured: luma 105-113 both inside and outside the rim on the lower spokes), and a pinch grip hides part of the top.

b16 keeps the full-outline path and adds a second one: the radius is chosen from the upper half's spokes only, and the
ball is accepted if at least 14 of the 24 upper spokes agree on a tight circle (rms under 0.6 px) at a size that puts
it no further away than the slab, and if the inside of its upper half looks like a mirror (a highlight 40+ grey levels
above the floor just outside, and plenty of light/dark detail). A ball found this way is shown only once two scans in
a row agree on it (or it continues the ball already shown).

New distractor clips with round things *behind* the slab, so they appear above it in the image (fp_tin_behind_d4,
fp_lid_sticker_behind_d5, fp_floorball_behind_d4): the first version of this change fired on a black-lidded tin there;
the mirror-appearance test removed that. Result (2 phases vs b15): held-ball detection at 4 ft 0 -> 53% of frames
(drop-height error 1.4-1.8 in), 5 ft with the ball 3 ft up 0 -> 7%, dim light 0 -> 2%; false ball detections still
0 on all 61 clips; no other clip metric changed.

## b17 - a briefly lost outline keeps turning with the phone (kept); re-finding the sweep's pick (reverted)

False locks in the pan clips come from stale outlines. Two fixes were tried:
- The sweep keeps the best slab it found over a whole pass of the picture, several frames long, so while the phone
  turns its pick is out of date. Re-finding it in the current frame before locking cut time-to-lock in the pan-in
  clip 0.69 -> 0.14 s and false locks in pan-out-and-back 3 -> 2, but re-finding from the pick's middle fails
  too often elsewhere (outdoor clip never locked; with the re-find limited to a turning phone, the orbit clip still
  locked 0.7 s later and the pan-in clip had one more false-lock event). Reverted.
- While the slab is lost for a moment (up to 12 frames), the held outline used to stay put. With the gyro's sign
  known, it is now turned with the phone. Result (2 phases vs b16): no clip worse; fp_lid_sticker_behind_d5 lock
  81 -> 96%, gyro_bias_d4 tilt 3.04 -> 2.81 deg. Kept.

## b18 - less work per frame (kept)

Profiled on this machine with nothing else running (tracking, 4 ft clip): 15.1 ms per frame, of which the ball search
5.9 ms, frame preparation 5.8 ms, edge tracking and pose about 3 ms.
- Frame preparation drew a downscaled copy of the whole picture on every frame, but while tracking it is only read on
  the frames that also run the colour search (every 15th, and recoveries). It is now drawn only then. Same pixels.
- While a ball is being followed, the ball search only covers a box four radii around it.
- Tried and reverted: searching the whole picture for a ball on every fourth frame instead of every second when none
  is shown. Faster, but a ball seen only by its upper outline needs two scans in a row, and the 5 ft and dim clips
  lost their few detections (11% / 2% -> 0%). The comparison didn't flag it (those clips' phase-to-phase spread is
  as large as the change), which the per-clip check below caught.
Result: tracking 15.1 -> 12.8 ms (4 ft clip without a ball) and 11.8 ms (with a ball), measured alone; no clip worse;
ball detection per clip identical to b17 (ball_held_d4 46/60%, d5_high 11/2%, dim 0/1% in the two phases).

## Review of b14 (second reviewer agent) and b19 - the gyro guard (kept)

The reviewer checked the WebKit (`DeviceMotionClientIOS.mm`), Chromium (`device_motion_event_pump.cc`) and Gecko
sources: all three report `rotationRate.alpha/beta/gamma` as the rates about the phone's x/y/z axes (as the current
W3C draft does). b14 and the test bed both used the older 2016 naming (alpha about z), so they only agreed with each
other: on a real phone b14's calibration would never have settled and the gyro step would have done nothing (harmless,
but useless), and under Chrome's naming one clip locked onto wrong axes. Also verified: WebKit reports
`interval` in seconds (b14 read it as milliseconds, making the turn 17x too small), units are deg/s everywhere, and
the gyro mapping ignored the screen's rotation. The reviewer added 12 clips at the end of `clips.js` (real namings,
iOS interval, flipped/single-axis-flipped/biased/rad-s gyro, gyro leading the camera, body sway, walking) and wrote
the guard adopted here as b19: both namings are accumulated; one is used only when over two-tick windows its predicted
motion correlates with the measured motion above 0.5, beats the other naming by 0.25, with a gain of 0.6-1.5 (sign
from the gain); an `interval` below 1 is read as seconds; the gyro axes follow the screen angle like gravity's; the
outline is turned only while the fit stays above 0.3. Diagnostics: `gyro: {sign, naming, gain, fit}`.

The runner now shows the page the engines' naming by default (`--gyroNames engines`; clips are remapped at run time,
no re-rendering), since that is what phones send; `--gyroNames 2016` reproduces the earlier runs.

Results, 2 phases, 64 clips:
- With the engines' naming (realistic) vs b18: median wobble 0.359 -> **0.215 deg** (normal) and 0.218 -> **0.152 deg**
  (tilt reading), 89 metrics better. One flagged: distract_mat_circles tilt 1.21 -> 1.59 deg. That clip's tilt swings
  between 1.13 and 1.51 deg for b18 alone across phases and namings (1.16-1.66 for b19), so I judged this to be within
  its noise and kept b19 - a judgement call, recorded here so it can be challenged.
- With the old naming vs b18: 38 metrics better; flagged distract_tin_coin tilt 4.0 -> 5.9 deg (that clip is bimodal,
  3.5-5.2 deg for b18 alone; under the engines' naming b19 is better, 2.0-3.0 deg) and rect_slab_d4 wobble
  0.217 -> 0.264 deg (0.354 -> 0.136 deg under the engines' naming).
- Photos unchanged. False ball detections 0. Tracking time 11.8 ms on the 4 ft ball clip alone.

## Final state (b19) and checks outside the main comparison

- **Cut-edge correction, re-measured on b19** (switch on vs off, 2 phases, 64 clips): median tilt error 5.17 -> 1.18 deg,
  corner error 4.74 -> 2.63 px, drop-height error 1.50 -> 1.04 in; 42 of 57 slab clips more than 0.3 deg better, only
  the strongly curved slab worse (0.6 -> 3.3 deg); clips under 1.5 deg 7 -> 39 of 57. Costs: wobble 0.215 -> 0.373 deg
  (normal) / 0.152 -> 0.241 deg (tilt reading), false-lock events 5.5 -> 8. Still off by default (see b15).
- **Clips rendered with the private photo textures** (8 core clips; `render.js --private`, results kept in
  tests/private/): they behave like the procedural ones (median tilt error ~5.0 vs ~5.4 deg for the same 8 clips with
  procedural textures; lock rates 92-96%), which suggests the procedural stand-ins are adequate for these metrics.
- **Real-time mode** (`run.js --mode live`, the fake camera playing at 30 fps under the app's own animation loop) now
  works (frames identified by the video's clock): on 5 clips lock rate, accuracy, wobble and ball detection match step
  mode, but time to lock is 0.8-1.8 s instead of ~0.3 s, because searching costs 50-90 ms a frame on this machine and
  the sweep sees fewer frames per second. Tracking ran at 11-17 ms a frame.

## Generator v2 (after the slab owner's notes) - all clips re-rendered (SCENE_VERSION 2)

The owner described the real slab: the top is a shallow dish (curved both ways, about 1/8 in lower in the middle than at
the corners, so a ball bounces back toward the middle), about 1 in thick at the edge, and the ball is polished
titanium, not chrome. Changes to the scenario generator:
- **Slab**: the top is now a paraboloid dish (`slab.dish`, default 0.125 in; the edges sag by half that between the
  corners), 1 in thick by default (the convex 0.1 in "sag" of v1 was the wrong way round). New clips: flat top, dish
  1/16 in at 5 ft, 3/16 in at 3 ft, a 1/4 in dish (the old curved-slab clip), a 3/4 in slab.
- **Ground truth**: the plane through the four top corners still defines the slab's normal; new per frame for the
  ball: where it would land on the dish if dropped straight down, the drop height to the dish (`ball.drop`; the old
  plane-based height is `dropPlane`) and the dish's own normal there (`ball.hitNormal`), which the new **bounceErr**
  metric compares with the direction the app launches the ball (with no ball, the slab's middle).
- **Ball**: polished titanium (base colour of titanium, metallic, roughness 0.14; one clip 0.3), also the distractor
  balls on the floor. Ball dropped off-centre now bounces off the dish's own normal.
- **Camera**: rolling shutter (`cam.rs`, rows read out over 25-30 ms; rendered in 8 bands, ground-truth corners
  projected at their own row's time), frame hiccups (`cam.hiccup`: the camera now and then drops a frame, the previous
  one stays up longer), heavier tremor / lighter sway (`cam.tremor`, `cam.swayK`).
- **Light**: colour temperature (`light.kelvin`) with a camera white balance that only partly corrects it (`wb`), a
  second light with its own shadows (`light.second`), and something passing between the light and the slab whose
  shadow sweeps across it mid-clip (`light.passing`; invisible to the camera).
- 16 new clips at the end of `clips.js` (dish range, thin slab, rolling shutter still and panning, hiccups, heavy
  tremor, warm lamp, cool window plus warm lamp, two lights, passing shadow, ball held / dropped off-centre, satin ball,
  ball at 3 ft held from the far side).
