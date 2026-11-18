import Foundation

/// The phone's video settings for a kit shot, as `KitRecorder` in the app sets them (CaptureKit.md, "Video"), so the
/// synthetic kits and the bundle's size budget use the same numbers. `KitHandoffTests.testPhoneVideoRuleIsTheApps` checks
/// them against the app's source (KitRecorder, or the BounceCore type it takes the rule from), so a change there shows up
/// here. Where BounceCore holds the same rule elsewhere (the pre-flight's storage estimate), these should call it.
public enum KitPhoneVideo {
    /// the video is the camera picture scaled to at most this wide (`KitRecorder.maxVideoWidth`)
    public static let maxWidth = 1440
    /// ordinary shots keep 30 frames a second; high-frame-rate shots (drops) every frame of ARKit's 60
    public static let keptFps = 30.0
    public static let highFrameRateFps = 60.0
    /// LiDAR depth about once a second (`KitRecorder.depthInterval`), 256 x 192 on current phones
    public static let depthInterval = 1.0
    public static let depthWidth = 256, depthHeight = 192

    /// The video's size for a camera picture (`KitRecorder.consume`): at most `maxWidth` wide, even sizes, same aspect.
    public static func videoSize(cameraWidth: Int, cameraHeight: Int) -> (width: Int, height: Int) {
        let w = min(maxWidth, cameraWidth) / 2 * 2
        let h = Int((Double(cameraHeight) * Double(w) / Double(cameraWidth)).rounded()) / 2 * 2
        return (w, h)
    }

    /// Target bitrate (bits/s), `KitRecorder.bitrate`: HEVC about 3.5 Mbit/s at 30 fps and 6 Mbit/s at 60 fps for
    /// 1440x1080, in proportion to the pixels for other sizes; H.264 1.5 times as much.
    public static func bitrate(width: Int, height: Int, fps: Double, hevc: Bool) -> Int {
        let base = fps > 45 ? 6_000_000.0 : 3_500_000.0
        let pixels = Double(width * height) / Double(1440 * 1080)
        return Int(max(300_000, base * pixels * (hevc ? 1 : 1.5)))
    }

    /// A key frame every second (`AVVideoMaxKeyFrameIntervalKey`).
    public static func keyFrameInterval(fps: Double) -> Int { max(1, Int(fps.rounded())) }

    /// The frames a second a shot keeps.
    public static func fps(_ shot: KitShotSpec) -> Double { shot.kind.highFrameRate ? highFrameRateFps : keptFps }

    /// One BDP2 depth file's bytes (8 header bytes, 2 bytes of depth and 1 of confidence a pixel).
    public static var depthFileBytes: Int64 { Int64(8 + depthWidth * depthHeight * 3) }

    /// The largest single file a video shot of `plan` can make, at most `overshoot` times the encoder's target
    /// bitrate (an average the encoder keeps over the clip; 1 is the target itself), from the 1440x1080 video of a
    /// 1920x1440 camera. The recording stops after the shot's seconds of frame time, so the plan bounds it.
    public static func largestVideoBytes(plan: KitPlan, hevc: Bool, overshoot: Double = 1) -> (shotId: String, bytes: Int64)? {
        let size = videoSize(cameraWidth: 1920, cameraHeight: 1440)
        var best: (String, Int64)? = nil
        for s in plan.shots {
            guard let seconds = s.kind.videoSeconds else { continue }
            let rate = Double(bitrate(width: size.width, height: size.height, fps: fps(s), hevc: hevc))
            // the container (mp4 boxes, sample tables) adds well under 1%; counted as 1% plus 64 KB
            let bytes = Int64((rate / 8 * seconds * overshoot * 1.01).rounded(.up)) + 65_536
            if best == nil || bytes > best!.1 { best = (s.id, bytes) }
        }
        return best
    }
}
