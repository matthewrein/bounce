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
| `falsePositives` | shots where the slab or the ball must not be in view (negatives, slab-only, ball-only) | the share of frames where it was found anyway is reported and never fails. Where the slab must not be in view the line says only that the app found one: the real slab left in the picture, or one the app keeps following after it left the picture (the live tracker keeps its lock in the world), counts here too |
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
             [--fail-on-regression] [--measured] [--positions SHOT=POSITION,...]
bounce-score --synthetic [--frames N] [--markdown] [--json out.json] [--video h264|hevc] [--truth-ball]
             [--max-tilt-error DEG]
bounce-score --drops [--drops-only ID,ID] [--drop-slab INCHES] [--drop-shrink N] [--drops-json out.json]
             [--truth-ball] [--markdown]
bounce-score --taps <kit folder or a folder of kits> ... [--taps-truth FILE] [--taps-only ID,ID] [--taps-lanes L,L]
             [--taps-json out.json] [--taps-trace]
```

It prints kit ids, shot ids and numbers, never paths. `--fail-on-regression` exits with status 2 when a metric got
worse than in `--compare`; `--max-tilt-error` exits with status 3 when the synthetic kit's median tilt error is above
it or missing; `--scorer LABEL` records who scored (a git hash) in the JSON.

`--positions` corrects kit.json where the slab was not where the plan put it (`KitScorer.Options.positions`): pairs
`SHOT=POSITION`, where SHOT is a shot id or its start (`s07` for both s07 shots; the longest match wins) and POSITION a
position id (`p4`) or `unmeasured`. An unmeasured shot has no true tilt: it reports the tilt it read (`tiltReading`)
and the tilt the app showed (`settledTiltReading`), with no error. The owner's first kit is scored with
`--positions s07=p4,s08=unmeasured,s09=unmeasured,s10=unmeasured,s11=unmeasured,s12=unmeasured` (s07 was still at
p4; s08-s12 were near level, about 0.5 ± 1.5°, with no flat-phone reading).

**Simulated taps** (`KitTapBench`, `bounce-score --taps`, build n15's tap hints): instead of scoring, every video shot
that should show the slab runs several times over one decode, once per lane, through the same per-frame path with the
app's settings (tap hints on), each lane tapping as the owner might: `none` (no tap); `slab` (on the slab on the first
frame, where the phone's live outline had its middle) and `slabLate` (the same 1 s in, if not locked by then); `ball`
(once locked, where the ball really is, while the lane does not show it; needs `--taps-truth`) and `ballOff` (the same
tap a ball radius and half a fingertip to the side); `dismiss` (on each false ring, up to three); and stray taps:
`floorSearch` (on the floor beside the slab, on the first frame that falls between two of the lane's scheduled
searches: a real finger lands on an ordinary frame), `floorConfirm` (the same while a candidate is being confirmed),
`floor05` to `floor45` (the same at 0.5, 1, 1.5, 2, 3 and 4.5 s, if not locked by then; marked `/off` when the frame was
between scheduled searches), `floorLocked` (on the floor 0.3 m from the lock, 0.5 s after it and then every 3 s, up to
4) and `slabOnLock` (on the locked slab's middle at those times). A lane that can no longer tap without having tapped
(`slabLate` or a fixed-time lane locked first) has run exactly as `none` and reports its result. Per lane it reports
when the slab locked, how much of the shot it stayed locked (after a stray tap, against the untapped lane over the same
frames), the lock's tilt and how far it ended from the untapped lane's, the ball scans and the rings shown (true or
false), when the first true ball came, the false rings after a dismissal (tapped on the frame after a false ring first
shows: no reaction time) and the tracker's tap counters. `--taps-truth` is where the ball is, read by eye from
the private clips and kept outside the repository with them: `{"<kit id>": {"<shot id>": {"frame": N, "x": X, "y": Y,
"r": R}}}` (video pixels on one frame; the ball is taken as still in the world). `--taps-only` picks shots (ids or
prefixes such as `s09`), `--taps-lanes` picks lanes, `--taps-json` writes the JSON (again after every shot) and
`--taps-trace` logs each lane's tracker events. It prints shot ids and numbers only. The taps are simulated on recorded
clips: where a real finger lands, and which frame it reaches, are not.

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
  lowest corner; this changes neither the slab nor the ball; the drop analysis lands the bounce where the ball is seen
  to come down next, or 0.1 m below the impact);
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
| `tiltErrorMedian`, `tiltErrorP90`, `tiltBias` | shots of a position with a usable true tilt (`manifest.position(forShot:)?.groundTruth`) | on every locked frame, the lock's tilt (what the outline and the path follow, and what the readouts showed before n11) minus the flat-phone `tiltDegrees`: median and 90th percentile of its absolute value, median of the signed value; per shot and per position (frames pooled). The tilt as shown (the honest estimate once settled) is scored apart (`settled*`) |
| `normalErrorMedian`, `normalErrorP90` | the same | angle between the tracker's normal and the true normal (below), on every locked frame |
| `settledRate`, `timeToSettle` | slab expected | the share of locked frames on which the tilt was shown (`TrackerOutput.angleSettled`: its honest uncertainty at or under 1°, see README "Using it"), and the first such frame's t - t0 (s; n/a: never shown) |
| `settledTiltErrorMedian`, `settledTiltErrorMax`, `settledNormalErrorMedian`, `settledNormalErrorMax` | shots with a true tilt | the tilt and normal errors of the settled normal on the shown (settled) frames only: what the owner would have seen as a number (the normal's error moves the landing: about 4.5 cm a degree) |
| `honestRatioMedian`, `honestRatioP95` | shots with a true normal | at every refresh of the tilt's honest estimate while locked (a re-check added to it), the true normal's distance from its normal in its own covariance (2-D Mahalanobis across the normal): median and 95th percentile. An honest uncertainty gives 1.18 and 2.45; less is cautious, more overconfident |
| `tiltReading`, `settledTiltReading` | shots of an unmeasured position (`--positions`) | the median tilt read on locked frames, and on the shown frames |
| `cornerRms` | slab expected | the lock's four world corners on every locked frame (matched to the first locked frame's), RMS distance from each corner's per-axis median (mm) |
| `slabSizeError` | slab expected, measurements entered | each locked frame's detected outline cast onto the lock's plane; mean of (long side - measured long side) and (short side - measured short side), median over frames (mm). The pose's distance scales with the size the app assumes, so this shows how well the outline fits the measured shape (and the size, once LiDAR is fused) |
| `slabFoundRate`, `slabLockedRate` | slab must not be in view (ball on the floor, `s12-no-slab`) | share of frames confirming or locked / locked on anything but the real slab |
| `slabInViewRate` | the same | share of frames found on the real slab, left in view (the owner's ball shots of both first kits had the ball a few inches from the slab): the find lies on the slab's top as the slab shots of the same ARKit session just before and after locked it (inside its outline, within 26 mm of its plane: half the 52 mm from the owner's top to the floor). A lock is judged by its centre in 3-D; a detection before a lock only by its line of sight (the ray through its middle crosses the top: what that pixel shows, not how far away the candidate is). A lock the app keeps after the slab has left the picture counts too. Those finds are not counted as false; a note names the shots. When no slab shot of the same session locked (another session, or those shots not scored) the finds are not checked, stay false, and a note says so |
| `ballDetectionRate` | ball expected (not `s08`: the app looks only for a ball 5 cm or more above the slab) | of the frames on which the app's ball finder ran (only while locked, every `ballInterval`), the share that found a ball there; a ball the app holds over from an earlier search (it keeps a missed ball for up to 2 searches) is not a find. A ball shot's searches over the real slab, left in view (`slabInViewRate`), are left out: the app looks only over the slab's top, never at the ball on the floor beside it |
| `ballFalsePositiveRate` | ball must not be in view | the same share, where there is no ball (a false ball held over counts once, where it was found) |
| `ballDistanceError` | ball resting on the slab (`s08`) | the tracking finder (below) on every locked frame: the ball's distance from the camera from its size minus the distance along the same ray to where its centre must be resting on the dish where it was found (a radius above the dish's surface along its own normal there, `Dish.at`; on a slab tilted 5-10° the ball cannot stay in the dish's middle, whose slope is at most 2°); frames with the ball not over the slab's top are left out; median (mm) |
| `dropHeightError` | held ball with an entered height (`s09`) | the app's drop height while it comes from the ball (`Readouts.dropHeight`: the ball's bottom above the dish straight below it), median, minus the entered height (mm). The app asks for the same height: a ruler stood on the slab under the ball (in the dish, not on the corners' plane 1/8 in above it) |
| `landingError`, `landingDistanceError`, `apexError`, `impactHeightError`, `rebound` | drops (`s10`, `s11`) | see below |
| `reboundMeasured`, `landingErrorApp`, `landingErrorRebound`, `launchDirectionError`, `impactClearance` | drops (`s10`, `s11`) | the drop measured on the dish, below |

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

**Drops measured on the dish** (`KitDropAnalysis`, `KitDropFit`, `KitDish`). The same track, with each sample's
camera position (`KitBallSample.c`), is measured again against the lock before the cue and the dish's geometry:

- *Noise.* The finder takes the ball's distance from its size, far less precisely than its place in the picture, so its
  error lies along the line of sight. Every free-fall fit (gravity known) is weighted least squares in which a sample's
  error along its line of sight counts kappa² as much as across it; kappa is the fall's own split of its residuals
  (re-estimated until it settles; the bounce's when that is lower), never more than the held ball's spread across over
  along (a still, sharp ball promises more than a blurred falling one gives), 0.03-1. With gravity known in metres the
  arc's curvature in the picture gives the distance, so a fall seen over a few frames is good to millimetres even when
  every frame's distance is centimetres off. All distances below (gates, misfits) are weighted the same way.
- *Segmenting* (release, fall, impact, as above) uses heights taken from the line of sight's elevation at the held
  ball's horizontal distance from the camera, which the distance error does not move. The reference is the median
  height over the hold; not seen held, the top of the first descent after the cue up to the first V (a fall of 3 cm and
  a rise of 2 cm: the first bounce), never the highest point within a second (a lively ball's first bounce can rise
  above the first frames seen of its fall). The fall starts where the ball leaves the hand's own level just before it
  (3 mm below the median height 0.1-0.45 s before the fall is found), not a few millimetres below the whole hold's
  median: a hand that sinks while it waits for the beep would otherwise turn its last held frames into a fall of their
  own. A ball seen rising 3 cm or more before the fall found had an earlier bounce, missed with its fall: refused.
- *The fall*: the arc most of its samples agree on (every trio of samples fitted, scored by the sum of min(d², (15 mm)²),
  MSAC), refitted robustly to those within 15 mm, with a prior that the ball was let go, not thrown (horizontal velocity
  0 ± 0.1 m/s); it must span 3 cm or 30% of the drop. *The rise*: the same consensus over the lowest sample and the next
  eight, the trios also taken through the point where the fall meets the dish (so two wrong frames among a few cannot
  outvote the rest), gate max(8 mm, 3 x the fall's misfit); then grown while each next sample is within max(15 mm, 5 x
  the fall's misfit, 4 x its own) of the fit; one to three wrong frames are skipped when one of the next three (within
  0.08 s) fits again; otherwise the flight ends there. It ended at a **next contact** only when the samples after it make
  an arc of their own (4 or more agree) that the rise comes down onto with an upward kick of 0.2 m/s or more (on the slab
  within 3 cm of the dish over the lock's outline, on the floor within 3 cm of ARKit's floor, else on something); a
  stray detection or a few noisy frames are not one: the ball left the view or was lost. A ball that never rises 1 cm
  but stays on the dish (within 2 cm, 3 or more samples) **rolled**: no rebound.
- *The impact*: where the two fits' heights meet; the impact centre the mean of the fits there; the **contact point**
  where the ball touches the dish when that centre is slid along its line of sight (the finder's error lies there; the
  lock and the dish are good to millimetres; not when the sight runs within 10° of the slab's plane), and the **local
  normal** the dish's normal there (`KitDish`: a spherical cap, 1/8 in deep at the centre, its rim the circle
  inscribed in the top, radius R = (a² + D²) / (2 D): 49 in for the owner's 7 in top; flat outside the rim; the
  surface leans asin(r / R) toward the middle: 1.2° 1 in out, 2.3° at 2 in, 3.5° at 3 in, 4.1° at the rim, so an
  off-centre hit's bounce is not the slab's). `impactClearance` is the gap between the ball at the impact centre and
  the dish (positive: the track turns round above the dish; the finder reads the ball high or the lock sits low). The
  contact point is given along the lock's axes (u, v: for a square slab, any of its edges) and down the slope and to
  its left looking downhill. The impact must be on the top: a clearance over 8 cm (the ball missed the slab and
  bounced on its base or the floor, or the fall is not the ball's) or a contact point more than a radius outside the
  lock's outline is refused, with the reason; one within a radius of the edge (the bounce may be off the edge) or a
  clearance over 4 cm and 3 sigma is kept but left out of the rebound to bake. (The heights' crossing is kept for the
  impact time: on the first rendered drops (an 18 in slab) it lands a few ms early when the finder's distance is off
  through a whole arc, but crossings taken where the fits' elevations meet as the camera sees them, which the distance
  error does not move, read the rebound 4-16 points low on them, and worse on the synthetic tracks; the fits' mismatch
  below covers it instead.)
- *The bounce*: **restitution** e = -(v_out . n) / (v_in . n) about the local normal n; **rebound** = e², exactly what
  the app's rebound setting (`BallSpec.rebound`) means: the share of the drop height a straight-up bounce regains;
  `speedRebound` = |v_out|² / |v_in|² (the older `rebound` metric); the tangential ratio (velocity along the surface
  after over before) and how far the bounce leaves the plane of incidence (`sideways`: spin, or a wrong normal). A
  rebound over 100% by more than 2 sigma is refused (more than the ball can regain), one over 100% within that, or a
  fall moving sideways over 0.2 m/s (thrown, or a later bounce taken for the drop), is kept out of the bake.
- *The release and the held point*: the release is the fall fit's vertex; the held point the median of the ball over
  the 0.4 s before it (a hand that drifts is read where it let go), cross-checked against the fall fit's position then,
  whose depth comes from gravity, not the ball's size: their disagreement (per axis) is part of the held point's
  uncertainty, and a note over 1 cm. The drop height is the held point's height above the impact centre.
- *The landing*: where the rise's arc comes down to the landing level (`landingLevelSource`): **"slab"** when the ball
  came down on the slab again (the real landing; the app's arc is compared at that height, and `carriedOn` gives the
  arc carried on through it to the app's own end level as well); else **"floor"**, ARKit's floor plus a radius when
  known (`floorY`, the phone); else **"next bounce"**, the next contact when it is seen 3 cm or more below the impact
  (the floor, seen; the next arc's fit met with the rise's); else **"lowest corner"**, the app's own end level without a
  floor (`Bounce.compute`: the lock's lowest top corner, plus a radius), so the comparison is the error of the landing
  marker the app draws; without a lock, 0.1 m below the impact centre ("fixed"). It is extrapolated past the last
  sample when the ball left the view (said so, with the seconds).
- *Against the app*: `app` is the app's bounce for the same held ball and the lock (`KitBouncePrediction.app`, so the
  app's own drop height) with the app's rebound, `measuredRebound` the same with the rebound measured here, so what is
  left is the model's error and the held reading's (both start from the held reading, as the app's prediction would),
  not the rebound's; each is carried down to the same landing level: landing error (mm), range error (actual minus
  predicted distance from the launch), direction error of the landing seen from above, and the launch directions'
  angle.
- *Uncertainties* (1 sigma): each fit's 6 x 6 parameter covariance (its sample times and lines of sight, the prior,
  and a sample's noise across the line of sight: the larger of the two fits', at least 0.5 mm) carried through every
  number by its numerical derivatives; then the fits' own check: they must meet at the impact, and their horizontal
  mismatch there against its sigma (chi², 2 degrees of freedom) shows errors their residuals do not (a distance off by
  a few centimetres through a whole arc, as the app's finder did on the 18 in rendered drops): the fits' part of every
  uncertainty is scaled up by sqrt(chi² / 2) when that exceeds 1 (a note over 2). The held point's uncertainty goes
  through the drop height and the predictions. On the scratch harness (the first, 18 in, drop set: 12 drops x 10 seeds
  per scenario: misses, wrong frames, 1.5-2 cm along the line of sight, motion blur, a sinking hand, a held ball not
  seen, the crop clipping it, distance errors correlated frame to frame) the rebound is beyond 3 sigma on 0-5% of the
  drops (it was up to 34%), and never more than 5 points and 3 sigma off in any but the harshest scenarios (one drop
  in 120). A rolling shutter (8 ms readout, not modelled) still leaves the rebound 0.3 points off with a sigma smaller
  than that.
- A track that does not hold together is refused with the reason (as above, but the speed in may be 30% off the fall's,
  and 12% gives a note).

`reboundMeasured` is e² per drop; `landingErrorApp` and `landingErrorRebound` the landing errors against the app's
prediction with its rebound and with the measured one (mm); `launchDirectionError` the angle between the app's launch
and the measured one; `impactClearance` (mm). The report has a table of the drops (drop height with the app's in
brackets, contact point, local tilt, rebound ± sigma, launch angle, and the landing against the app both ways: mm ±
sigma, range error, direction; the notes say when the ball landed on the slab again and what the arc carried on to the
app's end level gives, and when a drop is left out of the bake) and the line **rebound to bake into the app: X% ± Y%
(from N drops), restitution e ± sigma**: the drops' rebounds, those marked to leave out (`bakeExcluded`) and those more
than max(10 points, 3 sigma) off their median left out, weighted by 1 / sigma², and the restitution they stand for, the
square root, which is the app's setting since n12 (`KitDropAnalysis.reboundToBake`; the aggregate `reboundMeasured`).
Since n12 the app's own model is a real impact (`Bounce.LaunchRule.impact`): the falling ball touches the dish (the
measured spherical cap) where it first meets it, and leaves with its velocity along the dish's normal there reversed and
scaled by the restitution, and along the surface scaled by the ball's tangential share (`BallSpec.ownerTangential`).
The synthetic kit's drops bounce that way, so the rebound measured on them is the restitution squared (0.81 for the
app's 0.9); the rendered drops below stay physical (a solid ball that rolls off), so the app's prediction is tested on
them against a bounce it does not assume (with the true rebound it lands 13 mm to 26 cm short of those let go from rest, down the dish's
local slope, as it keeps 0.2 of the speed along the surface and they keep 5/7). Recordings made before n12 (no restitution in
their settings) replay with the rule they ran: out along the corner plane's normal at sqrt(rebound) of the speed in,
which measured this way has e = sqrt(rebound) / cos(tilt).

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
medians of the shots' absolute values, as are `impactHeightError` and `impactClearance`; `landingError`, `rebound`,
`landingErrorApp`, `landingErrorRebound` and `launchDirectionError` medians over drops; `reboundMeasured` the rebound to
bake (above); the slab and ball false-positive and detection rates pool their frames.

**Report.** JSON (`KitScoreSet`: one `KitScoreReport` per kit with the kit id ("synthetic" for the synthetic kit), plan,
build, phone model, iOS version, LiDAR, which settings, the shots, positions and aggregates with every metric's value,
unit, direction, count and n/a reason, and notes; no paths) and Markdown (the aggregates, a table per position, per slab
shot and per ball shot, and the n/a reasons). `--compare` matches kits by id and the settings they were scored with (a
kit scored with `--measured` against the same kit scored with the app's settings is listed as not compared: the settings
alone change its scores), and every metric by where it is (aggregate, shot or position): better or worse by more than
its tolerance (in the metric's direction: lower, higher or closer to zero), the same, `changed` for the rebound (a
measurement of the scene, not of the app), new or gone. A value that became n/a, or a metric with a value that is gone,
is a regression. Since `slabInViewRate` was added, `slabFoundRate` and `slabLockedRate` leave out finds on the real slab, left in
view, and a ball shot's `ballDetectionRate` its searches over it: compare a build scored before that with the same kits
scored again by the new scorer, not with its old score file, or the change shows up as a better app.

| Metric | Tolerance | | Metric | Tolerance |
|---|---|---|---|---|
| lockRate | 2 points | | ballDetectionRate | 3 points |
| timeToLock | 0.15 s | | ballFalsePositiveRate, slabFoundRate, slabLockedRate, slabInViewRate | 1 point |
| neverLocked | 0 | | ballDistanceError, dropHeightError | 3 mm |
| tiltErrorMedian, tiltBias | 0.05° | | landingError, landingDistanceError, apexError | 5 mm |
| tiltErrorP90, normalErrorP90 | 0.1°, 0.2° | | impactHeightError | 3 mm |
| normalErrorMedian | 0.1° | | rebound | 2 points |
| cornerRms, slabSizeError | 0.5 mm, 1 mm | | reboundMeasured | 2 points |
| landingErrorApp, landingErrorRebound | 5 mm | | launchDirectionError, impactClearance | 0.5°, 3 mm |

**The synthetic kit** (`KitSyntheticKit`): every shot of the plan made through `KitStore` as the app makes it, rendered
by `SyntheticScene` with known truth. The slab and ball are the app's own (`KitSyntheticKit.spec`, `.ball`:
`SlabSpec.ownerSlab`, a 180.2 mm flat top, 1 in thick, 1/8 in dish, with its sloped, rounded sides; `BallSpec.ownerBall`,
30 mm), so the scorer scores what ships, and they are the measurements entered; positions level, 5°
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

**Rendered drops** (`KitSyntheticDrops`, `KitDropPhysics`, `KitDropBench`; `bounce-score --drops`): drops with known,
physical truth, separate from the synthetic kit (whose drops keep the app's own model). The slab is the owner's, as the
app has it (`SlabSpec.standard`): 7 in square (`--drop-slab` for another size; the drops' offsets stay in inches), 1 in
thick, dished 1/8 in (the spherical cap above: a sphere of 49 in, leaning 3.5° 3 in out, so an off-centre bounce leaves
well off the slab's normal), its top centre 4.5 in over the floor, sliding in its cradle as it tilts. (The first drop
set was rendered on an 18 in slab by mistake; its numbers are gone from here.) The ball (35 mm) falls from rest (or with
a push or spin when a drop says so) and meets the dish where its centre is the sphere's radius minus its own from the
sphere's centre; the bounce reverses the velocity along the LOCAL normal at e = sqrt(rebound) and treats the velocity
along the surface as a solid sphere with friction 0.4 does (it leaves rolling: 5/7 of it kept when it came in without
spin, the spin taken up with it; it slides throughout only if friction cannot stop the slip within the impact); then
free flight (no drag: under 0.2% of g) to the next contact: the dish while the ball's centre is inside the slab's
outline, the slab's top edges and 1 in cut faces while it is outside (a ball overhanging the edge), the black base under
the slab (5% wider than it and 2 mm under it, as rendered) and the floor (both rebound 0.3), and so on (no drop of the
standard set touches an edge or the base: the tests check that, and the edge and base contacts themselves). The standard
set (rendered with `KitSyntheticDrops.Options.tangential = .ratio(0.4)`, n12's share, instead, the analysis refuses
d07, the 6 in drop: the app's finder loses the ball over the bounce's apex above the dish, 0.11-0.24 s after the impact,
and the analysis takes the descent after that gap for the fall, "too little of the fall was seen (9 mm of 105 mm)"; with
`.ratio(0.2)`, the share since n13, it refuses d02 instead, "too little of the fall was seen (26 mm of 219 mm)", and
reads d07 at 77% for 85%; open): 12 drops at the centre and about 1, 2 and 3 in from it on several sides (the 3 in ones toward the corners: toward
the middle of an edge a contact point stays more than the ball's radius inside it only within 2.8 in of the centre) and
one 3.3 in out, 10 mm inside the downhill edge (measured, but left out of the rebound to bake), so the dish leans
0.1-3.9° where they land; rebounds 0.5-0.85, tilts 0-12°, heights 6-36 in, cameras from the side, at 45°, from behind
and in front of the bounce, 0.94-1.06 m (3.1-3.5 ft) from the slab for the six drops of a foot or less (the distance the
kit asks for when it films the slab, 3 to 4 ft; its drop steps name none), and 1.22-1.51 m for the higher ones and for d05, kept at 1.36 m so that one drop's ball crop is not shrunk
(the tracker did not lock the 7 in slab from 1.7 m), a push at the release, frames the recorder dropped, the ball
leaving the picture 0.73 s after the release, halfway through its bounce (d12); every frame's timestamp jittered by up
to 0.4 ms. Each is a shot as a kit records it (6 fps to lock, the cue at 2 s, then 60 fps from 0.25 s before the release
until 0.25 s after the landing), 1440x1080, with exposure motion blur (1/120 s: the ball rendered at 7 instants over it
and averaged); the renderer draws the top as the corner plane, so a ball sunk into the dish below it is drawn over it.
`KitDropBench` runs each through the scorer's own per-frame path (`KitScoreRun.runShot`: the frame pipeline, a fresh
tracker with the measured slab, the tracking finder on every frame), analyses the track with `KitDropAnalysis` as a
kit's is (no floor; `--drops-floor` gives it ARKit's floor, y = 0, as on the phone) and also analyses a perfect track
(the true centre on every frame, the true slab): the analysis's own error. The landing and the comparisons are scored
against the truth at the analysis's own landing level (where the ball came down on the slab again, the floor seen, or
the lowest top corner). The report (Markdown, JSON with every track) gives each drop's camera distance, the shrink of
the app's ball crop and the true ball's radius in it, the measured minus the true numbers (rebound, contact point, local
tilt, drop height, impact time, launch direction, landing, and the landing against the app both ways), how many drops
are beyond 3 sigma (rebound, drop height, landing against the app), and the rebound to bake per true rebound. With the
app's finder every drop locks (d09's lock 0.47° and 11 mm off, the others within 0.31° and 2.1 mm), but only 4 of 12 are
measured: the finder finds the ball on 24-69% of a drop's frames, its track is 5-41 mm off on a median frame, and the
analysis refuses the rest with the reason: no rise seen after the fall (d01, d05, d06, d11), the fall's and the bounce's
fits not meeting at the impact (d03), a track that turns round 86-88 mm below the top (d08, d09: wrong frames taken for
the ball), too few frames after the impact (d12). All four measured read the rebound high: 75% ± 5 (d02) and 77% ± 6
(d10) for 70%, 89% ± 6 (d07) for 85%, and 79% ± 11 (d04) for 70%, left out of the bake as an edge hit (its contact point
read 6 mm from the edge, truly 29 mm). None is beyond 3 sigma, nor near it: the largest are d10's rebound at 1.3 sigma,
d02's drop height (26 ± 24 mm high) and rebound at 1.1, and d04's at 0.8-0.9; so the rebound to bake comes out 76% ± 4%
from the two 70% drops and 89% ± 6% from the one 85% drop, within their sigmas but all on the high side. Medians of
measured minus true: rebound 6.1 points (worst 8.7), contact point on the dish 9 mm, its local tilt 0.15°, drop height
19 mm, impact time 7.2 ms, launch direction 1.9°, landing 12 mm, the landing against the app 3 mm (its rebound) and 8 mm
(the measured one) from the truth's. Why the finder does so badly here: the app's crop is shrunk by 2 on 11 of the 12
drops, so the ball is 10-15 px in radius in the finder's image (19-21 px on d05, whose crop is not). Logged frame by
frame against the true ball (d01 and d10, shrunk; d05, not): on 50 of the 65 frames it misses on d01 and d10 (20 of 50
on d05) the ball's vote peak is the strongest in the search, but its outline is not read: the rendered ball's lower
half, which reflects the grey floor, is about the grey of the floor behind it, and in the fall motion blur softens its
top and bottom. The finder then finds nothing there (10 of d01's 66 drop frames, 3 of d10's 67, 28 of d05's 70), or
reads only the bright upper cap, as a circle 0.7-0.8 of the ball's radius, a size that puts the ball 20-40% too far
away, beyond the slab, so the locator rejects it (13 frames of d01, 10 of d10, 7 of d05); most of the rest are circles
it finds only with its radius range narrowed to the true one, or beyond the 8 vote peaks it examines. Where it takes a
find, the distance is still centimetres off along the line of sight. (A first explanation, that a crop not shrunk made
the ball too big for the finder, was wrong: shrunk crops fail the same way. An independent check that forced the shrink
to 2 on the earlier, farther cameras left the drops already shrunk unchanged, bit for bit, and found the ball more often
on the two that were not, without getting either measured.) That is the ball finder's to fix, or the rendered ball's:
real footage will say. With a finder that knows where the ball is (`--truth-ball`: the analysis, the lock and the crop
without the finder's errors) all 12 are measured: rebound 0.0 points (worst 0.1), contact point 0.7 mm (10.5 mm on d09,
whose lock is 11 mm and 0.47° off), local tilt 0.01°, landing 0.0 mm; the rebound to bake 50% ± 1%, 70% ± 1% and 85% ±
1% (d11, the one 60% drop, is the edge hit). Its sigmas are a perfect track's and leave out the lock's pose error, so
millimetres read as many sigma: d06's rebound, 50.1% ± 0.02, is 4.7 sigma for 0.1 point, and 6 of 12 landings against
the app (its rebound) are beyond 3 sigma, by 0.9-7.1 mm against sigmas of 0.2-0.7 mm: d01 0.9 mm (4.5 sigma), d03 1.7 mm
(8.9), d05 1.3 mm (7.1), d06 4.7 mm (24), d09 7.1 mm (10.5; 13.7 mm, 20 sigma, with the measured rebound: its lock's
error) and d12 3.8 mm (6.0). The app's crop also limits the track on a 7 in slab: it is the slab grown by its own size,
so the ball leaves it about 7 in past the slab's edge, and on the higher drops (d04, d08, d09) the bounce is followed
for only part of its flight and the landing extrapolated 0.22-0.34 s; d12's ball leaves the picture itself, 0.73 s after
the release, and its landing is extrapolated 0.33 s. The perfect tracks give the truth back (0.0 points, 0.0 mm; the
tests check it with the floor and without), and a test works the set's truth out again from first principles (the
sphere, the bounce, the landing and the comparison with the app's prediction), without the dish geometry and the
comparison the analysis shares with the simulator. What it shows about the app's model: the app launches along the
corner plane's normal, but a ball dropped straight onto a surface tilted by t leaves at about t + atan(5/7 tan t / e)
from vertical, nearly twice as far, and on the 7 in dish the surface leans up to 3.9° more, toward the middle: so even
with the true rebound its landing on the floor is 2-38 cm off, further than the app says on 11 of the 12 (7 cm on the
level slab 2 in out, where the app goes straight up) and 2 cm short on d11, near the downhill edge, where the dish leans
against the slope; its paraboloid dish leans half as much as the spherical cap near the middle.

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
