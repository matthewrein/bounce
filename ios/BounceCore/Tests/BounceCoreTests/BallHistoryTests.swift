import XCTest
@testable import BounceCore

/// The ball's history in Copy diagnostics (n16: `SlabTracker.ballLog`, `DiagnosticsReport.ballHistory`): what the ball
/// gate made of the finder's finds (waiting, accepted, kept, refused and why), the ring going, and what taps did with the
/// ball (set, cleared), each with its centre, its height over the slab's top and its circle in the full image's pixels;
/// runs of one verdict kept as one entry, at most 20 entries; written and read back, and older reports read without it.
final class BallHistoryTests: XCTestCase {
    let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
    let up = Vec3(0, 1, 0)
    let image = ColorFrame(gray: Plane(width: 8, height: 6))

    @discardableResult
    func step(_ tr: SlabTracker, _ det: SceneDetector, _ balls: ScriptedBalls, _ v: CameraView, _ t: Double, tap: Vec2? = nil) -> TrackerOutput {
        det.currentView = v; balls.view = v
        let ballDue = tr.ballDue(at: t)
        return tr.process(TrackerFrame(timestamp: t, view: v, frame: image,
                                       ballImage: ballDue ? Plane(width: v.intrinsics.width, height: v.intrinsics.height) : nil,
                                       ballIntrinsics: ballDue ? v.intrinsics : nil, tap: tap))
    }

    func testTheGatesVerdictsAndTheTapsAreLoggedWrittenAndReadBack() throws {
        var settings = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        settings.spec = .standard
        XCTAssertNotNil(settings.ballGate); XCTAssertTrue(settings.tapSetsBall)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let balls = ScriptedBalls()
        let tr = SlabTracker(settings: settings, detector: det, ballLocator: balls)
        let v = w.view(from: Vec3(0.05, 0.9, 0), at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        XCTAssertTrue(tr.ballLog.isEmpty, "nothing found yet: nothing logged")

        // a ball held over the slab's middle: waiting twice, accepted on the third find, then kept (one entry for the run)
        let B = slab.center + up * 0.30
        balls.balls = [B]
        for _ in 0..<60 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.ballLog.map { $0.event }, ["waiting", "accepted", "kept"])
        XCTAssertEqual(tr.ballLog[0].count, 2)
        XCTAssertNotNil(tr.ballLog[0].until)
        XCTAssertGreaterThan(tr.ballLog[2].count, 3)
        let acc = tr.ballLog[1]
        XCTAssertEqual(acc.source, "finder")
        XCTAssertEqual(acc.center?.distance(to: B) ?? 1, 0, accuracy: 1e-9)
        // the ball's bottom over the top face of the lock (within the lock's few millimetres of the true slab)
        XCTAssertEqual(acc.heightOverTop ?? 0, 0.30 - settings.ball.radius, accuracy: 0.005, "the ball's bottom over the top face")
        // the finder loses it: the ring goes
        balls.balls = []
        for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.ballLog.last?.event, "gone")
        // something beside the slab: refused, and why
        balls.balls = [slab.center + slab.axisU * 0.3 + up * 0.3]
        for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.ballLog.last?.event, "refused")
        XCTAssertEqual(tr.ballLog.last?.why, "offTop")
        XCTAssertGreaterThan(tr.ballLog.last?.count ?? 0, 1, "one entry for the run")
        // a tap over the slab where the finder finds nothing sets the ball (on the plane: no LiDAR), and a tap on it clears it
        balls.balls = []
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let S = slab.center + up * 0.28
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: S)!); k += 1
        for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let set = try XCTUnwrap(tr.ballLog.last)
        XCTAssertEqual(set.event, "set"); XCTAssertEqual(set.why, "plane"); XCTAssertEqual(set.source, "set")
        XCTAssertEqual(set.center?.distance(to: tr.setBall!.center) ?? 1, 0, accuracy: 1e-9)
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: tr.setBall!.center)!); k += 1
        XCTAssertEqual(tr.ballLog.last?.event, "cleared")

        // the report: circles in the full image's pixels (here 4 times the processing frame), written and read back
        let full = CameraIntrinsics(fx: v.intrinsics.fx * 4, fy: v.intrinsics.fy * 4, cx: v.intrinsics.cx * 4, cy: v.intrinsics.cy * 4,
                                    width: v.intrinsics.width * 4, height: v.intrinsics.height * 4)
        var rep = DiagnosticsReport(build: "t", device: "d", system: "s", time: "now", settings: RecordingSettings(), state: "locked", tracking: "normal",
                                    fps: 60, msProcess: 1, lens: full, depthSupported: false, depth: nil, captureLocked: false, slab: tr.slab, outline: nil,
                                    sideModes: [], ball: nil, readouts: nil, counts: tr.counts, recentEvents: [], recording: nil)
        rep.addTracker(tr, view: v, lens: full)
        let h = try XCTUnwrap(rep.ballHistory)
        XCTAssertEqual(h.map { $0.event }, tr.ballLog.map { $0.event })
        let a = h[1]
        XCTAssertEqual(a.event, "accepted")
        XCTAssertNil(a.count, "a single event has no count")
        XCTAssertEqual(h[0].count, 2)
        let c = try XCTUnwrap(a.circle)
        let p = full.project(v.toCamera(B))!, r = Bounce.imageRadius(ballCenter: v.toCamera(B), intrinsics: full, ball: settings.ball)!
        XCTAssertEqual(c[0], p.x, accuracy: 0.01); XCTAssertEqual(c[1], p.y, accuracy: 0.01); XCTAssertEqual(c[2], r, accuracy: 0.01)
        XCTAssertEqual(a.center ?? [], B.array.map { ($0 * 10000).rounded() / 10000 })
        XCTAssertNotNil(rep.frames?["ballHistory"])
        let back = try DiagnosticsReport.decode(json: rep.json())
        XCTAssertEqual(back.ballHistory, rep.ballHistory)
        XCTAssertEqual(back.counts, rep.counts)
        // an older report (no ballHistory) reads back as before, without it (the rest as written: the same JSON)
        var json = try JSONSerialization.jsonObject(with: Data(rep.json().utf8)) as! [String: Any]
        XCTAssertNotNil(json.removeValue(forKey: "ballHistory"))
        let old = try DiagnosticsReport.decode(json: String(data: JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
        XCTAssertNil(old.ballHistory)
        XCTAssertEqual(old.counts, back.counts); XCTAssertEqual(old.build, back.build); XCTAssertEqual(old.taps?.log, back.taps?.log)
        XCTAssertEqual(old.history, back.history)
        // without a lens the circles are left out (not given in another image's pixels)
        var bare = DiagnosticsReport(build: "t", device: "d", system: "s", time: "now", settings: RecordingSettings(), state: "locked", tracking: "normal",
                                     fps: 60, msProcess: 1, lens: nil, depthSupported: false, depth: nil, captureLocked: false, slab: tr.slab, outline: nil,
                                     sideModes: [], ball: nil, readouts: nil, counts: tr.counts, recentEvents: [], recording: nil)
        bare.addTracker(tr, view: v)
        XCTAssertNil(bare.ballHistory?[1].circle)
        XCTAssertEqual(bare.ballHistory?[1].center, a.center)
    }

    func testAtMostTwentyEntriesTheLatestKept() {
        var settings = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        settings.spec = .standard
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let balls = ScriptedBalls()
        let tr = SlabTracker(settings: settings, detector: det, ballLocator: balls)
        let v = w.view(from: Vec3(0.05, 0.9, 0), at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        // a ball that comes and goes: waiting, accepted, kept, gone, over and over
        for i in 0..<12 {
            balls.balls = [slab.center + up * (0.2 + 0.02 * Double(i))]
            for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
            balls.balls = []
            for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        }
        XCTAssertEqual(tr.ballLog.count, SlabTracker.ballLogSize)
        XCTAssertEqual(tr.ballLog.last?.event, "gone")
        XCTAssertEqual(tr.ballLog.dropLast().last?.event, "kept")
        XCTAssertEqual(tr.ballLog.last(where: { $0.event == "accepted" })?.heightOverTop ?? 0, 0.2 + 0.22 - settings.ball.radius, accuracy: 0.005)
        XCTAssertTrue(zip(tr.ballLog, tr.ballLog.dropFirst()).allSatisfy { $0.time <= $1.time }, "oldest first")
    }

    func testWithoutTheGateEveryFindIsFound() {
        var settings = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        settings.spec = .standard
        settings.ballGate = nil
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let balls = ScriptedBalls()
        let tr = SlabTracker(settings: settings, detector: det, ballLocator: balls)
        let v = w.view(from: Vec3(0.05, 0.9, 0), at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        balls.balls = [slab.center + up * 0.3]
        for _ in 0..<30 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        balls.balls = []
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.ballLog.map { $0.event }, ["found", "gone"])
        XCTAssertGreaterThan(tr.ballLog[0].count, 2)
        XCTAssertNil(tr.ballLog[0].lidar)
    }
}
