import Foundation

/// Result of fitting the slab's top face to four image corners.
public struct PoseFit: Equatable {
    /// pose in camera (CV) coordinates; the normal points out of the top face, toward the camera's side
    public var pose: SlabPose
    /// root-mean-square reprojection error of the corners (pixels)
    public var rmsPixels: Double
    /// the solver's cost (corner residuals plus the soft level prior), in units of its sigmas squared
    public var cost: Double
    /// whether the slab's U axis had to be matched to the outline's second side (rectangular slabs only)
    public var swappedSides: Bool
}

/// Pose of a known rectangle from its four image corners: a homography gives the start, then Levenberg-Marquardt on
/// the corner reprojection error, optionally with a soft prior that the slab is only gently tilted from level. A
/// rectangle seen from afar has two plausible tilts (mirror images about the line of sight); both are fitted and the
/// better kept, with hysteresis toward the previous normal. Ported from the web app's solvePose.
public enum PoseSolver {
    public struct Options {
        /// corner noise (pixels) assumed for the reprojection residuals
        public var cornerSigmaPixels: Double = 2.5
        /// soft prior on the tilt from level (degrees); nil for none
        public var levelPriorSigmaDegrees: Double? = 20
        public var maxIterations: Int = 25
        public init() {}
    }

    /// - Parameters:
    ///   - corners: four image corners in outline order (pixels)
    ///   - spec: the slab (its side lengths are used)
    ///   - down: gravity's direction in camera coordinates, for the level prior (optional)
    ///   - previousNormal: last frame's normal in camera coordinates, to avoid flipping between the mirror solutions
    public static func solve(corners: [Vec2], intrinsics K: CameraIntrinsics, spec: SlabSpec, down: Vec3? = nil,
                             previousNormal: Vec3? = nil, options: Options = Options()) -> PoseFit? {
        guard corners.count == 4 else { return nil }
        var best = solveOne(corners: corners, K: K, hu: spec.halfU, hv: spec.halfV, down: down, prev: previousNormal, opt: options)
        if spec.sideU != spec.sideV, var alt = solveOne(corners: corners, K: K, hu: spec.halfV, hv: spec.halfU, down: down, prev: previousNormal, opt: options) {
            alt.swappedSides = true
            if best == nil || alt.cost < best!.cost { best = alt }
        }
        return best
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

    static func refine(_ r1In: Vec3, _ r2In: Vec3, _ tIn: Vec3, obs: [Vec2], hu: Double, hv: Double, sign sg: Double,
                       up: Vec3?, sp: Double, st: Double, iterations: Int) -> Refined? {
        func residuals(_ a: Vec3, _ b: Vec3, _ t: Vec3) -> [Double]? {
            var o: [Double] = []
            o.reserveCapacity(11)
            for i in 0..<4 {
                let p = t + a * (slabCornerSigns[i].0 * hu) + b * (slabCornerSigns[i].1 * hv)
                if p.z < 1e-6 { return nil }
                o.append((p.x / p.z - obs[i].x) / sp); o.append((p.y / p.z - obs[i].y) / sp)
            }
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

    static func solveOne(corners q: [Vec2], K: CameraIntrinsics, hu: Double, hv: Double, down: Vec3?, prev: Vec3?, opt: Options) -> PoseFit? {
        guard let (c0, c1, c2) = homography(q, K: K, hu: hu, hv: hv) else { return nil }
        let l0 = c0.length, l1 = c1.length
        guard l0 > 0, l1 > 0 else { return nil }
        let lam = 2 / (l0 + l1)
        let c = c2 * lam, r1 = c0.normalized, r2 = (c1 - r1 * c1.dot(r1)).normalized
        let n0 = r1.cross(r2), sg: Double = n0.dot(c) > 0 ? -1 : 1
        let obs = q.map { K.normalized($0) }
        let f = K.focal, sp = opt.cornerSigmaPixels / f
        let up = opt.levelPriorSigmaDegrees != nil ? down.map { -$0.normalized } : nil
        let st = Units.radians(opt.levelPriorSigmaDegrees ?? 20)
        // the mirror-image solution: reflect the normal about the line of sight
        let v = c.normalized
        func half(_ a: Vec3, _ x: Vec3) -> Vec3 { a * (2 * a.dot(x)) - x }
        let n1 = half(v, n0), f1 = half(n1, half(v, r1)), f2 = half(n1, half(v, r2))
        let A = refine(r1, r2, c, obs: obs, hu: hu, hv: hv, sign: sg, up: up, sp: sp, st: st, iterations: opt.maxIterations)
        let B = refine(f1, f2, c, obs: obs, hu: hu, hv: hv, sign: sg, up: up, sp: sp, st: st, iterations: opt.maxIterations)
        var best: Refined
        switch (A, B) {
        case (nil, nil): return nil
        case (let a?, nil): best = a
        case (nil, let b?): best = b
        case (let a?, let b?):
            best = b.cost < a.cost ? b : a
            if let prev = prev {
                let other = b.cost < a.cost ? a : b
                let nb = best.r1.cross(best.r2).normalized * sg, no = other.r1.cross(other.r2).normalized * sg
                if no.dot(prev) > nb.dot(prev) && other.cost < best.cost * 3 + 1 { best = other }
            }
        }
        let n = best.r1.cross(best.r2).normalized * sg
        let u = best.r1.normalized, vv = n.cross(u)
        // corner residuals only, in pixels
        var se = 0.0
        for i in 0..<4 {
            let p = best.t + best.r1 * (slabCornerSigns[i].0 * hu) + best.r2 * (slabCornerSigns[i].1 * hv)
            if let pr = K.project(p) { se += pow(pr.x - q[i].x, 2) + pow(pr.y - q[i].y, 2) } else { return nil }
        }
        let pose = SlabPose(center: best.t, normal: n, axisU: u, axisV: vv, halfU: hu, halfV: hv)
        return PoseFit(pose: pose, rmsPixels: (se / 4).squareRoot(), cost: best.cost, swappedSides: false)
    }
}

/// Checks that an outline is a shape the slab could make.
public enum ShapeCheck {
    public struct Limits {
        /// largest corner misfit allowed, as a fraction of the mean side length in the image
        public var maxMisfitFraction: Double = 0.03
        /// the slab is expected this near / far (metres)
        public var minDistance: Double = 0.25
        public var maxDistance: Double = 3.0
        /// the slab never tilts more than this from level (degrees)
        public var maxTiltDegrees: Double = 25
        public init() {}
    }

    public enum Verdict: Equatable { case ok, notConvex, misfit(Double), tooNear, tooFar, tooTilted(Double), noPose }

    /// Mean side length of an image outline (pixels).
    public static func meanSide(_ q: [Vec2]) -> Double {
        (0..<4).reduce(0) { $0 + q[$1].distance(to: q[($1 + 1) % 4]) } / 4
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
        return .ok
    }
}
