import Foundation
@testable import BounceCore

/// A finger holding the ball, for the lattice renders: a capsule (camera axes, metres) of skin.
struct Finger {
    var a: Vec3
    var b: Vec3
    var radius: Double
    var luma: Float = 172

    /// how far along the unit ray from the camera it meets the capsule, if it does
    func hit(_ d: Vec3) -> Double? {
        let ab = b - a, L2 = ab.lengthSquared
        var best: Double? = nil
        // the cylinder
        let ao = Vec3.zero - a
        let dPar = d - ab * (d.dot(ab) / L2), oPar = ao - ab * (ao.dot(ab) / L2)
        let A = dPar.lengthSquared, B = 2 * dPar.dot(oPar), C = oPar.lengthSquared - radius * radius, disc = B * B - 4 * A * C
        if A > 1e-12, disc >= 0 {
            let t = (-B - disc.squareRoot()) / (2 * A)
            let s = (d * t - a).dot(ab) / L2
            if t > 0, s >= 0, s <= 1 { best = t }
        }
        // the end caps
        for c in [a, b] {
            let bb = d.dot(c), cc = c.lengthSquared - radius * radius, dd = bb * bb - cc
            if dd >= 0 { let t = bb - dd.squareRoot(); if t > 0, t < (best ?? .infinity) { best = t } }
        }
        return best
    }
}

/// Renders of the owner's lattice ball (`LatticeBall`) through a pinhole camera, painted over a picture: only the
/// pixels near the ball are rendered (n x n samples each), with the fingers holding it, and, for a falling ball, the
/// ball averaged over the instants of its exposure (`path`).
enum LatticePaint {
    /// - Parameters: center: the ball's centre (camera axes) or the first of `path`; up: the world's up (camera axes);
    ///   light: toward the light (camera axes); base: the picture behind.
    static func paint(ballAt center: Vec3, radius: Double, up: Vec3, K: CameraIntrinsics, over base: Plane, fingers: [Finger] = [],
                      path: [Vec3] = [], light: Vec3? = nil, samples n: Int = 3, seed: Int = 11) -> Plane {
        var img = base
        let centres = path.isEmpty ? [center] : path
        let u = up.normalized
        var ex = Vec3(1, 0, 0).rejecting(u)
        if ex.length < 1e-6 { ex = Vec3(0, 0, 1).rejecting(u) }
        ex = ex.normalized
        let ez = ex.cross(u)
        func world(_ v: Vec3) -> Vec3 { Vec3(v.dot(ex), v.dot(u), v.dot(ez)) }
        let L = world((light ?? (u + Vec3(0.3, 0, -0.5)).normalized).normalized)
        let ball = LatticeBall(radius: radius, seed: seed)
        // the box the ball (and the fingers near it) cover
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for c in centres {
            guard let p = K.project(c), let r = Bounce.imageRadius(ballCenter: c, intrinsics: K, ball: BallSpec(diameter: 2 * radius)) else { continue }
            x0 = min(x0, p.x - 1.6 * r - 3); y0 = min(y0, p.y - 1.6 * r - 3); x1 = max(x1, p.x + 1.6 * r + 3); y1 = max(y1, p.y + 1.6 * r + 3)
        }
        for f in fingers {
            for q in [f.a, f.b] {
                guard let p = K.project(q) else { continue }
                let r = K.focal * f.radius / q.z + 3
                x0 = min(x0, p.x - r); y0 = min(y0, p.y - r); x1 = max(x1, p.x + r); y1 = max(y1, p.y + r)
            }
        }
        let xa = Int(max(0, min(Double(K.width), x0))), xb = Int(max(0, min(Double(K.width), x1 + 1)))
        let ya = Int(max(0, min(Double(K.height), y0))), yb = Int(max(0, min(Double(K.height), y1 + 1)))
        guard xb > xa, yb > ya else { return img }
        let wc = centres.map(world)
        for y in ya..<yb {
            for x in xa..<xb {
                var acc: Float = 0
                for sy in 0..<n {
                    for sx in 0..<n {
                        let k = sy * n + sx
                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / Double(n), Double(y) + (Double(sy) + 0.5) / Double(n))).normalized
                        let c = wc[k % wc.count]
                        var tBall = Double.infinity, v: Float = base[x, y]
                        if case let .solid(t, rgb)? = ball.trace(.zero, world(d), center: c, light: L) {
                            tBall = t
                            v = Float(255 * pow(min(1, 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2), 1 / 1.6))
                        }
                        for f in fingers {
                            if let t = f.hit(d), t < tBall { tBall = t; v = f.luma * Float(0.8 + 0.2 * max(0, -d.dot(u))) }
                        }
                        acc += v
                    }
                }
                img[x, y] = acc / Float(n * n)
            }
        }
        return img
    }

    /// Fingers holding a ball from below, as the owner holds it in the kits: the thumb on one side and two fingertips
    /// under it, each about 8 mm thick, pressed against the ball (camera axes). `turn`: where round the ball (radians,
    /// in the plane facing the camera) the thumb is, from the world's down.
    static func grip(ballAt c: Vec3, radius R: Double, up: Vec3, turn: Double = 0.9) -> [Finger] {
        let u = up.normalized, toCam = (-c).normalized
        let side = u.cross(toCam).normalized, dn = -u
        func around(_ a: Double) -> Vec3 { (dn * cos(a) + side * sin(a)).normalized }
        var out: [Finger] = []
        // thumb: from below-side, its tip touching the ball's side, a little toward the camera
        let tDir = around(turn), tTip = c + tDir * (R + 0.004) + toCam * 0.004
        out.append(Finger(a: tTip, b: tTip + (tDir + dn).normalized * 0.05, radius: 0.0085, luma: 176))
        // two fingertips under it, on the other side
        for a in [-0.35, -0.95] {
            let fDir = around(a), tip = c + fDir * (R + 0.0035)
            out.append(Finger(a: tip, b: tip + (fDir * 0.4 + dn + toCam * 0.3).normalized * 0.05, radius: 0.008, luma: 168))
        }
        return out
    }
}
