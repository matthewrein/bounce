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
interrupted half-way (the app going to the background, a phone call) is discarded and stays pending. At the end, the app
lists what was captured and what was skipped, then builds the bundle and offers one **Share** button.

| Step | Shots (id) | What the owner does | Length |
|---|---|---|---|
| 1 Measurements | `s01-measure` (form) | Enter the slab's width, depth and thickness (ruler), the dish depth (optional) and the ball's diameter. The phone model and LiDAR are read automatically. The values also go into the app's Settings. | form |
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
part of the plan. kit.json is the authority on positions; each shot.json carries a copy made when it was captured.

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
about 2°.

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

**Checks.** The spread within each reading must be ≤ 0.3°, the phone must lie flat-ish (the reading's tilt ≤ 25°), the
turn must be between 120° and 240°, and the bump must be ≤ 5°. A larger bump suggests the phone is not lying flat,
perhaps in a thick or uneven case.

The phone must lie in the middle of the dish: centred on a spherical dish, a flat phone tilts with the dish's axis.

## Clip format (per shot)

A kit is a folder `<kitId>/` (`kitId` like `slab-kit-20261117-153000`, from the creation time in UTC, so it says nothing
about where the owner lives; `-2`, `-3` are appended if two kits start in the same second):

```
<kitId>/kit.json                    KitManifest (rewritten atomically after every change)
<kitId>/shots/<shotId>.attempt/     the shot being recorded; moved to shots/<shotId>/ when committed
<kitId>/shots/<shotId>/shot.json    KitShotManifest
<kitId>/shots/<shotId>/video.mp4    the frames (HEVC, or H.264 where HEVC is unavailable), sensor orientation (landscape)
<kitId>/shots/<shotId>/frames.jsonl one KitFrame per encoded video frame, in order (line n = video frame n)
<kitId>/shots/<shotId>/motion.jsonl one MotionSample per CoreMotion update (100 Hz)
<kitId>/shots/<shotId>/depth/d<NNNNNN>.bdp2   LiDAR depth for video frame NNNNNN (about 1 per second), if the phone has LiDAR
```

Flat-phone shots have `motion.jsonl` and `shot.json` (with the result) and no video. The measurements form has no folder:
its values live in kit.json.

A retry records into a fresh attempt folder, so the earlier capture stays until the new one is committed. If the app
dies mid-shot, loading the kit removes the attempt folder (and any shot folder without a shot.json) and the shot stays as
it was; a shot marked captured whose files are gone becomes pending again. Skipping a captured shot removes its files.

**Video.** 1280x960 (4:3, the camera image scaled down; the full camera image is usually 1920x1440). For ARKit at 60 fps,
ordinary shots keep every other frame (30 fps), and the high-frame-rate shots (drops) keep every frame. Target bitrate
for HEVC: 3 Mbit/s at 30 fps and 5 Mbit/s at 60 fps; H.264 gets 1.5 times as much. Timestamps in the file are ARKit's
frame timestamps minus the shot's start.

**KitFrame** (one JSON object per line; short keys keep the file small; optional values, and non-finite ones, are left
out; `pose` and `K` keep ARKit's own Float values):

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
| `luma` | mean luma 0-255 of the tracker's processing frame (live check) |
| `blur` | estimated motion blur in video pixels (angular speed × exposure × focal) |
| `depth` | depth file name, if this frame has one |
| `live` | the app's live result on this frame: `{"state": "searching"/"confirming"/"locked", "tilt": deg?, "corners": [[x,y]x4]? (video px), "ball": [x, y, r]? (video px)}` |

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
number; the start time (ISO) and duration; the build label; the device; the measurements; the slab position id; the true
tilt of that position (copied); the video (codec, width, height, fps, bitrate, frame count, file size); the camera format
(full width, height and fps); whether LiDAR depth is present, and how many depth frames; the motion sample count; the
entered height (inches) if any; the quality report; the release cue time for drops; for flat-phone shots, the result
(`flat`); free notes.

**KitManifest** (`kit.json`): format `"bouncekit"`, version 1, kit id, plan id, the time scale when it is not 1, build
label, created/updated/finished times; the device (model identifier like `iPhone16,1`, the iOS version, LiDAR, the chosen
ARKit video formats for ordinary and high-frame-rate shots); the measurements (slab width, depth and thickness, dish depth
or null, in inches; ball diameter in mm; validated against the Settings ranges: sides 3-20 in, thickness 0.2-4 in, dish
0-0.75 in, ball 5-120 mm); the slab positions with their true tilts; the level hold-still shot's median luma (the light
reference); one entry per shot in plan order: id, step, status (`pending` / `captured` / `skipped`), attempts, folder,
position id, quality verdict, entered height, duration, frames, bytes, capture time, optional. Times are ISO-8601 in UTC.
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
| `light` | video shots | median luma ≥ 45 (dim shots: ≥ 12), otherwise fair |
| `lightChange` | dim and bright shots, when the level hold-still shot was captured | dim: below 70% of its median luma, otherwise fair "doesn't look dimmer"; bright: above 110% of it, otherwise fair |
| `blur` | video shots | median blur ≤ 3 px for still shots, ≤ 6 px for moving ones, otherwise fair; above twice that is poor |
| `slab` | shots expecting the slab | the slab was found (confirming or locked) in at least 50% of frames, otherwise fair |
| `ball` | shots expecting the ball | the ball was found in at least 30% of frames, otherwise fair |
| `falsePositives` | shots where the slab or the ball must not be in view (negatives, slab-only, ball-only) | the share of frames where it was found anyway is reported and never fails |
| `reading` | flat-phone shots | no reading at all (the phone never lay still), poor |
| `still` | flat-phone shots | each reading's spread ≤ 0.3°, otherwise poor |
| `flat` | flat-phone shots | each reading's tilt ≤ 25°, otherwise poor |
| `turn` | flat-phone shots | 120-240°, otherwise fair (60-120° and 240-300° still solve, more loosely); without a reading B, fair |
| `bump` | flat-phone shots (two readings) | ≤ 5°, otherwise fair |

Boundaries pass (exactly 80%, 45, 3 px, 0.3°, 25°, 5° all pass). Each check carries its value, threshold and a plain
English message; the summary line is the verdict and the first problem ("Fair. ... Next is fine." / "Poor. ... Retry is
suggested."). Per frame, the app computes the mean luma (`KitImageStats.meanLuma`) and the blur from the camera's
rotation since the previous frame (`KitMotionBlur.pixels`: exposure × focal × the optical axis's angular speed, with
roll counted at half a focal length from the centre).

## Bundle

**Finish** builds the bundle into `Documents/Kits/<kitId>/`, which the Files app shows under On My iPhone > Slab Bounce >
Kits. The bundle is one or more zip **parts** named `<kitId>-partNofM.zip`. Each part is at most 24,000,000 bytes, because
GitHub's web upload takes files up to 25 MiB. Each part is a valid zip of whole files, with paths starting `<kitId>/`, so
unzipping all parts into one folder rebuilds the kit. Every part carries `kit.json` (first). Files are packed first fit
in path order. A single file too large for a part on its own gets a part of its own, larger than the limit, and is
reported. Video is stored as is; JSON, JSONL and depth are deflated (zip method 8, raw DEFLATE from Apple's Compression
framework, passed in by the app), and stored when the compressor fails or does not make them smaller. Files are streamed
in chunks, so a video is never held in memory whole. Unfinished attempts and hidden files are left out. Building again
replaces the kit's earlier parts; a failed build leaves nothing behind. The working copy lives in Application
Support, so the Files app does not show it. **Share** offers all the parts at once (AirDrop, Save to Files, ...). The
finish screen also offers to delete the kit once it has been sent.

## Getting it back (the owner's route)

Kits are private and the repository is public, so they travel through a **private GitHub repository**. It needs no Mac
and no coding, only Safari on the iPhone. Steps for the owner are in `ios/README.md` ("Capture kit"). Once the owner says
the kit is uploaded, the session attaches that repository and clones it outside this repository.

## Scoring (replay against ground truth)

`bounce-score` (an executable in the BounceCore package, macOS and Linux) runs every clip of a kit through the app's
detectors and `SlabTracker`. It decodes the video with `ffmpeg` and scores the result against the manifest:

- **Lock**: lock rate and time to first lock (slab shots).
- **Tilt**: tilt error against the flat-phone true tilt (median and p90, for shots of positions that have one).
- **Corners**: corner stability, the RMS spread of the per-frame world corners (mm), and slab size against the measured size.
- **Ball**: detection rate (ball shots), false positives (slab-only and negative shots), and the size check (ball on the
  slab: distance from its size against its distance from the slab pose).
- **Drop height**: the error against the entered heights.
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
| `KitFormats.swift` | `KitFrame`, `KitLiveResult`, `KitTracking`, `KitMotionSample`, `KitQuaternion`, `KitJSONLWriter`, `KitJSONL`, `KitDepth` | the clip files: frames.jsonl, motion.jsonl, BDP2 depth; `KitFrame.view(videoWidth:videoHeight:)` gives the `CameraView` for the detectors |
| `KitManifest.swift` | `KitManifest`, `KitShotManifest`, `KitShotRecord`, `KitSlabPosition`, `KitMeasurements`, `KitDevice`, `KitCameraFormat`, `KitVideoInfo`, `KitTime`, `KitJSON` | kit.json and shot.json; measurement ranges and conversion to `SlabSpec`, `BallSpec` and `RecordingSettings` |
| `KitFlatTilt.swift` | `KitFlatSession`, `KitFlatSettings`, `KitFlatTilt`, `KitFlatReading`, `KitTrueTilt`, `KitBump` | the flat-phone true tilt: the live state machine, and the maths (`twoReading`, `singleReading`, `solve`, `gravity`) |
| `KitQuality.swift` | `KitQuality`, `KitQualityReport`, `KitQualityCheck`, `KitFrameStat`, `KitVerdict`, `KitImageStats`, `KitMotionBlur` | the quality check after each shot, and the per-frame luma and blur |
| `KitStore.swift` | `KitStore`, `KitProgress`, `KitListing`, `KitSummary`, `KitFiles` | the kit folder: create, list, resume, record, skip, positions, heights, finish, summary |
| `KitBundle.swift` | `KitBundle`, `KitZipWriter`, `KitBundleResult`, `KitBundlePart` | the zip parts the owner shares |

**The app**, in outline:

```swift
let root = applicationSupport.appendingPathComponent("Kits")
let store = try KitStore.resumable(root: root).map { try KitStore.load(folder: $0.folder) }
    ?? KitStore.create(root: root, device: device, measurements: KitMeasurements(settings: settings), build: build, date: Date())
// each screen: store.progress.nextShotId, store.progress.label ("Step 4 of 12"), store.plan.shot(id)
try store.commitMeasurements(entered, date: Date())                  // step 1 (throws with plain messages if out of range)
let folder = try store.beginShot(id)                                // record into it: video.mp4, frames.jsonl, motion.jsonl, depth/
var m = try store.newShotManifest(id, startedAt: start, duration: d) // ids, attempt, device, position and true tilt filled in
m.video = ...; m.quality = KitQuality.evaluate(shot: shot, stats: frameStats, expectedFrames: n, reference: store.qualityReference)
try store.commitShot(id, manifest: m, date: Date())                 // Retry: beginShot again. Skip: skipShot. Leaving mid-shot: discardAttempt
let flat = KitFlatSession(settings: store.plan.flatSettings, knownBump: store.knownBump)  // flat-phone shots: feed every sample;
// beep when phase becomes .waitingForLift or .done; then m.flat = flat.result ?? flat.finish(); m.quality = KitQuality.evaluate(shot:flat:)
try store.setHeight(id, inches: h, date: Date())                    // step 9, optional
store.summary().lines                                               // the end screen; then try store.finish(date: Date())
let parts = try KitBundle.build(kitFolder: store.folder, outbox: documents.appendingPathComponent("Kits/\(store.kitId)"),
                                deflate: rawDeflate)                // Compression framework, COMPRESSION_ZLIB (raw DEFLATE)
```

**The scorer** reads a received kit without changing it: `KitJSON.decode(KitManifest.self, ...)` for kit.json and
`KitShotManifest` for each shot.json, `KitJSONL.read(KitFrame.self, from:)` and `KitJSONL.read(KitMotionSample.self, from:)`
for the clips, `KitDepth(data:).depthMap` for depth, and the ground truth from `manifest.position(id)?.groundTruth`
(`tiltDegrees`, `downhillAzimuthDegrees`, `tiltVector`, `uncertaintyDegrees`). `KitFlatTilt` can re-solve a flat-phone
shot from its motion.jsonl, and `KitFrameStat(frame:)` with `KitQuality.evaluate` re-runs the quality check. (`KitStore.load`
tidies a kit after a crash, so it is for the app.)
