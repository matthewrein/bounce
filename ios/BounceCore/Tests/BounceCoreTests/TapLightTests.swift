import XCTest
@testable import BounceCore

/// Tap hints in poor light, on renders (the owner's kits have one dim shot, which the app locks without a tap): the
/// owner's slab drawn with less light and the camera's noise (a dim room: the camera's gain lifts a darker picture and
/// its noise with it), seen from 3 ft at 45 degrees by the app's processing frame, through the app's tracker, detectors
/// and settings, with and without a tap on the slab's middle on the first frame.
final class TapLightTests: XCTestCase {
    /// The scene's colours times `light`, plus Gaussian noise of `noise` grey levels per channel (seeded).
    static func dim(_ rgb: [UInt8], light: Double, noise: Double, seed: UInt64) -> [UInt8] {
        var rng = SeededRandom(seed)
        return rgb.map { v in UInt8(clamp((Double(v) * light + (noise > 0 ? rng.gaussian() * noise : 0)).rounded(), 0, 255)) }
    }

    struct Run { var lockedAt: Double?; var tiltError: Double?; var counts: [String: Int] }

    static let slab = SyntheticScene.slabPose(tilt: 8, heading: 35, spec: RecordingSettings().trackerSettings.spec)

    static func view(_ t: Double, elevation: Double = 45, distance: Double = Units.feet(3)) -> CameraView {
        let az = Units.radians(25 + 3 * sin(t)), el = Units.radians(elevation)
        let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * distance
        return SyntheticScene.camera(at: pos, lookingAt: slab.center, intrinsics: .processing)
    }

    static func image(_ view: CameraView, light: Double, noise: Double, seed: UInt64) -> YCCImage {
        let spec = RecordingSettings().trackerSettings.spec, K = view.intrinsics
        var scene = SyntheticScene(spec: spec, slab: slab); scene.supersample = 1
        return SyntheticScene.ycc(rgb: dim(scene.renderRGB(view: view), light: light, noise: noise, seed: seed), width: K.width, height: K.height)
    }

    static func run(light: Double, noise: Double, tap: Bool, seconds: Double = 2) -> Run {
        let settings = RecordingSettings().trackerSettings
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: nil)
        var r = Run(lockedAt: nil, tiltError: nil, counts: [:])
        var t = 0.0, k = 0
        while t < seconds {
            let v = view(t), K = v.intrinsics
            // the frame is drawn only when the detector runs on it, as the app converts it
            let due = tracker.detectorWillRun(at: t, tap: tap && k == 0, trackingNormal: true)
            let img = due ? image(v, light: light, noise: noise, seed: UInt64(1000 + k)) : nil
            let detail = img.map { img in SlabImageCrop.provider(processing: K, full: K) { c in
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                return c.factor > 1 ? p.downscaled(by: c.factor) : p
            } }
            let tapAt: Vec2? = tap && k == 0 ? v.project(world: slab.center) : nil
            let out = tracker.process(TrackerFrame(timestamp: t, view: v, frame: img?.colorFrame ?? ColorFrame(gray: Plane(width: 2, height: 2)),
                                                   tap: tapAt, floorY: 0, slabDetail: detail))
            if out.state == .locked, r.lockedAt == nil {
                r.lockedAt = t
                r.tiltError = out.slab.map { Units.degrees($0.normal.angle(to: slab.normal)) }
            }
            t += 1.0 / 30; k += 1
        }
        r.counts = tracker.counts.filter { $0.key.hasPrefix("tap") || $0.key == "searches" || $0.key.hasPrefix("reject") }
        return r
    }

    /// In a dim room (the scene at 40% of its light, 3 grey levels of noise) the slab is not found unprompted (the sweep's
    /// tightest colour match leaks over the floor: colour differences shrink with the light, and its starting points read
    /// as dark or textured); a tap on it finds and locks it at once (the tapped growth tries tighter matches, down to a
    /// few times the colour noise at the tapped point), within a degree. In good light the tap changes nothing: the
    /// sweep's own outline under the finger is taken. (Measured on these renders: at 60% light 0.67 s without a tap,
    /// 0.27 s with; at 40% and 25% never without, 0.27 s with, 0.29 and 0.09 deg off; at 40% with 6 levels of noise never
    /// without, 1.6 s with, 1.5 deg off.)
    func testATapFindsTheSlabInPoorLight() {
        let dimNo = TapLightTests.run(light: 0.4, noise: 3, tap: false, seconds: 1.5)
        let dimTap = TapLightTests.run(light: 0.4, noise: 3, tap: true, seconds: 1.5)
        print(String(format: "TAP LIGHT dim: no tap %@, tap %@ (%.2f deg); counts %@",
                     dimNo.lockedAt.map { String(format: "%.2f s", $0) } ?? "never", dimTap.lockedAt.map { String(format: "%.2f s", $0) } ?? "never",
                     dimTap.tiltError ?? -1, "\(dimTap.counts.sorted { $0.key < $1.key })"))
        XCTAssertNil(dimNo.lockedAt, "found without a tap: the scene is not dim enough to test the tap")
        XCTAssertLessThan(dimTap.lockedAt ?? 9, 0.5)
        XCTAssertLessThan(dimTap.tiltError ?? 9, 1.0)
        XCTAssertGreaterThan(dimTap.counts["tapSlabGrown"] ?? 0, 0)
        let goodNo = TapLightTests.run(light: 1, noise: 3, tap: false, seconds: 0.6)
        let goodTap = TapLightTests.run(light: 1, noise: 3, tap: true, seconds: 0.6)
        XCTAssertNotNil(goodNo.lockedAt)
        XCTAssertEqual(goodTap.lockedAt, goodNo.lockedAt)
        XCTAssertEqual(goodTap.tiltError ?? -1, goodNo.tiltError ?? -2, accuracy: 1e-9, "the sweep's own outline")
        XCTAssertEqual(goodTap.counts["tapSlabGrown"] ?? 0, 0)
    }
}
