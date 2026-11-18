import XCTest
@testable import BounceCore

/// The CoreMotion-to-ARKit link.
final class KitMotionLinkTests: XCTestCase {
    /// A moving camera's ARKit frames and the CoreMotion samples a phone would give for them under `truth`.
    func streams(truth: KitMotionLink, frames n: Int = 40, conjugate: Bool = false, timeOffset: Double = 0) -> ([KitFrame], [KitMotionSample]) {
        let target = Vec3(0, 0.06, 0)
        func view(_ t: Double) -> CameraView {
            let a = Units.radians(20 + 60 * t), e = Units.radians(40 + 10 * sin(t * 2))
            return SyntheticScene.camera(at: target + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)), lookingAt: target,
                                         intrinsics: CameraIntrinsics(fx: 375, fy: 375, cx: 240, cy: 180, width: 480, height: 360),
                                         roll: 8 * sin(t * 3))
        }
        func arkit(_ t: Double) -> RigidTransform {
            let v = view(t)
            return RigidTransform(rotation: v.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: v.position)
        }
        let frames = (0..<n).map { i -> KitFrame in
            let t = Double(i) / 30
            return KitFrame(index: i, time: 100 + t, pose: arkit(t).columnMajor4x4.map { Float($0) }, intrinsics: [375, 375, 240, 180])
        }
        var motion: [KitMotionSample] = []
        var t = -0.05
        while t < Double(n) / 30 + 0.05 {
            var q = truth.attitude(worldFromARKitCamera: arkit(t).rotation)
            let g = q.matrix.transposed * Vec3(0, 0, -1)
            if conjugate { q = q.conjugate }
            motion.append(KitMotionSample(time: 100 + t + timeOffset, gravity: g, attitude: q))
            t += 0.01
        }
        return (frames, motion)
    }

    func testRecoversTheHeading() throws {
        for yaw in [0.0, 37, 181, 300] {
            let truth = KitMotionLink(yawDegrees: yaw, samples: 0, yawSpreadDegrees: 0, gravityMismatchDegrees: 0, attitudeConjugated: false, shotId: "")
            let (f, m) = streams(truth: truth)
            let l = try XCTUnwrap(KitMotionLink.estimate(frames: f, motion: m, shotId: "s04-level-arc").link)
            XCTAssertEqual(remainder(l.yawDegrees - yaw, 360), 0, accuracy: 0.05, "yaw \(yaw)")
            XCTAssertLessThan(l.yawSpreadDegrees, 0.1)
            XCTAssertLessThan(l.gravityMismatchDegrees, 0.1)
            XCTAssertFalse(l.attitudeConjugated)
            XCTAssertEqual(l.samples, 40)
            XCTAssertEqual(l.shotId, "s04-level-arc")
            // a direction in CoreMotion's frame comes out where it is in the world
            let n = Vec3(0.1, -0.05, 0.99).normalized
            XCTAssertLessThan(l.toWorld(n).angle(to: truth.toWorld(n)), Units.radians(0.05))
            // CoreMotion's vertical is ARKit's
            XCTAssertLessThan(l.toWorld(Vec3(0, 0, 1)).angle(to: Vec3(0, 1, 0)), 1e-9)
        }
    }

    /// Quaternions written in the opposite convention are noticed (gravity tells) and the heading still comes out.
    func testOppositeAttitudeConvention() throws {
        let truth = KitMotionLink(yawDegrees: 120, samples: 0, yawSpreadDegrees: 0, gravityMismatchDegrees: 0, attitudeConjugated: false, shotId: "")
        let (f, m) = streams(truth: truth, conjugate: true)
        let l = try XCTUnwrap(KitMotionLink.estimate(frames: f, motion: m, shotId: "x").link)
        XCTAssertTrue(l.attitudeConjugated)
        XCTAssertEqual(l.yawDegrees, 120, accuracy: 0.05)
    }

    /// The device and ARKit camera axes (ARKit's camera x runs along the phone toward the Home button): a phone lying
    /// flat, screen up, has its camera (out of the back) looking down and ARKit's camera z (out of the screen) up.
    func testDeviceAxes() {
        let D = KitMotionLink.deviceFromARKitCamera
        XCTAssertEqual(D * Vec3(1, 0, 0), Vec3(0, -1, 0))
        XCTAssertEqual(D * Vec3(0, 1, 0), Vec3(1, 0, 0))
        XCTAssertEqual(D * Vec3(0, 0, 1), Vec3(0, 0, 1))
        XCTAssertEqual(D.determinant, 1, accuracy: 1e-12)
        XCTAssertEqual(KitMotionLink.worldFromReferenceAtZeroYaw.determinant, 1, accuracy: 1e-12)
    }

    func testFailsWithAReason() {
        let truth = KitMotionLink(yawDegrees: 10, samples: 0, yawSpreadDegrees: 0, gravityMismatchDegrees: 0, attitudeConjugated: false, shotId: "")
        let (f, m) = streams(truth: truth)
        // motion from another time: nothing matches
        let (_, late) = streams(truth: truth, timeOffset: 30)
        XCTAssertEqual(KitMotionLink.estimate(frames: f, motion: late, shotId: "s04-level-still").reason,
                       "only 0 video frames of s04-level-still have a motion sample at the same time (at least 10 needed)")
        // motion from another phone pose (another session's frame): the verticals disagree
        let tilted = m.map { s -> KitMotionSample in
            var x = s; x.attitude = KitQuaternion(axis: Vec3(1, 0, 0), angle: Units.radians(20)) * s.attitude; return x
        }
        XCTAssertTrue(KitMotionLink.estimate(frames: f, motion: tilted, shotId: "s").reason?.contains("disagree") ?? false)
        // frames with tracking not normal are left out
        let limited = f.map { x -> KitFrame in var y = x; y.tracking = .limitedRelocalizing; return y }
        XCTAssertNotNil(KitMotionLink.estimate(frames: limited, motion: m, shotId: "s").reason)
    }

    /// A flat-phone shot's slab normal, carried into the world by the link, is the slab's normal.
    func testCarriesAFlatPhoneNormalIntoTheWorld() throws {
        var o = KitSyntheticKit.Options()
        o.shots = ["s03-flat-level", "s05-tilt1-flat", "s05-tilt2-flat"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = try KitSyntheticKit.build(root: root, options: o)
        for (id, tilt) in [("s03-flat-level", 0.0), ("s05-tilt1-flat", 5), ("s05-tilt2-flat", 10)] {
            let p = try XCTUnwrap(kit.store.manifest.position(forShot: id))
            let gt = try XCTUnwrap(p.groundTruth)
            XCTAssertEqual(gt.method, .twoReading, id)
            XCTAssertEqual(try XCTUnwrap(gt.tiltDegrees), tilt, accuracy: 0.05, id)
            let n = try XCTUnwrap(gt.slabNormalInMotionFrame)
            let truth = try XCTUnwrap(kit.truth[id]).slab.normal
            XCTAssertLessThan(Units.degrees(kit.link.toWorld(n).angle(to: truth)), 0.1, id)
        }
    }
}
