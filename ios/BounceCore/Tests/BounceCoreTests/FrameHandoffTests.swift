import Dispatch
import Foundation
import XCTest
@testable import BounceCore

/// The hand-off between ARKit's delegate queue and the processing queue (`FrameHandoff`): at most one frame processed
/// and one waiting (the latest), so the app never holds more than two of ARKit's frames whatever processing costs; and
/// the frame numbers it keeps (`FramePacer.frameDelivered` / `frameDropped` / `frameStarted`).
final class FrameHandoffTests: XCTestCase {
    /// A camera frame that counts how many of its kind are alive (ARKit's frames held by the app).
    final class Frame {
        static let lock = NSLock()
        static var live = 0, maxLive = 0
        static func resetCounts() { lock.lock(); live = 0; maxLive = 0; lock.unlock() }
        static var liveNow: Int { lock.lock(); defer { lock.unlock() }; return live }
        let t: Double
        init(_ t: Double) {
            self.t = t
            Frame.lock.lock(); Frame.live += 1; Frame.maxLive = max(Frame.maxLive, Frame.live); Frame.lock.unlock()
        }
        deinit { Frame.lock.lock(); Frame.live -= 1; Frame.lock.unlock() }
    }

    func testAtMostOneFrameWaitsAndItIsTheLatest() {
        let h = FrameHandoff<Int>()
        let dt = 1.0 / 60
        XCTAssertEqual(h.deliver(0, captureTime: 0, now: 0.03, nominalInterval: dt), 0, "idle: taken at once")
        XCTAssertEqual(h.framesHeld, 1)
        for i in 1...4 { XCTAssertNil(h.deliver(i, captureTime: Double(i) * dt, now: Double(i) * dt + 0.03, nominalInterval: dt)) }
        XCTAssertEqual(h.framesHeld, 2, "the one being processed and the one waiting")
        XCTAssertEqual(h.finished(captureTime: 0, seconds: 0.1, now: 0.13, search: true, recheck: false, ball: false), 4,
                       "the latest frame is the one that waited")
        XCTAssertEqual(h.framesHeld, 1)
        XCTAssertNil(h.finished(captureTime: 4 * dt, seconds: 0.005, now: 0.14, search: false, recheck: false, ball: false))
        XCTAssertEqual(h.framesHeld, 0, "idle again")
        XCTAssertEqual(h.deliver(5, captureTime: 5 * dt, now: 5 * dt + 0.03, nominalInterval: dt), 5)
        XCTAssertNil(h.finishedUnprocessed(now: 0.2))
        let r = h.report.total
        XCTAssertEqual(r.framesReceived, 6)
        XCTAssertEqual(r.framesProcessed, 2)
        XCTAssertEqual(r.framesDroppedBusy, 3, "frames 1-3 were replaced while they waited")
        XCTAssertEqual(r.maxFramesHeld, 2)
        XCTAssertEqual(r.framesSkippedLate, 0, "nothing is skipped by the lateness rule here")
        XCTAssertEqual(h.report.recent.framesDroppedBusy, 3)
        XCTAssertNotNil(r.handoffWaitMs)
    }

    func testAFrameReplacedInTheSlotIsReleasedAtOnce() {
        Frame.resetCounts()
        let h = FrameHandoff<Frame>()
        var first: Frame? = h.deliver(Frame(0), captureTime: 0, now: 0.03, nominalInterval: 1.0 / 60)
        XCTAssertNotNil(first)
        weak var second: Frame?
        do {
            let f = Frame(1.0 / 60)
            second = f
            XCTAssertNil(h.deliver(f, captureTime: f.t, now: f.t + 0.03, nominalInterval: 1.0 / 60))
        }
        XCTAssertNotNil(second, "it waits")
        XCTAssertNil(h.deliver(Frame(2.0 / 60), captureTime: 2.0 / 60, now: 2.0 / 60 + 0.03, nominalInterval: 1.0 / 60))
        XCTAssertNil(second, "replaced by a newer frame: released before deliver returned")
        XCTAssertEqual(Frame.liveNow, 2)
        let next = h.finished(captureTime: 0, seconds: 0.05, now: 0.08, search: false, recheck: false, ball: false)
        XCTAssertEqual(next?.t ?? -1, 2.0 / 60, accuracy: 1e-12)
        first = nil
        XCTAssertNil(h.finished(captureTime: 2.0 / 60, seconds: 0.005, now: 0.09, search: false, recheck: false, ball: false))
        _ = first
        withExtendedLifetime(next) {}
    }

    /// The app's shape on real threads: a delivery thread at camera rate and a serial processing queue whose frames
    /// take anything from nothing to longer than many frames (a slab search on a cluttered floor). However slow the
    /// processing, the app never holds more than two frames after a hand-off (plus, for a moment, the one the delegate
    /// is handing over and the one whose block is just ending), every frame is accounted for, and when the camera stops
    /// everything is let go.
    func testNeverHoldsMoreThanTwoFramesWhateverProcessingCosts() {
        Frame.resetCounts()
        let n = 400
        var rng = SplitMix(seed: 7)
        let costs: [Double] = (0..<n).map { i in i % 37 == 0 ? 0.06 : Double(rng.next() % 1000) / 1000 * 0.004 }
        let p = Processor(costs: costs)
        let t0 = Date()
        for i in 0..<n {
            // frames 1 ms apart in capture time (the test runs fast); delivered as they come
            let f = Frame(Double(i) / 1000)
            if let take = p.handoff.deliver(f, captureTime: f.t, now: Date().timeIntervalSince(t0), nominalInterval: 0.001) { p.start(take) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(p.group.wait(timeout: .now() + 30), .success, "processing went idle")
        XCTAssertEqual(p.handoff.framesHeld, 0)
        XCTAssertEqual(Frame.liveNow, 0, "every frame let go")
        let r = p.handoff.report.total
        XCTAssertEqual(r.framesReceived, n)
        XCTAssertEqual(r.framesProcessed, p.processedCount)
        XCTAssertEqual(r.framesProcessed + r.framesDroppedBusy, n, "each frame processed or dropped")
        XCTAssertGreaterThan(r.framesDroppedBusy, 0, "the slow frames made the frames behind them drop")
        XCTAssertLessThanOrEqual(r.maxFramesHeld ?? 99, 2)
        XCTAssertLessThanOrEqual(p.maxHeldSeen, 2)
        XCTAssertLessThanOrEqual(Frame.maxLive, 4, "two held, plus the one being handed over and the one whose block is ending")
    }

    /// The processing side of the threaded test: a serial queue, each frame taking its cost, then the next waiting one.
    final class Processor: @unchecked Sendable {
        let handoff = FrameHandoff<Frame>()
        let queue = DispatchQueue(label: "test.processing")
        let group = DispatchGroup()
        let costs: [Double]
        private let lock = NSLock()
        private var processed = 0, maxHeld = 0
        init(costs: [Double]) { self.costs = costs }
        var processedCount: Int { lock.lock(); defer { lock.unlock() }; return processed }
        var maxHeldSeen: Int { lock.lock(); defer { lock.unlock() }; return maxHeld }

        func start(_ f: Frame) {
            group.enter()
            queue.async { self.process(f); self.group.leave() }
        }

        private func process(_ f: Frame) {
            let begin = Date()
            let held = handoff.framesHeld
            lock.lock(); processed += 1; maxHeld = max(maxHeld, held); lock.unlock()
            let i = Int((f.t * 1000).rounded())
            Thread.sleep(forTimeInterval: costs[min(costs.count - 1, max(0, i))])
            let secs = Date().timeIntervalSince(begin)
            if let next = handoff.finished(captureTime: f.t, seconds: secs, now: f.t + secs, search: false, recheck: false, ball: false) {
                start(next)
            }
        }
    }

    /// The model the bench runs: 60 fps, frames reaching the delegate 30 ms after capture, every 0.12 s a 300 ms search.
    /// Through one queue (ARKit's delegate queue = the processing queue) the frames queue up behind each search; through
    /// the hand-off at most two are held, and processing still runs on the freshest frame.
    func testSlowSearchesNoLongerPileFramesUp() {
        let dt = 1.0 / 60, n = 600
        func cost(_ c: Double, _ lastSearch: inout Double) -> Double {
            if c - lastSearch >= 0.12 { lastSearch = c; return 0.3 }
            return 0.002
        }
        // one queue: FIFO, every frame waits its turn (the old pipeline, without the pacer's skips: the frames held)
        var free = -Double.infinity, ends: [Double] = [], head = 0, maxQueued = 0, last = -Double.infinity
        for i in 0..<n {
            let arrive = Double(i) * dt + 0.03
            while head < ends.count && ends[head] <= arrive { head += 1 }
            maxQueued = max(maxQueued, ends.count - head + 1)
            let start = max(arrive, free)
            free = start + cost(Double(i) * dt, &last)
            ends.append(free)
        }
        XCTAssertGreaterThan(maxQueued, 12, "behind 300 ms searches the frames pile up past ARKit's dozen")

        // the hand-off: an event loop over deliveries and the ends of processing
        let h = FrameHandoff<Int>()
        var busyUntil: Double? = nil, current: Int? = nil
        last = -Double.infinity
        var lastProcessed = -1, processedCount = 0
        func run(_ k: Int, at t: Double) { current = k; busyUntil = t + cost(Double(k) * dt, &last) }
        for i in 0..<n {
            let arrive = Double(i) * dt + 0.03
            while let b = busyUntil, b <= arrive, let k = current {
                processedCount += 1
                XCTAssertGreaterThan(k, lastProcessed, "frames are taken in order, never an older one after a newer")
                lastProcessed = k
                busyUntil = nil; current = nil
                if let next = h.finished(captureTime: Double(k) * dt, seconds: b - arrive, now: b, search: false, recheck: false, ball: false) {
                    run(next, at: b)
                }
            }
            if let k = h.deliver(i, captureTime: Double(i) * dt, now: arrive, nominalInterval: dt) { run(k, at: arrive) }
            XCTAssertLessThanOrEqual(h.framesHeld, 2)
        }
        let r = h.report.total
        XCTAssertEqual(r.maxFramesHeld, 2)
        XCTAssertGreaterThan(r.framesDroppedBusy, n / 2, "the frames during the searches are dropped, not held")
        XCTAssertEqual(r.framesProcessed, processedCount)
        // a frame taken after a search waited at most about a frame interval (it is the latest)
        XCTAssertLessThanOrEqual(r.handoffWaitMs?.max ?? 99, dt * 1000 + 1)
        XCTAssertEqual(r.longestUnprocessedMs, 300 + dt * 1000, accuracy: dt * 1000 + 1, "a search's length, plus a frame")
    }

    func testDeliveredFramesShowGapsPausesAndARKitsOwnLateness() {
        var p = FramePacer()
        let dt = 1.0 / 60
        var c = 100.0
        for i in 0..<120 {
            // frame 50 arrives 40 ms late (ARKit's own delay: the delegate was idle); frames 80-82 never came
            if (80...82).contains(i) { c += dt; continue }
            let late = i == 50 ? 0.04 : 0
            p.frameDelivered(captureTime: c, now: c + 0.03 + late, nominalInterval: dt, held: 1)
            p.frameStarted(captureTime: c, waited: 0)
            p.frameProcessed(captureTime: c, seconds: 0.004, search: false, recheck: false, ball: false)
            c += dt
        }
        // a pause (the session interrupted)
        c += 2
        p.frameDelivered(captureTime: c, now: c + 0.03, nominalInterval: dt, held: 1)
        let r = p.report.total
        XCTAssertEqual(r.framesReceived, 118)
        XCTAssertEqual(r.cameraGaps, 1)
        XCTAssertEqual(r.framesMissedByCamera, 3)
        XCTAssertEqual(r.pauses, 1)
        XCTAssertEqual(r.framesLateButIdle, 1, "ARKit's own lateness shows as before")
        XCTAssertEqual(r.framesDroppedBusy, 0)
        XCTAssertEqual(r.maxFramesHeld, 1)
        XCTAssertEqual(r.longestUnprocessedMs, 4 * dt * 1000, accuracy: 0.5, "the gap; the pause left out")
        XCTAssertEqual(r.handoffWaitMs?.max ?? -1, 0, accuracy: 0.5)
        // the old path reports nothing about holding frames
        XCTAssertNil(FramePacer().report.total.maxFramesHeld)
    }

    /// The JSON keys of the new numbers (the diagnostics' framePacing), round-tripped.
    func testTheHandoffNumbersAreInTheReportJSON() throws {
        let h = FrameHandoff<Int>()
        _ = h.deliver(0, captureTime: 0, now: 0.03, nominalInterval: 1.0 / 60)
        _ = h.deliver(1, captureTime: 1.0 / 60, now: 0.05, nominalInterval: 1.0 / 60)
        _ = h.deliver(2, captureTime: 2.0 / 60, now: 0.07, nominalInterval: 1.0 / 60)
        _ = h.finished(captureTime: 0, seconds: 0.05, now: 0.08, search: true, recheck: false, ball: false)
        let rep = h.report
        let data = try JSONEncoder().encode(rep)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["framesDroppedBusy", "maxFramesHeld", "handoffWaitMs"] { XCTAssertTrue(text.contains("\"\(key)\""), key) }
        XCTAssertEqual(try JSONDecoder().decode(FramePacingReport.self, from: data), rep)
    }

    /// The demo's frames go through the pacer behind the hand-off's lock (the app's calls, as written there).
    func testTheDemoUsesThePacerBehindTheLock() {
        let h = FrameHandoff<Int>()
        var p = FramePacer()
        p.rule.countsCameraGaps = false
        h.resetPacer(p)
        let interval = 0.08
        h.withPacer { $0.expectPause(at: 0) }
        for i in 0..<20 {
            let t = Double(i) * interval
            guard h.withPacer({ $0.frameArrived(captureTime: t, now: t, nominalInterval: interval) }) == .process else { continue }
            let secs = 0.01
            h.withPacer { $0.frameProcessed(captureTime: t, seconds: secs, search: i % 2 == 0, recheck: false, ball: false) }
        }
        let r = h.report.total
        XCTAssertEqual(r.framesReceived, 20)
        XCTAssertEqual(r.framesProcessed, 20)
        XCTAssertNil(r.maxFramesHeld, "the demo's frames do not go through the slot")
        XCTAssertFalse(h.report.rule.countsCameraGaps)
    }

    struct SplitMix {
        var s: UInt64
        init(seed: UInt64) { s = seed }
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
