# Slab Bounce for iPhone

[![iOS build](https://github.com/matthewrein/bounce/actions/workflows/ios.yml/badge.svg?branch=native-ios)](https://github.com/matthewrein/bounce/actions/workflows/ios.yml?query=branch%3Anative-ios)

## Build n13 (19 November 2026): restitution 0.9

Small build on top of n12; everything below still holds except the restitution and the along-surface share it starts
with. Developer shows **n13**.

**What changed**
- Settings' **Restitution** now starts at **0.90** (n12: 0.80), and the ball keeps **0.2** of its speed along the
  surface (n12: 0.4). The 0.9 is measured on your first kit: its drops' first bounces came back with 0.896, 0.912,
  0.903 and 0.917, the later bounces 0.917-0.924. The 0.2 is not measured; it is the share that, with 0.9, keeps the
  distance you saw with Rebound at 100% in n11 (the predicted distance is 0.94-1.00 of n11's at 100%).
- The scorer (track E): the "false slab" numbers on the ball-on-the-floor shots were the real slab, left in view a few
  inches from the ball, in both kits (apart from 4 frames of a candidate on the mat in your second kit, which the app
  never locked and the phone never showed). The scorer now counts a find on the real slab as the real slab. On the
  phone, the kit's note after those shots no longer says the app saw a slab that isn't there; it says a slab still in
  the picture is the real one. The app itself is otherwise unchanged.

**Checked on your real clips** (the same separate, careful tracker as in n12's check below): on your first kit's 4
drops the predicted landings move by 3 mm or less from n12's (4.0-7.1 cm off, the drop near the edge 2.6 cm); your
second kit's 2 drops move 5-7 mm further off (17.6 and 20.5 cm; the app still used its 3 ft default there). Those
drops are on a nearly level slab, where the pair hardly matters; it shows on a tilted slab.

**Only compiled**: the Settings screen with 0.90 compiles in GitHub's checks but has not run on a phone. The share of
0.2 is still a choice, not a measurement.

**Try**: after updating, check that Developer says n13 and Settings shows Restitution 0.90 (if it shows 0.80, n12 saved
it when you moved the slider or tapped Restore defaults: tap Restore defaults, because 0.80 with the new share of 0.2
lands about a fifth short of the distance you matched, 0.76-0.81 of n11's at 100%). Drop the ball from about 1 ft:
does it land nearer the drawn ring than in n12?
For the next kit, do the drops with the slab tilted (8 or 12 degrees, not moved after its flat-phone step): they
measure the along-surface share. In the ball-on-the-floor shots, turn so the slab is out of the picture.

## Build n12 (19 November 2026): the bounce model

Small build on top of n11; everything below about n11 still holds. Developer shows **n12**.

**What changed**
- The ball now bounces the way a real ball does. It hits the dish where it first touches it; its speed straight into the
  surface comes back scaled by the **restitution**, and it keeps part of its speed along the surface (a share of 0.4).
  Before, it always shot straight out of the slab and lost that along-the-surface speed, which is why "Rebound 100%"
  matched your distance.
- The dish is a round cap. Your first kit's pictures show it curves about twice as much near the middle as the app had
  assumed, so an off-centre hit now bends the bounce toward the middle.
- Settings has **Restitution** (starts at 0.80) instead of Rebound. The old Rebound value is not carried over: it was
  standing in for the missing along-surface speed and would make the bounce land about a third too far.

**Checked on your real clips** (a separate, careful tracker measured 6 of your 8 drops, all on a nearly level slab)
- First kit, 4 drops: the predicted landing moved from about 8 cm off to about 5 cm; the drop near the edge from 10 cm
  to 3 cm.
- Second kit, 2 drops: worse (17 and 20 cm off), because the app read the lattice ball as held off the side of the slab
  and fell back to its 3 ft default. That is the ball finder's problem; the lattice-ball build deals with it.
- Your drops come back with a restitution of about **0.9** (the first kit; the second kit's falls were not tracked
  well enough). If your 0.8 meant "it comes back to 80% of the height", the better pair is 0.9 with an along-surface
  share of about 0.2; build n13 (above) sets that.
- Left-right: in the kits the ball went right of the old prediction, not left, so your leftward miss is not reproduced
  yet; the slab was nearly level in every drop, which tests the dish's curve, not the tilt direction.

**Only on test scenes or only compiled**: the share of 0.4 is not measured (drops on a tilted slab would measure it); the
Settings screen and the app's bounce drawing compile in GitHub's checks but have not run on a phone.

**Try**: point at the slab as before, check that Settings shows Restitution 0.80, and drop the ball from about 1 ft:
does it land nearer the drawn landing ring than in n11? For the next kit, do the drops with the slab tilted (8 or 12
degrees) and do not move it after its flat-phone step.

## Morning brief: build n11 (19 November 2026)

Build n11 answers your three priorities from the first kit. It reaches `native-ios` only after GitHub's checks pass on
it: if the badge above is green and Developer says **n11**, it is the one described here.

### Update the phone

1. In Terminal: `cd bounce`, then `git checkout native-ios` and `git pull`.
2. `cd ios`, then `xcodegen generate`, then `open SlabBounce.xcodeproj`.
3. Plug in the iPhone, pick it at the top of the Xcode window and press **Run**. If Xcode asks for a team, pick yours
   (step 5 of "First time" keeps it for next time).
4. In the app, tap the gear, then **Developer**: Build should say **n11**.

### Try these first

1. **The angle from a still phone.** Stand about 3 ft from the slab (2.5-4 ft is fine) and hold the phone still,
   tilted about 45-55° down (up to 60° at 3 ft; the slab seen clearly from the side). About half a second after "Slab
   locked" the Tilt should show a number. Then gear > Developer > **Copy diagnostics** and paste it.
2. **Settling.** From the same distance, hold the phone steeply over the slab (about 70° down, as in your kit): the
   Tilt and Lands should read "settling". Lower the phone toward 45°: the number should come.
3. **Your sizes.** Measure the slab's top with a ruler (the flat part and the full width), its thickness, and the
   rounding of its top edge if you can (a coin held against it is enough), and tell me.

### Your three questions, in plain words

1. **The outline taking in the slab's side face (your top priority): fixed up to about 4 ft.** The app now knows the
   real shape of your slab's sides: each side face drops about 21 mm while it runs about 8 mm outward, and the top's
   edge is rounded. n10 assumed a straight-down 1 in face, so it expected the side face to show as a band about half as
   wide as it really is, and it often took that band, or its bottom, for the top's edge. Now each side's line goes on
   the top's own edge: where the side face shows as a band, on the band's inner edge, where the top's brightness ends;
   where the face is hidden, on the rounded edge's outline. The app also learns your sides' drop and run as it goes,
   from the sides where both edges of the band show. On your kit, judged from the pictures alone, about **5%** of the
   near sides that show a band now sit mid-band or on its bottom (about **41%** with n10), and about 3% more sit just
   inside the top's edge (bands about as light as the top, where one view cannot tell which edge it sees; the app
   treats those as uncertain, below). Most of the rest that are still off are sides read as a plain outline although
   their face shows a band, and the fast arc at the 17° position. Farther than about 4 ft, a side whose face is about as
   light as the top is still read a little onto the face (see 3).
2. **A poor tilt while the camera is still: it was mostly the side face, and is fixed with it.** With every side on
   the top's edge, a still view reads about right from the first lock: on your level still shot the locked tilt is
   **0.06°** off (its direction 0.45°), where n10 read 7.2° off. Two more changes help. LiDAR no longer turns the tilt:
   on this small raised top its plane was 4-15° off from a standstill; it now only checks the distance, and agrees with
   the picture to about 1%. And the app's new honest estimate of the tilt (below) keeps only a view's newest readings,
   so a bad start ages out within about a second; the outline and the path also drop a view's older readings once its
   newest ones disagree with them (within one to two seconds). Moving the phone is no longer what fixes it.
3. **A usable tilt within about a second, without moving: yes, without LiDAR, from a moderate angle; not from steeply
   above.** From about 3 ft (2.5-4 ft) with the phone tilted 45-55° down (up to 60° at 3 ft; the slab clearly seen
   from the side, not from above), one still view pins the tilt to about 1°, and the number shows about half a second
   after the slab locks: 1-1.3 s after you point the phone (up to 2 s at 4 ft), within 0.35° of the truth, on test
   pictures of your slab (your kit had no still view that low). The app now waits for two checks after the lock to agree before it shows a
   number, so a first reading that only looks precise is never shown on its own. At 4 ft and 62° down it shows from
   some sides of the slab and not from others. From steeper than about 65°, the way you held the phone in the kit
   (about 70° down, 3.5-4.5 ft), one view cannot pin it that well (its honest uncertainty there is 1.3-1.9°), so the
   app says **settling** instead of showing a number that may be a degree or more off. Lower the phone a little and
   the number comes.
   Nearly straight above the slab (within about 20° of looking straight down on it) all four side faces show, which
   the app does not read yet: it says settling there, or does not lock at all.
   **Beyond about 4 ft it is not right yet.** On harsher test pictures of your slab (a different look: lighting and
   texture) at 4 ft and 6 ft (40-45° down), the near sides, whose faces are about as light as the top, are read a
   little too far out: the outline's tilt comes out 1.2° and 1.9° off. The app now keeps saying settling there (it
   used to show that number for a moment), but your kit's room scan, from about 4.7 ft, still showed a number for two
   thirds of the shot, about 0.7° off and at worst 1.3° (its direction at worst 1.4°, which moves the landing about 6
   cm). So for now stand about 3 ft away; fixing the far sides is next.

### What you will see

- **settling**: right after the lock (for at least half a second: two checks of the lock must agree first), Tilt and
  Lands read "settling" (dimmed), the status says **Slab locked · settling**, and the path is drawn faint and dashed with no landing ring; Apex and Air keep their values (a degree
  moves them by millimetres). The number appears once the tilt is good to about 1° (1° moves the landing about
  4.5 cm). Gear > Developer shows the honest uncertainty itself ("tilt sigma 1.7° · 1 view group · settling").
- **The slab and the ball are your measured ones.** The flat top is **180.2 mm** (7.09 in) square: measured from the
  kit's own pictures, ± 1.5 mm (the outline over the rounded edge is about 184.5 mm). You said "160mmish" by eye; the
  kit rules 160 mm out for the flat top, so tell me what you measured, or give me a ruler reading of the top's flat
  width, the bottom's width and the thickness: it is one number to change. The size sets the slab's distance (and so
  the held ball's height), not its tilt. The ball is **30 mm**, as you said; the kit measures 30.1 ± 0.6 mm. n10 had
  35 mm, 16% too big, which put a held ball's height off by centimetres.

### Your kit, replayed through n11

Every video shot of your first kit through the n11 app's own code, each shot from a fresh start (the scorer), with s07
at the 17° position and s08-s12 near level (about 0.5°, not measured). "Shown" is a number on the screen; otherwise it
said settling.

- **Shown numbers:** never more than 0.6° off in tilt on the shots with a known slab position. On the three arcs
  where the number came (9-43% of the locked frames, after 12.9-14 s), the shown tilt was at most 0.14°, 0.57° and
  0.35° off; the slope's direction, which moves the landing (about 4.5 cm a degree), at most 0.32°, 0.94° and 0.37°.
  The fourth arc (17°) and the near-level drop shots stayed on settling, except one drop shot that showed 0.29° from
  0.9 s on a slab that is level to about a degree. The room scan (about 4.7 ft, taken before the first flat-phone
  shot, so scored as if the slab was level) showed a number on two thirds of its locked frames, 0.71° off at the
  median and 1.27° at worst (direction 1.42°): the one shot where a number more than a degree off was shown. The arcs
  were filmed fast (15-30° a second), which blurs the edges; a slower arc should settle sooner.
- **Your still views:** settling throughout, as they should: their single-view errors were up to 1.2°. The level still
  locked at 0.06° (0.45° in direction) and the 17° view at 3 ft at about 1.2° (measured before the last fixes; the
  scorer does not score that shot); the 5° and 17° stills from straight-ish above never locked, as in n10.
- **The locked tilt** (what the outline and path follow), median error per shot, n10 then n11: level still 7.19° to
  0.06°, level arc 2.56° to 1.43°, 5° arc 2.10° to 0.54°, 11° arc 0.98° to 1.41° (the one shot that got worse; it
  never showed a number more than 0.35° off), 17° arc 0.46° to 0.04°. Over all slab shots the lock reads 0.71° off at
  the median (90% within 1.8°).
- **How honest the uncertainty is:** at each update, the true slope's distance from the app's estimate measured in
  the app's own uncertainty has a median of 1.11 and a 95th percentile of 2.21 (an exactly honest uncertainty gives
  1.18 and 2.45; with the room scan 1.17 and 2.18). On the fast 5° arc it is still a little too sure of itself in the
  tail (2.9 at the 95th percentile), but the numbers it showed there were at most 0.57° off.
- **The 30 mm ball** (measured on the previous n11 build against 35 mm): more of the drops found (one drop shot 11% to
  22% of its searches, another 32% to 60%), fewer false balls (3% to 1%), but a ball held at mid height found less
  often (21% to 10%). Now: the ball found on 45% of searches, 2% false.
- **LiDAR**: 75 of its 98 checks of the top agreed and were used (77%; 13 were turned away for their angle, 10 for
  their distance). LiDAR's distance to the top is 0.9% longer than the picture's (it reads long by about that much
  against the floor too), so with your measured size the picture's distance is right to within about a percent.
  LiDAR never changes the tilt; it moves the slab's centre, typically by 0.2-1 cm (up to 3 cm on the room scan), which
  moves a held ball's height by as much. Whether that is better cannot be checked yet: please enter the drop heights in
  the next kit.
- **The learned side shape**: about 19 mm down and 8 mm out (median over the shots), against 19.5-22 mm and 7-8 mm
  measured by hand from the kit. Started from a straight-down face instead, it learns the 8 mm run but only about 14 mm
  of the drop, so the measured starting point matters.

### What changed in n11 (since n10)

- **The side's shape and the edge choice** (the outline, above), with the learned drop and run per slab.
- **LiDAR** keeps only the distance; it never moves the tilt.
- **The honest tilt and "settling"**: the app works out how well it knows the tilt from each side's own uncertainty
  (how sharp the edge is, how far the side's shape could be off, motion blur, and half the band when one view cannot
  tell which edge of it it sees), counts the same view seen again as one view, leaves out readings that do not fit the
  square, widens a view when its own readings disagree and the result when views disagree, and does not let the part
  of the error that every view shares (the edge's sharpness, the side's shape) shrink as views add up. It shows the
  tilt at 1.0° or better on two checks in a row after the lock (the lock's own first readings do not count, nor do
  readings it left out), and goes back to settling above 1.25°. The outline keeps a view's older readings only while
  they agree with its newest.
- **Your slab and ball** (above), in one place in the code.
- **Developer**: the tilt line, LiDAR's check counts in Copy diagnostics, the demo can start steep and lower the
  camera, and the kit scorer can be told where the slab really was (`--positions`).

### Verified by tests, and only compiled

- **Verified:** 484 tests of the slab, edges, tilt, settling, ball, bounce, tracking, recording, capture kit and
  hand-off code on Linux, optimised (483 in the unoptimised build GitHub's Linux check runs; in both, three
  wait for files or settings from you), all passing;
  your kit replayed through the n11 code (in private, nothing from it in the repository); the synthetic kit; the harsh
  test scenes.
- **Only compiled, never run on a phone:** the settling display (the dimmed readouts, the faint dashed path, the status
  line), the demo's steep start, the new UI test, and how long the new edge reading takes on an iPhone (it reads each
  side's profile in five runs and works out the side's shape for each; not yet timed on a phone or on GitHub's Mac).
  The camera, ARKit, LiDAR and motion code is as in n10.

### Open questions and known gaps

- **Your slab's size and edge.** "160mmish": what was measured? A ruler reading of the top's flat width, the bottom's
  width and the thickness, and the top edge's rounding (a coin against it, or a radius gauge), would tighten the
  settling: with the rounding measured, steeper views settle (at 4 ft up to about 65° instead of 60°).
- **The next kit:** a slow arc (about a quarter turn in 10 s), so the arcs show how soon a moving view settles.
- **Nearly straight above** the app still does not read the side faces (all four show there): it says settling or
  does not lock. Whether a degree is reachable there is not known yet.
- **The settling numbers are from one kit.** The constants (how sharp an edge is, how much blur costs, when two views
  count as one) were measured on your one slab, phone and floor; the next kit checks them. On your kit the honest
  uncertainty is about right (see "Your kit, replayed"); on the fast 5° arc it is still a little too sure in the tail.
- **Test scenes (the harsh scenes, which still draw the old straight-sided 7 in slab and a 35 mm ball).** At 2 ft
  the tilt went from 1.5-1.6° off to 0.13-0.24°, and at 3 ft from 6° to 1.5° (the app no longer takes that slab's cut
  face for its top either). But on that slab the app now expects your sloped sides: at 3 ft the held ball's height is
  24-35 mm off (it was 0-11), at 6 ft the tilt 1.8-1.9° (it was 0.03°), and in mixed lamp and window light at 3 ft
  2.2° (it was 0.7°). 13 of the 76 scenes passed (before the last review fixes, which were checked on the plain scenes
  only), against 19 for n9; the 6 that no longer pass are all at 6 ft. Drawn
  with your slab and ball, the plain scenes read 0.04-0.19° at 2-3 ft (the number shown from 0.9 s at 3 ft, 0.19°
  off), but 1.2° at 4 ft and 1.9° at 6 ft (the problem above); there the app now stays on settling throughout.
- **The held ball's height on the synthetic kit** (your slab and ball drawn) is 11 mm off (three shots: +16, +11 and
  -9 mm) where n10 was 2 mm off on its own drawn slab. That kit's pictures are small (480 x 360, the only image its
  edges are read in): there the near sides' edge is read a quarter of a pixel inside the top, which moves the lock's
  plane by a few millimetres. In the app the edges are read in the camera's full picture, where the same reading is
  0.02 px off (a new test checks this), so the phone should not have this error; your next kit's held-ball heights
  will tell.
- **The bounce itself.** The app launches the ball along the slab's normal. A real ball dropped on a tilted surface
  also keeps some of its downhill speed, which on an 8° slab sends it off at nearly twice that angle. Your recorded
  drops will show which is right; I will change the app only if they agree.
- **The dish's shape.** The app treats the 1/8 in dish as a bowl through the four corners. If it is a round dish
  inside the square, it leans about twice as much near the middle. Which is it?
- **A speckled floor** (terrazzo, granite, gravel) right behind the space over the slab can be taken for a ball.
- **Privacy:** the three slab photos can still be reached on GitHub through an old commit, although no branch has them
  (I'll give you its id in our conversation, not here). Make the repository private, or ask GitHub Support to remove
  the cached commit.

The native version of Slab Bounce. It finds the cement slab on its black base, works out its tilt and draws the path a
ball would take bouncing off it. It uses ARKit, so the lens is known exactly and the slab, once found, stays pinned in
place as you move the phone. On iPhones with LiDAR (Pro models) it also checks the slab's distance with depth (not its
tilt: on this small raised top LiDAR's plane is several degrees off).

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

Open the app and point the phone at the slab, from about 2-4 ft away, best about 3 ft (in build n11 the tilt is not
yet right from farther: see the morning brief). That is all: there is nothing to set up.

- When the outline turns yellow and the label says **Slab locked**, the slab is pinned. Focus, exposure and white balance
  are then held too, once the camera has stopped adjusting them (within about 2.5 s).
- The yellow outline is the slab's flat top (the app knows its sides slope outward and its top edge is rounded, so the
  outline stays on the top's edge, not on the side face below it). The dashed white line is the launch direction,
  perpendicular to the plane through the four top corners. The cyan arc is the bounce, with the apex and where it
  lands. The readouts at the bottom give the slab's tilt, the apex height, how far away the ball lands and its time in
  the air.
- **settling**: right after the lock (at least half a second: two checks of the lock must agree first), and for as
  long as the app cannot yet pin the tilt to within about a degree, Tilt and Lands read "settling" (dimmed), the label
  says **Slab locked · settling**, and the path is drawn faint and dashed with no landing ring. Apex and Air keep their
  values (a degree moves them by millimetres). The tilt appears once it is good to about 1° (1° moves the landing about
  4.5 cm). From about 3 ft (2.5-4 ft), with the phone tilted 45-55° down (up to 60° at 3 ft; the slab seen clearly
  from the side, not from above), that is about a second after you point the phone. From straight above or steeper
  than about 65°, one view cannot pin the tilt that well, so the app keeps saying "settling" rather than show a number
  that may be degrees off: lower the phone a little.
- Hold the ball above the slab: its height sets the drop height, shown as "(ball)", and the label says **Slab locked ·
  ball in view**. Without a ball, the drop height from Settings is used.
- If you slide the slab to change its angle, the app notices after about a second and locks onto the new position.
- The slab (a 180.2 mm, about 7.1 in, square flat top as measured on your first kit, 1 in thick, with a 1/8 in dish and
  sloped, rounded sides) and the 30 mm titanium ball are built into the app.
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
  the main screen never shows. While locked, a "tilt sigma 1.7° · 1 view group · settling" row gives the tilt's honest
  uncertainty (both directions together), how many distinct views of the slab it rests on (views more than 7.5° apart
  add up; the same view seen again does not), and whether the tilt is shown ("settled", at 1.0° or less on two
  checks in a row after the lock; back to "settling" above 1.25°). **Copy diagnostics** has the same (`tiltSigmaDegrees`,
  `angleSettled`, `viewGroups`, `settledTiltDegrees`) and, on a LiDAR phone, `depthChecks`: how many LiDAR checks of
  the slab's top were used and why the others were not, with LiDAR's range over the picture's. Its "frames:" row sums up the last 10 seconds and is refreshed every second, e.g.
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
  formats. With `-demo YES -kitFast YES` the kit runs on the demo scene at a quarter of its timings (the whole-kit UI
  test; the Copy log test keeps the real timings, so its Quit has the whole 20 s room scan to land in, and its summary
  line says how far into the scan the tap came).
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
