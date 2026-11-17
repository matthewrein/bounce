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
frames detected; bFP = false ball events; msT / msS = mean ms per frame tracking / searching.

| build | lock | never | FL | cErr | tilt | worst | >1.5 | jit | tJit | ball | bFP | msT | msS | photos cErr % |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| b12 baseline (phase 0 only) | 81.3 | 4 | 6 | 4.72 | 5.13 | 13.37 | 34/43 | 0.366 | 0.562 | 3.7 | 0 | 23.2 | 72 | 1.3 / 0.5 / 0.2 |
| b12 baseline (2 phases) | 82.0 | 4 | 6 | 4.72 | 5.15 | 13.40 | 34/43 | 0.361 | 0.579 | 2.3 | 0 | 21.8 | 68 | 1.3 / 0.5 / 0.2 |
| b13 clean gravity (kept) | 82.0 | 4 | 6 | 4.72 | 5.15 | 13.40 | 34/43 | 0.361 | **0.219** | 2.3 | 0 | 23.5 | 74 | 1.3 / 0.5 / 0.2 |
| b14 gyro-steadied smoothing (kept; 49 clips) | 82.3 | 4 | 6 | 4.80 | 5.21 | 13.21 | 36/44 | **0.276** | **0.178** | 2.3 | 0 | 22.7 | 72 | 1.3 / 0.5 / 0.2 |

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
