import XCTest
@testable import BounceCore

/// n17 (the demo build): the main screen's short cue (`MainScreenCue`) and the ball tap's larger reach
/// (`TapSetBall.reach`, `TapSetBall.underFinger`).
final class DemoCueTests: XCTestCase {
    // MARK: the cue

    func run(_ cue: inout MainScreenCue, from t0: Double, to t1: Double, locked: Bool, settling: Bool = false, distance: Double? = nil,
             angle: Double? = nil, events: [String] = []) -> [(Double, String?)] {
        var out: [(Double, String?)] = []
        var t = t0, first = true
        while t <= t1 + 1e-9 {
            out.append((t, cue.update(time: t, locked: locked, settling: settling, slabDistance: distance, viewAngleDegrees: angle,
                                      events: first ? events : [])))
            first = false
            t += 0.1
        }
        return out
    }

    func testNotLockedForTwoSecondsSaysPointAtTheSlabOrStepCloser() {
        var c = MainScreenCue()
        let a = run(&c, from: 0, to: 3, locked: false)
        XCTAssertTrue(a.filter { $0.0 <= 2.0 }.allSatisfy { $0.1 == nil }, "nothing for the first 2 s")
        XCTAssertEqual(a.last?.1, MainScreenCue.pointAtSlab)
        // the slab being confirmed is far: "Step closer" (no angle, or the phone low over it), "Lower the phone" (high
        // over it: 1.6 m at 35 deg is 1.31 m up, chest height)
        XCTAssertEqual(c.update(time: 3.1, locked: false, settling: false, slabDistance: 1.6, viewAngleDegrees: nil, events: []), MainScreenCue.stepCloser)
        XCTAssertEqual(c.update(time: 3.15, locked: false, settling: false, slabDistance: 1.6, viewAngleDegrees: 55, events: []), MainScreenCue.stepCloser)
        XCTAssertEqual(c.update(time: 3.17, locked: false, settling: false, slabDistance: 1.6, viewAngleDegrees: 35, events: []), MainScreenCue.lowerPhone)
        // a slab being confirmed within 1.25 m: hold steady (it is about to lock), not "Point at the slab"
        XCTAssertEqual(c.update(time: 3.2, locked: false, settling: false, slabDistance: 1.0, viewAngleDegrees: 45, events: []), MainScreenCue.holdSteady)
        // the search gives the slab up for a moment: the slab seen 0.05 s ago still counts (n19 dry run,
        // `slabMemorySeconds`)
        XCTAssertEqual(c.update(time: 3.25, locked: false, settling: false, slabDistance: nil, viewAngleDegrees: nil, events: []), MainScreenCue.holdSteady)
        // no slab for more than 2.5 s: "Point at the slab"
        let gone = run(&c, from: 3.3, to: 6.0, locked: false)
        XCTAssertTrue(gone.filter { $0.0 <= 3.2 + 2.5 - 1e-9 }.allSatisfy { $0.1 == MainScreenCue.holdSteady })
        XCTAssertEqual(gone.last?.1, MainScreenCue.pointAtSlab)
        // locked and settled: nothing
        XCTAssertNil(c.update(time: 6.05, locked: true, settling: false, slabDistance: 1.0, viewAngleDegrees: 45, events: []))
    }

    /// The n19 dry run on the owner's kits: before the lock the search gave its candidate up and started again 83 times
    /// (0.1 to 2.2 s each, the slab 0.6 to 1.8 m away and in the picture wherever its place was known), and once the 2 s
    /// wait was over the cue flipped to "Point at the slab" in those gaps (21 s over the two kits). The last slab seen now
    /// stands in for up to 2.5 s: the slab's own cue holds through the gaps, and "Point at the slab" comes 2.5 s after the
    /// phone last saw it.
    func testTheSearchStartingOverDoesNotSayPointAtTheSlab() {
        var c = MainScreenCue()
        XCTAssertEqual(c.slabMemorySeconds, 2.5)
        // kit 2's room scan: a candidate 1.33 m away, the phone 1.19 m over it (26 deg from straight down), given up and
        // found again; gaps of 0.13 to 2.2 s
        var cues: [(Double, String?)] = []
        var t = 0.0, lastSeen = 0.0
        for (seen, gap) in [(1.2, 0.13), (0.9, 1.6), (0.5, 0.4), (1.2, 2.2), (0.6, 0.13), (0.8, 1.07)] {
            let s = run(&c, from: t, to: t + seen, locked: false, distance: 1.33, angle: 26)
            cues += s; lastSeen = s.last!.0
            t += seen + 0.1
            cues += run(&c, from: t, to: t + gap, locked: false)
            t += gap + 0.1
        }
        XCTAssertFalse(cues.contains { $0.1 == MainScreenCue.pointAtSlab }, "no 'Point at the slab' while the search starts over")
        XCTAssertTrue(cues.filter { $0.0 > 2.05 }.allSatisfy { $0.1 == MainScreenCue.lowerPhone }, "the far, high slab's cue throughout")
        // the phone turned away from the slab: "Point at the slab" once 2.5 s have passed since it last saw it
        let away = run(&c, from: t, to: lastSeen + 3.5, locked: false)
        XCTAssertTrue(away.filter { $0.0 <= lastSeen + 2.5 - 1e-9 }.allSatisfy { $0.1 == MainScreenCue.lowerPhone })
        XCTAssertTrue(away.filter { $0.0 > lastSeen + 2.5 + 1e-9 }.allSatisfy { $0.1 == MainScreenCue.pointAtSlab })
        XCTAssertEqual(away.last?.1, MainScreenCue.pointAtSlab)
        // never seen at all: "Point at the slab" after 2 s, as before
        var d = MainScreenCue()
        XCTAssertEqual(run(&d, from: 0, to: 2.5, locked: false).last?.1, MainScreenCue.pointAtSlab)
        // a restart forgets the slab
        var e = MainScreenCue()
        _ = run(&e, from: 0, to: 1, locked: false, distance: 1.0, angle: 45)
        e.reset()
        XCTAssertEqual(run(&e, from: 1.1, to: 3.5, locked: false).last?.1, MainScreenCue.pointAtSlab)
        // with no memory: the old behaviour
        var f = MainScreenCue(); f.slabMemorySeconds = 0
        _ = run(&f, from: 0, to: 2.5, locked: false, distance: 1.0, angle: 45)
        XCTAssertEqual(f.update(time: 2.6, locked: false, settling: false, slabDistance: nil, viewAngleDegrees: nil, events: []), MainScreenCue.pointAtSlab)
        // locked: the memory plays no part (the lock always has its distance)
        var g = MainScreenCue()
        _ = run(&g, from: 0, to: 2, locked: true, settling: true, distance: 0.9, angle: 45)
        XCTAssertEqual(g.update(time: 2.1, locked: true, settling: true, slabDistance: 0.9, viewAngleDegrees: 45, events: []), MainScreenCue.moveSlowly)
    }

    func testSettlingLongerThanOneAndAHalfSecondsGivesTheReason() {
        func reason(distance: Double, angle: Double) -> String? {
            var c = MainScreenCue()
            let a = run(&c, from: 0, to: 2, locked: true, settling: true, distance: distance, angle: angle)
            XCTAssertTrue(a.filter { $0.0 <= 1.5 }.allSatisfy { $0.1 == nil }, "nothing for the first 1.5 s")
            return a.last?.1
        }
        // far, the phone about 0.86 m over the slab: "Step closer"
        XCTAssertEqual(reason(distance: 1.5, angle: 55), MainScreenCue.stepCloser)
        // far, the phone high over the slab (1.6 m at 35 deg: 1.31 m up, chest height; 1.5 m at 45 deg: 1.06 m up):
        // "Lower the phone", since stepping closer never brings it within 1.25 m
        XCTAssertEqual(reason(distance: 1.6, angle: 35), MainScreenCue.lowerPhone)
        XCTAssertEqual(reason(distance: 1.5, angle: 45), MainScreenCue.lowerPhone)
        // standing at chest height (1.3 m up) right over the slab, or 4 ft back: never "Step closer"
        for back in [0.0, 0.3, 0.6, 0.9, 1.2, 1.5] {
            let d = (1.3 * 1.3 + back * back).squareRoot(), a = atan2(back, 1.3) * 180 / .pi
            XCTAssertEqual(reason(distance: d, angle: a), MainScreenCue.lowerPhone, "\(back) m back at chest height")
        }
        // crouching (0.46 m up, 0.56 m back, n14's pose that settled): no far cue
        XCTAssertEqual(reason(distance: 0.726, angle: 50.5), MainScreenCue.moveSlowly)
        XCTAssertEqual(reason(distance: 1.0, angle: 65), MainScreenCue.holdHigher)
        XCTAssertEqual(reason(distance: 0.8, angle: 18), MainScreenCue.lowerPhone)
        XCTAssertEqual(reason(distance: 0.9, angle: 45), MainScreenCue.moveSlowly)
        // never "settling" alone for more than 1.5 s: every settling frame after it has a cue
        var c = MainScreenCue()
        let a = run(&c, from: 0, to: 10, locked: true, settling: true, distance: 1.1, angle: 40)
        XCTAssertTrue(a.filter { $0.0 > 1.6 }.allSatisfy { $0.1 != nil })
        // settled: gone at once
        XCTAssertNil(c.update(time: 10.1, locked: true, settling: false, slabDistance: 1.1, viewAngleDegrees: 40, events: []))
    }

    func testABallTapThatSetsNothingSaysHoldTheBallOverTheSlabForTwoSeconds() {
        var c = MainScreenCue()
        let a = run(&c, from: 0, to: 3, locked: true, settling: false, distance: 1, angle: 45, events: ["tap-ball-set-none"])
        XCTAssertTrue(a.filter { $0.0 <= 2.0 }.allSatisfy { $0.1 == MainScreenCue.ballOverSlab })
        XCTAssertEqual(MainScreenCue.ballOverSlab, "Hold the ball over the slab")
        XCTAssertTrue(a.filter { $0.0 > 2.05 }.allSatisfy { $0.1 == nil })
    }

    func testTheClockGoingBackStartsOver() {
        var c = MainScreenCue()
        _ = run(&c, from: 100, to: 103, locked: false)
        XCTAssertNil(c.update(time: 0, locked: false, settling: false, slabDistance: nil, viewAngleDegrees: nil, events: []))
    }

    func testTheViewAngle() {
        let s = World.slabAt(Vec3(0, 0, -1), tilt: 0, heading: 0)
        XCTAssertEqual(MainScreenCue.viewAngleDegrees(slab: s, camera: s.center + Vec3(0, 1, 0))!, 0, accuracy: 1e-6)
        XCTAssertEqual(MainScreenCue.viewAngleDegrees(slab: s, camera: s.center + Vec3(0, 1, 1))!, 45, accuracy: 1e-6)
        // a slab being confirmed: its centre and world up
        XCTAssertEqual(MainScreenCue.viewAngleDegrees(center: s.center, normal: -ARKitConvention.worldDown, camera: s.center + Vec3(0, 1, 1))!,
                       45, accuracy: 1e-6)
    }

    // MARK: the ball tap's reach

    let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
    let up = Vec3(0, 1, 0)
    let image = ColorFrame(gray: Plane(width: 8, height: 6))
    let cam = Vec3(0.05, 0.9, 0)

    func settings() -> TrackerSettings {
        var s = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        s.spec = .standard
        s.tapSetsBall = true
        return s
    }

    @discardableResult
    func step(_ tr: SlabTracker, _ det: SceneDetector, _ balls: ScriptedBalls?, _ v: CameraView, _ t: Double, tap: Vec2? = nil) -> TrackerOutput {
        det.currentView = v; balls?.view = v
        let ballDue = tr.ballDue(at: t)
        return tr.process(TrackerFrame(timestamp: t, view: v, frame: image, depth: nil, depthIntrinsics: nil,
                                       ballImage: ballDue ? Plane(width: v.intrinsics.width, height: v.intrinsics.height) : nil,
                                       ballIntrinsics: ballDue ? v.intrinsics : nil, tap: tap))
    }

    func lockedTracker(balls: ScriptedBalls) -> (SlabTracker, SceneDetector, CameraView, Int) {
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let tr = SlabTracker(settings: settings(), detector: det, ballLocator: balls)
        let v = w.view(from: cam, at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        return (tr, det, v, k)
    }

    /// Screen points on the owner's phone -> pixels of an image whose shorter side is `short` pixels.
    func pixels(points: Double, short: Int) -> Double { points / TapSetBall.shortSidePoints * Double(short) }

    func testTheReachIsAFortyFourPointFingertip() {
        XCTAssertEqual(TapSetBall.reach(width: 1920, height: 1440), 96.66, accuracy: 0.05)
        XCTAssertEqual(TapSetBall.reach(width: 480, height: 360), 24.17, accuracy: 0.05)
    }

    /// A tap `points` off the ball (on the owner's screen), the finder finding the ball where it is: accepted or set.
    func tapOff(points: Double, direction: Vec2) -> (accepted: Bool, set: Bool, kind: TrackerTapKind?) {
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.30 - slab.axisV * 0.04
        let short = min(v.intrinsics.width, v.intrinsics.height)
        let tap = v.project(world: B)! + direction.normalized * pixels(points: points, short: short)
        let t0 = Double(k) / 60
        let o = step(tr, det, balls, v, t0, tap: tap); k += 1
        balls.balls = [B]
        var accepted = false, set = false
        for _ in 0..<30 {
            let out = step(tr, det, balls, v, Double(k) / 60); k += 1
            if out.events.contains("tap-ball-accepted") { accepted = true }
            if out.events.contains("tap-ball-set") { set = true }
        }
        return (accepted, set, o.tap?.kind)
    }

    func testATapTenTwentyFiveAndFortyPointsOffTheBallStillAcceptsIt() {
        for pts in [10.0, 25.0, 40.0] {
            for dir in [Vec2(0, -1), Vec2(1, 0), Vec2(-1, 0)] {
                let r = tapOff(points: pts, direction: dir)
                XCTAssertEqual(r.kind, .ball, "\(pts) pt \(dir): a ball tap")
                XCTAssertTrue(r.accepted, "\(pts) pt \(dir): the ball is accepted")
                XCTAssertFalse(r.set, "\(pts) pt \(dir): nothing set at the tap")
            }
        }
    }

    func testATapFarFromTheBallSetsItAtTheTap() {
        // 90 pt beside the ball: not the ball tapped; the ball is set at the tap
        let r = tapOff(points: 90, direction: Vec2(0, -1))
        XCTAssertEqual(r.kind, .ball)
        XCTAssertFalse(r.accepted)
        XCTAssertTrue(r.set)
    }

    func testUnderTheFingerIsAtLeastFourRadii() {
        let o = Vec3.zero, d = Vec3(0, 0, -1), ball = BallSpec(diameter: 0.03)
        // a ball 0.5 m away, 3.5 radii off the line (as an angle), no slack: under the finger; 4.5 radii: not
        let a = asin(ball.radius / 0.5)
        func at(_ k: Double) -> Vec3 { Vec3(sin(k * a), 0, -cos(k * a)) * 0.5 }
        XCTAssertTrue(TapSetBall.underFinger(at(3.5), origin: o, direction: d, slack: 0, ball: ball))
        XCTAssertFalse(TapSetBall.underFinger(at(4.5), origin: o, direction: d, slack: 0, ball: ball))
    }
}
