import XCTest
@testable import BounceCore

/// Lost-lock recovery (n20r): the owner's kits never lost a lock (a dry run of n19/n20 over 12,120 real frames), so the
/// tracker's recovery paths were untested on the app's own detectors. These scenes force them, rendered by the package's
/// own ray caster (`SyntheticScene`) and run through the app's demo path (frames 12.5 a second, the slab crop cut from
/// the same pixels, the app's tracker settings and detectors, the main screen's cue as the app drives it):
///
/// - cover: something held over the slab (0.5 to 6 s; the slab not moved): the lock is kept, or found again at the
///   same place soon after it shows again, and never moves anywhere else;
/// - move: the slab slid (5 to 30 cm), turned, re-tilted, or picked up and put down elsewhere while covered: a lock at
///   the new place within a few seconds of it lying still in view, and no lock or shown tilt left at the old place more
///   than about a second after the slab shows elsewhere (n20 kept the old lock until the lost rule's 4 s ran out, or for
///   good while the old place was out of the picture);
/// - sweep: the camera turned away (1 to 10 s) and back, with and without the slab moved meanwhile;
/// - world jump: ARKit's world frame snaps (relocalisation): the lock proves itself again at the new coordinates.
///
/// What a scene checks (`Run`): the time from the slab lying still and visible at its final place to a confirmed lock
/// there (centre within 2 cm, tilt within 1 deg) that holds; the last time a lock or a shown tilt was at the wrong place
/// while the slab was visible elsewhere; "Point at the slab" while the slab was in the picture; a set ball left after
/// the slab moved.
///
/// Linux CI runs the package's tests unoptimised, where these rendered scenes run 6-7 times slower than optimised (about
/// 33 minutes for the full set): a debug build runs two of them (`debugScenes`); the macOS job's optimised run
/// (`swift test -c release`) runs them all.
final class LostLockRecoveryTests: XCTestCase {
    #if DEBUG
    static let debugScenes: Set<String>? = ["slide 20 cm", "away 3 s, slab put 40 cm away"]
    #else
    static let debugScenes: Set<String>? = nil
    #endif

    /// the re-lock rule's own time: `moveCount` agreeing re-checks 0.3 s apart (0.32 s at 12.5 frames a second), one more
    /// for where the first lands, and a frame: what the re-lock rule's scenes are held to (n20 alike)
    static let relockRule: Double = {
        let s = TrackerSettings(), frame = 0.08
        return Double(s.moveCount + 1) * (s.recheckInterval / frame).rounded(.up) * frame + 0.1
    }()

    /// A scene over time: where the slab is, where the camera looks, whether something covers the slab, and how ARKit's
    /// reported world is shifted from the true one (a relocalisation).
    struct Scene {
        var name: String
        var seconds: Double = 12
        /// the slab's pose (true world) at time t
        var slab: (Double) -> SlabPose
        /// where the camera aims (true world) at time t; nil: at the slab
        var aim: ((Double) -> Vec3)? = nil
        /// the camera turned away from its aim to look here instead (true world; the phone turned in the hand, not moved)
        var lookAway: ((Double) -> (Vec3, Double))? = nil
        /// the slab is covered (a cloth or a hand held over it) at time t
        var covered: (Double) -> Bool = { _ in false }
        /// the reported world is the true one moved by this (ARKit relocalised) at time t
        var worldShift: (Double) -> Vec3 = { _ in .zero }
        /// tracking limited at time t
        var limited: (Double) -> Bool = { _ in false }
        /// from this time the slab lies still at its final place and is visible (the clock for the time to a lock)
        var settledFrom: Double = 0
        /// from this time the slab is visibly away from where it was locked (nil: never moved)
        var elsewhereFrom: Double? = nil
        /// tap the hidden held ball this long after the first confirmed lock (sets a ball), nil: no tap
        var setBallAfterLock: Double? = nil
        var distance = 0.85
        var elevation = 48.0
        /// What n20r is held to (s; nil: a known gap, printed but not asserted): the time from the slab lying still and
        /// visible at its final place to a lock there that holds, and how long a lock or a shown tilt stays wrong while
        /// the slab is visibly elsewhere.
        var maxLock: Double? = 3
        var maxWrong: Double? = 1
        /// frames with a lock or a shown tilt at the wrong place (nil: not held)
        var maxWrongFrames: Int? = nil
        /// held to the owner's words only (centre within 2 cm, tilt amount within 1 deg; not the normal's direction or the
        /// corners): for a slab left near the picture's edge, where the re-checks pull the tilt a little (n20 alike)
        var tiltAmountOnly = false
    }

    struct Run {
        var name = ""
        var crashed = false
        var lockedAt: Double?
        /// first time from `settledFrom` with a confirmed lock at the truth (centre within 2 cm, normal within 1 deg, corners
        /// within 3 cm) that held for 1.5 s (or to the end of the scene)
        var correctFrom: Double?
        /// the last time a lock (or a shown tilt) was at the wrong place while the slab was visible elsewhere
        var lastWrong: Double?
        var wrongFrames = 0
        var pointAtSlabInView = 0
        var losses = 0, relocks = 0, locks = 0
        /// times of "locked" / "relocked" events, and of "lost" / "moved-away"
        var lockTimes: [Double] = [], lossTimes: [Double] = []
        /// at the scene's end: the confirmed lock's centre and tilt-amount error (nil: no confirmed lock)
        var endCentreError: Double?, endTiltError: Double?
        var setBallAt: Double?
        var setBallLeftAfterMove = 0
        var events: [String] = []
    }

    static let slabSpec = RecordingSettings(dishBounce: false).trackerSettings.spec

    /// The slab in its cradle at (x, z): tilting it slides its top's centre about 0.27 in per degree away from the way it
    /// leans (`DemoScript.scene(at:)`, the owner's 3 in for 10 deg).
    static func pose(x: Double = 0, z: Double = 0, tilt: Double = 6, heading: Double = 35, yaw: Double = 15) -> SlabPose {
        let shift = Units.inches(0.27 * tilt), hd = Units.radians(heading)
        return SyntheticScene.slabPose(x: x - shift * cos(hd), z: z - shift * sin(hd), tilt: tilt, heading: heading, yaw: yaw, spec: slabSpec)
    }

    static func intrinsics() -> CameraIntrinsics { CameraIntrinsics(verticalFovDegrees: 62, width: 360, height: 480) }

    /// The demo's drifting hand-held camera (`DemoScript.view(at:)`), aimed at `aim`.
    static func view(_ s: Scene, at t: Double, aim: Vec3) -> CameraView {
        let az = Units.radians(20 * sin(t * 2 * .pi / 14)), el = Units.radians(s.elevation + 4 * sin(t * 2 * .pi / 9))
        let pos = aim + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * s.distance + Vec3(0.01 * sin(t * 3.1), 0.008 * sin(t * 2.3), 0)
        var target = aim
        if let (away, f) = s.lookAway?(t), f > 0 {
            // turn from the aim toward the other point, about the camera's own position
            let a = (aim - pos).normalized, b = (away - pos).normalized
            target = pos + (a * (1 - f) + b * f).normalized
        }
        return SyntheticScene.camera(at: pos, lookingAt: target, intrinsics: intrinsics(), roll: 1.5 * sin(t * 0.7))
    }

    /// Paint a cloth over the slab: a disc around its projected top, wider than the top and its cut faces, mottled.
    static func cover(_ rgb: inout [UInt8], slab: SlabPose, view: CameraView) {
        let K = view.intrinsics
        guard let c = view.project(world: slab.center) else { return }
        let q = slab.topCorners.compactMap { view.project(world: $0) }
        let r = 1.45 * (q.map { $0.distance(to: c) }.max() ?? 60)
        for y in max(0, Int(c.y - r))..<min(K.height, Int(c.y + r) + 1) {
            for x in max(0, Int(c.x - r))..<min(K.width, Int(c.x + r) + 1) {
                let d = Vec2(Double(x) + 0.5, Double(y) + 0.5).distance(to: c)
                guard d <= r else { continue }
                let n = SyntheticScene.noise(Double(x) * 0.15, Double(y) * 0.15, 11)
                let i = (y * K.width + x) * 3
                rgb[i] = UInt8(clamp(150 + 40 * (n - 0.5), 0, 255))
                rgb[i + 1] = UInt8(clamp(112 + 30 * (n - 0.5), 0, 255))
                rgb[i + 2] = UInt8(clamp(92 + 25 * (n - 0.5), 0, 255))
            }
        }
    }

    static func slabInView(_ slab: SlabPose, _ v: CameraView) -> Bool {
        let q = slab.topCorners.compactMap { v.project(world: $0) }
        return q.count == 4 && q.allSatisfy { v.intrinsics.contains($0, margin: 4) }
    }

    static func translated(_ p: SlabPose, by d: Vec3) -> SlabPose { var x = p; x.center = p.center + d; return x }

    /// the largest distance between the lock's top corners and the truth's, matched the best way round (the square top
    /// looks the same turned by a quarter)
    static func cornerError(_ a: SlabPose, _ b: SlabPose) -> Double {
        let p = a.topCorners, q = b.topCorners
        var best = Double.infinity
        for k in 0..<4 { for dir in [1, 3] {
            best = min(best, (0..<4).map { p[$0].distance(to: q[(k + dir * $0) % 4]) }.max()!)
        } }
        return best
    }

    func run(_ s: Scene, verbose: Bool = false) -> Run {
        var settings = RecordingSettings(dishBounce: false).trackerSettings
        settings.spec = LostLockRecoveryTests.slabSpec
        XCTAssertTrue(settings.findsMovedSlab, "the app's settings")
        // LOSTLOCK_N20=1: n20's behaviour, for the before/after table (README, build n20r)
        if ProcessInfo.processInfo.environment["LOSTLOCK_N20"] != nil { settings.findsMovedSlab = false }
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var cue = MainScreenCue()
        var r = Run(); r.name = s.name
        var t = 0.0
        var correctSince: Double? = nil
        var firstConfirmed: Double? = nil, tap: Vec2? = nil, tapped = false
        let down = Vec3(0, -1, 0)
        while t < s.seconds {
            let truthSlab = s.slab(t)
            let aim = s.aim?(t) ?? (truthSlab.center + Vec3(0, -0.02, 0))
            let trueView = LostLockRecoveryTests.view(s, at: t, aim: aim)
            var scene = SyntheticScene(spec: settings.spec, slab: truthSlab)
            scene.supersample = 1
            // a hidden held ball over the slab, for tapping to set it
            let heldBall = truthSlab.center + Vec3(0.012, 0.30, -0.01)
            let K = trueView.intrinsics
            var rgb = scene.renderRGB(view: trueView)
            let covered = s.covered(t)
            if covered { LostLockRecoveryTests.cover(&rgb, slab: truthSlab, view: trueView) }
            let img = SyntheticScene.ycc(rgb: rgb, width: K.width, height: K.height)
            // what ARKit reports: the camera in its (possibly shifted) world; the truth moves with it
            let shift = s.worldShift(t)
            let view = CameraView(worldFromCamera: RigidTransform(rotation: trueView.worldFromCamera.rotation,
                                                                  translation: trueView.position + shift), intrinsics: K)
            let truth = LostLockRecoveryTests.translated(truthSlab, by: shift)
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
            if tracker.state == .locked, tracker.ballDue(at: t), let sl = tracker.slab, let c = BallImageCrop.plan(slab: sl, full: view) {
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                ballImage = c.factor > 1 ? p.downscaled(by: c.factor) : p
                ballK = c.intrinsics(full: K)
            }
            let detail = SlabImageCrop.provider(processing: K, full: K) { c in
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                return c.factor > 1 ? p.downscaled(by: c.factor) : p
            }
            let out = tracker.process(TrackerFrame(timestamp: t, view: view, frame: img.colorFrame, ballImage: ballImage, ballIntrinsics: ballK,
                                                   tap: tap, floorY: shift.y, trackingNormal: !s.limited(t), slabDetail: detail))
            tap = nil
            for e in out.events where ["locked", "relocked", "lost", "lock-expired"].contains(e) || e.hasPrefix("lock-unconfirmed")
                || e.hasPrefix("relock") || e.hasPrefix("moved") || e.hasPrefix("lost") {
                r.events.append(String(format: "%.2f %@", t, e))
            }
            if out.events.contains("lost") { r.losses += 1 }
            if out.events.contains(where: { $0 == "locked" || $0 == "relocked" }) { r.lockTimes.append(t) }
            if out.events.contains(where: { $0 == "lost" || $0 == "moved-away" }) { r.lossTimes.append(t) }
            if out.events.contains("relocked") { r.relocks += 1 }
            if out.events.contains("locked") { r.locks += 1 }
            let confirmed = out.state == .locked && !out.lockUnconfirmed
            if confirmed, r.lockedAt == nil { r.lockedAt = t }
            if confirmed, firstConfirmed == nil { firstConfirmed = t }
            // the set ball: tap the hidden held ball once, after the lock
            if let a = s.setBallAfterLock, let f = firstConfirmed, !tapped, t - f >= a, out.angleSettled {
                tap = view.project(world: heldBall + shift); tapped = true
            }
            if out.setBall != nil, r.setBallAt == nil { r.setBallAt = t }
            // the app's cue (ARController.makeHUD)
            let locked = out.state == .locked && !out.lockUnconfirmed, settling = out.state == .locked && !out.angleSettled
            let centre = out.slab?.center ?? tracker.candidateCenter
            let angle: Double? = out.slab.flatMap { MainScreenCue.viewAngleDegrees(slab: $0, camera: view.position) }
                ?? centre.flatMap { MainScreenCue.viewAngleDegrees(center: $0, normal: Vec3(0, 1, 0), camera: view.position) }
            let shown = cue.update(time: t, locked: locked, settling: settling, slabDistance: centre.map { $0.distance(to: view.position) },
                                   viewAngleDegrees: angle, events: out.events)
            let visible = !covered && LostLockRecoveryTests.slabInView(truthSlab, trueView)
            if visible && shown == MainScreenCue.pointAtSlab { r.pointAtSlabInView += 1 }
            // right: a confirmed lock at the truth (centre within 2 cm, normal within 1 deg: its direction as well as the tilt
            // amount, outline corners within 3 cm)
            let tiltTruth = Units.degrees(truth.tilt(down: down))
            var right = false
            if confirmed, let sl = out.slab {
                right = s.tiltAmountOnly
                    ? sl.center.distance(to: truth.center) < 0.02 && abs(Units.degrees(sl.tilt(down: down)) - tiltTruth) < 1
                    : sl.center.distance(to: truth.center) < 0.02 && Units.degrees(sl.normal.angle(to: truth.normal)) < 1
                        && LostLockRecoveryTests.cornerError(sl, truth) < 0.03
            }
            if t >= s.settledFrom, r.correctFrom == nil {
                if right { if correctSince == nil { correctSince = t } } else { correctSince = nil }
                if let c = correctSince, t - c >= 1.5 { r.correctFrom = c }
            }
            // wrong: with the slab visible elsewhere, a confirmed lock (or a shown tilt) off the truth and nearer where the slab
            // was locked before it moved than where it is (in a scene where it never moved: off the truth)
            if let e = s.elsewhereFrom, t >= e, visible {
                var wrong = false
                let old = LostLockRecoveryTests.translated(s.slab(0), by: shift)
                let moved = old.center.distance(to: truth.center) > 1e-6 || old.normal.angle(to: truth.normal) > 1e-6
                if confirmed, let sl = out.slab, sl.center.distance(to: truth.center) > 0.03 || Units.degrees(sl.normal.angle(to: truth.normal)) > 1.5
                    || LostLockRecoveryTests.cornerError(sl, truth) > 0.04 {
                    wrong = !moved || sl.center.distance(to: old.center) < sl.center.distance(to: truth.center)
                        || sl.normal.angle(to: old.normal) < sl.normal.angle(to: truth.normal)
                }
                if out.angleSettled, let rd = out.readouts, abs(rd.tiltDegrees - tiltTruth) > 1.5,
                   !moved || abs(rd.tiltDegrees - Units.degrees(old.tilt(down: down))) < abs(rd.tiltDegrees - tiltTruth) { wrong = true }
                if wrong { r.lastWrong = t; r.wrongFrames += 1 }
                if out.setBall != nil, r.setBallAt != nil, t >= e + 1.0 { r.setBallLeftAfterMove += 1 }
            }
            if confirmed, let sl = out.slab {
                r.endCentreError = sl.center.distance(to: truth.center); r.endTiltError = abs(Units.degrees(sl.tilt(down: down)) - tiltTruth)
            } else {
                r.endCentreError = nil; r.endTiltError = nil
            }
            if verbose {
                print(String(format: "  %@ t %.2f %@%@ vis %d c %@ tilt %@ truth %.2f %@", s.name, t, out.state.rawValue, out.lockUnconfirmed ? "?" : "",
                             visible ? 1 : 0, out.slab.map { String(format: "%.3f", $0.center.distance(to: truth.center)) } ?? "-",
                             out.slab.map { String(format: "%.2f", Units.degrees($0.tilt(down: down))) } ?? "-", tiltTruth,
                             out.events.joined(separator: ",")))
            }
            t += 0.08
        }
        if r.correctFrom == nil, let c = correctSince { r.correctFrom = c }
        return r
    }

    /// The time from the slab lying still and visible at its final place to the lock that holds there (nil: none).
    static func timeToLock(_ r: Run, _ s: Scene) -> Double? { r.correctFrom.map { max(0, $0 - s.settledFrom) } }
    /// how long after the slab showed elsewhere a lock or a shown tilt was last at the wrong place (0: never)
    static func wrongFor(_ r: Run, _ s: Scene) -> Double {
        guard let e = s.elsewhereFrom, let w = r.lastWrong else { return 0 }
        return w - e + 0.08
    }

    static func summary(_ r: Run, _ s: Scene) -> String {
        s.name.padding(toLength: 34, withPad: " ", startingAt: 0) + String(format: " lock %@  correct after %@  wrong for %.2f s (%d fr)  lost %d relock %d lock %d  'Point' in view %d  set ball %@ left %d  end %@  [%@]",
               r.lockedAt.map { String(format: "%.2f", $0) } ?? "never",
               timeToLock(r, s).map { String(format: "%.2f s", $0) } ?? "NEVER", wrongFor(r, s), r.wrongFrames, r.losses, r.relocks, r.locks,
               r.pointAtSlabInView, r.setBallAt.map { String(format: "%.2f", $0) } ?? "-", r.setBallLeftAfterMove,
               r.endCentreError.map { String(format: "%.1f cm %.2f deg", 100 * $0, r.endTiltError ?? 0) } ?? "-",
               r.events.joined(separator: "; "))
    }

    // MARK: scenes

    static let base = pose()

    /// covered from 3 s for `d` seconds
    static func coverScene(_ d: Double, after: Double = 4) -> Scene {
        var s = Scene(name: String(format: "cover %.1f s", d), slab: { _ in base })
        s.covered = { $0 >= 3 && $0 < 3 + d }
        s.settledFrom = 3 + d
        s.elsewhereFrom = 0   // never anywhere else: any lock away from it is wrong
        s.seconds = 3 + d + after
        return s
    }

    /// moved at 3 s (a hand over it for 0.6 s around the move); the camera keeps aiming between the two places (both in
    /// the picture) or follows the slab (`follow`)
    static func moveScene(_ name: String, to p: SlabPose, follow: Bool = false, coverSeconds: Double = 0.6) -> Scene {
        var s = Scene(name: name, slab: { $0 < 3 ? base : p })
        let mid = (base.center + p.center) / 2 + Vec3(0, -0.02, 0)
        if follow {
            // the phone turns to the new place over 0.6 s
            s.aim = { t in
                let f = clamp((t - 3) / 0.6, 0, 1)
                return base.center + (p.center - base.center) * f + Vec3(0, -0.02, 0)
            }
        } else {
            s.aim = { _ in mid }
        }
        s.covered = { $0 >= 3 - coverSeconds / 2 && $0 < 3 + coverSeconds / 2 }
        s.settledFrom = 3 + coverSeconds / 2 + (follow ? 0.3 : 0)
        s.elsewhereFrom = s.settledFrom
        s.seconds = 10
        return s
    }

    /// the camera turned `away` metres to the side for `d` seconds from 3 s (0.4 s each way), the slab moved to `p`
    /// meanwhile (or not)
    static func sweepScene(_ name: String, seconds d: Double, movedTo p: SlabPose? = nil, after: Double = 5) -> Scene {
        let moveAt = 3 + d / 2
        var s = Scene(name: name, slab: { t in (p != nil && t >= moveAt) ? p! : base })
        // the phone stays where it is (aimed between the slab's places) and turns to the floor 1.4 m to the side and back
        let mid = (base.center + (p ?? base).center) / 2 + Vec3(0, -0.02, 0)
        s.aim = { _ in mid }
        s.lookAway = { t in
            let f: Double
            if t < 3 { f = 0 } else if t < 3.4 { f = (t - 3) / 0.4 } else if t < 3 + d { f = 1 } else { f = max(0, 1 - (t - 3 - d) / 0.4) }
            return (Vec3(1.3, 0, 0.4), f)
        }
        s.settledFrom = 3 + d + 0.4
        s.elsewhereFrom = p != nil ? s.settledFrom : nil
        s.seconds = 3 + d + 0.4 + after
        return s
    }

    // MARK: tests

    func check(_ scenes: [Scene], file: StaticString = #filePath, line: UInt = #line,
               _ expect: (Run, Scene) -> Void) {
        for s in scenes {
            if let only = LostLockRecoveryTests.debugScenes, !only.contains(s.name) { continue }
            let r = run(s, verbose: ProcessInfo.processInfo.environment["LOSTLOCK_VERBOSE"] == s.name)
            print("LOSTLOCK " + LostLockRecoveryTests.summary(r, s))
            expect(r, s)
        }
    }

    /// the scene's limits (`Scene.maxLock`, `maxWrong`), and never "Point at the slab" with the slab in view
    func expectLimits(_ r: Run, _ s: Scene) {
        if let m = s.maxLock { XCTAssertLessThanOrEqual(LostLockRecoveryTests.timeToLock(r, s) ?? 99, m, "\(s.name): a lock at the slab") }
        if let m = s.maxWrong { XCTAssertLessThanOrEqual(LostLockRecoveryTests.wrongFor(r, s), m, "\(s.name): nothing left at the wrong place") }
        if let m = s.maxWrongFrames { XCTAssertLessThanOrEqual(r.wrongFrames, m, "\(s.name): frames at the wrong place") }
        XCTAssertEqual(r.pointAtSlabInView, 0, "\(s.name): no 'Point at the slab' with the slab in view")
    }

    func testCoveringTheSlabKeepsOrFindsTheLockAtTheSamePlace() {
        var scenes = [0.5, 1.5, 3].map { LostLockRecoveryTests.coverScene($0) }
        for i in scenes.indices { scenes[i].maxWrongFrames = 0 }   // never locked anywhere else
        // n20's own gap (the slab not moved, n20 the same frame for frame): at the demo camera's widest swing (9 s in) the
        // re-checks agree with each other 0.5 to 0.7 deg off the lock and re-lock onto them, its normal 1.5 deg off the
        // truth (n20: 5 frames). Held to no worse than n20 by more than a re-check's frames
        scenes[2].maxWrong = nil; scenes[2].maxWrongFrames = 8
        // covered 6 s: the lost rule gives the lock up after 4 s (as it should: the slab may have gone); the search finds
        // it again 3.3 s after the cloth goes and that lock is right (2 cm, 1 deg, held) 4.3 s after (n20 alike). Held to
        // that second lock: within 4 s of the cloth going, right within 5 s, at the slab's centre within 2 cm at the end
        var six = LostLockRecoveryTests.coverScene(6, after: 8)
        six.maxLock = 5; six.maxWrongFrames = 0
        scenes.append(six)
        check(scenes) { r, s in
            XCTAssertNotNil(r.lockedAt, s.name)
            self.expectLimits(r, s)
            if let lost = r.lossTimes.last {
                let again = r.lockTimes.first { $0 > lost }
                XCTAssertLessThanOrEqual(again ?? 99, s.settledFrom + 4, "\(s.name): locked again within 4 s of the cover going")
            }
            XCTAssertLessThanOrEqual(r.endCentreError ?? 99, 0.02, "\(s.name): a lock at the slab at the end")
        }
    }

    static var moveScenes: [Scene] {
        func limits(_ s: Scene, lock: Double?, wrong: Double?) -> Scene { var x = s; x.maxLock = lock; x.maxWrong = wrong; return x }
        return [
            // within the re-lock radius (20 cm) the re-checks follow the slab and re-lock after `moveCount` (4) of them, 0.3 s
            // apart: 1.2 s (n20 alike). After 5 cm the first re-lock can sit just outside 2 cm / 1 deg until the next.
            limits(moveScene("slide 5 cm", to: pose(x: 0.05)), lock: nil, wrong: relockRule),
            limits(moveScene("slide 10 cm", to: pose(x: -0.07, z: 0.07)), lock: relockRule, wrong: relockRule),
            // further: n20 kept the old lock until the lost rule ran out (3.3-3.4 s); n20r finds it over the whole view
            limits(moveScene("slide 20 cm", to: pose(x: 0.2)), lock: 1.5, wrong: 1),
            limits(moveScene("slide 30 cm", to: pose(x: -0.21, z: 0.21)), lock: 1.5, wrong: 1),
            // the phone turned with the slab so that the old place stays at the picture's edge (partly in view): n20 kept
            // that lock for good (a lock partly out of the picture is not missed); n20r's whole-view look runs while the
            // lock is not wholly in the picture and finds the slab moved
            limits(moveScene("slide 30 cm, camera follows", to: pose(x: 0.3), follow: true), lock: 1.5, wrong: 1),
            // the old place leaves the picture as the phone turns (n20: 5.4 s)
            limits(moveScene("put 45 cm away, camera follows", to: pose(x: -0.3, z: 0.34, tilt: 3, heading: 200, yaw: 40), follow: true),
                   lock: 1.5, wrong: 1),
            limits(moveScene("turned 30 deg", to: pose(yaw: 45)), lock: 1, wrong: 1),
            limits(moveScene("re-tilted 6 to 2 deg", to: pose(x: 0.015, tilt: 2)), lock: relockRule, wrong: relockRule),
            limits(moveScene("tilt to the other side", to: pose(tilt: 6, heading: 215)), lock: relockRule, wrong: relockRule),
        ]
    }

    func testMovingTheSlabRelocksAtTheNewPlace() {
        check(LostLockRecoveryTests.moveScenes) { r, s in self.expectLimits(r, s) }
    }

    func testPickedUpWhileCoveredAndPutElsewhere() {
        var s = LostLockRecoveryTests.moveScene("moved 25 cm while covered 2 s", to: LostLockRecoveryTests.pose(x: 0.18, z: -0.17, tilt: 4, heading: 90),
                                                coverSeconds: 2)
        s.seconds = 11
        // and a set ball over the old place: it goes with the move
        var b = LostLockRecoveryTests.moveScene("set ball, then slid 20 cm", to: LostLockRecoveryTests.pose(x: 0.2))
        b.slab = { $0 < 6 ? LostLockRecoveryTests.base : LostLockRecoveryTests.pose(x: 0.2) }
        b.covered = { $0 >= 5.7 && $0 < 6.3 }
        b.settledFrom = 6.3; b.elsewhereFrom = 6.3; b.seconds = 12
        b.setBallAfterLock = 0.5
        // the camera stays aimed between the places, so the slab lies near the picture's edge: the lock found there 0.6 s
        // after the move sits within 0.4 cm and 0.1 deg, then the re-checks there pull its tilt 0.2 to 0.8 deg low (n20
        // alike, an edge-of-picture measurement, not the recovery): held to the owner's words (centre 2 cm, tilt 1 deg)
        b.tiltAmountOnly = true
        check([s, b]) { r, s in
            XCTAssertLessThanOrEqual(LostLockRecoveryTests.timeToLock(r, s) ?? 99, 3, "\(s.name): locked at the new place")
            XCTAssertLessThanOrEqual(LostLockRecoveryTests.wrongFor(r, s), 1.0, "\(s.name): nothing left at the old place")
            XCTAssertEqual(r.pointAtSlabInView, 0, "\(s.name)")
            XCTAssertEqual(r.setBallLeftAfterMove, 0, "\(s.name): the set ball goes with the move")
        }
    }

    static var sweepScenes: [Scene] {
        // the slab not moved: any lock away from it is wrong (no frame of it)
        func unmoved(_ s: Scene) -> Scene { var x = s; x.elsewhereFrom = 0; x.maxWrongFrames = 0; return x }
        var slid = sweepScene("away 3 s, slab slid 10 cm", seconds: 3, movedTo: pose(x: 0.1))
        // within the re-lock radius: the re-checks follow it, `moveCount` (4) of them 0.3 s apart (as "slide 10 cm")
        slid.maxWrong = relockRule
        // n20's own gap: the slab not moved, at the demo camera's widest swing (9 s in) its re-checks agree with each other
        // 0.5 to 0.7 deg off the lock and re-lock onto them, the normal 1.5 to 2 deg off the truth (n20: 4 frames off).
        // Held to no worse than n20 by more than a re-check's frames (n20: 4), and run 4 s longer to see the re-lock settle
        // (0.1 deg off at the end)
        var away3 = unmoved(sweepScene("away 3 s", seconds: 3, after: 9))
        away3.maxWrong = nil; away3.maxWrongFrames = 7
        return [
            unmoved(sweepScene("away 1 s", seconds: 1)),
            away3,
            unmoved(sweepScene("away 10 s", seconds: 10)),
            slid,
            sweepScene("away 3 s, slab put 40 cm away", seconds: 3, movedTo: pose(x: -0.28, z: 0.28, tilt: 3, heading: 120)),
        ]
    }

    func testSweepingTheCameraAwayAndBack() {
        check(LostLockRecoveryTests.sweepScenes) { r, s in
            self.expectLimits(r, s)
        }
    }

    func testARKitRelocalisingMovesTheLockWithTheWorld() {
        // 2.5 s of limited tracking, then the reported world is 0.6 m off the old one
        var s = Scene(name: "relocalised 0.6 m", slab: { _ in LostLockRecoveryTests.base })
        s.limited = { $0 >= 3 && $0 < 5.5 }
        s.worldShift = { $0 >= 5.5 ? Vec3(0.6, 0, -0.2) : .zero }
        s.settledFrom = 5.5; s.elsewhereFrom = 5.5; s.seconds = 10
        // a pose jump with tracking normal throughout (a snap)
        var j = Scene(name: "world snap 0.4 m", slab: { _ in LostLockRecoveryTests.base })
        j.worldShift = { $0 >= 3 ? Vec3(-0.3, 0.02, 0.27) : .zero }
        j.settledFrom = 3; j.elsewhereFrom = 3; j.seconds = 9
        check([s, j]) { r, s in
            XCTAssertLessThanOrEqual(LostLockRecoveryTests.timeToLock(r, s) ?? 99, 3, "\(s.name): locked at the slab's new coordinates")
            XCTAssertLessThanOrEqual(LostLockRecoveryTests.wrongFor(r, s), 1.0, "\(s.name)")
        }
    }
}
