# Slab Bounce for iPhone

[![iOS build](https://github.com/matthewrein/bounce/actions/workflows/ios.yml/badge.svg?branch=native-ios)](https://github.com/matthewrein/bounce/actions/workflows/ios.yml?query=branch%3Anative-ios)

## Build n21-exp (21 November 2026): the tilt's direction from all the views (an experiment, not a candidate)

**Not a candidate: do not install it instead of n20.** This branch tried what n19 left out: n19's multi-view lock
fits the lock's views together for the centre and the turn but keeps the slab's normal fixed. Here the same views are
fitted again with the normal free too (`MultiViewLock.fitNormal`: corners seen from views at least 15 degrees apart
pin the plane by parallax; each view weighs as one detection; its standard deviation is the larger of the fit's own and
a jackknife over the views) and the result is offered to the shown tilt under n18's hold rule: it replaces the number
and the bounce's normal only when its deviation is smaller than the one shown (`TrackerSettings.multiViewNormal`, on
in this branch's app settings, off by default so recordings replay unchanged). Fewer than three views, a misfit over
1.5 px, a centre move over 2.5 cm or a change of over 4 degrees from the lock's normal: not offered, n20's normal stays.
The outline, the lock, the gates and LiDAR are untouched. Developer shows **n21-exp**.

**Replayed on both kits it failed the bar** (direction error clearly lower on every clip with several views, the
amount no worse). The direction of the shown normal against your phone-on-slab truth (across the tilt, in degrees of
the normal, which is what moves a bounce sideways; total angle on the level clips), median / 90th percentile over the
frames showing a number:

| kit | clip | n20 direction | n21-exp direction | n20 amount | n21-exp amount | |
|---|---|---|---|---|---|---|
| 1 | level, still | 0.30 / 0.39 | 0.30 / 0.39 | 0.03 / 0.07 | 0.03 / 0.07 | unchanged |
| 1 | level, arc | 0.15 / 0.46 | 0.15 / 2.24 | 0.08 / 0.45 | 0.08 / 2.04 | worse |
| 1 | tilt 1 (4.7 deg), arc | 0.31 / 0.90 | 0.31 / 0.53 | 0.68 / 0.68 | 0.68 / 0.68 | median same |
| 1 | tilt 2 (10.7 deg), arc | 1.39 / 1.39 | 0.49 / 1.39 | 1.74 / 1.74 | 1.74 / 2.16 | direction better, amount worse |
| 1 | tilt 3 (17.2 deg), arc | 0.50 / 0.71 | 0.50 / 0.54 | 0.91 / 0.91 | 0.20 / 0.39 | median same |
| 2 | level, still | 0.72 / 0.72 | 0.72 / 0.72 | 0.44 / 0.44 | 0.44 / 0.44 | unchanged |
| 2 | level, arc | 1.15 / 1.77 | 2.49 / 2.52 | 0.55 / 1.18 | 1.90 / 1.93 | worse |
| 2 | tilt 1 (3.6 deg), arc | 0.38 / 0.38 | 0.38 / 0.38 | 0.61 / 0.68 | 0.61 / 0.68 | never taken |
| 2 | tilt 2 (7.8 deg), arc | 0.43 / 0.43 | 0.14 / 0.43 | 0.58 / 0.58 | 0.39 / 0.58 | better |
| 2 | tilt 3 (12.1 deg), arc | 0.52 / 0.68 | 0.72 / 0.75 | 0.94 / 1.03 | 1.49 / 1.54 | worse |

The tilted still clips show no number in either build (one view); the stills that do are unchanged. Nothing else moved:
on every frame of every video shot of both kits the state, the lock's corners and every detection are identical, no
lock was lost, and as many frames show a number; only the shown tilt and the bounce's normal change (the first number
within 2 degrees of the truth came 0.9 s later on kit 1's level arc, 11.4 to 12.3 s; the same on the other clips).

**What it says about the left-right error.** n20's direction error is real but not larger than its amount error: across
the tilt 0.3-1.4 degrees median on the six tilted arcs (0.04-0.75 at the arcs' last frames), the downhill heading 1.6-7.4
degrees off, against 0.6-1.7 degrees in the amount (1 degree moves the landing about 4.5 cm). The views fitted with the
normal free do not fix it because the error is the same in every view, not noise that more views average away: on kit
2's level arc the fit from four views was 2.5 degrees off while stating 0.75 (the lock's own average 2.0, the shown n20
estimate 1.15), and with the size free too (tried, `fitNormal(freeSize:)`) it was no better. That points at the
outline itself (which edge of a side it sits on, seen the same way from one side of the slab), which is where the next
work on the direction belongs. The truth's heading is usable: the CoreMotion-to-ARKit link's heading varied by 0.01-0.07
degrees over each shot.

**Checked:** BounceCore unit tests (`MultiViewNormalTests`: the views bring a normal tipped 2 degrees back to under 0.01;
with a pixel of noise and an outline on the wrong edge the error stays under its stated deviation times three; the hold
rule; through the tracker on a synthetic walk round the shown normal ends nearer the truth with the outline unchanged)
and the full BounceCore suite. The app change is only the build label.

## Build n20 (20 November 2026): the cue no longer says "Point at the slab" while the slab is in view

Bug fix on top of n19; Developer shows **n20**. Before the lock, the slab search often drops its candidate for a moment
and starts again; n19's cue then said "Point at the slab" although the slab was in the picture (5.9 s of that on your
first kit, 15.4 s on your second, flickering about once a second). The cue now remembers where it last saw the slab for
2.5 s while not locked, so it keeps giving the right advice ("Lower the phone", "Hold the phone steady"). Replayed on both
kits: every wrong "Point at the slab" is gone, the shot without a slab still says it, and nothing but the cue changed on
any frame. Pointing away before a lock now shows "Point at the slab" after 3.6 s instead of 2 s.

## Build n19 (20 November 2026): the slab held in the room from all its views

Small build on top of n18; Developer shows **n19**.

**The locked square now combines its views.** Until now each detection fitted the square from one view at the known
size, so a pixel's error at a corner became 1-3 cm of distance along that view's line of sight: the outline looked
right from where it locked and off from anywhere else (what you saw on n16). The lock now keeps its own detections,
each view of the slab (7.5 degrees apart) its newest three, up to 12 views, and once two views at least 15 degrees
apart exist it fits them together: the square's centre and its turn, at the size setting, that put its corners nearest
every detection's outline in its own picture (`MultiViewLock`, `TrackerSettings.multiViewLock`, on in the app). The
tilt is not touched: the fit holds the lock's normal, so the tilt number, its settling and its uncertainty come from
the same detections as before. With one view, or if the fit misfits (over 1.5 px per corner) or would move the centre
more than 2.5 cm, the outline is the old single-view average. LiDAR no longer moves the centre either (it moved it half
way to its own range along the current line of sight, which also made the outline slide as you walked); LiDAR's checks
still run. Copy diagnostics shows what the fit did under `multiView`: views, whether it is used, its misfit, the size the
views imply against the setting, and how far the shown corners drift.

**Replayed on your two kits** (arcs and walk-round, n16 against this; error = the shown corners against all the views'
consensus): the median corner error fell in all 10 shots, kit 1 from 5-11 mm to 2-4 mm (the walk-round 10.8 to
1.8), kit 2's arcs from 12-25 mm to 2-12 mm; the largest error fell or stayed in all 10 (kit 1's walk-round 35.6 to
10.5 mm). How far the outline wanders over a shot fell in 7 of 10 (20.1 to 6.6 mm on kit 1's level arc, 18.1 to 6.5 on
kit 2's steepest) and rose a little in two of kit 1's tilted arcs (8.7 to 9.4, 6.6 to 7.8 mm, while it still had
one view). The tilt was no worse: the settled tilt against your phone-on-slab truth moved from -0.53 to -0.23 deg,
-0.28 to +0.08, -1.06 to -0.73 and +0.98 to +0.97 on the tilted arcs and from -0.04 to +0.08 on kit 1's level arc,
and it settled as often or more. Kit 2's walk-round (its edge finder took a side's outer edge in many views) improved
least: 25.7 to 17.6 mm, wander 19.5 to 17.8.

**The slab's size stays 180 mm** (the app's 180.2: your tape's 180 mm sides; the 250 mm diagonal fits corners rounded
by about 5-6 mm in plan). Both kits re-measured from the pictures give 179.8 ± 2.5 mm, and the views fitted together
imply 177.3-182.0 mm across the 10 shots (median about 180). If it ever needs changing: Settings > Developer > **Slab top (mm)** (1 mm steps, 120-250 mm, applied
when Settings closes; a change starts the lock again; the sloped sides' outer edge follows), or for tests the launch
argument `-slabTopMm 175`; the default is one constant, `SlabSpec.ownerFlatTopMm`. Recordings replay with the size
they were recorded with. Nothing on the main screen changed.

**Checked:** BounceCore unit tests (`MultiViewLockTests`: the fit puts a lock 15 mm off back on the slab from four
views, leaves out an outline on the wrong edge, keeps the tilt exactly, and on a synthetic walk round halves the corner
error, median 3.5 to 1.3 mm) and the replays above; the full BounceCore suite was re-run. The Developer row and the
size setting only compile in CI and are first seen on your phone.

## Build n18 (20 November 2026): the tilt number sooner

Small build on top of n17 (the cue, the 44 pt ball tap): the slab search, the lock and the ball finder are unchanged.
Developer shows **n18**.

**The number shows sooner, with its uncertainty.** The tilt now shows once its honest standard deviation is at most
**2.0 degrees** on two re-checks in a row (n11-n17: 1.0). While that deviation is over 1 degree it follows the number,
compact: **"3.2° ±1.4"**; at 1 degree or less the number reads alone ("3.2°"). Lands shows with it, as before.

**A shown number holds.** Once shown, the number stays while the lock holds: a later estimate replaces it only when a
re-check brings a smaller deviation, and it goes only when the lock is lost or the slab moved (a re-lock or slide). A hand
near the slab, which widens the estimate for a while, no longer takes it back to "settling". Apex, Lands and the drop point
use the same held value.

**After changing the slab's tilt, point the phone away for a moment (or step closer) so the app locks again.** A small
change (a few degrees) can keep the lock, and then the held number stays until the app notices the slide: measured on the
demo at 4 ft and 62 deg down, 8 to 5 deg kept showing "7.8° ±1.4" for 5.4 s (at the usual 48 deg and 0.85 m it re-locks
within about a second). No simple check on the estimate separates that from a hand near the slab yet, so the number is
not dropped on its own.

**Replayed on your two kits** (all video shots, the app's whole per-frame path; n16 is n17's slab and settle rule):

| | n16 / n17 | n18 |
|---|---|---|
| still shots (24 locked): a number within 2 s of the lock | 3 | 10 |
| still shots: a number within 2 s of the shot's start | 2 | 9 |
| still shots: a number at all | 5 | 12 |
| arcs (11 locked): a number within 2 s of the lock | 1 | 8 |
| arcs: a number at all | 7 | 11 |
| back to "settling" while still locked (drops included) | 2 | 0 |

- Still shots with a measured tilt that show a number (the level shots, kit 1 0.19 deg and kit 2 0.30 deg; kit 2's
  s06 and later were moved near level, so their tilt is not counted): first shown 0.6 s after the lock at ±1.35 and ±1.06,
  off by 0.03 and 0.41 deg, and every shown value stayed inside its ± (worst 0.07 and 0.44 deg).
- The other still shots with a measured tilt (kit 1 10.6 deg at 1.27 m, kit 1 17.2 deg at 0.93 m, kit 2 12.1 deg at
  1.31 m) never got under 2 deg on two re-checks (median deviation 3.7-8 deg), so they show no number; n17's cue
  then says what to do after 1.5 s.
- Arcs with a measured tilt (8): first number 0.6-3.9 s after the lock (k1 level arc 7.2 s), first error 0.4-1.7 deg.
  On 4 of 8 every shown value stayed inside its ±. Outside: kit 1's 10.6 deg arc showed 12.4 ±1.5 (1.7 deg off) for
  3.9 s until a better re-check replaced it with 10.1-10.4 ±0.7-0.9; kit 2's 3.6 deg arc read about 1.05 deg off at
  about ±1.0 (n16 showed the same value there, also outside), kit 2's 12.1 deg arc and level arc up to 1.05 and
  1.31 deg off, inside their ± (or within 1 deg while the number reads alone) on 83% and 89% of their shown frames.
- Drops: kit 1 drop 3 shows a number 86% of the time (n16 25%), kit 2 drop-edge 77% (n16 27%), kit 2 drops 2 and 3 38%
  and 86% (n16 none); kit 1 drops 1, 2 and drop-edge and kit 2 drop 1 still show none (median deviation 2.6-3.9 deg).
- The 2.0 threshold: 1.5 and 2.5 were replayed on the shots with a measured tilt. On the two still shots that show a
  number all three stay inside their ±, so the data gives no reason to go past 2.0; at 2.5 two arcs first showed at
  ±2.2-2.4, with errors up to 1.55 deg (inside their ±).

**What is checked, and how:** BounceCore's tests (HonestTilt: the held value, its replacement and the old behaviour with
the setting off; the "±" text; DemoSettle: the demo's app path at 48 deg, steep then lowered, and 4 ft at 62 deg, where
n18 now shows the number with its ±; the recording format: older recordings keep 1 deg and no hold, so they replay as
the phone ran them) and the replay above. The app only compiles in CI: the "±" on the Tilt tile, and the updated UI test
`testSettlingThenTheTilt` (while steep the tilt may now read "settling" or the number with its ±; lowered, the number
alone), are first seen there and on your phone.

## Build n17 (20 November 2026): demo build

Small build on top of n16 for the live demo: the slab search, the tilt's settling rule, the ball finder and its gate
(n15) are unchanged. Developer shows **n17**.

**A short cue under the status chip.** The main screen now shows one short orange line, only when you can do something
about what the app is waiting for, and nothing otherwise (the developer hints stay in Settings > Developer):
- not locked for more than 2 s: **"Point at the slab"** when it has seen no slab for 2.5 s (fix-dryrun: before, the
  search starting over between candidates flipped it to "Point at the slab" with the slab in full view), **"Hold the
  phone steady"** when the slab it is checking is within 1.25 m (about 4 ft) of the phone, and the far cue below when it
  is farther;
- locked but the tilt still "settling" for more than 1.5 s, the most useful reason: more than 1.25 m away, the far cue
  (the honest tilt uncertainty grows with distance and stays above the 1 degree threshold beyond about 4 ft, so the
  number would never show): **"Lower the phone"** when the phone is more than about 1.0 m above the slab (standing with
  the phone at chest height it is about 1.3 m above a slab on the floor, so stepping closer never helps: crouch),
  otherwise **"Step closer"**; line of sight more than 60 degrees from straight down onto the slab (phone held low)
  **"Hold the phone higher"**; less than 25 degrees (looking almost straight down, where n11 measured slow or no
  settling) **"Lower the phone"**; otherwise **"Move the phone slowly"** (a second view of the slab, a few degrees
  away, lets the tilt settle);
- for 2 s after a ball tap that set nothing: **"Hold the ball over the slab"** (the tap found no ball over the slab at a
  drop height: it missed the ball, or the ball was off the slab, too low or too high).
So "settling" never sits there alone for more than 1.5 s.

**A larger tap target for the ball.** A ball the finder sees within a 44 pt fingertip of your tap (on the iPhone 17
Pro's screen; at least four of the ball's radii) is taken as the ball you tapped, and the tap's search area is padded
by at least as much (n16: about 33 pt plus half again the ball's radius). n15's place checks still apply to it. If the
finder sees no ball there, the ball is set at the tap as in n16. Slab taps are unchanged.

**Where to hold the phone for the tilt number (n17):** crouch or kneel, the phone about 1.5 ft above the floor and
about 2 ft back from the slab, looking down at it about 35-40 degrees from straight down (your n14 test that settled:
0.73 m from the slab, 50 degrees from its normal, the phone about 0.46 m up). Standing with the phone at chest height,
at any distance, the phone is more than 1.25 m from the slab and the tilt number will not show in n17 (the cue says
"Lower the phone"). This is worked out from the geometry and the n14 numbers, not replayed on your kits.

**Not in this build:** showing an approximate tilt ("≈X.X°") while settling was considered and left out: it could not
be checked on your recordings in time.

**What is checked, and how:** the cue's rules and the tap reach have unit tests here (BounceCore `DemoCueTests`; taps
10, 25 and 40 pt off a ball are accepted, 90 pt off sets the ball at the tap) on synthetic scenes; the existing tap,
gate, tilt and replay suites were re-run. Nothing in n17 was checked on your real recordings, and the app itself only
compiles in CI: the cue's wording and position, and the larger target, are first seen on your phone.

## Build n16 (20 November 2026): tap the ball

Small build on top of n15: the lattice ball finder and the gate (the n15 section below) are unchanged, and so is
everything else. Developer shows **n16**. The main screen has no new words and nothing needs a tap: if you never tap,
the app runs exactly as n15. Tapping is there for when the app does not find your ball, so you can still test bounces.

**What a tap does** (what is under your finger decides):
- **Tap the ball** while you hold it over the locked slab and it has no ring. If the ball finder sees a ball right under
  your finger within about a third of a second, that ball is taken at once: its ring shows straight away (it does not
  wait for n15's three agreeing finds) and the drop height reads "(ball)". n15's other checks still apply to it: where
  LiDAR sees a surface behind it, or it is not over the slab's top at a drop height, it is not taken (and a ring a tap
  took goes as soon as they rule it out). Otherwise the ring stays while the finder keeps finding it there, and gives
  the drop height until it goes or you tap it away. If the finder sees no ball there, the ball is **set where you
  tapped**: a dashed yellow ring with a dot in the middle, the label **Slab locked · ball set**, and the drop height
  "(set)". Its height comes from LiDAR under your finger, or from where your line of sight crosses the upright plane
  through the slab's middle (the nearer of the two that puts it over the slab): right for a ball held over the middle
  of the slab, as on all your clips; a ball held over the slab's near or far edge can be set several cm too high or too
  low (not measured). It stays put, also after you drop the ball, and the finder's own rings are not shown meanwhile,
  until you tap it again, tap the ball somewhere else, the finder shows a ball close to it on two searches in a row, or
  the lock goes.
- **Tap the yellow ring again** to clear it: the drop height is your setting again.
- **Tap a wrong ring** to dismiss it: it goes at once and that spot is passed over for 20 seconds (tap the same spot
  again to take it back). A ring that is on your ball is right: leave it, because a tap on a ring removes it.
- **Before the lock**, a tap on the slab makes the search look there first for about a second.
- **A tap on the floor** costs nothing: it never costs the lock or changes anything else.
- **A tap on the locked slab's own top** is taken as a tap on a ball (a ball held low over the slab could be there). It
  never sets a ball where LiDAR under your finger reads the top (all 30 such taps on the top's far half below were on
  frames with LiDAR) or where your line of sight puts no ball over the slab; where LiDAR cannot read under your finger,
  a tap on the top's far half can set a ball a few cm up (tap its yellow ring to clear it). It does act on what is under
  your finger: a ring there goes, also the one on your ball; and a ball the finder finds right there is taken and gives
  the drop height until the finder loses it or you tap its ring away (if it is not your ball, tap it).

**On your real clips** (both kits replayed here in private, the taps simulated as the app takes them, with the app's own
lock; the ball's true place from the circles marked by hand and tracked by script, as for n15):
- **No tap: identical to n15**, search for search and frame for frame: 1,676 searches on your phone's lock and 12,120
  frames with the app's own lock. So n15's numbers below stand: the ball found while held over the slab 85% and 60% of
  the time on your phone's lock, 76% and 46% with the app's own; wrong balls about once a minute (0.3-0.4 s a minute) on
  the first kit, none on the second.
- **Tapping your ball when it had no ring** (held 4 in, 1 ft and 2 ft, and the drops before the release): 42 taps, on
  21 moments in 13 shots, each tapped on the ball's middle and a fingertip off its edge; 16 of the 42 on frames with
  LiDAR, the other 26 at the first moment the ball had no ring (frames without LiDAR: your kits store it once a
  second). **33 taken at once, every one your ball**, the drop height from it within 3.5 cm of the truth (typically
  1.3 cm); **9 set where tapped**, all on the second kit and all from the plane (on these clips LiDAR never put the ball
  nearer), off by 0.1 to 7.5 cm (typically 1.5 cm; the 7.5 cm was a fingertip off a ball held 4 in, on a frame without
  LiDAR). On the first kit every tap was taken at once. No tap set nothing. (The true height comes from the size of the
  circle marked on your ball, which is itself good to about 1-2 cm on the held shots: the typical 1.3 cm is about as
  close as can be checked.)
- **Afterwards**: 3 of the 9 set balls were later replaced by your ball, found close to them; **none by a wrong ball**
  (the second kit shows no wrong ball at all in n15). The tap-to-set build without n15's gate let a wrong find replace
  a set ball 3 times on the second kit's first drop; in n16 your ball shows there without a tap, and the taps simulated
  there were taken at once.
- **After a drop** (the numbers above stop at the drop's cue, about 0.9 s before your hand let go; this was checked
  frame by frame to the end of each clip): a ring a tap took follows your ball until it is let go, then stays where it
  was let go for up to about a quarter of a second, as without a tap. A set ball stays where you set it after the drop
  (on the second kit's third drop and edge drop, to the end of the clip, 3 s): tap it to clear it. On one shot (the
  first kit's first drop, the taps on frames with LiDAR) the tap moved the app's search times, and n15's known wrong
  ball after a drop, your ball lying on the floor beside the slab read as a ball 7 cm over it, showed for the clip's
  last 0.2 s; without the tap it was found but never shown.
- **Taps on the locked slab's own top**: 73 on its middle and 30 on its far half: **none set a ball**, and the lock and
  its tilt never moved. Where your ball was under the finger, the tap acted on it: on the second kit's held 4 in, which
  the app never shows by itself, both taps brought up your ball (33 and 119 frames); on the first kit's held 4 in, a
  far-half tap landed on your ball's ring and removed it (your ball shown on 14 frames instead of 44); and after the
  second kit's edge drop, a tap on the middle took your ball rolling across the top, for 0.1 s (its drop height reading
  6 cm). With the ball lying in the dish, the first version of this build showed a ring on it for about 2 s after a tap
  on the top (the drop height then read 2-3 in "(ball)"): a tap now looks for half-seen balls that low only while it
  waits (that third of a second) and while it follows the ball it took, and no ring shows there now.
- **Taps on the floor**: 145 (while searching, while confirming and once locked, on 38 shots): every shot exactly as
  without the tap (the same lock, tilt, searches and balls).
- **Wrong rings**: the one wrong ring the simulation could tap (the first kit, a toy at the picture's edge in a shot
  without the ball, shown for 12 frames): one tap when it first showed left it 1 frame, and it did not come back.
- **Tapping the slab before the lock** was measured on n14's tracking, which is unchanged since: it helped on 5 shots
  where the app was slow or never locked, and changed nothing on most. Not re-run on this build.

**Copy diagnostics** now has the ball's last 20 events (`ballHistory`): each time the gate let a ball through, kept
it, held one back (waiting) or refused one (and why: not over the slab's top, too low, too high, LiDAR saw a surface
behind it, or not where the ball let through was), and whether a ring was on screen after it (`shown`: none while a
set ball stands; a ring a tap took shows before the gate lets it through); each time the ring went; and each tap that
took, set, cleared, replaced or dismissed a ball, with where the ball was (in the room and in the picture) and how high
over the slab. If a wrong ball shows, copy the diagnostics right after and paste them: they say where it came from.

**Only on the demo** (the Developer demo scene, which has no LiDAR): a ball the finder cannot see (not drawn) set by a
tap, its drop height 0.1 in from the scene's, then cleared by a tap on it; a ring dismissed, kept away while the camera
drifts, and taken back by a tap there (taken at once, 0.3 s later). **Only compiled**: the app's side of tap to set
(the yellow mark, "ball set", "(set)", the invisible markers the tests read); GitHub's checks build it and run the
Simulator tests on the demo before this reaches you. Nothing of n16 has run on a phone, and the ball history is checked
here on test scenes only. (CI: the Pre-flight Simulator test is off the known-flaky list again: it passed on two runs in
a row.)

**Try**: point at the slab until **Slab locked**. Hold the ball still about 1 ft over the middle of the slab. If it
gets a ring by itself, that is n15 working: nothing to tap. If not, tap the ball: the drop height should read "(ball)"
or "(set)" within half a second, close to the true height. Drop the ball from there and see where it lands against the
path. Tap the yellow ring: the "(set)" goes. Try a tap a little off the ball's edge, and one on the slab's top with no
ball (nothing should happen). If a ring sits on something that is not your ball, tap it. Then Settings > Developer >
Copy diagnostics and paste it: `ballHistory` shows what the app made of the ball and of your taps.

## Build n15 (20 November 2026): the lattice ball finder, and far fewer wrong balls

Small build on top of n14; only the ball changes. The slab, the tilt, the bounce and the screens are as in n14 (the
Developer demo now draws your lattice ball). Developer shows **n15**. Nothing to set: point the phone and hold the ball
over the slab. (Your new recording and diagnostics from the n14 test had not reached me when this was built: these
numbers are from your two kits.)

**On your real clips, n14 against n15.** Every video shot of your two kits (slab alone, no ball, ball on the floor,
held, drops), replayed here in private two ways: on the slab lock your phone had while recording, with the app's ball
search on its own schedule (every 0.1 s, every 0.3 s after half a second of finding nothing); and the whole app as it
runs, with its own lock. Against the ball's place marked by hand and by a tracking script, spot-checked by eye.
"Found": searches after which the app showed a ball on the true ball, of those while you held it over the slab (held
shots, and drops before the release); "on screen": the share of that time a right ball was showing. "First": from the
start of a ball shot to the first right ball (median). "Wrong": each time a ball was shown that is not the true ball,
over all the footage (2.9 and 3.1 minutes), and the seconds it stayed per minute.

| | your phone's lock: n14 | n15 | the app's own lock: n14 | n15 |
|---|---|---|---|---|
| **First kit** (wooden floor): found | 79% (130 of 165) | 85% (157 of 185) | 64% (101 of 158) | 76% (138 of 182) |
| on screen | 51% | 62% | 33% | 45% |
| first | 0.1 s (5 of 7 shots) | 0.3 s (5 of 7) | 0.8 s (6 of 7) | 1.1 s (5 of 7); 0.4 s after the lock |
| wrong | 4.2 a min, 2.5 s | 1.1 a min, 0.3 s | 5.3 a min, 2.3 s | 1.1 a min, 0.4 s |
| **Second kit** (play mat): found | 3% (4 of 122) | 60% (134 of 222) | 0% (0 of 122) | 46% (82 of 180) |
| on screen | 1% | 39% | 0% | 24% |
| first | 0.2 s (1 of 7) | 0.3 s (5 of 7) | never | 1.0 s (4 of 7); 0.45 s after the lock |
| wrong | 1.0 a min, 0.9 s | none | 2.0 a min, 1.0 s | none |

So **n15 beats n14 on both kits**: it finds the ball more often (on the mat, where n14 almost never did) and shows a
wrong ball far less often. It is not perfect, and it takes about 0.2 s longer to show the ball. Without the gate below
(the lattice finder alone) it would find more (91% and 65% on your lock, 83% and 50% on its own) but show wrong balls
as often as n14 or more (4.2 and 3.6 a minute; 5.3 and 2.6).

- **Wrong balls n15 still shows**, all on the first kit (wood), each checked by eye: the ball lying on the floor after
  the edge drop (0.2-0.3 s); after a release the ring stays where the ball was for up to about a quarter of a second
  (once on your thumb, 0.1 s); and things that stay put at the picture's edge in shots with no ball: the stool's white
  label (0.5 s, on your lock), a red and yellow toy (0.4 s, drop height 0.90 m "from the ball") and the stool's handle
  cut-out (0.4 s, 0.78 m) with the app's own lock. None on the mat.
- **Weak spots**: over the mat, held 4 in: 34 of 48 on your lock but **0 of 27** with the app's own; held 1 ft: 6 of 36
  and 5 of 33, so it may rarely or never show there. The first kit's first drop, before the release: 14 of 29 on your
  lock, 0 of 24 with the app's own (n14 3: the finder found it only 3 times there, too few to agree). Resting in the
  dish: never shown (the app looks from 5 cm up). Falling: never shown right in any build; the app searches about 10
  times a second, one or two searches a fall, and does not follow the fall frame by frame (the kit's scorer does).

**The gate (new, plain words).** The finder's results pass it before the app shows a ball or takes the drop height
from it. Showing no ball is preferred to a wrong one:
- **found three times within half a second in one place** (within 6 mm across the line of sight, a few percent along
  it; the ball's 30 mm size and the phone's pose give its place in the room). This removes most wrong balls: your held
  ball moved at most 4.2 mm between searches; the mat's prints seen from a moving phone drift about 6 mm a search (up to
  7 mm), the fingertip 7 mm. A single find never shows. It does **not** stop something that stays put, and a print
  seen from a phone moving more slowly than in your kits could pass it.
- **LiDAR**, where it can see the ball (half a metre from the phone or nearer): a depth 15 cm or more behind the ball is
  the floor or a print, not shown. Your held ball read within 5 cm (25 frames only: the kits store depth once a second);
  the stool's label 1.3 m behind. Farther away (your 5 ft), nothing stops a look-alike that stays put.
- **over the slab's top, 5 cm to 1.8 m above it**: the finder already keeps to this, so it is only a re-check (it
  refused nothing on your clips). A look-alike of the wrong size reads as being in the air over the slab and passes it.
- once shown, the ball stays while new finds agree; after a third of a second unseen, or a find elsewhere, it goes.

**Verified on your real clips**: the numbers above (replays here, on Linux). **Only on test pictures**: the lattice
ball as the test scenes and the demo draw it (held over wood and a mat 8 of 8, the drop height within 1 cm; prints and a
toy ball, nothing); the gate's rules one by one. **Only compiled here**: nothing in the app's own code changed; the app
and its UI tests build only in GitHub's checks, which have not run (not pushed). The demo's ball appears a few tenths of
a second later. **Not run on a phone.** On the phone LiDAR is read on every search, not once a second.

**Cost**: the gate is a few sums per search. The finder's search, measured before (on a busy Linux computer, not a
phone): over the mat with no ball 1.6-3 times n14's (its slowest searches 64-81 ms), over wood 1.3-1.4 times, the ball
held over the mat about 1.1 times (slowest 165 ms). Not timed on your iPhone.

**Try**: hold the ball still about 2 ft, 1 ft and 4 in over the middle of the slab: within about half a second the
label should say **Slab locked · ball in view** and the drop height "(ball)"; over the mat at 1 ft and 4 in it may not
come at all (say so). Sweep the phone over the mat with no ball: "ball in view" should not show. On a wooden floor, a
toy or a stool at the edge of the picture may show for under half a second: say if it does, and how far the phone was.
Drop the ball: the ring should go within about a quarter of a second, and not come back on the ball on the floor. Try
once from 5 ft too. Then Settings > Developer > Copy diagnostics: its "ballGate.*" counts say how often each rule held a
find back ("ballGate.surface" is LiDAR's).

## Build n14 (19 November 2026): screens that hold still

Small build on top of n13; nothing about the slab, the ball or the bounce changes. Developer shows **n14**.

**What changed**
- Settings, Developer and Pre-flight no longer redraw with every camera frame. Until n13 the app's model announced
  every frame (the readouts, the outline, the demo picture, the developer line), so every open screen redrew about as
  often as the camera delivered frames. Now only the parts that show live numbers redraw: the main screen's picture,
  outline, status and readouts, and Developer's live line.
- Developer's live line keeps a fixed height (room for 16 lines at the normal text size, more at larger sizes), so the
  rows below it (Pre-flight, Copy log, Clear log) stay put when its numbers change and it rewraps. If a very long line
  needs more room than that, it ends in "..." on screen.
- Developer's Live section has a new row, **Screen redraws**: how many times that screen has redrawn since it opened.
  It should barely move while you watch.
- CI: an end-to-end test that is known to be flaky (listed in `ios/BounceAppUITests/known-flaky.txt`, with the reason)
  no longer holds a build when everything else passes; it shows as a warning. The first one listed is the Pre-flight
  test, which failed in n12, most likely because the Pre-flight row sat at the screen's bottom edge where a test tap was
  lost (the test now scrolls the row clear of the edges; whether that fixed it is not yet confirmed).

**Checked**: in the iOS Simulator only (no camera there; the demo scene at about 8 frames a second): a new end-to-end
test counts Settings' and Developer's redraws over 3 s (the test allows 2; redrawing with every demo frame would be about
24), checks that the
live line's height stays the same through a tracking reset, and that the Pre-flight row does not move for 3 s.
**Not checked on a phone**: on the phone the camera runs at 60 frames a second, so the saving is bigger there, but
nothing in this build has run on one yet.

**Try**: open Settings > Developer with the camera on the slab and watch **Screen redraws** (it should stay nearly
still) and the Pre-flight row (it should not jump). Settings' sliders should feel the same or smoother.

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
- If the app does not find the ball, you may tap it (never needed): it is taken at once if the app sees it under your
  finger, else set where you tapped ("(set)", a yellow ring; tap that again to clear it). A tap on a wrong ring removes
  it.
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
  `ballHistory` (n16) lists the ball's last 20 events: the gate's verdict on each find (let through, kept, waiting,
  or refused and why) and whether a ring was on screen after it, the ring going, and what each tap did with the ball,
  each with the time, the ball's place in the room and in the full picture, and its height over the slab's top.
- **Reset tracking**: forgets the slab and looks for it again.
- **Slab top (mm)** (under Experiments): the slab's flat top, side (default 180.2 mm, the owner's tape 180 mm). The
  outline and the ball's distance scale with it; a change starts the lock again when Settings closes.
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
