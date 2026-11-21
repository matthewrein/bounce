import XCTest
@testable import BounceCore

/// n21: the tilt's direction from the views too (`MultiViewLock.fitNormal`, `TrackerSettings.multiViewNormal`,
/// `HonestTilt.offer`).
final class MultiViewNormalTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    func views(_ w: World, azimuths: [Double], distance: Double = 1.0, elevation: Double = 45) -> [CameraView] {
        azimuths.map { a in
            let e = Units.radians(elevation), r = Units.radians(a)
            let pos = w.slab.center + Vec3(cos(e) * cos(r), sin(e), cos(e) * sin(r)) * distance
            return w.view(from: pos, at: w.slab.center)
        }
    }

    /// A pose with its normal (and axes) turned by `deg` about `axis`.
    func tipped(_ p: SlabPose, by deg: Double, about axis: Vec3) -> SlabPose {
        let w = axis.normalized * Units.radians(deg)
        let n = p.normal.rotated(by: w).normalized, u = p.axisU.rotated(by: w).rejecting(n).normalized
        return SlabPose(center: p.center, normal: n, axisU: u, axisV: n.cross(u), halfU: p.halfU, halfV: p.halfV)
    }

    /// Exact outlines from four views bring a start tipped 2 deg (and 1 cm off) back to the slab's normal; the
    /// position-only fit (n18) keeps the tipped normal.
    func testTheViewsPinTheNormal() throws {
        let w = World(slab: World.slabAt(Vec3(0.05, 0.03, -1.0), tilt: 6, heading: 40, spec: .ownerSlab))
        let vs = views(w, azimuths: [0, 40, 80, 120])
        let obs = vs.map { MultiViewLock.Observation(quad: w.corners(in: $0), camera: $0) }
        var S = tipped(w.slab, by: 2, about: w.slab.axisU)
        S.center = S.center + Vec3(0.006, -0.004, 0.008)
        let nf = try XCTUnwrap(MultiViewLock.fitNormal(start: S, observations: obs, groupDegrees: 7.5))
        XCTAssertLessThan(Units.degrees(nf.pose.normal.angle(to: w.slab.normal)), 0.01)
        XCTAssertLessThan(nf.pose.center.distance(to: w.slab.center), 0.0002)
        XCTAssertLessThan(nf.rmsPixels, 0.01)
        XCTAssertEqual(nf.views, 4); XCTAssertEqual(nf.used, 4)
        XCTAssertNotNil(nf.jackknifeSigmaDegrees, "four views: a jackknife over them")
        XCTAssertEqual(nf.sigmaDegrees, max(nf.formalSigmaDegrees, nf.jackknifeSigmaDegrees!), accuracy: 1e-9)
        let pos = try XCTUnwrap(MultiViewLock.fit(lock: S, observations: obs, groupDegrees: 7.5))
        XCTAssertEqual(Units.degrees(pos.pose.normal.angle(to: S.normal)), 0, accuracy: 1e-6, "the position fit holds the normal")
        // with the size free too it reads the slab's size from a start 5% small
        var small = S
        small.halfU *= 0.95; small.halfV *= 0.95
        let free = try XCTUnwrap(MultiViewLock.fitNormal(start: small, observations: obs, groupDegrees: 7.5, freeSize: true))
        XCTAssertEqual((free.pose.halfU + free.pose.halfV) * 1000, SlabSpec.ownerSlab.meanSide * 1000, accuracy: 0.2)
        XCTAssertLessThan(Units.degrees(free.pose.normal.angle(to: w.slab.normal)), 0.01)
    }

    /// With a pixel of noise on every corner, several detections per view and one outline on the wrong edge, the views'
    /// normal is nearer the truth than the single views' own normals on average, the outlier is left out, and the
    /// deviation it states covers its error. Two views: no jackknife (the caller treats the fit as weak).
    func testNoisyViewsGiveAnHonestNormal() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.03, -1.2), tilt: 4, heading: 200, spec: .ownerSlab))
        var worst = 0.0, ratios: [Double] = []
        for seed in 1...6 {
            var rng = SeededRandom(UInt64(seed))
            let vs = views(w, azimuths: [-50, -25, 0, 25, 50], distance: 1.2, elevation: 40)
            var obs: [MultiViewLock.Observation] = []
            for v in vs {
                for _ in 0..<3 {
                    obs.append(MultiViewLock.Observation(quad: w.corners(in: v).map { Vec2($0.x + rng.gaussian() * 0.8, $0.y + rng.gaussian() * 0.8) }, camera: v))
                }
            }
            var bad = w.corners(in: vs[2])
            let c = (bad[0] + bad[1] + bad[2] + bad[3]) / 4, m = (bad[0] + bad[1]) / 2
            bad[0] = bad[0] + (m - c).normalized * 8; bad[1] = bad[1] + (m - c).normalized * 8
            obs.append(MultiViewLock.Observation(quad: bad, camera: vs[2]))
            let nf = try XCTUnwrap(MultiViewLock.fitNormal(start: tipped(w.slab, by: 1.5, about: w.slab.axisV), observations: obs, groupDegrees: 7.5))
            XCTAssertEqual(nf.used, 15, "the outline on the wrong edge is left out")
            let err = Units.degrees(nf.pose.normal.angle(to: w.slab.normal))
            worst = max(worst, err)
            ratios.append(err / nf.sigmaDegrees)
            XCTAssertNotNil(nf.jackknifeSigmaDegrees)
        }
        print("MVNORMAL noisy: worst error \(worst) deg, error/sigma \(ratios)")
        XCTAssertLessThan(worst, 0.6)
        XCTAssertLessThan(ratios.max()!, 3, "the stated deviation covers the error")
        // two views: a fit, but no jackknife
        let two = views(w, azimuths: [0, 30], distance: 1.2, elevation: 40).map { MultiViewLock.Observation(quad: w.corners(in: $0), camera: $0) }
        let nf2 = try XCTUnwrap(MultiViewLock.fitNormal(start: w.slab, observations: two, groupDegrees: 7.5))
        XCTAssertNil(nf2.jackknifeSigmaDegrees)
    }

    /// The hold rule: an offered estimate replaces the shown one only once the tilt is shown, and only with a smaller
    /// deviation; never without `holdShown`.
    func testTheOfferFollowsTheHoldRule() throws {
        var s = SettleSettings(); s.holdShown = true; s.settleDegrees = 2; s.unsettleDegrees = 2.5
        var h = HonestTilt(settings: s)
        let n0 = Vec3(0.05, 1, 0).normalized, view = Vec3(0.3, 0.8, 0.5).normalized
        let r = Units.radians(0.8)
        let det = HonestTilt.Detection(normal: n0, cov: Mat3(rows: [r * r, 0, 0, 0, 0, 0, 0, 0, r * r]), view: view, chi2: 0, dof: 2, excluded: false)
        let other = Vec3(-0.03, 1, 0.02).normalized
        h.add(det)
        XCTAssertFalse(h.settled)
        XCTAssertFalse(h.offer(normal: other, sigmaDegrees: 0.1), "not before the tilt is shown")
        h.add(det)
        XCTAssertTrue(h.settled)
        let shownSigma = try XCTUnwrap(h.shownSigmaDegrees)
        XCTAssertFalse(h.offer(normal: other, sigmaDegrees: shownSigma + 0.1), "a larger deviation is not taken")
        XCTAssertEqual(Units.degrees(try XCTUnwrap(h.shownNormal).angle(to: n0)), 0, accuracy: 1e-6)
        XCTAssertTrue(h.offer(normal: other, sigmaDegrees: shownSigma / 2))
        XCTAssertEqual(Units.degrees(try XCTUnwrap(h.shownNormal).angle(to: other)), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(h.shownSigmaDegrees), shownSigma / 2, accuracy: 1e-12)
        XCTAssertFalse(h.offer(normal: n0, sigmaDegrees: .nan))
        // without the hold rule nothing is held, so nothing is replaced
        s.holdShown = false
        var h2 = HonestTilt(settings: s)
        h2.add(det); h2.add(det)
        XCTAssertTrue(h2.settled)
        XCTAssertFalse(h2.offer(normal: other, sigmaDegrees: 0.01))
    }

    /// Through the tracker, the camera walking a half circle round a tilted slab with a pixel of noise: with the views'
    /// normal on, the shown tilt (the readouts' and the bounce's normal) ends nearer the truth than without, the summary
    /// says the tilt took it, and the outline is unchanged. Off (the default), the summary has no normal.
    func testTheTrackersShownTiltUsesTheViews() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.03, -1.0), tilt: 5, heading: 70, spec: .ownerSlab))
        func run(_ on: Bool) -> (shown: Vec3?, outline: [SlabPose], took: Bool, tracker: SlabTracker) {
            let det = TruthDetector(w); det.noise = 1.0
            var s = RecordingSettings().trackerSettings
            s.spec = .ownerSlab; s.recheckInterval = 0.1; s.ballGate = nil; s.multiViewNormal = on
            let tr = SlabTracker(settings: s, detector: det)
            var outline: [SlabPose] = [], took = false
            for k in 0..<120 {
                let a = Units.radians(-90 + 1.5 * Double(k)), e = Units.radians(45)
                let v = w.view(from: w.slab.center + Vec3(cos(e) * cos(a), sin(e), cos(e) * sin(a)) * 1.1, at: w.slab.center)
                det.currentView = v
                _ = tr.process(TrackerFrame(timestamp: Double(k) * 0.1, view: v, frame: blank))
                if let p = tr.imageSlab { outline.append(p) }
                if tr.multiView?.normalApplied == true { took = true }
            }
            return (tr.settledNormal, outline, took, tr)
        }
        let off = run(false), on = run(true)
        XCTAssertEqual(on.tracker.state, .locked); XCTAssertEqual(off.tracker.state, .locked)
        XCTAssertNil(off.tracker.multiView?.normal)
        XCTAssertFalse(off.took)
        XCTAssertTrue(on.took, "\(String(describing: on.tracker.multiView))")
        let eOn = Units.degrees(try XCTUnwrap(on.shown).angle(to: w.slab.normal)), eOff = Units.degrees(try XCTUnwrap(off.shown).angle(to: w.slab.normal))
        print("MVNORMAL tracker: shown normal error on \(eOn) deg, off \(eOff) deg; summary \(String(describing: on.tracker.multiView))")
        XCTAssertLessThan(eOn, eOff)
        XCTAssertLessThan(eOn, 0.3)
        // the outline (the lock) is the same
        XCTAssertEqual(on.outline.count, off.outline.count)
        var worst = 0.0
        for (a, b) in zip(on.outline, off.outline) {
            worst = max(worst, a.center.distance(to: b.center), abs(a.normal.x - b.normal.x), abs(a.normal.y - b.normal.y), abs(a.normal.z - b.normal.z))
        }
        XCTAssertLessThanOrEqual(worst, 1e-12)
    }

    /// The app runs it; the default is off; an older recording's settings (without the key) replay without it.
    func testTheSettingIsCodedAndTheAppsIsOn() throws {
        let app = RecordingSettings().trackerSettings
        XCTAssertTrue(app.multiViewNormal)
        XCTAssertTrue(app.multiViewLock && app.settle.holdShown && app.readoutsFromSettledNormal, "what it needs")
        XCTAssertFalse(TrackerSettings().multiViewNormal)
        let back = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(back, app)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        XCTAssertNotNil(old.removeValue(forKey: "multiViewNormal"))
        XCTAssertFalse(try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: old)).multiViewNormal)
    }
}
