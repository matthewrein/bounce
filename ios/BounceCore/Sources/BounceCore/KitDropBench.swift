import Foundation

/// One rendered drop scored: its truth, what the scorer's path measured, and the analysis of a perfect track.
public struct KitDropBenchResult: Codable, Equatable {
    public var shot: KitDropShot
    public var truth: KitDropTruth
    /// frames of the shot, and those from the release cue on
    public var frames: Int
    public var dropFrames: Int
    /// frames from the cue on on which the tracking finder found the ball
    public var ballFound: Int
    /// the slab was locked before the cue (the analysis's dish needs the lock)
    public var lockedBeforeCue: Bool
    /// the camera's distance from the slab's centre at the cue (m)
    public var cameraDistance: Double?
    /// the shrink factors of the app's crop the tracking finder searched (`BallImageCrop.factor`) from the cue on, and
    /// the true ball's radius in that image (pixels, `Bounce.imageRadius`): median over those frames, and its least
    public var ballCropFactors: [Int]?
    public var ballImageRadius: Double?
    public var ballImageRadiusMin: Double?
    /// the lock's normal's angle from the true one (degrees) and its centre's distance from the true one (m)
    public var lockNormalError: Double?
    public var lockCenterError: Double?
    /// the tracking finder's track (the ball's centre, world) and its distance from the true centre on each frame:
    /// median, 90th percentile, and the share over 2 cm
    public var track: [KitBallSample] = []
    public var trackErrorMedian: Double?
    public var trackErrorP90: Double?
    public var trackWrongShare: Double?
    public var measured: KitDropAnalysis?
    /// the truth compared at the measured analysis's own landing level (`KitDropAnalysis.landingLevel`: the slab contact,
    /// the floor, or the lowest top corner), which its landing and comparisons are scored against
    public var measuredTruth: KitDropLevelTruth?
    /// the measured contact point in the TRUE slab's axes (m: the lock's own axes may be any of a square slab's four
    /// edge directions)
    public var measuredOffset: [Double]?
    public var failure: String?
    /// the analysis of a perfect track (the ball's true centre on every frame) with the true slab: the analysis's own
    /// error, without the finder's or the lock's
    public var perfect: KitDropAnalysis?
    public var perfectFailure: String?
    public var perfectTruth: KitDropLevelTruth?
}

/// The drop bench's report (`bounce-score --drops`).
public struct KitDropBenchReport: Codable, Equatable {
    public var format = "bouncekit-drops"
    public var version = 1
    /// the slab and dish the drops were rendered with
    public var slabInches: [Double]
    public var dish: KitDish
    /// the bounce's tangential model, the video size, rate and exposure
    public var tangential: String
    public var video: String
    /// "app" (the app's ball finder set up for tracking) or "truth" (a finder that knows where the ball is)
    public var finder: String
    /// ARKit's floor was given to the analysis (as on the phone); false: as in a kit, which has none
    public var floorKnown = false
    public var results: [KitDropBenchResult]
    public var notes: [String] = []

    /// Medians over the drops of the measured minus the true numbers (see `markdown`).
    public struct Summary: Codable, Equatable {
        public var drops: Int
        public var analysed: Int
        public var reboundError: Double?
        public var reboundErrorMax: Double?
        public var offsetError: Double?
        public var normalTiltError: Double?
        public var dropHeightError: Double?
        public var impactTimeError: Double?
        public var landingError: Double?
        /// |measured - true| landing error against the app's prediction (app rebound / true rebound)
        public var appComparisonError: Double?
        public var reboundComparisonError: Double?
        public var directionError: Double?
        /// the measured minus the true rebound over its sigma (|z|): median, and the drops beyond 3; the same for the drop
        /// height and the landing against the app (app's rebound)
        public var reboundZ: Double?
        public var reboundBeyond3Sigma: Int
        public var dropHeightBeyond3Sigma: Int
        public var appComparisonBeyond3Sigma: Int
        /// the same for the perfect tracks
        public var perfectReboundError: Double?
        public var perfectOffsetError: Double?
        public var perfectLandingError: Double?
    }

    public var summary: Summary {
        let ok = results.filter { $0.measured?.kind == .bounce }
        func med(_ v: [Double]) -> Double? { v.isEmpty ? nil : KitStats.median(v) }
        func offErr(_ a: KitDropAnalysis, _ t: KitDropTruth) -> Double? { a.contactPoint.distance(to: t.contactPoint) }
        func landErr(_ a: KitDropAnalysis, _ t: KitDropLevelTruth?) -> Double? {
            guard let l = a.landing, let t = t else { return nil }
            return (l - t.landing).rejecting(Vec3(0, 1, 0)).length
        }
        func z(_ e: Double, _ s: Double?) -> Double { abs(e) / max(1e-9, s ?? 0) }
        let rb = ok.compactMap { r in r.measured?.rebound.map { abs($0 - r.truth.rebound) } }
        let rz = ok.compactMap { r in r.measured.flatMap { a in a.rebound.map { z($0 - r.truth.rebound, a.reboundSigma) } } }
        let dz = ok.map { r in z(r.measured!.dropHeight - r.truth.dropHeight, r.measured!.dropHeightSigma) }
        let az = ok.compactMap { r -> Double? in
            guard let m = r.measured?.app, let t = r.measuredTruth?.app else { return nil }
            return z(m.landingError - t.landingError, m.landingErrorSigma)
        }
        let perf = results.filter { $0.perfect?.kind == .bounce }
        return Summary(drops: results.count, analysed: ok.count, reboundError: med(rb), reboundErrorMax: rb.max(),
                       offsetError: med(ok.compactMap { offErr($0.measured!, $0.truth) }),
                       normalTiltError: med(ok.compactMap { r in r.measured?.normalTilt.map { abs($0 - r.truth.normalTilt) } }),
                       dropHeightError: med(ok.map { abs($0.measured!.dropHeight - $0.truth.dropHeight) }),
                       impactTimeError: med(ok.map { abs($0.measured!.impactTime - $0.truth.impactTime) }),
                       landingError: med(ok.compactMap { landErr($0.measured!, $0.measuredTruth) }),
                       appComparisonError: med(ok.compactMap { r in
                           guard let m = r.measured?.app?.landingError, let t = r.measuredTruth?.app?.landingError else { return nil }
                           return abs(m - t) }),
                       reboundComparisonError: med(ok.compactMap { r in
                           guard let m = r.measured?.measuredRebound?.landingError, let t = r.measuredTruth?.trueRebound?.landingError else { return nil }
                           return abs(m - t) }),
                       directionError: med(ok.compactMap { r in
                           guard let o = r.measured?.velocityOut else { return nil }
                           return Units.degrees(o.angle(to: r.truth.velocityOut)) }),
                       reboundZ: med(rz), reboundBeyond3Sigma: rz.filter { $0 > 3 }.count, dropHeightBeyond3Sigma: dz.filter { $0 > 3 }.count,
                       appComparisonBeyond3Sigma: az.filter { $0 > 3 }.count,
                       perfectReboundError: med(perf.compactMap { r in r.perfect?.rebound.map { abs($0 - r.truth.rebound) } }),
                       perfectOffsetError: med(perf.compactMap { offErr($0.perfect!, $0.truth) }),
                       perfectLandingError: med(perf.compactMap { landErr($0.perfect!, $0.perfectTruth) }))
    }

    public func json() throws -> Data { try KitJSON.encode(self) }

    /// The report as Markdown: what was rendered, the summary, a table per drop (truth against measured) and the
    /// analysis's own table (the same as a kit's, `KitDropAnalysis.markdownTable`).
    public func markdown() -> String {
        var md: [String] = ["## Rendered drops (known truth)", ""]
        let sm = summary
        md.append(String(format: "%d drops onto a %.0f x %.0f in slab, %.3f in dish (%@, sphere radius %.0f in), %@; %@; ball finder: %@.",
                         results.count, slabInches[0], slabInches[1], Units.toInches(dish.depth),
                         dish.shape == .sphericalCap ? "spherical cap" : "paraboloid", Units.toInches(dish.sphereRadius),
                         tangential, video, finder == "truth" ? "truth-based (knows where the ball is)" : "the app's, set up for tracking"))
        md.append(floorKnown ? "The analysis knows ARKit's floor (as on the phone)." :
                  "The analysis has no floor, as in a kit: it lands the bounce where the ball came down on the slab again, on the floor when "
                  + "it is seen lower, else at the lock's lowest top corner (the app's own end level); each is scored against the truth there.")
        for n in notes { md.append("- " + KitScoreReport.cell(n)) }
        md.append("")
        func mm(_ v: Double?) -> String { v.map { String(format: "%.1f mm", $0 * 1000) } ?? "n/a" }
        func pts(_ v: Double?) -> String { v.map { String(format: "%.1f points", $0 * 100) } ?? "n/a" }
        func deg(_ v: Double?) -> String { v.map { String(format: "%.2f°", $0) } ?? "n/a" }
        md.append("| Measured minus true (median over drops) | Scorer's track | Perfect track |")
        md.append("|---|---|---|")
        md.append("| Drops analysed | \(sm.analysed) of \(sm.drops) | \(results.filter { $0.perfect?.kind == .bounce }.count) of \(sm.drops) |")
        md.append("| Rebound | \(pts(sm.reboundError)) (worst \(pts(sm.reboundErrorMax))) | \(pts(sm.perfectReboundError)) |")
        md.append("| Rebound error over its sigma | median \(sm.reboundZ.map { String(format: "%.1f", $0) } ?? "n/a"), beyond 3 sigma: "
                  + "\(sm.reboundBeyond3Sigma) of \(sm.analysed) | |")
        md.append("| Beyond 3 sigma: drop height, landing against the app | \(sm.dropHeightBeyond3Sigma), \(sm.appComparisonBeyond3Sigma) of \(sm.analysed) | |")
        md.append("| Contact point on the dish | \(mm(sm.offsetError)) | \(mm(sm.perfectOffsetError)) |")
        md.append("| Local normal's tilt | \(deg(sm.normalTiltError)) | |")
        md.append("| Drop height | \(mm(sm.dropHeightError)) | |")
        md.append("| Impact time | \(sm.impactTimeError.map { String(format: "%.1f ms", $0 * 1000) } ?? "n/a") | |")
        md.append("| Launch direction | \(deg(sm.directionError)) | |")
        md.append("| Landing point | \(mm(sm.landingError)) | \(mm(sm.perfectLandingError)) |")
        md.append("| Landing error against the app (app's rebound) | \(mm(sm.appComparisonError)) | |")
        md.append("| Landing error against the app (measured rebound) | \(mm(sm.reboundComparisonError)) | |")
        md.append("")
        // the rebound to bake, per true rebound (a real kit has one ball and one slab)
        let groups = Dictionary(grouping: results.filter { $0.measured != nil }, by: { $0.truth.rebound }).sorted { $0.key < $1.key }
        for (r, g) in groups {
            md.append(String(format: "- true rebound %.0f%%: ", r * 100) + KitDropAnalysis.bakeLine(g.compactMap { $0.measured }))
        }
        md.append("")
        md.append("| Drop | Tilt | Height | Camera to slab, crop shrink, ball radius (finder px) | Contact u, v (in, the true slab's axes) true / measured | "
                  + "Local tilt true / measured | Rebound true / measured | Impact centre (fits) | Landing | vs app: true / measured | "
                  + "vs true or measured rebound: true / measured | Found |")
        md.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in results {
            let t = r.truth
            let found = "\(r.ballFound)/\(r.dropFrames)"
            var cam = r.cameraDistance.map { String(format: "%.2f m", $0) } ?? "-"
            if let k = r.ballCropFactors { cam += ", /" + k.map(String.init).joined(separator: "-") }
            if let b = r.ballImageRadius { cam += String(format: ", %.0f px", b) + (r.ballImageRadiusMin.map { String(format: " (least %.0f)", $0) } ?? "") }
            guard let a = r.measured else {
                md.append("| \(r.shot.id) | \(String(format: "%.0f°", r.shot.tilt)) | \(String(format: "%.0f in", r.shot.heightInches)) | \(cam) | "
                          + String(format: "%.1f, %.1f / - | %.2f° / - | %.0f%% / - | | | | | ", Units.toInches(t.offsetU), Units.toInches(t.offsetV),
                                   t.normalTilt, t.rebound * 100) + "\(found) |")
                continue
            }
            let off = r.measuredOffset.map { String(format: "%.1f, %.1f", Units.toInches($0[0]), Units.toInches($0[1])) } ?? "-"
            let tilt = a.normalTilt.map { String(format: "%.2f°", $0) } ?? "-"
            let reb = a.rebound.map { String(format: "%.1f%% ± %.1f", $0 * 100, (a.reboundSigma ?? 0) * 100) } ?? a.kind.rawValue
            let imp = String(format: "%.1f mm", (a.impactCenter - t.impactCenter).length * 1000)
            let land = a.landing.flatMap { l in r.measuredTruth.map { String(format: "%.0f mm", (l - $0.landing).rejecting(Vec3(0, 1, 0)).length * 1000) } } ?? "-"
            func cmp(_ x: KitDropComparison?) -> String {
                guard let x = x else { return "-" }
                return String(format: "%.0f mm", x.landingError * 1000) + (x.bearingError.map { String(format: " %+.0f°", $0) } ?? "")
            }
            md.append("| \(r.shot.id) | \(String(format: "%.0f°", r.shot.tilt)) | \(String(format: "%.0f in", r.shot.heightInches)) | \(cam) | "
                      + String(format: "%.1f, %.1f / ", Units.toInches(t.offsetU), Units.toInches(t.offsetV)) + off + " | "
                      + String(format: "%.2f° / ", t.normalTilt) + tilt + " | " + String(format: "%.0f%% / ", t.rebound * 100) + reb + " | "
                      + imp + " | " + land + " | " + cmp(r.measuredTruth?.app) + " / " + cmp(a.app) + " | " + cmp(r.measuredTruth?.trueRebound)
                      + " / " + cmp(a.measuredRebound)
                      + " | " + found + " |")
        }
        let failed = results.filter { $0.measured == nil }
        if !failed.isEmpty {
            md.append("")
            md.append("Not analysed:")
            md.append("")
            for r in failed { md.append("- \(r.shot.id): " + KitScoreReport.cell(r.failure ?? "?")) }
        }
        let analysed = results.compactMap { r in r.measured.map { (r.shot.id, $0) } }
        if !analysed.isEmpty {
            md.append("")
            md.append("As a kit's report shows them:")
            md.append("")
            md.append(KitDropAnalysis.markdownTable(analysed))
        }
        return md.joined(separator: "\n")
    }
}

/// Scores rendered drops (`KitSyntheticDrops`) through the scorer's own per-frame path (`KitScoreRun.runShot`: the
/// app's frame pipeline, a fresh tracker, the tracking ball finder on every frame) and analyses each track with
/// `KitDropAnalysis` (the lock before the cue, the dish; no floor, as in a kit, unless `floorKnown`), against the truth
/// at the analysis's own landing level.
public enum KitDropBench {
    public struct Options {
        public var drops = KitSyntheticDrops.Options()
        /// a ball finder that knows where the ball is (tests the analysis without the finder's errors)
        public var truthBall = false
        /// give the analysis ARKit's floor (y = 0), as on the phone; false (the default): as a kit has it, no floor
        public var floorKnown = false
        public var log: ((String) -> Void)? = nil
        public init() {}
    }

    public static func run(_ o: Options) throws -> KitDropBenchReport {
        let maker = KitSyntheticDrops(options: o.drops)
        var results: [KitDropBenchResult] = []
        var start = 1000.0
        for shot in o.drops.shots {
            let d = maker.make(shot, start: start)
            start += 20
            let r = try score(d, maker: maker, truthBall: o.truthBall, floorKnown: o.floorKnown)
            let what = r.measured.map { a in a.rebound.map { String(format: "rebound %.1f%% (true %.0f%%)", $0 * 100, r.truth.rebound * 100) } ?? a.kind.rawValue }
                ?? "not analysed"
            o.log?("drops \(shot.id): \(r.frames) frames, ball on \(r.ballFound)/\(r.dropFrames) drop frames, \(what)")
            results.append(r)
        }
        let dop = o.drops
        let tang: String
        switch dop.tangential {
        case let .rolling(mu): tang = String(format: "the ball rolls off (solid sphere, friction %.2f)", mu)
        case .smooth: tang = "no friction (tangential velocity kept)"
        case let .ratio(k): tang = String(format: "%.2f of the tangential velocity kept", k)
        }
        let W = dop.width / max(1, dop.shrink), H = dop.height / max(1, dop.shrink)
        let video = String(format: "%dx%d at %.0f fps, exposure %@", W, H, dop.fps,
                           dop.exposure > 0 ? String(format: "1/%.0f s (%d instants)", 1 / dop.exposure, dop.blurSamples) : "none")
        var rep = KitDropBenchReport(slabInches: [Units.toInches(dop.spec.sideU), Units.toInches(dop.spec.sideV)], dish: maker.dish,
                                     tangential: tang, video: video, finder: o.truthBall ? "truth" : "app", results: results)
        rep.floorKnown = o.floorKnown
        rep.notes.append("The app predicts with its own model (launch along the corner plane's normal, |v_out| = sqrt(rebound) |v_in|, its "
                         + "paraboloid dish); the drops follow the physics (reflection about the dish's local normal, the ball rolling off): "
                         + "'vs app' with the true rebound is the model's own error.")
        return rep
    }

    /// One drop through the scorer's path, analysed, and its perfect track analysed.
    static func score(_ d: KitSyntheticDrops.Drop, maker: KitSyntheticDrops, truthBall: Bool, floorKnown: Bool = false) throws -> KitDropBenchResult {
        let settings = maker.settings
        let spec = KitPlan.standard.shots.first { $0.id == "s10-drop1" }!
        let W = maker.options.width / max(1, maker.options.shrink), H = maker.options.height / max(1, maker.options.shrink)
        let fmt = KitCameraFormat(width: 1920, height: Int((1920 * Double(maker.options.height) / Double(maker.options.width)).rounded()), fps: 60)
        let device = KitDevice(modelIdentifier: "synthetic", systemVersion: "0", hasLiDAR: false, cameraFormat: fmt, highFrameRateFormat: fmt)
        let sp = maker.options.spec
        let meas = KitMeasurements(slabWidthInches: Units.toInches(sp.sideU), slabDepthInches: Units.toInches(sp.sideV),
                                   slabThicknessInches: Units.toInches(sp.thickness), dishInches: Units.toInches(sp.dishDepth),
                                   ballDiameterMm: maker.options.ballDiameter * 1000)
        var m = KitShotManifest(kitId: "drops", shotId: spec.id, step: spec.step, attempt: 1, startedAt: KitTime.iso(KitSyntheticKit.date),
                                startTime: d.start, duration: (d.frames.last?.time ?? d.start) - d.start + 0.1, build: "synthetic", device: device,
                                measurements: meas, measurementsEntered: true, cameraFormat: fmt, releaseCue: 2, releaseTime: d.truth.cue)
        m.video = KitVideoInfo(codec: "memory", width: W, height: H, fps: maker.options.fps, bitrate: 0, frameCount: d.frames.count, fileBytes: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bounce-drops-unused")
        let shot = KitScoreRun.Shot(spec: spec, record: KitShotRecord(id: spec.id, step: spec.step, status: .captured), folder: folder,
                                    manifest: m, frames: d.frames, planIndex: 0)
        var so = KitScorer.Options()
        so.source = "synthetic"
        let images = maker.render(d)
        so.frames = { _ in KitArrayFrameSource(width: W, height: H, frames: images) }
        if truthBall {
            let tr = KitSyntheticKit.ShotTruth(shotId: spec.id, kind: .drop, slab: d.slab, tiltDegrees: d.shot.tilt,
                                               times: d.frames.map { $0.time }, views: d.views,
                                               balls: d.frames.map { Optional(d.physics.position(at: $0.time)) })
            so.makeBallLocator = { KitTruthBallLocator(truth: [spec.id: tr]) }
        }
        let run = KitScoreRun(folder: folder, options: so)
        run.settings = settings
        let sr = try run.runShot(shot, cue: d.truth.cue)
        let cue = d.truth.cue
        var res = KitDropBenchResult(shot: d.shot, truth: d.truth, frames: d.frames.count, dropFrames: d.frames.filter { $0.time >= cue }.count,
                                     ballFound: sr.track.filter { $0.t >= cue }.count, lockedBeforeCue: sr.lockBeforeCue != nil)
        res.track = sr.track
        if let i = d.frames.firstIndex(where: { $0.time >= cue }) { res.cameraDistance = d.views[i].position.distance(to: d.slab.center) }
        let searched = sr.ballImages.filter { $0.t >= cue }
        if !searched.isEmpty {
            res.ballCropFactors = Array(Set(searched.map { $0.crop.factor })).sorted()
            let radii = searched.compactMap { im in
                Bounce.imageRadius(ballCenter: im.view.toCamera(d.physics.position(at: im.t)), intrinsics: im.intrinsics, ball: settings.ball)
            }
            if !radii.isEmpty { res.ballImageRadius = KitStats.median(radii); res.ballImageRadiusMin = radii.min() }
        }
        let errs = sr.track.map { $0.p.distance(to: d.physics.position(at: $0.t)) }
        if !errs.isEmpty {
            res.trackErrorMedian = KitStats.median(errs)
            res.trackErrorP90 = KitStats.percentile(errs, 90)
            res.trackWrongShare = Double(errs.filter { $0 > 0.02 }.count) / Double(errs.count)
        }
        if let l = sr.lockBeforeCue {
            res.lockNormalError = Units.degrees(l.normal.angle(to: d.slab.normal))
            res.lockCenterError = l.center.distance(to: d.slab.center)
        }
        var ctx = KitDropAnalysis.Context(slab: sr.lockBeforeCue, dish: maker.dish)
        ctx.ballRadius = settings.ball.radius
        ctx.floorY = floorKnown ? 0 : nil
        ctx.appRebound = settings.ball.rebound
        if let lock = sr.lockBeforeCue {
            ctx.predict = { held, rebound in
                var s = settings
                s.ball.rebound = rebound
                return KitBouncePrediction.app(pose: lock, settings: s, held: held)
            }
        }
        switch KitDropAnalysis.analyze(track: sr.track, cue: cue, context: ctx) {
        case let .analyzed(a):
            res.measured = a
            res.measuredTruth = maker.truth(d, level: a.landingLevel)
            let q = d.slab.toSlab(a.contactPoint)
            res.measuredOffset = [q.x, q.y]
        case let .failed(why): res.failure = why
        }
        // the perfect track, with the true slab
        var pctx = ctx
        pctx.slab = d.slab
        pctx.predict = { held, rebound in
            var s = settings
            s.ball.rebound = rebound
            return KitBouncePrediction.app(pose: d.slab, settings: s, held: held)
        }
        switch KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: cue, context: pctx) {
        case let .analyzed(a): res.perfect = a; res.perfectTruth = maker.truth(d, level: a.landingLevel)
        case let .failed(why): res.perfectFailure = why
        }
        return res
    }
}
