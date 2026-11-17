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
    /// the cut face shows but is not lit: nothing black lies just outside the strong edge (the cut face is in shadow, or
    /// the slab overhangs the floor where it rocks in its cradle), so the strong edge is already the top face's own
    case outerIsTop
    /// too few edge points along the side: its line was kept as given
    case unfitted
}

/// What the edge refiner did on one side of the outline.
public struct SideEdge: Equatable {
    public var mode: EdgeMode
    /// the cut face's band as the box model predicts it: frame pixels, perpendicular to the side, mean of its two ends
    /// (0 when the cut face is hidden)
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

    public init(mode: EdgeMode, bandPixels: Double, contrast: Double, outerContrast: Double, innerContrast: Double, shift: Double,
                points: Int, outsideRatio: Double) {
        self.mode = mode; self.bandPixels = bandPixels; self.contrast = contrast; self.outerContrast = outerContrast
        self.innerContrast = innerContrast; self.shift = shift; self.points = points; self.outsideRatio = outsideRatio
    }
}

/// The edge refiner's memory between calls: which edge each side rests on, so a side does not flip between the top face's
/// edge and the bottom of its cut face on noise. The caller passes the last result's `choice` back in on the next call.
public struct EdgeChoice: Equatable, Codable {
    public struct Side: Equatable, Codable {
        public var mode: EdgeMode
        /// a different mode seen on the last `pendingCount` calls in a row; it takes over once seen often enough
        public var pending: EdgeMode?
        public var pendingCount: Int
        /// the visible share of the predicted band, learned from the inner edges seen (1 until one is seen)
        public var bandScale: Double
        /// how many times the inner edge has been seen
        public var sightings: Int
        public init(mode: EdgeMode, pending: EdgeMode? = nil, pendingCount: Int = 0, bandScale: Double = 1, sightings: Int = 0) {
            self.mode = mode; self.pending = pending; self.pendingCount = pendingCount; self.bandScale = bandScale; self.sightings = sightings
        }
    }
    /// per side of `outline` (side i runs from corner i to corner i+1)
    public var sides: [Side]
    /// the outline (frame pixels) the sides belong to; a new outline is matched to it corner by corner
    public var outline: [Vec2]
    /// the slab normal last solved (camera axes), for the pose solver's mirror-image hysteresis
    public var normal: Vec3?

    public init(sides: [Side], outline: [Vec2], normal: Vec3?) { self.sides = sides; self.outline = outline; self.normal = normal }

    /// The sides re-indexed to another outline of the same slab (matched corner to corner, either way round); nil when the
    /// outlines are too far apart to be the same sides.
    func sides(matching q: [Vec2]) -> [Side]? {
        guard sides.count == 4, outline.count == 4, q.count == 4 else { return nil }
        let m = Geometry.bestCorrespondence(q, outline)
        guard m.meanDistance < 0.75 * ShapeCheck.meanSide(q) else { return nil }
        return (0..<4).map { i -> Side in
            let a = m.map[i], b = m.map[(i + 1) % 4]
            return sides[b == (a + 1) % 4 ? a : b]
        }
    }
}

/// Finds the top face's edge on every side of a slab outline, using the slab as a box with thickness.
///
/// On a side whose cut face the camera can see, the image shows two parallel edges: the top face meeting the light cut
/// face, and (usually the stronger) the cut face meeting the black base. A plain edge search lands on either, from one
/// frame to the next, which made the near edge flip on the real phone. Here the pose is solved from the outline, the box
/// model predicts for each side whether its cut face shows and how wide its band is in pixels, and the gradient profiles
/// across each side are searched for the outer edge (the strongest step from light inside to dark outside) and for a
/// partner edge about one band-width inside it. The output is always the top edge: the inner partner when it is found
/// with enough contrast, otherwise the outer edge moved inward by the predicted band. That holds only where the black base
/// lies just outside the outer edge; where it does not (the cut face in shadow, or overhanging the floor as the slab rocks
/// in its cradle), the strong edge is the top face's own and is kept. Sides whose cut face is hidden are silhouettes: the
/// first clear edge from the inside is the top edge (beyond it there may be a sliver of black base and then the floor).
/// Pose -> bands -> edges is iterated, and each side's choice is kept with hysteresis across calls (`EdgeChoice`).
public struct EdgeRefiner {
    public struct Options {
        /// edge readings per side
        public var spokes = 32
        /// rounds of pose -> bands -> edges
        public var iterations = 2
        /// a cut face whose band is thinner than this (frame pixels) is treated as hidden
        public var minBandPixels = 1.0
        /// the outer edge sits on the black base when the luma just outside it is below this share of the top face's
        public var darkRatio = 0.4
        /// a reading's outer edge on a side whose cut face shows must step by at least this much (grey levels)
        public var minEdgeStep = 6.0
        /// the band just inside the outer edge is a cut face in shadow when its luma is below this share of the top face's
        public var shadowedBandRatio = 0.85
        /// where the inner partner edge is looked for, as a share of the predicted band
        public var partnerScales: ClosedRange<Double> = 0.5...1.7
        /// a partner edge must step by at least this much (grey levels, averaged along the side) ...
        public var minPartnerContrast = 3.0
        /// ... and stand this many standard errors clear of the side's scatter ...
        public var partnerNoiseFactor = 4.0
        /// ... and be at least this share of the outer edge's step
        public var innerContrastRatio = 0.08
        /// a side changes mode only after the new one has been seen on this many calls in a row
        public var switchAfter = 3
        /// how fast the visible share of the band is learned from inner edges seen, and its limits
        public var bandScaleRate = 0.25
        public var bandScaleRange: ClosedRange<Double> = 0.6...1.4
        public var pose = PoseSolver.Options()
        public init() {}
    }

    public struct Result: Equatable {
        /// the refined top-face outline (frame pixels, same corner order as the input)
        public var outline: [Vec2]
        /// the pose solved from it (frame intrinsics)
        public var fit: PoseFit
        /// per side (side i runs from corner i to corner i+1)
        public var sides: [SideEdge]
        /// pass this back in on the next call
        public var choice: EdgeChoice
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

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
    ///   - down: gravity in camera axes (for the pose's level prior), if known
    ///   - choice: the last call's `choice`, if this is the same slab
    public func refine(outline: [Vec2], intrinsics K: CameraIntrinsics, luma: Plane, lumaIntrinsics KDIn: CameraIntrinsics? = nil,
                       spec: SlabSpec, down: Vec3?, choice: EdgeChoice? = nil) -> Result? {
        guard outline.count == 4, ShapeCheck.isConvex(outline) else { return nil }
        let KD = KDIn ?? K
        let map = ImageMap(from: K, to: KD)
        let ds = map.scale, unit = max(0.5, ds / 2)
        let prevSides = choice?.sides(matching: outline)
        var cur = outline.map(map.forward)
        var sides: [SideEdge] = []
        var states: [EdgeChoice.Side] = []
        let h = 1.5 * unit
        for _ in 0..<max(1, options.iterations) {
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
                // the outer edge: on a side whose cut face shows, the strongest step from light (inside) to dark (outside),
                // or failing that (a floor lighter than the cut face beyond it) the strongest step to light; on a
                // silhouette, the first clear step from the inside, either way
                var outer: (line: Line2, inliers: Int)? = nil
                var darkening = false
                if visible {
                    outer = sp.edgeLine(.strongestDarkening, unit: unit, minStep: options.minEdgeStep)
                    darkening = outer != nil
                    if outer == nil { outer = sp.edgeLine(.strongestBrightening, unit: unit, minStep: options.minEdgeStep) }
                } else {
                    outer = sp.edgeLine(.firstFromInside, unit: unit)
                }
                guard let outer = outer else {
                    lines.append(Line2(p: A, d: dir))
                    let st = Self.update(prev, raw: .unfitted, partnerScale: nil, options: options)
                    states.append(st)
                    sides.append(SideEdge(mode: .unfitted, bandPixels: meanBandFrame, contrast: 0, outerContrast: 0, innerContrast: 0,
                                          shift: 0, points: 0, outsideRatio: 0))
                    continue
                }
                let offL = sp.offsets(of: outer.line)
                let muL = sp.mean(at: offL) ?? 0
                var raw: EdgeMode = .silhouette
                var inner: Partner? = nil
                var ratio = 0.0
                if visible {
                    // what lies right outside the outer edge (its darkest luma within ~2 px, against the top face's beyond
                    // where the band could reach): black (the base) or lighter than the top (a lit floor), the outer edge is
                    // the cut face's bottom; darker than the top but not black, it is a cut face in shadow, and the strong
                    // edge is the top face's own
                    ratio = sp.lumaRatio(luma: luma, offsets: offL, outside: [0.75 * ds, 1.25 * ds, 1.75 * ds, 2.25 * ds],
                                         inside: [-1.6 * bmax - 2 * ds, -1.6 * bmax - 3 * ds], unit: unit)
                    // the band just inside the outer edge, against the top face: clearly darker means the cut face is in
                    // shadow and fades into the black base, so the strong edge lies within it; the top edge is then where
                    // the top face's own level ends
                    let bandRatio = sp.lumaRatio(luma: luma, offsets: offL, outside: [-0.75 * bmax, -0.5 * bmax, -0.25 * bmax].filter { $0 < -0.5 * ds },
                                                 inside: [-1.6 * bmax - 2 * ds, -1.6 * bmax - 3 * ds], unit: unit, darkest: false)
                    if darkening && ratio >= options.darkRatio {
                        raw = .outerIsTop
                    } else {
                        let bandMid = max((b0 + b1) / 2, 1e-9)
                        if darkening && bandRatio < options.shadowedBandRatio,
                           let cp = sp.changePoint(offsets: offL, from: -1.7 * bmax - 2 * ds, to: 0, minInner: 2 * h, minOuter: 0.5 * ds),
                           cp.contrast < 0, abs(cp.contrast) >= max(options.minPartnerContrast, options.partnerNoiseFactor * cp.se),
                           -cp.offset / bandMid >= options.partnerScales.lowerBound - 0.2, -cp.offset / bandMid <= options.partnerScales.upperBound {
                            inner = Partner(scale: -cp.offset / bandMid, mu: cp.contrast, se: cp.se)
                        } else {
                            inner = sp.partner(offsets: offL, band: (b0, b1), direction: -1, scales: options.partnerScales, minSeparation: 2 * h,
                                               minContrast: max(options.minPartnerContrast, options.innerContrastRatio * abs(muL)),
                                               noiseFactor: options.partnerNoiseFactor)
                        }
                        raw = inner != nil ? .innerEdge : .shiftedOuter
                    }
                }
                let st = Self.update(prev, raw: raw, partnerScale: inner?.scale, options: options)
                states.append(st)
                // the output: always the top edge
                var k = 0.0
                switch st.mode {
                case .innerEdge: k = inner?.scale ?? st.bandScale
                case .shiftedOuter: k = st.bandScale
                default: k = 0
                }
                if !visible { k = 0 }
                let line = k == 0 ? outer.line : sp.shifted(offsets: offL, by: k, band: (b0, b1))
                lines.append(line)
                let usedInner = st.mode == .innerEdge && inner != nil
                sides.append(SideEdge(mode: visible ? st.mode : .silhouette, bandPixels: visible ? meanBandFrame : 0,
                                      contrast: usedInner ? abs(inner!.mu) : abs(muL), outerContrast: muL, innerContrast: inner?.mu ?? 0,
                                      shift: k, points: outer.inliers, outsideRatio: ratio))
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
            cur = next
        }
        let out = cur.map(map.inverse)
        guard let fit = PoseSolver.solve(corners: out, intrinsics: K, spec: spec, down: down, previousNormal: choice?.normal, options: options.pose) else { return nil }
        let newChoice = EdgeChoice(sides: states, outline: out, normal: fit.pose.normal)
        return Result(outline: out, fit: fit, sides: sides, choice: newChoice)
    }

    /// One side's memory after this call's observation: a new mode takes over only once seen `switchAfter` times in a row.
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
    func edgeLine(_ rule: EdgeRule, unit: Double, minStep: Double = 0) -> (line: Line2, inliers: Int)? {
        var pts: [Vec2] = []
        pts.reserveCapacity(n)
        var mags = [Float](repeating: 0, count: m), sc = [Float](repeating: 0, count: m)
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
                if best < 0 || sc[k] > sc[best] { best = k }
            }
            guard best > 0 else { continue }
            let sl = Double(sc[best - 1]), s0 = Double(sc[best]), sr = Double(sc[best + 1])
            let den = sl - 2 * s0 + sr
            let off = den < 0 ? 0.5 * (sl - sr) / den : 0
            pts.append(base[j] + normal * (o0 + (Double(best) + off) * step))
        }
        guard let r = Geometry.robustLine(pts, unit: unit, minPoints: max(6, n / 3)) else { return nil }
        var l = r.line
        if l.d.dot(dir) < 0 { l.d = -l.d }
        return (l, r.inliers)
    }

    /// Luma near the line at `off` against the top face's: per reading, the darkest (or mean) luma at the `outside`
    /// offsets (the darkest, so a thin strip of black base before the floor still counts), averaged over the readings, as
    /// a share of the mean luma at the `inside` offsets.
    func lumaRatio(luma: Plane, offsets off: [Double], outside: [Double], inside: [Double], unit: Double, darkest: Bool = true) -> Double {
        guard !outside.isEmpty, !inside.isEmpty else { return 1 }
        let along: [Double] = [-2, 0, 2].map { $0 * unit }
        func at(_ j: Int, _ o: Double) -> Double {
            var s = 0.0
            for u in along { s += Double(luma.sample(base[j] + dir * u + normal * (off[j] + o))) }
            return s / Double(along.count)
        }
        var out = 0.0, ins = 0.0
        for j in 0..<n {
            let vs = outside.map { at(j, $0) }
            out += darkest ? vs.min()! : vs.reduce(0, +) / Double(vs.count)
            ins += inside.map { at(j, $0) }.reduce(0, +) / Double(inside.count)
        }
        return out / max(ins, 1)
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
    /// Every reading's value is averaged along each candidate line, so even a faint step stands out; it counts only if it
    /// is a real peak inside the range searched (not the fading flank of the main edge), clearly above the readings'
    /// scatter, and steps by at least `minContrast`.
    func partner(offsets off: [Double], band: (Double, Double), direction: Double, scales: ClosedRange<Double>,
                 minSeparation: Double, minContrast: Double, noiseFactor: Double) -> Partner? {
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
                sc = abs(mu)
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
