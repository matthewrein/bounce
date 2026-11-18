import BounceCore
import Foundation

/// The frame budget at 60 fps.
enum FrameBudget {
    static let fps = 60.0
    static var interval: Double { 1000 / fps }        // 16.7 ms
    /// half a frame: what the processing queue may take and still leave room for ARKit's delivery and the UI
    static let comfortable = 8.0
    /// ARKit's frames held by the app (in the delegate's queue, being processed, or waiting in the hand-off): ARKit logs
    /// that the delegate is retaining ARFrames at about a dozen and then stops delivering camera frames; over 8 leaves
    /// no margin (THREAT), over 4 is worth watching
    static let heldThreat = 8, heldWatch = 4
    /// frames not processed per second (dropped while processing was busy, or skipped as late: the overlay updates that
    /// many fewer times a second): THREAT at 3/s (5% of frames), watch at 0.5/s
    static let skippedThreat = 3.0, skippedWatch = 0.5

    /// a single frame's time (a stage or a frame kind on the processing queue)
    static func flag(_ ms: Double) -> String {
        ms > interval ? "THREAT (over a 60 fps frame)" : ms > comfortable ? "watch (over half a frame)" : ""
    }

    /// a state's outcome in the cadence model: what decides whether 60 fps tracking is threatened
    static func flag(_ r: CadenceResult) -> String {
        if r.framesSkipped >= skippedThreat || r.maxFramesHeld > heldThreat {
            return "THREAT" + (r.maxFramesHeld > heldThreat ? " (ARKit frame retention)" : "")
        }
        return r.framesSkipped >= skippedWatch || r.maxFramesHeld > heldWatch ? "watch" : ""
    }
}

/// What the processing queue does in one state, frame kind by frame kind (whole-frame ms).
struct Scenario: Codable {
    enum State: String, Codable { case searching, locked }
    var name: String
    var state: State
    /// the cost of each kind of frame (ms); a kind without its own measurement is estimated from the others
    var costs: [FrameKind: Double]
    /// how many frames of each kind the costs come from
    var counts: [FrameKind: Int] = [:]
    /// the detector runs' kinds in the order they came in the app loop (without the ball): the model takes them in turn
    /// (empty: searches find the slab while searching, re-checks follow it while locked)
    var detectionCycle: [FrameKind] = []
    /// the session recorder keeps the image this often (s; RecordingCadence.imageInterval): a frame with nothing else
    /// converting it pays the conversion (`plainImage` - `plain`); nil: not recording
    var imageInterval: Double? = nil
    /// the capture kit's recorder: its work (ms) on every `kitEvery`-th frame (1: a 60 fps shot, 2: 30 fps), processed
    /// or not (the app gives every frame to it, on the delegate's queue; with one queue, on the processing queue, late
    /// frames too); 0: none
    var kitCost: Double = 0
    var kitEvery: Int = 0
    /// the delegate's own work on a frame (ms) apart from the kit's: the hand-off and the notes on every frame (with one
    /// queue: a skipped frame's handling)
    var skipCost: Double = 0.02
    /// the ball finder runs while locked (not when the lock is out of view: no ball crop)
    var ballScans: Bool = true
    /// Nothing to find, so the tracker's idle rates apply (the app's `idleSearchAfter` / `idleBallAfter`, from a still
    /// camera as the bench's): searches that never found a candidate (searching, nothing in view), and ball scans that
    /// never found a ball. Optional for reports from before them.
    var idleSearches: Bool? = nil
    var idleBall: Bool? = nil

    func cost(_ k: FrameKind) -> Double {
        if let c = costs[k] { return c }
        let plain = costs[.plain] ?? 0
        switch k {
        case .recheckBall, .recheckMissBall, .recheckWideBall:
            let base = costs[k.withoutBall] ?? costs[.recheck] ?? plain
            return base + (costs[.ball] ?? plain) - plain
        case .recheckMiss, .recheckWide: return costs[.recheck] ?? plain
        case .searchRefine: return costs[.search] ?? plain
        case .search: return costs[.searchRefine] ?? plain
        default: return plain
        }
    }

    /// "plain 1520 / ball 270 / rc 90": the measured frames behind the costs
    var countsLine: String {
        FrameKind.allCases.compactMap { k in counts[k].map { "\(k.short) \($0)" } }.joined(separator: " / ")
    }
}

/// How ARKit's frames reach the tracker in the model.
enum Pipeline: String, Codable {
    /// the app: ARKit's delegate queue does the cheap per-frame work (and the kit's recorder) and hands each frame to
    /// the processing queue through `FrameHandoff` (at most one processed and one waiting, the latest)
    case handoff
    /// before the hand-off: the processing queue was ARKit's delegate queue, every frame waited there in turn and the
    /// FramePacer skipped the late ones (the kit's work on the processing queue, late frames too)
    case queue
}

/// The result of running a scenario through the app's cadence and its frame pacer.
struct CadenceResult: Codable {
    var scenario: String
    var state: Scenario.State
    var timeScale: Double
    /// per second of camera time
    var framesProcessed: Double
    var framesSkipped: Double
    var searches: Double
    var rechecks: Double
    var ballScans: Double
    /// processing time per second of camera time (ms), and as a share of one core (%)
    var loadMsPerSecond: Double
    var loadPercent: Double
    /// the longest single frame (ms), and the longest camera time between two processed frames (ms)
    var worstFrameMs: Double
    var worstFrameKind: FrameKind
    var longestGapMs: Double
    /// the mean wait of processed frames in the queue, or in the hand-off (ms; how stale the overlay is beyond ARKit's
    /// own latency)
    var meanQueueWaitMs: Double
    /// ARKit's frames the app holds when a frame arrives (the new one, those still in the delegate's queue, the one
    /// being processed and the one waiting; with one queue: those still waiting or running, and the new one): each is
    /// an ARFrame and its camera buffer ARKit cannot reuse; the most, and the mean
    var maxFramesHeld: Int
    var meanFramesHeld: Double
    var pipeline: Pipeline? = nil
}

enum CadenceSim {
    /// Runs `seconds` of camera time at 60 fps through the app's tracker cadence (searchInterval 0.12 s while searching,
    /// recheckInterval 0.3 s and ballInterval 0.1 s while locked, minDetectionGap 0.05 s; with nothing to find, the idle
    /// rates: searches every idleSearchInterval after idleSearchAfter, ball scans every idleBallInterval after
    /// idleBallAfter, as the app's tracker does from a still camera) and the app's pipeline: frame i
    /// is captured at i/60 and reaches ARKit's delegate `latency` later (ARKit's own delay). The tracker stays in the
    /// scenario's state; its detector runs take the scenario's kinds in turn; a processed frame takes its kind's cost x
    /// `scale`.
    ///
    /// `.handoff` (the app): the delegate's queue spends `skipCost` (and the kit's work, when it records) on every frame
    /// and hands it to BounceCore's own FrameHandoff: processing takes it at once if idle, else it waits, replacing (and
    /// dropping) any frame already waiting; when processing ends it takes the waiting frame. `.queue` (before): the
    /// frame waits in the one serial queue while earlier frames are handled and is then processed or skipped as late by
    /// BounceCore's FramePacer (taking `skipCost`, and the kit's work if it records).
    static func run(_ sc: Scenario, scale: Double = 1, seconds: Double = 30, latency: Double = 0.03, pipeline: Pipeline = .handoff) -> CadenceResult {
        let settings = RecordingSettings().trackerSettings
        let dt = 1 / FrameBudget.fps
        // the idle rates (nothing to find, a still camera): after idleSearchAfter / idleBallAfter of camera time
        let idleSearchFrom = sc.idleSearches == true && settings.idleSearchAfter > 0 ? settings.idleSearchAfter : Double.infinity
        let idleBallFrom = sc.idleBall == true && settings.idleBallAfter > 0 ? settings.idleBallAfter : Double.infinity
        var lastCheck = -Double.infinity, lastRun = -Double.infinity, lastBall = -Double.infinity, lastImage = -Double.infinity
        var processed = 0, skipped = 0, searches = 0, rechecks = 0, balls = 0, cycle = 0
        var busy = 0.0, worst = 0.0, worstKind = FrameKind.plain, lastProcessed: Double? = nil, longestGap = 0.0, waits = 0.0
        var maxHeld = 0, sumHeld = 0
        let n = Int(seconds * FrameBudget.fps)
        let defaultDetection: FrameKind = sc.state == .searching ? (sc.costs[.searchRefine] != nil ? .searchRefine : .search) : .recheck
        func kitMs(_ i: Int) -> Double { sc.kitEvery > 0 && i % sc.kitEvery == 0 ? sc.kitCost : 0 }
        /// what the tracker runs on the frame captured at c (its own rule, `detectionDue` / `ballDue`), and its cost (ms)
        func kindAndCost(_ c: Double) -> (FrameKind, Double) {
            var kind = FrameKind.plain
            let searchInterval = c >= idleSearchFrom ? max(settings.searchInterval, settings.idleSearchInterval) : settings.searchInterval
            let detection = c - lastRun >= settings.minDetectionGap
                && c - lastCheck >= (sc.state == .searching ? searchInterval : settings.recheckInterval)
            if detection {
                lastCheck = c; lastRun = c
                kind = sc.detectionCycle.isEmpty ? defaultDetection : sc.detectionCycle[cycle % sc.detectionCycle.count]
                cycle += 1
            }
            let ballInterval = c >= idleBallFrom ? max(settings.ballInterval, settings.idleBallInterval) : settings.ballInterval
            if sc.state == .locked && sc.ballScans && c - lastBall >= ballInterval {
                lastBall = c
                kind = kind.withBall
            }
            var extra = 0.0
            if let ii = sc.imageInterval {
                // the recording keeps the image of every detection frame, and otherwise every `ii` seconds
                if kind.isDetection { lastImage = c } else if c - lastImage >= ii {
                    lastImage = c
                    if kind == .plain { kind = .plainImage } else { extra = sc.cost(.plainImage) - sc.cost(.plain) }
                }
            }
            return (kind, (sc.cost(kind) + extra) * scale)
        }
        func count(_ kind: FrameKind, _ ms: Double, capture c: Double, wait: Double) {
            processed += 1; busy += ms; waits += wait * 1000
            if kind.isSearch { searches += 1 }
            if kind.isRecheck { rechecks += 1 }
            if kind.isBall { balls += 1 }
            if ms > worst { worst = ms; worstKind = kind }
            if let p = lastProcessed { longestGap = max(longestGap, (c - p) * 1000) }
            lastProcessed = c
        }

        switch pipeline {
        case .queue:
            var pacer = FramePacer()
            var free = -Double.infinity
            // the queue's frames by when their handling ends (FIFO, so in order)
            var ends: [Double] = [], head = 0
            for i in 0..<n {
                let c = Double(i) * dt
                let arrive = c + latency
                while head < ends.count && ends[head] <= arrive { head += 1 }
                let held = ends.count - head + 1
                maxHeld = max(maxHeld, held); sumHeld += held
                let start = max(arrive, free)
                if pacer.frameArrived(captureTime: c, now: start, nominalInterval: dt) == .skip {
                    skipped += 1
                    let ms = sc.skipCost * scale + kitMs(i) * scale
                    free = start + ms / 1000
                    ends.append(free)
                    busy += ms
                    pacer.skippedFrameHandled(seconds: ms / 1000)
                    continue
                }
                let (kind, cost) = kindAndCost(c)
                let ms = cost + kitMs(i) * scale
                free = start + ms / 1000
                ends.append(free)
                pacer.frameProcessed(captureTime: c, seconds: ms / 1000, search: kind.isSearch, recheck: kind.isRecheck, ball: kind.isBall)
                count(kind, ms, capture: c, wait: start - arrive)
            }
        case .handoff:
            let h = FrameHandoff<Int>()
            // the delegate's queue (serial): when each frame's delegate call ends (in order), and when it is free
            var deliveryEnds: [Double] = [], dHead = 0, deliveryFree = -Double.infinity
            // the frame being processed: when it started and ends, its kind and cost
            var current: (i: Int, end: Double, kind: FrameKind)? = nil
            func start(_ j: Int, at t: Double) {
                let c = Double(j) * dt
                let (kind, ms) = kindAndCost(c)
                count(kind, ms, capture: c, wait: t - (c + latency))
                current = (j, t + ms / 1000, kind)
            }
            for i in 0..<n {
                let c = Double(i) * dt
                let delivered = max(c + latency, deliveryFree)
                // processing that ends before this frame is handed over takes the frame that waited meanwhile
                while let cur = current, cur.end <= delivered {
                    current = nil
                    let next = h.finished(captureTime: Double(cur.i) * dt, seconds: 0, now: cur.end, search: cur.kind.isSearch,
                                          recheck: cur.kind.isRecheck, ball: cur.kind.isBall)
                    if let j = next { start(j, at: cur.end) }
                }
                while dHead < deliveryEnds.count && deliveryEnds[dHead] <= c + latency { dHead += 1 }
                // held when it arrives: itself, the frames still in the delegate's queue ahead of it, and the hand-off's
                let held = 1 + (deliveryEnds.count - dHead) + h.framesHeld
                maxHeld = max(maxHeld, held); sumHeld += held
                if let j = h.deliver(i, captureTime: c, now: delivered, nominalInterval: dt) { start(j, at: delivered) }
                let ms = (sc.skipCost + kitMs(i)) * scale
                deliveryFree = delivered + ms / 1000
                deliveryEnds.append(deliveryFree)
            }
            skipped = h.report.total.framesDroppedBusy
        }
        let secs = Double(n) * dt
        return CadenceResult(scenario: sc.name, state: sc.state, timeScale: scale, framesProcessed: Double(processed) / secs,
                             framesSkipped: Double(skipped) / secs, searches: Double(searches) / secs, rechecks: Double(rechecks) / secs,
                             ballScans: Double(balls) / secs, loadMsPerSecond: busy / secs, loadPercent: busy / secs / 10,
                             worstFrameMs: worst, worstFrameKind: worstKind, longestGapMs: longestGap,
                             meanQueueWaitMs: processed > 0 ? waits / Double(processed) : 0,
                             maxFramesHeld: maxHeld, meanFramesHeld: Double(sumHeld) / Double(max(1, n)), pipeline: pipeline)
    }
}

/// The iPhone estimate: single-core speed relative to the CI Mac (the processing queue is serial, so one core's speed
/// is what counts). Geekbench 6 single-core scores (typical published results; the version and iOS move them by a few %).
struct Chip: Codable {
    var chip: String
    var phones: String
    var lidar: Bool
    var geekbench6Single: Double
    /// how well the score is founded
    var source: String
    /// time on this chip = time on the CI Mac x this
    var timeFactor: Double { Chip.ciMacGeekbench6Single / geekbench6Single }

    /// GitHub's macos-15 arm64 runner: a virtual machine on an Apple M1 (3 cores). A native M1 scores about 2,300-2,350
    /// single-core in Geekbench 6; the virtual machine's single-thread speed is taken to be about the same (no
    /// measurement of it here: CPU-bound code runs at nearly native speed in Apple's virtualisation, but a shared host can
    /// cost 5-10%).
    static let ciMacGeekbench6Single = 2300.0
    /// relative uncertainty of a time factor (Geekbench's mix is not this code's; per-result spread; the runner's VM)
    static let uncertainty = 0.2
    /// time multiplier for a phone warm from minutes of AR (camera, LiDAR, GPU rendering): its performance cores slow
    /// down; 1.3 is a middle guess for a sustained session, from published sustained-load tests of these phones (they
    /// keep about 65-85% of peak)
    static let thermal = 1.3
    /// time multiplier when the processing queue does not have a performance core to itself: A11-A18 phones have two,
    /// shared with ARKit's tracking and scene depth, the main thread's 60 Hz SwiftUI updates and the recorders; time
    /// sliced with them, or run on an efficiency core (several times slower), the queue's work takes longer. x2 is an
    /// assumption, not a measurement
    static let contended = 2.0

    /// iOS 16 (the app's deployment target) runs on the A11 and later; ARKit is the only required capability and LiDAR is
    /// optional, so the phones without LiDAR run the app too.
    static let all: [Chip] = [
        Chip(chip: "A11 Bionic", phones: "iPhone 8, X", lidar: false, geekbench6Single: 1050,
             source: "rough: no published GB6 average found; from its Geekbench 5 score"),
        Chip(chip: "A12 Bionic", phones: "iPhone XS, XR", lidar: false, geekbench6Single: 1310, source: "published GB6 results 1,290-1,340"),
        Chip(chip: "A13 Bionic", phones: "iPhone 11, 11 Pro, SE 2", lidar: false, geekbench6Single: 1740, source: "published GB6 results 1,710-1,760"),
        Chip(chip: "A14 Bionic", phones: "iPhone 12, 12 Pro (LiDAR)", lidar: true, geekbench6Single: 2070,
             source: "GB6 about 2,060; the M1's own core (Firestorm) at 3.0 GHz against 3.2"),
        Chip(chip: "A15 Bionic", phones: "iPhone 13, 13 Pro (LiDAR), 14", lidar: true, geekbench6Single: 2300, source: "GB6 about 2,300"),
        Chip(chip: "A16 Bionic", phones: "iPhone 14 Pro (LiDAR), 15", lidar: true, geekbench6Single: 2550, source: "GB6 about 2,570"),
        Chip(chip: "A17 Pro", phones: "iPhone 15 Pro (LiDAR)", lidar: true, geekbench6Single: 2900, source: "GB6 about 2,900"),
        Chip(chip: "A18 Pro", phones: "iPhone 16 Pro (LiDAR)", lidar: true, geekbench6Single: 3450, source: "GB6 3,400-3,460"),
    ]
}

/// The budget model's output.
struct BudgetModel: Codable {
    /// host time -> CI Mac time (1 on the CI Mac; from the calibration loop when a Mac's calibration is given)
    var hostToMac: Double
    var hostToMacBasis: String
    var scenarios: [Scenario]
    /// at this host's speed (scaled to the CI Mac), p50 and p95 costs
    var onMac: [CadenceResult]
    var onMacP95: [CadenceResult]
    /// the same p95 costs through one queue, as before the hand-off (ARKit's delegate queue = the processing queue): what
    /// the hand-off removed (nil in reports from before it)
    var onMacP95Queue: [CadenceResult]? = nil
    /// per chip: nominal, thermally throttled, and contended (not a performance core to itself)
    var phones: [PhoneEstimate]
}

struct PhoneEstimate: Codable {
    var chip: Chip
    var timeFactor: Double
    var results: [CadenceResult]
    var throttled: [CadenceResult]
    var contended: [CadenceResult]
}

extension BudgetModel {
    /// The scenarios from the app-loop runs: per kind, the whole frame's p50 (or p95) time.
    static func scenarios(from sessions: [SessionResult], percentile95: Bool) -> [Scenario] {
        func costs(_ r: SessionResult) -> ([FrameKind: Double], [FrameKind: Int]) {
            var c: [FrameKind: Double] = [:], n: [FrameKind: Int] = [:]
            for k in r.kinds { c[k.kind] = percentile95 ? k.total.p95 : k.total.p50; n[k.kind] = k.count }
            return (c, n)
        }
        var out: [Scenario] = []
        for r in sessions where !r.kinds.isEmpty {
            var (c, n) = costs(r)
            var name = "\(r.phase), \(r.scene)"
            var cycle = r.detectionCycle
            switch r.state {
            case .searching:
                c = c.filter { $0.key.isSearch || $0.key == .plain }
                if r.phase == "acquiring" { name = "searching/confirming, \(r.scene)" }
            case .locked:
                c = c.filter { !$0.key.isSearch }
                cycle = cycle.filter { $0.isRecheck }
            }
            n = n.filter { c[$0.key] != nil }
            var sc = Scenario(name: name, state: r.state, costs: c, counts: n, detectionCycle: cycle)
            sc.ballScans = r.kinds.contains { $0.kind.isBall }
            sc.idleSearches = r.state == .searching && r.phase == "searching" && !r.kinds.contains { $0.kind == .searchRefine }
            sc.idleBall = r.state == .locked && (r.ballShownFrames.map { $0 == 0 } ?? false)
            if r.recording { sc.imageInterval = RecordingCadence().imageInterval }
            if let kc = percentile95 ? r.kitP95 : r.kitP50 {
                // a 60 fps shot (every frame to the kit) and a 30 fps one (every other frame)
                var a = sc, b = sc
                #if canImport(Accelerate)
                let how = ""
                #else
                let how = " [Linux: a pure-Swift stand-in for vImage's scale]"
                #endif
                a.name = "\(r.phase) (60 fps shot), \(r.scene)\(how)"; a.kitCost = kc; a.kitEvery = 1
                b.name = "\(r.phase) (30 fps shot), \(r.scene)\(how)"; b.kitCost = kc; b.kitEvery = 2
                out += [a, b]
                continue
            }
            out.append(sc)
        }
        return out
    }

    static func make(sessions: [SessionResult], hostToMac: Double, basis: String) -> BudgetModel {
        let s50 = scenarios(from: sessions, percentile95: false), s95 = scenarios(from: sessions, percentile95: true)
        let mac = s50.map { CadenceSim.run($0, scale: hostToMac) }
        let mac95 = s95.map { CadenceSim.run($0, scale: hostToMac) }
        let mac95q = s95.map { CadenceSim.run($0, scale: hostToMac, pipeline: .queue) }
        let phones = Chip.all.map { ch -> PhoneEstimate in
            let f = hostToMac * ch.timeFactor
            return PhoneEstimate(chip: ch, timeFactor: ch.timeFactor, results: s50.map { CadenceSim.run($0, scale: f) },
                                 throttled: s50.map { CadenceSim.run($0, scale: f * Chip.thermal) },
                                 contended: s50.map { CadenceSim.run($0, scale: f * Chip.contended) })
        }
        return BudgetModel(hostToMac: hostToMac, hostToMacBasis: basis, scenarios: s50, onMac: mac, onMacP95: mac95, onMacP95Queue: mac95q,
                           phones: phones)
    }
}
