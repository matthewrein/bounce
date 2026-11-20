import XCTest
@testable import BounceCore

/// The app's demo with its held ball (what SlabBounceUITests.testTapARingToDismissItAndTapAgainToTakeItBack sees) through
/// the app's demo path (frames 12.5 a second, the ball crop and the slab crop cut from the same pixels, the app's tracker,
/// detectors and settings): a tap on the ball's ring takes it away at once and keeps it away while the camera drifts (the
/// dismissed spot covers its line of sight from the ball out to the slab's plane), and a tap where it is takes the
/// dismissal back and shows the ball again.
final class DemoTapTests: XCTestCase {
    func testTheDemosRingTapDismissesTheBallAndATapThereTakesItBack() {
        var d = DemoScript(); d.ballHeight = 0.30
        let settings = RecordingSettings(dishBounce: false).trackerSettings
        XCTAssertTrue(settings.tapHints)
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var t = 0.0
        var tap: Vec2? = nil
        var ringAt: Vec2? = nil, dismissedAt: Double? = nil, tappedBackAt: Double? = nil
        var shownWhileDismissed = 0, backAt: Double? = nil
        while t < 7.5 {
            let view = d.view(at: t), scene = d.scene(at: t, spec: settings.spec, ball: settings.ball)
            let K = view.intrinsics
            let img = SyntheticScene.ycc(rgb: scene.renderRGB(view: view), width: K.width, height: K.height)
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
                                                   tap: tap, floorY: 0, slabDetail: detail))
            tap = nil
            if dismissedAt == nil, let b = out.ball, t > 2 {
                // the ring, where the app draws it: tap it on the next frame (about the UI test's own delay later)
                ringAt = view.project(world: b.center)
                tap = ringAt
                dismissedAt = t
            } else if let td = dismissedAt, tappedBackAt == nil {
                if out.tap != nil { XCTAssertEqual(out.tap?.kind, .dismissBall); XCTAssertNil(out.ball, "gone at once") }
                else if out.ball != nil { shownWhileDismissed += 1 }
                // then a tap where the dismissed ball is now (the app marks the spot's near end for the UI tests)
                if t - td > 4, let spot = tracker.dismissedSpots.first { tap = view.project(world: spot.near); tappedBackAt = t }
            } else if tappedBackAt != nil, backAt == nil, out.ball != nil {
                backAt = t
            }
            t += 0.08
        }
        print(String(format: "DEMO TAP: dismissed at %.2f s, shown %d frames while dismissed, tapped back at %.2f s, back at %@; counts %@",
                     dismissedAt ?? -1, shownWhileDismissed, tappedBackAt ?? -1, backAt.map { String(format: "%.2f s", $0) } ?? "never",
                     "\(tracker.counts.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key })"))
        XCTAssertNotNil(dismissedAt, "the demo's ball was never shown")
        XCTAssertEqual(shownWhileDismissed, 0, "the dismissed ball came back while the camera drifted")
        XCTAssertEqual(tracker.counts["tapDismiss"], 1)
        XCTAssertEqual(tracker.counts["tapDismissLifted"], 1, "the second tap took the dismissal back")
        XCTAssertNotNil(backAt, "the ball never came back")
        XCTAssertLessThan((backAt ?? 99) - (tappedBackAt ?? 0), 2)
        // the path the UI test relies on for "ball in view" soon after the second tap: the ball found under the finger and
        // accepted at once (not set at the tap, which would say "ball set" until the gate's ball replaced it)
        XCTAssertEqual(tracker.counts["tapBallAccepted"], 1)
        XCTAssertNil(tracker.counts["tapBallSet"])
    }
}
