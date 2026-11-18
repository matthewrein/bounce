# Slab Bounce for iPhone

[![iOS build](https://github.com/matthewrein/bounce/actions/workflows/ios.yml/badge.svg?branch=native-ios)](https://github.com/matthewrein/bounce/actions/workflows/ios.yml?query=branch%3Anative-ios)

## Morning brief: build n9 (18 November 2026)

Everything in n9 reached `native-ios` only after GitHub's checks passed on it. If the badge above is green, build n9 is
ready for the phone. If it is red, don't pull yet.

### Update the phone

1. In Terminal: `cd bounce`, then `git checkout native-ios` and `git pull`.
2. `cd ios`, then `xcodegen generate`, then `open SlabBounce.xcodeproj`.
3. Plug in the iPhone, pick it at the top of the Xcode window and press **Run**. If Xcode asks for a team, pick yours
   (step 5 of "First time" keeps it for next time).
4. In the app, tap the gear, then **Developer**: Build should say **n9**.

### Try these three first

1. **Pre-flight.** Gear > Developer > **Pre-flight** > **Run**. Point the phone at the room and hold it fairly still for
   about 10 seconds. Each line says PASS, WARN, FAIL or N/A. Tap **Copy results** and paste them to me. If anything says
   FAIL, go back to Developer, tap **Copy log** and paste that too.
2. **Point and go.** From 4 to 5 ft, point at the slab. It should say "Slab locked" within a few seconds and draw the
   path. Hold the ball about a foot over the slab, with your fingers covering as little of it as you can: the drop
   height should change and read "(ball)". Then gear > Developer > **Copy diagnostics** and paste it: its "frames"
   numbers tell me whether the phone keeps up.
3. **Capture kit.** Gear > Developer > **Capture kit** (about 10 minutes; every step can be skipped). Then **Make
   bundle**, upload the parts to your private `bounce-captures` repository as described under "Sending it, privately"
   below, and tell me **"kit uploaded"**: I check every part and score the kit with one command. If a step fails, tap
   **Quit** (the steps already done are kept), then gear > Developer > **Copy log** and paste it.

### What changed overnight

- **Ball height.** The held ball's size is read from its outline more carefully, so the drop height from the ball is
  about 3 mm off on the plain test renders, down from 15 mm (a render of a ball that mirrors the room still reads about
  1 cm low). A shiny ringed lid on the slab no longer takes the place of a held ball; a lid on its own is still taken
  for a ball in a few views, as before. A ball held very low (about 4 in over the slab) is still usually missed.
- **Camera frames.** The app holds at most 2 of ARKit's frames (one being worked on, one waiting), where a slow slab
  search could hold over 100 before; ARKit stops sending frames at about a dozen. While the app is busy, a newer frame
  replaces the one waiting. Focus, exposure and white balance are held only once the camera has stopped adjusting.
  Opening or closing the capture kit, which changes the camera's format, makes the app re-confirm the slab's lock. The
  slab's edges are measured on the full-resolution picture, which roughly halves the corner error at 4 to 6 ft. Picture
  conversions are 2 to 3 times faster, with identical results.
- **First-run tools** (gear > Developer, "First run on a phone"): **Pre-flight**, **Copy log** and **Clear log**. The log
  records every error in the capture kit, the recorders, the camera and the motion sensors, plus each kit step, in
  words and numbers only.
- **Capture kit safety.** A failed or interrupted step never loses earlier steps: tested by simulating the app being
  killed at every file write. A retake that comes out worse no longer replaces a good take.
- **Hand-off.** When you say "kit uploaded", one command fetches your private repository, checks every part (all
  there, not damaged), unzips and scores the kit, and says whether you can delete the kit from the phone. A full-size
  synthetic kit (108 MB, 4 parts, each at most 24 MB) went through the whole path. GitHub also sends the bundle the
  real app makes in the Simulator through that command on every change.
- **Bounce analysis.** From a recorded drop the scorer now measures the ball's real path, the impact point on the dish,
  the rebound and where the ball really lands, and compares that with the app's prediction. I redid its 12 test drops on
  your 7 in slab (the first ones were on an 18 in slab by my mistake), half of them filmed from 3 to 3 1/2 ft, as the
  kit asks, the rest from 4 to 5 ft. With a stand-in ball finder that knows where the ball is, all 12 are measured and
  the rebound comes back within 0.1 point, so the analysis itself works. With the app's own ball finder only 4 of 12 are
  measured, and they read the rebound 4 to 9 points high (76 ± 4% for a true 70%, 89 ± 6% for 85%). The rendered ball's
  lower half is about the grey of the floor behind it, so the finder often sees only its bright top, takes the ball for
  smaller and farther away than it is, and throws the reading out. Your real drops will show whether a real ball does
  the same.
- **Device budget.** Each step of the per-frame work was timed and scaled to GitHub's Mac (an Apple M1); the Mac's own
  timing of this code is in n9's checks. Once the slab is locked, the app uses about 5 to 30% of one core at 60 frames a
  second, except close up over a speckled floor or with a hand over a corner of the slab, where it still drops some
  frames. While it is still searching close up (2 ft) on a cluttered floor, a search takes 130 to 230 ms, so the
  outline and path update only a few times a second until the slab locks (under a second). The camera picture itself
  stays smooth. Newer iPhones (13 Pro and later) should be about as fast as that Mac or faster; an iPhone 12 Pro about
  10% slower.
- **Harsher test scenes** (on a separate test branch, not in n9): a mirror ball reflecting a cluttered room and the
  person holding it, low light with sensor noise, motion blur, a slab side with almost no contrast, and mixed lighting.
  What they found is under "Open questions".

### Verified by tests, and only compiled

- **Verified:** 430 tests of the slab, ball, bounce, tracking, recording, capture kit, hand-off and budget code on Linux,
  and again optimised on a Mac; 9 end-to-end tests in the iPhone Simulator on the app's demo scene (lock and tilt,
  sliding the slab, the rebound setting, the ball's drop height, a recording, diagnostics, the whole capture kit
  including quitting mid-recording and resuming, pre-flight, Copy log); the hand-off dry run; the app's own bundle
  through the one command.
- **Only compiled, never run on a phone:** the camera and ARKit frames (including the new frame hand-off), focus,
  exposure and white balance holding, LiDAR depth, the motion sensors, the capture kit's video recording from the
  camera, the kit's camera format switch, pre-flight's camera, ARKit, LiDAR and motion checks, and real timing on an
  iPhone. The Simulator tests run the optimised build, but on a drawn scene on a shared Mac, so their speed says
  nothing about a phone.

### Open questions and known gaps

- **The bounce itself.** The app launches the ball along the slab's normal. A real ball dropped on a tilted surface
  also keeps some of its downhill speed, which on an 8° slab sends it off at nearly twice that angle. Your recorded
  drops will show which is right; I will change the app only if they agree.
- **The dish's shape.** The app treats the 1/8 in dish as a bowl through the four corners. If it is a round dish
  inside the square, it leans about twice as much near the middle. Which is it?
- **Close range.** When the slab's near cut face is about as bright as its top, the app can take the bottom of the cut
  face for the top's edge, and the tilt reads wrong: 1.5° off at 2 ft and 6° at 3 ft on the test scenes, and 5° at
  4 ft when a lamp lights the near cut face. From 4 to 6 ft the ordinary test scenes read within 0.1°. The obvious fix
  breaks the case of a cut face in deep shadow, so the reviewers held it back; your kit will show how often it happens.
- **Hard cases from the harsh scenes:** a hand holding the ball (from above or from the side, the app missed it at 2 to
  4 ft), a fast falling ball's motion blur, a slab side that almost vanishes against a floor of the same shade, mixed
  lamp and window light, and a shaky hand or a dim room at 6 ft can still fail. Fixes go in only where independent
  reviewers agree they are real weaknesses, not quirks of the renders; the hand and the mixed light are agreed and come
  after n9.
- **A speckled floor** (terrazzo, granite, gravel) right behind the space over the slab can be taken for a ball.
- **Privacy:** the three slab photos can still be reached on GitHub through an old commit, although no branch has them
  (I'll give you its id in our conversation, not here). Make the repository private, or ask GitHub Support to remove
  the cached commit.

The native version of Slab Bounce. It finds the cement slab on its black base, works out its tilt and draws the path a
ball would take bouncing off it. It uses ARKit, so the lens is known exactly and the slab, once found, stays pinned in
place as you move the phone. On iPhones with LiDAR (Pro models) it also measures the slab's top with depth.

You build it on a Mac and install it on your iPhone from Xcode. You don't need to edit any code.

**GitHub checks every change before you build it.** It runs the steps below on one of its Macs: installing XcodeGen,
generating the project, picking up your signing settings, building for the iPhone with the newest Xcode as well as the
default one, and opening the app in an iPhone Simulator. If the badge above is green, the latest version builds; you
only need your Mac to put it on the phone. If it is red, wait for a fix before pulling.

## What you need

- A Mac with **Xcode 16** or newer (free from the Mac App Store). Open it once and let it install its components, including
  the iOS platform.
- **Homebrew** (https://brew.sh), to install XcodeGen.
- An iPhone with **iOS 16** or newer, and a USB cable.
- An **Apple ID**. A free one works (apps installed that way stop opening after 7 days; just run it from Xcode again).

## First time

1. Open Terminal and install XcodeGen:

   ```
   brew install xcodegen
   ```

2. Get the code (once) and switch to the native branch:

   ```
   git clone https://github.com/matthewrein/bounce.git
   cd bounce
   git checkout native-ios
   ```

3. Generate the Xcode project and open it:

   ```
   cd ios
   xcodegen generate
   open SlabBounce.xcodeproj
   ```

4. In Xcode, sign in with your Apple ID: **Xcode > Settings > Accounts > +**.

5. Choose your team: click **SlabBounce** at the top of the left sidebar, then the **SlabBounce** target, then **Signing &
   Capabilities**, and pick your name under **Team**. If Xcode says the bundle identifier is not available, change it to
   something only you would use, such as `io.github.yourname.SlabBounce`.

   To keep these settings when you generate the project again (otherwise you pick the team again after every update),
   save them in a small file. After picking your team as above, run this in Terminal, still in the `ios` folder:

   ```
   TEAM=$(grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10}' SlabBounce.xcodeproj/project.pbxproj | awk '{print $3}')
   printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM" > Config/Local.xcconfig
   cat Config/Local.xcconfig
   ```

   It should print one line like `DEVELOPMENT_TEAM = ABCDE12345`. If you had to change the bundle identifier, add it too:

   ```
   echo 'PRODUCT_BUNDLE_IDENTIFIER = io.github.yourname.SlabBounce' >> Config/Local.xcconfig
   ```

   To check that the file is picked up, run `xcodegen generate`, then
   `xcodebuild -project SlabBounce.xcodeproj -scheme SlabBounce -showBuildSettings | grep DEVELOPMENT_TEAM`.
   It should show your team. The file stays on your Mac and is never committed.

6. Plug in the iPhone and unlock it. Tap **Trust** if it asks. On iOS 16 and later, turn on **Settings > Privacy & Security >
   Developer Mode** and restart when asked.

7. In Xcode's toolbar, pick your iPhone as the run destination, then press **Run** (the triangle). The first time, the iPhone
   may refuse to open the app: go to **Settings > General > VPN & Device Management**, tap your Apple ID, and tap **Trust**.
   Then press **Run** again.

## Updating

```
cd bounce
git pull
cd ios
xcodegen generate
```

Then press **Run** in Xcode. If you chose the team in Xcode instead of `Local.xcconfig`, choose it again.

## Using it

Open the app and point the phone at the slab, from about 2-5 ft away. That is all: there is nothing to set up.

- When the outline turns yellow and the label says **Slab locked**, the slab is pinned. Focus, exposure and white balance
  are then held too, once the camera has stopped adjusting them (within about 2.5 s).
- The yellow outline is the plane through the slab's four top corners. The dashed white line is the launch direction,
  perpendicular to that plane. The cyan arc is the bounce, with the apex and where it lands. The readouts at the bottom
  give the slab's tilt, the apex height, how far away the ball lands and its time in the air.
- Hold the ball above the slab: its height sets the drop height, shown as "(ball)", and the label says **Slab locked ·
  ball in view**. Without a ball, the drop height from Settings is used.
- If you slide the slab to change its angle, the app notices after about a second and locks onto the new position.
- The slab (about 7 in square, 1 in thick, with a 1/8 in dish) and the 35 mm titanium ball are built into the app.
- Seen from straight above, the slab's tilt hardly shows in the picture, so the app waits for a view at an angle before
  it locks, rather than lock on a tilt that could be several degrees off.

**Settings** (the gear at the top right) has the only two things you can change, and you never need to: the **drop
height** (used when no ball is held over the slab; 3 ft) and the **rebound** (how much of the drop height a straight-up
bounce would regain; 70%). **Restore defaults** puts both back.

## Developer tools

At the bottom of Settings, **Developer** opens the tools for working on the app. The app never needs them and never
opens them by itself.

- **Capture kit**: records the slab, the ball and a few bounces with the truth about them, once, when asked (see
  "Capture kit (developer tool)" below).
- **Record session**: records what the app sees and does, so the session can be replayed on a computer (see below).
- **Copy diagnostics**: copies a block of text (JSON) to the clipboard and shows it. Paste it into your message. It shows
  the build, the lens, what the app found, and its counters: numbers and settings, no pictures. `framePacing` shows how
  the camera's frames came and went, over the last 10 seconds and since the camera started: frames delivered,
  processed, dropped because processing was busy (`framesDroppedBusy`: a newer frame replaced them while they waited;
  in the demo, `framesSkippedLate`), the most camera frames the app held at once (`maxFramesHeld`: at most 2, the one
  being processed and the one waiting) and how long processed frames waited (`handoffWaitMs`), delivered late by ARKit
  itself (`framesLateButIdle`), how long ARKit's delegate took with each frame (`delegateMs`: the app's cheap notes and
  the hand-off, and while a capture kit shot records its scale of the picture) and the frames that waited behind it in
  the delegate's own queue (`framesQueuedOnDelegate`: held by the app outside the hand-off, and not counted as late from
  ARKit), and never delivered by the camera; pauses (an interruption, the camera stopping
  while the capture kit opens or closes), counted apart from missed frames; how long frames took to reach the app and
  to process (median, 95th percentile, largest), overall and by what ran on the frame (`processingByKind`: a slab
  search, a re-check of the lock, the ball finder alone, or none of them); and how often the slab search, the lock's
  re-check and the ball finder ran. `captureLockSettle` says how long the camera took to settle before its focus, exposure and
  white balance were locked, `slabCrop` where the last full-resolution close-up of the slab was cut (the
  counter `slabCropMisses` counts re-checks that found the slab outside the close-up cut around the lock, so its edges
  were read on the quarter-size frame: the slab moved, or the lock drifted), and
  `videoFormatChange` the last time the camera's video format changed (the capture kit opening or closing). The recent
  events list the same moments in words, e.g. "capture locked after 0.42 s settled" (or, at the 2.5 s timeout, what
  was still adjusting) and "video format 1920x1440 30 fps -> 1920x1440 60 fps".
- **Reset tracking**: forgets the slab and looks for it again.
- **Demo scene**: a synthetic slab instead of the camera, to see how the app works without the slab (it is also what
  the Simulator tests run). **Launch along the dish's normal** is an experiment: the ball leaves along the dish's normal
  where it lands instead of the corner plane's. Both apply when Settings closes.
- **Build** shows the build label (e.g. n7), and the line under it the tracker's live state, including its hints, which
  the main screen never shows. Its "frames:" row sums up the last 10 seconds and is refreshed every second, e.g.
  "frames: 58.9/s in, 3% dropped busy, held 2, wait 4/12 ms, 1% late from ARKit, delegate 1 ms p95, 0 gaps, 0 pauses,
  delivery 21/34 ms, process 6/19 ms (p50/p95; p95 plain 6, ball 9, search 80, re-check 25), detector 8.3/s": frames a
  second from the camera; the share dropped because processing was busy (a newer frame took their place), the most
  frames the app held at once (at most 2; "-" in the demo) and how long the processed frames waited for processing; the
  share ARKit itself delivered late; the delegate's own time per frame (if it ever reads more than about 16 ms, frames
  queue behind it, shown as "% queued behind it"); gaps where the camera sent nothing, and pauses; how long frames took to reach the app and to
  process (typical and slow, in milliseconds), with the slow time by what ran on the frame: nothing ("plain"), the ball
  finder, a slab search, a re-check of the lock; and how often the slab detector ran. Searches and re-checks are
  expected to take longer than a frame (tens of milliseconds) a few times a second; many dropped frames, or plain
  and ball frames well above 17 ms (one frame at 60 fps), mean the phone is not keeping up.
- **Pre-flight** (at the bottom, under "First run on a phone"): a 10-second check for the first run on a new phone. Tap
  **Run**, point the phone at the room and hold it fairly still. It checks the camera permission, ARKit's tracking,
  LiDAR depth, the motion sensors, whether there is room for a capture kit, and makes a 2-second test recording with
  the kit's recorder (as a drop shot records: every frame, with depth on a LiDAR phone), reads it back and deletes it.
  Frames or depth that stop part-way, frames the recorder drops and a clip without depth all show. Each line then says **PASS**, **WARN**, **FAIL** or **N/A** (the
  phone does not have it and the app does not need it, e.g. no LiDAR) with the reason. **Copy results** copies them to
  paste into your message. It never runs by itself, keeps nothing and changes nothing.
- **Copy log**: copies the app's log and shows its last lines. The app writes a line for every error in the capture
  kit, the recorders, the camera and the motion sensors, and a short line for each kit step (started, kept, skipped,
  stopped, bundle made), so if something fails on the phone, one Copy log tells us what happened. Words and numbers
  only: no pictures, no file paths, no names. It keeps about the last 1 MB. **Clear log** empties it (after asking).

### Recording a session

1. In **Settings > Developer**, tap **Record session**. Settings closes and a small red pill at the top of the screen
   shows the time. Aim at the slab for 10-20 seconds, from a few places, with and without the ball. Then tap **Stop** on
   the pill.
2. A share sheet opens with a file named like `slab-20261117-153000.bouncerec.zip`. Use AirDrop or Mail, or **Save to
   Files**.
   The recordings also show up in the **Files** app under **On My iPhone > Slab Bounce**.
3. Send the zip the same private way you sent the slab photos. A recording shows your room, so **don't** attach it to a
   GitHub issue or anything public.

A recording holds every frame's camera position, lens and tracking state with what the app made of it (60 a second),
the phone's motion, pictures at 480x360 (in black and white with colour detail) about 5-8 times a second, the ball
finder's close-up of the slab and the space above it 10 times a second while the slab is locked, the full-resolution
close-up of the slab its edges were measured on (about 0.3 MB) on every frame the slab detector used one, and LiDAR
depth where the phone has it. That comes to about **25-50 MB per 10 seconds** while the app is still looking for the
slab and roughly **70-130 MB per 10 seconds** once it is locked (most of it the close-ups; a little more with LiDAR), and
the zip is not compressed. So use **AirDrop**, **Save to Files** or iCloud Drive; Mail switches to Mail Drop above about
20 MB. Once the zip is made, the app deletes the unzipped copy. A recording stops by itself at 1.5 GB (a few minutes),
or if the phone runs out of space, and the pill (and Settings > Developer) says why.

## Capture kit (developer tool)

**What it is.** A guided recording of the slab, the ball and a few bounces, together with the truth about them: your
measurements, and the slab's exact tilt, read by laying the phone flat on it. With it, the app can be tested and
improved against your own room without more help from you. You do it **once, when asked**, and it takes about
**10 minutes**. The app never needs it and never starts it by itself.

**Where it is.** **Settings** (the gear) **> Developer > Capture kit**. Have a ruler and the ball at hand.

**Taking it.** Tap **New kit** (or **Resume** if you started one before). Each screen says which step you are on ("Step 4
of 12") and what to do, with a small picture. Tap **Start**: it counts down, records by itself and checks the result
(Good, Fair or Poor, with the reason). Then tap **Next** to keep it, or **Retry** to take it again. **Every step can be
skipped**: **Skip** is next to **Start**; once a shot is recorded, **Discard** deletes it (after asking) and skips it.
In the first step, enter only what you measured with the ruler (the grey numbers are the app's own; leave the dish
empty if you did not measure it), or tap **Skip**. For the drops, let go of the ball at the high beep, when the screen
says **Drop now** (the countdown's ticks come before it). For the slab's tilt, the phone lies flat on the slab: at the
long beep, when the screen says so in big letters, turn it around; a low tone means it is done. For the ball held
above the slab, you can enter its height afterwards: stand a ruler on the slab right under the ball and read the
height of the ball's bottom, or leave it empty. You can tap **Quit** at any time: everything done so far is
kept, and **Resume** carries on where you stopped. If it asks whether the slab has moved since you stopped, answer
honestly; it then reads the slab's tilt again first. If the phone rings or you leave the app in the middle of a shot,
that shot is not kept: tap **Start** to take it again. Nothing that was already kept is ever lost that way: if a
**Retry** fails, is cut short, or comes back worse than the take you had (a flat-phone reading with no tilt, or a
poor check where the earlier one was fair or good), it is not saved and **Keep earlier** keeps the take you already had.

**Sending it, privately.** The kit shows your room, so it goes into a **private** GitHub repository, never this public
one. You need only Safari on the iPhone.

Once, to make the private repository (in Safari on the iPhone):

1. Open **github.com/new** and sign in if asked.
2. Under **Repository name**, type `bounce-captures`. Choose **Private**. Turn on **Add README** (a switch or a tick
   box, depending on the page; without it the repository stays empty and has no upload page). Tap **Create
   repository**.
3. Open **github.com/settings/installations** and tap **Configure** next to **Claude**. Under **Repository access**, if
   it says **Only select repositories**, add `bounce-captures` and tap **Save**. (If it says **All repositories**, there
   is nothing to do.)

For each kit:

1. In the app, at the end of the kit, tap **Make bundle**. It saves the kit as one or more zip files named like
   `slab-kit-20261117-153000-part1of3.zip`, each at most 24 MB (under GitHub's 25 MB limit for uploads).
2. In Safari, open **github.com/matthewrein/bounce-captures/upload/main**. If the page shows no upload area, tap **aA**
   in the address bar, then **Request Desktop Website**.
3. Tap **choose your files**, then **Choose Files** in the menu that opens, then **Browse**, then **On My iPhone >
   Slab Bounce > Kits**, and open the kit's folder. Tap **Select**, select every part, then tap **Open**. (If the page
   says the repository is empty, it has no README yet: add one on the repository's page first.)
4. Wait until all the parts are listed, then tap **Commit changes** (leave **Commit directly to the main branch** chosen).
5. Tell Claude in the session: "kit uploaded". Claude checks every part and tells you either that you can delete the
   kit from the phone, or which part to upload again (the same way, just that file).

If the upload does not work from the phone: tap **Share kit** in the app, AirDrop the parts to your Mac, and drag them
onto the same page (github.com/matthewrein/bounce-captures/upload/main) in a browser there.

**Never attach a kit to an issue, a comment or anything public.** Once Claude confirms it has the kit, **Delete kit from
phone** on the app's last screen removes it and its parts.

## For developers

- `BounceCore/` is a Swift package with no Apple-only code. It contains the pose and bounce maths, the detectors, the
  tracker and the recording format. Run its tests with `swift test` in `ios/BounceCore`, on a Mac or on Linux. The tests
  include ground truth exported from the web test bed (`web/tests/export_ios.js`) and replays of short synthetic recordings.
- `BounceApp/` holds the SwiftUI and ARKit app. `ARController.swift` feeds ARKit frames to BounceCore's `SlabTracker`, the
  same code the replay tests run. The slab and ball the app uses are baked in at one place, `AppSettings` in
  `AppModel.swift` (BounceCore's `SlabSpec.standard` and `BallSpec()`); the user can only change the drop height and the
  rebound. The developer tools are in `DeveloperView.swift` (Settings > Developer).
- The capture kit's screens are `KitSession.swift` (the flow, on BounceCore's `KitStore`, `KitFlatSession` and
  `KitQuality`), `KitViews.swift` (the screens and diagrams) and `KitRecorder.swift` (video, frames, motion and depth for
  one shot); ARController hands it each frame while a kit shot records. `CaptureKit.md` describes the kit's design and
  formats. With `-demo YES -kitFast YES` the kit runs on the demo scene at a quarter of its timings (the UI tests).
- The pre-flight is `PreflightRunner.swift` (it watches ARController through `setPreflight` and records its test clip
  with `KitRecorder`) and `PreflightView.swift`; BounceCore's `Preflight.swift` judges what it saw. The developer log is
  `AppLog.swift`, on BounceCore's `DevLog` (Application Support/Logs on the phone).
- Recordings are version 2 of the format in `BounceCore/Sources/BounceCore/Recording.swift`: a line for every frame the
  tracker processed, with what was done to the tracker and its result on the phone, so a replay can compare frame by
  frame. Frames whose slab detection used the camera's full-resolution pixels keep that crop (`s<NNNNNN>.pgm`), and the
  replay hands it back to the tracker; older recordings, without crops, replay as before.
- The frame pipeline's rules are BounceCore types, tested on Linux, that ARController applies to every frame:
  `FrameHandoff` (ARKit delivers frames on a queue of their own, which does only cheap work and hands each frame to
  the processing queue: at most one frame is processed and at most one waits, the latest, a newer one replacing it and
  the old one released at once; so the app holds at most two of ARKit's frames in the hand-off however long a slab
  search takes, and ARKit, which stops delivering once an app holds about a dozen, does not stall behind a search
  (unless the delegate's own work outruns the camera, as the capture kit's scale of each picture could on a busy older
  phone: then frames wait in the delegate's queue, which `framePacing` shows as `framesQueuedOnDelegate` and
  `delegateMs`); its numbers, kept by a
  `FramePacer`, are the diagnostics' `framePacing`; the demo's frames, rendered on the processing queue, use the
  pacer's skip rule instead: skip a frame that waited behind slow processing and is more than a frame late, never more
  than 0.25 s without processing one), the tracker's `minDetectionGap` (the slab detector runs at most 20 times a second whatever forces
  it), `SlabImageCrop` (where to cut the full-resolution luma for the slab's edges: the processing frame at a quarter
  size finds the slab, the camera's own pixels place its edges, `TrackerFrame.slabDetail`), `CaptureLockGate` (lock
  focus, exposure and white balance once the camera has stopped adjusting them, at most 2.5 s after the slab locks)
  and `VideoFormatWatch` (a new video format, as when the capture kit opens, is a world-frame discontinuity: the lock is
  kept only unconfirmed until the slab is seen again in the new format). In ARController the delivery queue notes the
  tracking state, relocalisation and the video format on every frame (the notes reach the processing queue ahead of
  the frame), lets the pre-flight see it, hands it over, and gives it to the capture kit's recorder while a shot
  records (every frame, whatever the tracker is doing, with the latest tracker result; the recorder scales the picture
  into its own buffer there and then, keeps nothing of the frame, and takes only the frames its video's rate needs).
  The video format is read from the frames themselves, so any re-run of the session is covered, and
  the change is noted on a frame of the new run, not on the old run's last frames that ARKit still delivers after the
  ask: a new size on its first frame; a new frame rate alone (the same size) once three frames in a row are spaced at
  the new rate, or a second after the ask if they never are (noted "by time").
  `FrameConversion.lumaCrop` cuts the ball's and the slab's crops with vDSP, to the same values as summing pixel by
  pixel (the scorer's `KitFramePipeline.lumaCrop` mirrors it).
- The tracker's work is bounded where it buys nothing (`TrackerSettings` fields whose defaults are the old behaviour,
  so older recordings replay as the phone ran them; the app's values are in `RecordingSettings.trackerSettings`):
  searches from a still camera that have found nothing for a second run every 0.36 s instead of every 0.12 s, until
  the camera turns or moves, a search finds a candidate, a tap, a reset or a world-frame discontinuity
  (`idleSearchAfter`); with no ball shown and none waiting for its second scan, the ball finder slows from every
  0.1 s to every 0.3 s after half a second of finding none, and is back at 0.1 s as soon as it finds one or the lock
  changes (`idleBallAfter`); the slab sweep never grows a starting point inside an outline it has already found
  (`sweepSkipsFinds`), and refines a start's outline once rather than once per colour tolerance when they are the same
  (`sweepSameOutlinePixels`); it keeps the finder's own cap of 48 regions a search (`maxSweepRegions` unset: a cap of
  32, tried, missed the slab on a cluttered floor seen from some sides, and bounce-bench now checks the search on such
  views). The
  colour frame is converted only when the slab detector will run (`SlabTracker.detectorWillRun`), and the per-frame
  conversions (`YCCImage.fromBiplanar`, `colorFrame`) and the recorder's encoders are written for speed with the very
  same output (`SpeedupIdentityTests`). `ios/BounceBench` (bounce-bench) times each stage and models the 60 fps
  budget through the app's hand-off.
- Device budget, as bounce-bench models it for this code (a Linux run scaled to the CI Mac by the two machines'
  calibration loops; the CI Mac's own run of this code is still to come): frames dropped a second at the CI Mac's p95
  costs (in brackets: a warm A14, the oldest LiDAR phone), THREAT at 3 a second or more. ARKit's frames are never held
  more than 3 at a delivery (2 in the hand-off) in any of these states. Still THREAT, while locked:
  - 2 ft on a cluttered floor with no ball: 29/s (32). The ball finder takes a speckled patch of the floor for a ball
    and follows it, so its whole-window scan (50-70 ms on the Mac) runs every 0.1 s; a real speckled floor could also
    give a wrong drop height. Open: the ball finder's texture check.
  - a hand over a corner (the moment of the drop): 6.5/s (6.5) at 2 ft, 3.2/s (3.9) at 4 ft. A re-check of a covered
    outline takes 2-3 frames (about 35 ms at p50 on the Mac, up to 59 ms, against 16 ms uncovered). Open: cheaper
    re-checks of a covered or missed outline.
  - after world-frame discontinuities, 4 ft: 3.6/s (1.5); at 2 ft 2.6/s (watch). Each costs a whole-view re-check.
  - locked with no ball held: 0/s in this run, about 2/s when the slowed ball scan (every 0.3 s) lands on re-check
    frames, as the two 0.3 s timers drift in and out of step.
  And while it has no lock yet (the overlay is not tracking anything): searching or confirming at 2 ft on a cluttered
  floor 56/s (56) (a 130-230 ms search), at 4 ft cluttered or tiled 45/s, at 2 ft plain 15/s, at 4 and 6 ft 7.5/s (any
  search over 33 ms drops a frame); panning over an empty cluttered floor 30/s (38), or 14.5/s once the camera is held
  still for a second. Only a cheaper search, or one off the processing queue, would clear those.
- To replay one of your recordings: unzip it and run
  `BOUNCE_RECORDING=/path/to/slab-....bouncerec swift test --filter ReplayTests` in `ios/BounceCore`.
- CI (`.github/workflows/ios.yml`) runs the BounceCore tests on Linux and macOS. It then repeats the owner's steps on a
  Mac: it checks that `Config/Local.xcconfig` sets the team and bundle ID, and that Run uses the Release configuration. It
  builds the app without signing for the Simulator and for iPhone, with the default and the newest Xcode. Finally it
  launches the app in the Simulator and keeps a screenshot as an artifact.
