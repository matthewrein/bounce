import XCTest
@testable import BounceCore

final class PoseSolverTests: XCTestCase {
    func testExactCornersRecoverPose() {
        for (i, (tilt, heading, yaw, dist, pitch)) in [(0.0, 0.0, 0.0, 1.0, 50.0), (8, 30, 15, 1.2, 50), (12, 200, -30, 1.5, 40),
                                                         (18, 95, 60, 0.7, 65), (5, 300, 5, 0.6, 30)].enumerated() {
            let s = SyntheticView.make(pitch: pitch, distance: dist, tilt: tilt, heading: heading, yaw: yaw)
            var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
            let fit = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: s.down, options: opt)
            XCTAssertNotNil(fit, "case \(i)")
            guard let f = fit else { continue }
            XCTAssertLessThan(angleDeg(f.pose.normal, s.pose.normal), 0.01, "case \(i) normal")
            XCTAssertLessThan(f.pose.center.distance(to: s.pose.center), 1e-5, "case \(i) centre")
            XCTAssertLessThan(f.rmsPixels, 1e-3, "case \(i) rms")
            XCTAssertEqual(Units.degrees(f.pose.tilt(down: s.down)), tilt, accuracy: 0.01, "case \(i) tilt")
        }
    }

    func testNormalPointsTowardCamera() {
        let s = SyntheticView.make(tilt: 10, heading: 120)
        let f = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: s.down)!
        XCTAssertLessThan(f.pose.normal.dot(f.pose.center), 0) // faces the camera
        XCTAssertLessThan(f.pose.normal.dot(s.down), 0)          // and points up
    }

    func testCornerOrderInvariance() {
        // the outline may start at any corner and run either way round: the plane must come out the same
        let s = SyntheticView.make(tilt: 9, heading: 45, yaw: 20)
        let base = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: s.down)!
        for shift in 0..<4 {
            for reverse in [false, true] {
                var q = Array(s.corners[shift...] + s.corners[..<shift])
                if reverse { q.reverse() }
                let f = PoseSolver.solve(corners: q, intrinsics: s.intrinsics, spec: s.spec, down: s.down)!
                XCTAssertLessThan(angleDeg(f.pose.normal, base.pose.normal), 0.01, "shift \(shift) reverse \(reverse)")
            }
        }
    }

    func testNoiseGivesSmallErrorWithRealIntrinsics() {
        // 1 px corner noise at 4 ft with an iPhone-like lens: tilt error stays well under a degree
        var rng = SeededRandom(7)
        var errs: [Double] = []
        for k in 0..<200 {
            let s = SyntheticView.make(pitch: rng.uniform(35, 65), distance: rng.uniform(0.9, 1.5), tilt: rng.uniform(0, 12),
                                       heading: rng.uniform(0, 360), yaw: rng.uniform(-45, 45))
            let f = PoseSolver.solve(corners: s.noisyCorners(sigma: 1, rng: &rng), intrinsics: s.intrinsics, spec: s.spec, down: s.down)
            XCTAssertNotNil(f, "trial \(k)")
            if let f = f { errs.append(angleDeg(f.pose.normal, s.pose.normal)) }
        }
        errs.sort()
        XCTAssertLessThan(errs[errs.count / 2], 0.8)
        XCTAssertLessThan(errs[Int(Double(errs.count) * 0.9)], 1.6)
    }

    func testRectangleSidesMatchedEitherWay() {
        let spec = SlabSpec(sideU: Units.inches(7.2), sideV: Units.inches(6.8), thickness: Units.inches(1), dishDepth: 0)
        let s = SyntheticView.make(tilt: 6, heading: 80, yaw: 10, spec: spec)
        let q = Array(s.corners[1...] + s.corners[..<1]) // start the outline on the other kind of side
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        let f = PoseSolver.solve(corners: q, intrinsics: s.intrinsics, spec: spec, down: s.down, options: opt)!
        XCTAssertLessThan(angleDeg(f.pose.normal, s.pose.normal), 0.01)
        XCTAssertTrue(f.swappedSides)
        XCTAssertLessThan(f.rmsPixels, 1e-3)
    }

    func testWrongSizeShowsAsDistanceNotTilt() {
        // a slab 5% bigger than assumed: the fitted plane keeps its tilt, only the distance scales
        let big = SlabSpec(sideU: Units.inches(7.35), sideV: Units.inches(7.35), thickness: Units.inches(1), dishDepth: 0)
        let s = SyntheticView.make(tilt: 9, heading: 10, spec: big)
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        let f = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: .standard, down: s.down, options: opt)!
        XCTAssertLessThan(angleDeg(f.pose.normal, s.pose.normal), 0.01)
        XCTAssertEqual(f.pose.center.length / s.pose.center.length, 1 / 1.05, accuracy: 1e-4)
    }

    func testMirrorAmbiguityHysteresis() {
        // far away and nearly face-on, both mirror solutions fit; with the previous normal given, the solver keeps it
        let s = SyntheticView.make(pitch: 80, distance: 2.5, tilt: 4, heading: 90)
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        let f = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: nil, previousNormal: s.pose.normal, options: opt)!
        XCTAssertLessThan(angleDeg(f.pose.normal, s.pose.normal), 0.05)
    }

    func testShapeCheck() {
        let s = SyntheticView.make(tilt: 8)
        let f = PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: s.down)
        XCTAssertEqual(ShapeCheck.check(f, outline: s.corners, down: s.down), .ok)
        // a bow-tie is not convex
        let bow = [s.corners[0], s.corners[2], s.corners[1], s.corners[3]]
        XCTAssertEqual(ShapeCheck.check(f, outline: bow, down: s.down), .notConvex)
        // a strongly sheared outline is not a square
        var q = s.corners; q[2] = q[2] + Vec2(60, 0)
        let f2 = PoseSolver.solve(corners: q, intrinsics: s.intrinsics, spec: s.spec, down: s.down)
        if case .misfit = ShapeCheck.check(f2, outline: q, down: s.down) {} else { XCTFail("expected misfit") }
        // steep tilt rejected
        let t = SyntheticView.make(tilt: 35, heading: 0)
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        let f3 = PoseSolver.solve(corners: t.corners, intrinsics: t.intrinsics, spec: t.spec, down: t.down, options: opt)
        if case .tooTilted = ShapeCheck.check(f3, outline: t.corners, down: t.down) {} else { XCTFail("expected too tilted") }
    }

    /// The lens the tracker really runs at: ARKit's 1920x1440 image divided by 4 (ARController's processing frame).
    static let processingLens = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440).scaled(by: 0.25)

    func testOutlineEitherWayRoundMapsOntoThePoseCorners() {
        // An outline running clockwise on screen (positive shoelace area with y down, as a monotone-chain hull gives) is
        // matched to the pose's corners in reverse. The fit says so, and lookups by the outline's own sides find the
        // physically near side's cut face, not the far side's.
        let s = SyntheticView.make(pitch: 45, distance: 0.6, tilt: 0, heading: 0, yaw: 10)
        let K = s.intrinsics
        XCTAssertLessThan(ShapeCheck.signedArea(s.corners), 0) // pose order runs anticlockwise on screen
        for reverse in [false, true] {
            for shift in 0..<4 {
                var q = Array(s.corners[shift...] + s.corners[..<shift])
                if reverse { q.reverse() }
                let tag = "shift \(shift) reverse \(reverse)"
                let fit = PoseSolver.solve(corners: q, intrinsics: K, spec: s.spec, down: s.down)!
                XCTAssertEqual(fit.outlineReversed, ShapeCheck.signedArea(q) > 0, tag)
                XCTAssertEqual(fit.outlineReversed, reverse, tag)
                for j in 0..<4 { XCTAssertLessThan(K.project(fit.outlineTopCorners[j])!.distance(to: q[j]), 1e-6, tag) }
                for i in 0..<4 { XCTAssertLessThan(K.project(fit.pose.topCorners[i])!.distance(to: q[fit.cornerOrder[i]]), 1e-6, tag) }
                let inPoseOrder = fit.cornersInPoseOrder(q)
                for i in 0..<4 { XCTAssertLessThan(K.project(fit.pose.topCorners[i])!.distance(to: inPoseOrder[i]), 1e-6, tag) }
                // sides: pose side <-> outline side round trip, and per-side values rearranged consistently
                for j in 0..<4 {
                    let (ps, rev) = fit.poseSide(forOutlineSide: j)
                    XCTAssertEqual(fit.outlineSide(forPoseSide: ps).side, j, tag)
                    XCTAssertEqual(fit.outlineSide(forPoseSide: ps).reversed, rev, tag)
                    XCTAssertEqual(rev, reverse, tag)
                }
                let modes = ["a", "b", "c", "d"], pm = fit.sidesInPoseOrder(modes)
                for i in 0..<4 { XCTAssertEqual(pm[i], modes[fit.outlineSide(forPoseSide: i).side], tag) }
                // the box model by outline sides: the near side (nearest the camera) shows its cut face, the far one not
                let box = SlabBoxView(fit: fit, spec: s.spec, intrinsics: K)
                let tc = fit.outlineTopCorners
                let mid = (0..<4).map { j in ((tc[j] + tc[(j + 1) % 4]) / 2).length }
                let near = (0..<4).min { mid[$0] < mid[$1] }!, far = (0..<4).max { mid[$0] < mid[$1] }!
                XCTAssertTrue(box.cutFaceVisible(outlineSide: near), tag)
                XCTAssertFalse(box.cutFaceVisible(outlineSide: far), tag)
                // its band, start at outline corner `near`: how far the bottom corner below it lies from the side's line
                let w = box.cutBandWidth(outlineSide: near), a = q[near], b = q[(near + 1) % 4], dir = (b - a).normalized
                let bs = K.project(box.outlineBottomCorners[near])!, be = K.project(box.outlineBottomCorners[(near + 1) % 4])!
                XCTAssertEqual(w.start, abs(dir.cross(bs - a)), accuracy: 1e-6, tag)
                XCTAssertEqual(w.end, abs(dir.cross(be - b)), accuracy: 1e-6, tag)
                XCTAssertGreaterThan(w.start, 5, tag)
                // the cut-bottom outline in outline order moves only the near side's two corners
                let cb = box.outlineWithCutBottom(onOutlineSides: [near])!
                for j in 0..<4 {
                    let moved = cb[j].distance(to: q[j])
                    if j == near || j == (near + 1) % 4 { XCTAssertGreaterThan(moved, 3, tag) } else { XCTAssertLessThan(moved, 1e-6, tag) }
                }
            }
        }
    }

    func testBothSideAssignmentsOfARectangle() {
        // A 7.2 x 6.8 in slab: both assignments come back with their costs. The long side's direction is what tells
        // them apart (axisU runs along the outline's first side in both). Exact corners: the right one is cheaper.
        let spec = SlabSpec(sideU: Units.inches(7.2), sideV: Units.inches(6.8), thickness: Units.inches(1), dishDepth: 0)
        let s = SyntheticView.make(tilt: 6, heading: 80, yaw: 10, spec: spec)
        let fits = PoseSolver.solveAssignments(corners: s.corners, intrinsics: s.intrinsics, spec: spec, down: s.down)
        XCTAssertEqual(fits.count, 2)
        let right = fits.first { !$0.swappedSides }!, wrong = fits.first { $0.swappedSides }!
        XCTAssertLessThan(right.cost, wrong.cost)
        XCTAssertEqual(right.alternativeCost!, wrong.cost, accuracy: 1e-12)
        XCTAssertEqual(wrong.alternativeCost!, right.cost, accuracy: 1e-12)
        XCTAssertLessThan(abs(right.longSide!.dot(s.pose.axisU)), 1 + 1e-9)
        XCTAssertGreaterThan(abs(right.longSide!.dot(s.pose.axisU)), 0.9999)
        XCTAssertLessThan(abs(wrong.longSide!.dot(s.pose.axisU)), 0.2)
        XCTAssertEqual(abs(right.pose.axisU.dot(wrong.pose.axisU)), 1, accuracy: 0.05)
        XCTAssertEqual(PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: spec, down: s.down)!.swappedSides, false)
        // a square slab has one assignment and no long side
        let sq = PoseSolver.solveAssignments(corners: s.corners, intrinsics: s.intrinsics, spec: .standard, down: s.down)
        XCTAssertEqual(sq.count, 1)
        XCTAssertNil(sq[0].longSide)
        XCTAssertNil(sq[0].alternativeCost)

        // Under corner noise one frame's choice is often wrong, and the wrong choice tilts the normal by degrees; the
        // costs summed over a few frames of the same view choose well (what SlabTracker does with its long-side evidence).
        var rng = SeededRandom(21)
        var wrongSingle = 0, wrongSummed = 0, singles = 0, views = 0
        for _ in 0..<120 {
            let v = SyntheticView.make(pitch: rng.uniform(35, 65), distance: rng.uniform(0.6, 1.5), tilt: rng.uniform(0, 10),
                                       heading: rng.uniform(0, 360), yaw: rng.uniform(-45, 45), spec: spec)
            let start = Int(rng.uniform(0, 2)) // the outline starts on either kind of side
            var sumRight = 0.0, sumWrong = 0.0
            for _ in 0..<8 {
                let q0 = v.noisyCorners(sigma: 1.5, rng: &rng), q = Array(q0[start...] + q0[..<start])
                let f = PoseSolver.solveAssignments(corners: q, intrinsics: v.intrinsics, spec: spec, down: v.down)
                guard f.count == 2 else { continue }
                let isRight = { (p: PoseFit) in abs(p.longSide!.dot(v.pose.axisU)) > 0.7 }
                let r = f.first(where: isRight)!, w = f.first { !isRight($0) }!
                singles += 1
                if w.cost < r.cost { wrongSingle += 1 }
                sumRight += r.cost; sumWrong += w.cost
            }
            views += 1
            if sumWrong < sumRight { wrongSummed += 1 }
        }
        print("rectangle at 1.5 px: wrong per frame \(wrongSingle)/\(singles), wrong over 8 frames \(wrongSummed)/\(views)")
        XCTAssertGreaterThan(Double(wrongSingle) / Double(singles), 0.05)
        XCTAssertLessThan(Double(wrongSummed) / Double(views), 0.03)
    }

    func testNoiseAtTheTrackersProcessingResolution() {
        // The tracker solves on the 480x360 processing frame (fx about 362), where 1 px of corner noise is 4 px at full
        // resolution. The same 200 views as testNoiseGivesSmallErrorWithRealIntrinsics: 1 px there gives a per-frame
        // normal error about 4x larger; the 0.8 deg median of the full-resolution test needs about 0.25 px corners here,
        // the noise budget a ported detector would have to meet for single frames to be that good (the tracker averages).
        func run(sigma: Double) -> (median: Double, p90: Double, ratio: Double) {
            var rng = SeededRandom(7)
            var errs: [Double] = [], ratios: [Double] = []
            for _ in 0..<200 {
                let s = SyntheticView.make(pitch: rng.uniform(35, 65), distance: rng.uniform(0.9, 1.5), tilt: rng.uniform(0, 12),
                                           heading: rng.uniform(0, 360), yaw: rng.uniform(-45, 45), intrinsics: PoseSolverTests.processingLens)
                guard let f = PoseSolver.solve(corners: s.noisyCorners(sigma: sigma, rng: &rng), intrinsics: s.intrinsics, spec: s.spec, down: s.down) else {
                    XCTFail("no fit"); continue
                }
                let e = angleDeg(f.pose.normal, s.pose.normal)
                errs.append(e)
                ratios.append(e / (f.normalSigmaDegrees * sigma))  // the fit's sigma is for 1 px
            }
            errs.sort(); ratios.sort()
            return (errs[errs.count / 2], errs[Int(Double(errs.count) * 0.9)], ratios[ratios.count / 2])
        }
        let one = run(sigma: 1), quarter = run(sigma: 0.25)
        print(String(format: "processing lens: 1 px median %.2f p90 %.2f deg (err/sigma %.2f); 0.25 px median %.2f p90 %.2f deg",
                     one.median, one.p90, one.ratio, quarter.median, quarter.p90))
        XCTAssertGreaterThan(one.median, 1.5)       // honestly worse than the full-resolution test suggests
        XCTAssertLessThan(one.median, 3.0)
        XCTAssertLessThan(one.p90, 6.0)
        XCTAssertLessThan(quarter.median, 0.8)
        XCTAssertLessThan(quarter.p90, 1.6)
        // the reported sigma is calibrated: for a 2-D error with total standard deviation sigma, the median error is
        // about 0.83 sigma
        XCTAssertEqual(one.ratio, 0.83, accuracy: 0.25)
        XCTAssertEqual(quarter.ratio, 0.83, accuracy: 0.25)
    }

    func testNearOverheadViewsAreFlaggedAsIllConditioned() {
        // Looking nearly straight down, the corners barely show the tilt (a few pixels of keystone): the fit's normal
        // sigma says so, and ShapeCheck with a sigma limit refuses such a fit instead of passing a tilt that is off by
        // 5-15 deg.
        var rng = SeededRandom(5)
        func sigmas(pitch: Double) -> [Double] {
            (0..<40).compactMap { _ in
                let s = SyntheticView.make(pitch: pitch, distance: rng.uniform(0.9, 1.5), tilt: rng.uniform(2, 10), heading: rng.uniform(0, 360),
                                           yaw: rng.uniform(-45, 45), intrinsics: PoseSolverTests.processingLens)
                return PoseSolver.solve(corners: s.corners, intrinsics: s.intrinsics, spec: s.spec, down: s.down)?.normalSigmaDegrees
            }.sorted()
        }
        let m45 = sigmas(pitch: 45), m85 = sigmas(pitch: 85)
        let med45 = m45[m45.count / 2], med85 = m85[m85.count / 2]
        print(String(format: "normal sigma at 1 px, processing lens: pitch 45 median %.2f, pitch 85 median %.2f deg", med45, med85))
        XCTAssertGreaterThan(med85, 2.5 * med45)
        var lim = ShapeCheck.Limits(); lim.maxNormalSigmaDegrees = 6
        let steep = SyntheticView.make(pitch: 85, distance: 1.5, tilt: 5, heading: 30, intrinsics: PoseSolverTests.processingLens)
        let fs = PoseSolver.solve(corners: steep.corners, intrinsics: steep.intrinsics, spec: steep.spec, down: steep.down)
        if case .illConditioned(let sg) = ShapeCheck.check(fs, outline: steep.corners, down: steep.down, limits: lim) {
            XCTAssertGreaterThan(sg, 6)
        } else { XCTFail("expected ill-conditioned, got \(ShapeCheck.check(fs, outline: steep.corners, down: steep.down, limits: lim))") }
        XCTAssertEqual(ShapeCheck.check(fs, outline: steep.corners, down: steep.down), .ok) // no limit: the old behaviour
        let good = SyntheticView.make(pitch: 45, distance: 1.0, tilt: 5, heading: 30, intrinsics: PoseSolverTests.processingLens)
        let fg = PoseSolver.solve(corners: good.corners, intrinsics: good.intrinsics, spec: good.spec, down: good.down)
        XCTAssertEqual(ShapeCheck.check(fg, outline: good.corners, down: good.down, limits: lim), .ok)
    }

    func testVerdictKeysHaveNoValues() {
        XCTAssertEqual(ShapeCheck.Verdict.misfit(0.0312345).key, "misfit")
        XCTAssertEqual(ShapeCheck.Verdict.tooTilted(27.123).key, "tooTilted")
        XCTAssertEqual(ShapeCheck.Verdict.illConditioned(7.5).key, "illConditioned")
        XCTAssertEqual(ShapeCheck.Verdict.notConvex.key, "notConvex")
        XCTAssertEqual(ShapeCheck.Verdict.misfit(0.04).value, 0.04)
        XCTAssertNil(ShapeCheck.Verdict.tooFar.value)
    }
}
