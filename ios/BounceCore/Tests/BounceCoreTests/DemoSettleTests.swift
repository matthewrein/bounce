import XCTest
@testable import BounceCore

/// The app's demo (what the Simulator UI tests see) through the app's demo path (ARController.demoTick: frames 12.5 a
/// second, the slab crop cut from the same pixels, the app's tracker settings): after the lock the tilt first reads
/// "settling", then settles quickly and reads the truth; the UI tests rely on both (SlabBounceUITests.testSettlingThenTheTilt
/// sees the first, the others read the tilt once it shows).
final class DemoSettleTests: XCTestCase {
    struct Run {
        var lockedAt: Double?
        var settledAt: Double?
        /// tilt error of the readouts on settled frames (degrees), and the honest sigma when it first settled
        var settledErrors: [Double] = []
        var sigmaAtSettle: Double?
        var unsettledAfterSettle = 0
        var viewGroups = 0
    }

    func run(_ d: DemoScript, seconds: Double) -> Run {
        let settings = RecordingSettings(dishBounce: false).trackerSettings
        XCTAssertTrue(settings.readoutsFromSettledNormal)
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var r = Run()
        var t = 0.0
        while t < seconds {
            let view = d.view(at: t), scene = d.scene(at: t)
            let K = view.intrinsics
            let img = SyntheticScene.ycc(rgb: scene.renderRGB(view: view), width: K.width, height: K.height)
            let truth = Units.degrees(scene.slab.tilt(down: Vec3(0, -1, 0)))
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
            if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let c = BallImageCrop.plan(slab: s, full: view) {
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                ballImage = c.factor > 1 ? p.downscaled(by: c.factor) : p
                ballK = c.intrinsics(full: K)
            }
            let detail = SlabImageCrop.provider(processing: K, full: K) { c in
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                return c.factor > 1 ? p.downscaled(by: c.factor) : p
            }
            let out = tracker.process(TrackerFrame(timestamp: t, view: view, frame: img.colorFrame, ballImage: ballImage, ballIntrinsics: ballK,
                                                   floorY: 0, slabDetail: detail))
            if out.state == .locked, r.lockedAt == nil { r.lockedAt = t }
            if out.angleSettled {
                if r.settledAt == nil { r.settledAt = t; r.sigmaAtSettle = out.tiltSigmaDegrees }
                if let rd = out.readouts { r.settledErrors.append(abs(rd.tiltDegrees - truth)) }
            } else if r.settledAt != nil && out.state == .locked && (d.slideTo == nil || t < d.slideAt) {
                r.unsettledAfterSettle += 1
            }
            r.viewGroups = max(r.viewGroups, out.viewGroups)
            t += 0.08
        }
        return r
    }

    func testTheDemoSettlesSoonAfterItLocks() {
        let r = run(DemoScript(), seconds: 6)
        let errs = r.settledErrors.sorted()
        print(String(format: "DEMO settle: locked %.2f s, settled %.2f s (%.2f s after the lock, sigma %.2f deg), settled tilt error median %.2f worst %.2f deg, "
                     + "%d frames back to settling, up to %d view groups",
                     r.lockedAt ?? -1, r.settledAt ?? -1, (r.settledAt ?? -1) - (r.lockedAt ?? 0), r.sigmaAtSettle ?? -1,
                     errs.isEmpty ? -1 : errs[errs.count / 2], errs.last ?? -1, r.unsettledAfterSettle, r.viewGroups))
        XCTAssertNotNil(r.lockedAt)
        XCTAssertNotNil(r.settledAt)
        // the UI tests wait for the tilt to show (it settles once the re-checks have measured the detector's corner noise:
        // `SlabTracker.cornerNoiseEstimate` needs 8 re-checks, 0.3 s apart)
        XCTAssertLessThanOrEqual((r.settledAt ?? 99) - (r.lockedAt ?? 0), 3.5)
        // "settling" shows for a moment first (the new UI test looks for it)
        XCTAssertGreaterThanOrEqual((r.settledAt ?? 0) - (r.lockedAt ?? 0), 0.3)
        XCTAssertLessThan(errs.isEmpty ? 99 : errs[errs.count / 2], 0.5)
        XCTAssertLessThan(errs.last ?? 99, 1.0)
    }
}
