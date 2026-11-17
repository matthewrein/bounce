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
}
