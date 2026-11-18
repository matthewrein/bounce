import Foundation

/// The detectors the app and the replay tests use, in one place so a replay runs exactly what the phone ran.
public enum AppDetectors {
    public static func slab() -> SlabDetecting { SlabFinderDetector() }
    public static func ball() -> BallLocating? { BallLocator() }
}

/// A detector that finds nothing (for tests).
public struct NullSlabDetector: SlabDetecting {
    public init() {}
    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] { [] }
}

/// SlabFinder behind the tracker's detector interface. It keeps the edge refiner's memory (which edge of each side is
/// the top face's, by position) from one call to the next while the tracker follows the slab, and forgets it when the
/// tracker searches afresh.
public final class SlabFinderDetector: SlabDetecting {
    public var finder: SlabFinder
    private var choice: EdgeChoice?
    /// A finer luma image of the same view (e.g. a full-resolution crop around the slab) for the next call's edges.
    public var detail: DetailImage?

    public init(finder: SlabFinder = SlabFinder()) { self.finder = finder }

    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        let cands = finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: detail,
                                choice: near != nil ? choice : nil)
        detail = nil
        if let c = cands.first { choice = c.choice } else if near == nil { choice = nil }
        return cands.map { DetectedOutline(quad: $0.quad, score: $0.score, sideModes: $0.sides.map { $0.mode.rawValue }) }
    }
}

/// The ball finder behind the tracker's ball interface. A ball the last scan missed is held over for a couple of
/// scans (carried along with the slab), so a frame where the ball blurs does not drop the drop height.
extension BallLocator: BallLocating {
    public func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        update(luma: image, intrinsics: intrinsics, slab: slab, spec: spec, ball: ball, down: down).map { ($0.center, $0.circle.center, $0.circle.radius) }
    }
}
