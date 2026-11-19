import XCTest
@testable import BounceCore

/// A ball finder that reports scripted balls (world centres, in the order a finder would rank them), honouring the
/// tracker's tap hints as `BallLocator` does when `honoursHints` (a dismissed spot is passed over, a ball in the tap's
/// box comes first), or ignoring them (the tracker must then pass over a dismissed spot itself).
final class ScriptedBalls: BallLocating {
    var balls: [Vec3] = []
    var view: CameraView?
    var honoursHints = true
    private(set) var given: [BallSearchHints] = []
    private var hints = BallSearchHints()
    private(set) var resets = 0
    func setSearchHints(_ h: BallSearchHints) { hints = h; given.append(h) }
    func locate(image: Plane, intrinsics K: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        guard let v = view else { return nil }
        var found: [(Vec3, Vec2, Double)] = balls.compactMap { w in
            let c = v.toCamera(w)
            guard let p = K.project(c), let r = Bounce.imageRadius(ballCenter: c, intrinsics: K, ball: ball) else { return nil }
            return (c, p, r)
        }
        if honoursHints {
            found = found.filter { !hints.avoids($0.1) }
            if let box = hints.region { found = found.filter { box.contains($0.1) } + found.filter { !box.contains($0.1) } }
        }
        return found.first
    }
    func reset() { resets += 1 }
}

/// Tap hints (`TrackerSettings.tapHints`): a tap means what is under the finger. Without a tap nothing changes; a tap on
/// a ring dismisses it and passes over its spot; a tap where a ball could be looks there first; a slab tap never gives a
/// good lock up for nothing, and a tapped search that grows nothing from its pixel falls back to the sweep under the
/// finger.
final class TapHintTests: XCTestCase {
    let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
    let up = Vec3(0, 1, 0)
    let image = ColorFrame(gray: Plane(width: 8, height: 6))

    func settings(hints: Bool = true) -> TrackerSettings {
        var s = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        s.spec = .standard
        s.tapHints = hints
        return s
    }

    /// One frame at time t from view v (the ball image: the processing frame's size and intrinsics).
    @discardableResult
    func step(_ tr: SlabTracker, _ det: SceneDetector, _ balls: ScriptedBalls?, _ v: CameraView, _ t: Double, tap: Vec2? = nil) -> TrackerOutput {
        det.currentView = v; balls?.view = v
        let ballDue = tr.ballDue(at: t)
        return tr.process(TrackerFrame(timestamp: t, view: v, frame: image,
                                       ballImage: ballDue ? Plane(width: v.intrinsics.width, height: v.intrinsics.height) : nil,
                                       ballIntrinsics: ballDue ? v.intrinsics : nil, tap: tap))
    }

    func lockedTracker(hints: Bool = true, balls: ScriptedBalls? = nil) -> (SlabTracker, SceneDetector, CameraView, Int) {
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let tr = SlabTracker(settings: settings(hints: hints), detector: det, ballLocator: balls)
        let v = w.view(from: Vec3(0.05, 0.9, 0), at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        return (tr, det, v, k)
    }

    // MARK: no tap, no change

    func testWithoutATapTheHintsChangeNothing() {
        func run(_ hints: Bool) -> [String] {
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 9)
            let balls = ScriptedBalls(); balls.balls = [slab.center + up * 0.32]
            let tr = SlabTracker(settings: settings(hints: hints), detector: det, ballLocator: balls)
            var out: [String] = []
            for k in 0..<360 {
                let t = Double(k) / 60
                let v = w.view(from: Vec3(0.1 * sin(t), 0.9, 0.05 * cos(t * 0.7)), at: slab.center)
                let o = step(tr, det, balls, v, t)
                out.append("\(o.state) \(o.slab.map { "\($0.center) \($0.normal)" } ?? "-") \(o.ball.map { "\($0.center)" } ?? "-") "
                           + "\(o.readouts.map { "\($0.tiltDegrees) \($0.dropHeight)" } ?? "-") \(o.events)")
            }
            return out
        }
        XCTAssertEqual(run(false), run(true))
    }

    // MARK: what is under the finger

    func testATapMeansWhatIsUnderTheFinger() {
        let balls = ScriptedBalls()
        let B = slab.center + up * 0.30
        balls.balls = [B]
        let (tr, det, v, k) = lockedTracker(balls: balls)
        for j in 0..<12 { step(tr, det, balls, v, Double(k + j) / 60) }
        XCTAssertNotNil(tr.process(TrackerFrame(timestamp: Double(k + 12) / 60, view: v, frame: image, ballImage: Plane(width: 480, height: 360),
                                                ballIntrinsics: v.intrinsics)).ball, "the ball is shown")
        let ring = v.project(world: B)!
        XCTAssertEqual(tr.tapKind(ring, view: v), .dismissBall)
        XCTAssertEqual(tr.tapKind(ring + Vec2(6, -4), view: v), .dismissBall, "within a fingertip of the ring")
        // over the slab, away from the ring: where a ball could be
        let over = v.project(world: slab.center + up * 0.08 + slab.axisU * 0.04)!
        XCTAssertGreaterThan(over.distance(to: ring), 40)
        XCTAssertEqual(tr.tapKind(over, view: v), .ball)
        XCTAssertFalse(tr.tapSeedsSlab(over, view: v))
        // the floor well beside the slab: the slab
        let floor = v.project(world: Vec3(slab.center.x + 0.45, 0, slab.center.z + 0.25))!
        XCTAssertEqual(tr.tapKind(floor, view: v), .slab)
        XCTAssertTrue(tr.tapSeedsSlab(floor, view: v))
        // without tap hints every tap is the slab's (n11)
        tr.settings.tapHints = false
        XCTAssertEqual(tr.tapKind(ring, view: v), .slab)
        XCTAssertEqual(tr.tapKind(over, view: v), .slab)
        // and before the lock, with them
        let fresh = SlabTracker(settings: settings(), detector: SceneDetector(World(slab: slab, lens: .processing)))
        XCTAssertEqual(fresh.tapKind(over, view: v), .slab)
    }

    func testTheBallsPlaceAlongATappedLine() {
        let cam = Vec3(0.05, 0.9, 0), ball = BallSpec(diameter: 0.030)
        for h in [0.05, 0.3, 0.9] {
            let B = slab.center + up * (ball.radius + h)
            let d = (B - cam).normalized
            let r = TapHints.ballRange(origin: cam, direction: d, slab: slab, ball: ball, down: ARKitConvention.worldDown)
            XCTAssertNotNil(r, "\(h) m over the slab")
            if let r { XCTAssertTrue(r.contains(B.distance(to: cam)), "\(h) m: \(r) holds \(B.distance(to: cam))") }
        }
        let beside = (Vec3(0.5, 0.05, -1.0) - cam).normalized
        XCTAssertNil(TapHints.ballRange(origin: cam, direction: beside, slab: slab, ball: ball, down: ARKitConvention.worldDown))
    }

    // MARK: a wrong ring

    func testATapOnAWrongRingDismissesItAndPassesOverItsSpot() {
        for honours in [true, false] {
            let balls = ScriptedBalls(); balls.honoursHints = honours
            let wrong = slab.center + up * 0.22 + slab.axisV * 0.05
            balls.balls = [wrong]
            let (tr, det, v, k0) = lockedTracker(balls: balls)
            var k = k0
            for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
            let ring = v.project(world: wrong)!
            let o = step(tr, det, balls, v, Double(k) / 60, tap: ring); k += 1
            XCTAssertEqual(o.tap?.kind, .dismissBall)
            XCTAssertNil(o.ball, "gone at once")
            XCTAssertEqual(o.dismissedSpots, 1)
            XCTAssertNil(o.detectionKind, "no slab search for it")
            var shown = 0
            for _ in 0..<120 { if step(tr, det, balls, v, Double(k) / 60).ball != nil { shown += 1 }; k += 1 }
            XCTAssertEqual(shown, 0, "honours \(honours): passed over while it lasts")
            if !honours { XCTAssertGreaterThan(tr.counts["tapDismissPassed"] ?? 0, 0) }
            // the real ball elsewhere is shown (by a finder that passes over the spot itself, as BallLocator does: one that
            // does not keeps ranking the dismissed ring first, and the tracker can only drop it)
            let real = slab.center + up * 0.35 - slab.axisV * 0.06
            balls.balls = honours ? [wrong, real] : [real]
            var realShown = false
            for _ in 0..<30 { if let b = step(tr, det, balls, v, Double(k) / 60).ball, b.center.distance(to: real) < 0.01 { realShown = true }; k += 1 }
            XCTAssertTrue(realShown, "honours \(honours)")
            // the spot expires
            balls.balls = [wrong]
            var back = false
            let until = Double(k) / 60 + tr.settings.tapDismissSeconds + 1
            while Double(k) / 60 < until { if step(tr, det, balls, v, Double(k) / 60).ball != nil { back = true }; k += 1 }
            XCTAssertTrue(back, "back after \(tr.settings.tapDismissSeconds) s")
            XCTAssertEqual(tr.dismissedSpots.count, 0)
            XCTAssertEqual(tr.counts["tapDismiss"], 1)
        }
    }

    func testAtMostAFewSpotsAndAResetClearsThem() {
        let balls = ScriptedBalls()
        let (tr, det, v, k0) = lockedTracker(balls: balls)
        var k = k0
        for i in 0..<6 {
            let w = slab.center + up * (0.2 + 0.05 * Double(i)) + slab.axisU * (0.03 * Double(i) - 0.08)
            balls.balls = [w]
            for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
            let o = step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: w)!); k += 1
            XCTAssertEqual(o.tap?.kind, .dismissBall, "ring \(i)")
        }
        XCTAssertEqual(tr.dismissedSpots.count, tr.settings.tapDismissMax)
        tr.reset()
        XCTAssertEqual(tr.dismissedSpots.count, 0)
    }

    // MARK: a ball tap

    func testABallTapLooksThereFirst() {
        let balls = ScriptedBalls()
        let wrong = slab.center + up * 0.22 + slab.axisV * 0.06, real = slab.center + up * 0.40 - slab.axisV * 0.05
        balls.balls = [wrong, real]
        let (tr, det, v, k0) = lockedTracker(balls: balls)
        var k = k0
        var last: TrackerOutput? = nil
        for _ in 0..<12 { last = step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertLessThan(last!.ball!.center.distance(to: wrong), 0.01, "the finder ranks the wrong one first")
        let p = v.project(world: real)!
        let o = step(tr, det, balls, v, Double(k) / 60, tap: p); k += 1
        XCTAssertEqual(o.tap?.kind, .ball)
        XCTAssertTrue(o.ballHintActive)
        var found: Double? = nil
        let t0 = Double(k - 1) / 60
        for _ in 0..<30 {
            let t = Double(k) / 60
            let x = step(tr, det, balls, v, t); k += 1
            if let b = x.ball, b.center.distance(to: real) < 0.01 { found = t - t0; XCTAssertTrue(x.events.contains("tap-ball-found")); break }
        }
        XCTAssertNotNil(found)
        XCTAssertLessThanOrEqual(found ?? 9, 0.05, "on the next scan")
        XCTAssertNil(tr.ballHint, "done once found")
        XCTAssertEqual(tr.counts["tapBallFound"], 1)
        // the hint the finder got: the tapped place, at the real ball's size
        let h = balls.given.first { $0.region != nil }!
        let r = Bounce.imageRadius(ballCenter: v.toCamera(real), intrinsics: v.intrinsics, ball: tr.settings.ball)!
        XCTAssertTrue(h.region!.contains(p)); XCTAssertTrue(h.radii!.contains(r), "\(h.radii!) holds \(r)")
        // a tap where no ball is: it expires
        balls.balls = []
        _ = step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: slab.center + up * 0.1)!); k += 1
        var expired = false
        for _ in 0..<Int(60 * (tr.settings.tapBallSeconds + 0.5)) { if step(tr, det, balls, v, Double(k) / 60).events.contains("tap-ball-expired") { expired = true }; k += 1 }
        XCTAssertTrue(expired)
        XCTAssertEqual(tr.state, .locked, "a ball tap never touches the lock")
    }

    func testABallTapWhereARingWasDismissedTakesItBack() {
        let balls = ScriptedBalls()
        let b = slab.center + up * 0.25
        balls.balls = [b]
        let (tr, det, v, k0) = lockedTracker(balls: balls)
        var k = k0
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let p = v.project(world: b)!
        XCTAssertEqual(step(tr, det, balls, v, Double(k) / 60, tap: p).tap?.kind, .dismissBall); k += 1
        for _ in 0..<6 { XCTAssertNil(step(tr, det, balls, v, Double(k) / 60).ball); k += 1 }
        let o = step(tr, det, balls, v, Double(k) / 60, tap: p + Vec2(3, 2)); k += 1
        XCTAssertEqual(o.tap?.kind, .ball, "no ring under the finger now")
        XCTAssertEqual(o.dismissedSpots, 0, "taken back")
        var back = false
        for _ in 0..<6 { if step(tr, det, balls, v, Double(k) / 60).ball != nil { back = true }; k += 1 }
        XCTAssertTrue(back)
    }

    // MARK: a slab tap

    func testASlabTapAwayFromTheLockKeepsItUnlessAnotherSlabIsThere() {
        let a = World.slabAt(Vec3(0, 0.066, -1.2), tilt: 6, heading: 30)
        let bPose = World.slabAt(Vec3(0.3, 0.066, -1.3), tilt: 0, heading: 0, yaw: 30)
        let w = World(slab: a, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 161)
        det.other = bPose
        let tr = SlabTracker(settings: settings(), detector: det)
        let v = w.view(from: Vec3(0.1, 0.9, 0), at: (a.center + bPose.center) / 2)
        var k = 0
        for _ in 0..<60 { step(tr, det, nil, v, Double(k) / 30); k += 1 }
        XCTAssertLessThan(tr.slab!.center.distance(to: bPose.center), 0.03, "locked on the lookalike first")
        // a tap on the bare floor: looked at, nothing there, the lock stays
        let floor = v.project(world: Vec3(-0.35, 0, -0.9))!
        XCTAssertEqual(tr.tapKind(floor, view: v), .slab)
        var o = step(tr, det, nil, v, Double(k) / 30, tap: floor); k += 1
        XCTAssertEqual(o.state, .locked)
        XCTAssertTrue(o.events.contains("tap-slab")); XCTAssertFalse(o.events.contains("tap"), "no new search: the camera's locks stay")
        for _ in 0..<30 { o = step(tr, det, nil, v, Double(k) / 30); k += 1; XCTAssertEqual(o.state, .locked) }
        XCTAssertGreaterThan(tr.counts["tapSlabProbes"] ?? 0, 0)
        XCTAssertLessThan(tr.slab!.center.distance(to: bPose.center), 0.03)
        // a tap on the real slab: another slab is there, the search starts over on it
        let tapAt = w.corners(in: v).reduce(Vec2.zero) { $0 + $1 } / 4
        XCTAssertEqual(tr.tapKind(tapAt, view: v), .slab, "the real slab is not over the lookalike")
        var events: [String] = []
        events += step(tr, det, nil, v, Double(k) / 30, tap: tapAt).events; k += 1
        for _ in 0..<90 { events += step(tr, det, nil, v, Double(k) / 30).events; k += 1 }
        XCTAssertTrue(events.contains("tap-slab-elsewhere"), "\(events)")
        XCTAssertEqual(tr.state, .locked)
        XCTAssertLessThan(tr.slab!.center.distance(to: a.center), 0.03, "locked on the tapped slab")
        XCTAssertEqual(tr.counts["tapSlabLocks"], 1)
        XCTAssertEqual(tr.tapSlabLockSeconds.count, 1)
    }

    /// A detector whose tapped search grows nothing (the tapped pixel sat on a speck) while its sweep finds the slab
    /// (`sweeps`), or the other way round (the sweep's screens fail, in poor light, say, while the tapped growth does not).
    final class SweepOnly: SlabDetecting {
        let inner: SceneDetector
        var sweeps = true
        private(set) var seeded = 0, swept = 0
        init(_ d: SceneDetector) { inner = d }
        func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
            if seed != nil { seeded += 1; return sweeps ? [] : inner.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: nil, near: near) }
            swept += 1
            return sweeps ? inner.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: nil, near: near) : []
        }
    }

    /// With tap hints a tapped search takes the sweep's own outline under the finger (as it would without the tap), and
    /// grows the slab from the tapped point only where the sweep has none there.
    func testATappedSearchTakesTheSweepsOutlineUnderTheFingerAndGrowsOnlyWhereItHasNone() {
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        let tapAt = w.corners(in: v).reduce(Vec2.zero) { $0 + $1 } / 4
        for sweeps in [true, false] {
            var lockedAt: [Bool: Double] = [:]
            for hints in [false, true] {
                let inner = SceneDetector(w, noise: 0.3, seed: 5)
                let det = SweepOnly(inner); det.sweeps = sweeps
                let tr = SlabTracker(settings: settings(hints: hints), detector: det)
                for k in 0..<240 {
                    let t = Double(k) / 60
                    inner.currentView = v
                    _ = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, tap: k == 0 ? tapAt : nil))
                    if tr.state == .locked && lockedAt[hints] == nil { lockedAt[hints] = t }
                }
                if hints && sweeps { XCTAssertEqual(det.seeded, 0, "the sweep's outline under the finger: nothing grown") }
                if hints && !sweeps { XCTAssertGreaterThan(tr.counts["tapSlabGrown"] ?? 0, 0) }
            }
            if sweeps {
                XCTAssertNil(lockedAt[false], "n11: the seed holds the search to the tapped pixel until it times out")
            } else {
                XCTAssertLessThan(lockedAt[false] ?? 9, 0.6, "n11 grows it from the tap")
            }
            XCTAssertLessThan(lockedAt[true] ?? 9, 0.6, "sweeps \(sweeps): with hints it locks at once")
        }
    }

    /// A tap on the floor beside the slab before it is found (nothing there): with tap hints the search looks only there
    /// for `tapSlabFirstSeconds`, then the sweep's slab counts again; n11 held the search to the tapped pixel for the
    /// seed's whole `seedTimeout`.
    func testAStrayTapBeforeTheLockCostsAtMostTheFirstSecond() {
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        let stray = v.project(world: Vec3(slab.center.x - 0.4, 0, slab.center.z + 0.2))!
        XCTAssertFalse(SlabTracker.contains(w.corners(in: v), stray, slack: 0.25))
        var lockedAt: [Bool: Double] = [:]
        for hints in [false, true] {
            let inner = SceneDetector(w, noise: 0.3, seed: 6)
            let det = SweepOnly(inner)
            let tr = SlabTracker(settings: settings(hints: hints), detector: det)
            for k in 0..<240 {
                let t = Double(k) / 60
                inner.currentView = v
                _ = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, tap: k == 0 ? stray : nil))
                if tr.state == .locked && lockedAt[hints] == nil { lockedAt[hints] = t }
            }
        }
        XCTAssertNil(lockedAt[false], "n11: nothing for the seed's \(TrackerSettings().seedTimeout) s")
        let t = lockedAt[true] ?? 9
        XCTAssertGreaterThanOrEqual(t, TrackerSettings().tapSlabFirstSeconds, "only under the finger at first")
        XCTAssertLessThan(t, TrackerSettings().tapSlabFirstSeconds + 0.6, "then the slab the sweep finds")
    }

    /// With no floor known yet (ARKit's plane) and nothing found, a slab tap takes its place from LiDAR's depth under the
    /// finger, so the seed stays on the tapped thing as the phone moves (n11 guessed 1.2 m along the line); a guessed one
    /// lasts only `tapSlabFirstSeconds`.
    func testASlabTapWithoutAFloorTakesItsPlaceFromLiDAR() {
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        let (d, dk) = w.depthMap(v, spec: .standard)
        let tapAt = v.project(world: slab.center)!
        for hints in [false, true] {
            let tr = SlabTracker(settings: settings(hints: hints), detector: SceneDetector(w))
            _ = tr.process(TrackerFrame(timestamp: 0, view: v, frame: image, depth: d, depthIntrinsics: dk, tap: tapAt))
            let err = tr.seedPoint!.distance(to: slab.center)
            if hints { XCTAssertLessThan(err, 0.02) } else { XCTAssertGreaterThan(err, 0.05, "n11 guesses 1.2 m along the line") }
        }
        // no depth either: guessed, gone after the first second (n11: the seed's 6 s)
        for hints in [false, true] {
            let tr = SlabTracker(settings: settings(hints: hints), detector: SceneDetector(w))
            var expiredAt: Double? = nil
            for k in 0..<480 {
                let o = tr.process(TrackerFrame(timestamp: Double(k) / 60, view: v, frame: image, tap: k == 0 ? tapAt : nil))
                if expiredAt == nil, o.events.contains("seed-expired") { expiredAt = Double(k) / 60 }
            }
            XCTAssertEqual(expiredAt ?? 99, hints ? tr.settings.tapSlabFirstSeconds : tr.settings.seedTimeout, accuracy: 0.05, "hints \(hints)")
        }
    }

    func testATapOnTheOutlineBeingConfirmedKeepsIt() {
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 12)
        let tr = SlabTracker(settings: settings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var k = 0
        while tr.state != .confirming && k < 60 { step(tr, det, nil, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .confirming)
        let tapAt = w.corners(in: v).reduce(Vec2.zero) { $0 + $1 } / 4
        let o = step(tr, det, nil, v, Double(k) / 60, tap: tapAt); k += 1
        XCTAssertTrue(o.events.contains("tap-slab"), "\(o.events)")
        XCTAssertFalse(o.events.contains("candidate-lost") || o.events.contains("tap"))
        XCTAssertEqual(tr.counts["tapSlabOnCandidate"], 1)
        while tr.state != .locked && k < 120 { step(tr, det, nil, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .locked)
    }

    // MARK: settings

    func testTapSettingsAreRecordedAndOlderFilesReadThemOff() throws {
        let app = RecordingSettings().trackerSettings
        XCTAssertTrue(app.tapHints)
        XCTAssertEqual(try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app)), app)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as! [String: Any]
        for k in ["tapHints", "tapSlackFraction", "tapBallSeconds", "tapDismissSeconds", "tapDismissMax", "tapSlabFirstSeconds"] {
            XCTAssertNotNil(json.removeValue(forKey: k), k)
        }
        let old = try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.tapHints, "an n11 recording replays its taps as n11 took them")
    }
}

/// The ball finder's side of the tap hints (`BallLocator.searchHints`, a thin input to its search): on the phone's
/// crop of a rendered held ball, a dismissed spot over the ball keeps it from being reported, a tap's box elsewhere does
/// not stop the whole window's search, and in poor light (the scene at a third of its light, with noise) a tap's box on
/// the ball finds it at least as often as the unprompted search does.
final class TapBallLocatorTests: XCTestCase {
    struct Scene { var luma: Plane; var K: CameraIntrinsics; var slab: SlabPose; var down: Vec3; var ball: Vec2; var radius: Double }

    func scene(light: Double = 1, noise: Double = 0, seed: UInt64 = 1, inches: Double = 12) -> Scene {
        let f = 0.78 * 1920, Kf = CameraIntrinsics(fx: f, fy: f, cx: 960, cy: 720, width: 1920, height: 1440)
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35), spec = SlabSpec.standard, ball = BallSpec()
        let up = Vec3(0, 1, 0), h = Units.inches(inches)
        let B = slab.center - slab.normal * spec.dishDepth + up * (ball.radius + h)
        let a = Units.radians(32.0), e = Units.radians(45.0), aim = slab.center + up * (h * 0.4)
        let full = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * (1.0 + h * 0.25), lookingAt: aim, intrinsics: Kf)
        let crop = BallImageCrop.plan(slab: slab, full: full)!
        let view = CameraView(worldFromCamera: full.worldFromCamera, intrinsics: crop.intrinsics(full: Kf))
        let K = view.intrinsics
        let rgb = TapLightTests.dim(SyntheticScene(slab: slab, ball: B).renderRGB(view: view), light: light, noise: noise, seed: seed)
        let luma = SyntheticScene.ycc(rgb: rgb, width: K.width, height: K.height).luma
        let c = view.toCamera(B)
        return Scene(luma: luma, K: K, slab: slab.transformed(by: view.cameraFromWorld), down: view.cameraFromWorld.applyDirection(ARKitConvention.worldDown),
                     ball: K.project(c)!, radius: Bounce.imageRadius(ballCenter: c, intrinsics: K, ball: ball)!)
    }

    func scans(_ s: Scene, hints: BallSearchHints, count: Int = 3) -> [BallObservation?] {
        let loc = BallLocator()
        loc.searchHints = hints
        return (0..<count).map { _ in loc.update(luma: s.luma, intrinsics: s.K, slab: s.slab, spec: .standard, ball: BallSpec(), down: s.down) }
    }

    func testADismissedSpotIsPassedOverAndATapsBoxElsewhereStopsNothing() {
        let s = scene()
        let plain = scans(s, hints: BallSearchHints())
        XCTAssertNotNil(plain.last!, "the rendered ball is found unprompted")
        let over = scans(s, hints: BallSearchHints(avoid: [BallSearchAvoid(center: s.ball, radius: 1.5 * s.radius)]))
        XCTAssertTrue(over.allSatisfy { $0 == nil }, "passed over where it was dismissed")
        let elsewhere = ImageRect(center: Vec2(s.ball.x + 8 * s.radius, s.ball.y), halfSize: 2 * s.radius)
        let other = scans(s, hints: BallSearchHints(region: elsewhere, radii: (0.8 * s.radius)...(1.25 * s.radius)))
        XCTAssertNotNil(other.last!, "a tap's box elsewhere: the whole window is still searched")
        XCTAssertLessThan(other.last!!.circle.center.distance(to: s.ball), 0.25 * s.radius)
    }

    func testATapsBoxOnTheBallInPoorLight() {
        var plainFound = 0, tapFound = 0, n = 0
        for seed in UInt64(1)...4 {
            let s = scene(light: 0.33, noise: 4, seed: seed)
            let box = ImageRect(center: s.ball, halfSize: 2.2 * s.radius)
            let hint = BallSearchHints(region: box, radii: (0.75 * s.radius)...(1.3 * s.radius))
            for (k, o) in scans(s, hints: BallSearchHints()).enumerated() where k > 0 { n += 1; if let o, o.circle.center.distance(to: s.ball) < 0.5 * s.radius { plainFound += 1 } }
            for (k, o) in scans(s, hints: hint).enumerated() where k > 0 { if let o, o.circle.center.distance(to: s.ball) < 0.5 * s.radius { tapFound += 1 } }
        }
        print("TAP BALL dim (a third of the light, 4 levels of noise): found on \(plainFound) of \(n) scans unprompted, \(tapFound) with a tap's box")
        XCTAssertGreaterThanOrEqual(tapFound, plainFound)
    }
}
