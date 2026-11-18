import Foundation

/// When to lock the camera's focus, exposure and white balance once the slab is locked: not on the "locked" event
/// itself, but once the camera has stopped adjusting them (`AVCaptureDevice.isAdjustingFocus`, `isAdjustingExposure`,
/// `isAdjustingWhiteBalance` all false for `Rule.settleSeconds`), so the values held are settled ones. If the camera keeps
/// adjusting, it locks anyway after `Rule.timeoutSeconds` and says which was still adjusting.
///
/// Use (on the processing queue, every processed frame):
///
///     if let c = gate.note(events: output.events, at: t) { apply(c) }       // arms on "locked", unlocks on a new search
///     if let c = gate.update(at: t, adjusting: CaptureLockGate.Adjusting(focus: d.isAdjustingFocus,
///                            exposure: d.isAdjustingExposure, whiteBalance: d.isAdjustingWhiteBalance)) { apply(c) }
///
/// and `disarm()` when the app resets the tracker (Reset, a recording starting), `captureReconfigured(at:)` when the
/// camera may have been set up again under the lock (ARKit re-ran with another video format). `apply`: `.lock` locks the
/// three modes, `.unlock` returns them to continuous auto. Pure (no clock, no device), so every path is tested.
public struct CaptureLockGate {
    public struct Rule: Codable, Equatable {
        /// lock once none of the three has been adjusting for this long (s) ...
        public var settleSeconds = 0.3
        /// ... over at least this many frames in a row
        public var settleFrames = 3
        /// lock anyway this long after arming (s), reporting what was still adjusting
        public var timeoutSeconds = 2.5
        public init() {}
    }

    /// What the camera reports as still adjusting on a frame.
    public struct Adjusting: Equatable {
        public var focus: Bool
        public var exposure: Bool
        public var whiteBalance: Bool
        public init(focus: Bool, exposure: Bool, whiteBalance: Bool) { self.focus = focus; self.exposure = exposure; self.whiteBalance = whiteBalance }
        public static let none = Adjusting(focus: false, exposure: false, whiteBalance: false)
        public var any: Bool { focus || exposure || whiteBalance }
        /// "focus", "exposure", "whiteBalance", those adjusting
        public var names: [String] { [focus ? "focus" : nil, exposure ? "exposure" : nil, whiteBalance ? "whiteBalance" : nil].compactMap { $0 } }
    }

    /// How a lock came about, for the diagnostics and the event list.
    public struct Lock: Codable, Equatable {
        /// when the gate was armed and when it locked (the camera's clock, s)
        public var armedAt: Double
        public var lockedAt: Double
        /// it waited this long (s)
        public var waitedSeconds: Double
        /// it gave up waiting (`Rule.timeoutSeconds`): these were still adjusting
        public var timedOut: Bool
        public var stillAdjusting: [String]
        /// e.g. "capture locked after 0.42 s settled" or "capture locked at the 2.5 s timeout: exposure still adjusting"
        public var description: String {
            timedOut ? String(format: "capture locked at the %.1f s timeout: %@ still adjusting", waitedSeconds,
                              stillAdjusting.isEmpty ? "nothing" : stillAdjusting.joined(separator: ", "))
                     : String(format: "capture locked after %.2f s settled", waitedSeconds)
        }
    }

    public enum Command: Equatable {
        /// lock focus, exposure and white balance now
        case lock(Lock)
        /// return them to continuous auto (a new search, or the camera reconfigured under the lock)
        case unlock(reason: String)
    }

    public var rule: Rule
    /// waiting to lock since this time (s)
    public private(set) var armedAt: Double?
    /// the gate told the app to lock and has not told it to unlock since
    public private(set) var locked = false
    /// after the camera was reconfigured: arm again once the tracker confirms its lock
    public private(set) var awaitingConfirmation = false
    /// the last lock
    public private(set) var lastLock: Lock?
    private var quietSince: Double?
    private var quietFrames = 0
    private var lastAdjusting = Adjusting.none

    public init(rule: Rule = Rule()) { self.rule = rule }

    /// The tracker's events of a frame (`TrackerOutput.events`). "locked" arms the gate (a relock is the same scene: an
    /// existing capture lock stays); "tap", "lost" and "lock-expired" (a new search) disarm it and unlock. After
    /// `captureReconfigured`, "lock-confirmed", "relocked" or "locked" arm it again.
    public mutating func note(events: [String], at t: Double) -> Command? {
        if events.contains("tap") || events.contains("lost") || events.contains("lock-expired") {
            let reason = events.first { ["tap", "lost", "lock-expired"].contains($0) }!
            return disarm(reason: reason)
        }
        if awaitingConfirmation, events.contains(where: { ["lock-confirmed", "relocked", "locked"].contains($0) }) {
            awaitingConfirmation = false
            if !locked { armedAt = t }
        } else if events.contains("locked"), !locked, armedAt == nil {
            armedAt = t
        }
        return nil
    }

    /// The app reset the tracker or started over (Reset, a recording starting, a new session): disarm and unlock.
    public mutating func disarm(reason: String = "reset") -> Command? {
        armedAt = nil; awaitingConfirmation = false
        guard locked else { return nil }
        locked = false
        return .unlock(reason: reason)
    }

    /// The camera may have been set up again under a lock (ARKit re-ran with another video format, without a reset):
    /// whether its focus, exposure and white balance are still locked is not known. Unlock (so the app's state is known
    /// again) and lock afresh, settled, once the tracker has confirmed its lock in the new format ("lock-confirmed").
    /// Nothing happens unless the gate was armed or locked.
    public mutating func captureReconfigured(at t: Double) -> Command? {
        guard locked || armedAt != nil else { return nil }
        armedAt = nil
        awaitingConfirmation = true
        quietSince = nil; quietFrames = 0
        guard locked else { return nil }
        locked = false
        return .unlock(reason: "reconfigured")
    }

    /// Every processed frame: what the camera is adjusting. Returns `.lock` once armed and settled (or timed out).
    public mutating func update(at t: Double, adjusting a: Adjusting) -> Command? {
        lastAdjusting = a
        if a.any {
            quietSince = nil; quietFrames = 0
        } else {
            if quietSince == nil { quietSince = t }
            quietFrames += 1
        }
        guard let armed = armedAt, !locked else { return nil }
        let settled = (quietSince.map { t - $0 >= rule.settleSeconds } ?? false) && quietFrames >= max(1, rule.settleFrames)
        let timedOut = !settled && t - armed >= rule.timeoutSeconds
        guard settled || timedOut else { return nil }
        let l = Lock(armedAt: armed, lockedAt: t, waitedSeconds: max(0, t - armed), timedOut: timedOut, stillAdjusting: timedOut ? a.names : [])
        armedAt = nil; locked = true; lastLock = l
        return .lock(l)
    }
}
