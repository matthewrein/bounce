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
    public var finder: SlabFinder { didSet { lastSweep = nil } }
    private var choice: EdgeChoice?
    /// The last `detect` that was a plain sweep of the whole view (no seed, no prediction, no finer image), with its
    /// inputs: `look` on the same frame with the same inputs returns its outlines instead of sweeping again (the tracker's
    /// re-check of a lock behind the camera is such a sweep, and the moved-slab look follows it on the same frame).
    /// `SlabFinder.find` is a function of its inputs and the finder's options alone (a change of `finder` forgets it), so
    /// they are the outlines the sweep would return again.
    private var lastSweep: (frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, outlines: [DetectedOutline])?
    /// `look`s answered from the sweep `detect` had just run on the same frame (`lastSweep`)
    public private(set) var looksReused = 0
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
        finder.options.tapSearchesAround = settings.tapHints || base.tapSearchesAround
        finder.options.tapScreens = settings.tapHints || base.tapScreens
    }

    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: nil)
    }

    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                       detail d: DetailImage?) -> [DetectedOutline] {
        let finer = d ?? detail
        let cands = finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: finer,
                                choice: near != nil ? choice : nil)
        detail = nil
        if let c = cands.first { choice = c.choice } else if near == nil { choice = nil }
        let outlines = cands.map(SlabFinderDetector.outline)
        // a plain sweep (`look`'s very call: no seed, no prediction, no finer image, no edge memory)
        lastSweep = seed == nil && near == nil && finer == nil ? (frame, intrinsics, spec, down, outlines) : nil
        return outlines
    }

    public func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?,
                       detail: DetailImage) -> [DetectedOutline] {
        let cands = finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, near: outline, detail: detail, choice: choice)
        if let c = cands.first { choice = c.choice }
        return cands.map(SlabFinderDetector.outline)
    }

    public func forgetPixelMemory() { choice = nil; detail = nil; lastSweep = nil }

    /// A look for the slab grown from a tapped point: the finder's tapped search, leaving the edge memory of the outline
    /// the detector follows (or the sweep's, just found) as it was.
    public func probe(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2) -> [DetectedOutline] {
        finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed).map(SlabFinderDetector.outline)
    }

    /// A look over the whole view (the tracker's moved-slab look while locked): the finder's sweep, leaving the edge memory
    /// of the outline the detector follows (and a finer image set for the next call) as they were. Right after a `detect`
    /// that was the same sweep on the same frame (`lastSweep`), its outlines, without sweeping again.
    public func look(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?) -> [DetectedOutline] {
        if let s = lastSweep, s.intrinsics == intrinsics, s.spec == spec, s.down == down, s.frame == frame {
            looksReused += 1
            return s.outlines
        }
        return finder.find(frame: frame, intrinsics: intrinsics, spec: spec, down: down).map(SlabFinderDetector.outline)
    }

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
    public func setSearchHints(_ hints: BallSearchHints) { searchHints = hints }
}
