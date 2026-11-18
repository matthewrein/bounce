import BounceCore
import Foundation

/// What ran on a processed frame (as the frame pacer's diagnostics split them, with the coincidences and the re-check's
/// outcomes apart).
enum FrameKind: String, Codable, CaseIterable {
    case plain = "plain (nothing due)"
    case ball = "ball scan"
    /// a re-check that followed the lock's outline (on the crop around it) and found the slab there
    case recheck = "re-check"
    case recheckBall = "re-check + ball scan"
    /// a re-check that followed the lock's outline and found no usable outline (slab hidden or moved; `miss`)
    case recheckMiss = "re-check, missed"
    case recheckMissBall = "re-check, missed + ball scan"
    /// a re-check over the whole view (a sweep, then the refine pass on the crop if it found one): while a lock is
    /// unconfirmed after a world discontinuity, every second re-check, and every one while the lock is out of view
    case recheckWide = "re-check over the whole view"
    case recheckWideBall = "re-check over the whole view + ball scan"
    case search = "search (nothing found)"
    case searchRefine = "search + refine on the crop"
    /// a plain frame whose image the session recorder keeps (converted for it alone)
    case plainImage = "plain + image for the recording"

    static func of(_ o: TrackerOutput) -> FrameKind {
        switch o.detectionKind {
        case .search?: return o.slabDetail != nil || o.refinedDetections != nil ? .searchRefine : .search
        case .recheck?:
            // the tracker asks for the crop up front only when it follows the lock's outline; a sweep's find is refined
            let wide = o.refinedDetections != nil || o.slabDetail == nil
            let base: FrameKind = wide ? .recheckWide : o.measurement == nil ? .recheckMiss : .recheck
            return o.ballSearched ? base.withBall : base
        case nil: return o.ballSearched ? .ball : .plain
        }
    }
    var withBall: FrameKind {
        switch self {
        case .plain, .plainImage: return .ball
        case .recheck: return .recheckBall
        case .recheckMiss: return .recheckMissBall
        case .recheckWide: return .recheckWideBall
        default: return self
        }
    }
    var withoutBall: FrameKind {
        switch self {
        case .ball: return .plain
        case .recheckBall: return .recheck
        case .recheckMissBall: return .recheckMiss
        case .recheckWideBall: return .recheckWide
        default: return self
        }
    }
    var isSearch: Bool { self == .search || self == .searchRefine }
    var isRecheck: Bool { [.recheck, .recheckBall, .recheckMiss, .recheckMissBall, .recheckWide, .recheckWideBall].contains(self) }
    var isBall: Bool { [.ball, .recheckBall, .recheckMissBall, .recheckWideBall].contains(self) }
    var isDetection: Bool { isSearch || isRecheck }
    /// short label (n per kind)
    var short: String {
        switch self {
        case .plain: return "plain"
        case .ball: return "ball"
        case .recheck: return "rc"
        case .recheckBall: return "rc+b"
        case .recheckMiss: return "rc miss"
        case .recheckMissBall: return "rc miss+b"
        case .recheckWide: return "rc wide"
        case .recheckWideBall: return "rc wide+b"
        case .search: return "search"
        case .searchRefine: return "search+refine"
        case .plainImage: return "plain+img"
        }
    }
}

/// One processed frame's times (ms): the whole handling and its parts.
struct FrameSample {
    var kind: FrameKind
    /// the whole handling on the processing queue (the kit recorder's part included; see `kit`)
    var total: Double
    /// the image conversion (fromBiplanar + colorFrame), LiDAR copy, ball crop, slab crop (inside process), the tracker
    var convert: Double
    /// ycc.colorFrame alone (part of `convert`)
    var colorFrame: Double = 0
    var depth: Double
    var ballCrop: Double
    var slabCrop: Double
    var process: Double
    /// the app's glue around the tracker (pacer, format watch, capture-lock gate, overlay, HUD, developer line)
    var glue: Double = 0
    /// the capture kit recorder's work on this frame (KitRecorder.consume: scale, mean luma, depth once a second)
    var kit: Double = 0
    /// the session recorder's work: on the processing queue (RecordingCadence.record), and its encoding (its own queue)
    var record: Double = 0
    var encode: Double = 0
    /// the slab search's sweep (regions grown, of at most maxSweepRegions), when the bench is built instrumented
    var regionsGrown: Int? = nil
    /// the frame's tracker output showed a ball
    var ballShown = false
}

struct KindSummary: Codable {
    var kind: FrameKind
    var count: Int
    var total: Stats
    /// medians of the parts (ms)
    var convertP50: Double
    var colorFrameP50: Double?
    var depthP50: Double
    var ballCropP50: Double
    var slabCropP50: Double
    var processP50: Double
    var glueP50: Double
    var kitP50: Double?
    var recordP50: Double?
    var encodeP50: Double?
    var encodeP95: Double?
}

/// One run of the app's per-frame loop on one scene.
struct SessionResult: Codable {
    var scene: String
    /// searching (no slab), acquiring (search to lock, several times), locked (and its harder variants: after a world
    /// discontinuity, occluded, a drop), locked + recording, locked + kit
    var phase: String
    /// the state the budget model runs it in
    var state: Scenario.State
    var seconds: Double
    var frames: Int
    /// per kind: the whole frame without the kit recorder's work (`kitP50` apart), and its parts
    var kinds: [KindSummary]
    /// the detector runs' kinds in order, without the ball (search, search + refine; re-check, missed, whole view)
    var detectionCycle: [FrameKind]
    /// the capture kit recorder ran on every frame: its work per frame (ms, p50 and p95)
    var kitP50: Double?
    var kitP95: Double?
    var recording: Bool = false
    /// acquiring: the camera time to lock, every frame processed (median s)
    var lockSeconds: Double? = nil
    var note: String?
    /// regions grown per sweep (instrumented build only): mean, max, sweeps
    var regionsGrownMean: Double? = nil
    var regionsGrownMax: Int? = nil
    /// frames whose tracker output showed a ball (nil in reports from before it was counted)
    var ballShownFrames: Int? = nil

    func kind(_ k: FrameKind) -> KindSummary? { kinds.first { $0.kind == k } }

    static func summarise(scene: String, phase: String, state: Scenario.State, seconds: Double, samples: [FrameSample], note: String?,
                          recording: Bool = false) -> SessionResult {
        var ks: [KindSummary] = []
        let kit = samples.contains { $0.kit > 0 }
        for k in FrameKind.allCases {
            let s = samples.filter { $0.kind == k }
            guard !s.isEmpty else { continue }
            let rec = s.contains { $0.record > 0 || $0.encode > 0 }
            ks.append(KindSummary(kind: k, count: s.count, total: Stats(s.map { $0.total - $0.kit }), convertP50: Stats(s.map(\.convert)).p50,
                                  colorFrameP50: s.contains { $0.colorFrame > 0 } ? Stats(s.map(\.colorFrame)).p50 : nil,
                                  depthP50: Stats(s.map(\.depth)).p50, ballCropP50: Stats(s.map(\.ballCrop)).p50,
                                  slabCropP50: Stats(s.map(\.slabCrop)).p50, processP50: Stats(s.map(\.process)).p50,
                                  glueP50: Stats(s.map(\.glue)).p50, kitP50: kit ? Stats(s.map(\.kit)).p50 : nil,
                                  recordP50: rec ? Stats(s.map(\.record)).p50 : nil, encodeP50: rec ? Stats(s.map(\.encode)).p50 : nil,
                                  encodeP95: rec ? Stats(s.map(\.encode)).p95 : nil))
        }
        let ks2 = samples.filter { $0.kit > 0 }.map(\.kit)
        var r = SessionResult(scene: scene, phase: phase, state: state, seconds: seconds, frames: samples.count, kinds: ks,
                              detectionCycle: samples.filter { $0.kind.isDetection }.map { $0.kind.withoutBall },
                              kitP50: ks2.isEmpty ? nil : Stats(ks2).p50, kitP95: ks2.isEmpty ? nil : Stats(ks2).p95, recording: recording, note: note)
        r.ballShownFrames = samples.filter(\.ballShown).count
        let g = samples.compactMap(\.regionsGrown)
        if !g.isEmpty { r.regionsGrownMean = Double(g.reduce(0, +)) / Double(g.count); r.regionsGrownMax = g.max() }
        return r
    }
}

/// The time to lock with the app's pipeline deciding which frames the tracker sees (the frames that come while a slow
/// search runs wait in the hand-off, the latest replacing the others, which are dropped), at a given speed relative to
/// the CI Mac.
struct LockTimeResult: Codable {
    var scene: String
    /// time multiplier on this host's (measured) frame times: x1 = the CI Mac (or this host scaled to it)
    var scale: Double
    var label: String
    var runs: Int
    var locked: Int
    /// camera time to lock (s): median and max over the runs that locked
    var medianSeconds: Double?
    var maxSeconds: Double?
    /// per run: frames processed and dropped before the lock (means)
    var processed: Double
    var skipped: Double
}

/// The app's per-frame work (ARController.handle) on one scene, frame after frame at 60 fps of camera time, with the
/// app's tracker (its settings, SlabFinderDetector, BallLocator) and what the app hands it:
///   - the processing image (fromBiplanar + colorFrame) only when the tracker says the detector will run (or the
///     recording wants it); else the app's 2x2 blank;
///   - LiDAR depth (copied as FrameConversion.depth does) on every locked frame;
///   - the ball crop of the full image when the ball finder is due (BallImageCrop.plan + the app's lumaCrop);
///   - the slab's full-resolution crop on request (SlabImageCrop.provider + lumaCrop);
///   - ARKit's floor (y = 0) and normal tracking;
///   - the app's glue around it (AppGlue: pacer, format watch, capture-lock gate, overlay, HUD, developer line);
///   - optionally the session recorder (RecordingCadence) or the capture kit's recorder (KitWork).
/// The frame source gives the pixels and the camera's pose frame by frame: a still camera (rotating among copies of the
/// frame, so each frame's pixels come from memory as the camera's do), a drop, a hand, or a world frame that moved. The
/// time a frame takes does not change the clock (camera time is simulated) unless the run is paced (`acquirePaced`).
final class AppLoop {
    var source: (Int) -> BenchScene
    let crop: AppReplicas.CropVariant
    private(set) var tracker: SlabTracker
    private(set) var k = 0
    var recording: RecordingCadence?
    var kit: KitWork?
    private var glue = AppGlue()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let blank = ColorFrame(gray: Plane(width: 2, height: 2))

    init(source: @escaping (Int) -> BenchScene, crop: AppReplicas.CropVariant) {
        self.source = source; self.crop = crop
        tracker = SlabTracker(settings: RecordingSettings().trackerSettings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
    }

    convenience init(still frames: [BenchScene], crop: AppReplicas.CropVariant) {
        self.init(source: { frames[$0 % frames.count] }, crop: crop)
    }

    var time: Double { Double(k) / 60 }

    /// Skips frame k (the pacer said it was late): the tracker never sees it.
    func skip() { k += 1 }

    func step() -> (FrameSample, TrackerOutput) {
        let s = source(k), t = Double(k) / 60
        k += 1
        let t0 = nowNs()
        glue.arrived(t: t, width: s.width, height: s.height)
        let recImg = recording.map { $0.needsImage(at: t, tracker: tracker) } ?? false
        let needImage = tracker.detectionDue(at: t, tap: false) || recImg
        let ycc: YCCImage? = needImage ? s.processingImage() : nil
        let tc = nowNs()
        // as the app: the colour frame only when the detector will run (an image converted for the recording alone is not)
        let detects = tracker.detectorWillRun(at: t, tap: false, trackingNormal: true)
        let cf = (detects ? ycc?.colorFrame : nil) ?? AppLoop.blank
        let colorMs = ycc != nil && detects ? msSince(tc) : 0
        let convert = msSince(t0)

        let t1 = nowNs()
        var depth: (DepthMap, CameraIntrinsics)? = nil
        if tracker.state == .locked || recImg { depth = (s.depthFromBuffers(), s.depthIntrinsics) }
        let depthMs = msSince(t1)

        let t2 = nowNs()
        var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil, ballCrop: BallImageCrop? = nil
        if tracker.state == .locked, tracker.ballDue(at: t), let sl = tracker.slab, let c = BallImageCrop.plan(slab: sl, full: s.full),
           let p = s.lumaCrop(crop, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor),
           p.width == c.imageWidth, p.height == c.imageHeight {
            ballImage = p; ballK = c.intrinsics(full: s.full.intrinsics); ballCrop = c
        }
        let ballMs = msSince(t2)

        var slabNs: UInt64 = 0
        let v = crop
        let provider = SlabImageCrop.provider(processing: s.processing.intrinsics, full: s.full.intrinsics) { c in
            let tc = nowNs()
            defer { slabNs &+= nowNs() &- tc }
            return s.lumaCrop(v, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor)
        }
        let tf = TrackerFrame(timestamp: t, view: s.processing, frame: cf, depth: depth?.0, depthIntrinsics: depth?.1, ballImage: ballImage,
                              ballIntrinsics: ballK, tap: nil, floorY: 0, trackingNormal: true, slabDetail: provider)
        #if BENCH_SWEEP_STATS
        benchSweepLog.removeAll()
        #endif
        let t3 = nowNs()
        let out = tracker.process(tf)
        let processMs = msSince(t3)
        var grown: Int? = nil
        #if BENCH_SWEEP_STATS
        if !benchSweepLog.isEmpty { grown = benchSweepLog.map(\.grown).reduce(0, +) }
        #endif

        var recordMs = 0.0, encodeMs = 0.0
        if var rc = recording {
            let t4 = nowNs()
            let r = rc.record(tf, output: out, tracker: tracker, image: ycc, ballCrop: ballCrop)
            recording = rc
            recordMs = msSince(t4)
            // what SessionRecorder's queue then does with it (RecordingWriter.append, without the disk writes)
            let t5 = nowNs()
            blackHole(r.image?.data)
            blackHole(r.depth?.data)
            if let b = r.ball {
                let kk = [ballCrop?.factor ?? 1, 1, 2, 3, 4].first { $0 >= 1 && $0 <= 16 && b.isBlockAverage(of: $0) } ?? 16
                blackHole(b.pgmData(blockSum: kk))
            }
            if let sl = r.slab {
                let kk = [out.slabDetail?.crop.factor ?? 1, 1, 2, 3, 4].first { $0 >= 1 && $0 <= 16 && sl.isBlockAverage(of: $0) } ?? 16
                blackHole(sl.pgmData(blockSum: kk))
            }
            blackHole(try? encoder.encode(r.frame))
            encodeMs = msSince(t5)
        }
        var kitMs = 0.0
        if let kw = kit {
            let tk = nowNs()
            kw.consume(s, t: t)
            kitMs = msSince(tk)
        }
        let tg = nowNs()
        let soFar = msSince(t0) - encodeMs
        glue.after(out, full: s.full, t: t, processSeconds: soFar / 1000, ballRadius: tracker.settings.ball.radius)
        let glueMs = msSince(tg)
        let total = msSince(t0) - encodeMs   // the encoding is on the recorder's own queue, not the processing queue
        var kind = FrameKind.of(out)
        if kind == .plain && ycc != nil { kind = .plainImage }
        return (FrameSample(kind: kind, total: total, convert: convert, colorFrame: colorMs, depth: depthMs, ballCrop: ballMs,
                            slabCrop: Double(slabNs) / 1e6, process: processMs - Double(slabNs) / 1e6, glue: glueMs, kit: kitMs,
                            record: recordMs, encode: encodeMs, regionsGrown: grown, ballShown: out.ball != nil), out)
    }

    /// Frames until the tracker locks (at most `maxSeconds`); the samples and the camera time it took (nil: no lock).
    func acquire(maxSeconds: Double) -> (samples: [FrameSample], seconds: Double?) {
        let start = time
        var out: [FrameSample] = []
        while time - start < maxSeconds {
            let (smp, o) = step()
            out.append(smp)
            if o.state == .locked { return (out, time - start) }
        }
        return (out, nil)
    }

    /// The same with the app's pipeline deciding which frames are processed: frame i is captured at i/60 and reaches
    /// ARKit's delegate 30 ms later, which hands it to processing through BounceCore's FrameHandoff (taken at once if
    /// processing is idle, else it waits, replacing any frame already waiting; when a frame's processing ends, each
    /// taking its measured time x `scale`, the waiting frame is taken). The tracker sees only the processed frames (at
    /// their own capture times); the dropped ones are skipped. The time to lock runs to the end of the locking frame's
    /// handling.
    func acquirePaced(maxSeconds: Double, scale: Double, latency: Double = 0.03) -> (seconds: Double?, processed: Int, skipped: Int) {
        let h = FrameHandoff<Int>()
        let dt = 1.0 / 60, start = k
        var processed = 0, skipped = 0
        var busyUntil: Double? = nil, current = 0, out: TrackerOutput? = nil
        var i = start
        /// processes frame j from time t (the frames before it that were never processed are skipped); the lock time if
        /// it locked
        func run(_ j: Int, at t: Double) -> Double? {
            while k < j { skip(); skipped += 1 }
            let (smp, o) = step()
            processed += 1
            let end = t + smp.total * scale / 1000
            current = j; busyUntil = end; out = o
            // locked when the locking frame's handling ends (ARKit's own delivery delay left out)
            return o.state == .locked ? end - latency - Double(start) * dt : nil
        }
        while Double(i - start) * dt < maxSeconds {
            let c = Double(i) * dt, arrive = c + latency
            if let b = busyUntil, b <= arrive, let o = out {
                busyUntil = nil
                if let j = h.finished(captureTime: Double(current) * dt, seconds: 0, now: b, output: o), let lt = run(j, at: b) {
                    return (lt, processed, skipped)
                }
                continue
            }
            if let j = h.deliver(i, captureTime: c, now: arrive, nominalInterval: dt), let lt = run(j, at: arrive) {
                return (lt, processed, skipped)
            }
            i += 1
        }
        return (nil, processed, skipped)
    }

    func run(seconds: Double) -> [FrameSample] {
        let end = time + seconds
        var out: [FrameSample] = []
        while time < end { out.append(step().0) }
        return out
    }

    /// Runs until `until` says stop or `seconds` pass.
    func run(seconds: Double, until: (TrackerOutput) -> Bool) -> [FrameSample] {
        let end = time + seconds
        var out: [FrameSample] = []
        while time < end {
            let (s, o) = step()
            out.append(s)
            if until(o) { break }
        }
        return out
    }

    func reset() { tracker.reset() }
    func noteWorldDiscontinuity() { tracker.noteWorldDiscontinuity("bench") }
}

struct LoopConfig {
    var quick: Bool
    /// camera seconds of each locked run
    var lockedSeconds: Double
    var acquisitions: Int
    /// time multipliers for the paced lock times (relative to this host's measured times), with labels
    var pacedScales: [(Double, String)]
    var pacedRuns: Int
}

/// Runs the app loop over the scenes. On each plain slab scene: acquisitions (search to lock) unpaced and paced, and a
/// locked spell. With a ball held: after world discontinuities (the lock in view but where the world moved it; and the
/// lock out of view); a hand over a corner; a drop. On the empty and cluttered views: searching. On the 4 ft scene with a
/// ball held: the session recorder on, and the capture kit's recorder on.
func runAppLoops(scenes set: SceneSet, config cfg: LoopConfig, probe: (String) -> Void, log: (String) -> Void) -> (sessions: [SessionResult], lockTimes: [LockTimeResult]) {
    var results: [SessionResult] = []
    var lockTimes: [LockTimeResult] = []
    let crop = AppReplicas.CropVariant.app
    let L = cfg.lockedSeconds
    func searching(_ s: BenchScene) {
        let loop = AppLoop(still: s.ring(), crop: crop)
        _ = loop.run(seconds: 0.5)   // warm-up
        let smp = loop.run(seconds: cfg.quick ? 2 : 10)
        results.append(SessionResult.summarise(scene: s.name, phase: "searching", state: .searching, seconds: Double(smp.count) / 60, samples: smp,
                                               note: "\(loop.tracker.state.rawValue) at the end" + (loop.tracker.state == .locked ? " (a false lock on the floor)" : "")))
        log("  app loop \(s.name), searching: \(smp.count) frames, \(loop.tracker.state.rawValue) at the end")
    }
    /// a loop locked on `s` (rotating among copies of it), or nil
    func lockedLoop(_ s: BenchScene, _ ring: [BenchScene]) -> AppLoop? {
        let loop = AppLoop(still: ring, crop: crop)
        guard loop.acquire(maxSeconds: 4).seconds != nil else { return nil }
        _ = loop.run(seconds: 1)
        return loop
    }
    for s in set.scenes {
        if s.kind == .nothing { searching(s); probe("app loop, \(s.name)"); continue }
        let ring = s.ring()
        // a hand over a corner: locked on the clear view first, then the hand comes in (the same camera)
        if s.variant == .hand {
            guard let clear = set.scene(feet: s.feet, ball: true), let hl = lockedLoop(clear, clear.ring(4)) else { continue }
            hl.source = { ring[$0 % ring.count] }
            let smp = hl.run(seconds: L)
            let c = hl.tracker.counts
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, occluded", state: .locked, seconds: L, samples: smp,
                                                   note: "locked on the clear view, then the hand; re-check misses \(c["recheckMiss"] ?? 0), excused \(c["recheckMissExcused"] ?? 0); \(hl.tracker.state.rawValue) at the end"))
            log("  app loop \(s.name), occluded: \(smp.count) frames, \(hl.tracker.state.rawValue) at the end")
            probe("app loop, \(s.name)")
            continue
        }
        // warm-up: one lock and a second locked
        guard let loop = lockedLoop(s, ring) else {
            // never locks here: what searching costs on it
            log("  app loop \(s.name): did not lock in 4 s; timed as searching")
            searching(s)
            results[results.count - 1].note = "did not lock within 4 s (timed searching): " + (results[results.count - 1].note ?? "")
            continue
        }
        var acq: [FrameSample] = [], lt: [Double] = []
        for _ in 0..<cfg.acquisitions {
            loop.reset()
            let a = loop.acquire(maxSeconds: 4)
            acq += a.samples
            if let sec = a.seconds { lt.append(sec) }
        }
        let ltn = lt.isEmpty ? "never locked" : String(format: "locked %d of %d times, after %.2f s (median) of camera time, every frame processed",
                                                         lt.count, cfg.acquisitions, Stats(lt).p50)
        results.append(SessionResult.summarise(scene: s.name, phase: "acquiring", state: .searching, seconds: Double(acq.count) / 60, samples: acq, note: ltn))
        results[results.count - 1].lockSeconds = lt.isEmpty ? nil : Stats(lt).p50
        // paced: the pacer decides which frames the tracker sees
        for (scale, label) in cfg.pacedScales {
            var secs: [Double] = [], proc = 0, skip = 0
            for _ in 0..<cfg.pacedRuns {
                loop.reset()
                let p = loop.acquirePaced(maxSeconds: 8, scale: scale)
                if let x = p.seconds { secs.append(x) }
                proc += p.processed; skip += p.skipped
            }
            let st = secs.isEmpty ? nil : Stats(secs)
            lockTimes.append(LockTimeResult(scene: s.name, scale: scale, label: label, runs: cfg.pacedRuns, locked: secs.count, medianSeconds: st?.p50,
                                            maxSeconds: st?.max, processed: Double(proc) / Double(cfg.pacedRuns), skipped: Double(skip) / Double(cfg.pacedRuns)))
        }
        if loop.tracker.state != .locked { _ = loop.acquire(maxSeconds: 4) }
        _ = loop.run(seconds: 0.5)
        let lk = loop.run(seconds: s.variant == .plain ? L : L / 3)
        let c = loop.tracker.counts
        results.append(SessionResult.summarise(scene: s.name, phase: "locked", state: .locked, seconds: Double(lk.count) / 60, samples: lk,
                                               note: "ball found \(c["ballFrames"] ?? 0) times in all; \(loop.tracker.state.rawValue) at the end"))
        log("  app loop \(s.name): \(acq.count) acquiring + \(lk.count) locked frames; \(ltn)")
        guard s.variant == .plain, s.ballHeight != nil else { probe("app loop, \(s.name)"); continue }

        // after world discontinuities, the lock in view: ARKit's world moved by 12 cm under the lock (relocalised); the
        // re-checks follow the lock where it now projects (off the slab), every second one sweeps the whole view, and a
        // consistent slab elsewhere re-locks it. A new discontinuity every 3 s: the reported world 12 cm off, then back.
        do {
            var disc: [FrameSample] = []
            var n = 0, confirmed = 0
            let spell = 3.0
            let shifts = [Vec3(0.10, 0, -0.065), Vec3(0, 0, 0)]
            while Double(disc.count) / 60 < L {
                let cur = ring.map { $0.worldShifted(shifts[n % 2]) }
                loop.source = { cur[$0 % cur.count] }
                loop.noteWorldDiscontinuity()
                n += 1
                var wasUnconfirmed = false
                var spellSamples = 0
                while Double(spellSamples) / 60 < spell {
                    let (smp, o) = loop.step()
                    disc.append(smp); spellSamples += 1
                    if o.lockUnconfirmed { wasUnconfirmed = true } else if wasUnconfirmed && o.state == .locked { confirmed += 1; wasUnconfirmed = false }
                }
                if loop.tracker.state != .locked { _ = loop.acquire(maxSeconds: 4) }
            }
            let c = loop.tracker.counts
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, after world discontinuities", state: .locked, seconds: Double(disc.count) / 60,
                                                   samples: disc, note: "\(n) discontinuities (the world moved 12 cm each time), \(confirmed) re-confirmed within 3 s; "
                                                   + "relocks \(c["relocks"] ?? 0), discontinuities \(c["discontinuities"] ?? 0); \(loop.tracker.state.rawValue) at the end"))
            log("  app loop \(s.name), after discontinuities: \(disc.count) frames, \(n) discontinuities, \(confirmed) re-confirmed")
            loop.source = { ring[$0 % ring.count] }
            loop.reset()
            _ = loop.acquire(maxSeconds: 4)
            _ = loop.run(seconds: 1)
        }
        // after a discontinuity, the lock out of view (the camera turned to bare floor): every re-check sweeps the whole
        // view until the unconfirmed lock expires (unconfirmedTimeout, 5 s); measured for 4.9 s at a time
        if let empty = set.scene(feet: nil, ball: false) {
            let er = empty.ring(4)
            var out: [FrameSample] = []
            var reps = 0
            while Double(out.count) / 60 < L * 2 / 3 {
                if loop.tracker.state != .locked {
                    loop.source = { ring[$0 % ring.count] }
                    _ = loop.acquire(maxSeconds: 4)
                    _ = loop.run(seconds: 0.5)
                }
                loop.source = { er[$0 % er.count] }
                loop.noteWorldDiscontinuity()
                out += loop.run(seconds: 4.9)
                reps += 1
                loop.source = { ring[$0 % ring.count] }
                loop.reset()
            }
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, out of view after a discontinuity", state: .locked,
                                                   seconds: Double(out.count) / 60, samples: out,
                                                   note: "\(reps) times: locked here, a discontinuity, then the bare floor for 4.9 s (the lock unconfirmed, out of view)"))
            log("  app loop \(s.name), out of view: \(out.count) frames")
            _ = loop.acquire(maxSeconds: 4)
            _ = loop.run(seconds: 1)
        }
        // a drop: held 0.3 s, falling in 0.05 s steps, then gone (bounced away) for 0.4 s; repeated
        if let drop = s.feet.flatMap({ set.drops[$0] }), let none = set.scene(feet: s.feet, ball: false) {
            let hold = 18, step = 3, gone = 24
            let cycle = hold + step * (drop.count - 1) + gone
            loop.source = { k in
                let i = k % cycle
                if i < hold { return drop[0] }
                if i < hold + step * (drop.count - 1) { return drop[1 + (i - hold) / step] }
                return none
            }
            let smp = loop.run(seconds: L)
            let c = loop.tracker.counts
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, ball dropping", state: .locked, seconds: L, samples: smp,
                                                   note: "held 0.3 s, a \(drop.count - 1)-step fall (\(String(format: "%.2f", drop[0].ballHeight ?? 0)) m), gone 0.4 s, repeated; "
                                                   + "ball found \(c["ballFrames"] ?? 0) times in all; \(loop.tracker.state.rawValue) at the end"))
            log("  app loop \(s.name), drop: \(smp.count) frames")
            loop.source = { ring[$0 % ring.count] }
            _ = loop.run(seconds: 1)
        }
        // the recorders (4 ft, ball held)
        if s.feet == 4 {
            loop.recording = RecordingCadence()
            _ = loop.run(seconds: 0.5)
            let rk = loop.run(seconds: L)
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, recording", state: .locked, seconds: L, samples: rk,
                                                   note: "Record session on: RecordingCadence.record on the processing queue; the encoding (image, depth, crops, JSON line; no disk writes) on the recorder's queue",
                                                   recording: true))
            loop.recording = nil
            loop.kit = KitWork()
            _ = loop.run(seconds: 0.5)
            let kk = loop.run(seconds: L / 2)
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, capture kit recording", state: .locked, seconds: L / 2, samples: kk,
                                                   note: "the kit recorder's work (" + kitWhat + ") on every frame, kept apart from the kinds' times (kit p50/p95)"))
            loop.kit = nil
        }
        probe("app loop, \(s.name)")
    }
    return (results, lockTimes)
}

#if canImport(Accelerate)
let kitWhat = "vImage scale to 1440x1080, mean luma, depth once a second"
#else
let kitWhat = "a pure-Swift Lanczos stand-in for vImage's scale to 1440x1080 (much slower than vImage), mean luma, depth once a second"
#endif
