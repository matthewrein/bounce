import XCTest
@testable import BounceCore

/// Ground truth exported from the web test bed (web/tests/export_ios.js): rendered three.js scenes with exact corners,
/// normals and ball drop heights.
enum Fixtures {
    static var root: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }
    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name)))
    }
    static func recording(_ name: String) throws -> RecordingReader {
        try RecordingReader(folder: root.appendingPathComponent(name))
    }
    static func truth(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name).appendingPathComponent("truth.json"))) as! [String: Any]
    }
}

func vec3(_ a: Any?) -> Vec3? { (a as? [Double]).map { Vec3($0) } ?? (a as? [NSNumber]).map { Vec3($0.map { $0.doubleValue }) } }
func vec2s(_ a: Any?) -> [Vec2]? { (a as? [[Double]])?.map { Vec2($0[0], $0[1]) } }
func dbl(_ a: Any?) -> Double { (a as? Double) ?? (a as? NSNumber)?.doubleValue ?? .nan }

final class FixtureTests: XCTestCase {
    func spec(_ r: [String: Any]) -> SlabSpec {
        SlabSpec(sideU: Units.inches(dbl(r["sideUInches"])), sideV: Units.inches(dbl(r["sideVInches"])),
                 thickness: Units.inches(dbl(r["thicknessInches"])), dishDepth: Units.inches(dbl(r["dishInches"])))
    }

    /// The pose from the true corners and the true lens matches the rendered slab's normal on every exported frame.
    func testPoseFromTrueCornersMatchesRenderedNormal() throws {
        let rows = try Fixtures.json("gt_poses.json") as! [[String: Any]]
        XCTAssertGreaterThan(rows.count, 100)
        var errs: [Double] = [], tiltErrs: [Double] = []
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        for r in rows {
            let K = CameraIntrinsics(verticalFovDegrees: dbl(r["fovDeg"]), width: 720, height: 1280)
            let q = vec2s(r["corners"])!, n = vec3(r["normal"])!, g = vec3(r["down"])!
            guard let fit = PoseSolver.solve(corners: q, intrinsics: K, spec: spec(r), down: g, options: opt) else {
                XCTFail("no pose for \(r["clip"]!) \(r["fi"]!)"); continue
            }
            errs.append(angleDeg(fit.pose.normal, n))
            tiltErrs.append(abs(Units.degrees(fit.pose.tilt(down: g)) - dbl(r["tiltDeg"])))
        }
        errs.sort(); tiltErrs.sort()
        // corners are given to 0.01 px: the normal comes back almost exactly
        XCTAssertLessThan(errs[errs.count / 2], 0.01)
        XCTAssertLessThan(errs.last!, 0.1)
        XCTAssertLessThan(tiltErrs.last!, 0.1)
    }

    /// Drop height from the ball's image circle and the slab pose, against the renderer's truth.
    func testDropHeightFromBallCircle() throws {
        let rows = try Fixtures.json("gt_balls.json") as! [[String: Any]]
        XCTAssertGreaterThan(rows.count, 20)
        var errs: [Double] = []
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        for r in rows {
            let K = CameraIntrinsics(verticalFovDegrees: dbl(r["fovDeg"]), width: 720, height: 1280)
            let q = vec2s(r["corners"])!, g = vec3(r["down"])!, b = r["ball"] as! [String: Any]
            let ball = BallSpec(diameter: dbl(r["ballDiameterMm"]) / 1000)
            guard let fit = PoseSolver.solve(corners: q, intrinsics: K, spec: spec(r), down: g, options: opt),
                  let B = Bounce.ballCenter(pixel: Vec2(dbl(b["x"]), dbl(b["y"])), radiusPixels: dbl(b["r"]), intrinsics: K, ball: ball, model: .onAxis),
                  let d = Bounce.drop(ballCenter: B, pose: fit.pose, spec: spec(r), ball: ball, down: g) else {
                XCTFail("no drop for \(r["clip"]!) \(r["fi"]!)"); continue
            }
            XCTAssertTrue(d.onSlab, "\(r["clip"]!) \(r["fi"]!)")
            errs.append(abs(d.dropHeight - dbl(b["dropMetres"])))
        }
        errs.sort()
        // the circle's radius is given to 0.01 px; depth from size then puts the drop within a few mm
        XCTAssertLessThan(errs[errs.count / 2], 0.005)
        XCTAssertLessThan(errs[Int(Double(errs.count) * 0.9)], 0.015)
    }

    /// A recording exported from the test bed reads back, and its camera poses agree with the true corners.
    func testRecordingReadsAndPosesAgreeWithTruth() throws {
        let rec = try Fixtures.recording("rec_replay_still"), truth = try Fixtures.truth("rec_replay_still")
        XCTAssertEqual(rec.session.format, "bouncerec")
        XCTAssertEqual(rec.frames.count, 8)
        let tf = truth["frames"] as! [[String: Any]]
        for (f, t) in zip(rec.frames, tf) {
            let img = try rec.image(for: f)
            XCTAssertEqual(img.width, rec.session.frameWidth); XCTAssertEqual(img.height, rec.session.frameHeight)
            // the world corners projected through the recorded camera land on the true corner pixels
            let cw = (t["slabCornersWorld"] as! [[Double]]).map { Vec3($0) }, cp = vec2s(t["cornersPixels"])!
            for (w, p) in zip(cw, cp) {
                let q = f.view.project(world: w)!
                XCTAssertLessThan(q.distance(to: p), 0.3, "frame \(f.index)")
            }
            // and gravity from the world (y up) matches the recorded sensor gravity
            let g = f.view.directionToCamera(ARKitConvention.worldDown), gs = Vec3(f.gravityCamera!)
            XCTAssertLessThan(angleDeg(g, gs), 0.05)
        }
    }
}
