import Foundation

/// The hand-off between ARKit's delegate queue and the app's processing queue, so that ARKit's frames never pile up
/// behind slow processing.
///
/// ARKit delivers each camera frame to the session's delegate on the delegate's queue and cannot reuse its camera
/// buffer until the app lets the frame go; it warns once the app holds about a dozen and then stops delivering. When the
/// delegate's queue is the processing queue itself, every frame that arrives while a slab search runs (100-400 ms on a
/// cluttered floor) waits in that queue, held, until the handler reaches it. Here the delegate's queue does only cheap
/// work per frame and hands the frame over: at most one frame is being processed and at most one waits, the latest (a
/// newer frame replaces the waiting one, which is released at once: dropped because processing was busy). So the app
/// holds at most two of ARKit's frames whatever processing costs, and processing always takes the freshest frame there
/// is.
///
/// The frame numbers (`report`, the diagnostics' `framePacing`) come from a `FramePacer` behind the same lock: every
/// frame delivered (`FramePacer.frameDelivered`), every one dropped, every one taken, how long each took.
///
/// Use, on the delegate's queue, for every frame ARKit delivers (after the cheap per-frame work):
///
///     if let f = handoff.deliver(frame, captureTime: frame.timestamp, now: CACurrentMediaTime(), nominalInterval: 1 / fps) {
///         processingQueue.async { process(f) }       // processing was idle: this frame is taken now
///     }                                              // else it waits (in place of an older waiting one) or was dropped
///
/// and on the processing queue, at the end of every frame `deliver` or `finished` handed out:
///
///     let start = CACurrentMediaTime()
///     let out = ... process f ...
///     if let next = handoff.finished(captureTime: f.timestamp, seconds: CACurrentMediaTime() - start,
///                                    now: CACurrentMediaTime(), output: out) {
///         processingQueue.async { process(next) }    // the frame that waited meanwhile, taken now
///     }
///
/// Every frame handed out must be finished exactly once (`finished`, or `finishedUnprocessed` for one the processing
/// side chose not to process), or no frame is handed out again. Taking the next frame in a new block (rather than in a
/// loop) lets other work queued on the processing queue (settings, the diagnostics' synchronous read) run between
/// frames. Thread-safe: one lock guards the slot and the pacer; a frame replaced in the slot is released after the lock
/// is let go. Pure apart from the lock (it reads no clock), so tests drive it with made-up times.
public final class FrameHandoff<Frame> {
    private let lock = NSLock()
    private var pacer: FramePacer
    /// a frame has been handed out and not finished yet
    private var busy = false
    /// the frame waiting for processing, when it was delivered
    private var waiting: (frame: Frame, capture: Double, delivered: Double)?

    public init(pacer: FramePacer = FramePacer()) { self.pacer = pacer }

    /// A frame ARKit delivered (the delegate's queue). Returns it when processing is idle: the caller has it processed
    /// now and calls `finished` at the end. Otherwise it waits in the slot, taking the place of any frame already
    /// waiting (that one is dropped and released before this returns), and nil is returned.
    public func deliver(_ frame: Frame, captureTime c: Double, now: Double, nominalInterval: Double) -> Frame? {
        var replaced: Frame? = nil
        lock.lock()
        let start = !busy
        if start {
            busy = true
        } else {
            if let w = waiting {
                replaced = w.frame
                pacer.frameDropped(captureTime: w.capture)
            }
            waiting = (frame, c, now)
        }
        pacer.frameDelivered(captureTime: c, now: now, nominalInterval: nominalInterval, held: 1 + (waiting != nil ? 1 : 0))
        if start { pacer.frameStarted(captureTime: c, waited: 0) }
        lock.unlock()
        withExtendedLifetime(replaced) {}   // the dropped frame goes here, outside the lock
        return start ? frame : nil
    }

    /// The frame handed out last has been processed (the processing queue): how long its handling took (s) and what
    /// ran on it. Returns the frame that waited meanwhile, if any, now taken (process it, then call this again); nil:
    /// processing is idle until the next delivery.
    public func finished(captureTime c: Double, seconds: Double, now: Double, output: TrackerOutput) -> Frame? {
        finished(captureTime: c, seconds: seconds, now: now, search: output.detectionKind == .search,
                 recheck: output.detectionKind == .recheck, ball: output.ballSearched)
    }

    /// The same, saying which detectors ran.
    public func finished(captureTime c: Double, seconds: Double, now: Double, search: Bool, recheck: Bool, ball: Bool) -> Frame? {
        lock.lock()
        pacer.frameProcessed(captureTime: c, seconds: seconds, search: search, recheck: recheck, ball: ball)
        let next = takeWaiting(now: now)
        lock.unlock()
        return next
    }

    /// The frame handed out last was not processed after all (the processing side had stopped wanting camera frames:
    /// the demo started). Returns the next waiting frame as `finished` does.
    public func finishedUnprocessed(now: Double) -> Frame? {
        lock.lock()
        let next = takeWaiting(now: now)
        lock.unlock()
        return next
    }

    /// (locked) the waiting frame, taken; or none, and processing is idle
    private func takeWaiting(now: Double) -> Frame? {
        guard let w = waiting else {
            busy = false
            return nil
        }
        waiting = nil
        pacer.frameStarted(captureTime: w.capture, waited: now - w.delivered)
        return w.frame
    }

    /// Camera frames the app holds now: the one being processed (handed out, not finished) and the one waiting.
    public var framesHeld: Int {
        lock.lock(); defer { lock.unlock() }
        return (busy ? 1 : 0) + (waiting != nil ? 1 : 0)
    }

    /// The frame numbers so far (`FramePacer.report`).
    public var report: FramePacingReport {
        lock.lock(); defer { lock.unlock() }
        return pacer.report
    }

    /// The delegate's call for the frame delivered last returned (the delegate's queue): when it began and ended. Its
    /// own work per frame is timed, and a frame that reaches the delegate only as this call ends (it waited in the
    /// delegate's queue behind it, held there by the app) is counted (`framesQueuedOnDelegate`, `delegateMs`).
    public func delegateReturned(entered: Double, now: Double) {
        lock.lock(); pacer.delegateReturned(entered: entered, now: now); lock.unlock()
    }

    /// Work on the pacer under the lock: a pause about to happen (`expectPause`).
    public func withPacer<R>(_ body: (inout FramePacer) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&pacer)
    }

    /// The frame numbers start afresh (a new camera run). A frame being processed or waiting stays where it
    /// is: it is finished as usual (and counted in the new numbers).
    public func resetPacer(_ p: FramePacer = FramePacer()) {
        lock.lock(); pacer = p; lock.unlock()
    }
}
