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

- Point the phone at the slab, 2-5 ft away, and move it slowly for a second so ARKit can get its bearings. When the outline
  turns yellow and the label says **Slab locked**, the slab is pinned. Focus, exposure and white balance lock then too.
- The yellow outline is the plane through the slab's four top corners. The dashed white line is the launch direction,
  perpendicular to that plane. The cyan arc is the bounce, with the apex and where it lands.
- Hold the ball (35 mm) above the slab: its height sets the drop height, shown as "(ball)". Without a ball, the drop height
  from Settings is used.
- Look at the slab at an angle, not from straight above: from overhead its tilt hardly shows in the picture, so the app
  waits (or asks you to view it at more of an angle) rather than lock on a tilt that could be several degrees off.
- If the outline is on the wrong thing, **tap the slab** on the screen, or press **Reset**. The tap keeps guiding the
  search until the slab locks.
- If you slide the slab to change its angle, the app notices after about a second and locks onto the new position.
- **Settings**: the slab's side length (and the other side, if it is not quite square), thickness, dish depth, ball diameter,
  drop height and rebound.

## Sending results

**Diagnostics**: press **Diagnostics** and the app copies a block of text (JSON) to the clipboard. Paste it into your message.
It shows the build, the lens, what the app found, and its counters.

**A recording** lets the exact session be replayed on a computer, so problems can be reproduced:

1. Press **Record**, and move around the slab slowly for 10-20 seconds, with and without the ball. Then press **Stop**.
2. A share sheet opens with a file named like `slab-20261117-153000.bouncerec.zip`. Use AirDrop or Mail, or **Save to
   Files**.
   The recordings also show up in the **Files** app under **On My iPhone > Slab Bounce**.
3. Send the zip the same private way you sent the slab photos. A recording shows your room, so **don't** attach it to a
   GitHub issue or anything public.

A recording holds about 5 frames a second at 480x360, in black and white with colour detail. It also holds the camera's
position and lens, the phone's motion, and LiDAR depth where the phone has it. That comes to about **13 MB per 10
seconds**, or about **25 MB per 10 seconds on a phone with LiDAR**, and the zip is not compressed. So use **AirDrop**,
**Save to Files** or iCloud Drive; Mail switches to Mail Drop above about 20 MB. Once the zip is made, the app deletes the
unzipped copy. A recording stops by itself at 1.5 GB, or if the phone runs out of space, and the app tells you why.

## For developers

- `BounceCore/` is a Swift package with no Apple-only code. It contains the pose and bounce maths, the detectors, the
  tracker and the recording format. Run its tests with `swift test` in `ios/BounceCore`, on a Mac or on Linux. The tests
  include ground truth exported from the web test bed (`web/tests/export_ios.js`) and replays of short synthetic recordings.
- `BounceApp/` holds the SwiftUI and ARKit app. `ARController.swift` feeds ARKit frames to BounceCore's `SlabTracker`, the
  same code the replay tests run.
- To replay one of your recordings: unzip it and run
  `BOUNCE_RECORDING=/path/to/slab-....bouncerec swift test --filter ReplayTests` in `ios/BounceCore`.
- CI (`.github/workflows/ios.yml`) runs the BounceCore tests on Linux and macOS. It then repeats the owner's steps on a
  Mac: it checks that `Config/Local.xcconfig` sets the team and bundle ID, and that Run uses the Release configuration. It
  builds the app without signing for the Simulator and for iPhone, with the default and the newest Xcode. Finally it
  launches the app in the Simulator and keeps a screenshot as an artifact.
