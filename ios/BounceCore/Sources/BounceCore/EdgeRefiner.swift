import Foundation

/// Which edge a side of a refined outline rests on.
public enum EdgeMode: String, Codable, Equatable, CaseIterable {
    /// the side's cut face is out of sight (or too thin to matter): the edge found is the top face's own edge
    case silhouette
    /// the cut face shows and the top face's edge was seen inside the outer edge, about one band-width in
    case innerEdge
    /// the cut face shows but its inner edge was not clear: the outer edge (light cut face to black base) moved inward
    /// by the band the box model predicts
    case shiftedOuter
    /// the cut face shows and the strongest edge is already the top face's own: the cut face is darker than the top
    /// (in shadow), with the base darker still one band further out, or with no black base right outside it (the slab
    /// overhangs the floor where it slides in its cradle, or the base's lit rim shows)
    case outerIsTop
    /// too few edge points along the side: its line was kept as given
    case unfitted
}

/// What the edge refiner did on one side of the outline.
public struct SideEdge: Equatable {
    /// the side's settled mode: the edge its output line rests on, kept across calls with hysteresis (it changes only
    /// once another mode has been used on `switchAfter` calls in a row), so it does not flicker with the evidence
    public var mode: EdgeMode
    /// the band as the box model predicts it: frame pixels, perpendicular to the side, mean of its two ends (0 when the
    /// cut face is hidden)
    public var bandPixels: Double
    /// the step (grey levels) of the edge the output rests on: the inner edge's when it was used, else the outer edge's
    public var contrast: Double
    /// the strongest edge's step, signed outward (negative: darker outside)
    public var outerContrast: Double
    /// the inner partner's step, signed outward; 0 if none was found
    public var innerContrast: Double
    /// how far inside the outer edge the output lies, as a share of the predicted band (0: on the outer edge)
    public var shift: Double
    /// edge points on the outer line
    public var points: Int
    /// luma just outside the outer edge as a share of the top face's (small: the black base lies there); 0 on silhouettes
    public var outsideRatio: Double
    /// what this call's image evidence alone said (no memory): how the strongest edge relates to the top face's edge
    public var observed: EdgeMode
    /// the edge this call's output line was placed on (the observation, unless the predicted top line overruled a weak
    /// or not yet repeated one)
    public var used: EdgeMode
    /// the step (grey levels, signed outward) of a further darkening edge found one band outside the strongest edge; 0 if
    /// none
    public var outerPartnerContrast: Double
    /// where the predicted top line (`EdgeChoice.outline`) lay from the strongest edge, in predicted bands (negative:
    /// inside); nil without a prediction
    public var predictedShift: Double?

    // The side's uncertainty (frame pixels), for an honest estimate of the tilt. With a side profile
    // (`SlabSpec.hasProfile`) every term is measured; without one only the floors and the ambiguity are known.

    /// With a profile, the feature the line rests on (`SideFeature`); nil without one
    public var feature: SideFeature? = nil
    /// 1-sigma uncertainty of the line's position across the side (a parallel shift), in quadrature: the edge points'
    /// scatter about the line (floored at the measured still-frame jitter, `Options.edgeJitterRadians` x f), the edge's
    /// definition on the slab (`Options.edgeDefinitionSigma`), the profile's uncertainty carried into this side's feature,
    /// and on a side whose face shows but whose two edges were not both seen, half the band (its two readings lie a band
    /// apart; see `ambiguityShiftPixels`). Motion blur is not included: the caller knows the camera's motion.
    public var topSigmaPixels: Double = 0
    /// 1-sigma uncertainty of the line's turn about the side's middle, as the displacement of its ends (from the edge
    /// points' scatter, floored at `Options.turnFloorRadians` x f)
    public var turnSigmaPixels: Double = 0
    /// the edge points' own contribution to `topSigmaPixels` (their scatter about the line / sqrt(n - 2), before the floor)
    public var fitSigmaPixels: Double = 0
    /// how many edge points (with a profile: segment medians) the line was fitted through
    public var segments: Int = 0
    /// a side whose face shows: both its edges (the top's departure and the band's bottom one predicted band further out)
    /// were seen on at least 3 segments
    public var twoEdges: Bool = false
    /// the line was placed by the profile, not seen: one step to the background, taken as the band's bottom and moved
    /// in by the predicted band
    public var modelPlaced: Bool = false
    /// on a side whose two edges were not both seen and whose one step could be either of them: how far outward (frame
    /// pixels, negative inward) the middle of the two readings lies from the line placed. Half the band either way; an
    /// estimate that wants to stay neutral between them centres the side there (its sigma covers both).
    public var ambiguityShiftPixels: Double = 0
    /// the band seen between the side's two edges (frame pixels), when both were seen
    public var measuredBandPixels: Double? = nil

    public init(mode: EdgeMode, bandPixels: Double, contrast: Double, outerContrast: Double, innerContrast: Double, shift: Double,
                points: Int, outsideRatio: Double, observed: EdgeMode? = nil, used: EdgeMode? = nil, outerPartnerContrast: Double = 0,
                predictedShift: Double? = nil) {
        self.mode = mode; self.bandPixels = bandPixels; self.contrast = contrast; self.outerContrast = outerContrast
        self.innerContrast = innerContrast; self.shift = shift; self.points = points; self.outsideRatio = outsideRatio
        self.observed = observed ?? mode; self.used = used ?? mode; self.outerPartnerContrast = outerPartnerContrast
        self.predictedShift = predictedShift
    }
}

/// The edge refiner's memory between calls: where each side's top edge was, so a side does not flip between the top
/// face's edge and the bottom of its cut face on noise. The caller passes the last result's `choice` back in on the next
/// call, moved to where the slab should now appear (`moved(to:)`; the slab finder does this with its `near` outline).
public struct EdgeChoice: Equatable, Codable {
    public struct Side: Equatable, Codable {
        /// the settled mode reported for the side
        public var mode: EdgeMode
        /// a different mode used on the last `pendingCount` calls in a row; it takes over once used often enough
        public var pending: EdgeMode?
        public var pendingCount: Int
        /// the visible share of the predicted band, learned from the band's two edges seen together (1 until seen)
        public var bandScale: Double
        /// how many times the band's two edges have been seen together
        public var sightings: Int
        /// calls in a row on which clear image evidence put the top edge on the other edge than the predicted top line
        /// did; the evidence wins once this reaches `switchAfter`
        public var disagreements: Int
        public init(mode: EdgeMode, pending: EdgeMode? = nil, pendingCount: Int = 0, bandScale: Double = 1, sightings: Int = 0,
                    disagreements: Int = 0) {
            self.mode = mode; self.pending = pending; self.pendingCount = pendingCount; self.bandScale = bandScale
            self.sightings = sightings; self.disagreements = disagreements
        }
    }
    /// per side of `outline` (side i runs from corner i to corner i+1)
    public var sides: [Side]
    /// the top-face outline (frame pixels) the sides belong to, and where the refiner expects the top edges: the last
    /// output, or that outline moved by the camera's motion (`moved(to:)`). A new outline is matched to it corner by corner.
    public var outline: [Vec2]
    /// the slab normal last solved (camera axes), for the pose solver's mirror-image hysteresis
    public var normal: Vec3?
    /// with a side profile (`SlabSpec.hasProfile`): what has been learned of it on this slab (nil: the spec's prior)
    public var profile: ProfileLearning?

    public init(sides: [Side], outline: [Vec2], normal: Vec3?, profile: ProfileLearning? = nil) {
        self.sides = sides; self.outline = outline; self.normal = normal; self.profile = profile
    }

    /// The same memory with the top outline moved to where the slab should appear now (e.g. the last pose moved by the
    /// camera's motion, projected), in either corner order; nil when the two outlines are too far apart to be the same
    /// slab. The normal is kept (it is only a tie-breaker between mirror-image poses).
    public func moved(to predicted: [Vec2]) -> EdgeChoice? {
        guard let s = sides(matching: predicted) else { return nil }
        return EdgeChoice(sides: s, outline: predicted, normal: normal, profile: profile)
    }

    /// The sides re-indexed to another outline of the same slab (matched corner to corner, either way round); nil when the
    /// outlines are too far apart to be the same sides.
    func sides(matching q: [Vec2]) -> [Side]? {
        guard let m = correspondence(q) else { return nil }
        return (0..<4).map { i -> Side in
            let a = m[i], b = m[(i + 1) % 4]
            return sides[b == (a + 1) % 4 ? a : b]
        }
    }

    /// For each side of `q`, the matching side of `outline` (its two ends): where that side's top edge is expected.
    func expectedLines(matching q: [Vec2]) -> [(Vec2, Vec2)]? {
        guard let m = correspondence(q) else { return nil }
        return (0..<4).map { i in (outline[m[i]], outline[m[(i + 1) % 4]]) }
    }

    func correspondence(_ q: [Vec2]) -> [Int]? {
        guard sides.count == 4, outline.count == 4, q.count == 4 else { return nil }
        let m = Geometry.bestCorrespondence(q, outline)
        guard m.meanDistance < 0.75 * ShapeCheck.meanSide(q) else { return nil }
        return m.map
    }
}

/// Finds the top face's edge on every side of a slab outline, using the slab as a box with thickness.
///
/// On a side whose cut face the camera can see, the image shows two parallel edges about one band apart: the top face
/// meeting the cut face, and the cut face meeting what lies beyond it (usually the black base). A plain edge search
/// lands on either, from one frame to the next, which made the near edge flip on the real phone. Here the pose is solved
/// from the outline, the box model predicts for each side whether its cut face shows and how wide its band is in pixels,
/// and the gradient profiles across each side are searched for the strongest edge and for parallel partner edges about
/// one band-width inside and outside it. The output is always the top edge:
/// - an edge one band inside the strongest one (either way: a lit or a shadowed cut face) means the strongest edge is the
///   band's bottom, and the partner is the top edge;
/// - a further darkening edge one band outside means the cut face is in shadow with the base darker still: the strongest
///   edge is the top edge;
/// - with no partner: if right outside the strongest edge it is darker than the top face but not black (a cut face in
///   shadow, then the floor or the base's lit rim), the strongest edge is the top edge; if the band just inside it is
///   clearly darker than the top face (a shadowed cut face fading into the black base), the top edge is where the top
///   face's own level ends; otherwise (a cut face about as light as the top, on the black base) the strongest edge is the
///   band's bottom, moved inward by the predicted band.
/// Sides whose cut face is hidden are silhouettes: the first clear edge from the inside is the top edge (beyond it there
/// may be a sliver of black base and then the floor). Pose -> bands -> edges is iterated.
///
/// Memory (`EdgeChoice`) keeps each side's top line on the same physical edge from call to call. The last output, moved
/// by the camera's motion when the caller knows it (`EdgeChoice.moved(to:)`), says where each top edge should be. When
/// this call's evidence is weak (no partner edge, or one barely clear of its threshold) the candidate nearer that
/// prediction is used, and clear evidence for the other edge must repeat on `switchAfter` calls in a row before it wins.
/// The memory is a position, not a label: when the strongest edge itself moves from one physical edge to the other (a
/// cut face about halfway between the top's and the base's luma), each call's reading is applied to the edge it was
/// made on, and the output stays on the top edge.
public struct EdgeRefiner {
    public struct Options {
        /// edge readings per side
        public var spokes = 32
        /// rounds of pose -> bands -> edges: at least `iterations`, and up to `maxIterations` while a corner still moves by
        /// more than `settlePixels` (frame pixels) in a round (an outline that starts a few pixels off can make the first
        /// pose show a band on a side whose cut face is hidden; the next rounds undo that)
        public var iterations = 2
        public var maxIterations = 4
        public var settlePixels = 0.25
        /// a cut face whose band is thinner than this (frame pixels) is treated as hidden
        public var minBandPixels = 1.0
        /// right outside the strongest edge, luma below this share of the top face's counts as black (the base)
        public var darkRatio = 0.4
        /// ... and at or above this share, as not darker than the top (so the strongest edge cannot be the top's own)
        public var maxOutsideRatio = 0.9
        /// a reading's outer edge on a side whose cut face shows must step by at least this much (grey levels)
        public var minEdgeStep = 6.0
        /// the band just inside the strongest edge is darker than the top face when its luma is below this share of the
        /// top's (and lighter when above 2 minus this share)
        public var shadowedBandRatio = 0.85
        /// where partner edges are looked for, as a share of the predicted band
        public var partnerScales: ClosedRange<Double> = 0.5...1.7
        /// a partner edge must step by at least this much (grey levels, averaged along the side) ...
        public var minPartnerContrast = 3.0
        /// ... and stand this many standard errors clear of the side's scatter ...
        public var partnerNoiseFactor = 4.0
        /// ... and (one inside) be at least this share of the strongest edge's step
        public var innerContrastRatio = 0.08
        /// a further darkening edge outside the strongest one must step by at least this much (grey levels)
        public var minOuterPartnerContrast = 4.0
        /// where a band is too narrow for its two edges to stand apart: the strongest edge is the top's own when the luma
        /// right outside it exceeds the base's one band further out by this share of the top's step down to that base
        public var outerLevelShare = 0.15
        /// a partner edge at least this many times its threshold is clear evidence: it can overrule the predicted top line
        /// (after `switchAfter` calls in a row); weaker evidence cannot
        public var clearFactor = 1.5
        /// the predicted top line decides between the two candidate edges only when it lies within this share of the
        /// band (plus a pixel) of one of them, and nearer it by at least this share of the band
        public var predictionReach = 0.5
        public var predictionMargin = 0.4
        /// a side changes its reported mode only after the new one has been used on this many calls in a row; clear
        /// evidence against the predicted top line must repeat as often before it moves the line
        public var switchAfter = 3
        /// how fast the visible share of the band is learned from the band's two edges seen together, and its limits
        public var bandScaleRate = 0.25
        public var bandScaleRange: ClosedRange<Double> = 0.6...1.4
        public var pose = PoseSolver.Options()

        // With a side profile (`SlabSpec.hasProfile`). Constants measured on one kit (slab-kit-20261118: the owner's slab,
        // phone and floor); confirm them on renders and on the next kit.

        /// a side whose face shows is read at its departure when the predicted band is at least this wide (pixels of the
        /// image searched): narrower, its two edges cannot be told apart and the side is read at its outline
        public var bandSwitchPixels = 2.0
        /// the floor under an edge line's scatter, as an angle (x the focal length: pixels): the kit's still-frame jitter
        /// was 0.11-0.14 video px at f 1016 (and the segment fits' scatter 0.09-0.10, which agrees)
        public var edgeJitterRadians = 1.2e-4
        /// the floor under a line's turn (its ends' displacement): the kit's side turns were 0.22-0.43 px at f 1016
        public var turnFloorRadians = 2.0e-4
        /// the edge's definition on the slab (metres, per side): a coherent per-side pattern of 0.14-0.48 mm was left by
        /// true-normal fits on the kit, about twice that as an independent sigma
        public var edgeDefinitionSigma = 0.0005
        /// the profile's prior sigmas (metres) about the spec's face drop and side run (the kit's fits spread 19.5-22.2 and
        /// 6.8-8.2 mm; kept wide), and the rounded edge's (an effective value, 1-3 mm fitted the kit about as well)
        public var faceDropPriorSigma = 0.005
        public var sideRunPriorSigma = 0.004
        public var edgeRadiusSigma = 0.0015
        /// once `learnAfter` bands have been seen, the learned profile's sigmas, at least these (metres)
        public var learnAfter = 5
        public var learnedFaceDropFloor = 0.0015
        public var learnedSideRunFloor = 0.001
        /// how many band observations the profile's fit keeps (the newest)
        public var profileMemory = 40
        /// the runs along a side whose median edge offsets the line is fitted through
        public var segments = 5
        /// a band in deep shadow on the black base counts as seen (both its edges) only if the base beyond is darker than
        /// the band by at least this share of the band's luma: the slab's material in shadow against black. A judgement,
        /// not measured on the kit: on renders a shadowed band (0.25-0.33 of the top over a base at 0.17) leaves 0.3-0.5,
        /// the black cradle's top against its own shaded side 0.1-0.15.
        public var darkBandContrast = 0.25
        public init() {}
    }

    public struct Result: Equatable {
        /// the refined top-face outline (frame pixels, same corner order as the input)
        public var outline: [Vec2]
        /// the pose solved from it (frame intrinsics)
        public var fit: PoseFit
        /// per side (side i runs from corner i to corner i+1)
        public var sides: [SideEdge]
        /// pass this back in on the next call (moved by the camera's motion: `EdgeChoice.moved(to:)`)
        public var choice: EdgeChoice
    }

    /// What one call's image evidence alone says about a side whose cut face shows.
    struct Reading {
        var mode: EdgeMode          // .innerEdge, .outerIsTop or .shiftedOuter
        var clear: Bool             // a partner edge (or level change) well clear of its threshold
        var inner: Partner?         // the top edge found inside the strongest one
        var outerPartner: Partner?  // a further darkening edge found outside it (the band's bottom, the strongest being the top)
        var ratio: Double           // luma right outside the strongest edge / the top face's
        var bandRatio: Double       // luma just inside it / the top face's
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// The edge steps' sampling unit, in pixels of the image they read, `ds` times finer than the frame searched (its
    /// profiles are read every half unit, its steps measured over three units): half a frame pixel, but on a finer image
    /// (the camera's own pixels) never more than one of its pixels. A camera's edges are 2-3 of its pixels wide; read at
    /// half a frame pixel (2 camera pixels at the app's factor 4) they are sharper than the step measure, whose peak then
    /// lands on the edge's inner side (measured on the synthetic slab at 1920x1440: corners 0.7-0.9 px off at 4-6 ft,
    /// worse than the frame's own 0.2-0.3 px; at one camera pixel 0.1-0.2 px, `SlabDetailGainTests`). Unchanged for the
    /// frame itself and for crops up to twice as fine.
    static func unit(scale ds: Double) -> Double {
        ds <= 2 ? max(0.5, ds / 2) : 1
    }

    /// Refine an outline of the slab in a colour frame (its luma is used).
    public func refine(outline: [Vec2], frame: ColorFrame, intrinsics K: CameraIntrinsics, spec: SlabSpec, down: Vec3?,
                       choice: EdgeChoice? = nil) -> Result? {
        refine(outline: outline, intrinsics: K, luma: frame.y, lumaIntrinsics: K, spec: spec, down: down, choice: choice)
    }

    /// Refine an outline of the slab.
    /// - Parameters:
    ///   - outline: four corners (pixels of the frame `K` describes), in outline order; usually the outer outline a
    ///     colour or edge search found, or the outline predicted from the last frame
    ///   - K: the frame's intrinsics (the outline's pixels)
    ///   - luma: the image searched for edges: the frame's luma, or a finer image of the same view (e.g. the camera's
    ///     full-resolution luma, or a crop of it) described by `lumaIntrinsics`
    ///   - down: gravity in camera axes (the pose's level prior, and so which cut faces show). Without it the pose can
    ///     come out as its mirror image, which puts the bands on the wrong sides: pass it whenever it is known.
    ///   - choice: the last call's `choice` for this slab, moved to where the slab should be now (`moved(to:)`) when the
    ///     camera has moved
    public func refine(outline: [Vec2], intrinsics K: CameraIntrinsics, luma: Plane, lumaIntrinsics KDIn: CameraIntrinsics? = nil,
                       spec: SlabSpec, down: Vec3?, choice: EdgeChoice? = nil) -> Result? {
        guard outline.count == 4, ShapeCheck.isConvex(outline) else { return nil }
        let KD = KDIn ?? K
        if spec.hasProfile {
            return refineWithProfile(outline: outline, intrinsics: K, luma: luma, lumaIntrinsics: KD, spec: spec, down: down, choice: choice)
        }
        let map = ImageMap(from: K, to: KD)
        let ds = map.scale, unit = EdgeRefiner.unit(scale: ds)
        let prevSides = choice?.sides(matching: outline)
        let expected = choice?.expectedLines(matching: outline).map { $0.map { (map.forward($0.0), map.forward($0.1)) } }
        var cur = outline.map(map.forward)
        var sides: [SideEdge] = []
        var states: [EdgeChoice.Side] = []
        let h = 1.5 * unit
        var round = 0
        while true {
            round += 1
            let fit = PoseSolver.solve(corners: cur, intrinsics: KD, spec: spec, down: down, previousNormal: choice?.normal, options: options.pose)
            let bands = fit.map { Geometry.predictBands(pose: $0.pose, outline: cur, intrinsics: KD, spec: spec) }
                ?? [Band](repeating: Band(visible: false, start: 0, end: 0), count: 4)
            let c = Geometry.centroid(cur)
            var lines: [Line2] = []
            var maxBand = 0.0
            sides = []; states = []
            for i in 0..<4 {
                let A = cur[i], B = cur[(i + 1) % 4], len = A.distance(to: B)
                guard len > 4 * unit else { return nil }
                let dir = (B - A) / len
                var nrm = dir.perpendicular
                if nrm.dot((A + B) / 2 - c) < 0 { nrm = -nrm }
                let prev = prevSides?[i]
                // visible, with hysteresis on the band's width so a side seen nearly edge-on does not flip
                let bd = bands[i], meanBandFrame = (bd.start + bd.end) / 2 / ds
                var visible = false
                if bd.visible {
                    let need: Double
                    switch prev?.mode {
                    case nil: need = options.minBandPixels
                    case .some(.silhouette): need = options.minBandPixels * 1.5
                    default: need = options.minBandPixels * 0.5
                    }
                    visible = meanBandFrame >= need
                }
                let b0 = visible ? bd.start : 0, b1 = visible ? bd.end : 0, bmax = max(b0, b1)
                maxBand = max(maxBand, bmax)
                // how far either side of the given line to look: up to ~2 bands (the line may be the top edge or the cut
                // face's bottom), plus a margin for an outline a few pixels off. (A wider margin let weak sides jump to
                // stronger edges beyond them on the matched-tone floor fixture; a tracker should predict the outline from
                // the camera's motion instead.)
                let margin = max(3 * ds, 0.06 * len)
                let reach = 1.8 * bmax + margin
                let sp = SpokeProfiles(luma: luma, a: A, b: B, normal: nrm, inward: reach, outward: reach, unit: unit,
                                       count: options.spokes)
                // the strongest edge: on a side whose cut face shows, the strongest step from light (inside) to dark
                // (outside), or failing that (a floor lighter than the cut face beyond it) the strongest step to light; on
                // a silhouette, the first clear step from the inside, either way
                var outer: (line: Line2, inliers: Int)? = nil
                var darkening = false
                if visible {
                    // one edge, coherently along the side (the band's two edges lie apart by at least its narrower end)
                    let coh = (window: max(0.75 * ds, 0.4 * min(b0, b1)), maxTilt: max(2 * ds, 0.04 * len))
                    outer = sp.edgeLine(.strongestDarkening, unit: unit, minStep: options.minEdgeStep, coherent: coh)
                    darkening = outer != nil
                    if outer == nil { outer = sp.edgeLine(.strongestBrightening, unit: unit, minStep: options.minEdgeStep, coherent: coh) }
                } else {
                    outer = sp.edgeLine(.firstFromInside, unit: unit)
                }
                guard let outer = outer else {
                    lines.append(Line2(p: A, d: dir))
                    states.append(Self.update(prev, raw: .unfitted, partnerScale: nil, options: options))
                    sides.append(SideEdge(mode: .unfitted, bandPixels: meanBandFrame, contrast: 0, outerContrast: 0, innerContrast: 0,
                                          shift: 0, points: 0, outsideRatio: 0, observed: .unfitted, used: .unfitted))
                    continue
                }
                let offL = sp.offsets(of: outer.line)
                let muL = sp.mean(at: offL) ?? 0
                guard visible else {
                    lines.append(outer.line)
                    states.append(Self.update(prev, raw: .silhouette, partnerScale: nil, options: options))
                    sides.append(SideEdge(mode: .silhouette, bandPixels: 0, contrast: abs(muL), outerContrast: muL, innerContrast: 0,
                                          shift: 0, points: outer.inliers, outsideRatio: 0, observed: .silhouette, used: .silhouette))
                    continue
                }
                let bandMid = max((b0 + b1) / 2, 1e-9)
                let r = read(sp, luma: luma, offsets: offL, band: (b0, b1), darkening: darkening, strongest: muL, ds: ds, h: h, unit: unit)
                // the two candidates for the top edge: the strongest edge itself, or the edge one band inside it (the
                // inner edge seen, or the strongest edge moved in by the learned share of the band)
                let inK = r.inner?.scale ?? (prev?.bandScale ?? 1)
                // where the predicted top line lies from the strongest edge, in bands (negative: inside)
                var predShift: Double? = nil
                if let ex = expected?[i] {
                    let po = sp.offsets(of: Line2(p: ex.0, d: (ex.1 - ex.0).normalized))
                    predShift = zip(po, offL).map { $0 - $1 }.reduce(0, +) / Double(po.count) / bandMid
                }
                var preferTop: Bool? = nil
                if let ps = predShift, inK * bandMid >= 1.5 * ds {
                    let dTop = abs(ps), dIn = abs(ps + inK)
                    if abs(dTop - dIn) >= options.predictionMargin * inK && min(dTop, dIn) <= options.predictionReach * inK + ds / bandMid {
                        preferTop = dTop < dIn
                    }
                }
                var useTop = r.mode == .outerIsTop
                var disagreements = 0
                if let pt = preferTop, pt != useTop {
                    // weak evidence never moves a side off the edge it was on; clear evidence must repeat first
                    disagreements = r.clear ? (prev?.disagreements ?? 0) + 1 : 0
                    if !r.clear || disagreements < options.switchAfter { useTop = pt } else { disagreements = 0 }
                }
                let used: EdgeMode
                var k = 0.0
                if useTop { used = .outerIsTop }
                else if let p = r.inner { used = .innerEdge; k = p.scale }
                else { used = .shiftedOuter; k = prev?.bandScale ?? 1 }
                // the band's two edges seen together teach its visible share
                let seenScale = used == .innerEdge ? r.inner?.scale : used == .outerIsTop ? r.outerPartner?.scale : nil
                var st = Self.update(prev, raw: used, partnerScale: seenScale, options: options)
                st.disagreements = disagreements
                states.append(st)
                lines.append(k == 0 ? outer.line : sp.shifted(offsets: offL, by: k, band: (b0, b1)))
                sides.append(SideEdge(mode: st.mode, bandPixels: meanBandFrame,
                                      contrast: used == .innerEdge ? abs(r.inner!.mu) : abs(muL), outerContrast: muL,
                                      innerContrast: r.inner?.mu ?? 0, shift: k, points: outer.inliers, outsideRatio: r.ratio,
                                      observed: r.mode, used: used, outerPartnerContrast: r.outerPartner?.mu ?? 0,
                                      predictedShift: predShift))
            }
            // corners where the new lines cross (a corner that would jump implausibly far keeps its place)
            var next = cur
            for i in 0..<4 {
                let a = lines[(i + 3) % 4], b = lines[i]
                guard let p = a.intersection(b) else { continue }
                let side = min(cur[i].distance(to: cur[(i + 3) % 4]), cur[i].distance(to: cur[(i + 1) % 4]))
                if p.distance(to: cur[i]) < 0.2 * side + 2 * maxBand + 2 * ds { next[i] = p }
            }
            guard ShapeCheck.isConvex(next) else { return nil }
            let moved = zip(next, cur).map { $0.distance(to: $1) }.max() ?? 0
            cur = next
            if round >= max(1, options.iterations) && (moved <= options.settlePixels * ds || round >= max(options.iterations, options.maxIterations)) { break }
        }
        let out = cur.map(map.inverse)
        guard let fit = PoseSolver.solve(corners: out, intrinsics: K, spec: spec, down: down, previousNormal: choice?.normal, options: options.pose) else { return nil }
        // the sides' uncertainty, as far as this refiner knows it: the floors, the edge's definition, and on a side moved
        // in by the predicted band, half the band (it could be the top edge itself)
        let defPx = options.edgeDefinitionSigma * K.focal / max(0.05, fit.pose.center.z), j0 = options.edgeJitterRadians * K.focal
        for k in sides.indices where sides[k].mode != .unfitted {
            let amb = sides[k].used == .shiftedOuter ? sides[k].bandPixels / 2 : 0
            sides[k].topSigmaPixels = (j0 * j0 + defPx * defPx + amb * amb).squareRoot()
            sides[k].turnSigmaPixels = options.turnFloorRadians * K.focal
            sides[k].ambiguityShiftPixels = amb
            sides[k].modelPlaced = sides[k].used == .shiftedOuter
            sides[k].twoEdges = sides[k].used == .innerEdge || (sides[k].used == .outerIsTop && sides[k].outerPartnerContrast != 0)
        }
        let newChoice = EdgeChoice(sides: states, outline: out, normal: fit.pose.normal)
        return Result(outline: out, fit: fit, sides: sides, choice: newChoice)
    }

    /// Read a side whose cut face shows: is the strongest edge the top face's own edge or the band's bottom? (`offL`:
    /// each reading's offset to the strongest edge; `band`: the predicted band at the side's two ends, edge-image pixels)
    func read(_ sp: SpokeProfiles, luma: Plane, offsets offL: [Double], band: (Double, Double), darkening: Bool, strongest muL: Double,
              ds: Double, h: Double, unit: Double) -> Reading {
        let bmax = max(band.0, band.1), bandMid = max((band.0 + band.1) / 2, 1e-9)
        // the top face, beyond where the band could reach
        let top = [-1.6 * bmax - 2 * ds, -1.6 * bmax - 3 * ds]
        // right outside the strongest edge: its darkest luma (so a thin strip of black base before the floor still counts),
        // no further out than most of a band (beyond that lies whatever is past the band's bottom)
        let outEnd = min(2.25 * ds, max(1.25 * ds, 0.8 * bmax))
        let outside = Array(stride(from: 0.75 * ds, through: outEnd + 1e-9, by: 0.5 * ds))
        let ratio = sp.lumaRatio(luma: luma, offsets: offL, outside: outside, inside: top, unit: unit)
        // the band just inside the strongest edge, against the top face
        let bandRatio = sp.lumaRatio(luma: luma, offsets: offL, outside: [-0.75 * bmax, -0.5 * bmax, -0.25 * bmax].filter { $0 < -0.5 * ds },
                                     inside: top, unit: unit, darkest: false)
        var r = Reading(mode: .shiftedOuter, clear: false, inner: nil, outerPartner: nil, ratio: ratio, bandRatio: bandRatio)
        // 1. an edge one band inside, either way (a lit or a shadowed cut face): the strongest edge is the band's bottom
        let thrIn = max(options.minPartnerContrast, options.innerContrastRatio * abs(muL))
        if let p = sp.partner(offsets: offL, band: band, direction: -1, scales: options.partnerScales, minSeparation: 2 * h,
                              minContrast: thrIn, noiseFactor: options.partnerNoiseFactor) {
            r.mode = .innerEdge; r.inner = p
            r.clear = abs(p.mu) >= options.clearFactor * max(thrIn, options.partnerNoiseFactor * p.se)
            return r
        }
        // 2. a further darkening edge one band outside: the cut face is in shadow and the base darker still, so the
        //    strongest edge is the top's own
        if darkening, let p = sp.partner(offsets: offL, band: band, direction: 1, scales: options.partnerScales, minSeparation: 2 * h,
                                         minContrast: options.minOuterPartnerContrast, noiseFactor: options.partnerNoiseFactor, sign: -1) {
            r.mode = .outerIsTop; r.outerPartner = p
            r.clear = abs(p.mu) >= options.clearFactor * max(options.minOuterPartnerContrast, options.partnerNoiseFactor * p.se)
            return r
        }
        // 2b. the same seen in luma levels, where the band is too narrow for its two edges to stand apart: right outside the
        //    strongest edge clearly lighter than the base one band further out
        if darkening {
            let topLevel = sp.lumaLevel(luma: luma, offsets: offL, at: top, unit: unit)
            let near = ratio * max(topLevel, 1)
            let far = sp.lumaLevel(luma: luma, offsets: offL, at: [bmax + ds, bmax + 1.75 * ds, bmax + 2.5 * ds], unit: unit, darkest: true)
            if near - far >= max(options.minOuterPartnerContrast, options.outerLevelShare * (topLevel - far)) {
                r.mode = .outerIsTop
                return r
            }
        }
        // 3. right inside at the top's level, right outside darker than the top but not black (a cut face in shadow, then
        //    the floor or the base's lit rim): the strongest edge is the top's own. Black there is the base below the
        //    band's bottom; at least the top's level, a lit floor below it.
        if darkening && ratio >= options.darkRatio && ratio < options.maxOutsideRatio && abs(bandRatio - 1) <= 1 - options.shadowedBandRatio {
            r.mode = .outerIsTop
            return r
        }
        // 4. the band just inside clearly darker than the top (a cut face in shadow fading into the black base, its two
        //    edges merged): the top edge is where the top face's own level ends
        if darkening && bandRatio < options.shadowedBandRatio,
           let cp = sp.changePoint(offsets: offL, from: -1.7 * bmax - 2 * ds, to: 0, minInner: 2 * h, minOuter: 0.5 * ds),
           cp.contrast < 0, abs(cp.contrast) >= max(options.minPartnerContrast, options.partnerNoiseFactor * cp.se),
           -cp.offset / bandMid >= options.partnerScales.lowerBound - 0.2, -cp.offset / bandMid <= options.partnerScales.upperBound {
            r.mode = .innerEdge
            r.inner = Partner(scale: -cp.offset / bandMid, mu: cp.contrast, se: cp.se)
            r.clear = abs(cp.contrast) >= options.clearFactor * max(options.minPartnerContrast, options.partnerNoiseFactor * cp.se)
            return r
        }
        // 5. otherwise a cut face about as light as the top on the black base: the strongest edge is the band's bottom
        return r
    }

    /// One side's memory after this call: the mode used takes over the reported one once used `switchAfter` times in a
    /// row; a band share seen is learned.
    static func update(_ prev: EdgeChoice.Side?, raw: EdgeMode, partnerScale: Double?, options: Options) -> EdgeChoice.Side {
        var s = prev ?? EdgeChoice.Side(mode: raw)
        if let k = partnerScale {
            let r = options.bandScaleRange
            s.bandScale = s.sightings == 0 ? clamp(k, r.lowerBound, r.upperBound)
                : clamp(s.bandScale + (k - s.bandScale) * options.bandScaleRate, r.lowerBound, r.upperBound)
            s.sightings += 1
        }
        if prev == nil { return s }
        if raw == s.mode { s.pending = nil; s.pendingCount = 0; return s }
        // becoming visible or hidden follows the box model directly (its own hysteresis is on the band's width); a side
        // whose edge was not found this time keeps its mode
        if raw == .unfitted { return s }
        if raw == .silhouette || s.mode == .silhouette || s.mode == .unfitted {
            s.mode = raw; s.pending = nil; s.pendingCount = 0; return s
        }
        if s.pending == raw { s.pendingCount += 1 } else { s.pending = raw; s.pendingCount = 1 }
        if s.pendingCount >= options.switchAfter { s.mode = raw; s.pending = nil; s.pendingCount = 0 }
        return s
    }
}

// MARK: - Shared geometry and edge sampling (used by the edge refiner and the slab finder)

/// A 2-D line through p along unit direction d.
struct Line2: Equatable {
    var p: Vec2
    var d: Vec2
    func intersection(_ o: Line2) -> Vec2? {
        let c = d.cross(o.d)
        guard abs(c) > 1e-6 else { return nil }
        let t = (o.p - p).cross(o.d) / c
        return p + d * t
    }
    /// signed distance of q from the line (positive to the left of d in a y-up frame, i.e. along d.perpendicular)
    func distance(_ q: Vec2) -> Double { d.cross(q - p) }
}

/// Maps pixels of one image to another image of the same camera view (both described by pinhole intrinsics).
struct ImageMap {
    let from: CameraIntrinsics
    let to: CameraIntrinsics
    init(from: CameraIntrinsics, to: CameraIntrinsics) { self.from = from; self.to = to }
    var scale: Double { to.focal / from.focal }
    func forward(_ p: Vec2) -> Vec2 { Vec2((p.x - from.cx) / from.fx * to.fx + to.cx, (p.y - from.cy) / from.fy * to.fy + to.cy) }
    func inverse(_ p: Vec2) -> Vec2 { Vec2((p.x - to.cx) / to.fx * from.fx + from.cx, (p.y - to.cy) / to.fy * from.fy + from.cy) }
}

/// The predicted cut-face band on one side of an image outline: whether it shows and how far its bottom lies outside the
/// top edge at the side's two ends (pixels, perpendicular to the side).
struct Band: Equatable {
    var visible: Bool
    var start: Double
    var end: Double
}

/// A partner edge found parallel to a side's outer edge.
struct Partner {
    var scale: Double   // where, as a share of the predicted band
    var mu: Double      // its mean step (grey levels, signed outward)
    var se: Double      // standard error of that mean across the side's readings
}

enum Geometry {
    static func centroid(_ q: [Vec2]) -> Vec2 { q.reduce(Vec2.zero, +) / Double(max(1, q.count)) }

    /// shoelace sum (positive: clockwise on screen, with y down)
    static func signedArea(_ q: [Vec2]) -> Double {
        var a = 0.0
        for i in 0..<q.count { let p = q[i], r = q[(i + 1) % q.count]; a += p.x * r.y - r.x * p.y }
        return a / 2
    }

    /// Which corner of `ref` each corner of `q` is (the best of the 8 ways two quadrilaterals can correspond).
    static func bestCorrespondence(_ q: [Vec2], _ ref: [Vec2]) -> (map: [Int], meanDistance: Double) {
        var best: [Int] = [0, 1, 2, 3], bd = Double.infinity
        for r in 0..<4 {
            for dir in [1, -1] {
                var d = 0.0, m = [Int](repeating: 0, count: 4)
                for i in 0..<4 { let j = ((r + dir * i) % 4 + 4) % 4; m[i] = j; d += q[i].distance(to: ref[j]) }
                if d < bd { bd = d; best = m }
            }
        }
        return (best, bd / 4)
    }

    /// `q` reordered (start and direction) to correspond corner by corner with `ref`.
    static func aligned(_ q: [Vec2], to ref: [Vec2]) -> [Vec2] {
        let m = bestCorrespondence(q, ref).map
        var out = q
        for i in 0..<4 { out[m[i]] = q[i] }
        return out
    }

    /// The box model's cut-face bands for each side of an image outline, given a pose (camera axes).
    static func predictBands(pose: SlabPose, outline q: [Vec2], intrinsics K: CameraIntrinsics, spec: SlabSpec) -> [Band] {
        let hidden = [Band](repeating: Band(visible: false, start: 0, end: 0), count: 4)
        let box = SlabBoxView(pose: pose, spec: spec, intrinsics: K)
        let t2 = box.topCorners.compactMap { K.project($0) }, b2 = box.bottomCorners.compactMap { K.project($0) }
        guard t2.count == 4, b2.count == 4 else { return hidden }
        // which projected box corner each outline corner is
        let m = bestCorrespondence(q, t2).map
        let c = centroid(t2)
        return (0..<4).map { i -> Band in
            let a = m[i], b = m[(i + 1) % 4]
            let boxSide = b == (a + 1) % 4 ? a : b
            let A = t2[a], B = t2[b]
            var n = (B - A).normalized.perpendicular
            if n.dot((A + B) / 2 - c) < 0 { n = -n }
            let s = (b2[a] - A).dot(n), e = (b2[b] - B).dot(n)
            let vis = box.cutFaceVisible(side: boxSide) && min(s, e) > 0
            return Band(visible: vis, start: max(0, s), end: max(0, e))
        }
    }

    /// Least-squares line through points, refitted twice without the points far from it (the web app's rule).
    static func robustLine(_ pts: [Vec2], unit: Double, minPoints: Int) -> (line: Line2, inliers: Int)? {
        guard pts.count >= minPoints else { return nil }
        var use = pts
        var line = fitLine(use)
        for _ in 0..<3 {
            let res = pts.map { abs(line.distance($0)) }
            let med = res.sorted()[res.count / 2], lim = max(0.75 * unit, 2.5 * med)
            let keep = zip(pts, res).filter { $0.1 <= lim }.map { $0.0 }
            if keep.count < max(minPoints, 8) || keep.count == use.count { break }
            use = keep
            line = fitLine(use)
        }
        return (line, use.count)
    }

    static func fitLine(_ pts: [Vec2]) -> Line2 {
        let m = centroid(pts)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts { let a = p.x - m.x, b = p.y - m.y; sxx += a * a; sxy += a * b; syy += b * b }
        let th = 0.5 * atan2(2 * sxy, sxx - syy)
        return Line2(p: m, d: Vec2(cos(th), sin(th)))
    }
}

/// Luma profiles across one side of an outline: `count` readings spread along the side, each a row of gradient values
/// along the side's outward normal. Each value is the luma step across 2 x 1.5 `unit` (outer minus inner), averaged
/// over a short run along the side so texture and noise don't register as edges.
struct SpokeProfiles {
    let n: Int                // readings along the side
    let m: Int                // gradient values per reading
    let o0: Double            // offset (along the outward normal) of value 0
    let step: Double
    let normal: Vec2
    let dir: Vec2
    var base: [Vec2]          // each reading's point on the given side
    var t: [Double]           // its position along the side (0 at the side's first corner, 1 at its second)
    var g: [Float]            // n * m
    let mL: Int               // luma values per reading
    let l0: Double            // offset of luma value 0
    var lum: [Float]          // n * mL: the luma profiles the gradients come from

    init(luma: Plane, a: Vec2, b: Vec2, normal nrm: Vec2, inward: Double, outward: Double, unit: Double, count: Int) {
        let len = a.distance(to: b), d = (b - a) / max(len, 1e-9)
        let step = 0.5 * unit, hs = 3 // half-width of the step: 1.5 unit = 3 steps
        let mP = Int(((inward + outward) / step).rounded(.up)) + 1 + 2 * hs
        let m = mP - 2 * hs
        n = max(2, count); self.m = m; o0 = -inward; self.step = step; normal = nrm; dir = d
        mL = mP; l0 = -inward - Double(hs) * step
        base = []; t = []; base.reserveCapacity(n); t.reserveCapacity(n)
        g = [Float](repeating: 0, count: n * m)
        lum = [Float](repeating: 0, count: n * mP)
        let along: [Double] = [-4, -2, 0, 2, 4].map { $0 * unit }
        for j in 0..<n {
            let tj = 0.08 + 0.84 * Double(j) / Double(n - 1)
            let bj = a + d * (len * tj)
            base.append(bj); t.append(tj)
            let lrow = j * mP
            for k in 0..<mP {
                let o = l0 + Double(k) * step
                var s: Float = 0
                for u in along { s += luma.sample(bj.x + d.x * u + nrm.x * o, bj.y + d.y * u + nrm.y * o) }
                lum[lrow + k] = s / Float(along.count)
            }
            let row = j * m
            for k in 0..<m { g[row + k] = lum[lrow + k + 2 * hs] - lum[lrow + k] }
        }
    }

    /// value of reading j at offset o (linear between samples); nil outside the profile
    @inline(__always) func value(_ j: Int, _ o: Double) -> Double? {
        let f = (o - o0) / step
        guard f >= 0 else { return nil }
        let i = Int(f)
        guard i < m - 1 else { return nil }
        let a = Double(g[j * m + i]), b = Double(g[j * m + i + 1])
        return a + (b - a) * (f - Double(i))
    }

    enum EdgeRule {
        /// each reading's strongest step that gets darker outward
        case strongestDarkening
        /// each reading's strongest step that gets lighter outward
        case strongestBrightening
        /// each reading's first clear step from the inside, either way (the web app's refineQuad rule)
        case firstFromInside
    }

    /// One edge point per reading by `rule`, and a straight line through them ignoring strays.
    ///
    /// With `coherent`, the strongest-step rules first find the straight line along which the readings' summed step is
    /// largest (tilted by up to `maxTilt` across the side), then take on each reading the clear step nearest that line
    /// (within `window`). Without this, where two parallel edges are about equally strong (a cut face about halfway
    /// between the top's and the base's luma) each reading picks either, and the line fitted through both sets of points
    /// lands between the two edges.
    func edgeLine(_ rule: EdgeRule, unit: Double, minStep: Double = 0, coherent: (window: Double, maxTilt: Double)? = nil) -> (line: Line2, inliers: Int)? {
        var pts: [Vec2] = []
        pts.reserveCapacity(n)
        for (j, o) in edgeOffsets(rule, unit: unit, minStep: minStep, coherent: coherent).enumerated() {
            if let o = o { pts.append(base[j] + normal * o) }
        }
        guard let r = Geometry.robustLine(pts, unit: unit, minPoints: max(6, n / 3)) else { return nil }
        var l = r.line
        if l.d.dot(dir) < 0 { l.d = -l.d }
        return (l, r.inliers)
    }

    /// Each reading's edge point by `rule` (`edgeLine`), as its offset along the outward normal; nil where none was clear.
    func edgeOffsets(_ rule: EdgeRule, unit: Double, minStep: Double = 0, coherent: (window: Double, maxTilt: Double)? = nil) -> [Double?] {
        var out = [Double?](repeating: nil, count: n)
        var mags = [Float](repeating: 0, count: m), sc = [Float](repeating: 0, count: m)
        var lineK: [Double]? = nil
        if let coh = coherent, rule != .firstFromInside {
            let sgn: Float = rule == .strongestDarkening ? -1 : 1
            let tiltMax = Int((coh.maxTilt / step).rounded()), span = Double(max(1, n - 1)), st = 2
            var bestS: Float = 0, bestA = -1, bestD = 0
            for d in stride(from: -tiltMax, through: tiltMax, by: st) {
                for a in stride(from: 0, to: m, by: st) {
                    var s: Float = 0
                    for j in 0..<n {
                        let k = a + Int((Double(d) * Double(j) / span).rounded())
                        if k < 0 || k >= m { continue }
                        s += max(0, sgn * g[j * m + k])
                    }
                    if s > bestS { bestS = s; bestA = a; bestD = d }
                }
            }
            if bestA >= 0 { lineK = (0..<n).map { Double(bestA) + Double(bestD) * Double($0) / span } }
        }
        let win = coherent.map { $0.window / step } ?? 0
        for j in 0..<n {
            let row = j * m
            var gmax: Float = 0
            for k in 0..<m {
                let v = g[row + k]
                mags[k] = abs(v)
                switch rule {
                case .strongestDarkening: sc[k] = -v
                case .strongestBrightening: sc[k] = v
                case .firstFromInside: sc[k] = abs(v)
                }
                gmax = max(gmax, sc[k])
            }
            mags.sort()
            // an edge must stand clear of this reading's own background ripple (cement speckle, sensor noise). The web
            // app took the median as the ripple; in a window this tight two blurred edges can fill half of it, so the
            // lower quartile is used.
            let thr = max(0.25 * gmax, 2.5 * mags[m / 4] + 2, Float(minStep))
            guard gmax >= thr, gmax > 0 else { continue }
            var best = -1
            for k in 1..<(m - 1) where sc[k] >= thr && sc[k] >= sc[k - 1] && sc[k] >= sc[k + 1] {
                if case .firstFromInside = rule { best = k; break }
                if let lk = lineK {
                    // the clear step nearest the coherent line
                    let dk = abs(Double(k) - lk[j])
                    if dk <= win && (best < 0 || dk < abs(Double(best) - lk[j])) { best = k }
                } else if best < 0 || sc[k] > sc[best] { best = k }
            }
            guard best > 0 else { continue }
            let sl = Double(sc[best - 1]), s0 = Double(sc[best]), sr = Double(sc[best + 1])
            let den = sl - 2 * s0 + sr
            let off = den < 0 ? 0.5 * (sl - sr) / den : 0
            out[j] = o0 + (Double(best) + off) * step
        }
        return out
    }

    /// Luma near the line at `off` against the top face's: per reading, the darkest (or mean) luma at the `outside`
    /// offsets (the darkest, so a thin strip of black base before the floor still counts), averaged over the readings, as
    /// a share of the mean luma at the `inside` offsets.
    func lumaRatio(luma: Plane, offsets off: [Double], outside: [Double], inside: [Double], unit: Double, darkest: Bool = true) -> Double {
        guard !outside.isEmpty, !inside.isEmpty else { return 1 }
        return lumaLevel(luma: luma, offsets: off, at: outside, unit: unit, darkest: darkest) / max(lumaLevel(luma: luma, offsets: off, at: inside, unit: unit), 1)
    }

    /// Per reading, the darkest (or mean) luma at offsets `at` from the line at `off` (each averaged over a short run
    /// along the side), averaged over the readings.
    func lumaLevel(luma: Plane, offsets off: [Double], at: [Double], unit: Double, darkest: Bool = false) -> Double {
        guard !at.isEmpty else { return 0 }
        let along: [Double] = [-2, 0, 2].map { $0 * unit }
        var tot = 0.0
        for j in 0..<n {
            var lo = Double.infinity, sum = 0.0
            for o in at {
                var s = 0.0
                for u in along { s += Double(luma.sample(base[j] + dir * u + normal * (off[j] + o))) }
                s /= Double(along.count)
                lo = min(lo, s); sum += s
            }
            tot += darkest ? lo : sum / Double(at.count)
        }
        return tot / Double(n)
    }

    /// Where the top face's level ends between offsets `lo` and `hi` from the line at `off`: one change from an inner level
    /// to an outer one, at the same offset from the line on every reading (each reading keeps its own two levels), placed
    /// where the readings' squared misfit is least. Returns that offset, the mean step (outer minus inner level) and its
    /// standard error across the readings; nil if the best place is at either end of the range.
    func changePoint(offsets off: [Double], from lo: Double, to hi: Double, minInner: Double, minOuter: Double) -> (offset: Double, contrast: Double, se: Double)? {
        guard hi - lo > minInner + minOuter + 2 * step else { return nil }
        // each reading's luma (the profile's own samples) over [lo, hi] from the line, by linear interpolation
        let cnt = Int(((hi - lo) / step).rounded(.down)) + 1
        var v = [Double](repeating: 0, count: n * cnt)
        var ok = [Bool](repeating: true, count: n)
        for j in 0..<n {
            for k in 0..<cnt {
                guard let x = lumaValue(j, off[j] + lo + Double(k) * step) else { ok[j] = false; break }
                v[j * cnt + k] = x
            }
        }
        let use = (0..<n).filter { ok[$0] }
        guard use.count >= max(8, n / 2) else { return nil }
        let kIn = max(2, Int((minInner / step).rounded(.up))), kOut = max(2, Int((minOuter / step).rounded(.up)))
        guard cnt - kIn - kOut > 3 else { return nil }
        var bestK = -1, bestSSE = Double.infinity
        var pre = [Double](repeating: 0, count: cnt + 1), pre2 = pre
        var sse = [Double](repeating: 0, count: cnt)
        for j in use {
            for k in 0..<cnt { let x = v[j * cnt + k]; pre[k + 1] = pre[k] + x; pre2[k + 1] = pre2[k] + x * x }
            for k in kIn...(cnt - kOut) {
                let nl = Double(k), nr = Double(cnt - k)
                let sl = pre[k], sr = pre[cnt] - pre[k]
                sse[k] += (pre2[k] - sl * sl / nl) + (pre2[cnt] - pre2[k] - sr * sr / nr)
            }
        }
        for k in kIn...(cnt - kOut) where sse[k] < bestSSE { bestSSE = sse[k]; bestK = k }
        // at either end of the range searched, the change was not found inside it
        guard bestK > kIn, bestK < cnt - kOut else { return nil }
        var ds: [Double] = []
        for j in use {
            var a = 0.0, b = 0.0
            for k in 0..<bestK { a += v[j * cnt + k] }
            for k in bestK..<cnt { b += v[j * cnt + k] }
            ds.append(b / Double(cnt - bestK) - a / Double(bestK))
        }
        let mu = ds.reduce(0, +) / Double(ds.count)
        let sd = (ds.map { ($0 - mu) * ($0 - mu) }.reduce(0, +) / Double(ds.count)).squareRoot()
        // the change lies between samples bestK - 1 and bestK
        return (lo + (Double(bestK) - 0.5) * step, mu, sd / Double(ds.count).squareRoot())
    }

    /// luma of reading j at offset o (linear between samples); nil outside the profile
    @inline(__always) func lumaValue(_ j: Int, _ o: Double) -> Double? {
        let f = (o - l0) / step
        guard f >= 0 else { return nil }
        let i = Int(f)
        guard i < mL - 1 else { return nil }
        let a = Double(lum[j * mL + i]), b = Double(lum[j * mL + i + 1])
        return a + (b - a) * (f - Double(i))
    }

    /// Each reading's offset (along the outward normal) to a line.
    func offsets(of l: Line2) -> [Double] {
        let den = normal.cross(l.d)
        return base.map { b -> Double in abs(den) < 1e-9 ? 0 : (l.p - b).cross(l.d) / den }
    }

    /// mean value at the given offsets
    func mean(at off: [Double]) -> Double? {
        var s = 0.0, c = 0
        for j in 0..<n { if let v = value(j, off[j]) { s += v; c += 1 } }
        return c > 0 ? s / Double(c) : nil
    }

    /// Is there an edge parallel to the line at `off`, `direction` x (0.5-1.7) x the band away (inside: -1, outside: +1)?
    /// With `sign`, only steps that way count (-1: darker outward).
    /// Every reading's value is averaged along each candidate line, so even a faint step stands out; it counts only if it
    /// is a real peak inside the range searched (not the fading flank of the main edge), clearly above the readings'
    /// scatter, and steps by at least `minContrast`.
    func partner(offsets off: [Double], band: (Double, Double), direction: Double, scales: ClosedRange<Double>,
                 minSeparation: Double, minContrast: Double, noiseFactor: Double, sign: Double? = nil) -> Partner? {
        let bmin = min(band.0, band.1)
        guard bmin > 0 else { return nil }
        var scs: [Double] = [], stats: [(mu: Double, se: Double)] = [], ss: [Double] = [], valid: [Bool] = []
        var s = scales.lowerBound
        while s <= scales.upperBound + 1e-9 {
            var sum = 0.0, sq = 0.0, c = 0
            for j in 0..<n {
                let w = band.0 + (band.1 - band.0) * t[j]
                if let v = value(j, off[j] + direction * s * w) { sum += v; sq += v * v; c += 1 }
            }
            var sc = 0.0, mu = 0.0, se = 0.0
            // too close to the main edge to tell apart from its flank, or too few readings: not a place to look
            let ok = c >= max(8, n / 2) && s * bmin >= minSeparation
            if ok {
                mu = sum / Double(c); se = (max(0, sq / Double(c) - mu * mu) / Double(c)).squareRoot()
                sc = sign.map { max(0, $0 * mu) } ?? abs(mu)
            }
            scs.append(sc); stats.append((mu, se)); ss.append(s); valid.append(ok)
            s += 0.05
        }
        var bi = -1, bv = 0.0
        for i in 0..<scs.count where valid[i] && scs[i] > bv { bv = scs[i]; bi = i }
        // a real peak with a lower place to look on both sides of it
        guard bi > 0, bi < scs.count - 1, valid[bi - 1], valid[bi + 1], scs[bi - 1] < bv, scs[bi + 1] < bv else { return nil }
        guard bv >= max(minContrast, noiseFactor * stats[bi].se) else { return nil }
        return Partner(scale: ss[bi], mu: stats[bi].mu, se: stats[bi].se)
    }

    /// The line at `off` moved inward by k x the band (which varies linearly along the side).
    func shifted(offsets off: [Double], by k: Double, band: (Double, Double)) -> Line2 {
        let j0 = 0, j1 = n - 1
        let w0 = band.0 + (band.1 - band.0) * t[j0], w1 = band.0 + (band.1 - band.0) * t[j1]
        let p0 = base[j0] + normal * (off[j0] - k * w0), p1 = base[j1] + normal * (off[j1] - k * w1)
        return Line2(p: p0, d: (p1 - p0).normalized)
    }
}
