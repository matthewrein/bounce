import Foundation

/// The main screen's one short cue (n17, the demo build): a line of a few words under the status chip, shown only when
/// the owner can do something about what the app is waiting for, never otherwise (the developer hints stay in Settings >
/// Developer, `TrackerOutput.hint`):
///   - not locked (or the lock unconfirmed) for more than `notLockedSeconds`: "Point at the slab", or "Step closer" when
///     the slab being confirmed is farther than `farMetres`;
///   - locked, the tilt still settling for more than `settlingSeconds`, the most useful reason from the tracker's own
///     numbers: farther than `farMetres` (the honest tilt uncertainty grows with distance and stays above the settle
///     threshold beyond about 4 ft) "Step closer"; the line of sight more than `shallowDegrees` from the slab's normal
///     "Hold the phone higher"; less than `steepDegrees` (looking almost straight down: n11's steep views, 68-76 deg
///     elevation, settle slowly or never) "Lower the phone"; otherwise (one view, the uncertainty just over the
///     threshold: a second view 7.5 deg away combines with it) "Move the phone slowly";
///   - for `tapCueSeconds` after a ball tap that set nothing (event "tap-ball-set-none"): "Tap the ball".
/// The app keeps one per camera session and feeds it every processed frame (camera clock).
public struct MainScreenCue {
    public static let pointAtSlab = "Point at the slab"
    public static let stepCloser = "Step closer"
    public static let holdHigher = "Hold the phone higher"
    public static let lowerPhone = "Lower the phone"
    public static let moveSlowly = "Move the phone slowly"
    public static let tapTheBall = "Tap the ball"

    public var notLockedSeconds = 2.0
    public var settlingSeconds = 1.5
    /// about 4 ft, camera to the slab's centre (m)
    public var farMetres = 1.25
    /// the line of sight's angle from the slab's normal (degrees)
    public var shallowDegrees = 60.0
    public var steepDegrees = 25.0
    public var tapCueSeconds = 2.0

    private var notLockedSince: Double? = nil
    private var settlingSince: Double? = nil
    private var tapMissAt: Double? = nil
    private var lastTime: Double? = nil

    public init() {}

    /// Start over (a new camera session or the demo restarting).
    public mutating func reset() { notLockedSince = nil; settlingSince = nil; tapMissAt = nil; lastTime = nil }

    /// The line of sight's angle from the slab's normal (degrees, 0 straight down onto it, 90 edge-on), from the slab's
    /// centre to the camera.
    public static func viewAngleDegrees(slab: SlabPose, camera: Vec3) -> Double? {
        let v = camera - slab.center
        guard v.length > 1e-6, slab.normal.length > 1e-6 else { return nil }
        let c = abs(v.normalized.dot(slab.normal.normalized))
        return Units.degrees(acos(min(1, c)))
    }

    /// One frame: `locked` (locked and confirmed), `settling` (locked and the tilt not shown yet), `slabDistance` (m, camera
    /// to the lock's centre, or to the slab being confirmed; nil: none), `viewAngleDegrees` (`viewAngleDegrees(slab:
    /// camera:)`, while locked), and the frame's tracker events. Returns the cue to show, or nil.
    public mutating func update(time t: Double, locked: Bool, settling: Bool, slabDistance: Double?, viewAngleDegrees: Double?,
                                events: [String]) -> String? {
        // the clock went back (a restart) or jumped (the camera paused): start over
        if let l = lastTime, t < l - 0.5 || t > l + 2 { reset() }
        lastTime = t
        if events.contains("tap-ball-set-none") { tapMissAt = t }
        if let m = tapMissAt {
            if t - m <= tapCueSeconds && locked { return MainScreenCue.tapTheBall }
            if t - m > tapCueSeconds || !locked { tapMissAt = nil }
        }
        guard locked else {
            settlingSince = nil
            let since = notLockedSince ?? t
            notLockedSince = since
            guard t - since > notLockedSeconds else { return nil }
            if let d = slabDistance, d > farMetres { return MainScreenCue.stepCloser }
            return MainScreenCue.pointAtSlab
        }
        notLockedSince = nil
        guard settling else { settlingSince = nil; return nil }
        let since = settlingSince ?? t
        settlingSince = since
        guard t - since > settlingSeconds else { return nil }
        if let d = slabDistance, d > farMetres { return MainScreenCue.stepCloser }
        if let a = viewAngleDegrees {
            if a > shallowDegrees { return MainScreenCue.holdHigher }
            if a < steepDegrees { return MainScreenCue.lowerPhone }
        }
        return MainScreenCue.moveSlowly
    }
}
