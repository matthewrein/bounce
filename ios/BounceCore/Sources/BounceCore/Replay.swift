import Foundation

/// Plays a recording through the tracker (the same code the app runs), frame by frame, and compares each frame with
/// what the phone recorded for it.
///
/// A version 2 recording (`RecordingSession.everyFrame`) holds every frame the phone's tracker processed, the settings
/// it ran with, what was done to it between frames (settings changes, resets, world-frame discontinuities, a new
/// tracker), its inputs (taps, the floor height, LiDAR depth where it read it, the ball finder's images) and its result
/// on each frame. The replay does all of the same at the same moments, so with the same detectors it runs exactly what
/// the phone ran, and `ReplayReport` says where it does not. Where the recording lacks an input the phone had (pixels
/// dropped when the disk fell behind), the replay uses the phone's own result for that step (its detector's outlines,
/// its ball) and says so in `Step.substitutions`.
///
/// A version 1 recording holds only frames with images, taken on their own timer: the replay runs the tracker on those
/// alone, so its timing differs from the phone's, and there is nothing to compare with.
public struct ReplayRunner {
    public let reader: RecordingReader
    public init(reader: RecordingReader) { self.reader = reader }

    public struct Step {
        public var frame: RecordedFrame
        public var output: TrackerOutput
        /// where this frame's replay differs from the phone's result (`RecordedOutput.differences`); empty when they
        /// agree or when the recording holds no result for the frame
        public var differences: [String] = []
        /// inputs the replay could not take from the recording as the phone had them, and what it used instead, e.g.
        /// "detections: the phone's (no image recorded)", "ball: rebuilt from the frame's image"
        public var substitutions: [String] = []
        /// the phone's own result for this frame, if recorded
        public var phone: RecordedOutput? { frame.output }

        public init(frame: RecordedFrame, output: TrackerOutput, differences: [String] = [], substitutions: [String] = []) {
            self.frame = frame; self.output = output; self.differences = differences; self.substitutions = substitutions
        }
    }

    /// Where the replay takes a detector's results from.
    public enum Source: Equatable {
        /// run the detector (slab finder / ball finder) given to `replay` on the recorded pixels
        case run
        /// use the phone's own recorded results (the tracker alone is replayed, exactly)
        case recorded
    }

    public struct Options {
        /// the slab detector's outlines: run the given detector on the recorded images, or use the phone's
        public var detections: Source = .run
        /// the ball finder's results: run the given ball finder on the recorded ball images, or use the phone's
        public var ball: Source = .run
        /// When a frame records where its ball image was cut from (`ballIntrinsics`) but not its pixels, rebuild it from
        /// the frame's (smaller) image, the same view and intrinsics with fewer details, and run the ball finder on that
        /// (to try a ball finder on recordings without ball images; its results then differ from the phone's). Off: use
        /// the phone's result for that frame, which keeps the replay exact. Frames without a phone result are always
        /// rebuilt when they can be.
        public var rebuildBallCrops = false
        /// recordings without ball images (version 1): give the ball finder the whole processing frame with its
        /// intrinsics, as replays used to (a different image from the phone's crop); off: no ball image
        public var ballFromProcessingFrame = false
        public var tolerances = ReplayTolerances()
        public init() {}
    }

    public struct Result {
        public var steps: [Step]
        /// the tracker as the replay left it (the last one, if the recording made new ones)
        public var tracker: SlabTracker
        public var report: ReplayReport
    }

    /// The tracker settings a replay uses unless given others: the phone's exact settings (version 2), else those the
    /// app builds from the owner's settings in the recording.
    public var settings: TrackerSettings { reader.session.tracker ?? reader.session.settings.trackerSettings }

    /// Run every frame. `detector` and `ballLocator` default to what the caller supplies (SlabFinder / BallLocator in the
    /// app). Settings come from the recording unless given (then the recording's settings changes are not applied).
    /// `floorY` is used on frames that do not record one.
    public func run(detector: SlabDetecting, ballLocator: BallLocating? = nil, settings: TrackerSettings? = nil,
                    floorY: Double? = nil) throws -> (steps: [Step], tracker: SlabTracker) {
        let r = try replay(detector: detector, ballLocator: ballLocator, settings: settings, floorY: floorY)
        return (r.steps, r.tracker)
    }

    /// Run every frame, compare with the phone, and report.
    public func replay(detector: SlabDetecting, ballLocator: BallLocating? = nil, settings override: TrackerSettings? = nil,
                       floorY: Double? = nil, options: Options = Options()) throws -> Result {
        let session = reader.session
        let det = ReplaySlabDetector(detector)
        det.useRecorded = options.detections == .recorded
        let ball = ReplayBallLocator(ballLocator)
        let hasBall = ballLocator != nil || reader.frames.contains { $0.output?.ballSearched == true }
        func makeTracker(_ s: TrackerSettings) -> SlabTracker { SlabTracker(settings: s, detector: det, ballLocator: hasBall ? ball : nil) }
        var tracker = makeTracker(override ?? settings)
        var steps: [Step] = []
        steps.reserveCapacity(reader.frames.count)
        let blank = ColorFrame(gray: Plane(width: 2, height: 2))

        for f in reader.frames {
            var subs: [String] = []
            // what was done to the phone's tracker before this frame
            for c in f.controls ?? [] {
                switch c.kind {
                case .start: tracker = makeTracker(override ?? c.settings ?? settings)
                case .settings: if override == nil, let s = c.settings { tracker.settings = s }
                case .reset: tracker.reset()
                case .worldDiscontinuity: tracker.noteWorldDiscontinuity(c.reason ?? "world-frame")
                }
            }

            // The processing image, converted (as the app does) only when the tracker will run the detector on it: on a
            // tap or when a detection is due. Other frames get a blank, as in the app.
            let detects = f.tapPoint != nil || tracker.detectionDue(at: f.timestamp)
            let wantImage = f.hasImage && ((detects && options.detections == .run) || (f.ballIntrinsics != nil && f.ballFile == nil)
                                           || (options.ballFromProcessingFrame && f.output == nil))
            let img: YCCImage? = wantImage ? try reader.image(for: f) : nil
            let frame = detects && options.detections == .run ? img?.colorFrame : nil
            det.prepare(hasImage: frame != nil, recorded: f.output?.detections)

            // the ball finder's image
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
            ball.prepare(recorded: nil)
            let phoneRan = f.output?.ballSearched == true
            let phoneBall: (center: Vec3, circle: Vec2, radius: Double)? = f.output?.ball.flatMap { b in
                b.count == 6 ? (f.view.toCamera(Vec3(b[0], b[1], b[2])), Vec2(b[3], b[4]), b[5]) : nil
            }
            let useRecordedBall = options.ball == .recorded || ballLocator == nil
            if !useRecordedBall, let p = try reader.ball(for: f), let k = f.ballIntrinsics {
                ballImage = p; ballK = k
            } else if !useRecordedBall, options.rebuildBallCrops || f.output == nil, let k = f.ballIntrinsics, let im = img {
                ballImage = im.luma.resampled(from: f.intrinsics, to: k); ballK = k
                subs.append("ball: rebuilt from the frame's image")
            } else if phoneRan {
                // the phone's result, handed over through a stand-in image with the crop's intrinsics
                ballImage = Plane(width: 1, height: 1); ballK = f.ballIntrinsics ?? f.intrinsics
                ball.prepare(recorded: .some(phoneBall))
                if options.ball == .run {
                    subs.append(ballLocator == nil ? "ball: the phone's result (no ball finder given)" : "ball: the phone's result (no ball image recorded)")
                }
            } else if !useRecordedBall, options.ballFromProcessingFrame, f.output == nil, let im = img {
                ballImage = im.luma; ballK = f.intrinsics
                subs.append("ball: the whole processing frame (the recording has no ball images)")
            }

            let depth = try reader.depth(for: f)
            let tf = TrackerFrame(timestamp: f.timestamp, view: f.view, frame: frame ?? blank, depth: depth,
                                  depthIntrinsics: depth != nil ? f.depthIntrinsics : nil, ballImage: ballImage, ballIntrinsics: ballK,
                                  tap: f.tapPoint, floorY: f.floorY ?? floorY, trackingNormal: f.trackingNormal)
            let out = tracker.process(tf)
            if let n = det.note { subs.append(n) }
            var diffs: [String] = []
            if let phone = f.output { diffs = RecordedOutput(out).differences(from: phone, tolerances: options.tolerances) }
            steps.append(Step(frame: f, output: out, differences: diffs, substitutions: subs))
        }
        let report = ReplayReport(steps: steps, session: session, settingsGiven: override != nil, skippedLines: reader.skippedLines)
        return Result(steps: steps, tracker: tracker, report: report)
    }
}

/// How a replay went against the phone.
public struct ReplayReport: CustomStringConvertible {
    public var frames: Int
    /// frames with a phone result to compare with, and how many of them differ
    public var compared: Int
    public var differing: Int
    /// the first differing frame (index into the steps) and its differences
    public var firstDifference: Int?
    public var firstDifferences: [String]
    /// differing frames per field ("state", "events", "tilt", "outline", "detector", ...)
    public var differenceCounts: [String: Int]
    /// frames per substitution kind ("detections", "ball")
    public var substitutionCounts: [String: Int]
    /// the largest tilt difference (degrees) and outline distance (pixels) over frames where both had them
    public var maxTiltDifference: Double
    public var maxOutlineDistance: Double
    /// when each first locked (s, the camera's clock)
    public var phoneLockTime: Double?
    public var replayLockTime: Double?
    /// things that limit the comparison (e.g. a version 1 recording)
    public var notes: [String]

    /// the replay matched the phone on every frame it could be compared on
    public var agrees: Bool { compared > 0 && differing == 0 }

    public init(steps: [ReplayRunner.Step], session: RecordingSession, settingsGiven: Bool = false, skippedLines: Int = 0) {
        frames = steps.count
        var compared = 0, differing = 0, first: Int? = nil, counts: [String: Int] = [:], subs: [String: Int] = [:]
        var maxTilt = 0.0, maxOutline = 0.0, phoneLock: Double? = nil, replayLock: Double? = nil
        for (i, s) in steps.enumerated() {
            if let p = s.phone {
                compared += 1
                if phoneLock == nil, p.events?.contains("locked") == true { phoneLock = s.frame.timestamp }
                if let a = p.tiltDegrees, let b = s.output.readouts?.tiltDegrees { maxTilt = max(maxTilt, abs(a - b)) }
                if let a = p.outline, let b = s.output.outline {
                    maxOutline = max(maxOutline, RecordedOutput.maxDistance(a, b.map { [$0.x, $0.y] }))
                }
            }
            if replayLock == nil, s.output.events.contains("locked") { replayLock = s.frame.timestamp }
            if !s.differences.isEmpty {
                differing += 1
                if first == nil { first = i }
                for k in Set(s.differences.map { String($0.prefix { $0 != ":" }) }) { counts[k, default: 0] += 1 }
            }
            for k in Set(s.substitutions.map { String($0.prefix { $0 != ":" }) }) { subs[k, default: 0] += 1 }
        }
        self.compared = compared; self.differing = differing; firstDifference = first
        firstDifferences = first.map { steps[$0].differences } ?? []
        differenceCounts = counts; substitutionCounts = subs
        maxTiltDifference = maxTilt; maxOutlineDistance = maxOutline; phoneLockTime = phoneLock; replayLockTime = replayLock

        var notes: [String] = []
        if compared == 0 { notes.append("the recording holds no results from the phone (version \(session.version)): nothing to compare with") }
        if session.everyFrame != true {
            notes.append("the recording holds only some of the frames the phone processed: the replay's timing (searches, confirmations, losing the lock) cannot match the phone's")
        }
        if let s0 = session.trackerStateAtStart, s0 != .searching,
           !(steps.first?.frame.controls ?? []).contains(where: { $0.kind == .reset || $0.kind == .start }) {
            notes.append("the recording started while the phone's tracker was \(s0.rawValue); the replay starts from searching, so the first moments differ")
        }
        if settingsGiven { notes.append("tracker settings given for the replay, not the phone's") }
        if session.tracker == nil { notes.append("the recording does not hold the tracker's settings: rebuilt from the owner's settings") }
        if skippedLines > 0 { notes.append("\(skippedLines) unreadable line(s) of frames.jsonl left out (cut short?)") }
        self.notes = notes
    }

    public var description: String {
        var s = "replay: \(frames) frames, \(compared) compared with the phone, \(differing) differ"
        if let i = firstDifference { s += "\nfirst difference at step \(i):\n  " + firstDifferences.joined(separator: "\n  ") }
        if !differenceCounts.isEmpty {
            s += "\ndiffering frames by field: " + differenceCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        if !substitutionCounts.isEmpty {
            s += "\nphone results used where the recording lacks pixels: " + substitutionCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        s += String(format: "\nlargest tilt difference %.4f deg, outline %.3f px", maxTiltDifference, maxOutlineDistance)
        s += "\nfirst lock: phone " + (phoneLockTime.map { String(format: "%.3f s", $0) } ?? "-")
            + ", replay " + (replayLockTime.map { String(format: "%.3f s", $0) } ?? "-")
        for n in notes { s += "\nnote: " + n }
        return s
    }
}

/// The detector a replay hands its tracker: the real one on frames with an image, else the phone's recorded outlines.
final class ReplaySlabDetector: SlabDetecting {
    let inner: SlabDetecting
    var useRecorded = false
    private var hasImage = false
    private var recorded: [DetectedOutline]? = nil
    /// what it did on the current frame, when that was not running the real detector on the recorded image
    private(set) var note: String? = nil

    init(_ inner: SlabDetecting) { self.inner = inner }

    func prepare(hasImage: Bool, recorded: [DetectedOutline]?) {
        self.hasImage = hasImage; self.recorded = recorded; note = nil
    }

    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        if !useRecorded && hasImage { return inner.detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near) }
        if let r = recorded {
            if !useRecorded { note = "detections: the phone's (no image recorded)" }
            return r
        }
        note = "detections: none (the phone did not run the detector on this frame" + (hasImage || useRecorded ? ")" : ", and no image)")
        return []
    }
}

/// The ball finder a replay hands its tracker: the real one, or the phone's recorded result for this frame.
final class ReplayBallLocator: BallLocating {
    let inner: BallLocating?
    /// .some(result) to return the phone's result on this frame
    private var recorded: ((center: Vec3, circle: Vec2, radius: Double)?)? = nil

    init(_ inner: BallLocating?) { self.inner = inner }

    func prepare(recorded: ((center: Vec3, circle: Vec2, radius: Double)?)?) { self.recorded = recorded }

    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        if let r = recorded { return r }
        return inner?.locate(image: image, intrinsics: intrinsics, slab: slab, spec: spec, ball: ball, down: down)
    }

    func reset() { inner?.reset() }
}
