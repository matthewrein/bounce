import Foundation

/// Decides, frame by frame, whether the app processes a camera frame or skips it because processing has fallen behind,
/// and keeps the numbers that show how the frames came and went (`report`, in the diagnostics JSON).
///
/// ARKit hands each frame to the session's delegate on the app's processing queue some time after the camera captured
/// it: its own pipeline latency (often more than one 60 fps frame), plus however long the frame waited in the queue
/// while earlier frames were processed. Only the waiting is the app's to cut. So a frame counts as late when its
/// latency (handled time minus capture time) exceeds the normal latency by more than about one frame interval: then
/// a newer frame has been captured since and is most likely already waiting behind it, and processing this one would
/// only put the app further behind. The normal latency is estimated from the frames themselves, which also absorbs any
/// constant offset between the two clocks: a low percentile of the latencies, over the last couple of seconds, of the
/// frames that reached an idle handler (the previous frame's handling had ended before this one was handed over, so it
/// did not wait in the queue: its latency is ARKit's own). Frames that waited cannot be used: once processing is
/// chronically slower than the camera every frame waits, and an estimate from their latencies would settle wherever the
/// skipping holds the queue, however deep. Without an idle frame in the window the last such estimate is kept (a stale
/// low one makes the rule skip more, which frees the handler and brings idle frames back); before there was ever one,
/// the smallest latency of the frames processed is used.
///
/// Progress is guaranteed: a frame is always processed when no frame has been for `Rule.maxUnprocessedSeconds` of
/// camera time, and nothing is skipped until there are enough recent frames to judge by, so a wrong estimate (or a
/// clock that jumps) can delay frames by at most that long, never stop processing.
///
/// Use (on the processing queue, for every frame the camera delivers):
///
///     let start = CACurrentMediaTime()
///     let decision = pacer.frameArrived(captureTime: frame.timestamp, now: start,
///                                       nominalInterval: 1 / Double(videoFormat.framesPerSecond))
///     guard decision == .process else { return }       // nothing else touches a skipped frame
///     ... process it ...
///     pacer.frameProcessed(captureTime: frame.timestamp, seconds: CACurrentMediaTime() - start, output: trackerOutput)
///
/// `seconds` must cover the whole handling, from `start` until the handler returns (it tells the pacer when the handler
/// became free, which is how it knows which frames waited).
///
/// Both clocks are the system's uptime clock (ARFrame.timestamp and CACurrentMediaTime are). Pure: it reads no clock
/// itself, so tests drive it with made-up times.
public struct FramePacer {
    /// The skip rule's constants.
    public struct Rule: Codable, Equatable {
        /// a frame is late when its latency exceeds the baseline by more than this many frame intervals (about one frame:
        /// by then the next frame has been captured and has normally reached the queue)
        public var lateIntervals = 1.0
        /// the baseline latency: this percentile (0-1) of the latencies of the frames that reached an idle handler over
        /// the last `baselineSeconds` of camera time (low, against a delivery that came early by a glitch)
        public var baselinePercentile = 0.1
        public var baselineSeconds = 2.0
        /// a frame reached an idle handler when the previous frame's handling ended at least this long (s) before it
        /// was handed over
        public var idleSeconds = 0.002
        /// no frame is skipped until this many frames have been received (after a start or a clock jump)
        public var minBaselineFrames = 10
        /// a frame is processed, late or not, when no frame has been processed for this long (camera time, s): the
        /// tracker never goes longer without a frame, whatever the estimate says
        public var maxUnprocessedSeconds = 0.25
        /// a step between consecutive capture times larger than this many nominal intervals is a gap: frames the camera
        /// (ARKit) never delivered
        public var gapIntervals = 1.5
        /// the window of the recent statistics (camera time, s)
        public var recentSeconds = 10.0
        public init() {}
    }

    public enum Decision: String, Codable { case process, skip }

    public var rule: Rule

    // the baseline's window: (capture time, latency, it reached an idle handler, it was processed)
    private var window: [(c: Double, age: Double, idle: Bool, processed: Bool)] = []
    private var recentDeltas: [Double] = []
    private var lastCapture: Double?
    private var lastProcessedCapture: Double?
    private var nominalInterval: Double?
    /// when the handler became free (the `now` clock), and when the frame being processed was handed over
    private var handlerFreeAt: Double?
    private var processingSince: Double?
    /// the last baseline from idle frames
    private var idleBaseline: Double?
    private var lastBaseline: Double?
    private var lastThreshold: Double?
    private var consecutiveSkips = 0

    // statistics
    private struct Arrival { var c: Double; var ageMs: Double; var skipped: Bool; var forced: Bool }
    private struct Processed { var c: Double; var ms: Double; var overran: Bool; var search: Bool; var recheck: Bool; var ball: Bool }
    private struct Gap { var c: Double; var missing: Int }
    private var arrivals: [Arrival] = []
    private var processed: [Processed] = []
    private var gaps: [Gap] = []
    /// spans between consecutive processed frames (camera time): (capture time of the later one, span in ms)
    private var unprocessed: [(c: Double, ms: Double)] = []
    private var total = Totals()

    private struct Totals {
        var first: Double?, last: Double?
        var received = 0, processed = 0, skipped = 0, forced = 0, gaps = 0, missing = 0, overruns = 0
        var searches = 0, rechecks = 0, balls = 0
        var latency = Histogram(), processing = Histogram()
        var longestUnprocessedMs = 0.0, longestSkipRun = 0
    }

    public init(rule: Rule = Rule()) { self.rule = rule }

    /// A frame the camera delivered: process it or skip it. `captureTime`: the frame's capture time (ARFrame.timestamp);
    /// `now`: when it is being handled, on the same clock; `nominalInterval`: the video format's frame interval (s,
    /// 1 / its frames per second). A frame skipped needs nothing else; a frame processed should be followed by
    /// `frameProcessed`.
    public mutating func frameArrived(captureTime c: Double, now: Double, nominalInterval: Double) -> Decision {
        let nominal = nominalInterval.isFinite && nominalInterval > 0 ? nominalInterval : (self.nominalInterval ?? 1.0 / 60)
        self.nominalInterval = nominal
        let age = now - c
        // a clock that went backwards (a new session): start the estimate again
        if let last = lastCapture, c <= last - 1e-9 {
            window = []; recentDeltas = []; lastProcessedCapture = nil; handlerFreeAt = nil; idleBaseline = nil
        }
        // the frame did not wait in the queue: the handler had been free for a while when it came
        let idle = handlerFreeAt.map { now - $0 >= rule.idleSeconds } ?? true
        // frames the camera never delivered
        if let last = lastCapture, c > last {
            let d = c - last
            recentDeltas.append(d)
            if recentDeltas.count > 31 { recentDeltas.removeFirst(recentDeltas.count - 31) }
            if d > rule.gapIntervals * nominal {
                let missing = max(1, Int((d / nominal).rounded()) - 1)
                total.gaps += 1; total.missing += missing
                gaps.append(Gap(c: c, missing: missing))
            }
        }
        lastCapture = c
        window.removeAll { $0.c < c - rule.baselineSeconds }

        // the rule
        var late = false
        if age.isFinite { window.append((c, age, idle, false)) }
        let idleAges = window.filter { $0.idle }.map { $0.age }
        if !idleAges.isEmpty { idleBaseline = FramePacer.percentile(idleAges, rule.baselinePercentile) }
        let processedAges = window.filter { $0.processed }.map { $0.age }
        if window.count >= max(1, rule.minBaselineFrames), age.isFinite,
           let base = idleBaseline ?? processedAges.min() {
            let threshold = base + rule.lateIntervals * effectiveInterval
            lastBaseline = base; lastThreshold = threshold
            late = age > threshold
        }
        let starved = lastProcessedCapture.map { c - $0 >= rule.maxUnprocessedSeconds } ?? true
        let skip = late && !starved
        if !skip, age.isFinite { window[window.count - 1].processed = true }
        // the handler is busy with it until `frameProcessed`, free again at once after a skip
        handlerFreeAt = now
        processingSince = skip ? nil : now

        // statistics
        if total.first == nil { total.first = c }
        total.last = c
        total.received += 1
        let ageMs = age * 1000
        if ageMs.isFinite { total.latency.add(ageMs) }
        arrivals.append(Arrival(c: c, ageMs: ageMs, skipped: skip, forced: late && !skip))
        if skip {
            total.skipped += 1
            consecutiveSkips += 1
            total.longestSkipRun = max(total.longestSkipRun, consecutiveSkips)
        } else {
            if late { total.forced += 1 }
            consecutiveSkips = 0
            if let p = lastProcessedCapture, c > p {
                let ms = (c - p) * 1000
                unprocessed.append((c, ms))
                total.longestUnprocessedMs = max(total.longestUnprocessedMs, ms)
            }
            lastProcessedCapture = c
        }
        trim(c)
        return skip ? .skip : .process
    }

    /// A frame was processed: how long it took (s), and which detectors ran on it.
    public mutating func frameProcessed(captureTime c: Double, seconds: Double, search: Bool, recheck: Bool, ball: Bool) {
        if let s = processingSince, seconds.isFinite { handlerFreeAt = s + max(0, seconds) }
        processingSince = nil
        let ms = max(0, seconds) * 1000
        let overran = seconds > (nominalInterval ?? .infinity)
        total.processed += 1
        total.processing.add(ms)
        if overran { total.overruns += 1 }
        if search { total.searches += 1 }
        if recheck { total.rechecks += 1 }
        if ball { total.balls += 1 }
        processed.append(Processed(c: c, ms: ms, overran: overran, search: search, recheck: recheck, ball: ball))
        trim(lastCapture ?? c)
    }

    /// The same, reading which detectors ran from the tracker's output (`detectionKind`, `ballSearched`).
    public mutating func frameProcessed(captureTime c: Double, seconds: Double, output: TrackerOutput) {
        frameProcessed(captureTime: c, seconds: seconds, search: output.detectionKind == .search, recheck: output.detectionKind == .recheck,
                       ball: output.ballSearched)
    }

    /// The frame interval the rule uses: the nominal one, or the typical spacing of recent frames when the camera
    /// delivers more slowly than its format says (the median, so dropped frames here and there do not count).
    public var effectiveInterval: Double {
        let nominal = nominalInterval ?? 1.0 / 60
        guard recentDeltas.count >= 5 else { return nominal }
        return max(nominal, FramePacer.percentile(recentDeltas, 0.5))
    }

    private mutating func trim(_ now: Double) {
        let from = now - rule.recentSeconds
        if let i = arrivals.firstIndex(where: { $0.c >= from }), i > 0 { arrivals.removeFirst(i) }
        if let i = processed.firstIndex(where: { $0.c >= from }), i > 0 { processed.removeFirst(i) }
        gaps.removeAll { $0.c < from }
        unprocessed.removeAll { $0.c < from }
    }

    /// The numbers so far, rounded (`FramePacingReport`).
    public var report: FramePacingReport {
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        func rate(_ n: Int, _ s: Double) -> Double { s > 0 ? r2(Double(n) / s) : 0 }
        func stats(_ v: [Double]) -> FramePacingReport.Millis? {
            guard !v.isEmpty else { return nil }
            return FramePacingReport.Millis(p50: r1(FramePacer.percentile(v, 0.5)), p95: r1(FramePacer.percentile(v, 0.95)), max: r1(v.max()!))
        }
        func hstats(_ h: Histogram) -> FramePacingReport.Millis? {
            guard h.count > 0 else { return nil }
            return FramePacingReport.Millis(p50: r1(h.percentile(0.5)), p95: r1(h.percentile(0.95)), max: r1(h.max))
        }
        // the recent window's span: from its first frame to its last, at least one frame interval
        let interval = nominalInterval ?? 1.0 / 60
        let rs = arrivals.isEmpty ? 0 : max(interval, arrivals.last!.c - arrivals.first!.c + interval)
        let recent = FramePacingReport.Window(
            seconds: r2(rs), framesReceived: arrivals.count, framesProcessed: processed.count,
            framesSkippedLate: arrivals.filter { $0.skipped }.count, framesProcessedLate: arrivals.filter { $0.forced }.count,
            cameraGaps: gaps.count, framesMissedByCamera: gaps.reduce(0) { $0 + $1.missing },
            deliveryLatencyMs: stats(arrivals.map { $0.ageMs }.filter { $0.isFinite }), processingMs: stats(processed.map { $0.ms }),
            processingOverruns: processed.filter { $0.overran }.count,
            longestUnprocessedMs: r1(unprocessed.map { $0.ms }.max() ?? 0),
            searches: processed.filter { $0.search }.count, rechecks: processed.filter { $0.recheck }.count,
            ballSearches: processed.filter { $0.ball }.count,
            processedPerSecond: rate(processed.count, rs),
            searchesPerSecond: rate(processed.filter { $0.search }.count, rs), rechecksPerSecond: rate(processed.filter { $0.recheck }.count, rs),
            ballSearchesPerSecond: rate(processed.filter { $0.ball }.count, rs))
        let ts = total.first.map { max(interval, (total.last ?? $0) - $0 + interval) } ?? 0
        let all = FramePacingReport.Window(
            seconds: r2(ts), framesReceived: total.received, framesProcessed: total.processed, framesSkippedLate: total.skipped,
            framesProcessedLate: total.forced, cameraGaps: total.gaps, framesMissedByCamera: total.missing,
            deliveryLatencyMs: hstats(total.latency), processingMs: hstats(total.processing), processingOverruns: total.overruns,
            longestUnprocessedMs: r1(total.longestUnprocessedMs),
            searches: total.searches, rechecks: total.rechecks, ballSearches: total.balls,
            processedPerSecond: rate(total.processed, ts),
            searchesPerSecond: rate(total.searches, ts), rechecksPerSecond: rate(total.rechecks, ts), ballSearchesPerSecond: rate(total.balls, ts))
        return FramePacingReport(nominalFrameIntervalMs: nominalInterval.map { r2($0 * 1000) }, effectiveFrameIntervalMs: r2(effectiveInterval * 1000),
                                 baselineLatencyMs: lastBaseline.map { r1($0 * 1000) }, lateAfterMs: lastThreshold.map { r1($0 * 1000) },
                                 longestSkipRun: total.longestSkipRun, rule: rule, recent: recent, total: all)
    }

    /// The p-th percentile (0-1) of the values (nearest rank on the sorted values).
    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let i = Int((clamp(p, 0, 1) * Double(s.count - 1)).rounded())
        return s[i]
    }

    /// Millisecond values in 0.5 ms bins up to 1 s (beyond: one overflow bin; the largest is kept exactly), so the
    /// whole run's percentiles cost a fixed few kB.
    struct Histogram {
        static let binMs = 0.5, bins = 2000
        var counts = [Int](repeating: 0, count: Histogram.bins + 1)
        var count = 0
        var max = 0.0
        mutating func add(_ ms: Double) {
            guard ms.isFinite else { return }
            let i = Swift.min(Histogram.bins, Swift.max(0, Int(ms / Histogram.binMs)))
            counts[i] += 1; count += 1; max = Swift.max(max, ms)
        }
        /// the bin's middle (the largest value for the overflow bin)
        func percentile(_ p: Double) -> Double {
            guard count > 0 else { return .nan }
            let rank = Swift.max(1, Int((clamp(p, 0, 1) * Double(count)).rounded(.up)))
            var seen = 0
            for (i, n) in counts.enumerated() {
                seen += n
                if seen >= rank { return i == Histogram.bins ? max : Swift.min(max, (Double(i) + 0.5) * Histogram.binMs) }
            }
            return max
        }
    }
}

/// How the camera's frames came and went (`FramePacer.report`): the diagnostics JSON's `framePacing`. Times in
/// milliseconds; "recent" is the last `rule.recentSeconds` of camera time, "total" everything since the pacer started
/// (the camera started).
public struct FramePacingReport: Codable, Equatable {
    /// median, 95th percentile and largest (ms); the total's percentiles are to 0.5 ms
    public struct Millis: Codable, Equatable {
        public var p50: Double
        public var p95: Double
        public var max: Double
    }
    public struct Window: Codable, Equatable {
        /// camera time covered (s)
        public var seconds: Double
        /// frames ARKit delivered to the app, the app processed, and skipped because they were late
        public var framesReceived: Int
        public var framesProcessed: Int
        public var framesSkippedLate: Int
        /// late frames processed anyway, because nothing had been processed for `rule.maxUnprocessedSeconds`
        public var framesProcessedLate: Int
        /// steps between consecutive delivered frames longer than `rule.gapIntervals` nominal intervals, and how many
        /// frames those steps left out (estimated from the nominal interval): frames ARKit never delivered
        public var cameraGaps: Int
        public var framesMissedByCamera: Int
        /// how long after capture each delivered frame reached the app (its handler on the processing queue)
        public var deliveryLatencyMs: Millis?
        /// how long processing a frame took
        public var processingMs: Millis?
        /// processed frames that took longer than the nominal frame interval
        public var processingOverruns: Int
        /// the longest stretch of camera time between two processed frames (ms)
        public var longestUnprocessedMs: Double
        /// detector runs: slab searches (searching or confirming), re-checks of the lock, ball searches; and per second
        public var searches: Int
        public var rechecks: Int
        public var ballSearches: Int
        public var processedPerSecond: Double
        public var searchesPerSecond: Double
        public var rechecksPerSecond: Double
        public var ballSearchesPerSecond: Double
    }
    /// the video format's frame interval, and the one the rule used (larger when frames come more slowly)
    public var nominalFrameIntervalMs: Double?
    public var effectiveFrameIntervalMs: Double?
    /// the rule's latest baseline latency and lateness threshold (a frame older than `lateAfterMs` is skipped)
    public var baselineLatencyMs: Double?
    public var lateAfterMs: Double?
    /// the most frames skipped in a row
    public var longestSkipRun: Int
    public var rule: FramePacer.Rule
    public var recent: Window
    public var total: Window
}
