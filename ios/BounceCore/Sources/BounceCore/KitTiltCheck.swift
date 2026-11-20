import Foundation

/// The app's own tilt during a kit shot against the slab's true tilt (the flat-phone reading of the slab position the
/// shot was taken in). It catches a slab moved after its reading: in the owner's first two kits the slab was put back
/// level for the drops while the kit still held the third tilt's reading (17° and 12°), and the app read about 0.3° on
/// those clips. Stored in shot.json and in the shot's line of kit.json (`tiltCheck`; kits before n20k have none).
///
/// The app's tilt is the median of the tracker's tilt (`Readouts.tiltDegrees`) over the shot's frames with the slab
/// locked: over the frames where the tilt was settled (`TrackerOutput.angleSettled`, the app showed it) when there are
/// at least `minFrames` of them, else over every locked frame. Its uncertainty is the median of the tracker's honest
/// standard deviation (`TrackerOutput.tiltSigmaDegrees`) over the same frames. The two disagree when they are more than
/// `minDifferenceDegrees` apart and more than `sigmaFactor` times that uncertainty, so a still, unsettled single view
/// (whose uncertainty is large) cannot raise it falsely; without an uncertainty only a settled tilt can raise it.
public struct KitTiltCheck: Codable, Equatable {
    /// the app's tilt over the shot (degrees)
    public var appTiltDegrees: Double
    /// the tracker's honest standard deviation of it (degrees, both axes), if it gave one
    public var appSigmaDegrees: Double?
    /// the app's tilt is over settled frames (the tilt the app showed)
    public var appSettled: Bool
    /// frames it is over
    public var appFrames: Int
    /// the slab position's true tilt (degrees)
    public var truthTiltDegrees: Double
    /// |app - truth| (degrees)
    public var differenceDegrees: Double
    /// the app and the true tilt disagree: the slab moved since its reading, or the app is wrong
    public var disagrees: Bool

    /// the smallest difference that counts (degrees)
    public static let minDifferenceDegrees = 3.0
    /// and the difference must be over this many of the app's standard deviations
    public static let sigmaFactor = 2.0
    /// frames with the slab locked needed for a check
    public static let minFrames = 3

    public init(appTiltDegrees: Double, appSigmaDegrees: Double?, appSettled: Bool, appFrames: Int, truthTiltDegrees: Double) {
        self.appTiltDegrees = appTiltDegrees; self.appSigmaDegrees = appSigmaDegrees; self.appSettled = appSettled
        self.appFrames = appFrames; self.truthTiltDegrees = truthTiltDegrees
        let d = abs(appTiltDegrees - truthTiltDegrees)
        differenceDegrees = d
        disagrees = KitTiltCheck.disagree(difference: d, sigma: appSigmaDegrees, settled: appSettled)
    }

    /// The rule: over `minDifferenceDegrees` and over `sigmaFactor` sigmas (no sigma: only a settled tilt counts).
    public static func disagree(difference d: Double, sigma: Double?, settled: Bool) -> Bool {
        guard d.isFinite, d > minDifferenceDegrees else { return false }
        if let s = sigma, s.isFinite, s >= 0 { return d > sigmaFactor * s }
        return settled
    }

    /// The check from a shot's frames (the app's per-frame tilt in `KitFrameStat`) against a true tilt (degrees). nil
    /// without a true tilt, or with fewer than `minFrames` locked frames that have a tilt.
    public static func make(stats: [KitFrameStat], truthDegrees: Double?) -> KitTiltCheck? {
        guard let truth = truthDegrees, truth.isFinite else { return nil }
        let locked = stats.filter { $0.slabLocked && ($0.appTiltDegrees?.isFinite ?? false) }
        let settled = locked.filter { $0.appTiltSettled == true }
        let use = settled.count >= minFrames ? settled : locked
        guard use.count >= minFrames else { return nil }
        let tilt = KitStats.median(use.compactMap { $0.appTiltDegrees })
        let sigmas = use.compactMap { $0.appTiltSigmaDegrees }.filter { $0.isFinite && $0 >= 0 }
        return KitTiltCheck(appTiltDegrees: tilt, appSigmaDegrees: sigmas.isEmpty ? nil : KitStats.median(sigmas),
                            appSettled: settled.count >= minFrames, appFrames: use.count, truthTiltDegrees: truth)
    }

    /// The same reading of the app against another true tilt (degrees); nil without one.
    public func against(truthDegrees: Double?) -> KitTiltCheck? {
        guard let t = truthDegrees, t.isFinite else { return nil }
        return KitTiltCheck(appTiltDegrees: appTiltDegrees, appSigmaDegrees: appSigmaDegrees, appSettled: appSettled, appFrames: appFrames,
                            truthTiltDegrees: t)
    }

    /// What the kit says after the shot when they disagree, else nil: "The app reads 0.3° but the phone-on-slab reading
    /// says 17.2°: has the slab moved? Retake the reading."
    public var message: String? {
        guard disagrees else { return nil }
        return String(format: "The app reads %.1f° but the phone-on-slab reading says %.1f°: has the slab moved? Retake the reading.",
                      appTiltDegrees, truthTiltDegrees)
    }

    /// One line for summaries: "s10-drop1: the app read 0.3°, the reading 17.2° (16.9° apart)".
    public func line(shot id: String) -> String {
        String(format: "%@: the app read %.1f°, the phone-on-slab reading %.1f° (%.1f° apart)", id, appTiltDegrees, truthTiltDegrees, differenceDegrees)
    }
}
