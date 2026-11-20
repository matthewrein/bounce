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
///
/// With a finer image (`detect(..., detail:)`, the tracker's full-resolution crop around the slab) the finder refines
/// the edges of the outlines the image covers on it (`SlabFinder.find(detail:)`); `refine` re-runs the finder on one
/// outline a search found, following it as it follows a lock, with the finer image.
public final class SlabFinderDetector: SlabDetecting {
    public var finder: SlabFinder
    private var choice: EdgeChoice?
    /// A finer luma image of the same view (e.g. a full-resolution crop around the slab) for the next call's edges, when
    /// the call does not bring its own.
    public var detail: DetailImage?

    /// the finder's own sweep options, before any tracker's settings (`apply`)
    private let base: SlabFinder.Options

    public init(finder: SlabFinder = SlabFinder()) { self.finder = finder; base = finder.options }

    /// The tracker's settings for the sweep's work (unset ones leave the finder's own).
    public func apply(_ settings: TrackerSettings) {
        finder.options.maxSweepRegions = settings.maxSweepRegions ?? base.maxSweepRegions
        finder.options.skipSeedsInFinds = settings.sweepSkipsFinds || base.skipSeedsInFinds
        finder.options.sameOutlinePixels = settings.sweepSameOutlinePixels > 0 ? settings.sweepSameOutlinePixels : base.sameOutlinePixels
    }

    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: nil)
    }

    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                       detail d: DetailImage?) -> [DetectedOutline] {
        let cands = finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: d ?? detail,
                                choice: near != nil ? choice : nil)
        detail = nil
        if let c = cands.first { choice = c.choice } else if near == nil { choice = nil }
        return cands.map(SlabFinderDetector.outline)
    }

    public func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?,
                       detail: DetailImage) -> [DetectedOutline] {
        let cands = finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, near: outline, detail: detail, choice: choice)
        if let c = cands.first { choice = c.choice }
        return cands.map(SlabFinderDetector.outline)
    }

    public func forgetPixelMemory() { choice = nil; detail = nil }

    /// The tracker's view of a find: with a side profile (the refiner's sides say which feature they rest on), each
    /// side's line noise (and its frame's own part), a one-edge side's middle between its two readings and the profile learned so far go with it
    /// (`DetectedOutline.sideSigmas`, `sideShifts`); without one, as before.
    static func outline(_ c: SlabCandidate) -> DetectedOutline {
        var o = DetectedOutline(quad: c.quad, score: c.score, sideModes: c.sides.map { $0.mode.rawValue })
        if c.sides.count == 4, c.sides.contains(where: { $0.feature != nil }) {
            o.sideSigmas = c.sides.map { $0.topSigmaPixels }
            o.sideTurnSigmas = c.sides.map { $0.turnSigmaPixels }
            o.sideFrameSigmas = c.sides.map { $0.frameSigmaPixels }
            if c.sides.contains(where: { $0.ambiguityShiftPixels != 0 }) { o.sideShifts = c.sides.map { $0.ambiguityShiftPixels } }
            if let p = c.choice?.profile { o.faceDrop = p.faceDrop; o.sideRun = p.sideRun }
        }
        return o
    }
}

/// The ball finder behind the tracker's ball interface. A ball the last scan missed is held over for a couple of
/// scans (carried along with the slab), so a frame where the ball blurs does not drop the drop height.
extension BallLocator: BallLocating {
    /// the last scan's result is a ball held over from an earlier one (`BallObservation.missedUpdates` above 0)
    public var heldOver: Bool { (current?.missedUpdates ?? 0) > 0 }

    public func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        update(luma: image, intrinsics: intrinsics, slab: slab, spec: spec, ball: ball, down: down).map { ($0.center, $0.circle.center, $0.circle.radius) }
    }
}
