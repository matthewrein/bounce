import XCTest
@testable import BounceCore

/// The frame pipeline's pure parts: skipping late frames (`FramePacer`), locking the camera only once it has settled
/// (`CaptureLockGate`), and noticing a change of video format (`VideoFormatWatch`).
final class FramePacingTests: XCTestCase {
    // MARK: FramePacer

    /// ARKit's delivery as the app sees it: frames captured every `interval`, each reaching the serial processing queue
    /// `latency(i)` after capture, handled one at a time; a processed frame takes `work(i)` seconds, a skipped one
    /// `skipCost`. Returns, per frame, when it was handled and the pacer's decision.
    struct QueueSim {
        var interval = 1.0 / 60
        var latency: (Int) -> Double = { _ in 0.03 }
        var work: (Int) -> Double = { _ in 0.005 }
        var skipCost = 0.0002
        /// tell the pacer about `skipCost` (`skippedFrameHandled`), as the app does when it still records a skipped frame
        var reportSkipCost = false
        var pace = true
        var start = 1000.0

        func run(_ n: Int, pacer: inout FramePacer) -> [(capture: Double, handled: Double, processed: Bool)] {
            var free = 0.0
            var out: [(Double, Double, Bool)] = []
            for i in 0..<n {
                let c = start + Double(i) * interval
                let handled = max(c + latency(i), free)
                let d = pacer.frameArrived(captureTime: c, now: handled, nominalInterval: interval)
                let process = !pace || d == .process
                if process {
                    let w = work(i)
                    pacer.frameProcessed(captureTime: c, seconds: w, search: i % 7 == 0, recheck: i % 18 == 0, ball: i % 6 == 0)
                    free = handled + w
                } else {
                    free = handled + skipCost
                    if reportSkipCost { pacer.skippedFrameHandled(seconds: skipCost) }
                }
                out.append((c, handled, process))
            }
            return out
        }
    }

    func testKeepingUpProcessesEveryFrameWhateverARKitsOwnLatency() {
        // ARKit's own latency here is about two 60 fps frames (33 ms, with jitter): that is not lateness
        var p = FramePacer()
        var sim = QueueSim()
        sim.latency = { i in 0.033 + 0.003 * sin(Double(i) * 1.7) }
        let r = sim.run(600, pacer: &p)
        XCTAssertTrue(r.allSatisfy { $0.processed })
        let rep = p.report
        XCTAssertEqual(rep.total.framesReceived, 600)
        XCTAssertEqual(rep.total.framesProcessed, 600)
        XCTAssertEqual(rep.total.framesSkippedLate, 0)
        XCTAssertEqual(rep.total.cameraGaps, 0)
        XCTAssertEqual(rep.total.deliveryLatencyMs?.p50 ?? 0, 33, accuracy: 1)
        XCTAssertLessThan(rep.total.deliveryLatencyMs?.max ?? 99, 36.5)
        XCTAssertEqual(rep.baselineLatencyMs ?? 0, 30.5, accuracy: 1.5, "a low percentile of the latencies")
        XCTAssertEqual(rep.nominalFrameIntervalMs ?? 0, 16.67, accuracy: 0.01)
        XCTAssertEqual(rep.total.processingOverruns, 0)
    }

    func testFramesThatQueuedBehindSlowProcessingAreSkipped() {
        // processing takes 40 ms (2.4 frames at 60 fps): without skipping, every frame waits longer than the last and the
        // queue (and ARKit's retained frames) grows without bound; with it, the frames that waited are dropped quickly
        // and the freshest is processed
        var sim = QueueSim()
        sim.latency = { _ in 0.025 }
        sim.work = { _ in 0.040 }
        var unpaced = FramePacer(); sim.pace = false
        let a = sim.run(300, pacer: &unpaced)
        XCTAssertGreaterThan(a.last!.handled - a.last!.capture, 2.0, "unpaced, the 300th frame is handled seconds late")

        var p = FramePacer(); sim.pace = true
        let b = sim.run(1200, pacer: &p)
        let rep = p.report
        XCTAssertGreaterThan(rep.total.framesSkippedLate, 600)
        XCTAssertEqual(rep.total.framesProcessed + rep.total.framesSkippedLate, 1200)
        // processed frames (after the baseline settles) were at most about one frame later than the latency the baseline
        // sees (with the queue never empty, that is a little above ARKit's own)
        let ages = b.dropFirst(30).filter { $0.processed }.map { $0.handled - $0.capture }
        let base = (rep.baselineLatencyMs ?? 0) / 1000
        print(String(format: "pacer at 40 ms per frame: baseline %.1f ms, late after %.1f ms, processed frames' latency max %.1f ms, all frames max %.1f ms, %.1f processed/s, skipped %d of 1200",
                     base * 1000, rep.lateAfterMs ?? 0, ages.max()! * 1000, b.map { $0.handled - $0.capture }.max()! * 1000,
                     rep.total.processedPerSecond, rep.total.framesSkippedLate))
        XCTAssertGreaterThanOrEqual(base, 0.025 - 1e-9)
        XCTAssertLessThan(base, 0.025 + 1.0 / 60)
        XCTAssertLessThanOrEqual(ages.max()!, base + 1.0 / 60 + 1e-6)
        // the queue never grows (once there are frames to judge by): no frame waits much more than one processing time
        XCTAssertLessThan(b.dropFirst(30).map { $0.handled - $0.capture }.max()!, 0.025 + 0.040 + 2.0 / 60)
        XCTAssertEqual(rep.total.processingOverruns, rep.total.framesProcessed, "40 ms overruns a 16.7 ms frame")
        XCTAssertGreaterThan(rep.total.processedPerSecond, 18)
        XCTAssertLessThanOrEqual(rep.total.processedPerSecond, 25.1, "at most one frame per 40 ms of work")
        XCTAssertEqual(rep.total.framesProcessedLate, 0)
        XCTAssertLessThanOrEqual(rep.longestSkipRun, Int(FramePacer.Rule().maxUnprocessedSeconds * 60), "the start's backlog, drained")
        XCTAssertLessThanOrEqual(rep.recent.longestUnprocessedMs, 0.040 * 1000 + 2 * 1000.0 / 60)
    }

    func testWorkOnSkippedFramesIsNotTakenForARKitsLatency() {
        // while the capture kit records, the app still hands skipped frames to the kit's recorder (12 ms of scaling each):
        // a frame that waited behind that work did not reach an idle handler. Told so, the pacer keeps ARKit's own latency
        // (25 ms) as its baseline and keeps processed frames fresh; not told, it takes the waits for latency
        var sim = QueueSim()
        sim.latency = { _ in 0.025 }
        sim.work = { _ in 0.040 }
        sim.skipCost = 0.012
        func run(report: Bool, skipCost: Double = 0.012) -> (base: Double, maxAge: Double, skipped: Int) {
            var p = FramePacer(); var s = sim; s.reportSkipCost = report; s.skipCost = skipCost
            let r = s.run(1200, pacer: &p)
            let ages = r.dropFirst(300).filter { $0.processed }.map { $0.handled - $0.capture }
            return ((p.report.baselineLatencyMs ?? 0) / 1000, ages.max() ?? 0, p.report.total.framesSkippedLate)
        }
        let told = run(report: true), untold = run(report: false)
        print(String(format: "pacer, 12 ms of work on skipped frames: told: baseline %.1f ms, processed latency max %.1f ms, skipped %d; "
                     + "not told: baseline %.1f ms, max %.1f ms, skipped %d", told.base * 1000, told.maxAge * 1000, told.skipped,
                     untold.base * 1000, untold.maxAge * 1000, untold.skipped))
        XCTAssertEqual(told.base, 0.025, accuracy: 0.001)
        XCTAssertLessThanOrEqual(told.maxAge, told.base + 1.0 / 60 + 1e-6)
        XCTAssertGreaterThan(untold.base, told.base + 0.001, "without being told, waits look like latency")
        // work the pacer is not told of, but shorter than its idle margin (half a frame interval, as other work on the
        // queue might be): a frame that waited behind it still does not pass for idle, so the backlog is still skipped
        let short = run(report: false, skipCost: 0.008)
        XCTAssertEqual(short.base, 0.025, accuracy: 0.001)
        XCTAssertLessThanOrEqual(short.maxAge, short.base + 1.0 / 60 + 1e-6)
        // a skipped frame's work is in no statistics
        var p = FramePacer()
        XCTAssertEqual(p.frameArrived(captureTime: 1, now: 1.02, nominalInterval: 1.0 / 60), .process)
        p.skippedFrameHandled(seconds: 0.5)   // not after a skip: ignored
        p.frameProcessed(captureTime: 1, seconds: 0.005, search: false, recheck: false, ball: false)
        XCTAssertEqual(p.report.total.framesProcessed, 1)
        XCTAssertEqual(p.report.total.processingMs?.max ?? 0, 5, accuracy: 0.01)
    }

    func testAWrongBaselineCanDelayButNeverStopProcessing() {
        // the latency jumps for good from 20 ms to 220 ms (as if one clock jumped). With the handler idle, nothing waited
        // in the queue: every frame is processed (late, but ARKit's lateness, not the app's) and the baseline follows
        var p = FramePacer()
        var sim = QueueSim()
        sim.latency = { i in i < 300 ? 0.020 : 0.220 }
        let r = sim.run(900, pacer: &p)
        XCTAssertTrue(r.allSatisfy { $0.processed })
        XCTAssertEqual(p.report.total.framesSkippedLate, 0)
        XCTAssertGreaterThan(p.report.total.framesLateButIdle, 0, "the frames after the jump came late to an idle handler")
        XCTAssertEqual(p.report.total.framesProcessedLate, 0)
        XCTAssertEqual(p.report.baselineLatencyMs ?? 0, 220, accuracy: 1)

        // the same jump while the queue never empties (each frame handed over just as the last one's handling ended, so
        // none reached an idle handler and the baseline cannot follow): every frame after the jump looks late and waited,
        // but one is processed at least every 0.25 s
        var q = FramePacer()
        let dt = 1.0 / 60, busy = dt - 0.0005
        var lastProcessed = 0.0, longest = 0.0
        for i in 0..<900 {
            let c = Double(i) * dt
            let d = q.frameArrived(captureTime: c, now: c + (i < 60 ? 0.020 : 0.300), nominalInterval: dt)
            if d == .process {
                // (the frame before the jump keeps the handler busy until the next one is handed over, 0.28 s later)
                q.frameProcessed(captureTime: c, seconds: busy + (i == 59 ? 0.28 : 0), search: false, recheck: false, ball: false)
                longest = max(longest, c - lastProcessed); lastProcessed = c
            } else {
                q.skippedFrameHandled(seconds: busy)
            }
        }
        let rep = q.report
        print(String(format: "pacer, latency jump with the queue never empty: %d skipped, %d processed late, longest unprocessed %.0f ms",
                     rep.total.framesSkippedLate, rep.total.framesProcessedLate, rep.total.longestUnprocessedMs))
        XCTAssertGreaterThan(rep.total.framesSkippedLate, 500)
        XCTAssertGreaterThan(rep.total.framesProcessedLate, 0, "late frames processed to keep going")
        XCTAssertLessThanOrEqual(longest, FramePacer.Rule().maxUnprocessedSeconds + dt + 1e-9)
        XCTAssertEqual(rep.total.framesLateButIdle, 0)

        // a constant offset between the two clocks is absorbed by the baseline
        var o = FramePacer()
        var sim2 = QueueSim()
        sim2.latency = { _ in 1e5 }
        XCTAssertTrue(sim2.run(300, pacer: &o).allSatisfy { $0.processed })
    }

    func testFramesARKitDeliveredLateToAnIdleHandlerAreProcessed() {
        // processing keeps up (5 ms a frame) but ARKit's own latency varies by more than a frame: 30 ms, or 48.5 ms for
        // about a third of the frames. Nothing waited in the queue, so nothing is skipped; the late deliveries are counted
        // apart (ARKit's lateness, not the app's)
        var p = FramePacer()
        var sim = QueueSim()
        sim.latency = { i in (i * 7919) % 10 < 3 ? 0.0485 : 0.030 }
        let r = sim.run(1200, pacer: &p)
        XCTAssertTrue(r.allSatisfy { $0.processed })
        var rep = p.report
        XCTAssertEqual(rep.total.framesSkippedLate, 0)
        XCTAssertGreaterThan(rep.total.framesLateButIdle, 300)
        XCTAssertEqual(rep.total.framesProcessedLate, 0)
        XCTAssertEqual(rep.baselineLatencyMs ?? 0, 30, accuracy: 0.5)

        // ARKit's latency steps up for good, from 25 to 45 ms (more load, a warmer phone): every frame is processed,
        // none waits for the baseline to catch up
        var q = FramePacer()
        sim.latency = { i in i < 600 ? 0.025 : 0.045 }
        XCTAssertTrue(sim.run(1200, pacer: &q).allSatisfy { $0.processed })
        rep = q.report
        XCTAssertEqual(rep.total.framesSkippedLate, 0)
        XCTAssertGreaterThan(rep.total.framesLateButIdle, 0)
        XCTAssertEqual(rep.baselineLatencyMs ?? 0, 45, accuracy: 0.5, "the baseline follows within its window")

        // the same latencies, 25-45 ms, with processing slower than the camera (40 ms a frame): frames that waited
        // behind it are skipped as before, and the queue never grows
        var b = FramePacer()
        var slow = QueueSim()
        slow.work = { _ in 0.040 }
        slow.latency = { i in 0.025 + 0.020 * (0.5 + 0.5 * sin(Double(i) * 2.3)) }
        let s = slow.run(1200, pacer: &b)
        rep = b.report
        XCTAssertGreaterThan(rep.total.framesSkippedLate, 600)
        XCTAssertLessThan(s.dropFirst(30).map { $0.handled - $0.capture }.max()!, 0.045 + 0.040 + 2.0 / 60)
        XCTAssertLessThanOrEqual(rep.recent.longestUnprocessedMs, 0.040 * 1000 + 2 * 1000.0 / 60)
    }

    func testPausesAreNotFramesTheCameraMissed() {
        let dt = 1.0 / 60
        var p = FramePacer()
        var c = 100.0
        func frames(_ n: Int) { for _ in 0..<n { _ = p.frameArrived(captureTime: c, now: c + 0.03, nominalInterval: dt); p.frameProcessed(captureTime: c, seconds: 0.004, search: false, recheck: false, ball: false); c += dt } }
        frames(120)
        // the session interrupted for 5 s (a call, the app in the background): one pause, no frames missed
        c += 5
        frames(120)
        var rep = p.report
        XCTAssertEqual(rep.total.pauses, 1)
        XCTAssertEqual(rep.total.pausedSeconds, 5 + dt, accuracy: 0.01)
        XCTAssertEqual(rep.total.cameraGaps, 0)
        XCTAssertEqual(rep.total.framesMissedByCamera, 0)
        XCTAssertLessThan(rep.total.longestUnprocessedMs, 2 * dt * 1000)
        XCTAssertEqual(rep.total.framesProcessed, 240)
        // a re-run with another format (the capture kit opening): the app says so just before; its 0.3 s stop is a pause
        p.expectPause(at: c)
        frames(10)
        c += 0.3
        frames(60)
        rep = p.report
        XCTAssertEqual(rep.total.pauses, 2)
        XCTAssertEqual(rep.total.cameraGaps, 0)
        XCTAssertEqual(rep.recent.pauses, 2)
        XCTAssertLessThan(rep.total.longestUnprocessedMs, 2 * dt * 1000)
        // the same stop without a re-run asked for, or after the window: frames the camera missed
        c += 0.3
        frames(60)
        p.expectPause(at: c)
        c += 1.2
        frames(1)
        c += 0.3
        frames(10)
        rep = p.report
        XCTAssertEqual(rep.total.pauses, 3, "1.2 s is a pause anyway")
        XCTAssertEqual(rep.total.cameraGaps, 2)
        XCTAssertEqual(rep.total.framesMissedByCamera, 2 * 18)
        // the demo's timer drops ticks while a frame takes longer than its interval: no camera missed them
        var demo = FramePacer()
        demo.rule.countsCameraGaps = false
        for i in 0..<100 { _ = demo.frameArrived(captureTime: Double(i) * 0.16, now: Double(i) * 0.16, nominalInterval: 0.08) }
        XCTAssertEqual(demo.report.total.cameraGaps, 0)
        XCTAssertEqual(demo.report.total.pauses, 0)
    }

    func testProcessingTimesByWhatRan() {
        // searches take 80 ms, re-checks 25 ms, ball-only frames 8 ms, the rest 3 ms: the overall p95 mixes them, the kinds
        // keep them apart
        var p = FramePacer()
        let dt = 1.0 / 60
        for i in 0..<600 {
            let c = Double(i) * dt
            guard p.frameArrived(captureTime: c, now: c + 0.03, nominalInterval: dt) == .process else { continue }
            let search = i < 120 && i % 7 == 0, recheck = i >= 120 && i % 18 == 0, ball = i >= 120 && i % 6 == 0
            p.frameProcessed(captureTime: c, seconds: search ? 0.080 : recheck ? 0.025 : ball ? 0.008 : 0.003, search: search, recheck: recheck, ball: ball)
        }
        let k = p.report.total.processingByKind
        XCTAssertEqual(k.search?.p50 ?? 0, 80, accuracy: 0.5)
        XCTAssertEqual(k.recheck?.p95 ?? 0, 25, accuracy: 0.5)
        XCTAssertEqual(k.ball?.max ?? 0, 8, accuracy: 0.5)
        XCTAssertEqual(k.plain?.p95 ?? 0, 3, accuracy: 0.5)
        XCTAssertEqual(p.report.recent.processingByKind.search?.max ?? 0, 80, accuracy: 0.01)
        XCTAssertNil(FramePacer().report.total.processingByKind.search)
    }

    func testCameraGapsAndARestartedClock() {
        var p = FramePacer()
        let dt = 1.0 / 60
        var times = (0..<100).map { 50 + Double($0) * dt }
        times.removeSubrange(40..<43)       // three frames never delivered
        times.removeSubrange(70..<71)       // and one more
        for c in times { _ = p.frameArrived(captureTime: c, now: c + 0.02, nominalInterval: dt) }
        var rep = p.report
        XCTAssertEqual(rep.total.cameraGaps, 2)
        XCTAssertEqual(rep.total.framesMissedByCamera, 4)
        XCTAssertEqual(rep.recent.cameraGaps, 2)
        // a new session's clock starts lower: no gap, no skipping, the estimate starts again
        XCTAssertEqual(p.frameArrived(captureTime: 10, now: 10.5, nominalInterval: dt), .process)
        for i in 1..<20 { XCTAssertEqual(p.frameArrived(captureTime: 10 + Double(i) * dt, now: 10.5 + Double(i) * dt, nominalInterval: dt), .process) }
        rep = p.report
        XCTAssertEqual(rep.total.cameraGaps, 2)
        // a camera slower than its format (30 fps delivered in a 60 fps format): every step is a gap of one frame against
        // the nominal interval, and the skip rule's interval follows the frames, so a frame is not late for that
        var s = FramePacer()
        for i in 0..<120 {
            XCTAssertEqual(s.frameArrived(captureTime: Double(i) / 30, now: Double(i) / 30 + 0.02 + (i % 2 == 0 ? 0.02 : 0), nominalInterval: dt), .process)
        }
        XCTAssertEqual(s.effectiveInterval, 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(s.report.total.cameraGaps, 119)
        XCTAssertEqual(s.report.total.framesMissedByCamera, 119)
    }

    func testDetectionRatesRecentAndTotal() {
        var p = FramePacer()
        var sim = QueueSim()
        sim.work = { i in i % 10 == 0 ? 0.030 : 0.004 }
        _ = sim.run(60 * 25, pacer: &p)    // 25 s
        let rep = p.report
        XCTAssertEqual(rep.total.seconds, 25, accuracy: 0.05)
        XCTAssertEqual(rep.recent.seconds, FramePacer.Rule().recentSeconds, accuracy: 0.05)
        XCTAssertTrue((600...601).contains(rep.recent.framesReceived), "\(rep.recent.framesReceived)")
        XCTAssertEqual(rep.total.searchesPerSecond, 60.0 / 7, accuracy: 0.1)
        XCTAssertEqual(rep.total.rechecksPerSecond, 60.0 / 18, accuracy: 0.1)
        XCTAssertEqual(rep.total.ballSearchesPerSecond, 10, accuracy: 0.1)
        XCTAssertEqual(rep.recent.searchesPerSecond, 60.0 / 7, accuracy: 0.2)
        XCTAssertEqual(rep.total.processingOverruns, 150, "every 10th frame took 30 ms")
        XCTAssertEqual(rep.total.processingMs?.p50 ?? 0, 4, accuracy: 0.5)
        XCTAssertEqual(rep.total.processingMs?.max ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(rep.recent.processingMs?.p95 ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(rep.total.longestUnprocessedMs, 16.7, accuracy: 0.1)
    }

    func testTheReportIsInTheDiagnosticsJSON() throws {
        var p = FramePacer()
        var sim = QueueSim(); sim.work = { _ in 0.04 }
        _ = sim.run(200, pacer: &p)
        var rep = DiagnosticsReport(build: "t", device: "d", system: "s", time: "now", settings: RecordingSettings(), state: "searching",
                                    tracking: "normal", fps: 30, msProcess: 1, lens: nil, depthSupported: false, depth: nil, captureLocked: false,
                                    slab: nil, outline: nil, sideModes: [], ball: nil, readouts: nil, counts: [:], recentEvents: [], recording: nil)
        rep.framePacing = p.report
        rep.captureLockSettle = CaptureLockGate.Lock(armedAt: 1, lockedAt: 1.4, waitedSeconds: 0.4, timedOut: false, stillAdjusting: [])
        rep.slabCrop = SlabImageCrop(x0: 10, y0: 20, width: 400, height: 300, factor: 1)
        rep.videoFormatChanges = 1
        rep.videoFormatChange = VideoFormatWatch.Change(from: .init(width: 1920, height: 1440, framesPerSecond: 60),
                                                        to: .init(width: 1280, height: 960, framesPerSecond: 60), at: 3)
        let json = rep.json(pretty: true)
        for key in ["framePacing", "framesSkippedLate", "framesMissedByCamera", "deliveryLatencyMs", "processingMs", "searchesPerSecond",
                    "rechecksPerSecond", "ballSearchesPerSecond", "processingOverruns", "baselineLatencyMs", "lateAfterMs", "recent", "total",
                    "captureLockSettle", "slabCrop", "videoFormatChange", "framesLateButIdle", "pauses", "processingByKind"] {
            XCTAssertTrue(json.contains("\"\(key)\""), key)
        }
        let back = try DiagnosticsReport.decode(json: json)
        XCTAssertEqual(back.framePacing, rep.framePacing)
        XCTAssertEqual(back.captureLockSettle, rep.captureLockSettle)
        XCTAssertEqual(back.videoFormatChange, rep.videoFormatChange)
        XCTAssertGreaterThan(back.framePacing?.total.framesSkippedLate ?? 0, 0)
        // an older report without these still decodes
        var old = rep
        old.framePacing = nil; old.captureLockSettle = nil; old.slabCrop = nil; old.videoFormatChange = nil; old.videoFormatChanges = nil
        let o = try DiagnosticsReport.decode(json: old.json())
        XCTAssertNil(o.framePacing)
        XCTAssertFalse(old.json().contains("framesSkippedLate"))
    }

    // MARK: CaptureLockGate

    let still = CaptureLockGate.Adjusting.none
    let exposing = CaptureLockGate.Adjusting(focus: false, exposure: true, whiteBalance: false)

    /// Feeds frames at 30 fps from t0 for `seconds`, with what the camera adjusts at each time; returns the first command.
    func run(_ g: inout CaptureLockGate, from t0: Double, seconds: Double, adjusting: (Double) -> CaptureLockGate.Adjusting) -> (Double, CaptureLockGate.Command)? {
        var t = t0
        while t < t0 + seconds {
            if let c = g.update(at: t, adjusting: adjusting(t)) { return (t, c) }
            t += 1.0 / 30
        }
        return nil
    }

    func testLocksOnlyOnceTheCameraHasSettled() {
        var g = CaptureLockGate()
        XCTAssertNil(g.update(at: 9.9, adjusting: exposing))
        XCTAssertNil(g.note(events: ["candidate"], at: 9.95))
        XCTAssertNil(g.note(events: ["locked"], at: 10))
        XCTAssertEqual(g.armedAt, 10)
        // exposure still adjusting for 0.5 s after the lock, then quiet
        let r = run(&g, from: 10, seconds: 3) { $0 < 10.5 ? self.exposing : self.still }
        let (t, c) = try! XCTUnwrap(r)
        guard case .lock(let l) = c else { return XCTFail("\(c)") }
        XCTAssertGreaterThanOrEqual(t, 10.5 + 0.3 - 1e-9)
        XCTAssertLessThan(t, 10.5 + 0.3 + 0.07)
        XCTAssertFalse(l.timedOut)
        XCTAssertEqual(l.armedAt, 10); XCTAssertEqual(l.waitedSeconds, t - 10, accuracy: 1e-9)
        XCTAssertTrue(l.description.hasPrefix("capture locked after"), l.description)
        XCTAssertTrue(g.locked)
        XCTAssertEqual(g.lastLock, l)
        // a relock is the same scene: nothing to do
        XCTAssertNil(g.note(events: ["relocked"], at: 12))
        XCTAssertNil(g.update(at: 12.1, adjusting: still))

        // already settled before the lock: it locks on the next frame (but needs a few frames of evidence at least)
        var h = CaptureLockGate()
        for i in 0..<20 { _ = h.update(at: Double(i) / 30, adjusting: still) }
        _ = h.note(events: ["locked"], at: 0.7)
        guard case .lock(let l2)? = h.update(at: 0.7, adjusting: still) else { return XCTFail() }
        XCTAssertEqual(l2.waitedSeconds, 0)
    }

    func testGivesUpWaitingAndSaysWhatWasStillAdjusting() {
        var g = CaptureLockGate()
        _ = g.note(events: ["locked"], at: 5)
        // exposure keeps adjusting, and focus flickers on and off: never settled
        let r = run(&g, from: 5, seconds: 4) { t in
            CaptureLockGate.Adjusting(focus: Int(t * 30) % 2 == 0, exposure: true, whiteBalance: false)
        }
        let (t, c) = try! XCTUnwrap(r)
        guard case .lock(let l) = c else { return XCTFail("\(c)") }
        XCTAssertEqual(t, 5 + CaptureLockGate.Rule().timeoutSeconds, accuracy: 1.0 / 30 + 1e-9)
        XCTAssertTrue(l.timedOut)
        XCTAssertTrue(l.stillAdjusting.contains("exposure"))
        XCTAssertTrue(l.description.contains("exposure"), l.description)
        XCTAssertTrue(l.description.contains("timeout"), l.description)
    }

    func testANewSearchDisarmsAndUnlocks() {
        for ev in ["tap", "lost", "lock-expired"] {
            // before it locked: disarmed, no lock later
            var g = CaptureLockGate()
            _ = g.note(events: ["locked"], at: 1)
            XCTAssertNil(g.note(events: [ev], at: 1.1), "nothing was locked yet")
            XCTAssertNil(g.armedAt)
            XCTAssertNil(run(&g, from: 1.1, seconds: 4) { _ in self.still }, ev)
            // after it locked: back to auto
            _ = g.note(events: ["locked"], at: 6)
            XCTAssertNotNil(run(&g, from: 6, seconds: 1) { _ in self.still })
            XCTAssertEqual(g.note(events: [ev], at: 8), .unlock(reason: ev))
            XCTAssertFalse(g.locked)
        }
        // the app's reset
        var g = CaptureLockGate()
        _ = g.note(events: ["locked"], at: 1)
        _ = run(&g, from: 1, seconds: 1) { _ in self.still }
        XCTAssertEqual(g.disarm(), .unlock(reason: "reset"))
        XCTAssertNil(g.disarm())
    }

    func testAReconfiguredCameraIsUnlockedAndLockedAgainOnceTheLockIsConfirmed() {
        var g = CaptureLockGate()
        _ = g.note(events: ["locked"], at: 1)
        _ = run(&g, from: 1, seconds: 1) { _ in self.still }
        XCTAssertTrue(g.locked)
        // the kit opened: ARKit re-ran with another format; the tracker's lock is unconfirmed
        XCTAssertEqual(g.captureReconfigured(at: 3), .unlock(reason: "reconfigured"))
        XCTAssertTrue(g.awaitingConfirmation)
        XCTAssertNil(g.note(events: ["lock-unconfirmed: video-format"], at: 3))
        XCTAssertNil(run(&g, from: 3, seconds: 1) { _ in self.still }, "not before the tracker confirms its lock")
        XCTAssertNil(g.note(events: ["ok", "lock-confirmed"], at: 4.2))
        XCTAssertEqual(g.armedAt, 4.2)
        let r = run(&g, from: 4.2, seconds: 2) { t in t < 4.4 ? CaptureLockGate.Adjusting(focus: true, exposure: false, whiteBalance: false) : self.still }
        guard case .lock(let l)? = r?.1 else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(l.lockedAt, 4.7 - 1e-9)

        // reconfigured, and the lock is lost instead of confirmed: no lock
        var h = CaptureLockGate()
        _ = h.note(events: ["locked"], at: 1)
        _ = run(&h, from: 1, seconds: 1) { _ in self.still }
        _ = h.captureReconfigured(at: 3)
        XCTAssertNil(h.note(events: ["lock-expired", "lost"], at: 8))
        XCTAssertNil(run(&h, from: 8, seconds: 3) { _ in self.still })
        XCTAssertFalse(h.locked)
        // nothing armed or locked: a reconfiguration changes nothing
        var k = CaptureLockGate()
        XCTAssertNil(k.captureReconfigured(at: 1))
        XCTAssertFalse(k.awaitingConfirmation)
    }

    // MARK: VideoFormatWatch

    func testAVideoFormatChangeIsNoticedOnItsFirstFrame() {
        var w = VideoFormatWatch()
        XCTAssertNil(w.note(width: 1920, height: 1440, framesPerSecond: 60, at: 1), "the first frame is not a change")
        XCTAssertNil(w.note(width: 1920, height: 1440, framesPerSecond: 60, at: 1.02))
        XCTAssertNil(w.note(width: 1920, height: 1440, framesPerSecond: nil, at: 1.03), "an unknown rate is no change")
        XCTAssertEqual(w.current?.framesPerSecond, 60)
        let c = try! XCTUnwrap(w.note(width: 1280, height: 960, framesPerSecond: 60, at: 2))
        XCTAssertEqual(c.from, .init(width: 1920, height: 1440, framesPerSecond: 60))
        XCTAssertEqual(c.to, .init(width: 1280, height: 960, framesPerSecond: 60))
        XCTAssertEqual(c.at, 2)
        XCTAssertEqual(c.description, "video format 1920x1440 60 fps -> 1280x960 60 fps")
        XCTAssertNil(w.note(width: 1280, height: 960, framesPerSecond: 60, at: 2.02))
        // the rate alone
        XCTAssertNotNil(w.note(width: 1280, height: 960, framesPerSecond: 30, at: 3))
        XCTAssertEqual(w.changes, 2)
        XCTAssertEqual(w.lastChange?.basis, "caller")
        XCTAssertEqual(VideoFormatWatch.discontinuityReason, "video-format")
    }

    func testAFrameRateChangeIsNotedOnTheNewRunsFramesNotWhenItWasAsked() {
        // the app's format 1920x1440 at 30 fps, then the capture kit's 1920x1440 at 60 fps: the same size, so only the
        // frames' spacing shows the new run. ARKit keeps delivering the old run's frames for 0.3 s after the ask, then
        // stops for 0.2 s while it reconfigures the camera
        var w = VideoFormatWatch()
        let size = (w: 1920, h: 1440)
        func fmt(_ fps: Double, _ s: (w: Int, h: Int) = (1920, 1440)) -> VideoFormatWatch.Format { .init(width: s.w, height: s.h, framesPerSecond: fps) }
        var changes: [VideoFormatWatch.Change] = []
        func frames(from t0: Double, to t1: Double, fps: Double, _ s: (w: Int, h: Int) = (1920, 1440)) {
            var t = t0
            while t < t1 - 1e-9 { if let c = w.note(width: s.w, height: s.h, at: t) { changes.append(c) }; t += 1 / fps }
        }
        w.expect(fmt(30), askedAt: 0)
        frames(from: 0.01, to: 2.0, fps: 30)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(w.current, fmt(30), "the first frames take the rate asked for")
        XCTAssertNil(w.expected)

        w.expect(fmt(60), askedAt: 2.0)
        frames(from: 2.0, to: 2.3, fps: 30)          // the old run's last frames, captured after the ask
        XCTAssertTrue(changes.isEmpty, "not on frames still in the old format")
        XCTAssertEqual(w.current?.framesPerSecond, 30, "still labelled with the old rate")
        frames(from: 2.5, to: 3.0, fps: 60)          // the new run
        XCTAssertEqual(changes.count, 1)
        let up = try! XCTUnwrap(changes.first)
        XCTAssertEqual(up.at, 2.5 + 3.0 / 60, accuracy: 1e-6, "on the new run's fourth frame: three steps at the new spacing")
        XCTAssertEqual(up.from, fmt(30)); XCTAssertEqual(up.to, fmt(60))
        XCTAssertEqual(up.basis, "frame-steps")
        XCTAssertEqual(up.description, "video format 1920x1440 30 fps -> 1920x1440 60 fps")

        // back to 30 fps: the old run at 60 drops two frames in a row (spaced like 30 fps twice) before the new run starts:
        // not enough to be taken for the new rate
        changes = []
        w.expect(fmt(30), askedAt: 3.0)
        var t = 2.5 + 29.0 / 60                     // the last frame above
        for step in [1.0, 2, 2, 1, 1] { t += step / 60; if let c = w.note(width: size.w, height: size.h, at: t) { changes.append(c) } }
        XCTAssertTrue(changes.isEmpty)
        frames(from: 3.4, to: 3.8, fps: 30)
        XCTAssertEqual(changes.map { $0.at }.count, 1)
        XCTAssertEqual(changes.first?.at ?? 0, 3.4 + 3.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(w.current, fmt(30))

        // a re-run whose frames never show the new rate: noted anyway, once, a second after the ask
        changes = []
        w.expect(fmt(60), askedAt: 5.0)
        frames(from: 5.0, to: 6.5, fps: 30)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.basis, "time")
        XCTAssertGreaterThanOrEqual(changes.first?.at ?? 0, 6.0)
        XCTAssertLessThan(changes.first?.at ?? 0, 6.0 + 1.0 / 30 + 1e-9)
        XCTAssertTrue(changes.first?.description.hasSuffix("(by time)") ?? false)

        // a change of size: on the first frame of the new size, with the rate asked for it; the old size's frames after
        // the ask are not a change
        changes = []
        w.expect(fmt(60, (1280, 960)), askedAt: 8.0)
        frames(from: 8.0, to: 8.2, fps: 60)
        XCTAssertTrue(changes.isEmpty)
        frames(from: 8.4, to: 8.5, fps: 60, (1280, 960))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.at ?? 0, 8.4, accuracy: 1e-9)
        XCTAssertEqual(changes.first?.basis, "size")
        XCTAssertEqual(changes.first?.to, fmt(60, (1280, 960)))

        // asked for the format already running: nothing
        changes = []
        w.expect(fmt(60, (1280, 960)), askedAt: 9.0)
        frames(from: 9.0, to: 10.5, fps: 60, (1280, 960))
        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(w.expected)
        XCTAssertEqual(w.changes, 4)
    }
}
