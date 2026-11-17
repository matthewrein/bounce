import Foundation

/// A plane: points p with normal . (p - point) = 0. The normal is unit length.
public struct Plane3: Equatable, Codable {
    public var point: Vec3
    public var normal: Vec3
    public init(point: Vec3, normal: Vec3) { self.point = point; self.normal = normal.normalized }
    public func distance(_ p: Vec3) -> Double { (p - point).dot(normal) }
    /// where a ray meets the plane (nil if parallel or behind the origin)
    public func intersect(origin o: Vec3, direction d: Vec3) -> Vec3? {
        let den = d.dot(normal)
        guard abs(den) > 1e-9 else { return nil }
        let t = (point - o).dot(normal) / den
        return t > 0 ? o + d * t : nil
    }
}

/// Least-squares and robust plane fits, and the LiDAR check of the slab's top.
public enum PlaneFit {
    /// Least-squares plane through points (smallest-eigenvalue direction of their scatter). nil for fewer than 3 points
    /// or a degenerate (collinear) set.
    public static func leastSquares(_ pts: [Vec3]) -> (plane: Plane3, rms: Double)? {
        guard pts.count >= 3 else { return nil }
        var c = Vec3.zero
        for p in pts { c += p }
        c = c / Double(pts.count)
        var a = [Double](repeating: 0, count: 6) // xx xy xz yy yz zz
        for p in pts {
            let d = p - c
            a[0] += d.x * d.x; a[1] += d.x * d.y; a[2] += d.x * d.z; a[3] += d.y * d.y; a[4] += d.y * d.z; a[5] += d.z * d.z
        }
        let m = Mat3(rows: [a[0], a[1], a[2], a[1], a[3], a[4], a[2], a[4], a[5]])
        guard let n = smallestEigenvector(m) else { return nil }
        let plane = Plane3(point: c, normal: n)
        let rms = (pts.reduce(0) { $0 + pow(plane.distance($1), 2) } / Double(pts.count)).squareRoot()
        return (plane, rms)
    }

    /// Eigenvector of the smallest eigenvalue of a symmetric 3x3 matrix (cyclic Jacobi rotations).
    static func smallestEigenvector(_ m0: Mat3) -> Vec3? {
        var a = [[m0[0, 0], m0[0, 1], m0[0, 2]], [m0[1, 0], m0[1, 1], m0[1, 2]], [m0[2, 0], m0[2, 1], m0[2, 2]]]
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
            if off < 1e-30 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] {
                guard abs(a[p][q]) > 1e-300 else { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 { // A <- J^T A J
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 { // V <- V J
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq
                }
            }
        }
        var i = 0
        for k in 1..<3 where a[k][k] < a[i][i] { i = k }
        let e = Vec3(v[0][i], v[1][i], v[2][i])
        return e.isFinite && e.length > 0.5 ? e.normalized : nil
    }

    /// RANSAC then least squares on the inliers. Deterministic (a fixed pseudo-random sequence).
    public static func robust(_ pts: [Vec3], threshold: Double, iterations: Int = 80) -> (plane: Plane3, rms: Double, inliers: Int)? {
        guard pts.count >= 3 else { return nil }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        var best: Plane3? = nil, bestCount = 0
        for _ in 0..<iterations {
            let a = pts[rnd(pts.count)], b = pts[rnd(pts.count)], c = pts[rnd(pts.count)]
            let n = (b - a).cross(c - a)
            guard n.length > 1e-9 else { continue }
            let p = Plane3(point: a, normal: n)
            var k = 0
            for q in pts where abs(p.distance(q)) < threshold { k += 1 }
            if k > bestCount { bestCount = k; best = p }
        }
        guard let b = best else { return nil }
        let inl = pts.filter { abs(b.distance($0)) < threshold }
        guard let ls = leastSquares(inl) else { return nil }
        // keep the RANSAC orientation convention: normal toward the RANSAC normal
        var plane = ls.plane
        if plane.normal.dot(b.normal) < 0 { plane.normal = -plane.normal }
        return (plane, ls.rms, inl.count)
    }
}

/// What LiDAR says about the slab's top.
public struct DepthCheck: Equatable, Codable {
    /// plane fitted to depth points inside the slab's top (world frame), its normal pointing up out of the top
    public var plane: Plane3
    public var points: Int
    public var rms: Double
    /// angle between the depth plane's normal and the slab normal from the image (degrees)
    public var angleToImageDegrees: Double
    /// how far the image pose's centre lies above (+) or below (-) the depth plane (metres)
    public var centreOffset: Double
    /// the depth plane's tilt from level (degrees)
    public var tiltDegrees: Double
    /// how many depth points lay inside the top's polygon (the fit's inliers are `points` of them); nil in old reports
    public var candidates: Int? = nil

    /// share of the points inside the top that lie on the fitted plane: about 1 for a clean top (the dish fits inside
    /// the inlier band), lower when something else (a hand, the ground) shares the polygon with it
    public var inlierFraction: Double? { candidates.flatMap { $0 > 0 ? Double(points) / Double($0) : nil } }
}

extension PlaneFit {
    /// Fit a plane to the LiDAR depth inside the slab's top (shrunk to `inner` of its size so edges and the cut face are
    /// left out), in world coordinates, and compare it with the image pose.
    /// - Parameters: depth: the depth map; depthIntrinsics: intrinsics of the depth map's pixels; view: the camera
    ///   (world-from-camera, CV axes); slab: the image pose in world coordinates; minConfidence: 0-2 (ARKit's levels).
    public static func checkSlabTop(depth: DepthMap, depthIntrinsics K: CameraIntrinsics, view: CameraView, slab: SlabPose,
                                    down: Vec3 = ARKitConvention.worldDown, inner: Double = 0.7, minConfidence: UInt8 = 1) -> DepthCheck? {
        // the shrunk top in the depth image, as a polygon
        let corners = slabCornerSigns.map { slab.point(u: $0.0 * slab.halfU * inner, v: $0.1 * slab.halfV * inner) }
        let camCorners = corners.map { view.toCamera($0) }
        let poly = camCorners.compactMap { K.project($0) }
        guard poly.count == 4 else { return nil }
        let xs = poly.map { $0.x }, ys = poly.map { $0.y }
        let x0 = max(0, Int(floor(xs.min()!))), x1 = min(depth.width - 1, Int(ceil(xs.max()!)))
        let y0 = max(0, Int(floor(ys.min()!))), y1 = min(depth.height - 1, Int(ceil(ys.max()!)))
        guard x1 > x0, y1 > y0 else { return nil }
        func inside(_ q: Vec2) -> Bool {
            var sign = 0.0
            for i in 0..<4 {
                let z = (poly[(i + 1) % 4] - poly[i]).cross(q - poly[i])
                if z == 0 { continue }
                if sign == 0 { sign = z } else if (z > 0) != (sign > 0) { return false }
            }
            return true
        }
        var pts: [Vec3] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let q = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                guard inside(q) else { continue }
                let (d, c) = depth.at(x, y)
                guard c >= minConfidence, d.isFinite, d > 0.05 else { continue }
                pts.append(view.toWorld(K.unproject(q, depth: Double(d))))
            }
        }
        guard pts.count >= 30, let fit = robust(pts, threshold: 0.006) else { return nil }
        var plane = fit.plane
        if plane.normal.dot(down) > 0 { plane.normal = -plane.normal }
        let ang = Units.degrees(plane.normal.angle(to: slab.normal))
        return DepthCheck(plane: plane, points: fit.inliers, rms: fit.rms, angleToImageDegrees: ang,
                          centreOffset: plane.distance(slab.center), tiltDegrees: Units.degrees(acos(clamp(-plane.normal.dot(down.normalized), -1, 1))),
                          candidates: pts.count)
    }
}
