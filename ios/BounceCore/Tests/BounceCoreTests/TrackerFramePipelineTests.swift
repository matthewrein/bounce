import XCTest
@testable import BounceCore

/// Reports the world's true outline (with noise) like SceneDetector, and records what the tracker gave it: the finer
/// image on each run, and its refine calls (which return the true outline, shifted by `refineShift`).
final class DetailSpyDetector: SlabDetecting {
    var world: World
    var view: CameraView?
    var noise = 0.4
    var silent = false
    var refineShift = Vec2(0, 0)
    var rng = SeededRandom(91)
    struct Call { var detail: DetailImage?; var near: [Vec2]?; var refine: [Vec2]? }
    private(set) var calls: [Call] = []
    private(set) var refinedReturned: [[Vec2]] = []
    private(set) var forgets = 0
    init(_ w: World) { world = w }

    func truth(_ intrinsics: CameraIntrinsics) -> [Vec2]? {
        guard let v = view else { return nil }
        let cv = CameraView(worldFromCamera: v.worldFromCamera, intrinsics: intrinsics)
        let q = world.slab.topCorners.compactMap { cv.project(world: $0) }
        return q.count == 4 && q.allSatisfy({ intrinsics.contains($0, margin: 1) }) ? q : nil
    }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: nil)
    }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                detail: DetailImage?) -> [DetectedOutline] {
        calls.append(Call(detail: detail, near: near, refine: nil))
        guard !silent, let q = truth(intrinsics) else { return [] }
        return [DetectedOutline(quad: q.map { Vec2($0.x + rng.gaussian() * noise, $0.y + rng.gaussian() * noise) })]
    }
    func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, detail: DetailImage) -> [DetectedOutline] {
        calls.append(Call(detail: detail, near: nil, refine: outline))
        guard let q = truth(intrinsics) else { return [] }
        refinedReturned.append(q.map { $0 + refineShift })
        return [DetectedOutline(quad: q.map { $0 + refineShift })]
    }
    func forgetPixelMemory() { forgets += 1 }
}

/// The tracker's part of the frame pipeline: how often its detector can run, its full-resolution slab crops, and a change
/// of the camera's video format.
final class TrackerFramePipelineTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))
    /// the phone's full camera image and the app's processing frame (factor 4)
    let full = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
    var processing: CameraIntrinsics { .processing }

    func appSettings() -> TrackerSettings {
        var s = RecordingSettings().trackerSettings
        s.spec = .standard
        return s
    }

    // MARK: how often the detector runs

    /// Runs a tracker at 60 fps for `seconds`; `before(i, t)` is called before each frame (to force detections) and
    /// returns a tap for it, if any. Checks on every frame that `detectionDue(at:tap:)` said exactly whether the detector
    /// would run, and returns the times it ran.
    func runAt60(_ tr: SlabTracker, _ det: DetailSpyDetector, view: (Int) -> CameraView, from t0: Double = 0, seconds: Double,
                 before: (Int, Double) -> Vec2? = { _, _ in nil }) -> [Double] {
        var runs: [Double] = []
        for i in 0..<Int(seconds * 60) {
            let t = t0 + Double(i) / 60
            let tap = before(i, t)
            let v = view(i)
            det.view = v
            let due = tr.detectionDue(at: t, tap: tap != nil)
            let out = tr.process(TrackerFrame(timestamp: t, view: v, frame: blank, tap: tap))
            XCTAssertEqual(due, out.detections != nil, "frame \(i): detectionDue said \(due)")
            XCTAssertEqual(out.detectionKind != nil, out.detections != nil)
            if out.detections != nil { runs.append(t) }
        }
        return runs
    }

    func testSearchCannotRunOnEveryFrameAt60fps() {
        let s = appSettings()
        XCTAssertEqual(s.searchInterval, RecordingSettings.appSearchInterval)
        XCTAssertGreaterThan(s.minDetectionGap, 2.0 / 60, "the app's gap spans more than two frames at 60 fps")
        XCTAssertEqual(TrackerSettings().minDetectionGap, 0, "the default (older recordings) has none")
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)

        // nothing to find: a search every searchInterval, never two frames in a row
        let det = DetailSpyDetector(w); det.silent = true
        let tr = SlabTracker(settings: s, detector: det)
        var runs = runAt60(tr, det, view: { _ in v }, seconds: 10)
        XCTAssertEqual(tr.state, .searching)
        XCTAssertLessThanOrEqual(Double(runs.count) / 10, 1 / s.searchInterval + 0.2)
        XCTAssertGreaterThanOrEqual(zip(runs, runs.dropFirst()).map { $1 - $0 }.min()!, s.searchInterval - 1e-9)

        // the worst case: a discontinuity reported before every frame and a tap every fifth frame; each forces a run on the
        // next frame, but the runs stay minDetectionGap apart: at most 20 a second, never on consecutive frames
        let tr2 = SlabTracker(settings: s, detector: det)
        runs = runAt60(tr2, det, view: { _ in v }, seconds: 10) { i, _ in
            tr2.noteWorldDiscontinuity("relocalized")
            return i % 5 == 0 ? Vec2(240, 180) : nil
        }
        let gaps = zip(runs, runs.dropFirst()).map { $1 - $0 }
        print(String(format: "forced every frame at 60 fps: %d detector runs in 10 s, closest %.1f ms apart", runs.count, gaps.min()! * 1000))
        XCTAssertLessThanOrEqual(Double(runs.count) / 10, 1 / s.minDetectionGap + 0.1)
        XCTAssertGreaterThanOrEqual(gaps.min()!, s.minDetectionGap - 1e-9)
        XCTAssertGreaterThan(gaps.min()!, 1.5 / 60, "never on consecutive frames")
        XCTAssertGreaterThan(Double(runs.count) / 10, 12, "but forced runs still come promptly")

        // locked, with the camera's reported position jumping on every frame (a pose-jump discontinuity each time)
        let det3 = DetailSpyDetector(w)
        let tr3 = SlabTracker(settings: s, detector: det3)
        _ = runAt60(tr3, det3, view: { _ in v }, seconds: 2)
        XCTAssertEqual(tr3.state, .locked)
        let jumpy: (Int) -> CameraView = { i in w.view(from: Vec3(i % 2 == 0 ? 0.0 : 0.3, 0.9, 0), at: slab.center) }
        runs = runAt60(tr3, det3, view: jumpy, from: 2, seconds: 5)
        XCTAssertGreaterThan(tr3.counts["discontinuities"] ?? 0, 200)
        XCTAssertLessThanOrEqual(Double(runs.count) / 5, 1 / s.minDetectionGap + 0.2)
        XCTAssertGreaterThanOrEqual(zip(runs, runs.dropFirst()).map { $1 - $0 }.min()!, s.minDetectionGap - 1e-9)
    }

    func testAForcedDetectionWaitsAtMostTheGap() {
        let s = appSettings()
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        let det = DetailSpyDetector(w)
        let tr = SlabTracker(settings: s, detector: det)
        _ = runAt60(tr, det, view: { _ in v }, seconds: 3)
        XCTAssertEqual(tr.state, .locked)
        // a re-check runs at t0; one frame later the app reports a discontinuity: the forced run comes on the first frame
        // minDetectionGap after t0, not one frame later and not at the next scheduled re-check
        var t = 3.0, t0: Double? = nil
        while t0 == nil {
            det.view = v
            if tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)).detections != nil { t0 = t }
            t += 1.0 / 60
        }
        tr.noteWorldDiscontinuity("interruption")
        var forced: Double? = nil
        for _ in 0..<30 {
            if tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)).detections != nil { forced = t; break }
            t += 1.0 / 60
        }
        let dt = try! XCTUnwrap(forced) - t0!
        XCTAssertGreaterThanOrEqual(dt, s.minDetectionGap - 1e-9)
        XCTAssertLessThan(dt, s.minDetectionGap + 1.0 / 60 + 1e-9)
        XCTAssertLessThan(dt, s.recheckInterval)
        // a backwards clock does not hold the detector back
        tr.noteWorldDiscontinuity("interruption")
        XCTAssertTrue(tr.detectionDue(at: t - 10))
    }

    func testOlderSettingsWithoutTheGapReadAsNone() throws {
        let old = try JSONDecoder().decode(TrackerSettings.self, from: Data(#"{"searchInterval": 0.12}"#.utf8))
        XCTAssertEqual(old.minDetectionGap, 0)
        let back = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(appSettings()))
        XCTAssertEqual(back.minDetectionGap, RecordingSettings.appMinDetectionGap)
    }

    // MARK: full-resolution slab crops

    func testFullResolutionCropsAreCutWhereTheSlabShouldBe() {
        let s = appSettings()
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = DetailSpyDetector(w)
        det.refineShift = Vec2(0.3, -0.2)
        let tr = SlabTracker(settings: s, detector: det)
        var cuts: [SlabImageCrop] = []
        let provider = SlabImageCrop.provider(processing: processing, full: full) { c in
            cuts.append(c)
            return Plane(width: c.imageWidth, height: c.imageHeight, fill: 100)
        }
        var outs: [TrackerOutput] = []
        for i in 0..<(60 * 3) {
            let t = Double(i) / 60
            let v = w.view(from: Vec3(0.05 * sin(t), 0.9, 0.02 * t), at: slab.center)
            det.view = v
            let before = cuts.count
            let out = tr.process(TrackerFrame(timestamp: t, view: v, frame: blank, slabDetail: provider))
            outs.append(out)
            XCTAssertLessThanOrEqual(cuts.count - before, 1, "at most one crop a frame")
            if out.detections == nil { XCTAssertEqual(cuts.count, before, "no crop without a detector run") }
            XCTAssertEqual(out.slabDetail != nil, cuts.count > before)
            // every crop holds the slab's true outline and the edge steps' reach around it, in full image pixels
            if let d = out.slabDetail, let q = det.truth(full) {
                let longest = (0..<4).map { q[$0].distance(to: q[($0 + 1) % 4]) }.max()!
                for p in q {
                    XCTAssertGreaterThanOrEqual(p.x - 0.45 * longest, Double(d.crop.x0)); XCTAssertLessThanOrEqual(p.x + 0.45 * longest, Double(d.crop.x0 + d.crop.width))
                    XCTAssertGreaterThanOrEqual(p.y - 0.45 * longest, Double(d.crop.y0)); XCTAssertLessThanOrEqual(p.y + 0.45 * longest, Double(d.crop.y0 + d.crop.height))
                }
                XCTAssertEqual(d.intrinsics, d.crop.intrinsics(full: full))
                XCTAssertEqual(d.crop.factor, 1, "a slab 1 m away needs no shrinking")
            }
        }
        XCTAssertEqual(tr.state, .locked)
        // the search's find: detected on the processing frame alone, then refined on a crop around it
        let first = outs.firstIndex { $0.detections != nil }!
        XCTAssertNotNil(outs[first].refinedDetections)
        XCTAssertNotNil(outs[first].slabDetail)
        XCTAssertNil(det.calls[0].detail)
        XCTAssertNotNil(det.calls[1].refine)
        XCTAssertNotNil(det.calls[1].detail)
        let refined = det.refinedReturned[0]
        let used = SlabTracker.aligned(try! XCTUnwrap(outs[first].measurement), to: refined)
        XCTAssertLessThan(zip(used, refined).map { $0.distance(to: $1) }.max()!, 1e-9, "the refined outline is the one used")
        // every search (searching, confirming) ran on the processing frame alone and was refined on a crop around its
        // find; every re-check following the lock got the crop around the lock up front
        for (k, c) in det.calls.enumerated() where c.refine == nil {
            if c.near == nil {
                XCTAssertNil(c.detail, "call \(k)")
                XCTAssertTrue(k + 1 < det.calls.count && det.calls[k + 1].refine != nil && det.calls[k + 1].detail != nil, "call \(k): refined")
            } else {
                XCTAssertNotNil(c.detail, "call \(k)")
            }
        }
        XCTAssertTrue(det.calls.contains { $0.near != nil }, "re-checks ran")
        let log = tr.detectionLog
        XCTAssertTrue(log.allSatisfy { $0.edges == ($0.state == .locked ? "crop" : "refined") }, "\(log.map { "\($0.state) \($0.edges ?? "-")" })")
        XCTAssertEqual(tr.counts["slabCrops"] ?? 0, tr.counts["searches", default: 0] + tr.counts["rechecks", default: 0])
        XCTAssertEqual(tr.counts["slabRefines"], tr.counts["searches"])

        // a camera that cannot provide the pixels: the processing frame alone, as before
        let det2 = DetailSpyDetector(w)
        let tr2 = SlabTracker(settings: s, detector: det2)
        for i in 0..<(60 * 3) {
            let t = Double(i) / 60, v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
            det2.view = v
            let out = tr2.process(TrackerFrame(timestamp: t, view: v, frame: blank, slabDetail: { _ in nil }))
            XCTAssertNil(out.slabDetail); XCTAssertNil(out.refinedDetections)
        }
        XCTAssertEqual(tr2.state, .locked)
        XCTAssertTrue(det2.calls.allSatisfy { $0.detail == nil && $0.refine == nil })
        XCTAssertTrue(tr2.detectionLog.allSatisfy { $0.edges == nil })
    }

    func testARefinedOutlineElsewhereIsNotTaken() {
        // the refine pass returns an outline far from the find (another object): the find is kept
        let s = appSettings()
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = DetailSpyDetector(w)
        det.refineShift = Vec2(25, 0)
        let tr = SlabTracker(settings: s, detector: det)
        let provider = SlabImageCrop.provider(processing: processing, full: full) { c in Plane(width: c.imageWidth, height: c.imageHeight, fill: 9) }
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        det.view = v
        let out = tr.process(TrackerFrame(timestamp: 0, view: v, frame: blank, slabDetail: provider))
        XCTAssertNotNil(out.refinedDetections)
        XCTAssertEqual(tr.counts["slabRefineMisses"], 1)
        XCTAssertNil(tr.detectionLog.last?.edges)
        let q = try! XCTUnwrap(out.measurement)
        XCTAssertLessThan(zip(SlabTracker.aligned(q, to: det.truth(processing)!), det.truth(processing)!).map { $0.distance(to: $1) }.max()!, 3)
    }

    func testSlabCropPlanning() {
        let pK = processing
        // a slab 55 px across in the processing frame (about 4 ft): 220 px in the full image, cut at factor 1
        let q = [Vec2(200, 150), Vec2(255, 152), Vec2(253, 205), Vec2(198, 203)]
        let c = try! XCTUnwrap(SlabImageCrop.plan(outline: q, processing: pK, full: full))
        XCTAssertEqual(c.factor, 1)
        let fq = q.map { $0 * 4 }
        let longest = (0..<4).map { fq[$0].distance(to: fq[($0 + 1) % 4]) }.max()!
        XCTAssertEqual(Double(c.x0), fq.map { $0.x }.min()! - SlabImageCrop.margin * longest - SlabImageCrop.marginPixels, accuracy: 1)
        XCTAssertEqual(Double(c.x0 + c.width), fq.map { $0.x }.max()! + SlabImageCrop.margin * longest + SlabImageCrop.marginPixels, accuracy: 1)
        XCTAssertEqual(c.imageWidth, c.width); XCTAssertLessThan(c.width * c.height, SlabImageCrop.maxPixels)
        // its intrinsics map the same camera
        let K = c.intrinsics(full: full), p = Vec3(0.05, -0.02, 1.2)
        XCTAssertEqual(ImageMap(from: pK, to: K).forward(pK.project(p)!).distance(to: K.project(p)!), 0, accuracy: 1e-9)
        // a near slab (a third of the frame): shrunk so the crop stays within maxPixels, a whole number of blocks
        let big = [Vec2(120, 60), Vec2(330, 70), Vec2(320, 280), Vec2(110, 270)]
        let b = try! XCTUnwrap(SlabImageCrop.plan(outline: big, processing: pK, full: full))
        XCTAssertGreaterThanOrEqual(b.factor, 2)
        XCTAssertLessThanOrEqual(b.imageWidth * b.imageHeight, SlabImageCrop.maxPixels)
        XCTAssertEqual(b.width % b.factor, 0); XCTAssertEqual(b.height % b.factor, 0)
        XCTAssertGreaterThanOrEqual(b.x0, 0); XCTAssertLessThanOrEqual(b.x0 + b.width, 1920)
        XCTAssertGreaterThanOrEqual(b.y0, 0); XCTAssertLessThanOrEqual(b.y0 + b.height, 1440)
        // at the image's edge: clamped; off the image or degenerate: none
        let edge = q.map { $0 + Vec2(-195, -140) }
        let e = try! XCTUnwrap(SlabImageCrop.plan(outline: edge, processing: pK, full: full))
        XCTAssertEqual(e.x0, 0); XCTAssertEqual(e.y0, 0)
        XCTAssertNil(SlabImageCrop.plan(outline: q.map { $0 + Vec2(900, 0) }, processing: pK, full: full))
        XCTAssertNil(SlabImageCrop.plan(outline: Array(q.prefix(3)), processing: pK, full: full))
        XCTAssertNil(SlabImageCrop.plan(outline: [Vec2(.nan, 1), q[1], q[2], q[3]], processing: pK, full: full))
        // the provider refuses a cut of the wrong size
        XCTAssertNil(SlabImageCrop.provider(processing: pK, full: full) { _ in Plane(width: 10, height: 10) }(q))
        XCTAssertNotNil(SlabImageCrop.provider(processing: pK, full: full) { c in Plane(width: c.imageWidth, height: c.imageHeight) }(q))
    }

    // MARK: a change of video format

    func testAVideoFormatChangeLeavesTheLockUnconfirmedUntilSeenAgain() {
        let s = appSettings()
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var w = World(slab: slab, lens: .processing)
        let det = DetailSpyDetector(w)
        let tr = SlabTracker(settings: s, detector: det, ballLocator: HeldBall())
        let pos = Vec3(0.05, 0.9, 0.1)
        var t = 0.0
        func step(_ n: Int, note: String? = nil) -> [TrackerOutput] {
            var outs: [TrackerOutput] = []
            for k in 0..<n {
                if k == 0, let r = note { tr.noteWorldDiscontinuity(r) }
                let v = w.view(from: pos, at: slab.center)
                det.view = v
                outs.append(tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)))
                t += 1.0 / 60
            }
            return outs
        }
        _ = step(60 * 6)
        XCTAssertEqual(tr.state, .locked)
        XCTAssertFalse(tr.lockUnconfirmed)
        let noiseBefore = tr.cornerNoiseEstimate
        let lockBefore = tr.slab!
        XCTAssertNotEqual(noiseBefore, s.cornerNoisePixels, "the re-checks measured the corner noise")
        // the kit opens: 1280x960 (the processing frame 640x480, a finer pixel), noted by the app on its first frame
        w.intrinsics = CameraIntrinsics(fx: 1450.0 * 1280 / 1920 / 2, fy: 1450.0 * 1280 / 1920 / 2, cx: 320, cy: 240, width: 640, height: 480)
        det.world = w
        let firstAfter = step(1, note: VideoFormatWatch.discontinuityReason)
        XCTAssertEqual(tr.cornerNoiseEstimate, s.cornerNoisePixels, "measured again in the new pixels: the assumed noise until then")
        let after = firstAfter + step(60 * 2 - 1)
        let unconfirmedEvent = after[0].events.firstIndex { $0.hasPrefix("lock-unconfirmed") }
        XCTAssertEqual(unconfirmedEvent.map { after[0].events[$0] }, "lock-unconfirmed: video-format")
        XCTAssertEqual(tr.counts["discontinuities"], 1, "the app's report and the tracker's own notice are one discontinuity")
        XCTAssertEqual(tr.counts["frameSizeChanges"], 1)
        XCTAssertEqual(det.forgets, 1, "the detector's pixel memory was dropped")
        // unconfirmed until a detection at the new size sees it (here the forced re-check, on the first frame the gap
        // allows), then confirmed, without a relock
        let confirmedAt = after.firstIndex { $0.events.contains("lock-confirmed") }!
        XCTAssertTrue(after[..<confirmedAt].allSatisfy { $0.lockUnconfirmed })
        XCTAssertNotNil(after[confirmedAt].detections, "confirmed by a detection in the new frame")
        if confirmedAt == 0 { XCTAssertGreaterThan(after[0].events.firstIndex(of: "lock-confirmed")!, unconfirmedEvent!) }
        XCTAssertLessThan(Double(confirmedAt) / 60, s.minDetectionGap + 0.02, "the forced re-check confirms it")
        XCTAssertFalse(after.last!.lockUnconfirmed)
        XCTAssertEqual(tr.counts["relocks"] ?? 0, 0)
        XCTAssertLessThan(Units.degrees(tr.slab!.normal.angle(to: lockBefore.normal)), 0.5)
        // the outline is drawn in the new frame's pixels
        let truth = w.corners(in: w.view(from: pos, at: slab.center))
        XCTAssertLessThan(zip(after.last!.outline!, truth).map { $0.distance(to: $1) }.max()!, 2)
    }

    func testAFormatChangeWithTheSlabGoneLosesTheLock() {
        let s = appSettings()
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        for gone in ["out of view", "not found"] {
            var w = World(slab: slab, lens: .processing)
            let det = DetailSpyDetector(w)
            let tr = SlabTracker(settings: s, detector: det)
            let pos = Vec3(0, 0.9, 0)
            var t = 0.0
            for _ in 0..<(60 * 4) {
                let v = w.view(from: pos, at: slab.center); det.view = v
                _ = tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)); t += 1.0 / 60
            }
            XCTAssertEqual(tr.state, .locked, gone)
            w.intrinsics = CameraIntrinsics(fx: 483.3, fy: 483.3, cx: 320, cy: 240, width: 640, height: 480)
            det.world = w
            if gone == "not found" { det.silent = true }
            let target = gone == "out of view" ? Vec3(-2, 0.5, 0.5) : slab.center
            var lostAt: Double? = nil
            let t0 = t
            var events: [String] = []
            for _ in 0..<(60 * 8) {
                let v = w.view(from: pos, at: target); det.view = v
                let o = tr.process(TrackerFrame(timestamp: t, view: v, frame: blank)); t += 1.0 / 60
                events += o.events
                if o.events.contains("lost") { lostAt = t - t0; break }
            }
            XCTAssertTrue(events.contains("lock-unconfirmed: frame-size"), "\(gone): \(events)")
            let lost = try! XCTUnwrap(lostAt, "\(gone): the lock is not kept silently")
            XCTAssertLessThanOrEqual(lost, s.unconfirmedTimeout + 0.1, gone)
            XCTAssertEqual(tr.state, .searching)
        }
    }

    // MARK: the slab finder with a crop that covers only part of the view

    func testAnOutlineTheCropDoesNotCoverUsesTheFramesOwnPixels() throws {
        let f = try SlabFrame.load("rec_replay_still")[3]
        let finder = SlabFinder()
        let plain = try XCTUnwrap(finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down).first)
        // a crop of the view's far corner (nothing of the slab), at 4x the frame's resolution: no outline it does not cover
        // reads its clamped border, so the find is the same as without it
        let K4 = f.intrinsics.scaled(by: 4)
        let cx = plain.quad.map { $0.x }.reduce(0, +) / 4 < Double(f.intrinsics.width) / 2 ? K4.width - 300 : 0
        let cy = plain.quad.map { $0.y }.reduce(0, +) / 4 < Double(f.intrinsics.height) / 2 ? K4.height - 300 : 0
        let away = DetailImage(luma: Plane(width: 300, height: 300, fill: 37),
                               intrinsics: K4.cropped(x0: Double(cx), y0: Double(cy), scale: 1, width: 300, height: 300))
        let withAway = try XCTUnwrap(finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, detail: away).first)
        XCTAssertEqual(withAway.quad, plain.quad)
    }
}
