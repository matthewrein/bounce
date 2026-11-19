import XCTest
@testable import BounceCore

/// The scorer on a tiny synthetic kit (rendered here, known truth).
final class KitScorerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-score-\(UUID().uuidString)")
    }

    override func tearDown() { if let r = root { try? FileManager.default.removeItem(at: r) } }

    /// The shots of the tiny kit: two slab positions with their true tilts, a still shot in each, a held ball with its
    /// height entered, and the negative without the slab.
    static let tinyShots: Set<String> = ["s01-measure", "s03-flat-level", "s04-level-still", "s05-tilt1-flat", "s05-tilt1-still",
                                         "s09-held-low", "s12-no-slab"]

    /// `ballSize`: render the ball shots at a real kit's 1440x1080 (the default); here 480x360 unless asked, to stay fast.
    func tinyKit(frames: Int = 10, shots: Set<String> = KitScorerTests.tinyShots, video: String? = nil, ballSize: Bool = false) throws -> KitSyntheticKit {
        var o = KitSyntheticKit.Options()
        o.framesPerShot = frames
        o.shots = shots
        o.video = video
        if !ballSize { o.ballWidth = nil; o.ballHeight = nil }
        return try KitSyntheticKit.build(root: root, options: o)
    }

    func testScoresATinySyntheticKit() throws {
        let kit = try tinyKit()
        // the kit is made as the app makes one
        let m = kit.store.manifest
        XCTAssertTrue(m.measurementsEntered)
        XCTAssertNotNil(m.finishedAt)
        XCTAssertEqual(m.positions.map { $0.id }, ["p1", "p2", "p3"])
        XCTAssertNil(m.position("p3")?.groundTruth, "the second tilt's flat-phone shot was skipped")
        XCTAssertEqual(m.record("s09-held-low")?.enteredHeightInches ?? 0, 4, accuracy: 0.05)

        var o = kit.scorerOptions(truthBall: true)
        var lines: [String] = []
        o.log = { lines.append($0) }
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.kitId, "synthetic", "the synthetic kit is not mistaken for a captured one")
        XCTAssertEqual(r.source, "synthetic")
        XCTAssertEqual(r.settings, "app")
        XCTAssertEqual(r.shots.map { $0.shotId }, ["s04-level-still", "s05-tilt1-still", "s09-held-low", "s12-no-slab"])
        XCTAssertTrue(r.shots.allSatisfy { $0.error == nil }, "\(r.shots.compactMap { $0.error })")

        // tilt well under half a degree, against the flat-phone true tilt; the normal's direction too
        let tilt = try XCTUnwrap(r.aggregate("tiltErrorMedian")?.value)
        XCTAssertLessThan(tilt, 0.5)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("tiltErrorP90")?.value), 0.8)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("normalErrorMedian")?.value), 0.6)
        XCTAssertEqual(r.shot("s05-tilt1-still")?.trueTiltDegrees ?? 0, 5, accuracy: 0.05)
        XCTAssertEqual(r.position("p2")?.link?.yawDegrees ?? 0, 37, accuracy: 0.1, "the CoreMotion-to-ARKit link")
        XCTAssertEqual(r.position("p3")?.metric("tiltErrorMedian")?.value, nil)
        // locks quickly and stays locked
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.aggregate("lockRate")?.value), 0.9)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("timeToLock")?.value), 0.8)
        XCTAssertEqual(r.aggregate("neverLocked")?.value, 0)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("cornerRms")?.value), 3)
        XCTAssertLessThan(abs(try XCTUnwrap(r.aggregate("slabSizeError")?.value)), 3)
        // no slab where there is none
        let neg = try XCTUnwrap(r.shot("s12-no-slab"))
        XCTAssertEqual(neg.metric("slabFoundRate")?.value, 0)
        XCTAssertEqual(neg.metric("slabLockedRate")?.value, 0)
        XCTAssertEqual(neg.metric("ballFalsePositiveRate")?.note,
                       "the app looks for the ball only on a lock, and the slab is not in view")
        // the held ball, found by the truth-based finder: the drop height the app works out from it
        let held = try XCTUnwrap(r.shot("s09-held-low"))
        XCTAssertEqual(held.metric("ballDetectionRate")?.value, 1)
        XCTAssertLessThan(abs(try XCTUnwrap(held.metric("dropHeightError")?.value)), 10)
        XCTAssertEqual(r.shot("s04-level-still")?.metric("ballFalsePositiveRate")?.value, 0)
        // progress lines: ids and numbers only
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("/") })

        // JSON: round trip, and no paths in it
        let set = KitScoreSet(reports: [r], scoredAt: "2026-11-17T00:00:00Z", scorer: "test")
        let data = try set.json()
        XCTAssertEqual(try KitScoreSet.read(data), set)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(root.path), "no paths in the report")
        XCTAssertFalse(text.contains(FileManager.default.temporaryDirectory.path))
        let md = set.markdown()
        XCTAssertTrue(md.contains("| s05-tilt1-still | p2 | 10 |"), md)
        XCTAssertFalse(md.contains(root.path))
    }

    /// Without a ball finder the ball metrics are n/a, with the reason; scoring with the kit's measurements is noted.
    func testWithoutABallFinderAndWithTheMeasurements() throws {
        let kit = try tinyKit(frames: 6, shots: ["s01-measure", "s09-held-low"])
        var o = kit.scorerOptions()
        o.makeBallLocator = { nil }
        o.useMeasurements = true
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.settings, "measured")
        let held = try XCTUnwrap(r.shot("s09-held-low"))
        XCTAssertEqual(held.metric("ballDetectionRate")?.note, "no ball finder in this build")
        XCTAssertEqual(held.metric("dropHeightError")?.note, "no ball finder in this build")
        XCTAssertNil(held.metric("tiltErrorMedian")?.value)
        XCTAssertEqual(held.metric("tiltErrorMedian")?.note, "no true tilt for p3 (its flat-phone shot was skipped or failed)")
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("No ball finder in this build") })
        XCTAssertEqual(r.aggregate("ballDetectionRate")?.note, "no ball finder in this build")
        XCTAssertEqual(r.aggregate("landingError")?.note, "no drop scored")
    }

    /// A shot whose video ends early is reported as not scored, and the others are still scored.
    func testAShortVideoIsAnErrorForThatShotOnly() throws {
        let kit = try tinyKit(frames: 6, shots: ["s04-level-still", "s12-no-slab"])
        var o = kit.scorerOptions()
        o.frames = { input in
            let all = try kit.frames(input)
            let n = input.shotId == "s04-level-still" ? 3 : input.frames.count
            var frames: [YCCImage] = []
            for _ in 0..<n { if let f = try all.next() { frames.append(f) } }
            return KitArrayFrameSource(width: all.width, height: all.height, frames: frames)
        }
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.shot("s04-level-still")?.error, "the video ended after 3 frames but frames.jsonl has 6 lines")
        XCTAssertNil(r.shot("s12-no-slab")?.error)
        XCTAssertEqual(r.shot("s12-no-slab")?.metric("slabLockedRate")?.value, 0)
        XCTAssertTrue(r.markdown().contains("could not be: s04-level-still"))
    }

    /// A drop's dense track (and the ball resting on the slab) come from the app's BallLocator set up for tracking
    /// (`KitScorer.trackingLocator`): every frame stands on its own, so each sample is a measurement of that frame. A
    /// missed ball is not held over (the app's locator keeps it for two scans), a ball that moved is not smoothed
    /// toward where it was, and a ball 1.5 cm over the slab (under the app's 5 cm floor) or beside it (its bounce
    /// leaves the slab's footprint) is still reported.
    func testTheTrackingLocatorStandsOnEachFrame() throws {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let g = Vec3(0, 0.75, 0.66).normalized, up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        func slab(under B: Vec3, height h: Double, shift: Double = 0) -> SlabPose {
            SlabPose(center: B - n * (h + ball.radius) + u * shift, normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
        }
        func render(_ B: Vec3, ball shown: Bool = true) -> Plane {
            SphereScene(K: K, center: B, radius: ball.radius,
                        surface: shown ? SphereScene.mirrorSurface(up: up, lowerVisible: true) : { _ in nil }).render(noise: 1)
        }
        let B1 = K.ray(Vec2(190, 180)).normalized * 0.5, B2 = K.ray(Vec2(200, 192)).normalized * 0.5
        let s = slab(under: B1, height: 0.4)
        let img1 = render(B1), img2 = render(B2), empty = render(B1, ball: false)
        let tracking = try XCTUnwrap(KitScorer.trackingLocator(AppDetectors.ball()) as? BallLocator)
        XCTAssertNotNil(KitScorer.trackingLocator(KitTruthBallLocator(truth: [:])) as? KitTruthBallLocator, "other finders as they are")
        let app = BallLocator()

        // a miss is a miss: no hold-over
        XCTAssertNotNil(tracking.update(luma: img1, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        XCTAssertNotNil(app.update(luma: img1, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        XCTAssertNil(tracking.update(luma: empty, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        XCTAssertEqual(app.update(luma: empty, intrinsics: K, slab: s, spec: spec, ball: ball, down: g)?.missedUpdates, 1, "the app holds it over")

        // a ball that moved: the tracking answer is the fresh finder's, not smoothed toward where it was
        tracking.reset(); app.reset()
        _ = tracking.update(luma: img1, intrinsics: K, slab: s, spec: spec, ball: ball, down: g)
        _ = app.update(luma: img1, intrinsics: K, slab: s, spec: spec, ball: ball, down: g)
        let fresh = try XCTUnwrap(BallLocator(options: .tracking()).update(luma: img2, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        let t2 = try XCTUnwrap(tracking.update(luma: img2, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        let a2 = try XCTUnwrap(app.update(luma: img2, intrinsics: K, slab: s, spec: spec, ball: ball, down: g))
        XCTAssertEqual(t2.center, fresh.center)
        XCTAssertLessThan(t2.center.distance(to: B2), 0.01)
        XCTAssertGreaterThan(a2.circle.center.distance(to: t2.circle.center), 3, "the app's answer is smoothed toward the first frame's")

        // just over the dish, and beside the slab
        let low = slab(under: B1, height: 0.015), beside = slab(under: B1, height: 0.3, shift: 0.15)
        XCTAssertNil(BallLocator().update(luma: img1, intrinsics: K, slab: low, spec: spec, ball: ball, down: g), "under the app's 5 cm floor")
        let tl = try XCTUnwrap(BallLocator(options: .tracking()).update(luma: img1, intrinsics: K, slab: low, spec: spec, ball: ball, down: g))
        XCTAssertEqual(tl.drop.dropHeight, 0.015, accuracy: 0.01)
        XCTAssertNil(BallLocator().update(luma: img1, intrinsics: K, slab: beside, spec: spec, ball: ball, down: g), "the app wants it over the slab")
        let tb = try XCTUnwrap(BallLocator(options: .tracking()).update(luma: img1, intrinsics: K, slab: beside, spec: spec, ball: ball, down: g))
        XCTAssertFalse(tb.drop.onSlab)
        XCTAssertLessThan(tb.center.distance(to: B1), 0.01)
    }

    /// The tracking finder takes a ball seen from half its outline on a single frame and at any height: a falling ball
    /// never shows up twice at one place over the slab, and the end of its fall and its bounce are under the 0.2 m the
    /// app asks of a half outline. The app's own locator still holds such a ball back. Under those 0.2 m, a half outline
    /// found again where one was on the frame before is not taken (`BallLocator.Options.stillPartialCeiling`): a lid
    /// or a ring of light lying on the slab stays put, a ball in a drop does not; one found where none was, or higher,
    /// is.
    func testTheTrackingLocatorTakesAHalfOutlineOnOneFrame() throws {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let g = Vec3(0, 1, 0), up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let B = K.ray(Vec2(205, 170)).normalized * 0.5
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        for h in [0.08, 0.3] {
            let slab = SlabPose(center: B - n * (h + ball.radius), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
            // the lower half the very floor behind it: the upper outline only
            let img = SphereScene(K: K, center: B, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: false)).render(noise: 1)
            let t = try XCTUnwrap(BallLocator(options: .tracking()).update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g),
                                  "\(h) m: on the first frame")
            XCTAssertTrue(t.circle.partial)
            XCTAssertEqual(t.drop.dropHeight, h, accuracy: 0.03)
            // the same frame again: still there
            let tracking = BallLocator(options: .tracking())
            XCTAssertNotNil(tracking.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g))
            let again = tracking.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
            if h < 0.2 { XCTAssertNil(again, "\(h) m: a half outline low over the slab that stays put") } else { XCTAssertNotNil(again, "\(h) m") }
            // a ball that moved on: taken
            let B2 = B + up * 0.02
            let moved = SphereScene(K: K, center: B2, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: false)).render(noise: 1)
            let m = try XCTUnwrap(tracking.update(luma: moved, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g), "\(h) m: moved 2 cm")
            XCTAssertEqual(m.drop.dropHeight, h + 0.02, accuracy: 0.03)
            let app = BallLocator()
            XCTAssertNil(app.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g), "\(h) m: the app wants a second scan")
            let second = app.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
            if h < 0.2 { XCTAssertNil(second, "\(h) m: under the app's height for a half outline") } else { XCTAssertNotNil(second) }
        }
    }

    /// A drop scored with the truth-based finder: the track holds together, the bounce is measured (the app's own
    /// model, so the prediction from a good lock agrees), and the launch height says how far the lock's plane is off.
    func testADropWithTheTruthBall() throws {
        let kit = try tinyKit(frames: 6, shots: ["s01-measure", "s10-drop1"])
        let truth = try XCTUnwrap(kit.truth["s10-drop1"]?.drop)
        let r = try KitScorer(kitFolder: kit.folder, options: kit.scorerOptions(truthBall: true)).score()
        let d = try XCTUnwrap(r.shot("s10-drop1"))
        let a = try XCTUnwrap(d.bounce, "\(d.metrics.compactMap { $0.note })")
        XCTAssertEqual(a.rebound, truth.rebound, accuracy: 0.03)
        XCTAssertEqual(a.velocityIn.length, truth.velocityIn.length, accuracy: 0.05)
        XCTAssertEqual(a.apexHeight, truth.apexHeight, accuracy: 0.005)
        // (3 mm while the kit rendered the old box; with the owner's sloped sides and 2 mm rounding the effective edge
        // convention reads the rendered rounding 0.2-0.3 processing px off at 480x360, which moves the lock's plane: 4.3 mm)
        XCTAssertLessThan(abs(try XCTUnwrap(d.metric("impactHeightError")?.value)), 5, "mm: the lock is good to a few mm")
        XCTAssertLessThan(try XCTUnwrap(d.metric("landingError")?.value), 15)
        XCTAssertNil(r.aggregate("impactPointError"), "the horizontal impact point (always about 0) is no longer scored")
        // measured on the dish: this kit's drops follow the app's own model (out along the corner plane's normal at
        // sqrt(0.7) of the speed in), whose restitution about the normal is sqrt(0.7) / cos(tilt): a rebound of
        // 0.7 / cos²(tilt) as the app's setting means it; the app's prediction from a good lock lands where the ball does
        let drop = try XCTUnwrap(d.drop, "\(d.metrics.compactMap { $0.note })")
        let tilt = Units.radians(try XCTUnwrap(kit.truth["s10-drop1"]?.tiltDegrees))
        XCTAssertEqual(try XCTUnwrap(drop.rebound), 0.7 / (cos(tilt) * cos(tilt)), accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(d.metric("reboundMeasured")?.value), try XCTUnwrap(drop.rebound), accuracy: 1e-12)
        XCTAssertLessThan(try XCTUnwrap(d.metric("landingErrorApp")?.value), 15)
        XCTAssertLessThan(try XCTUnwrap(d.metric("launchDirectionError")?.value), 1.5)
        // the ball's gap from the dish at the impact follows the same lock-plane error (4.6 mm with the owner's 180.2 mm
        // slab and 30 mm ball rendered; 3-4 mm on the old 7 in box with a 35 mm ball)
        XCTAssertLessThan(abs(try XCTUnwrap(d.metric("impactClearance")?.value)), 5)
        XCTAssertNotNil(r.aggregate("reboundMeasured")?.value)
        XCTAssertTrue(r.reboundToBakeLine.hasPrefix("rebound to bake into the app: "), r.reboundToBakeLine)
        XCTAssertTrue(r.markdown().contains("rebound to bake into the app:"))
    }

    /// The ball resting on the slab is expected where it was found, a radius above the dish along the dish's own normal
    /// there: on a slab tilted 10° it cannot stay in the middle, so off-centre balls read 0 too, a ball 5 mm further
    /// along the ray reads +5 mm, and one beside the slab is n/a.
    func testBallDistanceErrorTakesTheBallWhereItRests() throws {
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35)
        let settings = RecordingSettings().trackerSettings
        let K = CameraIntrinsics(fx: 1100, fy: 1100, cx: 720, cy: 540, width: 1440, height: 1080)
        let view = SyntheticScene.camera(at: slab.center + Vec3(0.4, 0.6, 0.5), lookingAt: slab.center, intrinsics: K)
        let R = settings.ball.radius, D = settings.spec.dishDepth
        for (u, v) in [(0.0, 0.0), (0.06, -0.03), (-0.075, 0.07)] {
            let d = Dish.at(pose: slab, depth: D, u: u, v: v)
            let centre = slab.point(u: u, v: v) - slab.normal * d.depth + d.normal * R
            let e = try XCTUnwrap(KitScoreRun.ballDistanceError(ballWorld: centre, slab: slab, view: view, settings: settings))
            XCTAssertEqual(e, 0, accuracy: 1e-4, "(\(u), \(v))")
            let c = view.toCamera(centre)
            let further = view.toWorld(c * (1 + 0.005 / c.length))
            XCTAssertEqual(try XCTUnwrap(KitScoreRun.ballDistanceError(ballWorld: further, slab: slab, view: view, settings: settings)), 0.005,
                           accuracy: 3e-4)
        }
        XCTAssertNil(KitScoreRun.ballDistanceError(ballWorld: slab.point(u: 0.16, v: 0) + slab.normal * R, slab: slab, view: view, settings: settings),
                     "beside the slab")
    }

    /// The ball on the slab (s08) with the truth-based finder: its distance from its size agrees with the slab's, to
    /// within the lock's own error (a few mm here).
    func testTheBallOnTheSlab() throws {
        let kit = try tinyKit(frames: 6, shots: ["s01-measure", "s08-ball-centre"])
        let r = try KitScorer(kitFolder: kit.folder, options: kit.scorerOptions(truthBall: true)).score()
        let s = try XCTUnwrap(r.shot("s08-ball-centre"))
        // (8 mm while the kit rendered the old box; with the owner's sloped, rounded sides 10.1 mm: see testADropWithTheTruthBall)
        XCTAssertLessThan(abs(try XCTUnwrap(s.metric("ballDistanceError")?.value, "\(s.metrics.compactMap { $0.note })")), 12)
        XCTAssertNotNil(s.metric("ballDetectionRate")?.value, "the truth finder looks for a resting ball")
        // the app's own finder does not look for a ball resting on the slab: its detection rate there is n/a
        let app = try KitScorer(kitFolder: kit.folder, options: kit.scorerOptions()).score()
        XCTAssertEqual(app.shot("s08-ball-centre")?.metric("ballDetectionRate")?.note,
                       "the app looks for a ball only 5 cm or more above the slab, not one resting on it")
    }

    /// The synthetic kit renders the shots with the ball at a real kit's 1440x1080 and the others at 480x360.
    func testBallShotsAreRenderedAtAKitsVideoSize() throws {
        var o = KitSyntheticKit.Options()
        o.framesPerShot = 2
        o.shots = ["s04-level-still", "s08-ball-centre"]
        let kit = try KitSyntheticKit.build(root: root, options: o)
        func video(_ id: String) throws -> KitVideoInfo? {
            try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: kit.folder.appendingPathComponent("shots/\(id)/shot.json"))).video
        }
        XCTAssertEqual(try video("s08-ball-centre")?.width, 1440)
        XCTAssertEqual(try video("s08-ball-centre")?.height, 1080)
        XCTAssertEqual(try video("s04-level-still")?.width, 480)
        XCTAssertEqual(kit.truth["s08-ball-centre"]?.views.first?.intrinsics.width, 1440)
    }

    func testNotAKit() {
        XCTAssertThrowsError(try KitScorer(kitFolder: root).score()) { XCTAssertEqual($0 as? KitScoreError, .notAKit) }
    }

    #if os(macOS) || os(Linux)
    /// With ffmpeg: the synthetic kit written as H.264 and decoded back, as a captured kit is.
    func testThroughEncodedVideo() throws {
        try XCTSkipUnless(KitFFmpeg.isAvailable, "ffmpeg and ffprobe are not installed")
        let kit = try tinyKit(frames: 8, shots: ["s03-flat-level", "s04-level-still"], video: "h264")
        let still = kit.folder.appendingPathComponent("shots/s04-level-still/video.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: still.path))
        XCTAssertEqual(try KitVideoDecoder.probe(still).isFullRange, false)
        var o = KitScorer.Options()
        o.source = "synthetic"
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertNil(r.shot("s04-level-still")?.error)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("tiltErrorMedian")?.value), 0.5)
    }
    #endif
}
