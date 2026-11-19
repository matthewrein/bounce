import XCTest
@testable import BounceCore

/// The app's demo (what the Simulator UI tests see) through the app's demo path (ARController.demoTick: frames 12.5 a
/// second, the slab crop cut from the same pixels, the app's tracker settings): after the lock the tilt first reads
/// "settling" (until two re-checks agree), then settles quickly and reads the truth; the UI tests rely on both (SlabBounceUITests.testSettlingThenTheTilt
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
        /// per frame: time, locked, settled, honest sigma
        var frames: [(t: Double, locked: Bool, settled: Bool, sigma: Double?)] = []
    }

    func run(_ d: DemoScript, seconds: Double) -> Run {
        let settings = RecordingSettings(dishBounce: false).trackerSettings
        XCTAssertTrue(settings.readoutsFromSettledNormal)
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var r = Run()
        var t = 0.0
        while t < seconds {
            // the app's demo renders the app's slab and ball (ARController.demoTick)
            let view = d.view(at: t), scene = d.scene(at: t, spec: settings.spec, ball: settings.ball)
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
            r.frames.append((t, out.state == .locked, out.angleSettled, out.tiltSigmaDegrees))
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
        // the demo's view (48 deg elevation, 0.85 m): the detector's own side noise puts one view's honest sigma under
        // 1 deg, so the tilt shows within a second of the lock; not on the lock itself: the lock's own detections, taken in
        // one moment, do not count, and two re-checks (0.3 s apart) must agree first
        XCTAssertGreaterThanOrEqual((r.settledAt ?? 0) - (r.lockedAt ?? 0), 0.3)
        XCTAssertLessThanOrEqual((r.settledAt ?? 99) - (r.lockedAt ?? 0), 1.0)
        XCTAssertEqual(r.unsettledAfterSettle, 0)
        XCTAssertLessThan(errs.isEmpty ? 99 : errs[errs.count / 2], 0.5)
        XCTAssertLessThan(errs.last ?? 99, 1.0)
    }

    /// The owner's guidance (README: 45-55 deg down at 3-4 ft) pinned at its edge: 4 ft away and 62 deg down, the demo
    /// locks but stays on "settling" (one view cannot pin the tilt to a degree there). On the live phone's geometry
    /// (1920x1440 edges, 480x360 frame) the same view settles from one side of the slab and not from the other (sigma
    /// 0.73 against 1.35-1.6), so the README does not promise a number there.
    func testFourFeetAt62DegreesStaysSettling() {
        var d = DemoScript(); d.distance = Units.feet(4); d.elevation = 62
        let r = run(d, seconds: 5)
        let sig = r.frames.compactMap { $0.locked ? $0.sigma : nil }
        print(String(format: "DEMO 4 ft, 62 deg: locked %.2f s, %d locked frames, sigma min %.2f, settled %@", r.lockedAt ?? -1, sig.count,
                     sig.min() ?? -1, r.settledAt.map { String(format: "%.2f s", $0) } ?? "never"))
        XCTAssertNotNil(r.lockedAt, "locks")
        XCTAssertNil(r.settledAt, "settling throughout")
        XCTAssertGreaterThan(sig.min() ?? 0, 1.0)
    }

    /// The demo held steeply over the slab (72 deg elevation at 0.85 m: one view's honest sigma 1.7-4 deg, as the
    /// sigma table predicts for that view) locks but reads "settling" for as long as it stays there (measured: no
    /// settled frame in 7 s; at 68 deg it settled after 6 s, at 76-80 deg never); lowered to the demo's usual 48 deg, it
    /// shows the tilt within about a second (what SlabBounceUITests.testSettlingThenTheTilt does in the Simulator).
    func testASteepViewSettlesOnceTheCameraIsLowered() {
        var d = DemoScript(); d.elevation = 72; d.elevationTo = 48; d.elevationAt = 5; d.elevationRamp = 1.5
        let r = run(d, seconds: 10)
        let lowered = d.elevationAt + d.elevationRamp
        let steep = r.frames.filter { $0.t < d.elevationAt }
        let steepSigma = steep.compactMap { $0.locked ? $0.sigma : nil }
        let errs = r.settledErrors.sorted()
        print(String(format: "DEMO steep then lowered: locked %.2f s, steep sigma min %.2f, settled %.2f s (%.2f s after the camera reached 48 deg), "
                     + "settled tilt error median %.2f worst %.2f, up to %d view groups",
                     r.lockedAt ?? -1, steepSigma.min() ?? -1, r.settledAt ?? -1, (r.settledAt ?? -1) - lowered,
                     errs.isEmpty ? -1 : errs[errs.count / 2], errs.last ?? -1, r.viewGroups))
        XCTAssertLessThan(r.lockedAt ?? 99, d.elevationAt, "locks while steep")
        XCTAssertTrue(steep.allSatisfy { !$0.settled }, "settling while steep")
        XCTAssertGreaterThan(steepSigma.min() ?? 0, 1.0)
        XCTAssertNotNil(r.settledAt)
        XCTAssertLessThanOrEqual((r.settledAt ?? 99) - lowered, 1.5)
        XCTAssertLessThan(errs.isEmpty ? 99 : errs[errs.count / 2], 0.5)
        XCTAssertLessThan(errs.last ?? 99, 1.0)
    }
}
