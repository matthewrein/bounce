# Capture kit: design and formats

The capture kit is a guided mode in the iOS app. The owner runs it once, for about 10 minutes, and hands back one bundle.
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
- **Retry**, **Next** and **Skip**.

The owner can **Quit** at any point; progress is saved after every shot, and reopening the kit offers **Resume**. A shot
interrupted half-way (the app going to the background, a phone call) is discarded and stays pending. If the kit resumes
in the middle of a slab position (`KitStore.positionInProgress`), the app first asks "Has the slab moved since you set up
<label>?"; on **Yes** it calls `restartPosition`, and the position starts again from its flat-phone shot (see "Slab
positions"). At the end, the app lists what was captured and what was skipped, then builds the bundle and offers one
**Share** button.

| Step | Shots (id) | What the owner does | Length |
|---|---|---|---|
| 1 Measurements | `s01-measure` (form) | Enter the slab's width, depth and thickness (ruler), the dish depth (optional; the form starts with it empty) and the ball's diameter. The phone model and LiDAR are read automatically. The values also go into the app's Settings. | form |
| 2 Room scan | `s02-scan` | Walk slowly around the slab, 3-5 ft away, pointing at it, so ARKit settles. | 20 s |
| 3 True tilt (level) | `s03-flat-level` (flat) | Lay the phone flat in the middle of the slab, screen up, top pointing away; let go. When it beeps, turn it around (top toward you); let go again. Starts **slab position 1, "level"**. | about 12 s |
| 4 Slab only, level | `s04-level-still`, `s04-level-arc` | Hold still 3-4 ft away, slab in the middle of the screen; then walk a slow half circle around it. | 5 s + 20 s |
| 5 Slab only, tilts | `s05-tilt1-flat`, `s05-tilt1-still`, `s05-tilt1-arc`, then the same for `tilt2` and, optionally, `tilt3` | Slide the slab to a new tilt (about 5°, 10°, 15°). Each tilt starts with a flat-phone true tilt, which begins a new slab position. | per tilt: about 12 s + 5 s + 15 s |
| 6 Light | `s06-dim`, `s06-bright` | Same slab position: dim the room, then make it bright. | 6 s + 6 s |
| 7 Ball only | `s07-ball-3ft`, `s07-ball-5ft` | Ball resting on the floor away from the slab (slab out of view), the phone about 3 ft from it, then about 5 ft. | 5 s + 5 s |
| 8 Ball on the slab | `s08-ball-centre` | Ball resting in the middle of the dish. It ties the ball's size to the slab's distance. | 6 s |
| 9 Ball held above | `s09-held-low`, `s09-held-mid`, `s09-held-high` | Hold the ball over the middle of the slab: low (about 4 in), middle (about 1 ft), high (about 2 ft). After each shot, the owner may enter the measured height of the ball's bottom above the slab's top, or skip that. | 5 s each |
| 10 Bounces | `s10-drop1`, `s10-drop2`, `s10-drop3` | Hold the ball about 1 ft over the middle of the slab and let go at the beep. Keep the slab and the floor around it in view. Recorded at the highest frame rate ARKit offers. | 6 s each |
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
`waitingForLift` and `done`.

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
flat-phone shot with the same ids (best: the nearest video shot in time) can use it. Until the scorer does this, it scores
the tilt's size (`tiltDegrees`) only.

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

**Video.** 1280x960 (4:3, the camera image scaled down; the full camera image is usually 1920x1440). For ARKit at 60 fps,
ordinary shots keep every other frame (30 fps), and the high-frame-rate shots (drops) keep every frame. Target bitrate
for HEVC: 3 Mbit/s at 30 fps and 5 Mbit/s at 60 fps; H.264 gets 1.5 times as much. Timestamps in the file are ARKit's
frame timestamps minus the shot's start.

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
build label; the device; the measurements, and `measurementsEntered` (false: they are the app's settings, step 1 was not
done); the slab position id (with its generation) and the true tilt of that position (copied); `motionSessionId` and
`arSessionId` (see "The downhill direction and ARKit's world"); the video (codec, width, height, fps, bitrate, frame
count, file size); the camera format (full width, height and fps); whether LiDAR depth is present, and how many depth
frames; the motion sample count; the entered height (inches) if any; the quality report; for drops, the release cue (the
plan's seconds after `startTime`) and `releaseTime` (uptime seconds when the beep actually played); for flat-phone shots,
the result (`flat`); free notes. The app sets `startTime`, `releaseTime` and the two session ids.

**KitManifest** (`kit.json`): format `"bouncekit"`, version 1, kit id, plan id, the time scale when it is not 1, build
label, created/updated/finished times; the device (model identifier like `iPhone16,1`, the iOS version, LiDAR, the chosen
ARKit video formats for ordinary and high-frame-rate shots); the measurements (slab width, depth and thickness, dish depth
or null, in inches; ball diameter in mm; validated against the Settings ranges: sides 3-20 in, thickness 0.2-4 in, dish
0-0.75 in, ball 5-120 mm) and `measurementsEnteredAt`, when the owner entered them (null until step 1 is done, and again
if it is skipped: the measurements are then the app's settings, with no dish); the slab positions (and generations) with
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
reported. Video is stored as is; JSON, JSONL and depth are deflated (zip method 8, raw DEFLATE from Apple's Compression
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
uploaded on the web. The tap-by-tap steps for the owner are in `ios/README.md` ("Capture kit"). Once the owner says the
kit is uploaded, the session attaches that repository and clones it outside this repository.

## Scoring (replay against ground truth)

`bounce-score` (an executable in the BounceCore package, macOS and Linux) runs every clip of a kit through the app's
detectors and `SlabTracker`. It decodes the video with `ffmpeg` and scores the result against the manifest:

- **Lock**: lock rate and time to first lock (slab shots).
- **Tilt**: tilt error against the flat-phone true tilt (median and p90, for shots of positions that have one). The true
  tilt of a shot is that of its record's position and generation (`manifest.position(forShot:)`). Only the size of the
  tilt can be scored until the CoreMotion-to-ARKit link (above) is in; then the downhill direction too.
- **Corners**: corner stability, the RMS spread of the per-frame world corners (mm), and slab size against the measured size
  (only when `measurementsEnteredAt` is set; otherwise the measurements are the app's settings).
- **Ball**: detection rate (ball shots), false positives (slab-only and negative shots), and the size check (ball on the
  slab: distance from its size against its distance from the slab pose).
- **Drop height**: the error against the entered heights. Drops are found after `releaseTime` (or `startTime + releaseCue`).
- **Bounce**: predicted against actual landing and apex, plus the rebound measured from the bounces.

It prints a Markdown table and writes JSON. `--compare` against an earlier JSON shows the changes, so a change that makes
any score worse is caught. The same scorer runs on a **synthetic kit**, rendered by `SyntheticScene` with known truth,
in CI on every change, alongside the real kits scored locally.

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

**The scorer** reads a received kit without changing it: `KitJSON.decode(KitManifest.self, ...)` for kit.json and
`KitShotManifest` for each shot.json, `KitJSONL.read(KitFrame.self, from:)` and `KitJSONL.read(KitMotionSample.self, from:)`
for the clips (file names from `KitClipFiles`), `KitDepth(data:).depthMap` for depth (`KitFrame.depthURL(shotFolder:)`),
and the ground truth from `manifest.position(forShot: id)?.groundTruth`: `tiltDegrees` and `uncertaintyDegrees` (the
downhill direction, `downhillAzimuthDegrees` and `tiltVector`, is in phone-A axes; it reaches ARKit's world only through
`slabNormalInMotionFrame` and a CoreMotion-to-ARKit rotation, see above). Measurements count only when
`measurementsEnteredAt` is set. `KitFlatTilt` can re-solve a flat-phone shot from its motion.jsonl (or from the readings
kept in the result), and `KitFrameStat(frame:)` with `KitQuality.evaluate` re-runs the quality check. (`KitStore.load`
tidies a kit after a crash, so it is for the app.)
