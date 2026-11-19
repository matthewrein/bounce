import XCTest
@testable import BounceCore

/// The tilt's honest uncertainty and when the app shows the tilt (n11, `HonestTilt`, `SlabTracker.tiltSigmaDegrees`,
/// `angleSettled`): the per-side model, view groups, the three safeguards, and the lock left as it was.
final class HonestTiltTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))
    /// the kit's video camera: 1440 x 1080, focal 1016 px
    let kitK = CameraIntrinsics(fx: 1016, fy: 1016, cx: 720, cy: 540, width: 1440, height: 1080)

    /// A level slab (world z up) seen from `elev` degrees above the horizon, `dist` metres away, `az` degrees round from
    /// square-on to a side, in camera axes (as the prep's replay scripts build their views).
    func poseForView(elev: Double, dist: Double, az: Double, half h: Double) -> SlabPose {
        let e = Units.radians(elev), a = Units.radians(az)
        let C = Vec3(cos(e) * sin(a), -cos(e) * cos(a), sin(e)) * dist
        let fwd = (-C).normalized, right = fwd.cross(Vec3(0, 0, 1)).normalized, down = fwd.cross(right)
        func cam(_ x: Vec3) -> Vec3 { Vec3(right.dot(x), down.dot(x), fwd.dot(x)) }
        return SlabPose(center: cam(-C), normal: cam(Vec3(0, 0, 1)), axisU: cam(Vec3(1, 0, 0)), axisV: cam(Vec3(0, 1, 0)), halfU: h, halfV: h)
    }

    // MARK: the per-side model

    /// The linearised fit agrees with refitting: a side moved by half a pixel turns the refitted normal as
    /// `normalPerShift` says, and the misfit it leaves is what `residualPerShift` says.
    func testSideSensitivityMatchesRefitting() throws {
        let pose = poseForView(elev: 50, dist: 1.0, az: 25, half: 0.0901)
        let q = pose.topCorners.map { kitK.project($0)! }
        let ss = try XCTUnwrap(PoseSolver.sideSensitivity(pose: pose, corners: q, intrinsics: kitK))
        XCTAssertLessThan(ss.residuals.map { abs($0) }.max()!, 1e-6, "an exact outline leaves no misfit")
        let spec = SlabSpec(sideU: 0.1802, sideV: 0.1802, thickness: 0.0254, dishDepth: 0)
        for s in 0..<4 {
            for turn in [false, true] {
                let moved = try XCTUnwrap(SideSensitivity.moved(q, side: s, by: 0.5, turn: turn))
                let fit = try XCTUnwrap(PoseSolver.solve(corners: moved, intrinsics: kitK, spec: spec, previousNormal: pose.normal))
                let predicted = (turn ? ss.normalPerTurn[s] : ss.normalPerShift[s]) * 0.5
                let actual = fit.pose.normal - pose.normal
                XCTAssertLessThan((actual - predicted).length, 0.05 * predicted.length + 2e-6, "side \(s) turn \(turn)")
                let res = (turn ? ss.residualPerTurn[s] : ss.residualPerShift[s]).map { $0 * 0.5 }
                let rms = (res.reduce(0) { $0 + $1 * $1 } / 4).squareRoot()
                XCTAssertEqual(fit.rmsPixels, rms, accuracy: 0.05 * rms + 1e-4, "side \(s) turn \(turn)")
            }
        }
    }

    /// The same numbers as the prep's replay model (scratch sidejac.py, the same views and per-side noise): this is the
    /// rule the kit replays judged.
    func testDetectionSigmaMatchesTheReplayModel() throws {
        let par = [0.5, 0.4, 0.6, 0.3], turn = [0.2, 0.25, 0.2, 0.3]
        let cases: [(Double, Double, Double, Double)] = [(60, 1.2, 0, 0.72629), (50, 1.2, 30, 0.54373), (70, 1.2, 0, 1.04655), (45, 0.9, 15, 0.36704)]
        for (el, d, az, want) in cases {
            let pose = poseForView(elev: el, dist: d, az: az, half: 0.0901)
            let q = pose.topCorners.map { kitK.project($0)! }
            let view = CameraView(worldFromCamera: .identity, intrinsics: kitK)
            let det = try XCTUnwrap(HonestTilt.detection(pose: pose, quad: q, view: view, parallel: par, turn: turn, settings: SettleSettings()))
            XCTAssertEqual(det.sigmaDegrees, want, accuracy: want * 0.005, "elevation \(el), \(d) m, azimuth \(az)")
            XCTAssertFalse(det.excluded)
            XCTAssertLessThan(det.chi2, 1e-6)
        }
    }

    /// With the corner noise split equally into a shift and a turn of each side (the fallback while the detector gives no
    /// per-side noise), a detection's covariance is the solver's own for that corner noise.
    func testTheCornerNoiseFallbackIsThePerCornerModel() throws {
        let spec = SlabSpec(sideU: 0.1802, sideV: 0.1802, thickness: 0.0254, dishDepth: 0)
        for (el, az) in [(40.0, 10.0), (55, 35), (68, 0)] {
            let pose = poseForView(elev: el, dist: 1.1, az: az, half: 0.0901)
            let q = pose.topCorners.map { kitK.project($0)! }
            let fit = try XCTUnwrap(PoseSolver.solve(corners: q, intrinsics: kitK, spec: spec, previousNormal: pose.normal))
            let s = 0.8, e = s / 2.0.squareRoot()
            let det = try XCTUnwrap(HonestTilt.detection(pose: fit.pose, quad: q, view: CameraView(worldFromCamera: .identity, intrinsics: kitK),
                                                         parallel: [e, e, e, e], turn: [e, e, e, e], settings: SettleSettings()))
            XCTAssertEqual(det.sigmaDegrees, fit.normalSigmaDegrees * s, accuracy: fit.normalSigmaDegrees * s * 0.03, "elevation \(el)")
            // the same kept apart as a part that follows the corner noise (the tracker's fallback)
            let z = [0.0, 0, 0, 0]
            let follows = try XCTUnwrap(HonestTilt.detection(pose: fit.pose, quad: q, view: CameraView(worldFromCamera: .identity, intrinsics: kitK),
                                                             parallel: z, turn: z, cornerNoise: s, settings: SettleSettings()))
            XCTAssertEqual(follows.sigmaDegrees, det.sigmaDegrees, accuracy: 1e-9)
            XCTAssertEqual(HonestTilt.trace(follows.covariance(cornerNoise: 2 * s)), 4 * HonestTilt.trace(det.cov), accuracy: 1e-12)
        }
    }

    // MARK: groups and safeguards

    func detection(_ n: Vec3, sigmaDegrees: Double, view: Vec3) -> HonestTilt.Detection {
        let a = n.anyPerpendicular, b = n.cross(a), v = pow(Units.radians(sigmaDegrees), 2) / 2
        let C = add3(scale3(outer3(a, a), v), scale3(outer3(b, b), v))
        return HonestTilt.Detection(normal: n, cov: C, view: view.normalized, chi2: 0, dof: 2, excluded: false)
    }

    /// Fifteen detections from one view are worth one view, not fifteen: the sigma stays a single detection's.
    func testOneViewIsOneView() {
        var h = HonestTilt(settings: SettleSettings())
        let n = Vec3(0, 1, 0)
        for _ in 0..<15 { h.add(detection(n, sigmaDegrees: 0.8, view: Vec3(0, 1, 1))) }
        XCTAssertEqual(h.groups.count, 1)
        XCTAssertEqual(h.groups[0].members.count, SettleSettings().perGroup)
        XCTAssertEqual(h.sigmaDegrees!, 0.8, accuracy: 1e-6)
        XCTAssertTrue(h.settled)
    }

    /// Two views 20 deg apart that agree add up; two that disagree beyond their sigmas widen the result by their
    /// disagreement (and need not settle).
    func testViewsCombineAndDisagreementInflates() {
        let n = Vec3(0, 1, 0)
        let v1 = Vec3(0, 1, 1).normalized, v2 = Vec3(sin(Units.radians(20)), 1, cos(Units.radians(20))).normalized
        var agree = HonestTilt(settings: SettleSettings())
        agree.add(detection(n, sigmaDegrees: 1.2, view: v1))
        XCTAssertFalse(agree.settled)
        agree.add(detection(n, sigmaDegrees: 1.2, view: v2))
        XCTAssertEqual(agree.groups.count, 2)
        XCTAssertEqual(agree.sigmaDegrees!, 1.2 / 2.0.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(agree.inflation, 1)
        agree.add(detection(n, sigmaDegrees: 1.2, view: v2))
        XCTAssertTrue(agree.settled, "two refreshes at or under 1 deg")

        var disagree = HonestTilt(settings: SettleSettings())
        disagree.add(detection(n, sigmaDegrees: 0.6, view: v1))
        let off = n.rotated(by: Vec3(Units.radians(3), 0, 0))
        disagree.add(detection(off, sigmaDegrees: 0.6, view: v2))
        disagree.add(detection(off, sigmaDegrees: 0.6, view: v2))
        XCTAssertGreaterThan(disagree.inflation, 4)
        XCTAssertGreaterThan(disagree.sigmaDegrees!, 1.25)
        XCTAssertFalse(disagree.settled, "3 deg apart at 0.6 deg each: not shown")
    }

    /// Back to settling only above 1.25 deg; a view whose newest detections replace older ones moves the estimate.
    func testHysteresisAndAgeing() {
        var h = HonestTilt(settings: SettleSettings())
        let v = Vec3(0, 1, 1)
        h.add(detection(Vec3(0, 1, 0), sigmaDegrees: 0.9, view: v))
        h.add(detection(Vec3(0, 1, 0), sigmaDegrees: 0.9, view: v))
        XCTAssertTrue(h.settled)
        h.add(detection(Vec3(0, 1, 0), sigmaDegrees: 1.6, view: v))   // the view's mean: sqrt((0.81 * 2 + 2.56) / 3) = 1.18
        XCTAssertTrue(h.settled, "1.18 deg: still shown")
        h.add(detection(Vec3(0, 1, 0), sigmaDegrees: 1.6, view: v))   // sqrt((0.81 + 2.56 * 2) / 3) = 1.41
        XCTAssertFalse(h.settled)
        // a still view's early detections age out: three new ones replace them
        var a = HonestTilt(settings: SettleSettings())
        let biased = Vec3(0, 1, 0).rotated(by: Vec3(Units.radians(4), 0, 0)), right = Vec3(0, 1, 0)
        for _ in 0..<8 { a.add(detection(biased, sigmaDegrees: 0.5, view: v)) }
        for _ in 0..<3 { a.add(detection(right, sigmaDegrees: 0.5, view: v)) }
        XCTAssertLessThan(Units.degrees(a.normal!.angle(to: right)), 1e-6)
    }

    /// A detection the fit cannot explain with its sides' noise is left out (and the estimate still refreshes).
    func testAMisfitDetectionIsLeftOut() throws {
        let pose = poseForView(elev: 50, dist: 1.0, az: 20, half: 0.0901)
        let q = pose.topCorners.map { kitK.project($0)! }
        let view = CameraView(worldFromCamera: .identity, intrinsics: kitK)
        let spec = SlabSpec(sideU: 0.1802, sideV: 0.1802, thickness: 0.0254, dishDepth: 0)
        let noise = [0.3, 0.3, 0.3, 0.3], turn = [0.2, 0.2, 0.2, 0.2]
        // one corner pulled 2 px off: the square cannot fit it
        var bad = q; bad[1] = bad[1] + Vec2(2, 1.5)
        let fit = try XCTUnwrap(PoseSolver.solve(corners: bad, intrinsics: kitK, spec: spec, previousNormal: pose.normal))
        let order = fit.cornersInPoseOrder(bad)
        let d = try XCTUnwrap(HonestTilt.detection(pose: fit.pose, quad: order, view: view, parallel: noise, turn: turn, settings: SettleSettings()))
        XCTAssertEqual(d.dof, 2)
        XCTAssertGreaterThan(d.chi2, SettleSettings().misfitChi2)
        XCTAssertTrue(d.excluded)
        // half a pixel of the same: within what the noise allows
        var near = q; near[1] = near[1] + Vec2(0.25, 0.2)
        let fit2 = try XCTUnwrap(PoseSolver.solve(corners: near, intrinsics: kitK, spec: spec, previousNormal: pose.normal))
        let d2 = try XCTUnwrap(HonestTilt.detection(pose: fit2.pose, quad: fit2.cornersInPoseOrder(near), view: view, parallel: noise, turn: turn,
                                                    settings: SettleSettings()))
        XCTAssertLessThan(d2.chi2, SettleSettings().misfitChi2)
        var h = HonestTilt(settings: SettleSettings())
        h.add(d)
        XCTAssertTrue(h.groups.isEmpty)
        XCTAssertNil(h.sigmaDegrees)
        h.add(d2)
        XCTAssertEqual(h.groups.count, 1)
    }

    // MARK: through the tracker

    /// Reports the world's outline with noise, and for its first `biasedCalls` calls with one side moved outward (an
    /// edge taken on the cut face).
    final class BiasedDetector: SlabDetecting {
        let truth: TruthDetector
        var biasedCalls: Int
        var side: Int
        var pixels: Double
        private(set) var calls = 0
        init(_ w: World, biasedCalls: Int, side: Int = 0, pixels: Double) {
            truth = TruthDetector(w); truth.noise = 0.25; self.biasedCalls = biasedCalls; self.side = side; self.pixels = pixels
        }
        func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
            calls += 1
            truth.corruptSide = calls <= biasedCalls ? (side, pixels) : nil
            return truth.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near)
        }
    }

    /// The review's s04-still case: a still camera whose first 8 detections have a side on the cut face and the next 10
    /// on the top. The lock forms on the biased ones and keeps its 15-deep estimate; the honest estimate follows the
    /// correct ones within a second (its view keeps only its newest 3).
    func testBiasedDetectionsAgeOutOfTheHonestEstimate() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -0.8), tilt: 6, heading: 70))
        let det = BiasedDetector(w, biasedCalls: 8, side: 0, pixels: 2)
        var s = TrackerSettings(); s.recheckInterval = 0.3
        let tr = SlabTracker(settings: s, detector: det)
        let v = w.view(from: Vec3(0, 0.75, 0), at: w.slab.center)
        var t = 0.0, firstCorrect: Double? = nil, followedAt: Double? = nil, lockAt: Double? = nil
        var lockErrAtFollow = 0.0
        while det.calls < 18 && t < 10 {
            det.truth.currentView = v
            let o = tr.process(TrackerFrame(timestamp: t, view: v, frame: blank))
            if o.state == .locked && lockAt == nil { lockAt = t }
            if det.calls == 9 && firstCorrect == nil { firstCorrect = t }
            if let fc = firstCorrect, followedAt == nil, let n = tr.settledNormal, Units.degrees(n.angle(to: w.slab.normal)) < 0.5 {
                followedAt = t - fc
                lockErrAtFollow = Units.degrees(try XCTUnwrap(tr.imageSlab).normal.angle(to: w.slab.normal))
            }
            t += 0.05
        }
        print(String(format: "HONEST biased-then-correct: locked at %.2f s; honest within 0.5 deg %.2f s after the first correct detection; the lock then %.2f deg off",
                     lockAt ?? -1, followedAt ?? -1, lockErrAtFollow))
        XCTAssertNotNil(lockAt, "the lock still forms")
        XCTAssertNotNil(followedAt)
        XCTAssertLessThanOrEqual(followedAt ?? 99, 1.0)
        XCTAssertEqual(tr.state, .locked)
    }

    /// The app's readouts come from the settled normal (with `readoutsFromSettledNormal`), the outline from the lock; a
    /// steep view stays settling; a world-frame discontinuity starts settling again.
    func testSettlingThroughTheTracker() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -0.9), tilt: 8, heading: 30))
        func run(from pos: Vec3, seconds: Double, tracker tr: SlabTracker? = nil, _ det: TruthDetector) -> (SlabTracker, [TrackerOutput]) {
            var s = TrackerSettings(); s.recheckInterval = 0.3; s.readoutsFromSettledNormal = true
            let tr = tr ?? SlabTracker(settings: s, detector: det)
            let v = w.view(from: pos, at: w.slab.center)
            var outs: [TrackerOutput] = [], t = tr.lastFrameTime > 0 ? tr.lastFrameTime + 0.05 : 0
            let end = t + seconds
            while t < end {
                det.currentView = v
                outs.append(tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)))
                t += 0.05
            }
            return (tr, outs)
        }
        // from about 45 deg above the horizon, 0.9 m: settles once the corner noise is measured, and shows the truth
        let det = TruthDetector(w); det.noise = 0.2
        let (tr, outs) = run(from: Vec3(0, 0.7, 0), seconds: 5, det)
        let settledAt = outs.firstIndex { $0.angleSettled }.map { Double($0) * 0.05 }
        let lockedAt = outs.firstIndex { $0.state == .locked }.map { Double($0) * 0.05 }
        let last = try XCTUnwrap(outs.last)
        print(String(format: "HONEST moderate view: locked %.2f s, settled %.2f s, sigma %.2f deg, %d view(s), corner noise %.2f px",
                     lockedAt ?? -1, settledAt ?? -1, last.tiltSigmaDegrees ?? -1, last.viewGroups, tr.cornerNoiseEstimate))
        XCTAssertNotNil(settledAt)
        XCTAssertTrue(last.angleSettled)
        XCTAssertLessThanOrEqual(try XCTUnwrap(last.tiltSigmaDegrees), 1.0)
        let n = try XCTUnwrap(tr.settledNormal)
        XCTAssertLessThan(Units.degrees(n.angle(to: w.slab.normal)), 1.0)
        // the readouts' tilt is the settled normal's; the outline is the lock's
        XCTAssertEqual(try XCTUnwrap(last.readouts).tiltDegrees, Units.degrees(acos(n.y)), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(last.outline), try XCTUnwrap(tr.project(try XCTUnwrap(last.slab), w.view(from: Vec3(0, 0.7, 0), at: w.slab.center))))
        // the log says what each detection added
        XCTAssertNotNil(tr.detectionLog.last?.viewSigmaDegrees)
        XCTAssertEqual(tr.detectionLog.last?.misfitExcluded, false)

        // a world-frame discontinuity: settling again until re-checks rebuild the views
        tr.noteWorldDiscontinuity("test")
        let (_, after) = run(from: Vec3(0, 0.7, 0), seconds: 2, tracker: tr, det)
        // (the first frame after it runs a re-check, which starts the views again: one view, one refresh)
        XCTAssertFalse(after.first!.angleSettled)
        XCTAssertLessThanOrEqual(after.first!.viewGroups, 1)
        XCTAssertTrue(after.last!.angleSettled, "settled again on the re-checks after the discontinuity")

        // nearly straight above (85 deg above the horizon), 1 m: one view, wide: settling
        let det2 = TruthDetector(w); det2.noise = 0.2
        let (tr2, outs2) = run(from: Vec3(0, 0.06 + sin(Units.radians(85)), -0.9 + cos(Units.radians(85))), seconds: 5, det2)
        let locked2 = outs2.filter { $0.state == .locked }
        print(String(format: "HONEST steep view: %d locked frames, sigma %.2f deg, settled on %d",
                     locked2.count, locked2.last?.tiltSigmaDegrees ?? -1, locked2.filter { $0.angleSettled }.count))
        if !locked2.isEmpty {
            XCTAssertTrue(locked2.allSatisfy { !$0.angleSettled })
            XCTAssertGreaterThan(locked2.last?.tiltSigmaDegrees ?? 0, 1.0)
            // while settling the readouts are the lock's
            let s2 = try XCTUnwrap(locked2.last?.slab)
            XCTAssertEqual(try XCTUnwrap(locked2.last?.readouts).tiltDegrees, Units.degrees(s2.tilt(down: Vec3(0, -1, 0))), accuracy: 1e-9)
        }
        XCTAssertEqual(tr2.angleSettled, false)
    }

    /// The diagnostics say how sure the tilt is: its sigma, whether it is shown, on how many views, and its tilt; and an
    /// older report without them still reads.
    func testDiagnosticsExportTheSettling() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -0.9), tilt: 8, heading: 30))
        let det = TruthDetector(w); det.noise = 0.2
        var s = TrackerSettings(); s.recheckInterval = 0.3
        let tr = SlabTracker(settings: s, detector: det)
        let v = w.view(from: Vec3(0, 0.7, 0), at: w.slab.center)
        var o: TrackerOutput! = nil
        for k in 0..<100 { det.currentView = v; o = tr.process(TrackerFrame(timestamp: Double(k) * 0.05, view: v, frame: blank)) }
        var rep = DiagnosticsReport(build: "n11", device: "test", system: "linux", time: "now", settings: RecordingSettings(), state: o.state.rawValue,
                                    tracking: "normal", fps: 30, msProcess: 4, lens: v.intrinsics, depthSupported: false, depth: nil, captureLocked: true,
                                    slab: o.slab, outline: o.outline, sideModes: [], ball: nil, readouts: o.readouts, counts: tr.counts,
                                    recentEvents: o.events, recording: nil)
        rep.addTracker(tr, view: v, output: o)
        let back = try DiagnosticsReport.decode(json: rep.json())
        XCTAssertEqual(back.angleSettled, true)
        XCTAssertEqual(back.viewGroups, 1)
        XCTAssertEqual(try XCTUnwrap(back.tiltSigmaDegrees), try XCTUnwrap(o.tiltSigmaDegrees), accuracy: 0.006)
        XCTAssertEqual(try XCTUnwrap(back.settledTiltDegrees), 8, accuracy: 1)
        XCTAssertNotNil(back.frames?["tiltSigmaDegrees"])
        XCTAssertNotNil(back.history?.last?.viewSigmaDegrees)
        var old = try JSONSerialization.jsonObject(with: Data(rep.json().utf8)) as! [String: Any]
        for k in ["tiltSigmaDegrees", "angleSettled", "viewGroups", "settledTiltDegrees", "depthChecks"] { old[k] = nil }
        let oldBack = try DiagnosticsReport.decode(json: String(data: JSONSerialization.data(withJSONObject: old), encoding: .utf8)!)
        XCTAssertNil(oldBack.angleSettled)
    }

    /// A diagnostics file from the phone (BOUNCE_DIAGNOSTICS: a path; e.g. the owner's n10 report, kept outside the
    /// repository) still reads, and its tracker settings, written before n11, read the centre's LiDAR weight as the normal's.
    func testADiagnosticsFileFromTheEnvironmentStillReads() throws {
        guard let path = ProcessInfo.processInfo.environment["BOUNCE_DIAGNOSTICS"] else { throw XCTSkip("set BOUNCE_DIAGNOSTICS to a diagnostics file") }
        let rep = try DiagnosticsReport.decode(json: String(contentsOfFile: path, encoding: .utf8))
        let t = try XCTUnwrap(rep.tracker)
        print("DIAGNOSTICS build \(rep.build): state \(rep.state), depthNormalWeight \(t.depthNormalWeight), depthCentreWeight \(t.depthCentreWeight), "
              + "settled \(rep.angleSettled.map { "\($0)" } ?? "not reported")")
        if rep.angleSettled == nil { XCTAssertEqual(t.depthCentreWeight, t.depthNormalWeight) }
    }

    /// With the setting off (older recordings) the readouts stay the lock's even when settled.
    func testReadoutsStayTheLocksWithTheSettingOff() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -0.9), tilt: 8, heading: 30))
        let det = TruthDetector(w); det.noise = 0.2
        var s = TrackerSettings(); s.recheckInterval = 0.3
        XCTAssertFalse(s.readoutsFromSettledNormal)
        let tr = SlabTracker(settings: s, detector: det)
        let v = w.view(from: Vec3(0, 0.7, 0), at: w.slab.center)
        var o: TrackerOutput! = nil
        for k in 0..<100 { det.currentView = v; o = tr.process(TrackerFrame(timestamp: Double(k) * 0.05, view: v, frame: blank)) }
        XCTAssertTrue(o.angleSettled)
        let lock = try XCTUnwrap(o.slab)
        XCTAssertEqual(try XCTUnwrap(o.readouts).tiltDegrees, Units.degrees(lock.tilt(down: Vec3(0, -1, 0))), accuracy: 1e-12)
    }
}
