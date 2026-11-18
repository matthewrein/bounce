import BounceCore
import Foundation

/// What ran on a processed frame (as the frame pacer's diagnostics split them, with the coincidences apart).
enum FrameKind: String, Codable, CaseIterable {
    case plain = "plain (nothing due)"
    case ball = "ball scan"
    case recheck = "re-check"
    case recheckBall = "re-check + ball scan"
    case search = "search (nothing found)"
    case searchRefine = "search + refine on the crop"
    /// a plain frame whose image the session recorder keeps (converted for it alone)
    case plainImage = "plain + image for the recording"

    static func of(_ o: TrackerOutput) -> FrameKind {
        switch o.detectionKind {
        case .search?: return o.slabDetail != nil || o.refinedDetections != nil ? .searchRefine : .search
        case .recheck?: return o.ballSearched ? .recheckBall : .recheck
        case nil: return o.ballSearched ? .ball : .plain
        }
    }
    var isSearch: Bool { self == .search || self == .searchRefine }
    var isRecheck: Bool { self == .recheck || self == .recheckBall }
    var isBall: Bool { self == .ball || self == .recheckBall }
}

/// One processed frame's times (ms): the whole handling and its parts.
struct FrameSample {
    var kind: FrameKind
    var total: Double
    /// the image conversion (fromBiplanar + colorFrame), LiDAR copy, ball crop, slab crop (inside process), the tracker
    var convert: Double
    var depth: Double
    var ballCrop: Double
    var slabCrop: Double
    var process: Double
    /// the session recorder's work: on the processing queue (RecordingCadence.record), and its encoding (its own queue)
    var record: Double = 0
    var encode: Double = 0
}

struct KindSummary: Codable {
    var kind: FrameKind
    var count: Int
    var total: Stats
    /// medians of the parts (ms)
    var convertP50: Double
    var depthP50: Double
    var ballCropP50: Double
    var slabCropP50: Double
    var processP50: Double
    var recordP50: Double?
    var encodeP50: Double?
    var encodeP95: Double?
}

/// One run of the app's per-frame loop on one scene.
struct SessionResult: Codable {
    var scene: String
    /// searching (empty view), acquiring (search to lock, several times), locked, locked+recording
    var phase: String
    var seconds: Double
    var frames: Int
    var kinds: [KindSummary]
    var note: String?

    func kind(_ k: FrameKind) -> KindSummary? { kinds.first { $0.kind == k } }

    static func summarise(scene: String, phase: String, seconds: Double, samples: [FrameSample], note: String?) -> SessionResult {
        var ks: [KindSummary] = []
        for k in FrameKind.allCases {
            let s = samples.filter { $0.kind == k }
            guard !s.isEmpty else { continue }
            let rec = s.contains { $0.record > 0 || $0.encode > 0 }
            ks.append(KindSummary(kind: k, count: s.count, total: Stats(s.map(\.total)), convertP50: Stats(s.map(\.convert)).p50,
                                  depthP50: Stats(s.map(\.depth)).p50, ballCropP50: Stats(s.map(\.ballCrop)).p50,
                                  slabCropP50: Stats(s.map(\.slabCrop)).p50, processP50: Stats(s.map(\.process)).p50,
                                  recordP50: rec ? Stats(s.map(\.record)).p50 : nil, encodeP50: rec ? Stats(s.map(\.encode)).p50 : nil,
                                  encodeP95: rec ? Stats(s.map(\.encode)).p95 : nil))
        }
        return SessionResult(scene: scene, phase: phase, seconds: seconds, frames: samples.count, kinds: ks, note: note)
    }
}

/// The app's per-frame work (ARController.handle) on one scene, frame after frame at 60 fps of camera time, with the
/// app's tracker (its settings, SlabFinderDetector, BallLocator) and what the app hands it:
///   - the processing image (fromBiplanar + colorFrame) only when the tracker says the detector will run (or the
///     recording wants it); else the app's 2x2 blank;
///   - LiDAR depth (copied as FrameConversion.depth does) on every locked frame;
///   - the ball crop of the full image when the ball finder is due (BallImageCrop.plan + the app's lumaCrop);
///   - the slab's full-resolution crop on request (SlabImageCrop.provider + lumaCrop);
///   - ARKit's floor (y = 0) and normal tracking.
/// Not included (app code with no BounceCore part, small next to these): the overlay's projection, the HUD and developer
/// strings, the capture-lock gate, publishing to the main thread. The camera holds still (the same image every frame),
/// so the lock's re-checks find the same outline; the time a frame takes does not depend on the clock (camera time is
/// simulated), so the cadence is the app's exactly however slow this machine is.
final class AppLoop {
    let scene: BenchScene
    let crop: AppReplicas.CropVariant
    private(set) var tracker: SlabTracker
    private var k = 0
    var recording: RecordingCadence?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let blank = ColorFrame(gray: Plane(width: 2, height: 2))

    init(scene: BenchScene, crop: AppReplicas.CropVariant) {
        self.scene = scene; self.crop = crop
        tracker = SlabTracker(settings: RecordingSettings().trackerSettings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
    }

    var time: Double { Double(k) / 60 }

    func step() -> (FrameSample, TrackerOutput) {
        let s = scene, t = Double(k) / 60
        k += 1
        let t0 = nowNs()
        let recImg = recording.map { $0.needsImage(at: t, tracker: tracker) } ?? false
        let needImage = tracker.detectionDue(at: t, tap: false) || recImg
        let ycc: YCCImage? = needImage ? s.processingImage() : nil
        let cf = ycc?.colorFrame ?? AppLoop.blank
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
        let t3 = nowNs()
        let out = tracker.process(tf)
        let processMs = msSince(t3)

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
        let total = msSince(t0) - encodeMs   // the encoding is on the recorder's own queue, not the processing queue
        var kind = FrameKind.of(out)
        if kind == .plain && ycc != nil { kind = .plainImage }
        return (FrameSample(kind: kind, total: total, convert: convert, depth: depthMs, ballCrop: ballMs,
                            slabCrop: Double(slabNs) / 1e6, process: processMs - Double(slabNs) / 1e6, record: recordMs, encode: encodeMs), out)
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

    func run(seconds: Double) -> [FrameSample] {
        let end = time + seconds
        var out: [FrameSample] = []
        while time < end { out.append(step().0) }
        return out
    }

    func reset() { tracker.reset() }
}

/// Runs the app loop over the scenes: acquisitions (search to lock) and a locked spell on each slab scene, a searching
/// spell on the empty view, and a recorded locked spell.
func runAppLoops(scenes: [BenchScene], quick: Bool, log: (String) -> Void) -> [SessionResult] {
    var results: [SessionResult] = []
    let crop = AppReplicas.CropVariant.app
    let acquisitions = quick ? 2 : 6, lockedSeconds = quick ? 2.0 : 6.0, searchSeconds = quick ? 2.0 : 6.0
    for s in scenes {
        let loop = AppLoop(scene: s, crop: crop)
        if s.kind == .nothing {
            _ = loop.run(seconds: 0.5)   // warm-up
            let smp = loop.run(seconds: searchSeconds)
            let r = SessionResult.summarise(scene: s.name, phase: "searching", seconds: searchSeconds, samples: smp,
                                            note: "never locks: \(loop.tracker.state.rawValue) at the end")
            results.append(r)
            log("  app loop \(s.name), searching: \(smp.count) frames")
            continue
        }
        // warm-up: one lock and a second locked
        let w = loop.acquire(maxSeconds: 4)
        guard w.seconds != nil else {
            log("  app loop \(s.name): did not lock in 4 s (state \(loop.tracker.state.rawValue)); left out")
            results.append(SessionResult(scene: s.name, phase: "acquiring", seconds: 4, frames: w.samples.count, kinds: [],
                                         note: "did not lock within 4 s: no locked timings"))
            continue
        }
        _ = loop.run(seconds: 1)
        var acq: [FrameSample] = [], lockTimes: [Double] = []
        for _ in 0..<acquisitions {
            loop.reset()
            let a = loop.acquire(maxSeconds: 4)
            acq += a.samples
            if let sec = a.seconds { lockTimes.append(sec) }
        }
        let lt = lockTimes.isEmpty ? "never locked" : String(format: "locked %d of %d times, after %.2f s (median) of camera time", lockTimes.count, acquisitions,
                                                             Stats(lockTimes).p50)
        results.append(SessionResult.summarise(scene: s.name, phase: "acquiring", seconds: acq.count > 0 ? Double(acq.count) / 60 : 0, samples: acq, note: lt))
        if loop.tracker.state != .locked { _ = loop.acquire(maxSeconds: 4) }
        _ = loop.run(seconds: 0.5)
        let lk = loop.run(seconds: lockedSeconds)
        let c = loop.tracker.counts
        results.append(SessionResult.summarise(scene: s.name, phase: "locked", seconds: lockedSeconds, samples: lk,
                                               note: "ball frames found the ball \(c["ballFrames"] ?? 0) times in all; state at the end \(loop.tracker.state.rawValue)"))
        log("  app loop \(s.name): \(acq.count) acquiring + \(lk.count) locked frames; \(lt)")
        // the session recorder on (4 ft, ball held)
        if s.feet == 4 && s.ballHeight != nil {
            loop.recording = RecordingCadence()
            _ = loop.run(seconds: 0.5)
            let rk = loop.run(seconds: lockedSeconds)
            results.append(SessionResult.summarise(scene: s.name, phase: "locked, recording", seconds: lockedSeconds, samples: rk,
                                                   note: "Record session on: RecordingCadence.record on the processing queue; the encoding (image, depth, crops, JSON line; no disk writes) on the recorder's queue"))
            loop.recording = nil
        }
    }
    return results
}
