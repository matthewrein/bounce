import Foundation

// Tap to set the ball (`TrackerSettings.tapSetsBall`): a tap on the ball held over the locked slab is the owner saying
// "the ball is here". If the ball finder finds a ball in the tap's box within `TrackerSettings.tapAcceptSeconds`, that
// ball is accepted at once (the owner's word for it: `TrackerOutput.ballUserConfirmed`). If it finds none, the ball is SET
// at the tap: its centre on the tapped line of sight, at the range LiDAR reads there, or where that line meets the
// upright plane through the slab's middle that faces the camera, if either puts it over the slab's top at a drop height
// (the nearer of the two when both do: `TapSetBall.Candidates.chosen`); neither, or LiDAR reading the slab's own top (or
// what lies beyond it) under the finger: nothing is set. A set ball is drawn with its own mark and its height over the
// slab is the drop height until a tap on it clears it, another ball tap sets or finds one elsewhere, the finder finds a
// ball close to it on two searches in a row, or the lock is lost, moves or is reset (`SlabTracker`). The geometry is
// here; the tracker keeps the state.

/// Where a set ball's place came from.
public enum SetBallSource: String, Codable, Equatable {
    /// LiDAR's range under the finger (the surface a small window reads, `TapSetBall.lidarDepth`), plus the ball's radius
    case lidar
    /// where the tapped line meets the upright plane through the slab's middle, facing the camera
    case plane
}

/// A ball the owner set by tapping it (world).
public struct SetBall: Equatable {
    /// the ball's centre (world)
    public var center: Vec3
    public var source: SetBallSource
    /// how far it falls before it touches the slab's top, when it was set (m; the drop height it gives)
    public var dropHeight: Double
    /// the tap (pixels of the processing frame) and when it was made, and when the ball was set (camera clock, s)
    public var tapPixel: Vec2
    public var tapTime: Double
    public var time: Double
    public init(center: Vec3, source: SetBallSource, dropHeight: Double, tapPixel: Vec2, tapTime: Double, time: Double) {
        self.center = center; self.source = source; self.dropHeight = dropHeight; self.tapPixel = tapPixel; self.tapTime = tapTime; self.time = time
    }
}

/// One step in what the owner's ball taps did, for diagnostics (`SlabTracker.tapLog`, `DiagnosticsReport.Taps.log`):
/// "tap" (a ball tap: the finder looks in its box first), "accepted" (a ball found in its box in time: shown at once),
/// "set" (none found: set at the tap; `source`, `center`, `dropHeight`), "nothing" (none found, and neither LiDAR's range
/// nor the plane puts a ball over the slab at a drop height: `note` says why), "cleared" (a tap on the set ball),
/// "replaced" (by a ball the finder found close to it), "ended" (the lock was lost, moved or reset: `note`).
public struct TapLogEntry: Codable, Equatable {
    /// camera clock (s)
    public var time: Double
    public var event: String
    public var source: SetBallSource?
    /// world (m)
    public var center: [Double]?
    /// the drop height the ball gives (m)
    public var dropHeight: Double?
    public var note: String?
    public init(time: Double, event: String, source: SetBallSource? = nil, center: Vec3? = nil, dropHeight: Double? = nil, note: String? = nil) {
        self.time = (time * 1000).rounded() / 1000; self.event = event; self.source = source
        self.center = center.map { [$0.x, $0.y, $0.z].map { ($0 * 10000).rounded() / 10000 } }
        self.dropHeight = dropHeight.map { ($0 * 10000).rounded() / 10000 }; self.note = note
    }
}

public enum TapSetBall {
    /// A place for the tapped ball (world centre), where it came from, the drop height it gives (m) and its range from
    /// the camera along the tapped line (m).
    public struct Placement: Equatable {
        public var center: Vec3
        public var source: SetBallSource
        public var dropHeight: Double
        public var range: Double
        public init(center: Vec3, source: SetBallSource, dropHeight: Double, range: Double) {
            self.center = center; self.source = source; self.dropHeight = dropHeight; self.range = range
        }
    }

    /// Both candidate places for a tap, each nil when it cannot be had, with why (`lidarNote`, `planeNote`): the place
    /// itself whether plausible or not (`plausible` says), so a bench can measure both.
    public struct Candidates: Equatable {
        public var lidar: Placement?
        public var lidarPlausible = false
        public var lidarNote: String?
        public var plane: Placement?
        public var planePlausible = false
        public var planeNote: String?
        /// LiDAR reads the slab's own top (or what lies beyond it) where the tapped line meets the top: nothing is held in
        /// front of the slab under the finger (`slabUnderFinger`)
        public var slabUnderFinger = false
        /// The one taken: of the plausible places, the nearer to the camera; none without one. LiDAR's range is the first
        /// surface along the line as its smoothed map has it: on a solid ball its near side, but on the owner's open
        /// lattice ball it reads past the ball, into the hand or what is behind (the owner's two kits, 7 taps on the true
        /// ball with both places plausible: LiDAR's every time beyond the plane's, its drop height 14-99 mm low, the plane's
        /// -29..+27 mm). A range nearer than the plane's is something LiDAR saw in front of the slab's middle (the ball
        /// held over the slab's near half, or the hand holding it); one beyond it may only have seen past the ball.
        /// (Nothing when LiDAR reads the slab's own top under the finger, `slabUnderFinger`.)
        public var chosen: Placement? {
            guard !slabUnderFinger else { return nil }
            let l = lidarPlausible ? lidar : nil, p = planePlausible ? plane : nil
            if let a = l, let b = p { return a.range <= b.range ? a : b }
            return l ?? p
        }
        /// as first specified: LiDAR's place when plausible, else the plane's (for comparing, `KitTapBench`)
        public var lidarFirst: Placement? { lidarPlausible ? lidar : planePlausible ? plane : nil }
        /// why nothing was taken ("lidar: ...; plane: ...", or that LiDAR read the slab's top under the finger)
        public var why: String {
            slabUnderFinger ? "lidar: the slab's top under the finger"
                : "lidar: \(lidarNote ?? (lidarPlausible ? "ok" : "-")); plane: \(planeNote ?? (planePlausible ? "ok" : "-"))"
        }
    }

    /// LiDAR under the finger: a window of this many depth pixels either side of the tapped one (5 x 5: about 15 mm across
    /// at half a metre, inside a 30 mm ball's disc when the finger is on its middle)
    public static let lidarHalfWindow = 2
    /// at least this share of the window must have a reading (0.1-8 m)
    public static let lidarMinValidShare = 0.5
    /// and the middle half of their departures from one surface (a plane through them: a surface seen at a slant reads
    /// deeper across the window) must lie within this range (m): a window across the ball's edge and what is behind it
    /// reads two surfaces, and their median is neither (one surface reads within millimetres)
    public static let lidarMaxSpread = 0.03

    /// The range (m, camera z) LiDAR reads under a tapped pixel `px` of the processing frame (`view`): the surface the
    /// window around it reads (`lidarHalfWindow`: a plane through its readings, at the tapped pixel, moved by their median
    /// departure from it), or nil with why ("none": no map or the pixel is off it; "sparse": too few readings; "spread":
    /// two surfaces).
    public static func lidarDepth(_ px: Vec2, view: CameraView, depth d: DepthMap, depthIntrinsics dk: CameraIntrinsics) -> (z: Double?, note: String?) {
        guard let q = dk.project(view.intrinsics.ray(px)) else { return (nil, "none") }
        let cx = Int(q.x.rounded(.down)), cy = Int(q.y.rounded(.down)), h = lidarHalfWindow
        guard cx >= 0, cy >= 0, cx < d.width, cy < d.height else { return (nil, "none") }
        var pts: [(dx: Double, dy: Double, z: Double)] = []
        for y in (cy - h)...(cy + h) where y >= 0 && y < d.height {
            for x in (cx - h)...(cx + h) where x >= 0 && x < d.width {
                let z = d.depth[y * d.width + x]
                if z.isFinite && z > 0.1 && z < 8 { pts.append((Double(x) + 0.5 - q.x, Double(y) + 0.5 - q.y, Double(z))) }
            }
        }
        let n = (2 * h + 1) * (2 * h + 1)
        guard Double(pts.count) >= lidarMinValidShare * Double(n) else { return (nil, "sparse") }
        // the plane z = a + b dx + c dy through them (least squares; a flat window when it cannot be fitted)
        var a = [Double](repeating: 0, count: 9), r = Vec3.zero
        for p in pts {
            let v = [1, p.dx, p.dy]
            for i in 0..<3 { for j in 0..<3 { a[i * 3 + j] += v[i] * v[j] } }
            r = r + Vec3(1, p.dx, p.dy) * p.z
        }
        let coef = Mat3(rows: a).inverse.map { $0 * r } ?? Vec3(pts.map { $0.z }.reduce(0, +) / Double(pts.count), 0, 0)
        let res = pts.map { $0.z - (coef.x + coef.y * $0.dx + coef.z * $0.dy) }.sorted()
        let k = res.count
        guard res[min(k - 1, (3 * k) / 4)] - res[k / 4] <= lidarMaxSpread else { return (nil, "spread") }
        let med = k % 2 == 1 ? res[k / 2] : (res[k / 2 - 1] + res[k / 2]) / 2
        return (coef.x + med, nil)
    }

    /// Whether a ball centred at `c` (world) lies under a tap's finger: within half again its radius plus the finger's
    /// slack of the tapped line of sight (`origin`, unit `direction`, world; `slack`: the finger's slack as an angle,
    /// radians), as seen from where the tap was made (the rule for a ring under the finger, `SlabTracker.tapKind`, as
    /// angles). A ball the finder finds in a ball tap's box but beside the finger (the hand holding the ball, a print
    /// beyond it) is not taken for the one tapped.
    public static func underFinger(_ c: Vec3, origin o: Vec3, direction d: Vec3, slack: Double, ball: BallSpec) -> Bool {
        let v = c - o, along = v.dot(d)
        guard along > 0.05 else { return false }
        let off = atan2((v - d * along).length, along)
        return off <= 1.5 * asin(min(1, ball.radius / v.length)) + slack
    }

    /// The drop height a ball centred at `center` (world) gives over the slab `slab`, as the tracker's bounce takes it
    /// (`Bounce.compute` with `rule`: the ball is used only where it lands on the slab, within 5% of its edges): nil
    /// where it would not be used.
    public static func dropHeight(center: Vec3, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3, rule: Bounce.LaunchRule) -> Double? {
        if rule == .impact {
            guard let d = Bounce.impactDrop(ballCenter: center, pose: slab, spec: spec, ball: ball, down: down), d.onSlab else { return nil }
            return d.dropHeight
        }
        guard let d = Bounce.drop(ballCenter: center, pose: slab, spec: spec, ball: ball, down: down), d.onSlab else { return nil }
        return d.dropHeight
    }

    /// Whether a place is one where the owner can hold the ball over the slab: it lands on the slab's top (`dropHeight`
    /// not nil) from at least a ball's diameter up and at most `maxHeight`. Returns the drop height when it is, else why.
    static func plausible(_ c: Vec3, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3, rule: Bounce.LaunchRule,
                          maxHeight: Double) -> (height: Double?, note: String?) {
        guard c.isFinite else { return (nil, "nowhere") }
        guard let h = dropHeight(center: c, slab: slab, spec: spec, ball: ball, down: down, rule: rule) else { return (nil, "off the slab") }
        if h < ball.diameter { return (nil, String(format: "%.0f mm over the top", h * 1000)) }
        if h > maxHeight { return (nil, String(format: "%.2f m over the top", h)) }
        return (h, nil)
    }

    /// Both places for a tap at `px` (pixels of the processing frame, camera `view`, world) over the locked slab `slab`
    /// (world): LiDAR's (when the frame has depth: the window's median range along the tapped line, which is the ball's
    /// near surface, plus the ball's radius), and the upright plane's (through the slab's middle, its normal the camera's
    /// direction from there along the floor). Each is checked (`plausible`); and whether LiDAR reads the slab's own top
    /// under the finger (`Candidates.slabUnderFinger`; `depthTolerance`: the share of the range LiDAR and the lock may
    /// differ by, the tracker's `depthMaxOffsetFraction`).
    public static func candidates(tap px: Vec2, view: CameraView, depth: DepthMap?, depthIntrinsics: CameraIntrinsics?, slab: SlabPose,
                                  spec: SlabSpec, ball: BallSpec, down: Vec3 = ARKitConvention.worldDown, rule: Bounce.LaunchRule,
                                  maxHeight: Double, depthTolerance: Double = TrackerSettings().depthMaxOffsetFraction) -> Candidates {
        var out = Candidates()
        let (o, dir) = view.ray(through: px)
        // LiDAR: the near surface along the tapped line, the centre a radius beyond it
        if let d = depth, let dk = depthIntrinsics {
            let r = lidarDepth(px, view: view, depth: d, depthIntrinsics: dk)
            if let z = r.z {
                let surface = view.toWorld(view.intrinsics.unproject(px, depth: z))
                // The tapped line meets the slab's top inside its outline, and LiDAR's surface there is the top itself or
                // lies beyond it (within the tracker's own LiDAR-against-lock tolerance, `TrackerSettings
                // .depthMaxOffsetFraction` of the range, at least 1 cm): nothing is held in front of the slab under the
                // finger; the tap was on the slab. (Where the line passes beside or beyond the slab, as through a ball held
                // above its far edge, this does not apply: what LiDAR reads there says nothing about the slab.)
                if let top = Plane3(point: slab.center, normal: slab.normal).intersect(origin: o, direction: dir) {
                    let (u, v) = slab.local(top)
                    let range = top.distance(to: o)
                    if abs(u) <= slab.halfU, abs(v) <= slab.halfV, surface.distance(to: o) >= range - max(0.01, depthTolerance * range) {
                        out.slabUnderFinger = true
                    }
                }
                let c = surface + dir * ball.radius
                let p = plausible(c, slab: slab, spec: spec, ball: ball, down: down, rule: rule, maxHeight: maxHeight)
                out.lidar = Placement(center: c, source: .lidar, dropHeight: p.height ?? dropHeight(center: c, slab: slab, spec: spec, ball: ball, down: down, rule: rule) ?? .nan,
                                      range: c.distance(to: o))
                out.lidarPlausible = p.height != nil
                out.lidarNote = p.note
            } else {
                out.lidarNote = r.note
            }
        } else {
            out.lidarNote = "no depth"
        }
        // the upright plane through the slab's middle, facing the camera
        let up = -down.normalized
        let toCam = (o - slab.center).rejecting(up)
        if toCam.length > 1e-3, let c = Plane3(point: slab.center, normal: toCam.normalized).intersect(origin: o, direction: dir) {
            let p = plausible(c, slab: slab, spec: spec, ball: ball, down: down, rule: rule, maxHeight: maxHeight)
            out.plane = Placement(center: c, source: .plane, dropHeight: p.height ?? dropHeight(center: c, slab: slab, spec: spec, ball: ball, down: down, rule: rule) ?? .nan,
                                  range: c.distance(to: o))
            out.planePlausible = p.height != nil
            out.planeNote = p.note
        } else {
            out.planeNote = "no plane"
        }
        return out
    }
}
