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
        // the slab being confirmed is far
        XCTAssertEqual(c.update(time: 3.1, locked: false, settling: false, slabDistance: 1.6, viewAngleDegrees: nil, events: []), MainScreenCue.stepCloser)
        XCTAssertEqual(c.update(time: 3.2, locked: false, settling: false, slabDistance: 1.0, viewAngleDegrees: nil, events: []), MainScreenCue.pointAtSlab)
        // locked and settled: nothing
        XCTAssertNil(c.update(time: 3.3, locked: true, settling: false, slabDistance: 1.0, viewAngleDegrees: 45, events: []))
    }

    func testSettlingLongerThanOneAndAHalfSecondsGivesTheReason() {
        func reason(distance: Double, angle: Double) -> String? {
            var c = MainScreenCue()
            let a = run(&c, from: 0, to: 2, locked: true, settling: true, distance: distance, angle: angle)
            XCTAssertTrue(a.filter { $0.0 <= 1.5 }.allSatisfy { $0.1 == nil }, "nothing for the first 1.5 s")
            return a.last?.1
        }
        XCTAssertEqual(reason(distance: 1.5, angle: 45), MainScreenCue.stepCloser)
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

    func testABallTapThatSetsNothingSaysTapTheBallForTwoSeconds() {
        var c = MainScreenCue()
        let a = run(&c, from: 0, to: 3, locked: true, settling: false, distance: 1, angle: 45, events: ["tap-ball-set-none"])
        XCTAssertTrue(a.filter { $0.0 <= 2.0 }.allSatisfy { $0.1 == MainScreenCue.tapTheBall })
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
