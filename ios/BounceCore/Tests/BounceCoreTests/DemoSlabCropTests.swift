import XCTest
@testable import BounceCore

/// The app's demo (what the Simulator UI tests see) with the slab crop the app's demo path cuts (ARController.demoTick:
/// the demo frame is the full image, so the crop is a piece of the same pixels at factor 1) and the app's tracker settings:
/// it must still lock quickly, read the tilt and the slide, and find the held ball, as without the crop. (Measured with
/// `compare` on: the same lock time, tilt errors, ball frames and drop error as without the crop; the plain run is off by
/// default because ReplayTests.testDemoSceneThroughThePipeline and testDemoBallThroughThePipeline cover it.)
final class DemoSlabCropTests: XCTestCase {
    struct Run {
        var lockedAt: Double?
        var tiltErrors: [Double] = []
        var afterSlide: [Double] = []
        var crops = 0
        var factors: Set<Int> = []
        var lockedFrames = 0
        var ballFrames = 0
        var dropErrors: [Double] = []
        var median: Double { tiltErrors.isEmpty ? 99 : tiltErrors.sorted()[tiltErrors.count / 2] }
        var medianAfter: Double { afterSlide.isEmpty ? 99 : afterSlide.sorted()[afterSlide.count / 2] }
    }

    /// The tracker with the crop (and, with `compare`, one without) on the same rendered frames, 12.5 a second as the
    /// demo's timer runs.
    func run(_ d: DemoScript, seconds: Double, compare: Bool = false) -> (crop: Run, plain: Run) {
        let settings = RecordingSettings(dishBounce: false).trackerSettings
        XCTAssertEqual(settings.minDetectionGap, RecordingSettings.appMinDetectionGap)
        let withCrop = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        let plain = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var trackers = [withCrop]
        if compare { trackers.append(plain) }
        var runs = [Run(), Run()]
        var t = 0.0
        while t < seconds {
            // the app's demo renders the app's slab (ARController: `script.scene(at:spec: AppSettings.slab)`)
            let view = d.view(at: t), scene = d.scene(at: t, spec: settings.spec)
            let K = view.intrinsics
            let img = SyntheticScene.ycc(rgb: scene.renderRGB(view: view), width: K.width, height: K.height)
            let truth = Units.degrees(scene.slab.tilt(down: Vec3(0, -1, 0)))
            for (i, tracker) in trackers.enumerated() {
                // ARController.handle: the ball crop when the ball finder is due, the slab crop from the same image
                var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
                if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let c = BallImageCrop.plan(slab: s, full: view) {
                    let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                    ballImage = c.factor > 1 ? p.downscaled(by: c.factor) : p
                    ballK = c.intrinsics(full: K)
                }
                var detail: (([Vec2]) -> SlabDetail?)? = nil
                if i == 0 {
                    detail = SlabImageCrop.provider(processing: K, full: K) { c in
                        let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                        return c.factor > 1 ? p.downscaled(by: c.factor) : p
                    }
                }
                let out = tracker.process(TrackerFrame(timestamp: t, view: view, frame: img.colorFrame, ballImage: ballImage, ballIntrinsics: ballK,
                                                       floorY: 0, slabDetail: detail))
                if let c = out.slabDetail?.crop { runs[i].crops += 1; runs[i].factors.insert(c.factor) }
                if out.state == .locked, runs[i].lockedAt == nil { runs[i].lockedAt = t }
                if let r = out.readouts, out.state == .locked {
                    if d.slideTo == nil || t < d.slideAt { runs[i].tiltErrors.append(abs(r.tiltDegrees - truth)) } else if t > d.slideAt + 3 {
                        runs[i].afterSlide.append(abs(r.tiltDegrees - truth))
                    }
                    runs[i].lockedFrames += 1
                    if r.dropFromBall {
                        runs[i].ballFrames += 1
                        let dt = Bounce.compute(pose: scene.slab, spec: .standard, ball: BallSpec(), down: Vec3(0, -1, 0), ballCenter: scene.ball,
                                                defaultDropHeight: 0.9144).drop?.dropHeight ?? .nan
                        runs[i].dropErrors.append(abs(r.dropHeight - dt))
                    }
                }
            }
            t += 0.08
        }
        return (runs[0], runs[1])
    }

    func testDemoWithTheAppsSlabCropLocksAndReadsTheTiltAndTheSlide() {
        var d = DemoScript(); d.slideTo = 3; d.slideAt = 4
        let (crop, _) = run(d, seconds: 9)
        print(String(format: "DEMO slab crop: locked after %.2f s, tilt error median %.2f worst %.2f deg, after the slide %.2f; %d crops, factors %@",
                     crop.lockedAt ?? -1, crop.median, crop.tiltErrors.max() ?? -1, crop.medianAfter, crop.crops, "\(crop.factors.sorted())"))
        XCTAssertLessThan(crop.lockedAt ?? 99, 1.0)
        XCTAssertLessThan(crop.median, 1.0)
        XCTAssertLessThan(crop.medianAfter, 1.0, "the slide to 3 deg shows")
        XCTAssertGreaterThan(crop.crops, 0, "the demo hands the tracker its crop")
        XCTAssertEqual(crop.factors, [1], "the demo's frame is its full image: crops at factor 1")
    }

    func testDemoWithTheAppsSlabCropStillFindsTheBall() {
        var d = DemoScript(); d.ballHeight = 0.30
        let (crop, _) = run(d, seconds: 6)
        func med(_ v: [Double]) -> Double { v.isEmpty ? 99 : v.sorted()[v.count / 2] }
        print(String(format: "DEMO slab crop, ball: drop from the ball on %d of %d locked frames, drop error median %.1f mm",
                     crop.ballFrames, crop.lockedFrames, med(crop.dropErrors) * 1000))
        // the level testDemoBallThroughThePipeline guards (the demo's known gap while the camera drifts round)
        XCTAssertGreaterThan(Double(crop.ballFrames), 0.45 * Double(crop.lockedFrames))
        XCTAssertLessThan(med(crop.dropErrors), 0.02)
    }
}
