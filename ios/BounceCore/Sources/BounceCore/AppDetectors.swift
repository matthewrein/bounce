import Foundation

/// The detectors the app and the replay tests use, in one place so a replay runs exactly what the phone ran.
/// (Until the ported SlabFinder / BallLocator land these find nothing.)
public enum AppDetectors {
    public static func slab() -> SlabDetecting { NullSlabDetector() }
    public static func ball() -> BallLocating? { nil }
}

public struct NullSlabDetector: SlabDetecting {
    public init() {}
    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] { [] }
}
