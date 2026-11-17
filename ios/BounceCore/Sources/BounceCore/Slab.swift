import Foundation

/// The physical slab: its top face, thickness and the dish in its top. Metres.
public struct SlabSpec: Equatable, Codable {
    /// side lengths of the top face along its two edge directions (a square slab has sideU == sideV)
    public var sideU: Double
    public var sideV: Double
    /// how far the light cut face runs down from the top edge (the slab's thickness at its edges)
    public var thickness: Double
    /// how far the middle of the top lies below the plane through its four corners (a paraboloid dish: the middles of the
    /// edges lie half that far down)
    public var dishDepth: Double

    public init(sideU: Double, sideV: Double, thickness: Double, dishDepth: Double) {
        self.sideU = sideU; self.sideV = sideV; self.thickness = thickness; self.dishDepth = dishDepth
    }

    /// The owner's slab as described: about 7 in square, 1 in thick, 1/8 in dish.
    public static let standard = SlabSpec(sideU: Units.inches(7), sideV: Units.inches(7), thickness: Units.inches(1), dishDepth: Units.inches(0.125))

    public var halfU: Double { sideU / 2 }
    public var halfV: Double { sideV / 2 }
    public var meanSide: Double { (sideU + sideV) / 2 }
    /// the same slab with its two side lengths swapped
    public var swapped: SlabSpec { SlabSpec(sideU: sideV, sideV: sideU, thickness: thickness, dishDepth: dishDepth) }
}

/// The corners of the top face in the slab's own (u, v) frame, in the pose's corner order. Since axisU x axisV ==
/// normal, a pose's corners run anticlockwise seen from the top face's side: on screen, an outline in pose order has a
/// negative shoelace area (y down). A detector's outline may start anywhere and run either way round; a fitted pose
/// says how its corners map onto the outline's in `PoseFit.cornerOrder` (reversed for an outline running clockwise).
public let slabCornerSigns: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]

/// Where a slab is: the middle of the plane through its four top corners, that plane's unit normal (pointing out of the
/// top face) and the in-plane unit directions of its two edge directions. Expressed in whatever frame the caller uses
/// (camera or world). axisU x axisV == normal.
public struct SlabPose: Equatable, Codable {
    public var center: Vec3
    public var normal: Vec3
    public var axisU: Vec3
    public var axisV: Vec3
    public var halfU: Double
    public var halfV: Double

    public init(center: Vec3, normal: Vec3, axisU: Vec3, axisV: Vec3, halfU: Double, halfV: Double) {
        self.center = center; self.normal = normal; self.axisU = axisU; self.axisV = axisV; self.halfU = halfU; self.halfV = halfV
    }

    /// The four top corners (virtual sharp corners of the plane through them), in outline order.
    public var topCorners: [Vec3] { slabCornerSigns.map { center + axisU * ($0.0 * halfU) + axisV * ($0.1 * halfV) } }

    /// The point at (u, v) in the corner plane.
    public func point(u: Double, v: Double) -> Vec3 { center + axisU * u + axisV * v }

    /// (u, v) coordinates of a point's projection onto the corner plane.
    public func local(_ p: Vec3) -> (u: Double, v: Double) { let d = p - center; return (d.dot(axisU), d.dot(axisV)) }

    /// signed height of a point above the corner plane
    public func height(of p: Vec3) -> Double { (p - center).dot(normal) }

    /// The same pose moved into another frame.
    public func transformed(by t: RigidTransform) -> SlabPose {
        SlabPose(center: t.apply(center), normal: t.applyDirection(normal).normalized, axisU: t.applyDirection(axisU).normalized,
                 axisV: t.applyDirection(axisV).normalized, halfU: halfU, halfV: halfV)
    }

    /// Tilt from level (radians), given which way is down.
    public func tilt(down: Vec3) -> Double { acos(clamp(-normal.dot(down.normalized), -1, 1)) }

    /// Build a pose from four top corners in outline order (a least-squares rectangle through them).
    public static func fromCorners(_ c: [Vec3]) -> SlabPose? {
        guard c.count == 4 else { return nil }
        let center = (c[0] + c[1] + c[2] + c[3]) / 4
        // edge directions from the averaged opposite sides
        let du = ((c[1] - c[0]) + (c[2] - c[3])) / 2, dv = ((c[3] - c[0]) + (c[2] - c[1])) / 2
        var n = du.cross(dv)
        guard n.length > 1e-12 else { return nil }
        n = n.normalized
        let u = du.rejecting(n).normalized, v = n.cross(u)
        return SlabPose(center: center, normal: n, axisU: u, axisV: v, halfU: du.length / 2, halfV: dv.length / 2)
    }
}

/// The dish in the top face.
public enum Dish {
    /// How far the dish surface lies below the corner plane at (u, v), and its unit surface normal there.
    /// Points beyond the edges are clamped to the edge (the dish shape stops there).
    public static func at(pose: SlabPose, depth D: Double, u: Double, v: Double) -> (depth: Double, normal: Vec3) {
        guard D > 0 else { return (0, pose.normal) }
        let hu = pose.halfU, hv = pose.halfV
        let cu = clamp(u, -hu, hu), cv = clamp(v, -hv, hv)
        let d = D * (1 - (cu * cu / (hu * hu) + cv * cv / (hv * hv)) / 2)
        // the surface is corner-plane - d(u, v) * normal; its normal leans toward the middle by the slope of d
        let n = (pose.normal - pose.axisU * (D * cu / (hu * hu)) - pose.axisV * (D * cv / (hv * hv))).normalized
        return (d, n)
    }
}

/// The slab as a box with thickness, seen from a camera (all in camera coordinates): which cut faces show and how wide.
///
/// `side:` methods index the pose's own sides (side i runs from `pose.topCorners[i]` to `[i+1]`). A detector's outline
/// may run the other way round from the pose (see `PoseFit.cornerOrder`): build the view with `init(fit:spec:intrinsics:)`
/// and use the `outlineSide:` methods, which take the outline's own side numbers, so a per-side model cannot put the
/// near side's cut face on the far side.
public struct SlabBoxView {
    public let pose: SlabPose          // in camera (CV) coordinates
    public let spec: SlabSpec
    public let intrinsics: CameraIntrinsics
    /// which outline corner each pose corner is (as `PoseFit.cornerOrder`); [0, 1, 2, 3] when built from a pose alone
    public let cornerOrder: [Int]

    public init(pose: SlabPose, spec: SlabSpec, intrinsics: CameraIntrinsics) {
        self.pose = pose; self.spec = spec; self.intrinsics = intrinsics; cornerOrder = [0, 1, 2, 3]
    }

    /// The box of a fitted pose, with its outline's corner order, for lookups by the outline's own sides.
    public init(fit: PoseFit, spec: SlabSpec, intrinsics: CameraIntrinsics) {
        self.pose = fit.pose; self.spec = spec; self.intrinsics = intrinsics; cornerOrder = fit.cornerOrder
    }

    public var topCorners: [Vec3] { pose.topCorners }
    /// the corners at the bottom of the cut faces (the top corners moved down by the thickness)
    public var bottomCorners: [Vec3] { pose.topCorners.map { $0 - pose.normal * spec.thickness } }

    /// Side i runs from corner i to corner i+1. Its outward in-plane direction.
    public func outward(side i: Int) -> Vec3 {
        let c = pose.topCorners, a = c[i], b = c[(i + 1) % 4]
        let mid = (a + b) / 2
        return (mid - pose.center).rejecting(pose.normal).normalized
    }

    /// Whether the camera (at the origin) can see side i's cut face.
    public func cutFaceVisible(side i: Int) -> Bool {
        let c = pose.topCorners, mid = (c[i] + c[(i + 1) % 4]) / 2 - pose.normal * (spec.thickness / 2)
        return outward(side: i).dot(-mid) > 0
    }

    /// How wide side i's cut face looks in the image (pixels) at its two ends (corner i, corner i+1), measured across
    /// the side: the distance of each bottom corner from the image line of the top edge. This is how far a detector must
    /// step in from the bottom of the cut face to reach the top edge. 0 where the face is hidden.
    public func cutBandWidth(side i: Int) -> (start: Double, end: Double) {
        guard cutFaceVisible(side: i) else { return (0, 0) }
        let t = topCorners, j = (i + 1) % 4
        guard let ta = intrinsics.project(t[i]), let tb = intrinsics.project(t[j]) else { return (0, 0) }
        let e = tb - ta, len = e.length
        guard len > 1e-9 else { return (0, 0) }
        let dir = e / len
        func w(_ k: Int) -> Double {
            guard let v = verticalEdge(corner: k) else { return 0 }
            return abs(dir.cross(v))
        }
        return (w(i), w(j))
    }

    /// The image vector from top corner k to the bottom of the cut face below it (pixels): the projected vertical edge.
    /// Its length is the edge's projected length, which is longer than the band's width across a side seen obliquely.
    public func verticalEdge(corner k: Int) -> Vec2? {
        guard let p = intrinsics.project(topCorners[k]), let q = intrinsics.project(bottomCorners[k]) else { return nil }
        return q - p
    }

    /// The top face's outline in the image (pose order).
    public var topOutline: [Vec2]? {
        let p = topCorners.compactMap { intrinsics.project($0) }
        return p.count == 4 ? p : nil
    }

    /// The outer outline a naive detector would find: on sides whose cut face shows, the bottom of the cut face.
    public var outerOutlineLines: [(Vec2, Vec2)]? {
        let t = topCorners, b = bottomCorners
        var out: [(Vec2, Vec2)] = []
        for i in 0..<4 {
            let src = cutFaceVisible(side: i) ? b : t
            guard let p = intrinsics.project(src[i]), let q = intrinsics.project(src[(i + 1) % 4]) else { return nil }
            out.append((p, q))
        }
        return out
    }

    /// The outline a detector reports when it takes the given (pose) sides at the bottom of their cut face instead of
    /// at the top edge, e.g. the near edge flipping to the bottom of the light cut face: those sides' lines move to the
    /// projected bottom edges, and the corners are where neighbouring lines meet. Sides whose face is hidden stay on the
    /// top edge. Pose order; nil if a corner does not project.
    public func outlineWithCutBottom(onSides sides: Set<Int>) -> [Vec2]? {
        guard let T = topOutline else { return nil }
        let bp = bottomCorners.compactMap { intrinsics.project($0) }
        guard bp.count == 4 else { return nil }
        let lines: [(Vec2, Vec2)] = (0..<4).map { i in
            let j = (i + 1) % 4
            return sides.contains(i) && cutFaceVisible(side: i) ? (bp[i], bp[j]) : (T[i], T[j])
        }
        return (0..<4).map { i in SlabBoxView.intersect(lines[(i + 3) % 4], lines[i]) ?? T[i] }
    }

    static func intersect(_ l1: (Vec2, Vec2), _ l2: (Vec2, Vec2)) -> Vec2? {
        let d1 = l1.1 - l1.0, d2 = l2.1 - l2.0, den = d1.cross(d2)
        guard abs(den) > 1e-12 else { return nil }
        let s = (l2.0 - l1.0).cross(d2) / den
        return l1.0 + d1 * s
    }

    // MARK: by the outline's own corners and sides

    /// The pose side along outline side j (from outline corner j to j+1), and whether it runs the other way.
    public func poseSide(forOutlineSide j: Int) -> (side: Int, reversed: Bool) {
        PoseFit.poseSide(forOutlineSide: j, cornerOrder: cornerOrder)
    }

    /// The top corners in outline order: element j projects onto outline corner j.
    public var outlineTopCorners: [Vec3] { PoseFit.toOutlineOrder(topCorners, cornerOrder: cornerOrder) }
    /// The bottom corners in outline order.
    public var outlineBottomCorners: [Vec3] { PoseFit.toOutlineOrder(bottomCorners, cornerOrder: cornerOrder) }

    /// Whether outline side j's cut face shows.
    public func cutFaceVisible(outlineSide j: Int) -> Bool { cutFaceVisible(side: poseSide(forOutlineSide: j).side) }

    /// The band's width across outline side j at outline corner j (`start`) and j+1 (`end`), pixels; 0 where hidden.
    public func cutBandWidth(outlineSide j: Int) -> (start: Double, end: Double) {
        let (s, rev) = poseSide(forOutlineSide: j)
        let w = cutBandWidth(side: s)
        return rev ? (w.end, w.start) : w
    }

    /// `outlineWithCutBottom(onSides:)` with outline side numbers in and the outline's corner order out.
    public func outlineWithCutBottom(onOutlineSides sides: Set<Int>) -> [Vec2]? {
        let ps = Set(sides.map { poseSide(forOutlineSide: $0).side })
        return outlineWithCutBottom(onSides: ps).map { PoseFit.toOutlineOrder($0, cornerOrder: cornerOrder) }
    }
}
