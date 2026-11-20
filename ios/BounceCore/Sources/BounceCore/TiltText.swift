import Foundation

/// The tilt as the main screen shows it (n18): "3.2°", and while the honest standard deviation of the shown estimate
/// (`TrackerOutput.shownTiltSigmaDegrees`) is over `plainUpToDegrees`, its deviation after it, compact: "3.2° ±1.4".
public enum TiltText {
    /// at or under this deviation (degrees) the tilt is shown alone
    public static let plainUpToDegrees = 1.0

    public static func format(degrees: Double, sigmaDegrees: Double?) -> String {
        let tilt = String(format: "%.1f°", degrees)
        guard let s = sigmaDegrees, s.isFinite, s > plainUpToDegrees else { return tilt }
        return tilt + String(format: " ±%.1f", s)
    }
}
