import Foundation

/// A finer luma image of the same camera view for the edge steps (e.g. the camera's full-resolution luma plane, or a crop
/// of it around the slab); its intrinsics say how its pixels map to the camera.
public struct DetailImage {
    public var luma: Plane
    public var intrinsics: CameraIntrinsics
    public init(luma: Plane, intrinsics: CameraIntrinsics) { self.luma = luma; self.intrinsics = intrinsics }
}

/// One outline the slab finder found and checked.
public struct SlabCandidate: Equatable {
    public enum Source: String, Codable { case tapped, tracked, region, sweep }
    /// the top face's corners (pixels of the frame searched), in outline order
    public var quad: [Vec2]
    /// the outline before the box model's top-edge step (what the web app found: on sides whose cut face shows, often
    /// the bottom of the cut face)
    public var plainQuad: [Vec2]
    /// the pose solved from `quad` with the real lens and gravity
    public var fit: PoseFit
    /// the weakest side's edge step (grey levels): higher is clearer
    public var score: Double
    /// area of `quad` (square pixels)
    public var area: Double
    /// share of the strip just outside the outline that is dark like the slab's black base (best side)
    public var baseFraction: Double
    /// what the edge refiner did on each side (empty when the box model is off)
    public var sides: [SideEdge]
    /// pass to the next `find` call (with `near`, the slab moved by the camera's motion) so each side's top line stays on
    /// the same physical edge
    public var choice: EdgeChoice?
    public var source: Source
    /// colour match tolerance and reference (luma, Cb, Cr, texture) of the region it grew from (0 / empty when tracked)
    public var tolerance: Double
    public var reference: [Double]
}

/// Finds the slab: a smooth patch of one colour on a black base, whose outline is a square of the slab's size seen
/// through the real lens. Ported from the web app (web/index.html: ensureProc, detectAt, detectSeed, detect, sweep,
/// baseFrac, refineQuad), with these changes: the lens is known (no lens-angle guessing; PoseSolver and ShapeCheck judge
/// whether an outline could be the slab); nothing assumes which way up the image is (every image step is symmetric under
/// rotation, and "down" enters only in camera axes: the pose's level prior and tilt limit, from which the box model
/// predicts which cut faces show; the black base is looked for beside every side, since the slab slides in its cradle);
/// and the outline's sides are moved to the top face's edges by the box model (`EdgeRefiner`) instead of resting on
/// whichever of the two cut-face edges is clearer.
///
/// The frame should be at the web detector's processing size (about 480 pixels on its long side, e.g. ARKit's 1920x1440
/// image divided by 4): the colour and region steps use the web app's pixel and grey-level constants.
public struct SlabFinder {
    public struct Options {
        /// colour match looseness (the web app's "tol") and the ladder of multiples tried
        public var tolerance: Double = 26
        public var toleranceLadder: [Double] = [0.5, 0.7, 1, 1.45]
        /// "dark like the base": luma below this share of the slab's
        public var darkFraction: Double = 0.5
        /// unprompted finds must be smooth (texture / luma below this) and sit on the black base
        public var maxTexture: Double = 0.075
        public var minBaseFraction: Double = 0.07
        /// unprompted finds: the weakest side's snap edge must step by more than this (grey levels)
        public var minSideEdge: Double = 6
        /// unprompted finds need the black base (off: any smooth plausible square counts)
        public var requireBase: Bool = true
        /// the sweep's grid of starting points (pixels) and how many regions it may grow per call
        public var sweepStep: Int = 16
        public var maxSweepRegions: Int = 48
        /// move the sides to the top face's edges with the box model (off: the web app's plain outline)
        public var useBoxModel: Bool = true
        /// what an outline must satisfy to be the slab. With the box model the corners fit the slab's square within 1.5%
        /// of its side (measured on the fixtures' slab finds: at most 0.8%; the web app allowed 1% with its guessed lens);
        /// the plain outline (`useBoxModel` off), which rests on the cut face's bottom on some sides, within 2% (measured:
        /// up to 1.5%; a sheet of paper beside the clutter fixture's box fits within 2.4%)
        public var limits: ShapeCheck.Limits = {
            var l = ShapeCheck.Limits(); l.maxMisfitFraction = 0.015; return l
        }()
        public var plainLimits: ShapeCheck.Limits = {
            var l = ShapeCheck.Limits(); l.maxMisfitFraction = 0.02; return l
        }()
        /// the web app's shape test, with the real lens: the outline seen square-on (through the homography to the slab's
        /// plane) must have sides in the slab's proportion within this |log ratio| and corners square within this |cos|
        public var maxAspectLog: Double = 0.3
        public var maxSkewCos: Double = 0.25
        public var edges = EdgeRefiner.Options()
        public init() {}
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    /// Find the slab in a frame.
    /// - Parameters:
    ///   - frame: colour frame (luma and colour differences) at processing size
    ///   - intrinsics: the frame's intrinsics (ARKit's, scaled to the frame)
    ///   - down: gravity in camera axes (the pose's level prior and tilt limit, and so which cut faces show). Pass it
    ///     whenever it is known (ARKit gives it every frame): without it the pose can come out as its mirror image, which
    ///     puts the cut faces' bands on the wrong sides
    ///   - seed: a tapped point (frame pixels): grow the slab from there, base not required
    ///   - near: an outline predicted by tracking (frame pixels): follow its edges, and grow a region from its middle,
    ///     instead of searching the whole view
    ///   - detail: a finer luma image of the same view for the edge steps (the frame's own luma if nil)
    ///   - choice: the edge choice from the last call's best candidate (same slab), for per-side hysteresis; with `near`,
    ///     its top edges are expected where `near` puts them (so `near` should be the last outline moved by the camera's
    ///     motion); without, where they were last time
    /// - Returns: outlines that passed every check, best first: with `seed` the best colour tolerance; with `near` the
    ///   edge-tracked outline, then the colour region; otherwise the sweep's finds, largest first.
    public func find(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2? = nil,
                     near: [Vec2]? = nil, detail: DetailImage? = nil, choice: EdgeChoice? = nil) -> [SlabCandidate] {
        guard frame.width >= 16, frame.height >= 16 else { return [] }
        // the edge memory expects each side's top edge where the predicted outline puts it
        var ch = choice
        if let c = choice, let q = near, q.count == 4 { ch = c.moved(to: q) ?? c }
        let run = FinderRun(options: options, frame: frame, intrinsics: intrinsics, spec: spec, down: down, detail: detail, choice: ch)
        if let s = seed { return run.tapped(s) }
        if let q = near, q.count == 4 { return run.tracked(q) }
        return run.sweep()
    }
}

/// One `find` call: the processing planes and scratch buffers (allocated once per call, reused by every region grown).
final class FinderRun {
    let opt: SlabFinder.Options
    let w: Int, h: Int, n: Int
    let K: CameraIntrinsics
    let spec: SlabSpec
    let down: Vec3?
    let choice: EdgeChoice?
    let yRaw: Plane
    /// the finer image for the edge steps, if any, and the map from the frame's pixels to its pixels
    let detail: DetailImage?
    let detailMap: ImageMap?
    /// the frame's own pixels (for outlines the finer image does not cover)
    let frameMap: ImageMap
    let refiner: EdgeRefiner
    // processing planes (the web app's ensureProc): blurred luma and colour differences, texture
    let Y: UnsafeMutableBufferPointer<Float>
    let Cb: UnsafeMutableBufferPointer<Float>
    let Cr: UnsafeMutableBufferPointer<Float>
    let Tx: UnsafeMutableBufferPointer<Float>
    // scratch
    let cdist: UnsafeMutableBufferPointer<Float> // squared colour distance to the current reference
    let dist: UnsafeMutableBufferPointer<UInt16>
    let visit: UnsafeMutableBufferPointer<UInt32>
    /// which grown region (1-based index into `markRefs`) covers each pixel, 0 if none (the sweep's record)
    let mark: UnsafeMutableBufferPointer<UInt16>
    var markRefs: [[Float]] = [[]]
    /// references whose region covered most of the view even at the tightest match
    var background: [[Float]] = []
    let stack: UnsafeMutableBufferPointer<Int32>
    let rmin: UnsafeMutableBufferPointer<Int32>, rmax: UnsafeMutableBufferPointer<Int32>
    let cmin: UnsafeMutableBufferPointer<Int32>, cmax: UnsafeMutableBufferPointer<Int32>
    var gen: UInt32 = 0
    /// work done (for tests and tuning): regions grown from a start point, colour regions tried, outlines refined
    var seedsGrown = 0, regionsTried = 0, regionsKept = 0, refined = 0
    /// why each colour region was or was not kept (for tests and tuning)
    var trace: ((String) -> Void)? = nil

    init(options: SlabFinder.Options, frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, detail: DetailImage?, choice: EdgeChoice?) {
        opt = options; w = frame.width; h = frame.height; n = w * h
        K = intrinsics; self.spec = spec; self.down = down; self.choice = choice
        yRaw = frame.y
        self.detail = detail
        detailMap = detail.map { ImageMap(from: intrinsics, to: $0.intrinsics) }
        frameMap = ImageMap(from: intrinsics, to: intrinsics)
        refiner = EdgeRefiner(options: options.edges)
        func buf<T>(_ count: Int, _ v: T) -> UnsafeMutableBufferPointer<T> {
            let b = UnsafeMutableBufferPointer<T>.allocate(capacity: count); b.initialize(repeating: v); return b
        }
        // (buffers that are always written before they are read are left unfilled)
        func raw<T>(_ count: Int) -> UnsafeMutableBufferPointer<T> { .allocate(capacity: count) }
        Y = raw(n); Cb = raw(n); Cr = raw(n); Tx = raw(n)
        cdist = raw(n); dist = raw(n); stack = raw(n); visit = buf(n, 0); mark = buf(n, 0)
        rmin = buf(h, 0); rmax = buf(h, 0); cmin = buf(w, 0); cmax = buf(w, 0)
        // the same as Plane.blurred3() and Plane.localStdDev(radius: 3), written for speed (this runs on every frame)
        let tmp: UnsafeMutableBufferPointer<Float> = raw(n)
        defer { tmp.deallocate() }
        FinderRun.boxBlur3(frame.y.data, into: Y, tmp: tmp, w: w, h: h)
        FinderRun.boxBlur3(frame.cb.data, into: Cb, tmp: tmp, w: w, h: h)
        FinderRun.boxBlur3(frame.cr.data, into: Cr, tmp: tmp, w: w, h: h)
        // texture: local standard deviation of luma, so smooth cement separates from busy surroundings of the same colour
        FinderRun.localStd7(frame.y.data, into: Tx, w: w, h: h)
    }

    deinit {
        for b in [Y, Cb, Cr, Tx, cdist] { b.deallocate() }
        dist.deallocate(); visit.deallocate(); mark.deallocate(); stack.deallocate()
        rmin.deallocate(); rmax.deallocate(); cmin.deallocate(); cmax.deallocate()
    }

    /// 3x3 box blur; edge pixels average what is inside the image (as Plane.blurred3)
    static func boxBlur3(_ src: [Float], into out: UnsafeMutableBufferPointer<Float>, tmp: UnsafeMutableBufferPointer<Float>, w: Int, h: Int) {
        src.withUnsafeBufferPointer { s in
            // horizontal sums of 3 (2 at the ends), then vertical sums of those, divided by the number of pixels summed
            for y in 0..<h {
                let r = y * w
                for x in 0..<w {
                    var v = s[r + x]
                    if x > 0 { v += s[r + x - 1] }
                    if x < w - 1 { v += s[r + x + 1] }
                    tmp[r + x] = v
                }
            }
            for y in 0..<h {
                let r = y * w, cy: Float = (y > 0 ? 1 : 0) + 1 + (y < h - 1 ? 1 : 0)
                for x in 0..<w {
                    var v = tmp[r + x]
                    if y > 0 { v += tmp[r + x - w] }
                    if y < h - 1 { v += tmp[r + x + w] }
                    let cx: Float = (x > 0 ? 1 : 0) + 1 + (x < w - 1 ? 1 : 0)
                    out[r + x] = v / (cx * cy)
                }
            }
        }
    }

    /// local standard deviation in a 7x7 window clipped to the image, via integral images (as Plane.localStdDev(radius: 3))
    static func localStd7(_ src: [Float], into out: UnsafeMutableBufferPointer<Float>, w: Int, h: Int) {
        let r = 3, W1 = w + 1
        let i1 = UnsafeMutableBufferPointer<Double>.allocate(capacity: W1 * (h + 1)), i2 = UnsafeMutableBufferPointer<Double>.allocate(capacity: W1 * (h + 1))
        defer { i1.deallocate(); i2.deallocate() }
        // only the first row and column are read before being written
        for x in 0..<W1 { i1[x] = 0; i2[x] = 0 }
        for y in 1...h { i1[y * W1] = 0; i2[y * W1] = 0 }
        src.withUnsafeBufferPointer { s in
            for y in 0..<h {
                var r1 = 0.0, r2 = 0.0
                for x in 0..<w {
                    let v = Double(s[y * w + x]); r1 += v; r2 += v * v
                    let j = (y + 1) * W1 + x + 1
                    i1[j] = i1[j - W1] + r1; i2[j] = i2[j - W1] + r2
                }
            }
        }
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1), c = Double((x1 - x0) * (y1 - y0))
                let a = y1 * W1 + x1, b = y0 * W1 + x1, d = y1 * W1 + x0, e = y0 * W1 + x0
                let mu = (i1[a] - i1[b] - i1[d] + i1[e]) / c
                out[y * w + x] = Float(max(0, (i2[a] - i2[b] - i2[d] + i2[e]) / c - mu * mu).squareRoot())
            }
        }
    }

    /// How far beyond an outline the edge steps read, as a share of its longest side (the plain step's spokes reach 0.09
    /// of a side; the box model's up to about two cut-face bands plus 0.06 of the side, a band being under 0.2 of a side
    /// from any view the shape checks accept), plus `detailReachUnits` half pixels of the frame (the spokes' own width).
    static let detailReach = 0.45
    static let detailReachUnits = 6.0

    /// The image the edge steps read for an outline (frame pixels): the finer image (`detail`, e.g. a full-resolution crop
    /// around the slab) where it covers the outline and everything the steps look at around it (`detailReach`), else the
    /// frame's own luma. A crop around one outline then refines that outline on the finer pixels and leaves any other
    /// (a lookalike elsewhere in the view) on the frame's, instead of reading the crop's clamped border for it. Parts
    /// beyond the frame's own edges do not count (neither image has pixels there).
    func edgeImage(for q: [Vec2]) -> (luma: Plane, map: ImageMap) {
        guard let d = detail, let m = detailMap, FinderRun.detailCovers(q, frameWidth: w, frameHeight: h, detail: d, map: m) else {
            return (yRaw, frameMap)
        }
        return (d.luma, m)
    }

    /// Whether the finer image `detail` covers an outline `q` (pixels of a frame `frameWidth` x `frameHeight`; `map`:
    /// from the frame's pixels to the finer image's) and everything the edge steps look at around it (`detailReach`),
    /// so that its edges are read on the finer image (`edgeImage`). The tracker asks the same of the outline it used,
    /// to say whether its edges came from the crop.
    static func detailCovers(_ q: [Vec2], frameWidth w: Int, frameHeight h: Int, detail d: DetailImage, map m: ImageMap) -> Bool {
        guard q.count >= 3 else { return false }
        let P = q.map(m.forward)
        let longest = (0..<P.count).map { P[$0].distance(to: P[($0 + 1) % P.count]) }.max() ?? 0
        let g = FinderRun.detailReach * longest + FinderRun.detailReachUnits * max(0.5, m.scale / 2)
        let a = m.forward(Vec2(0, 0)), b = m.forward(Vec2(Double(w), Double(h)))
        let x0 = max(P.map { $0.x }.min()! - g, a.x), x1 = min(P.map { $0.x }.max()! + g, b.x)
        let y0 = max(P.map { $0.y }.min()! - g, a.y), y1 = min(P.map { $0.y }.max()! + g, b.y)
        let tol = 1.0
        return x0.isFinite && x1.isFinite && y0.isFinite && y1.isFinite && x0 >= -tol && y0 >= -tol
            && x1 <= Double(d.luma.width) + tol && y1 <= Double(d.luma.height) + tol
    }

    // MARK: entry points

    /// A tapped point is trusted: grow from it, base not required.
    func tapped(_ s: Vec2) -> [SlabCandidate] {
        guard let c = detectSeed(Vec2(s.x - 0.5, s.y - 0.5), needBase: false, roi: fullROI, markRegions: false, source: .tapped) else { return [] }
        return [canonical(c)]
    }

    /// Tracking: follow the predicted outline's edges (the steadiest path), and grow a colour region from its middle as a
    /// fallback, both kept to the predicted outline's surroundings.
    func tracked(_ near: [Vec2]) -> [SlabCandidate] {
        var out: [SlabCandidate] = []
        guard ShapeCheck.isConvex(near) else { return out }
        let plain = plainRefine(near)
        // the edge refiner starts from the plain edges when all four were found, else from the prediction itself; a side
        // it cannot find would keep the predicted line, which may be off by the camera's motion, so such an outline is
        // left to the colour region below
        let start = plain.fitted == 4 ? plain.quad : near
        if plain.fitted >= 3, var c = candidate(plain: start, plainContrast: plain.contrast, source: .tracked),
           !c.sides.contains(where: { $0.mode == .unfitted }) {
            let mid = Geometry.centroid(near)
            c.baseFraction = baseFraction(c.plainQuad, refY: patchMean(Vec2(mid.x - 0.5, mid.y - 0.5))[0])
            out.append(c)
        }
        let xs = near.map { $0.x }, ys = near.map { $0.y }
        let sz = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let roi = ROI(x0: Int(xs.min()! - 0.75 * sz), y0: Int(ys.min()! - 0.75 * sz), x1: Int(xs.max()! + 0.75 * sz) + 1,
                      y1: Int(ys.max()! + 0.75 * sz) + 1, w: w, h: h)
        let mid = Geometry.centroid(near)
        // (its corners come out in the predicted outline's order)
        if roi.isUsable, let c = detectSeed(Vec2(mid.x - 0.5, mid.y - 0.5), needBase: false, roi: roi, markRegions: false, source: .region, align: near) {
            out.append(c)
        }
        return out
    }

    /// The unprompted search. Most of the view is ruled out cheaply: a starting point must be smooth like cement, not
    /// itself dark, and close to something dark (the base). The survivors, nearest the dark first, get the full treatment;
    /// a region once grown is not started again; the largest valid find comes first.
    func sweep() -> [SlabCandidate] {
        var smp: [Float] = []
        smp.reserveCapacity(n / 11 + 1)
        var i = 0
        while i < n { smp.append(Y[i]); i += 11 }
        smp.sort()
        let lim = max(30, 0.45 * smp[smp.count / 2])
        // 3-4 chamfer distance to the nearest dark pixel
        let D = dist, big: UInt16 = 30000
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if Y[i] < lim { D[i] = 0; continue }
                var d = big
                if x > 0 { d = min(d, D[i - 1] &+ 3) }
                if y > 0 {
                    d = min(d, D[i - w] &+ 3)
                    if x > 0 { d = min(d, D[i - w - 1] &+ 4) }
                    if x < w - 1 { d = min(d, D[i - w + 1] &+ 4) }
                }
                D[i] = min(d, big)
            }
        }
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: w - 1, through: 0, by: -1) {
                let i = y * w + x
                var d = D[i]
                if d == 0 { continue }
                if x < w - 1 { d = min(d, D[i + 1] &+ 3) }
                if y < h - 1 {
                    d = min(d, D[i + w] &+ 3)
                    if x < w - 1 { d = min(d, D[i + w + 1] &+ 4) }
                    if x > 0 { d = min(d, D[i + w - 1] &+ 4) }
                }
                D[i] = d
            }
        }
        let far = UInt16(min(Double(big), Double(max(w, h)) * 0.12 * 3))
        // the grid is centred in the view, and points equally near the dark are taken nearest the middle first, so the
        // order (which decides which region a point is grown into) does not depend on which way up the image is
        let step = max(4, opt.sweepStep), cols = max(1, w / step), rows = max(1, h / step)
        let gx0 = (w - 1 - (cols - 1) * step) / 2, gy0 = (h - 1 - (rows - 1) * step) / 2
        let mx = Double(w - 1) / 2, my = Double(h - 1) / 2
        var seeds: [(d: UInt16, r2: Double, j: Int, x: Int, y: Int)] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = gx0 + c * step, y = gy0 + r * step
                guard x >= 0, y >= 0, x < w, y < h else { continue }
                let j = y * w + x
                if Y[j] < lim || Tx[j] / (Y[j] + 10) > Float(opt.maxTexture) || D[j] > far { continue }
                let dx = Double(x) - mx, dy = Double(y) - my
                seeds.append((D[j], dx * dx + dy * dy, j, x, y))
            }
        }
        seeds.sort { $0.d != $1.d ? $0.d < $1.d : $0.r2 != $1.r2 ? $0.r2 < $1.r2 : $0.j < $1.j }
        var found: [SlabCandidate] = []
        var grown = 0
        for s in seeds {
            if grown >= opt.maxSweepRegions { break }
            // a point inside a region grown before, of that region's colour, would only grow it again. The colour matters:
            // grown from the floor's colour, the floor's core can take in the slab, which grown from its own colour stands
            // apart (this made the sweep's result depend on the order of its starting points, i.e. on image orientation)
            let id = Int(mark[s.j]), same = Float(opt.tolerance * (opt.toleranceLadder.min() ?? 1))
            let here = patchMean(Vec2(Double(s.x), Double(s.y)))
            if id != 0 && FinderRun.colourDistance(here, markRefs[id]) < same * same { continue }
            // nor would a point of nearly the colour of a region that already covered most of the view at the tightest
            // match, wherever it is (that is the background)
            if background.contains(where: { FinderRun.colourDistance(here, $0) < same * same / 4 }) { continue }
            grown += 1; seedsGrown += 1
            if let c = detectSeed(Vec2(Double(s.x), Double(s.y)), needBase: opt.requireBase, roi: fullROI, markRegions: true, source: .sweep) {
                // the same slab found from another start: keep the clearer
                if let k = found.firstIndex(where: { Geometry.bestCorrespondence($0.quad, c.quad).meanDistance < 0.15 * ShapeCheck.meanSide(c.quad) }) {
                    if c.score > found[k].score { found[k] = c }
                } else {
                    found.append(c)
                }
            }
        }
        return found.sorted { $0.area > $1.area }.map(canonical)
    }

    // MARK: colour region -> hull -> 4 fitted sides (the web app's detectAt)

    struct ROI {
        var x0: Int, y0: Int, x1: Int, y1: Int // half-open
        init(x0: Int, y0: Int, x1: Int, y1: Int, w: Int, h: Int) {
            self.x0 = clamp(x0, 0, w); self.y0 = clamp(y0, 0, h); self.x1 = clamp(x1, 0, w); self.y1 = clamp(y1, 0, h)
        }
        var isUsable: Bool { x1 - x0 >= 12 && y1 - y0 >= 12 }
    }
    var fullROI: ROI { ROI(x0: 0, y0: 0, x1: w, y1: h, w: w, h: h) }

    struct Region {
        var quad: [Vec2]       // frame pixels (continuous)
        var tol: Double
        var ref: [Float]       // luma, Cb, Cr, texture the region was grown against
        var edges: [Double]    // each side's snap edge step
        var cv: Double         // mean texture / luma
    }

    func patchMean(_ p: Vec2) -> [Float] {
        let sx = clamp(Int(p.x.rounded()), 2, w - 3), sy = clamp(Int(p.y.rounded()), 2, h - 3)
        var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0
        for dy in -2...2 { for dx in -2...2 { let i = (sy + dy) * w + sx + dx; a += Y[i]; b += Cb[i]; c += Cr[i]; d += Tx[i] } }
        return [a / 25, b / 25, c / 25, d / 25]
    }

    /// The pixel a start point (pixel-index coordinates) grows from, kept inside the search area.
    func seedPixel(_ p: Vec2, roi: ROI) -> (x: Int, y: Int) {
        (clamp(Int(p.x.rounded()), max(2, roi.x0 + 2), min(w - 3, roi.x1 - 3)), clamp(Int(p.y.rounded()), max(2, roi.y0 + 2), min(h - 3, roi.y1 - 3)))
    }

    /// Squared colour distance of every pixel in the search area to a reference (the web app's match measure: luma
    /// weighted 0.6, colour differences, and texture above the reference's weighted 4). Computed once per start point
    /// and shared by every tolerance tried.
    func fillColourDistance(ref r: [Float], roi: ROI) {
        let y0 = r[0], b0 = r[1], r0 = r[2], x0 = r[3]
        for y in roi.y0..<roi.y1 {
            let row = y * w
            for x in roi.x0..<roi.x1 {
                let i = row + x
                let a = (Y[i] - y0) * 0.6, b = Cb[i] - b0, c = Cr[i] - r0, d = max(0, Tx[i] - x0) * 4
                cdist[i] = a * a + b * b + c * c + d * d
            }
        }
    }

    /// set by detectAt when the region it grew already covered most of the view (a looser tolerance would only grow it),
    /// or ran into the edge of the search area; and why it gave up (for tests and tuning)
    var lastRegionTooBig = false, lastRegionAtEdge = false
    var lastFailure = ""

    /// the match measure between two references (luma, Cb, Cr, texture), squared
    static func colourDistance(_ a: [Float], _ b: [Float]) -> Float {
        let y = (a[0] - b[0]) * 0.6, cb = a[1] - b[1], cr = a[2] - b[2], t = abs(a[3] - b[3]) * 4
        return y * y + cb * cb + cr * cr + t * t
    }

    /// The colour match (squared distance below t2) and the 3-4 chamfer distance of each matching pixel to the nearest
    /// non-matching one (or the search area's edge), in `dist`: a forward sweep, then a backward one.
    func chamfer(t2: Float, roi: ROI) {
        // row pointers, and the neighbouring row's three values carried along in registers (the same minima in the same
        // order: the same distances; this is the slab search's innermost loop, two passes per region and tolerance)
        guard let D = dist.baseAddress, let C = cdist.baseAddress else { return }
        let w = self.w
        let X0 = roi.x0, Y0 = roi.y0, X1 = roi.x1, Y1 = roi.y1
        for x in X0..<X1 { D[Y0 * w + x] = 0; D[(Y1 - 1) * w + x] = 0 }
        var y = Y0 + 1
        while y < Y1 - 1 {
            let row = D + y * w, up = row - w, c = C + y * w
            row[X0] = 0; row[X1 - 1] = 0
            var left: UInt16 = 0, ul = up[X0], uc = up[X0 + 1]
            var x = X0 + 1
            while x < X1 - 1 {
                let ur = up[x + 1]
                let d: UInt16 = c[x] < t2 ? min(min(left, uc) &+ 3, min(ul, ur) &+ 4) : 0
                row[x] = d; left = d; ul = uc; uc = ur
                x += 1
            }
            y += 1
        }
        y = Y1 - 2
        while y >= Y0 + 1 {
            let row = D + y * w, dn = row + w
            var right = row[X1 - 1], dr = dn[X1 - 1], dc = dn[X1 - 2]
            var x = X1 - 2
            while x >= X0 + 1 {
                let dl = dn[x - 1]
                var d = row[x]
                if d != 0 { d = min(d, min(right, dc) &+ 3, min(dr, dl) &+ 4); row[x] = d }
                right = d; dr = dc; dc = dl
                x -= 1
            }
            y -= 1
        }
    }

    /// Grow a region of the reference colour from pixel (sx, sy), keep its thick core (so thin leaks into look-alike
    /// surroundings are cut off), take its convex hull, reduce it to 4 corners, fit a line to each side and snap it to a
    /// clear luma edge. `fillColourDistance(ref:roi:)` must have been run for this reference and search area.
    func detectAt(sx: Int, sy: Int, ref r: [Float], tol: Double, roi: ROI, markRegion: Bool) -> Region? {
        lastRegionTooBig = false; lastRegionAtEdge = false; lastFailure = ""
        guard roi.isUsable else { return nil }
        var markID: UInt16 = 0
        if markRegion && markRefs.count < Int(UInt16.max) { markRefs.append(r); markID = UInt16(markRefs.count - 1) }
        let D = dist, w = self.w
        let X0 = roi.x0, Y0 = roi.y0, X1 = roi.x1, Y1 = roi.y1
        chamfer(t2: Float(tol * tol), roi: roi)
        // the nearest pixel well inside a matching region
        var s = -1
        search: for rr in 0...14 {
            for dy in -rr...rr {
                for dx in -rr...rr where max(abs(dx), abs(dy)) == rr {
                    let x = sx + dx, y = sy + dy
                    if x < X0 + 1 || y < Y0 + 1 || x >= X1 - 1 || y >= Y1 - 1 { continue }
                    if D[y * w + x] > 3 { s = y * w + x; break search }
                }
            }
        }
        if s < 0 { lastFailure = "no core"; return nil }
        // climb to the middle of the region the seed sits in, then keep only its thick core
        let nb8 = [-1, 1, -w, w, -w - 1, -w + 1, w - 1, w + 1]
        for _ in 0..<400 {
            var b = s
            for o in nb8 where D[s + o] > D[b] { b = s + o }
            if b == s { break }
            s = b
        }
        let rad = max(1, Double(D[s]) / 3 * 0.3)
        let core = UInt16(clamp((rad * 3).rounded(.down), 0, 60000))
        gen &+= 1
        if gen == 0 { for i in 0..<n { visit[i] = 0 }; gen = 1 }
        let g = gen
        for y in Y0..<Y1 { rmin[y] = Int32.max; rmax[y] = -1 }
        for x in X0..<X1 { cmin[x] = Int32.max; cmax[x] = -1 }
        var sp = 0
        stack[0] = Int32(s); sp = 1; visit[s] = g
        var count = 0, border = 0
        var tsum: Double = 0
        let maxCount = Int(Double(n) * 0.6)
        while sp > 0 {
            sp -= 1
            let i = Int(stack[sp]), y = i / w, x = i - y * w
            count += 1; tsum += Double(Tx[i])
            if markRegion { mark[i] = markID }
            if x <= X0 + 1 || y <= Y0 + 1 || x >= X1 - 2 || y >= Y1 - 2 { border += 1 }
            let x32 = Int32(x), y32 = Int32(y)
            if x32 < rmin[y] { rmin[y] = x32 }
            if x32 > rmax[y] { rmax[y] = x32 }
            if y32 < cmin[x] { cmin[x] = y32 }
            if y32 > cmax[x] { cmax[x] = y32 }
            var j = i - 1
            if visit[j] != g && D[j] > core { visit[j] = g; stack[sp] = Int32(j); sp += 1 }
            j = i + 1
            if visit[j] != g && D[j] > core { visit[j] = g; stack[sp] = Int32(j); sp += 1 }
            j = i - w
            if visit[j] != g && D[j] > core { visit[j] = g; stack[sp] = Int32(j); sp += 1 }
            j = i + w
            if visit[j] != g && D[j] > core { visit[j] = g; stack[sp] = Int32(j); sp += 1 }
            // hopeless already (it runs into the edge of the search area, or covers most of the view)
            if count > maxCount { lastRegionTooBig = true; return nil }
            if !markRegion && border > 8 { lastFailure = "touches the edge"; lastRegionAtEdge = true; return nil }
        }
        if border > 8 { lastFailure = "touches the edge"; lastRegionAtEdge = true; return nil }
        if Double(count) < Double(n) * 0.0012 || count > maxCount { lastFailure = "size"; return nil }
        var pts: [Vec2] = []
        pts.reserveCapacity(2 * (Y1 - Y0 + X1 - X0))
        for y in Y0..<Y1 where rmax[y] >= 0 { pts.append(Vec2(Double(rmin[y]), Double(y))); pts.append(Vec2(Double(rmax[y]), Double(y))) }
        for x in X0..<X1 where cmax[x] >= 0 { pts.append(Vec2(Double(x), Double(cmin[x]))); pts.append(Vec2(Double(x), Double(cmax[x]))) }
        var hl = FinderRun.hull(pts)
        if hl.count < 4 { lastFailure = "hull"; return nil }
        while hl.count > 4 {
            var bi = 0, ba = Double.infinity
            let m = hl.count
            for i in 0..<m {
                let a = abs(FinderRun.cr2(hl[(i + m - 1) % m], hl[i], hl[(i + 1) % m]))
                if a < ba { ba = a; bi = i }
            }
            hl.remove(at: bi)
        }
        let cen = Geometry.centroid(hl)
        // fit a line to each side from the boundary points; the core stops short of the true edge by the cut radius plus
        // the texture window, so push it out by that, then snap to a clear luma edge if one is close
        var lines: [Line2] = [], edges: [Double] = []
        var perim = 0.0
        let push = rad + 2.5
        for i in 0..<4 {
            let A = hl[i], B = hl[(i + 1) % 4], len = A.distance(to: B)
            perim += len
            if len < 6 { lastFailure = "short side"; return nil }
            var d = (B - A) / len, pp = (A + B) / 2
            let lim = max(1.5, len * 0.05)
            var sel: [Vec2] = []
            for q in pts {
                let t = (q - A).dot(d) / len
                if t < 0.12 || t > 0.88 { continue }
                if abs((q - A).cross(d)) < lim { sel.append(q) }
            }
            if sel.count >= 5 {
                let l = Geometry.fitLine(sel)
                d = l.d; pp = l.p
            }
            var nrm = d.perpendicular
            if nrm.dot(pp - cen) < 0 { nrm = -nrm }
            pp = pp + nrm * push
            let sA = (A - pp).dot(d), sB = (B - pp).dot(d)
            var gs: [Double] = [], gmax = 0.0
            var o = -4.0
            while o <= 4.0001 {
                var gsum = 0.0
                for j in 0..<14 {
                    let t = sA + (sB - sA) * (0.15 + 0.7 * Double(j) / 13)
                    let q = pp + d * t + nrm * o
                    gsum += Double(sampleIndex(yRaw, q + nrm) - sampleIndex(yRaw, q - nrm))
                }
                let gv = abs(gsum / 14)
                gs.append(gv); gmax = max(gmax, gv)
                o += 0.5
            }
            if gmax >= 10 {
                for j in 0..<gs.count {
                    let prev = j > 0 ? gs[j - 1] : 0, next = j + 1 < gs.count ? gs[j + 1] : 0
                    if gs[j] >= max(6, 0.3 * gmax) && gs[j] >= prev && gs[j] >= next {
                        pp = pp + nrm * (-4 + Double(j) * 0.5); break
                    }
                }
            }
            edges.append(gmax)
            lines.append(Line2(p: pp, d: d))
        }
        var q: [Vec2] = []
        for i in 0..<4 {
            var c = hl[i]
            if let r = lines[(i + 3) % 4].intersection(lines[i]), r.distance(to: c) < perim / 4 * 0.3 + 2 * push { c = r }
            q.append(c)
        }
        // the whole slab must be in view
        for c in q where c.x < 2 || c.y < 2 || c.x > Double(w - 3) || c.y > Double(h - 3) { lastFailure = "corner out of view"; lastRegionAtEdge = true; return nil }
        guard ShapeCheck.isConvex(q) else { lastFailure = "not convex"; return nil }
        let area = abs(Geometry.signedArea(q))
        if area < Double(n) * 0.006 { lastFailure = "small"; return nil } // too small in view to be the slab
        let fill = (Double(count) + perim * push + 4 * push * push) / area
        if fill < 0.6 || fill > 1.5 { lastFailure = "fill \(fill)"; return nil } // loose: the rigid-square test after edge refinement is the real gate
        return Region(quad: q.map { Vec2($0.x + 0.5, $0.y + 0.5) }, tol: tol, ref: r, edges: edges,
                      cv: tsum / Double(count) / Double(r[0] + 10))
    }

    /// bilinear sample in pixel-index coordinates (the web app's smp)
    @inline(__always) func sampleIndex(_ p: Plane, _ q: Vec2) -> Float { p.sample(q.x + 0.5, q.y + 0.5) }

    static func cr2(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }

    static func hull(_ input: [Vec2]) -> [Vec2] {
        let p = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count >= 3 else { return p }
        var hl: [Vec2] = []
        for q in p {
            while hl.count >= 2 && cr2(hl[hl.count - 2], hl[hl.count - 1], q) <= 0 { hl.removeLast() }
            hl.append(q)
        }
        let lo = hl.count + 1
        for i in stride(from: p.count - 2, through: 0, by: -1) {
            let q = p[i]
            while hl.count >= lo && cr2(hl[hl.count - 2], hl[hl.count - 1], q) <= 0 { hl.removeLast() }
            hl.append(q)
        }
        hl.removeLast()
        return hl
    }

    // MARK: tolerance ladder (the web app's detectSeed)

    /// Try several colour tolerances and keep the outline whose weakest side still sits on the clearest image edge. Too
    /// tight a match stops at a lighting gradient and too loose a one leaks; either way one side has no real edge under it.
    ///
    /// The regions are grown and screened first (cheap), then refined and checked clearest first until one passes: the
    /// same outline the web app's one-pass ladder keeps (the clearest that passes; the tighter on a tie), with usually
    /// one refinement instead of one per tolerance.
    func detectSeed(_ p: Vec2, needBase: Bool, roi: ROI, markRegions: Bool, source: SlabCandidate.Source, align: [Vec2]? = nil) -> SlabCandidate? {
        let minEdge = needBase ? opt.minSideEdge : -1
        guard roi.isUsable else { return nil }
        let (sx, sy) = seedPixel(p, roi: roi)
        let ref = patchMean(Vec2(Double(sx), Double(sy)))
        fillColourDistance(ref: ref, roi: roi)
        let ladder = opt.toleranceLadder.sorted()
        var screened: [(edge: Double, m: Double, region: Region, quad: [Vec2], base: Double)] = []
        for m in ladder {
            regionsTried += 1
            // only the tightest match is recorded for the sweep: a looser one can leak from the floor into a slab of the same
            // tone, and would then keep the slab's own points from being grown
            guard let r = detectAt(sx: sx, sy: sy, ref: ref, tol: opt.tolerance * m, roi: roi, markRegion: markRegions && m == ladder.first) else {
                trace?("seed (\(sx), \(sy)) tol x\(m): no region\(lastRegionTooBig ? " (covers most of the view)" : "") \(lastFailure)")
                // a looser match would only grow a region that already covers most of the view, or already runs out of it
                if lastRegionTooBig {
                    if m == ladder.first { background.append(ref) }
                    break
                }
                if lastRegionAtEdge && roi.x0 == 0 && roi.y0 == 0 && roi.x1 == w && roi.y1 == h { break }
                continue
            }
            regionsKept += 1
            let edge = r.edges.min() ?? 0
            if edge <= minEdge { trace?("seed (\(sx), \(sy)) tol x\(m): weakest edge \(edge) <= \(minEdge)"); continue }
            // when searching unprompted, the patch must also be smooth like cement and sit on the black base
            if needBase && r.cv > opt.maxTexture { trace?("seed (\(sx), \(sy)) tol x\(m): textured \(r.cv)"); continue }
            var quad = r.quad
            if let a = align { quad = Geometry.aligned(quad, to: a) }
            let bf = baseFraction(quad, refY: r.ref[0])
            if needBase && bf < opt.minBaseFraction { trace?("seed (\(sx), \(sy)) tol x\(m): base \(bf)"); continue }
            screened.append((edge, m, r, quad, bf))
        }
        // clearest first; the tighter match first on a tie
        for s in screened.enumerated().sorted(by: { $0.element.edge != $1.element.edge ? $0.element.edge > $1.element.edge : $0.offset < $1.offset }).map({ $0.element }) {
            refined += 1
            let plain = plainRefine(s.quad)
            guard var c = candidate(plain: plain.quad, plainContrast: plain.contrast, source: source) else {
                trace?("seed (\(sx), \(sy)) tol x\(s.m): rejected outline \(s.quad) plain \(plain.quad)"); continue
            }
            trace?("seed (\(sx), \(sy)) tol x\(s.m): candidate \(c.quad)")
            c.baseFraction = s.base; c.tolerance = s.region.tol; c.reference = s.region.ref.map { Double($0) }
            return c
        }
        return nil
    }

    /// The checks every outline must pass, and the box model's top-edge step.
    func candidate(plain: [Vec2], plainContrast: [Double], source: SlabCandidate.Source) -> SlabCandidate? {
        var quad = plain, sides: [SideEdge] = [], newChoice: EdgeChoice? = nil
        let fit: PoseFit
        if opt.useBoxModel {
            let edges = edgeImage(for: plain)
            guard let r = refiner.refine(outline: plain, intrinsics: K, luma: edges.luma, lumaIntrinsics: edges.map.to, spec: spec,
                                         down: down, choice: choice) else { return nil }
            quad = r.outline; fit = r.fit; sides = r.sides; newChoice = r.choice
        } else {
            guard let f = PoseSolver.solve(corners: plain, intrinsics: K, spec: spec, down: down, previousNormal: choice?.normal,
                                           options: opt.edges.pose) else { return nil }
            fit = f
        }
        guard ShapeCheck.check(fit, outline: quad, down: down, limits: opt.useBoxModel ? opt.limits : opt.plainLimits) == .ok,
              let shape = FinderRun.aspectAndSkew(quad, K: K, spec: spec), shape.aspectLog <= opt.maxAspectLog,
              shape.skewCos <= opt.maxSkewCos else { return nil }
        let score = sides.isEmpty ? (plainContrast.min() ?? 0) : sides.map { abs($0.outerContrast) }.min() ?? 0
        return SlabCandidate(quad: quad, plainQuad: plain, fit: fit, score: score, area: abs(Geometry.signedArea(quad)), baseFraction: 0,
                             sides: sides, choice: newChoice, source: source, tolerance: 0, reference: [])
    }

    /// The web app's shape measure with the real lens: the homography from the slab's top face to the outline, as two
    /// scaled rotation columns; for the slab they are equally long (|log ratio| near 0) and square (|cos| near 0). The
    /// better of the two ways the slab's sides can lie along the outline's (they differ only for a rectangular slab).
    static func aspectAndSkew(_ q: [Vec2], K: CameraIntrinsics, spec: SlabSpec) -> (aspectLog: Double, skewCos: Double)? {
        var best: (aspectLog: Double, skewCos: Double)? = nil
        for (hu, hv) in [(spec.halfU, spec.halfV), (spec.halfV, spec.halfU)] {
            guard let (c0, c1, _) = PoseSolver.homography(q, K: K, hu: hu, hv: hv) else { continue }
            let a = c0.length, b = c1.length
            guard a > 0, b > 0 else { continue }
            let m = (abs(log(a / b)), abs(c0.dot(c1)) / (a * b))
            if best == nil || m.0 < best!.aspectLog { best = m }
            if spec.sideU == spec.sideV { break }
        }
        return best
    }

    /// The outline turned to run clockwise on screen from the corner nearest the top-left (for searches with no
    /// predicted outline to follow).
    func canonical(_ cIn: SlabCandidate) -> SlabCandidate {
        var c = cIn
        var order = [0, 1, 2, 3]
        if Geometry.signedArea(c.quad) < 0 { order = [0, 3, 2, 1] }
        var start = 0, bv = Double.infinity
        for k in 0..<4 { let p = c.quad[order[k]]; if p.x + p.y < bv { bv = p.x + p.y; start = k } }
        let idx = (0..<4).map { order[($0 + start) % 4] }
        let reversed = order[1] == 3
        c.quad = idx.map { c.quad[$0] }
        c.plainQuad = idx.map { c.plainQuad[$0] }
        if c.sides.count == 4 {
            // side i ran from corner i to i+1; reversed, the new side k runs from idx[k] to idx[k+1] = old side idx[k+1]
            c.sides = (0..<4).map { k in reversed ? c.sides[idx[(k + 1) % 4]] : c.sides[idx[k]] }
        }
        return c
    }

    // MARK: the black base

    /// The cement always sits on its black base: how much of the strip just outside one side of the outline is dark?
    /// The best side counts, whichever way it faces: the slab slides in its cradle as it rocks, so the base can show
    /// beside any side, not only below the slab (restricting this to the sides facing down along gravity lost the
    /// slab on the cradle_r14 fixture, whose base shows beside a side facing up in the image).
    func baseFraction(_ q: [Vec2], refY: Float) -> Double {
        let lim = refY * Float(opt.darkFraction)
        let c = Geometry.centroid(q)
        var best = 0.0
        for i in 0..<4 {
            let A = q[i], B = q[(i + 1) % 4], len = A.distance(to: B)
            guard len > 1 else { continue }
            var nrm = ((B - A) / len).perpendicular
            if nrm.dot((A + B) / 2 - c) < 0 { nrm = -nrm }
            var dark = 0, tot = 0
            for o in 1...12 {
                for j in 0..<12 {
                    let t = 0.06 + 0.88 * Double(j) / 11
                    let p = A + (B - A) * t + nrm * (len * 0.03 * Double(o))
                    let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
                    if x < 0 || y < 0 || x >= w || y >= h { continue }
                    tot += 1
                    if Y[y * w + x] < lim { dark += 1 }
                }
            }
            if tot > 40 { best = max(best, Double(dark) / Double(tot)) }
        }
        return best
    }

    // MARK: plain edge refinement (the web app's refineQuad, without the cut-edge correction)

    /// Sharpen an outline on the edge image: find the first clear edge from the inside at many points along each side,
    /// fit a straight line through them ignoring strays, and take the corners where those lines cross.
    func plainRefine(_ q: [Vec2]) -> (quad: [Vec2], fitted: Int, contrast: [Double]) {
        let (edgeLuma, edgeMap) = edgeImage(for: q)
        let P = q.map(edgeMap.forward)
        let ds = edgeMap.scale, unit = EdgeRefiner.unit(scale: ds), wf = 0.09
        let c = Geometry.centroid(P)
        var lines: [Line2] = [], fitted = 0, contrast: [Double] = []
        for i in 0..<4 {
            let A = P[i], B = P[(i + 1) % 4], len = A.distance(to: B)
            let dir = (B - A) / max(len, 1e-9)
            var nrm = dir.perpendicular
            if nrm.dot((A + B) / 2 - c) < 0 { nrm = -nrm }
            let wd = max(5 * unit, len * wf)
            let sp = SpokeProfiles(luma: edgeLuma, a: A, b: B, normal: nrm, inward: wd, outward: wd, unit: unit, count: 32)
            var pts: [Vec2] = []
            var gs = [Float](repeating: 0, count: sp.m), sorted = gs
            for j in 0..<sp.n {
                var gmax: Float = 0
                for k in 0..<sp.m { gs[k] = abs(sp.g[j * sp.m + k]); gmax = max(gmax, gs[k]) }
                for k in 0..<sp.m { sorted[k] = gs[k] }
                sorted.sort()
                // an edge must stand clear of this reading's own background ripple (cement speckle, sensor noise); the
                // lower quartile, not the web app's median: at frame resolution two blurred edges can fill half the window
                let thr = max(0.25 * gmax, 2.5 * sorted[sp.m / 4] + 2)
                if gmax < thr { continue }
                for k in 1..<(sp.m - 1) where gs[k] >= thr && gs[k] >= gs[k - 1] && gs[k] >= gs[k + 1] {
                    let den = Double(gs[k - 1] - 2 * gs[k] + gs[k + 1])
                    let off = den < 0 ? 0.5 * Double(gs[k - 1] - gs[k + 1]) / den : 0
                    pts.append(sp.base[j] + nrm * (sp.o0 + (Double(k) + off) * sp.step))
                    break
                }
            }
            var L = Line2(p: A, d: dir)
            if pts.count >= 10, let r = Geometry.robustLine(pts, unit: unit, minPoints: 8) {
                fitted += 1
                L = r.line
                if L.d.dot(dir) < 0 { L.d = -L.d }
            }
            lines.append(L)
            contrast.append(abs(sp.mean(at: sp.offsets(of: L)) ?? 0))
        }
        let lim = wf * 2 + 0.01
        let out = (0..<4).map { i -> Vec2 in
            let a = lines[(i + 3) % 4], b = lines[i]
            guard let x = a.intersection(b) else { return q[i] }
            let side = P[i].distance(to: P[(i + 1) % 4])
            return x.distance(to: P[i]) < side * lim + 3 * unit ? edgeMap.inverse(x) : q[i]
        }
        return (out, fitted, contrast)
    }
}
