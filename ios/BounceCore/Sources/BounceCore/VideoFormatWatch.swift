import Foundation

/// Notices the camera's video format changing between frames: its image size or its nominal frame rate. The app runs
/// ARKit with one format and re-runs it with another while the capture kit is open (`ARController.setKitMode`), without
/// resetting tracking. Whether ARKit's world, and so the slab's lock in it, carries over such a re-run is not verified,
/// so a change is a world-frame discontinuity: the app reports it to the tracker
/// (`SlabTracker.noteWorldDiscontinuity(VideoFormatWatch.discontinuityReason)`), which keeps its lock only as unconfirmed
/// until a detection in the new format sees the slab where the lock says (or it expires, "lock-expired"). The tracker
/// also notices a change of its processing frame's size by itself (reason "frame-size") and rescales or drops what it
/// kept in the old frame's pixels; a change of the frame rate alone only this watch sees.
///
/// The change must be noted on a frame that really is in the new format, so that the lock is confirmed again on frames
/// of the new run, not on the old run's last few. ARKit keeps delivering frames in the old format for a while after a
/// re-run is asked for, and a frame does not say its format's frame rate. So:
/// - a change of size is noted on the first frame of the new size (exact);
/// - a change of the frame rate alone (the same size, e.g. 1920x1440 at 30 fps, then at 60) is noted on the first frame
///   captured after the re-run was asked for (`expect`) whose last `Rule.steps` capture steps all match the new rate's
///   frame interval and none the old one's (within `Rule.tolerance`), which the old run's frames cannot do (a camera
///   dropping frames may space them like a lower rate, but never like a higher one: even then it takes `Rule.steps`
///   steps in a row); if the frames show no such evidence within `Rule.timeoutSeconds` of the ask, the change is noted
///   anyway (`Change.basis` "time"), so a re-run whose rate the frames do not show is still a discontinuity.
///
/// Use: `expect(_:askedAt:)` with the format the session is about to run with, just before every `session.run` (on
/// the queue the frames come on, so frames captured before the ask are handled after it is known); then on every frame
/// the camera delivers (processed or not), `note(width:height:at:)` with the frame's full image size (ARKit:
/// `camera.imageResolution`) and capture time; a non-nil result is a change. `current` is then the frame's format (its
/// nominal rate: the one asked for, as far as the frames have shown it). The first frame is never a change.
public struct VideoFormatWatch {
    public struct Format: Codable, Equatable {
        public var width: Int
        public var height: Int
        /// nominal frames per second; nil when not known (then only the size is compared)
        public var framesPerSecond: Double?
        public init(width: Int, height: Int, framesPerSecond: Double?) {
            self.width = width; self.height = height; self.framesPerSecond = framesPerSecond
        }
    }

    public struct Change: Codable, Equatable {
        public var from: Format
        public var to: Format
        /// the frame it was noted on (the camera's clock, s): the first in the new format for a change of size, a few
        /// frames into it for a change of the rate alone
        public var at: Double
        /// what showed it: "size" (the frame's size), "frame-steps" (the frames' spacing matched the new rate), "time"
        /// (nothing showed it within `Rule.timeoutSeconds` of the ask: noted anyway), "caller" (the caller said the
        /// frame's rate); nil in older reports
        public var basis: String?
        public init(from: Format, to: Format, at: Double, basis: String? = nil) {
            self.from = from; self.to = to; self.at = at; self.basis = basis
        }
        /// e.g. "video format 1920x1440 60 fps -> 1280x960 60 fps", for the event list
        public var description: String {
            func f(_ x: Format) -> String { "\(x.width)x\(x.height)" + (x.framesPerSecond.map { String(format: " %.0f fps", $0) } ?? "") }
            return "video format \(f(from)) -> \(f(to))" + (basis == "time" ? " (by time)" : "")
        }
    }

    /// When a change of the frame rate alone is noted.
    public struct Rule: Codable, Equatable {
        /// this many capture steps in a row (each ending on a frame captured after the ask) ...
        public var steps = 3
        /// ... each within this share of the new rate's frame interval, and none within it of the old rate's
        public var tolerance = 0.25
        /// no such evidence this long (s) after the ask: noted anyway
        public var timeoutSeconds = 1.0
        public init() {}
    }

    /// A format the session was asked to run with, not yet seen in the frames.
    public struct Expected: Equatable {
        public var format: Format
        public var askedAt: Double
    }

    /// the reason passed to the tracker with a change
    public static let discontinuityReason = "video-format"

    public var rule: Rule
    public private(set) var current: Format?
    public private(set) var changes = 0
    public private(set) var lastChange: Change?
    public private(set) var expected: Expected?
    private var lastCapture: Double?
    /// capture steps of the frames captured since the ask
    private var stepsSinceAsk: [Double] = []

    public init(rule: Rule = Rule()) { self.rule = rule }

    /// The session is about to run with this format (`framesPerSecond`: its nominal rate), asked at `askedAt` (the
    /// frames' clock). Frames captured before then are in the format running before; frames after it may be in either
    /// until they show the new one.
    public mutating func expect(_ format: Format, askedAt: Double) {
        expected = Expected(format: format, askedAt: askedAt)
        stepsSinceAsk = []
    }

    /// A frame (its full image size and capture time): the change, if it is the frame the new format is noted on.
    public mutating func note(width w: Int, height h: Int, at t: Double) -> Change? {
        let step = lastCapture.map { t - $0 }
        lastCapture = t
        // the rate the ask gives frames of this size
        let askedRate = expected.flatMap { $0.format.width == w && $0.format.height == h ? $0.format.framesPerSecond : nil }
        guard let old = current else {
            current = Format(width: w, height: h, framesPerSecond: askedRate)
            if askedRate != nil { expected = nil }
            return nil
        }
        // a new size: the frame is in the new format (the rate: the ask's for that size, if any)
        if old.width != w || old.height != h {
            let matched = askedRate != nil
            if matched { expected = nil; stepsSinceAsk = [] }
            return changed(from: old, to: Format(width: w, height: h, framesPerSecond: askedRate), at: t, basis: "size")
        }
        guard let e = expected, t >= e.askedAt else { return nil }
        if let s = step, s > 0 { stepsSinceAsk.append(s); if stepsSinceAsk.count > 64 { stepsSinceAsk.removeFirst() } }
        let byTime = t - e.askedAt >= rule.timeoutSeconds
        // asked for another size: it shows by its size (above); after the timeout the ask is dropped (ARKit kept this one)
        guard e.format.width == w && e.format.height == h else {
            if byTime { expected = nil; stepsSinceAsk = [] }
            return nil
        }
        // the same size asked: a change of the rate alone, or none
        guard let newRate = e.format.framesPerSecond, newRate > 0 else { expected = nil; return nil }
        guard let oldRate = old.framesPerSecond, oldRate > 0, abs(oldRate - newRate) > 0.5 else {
            current = Format(width: w, height: h, framesPerSecond: newRate)
            expected = nil; stepsSinceAsk = []
            return nil
        }
        let newI = 1 / newRate, oldI = 1 / oldRate
        func near(_ x: Double, _ i: Double) -> Bool { abs(x - i) <= rule.tolerance * i }
        let last = stepsSinceAsk.suffix(max(1, rule.steps))
        let bySteps = last.count >= max(1, rule.steps) && last.allSatisfy { near($0, newI) && !near($0, oldI) }
        guard bySteps || byTime else { return nil }
        expected = nil; stepsSinceAsk = []
        return changed(from: old, to: Format(width: w, height: h, framesPerSecond: newRate), at: t, basis: bySteps ? "frame-steps" : "time")
    }

    /// A frame whose format's rate the caller knows (`framesPerSecond`, nil: not known, then only the size is compared):
    /// the change if it differs from the previous frame's.
    public mutating func note(width: Int, height: Int, framesPerSecond: Double?, at t: Double) -> Change? {
        lastCapture = t
        let new = Format(width: width, height: height, framesPerSecond: framesPerSecond)
        guard let old = current else { current = new; return nil }
        let sizeChanged = old.width != width || old.height != height
        var rateChanged = false
        if let a = old.framesPerSecond, let b = framesPerSecond { rateChanged = abs(a - b) > 0.5 }
        guard sizeChanged || rateChanged else {
            // keep a rate learned on an earlier frame when this one does not say
            current = Format(width: width, height: height, framesPerSecond: framesPerSecond ?? old.framesPerSecond)
            return nil
        }
        return changed(from: old, to: new, at: t, basis: sizeChanged ? "size" : "caller")
    }

    private mutating func changed(from old: Format, to new: Format, at t: Double, basis: String) -> Change {
        current = new
        let c = Change(from: old, to: new, at: t, basis: basis)
        changes += 1; lastChange = c
        return c
    }
}
