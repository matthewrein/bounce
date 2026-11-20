import Foundation

/// n18: the lock's outline from all its views at once (`TrackerSettings.multiViewLock`).
///
/// Each detection's pose is fitted from one view at the known size, so a corner error of a processing pixel is a depth
/// error of 1-3 cm along that view's line of sight: the lock, an average of such poses, looks right from where it was
/// made and visibly off from elsewhere (the owner, n16; the fusion audit of both kits: per-view depth sd 14-56 mm, the
/// shown lock wandering 7-22 mm). Here the lock's own detections, kept per view (`ViewStore`), are fitted
/// together: the centre (3) and the turn about the normal (1) that put the square's corners, at the size setting, nearest
/// every detection's outline corners in its own camera (reprojection, processing pixels). The normal is held at the lock's
/// (so the tilt, its honest uncertainty and the readouts' normal are unchanged) and so is the size. The same fit with the
/// size free says what size the views imply (diagnostics only).
public enum MultiViewLock {
    /// at most this many views of the slab are kept (newest first), each its newest `SettleSettings.perGroup` detections
    public static let maxViews = 12
    /// the fit is used once its views span at least this angle (deg: two views closer than this pin depth little better
    /// than one)
    public static let minSpreadDegrees = 15.0
    /// and only if it fits its detections to this rms (processing px) and moves the lock's centre at most this far (m);
    /// otherwise the lock is the single-view average, as before
    public static let maxRmsPixels = 1.5
    public static let maxShift = 0.025
    /// a detection misfitting by more than this many times the median detection's rms (at least `minDropPixels`) is left
    /// out (an outline on the outer edge of a side, a lookalike) and the fit run again
    public static let dropFactor = 3.0
    public static let minDropPixels = 1.0

    /// One detection: its outline's four corners (processing pixels of `camera`, any order), the camera it was seen from,
    /// and its own single-view pose (world; for the corner spread).
    public struct Observation {
        public var quad: [Vec2]
        public var camera: CameraView
        public var pose: SlabPose?
        public init(quad: [Vec2], camera: CameraView, pose: SlabPose? = nil) { self.quad = quad; self.camera = camera; self.pose = pose }
    }

    public struct Fit {
        /// the lock at the fitted centre and turn (its normal and size the given lock's; with `freeSize`, its size scaled)
        public var pose: SlabPose
        /// rms reprojection misfit over the corners of the detections kept (processing px)
        public var rmsPixels: Double
        /// detections kept, views among them (directions from the fitted centre more than `groupDegrees` apart), and the
        /// widest angle between two of them (deg)
        public var used: Int
        public var views: Int
        public var spreadDegrees: Double
        /// the size's scale (1 unless `freeSize`)
        public var scale: Double
        /// the kept detections' own single-view corners: rms spread about their mean (m), nil with fewer than two poses
        public var cornerSpread: Double?
    }

    /// The lock's detections kept per view: a view is anchored at the direction (from the slab to the camera) of the
    /// first detection that started it, and a detection joins the nearest view whose anchor lies within `groupDegrees`,
    /// else starts a view of its own. Each view keeps its newest `perGroup`; at most `maxViews` views are kept (those
    /// seen last). Anchors do not move with the views' newer detections, so a camera walking round the slab leaves a
    /// view behind every `groupDegrees` instead of one view sliding along with it.
    public struct ViewStore<T> {
        public private(set) var items: [(item: T, view: Int)] = []
        private var anchors: [Int: Vec3] = [:]
        private var nextView = 0
        public init() {}
        public var values: [T] { items.map { $0.item } }
        public var isEmpty: Bool { items.isEmpty }
        public mutating func removeAll() { items = []; anchors = [:] }
        /// add a detection seen from `direction` (nil: not kept)
        public mutating func add(_ x: T, direction: Vec3?, groupDegrees: Double, perGroup: Int, maxViews: Int = MultiViewLock.maxViews) {
            guard let v = direction, v.isFinite, v.length > 0 else { return }
            let d = v.normalized, lim = Units.radians(groupDegrees)
            let near = anchors.filter { $0.value.angle(to: d) < lim }.min { $0.value.angle(to: d) < $1.value.angle(to: d) }?.key
            let id: Int
            if let j = near { id = j } else { id = nextView; nextView += 1; anchors[id] = d }
            items.append((x, id))
            // each view its newest perGroup
            let k = max(1, perGroup)
            var seen: [Int: Int] = [:], keep = [Bool](repeating: false, count: items.count)
            for i in items.indices.reversed() {
                let c = seen[items[i].view, default: 0]
                if c < k { keep[i] = true; seen[items[i].view] = c + 1 }
            }
            // at most maxViews views: those seen last
            var order: [Int] = []
            for i in items.indices.reversed() where !order.contains(items[i].view) { order.append(items[i].view) }
            let live = Set(order.prefix(max(1, maxViews)))
            items = items.indices.filter { keep[$0] && live.contains(items[$0].view) }.map { items[$0] }
            anchors = anchors.filter { live.contains($0.key) }
        }
        /// the same detections changed in place (their views kept)
        public mutating func update(_ f: (T) -> T) { items = items.map { (f($0.item), $0.view) } }
    }

    /// The views among directions (unit or not): how many groups `groupDegrees` apart, and the widest angle between two
    /// groups (deg).
    public static func views(_ directions: [Vec3], groupDegrees: Double) -> (count: Int, spreadDegrees: Double) {
        let lim = Units.radians(groupDegrees)
        var groups: [Vec3] = []
        for v in directions where v.isFinite && v.length > 0 {
            let d = v.normalized
            if !groups.contains(where: { $0.angle(to: d) < lim }) { groups.append(d) }
        }
        var spread = 0.0
        for a in groups.indices { for b in groups.indices where b > a { spread = max(spread, groups[a].angle(to: groups[b])) } }
        return (groups.count, Units.degrees(spread))
    }

    /// The best of the eight orderings of `quad` onto `ref` (the square's turns and its mirror): `quad` reordered.
    static func matched<T>(_ quad: [T], to ref: [T], distance: (T, T) -> Double) -> [T] {
        guard quad.count == 4, ref.count == 4 else { return quad }
        var best = quad, bestCost = Double.infinity
        for s in 0..<4 {
            for d in [1, -1] {
                let idx = (0..<4).map { ((s + d * $0) % 4 + 4) % 4 }
                let c = (0..<4).reduce(0.0) { $0 + distance(quad[idx[$1]], ref[$1]) }
                if c < bestCost { bestCost = c; best = idx.map { quad[$0] } }
            }
        }
        return best
    }

    /// The pose at parameters x (centre offset 3, turn about the normal, log of the size's scale) from the lock.
    static func pose(_ L: SlabPose, _ x: [Double]) -> SlabPose {
        let n = L.normal, a = x[3], k = x.count > 4 ? exp(x[4]) : 1
        let u = (L.axisU * cos(a) + L.axisV * sin(a)).rejecting(n).normalized
        return SlabPose(center: L.center + Vec3(x[0], x[1], x[2]), normal: n, axisU: u, axisV: n.cross(u), halfU: L.halfU * k, halfV: L.halfV * k)
    }

    /// The lock fitted to all the detections at once (see the type's note); nil when no detection projects, or the fit
    /// fails. `freeSize`: the size is fitted too (diagnostics). Detections misfitting beyond `dropFactor` times the median
    /// are left out and the fit run again. The guards (views, spread, rms, shift) are the caller's.
    public static func fit(lock L: SlabPose, observations: [Observation], groupDegrees: Double, freeSize: Bool = false) -> Fit? {
        // each detection's corners in the lock's corner order: the ordering nearest the lock's projection in its view
        var obs: [(quad: [Vec2], camera: CameraView, pose: SlabPose?)] = []
        for o in observations where o.quad.count == 4 {
            let p = L.topCorners.compactMap { o.camera.project(world: $0) }
            guard p.count == 4 else { continue }
            obs.append((matched(o.quad, to: p) { $0.distance(to: $1) }, o.camera, o.pose))
        }
        guard !obs.isEmpty else { return nil }
        let np = freeSize ? 5 : 4
        var x = [Double](repeating: 0, count: np)
        var active = Array(obs.indices)

        // residuals (px) of the detections in `active` at parameters x: nil if a corner does not project
        func residuals(_ x: [Double], _ ids: [Int]) -> [Double]? {
            let C = pose(L, x).topCorners
            var r: [Double] = []
            r.reserveCapacity(ids.count * 8)
            for i in ids {
                for k in 0..<4 {
                    guard let q = obs[i].camera.project(world: C[k]), q.x.isFinite, q.y.isFinite else { return nil }
                    r.append(q.x - obs[i].quad[k].x); r.append(q.y - obs[i].quad[k].y)
                }
            }
            return r
        }
        func solve(_ ids: [Int]) -> Bool {
            for _ in 0..<12 {
                guard let r0 = residuals(x, ids) else { return false }
                // forward differences: metres, radians, log scale
                let h = 1e-6
                var J = [[Double]](repeating: [Double](repeating: 0, count: np), count: r0.count)
                for j in 0..<np {
                    var xp = x; xp[j] += h
                    guard let r1 = residuals(xp, ids) else { return false }
                    for i in r0.indices { J[i][j] = (r1[i] - r0[i]) / h }
                }
                var A = [[Double]](repeating: [Double](repeating: 0, count: np), count: np), b = [Double](repeating: 0, count: np)
                for i in r0.indices {
                    for p in 0..<np {
                        b[p] -= J[i][p] * r0[i]
                        for q in 0..<np { A[p][q] += J[i][p] * J[i][q] }
                    }
                }
                for p in 0..<np { A[p][p] *= 1 + 1e-9; A[p][p] += 1e-12 }
                guard let dx = solveLinear(A, b), dx.allSatisfy({ $0.isFinite }) else { return false }
                for j in 0..<np { x[j] += dx[j] }
                if dx.reduce(0, { $0 + $1 * $1 }).squareRoot() < 1e-9 { break }
            }
            return true
        }
        func rms(_ i: Int) -> Double? {
            guard let r = residuals(x, [i]) else { return nil }
            return (r.reduce(0) { $0 + $1 * $1 } / 4).squareRoot()
        }
        guard solve(active) else { return nil }
        // leave out the detections misfitting far beyond the rest, and fit again
        let per = active.map { rms($0) ?? .infinity }
        let lim = max(minDropPixels, dropFactor * KitStats.median(per.filter { $0.isFinite }))
        let kept = zip(active, per).filter { $0.1 <= lim }.map { $0.0 }
        if kept.count < active.count, !kept.isEmpty {
            active = kept
            guard solve(active) else { return nil }
        }
        guard let r = residuals(x, active) else { return nil }
        let P = pose(L, x)
        let v = views(active.map { obs[$0].camera.position - P.center }, groupDegrees: groupDegrees)
        // the kept detections' own corners, in the fitted pose's order: their spread about their mean
        var spread: Double? = nil
        let own = active.compactMap { obs[$0].pose?.topCorners }.map { matched($0, to: P.topCorners) { $0.distance(to: $1) } }
        if own.count >= 2 {
            var s2 = 0.0
            for k in 0..<4 {
                let mean = own.reduce(Vec3.zero) { $0 + $1[k] } / Double(own.count)
                s2 += own.reduce(0) { $0 + pow($1[k].distance(to: mean), 2) }
            }
            spread = (s2 / Double(4 * own.count)).squareRoot()
        }
        return Fit(pose: P, rmsPixels: (r.reduce(0) { $0 + $1 * $1 } / Double(r.count / 2)).squareRoot(), used: active.count,
                   views: v.count, spreadDegrees: v.spreadDegrees, scale: freeSize ? exp(x[4]) : 1, cornerSpread: spread)
    }

    /// Ax = b by Gaussian elimination with partial pivoting (small systems); nil when singular.
    static func solveLinear(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0
        let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-300 else { return nil }
            if p != c { A.swapAt(p, c); b.swapAt(p, c) }
            for r in (c + 1)..<n where r < n {
                let f = A[r][c] / A[c][c]
                if f == 0 { continue }
                for k in c..<n { A[r][k] -= f * A[c][k] }
                b[r] -= f * b[c]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for k in (r + 1)..<n where k < n { s -= A[r][k] * x[k] }
            x[r] = s / A[r][r]
        }
        return x
    }

    /// The largest distance of a corner from its mean over a run of the lock's corner sets (m), each matched to the first's
    /// order; nil with fewer than two.
    public static func drift(_ sets: [[Vec3]]) -> Double? {
        guard sets.count >= 2, let ref = sets.first, ref.count == 4 else { return nil }
        let m = sets.map { matched($0, to: ref) { $0.distance(to: $1) } }
        var worst = 0.0
        for k in 0..<4 {
            let mean = m.reduce(Vec3.zero) { $0 + $1[k] } / Double(m.count)
            for s in m { worst = max(worst, s[k].distance(to: mean)) }
        }
        return worst
    }
}

/// What the multi-view lock did on the latest refresh (`SlabTracker.multiView`, diagnostics' `multiView`).
public struct MultiViewSummary: Codable, Equatable {
    /// views of the slab among the detections kept for it (`MultiViewLock.ViewStore`), and those detections
    public var views: Int
    public var detections: Int
    /// the widest angle between two of those views (deg)
    public var spreadDegrees: Double
    /// the outline and the path use the fit (`MultiViewLock`); otherwise why not ("views": fewer than two or spread under
    /// 15 deg, "fit": it failed, "rms", "shift": a guard)
    public var applied: Bool
    public var reason: String?
    /// the fit's rms misfit (processing px) and how far it moved the lock's centre from the single-view average (mm)
    public var rmsPixels: Double?
    public var shiftMm: Double?
    /// the top's size the views imply with the size left free (mm, mean side), against the size setting (mm)
    public var impliedSizeMm: Double?
    public var sizeSettingMm: Double
    /// the detections' own single-view corners (world): their rms spread about their mean (mm): what the lock moved with
    /// before n18
    public var cornerSpreadMm: Double?
    /// the shown lock's corners over its latest refreshes (world): the largest distance of one from its mean (mm)
    public var lockDriftMm: Double?

    public var rounded: MultiViewSummary {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var s = self
        s.spreadDegrees = r(spreadDegrees); s.rmsPixels = rmsPixels.map(r); s.shiftMm = shiftMm.map(r); s.impliedSizeMm = impliedSizeMm.map(r)
        s.sizeSettingMm = r(sizeSettingMm); s.cornerSpreadMm = cornerSpreadMm.map(r); s.lockDriftMm = lockDriftMm.map(r)
        return s
    }
}
