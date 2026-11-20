import XCTest
@testable import BounceCore

/// The multi-view lock (n18, `MultiViewLock`, `TrackerSettings.multiViewLock`): the lock's views fitted together, so the
/// outline stays on the slab from every side.
final class MultiViewLockTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    /// cameras around the slab: azimuths (deg) at a distance and elevation, looking at its centre
    func views(_ w: World, azimuths: [Double], distance: Double = 1.0, elevation: Double = 45) -> [CameraView] {
        azimuths.map { a in
            let e = Units.radians(elevation), r = Units.radians(a)
            let pos = w.slab.center + Vec3(cos(e) * cos(r), sin(e), cos(e) * sin(r)) * distance
            return w.view(from: pos, at: w.slab.center)
        }
    }

    func turned(_ p: SlabPose, by deg: Double) -> SlabPose {
        let a = Units.radians(deg), u = (p.axisU * cos(a) + p.axisV * sin(a)).normalized
        return SlabPose(center: p.center, normal: p.normal, axisU: u, axisV: p.normal.cross(u), halfU: p.halfU, halfV: p.halfV)
    }

    /// A lock 15 mm off along one view's line of sight and turned 2 deg (what one view's depth error does) comes back onto
    /// the slab from four views' outlines (any corner order), its normal and size held.
    func testTheFitPutsTheLockBackOnTheSlab() throws {
        let w = World(slab: World.slabAt(Vec3(0.05, 0.03, -1.0), tilt: 6, heading: 40, spec: .ownerSlab))
        let vs = views(w, azimuths: [0, 50, 100, 150])
        // outlines in other orders: turned and mirrored
        let obs = vs.enumerated().map { i, v -> MultiViewLock.Observation in
            var q = w.corners(in: v)
            q = Array(q[(i % 4)...] + q[..<(i % 4)])
            if i % 2 == 1 { q.reverse() }
            return MultiViewLock.Observation(quad: q, camera: v)
        }
        let los = (w.slab.center - vs[0].position).normalized
        var L = turned(w.slab, by: 2)
        L.center = w.slab.center + los * 0.015
        let fit = try XCTUnwrap(MultiViewLock.fit(lock: L, observations: obs, groupDegrees: 7.5))
        XCTAssertLessThan(fit.pose.center.distance(to: w.slab.center), 0.0002)
        XCTAssertLessThan(fit.rmsPixels, 0.01)
        XCTAssertEqual(fit.pose.normal, L.normal, "the normal is held")
        XCTAssertEqual(fit.pose.halfU, L.halfU); XCTAssertEqual(fit.pose.halfV, L.halfV)
        XCTAssertEqual(MultiViewLock.drift([fit.pose.topCorners, w.slab.topCorners]) ?? 1, 0, accuracy: 0.0002)
        XCTAssertEqual(fit.used, 4); XCTAssertEqual(fit.views, 4)
        XCTAssertGreaterThan(fit.spreadDegrees, 60)

        // with the size free it reads the slab's own size from a lock assumed 5% small
        var small = L
        small.halfU *= 0.95; small.halfV *= 0.95
        let free = try XCTUnwrap(MultiViewLock.fit(lock: small, observations: obs, groupDegrees: 7.5, freeSize: true))
        XCTAssertEqual((free.pose.halfU + free.pose.halfV) * 1000, SlabSpec.ownerSlab.meanSide * 1000, accuracy: 0.2)
    }

    /// Single views with a pixel of error each disagree by centimetres along their lines of sight; fitted together they
    /// pin the centre to millimetres. A detection on the wrong edge (one side 8 px out) is left out.
    func testNoisyViewsAndAnOutlierFitTogether() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.03, -1.2), tilt: 3, heading: 200, spec: .ownerSlab))
        let vs = views(w, azimuths: [-60, -30, 0, 30, 60, 90], distance: 1.2, elevation: 40)
        var rng = SeededRandom(7)
        var obs = vs.map { v in
            MultiViewLock.Observation(quad: w.corners(in: v).map { Vec2($0.x + rng.gaussian() * 0.8, $0.y + rng.gaussian() * 0.8) }, camera: v)
        }
        var bad = w.corners(in: vs[2])
        let c = (bad[0] + bad[1] + bad[2] + bad[3]) / 4, m = (bad[0] + bad[1]) / 2
        bad[0] = bad[0] + (m - c).normalized * 8; bad[1] = bad[1] + (m - c).normalized * 8
        obs.append(MultiViewLock.Observation(quad: bad, camera: vs[2]))
        var L = w.slab
        L.center = L.center + Vec3(0.01, 0.006, -0.008)
        let fit = try XCTUnwrap(MultiViewLock.fit(lock: L, observations: obs, groupDegrees: 7.5))
        XCTAssertEqual(fit.used, 6, "the outline on the wrong edge is left out")
        XCTAssertLessThan(fit.pose.center.distance(to: w.slab.center), 0.002)
        XCTAssertLessThan(fit.rmsPixels, MultiViewLock.maxRmsPixels)
    }

    /// The store keeps each view's newest few, at most `maxViews` views (those seen last); views are anchored where they
    /// started, so a camera moving steadily round leaves one behind every `groupDegrees`.
    func testTheStoreKeepsViews() {
        let d = { (deg: Double) in Vec3(cos(Units.radians(deg)), 0, sin(Units.radians(deg))) }
        var s = MultiViewLock.ViewStore<Int>()
        for (i, a) in [0.0, 0.5, 1, 1.5, 20, 40, 0.2].enumerated() { s.add(i, direction: d(a), groupDegrees: 7.5, perGroup: 3) }
        s.add(99, direction: nil, groupDegrees: 7.5, perGroup: 3)
        XCTAssertEqual(s.values, [2, 3, 4, 5, 6])
        var t = MultiViewLock.ViewStore<Int>()
        for i in 0..<100 { t.add(i, direction: d(Double(i)), groupDegrees: 7.5, perGroup: 3, maxViews: 4) }
        // views start at 0, 8, 16, ... 96 deg: the last four (72, 80, 88, 96), their newest three (or fewer)
        XCTAssertEqual(t.values, [77, 78, 79, 85, 86, 87, 93, 94, 95, 97, 98, 99])
        let v = MultiViewLock.views([d(0), d(1), d(20), d(40)], groupDegrees: 7.5)
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v.spreadDegrees, 40, accuracy: 1e-9)
        t.removeAll(); XCTAssertTrue(t.isEmpty)
    }

    /// Through the tracker, the camera walking a half circle round the slab: with the multi-view lock the outline sits on
    /// the slab (its corners nearer the truth, drifting less), its normal is the single-view lock's (the tilt is
    /// unchanged), and the summary says what it did. Off (the default), the lock is as before and there is no summary.
    func testTheTrackersLockUsesItsViews() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.03, -1.0), tilt: 5, heading: 70, spec: .ownerSlab))
        func run(_ on: Bool) -> (err: [Double], normals: [Vec3], tracker: SlabTracker) {
            let det = TruthDetector(w); det.noise = 1.0
            var s = TrackerSettings(); s.spec = .ownerSlab; s.recheckInterval = 0.1; s.multiViewLock = on; s.lockKeepsNewestPerView = true
            let tr = SlabTracker(settings: s, detector: det)
            var err: [Double] = [], normals: [Vec3] = []
            for k in 0..<120 {
                let a = Units.radians(-90 + 1.5 * Double(k)), e = Units.radians(45)
                let v = w.view(from: w.slab.center + Vec3(cos(e) * cos(a), sin(e), cos(e) * sin(a)) * 1.1, at: w.slab.center)
                det.currentView = v
                _ = tr.process(TrackerFrame(timestamp: Double(k) * 0.1, view: v, frame: blank))
                if k >= 40, let p = tr.imageSlab {
                    let m = MultiViewLock.matched(p.topCorners, to: w.slab.topCorners) { $0.distance(to: $1) }
                    err.append(zip(m, w.slab.topCorners).map { $0.0.distance(to: $0.1) }.max()!)
                    normals.append(p.normal)
                }
            }
            return (err, normals, tr)
        }
        let off = run(false), on = run(true)
        XCTAssertEqual(on.tracker.state, .locked); XCTAssertEqual(off.tracker.state, .locked)
        XCTAssertNil(off.tracker.multiView)
        let sum = try XCTUnwrap(on.tracker.multiView)
        XCTAssertTrue(sum.applied, "\(sum)")
        XCTAssertGreaterThanOrEqual(sum.views, 4)
        XCTAssertEqual(sum.sizeSettingMm, SlabSpec.ownerSlab.meanSide * 1000, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sum.impliedSizeMm), sum.sizeSettingMm, accuracy: 3)
        XCTAssertNotNil(sum.cornerSpreadMm); XCTAssertNotNil(sum.lockDriftMm)
        // the tilt is the single-view lock's, exactly
        XCTAssertEqual(on.normals.count, off.normals.count)
        // compared component by component: acos of a dot product cannot resolve below 8.5e-7 deg (acos(1 - 2^-53)), and on
        // arm64 (fused multiply-add) two identical unit normals can dot to 1 - 2^-53, which failed on CI's Mac; a real change
        // of the tilt would show here as 1e-9 or more
        var worst = 0.0
        for (a, b) in zip(on.normals, off.normals) { worst = max(worst, abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
        print("MULTIVIEW normal: largest component difference on vs off \(worst)")
        XCTAssertLessThanOrEqual(worst, 1e-12)
        let mOn = KitStats.median(on.err), mOff = KitStats.median(off.err)
        print("MULTIVIEW corner error median on \(mOn * 1000) mm (max \(on.err.max()! * 1000)), off \(mOff * 1000) mm (max \(off.err.max()! * 1000))")
        XCTAssertLessThan(mOn, mOff)
        XCTAssertLessThan(on.err.max()!, off.err.max()!)
    }

    /// The app runs it, an older recording's settings (without the key) replay without it, and the app's LiDAR no longer
    /// moves the centre (n18).
    func testTheSettingIsCodedAndTheAppsIsOn() throws {
        let app = RecordingSettings().trackerSettings
        XCTAssertTrue(app.multiViewLock)
        XCTAssertEqual(app.depthCentreWeight, 0)
        XCTAssertEqual(app.spec.sideU, SlabSpec.ownerFlatTopMm / 1000, accuracy: 1e-12)
        XCTAssertFalse(TrackerSettings().multiViewLock)
        let back = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(back, app)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        XCTAssertNotNil(old.removeValue(forKey: "multiViewLock"))
        XCTAssertFalse(try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: old)).multiViewLock)
        // a recording's own slab size replays as recorded
        var r = RecordingSettings(); r.sideUInches = 175 / 25.4; r.sideVInches = 175 / 25.4
        XCTAssertEqual(r.trackerSettings.spec.meanSide, 0.175, accuracy: 1e-12)
        XCTAssertEqual(r.trackerSettings.spec.sideRun, SlabSpec.ownerSlab.sideRun, "the sides' run stays: the outer edge follows the top")
    }
}
