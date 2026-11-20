import Foundation

/// The physical slab: its top face, thickness, the dish in its top, and the shape of its sides. Metres.
///
/// The sides. `thickness` is the slab's physical thickness (what a ruler gives; the renderers' base and the tracker's
/// seed height use it). What a camera sees of a side is its profile, in the side's cross-section (x outward from the
/// flat top's edge, z up): the flat top (z = 0 for x <= 0), a rounded edge of radius `edgeRadius` (the arc
/// (r sin psi, -r (1 - cos psi)) for psi from 0 to where it meets the face), then a planar face down to (`sideRun`,
/// -`faceDrop`): the bottom of the visible band, where the black base (the cradle) begins. The face runs outward as it
/// drops (the real slab's sides are not vertical) and its normal is proportional to faceDrop x outward + sideRun x normal
/// (with no rounding). `sideU` and `sideV` are the flat top's sides.
///
/// A spec with no profile (`faceDrop`, `sideRun` and `edgeRadius` all 0, as every recording made before the profile
/// existed decodes) is the old box: a vertical cut face as deep as `thickness`, and the edge refiner's original rules
/// (`EdgeRefiner`). `faceDrop` 0 with a profile means the face drops by `thickness`.
public struct SlabSpec: Equatable, Codable {
    /// side lengths of the top face along its two edge directions (a square slab has sideU == sideV)
    public var sideU: Double
    public var sideV: Double
    /// the slab's physical thickness (with no profile: how far the light cut face runs down from the top edge)
    public var thickness: Double
    /// how far the middle of the top lies below the plane through its four corners (a paraboloid dish: the middles of the
    /// edges lie half that far down)
    public var dishDepth: Double
    /// H: how far the visible side face drops from the flat top's edge to the bottom of the visible band (0: `thickness`)
    public var faceDrop: Double
    /// R: how far the bottom of the visible side face lies outside the flat top's edge (0: a vertical face)
    public var sideRun: Double
    /// r: the radius of the rounded edge between the flat top and the side face (0: a sharp edge)
    public var edgeRadius: Double
    /// psi_n (radians): where on the rounded edge a side whose face shows departs from the top face's luma (the edge
    /// refiner's top line on such sides): 0 at the rounding's start. An effective (r, psi_n) pair can stand in for the
    /// real rounding (see `ownerSlab`).
    public var nearFeatureAngle: Double

    public init(sideU: Double, sideV: Double, thickness: Double, dishDepth: Double, faceDrop: Double = 0, sideRun: Double = 0,
                edgeRadius: Double = 0, nearFeatureAngle: Double = 0) {
        self.sideU = sideU; self.sideV = sideV; self.thickness = thickness; self.dishDepth = dishDepth
        self.faceDrop = faceDrop; self.sideRun = sideRun; self.edgeRadius = edgeRadius; self.nearFeatureAngle = nearFeatureAngle
    }

    /// The owner's slab as first described: about 7 in square, 1 in thick, 1/8 in dish, with vertical cut faces (no profile:
    /// the old box). Tests and old recordings use it.
    public static let standard = SlabSpec(sideU: Units.inches(7), sideV: Units.inches(7), thickness: Units.inches(1), dishDepth: Units.inches(0.125))

    /// The owner's slab, as the app runs it: the one place the app's slab comes from (`AppSettings.slab`,
    /// `RecordingSettings()`, so the kit scorer, the synthetic kits and replays of new recordings agree on it). Each number
    /// is one constant below, in inches; change it there.
    ///   - The flat top: 180.2 mm square (`ownerFlatTopMm`), measured on the owner's first kit (slab-kit-20261118-205900:
    ///     the flat top 180.2 ± 1.5 mm across the shots, the outline over the rounded edge about 184.5 mm) and confirmed by
    ///     the owner's tape (n18: 180 mm across adjacent corners, a 250 mm diagonal, which fits corners rounded in plan by
    ///     5-6 mm; both kits re-measured 179.8 ± 2.5 mm, the app's own corners triangulated over 8 shots 179.9 mm). The
    ///     size scales the slab's distance (and so the ball's), not its tilt. The app's Settings > Developer > "Slab top
    ///     (mm)" overrides it on the phone (`AppSettings.slabTopMm`); the outer (bottom) edge follows from `sideRun`.
    ///   - 1 in thick (physical: the renderers' base and the tracker's seed height), with a 1/8 in dish (the owner's).
    ///   - The sides: a prior the edge refiner refines online (`EdgeRefiner`, `ProfileLearning`), measured on the same kit:
    ///     the side face drops 19.5-22.2 mm and runs 6.8-8.2 mm out (two independent fits at 5 positions; prior 21.5 / 7.5
    ///     mm, sigma 5 / 4 mm), and an effective rounded edge of 2 mm with the near departure at the rounding's start
    ///     (psi_n 0) fitted the kit's near and far edges best (any r from 1 to 3 mm did about as well; the physical rounding
    ///     looked 3-5 mm; sigma 1.5 mm).
    public static let ownerSlab = SlabSpec(sideU: Units.inches(ownerFlatTopInches), sideV: Units.inches(ownerFlatTopInches),
                                           thickness: Units.inches(ownerThicknessInches), dishDepth: Units.inches(ownerDishInches),
                                           faceDrop: Units.inches(ownerFaceDropInches), sideRun: Units.inches(ownerSideRunInches),
                                           edgeRadius: Units.inches(ownerEdgeRadiusInches))
    /// the owner slab's flat top (both sides, mm): the one constant for the app's default size (see `ownerSlab`)
    public static let ownerFlatTopMm = 180.2
    public static let ownerFlatTopInches = ownerFlatTopMm / 25.4
    public static let ownerThicknessInches = 1.0
    public static let ownerDishInches = 0.125
    /// the owner slab's profile in inches (21.5, 7.5 and 2.0 mm), so `RecordingSettings`' inch fields give it exactly
    public static let ownerFaceDropInches = 21.5 / 25.4
    public static let ownerSideRunInches = 7.5 / 25.4
    public static let ownerEdgeRadiusInches = 2.0 / 25.4

    public var halfU: Double { sideU / 2 }
    public var halfV: Double { sideV / 2 }
    public var meanSide: Double { (sideU + sideV) / 2 }
    /// the same slab with its two side lengths swapped
    public var swapped: SlabSpec {
        SlabSpec(sideU: sideV, sideV: sideU, thickness: thickness, dishDepth: dishDepth, faceDrop: faceDrop, sideRun: sideRun,
                 edgeRadius: edgeRadius, nearFeatureAngle: nearFeatureAngle)
    }

    /// whether the sides have a profile (else the old box with vertical cut faces, and the edge refiner's original rules)
    public var hasProfile: Bool { faceDrop > 0 || sideRun > 0 || edgeRadius > 0 }
    /// H: the visible face's drop (`faceDrop`, or `thickness` when that is 0)
    public var drop: Double { faceDrop > 0 ? faceDrop : thickness }

    /// The same slab with another face drop and side run (e.g. learned ones).
    public func withProfile(faceDrop H: Double, sideRun R: Double) -> SlabSpec {
        var s = self; s.faceDrop = H; s.sideRun = R; return s
    }

    // Codable: the profile's fields were added later. A file without them (every recording, diagnostics file and kit made
    // before) decodes with 0 (no profile: the old box), and a spec without a profile writes exactly what it wrote before.
    enum CodingKeys: String, CodingKey { case sideU, sideV, thickness, dishDepth, faceDrop, sideRun, edgeRadius, nearFeatureAngle }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sideU = try c.decode(Double.self, forKey: .sideU); sideV = try c.decode(Double.self, forKey: .sideV)
        thickness = try c.decode(Double.self, forKey: .thickness); dishDepth = try c.decode(Double.self, forKey: .dishDepth)
        faceDrop = try c.decodeIfPresent(Double.self, forKey: .faceDrop) ?? 0
        sideRun = try c.decodeIfPresent(Double.self, forKey: .sideRun) ?? 0
        edgeRadius = try c.decodeIfPresent(Double.self, forKey: .edgeRadius) ?? 0
        nearFeatureAngle = try c.decodeIfPresent(Double.self, forKey: .nearFeatureAngle) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sideU, forKey: .sideU); try c.encode(sideV, forKey: .sideV)
        try c.encode(thickness, forKey: .thickness); try c.encode(dishDepth, forKey: .dishDepth)
        if faceDrop != 0 { try c.encode(faceDrop, forKey: .faceDrop) }
        if sideRun != 0 { try c.encode(sideRun, forKey: .sideRun) }
        if edgeRadius != 0 { try c.encode(edgeRadius, forKey: .edgeRadius) }
        if nearFeatureAngle != 0 { try c.encode(nearFeatureAngle, forKey: .nearFeatureAngle) }
    }
}

/// A side's cross-section (x outward from the flat top's edge, z up, metres): the flat top, the rounded edge and the
/// planar face down to the bottom of the visible band (`SlabSpec`).
public struct SideSection: Equatable {
    public var drop: Double      // H
    public var run: Double       // R
    public var radius: Double    // r
    /// where the rounding meets the face (radians from the flat top): the face is tangent to the arc there
    public let faceAngle: Double

    public init(drop H: Double, run R: Double, radius r: Double) {
        drop = H; run = R; radius = r
        if r <= 0 { faceAngle = atan2(H, R) }
        else {
            // the face from the arc's end (r sin psi, -r (1 - cos psi)) along (cos psi, -sin psi) passes through (R, -H):
            // R sin psi + (r - H) cos psi = r
            let rho = (R * R + (r - H) * (r - H)).squareRoot()
            faceAngle = asin(min(1, r / max(rho, 1e-12))) - atan2(r - H, R)
        }
    }
    public init(spec: SlabSpec) { self.init(drop: spec.drop, run: spec.sideRun, radius: spec.edgeRadius) }

    /// the point on the rounded edge at angle psi (clamped to the arc)
    public func arc(_ psi: Double) -> (x: Double, z: Double) {
        let p = clamp(psi, 0, faceAngle)
        return (radius * sin(p), -radius * (1 - cos(p)))
    }
    /// where the rounding ends and the face begins
    public var arcEnd: (x: Double, z: Double) { arc(faceAngle) }
    /// the bottom of the visible face
    public var bottom: (x: Double, z: Double) { (run, -drop) }
    /// the face's unit normal in (x, z): (sin psi_e, cos psi_e), outward and up
    public var faceNormal: (x: Double, z: Double) { (sin(faceAngle), cos(faceAngle)) }
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
    /// the corners at the bottom of the visible side faces: the top corners moved down by the face's drop and, with a side
    /// run, out along both sides that meet there (so neighbouring sloped faces meet on the corner's diagonal). With no
    /// profile, the top corners moved down by the thickness.
    public var bottomCorners: [Vec3] {
        let H = spec.drop
        guard spec.sideRun != 0 else { return pose.topCorners.map { $0 - pose.normal * H } }
        let c = pose.topCorners
        let out = (0..<4).map { outward(side: $0) }
        let down = pose.normal * H, R = spec.sideRun
        return (0..<4).map { (k: Int) -> Vec3 in
            let m: Vec3 = out[(k + 3) % 4] + out[k]
            return c[k] - down + m * R
        }
    }

    /// Side i runs from corner i to corner i+1. Its outward in-plane direction.
    public func outward(side i: Int) -> Vec3 {
        let c = pose.topCorners, a = c[i], b = c[(i + 1) % 4]
        let mid = (a + b) / 2
        return (mid - pose.center).rejecting(pose.normal).normalized
    }

    /// Whether the camera (at the origin) can see side i's cut face (with a profile: the planar face, whose normal leans
    /// up by the face's slope, proportional to faceDrop x outward + sideRun x normal for a sharp edge).
    public func cutFaceVisible(side i: Int) -> Bool {
        let c = pose.topCorners
        guard spec.sideRun != 0 || spec.edgeRadius != 0 else {
            let mid = (c[i] + c[(i + 1) % 4]) / 2 - pose.normal * (spec.drop / 2)
            return outward(side: i).dot(-mid) > 0
        }
        let sec = SideSection(spec: spec), o = outward(side: i), n = pose.normal
        let e = sec.arcEnd, b = sec.bottom, fn = sec.faceNormal
        let mid = (c[i] + c[(i + 1) % 4]) / 2 + o * ((e.x + b.x) / 2) + n * ((e.z + b.z) / 2)
        return (o * fn.x + n * fn.z).dot(-mid) > 0
    }

    // MARK: the side profile's features in the image

    /// Where side i's visible features lie in the image, as offsets outward from the image line of the flat top's edge
    /// (pixels, across the side), at a point a share `t` along it (0 at corner i, 1 at corner i+1). Each point of the side's
    /// cross-section (`SideSection`) is projected with the full camera model. `outer` is the outermost (the side's outline
    /// against what lies beyond: the bottom of a face that shows, or the rounded edge's tangent point when the face is
    /// hidden); `departure` is the arc point at `nearFeatureAngle` (where a side whose face shows departs from the top's
    /// luma; 0 at the rounding's start). With no profile, a hidden face gives 0 for both, and a face that shows gives the
    /// cut face's band as `outer` (`cutBandWidth`). `sp` evaluates another profile in the same view. nil if the side does
    /// not project.
    public func featureOffsets(side i: Int, at t: Double, spec sp: SlabSpec? = nil) -> (outer: Double, departure: Double)? {
        let s = sp ?? spec
        let c = pose.topCorners, a = c[i], b = c[(i + 1) % 4]
        let M = a + (b - a) * t, o = outward(side: i), n = pose.normal
        guard let m = intrinsics.project(M), let pa = intrinsics.project(a), let pb = intrinsics.project(b),
              let mo = intrinsics.project(M + o * 0.01) else { return nil }
        let d = pb - pa
        guard d.length > 1e-9 else { return nil }
        var nu = (d / d.length).perpendicular
        if nu.dot(mo - m) < 0 { nu = -nu }
        func u(_ x: Double, _ z: Double) -> Double? { intrinsics.project(M + o * x + n * z).map { ($0 - m).dot(nu) } }
        let sec = SideSection(drop: s.drop, run: s.sideRun, radius: s.edgeRadius)
        var outer = 0.0
        if let ub = u(sec.bottom.x, sec.bottom.z) { outer = max(outer, ub) }
        if sec.radius > 0 {
            // on the arc, u is (to first order) r (ax sin psi + az cos psi - az): largest at psi = atan2(ax, az)
            let h = 1e-4
            guard let ux = u(h, 0), let uz = u(0, h) else { return nil }
            let ps = clamp(atan2(ux / h, uz / h), 0, sec.faceAngle)
            for p in [ps, sec.faceAngle] { let q = sec.arc(p); if let v = u(q.x, q.z) { outer = max(outer, v) } }
        }
        let q = sec.arc(s.nearFeatureAngle)
        let dep = (q.x == 0 && q.z == 0) ? 0 : (u(q.x, q.z) ?? 0)
        return (outer, dep)
    }

    /// The cross-section's view angle at side i's middle (radians): the camera's direction from the side, measured from
    /// the outward direction toward the slab's normal (0: seen from straight outside, 90 deg: from straight above, beyond
    /// 90 deg: from across the slab). A face whose normal is (sin psi_e, cos psi_e) shows while this is below
    /// 180 deg - psi_e.
    public func viewAngle(side i: Int) -> Double {
        let c = pose.topCorners, M = (c[i] + c[(i + 1) % 4]) / 2, toCam = -M
        return atan2(toCam.dot(pose.normal), toCam.dot(outward(side: i)))
    }

    /// Side i's profile in the image (`SideProfile`): its features' offsets at both ends and the middle, and how they move
    /// with the profile's three lengths (by finite differences of `h` metres, one-sided at 0). nil if it does not project.
    public func sideProfile(side i: Int, derivativeStep h: Double = 1e-4) -> SideProfile? {
        guard let s0 = featureOffsets(side: i, at: 0), let s1 = featureOffsets(side: i, at: 1),
              let m = featureOffsets(side: i, at: 0.5) else { return nil }
        let base = spec.faceDrop == 0 ? spec.withProfile(faceDrop: spec.drop, sideRun: spec.sideRun) : spec
        func deriv(_ v: Double, _ set: (inout SlabSpec, Double) -> Void) -> (outer: Double, departure: Double) {
            let lo = max(0, v - h), hi = v + h
            var a = base, b = base
            set(&a, lo); set(&b, hi)
            guard let fa = featureOffsets(side: i, at: 0.5, spec: a), let fb = featureOffsets(side: i, at: 0.5, spec: b) else { return (0, 0) }
            return ((fb.outer - fa.outer) / (hi - lo), (fb.departure - fa.departure) / (hi - lo))
        }
        let dH = deriv(base.drop) { $0.faceDrop = $1 }
        let dR = deriv(base.sideRun) { $0.sideRun = $1 }
        let dr = deriv(base.edgeRadius) { $0.edgeRadius = $1 }
        return SideProfile(faceVisible: cutFaceVisible(side: i), viewAngle: viewAngle(side: i),
                           outerStart: s0.outer, outerEnd: s1.outer, departureStart: s0.departure, departureEnd: s1.departure,
                           outerMiddle: m.outer, departureMiddle: m.departure,
                           outerDerivatives: [dH.outer, dR.outer, dr.outer], departureDerivatives: [dH.departure, dR.departure, dr.departure])
    }

    /// `sideProfile(side:)` by the outline's own side j (its ends in the outline's direction).
    public func sideProfile(outlineSide j: Int) -> SideProfile? {
        let (s, rev) = poseSide(forOutlineSide: j)
        return sideProfile(side: s).map { rev ? $0.reversed : $0 }
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

/// One side's profile features in the image (`SlabBoxView.sideProfile`): offsets outward from the image line of the flat
/// top's edge (pixels of the image the view projects into, across the side), at the side's two ends and middle.
public struct SideProfile: Equatable {
    /// whether the side's planar face shows
    public var faceVisible: Bool
    /// the cross-section's view angle (`SlabBoxView.viewAngle`, radians)
    public var viewAngle: Double
    /// the side's outline against what lies beyond (the face's bottom, or the rounding's tangent point when it is hidden)
    public var outerStart: Double
    public var outerEnd: Double
    /// where a face that shows departs from the top's luma (`SlabSpec.nearFeatureAngle`)
    public var departureStart: Double
    public var departureEnd: Double
    public var outerMiddle: Double
    public var departureMiddle: Double
    /// d(offset)/d(faceDrop, sideRun, edgeRadius) at the middle (pixels per metre)
    public var outerDerivatives: [Double]
    public var departureDerivatives: [Double]

    /// the band between the departure and the outline at the two ends and the middle
    public var bandStart: Double { outerStart - departureStart }
    public var bandEnd: Double { outerEnd - departureEnd }
    public var bandMiddle: Double { outerMiddle - departureMiddle }
    /// d(band)/d(faceDrop, sideRun, edgeRadius) at the middle
    public var bandDerivatives: [Double] { zip(outerDerivatives, departureDerivatives).map { $0 - $1 } }

    /// the same with its two ends swapped (the side read the other way)
    public var reversed: SideProfile {
        var p = self
        (p.outerStart, p.outerEnd) = (outerEnd, outerStart)
        (p.departureStart, p.departureEnd) = (departureEnd, departureStart)
        return p
    }
}
