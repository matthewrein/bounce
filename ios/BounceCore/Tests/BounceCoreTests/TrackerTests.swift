import XCTest
@testable import BounceCore

/// A world (y up, metres) with a slab and a phone camera, for tracker tests.
struct World {
    var slab: SlabPose
    var intrinsics = CameraIntrinsics(fx: 480, fy: 480, cx: 240, cy: 180, width: 480, height: 360)

    static func slabAt(_ c: Vec3, tilt: Double, heading: Double, yaw: Double = 10, spec: SlabSpec = .standard) -> SlabPose {
        let th = Units.radians(tilt), hd = Units.radians(heading), yw = Units.radians(yaw)
        let n = Vec3(sin(th) * cos(hd), cos(th), sin(th) * sin(hd))
        let u = Vec3(cos(yw), 0, sin(yw)).rejecting(n).normalized
        return SlabPose(center: c, normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
    }

    /// A camera at `pos` looking at `target` (CV axes; world y up).
    func view(from pos: Vec3, at target: Vec3) -> CameraView {
        let fwd = (target - pos).normalized
        let right = fwd.cross(Vec3(0, 1, 0)).normalized, down = fwd.cross(right)
        return CameraView(worldFromCamera: RigidTransform(rotation: Mat3(columns: right, down, fwd), translation: pos), intrinsics: intrinsics)
    }

    func corners(in v: CameraView) -> [Vec2] { slab.topCorners.map { v.project(world: $0)! } }

    /// A depth map of the slab's top (dished) seen from `v`, everything else at 3 m.
    func depthMap(_ v: CameraView, spec: SlabSpec, scale: Double = 0.4) -> (DepthMap, CameraIntrinsics) {
        let K = v.intrinsics.scaled(by: scale)
        var d = [Float](repeating: 3, count: K.width * K.height), c = [UInt8](repeating: 2, count: K.width * K.height)
        let plane = Plane3(point: slab.center, normal: slab.normal)
        for y in 0..<K.height {
            for x in 0..<K.width {
                let r = v.worldFromCamera.applyDirection(K.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5)))
                guard var p = plane.intersect(origin: v.position, direction: r) else { continue }
                var (u, w) = slab.local(p)
                guard abs(u) < slab.halfU, abs(w) < slab.halfV else { continue }
                // where the ray meets the dished surface: a few steps through planes parallel to the corners' plane
                for _ in 0..<4 {
                    let dish = Dish.at(pose: slab, depth: spec.dishDepth, u: u, v: w).depth
                    guard let q = Plane3(point: slab.center - slab.normal * dish, normal: slab.normal).intersect(origin: v.position, direction: r) else { break }
                    p = q; (u, w) = slab.local(p)
                }
                d[y * K.width + x] = Float(v.toCamera(p).z); c[y * K.width + x] = 2
            }
        }
        return (DepthMap(width: K.width, height: K.height, depth: d, confidence: c), K)
    }
}

/// Reports the world's true outline, with noise, optional corruption and optional silence.
final class TruthDetector: SlabDetecting {
    var world: World
    var rng = SeededRandom(3)
    var noise = 0.7
    var silent = false
    /// moves one side outward by this many pixels (like an outline caught on the cut face's bottom)
    var corruptSide: (Int, Double)? = nil
    init(_ w: World) { world = w }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        if silent { return [] }
        // the tracker hands the detector intrinsics only; the view comes from the test via `currentView`
        guard let v = currentView else { return [] }
        var q = world.corners(in: v).map { Vec2($0.x + rng.gaussian() * noise, $0.y + rng.gaussian() * noise) }
        if let (i, px) = corruptSide {
            let a = q[i], b = q[(i + 1) % 4], c = (q[0] + q[1] + q[2] + q[3]) / 4, m = (a + b) / 2
            var n = (b - a).perpendicular.normalized
            if n.dot(m - c) < 0 { n = -n }
            q[i] = a + n * px; q[(i + 1) % 4] = b + n * px
        }
        return [DetectedOutline(quad: q)]
    }
    var currentView: CameraView?
}

final class TrackerTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    func makeTracker(_ det: TruthDetector) -> SlabTracker {
        var s = TrackerSettings(); s.recheckInterval = 0.1
        return SlabTracker(settings: s, detector: det)
    }

    func step(_ t: SlabTracker, _ det: TruthDetector, _ v: CameraView, _ time: Double, depth: (DepthMap, CameraIntrinsics)? = nil) -> TrackerOutput {
        det.currentView = v
        return t.process(TrackerFrame(timestamp: time, view: v, frame: blank, depth: depth?.0, depthIntrinsics: depth?.1))
    }

    func testLocksAfterConfirmationAndHoldsStillAsPhoneMoves() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 8, heading: 40))
        let det = TruthDetector(w), tr = makeTracker(det)
        var t = 0.0, lockedAt: Int? = nil
        var errs: [Double] = []
        for k in 0..<60 {
            // the phone sways around a point 1.4 m from the slab, 0.9 m up
            let pos = Vec3(0.15 * sin(Double(k) * 0.1), 0.95 + 0.05 * cos(Double(k) * 0.13), 0.0 + 0.1 * sin(Double(k) * 0.07))
            let v = w.view(from: pos, at: w.slab.center + Vec3(0.02 * sin(Double(k)), 0, 0))
            let out = step(tr, det, v, t)
            if out.state == .locked && lockedAt == nil { lockedAt = k }
            if out.state == .locked, let q = out.outline {
                let truth = w.corners(in: v)
                errs.append(zip(q, truth).map { $0.distance(to: $1) }.max()!)
            }
            t += 1.0 / 30
        }
        XCTAssertEqual(lockedAt, 2) // three consistent detections
        // the outline is the world-pinned lock projected: well under a pixel off despite 0.7 px detection noise
        XCTAssertLessThan(errs.sorted()[errs.count / 2], 0.8)
        XCTAssertEqual(tr.counts["locks"], 1)
        XCTAssertEqual(tr.state, .locked)
    }

    func testOneBadDetectionDoesNotMoveTheLock() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 6, heading: 200))
        let det = TruthDetector(w), tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: w.slab.center)
        var t = 0.0
        for _ in 0..<10 { _ = step(tr, det, v, t); t += 0.11 }
        let before = tr.slab!
        det.corruptSide = (2, 9) // the near edge caught on the cut face's bottom, once
        let o = step(tr, det, v, t); t += 0.11
        det.corruptSide = nil
        XCTAssertTrue(o.events.contains("recheck-disagree"), "\(o.events)")
        XCTAssertLessThan(tr.slab!.center.distance(to: before.center), 1e-9)
        for _ in 0..<5 { _ = step(tr, det, v, t); t += 0.11 }
        XCTAssertLessThan(Units.degrees(tr.slab!.normal.angle(to: w.slab.normal)), 0.5)
        XCTAssertEqual(tr.counts["relocks"] ?? 0, 0)
    }

    func testRelocksWhenTheSlabIsMoved() {
        var w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 0, heading: 0))
        let det = TruthDetector(w), tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: w.slab.center)
        var t = 0.0
        for _ in 0..<8 { _ = step(tr, det, v, t); t += 0.11 }
        XCTAssertLessThan(Units.degrees(tr.slab!.tilt(down: ARKitConvention.worldDown)), 1)
        // the owner slides the slab 3 in: it tilts 10 deg
        w.slab = World.slabAt(Vec3(0.076, 0.065, -1.2), tilt: 10, heading: 180)
        det.world = w
        var relockedAfter: Int? = nil
        for k in 0..<10 {
            let o = step(tr, det, v, t); t += 0.11
            if o.events.contains("relocked") { relockedAfter = k + 1; break }
        }
        // moveCount disagreeing re-detections; one more when the first after the move takes the mirror solution nearer the
        // old normal (the solver's hysteresis) and so does not agree with the next
        let mc = TrackerSettings().moveCount
        XCTAssertNotNil(relockedAfter)
        XCTAssertTrue((mc...(mc + 1)).contains(relockedAfter ?? 0), "relocked after \(relockedAfter ?? -1)")
        XCTAssertEqual(Units.degrees(tr.slab!.tilt(down: ARKitConvention.worldDown)), 10, accuracy: 1)
    }

    func testLostOnlyWhenTheSlabShouldBeInView() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 5, heading: 90))
        let det = TruthDetector(w), tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: w.slab.center)
        var t = 0.0
        for _ in 0..<5 { _ = step(tr, det, v, t); t += 0.11 }
        XCTAssertEqual(tr.state, .locked)
        det.silent = true
        // looking away (slab out of view) for longer than lostAfter: the lock stays
        let away = w.view(from: Vec3(0, 0.9, 0), at: Vec3(1.5, 0.5, -0.3))
        for _ in 0..<60 { _ = step(tr, det, away, t); t += 0.11 }
        XCTAssertEqual(tr.state, .locked)
        // in view but not found for longer than lostAfter: lost
        var lostAt: Double? = nil
        let t0 = t
        for _ in 0..<60 { let o = step(tr, det, v, t); if o.events.contains("lost") { lostAt = t; break }; t += 0.11 }
        XCTAssertNotNil(lostAt)
        XCTAssertGreaterThan(lostAt! - t0, TrackerSettings().lostAfter - 0.2)
        XCTAssertEqual(tr.state, .searching)
    }

    func testBounceAndReadoutsComeFromTheLock() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 10, heading: 0))
        let det = TruthDetector(w); det.noise = 0
        let tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: w.slab.center)
        var o: TrackerOutput! = nil
        for k in 0..<5 { o = step(tr, det, v, Double(k) * 0.11) }
        let r = o.readouts!
        XCTAssertEqual(r.tiltDegrees, 10, accuracy: 0.05)
        XCTAssertEqual(r.dropHeight, Units.feet(3), accuracy: 1e-9)
        XCTAssertFalse(r.dropFromBall)
        // launched along the normal at sqrt(2 g h e): apex = h e cos^2(tilt)
        XCTAssertEqual(r.apexHeight, Units.feet(3) * 0.7 * pow(cos(Units.radians(10)), 2), accuracy: 0.002)
        XCTAssertGreaterThan(r.landingDistance, 0.1)
        // a known floor 6 cm under the slab's centre lengthens the flight
        det.currentView = v
        let o2 = tr.process(TrackerFrame(timestamp: 1, view: v, frame: blank, floorY: 0.0))
        XCTAssertGreaterThan(o2.readouts!.airTime, r.airTime)
    }

    func testDepthCheckAgreesAndFuses() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.0), tilt: 9, heading: 120))
        let det = TruthDetector(w); det.noise = 0
        let tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.8, 0), at: w.slab.center)
        let dm = w.depthMap(v, spec: .standard)
        var o: TrackerOutput! = nil
        for k in 0..<5 { o = step(tr, det, v, Double(k) * 0.11, depth: dm) }
        let d = try! XCTUnwrap(o.depth)
        XCTAssertGreaterThan(d.points, 100)
        XCTAssertLessThan(d.angleToImageDegrees, 0.3)   // the dish is symmetric: its best plane is parallel to the corners'
        XCTAssertEqual(d.tiltDegrees, 9, accuracy: 0.3)
        // the corner plane's centre sits above the best plane through the inner 70% of the dish by its mean depth there:
        // D (1 - 0.7^2 / 3) for a paraboloid (more or less, as the points are not spread evenly in perspective)
        XCTAssertEqual(d.centreOffset, SlabSpec.standard.dishDepth * (1 - 0.49 / 3), accuracy: 0.0006)
        XCTAssertTrue(o.events.contains("depth-fused"))
        XCTAssertLessThan(Units.degrees(o.slab!.normal.angle(to: w.slab.normal)), 0.3)
    }

    func testPlaneFitRecoversAPlane() {
        var rng = SeededRandom(11)
        let n = Vec3(0.1, 1, -0.2).normalized, p0 = Vec3(0.3, -0.1, 1.2), u = n.anyPerpendicular, v = n.cross(u)
        var pts: [Vec3] = []
        for _ in 0..<400 { pts.append(p0 + u * rng.uniform(-0.1, 0.1) + v * rng.uniform(-0.02, 0.02) + n * rng.gaussian() * 0.002) }
        for _ in 0..<60 { pts.append(p0 + Vec3(rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2), rng.uniform(-0.2, 0.2))) } // clutter
        let f = PlaneFit.robust(pts, threshold: 0.006)!
        XCTAssertLessThan(Units.degrees(f.plane.normal.angle(to: n).truncatingRemainder(dividingBy: .pi)), 1.5)
        XCTAssertLessThan(abs(f.plane.distance(p0)), 0.002)
        XCTAssertGreaterThan(f.inliers, 380)
    }

    func testDiagnosticsJSON() {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.2), tilt: 7, heading: 10))
        let det = TruthDetector(w), tr = makeTracker(det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: w.slab.center)
        var o: TrackerOutput! = nil
        for k in 0..<5 { o = step(tr, det, v, Double(k) * 0.11) }
        let rep = DiagnosticsReport(build: "n1", device: "test", system: "linux", time: "now", settings: RecordingSettings(), state: o.state.rawValue,
                                    tracking: "normal", fps: 30, msProcess: 4.2, lens: v.intrinsics, depthSupported: false, depth: nil, captureLocked: true,
                                    slab: o.slab, outline: o.outline, sideModes: [], ball: nil, readouts: o.readouts, counts: tr.counts, recentEvents: o.events, recording: nil)
        let js = rep.json()
        XCTAssertTrue(js.contains("\"build\":\"n1\""))
        XCTAssertTrue(js.contains("\"tiltDegrees\":"))
        let back = try! JSONDecoder().decode(DiagnosticsReport.self, from: Data(js.utf8))
        XCTAssertEqual(back.state, "locked")
        XCTAssertEqual(back.tiltDegrees!, 7, accuracy: 0.5)
        XCTAssertEqual(back.counts["locks"], 1)
    }
}
