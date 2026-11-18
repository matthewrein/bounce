# Capture kit: design and formats

The capture kit is a guided developer tool in the iOS app (Settings > Developer > Capture kit; it never opens by itself
and the app never needs it). The owner runs it once, when asked, for about 10 minutes, and hands back one bundle.
Every clip in it carries ground truth, so the detectors and BounceCore can be scored and improved against real footage
without further help from the owner. Real captures outrank synthetic renders when the two disagree.

Kits show the owner's room. They are private, and this repository is public, so **kits are never committed**. That
includes clips, frames, crops and anything rendered from them. Keep them outside the repository, or in a gitignored
folder (`ios/private/`, `*.bouncekit/`, `slab-kit-*`, `kits/`). Logs carry only numbers, never paths to kits or frame content.

## Flow (what the owner sees)

The kit is a sequence of **shots** grouped into 12 **steps**. Each shot screen shows:

- the progress ("Step 4 of 12"), the step title and the shot's one-line instruction;
- a small diagram;
- a **Start** button, then a countdown (3 s; 5 s for the flat-phone shots);
- a recording that stops by itself;
- a quick quality check (good / fair / poor, with plain reasons);
- **Retry**, **Next** and **Discard** (Discard deletes the capture and skips the shot, after asking; before a shot is
  taken the button is **Skip**).

The owner can **Quit** at any point; progress is saved after every shot, and reopening the kit offers **Resume**. A shot
interrupted half-way (the app going to the background, a phone call) is discarded and stays pending. If the kit resumes
in the middle of a slab position (`KitStore.positionInProgress`), the app first asks "Has the slab moved since you
stopped?" (naming the position); on **Yes** it calls `restartPosition`, and the position starts again from its flat-phone shot (see "Slab
positions"). At the end, the app lists what was captured and what was skipped, then builds the bundle and offers one
**Share** button.

| Step | Shots (id) | What the owner does | Length |
|---|---|---|---|
| 1 Measurements | `s01-measure` (form) | Enter the slab's width, depth and thickness (ruler), the dish depth (optional) and the ball's diameter. The form starts empty, with the app's built-in slab and ball as its grey placeholders, and Start needs every field but the dish: a value the owner did not measure is never recorded as if it had been (Skip keeps `measurementsEnteredAt` null). The phone model and LiDAR are read automatically. The values are the kit's truth only: the app keeps its built-in slab and ball. | form |
| 2 Room scan | `s02-scan` | Walk slowly around the slab, 3-5 ft away, pointing at it, so ARKit settles. | 20 s |
| 3 True tilt (level) | `s03-flat-level` (flat) | Lay the phone flat in the middle of the slab, screen up, top pointing away; let go. At the long beep, turn it around (top toward you); let go again; a low tone means done. Starts **slab position 1, "level"**. | about 12 s |
| 4 Slab only, level | `s04-level-still`, `s04-level-arc` | Hold still 3-4 ft away, slab in the middle of the screen; then walk a slow half circle around it. | 5 s + 20 s |
| 5 Slab only, tilts | `s05-tilt1-flat`, `s05-tilt1-still`, `s05-tilt1-arc`, then the same for `tilt2` and, optionally, `tilt3` | Slide the slab to a new tilt (about 5°, 10°, 15°). Each tilt starts with a flat-phone true tilt, which begins a new slab position. | per tilt: about 12 s + 5 s + 15 s |
| 6 Light | `s06-dim`, `s06-bright` | Same slab position: dim the room, then make it bright. | 6 s + 6 s |
| 7 Ball only | `s07-ball-3ft`, `s07-ball-5ft` | Ball resting on the floor away from the slab (slab out of view), the phone about 3 ft from it, then about 5 ft. | 5 s + 5 s |
| 8 Ball on the slab | `s08-ball-centre` | Ball resting in the dish, as near the middle as it will stay (on the tilted slab it cannot stay in the middle: the scorer takes it where it is). It ties the ball's size to the slab's distance. | 6 s |
| 9 Ball held above | `s09-held-low`, `s09-held-mid`, `s09-held-high` | Hold the ball over the middle of the slab: low (about 4 in), middle (about 1 ft), high (about 2 ft). After each shot, the owner may enter the measured height of the ball's bottom above the slab right under it (a ruler stood on the slab under the ball, so in the dish: the app's drop height), or skip that. The field starts empty; the nominal height is only its placeholder. | 5 s each |
| 10 Bounces | `s10-drop1`, `s10-drop2`, `s10-drop3` | Hold the ball about 1 ft over the middle of the slab and let go at the high beep (Drop now): the only beep after the countdown's ticks. Keep the slab and the floor around it in view. Recorded at the highest frame rate ARKit offers. | 6 s each |
| 11 Off-centre bounce | `s11-drop-edge` | The same, dropping the ball near one edge of the slab. | 6 s |
| 12 Negatives | `s12-no-slab`, `s12-no-ball` | The room with neither the slab nor the ball in view; then the slab in view with no ball anywhere. | 6 s + 6 s |

There are 25 shots in total, or 28 with the optional third tilt (`KitPlan.standard`, id `standard-v1`). Recording takes
about 3 minutes; with reading, moving the slab and countdowns, the whole kit takes about 10 minutes. Every shot can be
skipped. UI tests run the same plan faster with `KitPlan.standard.scaled(by:)`, which shortens recordings, countdowns, the
release cue and the flat-phone timings; kit.json records the time scale.

### Slab positions

A flat-phone shot (`*-flat-*`) starts a new **slab position** (`p1` "level", `p2` "tilt 1", `p3` "tilt 2", `p4` "tilt 3")
and gives that position its true tilt. Every later shot belongs to the latest position until the next flat-phone shot:
precisely, a shot belongs to the position of the last flat-phone shot at or before it in plan order whose position has
started. Steps 6-12 use the position that is current then, normally the last tilt. If a flat-phone shot is skipped, its
position still starts, without a true tilt, since the slab was moved. The exception is the optional third tilt: skipping
its flat-phone shot skips all three of its shots and starts no position, because the slab stays at tilt 2. A flat-phone
shot whose result failed also starts its position without a true tilt. Moving the slab without a flat-phone shot is not
part of the plan.

If the slab is set up again for a position that has already started (the owner says it moved, on Resume),
`restartPosition` starts a new **generation** of that position: a new entry in kit.json's positions with its own id
(`p2#2`, `p2#3`, ...) and no true tilt yet, and the position's flat-phone shot goes back to pending (its earlier capture is
removed; the earlier result stays in the earlier generation's entry). Shots already captured keep the generation they were
captured in and its true tilt; shots taken from then on belong to the new one. A retry of the flat-phone shot without a
restart (the slab did not move) replaces the current generation's true tilt. kit.json is the authority on positions: a
captured shot's record names its position and generation (`positionId`), and `manifest.position(forShot:)` gives its true
tilt. Each shot.json carries a copy made when it was captured.

## True tilt from the phone lying flat

The phone's own gravity reading (CoreMotion `CMDeviceMotion.gravity`, device axes: x right, y toward the top, z out of the
screen) gives the tilt of whatever the phone lies on. Lying screen-up on a level surface, gravity is (0, 0, -1).

**The camera bump.** A phone lying on its back rests on its camera bump, which tilts it by a degree or two, enough to
spoil a ground truth. So the shot takes two readings: A with the top pointing away, and B after the owner turns the phone
around on the slab. The phone rests the same way on the bump in both readings, so the bump's tilt is fixed in the phone's
frame, while the slab's tilt turns with the phone.

Model: phone-in-world `R_k = T · Rz(ψ_k) · B`, where T tilts the slab, Rz(ψ_k) turns the phone about the slab's
normal, and B is the fixed rest on the bump. Gravity in the phone's frame is `g_k = Bᵀ Rz(ψ_k)ᵀ Tᵀ ĝ_world`. Unknowns:
the slab's tilt (2 dof) and the bump (2 dof). The turn `Δψ = ψ_B − ψ_A` comes from the attitude: the relative rotation
`q_Aᵀ q_B` between the two readings' mean attitudes turns by Δψ about the slab's normal. Four equations, four unknowns:
start from the small-angle solution (`t = (I − R(−Δψ))⁻¹ (m_A − m_B)`, `b = m_A − t`, with m the gravity's in-plane
components), then refine on the exact model with Gauss-Newton. This needs |Δψ| ≥ 60°; 180° is best.

Results are the slab's tilt in degrees, its downhill direction in phone-A axes (from the phone's right toward its top),
the bump (2 values, degrees: the tilt the phone reads lying on a level surface, as a vector pointing the way it leans
down) and the turn (0-360°). Cross-check: the axis of the relative rotation is the slab's normal in phone-A axes, so its
angle to gravity is a second, gyro-based tilt. The result also carries the small-angle start (at 20° of tilt and 3° of
bump it is about 0.4° off, while the refined result is within 0.05°), the model's residual and a rough one-sigma
uncertainty (each reading's noise over the root of its independent samples, divided by 2 sin(Δψ/2), plus the misfit
between the attitude and gravity readings).

**Attitude convention.** The relative rotation must carry g_B onto g_A. `KitMotionSample.attitude` is
`CMAttitude.quaternion` as given, read as the rotation taking device-axes vectors into the reference frame; the solver
checks that against the gravity readings and, if the opposite convention fits clearly better, uses that instead and
says so (`attitudeConjugated`). Where the two cannot be told apart, the slab and the bump are both nearly level, and the
answer is the same either way.

With one reading only (B skipped or timed out), the tilt is reading A corrected by the bump found earlier in the same kit,
if there is one ("bump-corrected"). Otherwise the reading stands uncorrected and is marked so, with an uncertainty of
about 2°. The bump reused is that of the latest two-reading result whose readings were steady and flat (the `still` and
`flat` checks below) and whose bump is at most 5°.

**Screen up, and readings that belong together.** Both readings must be taken with the phone flat, screen up: a reading
whose own tilt is over 25° (screen down reads about 180°, on its side about 90°) says nothing about the slab. Without a
flat reading A the shot fails ("The phone was not lying flat, screen up"); the live session then ends at once, without
asking for reading B. A reading B that is not flat is left out, and reading A stands alone. Four equations in four
unknowns always "solve", so a two-reading solution is also checked for sense: a camera bump over 10° (a bump 12 mm high
on a phone 70 mm wide; real ones rock the phone by a degree or two), a slab tilt over 45° or a misfit over 0.5° means the
readings do not belong together (the slab moved between them, say), and only reading A is used.

**Readings.** Each reading waits, up to 8 s for A and 15 s for B, until the phone has been still for 1 s. Still means
the gravity direction spreads less than 0.15° over that second and the rotation rate stays under 0.05 rad/s. The reading
then averages 3 s of samples (a robust mean: a single knock does not move it, but it shows in the spread). Between A and
B, the shot waits for the phone to be lifted (a rotation rate over 0.5 rad/s, or the gravity moving more than 3°), then
for it to be still again; the 15 s for B count from the end of reading A. If the phone moves during a reading (a rotation
rate over 0.2 rad/s, or gravity moving more than 1° from where it lay still), the reading starts over once the phone is
still again, with a fresh wait. Waiting for A in vain fails the shot; waiting for B in vain leaves reading A alone.
`KitFlatSession` runs this as a state machine the app feeds with CoreMotion samples
(`waitingForStillA → readingA → waitingForLift → waitingForStillB → readingB → done`); the app beeps when it reaches
`waitingForLift` (a long beep: turn it now) and `done` (a lower tone), and at no other change (not when a reading
starts or starts over), with sound only, so nothing shakes the phone on the slab.

**Checks.** The spread within each reading must be ≤ 0.3°, the phone must lie flat, screen up (the reading's tilt ≤ 25°),
the turn must be between 120° and 240°, and the bump must be ≤ 5°. A larger bump suggests the phone is not lying flat,
perhaps in a thick or uneven case.

**The downhill direction and ARKit's world.** The flat-phone shot has no camera picture, so its downhill direction is
known in phone-A axes (`downhillAzimuthDegrees`, `tiltVector`) and, through reading A's attitude, in CoreMotion's reference
frame: `KitTrueTilt.slabNormalInMotionFrame` is the slab's normal there (z up; the heading is arbitrary but fixed for one
run of motion updates, and drifts slowly). To bring it into ARKit's world, where the tracker reports the slab, the app
keeps **one** run of CoreMotion device-motion updates and **one** ARSession (no resets) for the whole kit screen, and
records their ids in every shot.json (`motionSessionId`, `arSessionId`; a new id whenever either restarts). In a video
shot, motion.jsonl and frames.jsonl give the fixed rotation from CoreMotion's reference frame to ARKit's world; a
flat-phone shot with the same ids (best: the nearest video shot in time) can use it. The scorer does this
(`KitMotionLink`, see "Scoring"), so it scores the slab's normal, downhill direction included, as well as the tilt's size;
where there is no usable link, only the tilt's size (`tiltDegrees`).

The phone must lie in the middle of the dish: centred on a spherical dish, a flat phone tilts with the dish's axis.

## Clip format (per shot)

A kit is a folder `<kitId>/` (`kitId` like `slab-kit-20261117-153000`, from the creation time in UTC, so it says nothing
about where the owner lives; `-2`, `-3` are appended if two kits start in the same second):

```
<kitId>/kit.json                    KitManifest (rewritten atomically after every change)
<kitId>/shots/<shotId>.attempt/     the shot being recorded; moved to shots/<shotId>/ when committed
<kitId>/shots/<shotId>.old/, .trash/  briefly, during a commit or a skip (never bundled)
<kitId>/shots/<shotId>/shot.json    KitShotManifest
<kitId>/shots/<shotId>/video.mp4    the frames (HEVC, or H.264 where HEVC is unavailable), sensor orientation (landscape)
<kitId>/shots/<shotId>/frames.jsonl one KitFrame per encoded video frame, in order (line n = video frame n)
<kitId>/shots/<shotId>/motion.jsonl one MotionSample per CoreMotion update (100 Hz)
<kitId>/shots/<shotId>/depth/d<NNNNNN>.bdp2   LiDAR depth for video frame NNNNNN (about 1 per second), if the phone has LiDAR
```

The names inside a shot folder are constants in `KitClipFiles` (`video`, `frames`, `motion`, `shotManifest`,
`depthFolder`, `depthURL(shotFolder:frame:)`); the app and the scorer use those, not their own strings.

Flat-phone shots have `motion.jsonl` and `shot.json` (with the result) and no video. The measurements form has no folder:
its values live in kit.json.

A retry records into a fresh attempt folder, so the earlier capture stays until the new one is committed. If the app
dies mid-shot, loading the kit removes the attempt folder (and any shot folder without a shot.json) and the shot stays as
it was; a shot marked captured whose files are gone becomes pending again. Skipping a captured shot removes its files.

kit.json is saved before any capture is deleted. A commit moves the new files into place, saves kit.json, then deletes
the earlier capture (kept aside as `<shotId>.old` until then); a skip renames the files to `<shotId>.trash`, saves
kit.json, then deletes them. A failed save puts everything back and throws. If the app dies in between, loading the kit
finishes the job: a shot folder whose shot.json disagrees with kit.json (another attempt number, a record not marked
captured, or an entered height only shot.json has) holds the newer capture, and its record, slab position and light
reference are rebuilt from it (`KitStore.repairedOnLoad`); a skip that kit.json does not know of did not happen, and its
files go back.

**Video.** 1440x1080 (4:3, the camera image scaled down; the full camera image is usually 1920x1440). A box downscale by
exactly 3 gives the app's 480x360 processing frame. For ARKit at 60 fps, ordinary shots keep 30 fps: the first frame
of each 1/30 s slot of time (from the first frame, with a quarter slot of slack for timestamp jitter), so a frame ARKit
drops costs no kept frame while another falls in the same slot; the high-frame-rate shots (drops) keep every frame.
The camera image's colour attachments (YCbCr matrix, primaries, transfer function) go with each scaled frame to the
encoder, which is given full-range samples. Target bitrate for HEVC: about 3.5 Mbit/s at 30 fps and 6 Mbit/s
at 60 fps; H.264 (where HEVC is unavailable, and always in the Simulator) gets 1.5 times as much. Timestamps in the file
are ARKit's frame timestamps minus the shot's start (`startTime`, the first recorded frame). The demo scene (Simulator,
UI tests) records its own frames at their size (360x480) with H.264, and has no motion samples in its video shots.

**KitFrame** (one JSON object per line; short keys keep the file small; optional values, and non-finite ones, are left
out, inside `live` too; `pose` and `K` keep ARKit's own Float values):

| key | meaning |
|---|---|
| `i` | video frame number, from 0 |
| `t` | ARFrame timestamp (s, the system's uptime clock, the same clock as CoreMotion) |
| `pose` | world-from-camera, ARKit camera axes, column-major 4x4 (16 numbers) |
| `K` | `[fx, fy, cx, cy]` for the **video** frame's pixels |
| `track` | `"normal"`, `"limited:initializing"`, `"limited:excessiveMotion"`, `"limited:insufficientFeatures"`, `"limited:relocalizing"`, `"notAvailable"` |
| `exp` | exposure duration (s), if known |
| `expOff` | exposure offset (EV), if known |
| `amb` | ARKit light estimate: ambient intensity (lumens, about 1000 for a well-lit room) |
| `ct` | ambient colour temperature (K) |
| `luma` | mean luma 0-255 of the frame's camera image, on **every** recorded frame (`KitImageStats.meanLuma(bytes:width:height:bytesPerRow:)` on the Y plane, every 8th pixel) |
| `blur` | estimated motion blur in video pixels (angular speed × exposure × focal) |
| `depth` | depth file name, if this frame has one |
| `live` | the app's live result on this frame: `{"state": "searching"/"confirming"/"locked", "tilt": deg?, "corners": [[x,y]x4]? (video px), "ball": [x, y, r]? (video px)}`. `KitLiveState` reads a state it does not know as `.other` (kept as spelled), so a newer tracker's files still read; corners or a ball with a non-finite number are left out |

**KitMotionSample**: `{"t": s, "g": [x,y,z] gravity (g), "ua": [x,y,z] user acceleration (g), "rr": [x,y,z] rotation rate
(rad/s), "q": [x,y,z,w] attitude}`, device axes, reference frame `xArbitraryZVertical`. Numbers are written rounded
(time to 10 µs, vectors to 1e-6, the quaternion to 1e-7), far below the sensors' noise.

**Reading JSONL**: a last line cut short (no newline and not valid JSON: the app was killed while writing it) is dropped;
any other bad line is an error.

**BDP2 depth**: the magic "BDP2", then the width and height as little-endian UInt16. Then width×height little-endian UInt16
depths in millimetres (0 = no depth), then width×height confidence bytes (ARKit: 0 low, 1 medium, 2 high). This is a third
of the size of the debug recordings' BDP1 (Float32). It reads as a `DepthMap` in metres (0 reads as NaN). Depths at or
below 0, beyond 65.535 m, NaN or infinite are stored as 0. Depth intrinsics are the video frame's `K` scaled by depth
width ÷ video width.

**KitShotManifest** (`shot.json`, format `"bouncekit-shot"`, version 1): the kit and shot ids; the step; the attempt
number; the start time (ISO, `startedAt`, for people) and duration; `startTime`, the start in seconds of system uptime
(the clock of the frames' `t` and of the motion samples: the origin of the video's timestamps and of `releaseCue`); the
build label; the device; the measurements, and `measurementsEntered` (false: they are the app's built-in slab and ball,
step 1 was not done); the slab position id (with its generation) and the true tilt of that position (copied); `motionSessionId` and
`arSessionId` (see "The downhill direction and ARKit's world"); the video (codec, width, height, fps, bitrate, frame
count, file size); the camera format (full width, height and fps); whether LiDAR depth is present, and how many depth
frames; the motion sample count; the entered height (inches) if any; the quality report; for drops, the release cue (the
plan's seconds after `startTime`) and `releaseTime` (uptime seconds when the beep actually played); for flat-phone shots,
the result (`flat`); free notes. The app sets `startTime`, `releaseTime` and the two session ids.

**KitManifest** (`kit.json`): format `"bouncekit"`, version 1, kit id, plan id, the time scale when it is not 1, build
label, created/updated/finished times; the device (model identifier like `iPhone16,1`, the iOS version, LiDAR, the chosen
ARKit video formats for ordinary and high-frame-rate shots); the measurements (slab width, depth and thickness, dish depth
or null, in inches; ball diameter in mm; validated against these ranges: sides 3-20 in, thickness 0.2-4 in, dish
0-0.75 in, ball 5-120 mm) and `measurementsEnteredAt`, when the owner entered them (null until step 1 is done, and again
if it is skipped: the measurements are then the app's built-in slab and ball, with no dish); the slab positions (and generations) with
their true tilts; the level hold-still shot's median luma and median light estimate (the light reference); one entry per
shot in plan order: id, step, status (`pending` / `captured` / `skipped`), attempts, folder, position id (with
generation), quality verdict, entered height, duration, frames, bytes, capture time, optional. Times are ISO-8601 in UTC.
**No device name, no location, no account details.**

## Quality check

The check is computed on the phone from per-frame statistics (BounceCore `KitQuality`, so it is unit-tested on Linux). It
only flags problems the owner can fix by retrying. A detector failing on good footage is exactly what the kit is for, so
detector-based checks are worded "if the slab was in view, Next is fine". Verdicts:

- **good**: every check passes.
- **fair**: a soft check failed; Next stays the default.
- **poor**: Retry is suggested.

| Check (id) | Applies to | Rule |
|---|---|---|
| `frames` | video shots | at least 80% of the expected frames, otherwise poor ("the phone dropped frames") |
| `tracking` | video shots | ARKit "normal" in at least 70% of frames (60% for the scan), otherwise fair |
| `light` | video shots | median luma ≥ 45 (dim shots: ≥ 12), otherwise fair; over the frames that measured it, and info "not measured" when none did |
| `lightChange` | dim and bright shots, when the level hold-still shot was captured | compares ARKit's light estimate (`amb`, median, when at least half the frames of both shots have one): dim below 70% of the level shot's, otherwise fair "doesn't look dimmer"; bright above 110% of it, otherwise fair. Without light estimates it compares median luma and only reports it (info): the camera's auto-exposure keeps the picture near mid-grey, so a picture that does not look dimmer is often the camera's doing, not something a retry fixes |
| `blur` | video shots | median blur ≤ 3 px for still shots, ≤ 6 px for moving ones, otherwise fair; above twice that is poor; over the frames that measured it, and info "not measured" when none did |
| `slab` | shots expecting the slab | the slab was found (confirming or locked) in at least 50% of frames, otherwise fair |
| `ball` | shots expecting the ball | the ball was found in at least 30% of frames, otherwise fair |
| `falsePositives` | shots where the slab or the ball must not be in view (negatives, slab-only, ball-only) | the share of frames where it was found anyway is reported and never fails |
| `reading` | flat-phone shots | no reading at all (the phone never lay still), poor |
| `still` | flat-phone shots | each reading's spread ≤ 0.3°, otherwise poor |
| `flat` | flat-phone shots | each reading's tilt ≤ 25° (flat, screen up), otherwise poor; checked on a failed result too, so the owner is told which reading went wrong |
| `turn` | flat-phone shots | 120-240°, otherwise fair (60-120° and 240-300° still solve, more loosely); without a reading B, fair |
| `bump` | flat-phone shots (two readings) | ≤ 5°, otherwise fair |
| `solve` | flat-phone shots with two flat readings turned at least 60° that did not solve together | poor ("The two readings don't fit together ..., so only reading A was used") |

Boundaries pass (exactly 80%, 45, 3 px, 0.3°, 25°, 5° all pass). Each check carries its value, threshold and a plain
English message; the summary line is the verdict and the first problem ("Fair. ... Next is fine." / "Poor. ... Retry is
suggested.", the advice said once even when the message already ends with it). Per frame, the app computes the mean luma
on every recorded frame, straight from the camera buffer's Y plane (`KitImageStats.meanLuma(bytes:width:height:bytesPerRow:)`,
every 8th pixel), and the blur from the camera's rotation since the previous frame (`KitMotionBlur.pixels`: exposure ×
focal × the optical axis's angular speed, with roll counted at half a focal length from the centre). A number not
measured on a frame is nil in `KitFrameStat`, never a stand-in value.

## Bundle

**Finish** builds the bundle into `Documents/Kits/<kitId>/`, which the Files app shows under On My iPhone > Slab Bounce >
Kits. The bundle is one or more zip **parts** named `<kitId>-partNofM.zip`. Each part is at most 24,000,000 bytes, because
GitHub's web upload takes files up to 25 MiB. Each part is a valid zip of whole files, with paths starting `<kitId>/`, so
unzipping all parts into one folder rebuilds the kit. Every part carries `kit.json` (first). Files are packed first fit
in path order. A single file too large for a part on its own gets a part of its own, larger than the limit, and is
reported; in a real kit none is that large (`KitPhoneVideo.largestVideoBytes`, checked by `KitHandoffTests`): the
largest file is the room scan's video, 20 s at 3.5 Mbit/s (HEVC) or 5.25 Mbit/s (H.264), about 9 or 13 MB, so the
encoder would have to overshoot its average bitrate 1.8 times (H.264) for it to need a part of its own. Video is stored as is; JSON, JSONL and depth are deflated (zip method 8, raw DEFLATE from Apple's Compression
framework, passed in by the app), and stored when the compressor fails or does not make them smaller. Files are streamed
in chunks, so a video is never held in memory whole. Unfinished attempts, interrupted commits and skips, and hidden files
are left out. The parts are written in a hidden working folder (`.<kitId>-bundle-<uuid>/`) and get their part names in
the outbox only once all of them are complete, so a build the app is killed in never leaves a half-written part with a
real name; the next build (or `KitBundle.removeLeftovers` at launch) removes such a working folder. Building again
replaces the kit's earlier parts; a failed build leaves nothing behind. The working copy lives in Application
Support, so the Files app does not show it. **Share** offers all the parts at once (AirDrop, Save to Files, ...). The
finish screen also offers to delete the kit once it has been sent.

## Getting it back (the owner's route)

Kits are private and the repository is public, so they travel through a **private GitHub repository**. It needs no Mac
and no coding, only Safari on the iPhone: each part is at most 24,000,000 bytes, under GitHub's 25 MiB limit for a file
uploaded on the web. The tap-by-tap steps for the owner are in `ios/README.md` ("Capture kit (developer tool)"). Once the owner says the
kit is uploaded, the session attaches that repository and clones it outside this repository (next section).

## When the kit is uploaded

When the owner says "kit uploaded":

1. Attach the private repository to the session: the `add_repo` tool with owner `matthewrein`, repo `bounce-captures`
   (it lets the session's git proxy fetch it; do not check it with curl or `gh` first, as a private repository answers
   404 to them). If that is refused, the owner has to create it or give Claude's GitHub app access to it
   (`ios/README.md`, "Sending it, privately"); say so and stop.
2. Run the one command, from this repository (no arguments needed). A first run in a new session builds the checker
   and the scorer (release) and can take about 10 minutes, so in a Claude session run it in the background (the Bash
   tool's `run_in_background`) and read its output when it ends:

   ```
   ios/tools/kit-uploaded.sh
   ```

It needs no setup beyond git, unzip and ffmpeg (with ffprobe), which Claude's sessions have: with no Swift on the PATH,
under `/opt/swift-*` or in `~/.swift`, it installs Swift 6.1.2 itself (`ios/tools/install-swift.sh`: on Ubuntu 24.04,
from download.swift.org, 878 MB, under a minute, checked against the SHA-256 pinned in the script, into `~/.swift`;
elsewhere it says how to install Swift). It clones `https://github.com/matthewrein/bounce-captures` into
`~/bounce-private/bounce-captures` (or `$BOUNCE_PRIVATE`; a folder inside this repository is refused), or updates that
clone; if add_repo gives another clone URL, pass it as the only argument. It finds every kit's parts in it, wherever
they are and also when Safari or GitHub renamed them (`... (1).zip`), on the default branch and on any other branch
(the upload page's "Create a new branch for this commit and start a pull request" choice: those parts are used, and
the report names the branch), and checks each kit: all its parts there (by their `partNofM` names), every zip's CRCs
(`unzip -t`; a part cut short or empty counts as damaged), the same kit.json in every part, every part within
24,000,000 bytes; a part uploaded twice is used once (the newest upload if the two differ). It then unzips each kit
afresh and checks the content against kit.json and each shot.json (`bounce-kit check`, `KitArrival`: every captured
shot's files, the video's size, a frames.jsonl line per video frame, the depth files the lines name, the motion
samples), so a part that went missing or a file cut short shows even when the names look right. kit.json is the
authority: a shot it records that this checkout's plan does not know is checked from its shot.json, and a plan shot it
has no record of is only noted (the phone runs another build), never reported as a missing upload; a kit.json this
checkout cannot decode at all (a newer build's) is reported as "NOT verified" with where it stopped, and the fix is to
update this checkout. A complete kit goes into `~/bounce-private/kits/<kitId>`; an incomplete one into
`kits-incomplete/`, where it is not scored (so it never becomes the baseline the complete kit is compared with), and it
never replaces a complete copy unzipped earlier.

It prints, per kit: the parts (how many, verified, the largest, any on another branch), the shots captured and skipped
(and held shots without a height), the files, the contents check, then one line per kit:

```
slab-kit-20261119-083000: all parts verified: the owner can delete this kit from the phone
```

or `NOT complete`, with each missing or damaged part named (`part 2 of 3 is missing: ask the owner to upload
slab-kit-...-part2of3.zip`): the owner keeps the kit on the phone and uploads that part the same way, and the command is
run again. Then it scores the complete kits with `score-kits.sh` (scores saved in `~/bounce-private/scores`, compared
with the previous run; a couple of minutes a kit), prints the scores Markdown, and the verdict lines again. Running it
again is always safe: it re-checks and re-scores every kit, a newly uploaded one included; a second run while one is
going is refused (a lock in the private folder). Exit status 0 when every kit is complete and scored, 2 when a kit is
incomplete, damaged or unreadable by this checkout, or nothing was uploaded, 3 when scoring failed (also when none of a
kit's video shots could be scored, e.g. ffmpeg could not decode them), 10 when the repository could not be fetched
(with what to do), 1 for setup problems (a missing tool, another run going). `--no-score` only checks; `--synthetic`
also scores the synthetic kit (4-6 minutes more; it says nothing about the owner's kit); `--measured` scores with the
kit's measured slab and ball. It prints kit ids, part numbers, branch names, shot ids and numbers only.

**The dry run** (`ios/tools/handoff-dryrun.sh`, in a private folder outside the repository) rehearses all of it from
nothing: a synthetic kit the size of a real one written as the phone writes it (`bounce-kit write-synthetic`,
`KitSyntheticPhoneKit`: every shot through `KitStore`, the measurements form, flat-phone shots, a retried shot, skipped
shots and an unentered height; each video shot at its plan length, 1440x1080, 30 fps or 60 for drops, HEVC (or H.264)
at the phone's bitrate with the camera's noise so it is as large as the phone's, LiDAR depth about once a second,
frames.jsonl lines as `KitRecorder` writes them; the scene and truth of `KitSyntheticKit`), bundled with `KitBundle`
(`bounce-kit bundle`, DEFLATE from gzip; every part checked under 24,000,000 bytes and GitHub's 25 MiB, and unzipping
them must rebuild the kit byte for byte), committed to a local bare repository standing in for bounce-captures as the
web upload commits ("Add files via upload" at the root), then the one command after each upload: the first part only
(incomplete, the missing parts named, not scored), the rest in a second commit (complete, scored: median tilt error at
most 2°; the verdict before the scores and after them), a second kit (H.264, no LiDAR) later, the same parts again
(renamed `(1)`, in a folder, re-committed), a damaged part (reported, the complete copy kept, then repaired), a part
whose kit.json is damaged, a part cut short and uploaded again as `(1)`, an empty part of a kit never uploaded (each
reported, the other kits still verified), a repository it cannot fetch (exit 10, what to do), parts committed to
another branch (used, the branch named), and a kit.json from a newer build (NOT verified); and no private path in
anything it prints. The full-length run took 32 minutes on 4 busy cores (the kit: 5,610 video frames, 108 MB on the
phone, 4 parts of 24.0, 24.0, 23.0 and 16.3 MB; writing it took 19 minutes, mostly rendering; scoring it about 2); CI
runs it with the plan at a quarter of its timings and 10,000,000-byte parts, so that kit too comes in several
(`--short`), and puts the bundle the real app made in the Simulator's end-to-end test (testCaptureKitFlow, the app's own
`KitBundle` with Apple's DEFLATE) through the one command too (`--app-bundle`). What it cannot rehearse: GitHub itself
(Safari's upload page, the private repository's access, the session's git proxy), real footage, the phone's own encoder
and Apple's DEFLATE (the Simulator's bundle covers the last).

## Scoring (replay against ground truth)

`bounce-score` (an executable in the BounceCore package, macOS and Linux) scores kits against their ground truth. It
reads a kit without changing it (`KitScorer`), runs every video shot through the app's own per-frame path
(`KitFramePipeline`) and a fresh `SlabTracker` per shot, with the app's detectors (`AppDetectors.slab()` and
`.ball()`) and the app's own settings (`RecordingSettings()`: the slab, ball and tuning baked into the app, as the owner's
phone runs them). `--measured` scores with the kit's measured slab and ball instead, only when `measurementsEnteredAt`
is set (otherwise the app's settings, with a note). The video is decoded with `ffmpeg` (`KitVideoDecoder`).

```
bounce-score <kit folder or a folder of kits> ... [--json out.json] [--markdown] [--compare old.json]
             [--fail-on-regression] [--measured]
bounce-score --synthetic [--frames N] [--markdown] [--json out.json] [--video h264|hevc] [--truth-ball]
             [--max-tilt-error DEG]
```

It prints kit ids, shot ids and numbers, never paths. `--fail-on-regression` exits with status 2 when a metric got
worse than in `--compare`; `--max-tilt-error` exits with status 3 when the synthetic kit's median tilt error is above
it or missing; `--scorer LABEL` records who scored (a git hash) in the JSON.

**From a video frame to the tracker** (`KitFramePipeline`), as `ARController.handle` does it: the processing frame is
the image shrunk by an integer box factor (`YCCImage.fromBiplanar`), converted only when `SlabTracker.detectionDue` (the
app's 2x2 blank otherwise); its camera is the frame's ARKit pose (`ARKitConvention`) with the video `K` scaled to it;
while locked and `ballDue`, the ball finder gets the app's crop (`BallImageCrop.plan`) planned on the camera image the
phone had (shot.json's camera format: the video's `K` scaled up to it), so its rectangle, size and intrinsics are the
phone's, with each pixel the video's mean over the same patch of the scene (`KitFramePipeline.areaAverage`; a video at
the camera's own size gets the app's integer block average); while locked, LiDAR depth when the frame has a BDP2 file
(`K` scaled by depth width ÷ video width); `trackingNormal` from `track`. A test checks this against a copy of the app's
code path. How it differs from the phone:

- compression: the frames went through HEVC (or H.264) at 3-5 Mbit/s;
- resolution: the app shrinks the 1920x1440 camera image by 4; from a 1440x1080 video the same 480x360 frame comes by a
  factor of 3, from 1280x960 it is resized by area averaging (the intrinsics scaled per axis) (a video smaller than
  480 px is used as it is). The ball finder's image has the phone's geometry, so the ball is as many pixels across as
  on the phone and the finder's pixel thresholds mean the same, but less detail (resampled from a video with a quarter
  fewer pixels across);
- frames: ordinary shots keep every other ARKit frame (30 fps) and drops every frame, while the app processes every
  frame at 60 fps, so searches and re-checks fall on other frames;
- depth: about one frame a second in the kit, every locked frame on the phone;
- floor: the kit has no ARKit plane anchors, so `floorY` is nil (the app's readouts then end the path at the slab's
  lowest corner; this changes neither the slab nor the ball);
- no taps, resets or settings changes; each shot starts a new tracker.

**Decoding** (`KitVideoDecoder`, ffmpeg and ffprobe): frames are streamed one at a time (the video is never held whole)
as 8-bit 4:2:0 YCbCr in full range, like the camera's buffer. The colour range comes from the stream's tags (ffprobe's
`color_range`, or a `yuvj` pixel format); a limited-range stream is expanded (luma (Y - 16) x 255/219, chroma
(C - 128) x 255/224 + 128). A stream without a tag (whether the phone's encoder writes one is up to VideoToolbox) is
read the way its samples say (`KitVideoDecoder.rangeCheck`, on its first 8 frames): luma outside 10-245 on more than
0.2% of the pixels means full range; otherwise the decoded mean luma, read either way, is compared with frames.jsonl's
`luma` (the camera's own, full range), and the closer reading wins by more than 1.5 levels; otherwise (near mid-grey
the two hardly differ) full range, as the app records. The report notes how an untagged stream was read, and a tagged
one whose samples look like the other range. Every decoded frame is kept (no frames dropped or repeated for a
constant rate) and a rotation tag is ignored (the frames stay in sensor orientation, which `K` describes). A video with
another number of frames than frames.jsonl has lines is an error for that shot; so is a missing ffmpeg.

**Metrics.** Frames are a shot's video frames; t0 is its first frame's time. A metric that cannot be measured is n/a,
with the reason (no ball finder in this build, the slab never locked, no true tilt for the position, measurements not
entered, no height entered, no CoreMotion-to-ARKit link, ...).

| Metric (id) | Shots | Definition |
|---|---|---|
| `lockRate` | slab expected in view | share of the frames with t - t0 ≥ 1 s on which the tracker is locked |
| `timeToLock` | slab expected | first locked frame's t - t0 (s) |
| `tiltErrorMedian`, `tiltErrorP90`, `tiltBias` | shots of a position with a usable true tilt (`manifest.position(forShot:)?.groundTruth`) | on every locked frame, the tracker's tilt (`Readouts.tiltDegrees`) minus the flat-phone `tiltDegrees`: median and 90th percentile of its absolute value, median of the signed value; per shot and per position (frames pooled) |
| `normalErrorMedian`, `normalErrorP90` | the same | angle between the tracker's normal and the true normal (below), on every locked frame |
| `cornerRms` | slab expected | the lock's four world corners on every locked frame (matched to the first locked frame's), RMS distance from each corner's per-axis median (mm) |
| `slabSizeError` | slab expected, measurements entered | each locked frame's detected outline cast onto the lock's plane; mean of (long side - measured long side) and (short side - measured short side), median over frames (mm). The pose's distance scales with the size the app assumes, so this shows how well the outline fits the measured shape (and the size, once LiDAR is fused) |
| `slabFoundRate`, `slabLockedRate` | slab must not be in view (ball on the floor, `s12-no-slab`) | share of frames confirming or locked / locked |
| `ballDetectionRate` | ball expected (not `s08`: the app looks only for a ball 5 cm or more above the slab) | of the frames on which the app's ball finder ran (only while locked, every `ballInterval`), the share that found a ball there; a ball the app holds over from an earlier search (it keeps a missed ball for up to 2 searches) is not a find |
| `ballFalsePositiveRate` | ball must not be in view | the same share, where there is no ball (a false ball held over counts once, where it was found) |
| `ballDistanceError` | ball resting on the slab (`s08`) | the tracking finder (below) on every locked frame: the ball's distance from the camera from its size minus the distance along the same ray to where its centre must be resting on the dish where it was found (a radius above the dish's surface along its own normal there, `Dish.at`; on a slab tilted 5-10° the ball cannot stay in the dish's middle, whose slope is at most 2°); frames with the ball not over the slab's top are left out; median (mm) |
| `dropHeightError` | held ball with an entered height (`s09`) | the app's drop height while it comes from the ball (`Readouts.dropHeight`: the ball's bottom above the dish straight below it), median, minus the entered height (mm). The app asks for the same height: a ruler stood on the slab under the ball (in the dish, not on the corners' plane 1/8 in above it) |
| `landingError`, `landingDistanceError`, `apexError`, `impactHeightError`, `rebound` | drops (`s10`, `s11`) | see below |

The ball metrics are written against `BallLocating`: while `AppDetectors.ball()` is nil they are n/a ("no ball finder
in this build"). `--truth-ball` gives the synthetic kit a finder that knows where the ball is
(`KitTruthBallLocator`), to exercise them.

**Bounces** (`KitBounceAnalysis`). On drops (and on `s08`) a second ball finder runs on every frame, on the app's crop
around the lock, giving the ball's centre in the world. It is the app's `BallLocator` set up for tracking
(`KitScorer.trackingLocator`, `BallLocator.Options.tracking`): every frame stands on its own (no hold-over of a missed
ball, no smoothing, no follow box), from just above the dish (no 5 cm floor) and around the slab, on it or not, so each
sample is a measurement of its frame; a ball seen from half its outline is taken at any height and on a single frame
(the app asks a half outline for two scans in a row at the same place over the slab and 0.2 m of height, which a falling
ball never shows), except that under 0.2 m one found again where one was on the frame before is not taken (something
lying on the slab, a lid or a ring of light, stays put; the ball in a drop does not); a truth-based finder is used as it
is. The release cue is `releaseTime`, else
`startTime + releaseCue`. Held: the median position from 1.5 s before the cue to 0.05 s after it. The fall and the
impact are found on the heights smoothed by a running median of five samples, so that one frame read wrong neither
starts the fall nor is taken for the impact. The fall starts with the first sample after cue - 0.3 s at least 1.5 cm
below the held height (and the next sample too) that goes on to fall at least 5 cm below the held height within 0.15 s
(a ball let go falls 10 cm more in the 0.1 s after its first 1.5 cm; a few frames read a little low do not); the impact
is the lowest sample about the lowest smoothed point before the ball rises 1 cm again. Free fall with gravity known
(`p = a + b t + g t²/2`) is fitted to the falling samples, less those far off it (more than max(6 mm, 5 x the median
distance), the worst first, at most a quarter; the release is where its vertical speed is 0), and to the samples after
the impact, started from the first five that fit (the same way) and grown one at a time while each lies within
max(15 mm, 5 x the fall's RMS misfit, 4 x its own) of the fit (one sample off is skipped, two in a row end the flight, at
the floor; samples at the end more than max(6 mm, 3 x RMS) off are dropped). The impact time is
where the two fits' heights meet, the impact point their mean there, the velocities in and out the fits' velocities
there; **rebound** = |v_out|² / |v_in|² (the app's rebound). The **apex** is the post-impact fit's highest point and the
**landing** where it comes back down to the impact point's height (extrapolated past the last sample if need be). A
track that does not hold together as a drop gives no numbers, only the reason: the two fits must meet within 0.02 s of
the frames around the impact, the speed in must match the fall (|v_in|² within 20% of 2 g x the fall height), the
rebound must be between 0 and 1.1, and at most half the flight may be extrapolated. The app's **prediction** is
`Bounce.compute` with the tracker's lock on the last frame before the cue and the held ball, the ball's centre taken a
radius above the launch point. `landingError`: horizontal distance between the predicted landing (where the predicted
bounce returns to its own start height) and the measured one; `landingDistanceError`: predicted minus measured landing
distance; `apexError`: predicted minus measured apex height; `impactHeightError`: the predicted launch's height (the
ball's centre a radius above the dish, straight below the held ball) minus the measured impact point's (mm, signed).
Both lie straight below the held ball, so their horizontal distance is about 0 whatever the lock; the height carries the
lock's plane and dish depth. (The app's model takes the ball's bottom to touch straight below its centre, about 0.3 mm
off at 10°.)

**The true normal: the CoreMotion-to-ARKit link** (`KitMotionLink`). CoreMotion's reference frame (z up) and ARKit's
world (y up) are both gravity-aligned: `world = Ry(yaw) · A0 · ref`, A0 taking ref x to world x, ref y to world -z and
ref z to world y. At each video frame of a shot, the attitude (interpolated to the frame's time) and ARKit's camera pose
give `world-from-ref = R_world←camera · D^T · R_ref←device^T`, D being the device-from-ARKit-camera axes (ARKit's camera
x is device -y, its y is device x, z is device z). The yaw is the circular mean; the link is used only with at least 10
matched frames, a median misfit of the verticals ≤ 2° and an RMS spread of the yaws ≤ 3° (the opposite quaternion
convention is used when it fits gravity clearly better). The flat-phone shot's `slabNormalInMotionFrame` is carried
into the world by the link of a video shot with the flat-phone shot's `motionSessionId` and the scored shot's
`arSessionId`, the nearest in time to its reading A, and compared with the tracker's normal: so the downhill direction
is scored, not only the tilt's size. Without the ids, a matching video shot or a usable link, the normal error is n/a
with the reason.

**Aggregates**: `lockRate` is the mean over slab shots, `timeToLock` the median over the shots that locked,
`neverLocked` a count; tilt and normal errors pool every locked frame of every shot with a true tilt; `cornerRms` is the
median over shots; `slabSizeError`, `ballDistanceError`, `dropHeightError`, `landingDistanceError` and `apexError` are
medians of the shots' absolute values, as is `impactHeightError`; `landingError` and `rebound` medians over drops; the slab
and ball false-positive and detection rates pool their frames.

**Report.** JSON (`KitScoreSet`: one `KitScoreReport` per kit with the kit id ("synthetic" for the synthetic kit), plan,
build, phone model, iOS version, LiDAR, which settings, the shots, positions and aggregates with every metric's value,
unit, direction, count and n/a reason, and notes; no paths) and Markdown (the aggregates, a table per position, per slab
shot and per ball shot, and the n/a reasons). `--compare` matches kits by id and the settings they were scored with (a
kit scored with `--measured` against the same kit scored with the app's settings is listed as not compared: the settings
alone change its scores), and every metric by where it is (aggregate, shot or position): better or worse by more than
its tolerance (in the metric's direction: lower, higher or closer to zero), the same, `changed` for the rebound (a
measurement of the scene, not of the app), new or gone. A value that became n/a, or a metric with a value that is gone,
is a regression.

| Metric | Tolerance | | Metric | Tolerance |
|---|---|---|---|---|
| lockRate | 2 points | | ballDetectionRate | 3 points |
| timeToLock | 0.15 s | | ballFalsePositiveRate, slabFoundRate, slabLockedRate | 1 point |
| neverLocked | 0 | | ballDistanceError, dropHeightError | 3 mm |
| tiltErrorMedian, tiltBias | 0.05° | | landingError, landingDistanceError, apexError | 5 mm |
| tiltErrorP90, normalErrorP90 | 0.1°, 0.2° | | impactHeightError | 3 mm |
| normalErrorMedian | 0.1° | | rebound | 2 points |
| cornerRms, slabSizeError | 0.5 mm, 1 mm | | | |

**The synthetic kit** (`KitSyntheticKit`): every shot of the plan made through `KitStore` as the app makes it, rendered
by `SyntheticScene` with known truth. Measurements entered (7 x 7 x 1 in, 1/8 in dish, 35 mm ball); positions level, 5°
and 10° (the optional third tilt skipped), the slab sliding in its cradle; flat-phone shots from CoreMotion streams of
the phone laid on the slab on a camera bump and turned around, run through `KitFlatSession`; camera paths still (3-4
ft, a little sway), half-circle arc and room scan; dim and bright (the picture's brightness x 0.6 and x 1.15); the ball
on the floor 3 ft and 5 ft away with the slab out of view; in the dish; held 4 in, 1 ft and 2 ft over the slab (the
heights entered); drops from 1 ft at the centre and near an edge at 60 fps, the ball falling from its release, bouncing
off the dish along the corner plane's normal at the rebound (0.7) of its speed squared (the app's model, so a perfect
tracker predicts it) and then on the floor; the negatives (camera turned away; slab without ball). Every video shot has
a 100 Hz CoreMotion stream consistent with its camera path through a fixed CoreMotion-to-ARKit rotation. To stay fast,
an ordinary shot has 12 frames at 6 fps (`--frames`) and drops 60 fps only around the bounce. Slab-only shots are
480x360 (the app's processing frame); the shots with the ball are 1440x1080, a real kit's video size, so the app's ball
finder gets as many pixels across the ball as from a real kit (a third as many at 480x360, where its scores would say
little). Frames are rendered when scored, or encoded as video.mp4 with `--video` (needs ffmpeg). The held heights are
entered as the app asks for them (the ball's bottom above the dish straight below it). Its truth
(`KitSyntheticKit.truth`) checks the scorer in the tests. CI runs it on every change, twice (`bounce-score --synthetic
--markdown --max-tilt-error 2`, with the app's ball finder, and again with `--truth-ball`, so the ball and bounce
scoring itself is exercised; Markdown in the run's summary); the synthetic renders are not real footage, and real
kits outrank them. In particular `SyntheticScene`'s ball reflects a plain sky above the horizon and a plain dark floor
below it, by direction only, so its outline shows a dark band inside the top and a crisp lower edge; a polished ball
reflects the slab, the floor and the room, and its edge brightens at a grazing angle. The ball finder's drop heights on
the synthetic kit (`dropHeightError`) are that renderer's, not a measure of the app on real held shots: on a test ball
that reflects the scene, with Fresnel, the held ball reads about 11 mm low in the same poses.

**Locally** (`ios/tools/score-kits.sh [bundle parts or folders of them]`): unzips all of a kit's parts
(`<kitId>-partNofM.zip`) into one folder outside the repository (default `~/bounce-private/kits`; a folder inside the
repository is refused), builds the release scorer, scores every kit there and the synthetic kit, saves the JSON as
`~/bounce-private/scores/<UTC date>-<git short hash>.json` (`-measured.json` with `--measured`), compares it with the
newest earlier one scored the same way and prints the Markdown (`--no-synthetic` leaves the synthetic kit out). For a kit
the owner uploaded, `ios/tools/kit-uploaded.sh` is the one command: it checks the parts first ("When the kit is
uploaded").

## Kit API (BounceCore)

The kit's core is plain Swift in `BounceCore/Sources/BounceCore/Kit*.swift`, unit-tested on Linux
(`swift test --filter Kit`, synthetic data only). The app adds the camera, CoreMotion, the encoder and the screens.

| File | Main types | What for |
|---|---|---|
| `KitPlan.swift` | `KitPlan` (`.standard`, `.scaled(by:)`, `.named(_:timeScale:)`), `KitStepSpec`, `KitShotSpec`, `KitShotKind`, `KitDiagram`, `KitExpectations`, `KitPositionSpec` | the steps and shots as data: instruction, diagram, kind (`.form`, `.video(seconds:highFrameRate:releaseCue:)`, `.flat`), countdown, expectations, positions; lookups `shot(_:)`, `index(of:)`, `shots(inStep:)`, `progressLabel(step:)`, `flatSettings` |
| `KitFormats.swift` | `KitClipFiles`, `KitFrame`, `KitLiveResult`, `KitLiveState`, `KitTracking`, `KitMotionSample`, `KitQuaternion`, `KitJSONLWriter`, `KitJSONL`, `KitDepth` | the clip files' names and formats: frames.jsonl, motion.jsonl, BDP2 depth; `KitFrame.view(videoWidth:videoHeight:)` gives the `CameraView` for the detectors |
| `KitManifest.swift` | `KitManifest`, `KitShotManifest`, `KitShotRecord`, `KitSlabPosition`, `KitMeasurements`, `KitDevice`, `KitCameraFormat`, `KitVideoInfo`, `KitTime`, `KitJSON` | kit.json and shot.json; measurement ranges and conversion to `SlabSpec`, `BallSpec` and `RecordingSettings` |
| `KitFlatTilt.swift` | `KitFlatSession`, `KitFlatSettings`, `KitFlatTilt`, `KitFlatReading`, `KitTrueTilt`, `KitBump`, `KitStats` | the flat-phone true tilt: the live state machine, and the maths (`twoReading`, `singleReading`, `solve`, `gravity`, `slabNormalInMotionFrame`) |
| `KitQuality.swift` | `KitQuality`, `KitQualityReport`, `KitQualityCheck`, `KitQualityReference`, `KitFrameStat`, `KitVerdict`, `KitSeverity`, `KitImageStats`, `KitMotionBlur` | the quality check after each shot, and the per-frame luma and blur |
| `KitStore.swift` | `KitStore`, `KitProgress`, `KitListing`, `KitSummary`, `KitStepSummary`, `KitFiles` | the kit folder: create, list, resume, record, skip, positions (and restarting one), heights, finish, summary, crash repair |
| `KitBundle.swift` | `KitBundle`, `KitZipWriter`, `KitBundleResult`, `KitBundlePart` | the zip parts the owner shares |
| `KitPhoneVideo.swift` | `KitPhoneVideo` | the phone's video settings (`KitRecorder`'s size, bitrate, frame rates, depth rate) and the largest file a real kit can hold |
| `KitArrival.swift` | `KitArrival`, `KitArrivalReport` | whether a kit unzipped from its parts holds every file kit.json and its shot.json files describe (`bounce-kit check`) |
| `KitSyntheticPhoneKit.swift` | `KitSyntheticPhoneKit`, `KitVideoStreamWriter` | the dry run's synthetic kit the size of a real one, as the phone writes it (macOS and Linux, needs ffmpeg) |
| `KitDemoMotion.swift` | `KitDemoFlatPhone` | the demo's phone lying on the slab (CoreMotion-like samples from the exact model, with a fake camera bump), for the flat-phone shot in the Simulator and the UI tests |

**The app**, in outline:

```swift
let root = applicationSupport.appendingPathComponent("Kits")
let store = try KitStore.resumable(root: root).map { try KitStore.load(folder: $0.folder) }   // only kits this build can open
    ?? KitStore.create(root: root, device: device, measurements: KitMeasurements(settings: settings), build: build, date: Date())
if let p = store.positionInProgress, ownerSaysSlabMoved(p.label) {  // on Resume only: "Has the slab moved since you set up ...?"
    try store.restartPosition(forShot: store.progress.nextShotId!, date: Date())   // the flat-phone shot is next again
}
// each screen: store.progress.nextShotId, store.progress.label ("Step 4 of 12"), store.plan.shot(id)
try store.commitMeasurements(entered, date: Date())                  // step 1 (throws with plain messages if out of range)
let folder = try store.beginShot(id)                                // record into it: KitClipFiles.video, .frames, .motion, .depthFolder
var m = try store.newShotManifest(id, startedAt: start, duration: d) // ids, attempt, device, measurements, position and true tilt filled in
m.startTime = startUptime; m.releaseTime = beepUptime                // ARFrame/CoreMotion clock; drops only for releaseTime
m.motionSessionId = motionRun; m.arSessionId = arRun                // one CoreMotion run and one ARSession for the whole kit screen
m.video = ...; m.quality = KitQuality.evaluate(shot: shot, stats: frameStats, expectedFrames: n, reference: store.qualityReference)
try store.commitShot(id, manifest: m, date: Date())                 // Retry: beginShot again. Skip: skipShot. Leaving mid-shot: discardAttempt
let flat = KitFlatSession(settings: store.plan.flatSettings, knownBump: store.knownBump)  // flat-phone shots: feed every sample;
// beep when phase becomes .waitingForLift or .done; then m.flat = flat.result ?? flat.finish(); m.quality = KitQuality.evaluate(shot:flat:)
try store.setHeight(id, inches: h, date: Date())                    // step 9, optional
store.summary().lines                                               // the end screen; then try store.finish(date: Date())
let outbox = documents.appendingPathComponent("Kits/\(store.kitId)")
let parts = try KitBundle.build(kitFolder: store.folder, outbox: outbox,
                                deflate: rawDeflate)                // Compression framework, COMPRESSION_ZLIB (raw DEFLATE)
```

Per frame the app fills a `KitFrame` (luma from `KitImageStats.meanLuma(bytes:...)` on every frame, `live:
KitLiveResult(state: KitLiveState(tracker.state), ...)`) and a `KitFrameStat(frame:)` for the quality check.

**In the app** (`ios/BounceApp`): `KitSession.swift` runs the flow above; `KitViews.swift` draws the screens and the
diagrams; `KitRecorder.swift` writes one shot (AVAssetWriter with its own pixel-buffer pool: each camera image is scaled
with vImage while ARKit's delegate call runs, so no ARFrame is kept; a frame gets its frames.jsonl line only once the
encoder took it). While the kit screen is open, `ARController` runs ARKit's 4:3 format (at most 1920 wide) with the
highest frame rate, re-run without resetting tracking, and its one CMMotionManager at 100 Hz in `xArbitraryZVertical`
with a handler that feeds motion.jsonl and `KitFlatSession`; both go back to the app's own when the kit closes, and their
run ids (new UUIDs when the kit opens and whenever either restarts) go into every shot.json. The demo's flat-phone shot
uses `KitDemoFlatPhone` (synthetic samples from the demo slab's tilt with a 1.5° camera bump, turned by itself about a
second after the prompt).

**The scorer** reads a received kit without changing it: `KitJSON.decode(KitManifest.self, ...)` for kit.json and
`KitShotManifest` for each shot.json, `KitJSONL.read(KitFrame.self, from:)` and `KitJSONL.read(KitMotionSample.self, from:)`
for the clips (file names from `KitClipFiles`), `KitDepth(data:).depthMap` for depth (`KitFrame.depthURL(shotFolder:)`),
and the ground truth from `manifest.position(forShot: id)?.groundTruth`: `tiltDegrees` and `uncertaintyDegrees` (the
downhill direction, `downhillAzimuthDegrees` and `tiltVector`, is in phone-A axes; it reaches ARKit's world only through
`slabNormalInMotionFrame` and a CoreMotion-to-ARKit rotation, see above). Measurements count only when
`measurementsEnteredAt` is set. `KitFlatTilt` can re-solve a flat-phone shot from its motion.jsonl (or from the readings
kept in the result), and `KitFrameStat(frame:)` with `KitQuality.evaluate` re-runs the quality check. (`KitStore.load`
tidies a kit after a crash, so it is for the app.)
