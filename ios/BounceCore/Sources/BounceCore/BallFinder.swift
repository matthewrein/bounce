import Foundation

/// An axis-aligned rectangle in image coordinates (continuous, as `CameraIntrinsics`: pixel (i, j) covers
/// [i, i+1) x [j, j+1)).
public struct ImageRect: Equatable, CustomStringConvertible {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    /// A square of half-size `h` around a point.
    public init(center c: Vec2, halfSize h: Double) { self.init(minX: c.x - h, minY: c.y - h, maxX: c.x + h, maxY: c.y + h) }
    /// The whole of a `width` x `height` image.
    public init(width: Int, height: Int) { self.init(minX: 0, minY: 0, maxX: Double(width), maxY: Double(height)) }
    /// Nothing (a union starts from this).
    public static let empty = ImageRect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    public var isEmpty: Bool { !(maxX > minX && maxY > minY) }
    public func contains(_ p: Vec2) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    public func expanded(by m: Double) -> ImageRect { ImageRect(minX: minX - m, minY: minY - m, maxX: maxX + m, maxY: maxY + m) }
    public func union(_ p: Vec2) -> ImageRect {
        ImageRect(minX: min(minX, p.x), minY: min(minY, p.y), maxX: max(maxX, p.x), maxY: max(maxY, p.y))
    }
    public func intersection(_ r: ImageRect) -> ImageRect {
        ImageRect(minX: max(minX, r.minX), minY: max(minY, r.minY), maxX: min(maxX, r.maxX), maxY: min(maxY, r.maxY))
    }
    /// The part inside a `width` x `height` image.
    public func clamped(width: Int, height: Int) -> ImageRect { intersection(ImageRect(width: width, height: height)) }
    public var description: String { String(format: "[%.1f...%.1f] x [%.1f...%.1f]", minX, maxX, minY, maxY) }
}

/// A ball's outline found in an image.
public struct BallCircle: Equatable, CustomStringConvertible {
    /// Where the ball's centre is seen (pixels). Found with the camera's intrinsics this is the projection of the
    /// sphere's centre (off the optical axis its outline is a slightly elongated ellipse around it).
    public var center: Vec2
    /// Radius (pixels) in the sense of `Bounce.RadiusModel.imageCircle`: `Bounce.ballCenter(pixel: center,
    /// radiusPixels: radius, ..., model: .imageCircle)` puts the ball where the outline says it is.
    public var radius: Double
    /// How many of the 48 rim spokes found the outline where the circle runs. For a partial find these are counted on
    /// its half of the rim (at most about 24, with a few beyond it), so a partial and a whole find's support are not on
    /// one scale (`BallLocator` tries finds in order of support).
    public var support: Int
    /// Rests on half the outline only: its upper half (a polished ball held above the floor and seen from above can
    /// reflect the same floor that lies behind its lower half, so the outline there is all but invisible) or its lower
    /// half (the top can blend into the floor it reflects at a grazing angle, and the fingers cover it). That is so
    /// where no reading of the whole outline was found, and where one was but its points are not those of one circle
    /// and lie, on one half, inside the circle the other half makes (`BallFinder.outermost`). `BallLocator` holds a
    /// partial find to stricter rules (two scans in a row, a least height).
    public var partial: Bool

    public init(center: Vec2, radius: Double, support: Int, partial: Bool) {
        self.center = center; self.radius = radius; self.support = support; self.partial = partial
    }
    public var description: String {
        String(format: "(%.2f, %.2f) r %.2f, %d spokes%@", center.x, center.y, radius, support, partial ? ", partial" : "")
    }
}

/// Finds a ball - a round outline of an expected size - in a luma image. Port of the web app's findBall:
///  1. every strong edge pixel votes for centres along its gradient direction at each plausible radius (a Hough
///     transform on a half-resolution grid); the strongest few peaks are examined in turn;
///  2. the rim is measured along 48 spokes from the peak: every edge crossing is noted, the radius most spokes agree on
///     is found, and of the well-supported radii the outermost is taken (a mirror ball shows reflected rings inside it);
///     each spoke's crossing nearest that radius is kept and a circle fitted; then measured again around that circle
///     with a tight tolerance;
///  3. a ball whose outline shows on at least 80% of the spokes and fits a circle is accepted ("full");
///  4. the upper outline alone may do too ("partial"): held above the floor and seen from above, a mirror ball's
///     lower half reflects the very floor behind it, while its upper half reflects the room above. At least 14 of the
///     upper spokes must agree on a tight circle (rms under 0.6 px), and the inside of the upper half must look like a
///     mirror: a highlight well above the background just outside, and plenty of light and dark detail.
///
/// Changes from the web app, each found necessary on the full-resolution fixtures (the web app ran at about 0.7x):
/// - With the camera's intrinsics the rim is measured and fitted in a virtual camera turned to look straight at the
///   candidate, where a sphere's outline is an exact circle (in the image it is an ellipse, stretched along the line
///   from the image centre by up to 1/cos^2 of the angle off the axis), and the result is reported in the
///   `RadiusModel.imageCircle` sense. "Up" can be any image direction (the camera image need not be upright).
/// - The vote peak is often 2-4 px off the ball's centre, which spreads the rim over a range of radii; the rim is
///   measured from the centres its crossings agree on best (`RimMeasure.centerCandidates`), crossings are located to a
///   fraction of a pixel and the radius histogram uses quarter-pixel bins.
/// - Circle fits are robust (points far off are dropped).
/// - The first circle fitted from a start is rough, so its size is checked loosely (15% either way) and only the final
///   circle has to lie within the radius range.
/// - A partial find may also come from the lower half of the outline alone (`Options.minLowerShare`: 80% of the lower
///   spokes, as the whole outline needs 80% of all): on the renders of the owner's titanium ball the lower outline
///   shows clearly while the top of the ball blends into the floor it reflects at a grazing angle and is covered by
///   the fingers.
/// - Every start is read three ways (the whole outline, its lower half, its upper half), and the readings of one ball
///   (from several starts and peaks) are settled by `outermost`: the whole outline's reading stands unless its points
///   are not those of one circle and one half of them lies inside the circle a half reading makes of the other half,
///   by more than the fits' uncertainty; then that half reading gives the outline, and the find is partial.
/// - The partial readings count a rim crossing only where the edge runs across the spoke (`Options.maxEdgeAngle`):
///   resting on fewer spokes, they could otherwise be made up from texture and noise (a printed circle on the floor
///   mat was reported this way in a noisy picture). The upper outline's final fit drops points inside the circle more
///   readily than outside ones (`Options.innerLimit`). A whole outline needs 80% of its points to be such edges: a
///   square tile's or grid cell's outline, read as a circle, never has that many.
/// - With the intrinsics and gravity (`find`'s `down`), a find whose outline is that of a flat round thing lying level
///   (a sticker, lid or coaster on the floor) rather than a sphere's is dropped (`flatness`), and a whole find must also
///   look like a mirror inside (`Options.mirrorTestAll`). Neither tells a textured print standing up and facing the
///   camera from a ball: its outline is round and its inside can look like a mirror's.
/// - Edge thresholds rise with the picture's noise (`Options.gradientPerNoise`), and the fixed ones scale with its
///   exposure (`Options.referenceLuma`): with fixed thresholds a darker picture of the same scene loses the ball's
///   outline before the stronger reflections inside it, and an inner ring was then reported as the ball.
public enum BallFinder {
    public struct Options {
        /// edge pixels that vote: central-difference gradient magnitude (luma levels across 2 px)
        public var minGradient: Float = 16
        /// radius step of the votes (pixels)
        public var radiusStep: Double = 1.5
        /// a peak needs at least this many votes
        public var minVotes: Int = 12
        /// at most this many peaks are examined
        public var maxCandidates: Int = 8
        /// how far (pixels) from a vote peak its centre is looked for along the rim
        public var centerReach: Int = 5
        /// a rim crossing: luma difference across 2 px along a spoke, at a local maximum
        public var minRimContrast: Float = 9
        /// spokes (of 48) that must find the outline for a full find (web: 39, "at least 80% of the rim")
        public var minFullSupport: Int = 39
        /// upper spokes that must agree on the radius to start a partial find, and that must lie on its circle
        public var minUpperSeed: Int = 13
        /// No longer used: a partial find from part of the outline other than its upper half now needs its whole lower
        /// half (`minLowerShare`).
        public var minArcSupport: Int = 24
        /// a partial find from the lower outline (not in the web app) needs at least this share of the lower spokes on
        /// a tight circle: the share the whole outline needs (39 of 48 spokes, the web app's rule)
        public var minLowerShare: Double = 0.8
        /// In the final fit of the upper outline's reading a rim point this far (pixels) inside the circle is dropped,
        /// whatever the scatter of the others (2.5 times the quarter pixel to which an edge can be placed); one outside
        /// is dropped only if it is far off the scatter. Every edge a ball shows other than its outline lies inside it,
        /// while the background's edges lie on either side. (The lower half's reading drops points on either side
        /// alike: dropping inside points first, pass after pass, pushed its circle out by several per cent on clean
        /// balls.)
        public var innerLimit: Double = 0.6
        public var minUpperSupport: Int = 14
        /// largest rms distance (pixels) of a partial find's rim points from its circle
        public var maxUpperRms: Double = 0.6
        /// mirror test for a partial find: brightest inside the upper half over the background just outside, and the
        /// standard deviation inside (luma levels)
        public var minHighlight: Float = 40
        public var minMirrorDetail: Float = 12
        /// In a noisy or busy picture both edge thresholds rise with the median luma difference across 2 px in the
        /// region (3 levels on the test renders, 7.5 on the dim one): the vote threshold to this many times it and the
        /// rim-crossing threshold to that many times it, whichever is larger than the fixed thresholds above.
        public var gradientPerNoise: Float = 3
        public var rimContrastPerNoise: Float = 2
        /// The fixed thresholds above (gradient, rim contrast, highlight, mirror detail) are for a picture whose median
        /// luma in the region is this (the fixtures' is 109-115); they are scaled with the region's own median luma
        /// (within 0.25-2x), so a darker exposure of the same scene is searched alike. Nil keeps them fixed (the web
        /// app's behaviour).
        public var referenceLuma: Float? = 110
        /// Measured around a fitted circle for a partial reading, a rim crossing counts only where the edge runs across
        /// the spoke, its normal within this many degrees of the spoke (0: any edge): an outline does (the fitted centre
        /// is within a pixel or so of the true one, a few degrees on these radii), while the edges of texture, noise and
        /// reflections cross the spokes at any angle, so only a third of them pass. A whole outline's reading needs that
        /// share (`minLowerShare`) of its points to be such edges.
        public var maxEdgeAngle: Double = 30
        var maxSkew: Float { maxEdgeAngle > 0 ? Float(tan(maxEdgeAngle * .pi / 180)) : 0 }
        /// With the intrinsics and gravity given, a round outline that is a flat round thing lying level (a sticker, lid
        /// or coaster on the floor) rather than a sphere is not reported (see `flatness`).
        public var rejectLevelDiscs = true
        /// A find from the whole outline must pass the mirror test too (`minHighlight`, `minMirrorDetail`), sampled all
        /// round its inside: a polished ball reflects the room in its upper half and the floor in its lower half, while a
        /// plain printed disc (a sticker, a coaster) is plain throughout. (The web app tested partial finds only, on
        /// their upper half, as is still done.)
        public var mirrorTestAll = true
        public init() {}
    }

    public static let spokeCount = 48

    /// - Parameters:
    ///   - luma: the image (0-255)
    ///   - radiusRange: radii (pixels, in the `imageCircle` sense) a ball may have
    ///   - roi: only edges inside this region vote (e.g. a box around a ball being followed); nil for the whole image
    ///   - intrinsics: the camera's intrinsics for this image; nil treats the image as if every ball were seen on the
    ///     optical axis (the web app's behaviour)
    ///   - up: the image direction pointing up in the world (default: up the image); used for the upper outline
    ///   - down: gravity in the camera's axes, with `intrinsics`: then a flat round thing lying level is told from a
    ///     sphere and not returned (`Options.rejectLevelDiscs`); nil skips that test
    /// - Returns: the balls found, most rim support first
    public static func find(luma: Plane, radiusRange: ClosedRange<Double>, roi: ImageRect? = nil,
                            intrinsics: CameraIntrinsics? = nil, up: Vec2 = Vec2(0, -1), down: Vec3? = nil,
                            options: Options = Options()) -> [BallCircle] {
        let W = luma.width, H = luma.height
        guard W >= 8, H >= 8, radiusRange.upperBound.isFinite else { return [] }
        let rmin = max(4, radiusRange.lowerBound), rmax = max(rmin, radiusRange.upperBound)
        let region = (roi ?? ImageRect(width: W, height: H)).clamped(width: W, height: H)
        guard !region.isEmpty else { return [] }
        let options = adapted(options, to: luma, in: region)
        guard var votes = Votes(luma: luma, roi: region, rmin: rmin, rmax: rmax, options: options) else { return [] }
        var rim = RimMeasure(luma: luma, maxRadius: rmax * 3 + 4, minContrast: options.minRimContrast)
        // the readings of each ball found, and what they give
        var balls: [(readings: [Reading], choice: Reading)] = []
        let z = max(2, Int((rmin / 2).rounded()))
        for _ in 0..<options.maxCandidates {
            guard let (seed, _) = votes.takePeak(minVotes: options.minVotes, clear: z) else { break }
            let rs = examine(seed: seed, rmin: rmin, rmax: rmax, intrinsics: intrinsics, up: up, rim: &rim, options: options)
            guard let c = outermost(rs, intrinsics: intrinsics, up: up) else { continue }
            // two peaks on one ball: choose from all their readings
            if let k = balls.firstIndex(where: { $0.choice.circle.center.distance(to: c.circle.center) < 0.5 * max($0.choice.circle.radius, c.circle.radius) }) {
                balls[k].readings += rs
                balls[k].choice = outermost(balls[k].readings, intrinsics: intrinsics, up: up) ?? c
            } else {
                balls.append((rs, c))
            }
        }
        var out = balls.map(\.choice.circle)
        // every find looks like a mirror (a partial one was tested on its upper half already; a whole one is tested all
        // round)
        if options.mirrorTestAll {
            out.removeAll { c in
                guard !c.partial else { return false }
                let F = LocalFrame(at: c.center, intrinsics: intrinsics, up: up)
                return !looksLikeMirror(F, (0, 0, c.radius / F.stretch), luma, options, allAround: true, trace: nil)
            }
        }
        // not a flat round thing lying level (see `flatness`)
        if options.rejectLevelDiscs, let K = intrinsics, let down {
            out.removeAll { flatness(luma: luma, circle: $0, intrinsics: K, down: down, rim: &rim, options: options)?.isLevelDisc ?? false }
        }
        return out.sorted { $0.support > $1.support }
    }

    /// The options with the edge thresholds raised for the region's noise.
    static func adapted(_ o: Options, to luma: Plane, in region: ImageRect) -> Options {
        var o = o
        if let ref = o.referenceLuma, ref > 0 {
            let k = min(2, max(0.25, medianLuma(luma, region) / ref))
            o.minGradient *= k; o.minRimContrast *= k; o.minHighlight *= k; o.minMirrorDetail *= k
        }
        let noise = noiseLevel(luma, region)
        o.minGradient = max(o.minGradient, o.gradientPerNoise * noise)
        o.minRimContrast = max(o.minRimContrast, o.rimContrastPerNoise * noise)
        return o
    }

    /// Median luma over a region (sampled on a 3-px grid).
    static func medianLuma(_ luma: Plane, _ region: ImageRect) -> Float {
        let W = luma.width
        let x0 = max(0, Int(region.minX)), x1 = min(W, Int(region.maxX)), y0 = max(0, Int(region.minY)), y1 = min(luma.height, Int(region.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        var n = 0
        luma.data.withUnsafeBufferPointer { Y in
            var y = y0
            while y < y1 {
                var x = x0 + (y % 3)
                while x < x1 { counts[min(255, max(0, Int(Y[y * W + x] + 0.5)))] += 1; n += 1; x += 3 }
                y += 3
            }
        }
        var acc = 0
        for (v, c) in counts.enumerated() where c > 0 {
            if 2 * (acc + c) >= n { return Float(v) }
            acc += c
        }
        return 255
    }

    /// Median absolute luma difference across 2 px (horizontal), sampled over a region: the picture's noise and fine
    /// texture. Counted in whole-level bins (centred on whole levels) and interpolated within the median's bin, so it
    /// changes smoothly with the noise rather than in whole levels.
    static func noiseLevel(_ luma: Plane, _ region: ImageRect) -> Float {
        let W = luma.width
        let x0 = max(1, Int(region.minX)), x1 = min(W - 1, Int(region.maxX)), y0 = max(0, Int(region.minY)), y1 = min(luma.height, Int(region.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        var n = 0
        luma.data.withUnsafeBufferPointer { Y in
            var y = y0
            while y < y1 {
                var x = x0 + (y % 3)
                while x < x1 {
                    let i = y * W + x
                    counts[min(255, Int(abs(Y[i + 1] - Y[i - 1]) + 0.5))] += 1; n += 1
                    x += 3
                }
                y += 3
            }
        }
        guard n > 0 else { return 0 }
        var acc = 0
        for (v, c) in counts.enumerated() where c > 0 {
            if 2 * (acc + c) >= n { return max(0, Float(v) - 0.5 + (Float(n) / 2 - Float(acc)) / Float(c)) }
            acc += c
        }
        return 255
    }

    /// Steps 2-4 for one vote peak: every reading of an outline around it (`outermost` chooses among them).
    static func examine(seed: Vec2, rmin: Double, rmax: Double, intrinsics K: CameraIntrinsics?, up: Vec2,
                        rim: inout RimMeasure, options o: Options, trace: ((String) -> Void)? = nil) -> [Reading] {
        let Fs = LocalFrame(at: seed, intrinsics: K, up: up)
        // the radius range in the frame's own units (the frame looks straight at the candidate)
        let sMin = rmin / Fs.stretch, sMax = rmax / Fs.stretch
        rim.measure(Fs, lo: sMin * 0.7, hi: sMax * 1.15, tol: 0.15)
        // start from the centres the crossings agree on (see centerCandidates); of what they lead to, keep the
        // outermost well-supported outline
        // (the upper outline alone also starts from the centres its own crossings agree on: where the lower half
        // blends in, the whole rim's crossings can agree on a circle inscribed in the outline)
        let starts = rim.centerCandidates(reach: o.centerReach, maxRadius: sMax * 1.15)
        var upperStarts = rim.centerCandidates(reach: o.centerReach, maxRadius: sMax * 1.15, half: .upper)
        upperStarts.removeAll { u in starts.contains { ($0.0 - u.0) * ($0.0 - u.0) + ($0.1 - u.1) * ($0.1 - u.1) < 0.36 } }
        var results: [Reading] = []
        for ((x, y), modes) in starts.map({ ($0, Set<Reading.Mode>([.full, .lower, .upper])) }) + upperStarts.map({ ($0, Set<Reading.Mode>([.upper])) }) {
            let F0 = x == 0 && y == 0 ? Fs : LocalFrame(at: Fs.image(x, y), intrinsics: K, up: up)
            trace?(String(format: "start (%.1f, %.1f) from the seed", x, y))
            for c in examine(from: F0, sMin: sMin, sMax: sMax, intrinsics: K, up: up, rim: &rim, options: o, modes: modes, trace: trace) {
                trace?("  -> \(c.circle) (\(c.mode))")
                results.append(c)
            }
        }
        return results
    }

    /// One reading of a ball's outline: the circle, and which part of the outline it rests on.
    struct Reading {
        enum Mode { case full, lower, upper }
        var circle: BallCircle
        var mode: Mode
        /// the standard error of the radius (pixels, local frame)
        var radiusError: Double
        /// the share of the upper and of the lower spokes on which the outline was found
        var upperShare = 0.0, lowerShare = 0.0
        /// the rim points the circle was fitted to (image coordinates), and which lie on upper and on lower spokes
        var points: [Vec2] = []
        var onUpper: [Bool] = []
        var onLower: [Bool] = []
    }

    /// Of several readings of one ball, the one that gives its outline. A ball's outline is the outermost circle its
    /// edges form: reflections' edges, the near edge of a finger over it and the boundary of a part that blends into
    /// what it reflects all lie inside it.
    /// 1. Of the readings of the whole outline, those with at least 80% of the best support, the largest (a dark band
    ///    reflected inside the top can pair up with the lower rim into a smaller circle that more spokes cross); if
    ///    there are none, the same of the lower half's readings, else of the upper outline's.
    /// 2. Where that is a reading of the whole outline, a reading of one half replaces it only on direct evidence that
    ///    the other half of the whole reading's points lies inside the outline (`liesInside`): seen from above, the top
    ///    of a polished ball can blend into the floor it reflects at a grazing angle, with the edges of what it reflects
    ///    and of the fingers just inside the outline; or the lower half blends in, and the whole reading is a circle
    ///    inscribed in the outline, through its top and the edge of the reflected floor. The lower half's reading is
    ///    tried first, then the upper outline's (14 of the 24 upper spokes, the web app's partial find); either must
    ///    enclose the whole reading by more than the fits' scatter and find the outline on its half's spokes about as
    ///    often. Without such evidence the whole reading stands, however the half readings come out (their fits on half
    ///    the spokes are looser, and a half reading larger by chance would make the ball too large).
    /// 3. Where there is no reading of the whole outline, a lower half's reading that encloses the chosen one (by more
    ///    than the fits' scatter) and finds the outline on its half's spokes about as often replaces it; then the same
    ///    for the upper outline's, unless a lower half's reading is the same circle.
    /// The result is `partial` unless it is a reading of the whole outline.
    static func outermost(_ finds: [Reading], intrinsics K: CameraIntrinsics? = nil, up: Vec2 = Vec2(0, -1)) -> Reading? {
        func largestWellSupported(_ fs: [Reading]) -> Reading? {
            guard let top = fs.map(\.circle.support).max() else { return nil }
            return fs.filter { Double($0.circle.support) >= 0.8 * Double(top) }.max {
                $0.circle.radius != $1.circle.radius ? $0.circle.radius < $1.circle.radius : $0.circle.support < $1.circle.support
            }
        }
        let fulls = finds.filter { $0.mode == .full }, lowers = finds.filter { $0.mode == .lower }, uppers = finds.filter { $0.mode == .upper }
        guard var best = largestWellSupported(fulls) ?? largestWellSupported(lowers) ?? largestWellSupported(uppers) else { return nil }
        if best.mode == .full {
            // the half readings that enclose the whole one with direct evidence that the other half lies inside them,
            // where the whole outline is not one circle
            let w = best
            func claims(_ fs: [Reading]) -> [Reading] { fs.filter { encloses($0, w) && liesInside(w, of: $0, intrinsics: K, up: up) } }
            // the lower half first: seen from above, the top of a held polished ball can blend into the floor it
            // reflects and is covered by the fingers, and a circle fitted to that flattened top alone then reads as a
            // larger one centred lower
            for fs in [lowers, uppers] where !isCircle(w, intrinsics: K, up: up) {
                if let h = claims(fs).filter({ accountsForItsHalf($0, as: w) }).max(by: { $0.circle.radius < $1.circle.radius }) {
                    best = h
                    break
                }
            }
        } else {
            func replace(from fs: [Reading]) {
                while let f = fs.filter({ encloses($0, best) && accountsForItsHalf($0, as: best) }).max(by: { $0.circle.radius < $1.circle.radius }) { best = f }
            }
            replace(from: lowers)
            if best.mode != .lower && !lowers.contains(where: { agrees($0, best) }) { replace(from: uppers) }
        }
        best.circle.partial = best.mode != .full
        return best
    }

    /// Direct evidence that the half reading `h` gives the outline rather than the whole reading `w`: measured from h's
    /// circle (in a frame looking straight at it), w's points on the other half lie further inside it than those on
    /// h's own half, the difference of their mean distances from it more than three standard errors. The standard
    /// error counts the points' scatter (each no less than a quarter pixel) and the uncertainty of h's circle where it
    /// is carried over to the other half: fitted to half the outline, its centre and radius trade off along up, so it
    /// is known far less well there than on its own half.
    static func liesInside(_ w: Reading, of h: Reading, intrinsics K: CameraIntrinsics?, up: Vec2) -> Bool {
        guard h.mode != .full, w.points.count == w.onUpper.count, w.points.count == w.onLower.count, h.points.count >= 5 else { return false }
        let F = LocalFrame(at: h.circle.center, intrinsics: K, up: up)
        let s = h.circle.radius / F.stretch
        // h's circle in its frame: centre (0, 0), radius s; the covariance of (centre x, centre y, radius) from its points
        var M = [Double](repeating: 0, count: 9), e2 = 0.0
        for p in h.points {
            let q = F.local(p), d = max(1e-9, q.length)
            let g = [-q.x / d, -q.y / d, -1.0]
            for a in 0..<3 { for b in 0..<3 { M[a * 3 + b] += g[a] * g[b] } }
            e2 += (d - s) * (d - s)
        }
        guard let inv = invert3(M) else { return false }
        let s2h = max(e2 / Double(h.points.count - 3), 0.0625)
        // w's points (in the order of their spokes): their distances from h's circle, and the gradient of each half's
        // mean with respect to h's circle
        let order = w.points.indices.sorted { atan2(F.local(w.points[$0]).y, F.local(w.points[$0]).x) < atan2(F.local(w.points[$1]).y, F.local(w.points[$1]).x) }
        var same: [Double] = [], other: [Double] = [], sameAt: [Vec2] = [], otherAt: [Vec2] = []
        var gs = [0.0, 0.0, 0.0], go = [0.0, 0.0, 0.0]
        for i in order {
            let q = F.local(w.points[i]), d = max(1e-9, q.length)
            let g = [-q.x / d, -q.y / d, -1.0]
            if h.mode == .lower ? w.onLower[i] : w.onUpper[i] { same.append(d - s); sameAt.append(q); for k in 0..<3 { gs[k] += g[k] } }
            if h.mode == .lower ? w.onUpper[i] : w.onLower[i] { other.append(d - s); otherAt.append(q); for k in 0..<3 { go[k] += g[k] } }
        }
        guard same.count >= 6, other.count >= 6, let (ms, vs) = Self.meanAndError(same, at: sameAt),
              let (mo, vo) = Self.meanAndError(other, at: otherAt) else { return false }
        let g = (0..<3).map { go[$0] / Double(other.count) - gs[$0] / Double(same.count) }
        var vh = 0.0
        for a in 0..<3 { for b in 0..<3 { vh += g[a] * inv[a * 3 + b] * g[b] } }
        return mo - ms < -3 * (vs + vo + s2h * vh).squareRoot()
    }

    /// Whether the whole reading's points are those of one circle: their squared distances from it, in units of the
    /// quarter pixel to which an edge can be placed, sum to no more than a chi-square variable with n - 3 degrees of
    /// freedom exceeds once in 740 (three standard deviations; Wilson-Hilferty approximation).
    static func isCircle(_ w: Reading, intrinsics K: CameraIntrinsics?, up: Vec2) -> Bool {
        let n = w.points.count
        guard n > 3 else { return true }
        let F = LocalFrame(at: w.circle.center, intrinsics: K, up: up)
        let s = w.circle.radius / F.stretch
        let chi2 = w.points.reduce(0) { let e = F.local($1).length - s; return $0 + e * e } / 0.0625
        return chi2 <= chiSquareBound(Double(n - 3))
    }

    /// The value a chi-square variable with `v` degrees of freedom exceeds once in 740 (three standard deviations), by
    /// the Wilson-Hilferty approximation.
    static func chiSquareBound(_ v: Double) -> Double {
        guard v > 0 else { return 0 }
        let a = 2 / (9 * v)
        return v * pow(1 - a + 3 * a.squareRoot(), 3)
    }

    /// The mean of distances measured at rim points on neighbouring spokes (`at`, in their order round the rim), and its
    /// variance. The measurement noise is what a circle fitted to these points alone leaves (so the systematic shape of
    /// this stretch of rim is not counted as noise), each no less than a quarter pixel; on a mirror ball the
    /// reflections shift the edges found along the rim together over several spokes, so neighbouring values are
    /// correlated, and with lag-one correlation p of that noise the mean has the precision of n (1 - p) / (1 + p)
    /// independent values (the usual first-order autoregressive estimate), never more than n.
    static func meanAndError(_ a: [Double], at pts: [Vec2]) -> (Double, Double)? {
        let n = Double(a.count), m = a.reduce(0, +) / n
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard pts.count == a.count,
              let c = xs.withUnsafeBufferPointer({ X in ys.withUnsafeBufferPointer { Y in circleFit(X, Y, count: pts.count) } }) else { return nil }
        let e = pts.map { ($0 - Vec2(c.x, c.y)).length - c.r }
        var c0 = 0.0, c1 = 0.0
        for i in e.indices { c0 += e[i] * e[i]; if i + 1 < e.count { c1 += e[i] * e[i + 1] } }
        let p = c0 > 1e-12 ? min(0.9, max(0, c1 / c0)) : 0
        let nEff = max(1, n * (1 - p) / (1 + p))
        return (m, max(c0 / max(1, n - 3), 0.0625) / nEff)
    }

    /// Inverse of a 3x3 matrix (row-major); nil if singular.
    static func invert3(_ m: [Double]) -> [Double]? {
        let c00 = m[4] * m[8] - m[5] * m[7], c01 = m[5] * m[6] - m[3] * m[8], c02 = m[3] * m[7] - m[4] * m[6]
        let det = m[0] * c00 + m[1] * c01 + m[2] * c02
        let scale = abs(m[0]) + abs(m[4]) + abs(m[8])
        guard abs(det) > 1e-12 * max(1, scale * scale * scale) else { return nil }
        let inv = [c00, m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
                   c01, m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
                   c02, m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]]
        return inv.map { $0 / det }
    }

    /// Whether two readings give the same circle, within the fits' scatter.
    static func agrees(_ a: Reading, _ b: Reading) -> Bool {
        abs(a.circle.radius - b.circle.radius) < margin(a, b)
            && a.circle.center.distance(to: b.circle.center) < max(1, 0.06 * max(a.circle.radius, b.circle.radius))
    }

    /// How much two readings' radii must differ to be told apart: three standard errors of the difference, and at
    /// least half a pixel.
    static func margin(_ a: Reading, _ b: Reading) -> Double {
        max(0.5, 3 * (a.radiusError * a.radiusError + b.radiusError * b.radiusError).squareRoot())
    }

    /// Whether the half reading `a` finds the outline on its half of the spokes about as often as reading `b` does
    /// there (one spoke fewer at most): only then is it the better account of that half.
    static func accountsForItsHalf(_ a: Reading, as b: Reading) -> Bool {
        a.mode == .lower ? a.lowerShare >= b.lowerShare - 0.05 : a.upperShare >= b.upperShare - 0.05
    }

    /// Whether reading `a` encloses reading `b`: larger by more than the fits' scatter (`margin`), and `b` lies inside
    /// it give or take the rim measurement's tolerance (6% of the radius, at least a pixel).
    static func encloses(_ a: Reading, _ b: Reading) -> Bool {
        a.circle.radius >= b.circle.radius + margin(a, b)
            && a.circle.center.distance(to: b.circle.center) + b.circle.radius <= a.circle.radius + max(1, 0.06 * a.circle.radius)
    }

    /// Steps 2-4 from one start: the rim measured around the frame's centre. Returns every reading of the outline that
    /// passes: the whole outline, its lower half and its upper half; `outermost` chooses among them.
    static func examine(from F0: LocalFrame, sMin: Double, sMax: Double, intrinsics K: CameraIntrinsics?, up: Vec2,
                        rim: inout RimMeasure, options o: Options, modes: Set<Reading.Mode> = [.full, .lower, .upper],
                        trace: ((String) -> Void)?) -> [Reading] {
        func fmt(_ c: (x: Double, y: Double, r: Double)?) -> String {
            c.map { String(format: "(%.2f, %.2f) s %.2f", $0.x, $0.y, $0.r) } ?? "nil"
        }
        var out: [Reading] = []
        // the whole outline
        if modes.contains(.full) { rim.measure(F0, lo: sMin * 0.7, hi: sMax * 1.15, tol: 0.15) }
        // The first fit is rough (from an off-centre start the rim spreads over a range of radii, and a ring reflected
        // inside the ball can pull it in), so its size is checked loosely; the final circle's strictly.
        if modes.contains(.full), rim.count >= 26, let c = rim.robustFit(), c.r >= sMin * 0.85, c.r <= sMax * 1.15 {
            let F1 = LocalFrame(at: F0.image(c.x, c.y), intrinsics: K, up: up)
            rim.measure(F1, lo: c.r * 0.75, hi: c.r * 1.25, tol: 0.06)
            rim.keep(within: max(1, c.r * 0.06), of: (0, 0, c.r))
            let n2 = rim.count
            let c2 = rim.robustFit()
            trace?("full: fit \(fmt(c)) -> pass 2: \(n2) spokes, robust fit \(fmt(c2)) on \(rim.count), rms \(String(format: "%.2f", c2.map { rim.rms($0) } ?? -1)), widest gap \(rim.widestGap()) spokes")
            // the outline shows on at least 80% of the rim: a clear ball; and at least that share of its points are edges
            // that run across their spokes (`Options.maxEdgeAngle`): only about two thirds of the directions round a
            // square lie within 30 degrees of a side's normal, so a tile's or a grid cell's outline never passes
            if let c2, abs(c2.r - c.r) <= c.r * 0.1, c2.r >= sMin, c2.r <= sMax, rim.count >= o.minFullSupport,
               Double(rim.acrossCount(F1, maxSkew: o.maxSkew)) >= o.minLowerShare * Double(rim.count) {
                let (p, r) = F1.imageCircle(c2.x, c2.y, c2.r)
                out.append(Reading(circle: BallCircle(center: p, radius: r, support: rim.count, partial: false), mode: .full,
                                   radiusError: rim.radiusError(c2) * r / c2.r, upperShare: rim.upperShare, lowerShare: rim.lowerShare,
                                   points: (0..<rim.count).map { F1.image(rim.xs[$0], rim.ys[$0]) },
                                   onUpper: Array(rim.isUp[0..<rim.count]), onLower: Array(rim.isLow[0..<rim.count])))
            }
        }
        // The lower half alone (not in the web app): seen from above, the top of a polished ball reflects the floor
        // beyond it at a grazing angle and can blend into it, and the fingers holding it cover the top. Nothing covers
        // the lower half, so the share of it that must show is the whole outline's (80%).
        if modes.contains(.lower) {
            rim.measure(F0, lo: sMin * 0.7, hi: sMax * 1.15, tol: 0.15, half: .lower)
            rim.keepLower()
            trace?("lower: \(rim.count) of \(rim.lowerSpokes) spokes, fit \(fmt(rim.fit()))")
        }
        if modes.contains(.lower), Double(rim.count) >= o.minLowerShare * Double(rim.lowerSpokes), let c = rim.robustFit(),
           c.r >= sMin * 0.85, c.r <= sMax * 1.15 {
            let F1 = LocalFrame(at: F0.image(c.x, c.y), intrinsics: K, up: up)
            rim.measure(F1, lo: c.r * 0.75, hi: c.r * 1.25, tol: 0.06, half: .lower, maxSkew: o.maxSkew)
            rim.keep(within: max(1, c.r * 0.06), of: (0, 0, c.r))
            rim.keepLower()
            let c2 = rim.robustFit()
            trace?("lower pass 2: \(rim.count) of \(rim.lowerSpokes) spokes, robust fit \(fmt(c2)), rms \(String(format: "%.2f", c2.map { rim.rms($0) } ?? -1))")
            if let c2, Double(rim.count) >= o.minLowerShare * Double(rim.lowerSpokes), abs(c2.r - c.r) <= c.r * 0.1, c2.r >= sMin, c2.r <= sMax,
               rim.rms(c2) <= o.maxUpperRms, looksLikeMirror(F1, c2, rim.luma, o, trace: trace) {
                let (p, r) = F1.imageCircle(c2.x, c2.y, c2.r)
                out.append(Reading(circle: BallCircle(center: p, radius: r, support: rim.count, partial: true), mode: .lower,
                                   radiusError: rim.radiusError(c2) * r / c2.r, upperShare: rim.upperShare, lowerShare: rim.lowerShare,
                                   points: (0..<rim.count).map { F1.image(rim.xs[$0], rim.ys[$0]) },
                                   onUpper: Array(rim.isUp[0..<rim.count]), onLower: Array(rim.isLow[0..<rim.count])))
            }
        }
        // the upper outline only (the web app's partial find): held above the floor and seen from above, a mirror ball's
        // lower half reflects the very floor that lies behind it
        guard modes.contains(.upper) else { return out }
        rim.measure(F0, lo: sMin * 0.7, hi: sMax * 1.15, tol: 0.15, half: .upper)
        rim.keepUpper()
        trace?("upper: \(rim.count) spokes, fit \(fmt(rim.fit()))")
        guard rim.count >= o.minUpperSeed, let c = rim.fit(), c.r >= sMin * 0.85, c.r <= sMax * 1.15 else { return out }
        let F1 = LocalFrame(at: F0.image(c.x, c.y), intrinsics: K, up: up)
        rim.measure(F1, lo: c.r * 0.75, hi: c.r * 1.25, tol: 0.06, half: .upper, maxSkew: o.maxSkew)
        rim.keep(within: max(1, c.r * 0.06), of: (0, 0, c.r))
        let fit2 = rim.fit()
        trace?("upper pass 2: \(rim.count) spokes (\(rim.upperCount) upper), fit \(fmt(fit2)), rms \(String(format: "%.2f", fit2.map { rim.rms($0) } ?? -1))")
        // 14 of the 24 upper spokes (the fingers hide the top), on a tight circle
        guard rim.upperCount >= o.minUpperSupport, let c2 = fit2, abs(c2.r - c.r) <= c.r * 0.1,
              rim.rms(c2) <= o.maxUpperRms, looksLikeMirror(F1, c2, rim.luma, o, trace: trace) else { return out }
        let support = rim.count
        let cr = rim.robustFit(innerLimit: o.innerLimit) ?? c2
        guard cr.r >= sMin, cr.r <= sMax else { return out }
        let (p, r) = F1.imageCircle(cr.x, cr.y, cr.r)
        out.append(Reading(circle: BallCircle(center: p, radius: r, support: support, partial: true), mode: .upper,
                           radiusError: rim.radiusError(cr) * r / cr.r, upperShare: rim.upperShare, lowerShare: rim.lowerShare,
                           points: (0..<rim.count).map { F1.image(rim.xs[$0], rim.ys[$0]) },
                           onUpper: Array(rim.isUp[0..<rim.count]), onLower: Array(rim.isLow[0..<rim.count])))
        return out
    }

    /// The mirror test: the upper half reflects the room above, so it holds a clear highlight well above the
    /// background just outside, and plenty of light-and-dark detail, unlike a dark lid or a plain disc.
    /// With `allAround` the whole inside and the whole surround are sampled instead of the upper half's: for a find
    /// whose whole outline was read, a polished ball reflects the room in its upper half and the floor in its lower
    /// half, so its inside is never plain either way.
    static func looksLikeMirror(_ F: LocalFrame, _ c: (x: Double, y: Double, r: Double), _ luma: Plane, _ o: Options,
                                allAround: Bool = false, trace: ((String) -> Void)?) -> Bool {
        var mx: Float = 0, s1: Float = 0, s2: Float = 0, n: Float = 0, bg: Float = 0, nb: Float = 0
        for k in 0..<spokeCount {
            let (ca, sa) = spokeDirections[k]
            if !allAround && ca * F.up.x + sa * F.up.y <= 0.2 { continue }
            for f in insideFractions {
                let v = luma.sample(F.image(c.x + ca * c.r * f, c.y + sa * c.r * f))
                mx = max(mx, v); s1 += v; s2 += v * v; n += 1
            }
            for f in outsideFractions { bg += luma.sample(F.image(c.x + ca * c.r * f, c.y + sa * c.r * f)); nb += 1 }
        }
        guard n > 0, nb > 0 else { return false }
        let mu = s1 / n, sd = max(0, s2 / n - mu * mu).squareRoot()
        bg /= nb
        trace?(String(format: "mirror: brightest %.0f, background %.0f, sd %.1f", mx, bg, sd))
        return mx >= bg + o.minHighlight && sd >= o.minMirrorDetail
    }

    /// Whether a found outline is a sphere's or that of a flat round thing lying level (see `flatness`).
    struct Flatness {
        /// spokes on which the whole outline was found, in the frame where a sphere is round and in the frame where a
        /// level disc is
        var roundSupport: Int
        var flatSupport: Int
        /// the scatter (rms, local pixels) of each outline about its circle in its own frame
        var roundRms: Double
        var flatRms: Double
        /// fitted, in the sphere's frame, to the whole outline (nil where neither frame found one that is a circle there):
        /// its foreshortening along up (local pixels: half of the radius across up minus the radius along up), with its
        /// standard error
        var squash: Double?
        var error: Double?
        /// the foreshortening a flat round thing lying level, with the same mean radius, shows there
        var levelDisc: Double
        /// cosine of the angle between the line of sight and the vertical
        var cosine: Double
        /// A flat round thing lying level: the whole outline (found in whichever frame makes it tighter) is foreshortened
        /// along up nearer what a level disc would show than not at all (each hypothesis predicts one value; this is the
        /// better fit of the two). Without a whole outline that is a circle in either frame there is no telling, and the
        /// find stands.
        var isLevelDisc: Bool {
            if let squash { return squash > levelDisc / 2 }
            return false
        }
    }

    /// A sphere's outline is a circle in a camera turned to look straight at it, whichever way it is seen; a flat round
    /// thing (a sticker, a lid, a coaster) lying on a level floor or table is an ellipse there, shortened along the
    /// world's up by the cosine of the angle between the line of sight and the vertical. Its outline is looked for in
    /// both frames, the one in which a sphere is round and the one stretched along up in which a level disc is (the
    /// whole outline, as a full reading: outermost well-supported radius, robust circle, then measured again tightly;
    /// only crossings whose edge runs across the spoke). Of the two, the outline that is whole and a circle in its own
    /// frame (`isCircle`'s test), the tighter if both are, is then fitted, robustly, with a circle plus the two
    /// components of an ellipse's elongation (along the world's up and at 45 degrees to it): a sphere's shows none along
    /// up, a level disc's (1 - k) / (1 + k) of its mean radius, k the cosine of the line of sight's angle to the
    /// vertical. Nil where gravity is unknown or the line of sight is vertical.
    static func flatness(luma: Plane, circle: BallCircle, intrinsics K: CameraIntrinsics, down: Vec3, rim: inout RimMeasure,
                         options o: Options, trace: ((String) -> Void)? = nil) -> Flatness? {
        let up3 = -down.normalized
        guard up3.isFinite, up3.length > 0.5 else { return nil }
        let F = LocalFrame(at: circle.center, intrinsics: K, up: Vec2(0, -1))
        guard F.camera else { return nil }
        // the world's up in a frame, and the cosine of the line of sight's angle to the vertical
        func level(_ G: LocalFrame) -> (u: Vec2, k: Double)? {
            let u0 = Vec2(up3.dot(G.e1), up3.dot(G.e2))
            return u0.length > 1e-6 ? (u0.normalized, abs(up3.dot(G.c))) : nil
        }
        // looking straight up or down: a level disc is not foreshortened either
        guard let (u, cosA) = level(F), cosA < 0.999 else { return nil }
        let s = circle.radius / F.stretch
        func sphereFrame(_ p: Vec2) -> LocalFrame { LocalFrame(at: p, intrinsics: K, up: Vec2(0, -1)) }
        func discFrame(_ p: Vec2) -> LocalFrame {
            let G = LocalFrame(at: p, intrinsics: K, up: Vec2(0, -1))
            return level(G).map { G.squashed(along: $0.u, by: $0.k) } ?? G
        }
        // the whole outline seen from a frame, from the centres its crossings agree on: its points (in F), how many
        // spokes find it and its scatter about its circle (in that frame)
        func outline(_ frame: (Vec2) -> LocalFrame, lo: Double, hi: Double, alongUp: Double = 0) -> (points: [Vec2], support: Int, rms: Double)? {
            let F0 = frame(circle.center)
            rim.measure(F0, lo: lo, hi: hi, tol: 0.15, maxSkew: o.maxSkew)
            var starts = rim.centerCandidates(reach: o.centerReach, maxRadius: hi).map { F0.image($0.0, $0.1) }
            if alongUp > 0 {
                // the best centre along up, then the centres the crossings agree on around it
                let (x, y) = rim.centerAlong(F0.up, range: alongUp, maxRadius: hi)
                let Fu = frame(F0.image(x, y))
                rim.measure(Fu, lo: lo, hi: hi, tol: 0.15, maxSkew: o.maxSkew)
                starts += rim.centerCandidates(reach: o.centerReach, maxRadius: hi).map { Fu.image($0.0, $0.1) }
            }
            var best: (points: [Vec2], support: Int, rms: Double)? = nil
            for p in starts {
                let Fa = frame(p)
                rim.measure(Fa, lo: lo, hi: hi, tol: 0.15, maxSkew: o.maxSkew)
                guard rim.count >= 10, let c = rim.robustFit() else { continue }
                let F1 = frame(Fa.image(c.x, c.y))
                rim.measure(F1, lo: c.r * 0.75, hi: c.r * 1.25, tol: 0.06, maxSkew: o.maxSkew)
                rim.keep(within: max(1, c.r * 0.06), of: (0, 0, c.r))
                guard rim.count >= 10, let c2 = rim.robustFit() else { continue }
                let rms = rim.rms(c2)
                if let b = best, b.support > rim.count || (b.support == rim.count && b.rms <= rms) { continue }
                best = ((0..<rim.count).map { F.local(F1.image(rim.xs[$0], rim.ys[$0])) }, rim.count, rms)
            }
            return best
        }
        let round = outline(sphereFrame, lo: s * 0.6, hi: s * 1.4)
        // A find from part of a level disc's outline rests on an arc of its ellipse, and the circle through that arc can
        // be centred well away from the ellipse's centre along up: up to a (1/k - k) for semi-axes a and k a, which the
        // level disc's frame stretches by 1/k. So there its centre is also looked for along up that far (the circle
        // radius standing in for a), besides near the find's own centre.
        let flat = outline(discFrame, lo: 1.5, hi: min(3, 1.4 / cosA) * s, alongUp: min(3, 1 / (cosA * cosA) - 1) * s)
        var fl = Flatness(roundSupport: round?.support ?? 0, flatSupport: flat?.support ?? 0, roundRms: round?.rms ?? .infinity,
                          flatRms: flat?.rms ?? .infinity, squash: nil, error: nil, levelDisc: 0, cosine: cosA)
        // the elongation of the whole outline, fitted about the points' own circle in the sphere's frame: of the outlines
        // that are whole (on at least `minFullSupport` spokes) and a circle in their own frame (`isCircle`'s test), the
        // tighter one
        func isWholeCircle(_ ol: (points: [Vec2], support: Int, rms: Double)) -> Bool {
            let n = Double(ol.support)
            return ol.support >= o.minFullSupport && n * ol.rms * ol.rms <= 0.0625 * chiSquareBound(n - 3)
        }
        let whole = [round, flat].compactMap { $0 }.filter(isWholeCircle).min { $0.rms < $1.rms }
        if let whole, let (sq, err, r0) = elongation(whole.points, up: u) {
            fl.squash = sq; fl.error = err; fl.levelDisc = r0 * (1 - cosA) / (1 + cosA)
        }
        trace?(String(format: "flatness: whole outline on %d spokes in the sphere's frame (rms %.2f), %d in a level disc's (rms %.2f); squash %@, a level disc's %.2f (cos %.2f)%@",
                      fl.roundSupport, fl.roundRms, fl.flatSupport, fl.flatRms,
                      fl.squash.map { String(format: "%+.2f +- %.2f px", $0, fl.error ?? 0) } ?? "-", fl.levelDisc, cosA, fl.isLevelDisc ? ": level disc" : ""))
        return fl
    }

    /// Robust least-squares fit of rho = r0 + x0 cos t + y0 sin t + a cos 2p + b sin 2p to points around their own
    /// circle (t the point's direction, p its angle from the direction across the unit `up`): the elongation along up
    /// `a` (positive: shorter along up), its standard error and the mean radius r0.
    static func elongation(_ pts: [Vec2], up u: Vec2) -> (Double, Double, Double)? {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let c0 = xs.withUnsafeBufferPointer({ X in ys.withUnsafeBufferPointer { Y in circleFit(X, Y, count: pts.count) } }) else { return nil }
        var keep = [Bool](repeating: true, count: pts.count)
        var fit: [Double] = [], cov: [Double] = []
        func row(_ q: Vec2) -> (rho: Double, g: [Double])? {
            let x = q.x - c0.x, y = q.y - c0.y, rho = (x * x + y * y).squareRoot()
            guard rho > 1e-9 else { return nil }
            let ct = x / rho, st = y / rho
            let along = ct * u.x + st * u.y, across = -ct * u.y + st * u.x
            return (rho, [1, ct, st, across * across - along * along, 2 * across * along])
        }
        for _ in 0..<6 {
            var M = [Double](repeating: 0, count: 25), v = [Double](repeating: 0, count: 5)
            var n = 0
            for (i, q) in pts.enumerated() where keep[i] {
                guard let (rho, g) = row(q) else { continue }
                for a in 0..<5 { v[a] += g[a] * rho; for b in 0..<5 { M[a * 5 + b] += g[a] * g[b] } }
                n += 1
            }
            guard n >= 10, let inv = Self.invert5(M) else { return nil }
            fit = (0..<5).map { a in (0..<5).reduce(0) { $0 + inv[a * 5 + $1] * v[$1] } }
            // residuals, and the points far off dropped (2.5 robust standard deviations, at least half a pixel)
            var e: [Double] = [], idx: [Int] = []
            for (i, q) in pts.enumerated() where keep[i] {
                guard let (rho, g) = row(q) else { continue }
                e.append(rho - (0..<5).reduce(0) { $0 + fit[$1] * g[$1] })
                idx.append(i)
            }
            let med = RimMeasure.median(e), mad = RimMeasure.median(e.map { abs($0 - med) })
            let lim = max(0.5, 2.5 * 1.4826 * mad)
            var dropped = 0
            for (j, i) in idx.enumerated() where abs(e[j]) > lim { keep[i] = false; dropped += 1 }
            // the points' scatter, but no less than a quarter pixel each (as RimMeasure.radiusError)
            let rss = e.reduce(0) { $0 + $1 * $1 }
            let s2 = max(rss / Double(max(1, e.count - 5)), 0.0625)
            cov = inv.map { $0 * s2 }
            if dropped == 0 || e.count - dropped < 10 { break }
        }
        return (fit[3], cov[3 * 5 + 3].squareRoot(), fit[0])
    }

    /// Inverse of a symmetric positive-definite 5x5 matrix (row-major), by Gauss-Jordan elimination; nil if singular.
    static func invert5(_ m: [Double]) -> [Double]? {
        var a = m, inv = [Double](repeating: 0, count: 25)
        for i in 0..<5 { inv[i * 5 + i] = 1 }
        let scale = (0..<5).reduce(0.0) { max($0, abs(m[$1 * 5 + $1])) }
        for c in 0..<5 {
            var p = c
            for r in (c + 1)..<5 where abs(a[r * 5 + c]) > abs(a[p * 5 + c]) { p = r }
            guard abs(a[p * 5 + c]) > 1e-12 * max(1, scale) else { return nil }
            if p != c { for k in 0..<5 { a.swapAt(p * 5 + k, c * 5 + k); inv.swapAt(p * 5 + k, c * 5 + k) } }
            let d = a[c * 5 + c]
            for k in 0..<5 { a[c * 5 + k] /= d; inv[c * 5 + k] /= d }
            for r in 0..<5 where r != c {
                let f = a[r * 5 + c]
                if f == 0 { continue }
                for k in 0..<5 { a[r * 5 + k] -= f * a[c * 5 + k]; inv[r * 5 + k] -= f * inv[c * 5 + k] }
            }
        }
        return inv
    }

    /// where the mirror test samples along the upper spokes, as fractions of the radius
    static let insideFractions: [Double] = [0.2, 0.33, 0.46, 0.59, 0.72, 0.85]
    static let outsideFractions: [Double] = [1.2, 1.35]

    /// unit directions of the spokes, (cos, sin) of k * 7.5 degrees
    static let spokeDirections: [(Double, Double)] = (0..<spokeCount).map {
        let a = Double($0) * 2 * .pi / Double(spokeCount)
        return (cos(a), sin(a))
    }

    // MARK: circle fits

    /// Least-squares circle through points: algebraic (x^2 + y^2 = 2ax + 2by + c), then a few Gauss-Newton steps on
    /// the geometric distances.
    static func circleFit(_ xs: UnsafeBufferPointer<Double>, _ ys: UnsafeBufferPointer<Double>, count n: Int) -> (x: Double, y: Double, r: Double)? {
        guard n >= 3 else { return nil }
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sz = 0.0, sxz = 0.0, syz = 0.0
        for i in 0..<n {
            let x = xs[i], y = ys[i], z = x * x + y * y
            sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; sz += z; sxz += x * z; syz += y * z
        }
        guard let s = solve3([2 * sxx, 2 * sxy, sx, 2 * sxy, 2 * syy, sy, 2 * sx, 2 * sy, Double(n)], [sxz, syz, sz]) else { return nil }
        let rr = s.2 + s.0 * s.0 + s.1 * s.1
        guard rr > 0 else { return nil }
        var cx = s.0, cy = s.1, r = rr.squareRoot()
        for _ in 0..<5 {
            // J^T J and J^T e for residuals e_i = |p_i - c| - r
            var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, b0 = 0.0, b1 = 0.0, b2 = 0.0
            for i in 0..<n {
                let dx = xs[i] - cx, dy = ys[i] - cy, d = (dx * dx + dy * dy).squareRoot()
                if d < 1e-9 { continue }
                let jx = -dx / d, jy = -dy / d, e = d - r // d e / d(cx, cy, r) = (jx, jy, -1)
                a00 += jx * jx; a01 += jx * jy; a02 -= jx; a11 += jy * jy; a12 -= jy
                b0 -= jx * e; b1 -= jy * e; b2 += e
            }
            guard let st = solve3([a00, a01, a02, a01, a11, a12, a02, a12, Double(n)], [b0, b1, b2]) else { break }
            cx += st.0; cy += st.1; r += st.2
            if abs(st.0) + abs(st.1) + abs(st.2) < 1e-6 { break }
        }
        guard r > 0, r.isFinite, cx.isFinite, cy.isFinite else { return nil }
        return (cx, cy, r)
    }

    /// 3x3 linear solve (row-major), Cramer's rule; nil if singular.
    static func solve3(_ m: [Double], _ b: [Double]) -> (Double, Double, Double)? {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        let scale = abs(m[0]) + abs(m[4]) + abs(m[8])
        guard abs(det) > 1e-12 * max(1, scale * scale * scale) else { return nil }
        let dx = b[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (b[1] * m[8] - m[5] * b[2]) + m[2] * (b[1] * m[7] - m[4] * b[2])
        let dy = m[0] * (b[1] * m[8] - m[5] * b[2]) - b[0] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * b[2] - b[1] * m[6])
        let dz = m[0] * (m[4] * b[2] - b[1] * m[7]) - m[1] * (m[3] * b[2] - b[1] * m[6]) + b[0] * (m[3] * m[7] - m[4] * m[6])
        return (dx / det, dy / det, dz / det)
    }
}

/// Step 1: every strong edge pixel in the region votes for the centres along its gradient direction, at each radius,
/// on a grid of 2x2-pixel cells (cell (i, j) covers [ox + 2i, ox + 2i + 2) x [oy + 2j, oy + 2j + 2)).
struct Votes {
    var acc: [UInt32]
    let aw: Int, ah: Int
    let ox: Double, oy: Double

    init?(luma: Plane, roi: ImageRect?, rmin: Double, rmax: Double, options: BallFinder.Options) {
        let W = luma.width, H = luma.height
        let box = (roi ?? ImageRect(width: W, height: H))
        guard !box.isEmpty, box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite else { return nil }
        let X0 = max(1, Int(floor(box.minX))), Y0 = max(1, Int(floor(box.minY)))
        let X1 = min(W - 1, Int(ceil(box.maxX))), Y1 = min(H - 1, Int(ceil(box.maxY)))
        guard X1 - X0 >= 4, Y1 - Y0 >= 4 else { return nil }
        let ox = Double(X0), oy = Double(Y0)
        let aw = (X1 - X0 + 1) / 2 + 1, ah = (Y1 - Y0 + 1) / 2 + 1
        var acc = [UInt32](repeating: 0, count: aw * ah)
        var radii: [Double] = []
        var r = rmin
        while r <= rmax + 1e-9 { radii.append(r); r += max(0.25, options.radiusStep) }
        let g2min = options.minGradient * options.minGradient
        luma.data.withUnsafeBufferPointer { Y in
            acc.withUnsafeMutableBufferPointer { A in
                for y in Y0..<Y1 {
                    let row = y * W
                    let py = Double(y) + 0.5 - oy
                    for x in X0..<X1 {
                        let i = row + x
                        let gx = Y[i + 1] - Y[i - 1], gy = Y[i + W] - Y[i - W]
                        let m2 = gx * gx + gy * gy
                        if m2 < g2min { continue }
                        let m = Double(m2.squareRoot()), ux = Double(gx) / m, uy = Double(gy) / m
                        let px = Double(x) + 0.5 - ox
                        for rr in radii {
                            let dx = ux * rr, dy = uy * rr
                            var qx = px + dx, qy = py + dy
                            if qx >= 0 && qy >= 0 {
                                let cx = Int(qx * 0.5), cy = Int(qy * 0.5)
                                if cx < aw && cy < ah { A[cy * aw + cx] &+= 1 }
                            }
                            qx = px - dx; qy = py - dy
                            if qx >= 0 && qy >= 0 {
                                let cx = Int(qx * 0.5), cy = Int(qy * 0.5)
                                if cx < aw && cy < ah { A[cy * aw + cx] &+= 1 }
                            }
                        }
                    }
                }
            }
        }
        self.acc = acc; self.aw = aw; self.ah = ah; self.ox = ox; self.oy = oy
    }

    /// The strongest cell left (its centre in image coordinates, and its votes), cleared with the cells within
    /// `clear` of it; nil when none has `minVotes`.
    mutating func takePeak(minVotes: Int, clear z: Int) -> (Vec2, Int)? {
        var mi = 0
        var mv: UInt32 = 0
        acc.withUnsafeBufferPointer { A in
            for i in 0..<A.count where A[i] > mv { mv = A[i]; mi = i }
        }
        if mv == 0 || mv < UInt32(max(0, minVotes)) { return nil }
        let ax = mi % aw, ay = mi / aw
        for dy in -z...z {
            let yy = ay + dy
            if yy < 0 || yy >= ah { continue }
            for dx in -z...z { let xx = ax + dx; if xx >= 0 && xx < aw { acc[yy * aw + xx] = 0 } }
        }
        return (Vec2(ox + Double(2 * ax) + 1, oy + Double(2 * ay) + 1), Int(mv))
    }
}

/// A view of the image from a virtual camera turned to look straight at a point (the "local frame"): local (X, Y) are
/// pixels on that camera's image plane (same focal length), centred on the point, X roughly along the image's x. A
/// sphere seen there is an exact circle of radius f tan(angular radius) around its centre. Without intrinsics the frame
/// is the image itself, shifted.
struct LocalFrame {
    let camera: Bool
    let ox: Double, oy: Double            // no intrinsics: the image point of local (0, 0)
    let c: Vec3, a: Vec3, b: Vec3        // local (X, Y) looks along c + a X + b Y (c unit, a and b perpendicular to it, 1/f long)
    let e1: Vec3, e2: Vec3
    let f: Double, fx: Double, fy: Double, cx: Double, cy: Double
    /// RadiusModel.imageCircle stretch at the frame's centre (1 without intrinsics)
    let stretch: Double
    /// the world's up as a unit direction in local coordinates
    let up: Vec2

    init(at p: Vec2, intrinsics: CameraIntrinsics?, up upImage: Vec2) {
        let u = upImage.length > 0 ? upImage.normalized : Vec2(0, -1)
        guard let K = intrinsics else {
            camera = false; ox = p.x; oy = p.y
            c = Vec3(0, 0, 1); a = .zero; b = .zero; e1 = Vec3(1, 0, 0); e2 = Vec3(0, 1, 0)
            f = 1; fx = 1; fy = 1; cx = 0; cy = 0; stretch = 1; up = u
            return
        }
        camera = true; ox = p.x; oy = p.y
        let cc = K.ray(p).normalized
        var y = Vec3(0, 1, 0).rejecting(cc)
        if y.length < 1e-9 { y = Vec3(1, 0, 0).rejecting(cc) }
        let ee2 = y.normalized, ee1 = ee2.cross(cc)
        c = cc; e1 = ee1; e2 = ee2
        f = K.focal; fx = K.fx; fy = K.fy; cx = K.cx; cy = K.cy
        a = ee1 / f; b = ee2 / f
        let cosT = cc.z
        stretch = (1 / cosT + 1 / (cosT * cosT)) / 2
        // the up direction carried into the frame
        let q0 = Self.toLocal(p, c: cc, e1: ee1, e2: ee2, f: f, fx: fx, fy: fy, cx: cx, cy: cy)
        let q1 = Self.toLocal(p + u, c: cc, e1: ee1, e2: ee2, f: f, fx: fx, fy: fy, cx: cx, cy: cy)
        let d = q1 - q0
        up = d.length > 1e-9 ? d.normalized : u
    }

    private init(copying F: LocalFrame, a: Vec3, b: Vec3) {
        camera = F.camera; ox = F.ox; oy = F.oy; c = F.c; self.a = a; self.b = b; e1 = F.e1; e2 = F.e2
        f = F.f; fx = F.fx; fy = F.fy; cx = F.cx; cy = F.cy; stretch = F.stretch; up = F.up
    }

    /// The frame in which local (X, Y) is this frame's point with its component along the unit direction `u` multiplied
    /// by `k`: a round thing seen shortened by `k` along `u` here is a circle there.
    func squashed(along u: Vec2, by k: Double) -> LocalFrame {
        let m00 = 1 - (1 - k) * u.x * u.x, m01 = -(1 - k) * u.x * u.y, m11 = 1 - (1 - k) * u.y * u.y
        return LocalFrame(copying: self, a: a * m00 + b * m01, b: a * m01 + b * m11)
    }

    /// image -> local (for a frame that is not `squashed`)
    func local(_ p: Vec2) -> Vec2 {
        if !camera { return Vec2(p.x - ox, p.y - oy) }
        return Self.toLocal(p, c: c, e1: e1, e2: e2, f: f, fx: fx, fy: fy, cx: cx, cy: cy)
    }

    private static func toLocal(_ p: Vec2, c: Vec3, e1: Vec3, e2: Vec3, f: Double, fx: Double, fy: Double, cx: Double, cy: Double) -> Vec2 {
        let r = Vec3((p.x - cx) / fx, (p.y - cy) / fy, 1), k = r.dot(c)
        guard k > 1e-9 else { return Vec2(.infinity, .infinity) }
        return Vec2(f * r.dot(e1) / k, f * r.dot(e2) / k)
    }

    /// The luma at local (X, Y).
    @inline(__always) func sample(_ luma: Plane, _ X: Double, _ Y: Double) -> Float {
        if !camera { return luma.sample(ox + X, oy + Y) }
        let dx = c.x + a.x * X + b.x * Y, dy = c.y + a.y * X + b.y * Y, dz = c.z + a.z * X + b.z * Y
        return luma.sample(fx * dx / dz + cx, fy * dy / dz + cy)
    }

    /// local -> image
    @inline(__always) func image(_ X: Double, _ Y: Double) -> Vec2 {
        if !camera { return Vec2(ox + X, oy + Y) }
        let dx = c.x + a.x * X + b.x * Y, dy = c.y + a.y * X + b.y * Y, dz = c.z + a.z * X + b.z * Y
        return Vec2(fx * dx / dz + cx, fy * dy / dz + cy)
    }

    /// A circle (X, Y, s) in this frame as seen in the image: the image of its centre and its `imageCircle` radius.
    func imageCircle(_ X: Double, _ Y: Double, _ s: Double) -> (Vec2, Double) {
        if !camera { return (Vec2(ox + X, oy + Y), s) }
        let d = c + a * X + b * Y
        let cosT = d.z / d.length
        let st = (1 / cosT + 1 / (cosT * cosT)) / 2
        // s / f is the tangent of the angular radius (exactly so for a circle centred in the frame; the fitted centre
        // lies within a pixel or two of it, which changes the radius by parts per million)
        return (Vec2(fx * d.x / d.z + cx, fy * d.y / d.z + cy), s * st)
    }
}

/// The rim measurement along the spokes, with its scratch space (allocated once per search).
struct RimMeasure {
    /// which spokes choose the rim's radius: all of them, those pointing up from the centre (in the world), or down
    enum Half { case all, upper, lower }

    let luma: Plane
    var minContrast: Float
    /// radius histograms: bins this wide (pixels); a crossing counts in every bin within `window` of it
    static let binWidth = 0.25
    static let window = 0.5
    let maxPeaks: Int
    var values: [Float]
    var peaks: [Double]
    var peakCount: [Int]
    var hist: [Int]
    var stamp: [Int]
    var gen = 0
    var spokeUp: [Bool]
    var spokeLow: [Bool]
    // the chosen rim points, in the local frame
    var xs: [Double]
    var ys: [Double]
    var isUp: [Bool]
    var isLow: [Bool]
    var spoke: [Int]
    var count = 0

    init(luma: Plane, maxRadius: Double, minContrast: Float) {
        self.luma = luma; self.minContrast = minContrast
        let n = Int(ceil(maxRadius)) + 8
        values = [Float](repeating: 0, count: 2 * n + 16)
        maxPeaks = n + 4 // a spoke's crossings are at least a step apart: never more than half its samples
        peaks = [Double](repeating: 0, count: BallFinder.spokeCount * maxPeaks)
        peakCount = [Int](repeating: 0, count: BallFinder.spokeCount)
        hist = [Int](repeating: 0, count: Int(Double(n + 16) / Self.binWidth) + 8)
        stamp = [Int](repeating: 0, count: hist.count)
        spokeUp = [Bool](repeating: false, count: BallFinder.spokeCount)
        spokeLow = spokeUp
        xs = [Double](repeating: 0, count: BallFinder.spokeCount)
        ys = xs
        isUp = spokeUp
        isLow = spokeUp
        spoke = [Int](repeating: 0, count: BallFinder.spokeCount)
    }

    var upperCount: Int { (0..<count).reduce(0) { $0 + (isUp[$1] ? 1 : 0) } }
    /// the share of the upper (lower) spokes of the last frame measured that hold a point
    var upperShare: Double { Double(upperCount) / Double(max(1, spokeUp.reduce(0) { $0 + ($1 ? 1 : 0) })) }
    var lowerShare: Double { Double((0..<count).reduce(0) { $0 + (isLow[$1] ? 1 : 0) }) / Double(max(1, lowerSpokes)) }
    /// how many spokes point down from the centre (in the last frame measured)
    var lowerSpokes: Int { spokeLow.reduce(0) { $0 + ($1 ? 1 : 0) } }


    /// Along every spoke from the frame's centre, note each edge crossing between radii lo and hi (a local maximum of
    /// the luma difference across 2 px, at least `minContrast`, located to a fraction of a step). Find the radius most
    /// spokes agree on (only the spokes of one `half` if given), take the outermost of the well-supported radii (a
    /// mirror ball is full of reflected rings inside it) and keep each spoke's crossing nearest it, within `tol` of it.
    mutating func measure(_ F: LocalFrame, lo loIn: Double, hi: Double, tol: Double, half: Half = .all, maxSkew: Float = 0,
                          radius fixedRadius: Double? = nil) {
        count = 0
        let lo = max(1.5, loIn)
        guard hi > lo else { for k in 0..<BallFinder.spokeCount { peakCount[k] = 0 }; return }
        let step = 0.5
        let ns = Int(((hi + 0.5 - lo) / step).rounded(.down)) + 1   // radii lo, lo + 0.5, ..., <= hi + 0.5
        let nv = ns + 4                                              // samples from lo - 1 to hi + 1.5
        if values.count < nv { values = [Float](repeating: 0, count: nv) }
        for k in 0..<BallFinder.spokeCount {
            let (ca, sa) = BallFinder.spokeDirections[k]
            spokeUp[k] = ca * F.up.x + sa * F.up.y > 0.01
            spokeLow[k] = ca * F.up.x + sa * F.up.y < -0.01
            // luma along the spoke
            if F.camera {
                let wx = F.a.x * ca + F.b.x * sa, wy = F.a.y * ca + F.b.y * sa, wz = F.a.z * ca + F.b.z * sa
                for i in 0..<nv {
                    let s = lo - 1 + step * Double(i)
                    let dz = F.c.z + wz * s
                    values[i] = luma.sample(F.fx * (F.c.x + wx * s) / dz + F.cx, F.fy * (F.c.y + wy * s) / dz + F.cy)
                }
            } else {
                for i in 0..<nv {
                    let s = lo - 1 + step * Double(i)
                    values[i] = luma.sample(F.ox + ca * s, F.oy + sa * s)
                }
            }
            // crossings
            var np = 0
            var g0: Float = 0, g1: Float = 0
            for j in 0..<ns {
                let g = abs(values[j + 4] - values[j])
                if g1 >= minContrast && g1 >= g0 && g1 > g && np < maxPeaks {
                    // parabola through (g0, g1, g) for the sub-step position of the maximum
                    let den = g0 - 2 * g1 + g
                    let d = den < 0 ? Double(0.5 * (g0 - g) / den) : 0
                    let r = lo + step * (Double(j - 1) + clamp(d, -0.5, 0.5))
                    // the edge must run across the spoke: an outline centred near the frame's centre does, while
                    // texture and reflections cross it at any angle
                    if maxSkew > 0 {
                        let px = ca * r, py = sa * r
                        let gt = abs(F.sample(luma, px - sa, py + ca) - F.sample(luma, px + sa, py - ca))
                        if gt > maxSkew * g1 { g0 = g1; g1 = g; continue }
                    }
                    peaks[k * maxPeaks + np] = r
                    np += 1
                }
                g0 = g1; g1 = g
            }
            peakCount[k] = np
        }
        let rbD: Double
        if let fixedRadius {
            rbD = fixedRadius
        } else {
            let nb = histogram(x: 0, y: 0, half: half, maxRadius: hi + 1)
            var hm = 0
            for i in 0..<nb where hist[i] > hm { hm = hist[i] }
            guard hm > 0 else { return }
            // (the upper outline is often partly hidden by the fingers)
            let need = Double(hm) * (half == .upper ? 0.6 : 0.8)
            var rb = 0
            for i in stride(from: nb - 1, through: 0, by: -1) where Double(hist[i]) >= need { rb = i; break }
            rbD = (Double(rb) + 0.5) * Self.binWidth
        }
        let win = max(1.5, rbD * tol)
        for k in 0..<BallFinder.spokeCount {
            var br = -1.0
            for m in 0..<peakCount[k] {
                let r = peaks[k * maxPeaks + m]
                if abs(r - rbD) <= win && (br < 0 || abs(r - rbD) < abs(br - rbD)) { br = r }
            }
            if br > 0 {
                let (ca, sa) = BallFinder.spokeDirections[k]
                xs[count] = ca * br; ys[count] = sa * br; isUp[count] = spokeUp[k]; isLow[count] = spokeLow[k]; spoke[count] = k
                count += 1
            }
        }
    }

    /// Histogram of the noted crossings' distances from (x, y): each spoke counts once in every bin within `window` of
    /// one of its crossings. Returns the number of bins filled.
    mutating func histogram(x: Double, y: Double, half: Half = .all, maxRadius: Double, window win: Double = RimMeasure.window) -> Int {
        let w = Self.binWidth
        let nb = min(hist.count, Int(maxRadius / w) + 4)
        for i in 0..<nb { hist[i] = 0 }
        for k in 0..<BallFinder.spokeCount where half == .all || (half == .upper ? spokeUp[k] : spokeLow[k]) {
            let (ca, sa) = BallFinder.spokeDirections[k]
            gen += 1
            for m in 0..<peakCount[k] {
                let r = peaks[k * maxPeaks + m]
                let d = x == 0 && y == 0 ? r : ((ca * r - x) * (ca * r - x) + (sa * r - y) * (sa * r - y)).squareRoot()
                let b0 = max(0, Int(((d - win) / w).rounded(.down))), b1 = min(nb - 1, Int(((d + win) / w).rounded(.down)))
                if b0 > b1 { continue }
                for b in b0...b1 where stamp[b] != gen { stamp[b] = gen; hist[b] += 1 }
            }
        }
        return nb
    }

    /// Where to start the rim measurement near the frame's centre (within about `reach` pixels), judged on the
    /// crossings the last `measure` noted: the centre around which the most spokes cross at one radius, and the centre
    /// of the largest circle that at least `share` of that many spokes cross (the outermost-radius rule applied to
    /// centre and radius together). Searched on a 2-pixel grid with a 1-pixel window, then on a 1-pixel grid and half a
    /// pixel around each pick with the half-pixel window. The vote peak can be a few pixels off (its cells are 2 px,
    /// and a hand's edges pull it), and from an off-centre start the rim's crossings spread over a range of radii.
    /// Either start can be wrong: the most-crossed circle can pair the rim's lower half with a reflection's edge inside
    /// the top, and the largest can take in a ball's shadow; both are measured and the finds compared.
    mutating func centerCandidates(reach: Int, maxRadius: Double, share: Double = 0.8, half: Half = .all) -> [(Double, Double)] {
        let mr = maxRadius + Double(reach) + 2
        typealias Pick = (x: Double, y: Double, bin: Int, support: Int, d: Double)
        // most: the best-supported bin anywhere; outer: the outermost bin with `need` spokes
        func most(_ offsets: [(Double, Double)], window: Double) -> Pick {
            var best: Pick = (0, 0, -1, -1, .infinity)
            for (x, y) in offsets {
                let d = x * x + y * y, nb = histogram(x: x, y: y, half: half, maxRadius: mr, window: window)
                for i in 0..<nb where hist[i] > best.support || (hist[i] == best.support && d < best.d) { best = (x, y, i, hist[i], d) }
            }
            return best
        }
        func outer(_ offsets: [(Double, Double)], window: Double, need: Int) -> Pick {
            var best: Pick = (0, 0, -1, 0, .infinity)
            for (x, y) in offsets {
                let d = x * x + y * y, nb = histogram(x: x, y: y, half: half, maxRadius: mr, window: window)
                var b = -1
                for i in stride(from: nb - 1, through: 0, by: -1) where hist[i] >= need { b = i; break }
                if b < 0 { continue }
                if b > best.bin || (b == best.bin && (hist[b] > best.support || (hist[b] == best.support && d < best.d))) {
                    best = (x, y, b, hist[b], d)
                }
            }
            return best
        }
        func around(_ p: Pick, step: Double) -> [(Double, Double)] {
            var o: [(Double, Double)] = []
            for dy in [-step, 0, step] { for dx in [-step, 0, step] { o.append((p.x + dx, p.y + dy)) } }
            return o
        }
        // coarse
        let h = max(1, reach / 2)
        var grid: [(Double, Double)] = []
        for j in -h...h { for i in -h...h { grid.append((Double(2 * i), Double(2 * j))) } }
        let m0 = most(grid, window: 1)
        guard m0.support > 0 else { return [(0, 0)] }
        let o0 = outer(grid, window: 1, need: max(1, Int((Double(m0.support) * share).rounded(.up))))
        // fine: the most-supported start, then the outermost one judged against it
        let m1 = most(around(m0, step: 1), window: Self.window)
        let m2 = most(around(m1, step: 0.5), window: Self.window)
        var starts = [(m2.x, m2.y)]
        if o0.bin >= 0 {
            let need = max(1, Int((Double(m2.support) * share).rounded(.up)))
            let o1 = outer(around(o0, step: 1), window: Self.window, need: need)
            if o1.bin >= 0 {
                // half a pixel around it: the most spokes within half a pixel of its radius
                var fine = (x: o1.x, y: o1.y, support: -1)
                for (x, y) in around(o1, step: 0.5) {
                    let nb = histogram(x: x, y: y, half: half, maxRadius: mr)
                    var s = 0
                    for i in max(0, o1.bin - 2)...max(0, min(nb - 1, o1.bin + 2)) where hist[i] > s { s = hist[i] }
                    if s > fine.support { fine = (x, y, s) }
                }
                if (fine.x - m2.x) * (fine.x - m2.x) + (fine.y - m2.y) * (fine.y - m2.y) >= 0.6 { starts.append((fine.x, fine.y)) }
            }
        }
        return starts
    }

    /// How many of the points are edges that run across their spokes: the luma difference across 2 px along the spoke
    /// at least 1 / maxSkew times that across the spoke (as `measure` checks with `maxSkew`).
    func acrossCount(_ F: LocalFrame, maxSkew: Float) -> Int {
        guard maxSkew > 0 else { return count }
        var n = 0
        for i in 0..<count {
            let (ca, sa) = BallFinder.spokeDirections[spoke[i]]
            let px = xs[i], py = ys[i]
            let g = abs(F.sample(luma, px + ca, py + sa) - F.sample(luma, px - ca, py - sa))
            let gt = abs(F.sample(luma, px - sa, py + ca) - F.sample(luma, px + sa, py - ca))
            if gt <= maxSkew * g { n += 1 }
        }
        return n
    }

    /// Of the points along the unit direction `u` from the frame's centre (up to `range` either way, a pixel apart), the
    /// one around which the most spokes of the last `measure` cross at one radius (the nearer to the centre on a tie).
    mutating func centerAlong(_ u: Vec2, range: Double, maxRadius: Double) -> (Double, Double) {
        var best = (x: 0.0, y: 0.0, support: -1, d: Double.infinity)
        let m = Int(range.rounded(.down))
        guard m > 0 else { return (0, 0) }
        for i in -m...m {
            let x = u.x * Double(i), y = u.y * Double(i), d = abs(Double(i))
            let nb = histogram(x: x, y: y, maxRadius: maxRadius + range + 2)
            var top = 0
            for b in 0..<nb where hist[b] > top { top = hist[b] }
            if top > best.support || (top == best.support && d < best.d) { best = (x, y, top, d) }
        }
        return (best.x, best.y)
    }

    /// Keep only the points within `tol` of a circle.
    mutating func keep(within tol: Double, of c: (x: Double, y: Double, r: Double)) {
        var n = 0
        for i in 0..<count {
            let d = ((xs[i] - c.x) * (xs[i] - c.x) + (ys[i] - c.y) * (ys[i] - c.y)).squareRoot()
            if abs(d - c.r) < tol { move(i, to: n); n += 1 }
        }
        count = n
    }

    /// Keep only the points on upper spokes.
    mutating func keepUpper() {
        var n = 0
        for i in 0..<count where isUp[i] { move(i, to: n); n += 1 }
        count = n
    }

    /// Keep only the points on lower spokes.
    mutating func keepLower() {
        var n = 0
        for i in 0..<count where isLow[i] { move(i, to: n); n += 1 }
        count = n
    }

    private mutating func move(_ i: Int, to n: Int) {
        xs[n] = xs[i]; ys[n] = ys[i]; isUp[n] = isUp[i]; isLow[n] = isLow[i]; spoke[n] = spoke[i]
    }

    /// A circle fit that drops the points far off it (beyond 2.5 robust standard deviations, and at least 0.6 px),
    /// refitting until none is dropped: where a finger covers the rim, or the top of a mirror ball blends into what it
    /// reflects, the crossing nearest the radius is often a reflection or the finger's edge a pixel or two inside.
    mutating func robustFit(innerLimit: Double? = nil) -> (x: Double, y: Double, r: Double)? {
        guard var c = fit() else { return nil }
        var e = [Double](repeating: 0, count: count)
        for _ in 0..<(innerLimit == nil ? 4 : 8) {
            for i in 0..<count { e[i] = ((xs[i] - c.x) * (xs[i] - c.x) + (ys[i] - c.y) * (ys[i] - c.y)).squareRoot() - c.r }
            let med = Self.median(Array(e[0..<count]))
            let mad = Self.median(e[0..<count].map { abs($0 - med) })
            let lim = max(0.6, 2.5 * 1.4826 * mad)
            let limIn = innerLimit.map { min(lim, $0) } ?? lim
            var n = 0
            for i in 0..<count where e[i] <= lim && e[i] >= -limIn { e[n] = e[i]; move(i, to: n); n += 1 }
            if n == count || n < 5 { break }
            count = n
            guard let c2 = fit() else { return nil }
            c = c2
        }
        return c
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// The widest run of spokes (of 48) without a point.
    func widestGap() -> Int {
        guard count > 0 else { return BallFinder.spokeCount }
        var on = [Bool](repeating: false, count: BallFinder.spokeCount)
        for i in 0..<count { on[spoke[i]] = true }
        var best = 0, run = 0
        for k in 0..<(2 * BallFinder.spokeCount) {
            if on[k % BallFinder.spokeCount] { run = 0 } else { run += 1; best = max(best, run) }
        }
        return min(best, BallFinder.spokeCount)
    }

    func fit() -> (x: Double, y: Double, r: Double)? {
        xs.withUnsafeBufferPointer { X in ys.withUnsafeBufferPointer { Y in BallFinder.circleFit(X, Y, count: count) } }
    }

    /// The standard error of a fitted circle's radius from the points' scatter about it (pixels).
    func radiusError(_ c: (x: Double, y: Double, r: Double)) -> Double {
        guard count > 3 else { return .infinity }
        // J^T J for residuals |p_i - c| - r, whose gradient in (cx, cy, r) is (-dx/d, -dy/d, -1)
        var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, e2 = 0.0
        for i in 0..<count {
            let dx = xs[i] - c.x, dy = ys[i] - c.y, d = max(1e-9, (dx * dx + dy * dy).squareRoot())
            let jx = -dx / d, jy = -dy / d
            a00 += jx * jx; a01 += jx * jy; a02 -= jx; a11 += jy * jy; a12 -= jy
            e2 += (d - c.r) * (d - c.r)
        }
        let a22 = Double(count)
        let det = a00 * (a11 * a22 - a12 * a12) - a01 * (a01 * a22 - a12 * a02) + a02 * (a01 * a12 - a11 * a02)
        guard det > 1e-12 else { return .infinity }
        let inv22 = (a00 * a11 - a01 * a01) / det
        // the points' scatter, but no less than a quarter pixel each: an edge's position is not known better than that
        return (max(e2 / Double(count - 3), 0.0625) * inv22).squareRoot()
    }

    func rms(_ c: (x: Double, y: Double, r: Double)) -> Double {
        guard count > 0 else { return .infinity }
        var e2 = 0.0
        for i in 0..<count {
            let d = ((xs[i] - c.x) * (xs[i] - c.x) + (ys[i] - c.y) * (ys[i] - c.y)).squareRoot() - c.r
            e2 += d * d
        }
        return (e2 / Double(count)).squareRoot()
    }
}

extension Bounce {
    /// The image radius (pixels) of a ball whose centre is at `B` (camera axes): the inverse of `ballCenter`.
    public static func imageRadius(ballCenter B: Vec3, intrinsics K: CameraIntrinsics, ball: BallSpec, model: RadiusModel = .imageCircle) -> Double? {
        let d = B.length
        guard B.z > 1e-9, d > ball.radius * 1.0001 else { return nil }
        let tanA = ball.radius / (d * d - ball.radius * ball.radius).squareRoot()
        let c = B.z / d
        let stretch = model == .imageCircle ? (1 / c + 1 / (c * c)) / 2 : 1
        return K.focal * tanA * stretch
    }
}

/// A ball held over the slab: what the image shows, where it is and where it would land.
public struct BallObservation: Equatable {
    /// its outline in the image passed to `update`
    public var circle: BallCircle
    /// its centre in camera (CV) axes, metres
    public var center: Vec3
    /// where it lands on the slab if let go, and from how high (camera axes)
    public var drop: DropPoint
    /// 0 when seen in this image; otherwise how many updates in a row have missed it (it is held over, carried along
    /// with the slab, for a few)
    public var missedUpdates: Int
}

/// Looks for the ball over the slab, frame after frame. Port of the web app's scanBall:
/// - only a ball whose straight drop lands on the slab counts;
/// - a ball found from half its outline (`BallCircle.partial`) is reported only once it shows up on two scans in
///   a row, or where the ball already being followed is;
/// - a ball being followed is looked for in a box around it (the costliest step of a frame otherwise);
/// - its position and size are smoothed while it stays put, and a ball missed for a moment is held over for a few
///   updates.
///
/// Adapted for the phone: the camera's real intrinsics and gravity; the search region and the radius range come from
/// where a ball held 5 cm to 1.5 m over the slab could be (the web app took 0.6-1.6x the size of a ball at the slab's
/// distance, anywhere in the picture); a ball is turned into a position with `Bounce.ballCenter` (`.imageCircle`) and
/// dropped with `Bounce.drop`; and everything remembered from earlier scans is kept relative to the slab, so it stays
/// put while the phone moves (the web app compared image positions). The range of radii can be wide (a ball held high
/// is much nearer the camera than one just over the slab), so it is split into bands of up to 3x, each searched only
/// where balls of that size can be and at a scale that makes them 12-36 px across (`searchBands`); the web app capped
/// the radius at 70 px instead. A followed ball is looked for at 0.7-1.4x its last size.
///
/// Keeps state between calls: use one locator per camera stream, from one queue at a time.
public final class BallLocator {
    public struct Options {
        /// how high over the slab (bottom of the ball over the top face, metres) a ball is looked for; one found lower
        /// is not reported
        public var minHeight: Double = 0.05
        public var maxHeight: Double = 1.5
        /// A ball found from half its outline is reported only this high over the slab or higher (metres). The owner
        /// holds the ball 1-3 ft (0.3-0.9 m) over the slab; the weaker evidence of half an outline is taken only where
        /// a held ball can be, with room for a ball held a little low (two thirds of a foot). A whole outline is taken
        /// down to `minHeight`. (Chosen while looking at testPrintedDiscsBesideAMatEdge, where 0.15 m let printed discs
        /// through; it does nothing against a print whose size implies 0.2 m or more.)
        public var minPartialHeight: Double = 0.2
        /// a followed ball is looked for within this many radii of where it was
        public var followRadii: Double = 4
        /// updates a followed ball may go unseen before it is dropped (the web app allowed 5 scans at 15 a second)
        public var maxMissedUpdates: Int = 2
        /// smoothing of a ball that stays put: share of the new position / radius taken each update
        public var positionGain: Double = 0.5
        public var radiusGain: Double = 0.3
        /// the radius range is searched in bands, each at a reduced scale where its radii are this many pixels and up
        /// to 3x as many (see `searchBands`)
        public var minSearchRadius: Double = 12
        /// a followed ball is looked for at radii within this factor of its last radius
        public var followRadiusFactor: Double = 1.4
        public var finder = BallFinder.Options()
        public init() {}
    }

    public var options: Options
    /// the last observation (nil when no ball is shown)
    public private(set) var current: BallObservation?

    /// a ball remembered relative to the slab: its centre in the slab's axes (along axisU, axisV, normal, from the centre)
    struct Anchored {
        var local: Vec3
        var slab: SlabPose
    }
    private var followed: Anchored?
    private var pendingPartial: Anchored?
    private var missed = 0

    public init(options: Options = Options()) { self.options = options }

    public func reset() {
        current = nil; followed = nil; pendingPartial = nil; missed = 0
    }

    /// Where a ball held between `heights` over the slab (camera axes) would be seen, and how large: its centre's image
    /// position and imageCircle radius for balls over the slab's footprint (within the 5% that still counts as landing
    /// on it) at heights spaced evenly in log height. Only those in view.
    static func searchSamples(intrinsics K: CameraIntrinsics, slab: SlabPose, ball: BallSpec, down: Vec3,
                              heights: ClosedRange<Double>) -> [(p: Vec2, r: Double)] {
        let up = -down.normalized
        guard up.isFinite, up.length > 0.5 else { return [] }
        let R = ball.radius
        var foot: [Vec3] = []
        for su in [-1.05, 0, 1.05] { for sv in [-1.05, 0, 1.05] { foot.append(slab.point(u: su * slab.halfU, v: sv * slab.halfV)) } }
        let n = 40, h0 = max(0.005, heights.lowerBound), h1 = max(h0, heights.upperBound)
        let frame = ImageRect(width: K.width, height: K.height)
        var out: [(p: Vec2, r: Double)] = []
        out.reserveCapacity((n + 1) * foot.count)
        for i in 0...n {
            let h = h0 * pow(h1 / h0, Double(i) / Double(n))
            for P in foot {
                let B = P + up * (h + R)
                guard B.z > 0.05, let p = K.project(B), frame.contains(p),
                      let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball) else { continue }
                out.append((p, r))
            }
        }
        return out
    }

    /// Where to look and what size of ball to expect for a ball held between `heights` over the slab (camera axes):
    /// the image region its centre can be in (padded by the largest radius) and the range of radii (imageCircle sense,
    /// with 15% to spare either way). Nil if no such ball would be in view.
    public static func searchWindow(intrinsics K: CameraIntrinsics, slab: SlabPose, ball: BallSpec, down: Vec3,
                                    heights: ClosedRange<Double>) -> (region: ImageRect, radii: ClosedRange<Double>)? {
        let samples = searchSamples(intrinsics: K, slab: slab, ball: ball, down: down, heights: heights)
        guard let lo = samples.map(\.r).min(), let hi = samples.map(\.r).max() else { return nil }
        let radii = (lo * 0.85)...(hi * 1.15)
        let region = samples.reduce(ImageRect.empty) { $0.union($1.p) }.expanded(by: radii.upperBound * 1.2).clamped(width: K.width, height: K.height)
        return region.isEmpty ? nil : (region, radii)
    }

    /// One part of the search: radii (full-image pixels), where balls of that size can be, and the integer factor the
    /// image is shrunk by before searching it.
    public struct SearchBand: Equatable {
        public var region: ImageRect
        public var radii: ClosedRange<Double>
        public var scale: Int
    }

    /// The search window split by radius: bands spanning up to 3x in radius (the lowest from the smallest radius), each
    /// searched at a scale that makes its smallest radius at least `minSearchRadius` pixels, so a band's radii are
    /// about 12-36 px there (a remainder of less than a quarter of a band is added to the band below it), and only
    /// where its balls can be (padded by its largest radius). Neighbouring bands overlap by 10% in radius.
    public static func searchBands(intrinsics K: CameraIntrinsics, slab: SlabPose, ball: BallSpec, down: Vec3,
                                   heights: ClosedRange<Double>, minSearchRadius m: Double = 12) -> [SearchBand] {
        let samples = searchSamples(intrinsics: K, slab: slab, ball: ball, down: down, heights: heights)
        guard let sLo = samples.map(\.r).min(), let sHi = samples.map(\.r).max() else { return [] }
        return bands(radii: (sLo * 0.85)...(sHi * 1.15), minSearchRadius: m, width: K.width, height: K.height) { lo, hi in
            // where a ball of radius within [lo, hi] can be (each sample with its 15% to spare)
            samples.reduce(ImageRect.empty) { $1.r * 1.15 >= lo && $1.r * 0.85 <= hi ? $0.union($1.p) : $0 }
        }
    }

    /// The band split of a radius range; `centres(lo, hi)` gives the box the centres of balls with those radii lie in.
    static func bands(radii: ClosedRange<Double>, minSearchRadius m: Double, width: Int, height: Int,
                      centres: (Double, Double) -> ImageRect) -> [SearchBand] {
        var out: [SearchBand] = []
        let rHi = radii.upperBound
        var k = max(1, Int(radii.lowerBound / m)), lo = radii.lowerBound
        while lo < rHi && out.count < 12 {
            var hi = min(rHi, 3 * m * Double(k))
            if rHi <= hi * 1.25 { hi = rHi }
            let bandLo = out.isEmpty ? lo : lo * 0.9
            let region = centres(bandLo, hi).expanded(by: hi * 1.2).clamped(width: width, height: height)
            if !region.isEmpty { out.append(SearchBand(region: region, radii: bandLo...hi, scale: k)) }
            lo = hi; k *= 3
        }
        return out
    }

    /// One scan. `slab` is the slab's pose in this frame's camera (CV) axes, `down` gravity in the same axes.
    /// Returns the ball over the slab, if any.
    @discardableResult
    public func update(luma: Plane, intrinsics K: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> BallObservation? {
        let g = down.normalized
        // what earlier scans saw, carried into this frame by the slab (the phone may have moved)
        let follow = followed.flatMap { circle(of: $0, in: slab, K: K, ball: ball) }
        let pending = pendingPartial.flatMap { circle(of: $0, in: slab, K: K, ball: ball) }
        var bands = Self.searchBands(intrinsics: K, slab: slab, ball: ball, down: g, heights: options.minHeight...options.maxHeight,
                                     minSearchRadius: options.minSearchRadius)
        guard let first = bands.first, let last = bands.last else {
            pendingPartial = nil
            return missedScan(K: K, slab: slab, spec: spec, ball: ball, down: g)
        }
        if let f = follow {
            // a box around the followed ball, at radii near its own
            let box = ImageRect(center: f.center, halfSize: f.radius * options.followRadii).clamped(width: K.width, height: K.height)
            let lo = max(first.radii.lowerBound, f.radius / options.followRadiusFactor)
            let hi = min(last.radii.upperBound, f.radius * options.followRadiusFactor)
            bands = hi > lo && !box.isEmpty
                ? Self.bands(radii: lo...hi, minSearchRadius: options.minSearchRadius, width: K.width, height: K.height) { _, _ in box }
                    .map { SearchBand(region: box, radii: $0.radii, scale: $0.scale) }
                : []
        }
        var circles: [BallCircle] = []
        for band in bands {
            let up = Self.imageUp(at: band.region.center, depth: slab.center.length, intrinsics: K, down: g)
            for c in search(luma: luma, K: K, region: band.region, radii: band.radii, scale: band.scale, up: up, down: g) {
                // the same ball found in two neighbouring bands: keep the finer band's find
                if !circles.contains(where: { $0.center.distance(to: c.center) < 0.5 * max($0.radius, c.radius) }) { circles.append(c) }
            }
        }
        circles.sort { $0.support > $1.support }

        var part: Anchored? = nil
        var chosen: (BallCircle, Vec3, DropPoint)? = nil
        for c in circles {
            guard let B = Bounce.ballCenter(pixel: c.center, radiusPixels: c.radius, intrinsics: K, ball: ball, model: .imageCircle),
                  let d = Bounce.drop(ballCenter: B, pose: slab, spec: spec, ball: ball, down: g), d.onSlab,
                  d.dropHeight >= options.minHeight, d.dropHeight <= options.maxHeight + 0.3 else { continue }
            if c.partial {
                // the web app's size floor for a partial find, "at a size that puts it no further away than the slab"
                // (radius at least 0.9x that of a ball at the slab's depth), here as a distance; and a size that puts it
                // where a held ball can be
                if B.length > slab.center.length / 0.9 || d.dropHeight < options.minPartialHeight { continue }
                // only part of the outline seen: report it only once the same ball turns up on two scans in a row
                if part == nil { part = anchor(B, slab) }
                let again = pending.map { c.center.distance(to: $0.center) < $0.radius * 0.5 && abs(c.radius - $0.radius) < $0.radius * 0.25 } ?? false
                let known = follow.map { c.center.distance(to: $0.center) < $0.radius } ?? false
                if !again && !known { continue }
            }
            chosen = (c, B, d)
            break
        }
        pendingPartial = part
        guard var (c, B, d) = chosen else {
            return missedScan(K: K, slab: slab, spec: spec, ball: ball, down: g)
        }
        missed = 0
        if let f = follow, c.center.distance(to: f.center) < f.radius * 2 {
            // the same ball: smooth
            let s = BallCircle(center: f.center + (c.center - f.center) * options.positionGain,
                               radius: f.radius + (c.radius - f.radius) * options.radiusGain, support: c.support, partial: c.partial)
            if let B2 = Bounce.ballCenter(pixel: s.center, radiusPixels: s.radius, intrinsics: K, ball: ball, model: .imageCircle),
               let d2 = Bounce.drop(ballCenter: B2, pose: slab, spec: spec, ball: ball, down: g) {
                c = s; B = B2; d = d2
            }
        }
        followed = anchor(B, slab)
        let obs = BallObservation(circle: c, center: B, drop: d, missedUpdates: 0)
        current = obs
        return obs
    }

    /// No ball this scan: hold the followed one over for a few scans.
    private func missedScan(K: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down g: Vec3) -> BallObservation? {
        guard let f = followed else { current = nil; return nil }
        missed += 1
        guard missed <= options.maxMissedUpdates, let c = circle(of: f, in: slab, K: K, ball: ball),
              let B = Bounce.ballCenter(pixel: c.center, radiusPixels: c.radius, intrinsics: K, ball: ball, model: .imageCircle),
              let d = Bounce.drop(ballCenter: B, pose: slab, spec: spec, ball: ball, down: g), d.onSlab else {
            followed = nil; current = nil; missed = 0
            return nil
        }
        followed = anchor(B, slab)
        let obs = BallObservation(circle: c, center: B, drop: d, missedUpdates: missed)
        current = obs
        return obs
    }

    /// The image direction of the world's up at an image point (seen at about `depth`): toward gravity's vanishing point.
    static func imageUp(at p: Vec2, depth: Double, intrinsics K: CameraIntrinsics, down: Vec3) -> Vec2 {
        let ray = K.ray(p).normalized
        if let p0 = K.project(ray * depth), let p1 = K.project(ray * depth - down.normalized * (0.05 * depth)), (p1 - p0).length > 1e-6 {
            return (p1 - p0).normalized
        }
        return Vec2(0, -1)
    }

    // MARK: search

    /// Runs the finder on the region, with the image shrunk by `k` (area average).
    func search(luma: Plane, K: CameraIntrinsics, region: ImageRect, radii: ClosedRange<Double>, scale k: Int, up: Vec2,
                down: Vec3? = nil) -> [BallCircle] {
        if k <= 1 {
            return BallFinder.find(luma: luma, radiusRange: radii, roi: region, intrinsics: K, up: up, down: down, options: options.finder)
        }
        // area-average the region (plus room for the rim measurement around it) down by k
        let pad = radii.upperBound * 0.6
        let x0 = max(0, Int(floor(region.minX - pad)) / k * k), y0 = max(0, Int(floor(region.minY - pad)) / k * k)
        let x1 = min(luma.width, Int(ceil(region.maxX + pad))), y1 = min(luma.height, Int(ceil(region.maxY + pad)))
        let w = (x1 - x0) / k, h = (y1 - y0) / k
        guard w >= 8, h >= 8 else { return [] }
        var d = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(k * k), W = luma.width
        luma.data.withUnsafeBufferPointer { src in
            d.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        var s: Float = 0
                        for dy in 0..<k {
                            let r = (y0 + y * k + dy) * W + x0 + x * k
                            for dx in 0..<k { s += src[r + dx] }
                        }
                        dst[y * w + x] = s * inv
                    }
                }
            }
        }
        let small = Plane(width: w, height: h, data: d)
        let s = 1 / Double(k)
        let Ks = K.cropped(x0: Double(x0), y0: Double(y0), scale: s, width: w, height: h)
        let roi = ImageRect(minX: (region.minX - Double(x0)) * s, minY: (region.minY - Double(y0)) * s,
                            maxX: (region.maxX - Double(x0)) * s, maxY: (region.maxY - Double(y0)) * s)
        return BallFinder.find(luma: small, radiusRange: (radii.lowerBound * s)...(radii.upperBound * s), roi: roi,
                               intrinsics: Ks, up: up, down: down, options: options.finder).map {
            BallCircle(center: Vec2(Double(x0) + $0.center.x * Double(k), Double(y0) + $0.center.y * Double(k)),
                       radius: $0.radius * Double(k), support: $0.support, partial: $0.partial)
        }
    }

    // MARK: remembering a ball relative to the slab

    private func anchor(_ B: Vec3, _ slab: SlabPose) -> Anchored {
        let r = B - slab.center
        return Anchored(local: Vec3(r.dot(slab.axisU), r.dot(slab.axisV), r.dot(slab.normal)), slab: slab)
    }

    /// Where a remembered ball is in this frame, and how it looks.
    private func circle(of a: Anchored, in slab: SlabPose, K: CameraIntrinsics, ball: BallSpec) -> BallCircle? {
        let B = Self.carry(a.local, from: a.slab, to: slab)
        guard let p = K.project(B), let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball) else { return nil }
        return BallCircle(center: p, radius: r, support: 0, partial: false)
    }

    /// A point given in one pose's slab axes, placed by another pose of the same slab. A square slab's outline has no
    /// first corner, so the two poses may name its sides differently: the new pose's axes are turned by the multiple of
    /// 90 degrees that best matches the old ones (the camera turns little between scans).
    static func carry(_ local: Vec3, from old: SlabPose, to new: SlabPose) -> Vec3 {
        var u = new.axisU, v = new.axisV, best = -Double.infinity, bu = u, bv = v
        for _ in 0..<4 {
            let s = u.dot(old.axisU) + v.dot(old.axisV)
            if s > best { best = s; bu = u; bv = v }
            (u, v) = (v, -u)
        }
        return new.center + bu * local.x + bv * local.y + new.normal * local.z
    }
}
