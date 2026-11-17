import XCTest
@testable import BounceCore

/// The tracker's newer API: world-frame discontinuities, hints, rejection values, LiDAR fusion state, side modes.
final class TrackerAPITests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    func appSettings() -> TrackerSettings { var s = TrackerSettings(); s.searchInterval = 0.12; return s }

    @discardableResult
    func step(_ t: SlabTracker, _ det: SceneDetector, _ v: CameraView, _ time: Double, depth: (DepthMap, CameraIntrinsics)? = nil,
              normal: Bool = true, tap: Vec2? = nil) -> TrackerOutput {
        det.currentView = v
        return t.process(TrackerFrame(timestamp: time, view: v, frame: blank, depth: depth?.0, depthIntrinsics: depth?.1, tap: tap, trackingNormal: normal))
    }

    func maxDistance(_ a: [Vec2]?, _ b: [Vec2]) -> Double { a.map { zip($0, b).map { $0.distance(to: $1) }.max()! } ?? .infinity }

    func testAReportedDiscontinuityFindsTheSlabAgainOrExpires() {
        // The app reports an interruption / relocalisation (noteWorldDiscontinuity). The world frame has shifted 0.9 m
        // under the lock while the camera's own pose is continuous; the stale lock is partly off screen and a detector
        // that searches only around the prediction finds nothing there. Before, the out-of-view rule kept it forever.
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 201)
        det.nearRadius = 80
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let pos = Vec3(0, 0.9, 0)
        var k = 0
        for _ in 0..<60 { step(tr, det, w.view(from: pos, at: slab.center), Double(k) / 30); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        var moved = slab; moved.center = moved.center + Vec3(0.9, 0, 0.1)
        w.slab = moved; det.world = w
        tr.noteWorldDiscontinuity("interruption ended")
        XCTAssertTrue(tr.detectionDue(at: Double(k) / 30), "the next frame re-checks")
        var events: [String] = [], unconfirmedSeen = false
        var o: TrackerOutput! = nil
        for _ in 0..<(30 * 8) {
            o = step(tr, det, w.view(from: pos, at: moved.center), Double(k) / 30); k += 1
            events += o.events
            unconfirmedSeen = unconfirmedSeen || o.lockUnconfirmed
        }
        XCTAssertTrue(unconfirmedSeen)
        XCTAssertTrue(events.contains { $0.hasPrefix("lock-unconfirmed") }, "\(events)")
        XCTAssertEqual(o.state, .locked)
        XCTAssertFalse(o.lockUnconfirmed)
        XCTAssertLessThan(maxDistance(o.outline, w.corners(in: w.view(from: pos, at: moved.center))), 3)

        // the same, but nothing of the slab is in view afterwards: the unconfirmed lock expires ("lost", so the app
        // releases the camera settings) after unconfirmedTimeout seconds of normal tracking, not counting limited tracking
        let det2 = SceneDetector(World(slab: slab, lens: .processing), noise: 0.5, seed: 202)
        let tr2 = SlabTracker(settings: appSettings(), detector: det2)
        k = 0
        for _ in 0..<60 { step(tr2, det2, w.view(from: pos, at: slab.center), Double(k) / 30); k += 1 }
        XCTAssertEqual(tr2.state, .locked)
        tr2.noteWorldDiscontinuity()
        let away = w.view(from: pos, at: Vec3(-2, 0.5, 0.5))
        for _ in 0..<(30 * 3) { step(tr2, det2, away, Double(k) / 30, normal: false); k += 1 }
        XCTAssertEqual(tr2.state, .locked, "limited tracking does not count")
        var expiredAt: Double? = nil
        let t0 = Double(k) / 30
        for _ in 0..<(30 * 8) {
            let o2 = step(tr2, det2, away, Double(k) / 30); k += 1
            if o2.events.contains("lost") { XCTAssertTrue(o2.events.contains("lock-expired")); expiredAt = Double(k) / 30 - t0; break }
        }
        XCTAssertNotNil(expiredAt)
        XCTAssertEqual(expiredAt ?? 0, TrackerSettings().unconfirmedTimeout, accuracy: 0.2)
        // without a discontinuity, looking away keeps the lock (testLostOnlyWhenTheSlabShouldBeInView)
    }

    func testLongLimitedTrackingMakesTheLockProveItself() {
        // tracking limited for 3 s (e.g. relocalising): when it is normal again the lock must be seen where it should be
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 203)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var k = 0
        for _ in 0..<60 { step(tr, det, v, Double(k) / 30); k += 1 }
        for _ in 0..<(30 * 3) { step(tr, det, v, Double(k) / 30, normal: false); k += 1 }
        var events: [String] = []
        for _ in 0..<30 { events += step(tr, det, v, Double(k) / 30).events; k += 1 }
        XCTAssertTrue(events.contains("lock-unconfirmed: tracking-resumed"), "\(events)")
        XCTAssertTrue(events.contains("lock-confirmed"), "\(events)")
        XCTAssertFalse(tr.lockUnconfirmed)
        XCTAssertEqual(tr.counts["relocks"] ?? 0, 0)
    }

    func testNearOverheadShowsAHint() {
        let slab = World.slabAt(Vec3(0, 0.066, 0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.7, seed: 204)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: slab.center + Vec3(0, 1.2, 0.04), at: slab.center)
        var hint: String? = nil
        for k in 0..<(30 * 4) { if let h = step(tr, det, v, Double(k) / 30).hint { hint = h } }
        XCTAssertEqual(hint, SlabTracker.overheadHint)
        XCTAssertNotEqual(tr.state, .locked)
        XCTAssertGreaterThan(tr.counts["reject:illConditioned"] ?? 0, 0)
        // seen at an angle, no hint and it locks, with its uncertainty reported
        let v2 = w.view(from: slab.center + Vec3(0, 0.8, 0.8), at: slab.center)
        var o: TrackerOutput! = nil
        for k in 120..<(120 + 30 * 4) { o = step(tr, det, v2, Double(k) / 30) }
        XCTAssertEqual(o.state, .locked)
        XCTAssertNil(o.hint)
        XCTAssertLessThan(o.lockSigmaDegrees ?? 99, TrackerSettings().maxLockSigmaDegrees)
    }

    func testRejectionValuesAreSummarisedBesideTheCounters() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let shear = ShearDetector(w)
        var s = appSettings(); s.searchInterval = 0
        let tr = SlabTracker(settings: s, detector: shear)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        for k in 0..<100 { shear.view = v; shear.amount = 20 + Double(k) * 0.1; _ = tr.process(TrackerFrame(timestamp: Double(k) / 30, view: v, frame: blank)) }
        let m = try! XCTUnwrap(tr.rejectionValues["misfit"])
        XCTAssertEqual(m.count, 100)
        XCTAssertLessThan(m.min, m.max)
        XCTAssertGreaterThanOrEqual(m.last, m.min); XCTAssertLessThanOrEqual(m.last, m.max)
        XCTAssertGreaterThan(m.min, ShapeCheck.Limits().maxMisfitFraction)
        // and they reach the diagnostics report, rounded
        let rep = DiagnosticsReport(build: "t", device: "d", system: "s", time: "now", settings: RecordingSettings(), state: "searching",
                                    tracking: "normal", fps: 30, msProcess: 1, lens: nil, depthSupported: false, depth: nil, captureLocked: false,
                                    slab: nil, outline: nil, sideModes: [], ball: nil, readouts: nil, counts: tr.counts, recentEvents: [],
                                    recording: nil, rejectionValues: tr.rejectionValues, cornerNoisePixels: tr.cornerNoiseEstimate,
                                    lockSigmaDegrees: 1.23456)
        let back = try! JSONDecoder().decode(DiagnosticsReport.self, from: Data(rep.json().utf8))
        XCTAssertEqual(back.rejectionValues?["misfit"]?.count, 100)
        XCTAssertEqual(back.cornerNoisePixels, TrackerSettings().cornerNoisePixels)
        XCTAssertEqual(back.lockSigmaDegrees, 1.23)
        XCTAssertEqual(back.counts["reject:misfit"], 100)
        // an older report without the field still decodes
        let old = try! JSONDecoder().decode(DiagnosticsReport.self, from: Data(rep.json().replacingOccurrences(of: "\"rejectionValues\"", with: "\"x\"").utf8))
        XCTAssertNil(old.rejectionValues)
    }

    func testDepthCheckReportsItsInlierShare() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: slab.center)
        var rng = SeededRandom(9)
        let (clean, K) = w.depthMap(v, spec: .standard, rng: &rng)
        let c = PlaneFit.checkSlabTop(depth: clean, depthIntrinsics: K, view: v, slab: slab)!
        XCTAssertGreaterThan(c.inlierFraction!, 0.95)
        // a hand over two thirds of the top: its plane wins, but only part of the points lie on it
        let hand = w.depthMap(v, spec: .standard, occluder: (slab.center + slab.normal * 0.04 + slab.axisU * 0.05, slab.normal, 0.06), rng: &rng)
        let h = PlaneFit.checkSlabTop(depth: hand.0, depthIntrinsics: hand.1, view: v, slab: slab)!
        XCTAssertLessThan(h.inlierFraction!, 0.9)
        XCTAssertEqual(DiagnosticsReport.Depth(c).inlierFraction!, (c.inlierFraction! * 100).rounded() / 100, accuracy: 1e-12)
    }

    func testSideModesAndTheMeasurementFollowThePoseOrder() {
        // The detector reports its outline clockwise on screen (the other way round from the pose) with its side modes;
        // the tracker's lastSideModes and measurement are in the pose's order, like the outline it draws, so the near
        // side's mode stays on the near side.
        let slab = World.slabAt(Vec3(0, 0.066, -0.8), tilt: 4, heading: 30, yaw: 5)
        let w = World(slab: slab, lens: .processing)
        let det = ReversedModesDetector(w)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.7, 0), at: slab.center)
        var o: TrackerOutput! = nil
        for k in 0..<12 { det.view = v; o = tr.process(TrackerFrame(timestamp: Double(k) * 0.13, view: v, frame: blank)) }
        let q = try! XCTUnwrap(o.measurement)
        XCTAssertLessThan(ShapeCheck.signedArea(q), 0, "pose order runs anticlockwise on screen")
        let i = try! XCTUnwrap(tr.lastSideModes.firstIndex(of: "near"))
        // the near side is the lowest in the image for a camera looking down at the slab
        let lows = (0..<4).map { (q[$0].y + q[($0 + 1) % 4].y) / 2 }
        XCTAssertEqual(i, lows.indices.max { lows[$0] < lows[$1] })
        // and the drawn outline runs the same way
        if let ol = o.outline { XCTAssertLessThan(maxDistance(ol, q), 3) }
    }

    func testATapOnNothingExpires() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 205)
        det.silent = true
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        step(tr, det, v, 0, tap: Vec2(240, 180))
        XCTAssertNotNil(tr.seedPoint)
        var expired = false
        for k in 1..<(30 * 8) { if step(tr, det, v, Double(k) / 30).events.contains("seed-expired") { expired = true; break } }
        XCTAssertTrue(expired)
        XCTAssertNil(tr.seedPoint)
        XCTAssertGreaterThan(det.seeds.compactMap { $0 }.count, 10)
    }

    func testResetForgetsTheSeedAndTheNoise() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 206)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        for k in 0..<(30 * 6) { step(tr, det, v, Double(k) / 30) }
        XCTAssertLessThan(tr.cornerNoiseEstimate, 0.7)   // measured from the re-checks: the detector is better than 1 px
        tr.reset()
        XCTAssertEqual(tr.cornerNoiseEstimate, TrackerSettings().cornerNoisePixels)
        XCTAssertNil(tr.seedPoint)
        XCTAssertEqual(tr.state, .searching)
    }
}

/// The true outline, reversed (clockwise on screen) and starting at corner 2, with side modes marking the side nearest
/// the camera "near".
final class ReversedModesDetector: SlabDetecting {
    let world: World
    var view: CameraView?
    init(_ w: World) { world = w }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        guard let v = view else { return [] }
        let c = world.corners(in: v)
        let q = [c[2], c[1], c[0], c[3]]
        let lows = (0..<4).map { (q[$0].y + q[($0 + 1) % 4].y) / 2 }
        let near = lows.indices.max { lows[$0] < lows[$1] }!
        return [DetectedOutline(quad: q, sideModes: (0..<4).map { $0 == near ? "near" : "top" })]
    }
}
