import Foundation

/// Notices the camera's video format changing between frames: its image size or its nominal frame rate. The app runs
/// ARKit with one format and re-runs it with another while the capture kit is open (`ARController.setKitMode`), without
/// resetting tracking. Whether ARKit's world, and so the slab's lock in it, carries over such a re-run is not verified,
/// so a change is a world-frame discontinuity: the app reports it to the tracker
/// (`SlabTracker.noteWorldDiscontinuity(VideoFormatWatch.discontinuityReason)`), which keeps its lock only as unconfirmed
/// until a detection at the new size sees the slab where the lock says (or it expires, "lock-expired"). The tracker
/// also notices a change of its processing frame's size by itself (reason "frame-size") and rescales or drops what it
/// kept in the old frame's pixels; a change of the frame rate alone only this watch sees.
///
/// Use: on every frame the camera delivers (processed or not), `note(width:height:framesPerSecond:at:)` with the frame's
/// full image size (ARKit: `camera.imageResolution`) and the nominal frame rate of the format it came from; a non-nil
/// result is a change. The first frame is never a change.
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
        /// the first frame in the new format (the camera's clock, s)
        public var at: Double
        /// e.g. "video format 1920x1440 60 fps -> 1280x960 60 fps", for the event list
        public var description: String {
            func f(_ x: Format) -> String { "\(x.width)x\(x.height)" + (x.framesPerSecond.map { String(format: " %.0f fps", $0) } ?? "") }
            return "video format \(f(from)) -> \(f(to))"
        }
    }

    /// the reason passed to the tracker with a change
    public static let discontinuityReason = "video-format"

    public private(set) var current: Format?
    public private(set) var changes = 0
    public private(set) var lastChange: Change?

    public init() {}

    /// A frame's format; the change if it differs from the previous frame's.
    public mutating func note(width: Int, height: Int, framesPerSecond: Double?, at t: Double) -> Change? {
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
        current = new
        let c = Change(from: old, to: new, at: t)
        changes += 1; lastChange = c
        return c
    }
}
