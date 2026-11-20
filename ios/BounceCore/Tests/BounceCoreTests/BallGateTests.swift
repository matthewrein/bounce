import XCTest
@testable import BounceCore

/// The ball gate (n15, `BallGate`, `TrackerSettings.ballGate`): a ball is shown only once it has been found three times in
/// one place over the slab's top, at a drop height, and not where LiDAR sees a surface; older settings have no gate.
final class BallGateTests: XCTestCase {
    /// A level 7 in slab 1 m in front of a camera 0.6 m above it (world y up), the 30 mm ball.
    let slab = World.slabAt(Vec3(0, 0.03, -1.0), tilt: 0, heading: 0, yaw: 0)
    let spec = SlabSpec.standard
    let ball = BallSpec(diameter: 0.03, rebound: 0.81)
    let camera = Vec3(0, 0.6, -0.2)
    let down = ARKitConvention.worldDown

    /// a point `h` (m) above the top's centre (its bottom h - radius over the face), moved by `offset`
    func above(_ h: Double, _ offset: Vec3 = Vec3(0, 0, 0)) -> Vec3 { slab.center + Vec3(0, h, 0) + offset }

    func gate() -> BallGate { BallGate(settings: BallGateSettings()) }

    /// One search at time t.
    func step(_ g: inout BallGate, _ t: Double, _ c: Vec3?, heldOver: Bool = false, lidar: Double? = nil) -> BallGate.Verdict {
        g.update(time: t, center: c, heldOver: heldOver, slab: slab, spec: spec, ball: ball, down: down, camera: camera, lidarExcess: lidar)
    }

    /// A single find, its finder's hold-overs, then nothing: never shown.
    func testASingleFindNeverShows() {
        var g = gate()
        XCTAssertEqual(step(&g, 0, above(0.4)), .waiting)
        XCTAssertEqual(step(&g, 0.1, above(0.4), heldOver: true), .notShownHeldOver)
        XCTAssertEqual(step(&g, 0.2, above(0.4), heldOver: true), .notShownHeldOver)
        for k in 3..<20 { XCTAssertEqual(step(&g, Double(k) * 0.1, nil), .none) }
        XCTAssertFalse(g.showing)
        // a find every half second (each alone in the window) is never three
        var h = gate()
        for k in 0..<10 { XCTAssertFalse(step(&h, Double(k) * 0.55, above(0.4)).shows) }
    }

    /// A find that moves on by 8 mm a search across the line of sight (a print on the floor seen from a walking phone, a
    /// passing hand), or that hops between places 2 cm apart (back at each only after the window), never shows; one that
    /// moves 2 mm a search (a held ball's jitter) shows on its third find.
    func testAWanderingFindNeverShows() {
        var g = gate()
        for k in 0..<20 { XCTAssertFalse(step(&g, Double(k) * 0.1, above(0.4, Vec3(0.008 * Double(k), 0, 0))).shows, "find \(k)") }
        var j = gate()
        for k in 0..<20 { XCTAssertFalse(step(&j, Double(k) * 0.1, above(0.4, Vec3(0.02 * Double(k % 7), 0, 0))).shows, "find \(k)") }
        var s = gate()
        let v = (0..<5).map { step(&s, Double($0) * 0.1, above(0.4, Vec3(0.002 * Double($0 % 2), 0.001 * Double($0 % 3), 0))) }
        XCTAssertEqual(v, [.waiting, .waiting, .accepted, .kept, .kept])
    }

    /// A ball held still shows on its third find (finds a tenth of a second apart, jitter within the measured 4 mm, and
    /// its range off by up to 4% along the line of sight); the finder's hold-over of it is shown; not found for longer than
    /// `keepSeconds`, it must be found three times again; a find elsewhere ends it at once.
    func testAHeldBallShowsOnItsThirdFind() {
        var g = gate()
        let los = (above(0.4) - camera).normalized
        let jitter: [Vec3] = [Vec3(0, 0, 0), Vec3(0.003, -0.002, 0), los * 0.025, Vec3(-0.002, 0.002, 0.001), los * -0.02]
        let v = jitter.enumerated().map { step(&g, Double($0.offset) * 0.1, above(0.4) + $0.element) }
        XCTAssertEqual(v, [.waiting, .waiting, .accepted, .kept, .kept])
        XCTAssertTrue(g.showing)
        XCTAssertEqual(step(&g, 0.5, above(0.4), heldOver: true), .heldOver)
        XCTAssertEqual(step(&g, 0.6, nil), .none)
        XCTAssertEqual(step(&g, 0.7, above(0.4)), .kept, "found again within keepSeconds")
        // a gap: not seen for 0.6 s (> keepSeconds 0.35, and the window's 0.5 s): three finds again
        XCTAssertEqual(step(&g, 1.3, above(0.4)), .waiting)
        XCTAssertEqual(step(&g, 1.4, above(0.4)), .waiting)
        XCTAssertEqual(step(&g, 1.5, above(0.4)), .accepted)
        // a find 5 cm away: the shown ball is not where it was; nothing shown until that place is found three times
        XCTAssertEqual(step(&g, 1.6, above(0.4, Vec3(0.05, 0, 0))), .waiting)
        XCTAssertFalse(g.showing)
        XCTAssertEqual(step(&g, 1.7, above(0.4, Vec3(0.05, 0, 0))), .waiting)
        XCTAssertEqual(step(&g, 1.8, above(0.4, Vec3(0.05, 0, 0))), .accepted)
        // a ball missed for a moment (a gap under keepSeconds) whose earlier finds are still in the window: three finds
        // within 0.5 s are three finds
        var m = gate()
        XCTAssertEqual([0, 0.1, 0.45].map { step(&m, $0, above(0.4)) }, [.waiting, .waiting, .accepted])
        // after the idle rate (0.3 s), the finder is back at 0.1 s once it finds something: three finds in 0.5 s
        var i = gate()
        XCTAssertEqual([0, 0.1, 0.2].map { step(&i, 5 + $0, above(0.3)) }, [.waiting, .waiting, .accepted])
    }

    /// Something at or under the slab's surface, or not over its top, or too high, is never shown however often it is
    /// found in one place.
    func testBelowBesideOrAboveTheRangeNeverShows() {
        let places: [(Vec3, BallGate.Verdict, String)] = [
            (above(0.03), .tooLow, "the ball's bottom 1.5 cm over the top (under the 5 cm drop)"),
            (above(0.015), .tooLow, "resting on the slab"),
            (above(-0.05), .tooLow, "under the top's surface (a print on the floor read as a ball there)"),
            (above(0.4, Vec3(slab.halfU + 0.03, 0, 0)), .offTop, "3 cm beside the top"),
            (above(0.4, Vec3(0, 0, slab.halfV + 0.05)), .offTop, "5 cm beyond the far edge"),
            (above(2.5), .tooHigh, "2.5 m up"),
        ]
        for (p, why, what) in places {
            var g = gate()
            for k in 0..<12 { XCTAssertEqual(step(&g, Double(k) * 0.1, p), why, what) }
            XCTAssertFalse(g.showing, what)
        }
        // the top's edge with the margin: 5 mm beyond it still counts, 2 cm does not
        var e = gate()
        XCTAssertTrue((0..<3).map { step(&e, Double($0) * 0.1, above(0.3, Vec3(slab.halfU + 0.005, 0, 0))) }.contains(.accepted))
    }

    /// LiDAR: where it resolves the ball, a depth well beyond the ball's centre is a surface (a print, the floor), never
    /// shown, and that place is not taken for the ball for `lidarMemorySeconds` even on frames without depth; a depth at
    /// the ball (the held ball, the hand) is no objection. Off (nil), LiDAR is not read.
    func testLidarSurfaceNeverShows() {
        var g = gate()
        XCTAssertEqual(step(&g, 0, above(0.4), lidar: 0.9), .surface)
        XCTAssertEqual(step(&g, 0.1, above(0.4)), .surface, "remembered")
        XCTAssertEqual(step(&g, 0.2, above(0.4)), .surface)
        XCTAssertEqual(step(&g, 0.5, above(0.4)), .surface)
        XCTAssertFalse(g.showing)
        // after the memory, three finds again
        XCTAssertEqual([1.1, 1.2, 1.3].map { step(&g, $0, above(0.4)) }, [.waiting, .waiting, .accepted])
        // a shown ball that LiDAR then reads as a surface is hidden at once
        XCTAssertEqual(step(&g, 1.4, above(0.4), lidar: 0.5), .surface)
        XCTAssertFalse(g.showing)
        // the held ball: LiDAR reads it (and the hand) within a few cm of its centre
        var h = gate()
        XCTAssertEqual([0, 0.1, 0.2, 0.3].map { step(&h, $0, above(0.4), lidar: [-0.05, 0.05, 0.02, -0.01][Int($0 * 10 + 0.5)]) },
                       [.waiting, .waiting, .accepted, .kept])
        var off = BallGateSettings(); off.lidarSurfaceMetres = nil
        var o = BallGate(settings: off)
        XCTAssertEqual([0, 0.1, 0.2].map { o.update(time: $0, center: above(0.4), heldOver: false, slab: slab, spec: spec, ball: ball, down: down,
                                                    camera: camera, lidarExcess: 2) }, [.waiting, .waiting, .accepted])
    }

    /// One stray LiDAR reading behind a held, shown ball (depth that mixed in the background) hides it for that search,
    /// not for `lidarMemorySeconds`: the readings after it, at the ball, overrule it, and the ball is shown again on its
    /// third find. The memory stands in only for searches without a reading, and a reading at the ball clears it.
    func testOneStrayLidarReadingDoesNotHideAHeldBallForLong() {
        var g = gate()
        let readings: [Double?] = [0.01, -0.02, 0.0, 0.2, 0.01, -0.01, 0.02, 0.0, 0.01]
        let v = readings.enumerated().map { step(&g, Double($0.offset) * 0.1, above(0.4), lidar: $0.element) }
        XCTAssertEqual(v, [.waiting, .waiting, .accepted, .surface, .waiting, .waiting, .accepted, .kept, .kept])
        // a surface reading, then a reading at the ball there: later searches without depth are not refused
        var h = gate()
        XCTAssertEqual(step(&h, 0, above(0.4), lidar: 0.9), .surface)
        XCTAssertEqual(step(&h, 0.1, above(0.4), lidar: -0.01), .waiting)
        XCTAssertEqual([0.2, 0.3].map { step(&h, $0, above(0.4)) }, [.waiting, .accepted])
        // the floor or a print really there reads as a surface on every search with depth: never shown
        var p = gate()
        for k in 0..<15 { XCTAssertEqual(step(&p, Double(k) * 0.1, above(0.4), lidar: k % 3 == 0 ? 0.8 : nil), .surface, "search \(k)") }
        XCTAssertFalse(p.showing)
    }

    /// A shown ball that the finder then finds beside the top, too low or too high is no longer shown, and the finder's
    /// hold-over of that find is not shown either; a hold-over away from the shown ball is not shown.
    func testARefusedFindEndsTheShownBallAndItsHoldOver() {
        let refused: [(Vec3, BallGate.Verdict)] = [(above(0.4, Vec3(slab.halfU + 0.05, 0, 0)), .offTop), (above(0.035), .tooLow),
                                                   (above(2.5), .tooHigh)]
        for (p, why) in refused {
            var g = gate()
            XCTAssertEqual([0, 0.1, 0.2].map { step(&g, $0, above(0.4)) }, [.waiting, .waiting, .accepted])
            XCTAssertEqual(step(&g, 0.3, p), why)
            XCTAssertFalse(g.showing, "\(why)")
            XCTAssertEqual(step(&g, 0.4, p, heldOver: true), .notShownHeldOver, "\(why)")
        }
        var h = gate()
        XCTAssertEqual([0, 0.1, 0.2].map { step(&h, $0, above(0.4)) }, [.waiting, .waiting, .accepted])
        XCTAssertEqual(step(&h, 0.3, above(0.4, Vec3(0.04, 0, 0)), heldOver: true), .notShownHeldOver)
        XCTAssertEqual(step(&h, 0.4, above(0.4), heldOver: true), .heldOver)
    }

    /// The tolerance along the line of sight follows the ball's own size: a few pixels of radius are a larger share of a
    /// small ball's image than of a large one's.
    func testAgreementAlongTheLineOfSightFollowsTheBallsSize() {
        let s = BallGateSettings()
        let b = above(0.4), range = (b - camera).length, los = (b - camera) / range
        // 30 mm ball: max(6%, 0.00195 * range / 0.015); 50 mm: max(6%, 0.00195 * range / 0.025)
        let small = max(s.alongFraction, s.radiusNoiseRadians * range / 0.015), large = max(s.alongFraction, s.radiusNoiseRadians * range / 0.025)
        XCTAssertGreaterThan(small, large + 0.02)
        let share = (small + large) / 2
        let a = BallGate.Sighting(time: 0, center: b, camera: camera), x = BallGate.Sighting(time: 0.1, center: b + los * (share * range), camera: camera)
        XCTAssertTrue(BallGate.agree(a, x, s, radius: 0.015))
        XCTAssertFalse(BallGate.agree(a, x, s, radius: 0.025))
    }

    /// LiDAR around a ball: the median depth within half its radius less the centre's depth, only where the map resolves
    /// the ball (its radius at least `lidarMinRadiusPixels` of the map's pixels).
    func testLidarExcessReadsTheMapNearTheBall() throws {
        let K = CameraIntrinsics(fx: 180, fy: 180, cx: 128, cy: 96, width: 256, height: 192)
        var d = [Float](repeating: 1.5, count: 256 * 192)
        let B = Vec3(0.02, -0.01, 0.45)            // 6 depth pixels in radius
        let p = try XCTUnwrap(K.project(B))
        for y in 0..<192 { for x in 0..<256 where Vec2(Double(x) + 0.5, Double(y) + 0.5).distance(to: p) < 6 { d[y * 256 + x] = 0.44 } }
        let map = DepthMap(width: 256, height: 192, depth: d, confidence: [UInt8](repeating: 2, count: 256 * 192))
        let floor = DepthMap(width: 256, height: 192, depth: [Float](repeating: 1.5, count: 256 * 192), confidence: [UInt8](repeating: 2, count: 256 * 192))
        XCTAssertEqual(try XCTUnwrap(BallGate.lidarExcess(depth: map, intrinsics: K, ballCenter: B, ballRadius: 0.015, minRadiusPixels: 5)), -0.01, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(BallGate.lidarExcess(depth: floor, intrinsics: K, ballCenter: B, ballRadius: 0.015, minRadiusPixels: 5)), 1.05, accuracy: 1e-6)
        // too far for the map to resolve it (radius 2 px), behind the camera, out of the map
        XCTAssertNil(BallGate.lidarExcess(depth: floor, intrinsics: K, ballCenter: Vec3(0, 0, 1.35), ballRadius: 0.015, minRadiusPixels: 5))
        XCTAssertNil(BallGate.lidarExcess(depth: floor, intrinsics: K, ballCenter: Vec3(0, 0, -0.4), ballRadius: 0.015, minRadiusPixels: 5))
        XCTAssertNil(BallGate.lidarExcess(depth: floor, intrinsics: K, ballCenter: Vec3(2, 0, 0.4), ballRadius: 0.015, minRadiusPixels: 5))
    }

    /// Settings: older files (no "ballGate") read as no gate, so they replay as the phone ran them; the app's settings
    /// turn it on with the gate's own values; every gate setting is written and read back, and a gate written without
    /// some keys keeps their defaults.
    func testOlderSettingsReadAsNoGateAndTheAppTurnsItOn() throws {
        XCTAssertNil(TrackerSettings().ballGate)
        XCTAssertNil(try JSONDecoder().decode(TrackerSettings.self, from: Data(#"{"ballInterval": 0.1, "idleBallAfter": 0.5}"#.utf8)).ballGate)
        let app = RecordingSettings().trackerSettings
        XCTAssertEqual(app.ballGate, BallGateSettings())
        XCTAssertEqual(try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app)).ballGate, BallGateSettings())
        let props = Set(Mirror(reflecting: BallGateSettings()).children.compactMap { $0.label })
        XCTAssertEqual(Set(BallGateSettings.codingFields.map { $0.key }), props)
        XCTAssertEqual(BallGateSettings.codingFields.count, props.count)
        var s = BallGateSettings()
        s.sightings = 4; s.window = 0.6; s.acrossMetres = 0.01; s.alongFraction = 0.1; s.radiusNoiseRadians = 0.003; s.minHeight = 0.08
        s.maxHeight = 1.2; s.topMargin = 0; s.keepSeconds = 0.5; s.lidarSurfaceMetres = 0.3; s.lidarMinRadiusPixels = 4; s.lidarMemorySeconds = 2
        for c in Mirror(reflecting: s).children {
            let d = Mirror(reflecting: BallGateSettings()).children.first { $0.label == c.label }!
            XCTAssertNotEqual(String(describing: c.value), String(describing: d.value), "test changes \(c.label!)")
        }
        XCTAssertEqual(try JSONDecoder().decode(BallGateSettings.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(try JSONDecoder().decode(BallGateSettings.self, from: Data("{}".utf8)), BallGateSettings())
        XCTAssertNil(try JSONDecoder().decode(BallGateSettings.self, from: Data(#"{"lidarSurfaceMetres": null}"#.utf8)).lidarSurfaceMetres)
    }

    /// Through the tracker as the app runs it: a ball held over the slab is shown (ring, "ball in view", the drop height)
    /// from the gate's third search, not before; the finder's result held back is reported (`ballFound`) and recorded; one
    /// beside the slab or a single find is never shown. Without a gate (older settings) the first find shows, as before.
    func testTheTrackerShowsOnlyWhatTheGateLetsThrough() throws {
        let w0 = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        func run(_ settings: TrackerSettings, ballAt place: (SlabPose) -> Vec3?, frames: Int = 240) -> [TrackerOutput] {
            let w = World(slab: w0, lens: .processing)
            let det = SceneDetector(w, noise: 0.3, seed: 41), b = KnownBall()
            let tr = SlabTracker(settings: settings, detector: det, ballLocator: b)
            var outs: [TrackerOutput] = []
            for k in 0..<frames {
                let t = Double(k) / 60
                let v = w.view(from: Vec3(0.05 * sin(t), 0.9, 0.03 * cos(t)), at: w.slab.center)
                det.currentView = v; b.view = v; b.now = t
                b.world = tr.state == .locked ? place(w0) : nil
                let due = tr.ballDue(at: t)
                outs.append(tr.process(TrackerFrame(timestamp: t, view: v, frame: ColorFrame(gray: Plane(width: 16, height: 12)),
                                                    ballImage: due ? Plane(width: 30, height: 20) : nil,
                                                    ballIntrinsics: due ? v.intrinsics.scaled(by: 2) : nil, floorY: 0)))
            }
            return outs
        }
        var app = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 35).trackerSettings
        XCTAssertNotNil(app.ballGate)
        let held: (SlabPose) -> Vec3? = { $0.center + Vec3(0.01, 0.4, -0.02) }
        let outs = run(app, ballAt: held)
        let searches = outs.filter { $0.ballSearched && $0.state == .locked }
        XCTAssertGreaterThan(searches.count, 5)
        XCTAssertEqual(searches.prefix(5).map { $0.ballGateVerdict }, [.waiting, .waiting, .accepted, .kept, .kept])
        XCTAssertNil(searches[0].ball); XCTAssertNil(searches[1].ball)
        XCTAssertNotNil(searches[0].ballFound, "held back, reported")
        XCTAssertNotNil(RecordedOutput(searches[1]).ballFound, "and recorded")
        XCTAssertFalse(searches[1].readouts!.dropFromBall, "no drop height from a ball not shown")
        XCTAssertNotNil(searches[2].ball); XCTAssertNil(searches[2].ballFound)
        XCTAssertTrue(searches[2].readouts!.dropFromBall)
        XCTAssertNotNil(outs.last!.ball)
        // beside the slab (5 cm off its top): found every time, never shown
        let beside = run(app, ballAt: { $0.point(u: $0.halfU + 0.05, v: 0) + $0.normal * 0.3 })
        XCTAssertTrue(beside.filter { $0.ballSearched && $0.state == .locked }.allSatisfy { $0.ballFound != nil && $0.ballGateVerdict == .offTop })
        XCTAssertTrue(beside.allSatisfy { $0.ball == nil })
        // no gate: the first find shows, and nothing is held back
        app.ballGate = nil
        let old = run(app, ballAt: held).filter { $0.ballSearched && $0.state == .locked }
        XCTAssertNotNil(old.first?.ball)
        XCTAssertTrue(old.allSatisfy { $0.ballGateVerdict == nil && $0.ballFound == nil })
    }
}
