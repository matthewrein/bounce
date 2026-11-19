import Foundation

/// How a fitted pose answers small moves of the outline's four sides: the square fit linearised at its solution. A
/// detector places each side's line on an edge; its error is a shift of the line parallel to itself (the edge taken a
/// little in or out) and a turn about the side's middle. Through the linearised fit each move turns the normal
/// (`normalPerShift`, `normalPerTurn`) and leaves some corner misfit that no pose can absorb (`residualPerShift`,
/// `residualPerTurn`): what a side's error costs in the fit's misfit (`PoseSolver.Options` sigma aside). With these, per-side
/// noise becomes the normal's covariance, and the fit's actual misfit can be judged against what that noise allows
/// (`HonestTilt`).
///
/// Sides are the pose's (side i runs from pose corner i to i+1); corner residuals are 8 numbers, x then y of each pose
/// corner; pixels of the image the corners are in; camera axes.
public struct SideSensitivity: Equatable {
    /// the normal's change (radians, camera axes) per pixel of side i's line moved outward, parallel to itself
    public var normalPerShift: [Vec3]
    /// the same per pixel of side i turned about its middle (its end corner moved out by a pixel, its start in)
    public var normalPerTurn: [Vec3]
    /// the corner misfit (pixels) those moves leave after refitting, per side
    public var residualPerShift: [[Double]]
    public var residualPerTurn: [[Double]]
    /// the fit's own corner misfit: observed minus fitted corners (pixels, pose order, x then y)
    public var residuals: [Double]
}

extension PoseSolver {
    /// The pose's answer to moves of the outline's sides (see `SideSensitivity`). `pose`: the fitted pose (camera axes);
    /// `corners`: the outline it was fitted to, in pose order (element i is where pose corner i was seen). nil when a
    /// corner does not project or the fit is degenerate.
    public static func sideSensitivity(pose: SlabPose, corners q: [Vec2], intrinsics K: CameraIntrinsics) -> SideSensitivity? {
        guard q.count == 4 else { return nil }
        let n = pose.normal
        func projected(_ w: Vec3, _ dt: Vec3) -> [Double]? {
            let u = pose.axisU.rotated(by: w), v = pose.axisV.rotated(by: w), c = pose.center + dt
            var o: [Double] = []
            o.reserveCapacity(8)
            for s in slabCornerSigns {
                guard let p = K.project(c + u * (s.0 * pose.halfU) + v * (s.1 * pose.halfV)) else { return nil }
                o.append(p.x); o.append(p.y)
            }
            return o
        }
        guard let c0 = projected(.zero, .zero) else { return nil }
        // the corners' Jacobian (8 x 6: rotation vector, then translation), by central differences
        let hr = 1e-6, ht = max(pose.center.length * 1e-6, 1e-9)
        var J = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 8)
        for j in 0..<6 {
            var e = Vec3.zero
            switch j % 3 { case 0: e.x = 1; case 1: e.y = 1; default: e.z = 1 }
            let h = j < 3 ? hr : ht
            guard let a = j < 3 ? projected(e * h, .zero) : projected(.zero, e * h),
                  let b = j < 3 ? projected(e * -h, .zero) : projected(.zero, e * -h) else { return nil }
            for r in 0..<8 { J[r][j] = (a[r] - b[r]) / (2 * h) }
        }
        // P = (J^T J)^-1 J^T (6 x 8): the least-squares pose change for a corner change
        var A = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for i in 0..<6 { for j in 0..<6 { var s = 0.0; for r in 0..<8 { s += J[r][i] * J[r][j] }; A[i][j] = s } }
        var P = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 6)
        for r in 0..<8 {
            guard let x = solveLinear(A, (0..<6).map { J[r][$0] }) else { return nil }
            for i in 0..<6 { P[i][r] = x[i] }
        }
        // the normal's change per corner coordinate: a small turn w moves the normal by w x n
        func normalChange(_ dc: [Double]) -> Vec3 {
            var w = Vec3.zero
            for r in 0..<8 { w += Vec3(P[0][r], P[1][r], P[2][r]) * dc[r] }
            return w.cross(n)
        }
        // what refitting leaves of a corner change: (I - J P) dc
        func residual(_ dc: [Double]) -> [Double] {
            var x = [Double](repeating: 0, count: 6)
            for i in 0..<6 { var s = 0.0; for r in 0..<8 { s += P[i][r] * dc[r] }; x[i] = s }
            return (0..<8).map { r in dc[r] - (0..<6).reduce(0) { $0 + J[r][$1] * x[$1] } }
        }
        // the corners' change for a side moved or turned: the four lines' meeting points, by central differences
        let eps = 1e-3
        var shift: [Vec3] = [], turn: [Vec3] = [], resShift: [[Double]] = [], resTurn: [[Double]] = []
        for s in 0..<4 {
            for turning in [false, true] {
                guard let a = SideSensitivity.moved(q, side: s, by: eps, turn: turning),
                      let b = SideSensitivity.moved(q, side: s, by: -eps, turn: turning) else { return nil }
                var dc = [Double](repeating: 0, count: 8)
                for k in 0..<4 { dc[2 * k] = (a[k].x - b[k].x) / (2 * eps); dc[2 * k + 1] = (a[k].y - b[k].y) / (2 * eps) }
                if turning { turn.append(normalChange(dc)); resTurn.append(residual(dc)) } else { shift.append(normalChange(dc)); resShift.append(residual(dc)) }
            }
        }
        var res = [Double](repeating: 0, count: 8)
        for k in 0..<4 { res[2 * k] = q[k].x - c0[2 * k]; res[2 * k + 1] = q[k].y - c0[2 * k + 1] }
        return SideSensitivity(normalPerShift: shift, normalPerTurn: turn, residualPerShift: resShift, residualPerTurn: resTurn, residuals: res)
    }
}

extension SideSensitivity {
    /// The outline with side s's line moved outward by d pixels (`turn` false), or turned about its middle so its end
    /// corner moves out by d and its start in by d (`turn` true): its corners where neighbouring lines meet.
    static func moved(_ q: [Vec2], side s: Int, by d: Double, turn: Bool) -> [Vec2]? {
        let c = (q[0] + q[1] + q[2] + q[3]) / 4
        var lines: [(Vec2, Vec2)] = []
        for i in 0..<4 {
            var a = q[i], b = q[(i + 1) % 4]
            if i == s {
                var o = (b - a).perpendicular.normalized
                if o.dot((a + b) / 2 - c) < 0 { o = -o }
                if turn { a = a - o * d; b = b + o * d } else { a = a + o * d; b = b + o * d }
            }
            lines.append((a, b))
        }
        var out: [Vec2] = []
        for k in 0..<4 {
            guard let p = SlabBoxView.intersect(lines[(k + 3) % 4], lines[k]) else { return nil }
            out.append(p)
        }
        return out
    }
}
