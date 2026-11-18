import BounceCore
import Foundation

/// The frame budget at 60 fps.
enum FrameBudget {
    static let fps = 60.0
    static var interval: Double { 1000 / fps }        // 16.7 ms
    /// half a frame: what the processing queue may take and still leave room for ARKit's delivery and the UI
    static let comfortable = 8.0

    static func flag(_ ms: Double) -> String {
        ms > interval ? "THREAT (over a 60 fps frame)" : ms > comfortable ? "watch (over half a frame)" : ""
    }
}

/// What the processing queue does in one state, frame kind by frame kind (whole-frame ms).
struct Scenario: Codable {
    enum State: String, Codable { case searching, locked }
    var name: String
    var state: State
    /// the cost of each kind of frame (ms); a kind without its own measurement is estimated from the others
    var costs: [FrameKind: Double]
    /// the session recorder keeps the image this often (s; RecordingCadence.imageInterval): a frame with nothing else
    /// converting it pays the conversion (`plainImage` - `plain`); nil: not recording
    var imageInterval: Double? = nil

    func cost(_ k: FrameKind) -> Double {
        if let c = costs[k] { return c }
        let plain = costs[.plain] ?? 0
        switch k {
        case .recheckBall: return (costs[.recheck] ?? plain) + (costs[.ball] ?? plain) - plain
        case .searchRefine: return costs[.search] ?? plain
        case .search: return costs[.searchRefine] ?? plain
        case .plainImage: return plain
        default: return plain
        }
    }

    func scaled(_ k: Double) -> Scenario {
        var o = self
        o.costs = costs.mapValues { $0 * k }
        return o
    }
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
    /// the mean wait of processed frames in the queue (ms; how stale the overlay is beyond ARKit's own latency)
    var meanQueueWaitMs: Double
}

enum CadenceSim {
    /// Runs `seconds` of camera time at 60 fps through the app's tracker cadence (searchInterval 0.12 s while searching,
    /// recheckInterval 0.3 s and ballInterval 0.1 s while locked, minDetectionGap 0.05 s) and the app's FramePacer
    /// (BounceCore's own, with its default rule): frame i is captured at i/60, reaches the serial processing queue
    /// `latency` later (ARKit's own delay), waits there while earlier frames are handled, and is then processed (taking
    /// its kind's cost x `scale`) or skipped as late (taking nothing). The tracker stays in the scenario's state.
    static func run(_ sc: Scenario, scale: Double = 1, seconds: Double = 30, latency: Double = 0.03) -> CadenceResult {
        let settings = RecordingSettings().trackerSettings
        var pacer = FramePacer()
        let dt = 1 / FrameBudget.fps
        var free = -Double.infinity
        var lastCheck = -Double.infinity, lastRun = -Double.infinity, lastBall = -Double.infinity, lastImage = -Double.infinity
        var processed = 0, skipped = 0, searches = 0, rechecks = 0, balls = 0
        var busy = 0.0, worst = 0.0, worstKind = FrameKind.plain, lastProcessed: Double? = nil, longestGap = 0.0, waits = 0.0
        let n = Int(seconds * FrameBudget.fps)
        for i in 0..<n {
            let c = Double(i) * dt
            let start = max(c + latency, free)
            if pacer.frameArrived(captureTime: c, now: start, nominalInterval: dt) == .skip {
                skipped += 1
                free = start + 2e-5
                continue
            }
            // what the tracker runs on this frame (its own rule, `detectionDue` / `ballDue`)
            var kind = FrameKind.plain
            switch sc.state {
            case .searching:
                if c - lastRun >= settings.minDetectionGap && c - lastCheck >= settings.searchInterval {
                    lastCheck = c; lastRun = c
                    kind = sc.costs[.searchRefine] != nil ? .searchRefine : .search
                }
            case .locked:
                let recheck = c - lastRun >= settings.minDetectionGap && c - lastCheck >= settings.recheckInterval
                let ball = c - lastBall >= settings.ballInterval
                if recheck { lastCheck = c; lastRun = c }
                if ball { lastBall = c }
                kind = recheck ? (ball ? .recheckBall : .recheck) : (ball ? .ball : .plain)
            }
            var extra = 0.0
            if let ii = sc.imageInterval {
                // the recording keeps the image of every detection frame, and otherwise every `ii` seconds
                if kind.isSearch || kind.isRecheck { lastImage = c } else if c - lastImage >= ii {
                    lastImage = c
                    if kind == .plain { kind = .plainImage } else { extra = sc.cost(.plainImage) - sc.cost(.plain) }
                }
            }
            let ms = (sc.cost(kind) + extra) * scale
            free = start + ms / 1000
            pacer.frameProcessed(captureTime: c, seconds: ms / 1000, search: kind.isSearch, recheck: kind.isRecheck, ball: kind.isBall)
            processed += 1; busy += ms; waits += (start - c - latency) * 1000
            if kind.isSearch { searches += 1 }
            if kind.isRecheck { rechecks += 1 }
            if kind.isBall { balls += 1 }
            if ms > worst { worst = ms; worstKind = kind }
            if let p = lastProcessed { longestGap = max(longestGap, (c - p) * 1000) }
            lastProcessed = c
        }
        let secs = Double(n) * dt
        return CadenceResult(scenario: sc.name, state: sc.state, timeScale: scale, framesProcessed: Double(processed) / secs,
                             framesSkipped: Double(skipped) / secs, searches: Double(searches) / secs, rechecks: Double(rechecks) / secs,
                             ballScans: Double(balls) / secs, loadMsPerSecond: busy / secs, loadPercent: busy / secs / 10,
                             worstFrameMs: worst, worstFrameKind: worstKind, longestGapMs: longestGap,
                             meanQueueWaitMs: processed > 0 ? waits / Double(processed) : 0)
    }
}

/// The iPhone estimate: single-core speed relative to the CI Mac (the processing queue is serial, so one core's speed
/// is what counts). Geekbench 6 single-core scores (typical published results; the version and iOS move them by a few %).
struct Chip: Codable {
    var chip: String
    var phone: String
    var geekbench6Single: Double
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

    static let lidarPhones: [Chip] = [
        Chip(chip: "A14 Bionic", phone: "iPhone 12 Pro", geekbench6Single: 2070),
        Chip(chip: "A15 Bionic", phone: "iPhone 13 Pro", geekbench6Single: 2300),
        Chip(chip: "A16 Bionic", phone: "iPhone 14 Pro", geekbench6Single: 2550),
        Chip(chip: "A17 Pro", phone: "iPhone 15 Pro", geekbench6Single: 2900),
        Chip(chip: "A18 Pro", phone: "iPhone 16 Pro", geekbench6Single: 3450),
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
    /// per chip: nominal and thermally throttled
    var phones: [PhoneEstimate]
}

struct PhoneEstimate: Codable {
    var chip: Chip
    var timeFactor: Double
    var results: [CadenceResult]
    var throttled: [CadenceResult]
}

extension BudgetModel {
    /// The scenarios from the app-loop runs: per kind, the whole frame's p50 (or p95) time.
    static func scenarios(from sessions: [SessionResult], percentile95: Bool) -> [Scenario] {
        func costs(_ r: SessionResult) -> [FrameKind: Double] {
            var c: [FrameKind: Double] = [:]
            for k in r.kinds { c[k.kind] = percentile95 ? k.total.p95 : k.total.p50 }
            return c
        }
        var out: [Scenario] = []
        if let e = sessions.first(where: { $0.phase == "searching" }) {
            out.append(Scenario(name: "searching, empty view (\(e.scene))", state: .searching, costs: costs(e)))
        }
        for r in sessions where r.phase == "acquiring" && !r.kinds.isEmpty {
            // searching with the slab in view: every search finds it and refines it on the crop (confirming)
            var c = costs(r)
            c = c.filter { $0.key == .searchRefine || $0.key == .plain || $0.key == .search }
            out.append(Scenario(name: "searching/confirming, \(r.scene)", state: .searching, costs: c))
        }
        for r in sessions where r.phase == "locked" && !r.kinds.isEmpty {
            var c = costs(r)
            c = c.filter { !$0.key.isSearch }
            out.append(Scenario(name: "locked, \(r.scene)", state: .locked, costs: c))
        }
        if let r = sessions.first(where: { $0.phase == "locked, recording" }) {
            out.append(Scenario(name: "locked + recording, \(r.scene)", state: .locked, costs: costs(r).filter { !$0.key.isSearch },
                                imageInterval: RecordingCadence().imageInterval))
        }
        return out
    }

    static func make(sessions: [SessionResult], hostToMac: Double, basis: String) -> BudgetModel {
        let s50 = scenarios(from: sessions, percentile95: false), s95 = scenarios(from: sessions, percentile95: true)
        let mac = s50.map { CadenceSim.run($0, scale: hostToMac) }
        let mac95 = s95.map { CadenceSim.run($0, scale: hostToMac) }
        let phones = Chip.lidarPhones.map { ch -> PhoneEstimate in
            let f = hostToMac * ch.timeFactor
            return PhoneEstimate(chip: ch, timeFactor: ch.timeFactor, results: s50.map { CadenceSim.run($0, scale: f) },
                                 throttled: s50.map { CadenceSim.run($0, scale: f * Chip.thermal) })
        }
        return BudgetModel(hostToMac: hostToMac, hostToMacBasis: basis, scenarios: s50, onMac: mac, onMacP95: mac95, phones: phones)
    }
}
