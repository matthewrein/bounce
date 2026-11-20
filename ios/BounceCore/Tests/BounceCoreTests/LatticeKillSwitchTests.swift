import XCTest
@testable import BounceCore

/// The lattice finder's kill switch (`BallFinder.Options.lattice` off): the finder is then n14's (n11's). On the
/// ball-crop fixtures and on SyntheticScene's polished ball (`BallLook.polished`, the ball n14's scenes drew), the app's
/// locator (three scans) and the drop-following locator (`BallLocator.Options.tracking`, one scan) give what n14 gave.
/// The expectations were printed by n14 (build 6b23e84) running this test's code; n15 with the lattice off printed the
/// same, to the last of the six decimals. (On the owner's two kits the same switch gave n11's finds on all 3,249 of the
/// phone's own searches.)
final class LatticeKillSwitchTests: XCTestCase {
    /// what n14 found, per picture: the app's three scans, then the tracking locator's scan ("x y r partial missed drop",
    /// or nil)
    static let n14: [String: (app: [String], tracking: String)] = [
        "ball_held_d4_30": (["nil", "160.009263 96.600399 21.872341 1 0 0.609368", "160.017415 96.613393 21.868631 1 0 0.609291"],
                            "160.021185 96.610320 21.875866 1 0 0.609433"),
        "ball_held_d4_90": (["nil", "163.987469 102.553763 21.655833 1 0 0.606909", "164.028309 102.927087 21.505220 0 0 0.603782"],
                            "163.988026 102.555639 21.654250 1 0 0.606878"),
        "ball_held_offcenter_d4_60": (["197.142985 268.541276 17.730605 0 0 0.469445", "197.199263 267.975159 17.996033 1 0 0.477836",
                                       "197.224333 268.182849 17.976850 0 0 0.477147"], "197.288542 267.472006 18.538801 1 0 0.493746"),
        "ball_held_satin_d4_60": (["nil", "162.753045 191.343397 18.556627 1 0 0.547202", "162.746503 191.324021 18.565862 1 0 0.547370"],
                                  "162.748329 191.318278 18.576046 1 0 0.547544"),
        "ball_held_d5_high_60": (["174.373294 25.462369 14.803899 0 0 0.913572", "174.390225 25.404178 14.834045 1 0 0.913339",
                                  "174.381517 25.433594 14.825792 0 0 0.913386"], "174.377051 25.465797 14.802201 0 0 0.913584"),
        "ball_held_d3_other_60": (["137.195212 230.280718 25.019067 0 0 0.369609", "137.185016 230.275397 25.016881 0 0 0.369579",
                                   "137.179935 230.272752 25.015346 0 0 0.369556"], "137.224361 230.283317 25.002601 0 0 0.369356"),
        "ball_held_dim_60": (["nil", "163.867765 113.769904 21.381785 1 0 0.601827", "163.832045 113.887056 21.317010 1 0 0.600780"],
                             "163.866519 113.775185 21.377794 1 0 0.601764"),
        "d4_t10_h90_mat_60": (["nil", "nil", "nil"], "nil"),
        "distract_floorball_60": (["nil", "nil", "nil"], "nil"),
        "distract_mat_circles_60": (["nil", "nil", "nil"], "nil"),
        "scene 4": (["nil", "nil", "nil"], "253.386347 323.438252 13.206912 1 0 0.106851"),
        "scene 12": (["nil", "236.823228 260.192453 14.035081 1 0 0.317606", "236.822498 260.190003 14.036413 1 0 0.317672"],
                     "236.827784 260.191115 14.036294 1 0 0.317666"),
        "scene 24": (["nil", "216.378796 153.713824 15.315769 1 0 0.620758", "216.380133 153.714224 15.315095 1 0 0.620733"],
                     "216.380501 153.717413 15.313035 1 0 0.620657"),
    ]

    static func appOptions() -> BallLocator.Options {
        var o = BallLocator.Options(); o.finder.lattice = false; return o
    }

    /// An answer against n14's: the same (nil or not, partial or not, held over or not), the circle within 0.001 px and
    /// the drop height within 0.01 mm (room for another machine's arithmetic, none for another rule).
    func check(_ o: BallObservation?, _ expected: String, _ label: String) {
        let e = expected.split(separator: " ").compactMap { Double($0) }
        guard let o else { XCTAssertEqual(expected, "nil", label + ": nothing found"); return }
        guard e.count == 6 else { XCTFail(label + ": found \(o.circle), n14 found nothing"); return }
        XCTAssertEqual(o.circle.center.x, e[0], accuracy: 1e-3, label)
        XCTAssertEqual(o.circle.center.y, e[1], accuracy: 1e-3, label)
        XCTAssertEqual(o.circle.radius, e[2], accuracy: 1e-3, label)
        XCTAssertEqual(o.circle.partial, e[3] == 1, label)
        XCTAssertEqual(o.missedUpdates, Int(e[4]), label)
        XCTAssertEqual(o.drop.dropHeight, e[5], accuracy: 1e-5, label)
        XCTAssertFalse(o.circle.lattice || o.circle.arc, label + ": a lattice reading with the lattice off")
    }

    func testTheFixturesAsInN14() throws {
        let crops = try BallCrop.all()
        XCTAssertEqual(crops.count, 10)
        for c in crops {
            guard let want = Self.n14[c.name] else { XCTFail("no n14 answer for \(c.name)"); continue }
            let slab = c.slab
            let app = BallLocator(options: Self.appOptions())
            for k in 0..<3 {
                check(app.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down), want.app[k], "\(c.name) scan \(k + 1)")
            }
            let tracking = BallLocator(options: .tracking(Self.appOptions()))
            XCTAssertFalse(tracking.options.streaks, "the drop's streaks are the lattice finder's")
            check(tracking.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down), want.tracking, "\(c.name) tracking")
        }
    }

    /// SyntheticScene's polished ball held 4, 12 and 24 in over a slab tilted 6 degrees, seen from 50 degrees up at the
    /// phone's crop (cut from 1920 x 1440 and shrunk by 2).
    func testThePolishedSceneAsInN14() throws {
        let spec = SlabSpec.standard, ball = BallSpec()
        let slab = SyntheticScene.slabPose(tilt: 6, heading: 30)
        let up = Vec3(0, 1, 0), down = Vec3(0, -1, 0)
        let Kf = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        for inches in [4.0, 12, 24] {
            let h = Units.inches(inches)
            let B = slab.center - slab.normal * spec.dishDepth + up * (ball.radius + h)
            let a = Units.radians(32), e = Units.radians(50), aim = slab.center + up * (h * 0.4)
            let full = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * (1.0 + h * 0.25), lookingAt: aim, intrinsics: Kf)
            let crop = try XCTUnwrap(BallImageCrop.plan(slab: slab, full: full))
            let view = CameraView(worldFromCamera: full.worldFromCamera, intrinsics: crop.intrinsics(full: Kf))
            let K = view.intrinsics
            let Kc = Kf.cropped(x0: Double(crop.x0), y0: Double(crop.y0), scale: 1, width: crop.width, height: crop.height)
            var scene = SyntheticScene(slab: slab, ball: B); scene.supersample = 1
            scene.ballLook = .polished
            let p = SyntheticScene.ycc(rgb: scene.renderRGB(view: CameraView(worldFromCamera: full.worldFromCamera, intrinsics: Kc)),
                                       width: crop.width, height: crop.height).luma
            let luma = crop.factor > 1 ? p.downscaled(by: crop.factor) : p
            let sc = slab.transformed(by: view.cameraFromWorld), g = view.cameraFromWorld.applyDirection(down)
            let want = try XCTUnwrap(Self.n14["scene \(Int(inches))"])
            let app = BallLocator(options: Self.appOptions())
            for k in 0..<3 {
                check(app.update(luma: luma, intrinsics: K, slab: sc, spec: spec, ball: ball, down: g), want.app[k], "\(Int(inches)) in, scan \(k + 1)")
            }
            let tracking = BallLocator(options: .tracking(Self.appOptions()))
            check(tracking.update(luma: luma, intrinsics: K, slab: sc, spec: spec, ball: ball, down: g), want.tracking, "\(Int(inches)) in, tracking")
        }
    }
}
