import Foundation

/// Simulated taps on a capture kit's real clips (`bounce-score --taps`): every video shot that should show the slab is
/// run through the app's per-frame path (`KitFramePipeline`, a fresh tracker with the app's detectors and settings, as
/// the scorer does) several times over one decode, once per lane, each lane tapping as the owner might:
///   - `none`: no tap (the app as it is without hints);
///   - `slab`: a tap on the slab on the shot's first frame (where the phone's own live outline had the slab's middle,
///     frames.jsonl `live.corners`); `slabLate`: the same tap one second in, only if the slab is not locked by then;
///   - `ball`: once locked, `ballTapDelay` later (before the release cue of a drop) and while the lane does not show the
///     ball, a tap where the ball is (the truth given for the shot: `Options.ballTruth`, a circle in video pixels on one
///     frame, held still in the world);
///   - `dismiss`: a tap on each ring the lane shows that is false (in a shot that expects no ball, any; else one away
///     from the truth), up to three;
///   - stray taps, where a finger lands by mistake: `floorSearch`, one on the floor beside the slab (beside the phone's
///     live outline by 1.1 times its size in the image) on the first frame with that outline that falls between the
///     lane's scheduled searches (not due, and at least `minDetectionGap` after its last run: a real finger lands on an
///     ordinary frame, where a tap that ran a search of its own would add one); `floorConfirm`, the same on the lane's
///     first such confirming frame; `floor05` ... `floor45`, the same at a fixed time (0.5, 1, 1.5, 2, 3, 4.5 s: the
///     first frame from then on with the live outline, if the lane has not locked by then; such a lane that has locked
///     first never taps, and copies the untapped lane's result); `floorLocked`, once locked, 0.5 s on and then every 3 s
///     (up to 4), one on the floor
///     0.3 m from the lock (toward the phone, or to a side: the first such place the tracker takes for a slab tap);
///     `slabOnLock`, the same times, one on the locked slab's middle; `ballOff`, the ball lane's tap one ball radius
///     plus half the finger's slack to the right of the ball's middle;
///   - tap to set the ball (`TrackerSettings.tapSetsBall`; on shots with a ball track, `Options.ballTrack`: the ball's
///     circle on every frame it is seen): `setTrue`, once locked, `ballTapDelay` later (before a drop's release cue),
///     while the lane does not show the true ball, and on a frame with LiDAR depth when the shot has any (the app reads
///     depth on every locked frame; a kit keeps it about once a second), a tap on the ball's middle on that frame;
///     `setOff`, the same a fingertip off it (one radius plus half the finger's slack to the right); `setTrueAny` and
///     `setOffAny`, the same on the first frame they can, with depth or not (a kit has none on most frames: the plane's
///     place then); `slabFarOnLock`, once
///     locked (0.5 s on, on a depth frame when there are any), one tap on the slab's top three quarters of the way from
///     its middle to its far edge (a slab tap out of habit, which the tracker takes for a ball tap: does it set a ball?).
///     Each reports what came of its tap (`SetTapResult`).
/// Per lane: when it locked, how much of the shot it stayed locked (and from the first stray tap on, against the untapped
/// lane over the same frames), its lock's tilt at the end and how far that is from the untapped lane's (a tap must not
/// move the lock), the ball scans (true, false, unclassified), the frames that showed a true or a false ball (and
/// whether a true one was shown in the half second before a drop's release cue), when the first true ball came, and the
/// false balls after the first dismissal or stray tap. Kits are private: the report holds shot ids and numbers only.
public enum KitTapBench {
    /// Where the ball is in a shot: its image circle (video pixels) on one frame (`frame`: frames.jsonl's line index).
    public struct BallTruth: Codable, Equatable {
        public var frame: Int
        public var x: Double
        public var y: Double
        public var r: Double
        public init(frame: Int, x: Double, y: Double, r: Double) { self.frame = frame; self.x = x; self.y = y; self.r = r }
    }

    public enum Lane: String, Codable, CaseIterable {
        case none, slab, slabLate, ball, dismiss, floorSearch, floorConfirm, floorLocked, slabOnLock, ballOff
        case floor05, floor10, floor15, floor20, floor30, floor45
        case setTrue, setOff, slabFarOnLock, setTrueAny, setOffAny
        /// the lanes that tap the ball where the truth puts it (run only on shots with a ball truth)
        var needsBallTruth: Bool { self == .ball || self == .ballOff }
        /// the lanes that tap the ball where its track puts it on the tap's frame (run only on shots with a ball track)
        var needsBallTrack: Bool { [.setTrue, .setOff, .setTrueAny, .setOffAny].contains(self) }
        /// a fixed-time stray tap's time (s from the shot's first frame)
        var strayTime: Double? {
            switch self {
            case .floor05: return 0.5
            case .floor10: return 1
            case .floor15: return 1.5
            case .floor20: return 2
            case .floor30: return 3
            case .floor45: return 4.5
            default: return nil
            }
        }
    }

    public struct Options {
        /// only these shots (ids, or the start of ids such as "s09")
        public var only: [String]? = nil
        public var ballTruth: [String: BallTruth] = [:]
        /// the ball's circle (video pixels) on every frame it is seen, per shot (frames.jsonl line index -> circle)
        public var ballTrack: [String: [Int: BallTruth]] = [:]
        public var lanes: [Lane] = Lane.allCases
        /// the late slab tap: this long after the shot's first frame, if not locked by then (s)
        public var lateSlabTap = 1.0
        /// the ball tap: this long after the lane's lock (s)
        public var ballTapDelay = 0.3
        /// where the frames come from (tests); nil: the kit's video
        public var frames: KitScorer.FrameProvider? = nil
        public var makeDetector: () -> SlabDetecting = { AppDetectors.slab() }
        public var makeBallLocator: () -> BallLocating? = { AppDetectors.ball() }
        public var settings: TrackerSettings = RecordingSettings().trackerSettings
        public var log: ((String) -> Void)? = nil
        /// log every frame's tracker events per lane (to `log`), for tracing what a tap did
        public var traceEvents = false
        /// called with each shot's result as it is done (so a long run keeps what it has)
        public var onShot: ((String, ShotResult) -> Void)? = nil
        public init() {}
        func wants(_ id: String) -> Bool { only.map { $0.contains { id == $0 || id.hasPrefix($0) } } ?? true }
    }

    public struct LaneResult: Codable, Equatable {
        public var lane: Lane
        /// when its taps were made (s from the shot's first frame)
        public var slabTapAt: Double? = nil
        public var ballTapAt: Double? = nil
        public var dismissAt: [Double] = []
        /// the first locked frame (s from the shot's first frame), and the share of frames from 1 s on that were locked
        public var timeToLock: Double? = nil
        public var lockRate: Double? = nil
        /// the lock's tilt on its last locked frame (degrees), and its normal and centre then (world) for comparing lanes
        public var endTilt: Double? = nil
        var endNormal: Vec3? = nil
        var endCentre: Vec3? = nil
        /// against the untapped lane's lock at the end: the normals' angle (degrees) and the centres' distance (mm)
        public var endNormalVsNone: Double? = nil
        public var endCentreVsNoneMm: Double? = nil
        /// the lock's tilt over its locked frames (median, degrees), and against the shot's true tilt where it has one
        /// (median absolute error); the share of locked frames on which the tilt was shown (settled), and the shown tilt's
        /// median absolute error
        public var lockTiltMedian: Double? = nil
        public var lockTiltError: Double? = nil
        public var settledShare: Double? = nil
        public var shownTiltError: Double? = nil
        /// ball scans: in all, finding a ball, of those true / false / not classified (no truth for a shot that expects a
        /// ball, or a drop after its release cue)
        public var ballScans = 0
        public var ballFound = 0
        public var ballTrue = 0
        public var ballFalse = 0
        public var ballUnclassified = 0
        /// the first true ball, s after the lane's ball tap (or its lock, without one)
        public var timeToTrueBall: Double? = nil
        /// false finds from the first dismissal on (this lane), and the untapped lane's over the same frames
        public var falseAfterDismiss: Int? = nil
        public var noneFalseAfterDismiss: Int? = nil
        /// the tracker's tap counters at the end
        public var counts: [String: Int] = [:]
        /// frames on which a ball was shown that was true / false (classified as the scans are); whether a true one was
        /// shown in the half second before a drop's release cue (nil: not a drop)
        public var shownTrue = 0
        public var shownFalse = 0
        public var shownTrueBeforeCue: Bool? = nil
        /// the stray taps made ("t:kind", s from the shot's first frame and what the tracker took each for)
        public var strayTaps: [String] = []
        /// from the first stray tap on: the share of frames locked, and the false balls found (this lane, and the untapped
        /// lane over the same frames)
        public var lockedAfterTap: Double? = nil
        public var noneLockedAfterTap: Double? = nil
        public var falseAfterTap: Int? = nil
        public var noneFalseAfterTap: Int? = nil
        /// a tap-to-set lane's tap (`setTrue`, `setOff`, `slabFarOnLock`): what came of it; and why it waited on frames it
        /// could have tapped on ("shown": the lane showed the true ball; "noTrack": the track has no ball there; "outOfView")
        public var setTap: SetTapResult? = nil
        public var setSkips: [String: Int]? = nil
        enum CodingKeys: String, CodingKey {
            case lane, slabTapAt, ballTapAt, dismissAt, timeToLock, lockRate, endTilt, endNormalVsNone, endCentreVsNoneMm,
                 lockTiltMedian, lockTiltError, settledShare, shownTiltError,
                 ballScans, ballFound, ballTrue, ballFalse, ballUnclassified, timeToTrueBall, falseAfterDismiss, noneFalseAfterDismiss, counts,
                 shownTrue, shownFalse, shownTrueBeforeCue, strayTaps, lockedAfterTap, noneLockedAfterTap, falseAfterTap, noneFalseAfterTap,
                 setTap, setSkips
        }
    }

    /// What came of a tap-to-set lane's tap.
    public struct SetTapResult: Codable, Equatable {
        /// when (s from the shot's first frame), whether its frame had LiDAR depth, and what the tracker took it for
        /// (`TrackerTapKind`)
        public var at: Double
        public var withDepth: Bool
        public var kind: String
        /// "accepted" (a ball found in its box within `tapAcceptSeconds`), "set-lidar", "set-plane", "nothing" (neither
        /// put a ball over the slab at a drop height), "pending" (the shot ended first), or the tap's kind when it was not
        /// a ball tap ("dismissBall": a ring shown there went, "slab")
        public var outcome: String = "pending"
        /// how long after the tap (s)
        public var after: Double? = nil
        /// the accepted ball was the true one (nil: not classified), and its drop height's error against the true one (m)
        public var acceptedTrue: Bool? = nil
        public var acceptedDropError: Double? = nil
        /// the true drop height (m: the track's circle on the tap's frame, its 3-D place from its size, dropped onto the
        /// lane's lock), the set ball's drop height and its error against it (m), and how far the set ball's centre is from
        /// the true one (mm)
        public var trueDrop: Double? = nil
        public var setDrop: Double? = nil
        public var setDropError: Double? = nil
        public var setPositionErrorMm: Double? = nil
        /// both places on the tap's frame, whichever was taken (`TapSetBall.candidates`): their drop height's error (m),
        /// whether each was plausible, and why not
        public var lidarDropError: Double? = nil
        public var lidarPlausible: Bool? = nil
        public var lidarNote: String? = nil
        public var planeDropError: Double? = nil
        public var planePlausible: Bool? = nil
        public var planeNote: String? = nil
        /// the place the tracker takes (`TapSetBall.Candidates.chosen`: the nearer plausible one) and the one LiDAR first
        /// would have taken (`lidarFirst`): where each came from and its drop height's error (m)
        public var chosenSource: String? = nil
        public var chosenDropError: Double? = nil
        public var lidarFirstSource: String? = nil
        public var lidarFirstDropError: Double? = nil
        /// a set ball later replaced by the finder's ball: whether that one was the true ball (nil: not replaced, or not
        /// classified)
        public var replacedBy: String? = nil
        /// frames from the accept or set to a drop's release cue (or the shot's end), and of those the frames whose drop came
        /// from the owner's ball (set, or the accepted one)
        public var framesAfter = 0
        public var framesUsed = 0
    }

    public struct ShotResult: Codable, Equatable {
        public var shotId: String
        public var frames: Int
        public var meanLuma: Double?
        /// the slab position's true tilt (flat-phone), for the shots taken in their position (steps 3-5; later shots may
        /// have been taken after the slab was moved)
        public var trueTilt: Double? = nil
        public var hasBallTruth: Bool
        public var lanes: [LaneResult]
        public var note: String? = nil
    }

    public struct Report: Codable, Equatable {
        public var kitId: String
        public var shots: [ShotResult]
        public init(kitId: String, shots: [ShotResult]) { self.kitId = kitId; self.shots = shots }

        public func json() throws -> Data {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try e.encode(self)
        }

        /// One line per shot and lane.
        public func markdown() -> String {
            func f(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "-" }
            var out = ["### \(kitId): simulated taps", "",
                       "| shot | luma | true tilt | lane | taps (s) | lock at (s) | locked | after stray tap: locked (none), false (none) | lock tilt (err) | shown: share, err | end vs none (deg / mm) | ball scans true/false/other | ball shown true/false (before cue) | first true ball (s) | false after dismiss (none) | tap counts |",
                       "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
            for s in shots {
                for l in s.lanes {
                    var taps: [String] = []
                    if let t = l.slabTapAt { taps.append("slab \(f(t))") }
                    if let t = l.ballTapAt { taps.append("ball \(f(t))") }
                    if !l.dismissAt.isEmpty { taps.append("dismiss " + l.dismissAt.map { f($0) }.joined(separator: ",")) }
                    if !l.strayTaps.isEmpty { taps.append("stray " + l.strayTaps.joined(separator: ",")) }
                    let counts = l.counts.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                    let after = l.lockedAfterTap == nil ? "-" : "\(f(l.lockedAfterTap)) (\(f(l.noneLockedAfterTap))), \(l.falseAfterTap.map(String.init) ?? "-") (\(l.noneFalseAfterTap.map(String.init) ?? "-"))"
                    let cue = l.shownTrueBeforeCue.map { $0 ? " (yes)" : " (no)" } ?? ""
                    out.append("| \(s.shotId) | \(f(s.meanLuma, 0)) | \(f(s.trueTilt)) | \(l.lane.rawValue) | \(taps.joined(separator: "; ")) | \(f(l.timeToLock)) | \(f(l.lockRate)) | \(after) | "
                               + "\(f(l.lockTiltMedian)) (\(f(l.lockTiltError))) | \(f(l.settledShare)), \(f(l.shownTiltError)) | "
                               + "\(f(l.endNormalVsNone)) / \(f(l.endCentreVsNoneMm, 0)) | \(l.ballScans): \(l.ballTrue)/\(l.ballFalse)/\(l.ballUnclassified) | "
                               + "\(l.shownTrue)/\(l.shownFalse)\(cue) | "
                               + "\(f(l.timeToTrueBall)) | \(l.falseAfterDismiss.map(String.init) ?? "-") (\(l.noneFalseAfterDismiss.map(String.init) ?? "-")) | \(counts) |")
                }
                if let n = s.note { out.append("| \(s.shotId) | | | note | \(n) | | | | | | | | | | | |") }
            }
            let sets = shots.flatMap { s in s.lanes.compactMap { l in l.setTap.map { (s.shotId, l.lane, $0) } } }
            if !sets.isEmpty {
                func mm(_ v: Double?) -> String { v.map { String(format: "%+.0f", $0 * 1000) } ?? "-" }
                out += ["", "#### \(kitId): tap to set the ball", "",
                        "| shot | lane | tap at (s) | depth | kind | outcome | after (s) | accepted true | true drop (mm) | set drop (mm) | error (mm) | centre off (mm) | LiDAR: error, ok | plane: error, ok | LiDAR first: source, error | replaced by | used / frames |",
                        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
                for (id, lane, r) in sets {
                    let lid = "\(mm(r.lidarDropError)), \(r.lidarPlausible.map { $0 ? "yes" : "no" } ?? "-")\(r.lidarNote.map { " (\($0))" } ?? "")"
                    let pl = "\(mm(r.planeDropError)), \(r.planePlausible.map { $0 ? "yes" : "no" } ?? "-")\(r.planeNote.map { " (\($0))" } ?? "")"
                    out.append("| \(id) | \(lane.rawValue) | \(f(r.at)) | \(r.withDepth ? "yes" : "no") | \(r.kind) | \(r.outcome) | \(f(r.after)) | "
                               + "\(r.acceptedTrue.map { $0 ? "yes" : "no" } ?? "-") | \(r.trueDrop.map { String(format: "%.0f", $0 * 1000) } ?? "-") | "
                               + "\(r.setDrop.map { String(format: "%.0f", $0 * 1000) } ?? "-") | \(mm(r.setDropError)) | \(r.setPositionErrorMm.map { String(format: "%.0f", $0) } ?? "-") | "
                               + "\(lid) | \(pl) | \(r.lidarFirstSource ?? "-"), \(mm(r.lidarFirstDropError)) | \(r.replacedBy ?? "-") | \(r.framesUsed) / \(r.framesAfter) |")
                }
            }
            return out.joined(separator: "\n")
        }
    }

    /// One lane's run through a shot.
    final class LaneRun {
        let lane: Lane
        let tracker: SlabTracker
        let locator: BallLocating?
        var result: LaneResult
        var last: TrackerOutput? = nil
        var lockTime: Double? = nil
        var slabTapped = false, ballTapped = false
        var lateFrames = 0, lateLocked = 0
        /// per frame from the first dismissal: whether the frame's scan found a false ball
        var falseAt: [Double] = []
        /// the lock's tilt on each locked frame, and the shown (settled) tilt
        var lockTilts: [Double] = [], shownTilts: [Double] = []
        /// stray taps made, when the next may be, when the first was; every frame's time and whether it was locked
        var strayCount = 0, nextStray: Double? = nil, firstStray: Double? = nil
        var lockedAt: [(Double, Bool)] = []
        /// when the lane's detector last ran (a search or a re-check)
        var lastRun = -Double.infinity
        /// a lane that can no longer tap and has not tapped (`slabLate` locked by its time, a fixed-time stray lane locked
        /// before its time): its tracker has had exactly the untapped lane's frames, so it stops and copies that lane's
        /// result at the end
        var dormant = false
        /// a tap-to-set lane: its tap's frame, the true ball's centre then (world), and when its tap was accepted or set
        var setTapFrame: Int? = nil
        var setTrueCentre: Vec3? = nil
        var setResolvedAt: Double? = nil
        init(_ lane: Lane, settings: TrackerSettings, options: Options) {
            self.lane = lane
            locator = options.makeBallLocator()
            tracker = SlabTracker(settings: settings, detector: options.makeDetector(), ballLocator: locator)
            result = LaneResult(lane: lane)
        }
    }

    public static func run(kitFolder: URL, options: Options = Options()) throws -> Report {
        var so = KitScorer.Options()
        so.log = options.log
        let run = KitScoreRun(folder: kitFolder, options: so)
        guard let data = try? Data(contentsOf: kitFolder.appendingPathComponent(KitStore.manifestFile)),
              let m = try? KitJSON.decode(KitManifest.self, from: data), m.format == KitManifest.formatName else { throw KitScoreError.notAKit }
        run.manifest = m
        guard let p = KitPlan.named(m.planId, timeScale: m.timeScale ?? 1) else { throw KitScoreError.unknownPlan(m.planId) }
        run.plan = p
        run.loadShots()
        var shots: [ShotResult] = []
        for sh in run.shots where sh.spec.isVideo && sh.spec.expect.slab != .forbidden && options.wants(sh.spec.id) {
            guard sh.loadError == nil, !sh.frames.isEmpty, let man = sh.manifest else { continue }
            options.log?("taps: \(m.kitId) \(sh.spec.id)")
            let truth = sh.spec.step <= 5 ? m.record(sh.spec.id)?.positionId.flatMap { m.position($0)?.groundTruth }.flatMap { $0.isUsable ? $0.tiltDegrees : nil } : nil
            do { shots.append(try runShot(sh, manifest: man, cue: run.cue(sh), trueTilt: truth, options: options)) } catch {
                shots.append(ShotResult(shotId: sh.spec.id, frames: sh.frames.count, meanLuma: nil, hasBallTruth: false, lanes: [],
                                        note: "not run: " + KitScorer.describe(error)))
            }
            options.onShot?(m.kitId, shots[shots.count - 1])
        }
        return Report(kitId: m.kitId, shots: shots)
    }

    static func runShot(_ sh: KitScoreRun.Shot, manifest m: KitShotManifest, cue: Double?, trueTilt: Double?, options: Options) throws -> ShotResult {
        let input = KitScorer.ShotInput(shotId: sh.spec.id, folder: sh.folder, manifest: m, frames: sh.frames)
        let source = try (options.frames ?? KitScorer.videoFrames)(input)
        defer { source.close() }
        let pipeline = KitFramePipeline(videoWidth: source.width, videoHeight: source.height, cameraFormat: m.cameraFormat)
        let settings = options.settings
        let track = options.ballTrack[sh.spec.id] ?? [:]
        let hasDepth = sh.frames.contains { $0.depthURL(shotFolder: sh.folder) != nil }
        let lanes = options.lanes.compactMap { l -> LaneRun? in
            if l.needsBallTruth && options.ballTruth[sh.spec.id] == nil { return nil }
            if l.needsBallTrack && track.isEmpty { return nil }
            return LaneRun(l, settings: settings, options: options)
        }
        let t0 = sh.frames[0].time
        // (a lane that can no longer tap copies the untapped lane's result: only when that lane runs)
        let canRest = lanes.contains { $0.lane == .none }
        let expectsBall = sh.spec.expect.ball
        // the true ball (world), from its circle on its frame
        var trueBall: Vec3? = nil
        if let b = options.ballTruth[sh.spec.id], sh.frames.indices.contains(b.frame), let vs = pipeline.views(sh.frames[b.frame]),
           let c = Bounce.ballCenter(pixel: Vec2(b.x, b.y), radiusPixels: b.r, intrinsics: vs.video.intrinsics, ball: settings.ball) {
            trueBall = vs.video.toWorld(c)
        }
        /// a ball the lane shows (world centre) on a frame (video camera): true, false, or not classified (nil)
        func classify(_ w: Vec3, _ video: CameraView, _ t: Double) -> Bool? {
            if let c = cue, t >= c - 0.1 { return nil }
            if expectsBall == .forbidden { return false }
            guard let tb = trueBall, let p = video.project(world: tb), let q = video.project(world: w),
                  let r = Bounce.imageRadius(ballCenter: video.toCamera(tb), intrinsics: video.intrinsics, ball: settings.ball) else { return nil }
            return q.distance(to: p) <= max(1.5 * r, r + 6)
        }
        /// the ball's track on frame i (the nearest frame within two that has it)
        func trackAt(_ i: Int) -> BallTruth? {
            for d in [0, -1, 1, -2, 2] { if let b = track[i + d] { return b } }
            return nil
        }
        /// the tracked ball's centre (world) on frame i, from its circle's place and size (video camera)
        func trackCentre(_ i: Int, _ video: CameraView) -> Vec3? {
            guard let b = trackAt(i), let c = Bounce.ballCenter(pixel: Vec2(b.x, b.y), radiusPixels: b.r, intrinsics: video.intrinsics, ball: settings.ball) else { return nil }
            return video.toWorld(c)
        }
        /// a ball (world centre) against the track on frame i: true, false, or nil (no track there)
        func classifyTrack(_ w: Vec3, _ video: CameraView, _ i: Int) -> Bool? {
            guard let b = trackAt(i), let q = video.project(world: w) else { return nil }
            return q.distance(to: Vec2(b.x, b.y)) <= max(1.5 * b.r, b.r + 6)
        }
        var lumaSum = 0.0
        for (i, f) in sh.frames.enumerated() {
            guard let img = try source.next() else { throw KitScoreError.videoEnded(at: i, of: sh.frames.count) }
            lumaSum += f.luma ?? 0
            guard let vs = pipeline.views(f) else { continue }
            let t = f.time
            // the phone's own live outline, for the slab tap's place (video pixels -> processing pixels)
            let liveMiddle: Vec2? = f.live?.cornerPoints.map { q in q.reduce(Vec2.zero) { $0 + $1 } / 4 }
            func toProcessing(_ p: Vec2) -> Vec2? {
                let ray = vs.video.intrinsics.ray(p)
                guard let q = vs.processing.intrinsics.project(ray), vs.processing.intrinsics.contains(q, margin: 2) else { return nil }
                return q
            }
            /// the floor beside the phone's live outline (processing pixels), on the first side that is in view and off it
            func floorBeside() -> Vec2? {
                guard let live = f.live?.cornerPoints else { return nil }
                let pq = live.compactMap(toProcessing)
                guard pq.count == 4 else { return nil }
                let mid = pq.reduce(Vec2.zero) { $0 + $1 } / 4
                let xs = pq.map { $0.x }, ys = pq.map { $0.y }
                let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
                for off in [Vec2(0, 1.1 * h + 10), Vec2(1.1 * w + 10, 0), Vec2(-1.1 * w - 10, 0), Vec2(0, -1.1 * h - 10)] {
                    let q = mid + off
                    if vs.processing.intrinsics.contains(q, margin: 8), !SlabTracker.contains(pq, q, slack: 0.6) { return q }
                }
                return nil
            }
            let depth: () -> (DepthMap, CameraIntrinsics)? = {
                guard let u = f.depthURL(shotFolder: sh.folder), let d = try? Data(contentsOf: u), let k = try? KitDepth(data: d),
                      let vk = f.cameraIntrinsics(videoWidth: pipeline.videoWidth, videoHeight: pipeline.videoHeight) else { return nil }
                return KitFramePipeline.depth(k, video: vk)
            }
            let frameHasDepth = f.depthURL(shotFolder: sh.folder) != nil
            for l in lanes where !l.dormant {
                var tap: Vec2? = nil
                let locked = l.last?.state == .locked
                /// a tap-to-set lane's tap at q on this frame: its kind, and both places for it against the true ball (`tc`)
                func startSetTap(_ q: Vec2, trueCentre tc: Vec3?) {
                    tap = q; l.ballTapped = true; l.setTapFrame = i; l.setTrueCentre = tc
                    var r = SetTapResult(at: t - t0, withDepth: frameHasDepth, kind: l.tracker.tapKind(q, view: vs.processing).rawValue)
                    if let s = l.tracker.slab {
                        let d = depth()
                        let c = TapSetBall.candidates(tap: q, view: vs.processing, depth: d?.0, depthIntrinsics: d?.1, slab: s, spec: settings.spec,
                                                      ball: settings.ball, rule: settings.launchRule, maxHeight: settings.tapSetMaxHeight,
                                                      depthTolerance: settings.depthMaxOffsetFraction)
                        let truth = tc.flatMap { TapSetBall.dropHeight(center: $0, slab: s, spec: settings.spec, ball: settings.ball,
                                                                      down: ARKitConvention.worldDown, rule: settings.launchRule) }
                        r.trueDrop = truth
                        if let x = c.lidar { r.lidarPlausible = c.lidarPlausible; if let h = truth, x.dropHeight.isFinite { r.lidarDropError = x.dropHeight - h } }
                        if let x = c.plane { r.planePlausible = c.planePlausible; if let h = truth, x.dropHeight.isFinite { r.planeDropError = x.dropHeight - h } }
                        r.lidarNote = c.slabUnderFinger ? "the slab's top under the finger" : c.lidarNote; r.planeNote = c.planeNote
                        r.chosenSource = c.chosen?.source.rawValue; r.lidarFirstSource = c.lidarFirst?.source.rawValue
                        if let h = truth { r.chosenDropError = c.chosen.map { $0.dropHeight - h }; r.lidarFirstDropError = c.lidarFirst.map { $0.dropHeight - h } }
                    }
                    l.result.setTap = r
                    l.result.ballTapAt = t - t0
                }
                // a frame the lane's schedule does not search on, far enough from its last run that a tap could have run one
                let offSchedule = !l.tracker.detectionDue(at: t) && t - l.lastRun >= settings.minDetectionGap
                /// "t:kind", and "/off" for a tap between the scheduled searches
                func strayNote(_ q: Vec2) -> String {
                    String(format: "%.2f:", t - t0) + l.tracker.tapKind(q, view: vs.processing).rawValue + (!locked && offSchedule ? "/off" : "")
                }
                switch l.lane {
                case .none: break
                case .slab:
                    if !l.slabTapped, let p = liveMiddle.flatMap(toProcessing) { tap = p; l.slabTapped = true; l.result.slabTapAt = t - t0 }
                case .slabLate:
                    if !l.slabTapped, t - t0 >= options.lateSlabTap {
                        l.slabTapped = true
                        if !locked, let p = liveMiddle.flatMap(toProcessing) { tap = p; l.result.slabTapAt = t - t0 } else if locked { l.dormant = canRest }
                    }
                case .ball:
                    // (only while the app does not show the ball: nobody taps a ball the app already has)
                    let shown = l.last?.ball.flatMap { classify($0.center, vs.video, t) } == true
                    if !l.ballTapped, locked, !shown, let lt = l.lockTime, t - lt >= options.ballTapDelay, cue.map({ t < $0 - 0.3 }) ?? true,
                       let tb = trueBall, let p = vs.processing.project(world: tb), vs.processing.intrinsics.contains(p, margin: 2) {
                        tap = p; l.ballTapped = true; l.result.ballTapAt = t - t0
                    }
                case .dismiss:
                    if locked, l.result.dismissAt.count < 3, let b = l.last?.ball, classify(b.center, vs.video, t) == false,
                       let p = vs.processing.project(world: b.center) {
                        tap = p; l.result.dismissAt.append(t - t0)
                    }
                case .floorLocked, .slabOnLock:
                    if locked, let lt = l.lockTime, l.strayCount < 4, t - lt >= 0.5, t >= (l.nextStray ?? 0), let s = l.last?.slab {
                        var pick: Vec2? = nil
                        if l.lane == .slabOnLock {
                            pick = vs.processing.project(world: s.center).flatMap { vs.processing.intrinsics.contains($0, margin: 4) ? $0 : nil }
                        } else {
                            // the floor (the slab's top is 52 mm over it when level) 0.3 m from the lock's middle
                            var fw = vs.processing.position - s.center; fw = Vec3(fw.x, 0, fw.z)
                            if fw.length > 1e-6 {
                                fw = fw / fw.length
                                let side = Vec3(-fw.z, 0, fw.x)
                                for dir in [fw, side, side * -1, fw * -1] {
                                    let w = Vec3(s.center.x, s.center.y - 0.052, s.center.z) + dir * 0.30
                                    guard let q = vs.processing.project(world: w), vs.processing.intrinsics.contains(q, margin: 8) else { continue }
                                    if let o = l.last?.outline, SlabTracker.contains(o, q, slack: 0.6) { continue }
                                    if l.tracker.tapKind(q, view: vs.processing) != .slab { continue }
                                    pick = q; break
                                }
                            }
                        }
                        if let q = pick {
                            tap = q; l.strayCount += 1; l.nextStray = t + 3
                            if l.firstStray == nil { l.firstStray = t }
                            l.result.strayTaps.append(strayNote(q))
                        }
                    }
                case .floorSearch, .floorConfirm:
                    let when = l.lane == .floorSearch || l.last?.state == .confirming
                    if l.strayCount == 0, !locked, when, offSchedule, let q = floorBeside() {
                        tap = q; l.strayCount = 1; l.firstStray = t
                        l.result.strayTaps.append(strayNote(q))
                    }
                case .floor05, .floor10, .floor15, .floor20, .floor30, .floor45:
                    if l.strayCount == 0, !l.slabTapped, let at = l.lane.strayTime, t - t0 >= at {
                        if locked {
                            // (locked first: this lane never taps; `slabTapped` marks it done)
                            l.slabTapped = true; l.dormant = canRest
                        } else if let q = floorBeside() {
                            tap = q; l.strayCount = 1; l.firstStray = t
                            l.result.strayTaps.append(strayNote(q))
                        }
                    }
                case .setTrue, .setOff, .setTrueAny, .setOffAny:
                    // (only while the app does not show the true ball; on a frame with depth when the shot has any, but for
                    // the "Any" lanes)
                    let any = l.lane == .setTrueAny || l.lane == .setOffAny
                    if !l.ballTapped, locked, let lt = l.lockTime, t - lt >= options.ballTapDelay, cue.map({ t < $0 - 0.3 }) ?? true,
                       any || frameHasDepth || !hasDepth {
                        func skip(_ why: String) { l.result.setSkips = (l.result.setSkips ?? [:]).merging([why: 1], uniquingKeysWith: +) }
                        let K = vs.processing.intrinsics
                        if l.last?.ball.flatMap({ classifyTrack($0.center, vs.video, i) }) == true {
                            skip("shown")
                        } else if let tc = trackCentre(i, vs.video) {
                            if let p = vs.processing.project(world: tc),
                               let r = Bounce.imageRadius(ballCenter: vs.processing.toCamera(tc), intrinsics: K, ball: settings.ball) {
                                let off = l.lane == .setOff || l.lane == .setOffAny
                                let q = off ? p + Vec2(r + 0.5 * TapHints.slack(fraction: settings.tapSlackFraction, width: K.width, height: K.height), 0) : p
                                if K.contains(q, margin: 2) { startSetTap(q, trueCentre: tc) } else { skip("outOfView") }
                            } else { skip("outOfView") }
                        } else {
                            skip("noTrack")
                        }
                    }
                case .slabFarOnLock:
                    // a tap on the slab's top, three quarters of the way to its far edge (away from the phone)
                    if !l.ballTapped, locked, let lt = l.lockTime, t - lt >= 0.5, frameHasDepth || !hasDepth, let s = l.last?.slab {
                        let away = (s.center - vs.processing.position).rejecting(s.normal)
                        if away.length > 1e-6 {
                            let w = s.center + away.normalized * (0.75 * min(s.halfU, s.halfV))
                            if let q = vs.processing.project(world: w), vs.processing.intrinsics.contains(q, margin: 4) {
                                startSetTap(q, trueCentre: nil)
                                l.result.strayTaps.append(strayNote(q))
                            }
                        }
                    }
                case .ballOff:
                    // the ball lane's tap, a fingertip off the ball's middle
                    let shown = l.last?.ball.flatMap { classify($0.center, vs.video, t) } == true
                    if !l.ballTapped, locked, !shown, let lt = l.lockTime, t - lt >= options.ballTapDelay, cue.map({ t < $0 - 0.3 }) ?? true,
                       let tb = trueBall, let p = vs.processing.project(world: tb),
                       let r = Bounce.imageRadius(ballCenter: vs.processing.toCamera(tb), intrinsics: vs.processing.intrinsics, ball: settings.ball) {
                        let K = vs.processing.intrinsics
                        let q = p + Vec2(r + 0.5 * TapHints.slack(fraction: settings.tapSlackFraction, width: K.width, height: K.height), 0)
                        if K.contains(q, margin: 2) {
                            tap = q; l.ballTapped = true; l.result.ballTapAt = t - t0
                            l.result.strayTaps.append(strayNote(q))
                        }
                    }
                }
                if l.dormant { continue }
                guard let pf = pipeline.frame(image: img, kitFrame: f, tracker: l.tracker, depth: depth, tap: tap) else { continue }
                let out = l.tracker.process(pf.tracker)
                l.last = out
                // a tap-to-set lane: what came of its tap
                if var r = l.result.setTap, let ti = l.setTapFrame {
                    let since = t - (t0 + r.at)
                    if i == ti, let k = out.tap?.kind, k != .ball { r.outcome = k.rawValue; r.after = 0 }
                    if out.events.contains("tap-ball-accepted") {
                        r.outcome = "accepted"; r.after = since; l.setResolvedAt = t
                        r.acceptedTrue = out.ball.flatMap { classifyTrack($0.center, pf.video, i) }
                        if let b = out.ball, let s = out.slab, let tc = l.setTrueCentre,
                           let h = TapSetBall.dropHeight(center: tc, slab: s, spec: settings.spec, ball: settings.ball, down: ARKitConvention.worldDown, rule: settings.launchRule),
                           let a = TapSetBall.dropHeight(center: b.center, slab: s, spec: settings.spec, ball: settings.ball, down: ARKitConvention.worldDown, rule: settings.launchRule) {
                            r.acceptedDropError = a - h
                        }
                    }
                    if out.events.contains("tap-ball-set"), let b = l.tracker.setBall, let s = out.slab {
                        r.outcome = "set-" + b.source.rawValue; r.after = since; l.setResolvedAt = t
                        r.setDrop = TapSetBall.dropHeight(center: b.center, slab: s, spec: settings.spec, ball: settings.ball,
                                                          down: ARKitConvention.worldDown, rule: settings.launchRule)
                        if let tc = l.setTrueCentre {
                            r.setPositionErrorMm = b.center.distance(to: tc) * 1000
                            if let h = TapSetBall.dropHeight(center: tc, slab: s, spec: settings.spec, ball: settings.ball, down: ARKitConvention.worldDown,
                                                             rule: settings.launchRule), let d = r.setDrop {
                                r.setDropError = d - h
                            }
                        }
                    }
                    if out.events.contains("tap-ball-set-none") { r.outcome = "nothing"; r.after = since }
                    if out.events.contains("tap-set-replaced"), let b = out.ball {
                        r.replacedBy = classifyTrack(b.center, pf.video, i).map { $0 ? "true ball" : "false ball" } ?? "unclassified"
                    }
                    if let from = l.setResolvedAt, t >= from, cue.map({ t < $0 }) ?? true {
                        r.framesAfter += 1
                        if out.readouts?.dropFromBall == true && (out.setBall != nil || out.ballUserConfirmed) { r.framesUsed += 1 }
                    }
                    l.result.setTap = r
                }
                if out.detectionKind != nil { l.lastRun = t }
                if options.traceEvents, !out.events.isEmpty || tap != nil {
                    options.log?(String(format: "trace %@ %@ t=%.2f %@ seed=%@ ", sh.spec.id, l.lane.rawValue, t - t0, "\(out.state)",
                                        l.tracker.seedPoint != nil ? "y" : "n") + out.events.joined(separator: ","))
                }
                if out.state == .locked {
                    if l.lockTime == nil { l.lockTime = t; l.result.timeToLock = t - t0 }
                    if let s = out.slab {
                        l.result.endTilt = Units.degrees(s.tilt(down: ARKitConvention.worldDown))
                        l.result.endNormal = s.normal; l.result.endCentre = s.center
                        l.lockTilts.append(l.result.endTilt!)
                    }
                    if out.angleSettled, let r = out.readouts { l.shownTilts.append(r.tiltDegrees) }
                }
                if t - t0 >= 1 { l.lateFrames += 1; if out.state == .locked { l.lateLocked += 1 } }
                l.lockedAt.append((t, out.state == .locked))
                if let b = out.ball {
                    switch classify(b.center, pf.video, t) {
                    case .some(true):
                        l.result.shownTrue += 1
                        if let c = cue, t >= c - 0.6 { l.result.shownTrueBeforeCue = true }
                    case .some(false): l.result.shownFalse += 1
                    case .none: break
                    }
                }
                if out.ballSearched {
                    l.result.ballScans += 1
                    let heldOver = out.ball != nil && ((l.locator as? BallLocator)?.current?.missedUpdates ?? 0) > 0
                    if let b = out.ball, !heldOver {
                        l.result.ballFound += 1
                        switch classify(b.center, pf.video, t) {
                        case .some(true):
                            l.result.ballTrue += 1
                            if l.result.timeToTrueBall == nil, let ref = l.result.ballTapAt.map({ $0 + t0 }) ?? l.lockTime {
                                if t >= ref { l.result.timeToTrueBall = t - ref }
                            }
                        case .some(false): l.result.ballFalse += 1; l.falseAt.append(t)
                        case .none: l.result.ballUnclassified += 1
                        }
                    }
                }
            }
        }
        #if os(macOS) || os(Linux)
        if let dec = source as? KitVideoDecoder { try dec.finish() }
        #endif
        let none = lanes.first { $0.lane == .none }
        func median(_ v: [Double]) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted(), k = s.count
            return k % 2 == 1 ? s[k / 2] : (s[k / 2 - 1] + s[k / 2]) / 2
        }
        // a dormant lane ran exactly as the untapped one until it stopped, and would have after: its result is that lane's
        for l in lanes where l.dormant {
            guard let n = none else { continue }
            l.result = n.result; l.result.lane = l.lane
            l.lockTilts = n.lockTilts; l.shownTilts = n.shownTilts; l.lateFrames = n.lateFrames; l.lateLocked = n.lateLocked
            l.lockedAt = n.lockedAt; l.falseAt = n.falseAt; l.lockTime = n.lockTime
        }
        for l in lanes {
            l.result.lockTiltMedian = median(l.lockTilts)
            l.result.settledShare = l.lockTilts.isEmpty ? nil : Double(l.shownTilts.count) / Double(l.lockTilts.count)
            if let tt = trueTilt {
                l.result.lockTiltError = median(l.lockTilts.map { abs($0 - tt) })
                l.result.shownTiltError = median(l.shownTilts.map { abs($0 - tt) })
            }
            l.result.lockRate = l.lateFrames > 0 ? Double(l.lateLocked) / Double(l.lateFrames) : nil
            l.result.counts = (l.dormant ? none?.tracker ?? l.tracker : l.tracker).counts
                .filter { $0.key.hasPrefix("tap") || ["locks", "relocks", "lost", "reset"].contains($0.key) }
            if let n = none, l.lane != .none, let a = l.result.endNormal, let b = n.result.endNormal {
                l.result.endNormalVsNone = Units.degrees(a.angle(to: b))
            }
            if let n = none, l.lane != .none, let a = l.result.endCentre, let b = n.result.endCentre {
                l.result.endCentreVsNoneMm = a.distance(to: b) * 1000
            }
            if cue != nil, l.result.shownTrueBeforeCue == nil { l.result.shownTrueBeforeCue = false }
            if let fs = l.firstStray {
                let a = l.lockedAt.filter { $0.0 >= fs }
                if !a.isEmpty { l.result.lockedAfterTap = Double(a.filter { $0.1 }.count) / Double(a.count) }
                if let n = none {
                    let b = n.lockedAt.filter { $0.0 >= fs }
                    if !b.isEmpty { l.result.noneLockedAfterTap = Double(b.filter { $0.1 }.count) / Double(b.count) }
                    l.result.noneFalseAfterTap = n.falseAt.filter { $0 >= fs }.count
                }
                l.result.falseAfterTap = l.falseAt.filter { $0 >= fs }.count
            }
            if let d0 = l.result.dismissAt.first {
                let from = t0 + d0
                l.result.falseAfterDismiss = l.falseAt.filter { $0 >= from }.count
                l.result.noneFalseAfterDismiss = none.map { $0.falseAt.filter { $0 >= from }.count }
            }
        }
        return ShotResult(shotId: sh.spec.id, frames: sh.frames.count, meanLuma: lumaSum / Double(sh.frames.count), trueTilt: trueTilt,
                          hasBallTruth: trueBall != nil, lanes: lanes.map { $0.result })
    }
}
