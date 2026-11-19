import Foundation

/// When the tilt may be shown, and how its honest uncertainty is built (`HonestTilt`, `SlabTracker.tiltSigmaDegrees`,
/// `angleSettled`). The constants were measured on the owner's first kit (slab-kit-20261118-205900, one slab, phone and
/// floor; replays of the rule on both checkers' edge sets and the n10 tracker's own outlines): they are to be confirmed on
/// renders and the next kit.
public struct SettleSettings: Equatable {
    /// A side's parallel noise never counts as less than this angle seen from the camera (radians; times the focal length
    /// in pixels: 0.12 px at the kit's 1016 px focal length). Measured: a still camera's sides jitter by 0.11-0.14 px from
    /// frame to frame, and the scatter of a side's edge points about its line gives 0.09-0.10 px.
    public var parallelFloorRadians = 1.2e-4
    /// A side's turn about its middle never counts as less than this (radians; 0.2 px at its ends at 1016 px). Measured:
    /// still sides' ends move by 0.22-0.43 px, roll included. Without the turn the misfit test rejects nearly every still
    /// detection (26 of 27 on one shot): parallel moves cannot explain the misfit's other direction.
    public var turnFloorRadians = 2.0e-4
    /// Motion blur's share of a side's parallel noise (pixels per pixel of blur, `KitMotionBlur.pixels`). Measured: the
    /// per-side error of outlines that fit the square goes from 0.45 px with blur under 0.75 px to 1.2 px with blur over 4.
    public var blurShare = 0.35
    /// the exposure assumed for blur when a frame does not give one (s)
    public var defaultExposure = 1.0 / 60
    /// Views of the slab (directions from it to the camera) within this angle of a group's first are one view (degrees):
    /// their errors are correlated, so they are averaged rather than added. The kit's error correlation fell to 1/e at
    /// about this angle (0.97, 0.91, 0.43, 0.14 at 0-1, 1-3, 3-10, 10-20 deg of view change).
    public var groupDegrees = 7.5
    /// The newest detections kept per view (about 0.4-0.6 s of a still camera's re-checks), so a view's early detections
    /// age out within about a second.
    public var perGroup = 3
    /// A detection whose outline misfits the square beyond what its sides' noise allows (chi-square, 2 degrees of
    /// freedom; 9.21 is its 99th percentile) is left out.
    public var misfitChi2 = 9.21
    /// Settled (the tilt is shown) once the standard deviation (degrees, both tilt axes together) is at or under
    /// `settleDegrees` on `settleRefreshes` refreshes in a row; back to settling above `unsettleDegrees`. 1 deg of tilt
    /// moves the landing about 4.5 cm.
    public var settleDegrees = 1.0
    public var unsettleDegrees = 1.25
    public var settleRefreshes = 2
    public init() {}
}

/// The tilt's honest uncertainty, separate from the lock (which keeps its own estimate, gates and history): the lock's
/// detections grouped by view, each view's newest few averaged with one view's uncertainty (not divided by their number:
/// one view's errors are mostly the same error), the views combined, and these safeguards:
///   - per side, each detection's noise includes the edge's own uncertainty (`SlabTracker` Measurement's side sigmas);
///   - a detection whose outline misfits the square beyond what that noise allows is left out;
///   - the part of a side's noise that is the same error in every view (the edge's definition on the slab, the profile's
///     uncertainty, a one-edge side's ambiguity: `DetectedOutline.sideFrameSigmas` says which part is the frame's own)
///     is carried as one error per side of the slab, common to all views, so more views do not shrink it;
///   - a view's detections that disagree beyond their own noise widen that view's own part by their disagreement;
///   - views that disagree beyond their uncertainties widen the result by their disagreement.
/// The tilt is shown (`settled`) once its standard deviation is at or under `SettleSettings.settleDegrees` on
/// `settleRefreshes` re-checks in a row: refreshes that added a usable detection after the lock (the lock's own
/// detections, taken in one moment, and left-out ones do not count).
struct HonestTilt {
    /// One detection: its normal and covariance (world, rad^2), its view direction, and how it fitted. Its covariance
    /// is `cov` plus `perCornerNoise` times the square of the corner noise (pixels) at the time it is used: the part that
    /// comes from a corner noise the tracker is still measuring (`SlabTracker.cornerNoiseEstimate`, the fallback while a
    /// detector gives no per-side noise) follows what it has measured since.
    struct Detection {
        var normal: Vec3
        /// the covariance of the detection's own error (this frame's: the edge points' scatter, blur), world rad^2
        var cov: Mat3
        var perCornerNoise: Mat3 = zero3
        /// unit direction from the slab's centre to the camera (world)
        var view: Vec3
        /// misfit chi-square against what the sides' noise allowed when it was added, its degrees of freedom, and whether
        /// it was left out
        var chi2: Double
        var dof: Int
        var excluded: Bool
        /// the corner noise it was added with (pixels; 0 when it has no such part)
        var cornerNoise: Double = 0
        /// Per side of the pose (side i from corner i to i+1): the normal's change (world, radians) for one sigma of the
        /// side's error that is the same in every view (`DetectedOutline.sideFrameSigmas`), and the side's outward
        /// direction (world), which tells the same side of the slab in other detections. Empty: no such part.
        var shared: [Vec3] = []
        var sideOut: [Vec3] = []
        /// the covariance of its own error, with the corner-noise part at `s` pixels
        func ownCovariance(cornerNoise s: Double) -> Mat3 { add3(cov, scale3(perCornerNoise, s * s)) }
        /// its whole covariance: its own and the shared part
        func covariance(cornerNoise s: Double) -> Mat3 { shared.reduce(ownCovariance(cornerNoise: s)) { add3($0, outer3($1, $1)) } }
        /// the detection's own standard deviation (degrees), as it was added
        var sigmaDegrees: Double { Units.degrees(max(0, HonestTilt.trace(covariance(cornerNoise: cornerNoise))).squareRoot()) }
    }
    struct Group {
        var anchor: Vec3
        var members: [Detection]
    }

    var settings: SettleSettings
    private(set) var groups: [Group] = []
    /// the combined normal (world) and its covariance across it (rad^2), after the last refresh; nil before any view
    private(set) var normal: Vec3? = nil
    private(set) var cov: Mat3? = nil
    /// sqrt(trace) of `cov` in degrees (nil before any view), and the consistency inflation applied
    private(set) var sigmaDegrees: Double? = nil
    private(set) var inflation = 1.0
    private(set) var settled = false
    private var previousOk = 0
    /// how many refreshes there have been since the estimate was made (not reset; for scoring per refresh)
    private(set) var refreshCount = 0

    init(settings: SettleSettings) { self.settings = settings }

    mutating func reset() {
        groups = []; normal = nil; cov = nil; sigmaDegrees = nil; inflation = 1; settled = false; previousOk = 0
    }

    /// A detection's covariance and misfit, from its pose (world), its outline (pose order, pixels of `view`), the camera
    /// and its sides' noise (pixels, pose side order): parallel and turn; with `cornerNoise`, also a corner noise of that
    /// many pixels split equally into each side's shift and turn (s^2 / 2 each: the per-corner model), kept apart
    /// (`Detection.perCornerNoise`). `shift` (pixels outward, pose side order): sides to move before use (e.g. a one-edge
    /// side to the middle of its two possible readings, `DetectedOutline.sideShifts`; the tracker does not, see its
    /// sideNoise); the normal and the misfit follow through the linearised fit (a shift of a band's half moves the normal
    /// by about a degree, well inside the fit's linear range). nil when the fit cannot be linearised.
    /// `shared` (pixels, pose side order): the part of each side's `parallel` noise that is the same error in every view
    /// (`Detection.shared`); nil: none (all of it the detection's own).
    static func detection(pose: SlabPose, quad: [Vec2], view: CameraView, parallel: [Double], turn: [Double], shift: [Double]? = nil,
                          shared: [Double]? = nil, cornerNoise: Double? = nil, settings: SettleSettings) -> Detection? {
        guard quad.count == 4, parallel.count == 4, turn.count == 4 else { return nil }
        let pc = pose.transformed(by: view.cameraFromWorld)
        guard let ss = PoseSolver.sideSensitivity(pose: pc, corners: quad, intrinsics: view.intrinsics) else { return nil }
        // the sides moved to where the estimate puts them: the normal (camera axes) and the misfit follow linearly
        var nc = pc.normal, residuals = ss.residuals, shifted = false
        if let sh = shift, sh.count == 4, sh.contains(where: { $0 != 0 }) {
            shifted = true
            for s in 0..<4 where sh[s] != 0 {
                nc += ss.normalPerShift[s] * sh[s]
                for i in 0..<8 { residuals[i] += ss.residualPerShift[s][i] * sh[s] }
            }
            nc = nc.normalized
        }
        var C = zero3, U = zero3
        var Cr = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        let cn2 = pow(cornerNoise ?? 0, 2) / 2
        let sh = shared.flatMap { $0.count == 4 ? $0.map { max(0, $0) } : nil }
        for s in 0..<4 {
            let p2 = parallel[s] * parallel[s], t2 = turn[s] * turn[s]
            // the side's own part (the shared part is carried apart, `Detection.shared`)
            let own2 = max(0, p2 - pow(sh?[s] ?? 0, 2))
            let gs = outer3(ss.normalPerShift[s], ss.normalPerShift[s]), gt = outer3(ss.normalPerTurn[s], ss.normalPerTurn[s])
            C = add3(C, add3(scale3(gs, own2), scale3(gt, t2)))
            if cornerNoise != nil { U = add3(U, scale3(add3(gs, gt), 0.5)) }
            let a = ss.residualPerShift[s], b = ss.residualPerTurn[s]
            for i in 0..<8 { for j in 0..<8 { Cr[i][j] += (p2 + cn2) * a[i] * a[j] + (t2 + cn2) * b[i] * b[j] } }
        }
        let R = view.worldFromCamera.rotation
        let Cw = R * C * R.transposed, Uw = R * U * R.transposed
        // the misfit in the residual space (at most 2 dimensions: 8 corner numbers less 6 pose numbers)
        let (w, V) = HonestTilt.symmetricEigen(Cr)
        let wmax = w.max() ?? 0
        var chi2 = 0.0, dof = 0
        if wmax > 0 {
            for k in 0..<8 where w[k] > 1e-9 * wmax {
                var y = 0.0
                for i in 0..<8 { y += V[i][k] * residuals[i] }
                chi2 += y * y / w[k]; dof += 1
            }
        }
        let v = (view.position - pose.center).normalized, nw = shifted ? R * nc : pose.normal
        guard Cw.m.allSatisfy({ $0.isFinite }), Uw.m.allSatisfy({ $0.isFinite }), chi2.isFinite, v.isFinite, nw.isFinite else { return nil }
        var d = Detection(normal: nw, cov: Cw, perCornerNoise: Uw, view: v, chi2: chi2, dof: dof, excluded: chi2 > settings.misfitChi2,
                          cornerNoise: cornerNoise ?? 0)
        if let sh = sh {
            let g = (0..<4).map { R * (ss.normalPerShift[$0] * sh[$0]) }
            let c = pose.topCorners
            let out = (0..<4).map { (((c[$0] + c[($0 + 1) % 4]) * 0.5) - pose.center).normalized }
            if g.allSatisfy({ $0.isFinite }) && out.allSatisfy({ $0.isFinite }) { d.shared = g; d.sideOut = out }
        }
        return d
    }

    /// Add a detection (nil: one that could not be linearised, left out) and refresh, with the corner noise measured so
    /// far (pixels; for the detections' part that follows it). `counts`: the refresh may count toward settling (a re-check
    /// after the lock; not the lock's own detections, `SlabTracker` restarting the estimate). A detection left out (or
    /// nil) never counts, and starts the count again: it is evidence that an outline was off.
    mutating func add(_ d: Detection?, cornerNoise: Double = 0, counts: Bool = true) {
        var usable = false
        if let d = d, !d.excluded {
            usable = true
            let lim = Units.radians(settings.groupDegrees)
            if let i = groups.firstIndex(where: { $0.anchor.angle(to: d.view) < lim }) {
                groups[i].members.append(d)
                let k = max(1, settings.perGroup)
                if groups[i].members.count > k { groups[i].members.removeFirst(groups[i].members.count - k) }
            } else {
                groups.append(Group(anchor: d.view, members: [d]))
            }
        }
        refresh(cornerNoise: cornerNoise, counts: counts && usable)
    }

    /// Combine the views and update `settled` (`counts`: as in `add`; a refresh that does not count starts the count
    /// again).
    ///
    /// Each view: its detections' normals averaged, its own part of their covariance averaged (one view's errors are
    /// mostly the same error) and widened by their scatter beyond it (chi-square over 2(k - 1)), and its shared part per
    /// side of the slab (the members' `Detection.shared` matched to the sides by direction) averaged. The views are
    /// combined with weights from their whole covariances; the result's covariance carries each view's own part through
    /// its weight, and the shared parts summed over the views before squaring: an error common to every view does not
    /// shrink with their number (views of the same side from opposite directions can still cancel it). Views that
    /// disagree beyond their whole covariances widen the result (chi-square over 2(G - 1)).
    mutating func refresh(cornerNoise: Double = 0, counts: Bool = true) {
        refreshCount += 1
        guard !groups.isEmpty else {
            normal = nil; cov = nil; sigmaDegrees = nil; inflation = 1
            previousOk = 0; settled = false
            return
        }
        // the slab's sides (outward, world) the shared parts are matched to: the first detection's that has them
        let ref = groups.lazy.flatMap { $0.members }.first(where: { $0.shared.count == 4 && $0.sideOut.count == 4 })?.sideOut
        func sharedBySide(_ m: Detection) -> [Vec3] {
            var out = [Vec3](repeating: .zero, count: 4)
            guard let ref = ref, m.shared.count == 4, m.sideOut.count == 4 else { return out }
            for s in 0..<4 {
                let p = (0..<4).max(by: { m.sideOut[s].dot(ref[$0]) < m.sideOut[s].dot(ref[$1]) })!
                out[p] += m.shared[s]
            }
            return out
        }
        var gn: [Vec3] = [], gOwn: [Mat3] = [], gSh: [[Vec3]] = [], gC: [Mat3] = []
        for g in groups {
            let k = Double(g.members.count)
            let msh = g.members.map(sharedBySide)
            var n = Vec3.zero, C = zero3, sh = [Vec3](repeating: .zero, count: 4)
            for (m, ms) in zip(g.members, msh) {
                n += m.normal; C = add3(C, m.ownCovariance(cornerNoise: cornerNoise))
                for p in 0..<4 { sh[p] += ms[p] }
            }
            n = n.normalized; C = scale3(C, 1 / k); sh = sh.map { $0 / k }
            // the view's detections against each other: what they share cancels, their own errors (and any difference in
            // their shared parts) should explain the rest
            if g.members.count >= 2 {
                var chi = 0.0
                for (m, ms) in zip(g.members, msh) {
                    var Cm = m.ownCovariance(cornerNoise: cornerNoise)
                    for p in 0..<4 { let e = ms[p] - sh[p]; Cm = add3(Cm, outer3(e, e)) }
                    let d = m.normal - n
                    chi += d.dot(HonestTilt.information(Cm, n) * d)
                }
                C = scale3(C, max(1, chi / (2 * (k - 1))))
            }
            gn.append(n); gOwn.append(C); gSh.append(sh)
            gC.append(sh.reduce(C) { add3($0, outer3($1, $1)) })
        }
        var n0 = Vec3.zero
        for n in gn { n0 += n }
        n0 = n0.normalized
        var J = zero3, b = Vec3.zero
        var W: [Mat3] = []
        for (n, C) in zip(gn, gC) {
            let I = HonestTilt.information(C, n0)
            W.append(I)
            J = add3(J, I); b += I * (n - n0)
        }
        let Pn = outer3(n0, n0)
        let Cn = HonestTilt.inverse(add3(J, Pn)).map { add3($0, scale3(Pn, -1)) } ?? scale3(add3(.identity, scale3(Pn, -1)), 1)
        let n = (n0 + Cn * b).normalized
        // the combined covariance: each view's own part through its weight; the shared parts summed before squaring
        var Cc = zero3, shc = [Vec3](repeating: .zero, count: 4)
        for g in gn.indices {
            let A = Cn * W[g]
            Cc = add3(Cc, A * gOwn[g] * A.transposed)
            for p in 0..<4 { shc[p] += A * gSh[g][p] }
        }
        Cc = shc.reduce(Cc) { add3($0, outer3($1, $1)) }
        var infl = 1.0
        if gn.count >= 2 {
            var chi = 0.0
            for (g, C) in zip(gn, gC) { let d = g - n; chi += d.dot(HonestTilt.information(C, n) * d) }
            infl = max(1, chi / (2 * Double(gn.count - 1)))
        }
        let Ct = scale3(HonestTilt.across(Cc, n), infl)
        normal = n; cov = Ct; inflation = infl
        let sig = Units.degrees(max(0, HonestTilt.trace(Ct)).squareRoot())
        sigmaDegrees = sig
        let ok = sig <= settings.settleDegrees
        previousOk = counts && ok ? previousOk + 1 : 0
        settled = settled ? sig <= settings.unsettleDegrees : previousOk >= max(1, settings.settleRefreshes)
    }

    // MARK: small matrices

    static func trace(_ a: Mat3) -> Double { a[0, 0] + a[1, 1] + a[2, 2] }

    /// C with its parts along n removed: (I - n n^T) C (I - n n^T)
    static func across(_ C: Mat3, _ n: Vec3) -> Mat3 {
        let Q = add3(.identity, scale3(outer3(n, n), -1))
        return Q * C * Q
    }

    /// The information across n of a covariance (its inverse there; nothing along n). A tiny floor keeps an exact
    /// measurement finite.
    static func information(_ C: Mat3, _ n: Vec3) -> Mat3 {
        let P = outer3(n, n), Q = add3(.identity, scale3(P, -1))
        guard let Ai = inverse(add3(add3(across(C, n), P), scale3(Q, 1e-14))) else { return zero3 }
        return add3(Ai, scale3(P, -1))
    }

    /// The inverse of a symmetric 3x3 matrix, scaled first so tiny covariances invert.
    static func inverse(_ A: Mat3) -> Mat3? {
        let s = A.m.map { abs($0) }.max() ?? 0
        guard s > 0, s.isFinite, let i = scale3(A, 1 / s).inverse else { return nil }
        return scale3(i, 1 / s)
    }

    /// Eigenvalues and eigenvectors (columns of V) of a symmetric matrix, by cyclic Jacobi rotations.
    static func symmetricEigen(_ M: [[Double]]) -> ([Double], [[Double]]) {
        let n = M.count
        var A = M
        var V = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<60 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<max(i + 1, n) { off += A[i][j] * A[i][j] } }
            var diag = 0.0
            for i in 0..<n { diag += A[i][i] * A[i][i] }
            if off <= 1e-30 * max(diag, 1e-300) { break }
            for p in 0..<n {
                for q in (p + 1)..<max(p + 1, n) where A[p][q] != 0 {
                    let theta = (A[q][q] - A[p][p]) / (2 * A[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = A[k][p], akq = A[k][q]
                        A[k][p] = c * akp - s * akq; A[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = A[p][k], aqk = A[q][k]
                        A[p][k] = c * apk - s * aqk; A[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = V[k][p], vkq = V[k][q]
                        V[k][p] = c * vkp - s * vkq; V[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<n).map { A[$0][$0] }, V)
    }
}

let zero3 = Mat3(rows: [0, 0, 0, 0, 0, 0, 0, 0, 0])
func add3(_ a: Mat3, _ b: Mat3) -> Mat3 { Mat3(rows: zip(a.m, b.m).map { $0 + $1 }) }
func scale3(_ a: Mat3, _ s: Double) -> Mat3 { Mat3(rows: a.m.map { $0 * s }) }
func outer3(_ a: Vec3, _ b: Vec3) -> Mat3 { Mat3(rows: [a.x * b.x, a.x * b.y, a.x * b.z, a.y * b.x, a.y * b.y, a.y * b.z, a.z * b.x, a.z * b.y, a.z * b.z]) }

extension SettleSettings: Codable {
    /// Every stored property (a test checks this list against the struct's properties).
    static let codingFields: [SettingsField<SettleSettings>] = [
        .init("parallelFloorRadians", \.parallelFloorRadians),
        .init("turnFloorRadians", \.turnFloorRadians),
        .init("blurShare", \.blurShare),
        .init("defaultExposure", \.defaultExposure),
        .init("groupDegrees", \.groupDegrees),
        .init("perGroup", \.perGroup),
        .init("misfitChi2", \.misfitChi2),
        .init("settleDegrees", \.settleDegrees),
        .init("unsettleDegrees", \.unsettleDegrees),
        .init("settleRefreshes", \.settleRefreshes),
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        try SettingsField.decode(into: &self, SettleSettings.codingFields, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try SettingsField.encode(self, SettleSettings.codingFields, to: encoder)
    }
}
