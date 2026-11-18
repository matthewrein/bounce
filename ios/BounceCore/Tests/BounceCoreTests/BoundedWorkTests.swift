import XCTest
@testable import BounceCore

/// Work bounded where it buys nothing (behind TrackerSettings fields whose defaults keep the old behaviour, so older
/// recordings replay as the phone ran them): searches from a still camera that keep finding nothing back off
/// (`idleSearchAfter`); the ball finder, with no ball shown or about to be, slows down after a while of finding none
/// (`idleBallAfter`); the slab sweep does not grow its own finds again, nor refine the same outline twice from one start
/// (`sweepSkipsFinds`, `sweepSameOutlinePixels`).
final class BoundedWorkTests: XCTestCase {
    /// Counts the detector's runs and when they happened; finds the slab only while `visible`.
    final class Counting: SlabDetecting {
        let inner: SceneDetector
        var visible = true
        private(set) var times: [Double] = []
        var now = 0.0
        init(_ inner: SceneDetector) { self.inner = inner }
        func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
            times.append(now)
            return visible ? inner.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near) : []
        }
    }

    let image = ColorFrame(gray: Plane(width: 16, height: 12))
    let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)

    func testTheDefaultsKeepTheOldBehaviourAndTheAppTurnsTheCutsOn() throws {
        let d = TrackerSettings()
        XCTAssertEqual(d.idleSearchAfter, 0)
        XCTAssertEqual(d.idleBallAfter, 0)
        XCTAssertNil(d.maxSweepRegions)
        XCTAssertFalse(d.sweepSkipsFinds)
        XCTAssertEqual(d.sweepSameOutlinePixels, 0)
        // a recording's settings from before the cuts (no such keys) read back with them off
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecordingSettings().trackerSettings)) as! [String: Any]
        for k in ["idleSearchAfter", "idleSearchInterval", "idleSearchMoveDegrees", "idleSearchMoveDistance", "idleBallAfter", "idleBallInterval",
                  "maxSweepRegions", "sweepSkipsFinds", "sweepSameOutlinePixels"] {
            XCTAssertNotNil(json.removeValue(forKey: k), k)
        }
        let old = try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.idleSearchAfter, 0); XCTAssertEqual(old.idleBallAfter, 0); XCTAssertNil(old.maxSweepRegions)
        XCTAssertFalse(old.sweepSkipsFinds); XCTAssertEqual(old.sweepSameOutlinePixels, 0)
        let app = RecordingSettings().trackerSettings
        XCTAssertGreaterThan(app.idleSearchAfter, 0)
        XCTAssertGreaterThan(app.idleBallAfter, 0)
        XCTAssertTrue(app.sweepSkipsFinds)
        XCTAssertGreaterThan(app.sweepSameOutlinePixels, 0)
        XCTAssertEqual(try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app)), app)
    }

    /// Runs `seconds` at 60 fps from `start`, the camera at `pos(t)`, a tap at `tapAt`, a discontinuity at `jumpAt`.
    func run(_ tr: SlabTracker, _ det: Counting, _ w: World, from start: Double, seconds: Double, pos: (Double) -> Vec3,
             tapAt: Double? = nil, jumpAt: Double? = nil) {
        var k = Int((start * 60).rounded())
        while Double(k) / 60 < start + seconds - 1e-9 {
            let t = Double(k) / 60
            let v = w.view(from: pos(t), at: slab.center)
            det.inner.currentView = v; det.now = t
            if let j = jumpAt, abs(t - j) < 0.5 / 60 { tr.noteWorldDiscontinuity("test") }
            let tap: Vec2? = tapAt.map { abs(t - $0) < 0.5 / 60 } == true ? Vec2(240, 180) : nil
            _ = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, tap: tap))
            k += 1
        }
    }

    func gaps(_ times: [Double], from a: Double, to b: Double) -> [Double] {
        let ts = times.filter { $0 >= a - 1e-9 && $0 < b - 1e-9 }
        return zip(ts.dropFirst(), ts).map { $0 - $1 }
    }

    func testSearchesFromAStillCameraThatFindNothingBackOffUntilSomethingChanges() {
        let w = World(slab: slab, lens: .processing)
        let det = Counting(SceneDetector(w, noise: 0.3, seed: 5))
        det.visible = false
        let tr = SlabTracker(settings: RecordingSettings().trackerSettings, detector: det)
        let still = { (_: Double) in Vec3(0, 0.9, 0) }
        run(tr, det, w, from: 0, seconds: 3, pos: still)
        // the first second at the search rate, then backed off
        XCTAssertEqual(gaps(det.times, from: 0, to: 0.95).max() ?? 0, 0.12, accuracy: 0.02)
        let late = gaps(det.times, from: 1.5, to: 3)
        XCTAssertFalse(late.isEmpty)
        XCTAssertEqual(late.min() ?? 0, 0.36, accuracy: 0.02, "backed off to the idle interval")
        XCTAssertTrue(tr.searchIdle)
        // a tap searches on its frame and the rate is back at once
        run(tr, det, w, from: 3, seconds: 0.6, pos: still, tapAt: 3.2)
        XCTAssertTrue(det.times.contains { $0 >= 3.2 - 1e-6 && $0 <= 3.2 + 0.06 }, "searched on the tap's frame (or the first after the 0.05 s gap)")
        XCTAssertEqual(gaps(det.times, from: 3.2, to: 3.6).max() ?? 0, 0.12, accuracy: 0.02)
        // (the tap's seed holds the fast rate; once it times out the backing off starts again)
        run(tr, det, w, from: 3.6, seconds: 9, pos: still)
        XCTAssertTrue(tr.searchIdle)
        // a world-frame discontinuity: at once
        run(tr, det, w, from: 12.6, seconds: 0.5, pos: still, jumpAt: 12.8)
        XCTAssertTrue(det.times.contains { $0 >= 12.8 - 1e-6 && $0 <= 12.8 + 0.06 })
        XCTAssertFalse(tr.searchIdle)
        // backed off again, then the camera turns: the next frame searches at the usual rate
        run(tr, det, w, from: 13.1, seconds: 2, pos: still)
        XCTAssertTrue(tr.searchIdle)
        let turned = { (t: Double) in Vec3(0.3 * min(1, (t - 15.1) / 0.3), 0.9, 0) }
        run(tr, det, w, from: 15.1, seconds: 0.6, pos: turned)
        XCTAssertEqual(gaps(det.times, from: 15.2, to: 15.7).max() ?? 0, 0.12, accuracy: 0.02, "a moving camera searches at the usual rate")
    }

    func testTheOldSettingsNeverBackOff() {
        let w = World(slab: slab, lens: .processing)
        let det = Counting(SceneDetector(w, noise: 0.3, seed: 6))
        det.visible = false
        var s = RecordingSettings().trackerSettings
        s.idleSearchAfter = 0
        let tr = SlabTracker(settings: s, detector: det)
        run(tr, det, w, from: 0, seconds: 4, pos: { _ in Vec3(0, 0.9, 0) })
        XCTAssertEqual(gaps(det.times, from: 0, to: 4).max() ?? 0, 0.12, accuracy: 0.02)
        XCTAssertFalse(tr.searchIdle)
    }

    /// The slab appearing in front of a still camera after a long empty spell is found within one idle interval, and
    /// once a search finds it the confirmation runs at the usual rate: the lock comes at most about 0.24 s later than
    /// without the backing off. A camera panning onto it is not slowed at all.
    func testTimeToLockAfterAnEmptySpell() {
        func lockTime(idle: Bool, panning: Bool) -> Double? {
            let w = World(slab: slab, lens: .processing)
            let det = Counting(SceneDetector(w, noise: 0.3, seed: 7))
            var s = RecordingSettings().trackerSettings
            if !idle { s.idleSearchAfter = 0 }
            let tr = SlabTracker(settings: s, detector: det)
            // 5 s with nothing to find (panning: the camera sweeps the floor), then the slab
            for k in 0..<600 {
                let t = Double(k) / 60
                det.visible = t >= 5
                let x = panning ? 0.4 * sin(t * 1.3) : 0
                let v = w.view(from: Vec3(x, 0.9, 0), at: slab.center)
                det.inner.currentView = v; det.now = t
                if tr.process(TrackerFrame(timestamp: t, view: v, frame: image)).state == .locked { return t - 5 }
            }
            return nil
        }
        let base = lockTime(idle: false, panning: false), idle = lockTime(idle: true, panning: false)
        let panBase = lockTime(idle: false, panning: true), pan = lockTime(idle: true, panning: true)
        XCTAssertNotNil(base); XCTAssertNotNil(idle); XCTAssertNotNil(pan)
        XCTAssertLessThanOrEqual(idle! - base!, 0.36 + 1e-6, "at most one idle interval later")
        XCTAssertEqual(pan!, panBase!, accuracy: 1e-9, "a moving camera is never backed off")
    }

    /// A ball finder with no ball to find, then a ball: after half a second of empty scans it runs every 0.3 s; the ball
    /// is found at the next of those scans, and from then on every 0.1 s; a half outline waiting for its second scan
    /// keeps the usual rate.
    func testTheBallFinderSlowsDownOnlyWhileNothingIsThere() {
        final class Ball: BallLocating {
            var world: Vec3?, view: CameraView?, waiting = false
            private(set) var times: [Double] = []
            var now = 0.0
            var awaitsConfirmation: Bool { waiting }
            func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
                times.append(now)
                guard let w = world, let v = view else { return nil }
                let c = v.toCamera(w)
                return (c, intrinsics.project(c) ?? .zero, 9)
            }
            func reset() {}
        }
        func scenario(_ s: TrackerSettings, waitingFrom: Double? = nil) -> (ball: Ball, foundAt: Double?) {
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.3, seed: 8), ball = Ball()
            let tr = SlabTracker(settings: s, detector: det, ballLocator: ball)
            var foundAt: Double? = nil
            for k in 0..<360 {
                let t = Double(k) / 60
                let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
                det.currentView = v; ball.view = v; ball.now = t
                ball.world = t >= 4 ? slab.center + Vec3(0, 0.4, 0) : nil
                if let wf = waitingFrom { ball.waiting = t >= wf }
                let o = tr.process(TrackerFrame(timestamp: t, view: v, frame: image, ballImage: tr.ballDue(at: t) ? Plane(width: 30, height: 20) : nil,
                                                ballIntrinsics: w.intrinsics))
                if foundAt == nil, o.ball != nil { foundAt = t }
            }
            return (ball, foundAt)
        }
        var old = RecordingSettings().trackerSettings
        old.idleBallAfter = 0
        let (b0, f0) = scenario(old)
        XCTAssertEqual(gaps(b0.times, from: 1, to: 6).max() ?? 0, 0.1, accuracy: 0.02, "the old settings: every 0.1 s")
        let (b1, f1) = scenario(RecordingSettings().trackerSettings)
        let first = b1.times.first ?? 0
        XCTAssertEqual(gaps(b1.times, from: first, to: first + 0.45).max() ?? 0, 0.1, accuracy: 0.02, "the first half second at the usual rate")
        XCTAssertEqual(gaps(b1.times, from: first + 0.8, to: 4).min() ?? 0, 0.3, accuracy: 0.02, "then every 0.3 s")
        XCTAssertNotNil(f0); XCTAssertNotNil(f1)
        XCTAssertLessThanOrEqual(f1! - f0!, 0.3 + 1.0 / 60 + 1e-6, "the ball is found at the next idle scan")
        XCTAssertEqual(gaps(b1.times, from: f1! + 0.01, to: 6).max() ?? 0, 0.1, accuracy: 0.02, "a shown ball: every 0.1 s again")
        // something waiting for a second scan keeps the usual rate
        let (b2, _) = scenario(RecordingSettings().trackerSettings, waitingFrom: 0)
        XCTAssertEqual(gaps(b2.times, from: 1, to: 4).max() ?? 0, 0.1, accuracy: 0.02)
    }

    /// The finder's two sweep options on rendered frames (the slab at 2 and 4 ft, a bare floor): the same slab found
    /// (outline within a fraction of a pixel of the full sweep's), with fewer regions grown and refined.
    func testTheSweepFindsTheSameSlabWithLessWork() {
        let K = CameraIntrinsics(fx: 362.5, fy: 362.5, cx: 240, cy: 180, width: 480, height: 360)
        for (i, feet) in [2.0, 4, 0].enumerated() {
            let sl = SyntheticScene.slabPose(tilt: 8, heading: 35, yaw: 20)
            let az = Units.radians(25), el = Units.radians(50)
            let pos = sl.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * Units.feet(feet == 0 ? 3 : feet)
            let target = feet == 0 ? sl.center + Vec3(1.2, 0, 1.4) : sl.center
            let view = SyntheticScene.camera(at: pos, lookingAt: target, intrinsics: K, roll: 3)
            var sc = SyntheticScene(slab: sl)
            sc.supersample = 1
            let frame = SyntheticScene.ycc(rgb: sc.renderRGB(view: view), width: K.width, height: K.height).colorFrame
            let down = view.directionToCamera(ARKitConvention.worldDown)
            func sweep(_ o: SlabFinder.Options) -> (found: [SlabCandidate], grown: Int, refined: Int) {
                let run = FinderRun(options: o, frame: frame, intrinsics: K, spec: .standard, down: down, detail: nil, choice: nil)
                let f = run.sweep()
                return (f, run.seedsGrown, run.refined)
            }
            let full = sweep(SlabFinder.Options())
            var o = SlabFinder.Options()
            o.skipSeedsInFinds = true
            o.sameOutlinePixels = RecordingSettings().trackerSettings.sweepSameOutlinePixels
            let cut = sweep(o)
            XCTAssertEqual(cut.found.count > 0, full.found.count > 0, "frame \(i)")
            if let a = full.found.first, let b = cut.found.first {
                let d = Geometry.bestCorrespondence(a.quad, b.quad).meanDistance
                XCTAssertLessThan(d, 1.0, "frame \(i): the same slab (\(d) px)")
            }
            XCTAssertLessThanOrEqual(cut.grown, full.grown, "frame \(i)")
            XCTAssertLessThanOrEqual(cut.refined, full.refined, "frame \(i)")
            if feet == 2 { XCTAssertLessThan(cut.grown, full.grown, "the slab's own points are not grown again") }
        }
    }

    /// The tracker hands its settings for the sweep to the slab finder (and unset ones leave the finder's own).
    func testTheDetectorTakesTheTrackersSweepSettings() {
        var base = SlabFinder.Options()
        base.maxSweepRegions = 40
        let det = SlabFinderDetector(finder: SlabFinder(options: base))
        var s = TrackerSettings()
        let tr = SlabTracker(settings: s, detector: det)
        XCTAssertEqual(det.finder.options.maxSweepRegions, 40)
        XCTAssertFalse(det.finder.options.skipSeedsInFinds)
        s.maxSweepRegions = 24; s.sweepSkipsFinds = true; s.sweepSameOutlinePixels = 1.5
        tr.settings = s
        XCTAssertEqual(det.finder.options.maxSweepRegions, 24)
        XCTAssertTrue(det.finder.options.skipSeedsInFinds)
        XCTAssertEqual(det.finder.options.sameOutlinePixels, 1.5)
        tr.settings = TrackerSettings()
        XCTAssertEqual(det.finder.options.maxSweepRegions, 40, "back to the finder's own")
        XCTAssertFalse(det.finder.options.skipSeedsInFinds)
        XCTAssertEqual(det.finder.options.sameOutlinePixels, 0)
    }
}
