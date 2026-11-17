import XCTest
@testable import BounceCore

/// A ball held at a known world point: returns its centre in the camera axes of the frame's view, as a perfect ball
/// finder would, and records what it was handed.
final class KnownBall: BallLocating {
    var world: Vec3?
    var view: CameraView?
    struct Call { var time: Double; var slab: SlabPose; var image: (Int, Int); var intrinsics: CameraIntrinsics }
    private(set) var calls: [Call] = []
    private(set) var resets = 0
    var now = 0.0
    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        calls.append(Call(time: now, slab: slab, image: (image.width, image.height), intrinsics: intrinsics))
        guard let w = world, let v = view else { return nil }
        let c = v.toCamera(w)
        return (c, intrinsics.project(c) ?? .zero, 9)
    }
    func reset() { resets += 1 }
}

/// Counts the frames it was handed without the image (a blank: the app did not convert one).
final class BlankCountingDetector: SlabDetecting {
    let inner: SceneDetector
    private(set) var blanks = 0, calls = 0
    private(set) var seeds: [Vec2?] = []
    init(_ inner: SceneDetector) { self.inner = inner }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        calls += 1; seeds.append(seed)
        if frame.width < 10 { blanks += 1 }
        return inner.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near)
    }
}

/// The app's paths through the tracker that no test covered (review #33), and what it now reports for recordings and
/// diagnostics.
final class TrackerAppPathTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 2, height: 2))
    let image = ColorFrame(gray: Plane(width: 16, height: 12))

    func appSettings() -> TrackerSettings { RecordingSettings().trackerSettings }

    /// The ball through the tracker as the app drives it (60 fps, the app's intervals, the ball image made only when
    /// `ballDue`): its world centre, the drop from it, the slab handed over in camera axes, the finder's rate; no ball
    /// after a re-lock or a lost lock until the finder sees it again.
    func testTheBallThroughTheTracker() throws {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 41), ball = KnownBall()
        let tr = SlabTracker(settings: appSettings(), detector: det, ballLocator: ball)
        let ballW = slab.center + Vec3(0.01, 0.4, -0.02)
        ball.world = ballW
        var k = 0, dueFrames = 0, crops = true
        func frame() -> TrackerOutput {
            let t = Double(k) / 60; k += 1
            let v = w.view(from: Vec3(0.05 * sin(t), 0.9, 0.03 * cos(t)), at: w.slab.center)
            det.currentView = v; ball.view = v; ball.now = t
            let due = tr.ballDue(at: t) && crops
            if due { dueFrames += 1 }
            let o = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, ballImage: due ? Plane(width: 30, height: 20) : nil,
                                             ballIntrinsics: due ? v.intrinsics.scaled(by: 2) : nil, floorY: 0))
            XCTAssertEqual(o.ballSearched, due && o.state == .locked, "t \(t)")
            if o.ballSearched, let s = o.slab {
                // the slab the finder got is the lock in this frame's camera axes, with the crop's intrinsics
                let c = ball.calls.last!
                XCTAssertLessThan(angleDeg(c.slab.normal, v.directionToCamera(s.normal)), 1e-5)
                XCTAssertLessThan(c.slab.center.distance(to: v.toCamera(s.center)), 1e-9)
                XCTAssertEqual(c.intrinsics, v.intrinsics.scaled(by: 2))
                XCTAssertTrue(c.image == (30, 20))
            }
            return o
        }
        var o = frame()
        while o.state != .locked { o = frame() }
        for _ in 0..<60 { o = frame() }
        let b = try XCTUnwrap(o.ball)
        XCTAssertLessThan(b.center.distance(to: ballW), 1e-9, "world centre")
        let r = try XCTUnwrap(o.readouts)
        XCTAssertTrue(r.dropFromBall)
        let d = try XCTUnwrap(Bounce.drop(ballCenter: ballW, pose: o.slab!, spec: .standard, ball: BallSpec(), down: ARKitConvention.worldDown))
        XCTAssertEqual(r.dropHeight, d.dropHeight, accuracy: 1e-9)
        // the finder ran on every frame the app was told it was due, never more often than ballInterval
        XCTAssertEqual(ball.calls.count, dueFrames)
        let gaps = zip(ball.calls.dropFirst(), ball.calls).map { $0.time - $1.time }
        XCTAssertGreaterThanOrEqual(gaps.min()!, appSettings().ballInterval - 1e-9)
        XCTAssertLessThan(gaps.max()!, appSettings().ballInterval + 0.02)

        // the slab is moved: on the re-lock the ball is forgotten (and the finder reset) until it is seen again
        let resets0 = ball.resets
        w.slab = World.slabAt(slab.center + Vec3(0.03, 0.002, 0), tilt: 12, heading: 200)
        det.world = w
        var relock: TrackerOutput? = nil
        for _ in 0..<(60 * 4) { o = frame(); if o.events.contains("relocked") { relock = o; break } }
        let rl = try XCTUnwrap(relock)
        XCTAssertGreaterThan(ball.resets, resets0)
        if !rl.ballSearched { XCTAssertNil(rl.ball, "no ball from before the re-lock") }

        // the slab disappears in view and the app can no longer make the ball's crop, so the last ball is kept but goes
        // stale (a held ball would excuse the misses for a second): lost, the ball forgotten and the finder reset; found
        // again, the first locked frame shows no ball from before
        for _ in 0..<30 { o = frame() }
        XCTAssertNotNil(o.ball)
        let resets1 = ball.resets
        crops = false
        det.silent = true
        var lost = false
        for _ in 0..<(60 * 8) { o = frame(); if o.events.contains("lost") { lost = true; break } }
        XCTAssertTrue(lost)
        XCTAssertGreaterThan(ball.resets, resets1)
        XCTAssertNil(o.ball)
        det.silent = false
        crops = true
        repeat { o = frame() } while o.state != .locked
        XCTAssertNil(o.ball, "the lock frame has no ball from before the loss")
        XCTAssertFalse(o.readouts!.dropFromBall)
    }

    /// With ARKit's tracking limited the detector never runs (the poses are not good), whatever is due; a tap then is
    /// searched on the first normal frame, at the tapped place, on an image the app converted because `detectionDue`
    /// said so.
    func testLimitedTrackingNeverRunsTheDetectorAndATapWaitsForNormalTracking() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = BlankCountingDetector(SceneDetector(w, noise: 0.3, seed: 42))
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        det.inner.currentView = v
        var events: [String] = []
        func frame(_ k: Int, normal: Bool, tap: Vec2? = nil) {
            let t = Double(k) / 60
            let needImage = tap != nil || tr.detectionDue(at: t)   // as the app decides
            events += tr.process(TrackerFrame(timestamp: t, view: v, frame: needImage ? image : blank, tap: tap, trackingNormal: normal)).events
        }
        for k in 0..<90 { frame(k, normal: false) }
        XCTAssertEqual(det.calls, 0, "no detection while limited")
        for k in 90..<180 { frame(k, normal: true) }
        XCTAssertEqual(tr.state, .locked)
        let calls = det.calls
        for k in 180..<240 { frame(k, normal: false, tap: k == 200 ? Vec2(240, 180) : nil) }
        XCTAssertEqual(det.calls, calls, "no detection while limited, tap or not")
        XCTAssertTrue(events.contains("tap-deferred"))
        XCTAssertEqual(tr.state, .locked, "the tap waits")
        frame(240, normal: true)
        XCTAssertEqual(det.calls, calls + 1, "searched on the first normal frame")
        XCTAssertNotNil(det.seeds.last!, "at the tapped place")
        XCTAssertNotEqual(tr.state, .locked)
        for k in 241..<330 { frame(k, normal: true) }
        XCTAssertEqual(tr.state, .locked)
        XCTAssertEqual(det.blanks, 0, "the detector always had the image")
    }

    /// What is done to the tracker between frames is reported with the next frame, in order, for recordings.
    func testControlsAreReportedWithTheNextFrame() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 43)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        det.currentView = v
        let first = tr.process(TrackerFrame(timestamp: 0, view: v, frame: image))
        XCTAssertEqual(first.controls, [TrackerControl(kind: .start, settings: appSettings())])
        XCTAssertEqual(tr.process(TrackerFrame(timestamp: 0.1, view: v, frame: image)).controls, [])
        var s = tr.settings; s.launchRule = .dishNormal
        tr.settings = s
        tr.settings = s                 // unchanged: not reported again
        tr.reset()
        tr.noteWorldDiscontinuity("interruption")
        let o = tr.process(TrackerFrame(timestamp: 0.2, view: v, frame: image))
        XCTAssertEqual(o.controls, [TrackerControl(kind: .settings, settings: s), TrackerControl(kind: .reset),
                                    TrackerControl(kind: .worldDiscontinuity, reason: "interruption")])
        XCTAssertNotNil(o.detections, "the detector ran on this frame")
        XCTAssertEqual(tr.process(TrackerFrame(timestamp: 0.21, view: v, frame: image)).controls, [])
    }

    /// Each detection is logged with what it led to and the measurement's shape, for diagnostics.
    func testTheDetectionLogSaysWhatEachDetectionDid() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 44)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        det.currentView = v
        var k = 0
        func frame() -> TrackerOutput { defer { k += 1 }; return tr.process(TrackerFrame(timestamp: Double(k) / 30, view: v, frame: image)) }
        while frame().state != .locked {}
        let lockEntry = tr.detectionLog.last!
        XCTAssertTrue(lockEntry.outcome.contains("locks"), "\(lockEntry.outcome)")
        XCTAssertEqual(lockEntry.state, .confirming)
        for _ in 0..<30 { _ = frame() }
        let e = tr.detectionLog.last!
        XCTAssertEqual(e.state, .locked)
        XCTAssertTrue(e.outcome.contains("recheckAgree"), "\(e.outcome)")
        XCTAssertEqual(e.found, 1)
        XCTAssertEqual(e.tiltDegrees!, 6, accuracy: 1.5)
        XCTAssertEqual(e.distance!, slab.center.distance(to: v.position), accuracy: 0.05)
        XCTAssertEqual(e.sidesPixels!.count, 4)
        XCTAssertGreaterThan(e.aspect!, 0.3); XCTAssertLessThan(e.aspect!, 3)
        XCTAssertNotNil(e.rmsPixels); XCTAssertNotNil(e.sigmaDegrees)
        XCTAssertEqual(Vec3(e.center!).distance(to: slab.center), 0, accuracy: 0.02)
        // a misshapen outline: rejected, and logged as such
        det.occludedCorner = true
        while tr.detectionLog.last!.rejected.isEmpty { _ = frame() }
        XCTAssertEqual(tr.detectionLog.last!.rejected, ["misfit"])
        XCTAssertNil(tr.detectionLog.last!.center)
        XCTAssertLessThanOrEqual(tr.detectionLog.count, SlabTracker.detectionLogSize)
    }

    /// The diagnostics carry what reading a bad session needs (#29), each field's frame stated in the JSON itself.
    func testDiagnosticsHaveWhatAnEngineerNeeds() throws {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 7, heading: 120)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.2, seed: 45), ball = KnownBall()
        let tr = SlabTracker(settings: appSettings(), detector: det, ballLocator: ball)
        let v = w.view(from: Vec3(0, 0.8, 0.1), at: slab.center)
        det.currentView = v; ball.view = v; ball.world = slab.center + Vec3(0, 0.3, 0)
        let dm = w.depthMap(v, spec: .standard)
        var o: TrackerOutput! = nil
        for k in 0..<90 {
            let t = Double(k) / 30, due = tr.ballDue(at: t)
            o = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, depth: dm.0, depthIntrinsics: dm.1,
                                        ballImage: due ? Plane(width: 40, height: 30) : nil, ballIntrinsics: due ? v.intrinsics : nil, floorY: 0))
        }
        XCTAssertEqual(o.state, .locked)
        var readouts = try XCTUnwrap(o.readouts)
        readouts.airTime = .infinity; readouts.apexHeight = .nan
        let lens = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let crop = BallImageCrop(x0: 400, y0: 100, width: 800, height: 900, factor: 2)
        var rep = DiagnosticsReport(build: "n3", device: "iPhone15,2", system: "iOS 17", time: "now", settings: RecordingSettings(dishBounce: true),
                                    state: o.state.rawValue, tracking: "normal", fps: 60, msProcess: 3, lens: lens, depthSupported: true,
                                    depth: o.depth, captureLocked: true, slab: o.slab, outline: o.outline, sideModes: tr.lastSideModes, ball: o.ball,
                                    readouts: readouts, counts: tr.counts, recentEvents: ["1.00 locked"], recording: nil)
        rep.addTracker(tr, view: v, lens: lens, output: o, ballCrop: crop, floorY: 0)
        rep.videoFormat = .init(width: 1920, height: 1440, framesPerSecond: 60)
        rep.thermalState = "fair"
        rep.frameTime = 2.9667
        let js = rep.json(pretty: true)
        let back = try DiagnosticsReport.decode(json: rep.json())
        // the frames legend explains every field that has one
        let legend = try XCTUnwrap(back.frames)
        for key in ["world", "lens", "processing", "slab", "imageSlab", "outline", "ball", "ballCrop", "ballFull", "camera", "depth", "history",
                    "readouts", "recentEvents", "floorY"] {
            XCTAssertNotNil(legend[key], key)
        }
        XCTAssertEqual(back.processing, .init(width: 480, height: 360, factor: 4))
        let cam = try XCTUnwrap(back.camera)
        XCTAssertEqual(cam.distanceToSlab!, v.position.distance(to: o.slab!.center), accuracy: 1e-3)
        XCTAssertEqual(cam.position, v.position.array.map { ($0 * 10000).rounded() / 10000 })
        XCTAssertEqual(cam.downInImage[1], 1, accuracy: 1e-3, "held in landscape: gravity down the image")
        XCTAssertGreaterThan(cam.viewAngleDegrees!, 20)
        XCTAssertNotNil(back.imageSlab)
        XCTAssertEqual(back.depthFused, o.depthFused)
        XCTAssertNotNil(back.depth)
        let hist = try XCTUnwrap(back.history)
        XCTAssertGreaterThan(hist.count, 5); XCTAssertLessThanOrEqual(hist.count, 15)
        XCTAssertNotNil(hist.last!.sidesPixels)
        XCTAssertEqual(back.tracker, tr.settings)
        XCTAssertEqual(back.settings.launchRule, .dishNormal)
        let b = try XCTUnwrap(back.ball)
        XCTAssertEqual(back.ballCrop, crop)
        let full = crop.toFull(Vec2(b[3], b[4]))
        XCTAssertEqual(back.ballFull![0], full.x, accuracy: 0.01); XCTAssertEqual(back.ballFull![2], b[5] * 2, accuracy: 0.01)
        XCTAssertEqual(back.floorY, 0); XCTAssertEqual(back.floorBelowSlab!, o.slab!.center.y, accuracy: 1e-4)
        XCTAssertEqual(back.videoFormat?.framesPerSecond, 60)
        XCTAssertEqual(back.thermalState, "fair")
        XCTAssertEqual(back.frameTime, 2.9667)
        // non-finite readouts survive as strings rather than breaking the JSON
        XCTAssertTrue(js.contains("\"inf\"") && js.contains("\"nan\""), js)
        XCTAssertEqual(back.readouts?.airTime, .infinity)
        XCTAssertTrue(back.readouts!.apexHeight.isNaN)
        // a report from an older build, without the new fields, still reads
        var old = try JSONSerialization.jsonObject(with: Data(rep.json().utf8)) as! [String: Any]
        for k in ["frames", "processing", "camera", "imageSlab", "depthFused", "history", "ballCrop", "ballFull", "tracker", "floorY",
                  "floorBelowSlab", "videoFormat", "thermalState", "frameTime"] { old[k] = nil }
        old["readouts"] = nil
        let oldBack = try JSONDecoder().decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(oldBack.camera); XCTAssertEqual(oldBack.build, "n3")
    }
}
