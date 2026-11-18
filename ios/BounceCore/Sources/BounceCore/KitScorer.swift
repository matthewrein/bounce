import Foundation

/// A ball finder that wants to know which frame comes next (a truth-based finder for synthetic kits and tests; the
/// app's finders do not need this). The scorer tells it before every frame it may be handed.
public protocol KitFrameAware: AnyObject {
    func prepare(shotId: String, frameIndex: Int, time: Double, view: CameraView)
}

/// Errors scoring a kit. Messages carry kit, shot and file names, never folders.
public enum KitScoreError: Error, Equatable, CustomStringConvertible {
    /// the folder holds no readable kit.json
    case notAKit
    /// kit.json names a plan this build does not know
    case unknownPlan(String)
    /// a file of a shot is missing or unreadable
    case unreadable(String)
    /// the video ended before frames.jsonl did
    case videoEnded(at: Int, of: Int)
    /// this platform cannot decode video (iOS): pass frames in
    case noDecoder

    public var description: String {
        switch self {
        case .notAKit: return "not a kit: no readable kit.json"
        case let .unknownPlan(p): return "kit.json names an unknown plan (\(p))"
        case let .unreadable(f): return "\(f) is missing or unreadable"
        case let .videoEnded(i, n): return "the video ended after \(i) frames but frames.jsonl has \(n) lines"
        case .noDecoder: return "this platform cannot decode the kit's video"
        }
    }
}

/// Scores a capture kit against its ground truth (CaptureKit.md, "Scoring"): every video shot is run through the app's
/// per-frame path (`KitFramePipeline`) and a fresh `SlabTracker` with the app's detectors (`AppDetectors`) and the
/// app's own settings (`RecordingSettings()`: the slab, ball and tuning baked into the app; `Options.useMeasurements`
/// scores with the kit's measured slab and ball instead, when the owner entered them). The kit is only read.
///
/// Definitions (frames are a shot's video frames, in order; t0 is its first frame's time):
///   - **lockRate** (slab shots: the slab is expected in view): the share of frames with t - t0 >= 1 s on which the
///     tracker is locked. **timeToLock**: the first locked frame's t - t0 (n/a: never locked).
///   - **tiltError** (shots of a slab position with a usable true tilt, `manifest.position(forShot:)?.groundTruth`): on
///     every locked frame, the tracker's tilt (`Readouts.tiltDegrees`) minus the flat-phone true tilt's size; per shot
///     and per position (frames pooled) the median and 90th percentile of its absolute value, and the median of the
///     signed error (`tiltBias`).
///   - **normalError**: the angle between the tracker's normal (world) and the true normal: the flat-phone shot's slab
///     normal in CoreMotion's frame (`KitTrueTilt.slabNormalInMotionFrame`) carried into ARKit's world by a
///     `KitMotionLink` estimated from a video shot with the flat-phone shot's `motionSessionId` and the scored shot's
///     `arSessionId`, the nearest in time to its reading A. Median and 90th percentile over locked frames (n/a when no
///     link can be made: the reason says why).
///   - **cornerRms** (slab shots): the lock's four world corners on every locked frame, matched to the first locked
///     frame's corners; the RMS distance from each corner's per-axis median (mm).
///   - **slabSizeError** (slab shots, only when the measurements were entered): on every locked frame with a detection,
///     its outline's corners cast onto the lock's plane; the mean of the long and short side minus the measured long and
///     short side (mm), median over frames. With the slab's size assumed known, the pose's distance scales with it, so
///     this measures how well the detected outline fits the measured shape (and, with LiDAR fused, its size).
///   - **slabFoundRate / slabLockedRate** (shots where the slab must not be in view: ball-only shots, `s12-no-slab`):
///     the share of frames on which the tracker was confirming or locked / locked.
///   - **ballDetectionRate** (shots expecting the ball): of the frames on which the app's ball finder ran (only while
///     locked, every `ballInterval`), the share that found a ball. **ballFalsePositiveRate** (shots where the ball must
///     not be in view): the same share where there is no ball. n/a without a ball finder (`AppDetectors.ball()` is nil)
///     or when the slab never locked (the app looks for the ball only on a lock).
///   - **ballDistanceError** (the ball resting in the dish, `s08`): the ball's distance from the camera from its size
///     (the ball finder's centre) minus the distance along the same ray to where its centre must be, the ball's radius
///     above the dish's bottom (the lock's plane less the dish depth); median over frames (mm).
///   - **dropHeightError** (held ball with an entered height, `s09`): the app's drop height (the ball's bottom above
///     the dish where it would land, `Readouts.dropHeight` while it comes from the ball), median over frames, minus the
///     entered height (mm). The owner measures to the slab's top: up to the dish's depth of it can be how it was measured.
///   - **bounce** (drops, `s10`/`s11`): the ball finder is also run on every frame (a separate instance, on the app's
///     crop around the lock), the release is looked for after `releaseTime` (else `startTime + releaseCue`), and the
///     track is analysed as `KitBounceAnalysis` describes: `landingError`, `landingDistanceError`, `apexError`,
///     `impactPointError` against the app's prediction (`Bounce.compute` with the lock before the release and the held
///     ball) and the `rebound` measured from the bounce.
/// Aggregates: lockRate is the mean over slab shots, timeToLock the median over shots that locked, neverLocked a count;
/// tilt and normal errors pool every frame; cornerRms, slabSizeError, landing, apex and impact errors are medians over
/// shots (signed errors as medians of their absolute values); the false-positive and detection rates pool frames.
/// Anything that cannot be measured is n/a with the reason.
public struct KitScorer {
    /// What the frame source is given.
    public struct ShotInput {
        public var shotId: String
        public var folder: URL
        public var manifest: KitShotManifest
        public var frames: [KitFrame]
    }
    public typealias FrameProvider = (ShotInput) throws -> KitFrameSource

    public struct Options {
        /// score with the kit's measured slab and ball (when the owner entered them) instead of the app's settings
        public var useMeasurements = false
        public var makeDetector: () -> SlabDetecting = { AppDetectors.slab() }
        public var makeBallLocator: () -> BallLocating? = { AppDetectors.ball() }
        /// where the video frames come from; nil: the kit's video.mp4 through ffmpeg (macOS and Linux)
        public var frames: FrameProvider? = nil
        /// "kit", or "synthetic" for the synthetic kit
        public var source = "kit"
        /// progress lines (kit and shot ids and numbers only)
        public var log: ((String) -> Void)? = nil
        public init() {}
    }

    public let kitFolder: URL
    public var options: Options

    public init(kitFolder: URL, options: Options = Options()) { self.kitFolder = kitFolder; self.options = options }

    /// The kit's video.mp4 through ffmpeg (macOS and Linux).
    public static func videoFrames(_ s: ShotInput) throws -> KitFrameSource {
        #if os(macOS) || os(Linux)
        let url = s.folder.appendingPathComponent(KitClipFiles.video)
        guard FileManager.default.fileExists(atPath: url.path) else { throw KitScoreError.unreadable(KitClipFiles.video) }
        return try KitVideoDecoder(url: url, expectedFrames: s.frames.count)
        #else
        throw KitScoreError.noDecoder
        #endif
    }

    /// Scores every video shot of the kit.
    public func score() throws -> KitScoreReport {
        try KitScoreRun(folder: kitFolder, options: options).run()
    }

    /// An error's description for the report or a log, without paths.
    public static func describe(_ e: Error) -> String {
        switch e {
        case let x as KitScoreError: return x.description
        case let x as KitFormatError: return x.description
        case let x as KitStoreError: return x.description
        default:
            #if os(macOS) || os(Linux)
            if let x = e as? KitVideoError { return x.description }
            #endif
            if e is DecodingError { return "a file could not be decoded" }
            let n = e as NSError
            return "error \(n.code) (\(n.domain))"
        }
    }
}

/// One scoring run over a kit.
final class KitScoreRun {
    struct Shot {
        var spec: KitShotSpec
        var record: KitShotRecord
        var folder: URL
        var manifest: KitShotManifest?
        var frames: [KitFrame] = []
        var motion: [KitMotionSample]? = nil
        var loadError: String? = nil
        var planIndex: Int
    }

    /// The tracker's result on one frame, as the metrics need it.
    struct FrameResult {
        var t: Double
        var state: TrackerState
        var tilt: Double? = nil
        var normal: Vec3? = nil
        var corners: [Vec3]? = nil
        /// the frame's detected outline cast onto the lock's plane: long and short side (m)
        var sides: (long: Double, short: Double)? = nil
        var ballSearched = false
        var ballFound = false
        var ballDistanceError: Double? = nil
        var dropHeight: Double? = nil
    }

    struct ShotRun {
        var results: [FrameResult] = []
        var track: [KitBallSample] = []
        var lockBeforeCue: SlabPose? = nil
        var unusableFrames = 0
        var depthErrors = 0
    }

    let folder: URL
    let options: KitScorer.Options
    var manifest: KitManifest!
    var plan: KitPlan!
    var settings = TrackerSettings()
    var shots: [Shot] = []
    var links: [String: KitMotionLink.Estimate] = [:]
    var hasBallLocator = false
    var notes: [String] = []
    /// pooled values for the aggregates
    var tiltErrors: [Double] = [], normalErrors: [Double] = []

    init(folder: URL, options: KitScorer.Options) { self.folder = folder; self.options = options }

    func log(_ s: String) { options.log?(s) }

    /// The kit's id in the report: "synthetic" for the synthetic kit (its folder's id is a fixed date)
    var kitId: String { options.source == "synthetic" ? "synthetic" : manifest.kitId }

    func run() throws -> KitScoreReport {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(KitStore.manifestFile)),
              let m = try? KitJSON.decode(KitManifest.self, from: data), m.format == KitManifest.formatName else { throw KitScoreError.notAKit }
        manifest = m
        guard let p = KitPlan.named(m.planId, timeScale: m.timeScale ?? 1) else { throw KitScoreError.unknownPlan(m.planId) }
        plan = p
        // settings: the app's own, or the kit's measurements
        var setting = "app"
        settings = RecordingSettings().trackerSettings
        if options.useMeasurements {
            if m.measurementsEntered {
                settings = m.measurements.recordingSettings(base: RecordingSettings()).trackerSettings
                setting = "measured"
            } else {
                notes.append("The measurements were not entered (kit.json measurementsEnteredAt is null): scored with the app's settings.")
            }
        }
        let s = settings.spec
        notes.append(String(format: "Slab %.2f x %.2f in, %.2f in thick, %.3f in dish; ball %.1f mm; rebound %.0f%%.",
                            Units.toInches(s.sideU), Units.toInches(s.sideV), Units.toInches(s.thickness), Units.toInches(s.dishDepth),
                            settings.ball.diameter * 1000, settings.ball.rebound * 100))
        hasBallLocator = options.makeBallLocator() != nil
        if !hasBallLocator { notes.append("No ball finder in this build (AppDetectors.ball() is nil): the ball and bounce metrics are n/a.") }
        loadShots()

        var scores: [KitShotScore] = []
        var perShotFrames: [String: [FrameResult]] = [:]
        var perShotNormals: [String: [Double]] = [:], perShotTilts: [String: [Double]] = [:]
        for sh in shots where sh.spec.isVideo {
            let (score, results, tilts, normals) = scoreShot(sh)
            scores.append(score)
            perShotFrames[sh.spec.id] = results
            perShotTilts[sh.spec.id] = tilts
            perShotNormals[sh.spec.id] = normals
        }
        let positions = scorePositions(scores, tilts: perShotTilts, normals: perShotNormals)
        let aggregates = aggregate(scores, frames: perShotFrames)
        return KitScoreReport(kitId: kitId, planId: m.planId, build: m.build, deviceModel: m.device.modelIdentifier,
                              systemVersion: m.device.systemVersion, hasLiDAR: m.device.hasLiDAR, source: options.source,
                              settings: setting, measurementsEntered: m.measurementsEntered, shots: scores, positions: positions,
                              aggregates: aggregates, notes: notes)
    }

    // MARK: loading

    func loadShots() {
        for (i, spec) in plan.shots.enumerated() {
            guard let r = manifest.record(spec.id), r.status == .captured, !spec.isForm else { continue }
            let f = folder.appendingPathComponent(r.folder ?? (KitStore.shotsFolder + "/" + spec.id))
            var sh = Shot(spec: spec, record: r, folder: f, planIndex: i)
            do {
                let d = try Data(contentsOf: f.appendingPathComponent(KitClipFiles.shotManifest))
                sh.manifest = try KitJSON.decode(KitShotManifest.self, from: d)
            } catch { sh.loadError = KitScoreError.unreadable(KitClipFiles.shotManifest).description }
            if sh.loadError == nil && spec.isVideo {
                do { sh.frames = try KitJSONL.read(KitFrame.self, from: f.appendingPathComponent(KitClipFiles.frames)) }
                catch { sh.loadError = KitScoreError.unreadable(KitClipFiles.frames).description + ": " + KitScorer.describe(error) }
            }
            let mu = f.appendingPathComponent(KitClipFiles.motion)
            if FileManager.default.fileExists(atPath: mu.path) { sh.motion = try? KitJSONL.read(KitMotionSample.self, from: mu) }
            shots.append(sh)
        }
    }

    func shot(_ id: String) -> Shot? { shots.first { $0.spec.id == id } }

    /// The release cue of a drop (uptime s).
    func cue(_ sh: Shot) -> Double? {
        guard let m = sh.manifest else { return nil }
        if let r = m.releaseTime { return r }
        guard let st = m.startTime, let c = m.releaseCue ?? sh.spec.kind.releaseCue else { return nil }
        return st + c
    }

    // MARK: running a shot

    func runShot(_ sh: Shot, cue: Double?) throws -> ShotRun {
        guard let m = sh.manifest else { throw KitScoreError.unreadable(KitClipFiles.shotManifest) }
        let input = KitScorer.ShotInput(shotId: sh.spec.id, folder: sh.folder, manifest: m, frames: sh.frames)
        let source = try (options.frames ?? KitScorer.videoFrames)(input)
        defer { source.close() }
        let pipeline = KitFramePipeline(videoWidth: source.width, videoHeight: source.height, cameraFormat: m.cameraFormat)
        let locator = options.makeBallLocator()
        let tracker = SlabTracker(settings: settings, detector: options.makeDetector(), ballLocator: locator)
        let isDrop = sh.spec.kind.highFrameRate && sh.spec.kind.releaseCue != nil
        let dense: BallLocating? = isDrop ? options.makeBallLocator() : nil
        dense?.reset()
        let isBallOnSlab = sh.spec.diagram == .ballOnSlab
        var run = ShotRun()
        var lastLock: SlabPose? = nil
        let down = ARKitConvention.worldDown
        for (i, f) in sh.frames.enumerated() {
            guard let img = try source.next() else { throw KitScoreError.videoEnded(at: i, of: sh.frames.count) }
            let depth: () -> (DepthMap, CameraIntrinsics)? = {
                guard let u = f.depthURL(shotFolder: sh.folder) else { return nil }
                guard let d = try? Data(contentsOf: u), let k = try? KitDepth(data: d) else { run.depthErrors += 1; return nil }
                guard let vk = f.cameraIntrinsics(videoWidth: pipeline.videoWidth, videoHeight: pipeline.videoHeight) else { return nil }
                return KitFramePipeline.depth(k, video: vk)
            }
            guard let pf = pipeline.frame(image: img, kitFrame: f, tracker: tracker, depth: depth) else { run.unusableFrames += 1; continue }
            (locator as? KitFrameAware)?.prepare(shotId: sh.spec.id, frameIndex: i, time: f.time, view: pf.video)
            let out = tracker.process(pf.tracker)
            var r = FrameResult(t: f.time, state: out.state)
            if out.state == .locked, let s = out.slab {
                lastLock = s
                if let c = cue, f.time < c { run.lockBeforeCue = s }
                r.tilt = out.readouts?.tiltDegrees
                r.normal = s.normal
                r.corners = s.topCorners
                if let q = out.measurement, q.count == 4 {
                    let plane = Plane3(point: s.center, normal: s.normal), v = pf.tracker.view
                    let P = q.compactMap { px -> Vec3? in let ray = v.ray(through: px); return plane.intersect(origin: ray.origin, direction: ray.direction) }
                    if P.count == 4 {
                        let side = (0..<4).map { P[$0].distance(to: P[($0 + 1) % 4]) }
                        let u = (side[0] + side[2]) / 2, w = (side[1] + side[3]) / 2
                        r.sides = (max(u, w), min(u, w))
                    }
                }
                if out.readouts?.dropFromBall == true { r.dropHeight = out.readouts?.dropHeight }
            }
            if out.ballSearched {
                r.ballSearched = true
                r.ballFound = out.ball != nil
                if isBallOnSlab, let b = out.ball, let s = out.slab {
                    r.ballDistanceError = KitScoreRun.ballDistanceError(ballWorld: b.center, slab: s, view: pf.tracker.view, settings: settings)
                }
            }
            run.results.append(r)
            // the drop's dense ball track: the ball finder on every frame, on the app's crop around the lock
            if let d = dense, let lock = out.slab ?? lastLock, let b = pipeline.ballImage(img, slab: lock, video: pf.video) {
                (d as? KitFrameAware)?.prepare(shotId: sh.spec.id, frameIndex: i, time: f.time, view: pf.video)
                let sc = lock.transformed(by: pf.video.cameraFromWorld)
                if let x = d.locate(image: b.image, intrinsics: b.intrinsics, slab: sc, spec: settings.spec, ball: settings.ball,
                                    down: pf.video.directionToCamera(down)), x.center.isFinite {
                    run.track.append(KitBallSample(t: f.time, p: pf.video.toWorld(x.center)))
                }
            }
        }
        #if os(macOS) || os(Linux)
        if let dec = source as? KitVideoDecoder { try dec.finish() }
        #endif
        return run
    }

    /// The ball's distance from the camera from its size minus the distance along the same ray to the place its centre
    /// must be when it rests in the dish: the ball's radius above the dish's bottom (m).
    static func ballDistanceError(ballWorld: Vec3, slab: SlabPose, view: CameraView, settings: TrackerSettings) -> Double? {
        let c = view.toCamera(ballWorld), dist = c.length
        guard dist > 1e-6 else { return nil }
        let p = slab.transformed(by: view.cameraFromWorld)
        let point = p.center + p.normal * (settings.ball.radius - settings.spec.dishDepth)
        let dir = c / dist, den = dir.dot(p.normal)
        guard abs(den) > 0.05 else { return nil }
        let t = point.dot(p.normal) / den
        guard t > 0 else { return nil }
        return dist - t
    }

    // MARK: scoring a shot

    func scoreShot(_ sh: Shot) -> (KitShotScore, [FrameResult], [Double], [Double]) {
        let posId = manifest.record(sh.spec.id)?.positionId
        let position = posId.flatMap { manifest.position($0) }
        let truth = position?.groundTruth.flatMap { $0.isUsable ? $0 : nil }
        var score = KitShotScore(shotId: sh.spec.id, step: sh.spec.step, positionId: posId, trueTiltDegrees: truth?.tiltDegrees)
        if let e = sh.loadError { score.error = e; log("\(kitId) \(sh.spec.id): not scored"); return (score, [], [], []) }
        guard !sh.frames.isEmpty else { score.error = "frames.jsonl has no frames"; return (score, [], [], []) }
        let c = cue(sh)
        let run: ShotRun
        do { run = try runShot(sh, cue: c) } catch {
            score.error = KitScorer.describe(error)
            log("\(kitId) \(sh.spec.id): not scored")
            return (score, [], [], [])
        }
        let res = run.results
        score.frames = res.count
        let t0 = sh.frames.first!.time
        score.seconds = (sh.frames.last!.time - t0)
        let expect = sh.spec.expect
        var metrics: [KitMetric] = []
        let locked = res.filter { $0.state == .locked }
        let firstLock = res.first { $0.state == .locked }
        let neverLocked = "the slab never locked"

        // lock
        if expect.slab == .required {
            let late = res.filter { $0.t - t0 >= 1 }
            if late.isEmpty { metrics.append(.na("lockRate", "the shot is shorter than 1 s")) }
            else { metrics.append(KitMetric(id: "lockRate", value: Double(late.filter { $0.state == .locked }.count) / Double(late.count), count: late.count)) }
            metrics.append(firstLock.map { KitMetric(id: "timeToLock", value: $0.t - t0) } ?? .na("timeToLock", neverLocked))
        }
        if expect.slab == .forbidden {
            let n = Double(max(1, res.count))
            metrics.append(KitMetric(id: "slabFoundRate", value: Double(res.filter { $0.state != .searching }.count) / n, count: res.count))
            metrics.append(KitMetric(id: "slabLockedRate", value: Double(locked.count) / n, count: res.count))
        }

        // tilt, against the flat-phone true tilt
        var tiltErr: [Double] = [], normalErr: [Double] = []
        if expect.slab != .forbidden {
            let reason: String?
            if posId == nil { reason = "the shot belongs to no slab position (taken before the first flat-phone shot)" }
            else if truth == nil { reason = "no true tilt for \(posId!) (its flat-phone shot was skipped or failed)" }
            else if locked.isEmpty { reason = neverLocked }
            else { reason = nil }
            if let r = reason {
                if expect.slab == .required || posId != nil {
                    for id in ["tiltErrorMedian", "tiltErrorP90", "tiltBias"] { metrics.append(.na(id, r)) }
                }
            } else if let tt = truth?.tiltDegrees {
                tiltErr = locked.compactMap { $0.tilt.map { $0 - tt } }
                let abs = tiltErr.map { Swift.abs($0) }
                metrics.append(KitMetric(id: "tiltErrorMedian", value: KitStats.median(abs), count: abs.count))
                metrics.append(KitMetric(id: "tiltErrorP90", value: KitStats.percentile(abs, 90), count: abs.count))
                metrics.append(KitMetric(id: "tiltBias", value: KitStats.median(tiltErr), count: abs.count))
            }
            // the normal's direction, through the CoreMotion-to-ARKit link
            if let p = position, truth != nil {
                let (n, why) = trueNormalWorld(position: p, for: sh)
                if let n = n, !locked.isEmpty {
                    normalErr = locked.compactMap { $0.normal.map { Units.degrees($0.angle(to: n)) } }
                    metrics.append(KitMetric(id: "normalErrorMedian", value: KitStats.median(normalErr), count: normalErr.count))
                    metrics.append(KitMetric(id: "normalErrorP90", value: KitStats.percentile(normalErr, 90), count: normalErr.count))
                } else {
                    let r = n == nil ? (why ?? "no link") : neverLocked
                    metrics.append(.na("normalErrorMedian", r)); metrics.append(.na("normalErrorP90", r))
                }
            }
        }

        // corners and size
        if expect.slab == .required {
            let cs = locked.compactMap { $0.corners }
            if cs.count >= 2 {
                metrics.append(KitMetric(id: "cornerRms", value: KitScoreRun.cornerRms(cs) * 1000, count: cs.count))
            } else {
                metrics.append(.na("cornerRms", cs.isEmpty ? neverLocked : "locked on only one frame"))
            }
            if !manifest.measurementsEntered {
                metrics.append(.na("slabSizeError", "the measurements were not entered (kit.json measurementsEnteredAt is null)"))
            } else {
                let me = manifest.measurements
                let mLong = Units.inches(max(me.slabWidthInches, me.slabDepthInches)), mShort = Units.inches(min(me.slabWidthInches, me.slabDepthInches))
                let errs = locked.compactMap { $0.sides }.map { (($0.long - mLong) + ($0.short - mShort)) / 2 }
                metrics.append(errs.isEmpty ? .na("slabSizeError", locked.isEmpty ? neverLocked : "no detection while locked")
                                            : KitMetric(id: "slabSizeError", value: KitStats.median(errs) * 1000, count: errs.count))
            }
        }

        // the ball
        let searched = res.filter { $0.ballSearched }
        func ballReason() -> String? {
            if !hasBallLocator { return "no ball finder in this build" }
            if locked.isEmpty { return expect.slab == .forbidden ? "the app looks for the ball only on a lock, and the slab is not in view"
                                                                 : "the app looks for the ball only on a lock, and the slab never locked" }
            if searched.isEmpty { return "the ball finder never ran" }
            return nil
        }
        if expect.ball == .required {
            if let r = ballReason() { metrics.append(.na("ballDetectionRate", r)) }
            else { metrics.append(KitMetric(id: "ballDetectionRate", value: Double(searched.filter { $0.ballFound }.count) / Double(searched.count),
                                            count: searched.count)) }
        }
        if expect.ball == .forbidden {
            if let r = ballReason() { metrics.append(.na("ballFalsePositiveRate", r)) }
            else { metrics.append(KitMetric(id: "ballFalsePositiveRate", value: Double(searched.filter { $0.ballFound }.count) / Double(searched.count),
                                            count: searched.count)) }
        }
        if sh.spec.diagram == .ballOnSlab {
            let e = res.compactMap { $0.ballDistanceError }
            if let r = ballReason() { metrics.append(.na("ballDistanceError", r)) }
            else if e.isEmpty { metrics.append(.na("ballDistanceError", "the ball was not found on the slab")) }
            else { metrics.append(KitMetric(id: "ballDistanceError", value: KitStats.median(e) * 1000, count: e.count)) }
        }
        if sh.spec.asksHeight {
            let entered = sh.record.enteredHeightInches ?? sh.manifest?.enteredHeightInches
            let h = res.compactMap { $0.dropHeight }
            if entered == nil { metrics.append(.na("dropHeightError", "no height was entered")) }
            else if let r = ballReason() { metrics.append(.na("dropHeightError", r)) }
            else if h.isEmpty { metrics.append(.na("dropHeightError", "the app never had the ball over the slab")) }
            else { metrics.append(KitMetric(id: "dropHeightError", value: (KitStats.median(h) - Units.inches(entered!)) * 1000, count: h.count)) }
        }

        // the bounce
        if sh.spec.kind.highFrameRate && sh.spec.kind.releaseCue != nil {
            let ids = ["landingError", "landingDistanceError", "apexError", "impactPointError", "rebound"]
            var reason: String? = nil
            if !hasBallLocator { reason = "no ball finder in this build" }
            else if c == nil { reason = "shot.json has neither releaseTime nor startTime and releaseCue" }
            else if locked.isEmpty { reason = neverLocked }
            if reason == nil, let cue = c {
                let lock = run.lockBeforeCue
                let predict: ((Vec3) -> KitBouncePrediction?)? = lock.map { p in { KitBouncePrediction.app(pose: p, settings: self.settings, held: $0) } }
                switch KitBounceAnalysis.analyze(track: run.track, cue: cue, predict: predict) {
                case let .analyzed(a):
                    score.bounce = a
                    let noPred = "the slab was not locked before the release"
                    metrics.append(a.landingError.map { KitMetric(id: "landingError", value: $0 * 1000, count: a.postSamples) } ?? .na("landingError", noPred))
                    metrics.append(a.landingDistanceError.map { KitMetric(id: "landingDistanceError", value: $0 * 1000) } ?? .na("landingDistanceError", noPred))
                    metrics.append(a.apexError.map { KitMetric(id: "apexError", value: $0 * 1000) } ?? .na("apexError", noPred))
                    metrics.append(a.impactPointError.map { KitMetric(id: "impactPointError", value: $0 * 1000) } ?? .na("impactPointError", noPred))
                    metrics.append(KitMetric(id: "rebound", value: a.rebound, count: a.preSamples + a.postSamples))
                case let .failed(why): reason = why
                }
            }
            if let r = reason { for id in ids { metrics.append(.na(id, r)) } }
        }

        score.metrics = metrics
        if run.unusableFrames > 0 { notes.append("\(sh.spec.id): \(run.unusableFrames) frames without a usable pose were left out.") }
        if run.depthErrors > 0 { notes.append("\(sh.spec.id): \(run.depthErrors) depth files could not be read.") }
        let lockText = locked.isEmpty ? "never locked" : String(format: "locked on %.0f%% of frames", 100 * Double(locked.count) / Double(max(1, res.count)))
        log("\(kitId) \(sh.spec.id): \(res.count) frames, \(lockText)")
        tiltErrors += tiltErr; normalErrors += normalErr
        return (score, res, tiltErr, normalErr)
    }

    /// RMS distance of each corner from its per-axis median over frames (m); frames' corners are matched to the first
    /// frame's (the lock's corner order can turn).
    static func cornerRms(_ frames: [[Vec3]]) -> Double {
        guard let ref = frames.first, ref.count == 4 else { return 0 }
        var matched: [[Vec3]] = []
        for c in frames where c.count == 4 {
            var best = c, bd = Double.infinity
            for rev in [false, true] {
                let r = rev ? Array(c.reversed()) : c
                for k in 0..<4 {
                    let x = (0..<4).map { r[($0 + k) % 4] }
                    let d = zip(x, ref).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                    if d < bd { bd = d; best = x }
                }
            }
            matched.append(best)
        }
        var sum = 0.0, n = 0.0
        for k in 0..<4 {
            let pts = matched.map { $0[k] }
            let med = Vec3(KitStats.median(pts.map { $0.x }), KitStats.median(pts.map { $0.y }), KitStats.median(pts.map { $0.z }))
            for p in pts { sum += p.distance(to: med) * p.distance(to: med); n += 1 }
        }
        return n > 0 ? (sum / n).squareRoot() : 0
    }

    // MARK: the true normal through the CoreMotion-to-ARKit link

    func link(for sh: Shot) -> KitMotionLink.Estimate {
        if let l = links[sh.spec.id] { return l }
        let e: KitMotionLink.Estimate
        if let mo = sh.motion { e = KitMotionLink.estimate(frames: sh.frames, motion: mo, shotId: sh.spec.id) }
        else { e = .failed("\(sh.spec.id) has no motion.jsonl") }
        links[sh.spec.id] = e
        return e
    }

    /// The slab's true normal in ARKit's world for shot `sh` of position `p`, or why it cannot be had; also the link.
    func trueNormalWorld(position p: KitSlabPosition, for sh: Shot) -> (Vec3?, String?) {
        let r = linkFor(position: p, shot: sh)
        guard let l = r.link, let n = p.groundTruth?.slabNormalInMotionFrame else { return (nil, r.reason ?? "the true tilt has no attitude reading") }
        return (l.toWorld(n).normalized, nil)
    }

    func linkFor(position p: KitSlabPosition, shot sh: Shot) -> (link: KitMotionLink?, reason: String?) {
        guard let gt = p.groundTruth, gt.isUsable else { return (nil, "no true tilt") }
        guard gt.slabNormalInMotionFrame != nil else { return (nil, "the true tilt has no attitude reading") }
        guard let flat = shot(p.shotId), let fm = flat.manifest, fm.positionId == p.id else {
            return (nil, "the flat-phone shot of \(p.id) is no longer in the kit (the slab was set up again), so its motion session is unknown")
        }
        guard let mid = fm.motionSessionId, let aid = sh.manifest?.arSessionId else {
            return (nil, "the shots do not record their CoreMotion and ARKit session ids")
        }
        let tF = gt.readingA?.start ?? fm.startTime
        let cands = shots.filter { $0.spec.isVideo && $0.manifest?.motionSessionId == mid && $0.manifest?.arSessionId == aid && $0.motion != nil }
            .sorted { a, b in
                if let t = tF, let ta = a.manifest?.startTime, let tb = b.manifest?.startTime { return abs(ta - t) < abs(tb - t) }
                return abs(a.planIndex - flat.planIndex) < abs(b.planIndex - flat.planIndex)
            }
        guard !cands.isEmpty else {
            return (nil, "no video shot shares the flat-phone shot's CoreMotion session and this shot's ARKit session")
        }
        var first: String? = nil
        for c in cands {
            switch link(for: c) {
            case let .linked(l): return (l, nil)
            case let .failed(why): if first == nil { first = why }
            }
        }
        return (nil, "no CoreMotion-to-ARKit link: " + (first ?? "?"))
    }

    // MARK: positions and aggregates

    func scorePositions(_ scores: [KitShotScore], tilts: [String: [Double]], normals: [String: [Double]]) -> [KitPositionScore] {
        var out: [KitPositionScore] = []
        for p in manifest.positions {
            let gt = p.groundTruth.flatMap { $0.isUsable ? $0 : nil }
            // the shots whose tilt is scored in this position (not those where the slab must be out of view)
            let ss = scores.filter { $0.positionId == p.id && $0.error == nil && $0.frames > 0 && $0.metric("tiltErrorMedian") != nil }
            var ps = KitPositionScore(positionId: p.id, label: p.label, trueTiltDegrees: gt?.tiltDegrees, method: p.groundTruth?.method.rawValue,
                                      uncertaintyDegrees: gt?.uncertaintyDegrees, shots: ss.map { $0.shotId })
            guard gt != nil else {
                let r = p.groundTruth == nil ? "no true tilt (the flat-phone shot was skipped or is not taken)" : "the flat-phone reading failed"
                ps.metrics = ["tiltErrorMedian", "tiltErrorP90", "tiltBias"].map { KitMetric.na($0, r) }
                out.append(ps); continue
            }
            let e = ss.flatMap { tilts[$0.shotId] ?? [] }, a = e.map { abs($0) }
            if a.isEmpty {
                let r = ss.isEmpty ? "no video shot scored in this position" : "the slab never locked in this position's shots"
                ps.metrics = ["tiltErrorMedian", "tiltErrorP90", "tiltBias"].map { KitMetric.na($0, r) }
            } else {
                ps.metrics = [KitMetric(id: "tiltErrorMedian", value: KitStats.median(a), count: a.count),
                              KitMetric(id: "tiltErrorP90", value: KitStats.percentile(a, 90), count: a.count),
                              KitMetric(id: "tiltBias", value: KitStats.median(e), count: a.count)]
            }
            let n = ss.flatMap { normals[$0.shotId] ?? [] }
            if let first = ss.first, let sh = shot(first.shotId) { ps.link = linkFor(position: p, shot: sh).link }
            if n.isEmpty {
                let why = ss.compactMap { $0.metric("normalErrorMedian")?.note }.first ?? "no locked frames"
                ps.metrics += [KitMetric.na("normalErrorMedian", why), KitMetric.na("normalErrorP90", why)]
            } else {
                ps.metrics += [KitMetric(id: "normalErrorMedian", value: KitStats.median(n), count: n.count),
                               KitMetric(id: "normalErrorP90", value: KitStats.percentile(n, 90), count: n.count)]
            }
            out.append(ps)
        }
        return out
    }

    func aggregate(_ scores: [KitShotScore], frames: [String: [FrameResult]]) -> [KitMetric] {
        var out: [KitMetric] = []
        let ok = scores.filter { $0.error == nil }
        func values(_ id: String) -> [Double] { ok.compactMap { $0.metric(id)?.value } }
        func reason(_ id: String, _ fallback: String) -> String {
            var counts: [String: Int] = [:]
            for s in ok { if let n = s.metric(id)?.note, s.metric(id)?.value == nil { counts[n, default: 0] += 1 } }
            return counts.max { $0.value < $1.value }?.key ?? fallback
        }
        func medianOf(_ id: String, abs useAbs: Bool = false, fallback: String) -> KitMetric {
            let v = values(id).map { useAbs ? Swift.abs($0) : $0 }
            return v.isEmpty ? .na(id, reason(id, fallback)) : KitMetric(id: id, value: KitStats.median(v), count: v.count)
        }
        let slabShots = ok.filter { $0.metric("lockRate") != nil || $0.metric("timeToLock") != nil }
        let rates = values("lockRate")
        out.append(rates.isEmpty ? .na("lockRate", reason("lockRate", "no slab shot scored"))
                                 : KitMetric(id: "lockRate", value: rates.reduce(0, +) / Double(rates.count), count: rates.count))
        out.append(medianOf("timeToLock", fallback: "no slab shot scored"))
        out.append(slabShots.isEmpty ? .na("neverLocked", "no slab shot scored")
                                     : KitMetric(id: "neverLocked", value: Double(slabShots.filter { $0.metric("timeToLock")?.value == nil }.count),
                                                 count: slabShots.count))
        let a = tiltErrors.map { abs($0) }
        if a.isEmpty {
            for id in ["tiltErrorMedian", "tiltErrorP90", "tiltBias"] { out.append(.na(id, reason("tiltErrorMedian", "no locked frame with a true tilt"))) }
        } else {
            out.append(KitMetric(id: "tiltErrorMedian", value: KitStats.median(a), count: a.count))
            out.append(KitMetric(id: "tiltErrorP90", value: KitStats.percentile(a, 90), count: a.count))
            out.append(KitMetric(id: "tiltBias", value: KitStats.median(tiltErrors), count: a.count))
        }
        if normalErrors.isEmpty {
            for id in ["normalErrorMedian", "normalErrorP90"] { out.append(.na(id, reason("normalErrorMedian", "no locked frame with a true normal"))) }
        } else {
            out.append(KitMetric(id: "normalErrorMedian", value: KitStats.median(normalErrors), count: normalErrors.count))
            out.append(KitMetric(id: "normalErrorP90", value: KitStats.percentile(normalErrors, 90), count: normalErrors.count))
        }
        out.append(medianOf("cornerRms", fallback: "no slab shot locked"))
        out.append(medianOf("slabSizeError", abs: true, fallback: "no slab shot locked"))
        // false slabs: frames pooled over the shots where the slab must not be in view
        let forb = ok.filter { $0.metric("slabFoundRate") != nil }.flatMap { frames[$0.shotId] ?? [] }
        if forb.isEmpty {
            out.append(.na("slabFoundRate", "no shot without the slab was scored")); out.append(.na("slabLockedRate", "no shot without the slab was scored"))
        } else {
            out.append(KitMetric(id: "slabFoundRate", value: Double(forb.filter { $0.state != .searching }.count) / Double(forb.count), count: forb.count))
            out.append(KitMetric(id: "slabLockedRate", value: Double(forb.filter { $0.state == .locked }.count) / Double(forb.count), count: forb.count))
        }
        func pooledBall(_ id: String, _ shotsWith: [KitShotScore]) -> KitMetric {
            let runs = shotsWith.filter { $0.metric(id)?.value != nil }.flatMap { (frames[$0.shotId] ?? []).filter { $0.ballSearched } }
            guard !runs.isEmpty else { return .na(id, reason(id, hasBallLocator ? "the ball finder never ran" : "no ball finder in this build")) }
            return KitMetric(id: id, value: Double(runs.filter { $0.ballFound }.count) / Double(runs.count), count: runs.count)
        }
        out.append(pooledBall("ballDetectionRate", ok))
        out.append(pooledBall("ballFalsePositiveRate", ok))
        out.append(medianOf("ballDistanceError", abs: true, fallback: "the ball-on-the-slab shot was not scored"))
        out.append(medianOf("dropHeightError", abs: true, fallback: "no held-ball shot with an entered height"))
        out.append(medianOf("landingError", fallback: "no drop scored"))
        out.append(medianOf("landingDistanceError", abs: true, fallback: "no drop scored"))
        out.append(medianOf("apexError", abs: true, fallback: "no drop scored"))
        out.append(medianOf("impactPointError", fallback: "no drop scored"))
        out.append(medianOf("rebound", fallback: "no drop scored"))
        return out
    }
}
