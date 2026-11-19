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
///   - stray taps, where a finger lands by mistake: `floorSearch`, one on the floor beside the slab on the first frame
///     with the phone's live outline (beside it by 1.1 times its size in the image); `floorConfirm`, the same on the
///     lane's first confirming frame; `floorLocked`, once locked, 0.5 s on and then every 3 s (up to 4), one on the floor
///     0.3 m from the lock (toward the phone, or to a side: the first such place the tracker takes for a slab tap);
///     `slabOnLock`, the same times, one on the locked slab's middle; `ballOff`, the ball lane's tap one ball radius
///     plus half the finger's slack to the right of the ball's middle.
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
        /// the lanes that tap the ball where the truth puts it (run only on shots with a ball truth)
        var needsBallTruth: Bool { self == .ball || self == .ballOff }
    }

    public struct Options {
        /// only these shots (ids, or the start of ids such as "s09")
        public var only: [String]? = nil
        public var ballTruth: [String: BallTruth] = [:]
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
        enum CodingKeys: String, CodingKey {
            case lane, slabTapAt, ballTapAt, dismissAt, timeToLock, lockRate, endTilt, endNormalVsNone, endCentreVsNoneMm,
                 lockTiltMedian, lockTiltError, settledShare, shownTiltError,
                 ballScans, ballFound, ballTrue, ballFalse, ballUnclassified, timeToTrueBall, falseAfterDismiss, noneFalseAfterDismiss, counts,
                 shownTrue, shownFalse, shownTrueBeforeCue, strayTaps, lockedAfterTap, noneLockedAfterTap, falseAfterTap, noneFalseAfterTap
        }
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
        let lanes = options.lanes.compactMap { l -> LaneRun? in
            if l.needsBallTruth && options.ballTruth[sh.spec.id] == nil { return nil }
            return LaneRun(l, settings: settings, options: options)
        }
        let t0 = sh.frames[0].time
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
            for l in lanes {
                var tap: Vec2? = nil
                let locked = l.last?.state == .locked
                switch l.lane {
                case .none: break
                case .slab:
                    if !l.slabTapped, let p = liveMiddle.flatMap(toProcessing) { tap = p; l.slabTapped = true; l.result.slabTapAt = t - t0 }
                case .slabLate:
                    if !l.slabTapped, t - t0 >= options.lateSlabTap {
                        l.slabTapped = true
                        if !locked, let p = liveMiddle.flatMap(toProcessing) { tap = p; l.result.slabTapAt = t - t0 }
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
                            l.result.strayTaps.append(String(format: "%.2f:", t - t0) + l.tracker.tapKind(q, view: vs.processing).rawValue)
                        }
                    }
                case .floorSearch, .floorConfirm:
                    let when = l.lane == .floorSearch || l.last?.state == .confirming
                    if l.strayCount == 0, !locked, when, let live = f.live?.cornerPoints {
                        let pq = live.compactMap(toProcessing)
                        if pq.count == 4 {
                            let mid = pq.reduce(Vec2.zero) { $0 + $1 } / 4
                            let xs = pq.map { $0.x }, ys = pq.map { $0.y }
                            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
                            for off in [Vec2(0, 1.1 * h + 10), Vec2(1.1 * w + 10, 0), Vec2(-1.1 * w - 10, 0), Vec2(0, -1.1 * h - 10)] {
                                let q = mid + off
                                guard vs.processing.intrinsics.contains(q, margin: 8), !SlabTracker.contains(pq, q, slack: 0.6) else { continue }
                                tap = q; l.strayCount = 1; l.firstStray = t
                                l.result.strayTaps.append(String(format: "%.2f:", t - t0) + l.tracker.tapKind(q, view: vs.processing).rawValue)
                                break
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
                            l.result.strayTaps.append(String(format: "%.2f:", t - t0) + l.tracker.tapKind(q, view: vs.processing).rawValue)
                        }
                    }
                }
                let depth: () -> (DepthMap, CameraIntrinsics)? = {
                    guard let u = f.depthURL(shotFolder: sh.folder), let d = try? Data(contentsOf: u), let k = try? KitDepth(data: d),
                          let vk = f.cameraIntrinsics(videoWidth: pipeline.videoWidth, videoHeight: pipeline.videoHeight) else { return nil }
                    return KitFramePipeline.depth(k, video: vk)
                }
                guard let pf = pipeline.frame(image: img, kitFrame: f, tracker: l.tracker, depth: depth, tap: tap) else { continue }
                let out = l.tracker.process(pf.tracker)
                l.last = out
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
        for l in lanes {
            l.result.lockTiltMedian = median(l.lockTilts)
            l.result.settledShare = l.lockTilts.isEmpty ? nil : Double(l.shownTilts.count) / Double(l.lockTilts.count)
            if let tt = trueTilt {
                l.result.lockTiltError = median(l.lockTilts.map { abs($0 - tt) })
                l.result.shownTiltError = median(l.shownTilts.map { abs($0 - tt) })
            }
            l.result.lockRate = l.lateFrames > 0 ? Double(l.lateLocked) / Double(l.lateFrames) : nil
            l.result.counts = l.tracker.counts.filter { $0.key.hasPrefix("tap") || ["locks", "relocks", "lost", "reset"].contains($0.key) }
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
