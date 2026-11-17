import Foundation

/// Result of fitting the slab's top face to four image corners.
///
/// Corner order: `pose` is a right-handed SlabPose (axisU x axisV == normal, the normal toward the camera), so its
/// `topCorners` always run anticlockwise on screen seen from the top face's side, i.e. with a negative shoelace area in
/// image coordinates (y down). An outline that runs the other way (positive area) is matched to them in reverse:
/// `cornerOrder` says which outline corner each pose corner is, and `outlineTopCorners`, `poseSide(forOutlineSide:)`
/// and `SlabBoxView(fit:spec:intrinsics:)` look things up by the outline's own corners and sides.
public struct PoseFit: Equatable {
    /// pose in camera (CV) coordinates; the normal points out of the top face, toward the camera's side
    public var pose: SlabPose
    /// root-mean-square reprojection error of the corners (pixels)
    public var rmsPixels: Double
    /// the solver's cost (corner residuals plus the soft level prior), in units of its sigmas squared
    public var cost: Double
    /// whether the slab's U axis had to be matched to the outline's second side (rectangular slabs only)
    public var swappedSides: Bool
    /// `pose.topCorners[i]` projects onto outline corner `cornerOrder[i]`: [0, 1, 2, 3] when the outline runs the same
    /// way as the pose's corners, [3, 2, 1, 0] when it runs the other way round
    public var cornerOrder: [Int] = [0, 1, 2, 3]
    /// How well the corners pin the normal: the standard deviation of its direction (degrees, both tilt axes together)
    /// for corner noise of `PoseSolver.Options.uncertaintyCornerPixels`. A slab seen nearly face-on shows its tilt only
    /// through a few pixels of keystone, so this grows quickly toward a straight-down view. 0 when not computed.
    public var normalSigmaDegrees: Double = 0
    /// The normal's covariance (camera axes, square radians) for the same corner noise: nothing along the normal itself,
    /// and usually far more along one axis across it than the other (the tilt is pinned well in one direction and poorly
    /// in the other). Its trace is normalSigmaDegrees^2 in radians. Zero when not computed.
    public var normalCovariance: Mat3 = Mat3(rows: [0, 0, 0, 0, 0, 0, 0, 0, 0])
    /// covariance of `pose.center` (camera axes, square metres) for the same corner noise; mostly along the line of
    /// sight. Zero when not computed.
    public var centreCovariance: Mat3 = Mat3(rows: [0, 0, 0, 0, 0, 0, 0, 0, 0])
    /// rectangular slabs: the cost of the other side assignment (which outline side is the long one); nil for a square
    /// slab or when that fit failed. The cost difference is this frame's evidence for one assignment (see `longSide`).
    public var alternativeCost: Double? = nil
    /// the cost of the other mirror-image solution (the normal reflected about the line of sight), when both were
    /// fitted; with `previousNormal` the solver may keep the costlier one for continuity, so an assignment's own best
    /// cost is min(cost, mirrorCost)
    public var mirrorCost: Double? = nil

    /// the lowest cost this side assignment reaches over its two mirror-image solutions
    public var bestCost: Double { min(cost, mirrorCost ?? cost) }

    /// whether the outline runs the other way round from the pose's corners
    public var outlineReversed: Bool { cornerOrder == [3, 2, 1, 0] }

    /// The pose's top corners (camera axes) in the outline's order: `outlineTopCorners[j]` projects onto outline corner j.
    public var outlineTopCorners: [Vec3] { PoseFit.toOutlineOrder(pose.topCorners, cornerOrder: cornerOrder) }

    /// Values given per outline corner, rearranged per pose corner (e.g. the outline itself: then element i is where
    /// pose corner i was seen).
    public func cornersInPoseOrder<T>(_ outlineOrdered: [T]) -> [T] {
        precondition(outlineOrdered.count == 4)
        return cornerOrder.map { outlineOrdered[$0] }
    }

    /// Values given per outline side (side j runs from outline corner j to j+1, e.g. a detector's `sideModes`),
    /// rearranged per pose side.
    public func sidesInPoseOrder<T>(_ outlineSides: [T]) -> [T] {
        precondition(outlineSides.count == 4)
        return (0..<4).map { outlineSides[outlineSide(forPoseSide: $0).side] }
    }

    /// The pose side (from pose corner i to i+1) that lies along outline side j (from outline corner j to j+1), and
    /// whether it runs the other way. For a reversed outline it is pose side (2 - j) mod 4, run backwards.
    public func poseSide(forOutlineSide j: Int) -> (side: Int, reversed: Bool) {
        PoseFit.poseSide(forOutlineSide: j, cornerOrder: cornerOrder)
    }

    /// The outline side along pose side i, and whether it runs the other way.
    public func outlineSide(forPoseSide i: Int) -> (side: Int, reversed: Bool) {
        let a = cornerOrder[i], b = cornerOrder[(i + 1) % 4]
        return b == (a + 1) % 4 ? (a, false) : (b, true)
    }

    /// The long side's direction (unit, camera axes; its sign is arbitrary) for a rectangular slab, nil for a square one.
    /// The two side assignments of one outline differ in which edge direction this is; `axisU` follows the outline's
    /// corner 0 -> 1 side in both, so it cannot tell them apart.
    public var longSide: Vec3? {
        if pose.halfU == pose.halfV { return nil }
        return pose.halfU > pose.halfV ? pose.axisU : pose.axisV
    }

    /// standard deviation of the centre along the line of sight (metres), for the same corner noise as the covariance
    public var centreSigmaAlongRay: Double {
        let r = pose.center.normalized
        return max(0, r.dot(centreCovariance * r)).squareRoot()
    }

    static func poseSide(forOutlineSide j: Int, cornerOrder: [Int]) -> (side: Int, reversed: Bool) {
        let a = cornerOrder.firstIndex(of: j)!, b = cornerOrder.firstIndex(of: (j + 1) % 4)!
        return b == (a + 1) % 4 ? (a, false) : (b, true)
    }

    static func toOutlineOrder<T>(_ poseOrdered: [T], cornerOrder: [Int]) -> [T] {
        var out = poseOrdered
        for i in 0..<4 { out[cornerOrder[i]] = poseOrdered[i] }
        return out
    }
}

/// Pose of a known rectangle from its four image corners: a homography gives the start, then Levenberg-Marquardt on
/// the corner reprojection error, optionally with a soft prior that the slab is only gently tilted from level. A
/// rectangle seen from afar has two plausible tilts (mirror images about the line of sight); both are fitted and the
/// better kept, with hysteresis toward the previous normal. Ported from the web app's solvePose.
///
/// The outline may start at any corner and run either way round; see `PoseFit.cornerOrder` for how its corners map
/// onto the pose's.
public enum PoseSolver {
    public struct Options {
        /// corner noise (pixels) assumed for the reprojection residuals
        public var cornerSigmaPixels: Double = 2.5
        /// soft prior on the tilt from level (degrees); nil for none. By default it only helps choose between the two
        /// mirror-image solutions; with `levelPriorInFit` it also pulls the fitted normal toward level (as the web app did,
        /// which biases a real tilt toward 0 when the corners are few pixels apart).
        public var levelPriorSigmaDegrees: Double? = 20
        public var levelPriorInFit = false
        public var maxIterations: Int = 25
        /// corner noise (pixels of the image the corners are in) behind the uncertainty a fit reports
        /// (`PoseFit.normalSigmaDegrees`, `centreCovariance`). Scale those by (actual noise / this) for another noise.
        public var uncertaintyCornerPixels: Double = 1
        public init() {}
    }

    /// - Parameters:
    ///   - corners: four image corners in outline order (pixels; any start, either way round)
    ///   - spec: the slab (its side lengths are used)
    ///   - down: gravity's direction in camera coordinates, for the level prior (optional)
    ///   - previousNormal: last frame's normal in camera coordinates, to avoid flipping between the mirror solutions
    /// - Returns: for a rectangular slab, the side assignment with the lower cost on this outline alone (with the other's
    ///   cost in `alternativeCost`). That choice is often wrong for a nearly square slab under corner noise: a tracker
    ///   should gather the evidence over frames with `solveAssignments`.
    public static func solve(corners: [Vec2], intrinsics K: CameraIntrinsics, spec: SlabSpec, down: Vec3? = nil,
                             previousNormal: Vec3? = nil, options: Options = Options()) -> PoseFit? {
        let fits = solveAssignments(corners: corners, intrinsics: K, spec: spec, down: down, previousNormal: previousNormal, options: options)
        var best: PoseFit? = nil
        for f in fits where best == nil || f.cost < best!.cost { best = f }
        return best
    }

    /// Both side assignments of a rectangular slab (which outline side is the long one), each with its own cost and
    /// the other's in `alternativeCost`; one fit for a square slab. Empty when nothing fits.
    public static func solveAssignments(corners: [Vec2], intrinsics K: CameraIntrinsics, spec: SlabSpec, down: Vec3? = nil,
                                        previousNormal: Vec3? = nil, options: Options = Options()) -> [PoseFit] {
        guard corners.count == 4 else { return [] }
        var fits: [PoseFit] = []
        if let a = solveOne(corners: corners, K: K, hu: spec.halfU, hv: spec.halfV, down: down, prev: previousNormal, opt: options) { fits.append(a) }
        if spec.sideU != spec.sideV, var alt = solveOne(corners: corners, K: K, hu: spec.halfV, hv: spec.halfU, down: down, prev: previousNormal, opt: options) {
            alt.swappedSides = true
            fits.append(alt)
        }
        if fits.count == 2 { fits[0].alternativeCost = fits[1].cost; fits[1].alternativeCost = fits[0].cost }
        return fits
    }

    static func homography(_ q: [Vec2], K: CameraIntrinsics, hu: Double, hv: Double) -> (Vec3, Vec3, Vec3)? {
        var A: [[Double]] = [], b: [Double] = []
        for i in 0..<4 {
            let X = slabCornerSigns[i].0 * hu, Y = slabCornerSigns[i].1 * hv, n = K.normalized(q[i])
            A.append([X, Y, 1, 0, 0, 0, -n.x * X, -n.x * Y]); b.append(n.x)
            A.append([0, 0, 0, X, Y, 1, -n.y * X, -n.y * Y]); b.append(n.y)
        }
        guard let h = solveLinear(A, b) else { return nil }
        return (Vec3(h[0], h[3], h[6]), Vec3(h[1], h[4], h[7]), Vec3(h[2], h[5], 1))
    }

    struct Refined { var r1: Vec3; var r2: Vec3; var t: Vec3; var cost: Double }

    /// The corner residuals (normalised image coordinates divided by sp), 8 of them; nil if a corner is behind the camera.
    static func cornerResiduals(_ a: Vec3, _ b: Vec3, _ t: Vec3, obs: [Vec2], hu: Double, hv: Double, sp: Double) -> [Double]? {
        var o: [Double] = []
        o.reserveCapacity(11)
        for i in 0..<4 {
            let p = t + a * (slabCornerSigns[i].0 * hu) + b * (slabCornerSigns[i].1 * hv)
            if p.z < 1e-6 { return nil }
            o.append((p.x / p.z - obs[i].x) / sp); o.append((p.y / p.z - obs[i].y) / sp)
        }
        return o
    }

    static func refine(_ r1In: Vec3, _ r2In: Vec3, _ tIn: Vec3, obs: [Vec2], hu: Double, hv: Double, sign sg: Double,
                       up: Vec3?, sp: Double, st: Double, iterations: Int) -> Refined? {
        func residuals(_ a: Vec3, _ b: Vec3, _ t: Vec3) -> [Double]? {
            guard var o = cornerResiduals(a, b, t, obs: obs, hu: hu, hv: hv, sp: sp) else { return nil }
            if let up = up {
                let n = a.cross(b).normalized * sg
                o.append((n.x - up.x) / st); o.append((n.y - up.y) / st); o.append((n.z - up.z) / st)
            }
            return o
        }
        func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }
        var r1 = r1In, r2 = r2In, t = tIn
        guard var r = residuals(r1, r2, t) else { return nil }
        var c = cost(r), lam = 1e-3
        for _ in 0..<iterations {
            let ts = t.length * 1e-5
            var J: [[Double]] = []
            for j in 0..<6 {
                var w = Vec3.zero, d = Vec3.zero
                let h = j < 3 ? 1e-5 : ts
                switch j { case 0: w.x = h; case 1: w.y = h; case 2: w.z = h; case 3: d.x = h; case 4: d.y = h; default: d.z = h }
                guard let rr = residuals(r1.rotated(by: w), r2.rotated(by: w), t + d) else { return nil }
                J.append(zip(rr, r).map { ($0 - $1) / h })
            }
            var A = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6), g = [Double](repeating: 0, count: 6)
            for i in 0..<6 {
                var gi = 0.0
                for m in 0..<r.count { gi -= J[i][m] * r[m] }
                g[i] = gi
                for j in 0..<6 {
                    var v = 0.0
                    for m in 0..<r.count { v += J[i][m] * J[j][m] }
                    A[i][j] = i == j ? v * (1 + lam) + 1e-12 : v
                }
            }
            guard let x = solveLinear(A, g) else { break }
            let w = Vec3(x[0], x[1], x[2]), a2 = r1.rotated(by: w), b2 = r2.rotated(by: w), t2 = t + Vec3(x[3], x[4], x[5])
            if let nr = residuals(a2, b2, t2), cost(nr) < c {
                let nc = cost(nr), done = c - nc < 1e-10 * (c + 1e-12)
                r1 = a2; r2 = b2; t = t2; r = nr; c = nc; lam *= 0.3
                if done { break }
            } else {
                lam *= 10
                if lam > 1e7 { break }
            }
        }
        return Refined(r1: r1, r2: r2, t: t, cost: c)
    }

    /// The fit's uncertainty from the corners alone (no prior): the covariance of (rotation vector, translation) is
    /// k^2 (J^T J)^-1 for the undamped Jacobian of the corner residuals at the solution, with k the assumed corner noise
    /// over the residuals' own sigma. Returns the normal's angular sigma (radians, both axes), its covariance and the
    /// centre's covariance.
    static func uncertainty(_ s: Refined, normal n: Vec3, axisU u: Vec3, obs: [Vec2], hu: Double, hv: Double, sp: Double,
                            k: Double) -> (normalSigma: Double, normal: Mat3, centre: Mat3)? {
        guard let r0 = cornerResiduals(s.r1, s.r2, s.t, obs: obs, hu: hu, hv: hv, sp: sp) else { return nil }
        let ts = max(s.t.length * 1e-6, 1e-9)
        var J: [[Double]] = []
        for j in 0..<6 {
            var w = Vec3.zero, d = Vec3.zero
            let h = j < 3 ? 1e-6 : ts
            switch j { case 0: w.x = h; case 1: w.y = h; case 2: w.z = h; case 3: d.x = h; case 4: d.y = h; default: d.z = h }
            guard let rr = cornerResiduals(s.r1.rotated(by: w), s.r2.rotated(by: w), s.t + d, obs: obs, hu: hu, hv: hv, sp: sp) else { return nil }
            J.append(zip(rr, r0).map { ($0 - $1) / h })
        }
        var A = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for i in 0..<6 { for j in 0..<6 { var v = 0.0; for m in 0..<8 { v += J[i][m] * J[j][m] }; A[i][j] = v } }
        // the columns of the inverse we need: all six (rotation block for the normal, translation block for the centre)
        var inv = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for c in 0..<6 {
            var e = [Double](repeating: 0, count: 6); e[c] = 1
            guard let x = solveLinear(A, e) else { return nil }
            for r in 0..<6 { inv[r][c] = x[r] * k * k }
        }
        let Sw = Mat3(rows: [inv[0][0], inv[0][1], inv[0][2], inv[1][0], inv[1][1], inv[1][2], inv[2][0], inv[2][1], inv[2][2]])
        let v = n.cross(u)
        let varN = u.dot(Sw * u) + v.dot(Sw * v)
        let St = Mat3(rows: [inv[3][3], inv[3][4], inv[3][5], inv[4][3], inv[4][4], inv[4][5], inv[5][3], inv[5][4], inv[5][5]])
        guard varN.isFinite, varN >= 0 else { return nil }
        // a small turn w moves the normal by w x n = -[n]x w
        let K = Mat3(rows: [0, -n.z, n.y, n.z, 0, -n.x, -n.y, n.x, 0])
        return (varN.squareRoot(), K * Sw * K.transposed, St)
    }

    static func solveOne(corners q: [Vec2], K: CameraIntrinsics, hu: Double, hv: Double, down: Vec3?, prev: Vec3?, opt: Options) -> PoseFit? {
        guard let (c0, c1, c2) = homography(q, K: K, hu: hu, hv: hv) else { return nil }
        let l0 = c0.length, l1 = c1.length
        guard l0 > 0, l1 > 0 else { return nil }
        let lam = 2 / (l0 + l1)
        let c = c2 * lam, r1 = c0.normalized, r2 = (c1 - r1 * c1.dot(r1)).normalized
        let n0 = r1.cross(r2), sg: Double = n0.dot(c) > 0 ? -1 : 1
        let obs = q.map { K.normalized($0) }
        let f = K.focal, sp = opt.cornerSigmaPixels / f
        let upPrior = opt.levelPriorSigmaDegrees != nil ? down.map { -$0.normalized } : nil
        let up = opt.levelPriorInFit ? upPrior : nil
        let st = Units.radians(opt.levelPriorSigmaDegrees ?? 20)
        // the prior's cost of a solution, used to choose between the mirror images when it is not in the fit
        func priorCost(_ r: Refined) -> Double {
            guard let u = upPrior, !opt.levelPriorInFit else { return 0 }
            let n = r.r1.cross(r.r2).normalized * sg
            return (n - u).lengthSquared / (st * st)
        }
        // the mirror-image solution: reflect the normal about the line of sight
        let v = c.normalized
        func half(_ a: Vec3, _ x: Vec3) -> Vec3 { a * (2 * a.dot(x)) - x }
        let n1 = half(v, n0), f1 = half(n1, half(v, r1)), f2 = half(n1, half(v, r2))
        let A = refine(r1, r2, c, obs: obs, hu: hu, hv: hv, sign: sg, up: up, sp: sp, st: st, iterations: opt.maxIterations)
        let B = refine(f1, f2, c, obs: obs, hu: hu, hv: hv, sign: sg, up: up, sp: sp, st: st, iterations: opt.maxIterations)
        var best: Refined, mirror: Refined? = nil
        switch (A, B) {
        case (nil, nil): return nil
        case (let a?, nil): best = a
        case (nil, let b?): best = b
        case (let a?, let b?):
            let ca = a.cost + priorCost(a), cb = b.cost + priorCost(b)
            best = cb < ca ? b : a
            var other = cb < ca ? a : b
            if let prev = prev {
                let nb = best.r1.cross(best.r2).normalized * sg, no = other.r1.cross(other.r2).normalized * sg
                if no.dot(prev) > nb.dot(prev) && other.cost < best.cost * 3 + 1 { swap(&best, &other) }
            }
            mirror = other
        }
        let n = best.r1.cross(best.r2).normalized * sg
        // the pose is right-handed (axisV = n x axisU), so with sg = -1 its v axis is -r2: pose corner i is outline
        // corner 3 - i
        let u = best.r1.normalized, vv = n.cross(u)
        // corner residuals only, in pixels
        var se = 0.0
        for i in 0..<4 {
            let p = best.t + best.r1 * (slabCornerSigns[i].0 * hu) + best.r2 * (slabCornerSigns[i].1 * hv)
            if let pr = K.project(p) { se += pow(pr.x - q[i].x, 2) + pow(pr.y - q[i].y, 2) } else { return nil }
        }
        let pose = SlabPose(center: best.t, normal: n, axisU: u, axisV: vv, halfU: hu, halfV: hv)
        var fit = PoseFit(pose: pose, rmsPixels: (se / 4).squareRoot(), cost: best.cost, swappedSides: false)
        fit.cornerOrder = sg < 0 ? [3, 2, 1, 0] : [0, 1, 2, 3]
        fit.mirrorCost = mirror?.cost
        if let un = uncertainty(best, normal: n, axisU: u, obs: obs, hu: hu, hv: hv, sp: sp, k: opt.uncertaintyCornerPixels / opt.cornerSigmaPixels) {
            fit.normalSigmaDegrees = Units.degrees(un.normalSigma)
            fit.normalCovariance = un.normal
            fit.centreCovariance = un.centre
        }
        return fit
    }
}

/// Checks that an outline is a shape the slab could make.
public enum ShapeCheck {
    public struct Limits: Equatable {
        /// largest corner misfit allowed, as a fraction of the mean side length in the image
        public var maxMisfitFraction: Double = 0.03
        /// the slab is expected this near / far (metres)
        public var minDistance: Double = 0.25
        public var maxDistance: Double = 3.0
        /// the slab never tilts more than this from level (degrees)
        public var maxTiltDegrees: Double = 25
        /// reject fits whose normal the corners cannot pin (`PoseFit.normalSigmaDegrees` above this): views from nearly
        /// straight above, where corner noise alone moves the tilt by degrees. nil: no check.
        public var maxNormalSigmaDegrees: Double? = nil
        public init() {}
    }

    public enum Verdict: Equatable {
        case ok, notConvex, misfit(Double), tooNear, tooFar, tooTilted(Double), noPose
        /// the normal's uncertainty (degrees) is above `Limits.maxNormalSigmaDegrees`
        case illConditioned(Double)

        /// The verdict's kind without its value, for counters ("misfit", "tooTilted", ...).
        public var key: String {
            switch self {
            case .ok: return "ok"
            case .notConvex: return "notConvex"
            case .misfit: return "misfit"
            case .tooNear: return "tooNear"
            case .tooFar: return "tooFar"
            case .tooTilted: return "tooTilted"
            case .noPose: return "noPose"
            case .illConditioned: return "illConditioned"
            }
        }

        /// The value a verdict carries (misfit fraction, tilt or normal sigma in degrees), if any.
        public var value: Double? {
            switch self {
            case .misfit(let v), .tooTilted(let v), .illConditioned(let v): return v
            default: return nil
            }
        }
    }

    /// Mean side length of an image outline (pixels).
    public static func meanSide(_ q: [Vec2]) -> Double {
        (0..<4).reduce(0) { $0 + q[$1].distance(to: q[($1 + 1) % 4]) } / 4
    }

    /// Signed area of an outline (pixels squared) by the shoelace formula in image coordinates (y down): positive when
    /// it runs clockwise on screen, negative when anticlockwise (as a fitted pose's corners do).
    public static func signedArea(_ q: [Vec2]) -> Double {
        var a = 0.0
        for i in 0..<q.count { a += q[i].cross(q[(i + 1) % q.count]) }
        return a / 2
    }

    public static func isConvex(_ q: [Vec2]) -> Bool {
        guard q.count == 4 else { return false }
        var sign = 0.0
        for i in 0..<4 {
            let z = (q[(i + 1) % 4] - q[i]).cross(q[(i + 2) % 4] - q[(i + 1) % 4])
            if z == 0 { return false }
            if sign != 0 && (z > 0) != (sign > 0) { return false }
            sign = z
        }
        return true
    }

    public static func check(_ fit: PoseFit?, outline q: [Vec2], down: Vec3?, limits: Limits = Limits()) -> Verdict {
        guard isConvex(q) else { return .notConvex }
        guard let fit = fit else { return .noPose }
        let side = meanSide(q)
        if fit.rmsPixels > side * limits.maxMisfitFraction { return .misfit(fit.rmsPixels / max(side, 1e-9)) }
        let d = fit.pose.center.length
        if d < limits.minDistance { return .tooNear }
        if d > limits.maxDistance { return .tooFar }
        if let g = down {
            let tilt = Units.degrees(fit.pose.tilt(down: g))
            if tilt > limits.maxTiltDegrees { return .tooTilted(tilt) }
        }
        if let m = limits.maxNormalSigmaDegrees, fit.normalSigmaDegrees > m { return .illConditioned(fit.normalSigmaDegrees) }
        return .ok
    }
}
