# Slab Bounce for iPhone

[![iOS build](https://github.com/matthewrein/bounce/actions/workflows/ios.yml/badge.svg?branch=native-ios)](https://github.com/matthewrein/bounce/actions/workflows/ios.yml?query=branch%3Anative-ios)

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
  lock then too.
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

- **Capture kit**: records the slab, the ball and a few bounces with the truth about them (see below). Coming next: until
  a build has its screens, the row says "coming next".
- **Record session**: records what the app sees and does, so the session can be replayed on a computer (see below).
- **Copy diagnostics**: copies a block of text (JSON) to the clipboard and shows it. Paste it into your message. It shows
  the build, the lens, what the app found, and its counters: numbers and settings, no pictures.
- **Reset tracking**: forgets the slab and looks for it again.
- **Demo scene**: a synthetic slab instead of the camera, to see how the app works without the slab (it is also what
  the Simulator tests run). **Launch along the dish's normal** is an experiment: the ball leaves along the dish's normal
  where it lands instead of the corner plane's. Both apply when Settings closes.
- **Build** shows the build label (e.g. n6), and the line under it the tracker's live state, including its hints, which
  the main screen never shows.

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
finder's close-up of the slab and the space above it 10 times a second while the slab is locked, and LiDAR depth where
the phone has it. That comes to about **25 MB per 10 seconds** while the app is still looking for the slab and roughly
**60-120 MB per 10 seconds** once it is locked (most of it the ball finder's close-ups; a little more with LiDAR), and
the zip is not compressed. So use **AirDrop**, **Save to Files** or iCloud Drive; Mail switches to Mail Drop above about
20 MB. Once the zip is made, the app deletes the unzipped copy. A recording stops by itself at 1.5 GB (a few minutes),
or if the phone runs out of space, and the pill (and Settings > Developer) says why.

### Capture kit (coming next)

The capture kit records the slab, the ball and a few bounces together with the truth about them: your measurements, and
the slab's exact tilt, read by laying the phone flat on it. With it, the app can be tested and improved against your own
room without more help from you. You do it once, and it takes about 10 minutes. (The app's capture kit screens are still
being built. Until a build has them, the row says "coming next" and this section describes what is coming.)

**Taking it.** Have a ruler and the ball at hand. Open **Settings > Developer > Capture kit** and follow the screens.
Each one says what to do ("Step 4 of 12"), counts down, records by itself and then checks the result. Tap **Next** to go
on, **Retry** to take a shot again, or **Skip**. You can quit at any time, and the app offers **Resume** later. If it
asks whether the slab has moved since you last set it up, answer honestly; the app then retakes the slab's tilt first.
At the end it lists what was captured and what was skipped, and saves the kit as one or more zip files named like
`slab-kit-20261117-153000-part1of3.zip`. You can see them in the **Files** app under **On My iPhone > Slab Bounce > Kits**.

**Sending it back.** The kit shows your room, so it goes into a **private** GitHub repository. Never put it in this
public repository, an issue or a comment. You need only Safari on the iPhone.

Once, to make the private repository:

1. In Safari, open **github.com/new** and sign in if asked.
2. Under **Repository name**, type `slab-kits`. Choose **Private**. Turn on **Add a README file**. Tap **Create
   repository**.

For each kit:

3. In Safari, open your `slab-kits` repository (github.com/*your-name*/slab-kits).
4. Tap the **aA** button at the left of the address bar, then **Request Desktop Website**. The phone version of the page
   has no upload button.
5. Tap **Add file**, then **Upload files**, then **choose your files**. In the menu that opens, tap **Choose File**. Go to
   **On My iPhone > Slab Bounce > Kits** and open the kit's folder. Tap **Select**, tap every part, then tap **Open**.
6. Wait until every part has finished uploading. Each part is at most 24 MB, under GitHub's 25 MB limit for uploads.
   Then tap **Commit changes**.
7. Tell Claude "the kit is in *your-name*/slab-kits". If Claude can reach only some of your repositories, add this one
   first: on github.com, open **Settings > Applications > Installed GitHub Apps**, tap **Configure** next to Claude, and
   add `slab-kits` under **Repository access**.

Once Claude confirms it has the kit, the app's finish screen can delete it from the phone.

## For developers

- `BounceCore/` is a Swift package with no Apple-only code. It contains the pose and bounce maths, the detectors, the
  tracker and the recording format. Run its tests with `swift test` in `ios/BounceCore`, on a Mac or on Linux. The tests
  include ground truth exported from the web test bed (`web/tests/export_ios.js`) and replays of short synthetic recordings.
- `BounceApp/` holds the SwiftUI and ARKit app. `ARController.swift` feeds ARKit frames to BounceCore's `SlabTracker`, the
  same code the replay tests run. The slab and ball the app uses are baked in at one place, `AppSettings` in
  `AppModel.swift` (BounceCore's `SlabSpec.standard` and `BallSpec()`); the user can only change the drop height and the
  rebound. The developer tools are in `DeveloperView.swift` (Settings > Developer).
- Recordings are version 2 of the format in `BounceCore/Sources/BounceCore/Recording.swift`: a line for every frame the
  tracker processed, with what was done to the tracker and its result on the phone, so a replay can compare frame by
  frame.
- To replay one of your recordings: unzip it and run
  `BOUNCE_RECORDING=/path/to/slab-....bouncerec swift test --filter ReplayTests` in `ios/BounceCore`.
- CI (`.github/workflows/ios.yml`) runs the BounceCore tests on Linux and macOS. It then repeats the owner's steps on a
  Mac: it checks that `Config/Local.xcconfig` sets the team and bundle ID, and that Run uses the Release configuration. It
  builds the app without signing for the Simulator and for iPhone, with the default and the newest Xcode. Finally it
  launches the app in the Simulator and keeps a screenshot as an artifact.
