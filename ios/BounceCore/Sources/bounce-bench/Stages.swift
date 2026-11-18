import BounceCore
import Foundation

/// One timed stage.
struct StageResult: Codable {
    /// convert, crop, slab, ball, lidar, recording
    var group: String
    var name: String
    /// what it ran on (scene, sizes)
    var input: String
    var stats: Stats
    /// what it found, or how it relates to the app
    var note: String?
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

/// The per-stage timings.
final class StageBench {
    let scenes: [BenchScene]
    let quick: Bool
    let only: String?
    let iterations: Int?
    let log: (String) -> Void
    private(set) var results: [StageResult] = []

    init(scenes: [BenchScene], quick: Bool, only: String?, iterations: Int?, log: @escaping (String) -> Void) {
        self.scenes = scenes; self.quick = quick; self.only = only; self.iterations = iterations; self.log = log
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

    func timeStage(_ group: String, _ name: String, input: String, _ b: Budget, note: String? = nil, _ body: () -> Void) {
        guard wanted(group, name, input) else { return }
        let ts = timeRuns(budget(b), body)
        let st = Stats(ts)
        results.append(StageResult(group: group, name: name, input: input, stats: st, note: note))
        log(String(format: "  %@ | %@ | %@: p50 %.3f ms, p95 %.3f, min %.3f (n %d)", group, name, input, st.p50, st.p95, st.min, st.n) + (note.map { "; \($0)" } ?? ""))
    }

    var slabScenes: [BenchScene] { scenes.filter { $0.kind == .slab } }
    func scene(feet: Double, ball: Bool) -> BenchScene? { scenes.first { $0.feet == feet && ($0.ballHeight != nil) == ball } }
    var empty: BenchScene? { scenes.first { $0.kind == .nothing } }

    func runAll() {
        conversions()
        crops()
        slabFinder()
        ballFinder()
        lidar()
        recording()
        candidates()
    }

    // MARK: conversions

    func conversions() {
        guard let s = scene(feet: 4, ball: false) ?? scenes.first else { return }
        timeStage("convert", "bi-planar -> 480x360 YCCImage (YCCImage.fromBiplanar, factor 4)", input: "1920x1440 camera buffer", .fast,
             note: "the app's FrameConversion.ycc: on every frame the slab detector runs on (and recorded frames)") {
            blackHole(s.processingImage())
        }
        let img = s.processingImage()   // (cheap next to what follows)
        timeStage("convert", "YCCImage -> ColorFrame (ycc.colorFrame)", input: "480x360", .fast,
             note: "the app converts it before tracker.process on the same frames") {
            blackHole(img.colorFrame)
        }
        timeStage("convert", "mean luma, every 8th pixel (KitImageStats.meanLuma)", input: "1920x1440 luma", .fast,
             note: "capture kit recorder only, per recorded frame") {
            s.luma.withUnsafeBufferPointer { blackHole(KitImageStats.meanLuma(bytes: $0, width: s.width, height: s.height, bytesPerRow: s.lumaStride, step: 8)) }
        }
        #if canImport(Accelerate)
        var l = s.luma, c = s.cbcr
        var dl = [UInt8](repeating: 0, count: 1440 * 1080), dc = [UInt8](repeating: 0, count: 1440 * 540)
        timeStage("convert", "kit video scale (vImage Lanczos, FrameConversion.scale)", input: "1920x1440 -> 1440x1080", .fast,
             note: "capture kit recorder only, per recorded frame") {
            l.withUnsafeMutableBufferPointer { lp in c.withUnsafeMutableBufferPointer { cp in
                dl.withUnsafeMutableBufferPointer { dlp in dc.withUnsafeMutableBufferPointer { dcp in
                    blackHole(AppReplicas.kitVideoScale(luma: lp, cbcr: cp, width: 1920, height: 1440, lumaStride: s.lumaStride, cbcrStride: s.cbcrStride,
                                                        into: dlp, dcp, dw: 1440, dh: 1080))
                } }
            } }
        }
        #endif
    }

    // MARK: crops

    func crops() {
        for s in slabScenes where s.ballHeight == nil {
            guard let q = s.truthOutline, let c = SlabImageCrop.plan(outline: q, processing: s.processing.intrinsics, full: s.full.intrinsics) else {
                log("  (\(s.name): no slab crop)"); continue
            }
            let input = "\(s.name): \(c.imageWidth)x\(c.imageHeight) px, factor \(c.factor) (\(c.width)x\(c.height) camera px)"
            for v in AppReplicas.CropVariant.available {
                timeStage("crop", "slab crop, " + v.rawValue, input: input, .fast) { blackHole(s.lumaCrop(v, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor)) }
            }
        }
        for s in slabScenes where s.ballHeight != nil {
            guard let c = BallImageCrop.plan(slab: s.scene.slab, full: s.full) else { log("  (\(s.name): no ball crop)"); continue }
            let input = "\(s.name): \(c.imageWidth)x\(c.imageHeight) px, factor \(c.factor) (\(c.width)x\(c.height) camera px)"
            for v in AppReplicas.CropVariant.available {
                timeStage("crop", "ball crop, " + v.rawValue, input: input, .fast) { blackHole(s.lumaCrop(v, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor)) }
            }
        }
    }

    // MARK: the slab finder

    func slabFinder() {
        let spec = SlabSpec.standard
        for s in slabScenes.filter({ $0.ballHeight == nil }) + (empty.map { [$0] } ?? []) {
            let cf = s.processingImage().colorFrame
            let pK = s.processing.intrinsics, down = s.downCam
            let truth = s.truthOutline
            let finder = SlabFinder()
            func found(_ c: [SlabCandidate]) -> String {
                guard let t = truth else { return "\(c.count) outline(s) (none is right: no slab in view)" }
                let best = c.map { outlineDistance($0.quad, t) }.min()
                return "\(c.count) outline(s), nearest the truth \(best.map { String(format: "%.1f px", $0) } ?? "-")"
            }
            let coldName = "search, cold, whole view (SlabFinder.find)"
            if wanted("slab", coldName, s.name) {
                let cold = finder.find(frame: cf, intrinsics: pK, spec: spec, down: down)
                timeStage("slab", coldName, input: s.name, .slow, note: found(cold)) {
                    blackHole(finder.find(frame: cf, intrinsics: pK, spec: spec, down: down))
                }
            }
            let tap = s.tapPoint ?? Vec2(Double(pK.width) / 2, Double(pK.height) / 2)
            let tapName = "search with a tap seed"
            if wanted("slab", tapName, s.name) {
                let tapped = finder.find(frame: cf, intrinsics: pK, spec: spec, down: down, seed: tap)
                timeStage("slab", tapName, input: s.name, .slow, note: found(tapped)) {
                    blackHole(finder.find(frame: cf, intrinsics: pK, spec: spec, down: down, seed: tap))
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
                    blackHole(det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: detail.image))
                }
            }
            let plainName = "re-check without the crop (processing frame only)"
            if wanted("slab", plainName, s.name) {
                let det = SlabFinderDetector()
                for _ in 0..<3 { _ = det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: nil) }
                timeStage("slab", plainName, input: s.name, .slow, note: "for comparison: what the crop adds to a re-check") {
                    blackHole(det.detect(frame: cf, intrinsics: pK, spec: spec, down: down, seed: nil, near: q, detail: nil))
                }
            }
            let refineName = "refine a search's find on the full-res crop"
            if wanted("slab", refineName, cropIn) {
                // (the search's find is the true outline within 0.1 px on these frames)
                let det = SlabFinderDetector()
                let rf = det.refine(outline: q, frame: cf, intrinsics: pK, spec: spec, down: down, detail: detail.image)
                timeStage("slab", refineName, input: cropIn, .slow, note: nearest(rf)) {
                    blackHole(det.refine(outline: q, frame: cf, intrinsics: pK, spec: spec, down: down, detail: detail.image))
                }
            }
            timeStage("slab", "plan + cut the slab crop (SlabImageCrop.provider)", input: cropIn, .fast) { blackHole(provider(q)) }
        }
    }

    // MARK: the ball finder

    func ballFinder() {
        let spec = SlabSpec.standard, ball = BallSpec()
        for s in slabScenes {
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
                    blackHole(BallLocator().update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down))
                }
            }
            let followName = "following scan (BallLocator after earlier scans)"
            if wanted("ball", followName, input) {
                let loc = BallLocator()
                for _ in 0..<3 { _ = loc.update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down) }
                timeStage("ball", followName, input: input, .slow,
                     note: loc.current == nil ? "nothing followed: each scan searches the whole window" : "follows the ball found") {
                    blackHole(loc.update(luma: img, intrinsics: K, slab: slabCam, spec: spec, ball: ball, down: down))
                }
            }
        }
    }

    // MARK: LiDAR

    func lidar() {
        if let s = scene(feet: 4, ball: false) {
            timeStage("lidar", "depth + confidence copy (FrameConversion.depth)", input: "256x192", .fast,
                 note: "the app does it on every locked frame") { blackHole(s.depthFromBuffers()) }
        }
        for s in slabScenes where s.ballHeight == nil {
            let r = PlaneFit.checkSlabTop(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab)
            timeStage("lidar", "plane check of the slab's top (PlaneFit.checkSlabTop)", input: s.name, .fast,
                 note: r.map { "\($0.candidates ?? 0) points, \($0.points) inliers, \(String(format: "%.2f", $0.angleToImageDegrees)) deg to the truth" } ?? "no check")
            {
                blackHole(PlaneFit.checkSlabTop(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab))
            }
        }
    }

    // MARK: recording (the session recorder's encoding, on its own queue in the app)

    func recording() {
        guard let s = scene(feet: 4, ball: true) else { return }
        let img = s.processingImage()
        timeStage("recording", "processing image -> BYC1 bytes (YCCImage.data)", input: "480x360", .fast, note: "session recorder queue (utility)") {
            blackHole(img.data)
        }
        timeStage("recording", "whole depth map -> BDP1 bytes (DepthMap.data)", input: "256x192", .fast, note: "session recorder queue") {
            blackHole(s.depth.data)
        }
        if let r = PlaneFit.depthRegion(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab) {
            timeStage("recording", "depth under the lock (PlaneFit.depthRegion)", input: "\(r.0.width)x\(r.0.height) of 256x192", .fast,
                 note: "processing queue, every recorded locked frame") {
                blackHole(PlaneFit.depthRegion(depth: s.depth, depthIntrinsics: s.depthIntrinsics, view: s.full, slab: s.scene.slab))
            }
        }
        for f in [2.0, 4] {
            guard let b = scene(feet: f, ball: true), let c = BallImageCrop.plan(slab: b.scene.slab, full: b.full),
                  let p = b.lumaCrop(.rows, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor) else { continue }
            timeStage("recording", "ball crop -> exact PGM (Plane.pgmData(blockSum:))", input: "\(b.name): \(fmtSize(p)) factor \(c.factor)", .fast,
                 note: "session recorder queue, every ball frame") {
                let k = [c.factor, 1, 2, 3, 4].first { p.isBlockAverage(of: $0) } ?? 16
                blackHole(p.pgmData(blockSum: k))
            }
        }
    }
}
