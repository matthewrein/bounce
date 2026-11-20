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
///     the share of frames on which the tracker was confirming or locked / locked on anything but the real slab.
///     **slabInViewRate**: the share found on the real slab, left in view (its top, where the slab shots of the same ARKit
///     session just before and after locked it: `markRealSlab`); those finds are not false.
///   - **ballDetectionRate** (shots expecting the ball): of the frames on which the app's ball finder ran (only while
///     locked, every `ballInterval`), the share that found a ball there. A ball the app holds over from an earlier
///     search (`BallObservation.missedUpdates` > 0: it keeps showing a missed ball for a couple of searches) is not a
///     find. **ballFalsePositiveRate** (shots where the ball must not be in view): the same share where there is no
///     ball. n/a without a ball finder (`AppDetectors.ball()` is nil), when the slab never locked (the app looks for the
///     ball only on a lock), and for the ball resting on the slab when the app's finder does not look that low. A ball
///     shot's searches over the real slab, left in view (`markRealSlab`), are left out: the app looks for a ball only
///     over the slab's top, so the ball on the floor beside it is never there to find.
///   - **ballDistanceError** (the ball resting on the slab, `s08`): the ball's distance from the camera from its size
///     (the tracking finder's centre, every locked frame: `trackingLocator`) minus the distance along the same ray to where its centre must be resting on the dish
///     where it was found (a radius above the dish's surface along its own normal there; on a tilted slab the ball
///     cannot stay in the middle); median over the frames with a ball found over the slab's top (mm).
///   - **dropHeightError** (held ball with an entered height, `s09`): the app's drop height (the ball's bottom above
///     the dish straight below it, `Readouts.dropHeight` while it comes from the ball), median over frames, minus the
///     entered height (mm). The app asks for the same height: the ball's bottom above the slab right under it, a ruler
///     stood on the slab under the ball (in the dish, not on the corners' plane 1/8 in above it).
///   - **bounce** (drops, `s10`/`s11`): a second ball finder runs on every frame, on the app's crop around the lock:
///     the app's `BallLocator` set up for tracking (`trackingLocator`: each frame on its own, so every sample of the
///     track is a measurement of that frame, not a ball held over or smoothed). The release is looked for after
///     `releaseTime` (else `startTime + releaseCue`), and the track is analysed as `KitBounceAnalysis` describes (a
///     track that does not hold together as a drop is n/a, with the reason): `landingError`, `landingDistanceError`, `apexError`,
///     `impactHeightError` against the app's prediction (`Bounce.compute` with the lock before the release and the held
///     ball) and the `rebound` measured from the bounce. The same track is measured on the dish (`KitDropAnalysis`, with
///     the lock before the cue and the dish's geometry, `KitDish`): `reboundMeasured` (e², e the restitution about the
///     dish's local normal: the app's rebound setting), `landingErrorApp` and `landingErrorRebound` (the actual landing
///     against the app's prediction for the same held ball with the app's rebound, and with the measured one, both
///     carried down to the same level: where the ball came down on the slab again, else where it came down next when
///     that is seen lower (the floor), else the lock's lowest top corner, the app's own end level),
///     `launchDirectionError` (the app's launch direction against the measured one) and `impactClearance` (the gap
///     between the ball and the dish where the fall's and the bounce's fits meet: the track against the lock).
/// Aggregates: lockRate is the mean over slab shots, timeToLock the median over shots that locked, neverLocked a count;
/// tilt and normal errors pool every frame; cornerRms, slabSizeError, landing, apex and impact height errors are medians
/// over shots (signed errors as medians of their absolute values); the false-positive and detection rates pool frames.
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
        /// the ball finder for a drop's dense track (every frame); nil: `makeBallLocator`'s, set up for tracking
        /// (`KitScorer.trackingLocator`)
        public var makeTrackingBallLocator: (() -> BallLocating?)? = nil
        /// where the video frames come from; nil: the kit's video.mp4 through ffmpeg (macOS and Linux)
        public var frames: FrameProvider? = nil
        /// "kit", or "synthetic" for the synthetic kit
        public var source = "kit"
        /// progress lines (kit and shot ids and numbers only)
        public var log: ((String) -> Void)? = nil
        /// The slab position a shot was taken in, where kit.json has it wrong (the slab was moved without a new position,
        /// or left where it was): shot id, or the start of shot ids (e.g. "s07" for both s07 shots), to a position id, or
        /// `KitScorer.unmeasured` for a position with no true tilt (its shots report what they read, no error). The
        /// longest matching key wins; shots not named keep kit.json's.
        public var positions: [String: String] = [:]
        public init() {}

        /// The position `positions` gives a shot, if any (a position id or `KitScorer.unmeasured`).
        public func position(forShot id: String) -> String? {
            if let p = positions[id] { return p }
            let keys = positions.keys.filter { id.hasPrefix($0) && (id.count == $0.count || id[id.index(id.startIndex, offsetBy: $0.count)] == "-") }
            return keys.max { $0.count < $1.count }.flatMap { positions[$0] }
        }
    }

    /// `Options.positions`' value for a slab position with no true tilt
    public static let unmeasured = "unmeasured"

    public let kitFolder: URL
    public var options: Options

    public init(kitFolder: URL, options: Options = Options()) { self.kitFolder = kitFolder; self.options = options }

    /// The kit's video.mp4 through ffmpeg (macOS and Linux). The colour range is the stream's tag; a stream without one
    /// (the phone's encoder may leave it out) is read the way its samples say (`KitVideoDecoder.rangeCheck`, against
    /// frames.jsonl's `luma`), and the decoder's `rangeNote` says how, or that a tagged stream's samples disagree.
    public static func videoFrames(_ s: ShotInput) throws -> KitFrameSource {
        #if os(macOS) || os(Linux)
        let url = s.folder.appendingPathComponent(KitClipFiles.video)
        guard FileManager.default.fileExists(atPath: url.path) else { throw KitScoreError.unreadable(KitClipFiles.video) }
        let probe = try KitVideoDecoder.probe(url)
        let tagged = probe.colorRange != nil || probe.pixelFormat.hasPrefix("yuvj")
        let check = try? KitVideoDecoder.rangeCheck(url: url, luma: s.frames.map { $0.luma })
        let dec = try KitVideoDecoder(url: url, expectedFrames: s.frames.count, fullRange: tagged ? nil : (check?.fullRange ?? true))
        if !tagged {
            dec.rangeNote = "the video has no colour range tag: " + (check?.reason ?? "read as full range, as the app records")
        } else if let c = check, c.fullRange != probe.isFullRange,
                  c.outsideShare > 0.002 || abs((c.fullLumaError ?? 0) - (c.limitedLumaError ?? 0)) > 1.5 {
            dec.rangeNote = "the video is tagged \(probe.isFullRange ? "full" : "limited") range, but \(c.reason); read as tagged"
        }
        return dec
        #else
        throw KitScoreError.noDecoder
        #endif
    }

    /// A ball finder for following a drop frame by frame: the app's `BallLocator` with `BallLocator.Options.tracking`
    /// (every frame stands on its own: no hold-over, no smoothing, no follow box, no 5 cm floor, on the slab or not, and
    /// a half outline taken on one frame at any height), so each sample of the track is a measurement of that frame.
    /// Any other finder is used as it is.
    public static func trackingLocator(_ l: BallLocating?) -> BallLocating? {
        guard let b = l as? BallLocator else { return l }
        b.options = BallLocator.Options.tracking(b.options)
        b.reset()
        return b
    }

    /// Parse "s07=p4,s08=unmeasured,..." (bounce-score --positions) into `Options.positions`; nil if malformed.
    public static func parsePositions(_ spec: String) -> [String: String]? {
        var out: [String: String] = [:]
        for part in spec.split(separator: ",") {
            let kv = part.split(separator: "=", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty else { return nil }
            out[kv[0]] = kv[1]
        }
        return out.isEmpty ? nil : out
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
        /// the ball finder found a ball in this frame (a ball the app holds over from an earlier search does not count)
        var ballFound = false
        /// the app showed a ball held over from an earlier search
        var ballHeldOver = false
        var ballDistanceError: Double? = nil
        var dropHeight: Double? = nil
        /// the tilt was settled enough to show (`TrackerOutput.angleSettled`), and the settled normal (world) then
        var settled = false
        var settledNormal: Vec3? = nil
        /// on a frame whose re-check refreshed the tilt's honest estimate: its normal (world) and covariance (rad^2)
        var honest: (normal: Vec3, cov: Mat3)? = nil
        /// this frame's own detection, in any state: the ray (world) through the middle of the square it shows (where
        /// its outline's diagonals cross), to tell a find on the real slab from a false one (`markRealSlab`)
        var findRay: (origin: Vec3, direction: Vec3)? = nil
        /// found (confirming or locked) on the real slab, left in view in a shot that should not show it (`markRealSlab`)
        var onRealSlab = false
        /// the find was in the picture: a lock with a top corner in it, or this frame's own detection (nil: nothing was
        /// found, or a confirming frame without a detection). The tracker keeps a lock after the slab leaves the picture.
        var inPicture: Bool? = nil
    }

    struct ShotRun {
        var results: [FrameResult] = []
        var track: [KitBallSample] = []
        /// a drop's frames the tracking finder searched: when, the app's crop it searched, that image's intrinsics and
        /// the camera (full image, world)
        var ballImages: [(t: Double, crop: BallImageCrop, intrinsics: CameraIntrinsics, view: CameraView)] = []
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
    /// the app's ball finder reports a ball only this high over the slab (m; `BallLocator.Options.minHeight`), if it says
    var appBallMinHeight: Double? = nil
    var notes: [String] = []
    /// pooled values for the aggregates
    var tiltErrors: [Double] = [], normalErrors: [Double] = []
    var settledTiltErrors: [Double] = [], settledNormalErrors: [Double] = []
    var honestRatios: [Double] = []

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
        let bounce = settings.launchRule == .impact
            ? String(format: "restitution %.2f, tangential share %.2f (the impact rule)", settings.ball.restitution, settings.ball.tangentialFactor)
            : String(format: "rebound %.0f%%", settings.ball.rebound * 100)
        notes.append(String(format: "Slab %.2f x %.2f in, %.2f in thick, %.3f in dish; ball %.1f mm; %@.",
                            Units.toInches(s.sideU), Units.toInches(s.sideV), Units.toInches(s.thickness), Units.toInches(s.dishDepth),
                            settings.ball.diameter * 1000, bounce))
        let probe = options.makeBallLocator()
        hasBallLocator = probe != nil
        appBallMinHeight = (probe as? BallLocator)?.options.minHeight
        if !hasBallLocator { notes.append("No ball finder in this build (AppDetectors.ball() is nil): the ball and bounce metrics are n/a.") }
        loadShots()
        // the phone's own tilt check (kits from n20k): shots whose app tilt disagreed with their true tilt at capture
        let flagged = shots.compactMap { sh -> String? in
            guard let c = sh.manifest?.tiltCheck, c.disagrees else { return nil }
            return c.line(shot: sh.spec.id)
        }
        if !flagged.isEmpty {
            notes.append("Tilt check on the phone: the app's tilt disagreed with the true tilt on " + flagged.joined(separator: "; ")
                         + ". The slab may have moved since its reading: those shots' true tilt may be wrong.")
        }
        if !options.positions.isEmpty {
            let named = shots.filter { $0.spec.isVideo }.compactMap { sh in options.position(forShot: sh.spec.id).map { "\(sh.spec.id) \($0)" } }
            notes.append("Slab positions overridden (--positions): " + (named.isEmpty ? "none of the kit's shots matched" : named.joined(separator: ", ")) + ".")
        }

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
        markRealSlab(&scores, frames: &perShotFrames)
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
        #if os(macOS) || os(Linux)
        if let n = (source as? KitVideoDecoder)?.rangeNote { notes.append("\(sh.spec.id): \(n).") }
        #endif
        let pipeline = KitFramePipeline(videoWidth: source.width, videoHeight: source.height, cameraFormat: m.cameraFormat)
        let locator = options.makeBallLocator()
        let tracker = SlabTracker(settings: settings, detector: options.makeDetector(), ballLocator: locator)
        let isDrop = sh.spec.kind.highFrameRate && sh.spec.kind.releaseCue != nil
        let isBallOnSlab = sh.spec.diagram == .ballOnSlab
        // drops and the ball resting on the slab: the ball finder set up for tracking, on every frame (the app's own
        // looks only every `ballInterval`, holds a missed ball over, smooths, and ignores a ball under 5 cm)
        let dense: BallLocating? = isDrop || isBallOnSlab
            ? (options.makeTrackingBallLocator?() ?? KitScorer.trackingLocator(options.makeBallLocator())) : nil
        dense?.reset()
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
            let refreshes = tracker.honestRefreshes
            let out = tracker.process(pf.tracker)
            var r = FrameResult(t: f.time, state: out.state)
            if let q = out.measurement, q.count == 4, let mid = SlabBoxView.intersect((q[0], q[2]), (q[1], q[3])) {
                let ray = pf.tracker.view.ray(through: mid)
                r.findRay = (ray.origin, ray.direction)
                r.inPicture = true
            }
            if out.state == .locked, let s = out.slab {
                lastLock = s
                if let c = cue, f.time < c { run.lockBeforeCue = s }
                // the lock's tilt (what the outline and the path follow, and what the readouts showed before n11); the
                // tilt as shown, from the settled normal, is scored apart (settled*)
                r.tilt = Units.degrees(s.tilt(down: down))
                r.normal = s.normal
                if tracker.honestRefreshes != refreshes, let n = tracker.honestNormal, let C = tracker.settledCovariance { r.honest = (n, C) }
                r.corners = s.topCorners
                let v = pf.tracker.view
                r.inPicture = s.topCorners.contains { v.project(world: $0).map { v.intrinsics.contains($0) } ?? false }
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
                if out.angleSettled { r.settled = true; r.settledNormal = tracker.settledNormal }
            }
            if out.ballSearched {
                r.ballSearched = true
                // a ball the app's locator holds over from an earlier search (it keeps a missed ball for a couple of
                // searches) is what the app shows, but not something found in this frame
                r.ballHeldOver = out.ball != nil && ((locator as? BallLocator)?.current?.missedUpdates ?? 0) > 0
                r.ballFound = out.ball != nil && !r.ballHeldOver
            }
            // the tracking finder on every frame, on the app's crop around the lock: a drop's dense track, and the ball
            // resting on the slab (its distance from its size, while the slab is locked)
            if let d = dense, let lock = out.slab ?? lastLock, let b = pipeline.ballImage(img, slab: lock, video: pf.video) {
                (d as? KitFrameAware)?.prepare(shotId: sh.spec.id, frameIndex: i, time: f.time, view: pf.video)
                if isDrop { run.ballImages.append((f.time, b.crop, b.intrinsics, pf.video)) }
                let sc = lock.transformed(by: pf.video.cameraFromWorld)
                if let x = d.locate(image: b.image, intrinsics: b.intrinsics, slab: sc, spec: settings.spec, ball: settings.ball,
                                    down: pf.video.directionToCamera(down)), x.center.isFinite {
                    let w = pf.video.toWorld(x.center)
                    if isDrop { run.track.append(KitBallSample(t: f.time, p: w, c: pf.video.position)) }
                    if isBallOnSlab, out.state == .locked, let s = out.slab {
                        r.ballDistanceError = KitScoreRun.ballDistanceError(ballWorld: w, slab: s, view: pf.video, settings: settings)
                    }
                }
            }
            run.results.append(r)
        }
        #if os(macOS) || os(Linux)
        if let dec = source as? KitVideoDecoder { try dec.finish() }
        #endif
        return run
    }

    /// The ball's distance from the camera from its size minus the distance along the same ray to the place its centre
    /// must be when it rests on the dish where it was found: a radius above the dish's surface along the dish's own
    /// normal there (`Dish.at`; the ball need not rest in the middle: on a tilted slab it rests wherever the dish holds
    /// it, or rolls to the rim). The contact point is found by intersecting the ray with the tangent plane a few times
    /// over. nil when the ball is not over the slab's top (it rolled to the rim or off), or the ray grazes the dish (m).
    static func ballDistanceError(ballWorld: Vec3, slab: SlabPose, view: CameraView, settings: TrackerSettings) -> Double? {
        let c = view.toCamera(ballWorld), dist = c.length
        guard dist > 1e-6 else { return nil }
        let p = slab.transformed(by: view.cameraFromWorld)
        let dir = c / dist, R = settings.ball.radius
        var (u, v) = p.local(c)
        var t = dist
        for _ in 0..<4 {
            guard abs(u) <= p.halfU, abs(v) <= p.halfV else { return nil }
            let d = Dish.at(pose: p, depth: settings.spec.dishDepth, u: u, v: v)
            let centre = p.point(u: u, v: v) - p.normal * d.depth + d.normal * R
            let den = dir.dot(d.normal)
            guard abs(den) > 0.05 else { return nil }
            t = centre.dot(d.normal) / den
            guard t > 0 else { return nil }
            (u, v) = p.local(dir * t - d.normal * R)
        }
        guard abs(u) <= p.halfU, abs(v) <= p.halfV else { return nil }
        return dist - t
    }

    // MARK: scoring a shot

    func scoreShot(_ sh: Shot) -> (KitShotScore, [FrameResult], [Double], [Double]) {
        let override = options.position(forShot: sh.spec.id)
        let unmeasured = override == KitScorer.unmeasured
        let posId = unmeasured ? nil : (override ?? manifest.record(sh.spec.id)?.positionId)
        let position = posId.flatMap { manifest.position($0) }
        let truth = position?.groundTruth.flatMap { $0.isUsable ? $0 : nil }
        var score = KitShotScore(shotId: sh.spec.id, step: sh.spec.step, positionId: unmeasured ? KitScorer.unmeasured : posId,
                                 trueTiltDegrees: truth?.tiltDegrees)
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
            // finds on the real slab, left in view, are told apart once every shot has run (`markRealSlab`)
            metrics += KitScoreRun.falseSlabMetrics(res)
        }

        // tilt, against the flat-phone true tilt
        var tiltErr: [Double] = [], normalErr: [Double] = [], honestRatio: [Double] = []
        if expect.slab != .forbidden {
            let reason: String?
            if unmeasured { reason = "the slab's position in this shot has no true tilt (--positions: unmeasured)" }
            else if posId == nil { reason = "the shot belongs to no slab position (taken before the first flat-phone shot)" }
            else if truth == nil { reason = "no true tilt for \(posId!) (its flat-phone shot was skipped or failed)" }
            else if locked.isEmpty { reason = neverLocked }
            else { reason = nil }
            if let r = reason {
                if expect.slab == .required || posId != nil || unmeasured {
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
                    // the honest estimate's error in its own uncertainty, at each refresh (2-D: across the normal)
                    honestRatio = locked.compactMap { $0.honest.flatMap { KitScorer.honestRatio(truth: n, estimate: $0.normal, covariance: $0.cov) } }
                    if honestRatio.isEmpty {
                        for id in ["honestRatioMedian", "honestRatioP95"] { metrics.append(.na(id, "the tilt's honest estimate never refreshed")) }
                    } else {
                        metrics.append(KitMetric(id: "honestRatioMedian", value: KitStats.median(honestRatio), count: honestRatio.count))
                        metrics.append(KitMetric(id: "honestRatioP95", value: KitStats.percentile(honestRatio, 95), count: honestRatio.count))
                    }
                } else {
                    let r = n == nil ? (why ?? "no link") : neverLocked
                    metrics.append(.na("normalErrorMedian", r)); metrics.append(.na("normalErrorP90", r))
                }
            }
        }

        // the tilt as the app shows it: only once settled (`TrackerOutput.angleSettled`), from the settled normal
        var settledErr: [Double] = [], settledNormalErr: [Double] = []
        if expect.slab != .forbidden && (expect.slab == .required || posId != nil || unmeasured) {
            let settled = locked.filter { $0.settled }
            let up = -ARKitConvention.worldDown
            let settledTilts = settled.compactMap { $0.settledNormal.map { Units.degrees($0.angle(to: up)) } }
            if locked.isEmpty {
                metrics.append(.na("settledRate", neverLocked))
            } else {
                metrics.append(KitMetric(id: "settledRate", value: Double(settled.count) / Double(locked.count), count: locked.count))
                metrics.append(settled.first.map { KitMetric(id: "timeToSettle", value: $0.t - t0) } ?? .na("timeToSettle", "the tilt never settled"))
            }
            if unmeasured {
                let reads = locked.compactMap { $0.tilt }
                metrics.append(reads.isEmpty ? .na("tiltReading", neverLocked) : KitMetric(id: "tiltReading", value: KitStats.median(reads), count: reads.count))
                metrics.append(settledTilts.isEmpty ? .na("settledTiltReading", locked.isEmpty ? neverLocked : "the tilt never settled")
                                                    : KitMetric(id: "settledTiltReading", value: KitStats.median(settledTilts), count: settledTilts.count))
            } else if let tt = truth?.tiltDegrees, !settledTilts.isEmpty {
                settledErr = settledTilts.map { abs($0 - tt) }
                metrics.append(KitMetric(id: "settledTiltErrorMedian", value: KitStats.median(settledErr), count: settledErr.count))
                metrics.append(KitMetric(id: "settledTiltErrorMax", value: settledErr.max(), count: settledErr.count))
                if let p = position {
                    let (n, why) = trueNormalWorld(position: p, for: sh)
                    if let n = n {
                        settledNormalErr = settled.compactMap { $0.settledNormal.map { Units.degrees($0.angle(to: n)) } }
                        metrics.append(KitMetric(id: "settledNormalErrorMedian", value: KitStats.median(settledNormalErr), count: settledNormalErr.count))
                        metrics.append(KitMetric(id: "settledNormalErrorMax", value: settledNormalErr.max(), count: settledNormalErr.count))
                    } else {
                        metrics.append(.na("settledNormalErrorMedian", why ?? "no link")); metrics.append(.na("settledNormalErrorMax", why ?? "no link"))
                    }
                }
            } else if truth != nil {
                let r = locked.isEmpty ? neverLocked : "the tilt never settled"
                for id in ["settledTiltErrorMedian", "settledTiltErrorMax"] { metrics.append(.na(id, r)) }
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
            if locked.isEmpty { return expect.slab == .forbidden ? KitScoreRun.noLockSlabForbidden
                                                                 : "the app looks for the ball only on a lock, and the slab never locked" }
            if searched.isEmpty { return "the ball finder never ran" }
            return nil
        }
        if expect.ball == .required {
            if let r = ballReason() { metrics.append(.na("ballDetectionRate", r)) }
            else if sh.spec.diagram == .ballOnSlab, let h = appBallMinHeight, h > 0.01 {
                metrics.append(.na("ballDetectionRate", String(format: "the app looks for a ball only %.0f cm or more above the slab, not one resting on it", h * 100)))
            }
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
            else if e.isEmpty { metrics.append(.na("ballDistanceError", "the ball was not found resting over the slab's top")) }
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
            let ids = ["landingError", "landingDistanceError", "apexError", "impactHeightError", "rebound"]
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
                    metrics.append(a.impactHeightError.map { KitMetric(id: "impactHeightError", value: $0 * 1000) } ?? .na("impactHeightError", noPred))
                    metrics.append(KitMetric(id: "rebound", value: a.rebound, count: a.preSamples + a.postSamples))
                case let .failed(why): reason = why
                }
            }
            if let r = reason { for id in ids { metrics.append(.na(id, r)) } }

            // the drop measured on the dish (`KitDropAnalysis`): the rebound as the app's setting means it, where the
            // ball hit the dish, and the landing against the app's prediction with its rebound and with the measured one
            let dropIds = ["reboundMeasured", "landingErrorApp", "landingErrorRebound", "launchDirectionError", "impactClearance"]
            var dropReason: String? = nil
            if !hasBallLocator { dropReason = "no ball finder in this build" }
            else if c == nil { dropReason = "shot.json has neither releaseTime nor startTime and releaseCue" }
            else if locked.isEmpty { dropReason = neverLocked }
            if dropReason == nil, let cue = c {
                let settings = self.settings
                var ctx = KitDropAnalysis.Context(slab: run.lockBeforeCue, dish: KitDish(spec: settings.spec))
                ctx.ballRadius = settings.ball.radius
                ctx.appRebound = settings.ball.rebound
                ctx.floorY = nil
                if let lock = run.lockBeforeCue {
                    ctx.predict = { held, rebound in
                        var s = settings
                        s.ball.rebound = rebound
                        return KitBouncePrediction.app(pose: lock, settings: s, held: held)
                    }
                }
                switch KitDropAnalysis.analyze(track: run.track, cue: cue, context: ctx) {
                case let .analyzed(a):
                    score.drop = a
                    let noPred = "the slab was not locked before the release"
                    let n = a.fallSamples + a.riseSamples
                    metrics.append(a.rebound.map { KitMetric(id: "reboundMeasured", value: $0, count: n) }
                                   ?? .na("reboundMeasured", "the ball did not bounce (it stayed on the slab)"))
                    metrics.append(a.app.map { KitMetric(id: "landingErrorApp", value: $0.landingError * 1000, count: a.riseSamples) }
                                   ?? .na("landingErrorApp", a.kind == .rolled ? "the ball did not bounce" : noPred))
                    metrics.append(a.measuredRebound.map { KitMetric(id: "landingErrorRebound", value: $0.landingError * 1000, count: a.riseSamples) }
                                   ?? .na("landingErrorRebound", a.kind == .rolled ? "the ball did not bounce" : noPred))
                    metrics.append(a.app.map { KitMetric(id: "launchDirectionError", value: $0.directionError) }
                                   ?? .na("launchDirectionError", a.kind == .rolled ? "the ball did not bounce" : noPred))
                    metrics.append(a.impactClearance.map { KitMetric(id: "impactClearance", value: $0 * 1000) }
                                   ?? .na("impactClearance", a.kind == .rolled ? "the ball did not bounce" : noPred))
                case let .failed(why): dropReason = why
                }
            }
            if let r = dropReason { for id in dropIds { metrics.append(.na(id, r)) } }
        }

        score.metrics = metrics
        if run.unusableFrames > 0 { notes.append("\(sh.spec.id): \(run.unusableFrames) frames without a usable pose were left out.") }
        if run.depthErrors > 0 { notes.append("\(sh.spec.id): \(run.depthErrors) depth files could not be read.") }
        let lockText = locked.isEmpty ? "never locked" : String(format: "locked on %.0f%% of frames", 100 * Double(locked.count) / Double(max(1, res.count)))
        log("\(kitId) \(sh.spec.id): \(res.count) frames, \(lockText)")
        tiltErrors += tiltErr; normalErrors += normalErr
        settledTiltErrors += settledErr; settledNormalErrors += settledNormalErr
        honestRatios += honestRatio
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
            // the commonest note; of notes as common, the first in alphabetical order (a dictionary's order is not fixed,
            // so a tie must not be left to it: the same kit scored twice gave two notes)
            return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? fallback
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
        // the tilt as shown: frames settled, of the locked frames of the slab shots; the error of the frames shown
        let lockedFrames = ok.filter { $0.metric("settledRate")?.value != nil }.flatMap { (frames[$0.shotId] ?? []).filter { $0.state == .locked } }
        out.append(lockedFrames.isEmpty ? .na("settledRate", "no slab shot locked")
                                        : KitMetric(id: "settledRate", value: Double(lockedFrames.filter { $0.settled }.count) / Double(lockedFrames.count),
                                                    count: lockedFrames.count))
        out.append(medianOf("timeToSettle", fallback: "no slab shot settled"))
        if settledTiltErrors.isEmpty {
            for id in ["settledTiltErrorMedian", "settledTiltErrorMax"] { out.append(.na(id, "no settled frame with a true tilt")) }
        } else {
            out.append(KitMetric(id: "settledTiltErrorMedian", value: KitStats.median(settledTiltErrors), count: settledTiltErrors.count))
            out.append(KitMetric(id: "settledTiltErrorMax", value: settledTiltErrors.max(), count: settledTiltErrors.count))
        }
        if settledNormalErrors.isEmpty {
            for id in ["settledNormalErrorMedian", "settledNormalErrorMax"] { out.append(.na(id, "no settled frame with a true normal")) }
        } else {
            out.append(KitMetric(id: "settledNormalErrorMedian", value: KitStats.median(settledNormalErrors), count: settledNormalErrors.count))
            out.append(KitMetric(id: "settledNormalErrorMax", value: settledNormalErrors.max(), count: settledNormalErrors.count))
        }
        if honestRatios.isEmpty {
            for id in ["honestRatioMedian", "honestRatioP95"] { out.append(.na(id, "no refresh of the honest estimate with a true normal")) }
        } else {
            out.append(KitMetric(id: "honestRatioMedian", value: KitStats.median(honestRatios), count: honestRatios.count))
            out.append(KitMetric(id: "honestRatioP95", value: KitStats.percentile(honestRatios, 95), count: honestRatios.count))
        }
        out.append(medianOf("cornerRms", fallback: "no slab shot locked"))
        out.append(medianOf("slabSizeError", abs: true, fallback: "no slab shot locked"))
        // false slabs: frames pooled over the shots where the slab must not be in view
        let forb = ok.filter { $0.metric("slabFoundRate") != nil }.flatMap { frames[$0.shotId] ?? [] }
        if forb.isEmpty {
            out.append(.na("slabFoundRate", "no shot without the slab was scored")); out.append(.na("slabLockedRate", "no shot without the slab was scored"))
            out.append(.na("slabInViewRate", "no shot without the slab was scored"))
        } else {
            out += KitScoreRun.falseSlabMetrics(forb)
        }
        func pooledBall(_ id: String, _ shotsWith: [KitShotScore]) -> KitMetric {
            // a search over the real slab, left in view, cannot see the ball on the floor beside it (`markRealSlab`)
            let runs = shotsWith.filter { $0.metric(id)?.value != nil }.flatMap { (frames[$0.shotId] ?? []).filter {
                $0.ballSearched && !(id == "ballDetectionRate" && $0.onRealSlab) } }
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
        out.append(medianOf("impactHeightError", abs: true, fallback: "no drop scored"))
        out.append(medianOf("rebound", fallback: "no drop scored"))
        // the rebound to bake into the app: the drops' measured rebounds averaged (`KitDropAnalysis.reboundToBake`)
        let drops = ok.compactMap { $0.drop }
        if let b = KitDropAnalysis.reboundToBake(drops) {
            out.append(KitMetric(id: "reboundMeasured", value: b.rebound, note: String(format: "± %.1f points", b.sigma * 100), count: b.count))
        } else {
            out.append(.na("reboundMeasured", reason("reboundMeasured", "no drop scored")))
        }
        out.append(medianOf("landingErrorApp", fallback: "no drop scored"))
        out.append(medianOf("landingErrorRebound", fallback: "no drop scored"))
        out.append(medianOf("launchDirectionError", fallback: "no drop scored"))
        out.append(medianOf("impactClearance", abs: true, fallback: "no drop scored"))
        return out
    }
}

extension KitScorer {
    /// How far the tilt's honest estimate lies from the true normal in its own uncertainty: the 2-D Mahalanobis distance
    /// across the estimate (`HonestTilt`; an honest uncertainty gives a median of 1.18 and a 95th percentile of 2.45).
    /// nil when it cannot be worked out.
    static func honestRatio(truth: Vec3, estimate n: Vec3, covariance C: Mat3) -> Double? {
        let t = truth.normalized, e = t - n * n.dot(t)
        let m2 = e.dot(HonestTilt.information(C, n) * e)
        return m2.isFinite && m2 >= 0 ? m2.squareRoot() : nil
    }
}

// MARK: the slab left in view

extension KitScoreRun {
    /// Where a slab shot had the slab: its lock nearest the per-axis median of its locked frames' centres (world), the
    /// ARKit session (one world) it ran in, and when (uptime, s).
    struct SlabPlace {
        var shotId: String
        var session: String
        var start: Double
        var end: Double
        var pose: SlabPose
    }

    /// The false-slab metrics of a slab-forbidden shot's frames (or of such shots' frames pooled): the share of frames
    /// confirming or locked on anything but the real slab, the share locked on it, and the share found on the real slab
    /// (left in view, `markRealSlab`: not a false slab).
    static func falseSlabMetrics(_ res: [FrameResult]) -> [KitMetric] {
        let n = Double(max(1, res.count))
        let found = res.filter { $0.state != .searching }, wrong = found.filter { !$0.onRealSlab }
        return [KitMetric(id: "slabFoundRate", value: Double(wrong.count) / n, count: res.count),
                KitMetric(id: "slabLockedRate", value: Double(wrong.filter { $0.state == .locked }.count) / n, count: res.count),
                KitMetric(id: "slabInViewRate", value: Double(found.count - wrong.count) / n, count: res.count)]
    }

    /// The slab shots' places (`SlabPlace`): every video shot that may show the slab and locked it.
    func slabPlaces(_ frames: [String: [FrameResult]]) -> [SlabPlace] {
        shots.compactMap { sh -> SlabPlace? in
            guard sh.spec.isVideo, sh.spec.expect.slab != .forbidden, let a = sh.manifest?.arSessionId,
                  let start = sh.frames.first?.time, let end = sh.frames.last?.time else { return nil }
            let poses = (frames[sh.spec.id] ?? []).compactMap { $0.corners.flatMap { SlabPose.fromCorners($0) } }
            guard !poses.isEmpty else { return nil }
            let m = Vec3(KitStats.median(poses.map { $0.center.x }), KitStats.median(poses.map { $0.center.y }),
                         KitStats.median(poses.map { $0.center.z }))
            guard let p = poses.min(by: { $0.center.distance(to: m) < $1.center.distance(to: m) }) else { return nil }
            return SlabPlace(shotId: sh.spec.id, session: a, start: start, end: end, pose: p)
        }
    }

    /// Where the slab was around a shot: the places of the slab shots of the same ARKit session that ran last before it
    /// and first after it (the slab may have been moved further off in time).
    func neighbours(of sh: Shot, in all: [SlabPlace]) -> [SlabPlace] {
        guard let a = sh.manifest?.arSessionId, let start = sh.frames.first?.time, let end = sh.frames.last?.time else { return [] }
        let same = all.filter { $0.session == a && $0.shotId != sh.spec.id }
        let before = same.filter { $0.end <= start }.max { $0.end < $1.end }
        let after = same.filter { $0.start >= end }.min { $0.start < $1.start }
        return [before, after].compactMap { $0 }
    }

    /// How far from the top's plane a find on the real slab may lie (m): half the 52 mm the owner's top stands above
    /// the floor when level, so a find on the floor beside or under the slab fails by a wide margin, and twice the
    /// largest offset measured for the real slab's locks in both of the owner's first kits (12 mm; their centres lay
    /// 6-17 mm from the slab shots' locks). Not the slab's thickness: that is what the owner enters (0.2-4 in), and it
    /// has nothing to do with how far off a lock may be.
    static let realSlabHeightTolerance = 0.026

    /// The ball finder's n/a reason for a slab-forbidden shot that never locked (`scoreShot`); `markRealSlab` words it
    /// again when the shot found the real slab, left in view.
    static let noLockSlabForbidden = "the app looks for the ball only on a lock, and the slab is not in view"

    /// A shot that should not show the slab can still show it: in both of the owner's first kits the ball lay on the floor
    /// a few inches from the slab in the ball shots (s07), and a slab carried away can stay at the picture's edge. A find
    /// there is not a false slab when it lies on the real slab's top, as the slab shots of the same ARKit session just
    /// before and just after it locked it (`neighbours`). A locked frame is judged by its lock's centre (in 3-D), any
    /// other frame with a detection by the ray through that outline's middle cast onto the top (by its line of sight only:
    /// what that pixel shows, not how far away the candidate is), and a confirming frame without one keeps the previous
    /// frame's answer (the candidate it confirms is the same). On the top means inside its outline, in its plane, and
    /// within `realSlabHeightTolerance` of that plane: a lock on the floor (the owner's top stands 52 mm above it) or
    /// anywhere else does not pass, nor does a lock in a world ARKit has since moved (a relocalised session: it matches
    /// neither neighbour, so it stays false). A lock the tracker keeps after the slab has left the picture is still on the
    /// real slab, and the note says so. The forbidden shots' false-slab metrics are then worked out again, with a note
    /// for each shot that found the real slab, and for each shot with finds that could not be checked (no slab shot of
    /// its session locked: they stay false). A ball shot's searches over the real slab are taken out of its
    /// ballDetectionRate (the app looks for a ball only over the slab's top, not one on the floor beside it).
    func markRealSlab(_ scores: inout [KitShotScore], frames: inout [String: [FrameResult]]) {
        let all = slabPlaces(frames), tolerance = KitScoreRun.realSlabHeightTolerance
        func onTop(_ p: Vec3, _ s: SlabPose) -> Bool {
            let (u, v) = s.local(p)
            return abs(u) <= s.halfU && abs(v) <= s.halfV && abs(s.height(of: p)) <= tolerance
        }
        for i in scores.indices where scores[i].metric("slabFoundRate") != nil {
            let id = scores[i].shotId
            guard let sh = shot(id), var res = frames[id], !res.isEmpty else { continue }
            let near = neighbours(of: sh, in: all)
            guard !near.isEmpty else {
                let found = res.filter { $0.state != .searching }.count
                if found > 0 {
                    notes.append("\(id): not checked for the real slab left in view (no slab shot of its ARKit session was scored "
                                 + "and locked just before or after it): its finds (\(found) of \(res.count) frames) count as a false slab.")
                }
                continue
            }
            var last = false, lastPicture = true, seen: Set<String> = [], gaps: [Double] = [], shown = 0
            for k in res.indices {
                guard res[k].state != .searching else { last = false; continue }
                var on: Bool? = nil
                if let c = res[k].corners, c.count == 4 {
                    let m = (c[0] + c[1] + c[2] + c[3]) / 4
                    let hit = near.first { onTop(m, $0.pose) }
                    if let p = hit { seen.insert(p.shotId); gaps.append(m.distance(to: p.pose.center)) }
                    on = hit != nil
                } else if let ray = res[k].findRay {
                    let hit = near.first { p in
                        Plane3(point: p.pose.center, normal: p.pose.normal).intersect(origin: ray.origin, direction: ray.direction)
                            .map { onTop($0, p.pose) } ?? false
                    }
                    if let p = hit { seen.insert(p.shotId) }
                    on = hit != nil
                }
                res[k].onRealSlab = on ?? last
                last = res[k].onRealSlab
                lastPicture = res[k].inPicture ?? lastPicture
                if res[k].onRealSlab && lastPicture { shown += 1 }
            }
            frames[id] = res
            let revised = KitScoreRun.falseSlabMetrics(res)
            scores[i].metrics = scores[i].metrics.map { m in revised.first { $0.id == m.id } ?? m }
            let k = res.filter { $0.onRealSlab }.count
            guard k > 0 else { continue }
            var s = shown == k ? "\(id): the slab was in view: \(k) of \(res.count) frames found it on the real slab, where "
                               : "\(id): \(k) of \(res.count) frames found the real slab (in the picture on \(shown); on the rest the app "
                                 + "kept its lock after the slab left the picture), where "
            s += seen.sorted().joined(separator: " and ") + " locked it"
            if !gaps.isEmpty { s += String(format: " (the lock %.0f mm from there)", KitStats.median(gaps) * 1000) }
            notes.append(s + "; they are not counted as a false slab.")

            // the ball finder over the real slab, left in view
            if !res.contains(where: { $0.state == .locked }) {
                for j in scores[i].metrics.indices where scores[i].metrics[j].value == nil && scores[i].metrics[j].note == KitScoreRun.noLockSlabForbidden {
                    scores[i].metrics[j] = .na(scores[i].metrics[j].id, "the app looks for the ball only on a lock, and it never locked here "
                                               + "(it was confirming the real slab, left in view, on \(k) frames)")
                }
            }
            if sh.spec.expect.ball == .required, let j = scores[i].metrics.firstIndex(where: { $0.id == "ballDetectionRate" }),
               scores[i].metrics[j].value != nil {
                let searched = res.filter { $0.ballSearched }, rest = searched.filter { !$0.onRealSlab }
                if rest.count < searched.count {
                    let above = appBallMinHeight.map { $0 > 0.01 ? String(format: " (%.0f cm or more above it)", $0 * 100) : "" } ?? ""
                    scores[i].metrics[j] = rest.isEmpty
                        ? .na("ballDetectionRate", "the slab was in view and the app locked it: it looks for a ball only over the slab's top"
                              + above + ", not one on the floor beside it")
                        : KitMetric(id: "ballDetectionRate", value: Double(rest.filter { $0.ballFound }.count) / Double(rest.count), count: rest.count)
                }
            }
        }
    }
}
