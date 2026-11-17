# Improvement log

Every attempt is scored on all synthetic clips in step mode (frame-exact, repeatable) and compared clip by
clip with the previous accepted build (`node compare.js <before> <after>`). A change is kept only if no clip
gets worse beyond the noise allowances in `compare.js`; otherwise it is reverted or reworked. Frame times are
measured inside the app on this test machine's CPU (an x86 server core under SwiftShader-free 2D canvas),
so they are only comparable between runs here, not with the phone.

The three reference photos are also run as stills; only their aggregate corner error (as % of the slab side)
is recorded here.

Columns: lock = % of slab-in-view frames with a correct outline; never = clips that never lock; FL = false-lock
events; cErr = mean corner error px; tilt = median angle between app and true slab normal (deg, median over
clips of per-clip medians); worst = worst clip's median; >1.5 = clips whose median is 1.5 deg or more;
jit / tJit = median over clips of normal / tilt-reading wobble while held still (deg); ball = % of held-ball
frames detected; bFP = false ball events; msT / msS = mean ms per frame tracking / searching.

| build | lock | never | FL | cErr | tilt | worst | >1.5 | jit | tJit | ball | bFP | msT | msS | photos cErr % |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| b12 baseline | 81.3 | 4 | 6 | 4.72 | 5.13 | 13.37 | 34/43 | 0.366 | 0.562 | 3.7 | 0 | 23.2 | 72 | 1.3 / 0.5 / 0.2 |

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
