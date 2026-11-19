import BounceCore
import Foundation

/// One timed stage.
struct StageResult: Codable {
    /// where it runs in the app: on the processing queue (what the app runs per frame), for comparison only (not what the
    /// app runs), on the session recorder's own queue, or the code a behaviour-preserving cut replaced
    enum Role: String, Codable { case app, comparison, recorderQueue = "recorder queue", candidate }
    /// convert, crop, slab, ball, lidar, kit, recording, fixtures, candidate
    var group: String
    var name: String
    /// what it ran on (scene, sizes)
    var input: String
    var stats: Stats
    var role: Role = .app
    /// what it found, or how it relates to the app
    var note: String?
    /// regions the slab search's sweep grew (instrumented build only)
    var regionsGrown: Int? = nil
}

/// Smallest rms corner distance between two four-corner outlines over the corner orders (start and direction).
func outlineDistance(_ a: [Vec2], _ b: [Vec2]) -> Double {
    guard a.count == 4, b.count == 4 else { return .infinity }
    var best = Double.infinity
    for rev in [false, true] {
        let bb = rev ? Array(b.reversed()) : b
        for s in 0..<4 {
            var e = 0.0
            for i in 0..<4 { e += a[i].distance(to: bb[(i + s) % 4]).squared }
            best = min(best, (e / 4).squareRoot())
        }
    }
    return best
}

extension Double { var squared: Double { self * self } }

func fmtSize(_ p: Plane) -> String { "\(p.width)x\(p.height)" }

/// The regions the last sweeps grew (instrumented build: BounceCore's SlabFinder copy logs them), summed; nil otherwise.
func takeSweepRegions() -> Int? {
    #if BENCH_SWEEP_STATS
    defer { benchSweepLog.removeAll() }
    return benchSweepLog.isEmpty ? nil : benchSweepLog.map(\.grown).reduce(0, +)
    #else
    return nil
    #endif
}

/// The per-stage timings.
final class StageBench {
    let all: SceneSet
    let quick: Bool
    let only: String?
    let iterations: Int?
    let fixtures: URL?
    let log: (String) -> Void
    let probe: (String) -> Void
    private(set) var results: [StageResult] = []

    init(scenes: SceneSet, quick: Bool, only: String?, iterations: Int?, fixtures: URL?, log: @escaping (String) -> Void, probe: @escaping (String) -> Void) {
        all = scenes; self.quick = quick; self.only = only; self.iterations = iterations; self.fixtures = fixtures; self.log = log; self.probe = probe
    }

    private func budget(_ b: Budget) -> Budget {
        var o = quick ? b.quick() : b
        if let n = iterations { o = o.with(iterations: n); o.warmup = min(o.warmup, 1) }
        return o
    }

    private func wanted(_ group: String, _ name: String, _ input: String) -> Bool {
        guard let o = only?.lowercased(), !o.isEmpty else { return true }
        return "\(group) \(name) \(input)".lowercased().contains(o)
    }

    func timeStage(_ group: String, _ name: String, input: String, _ b: Budget, role: StageResult.Role = .app, note: String? = nil,
                   regions: Int? = nil, _ body: (Int) -> Void) {
        guard wanted(group, name, input) else { return }
        var i = 0
        let ts = timeRuns(budget(b)) { body(i); i += 1 }
        let st = Stats(ts)
        results.append(StageResult(group: group, name: name, input: input, stats: st, role: role, note: note, regionsGrown: regions))
        log(String(format: "  %@ | %@ | %@: p50 %.3f ms, p95 %.3f, min %.3f (n %d)", group, name, input, st.p50, st.p95, st.min, st.n)
            + (note.map { "; \($0)" } ?? "") + (regions.map { "; \($0) regions grown" } ?? ""))
    }

    var plain: [BenchScene] { all.scenes.filter { $0.variant == .plain } }
    var slabScenes: [BenchScene] { plain.filter { $0.kind == .slab } }
    func scene(feet: Double, ball: Bool) -> BenchScene? { all.scene(feet: feet, ball: ball) }
    var empty: BenchScene? { all.scene(feet: nil, ball: false) }

    func runAll() {
        conversions(); probe("after convert")
        crops(); probe("after crop")
        slabFinder(); probe("after slab")
        ballFinder(); probe("after ball")
        lidar()
        kit()
        recording()
        fixtureSearches(); probe("after fixtures")
        candidates(); probe("after candidates")
    }

    // MARK: conversions

    func conversions() {
        guard let s = scene(feet: 4, ball: false) ?? all.scenes.first else { return }
        let ring = s.ring()
        timeStage("convert", "bi-planar -> 480x360 YCCImage (YCCImage.fromBiplanar, factor 4)", input: "1920x1440 camera buffer, 8 buffers in turn", .fast,
             note: "the app's FrameConversion.ycc: on every frame the slab detector runs on (and recorded frames); each run reads another buffer (from memory, as the camera's)") {
            blackHole(ring[$0 % ring.count].processingImage())
        }
        timeStage("convert", "bi-planar -> 480x360 YCCImage (YCCImage.fromBiplanar, factor 4)", input: "1920x1440, the same buffer every run (cache-warm)", .fast,
             role: .comparison, note: "for comparison: what the cache-warm figure would say") {
            _ in blackHole(s.processingImage())
        }
        let img = s.processingImage()   // (cheap next to what follows)
        timeStage("convert", "YCCImage -> ColorFrame (ycc.colorFrame)", input: "480x360", .fast,
             note: "the app converts it only when the slab detector will run (SlabTracker.detectorWillRun): the detector is all that reads it") {
            _ in blackHole(img.colorFrame)
        }
        timeStage("convert", "mean luma, every 8th pixel (KitImageStats.meanLuma)", input: "1920x1440 luma, 8 buffers in turn", .fast,
             note: "capture kit recorder only, per recorded frame") { i in
            let r = ring[i % ring.count]
            r.luma.withUnsafeBufferPointer { blackHole(KitImageStats.meanLuma(bytes: $0, width: r.width, height: r.height, bytesPerRow: r.lumaStride, step: 8)) }
        }
    }

    // MARK: crops

    func crops() {
        for s in slabScenes where s.ballHeight == nil {
            guard let q = s.truthOutline, let c = SlabImageCrop.plan(outline: q, processing: s.processing.intrinsics, full: s.full.intrinsics) else {
                log("  (\(s.name): no slab crop)"); continue
            }
            let ring = s.ring()
            let input = "\(s.name): \(c.imageWidth)x\(c.imageHeight) px, factor \(c.factor) (\(c.width)x\(c.height) camera px)"
            for v in AppReplicas.CropVariant.available {
                timeStage("crop", "slab crop, " + v.rawValue, input: input, .fast, role: v == .app ? .app : .comparison) { i in
                    blackHole(ring[i % ring.count].lumaCrop(v, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor))
                }
            }
        }
        for s in slabScenes where s.ballHeight != nil {
            guard let c = BallImageCrop.plan(slab: s.scene.slab, full: s.full) else { log("  (\(s.name): no ball crop)"); continue }
            let ring = s.ring()
            let input = "\(s.name): \(c.imageWidth)x\(c.imageHeight) px, factor \(c.factor) (\(c.width)x\(c.height) camera px)"
            for v in AppReplicas.CropVariant.available {
                timeStage("crop", "ball crop, " + v.rawValue, input: input, .fast, role: v == .app ? .app : .comparison) { i in
                    blackHole(ring[i % ring.count].lumaCrop(v, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor))
                }
            }
        }
    }

    // MARK: the slab finder

    /// The slab finder as the app runs it: SlabFinderDetector with the app's tracker settings applied (the sweep's
    /// options, `SlabDetecting.apply`).
    static func appFinder() -> SlabFinder {
        let det = SlabFinderDetector()
        det.apply(RecordingSettings().trackerSettings)
        return det.finder
    }

    func slabFinder() {
        let spec = RecordingSettings().slab
        let searchScenes = all.scenes.filter { $0.ballHeight == nil && $0.variant != .hand }
        for s in searchScenes {
            let cf = s.processingImage().colorFrame
            let pK = s.processing.intrinsics, down = s.downCam
            let truth = s.truthOutline
            let finder = StageBench.appFinder(), ownFinder = SlabFinder()
            func found(_ c: [SlabCandidate]) -> String {
                guard let t = truth else { return "\(c.count) outline(s) (none is right: no slab in view)" }
                let best = c.map { outlineDistance($0.quad, t) }.min()
                return "\(c.count) outline(s), nearest the truth \(best.map { String(format: "%.1f px", $0) } ?? "-")"
            }
            let coldName = "search, cold, whole view (SlabFinder.find, the app's sweep options)"
            if wanted("slab", coldName, s.name) {
                _ = takeSweepRegions()
                let cold = finder.find(frame: cf, intrinsics: pK, spec: spec, down: down)
                let grown = takeSweepRegions()
                timeStage("slab", coldName, input: s.name, .slow, note: found(cold), regions: grown) {
                    _ in blackHole(finder.find(frame: cf, intrinsics: pK, spec: spec, down: down))
                }
            }
            let ownName = "search, cold, whole view, the finder's own sweep (before the app's options)"
            if wanted("slab", ownName, s.name) {
                let cold = ownFinder.find(frame: cf, intrinsics: pK, spec: spec, down: down)
                timeStage("slab", ownName, input: s.name, Budget.slow.with(iterations: 10), role: .comparison, note: "for comparison: " + found(cold)) {
                    _ in blackHole(ownFinder.find(frame: cf, intrinsics: pK, spec: spec, down: down))
                }
            }
            guard s.variant == .plain else { continue }
            let tap = s.tapPoint ?? Vec2(Double(pK.width) / 2, Double(pK.height) / 2)
            let tapName = "search with a tap seed"
            if wanted("slab", tapName, s.name) {
                let tapped = finder.find(frame: cf, intrinsics: pK, spec: spec, down: down, seed: tap)
                timeStage("slab", tapName, input: s.name, .slow, role: .comparison, note: "for comparison (a tap's search): " + found(tapped)) {
                    _ in blackHole(finder.find(frame: cf, intrinsics: pK, spec: spec, down: down, seed: tap))
                }
            }
            guard let q = truth else { continue }
            // the full-resolution crop the tracker asks for around the predicted outline (cut as the app does)
            let provider = SlabImageCrop.provider(processing: pK, full: s.full.intrinsics) { c in
                s.lumaCrop(AppReplicas.CropVariant.app, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor)
            }
            guard let detail = provider(q) else { log("  (\(s.name): no slab crop)"); continue }
            let cropIn = "\(s.name), crop \(fmtSize(detail.luma)) factor \(detail.crop.factor)"
            func nearest(_ o: [DetectedOutline]) -> String {
                "\(o.count) outline(s), nearest the truth \(o.map { outlineDistance($0.quad, q) }.min().map { String(format: "%.2f px", $0) } ?? "-")"
            }
            let recheckName = "re-check: follow the predicted outline, full-res crop"
            if wanted("slab", recheckName, cropIn) {
                // the detector as the tracker keeps it: its edge memory from the re-checks before
                let det = SlabFinderDetector()
                for _ in 0..<3 { _ = det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: detail.image) }
                let rc = det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: detail.image)
                timeStage("slab", recheckName, input: cropIn, .slow, note: nearest(rc)) {
                    _ in blackHole(det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: detail.image))
                }
            }
            let plainName = "re-check without the crop (processing frame only)"
            if wanted("slab", plainName, s.name) {
                let det = SlabFinderDetector()
                for _ in 0..<3 { _ = det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: nil) }
                timeStage("slab", plainName, input: s.name, .slow, role: .comparison, note: "for comparison: what the crop adds to a re-check") {
                    _ in blackHole(det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: nil))
                }
            }
            let refineName = "refine a search's find on the full-res crop"
            if wanted("slab", refineName, cropIn) {
                // (the search's find is the true outline within 0.1 px on these frames)
                let det = SlabFinderDetector()
                let rf = det.refine(outline: q, frame: cf, intrinsics: pK, spec: spec, down: down, detail: detail.image)
                timeStage("slab", refineName, input: cropIn, .slow, role: .comparison, note: "part of a search + refine frame: " + nearest(rf)) {
                    _ in blackHole(det.refine(outline: q, frame: cf, intrinsics: pK, spec: spec, down: down, detail: detail.image))
                }
            }
            let ring = s.ring(4)
            timeStage("slab", "plan + cut the slab crop (SlabImageCrop.provider)", input: cropIn, .fast) { i in
                let r = ring[i % ring.count]
                let p = SlabImageCrop.provider(processing: pK, full: r.full.intrinsics) { c in
                    r.lumaCrop(AppReplicas.CropVariant.app, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor)
                }
                blackHole(p(q))
            }
        }
    }

    // MARK: the ball finder

    func ballFinder() {
        let rs = RecordingSettings(), spec = rs.slab, ball = rs.ball
        for s in all.scenes where s.kind == .slab {
            guard let c = BallImageCrop.plan(slab: s.scene.slab, full: s.full),
                  let img = s.lumaCrop(.rows, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor) else { continue }
            let K = c.intrinsics(full: s.full.intrinsics)
            let slabCam = s.scene.slab.transformed(by: s.full.cameraFromWorld)
            let down = s.downCam
            let input = "\(s.name), crop \(fmtSize(img)) factor \(c.factor)"
            let firstName = "first scan, whole window (fresh BallLocator)"
            if wanted("ball", firstName, input) {
                let first = BallLocator().update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down)
                var note = first.map { String(format: "found r %.1f px", $0.circle.radius) } ?? "none found"
                if let B = s.scene.ball, let o = first { note += String(format: ", %.1f cm from the truth", o.center.distance(to: s.full.toCamera(B)) * 100) }
                timeStage("ball", firstName, input: input, .slow, note: note) {
                    _ in blackHole(BallLocator().update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down))
                }
            }
            let followName = "following scan (BallLocator after earlier scans)"
            if wanted("ball", followName, input) {
                let loc = BallLocator()
                for _ in 0..<3 { _ = loc.update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down) }
                timeStage("ball", followName, input: input, .slow,
                     note: loc.current == nil ? "nothing followed: each scan searches the whole window" : "follows the ball found (a still ball: the cheapest case)") {
                    _ in blackHole(loc.update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down))
                }
            }
        }
    }

    // MARK: LiDAR

    func lidar() {
        if let s = scene(feet: 4, ball: false) {
            timeStage("lidar", "depth + confidence copy (FrameConversion.depth)", input: "256x192", .fast,
                 note: "the app does it on every locked frame") { _ in blackHole(s.depthFromBuffers()) }
        }
        for s in slabScenes where s.ballHeight == nil {
            let r = PlaneFit.checkSlabTop(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab)
            timeStage("lidar", "plane check of the slab's top (PlaneFit.checkSlabTop)", input: s.name, .fast,
                 note: r.map { "\($0.candidates ?? 0) points, \($0.points) inliers, \(String(format: "%.2f", $0.angleToImageDegrees)) deg to the truth" } ?? "no check")
            { _ in
                blackHole(PlaneFit.checkSlabTop(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab))
            }
        }
    }

    // MARK: the capture kit's recorder (per kept frame, on the processing queue)

    func kit() {
        guard let s = scene(feet: 4, ball: true) ?? all.scenes.first else { return }
        let ring = s.ring()
        let kw = KitWork()
        #if canImport(Accelerate)
        timeStage("kit", "kit video scale (vImage Lanczos, FrameConversion.scale), the app's call", input: "1920x1440 -> 1440x1080, 8 buffers in turn", .fast,
             note: "capture kit recorder, every kept frame (late ones too); vImage splits it over the cores: wall time") { i in kw.scale(ring[i % ring.count]) }
        timeStage("kit", "kit video scale, one core (kvImageDoNotTile)", input: "1920x1440 -> 1440x1080, 8 buffers in turn", .fast, role: .comparison,
             note: "for comparison: one core's time (what it costs the phone's cores in all)") { i in kw.scale(ring[i % ring.count], oneCore: true) }
        #else
        timeStage("kit", "kit video scale: pure-Swift Lanczos-3 stand-in for vImage (Linux)", input: "1920x1440 -> 1440x1080, 8 buffers in turn", .slow,
             note: "NOT the app's code: vImage is several times faster; the Mac's report times vImage itself") { i in kw.scale(ring[i % ring.count]) }
        #endif
        timeStage("kit", "the kit recorder's work per kept frame (scale, mean luma, depth once a second)", input: "1920x1440, 8 buffers in turn", .slow,
             note: kitWhat) { i in kw.consume(ring[i % ring.count], t: Double(i) / 60) }
    }

    // MARK: recording (the session recorder's encoding, on its own queue in the app)

    func recording() {
        guard let s = scene(feet: 4, ball: true) else { return }
        let img = s.processingImage()
        timeStage("recording", "processing image -> BYC1 bytes (YCCImage.data)", input: "480x360", .fast, role: .recorderQueue, note: "session recorder queue (utility)") {
            _ in blackHole(img.data)
        }
        timeStage("recording", "whole depth map -> BDP1 bytes (DepthMap.data)", input: "256x192", .fast, role: .recorderQueue, note: "session recorder queue") {
            _ in blackHole(s.depth.data)
        }
        if let r = PlaneFit.depthRegion(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab) {
            timeStage("recording", "depth under the lock (PlaneFit.depthRegion)", input: "\(r.0.width)x\(r.0.height) of 256x192", .fast,
                 note: "processing queue, every recorded locked frame") { _ in
                blackHole(PlaneFit.depthRegion(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab))
            }
        }
        for f in [2.0, 4] {
            guard let b = scene(feet: f, ball: true), let c = BallImageCrop.plan(slab: b.scene.slab, full: b.full),
                  let p = b.lumaCrop(.rows, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor) else { continue }
            timeStage("recording", "ball crop -> exact PGM (Plane.pgmData(blockSum:))", input: "\(b.name): \(fmtSize(p)) factor \(c.factor)", .fast,
                 role: .recorderQueue, note: "session recorder queue, every ball frame") { _ in
                let k = [c.factor, 1, 2, 3, 4].first { p.isBlockAverage(of: $0) } ?? 16
                blackHole(p.pgmData(blockSum: k))
            }
        }
    }

    // MARK: the committed procedural fixtures (a cross-check of the search's cost on other floors)

    func fixtureSearches() {
        guard let root = fixtures, let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            log("  (no fixtures folder: the fixture searches are left out)"); return
        }
        let finder = StageBench.appFinder()
        for n in names.sorted() where n.hasPrefix("rec_") {
            guard let r = try? RecordingReader(folder: root.appendingPathComponent(n)), let f = r.frames.first, let img = try? r.image(for: f),
                  let g = f.gravityCamera else { continue }
            let cf = img.colorFrame, K = f.intrinsics, spec = r.session.settings.slab, down = Vec3(g)
            let px = Double(K.width * K.height)
            _ = takeSweepRegions()
            let found = finder.find(frame: cf, intrinsics: K, spec: spec, down: down)
            let grown = takeSweepRegions()
            let name = "search, cold, whole view (SlabFinder.find, the app's sweep options)"
            guard wanted("fixtures", name, n) else { continue }
            let ts = timeRuns(budget(.slow)) { blackHole(finder.find(frame: cf, intrinsics: K, spec: spec, down: down)) }
            let st = Stats(ts)
            let per = st.p50 / px * 172_800
            results.append(StageResult(group: "fixtures", name: name, input: "\(n) (\(K.width)x\(K.height))", stats: st, role: .comparison,
                                       note: String(format: "%d outline(s); %.1f ms at 480x360's pixel count (p50 x 172800 / %.0f px)", found.count, per, px),
                                       regionsGrown: grown))
            log(String(format: "  fixtures | %@ | %@: p50 %.3f ms (%.1f at 480x360's pixels), min %.3f", name, n, st.p50, per, st.min) + (grown.map { "; \($0) regions" } ?? ""))
        }
    }
}
