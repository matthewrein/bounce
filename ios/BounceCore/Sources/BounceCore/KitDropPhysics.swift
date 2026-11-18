import Foundation

// The physics of a ball dropped onto the slab, independent of the app's model (`Bounce`), for rendered drops with known
// truth (`KitSyntheticDrops`) and for the drop analysis's dish geometry (`KitDropAnalysis`). Everything here is in
// metres and seconds; the world is ARKit's (y up, gravity 9.80665 m/s² down).

/// The dish in the slab's top as a physical surface, in the slab's own coordinates: a point is (u, v, h), u and v along
/// the pose's axes from its centre, h along its normal above the plane through the four top corners.
///
/// Two shapes:
///   - **sphericalCap** (the default, the owner's description: "dished 1/8 in deep at the centre"): a spherical cap
///     `depth` deep at the centre whose rim is the circle inscribed in the top (radius a = the top's half-width), so the
///     sphere's radius is R = (a² + D²) / (2 D) (the owner's 7 in top, D = 1/8 in: R = 49.06 in = 1.25 m), and the top
///     is flat (the corner plane) outside the rim. Its surface leans toward the middle by asin(r / R) at r from the
///     centre: on the 7 in top 1.17° 1 in out, 2.34° at 2 in, 3.5° at 3 in and 4.1° at its rim.
///   - **paraboloid**: the app's model (`Dish.at`, `SlabSpec.dishDepth`): through the four corners, D at the centre and
///     D/2 at the middles of the edges, so it leans half as much as the cap near the middle (the cap through the corners
///     would be the same to second order).
public struct KitDish: Codable, Equatable {
    public enum Shape: String, Codable {
        case sphericalCap
        case paraboloid
    }

    public var shape: Shape
    /// how far the middle lies below the corner plane (m)
    public var depth: Double
    public var halfU: Double
    public var halfV: Double

    public init(shape: Shape = .sphericalCap, depth: Double, halfU: Double, halfV: Double) {
        self.shape = shape; self.depth = depth; self.halfU = halfU; self.halfV = halfV
    }

    public init(spec: SlabSpec, shape: Shape = .sphericalCap) {
        self.init(shape: shape, depth: spec.dishDepth, halfU: spec.halfU, halfV: spec.halfV)
    }

    /// the cap's rim: the circle inscribed in the top (m)
    public var rimRadius: Double { min(halfU, halfV) }
    /// the cap's sphere radius (m): (a² + D²) / (2 D); infinite for a flat top
    public var sphereRadius: Double {
        depth > 0 ? (rimRadius * rimRadius + depth * depth) / (2 * depth) : .infinity
    }

    /// How far the surface lies below the corner plane at (u, v), and its unit normal there (slab coordinates, pointing
    /// out of the top: (0, 0, 1) on a flat top).
    public func surface(u: Double, v: Double) -> (depth: Double, normal: Vec3) {
        guard depth > 0 else { return (0, Vec3(0, 0, 1)) }
        switch shape {
        case .sphericalCap:
            let rho2 = u * u + v * v, a = rimRadius, Rs = sphereRadius
            guard rho2 < a * a else { return (0, Vec3(0, 0, 1)) }
            let w = (Rs * Rs - rho2).squareRoot()
            // the sphere's centre is (0, 0, Rs - D); the surface point (u, v, Rs - D - w)
            return (w - Rs + depth, Vec3(-u / Rs, -v / Rs, w / Rs))
        case .paraboloid:
            let hu = halfU, hv = halfV, cu = clamp(u, -hu, hu), cv = clamp(v, -hv, hv)
            let d = depth * (1 - (cu * cu / (hu * hu) + cv * cv / (hv * hv)) / 2)
            return (d, Vec3(-depth * cu / (hu * hu), -depth * cv / (hv * hv), 1).normalized)
        }
    }

    /// The ball (centre `c` in slab coordinates, radius `r`) against the top: its clearance (the gap between the ball and
    /// the surface, negative when it would overlap), the nearest point of the surface and the surface's normal there
    /// (pointing from that point toward the ball's centre when it is clear of it). The top has no edges here: it runs on
    /// past the outline (the caller decides whether the ball is over the slab).
    public func contact(center c: Vec3, radius r: Double) -> (clearance: Double, point: Vec3, normal: Vec3) {
        guard depth > 0 else { return (c.z - r, Vec3(c.x, c.y, 0), Vec3(0, 0, 1)) }
        switch shape {
        case .sphericalCap:
            let a = rimRadius, Rs = sphereRadius, C = Vec3(0, 0, Rs - depth)
            var best: (clearance: Double, point: Vec3, normal: Vec3)? = nil
            func consider(_ d: Double, _ p: Vec3, _ n: Vec3) { if best == nil || d < best!.clearance { best = (d, p, n) } }
            // the cap: the nearest point of its sphere, if it lies inside the rim
            let q = c - C, dist = q.length
            if dist > 1e-9 {
                let s = C + q * (Rs / dist)
                if s.x * s.x + s.y * s.y <= a * a && s.z <= 0 { consider(Rs - dist - r, s, q * (-1 / dist)) }
            }
            // the flat top outside the rim
            let rho = (c.x * c.x + c.y * c.y).squareRoot()
            if rho >= a { consider(c.z - r, Vec3(c.x, c.y, 0), Vec3(0, 0, 1)) }
            // the rim's edge (where the two meet)
            let e = rho > 1e-12 ? Vec3(c.x * a / rho, c.y * a / rho, 0) : Vec3(a, 0, 0)
            let de = c - e, l = de.length
            if l > 1e-12 { consider(l - r, e, de / l) }
            return best!
        case .paraboloid:
            // the ball's centre lies a radius out along the normal from its contact: a few steps settle it (the slope is
            // under 3° on a 7 in top)
            var u = c.x, v = c.y
            var s = surface(u: u, v: v)
            for _ in 0..<4 {
                let foot = c - s.normal * r
                u = foot.x; v = foot.y
                s = surface(u: u, v: v)
            }
            let p = Vec3(u, v, -s.depth)
            return ((c - p).dot(s.normal) - r, p, s.normal)
        }
    }
}

extension SlabPose {
    /// A world point in the slab's coordinates (u, v, h: along `axisU`, `axisV`, and the height above the corner plane).
    public func toSlab(_ p: Vec3) -> Vec3 { let d = p - center; return Vec3(d.dot(axisU), d.dot(axisV), d.dot(normal)) }
    /// A point in the slab's coordinates in the world.
    public func fromSlab(_ q: Vec3) -> Vec3 { center + axisU * q.x + axisV * q.y + normal * q.z }
    /// A direction in the slab's coordinates in the world.
    public func directionFromSlab(_ q: Vec3) -> Vec3 { axisU * q.x + axisV * q.y + normal * q.z }
}

/// How a bounce treats the velocity along the surface.
public enum KitTangentialModel: Codable, Equatable {
    /// a solid sphere with friction `mu` (Coulomb): it sticks and leaves rolling (no slip at its contact point) when the
    /// friction can do that within the impact, keeping 5/7 of the tangential velocity of a ball that came in without
    /// spin and taking up the spin that goes with it; otherwise it slides throughout, losing mu (1 + e) of its normal
    /// speed along the surface. A titanium ball on concrete (mu about 0.3-0.5) dropped onto a slab tilted under 15°
    /// always rolls off.
    case rolling(mu: Double)
    /// no friction: the velocity along the surface is kept (a mirror-like bounce at the restitution)
    case smooth
    /// a fixed share of the velocity along the surface is kept (spin ignored)
    case ratio(Double)

    /// The velocity and spin after an impact with normal restitution `e` off a surface with unit normal `n`, for a
    /// solid sphere of radius `r` coming in with velocity `v` and spin `w` (rad/s).
    public func bounce(velocity v: Vec3, spin w: Vec3, normal n: Vec3, restitution e: Double, radius r: Double) -> (velocity: Vec3, spin: Vec3) {
        let vn = v.dot(n)
        guard vn < 0 else { return (v, w) }
        let vt = v - n * vn
        let outN = n * (-e * vn)
        switch self {
        case .smooth: return (outN + vt, w)
        case let .ratio(k): return (outN + vt * k, w)
        case let .rolling(mu):
            // the contact point's slip: v_c = v + w x (-r n)
            let slip = vt + w.cross(n * -r)
            let slipT = slip - n * slip.dot(n)
            // rolling at the end of the impact: angular momentum about the contact point is kept, so the tangential
            // velocity becomes 5/7 v_t + 2/7 r (w x n), and the spin r w_t = n x v_t' (about n unchanged)
            let wn = n * w.dot(n)
            let wt = w - wn
            let vRoll = vt * (5.0 / 7) + wt.cross(n) * (2.0 / 7 * r)
            let needed = (vRoll - vt).length          // tangential impulse per unit mass to roll
            let available = mu * (1 + e) * -vn        // what friction can give
            if needed <= available + 1e-12 {
                return (outN + vRoll, n.cross(vRoll) / r + wn)
            }
            // slides throughout: friction opposes the slip, its impulse per unit mass `available`
            let dir = slipT.length > 1e-12 ? slipT.normalized : Vec3.zero
            let dv = dir * -available
            // the friction impulse at the contact point (-r n from the centre) turns the ball: I dw = (-r n) x (m dv)
            let dw = (n * -r).cross(dv) / (0.4 * r * r)
            return (outN + vt + dv, w + dw)
        }
    }
}

/// A ball dropped onto the slab and bouncing on, as it really goes (not the app's model): free fall from the release;
/// at each contact with the dish (`KitDish`, inside the slab's outline), the slab's top edges and cut faces (with its
/// centre outside the outline), the base under the slab or the floor, the velocity's component along the LOCAL surface
/// normal is reversed and scaled by the restitution, and the component along the surface follows the tangential model;
/// then free fall again. The slab and the base are the renderer's (`SyntheticScene`): the slab a box `slabThickness`
/// under its corner plane, the base a box slab-aligned about the vertical, its sides `baseShare` of the slab's, from the
/// floor up to 2 mm under the slab's lowest bottom corner. No air drag (under 0.2% of g for a 35 mm titanium ball at
/// these speeds) and no spin forces. Contacts are found by stepping each parabola 0.5 ms at a time and bisecting to
/// 0.1 µs.
public struct KitDropPhysics {
    public struct Params {
        public var ballRadius = 0.0175
        /// the slab's restitution, as the app's rebound: e = sqrt(rebound) along the normal (`BallSpec.rebound`: the share
        /// of the drop height a straight-up bounce regains)
        public var rebound = 0.7
        public var tangential = KitTangentialModel.rolling(mu: 0.4)
        /// the floor (world y) and its rebound (the base's too)
        public var floorY = 0.0
        public var floorRebound = 0.3
        public var floorTangential = KitTangentialModel.rolling(mu: 0.5)
        /// the slab's thickness (m; the owner's 1 in) and the base's sides over the slab's (nil: no base)
        public var slabThickness = Units.inches(1)
        public var baseShare: Double? = 1.05
        /// stop after this many contacts, or this long after the release (s)
        public var maxContacts = 12
        public var maxTime = 3.0
        public init() {}
    }

    /// One stretch of free flight, starting at a contact (or the release).
    public struct Segment: Equatable {
        public var t0: Double
        public var p0: Vec3
        public var v0: Vec3
        public var spin: Vec3
        public func position(at t: Double) -> Vec3 { let s = t - t0; return p0 + v0 * s + Vec3(0, -Units.gravity, 0) * (0.5 * s * s) }
        public func velocity(at t: Double) -> Vec3 { v0 + Vec3(0, -Units.gravity * (t - t0), 0) }
    }

    /// A contact.
    public struct Contact: Equatable {
        /// the slab (its dish, or its top edges and cut faces: `edge`), the base under it, the floor
        public enum Surface: String, Codable { case slab, base, floor }
        public var time: Double
        public var surface: Surface
        /// the ball's centre at the contact, and the point it touches (world)
        public var center: Vec3
        public var point: Vec3
        /// the surface's unit normal there (world)
        public var normal: Vec3
        public var velocityIn: Vec3
        public var velocityOut: Vec3
        public var spinIn: Vec3
        public var spinOut: Vec3
        /// a contact with the slab's top edges or cut faces (the ball's centre outside its outline), not its dish
        public var edge = false
    }

    public var params: Params
    public let slab: SlabPose
    public let dish: KitDish
    public let release: Double
    public let held: Vec3
    public private(set) var segments: [Segment] = []
    public private(set) var contacts: [Contact] = []
    /// when the simulation stopped (the last contact allowed, or `maxTime`): the ball stays where it is then
    public private(set) var stoppedAt = 0.0

    /// Drops the ball from rest (or with `releaseVelocity` and `releaseSpin`) at `held` (its centre, world) at time
    /// `release`.
    public init(slab: SlabPose, dish: KitDish, held: Vec3, release: Double, releaseVelocity: Vec3 = .zero, releaseSpin: Vec3 = .zero,
                params: Params = Params()) {
        self.slab = slab; self.dish = dish; self.held = held; self.release = release; self.params = params
        simulate(Segment(t0: release, p0: held, v0: releaseVelocity, spin: releaseSpin))
    }

    /// The ball's clearance from the nearest surface (the gap, negative when it would overlap), which surface that is,
    /// its nearest point (world) and its normal there, and whether it is the slab's top edges or cut faces (the ball's
    /// centre outside the outline) rather than its dish.
    func clearance(_ p: Vec3) -> (Double, Contact.Surface, Vec3, Vec3, Bool) {
        let r = params.ballRadius
        var best = (p.y - params.floorY - r, Contact.Surface.floor, Vec3(p.x, params.floorY, p.z), Vec3(0, 1, 0), false)
        let q = slab.toSlab(p)
        if abs(q.x) <= slab.halfU && abs(q.y) <= slab.halfV {
            if q.z > -dish.depth - r {
                let c = dish.contact(center: q, radius: r)
                if c.clearance < best.0 { best = (c.clearance, .slab, slab.fromSlab(c.point), slab.directionFromSlab(c.normal).normalized, false) }
            }
        } else if let (d, b, n) = Self.boxContact(q, half: Vec3(slab.halfU, slab.halfV, params.slabThickness / 2),
                                                  center: Vec3(0, 0, -params.slabThickness / 2), radius: r), d < best.0 {
            // outside the outline: the slab's top edges and cut faces
            best = (d, .slab, slab.fromSlab(b), slab.directionFromSlab(n).normalized, true)
        }
        if let base = baseBox {
            // the base, in its own axes (along `u`, up, along `v` from its foot under the slab's centre)
            let rel = p - base.foot, bq = Vec3(rel.dot(base.u), rel.y, rel.dot(base.v))
            if let (d, b, n) = Self.boxContact(bq, half: base.half, center: Vec3(0, base.half.y, 0), radius: r), d < best.0 {
                best = (d, .base, base.foot + base.u * b.x + Vec3(0, b.y, 0) + base.v * b.z,
                        (base.u * n.x + Vec3(0, n.y, 0) + base.v * n.z).normalized, false)
            }
        }
        return best
    }

    /// The base as the renderer draws it: its foot on the floor under the slab's centre, its horizontal axes and its
    /// half-sizes (along u, up, along v); nil without one.
    var baseBox: (foot: Vec3, u: Vec3, v: Vec3, half: Vec3)? {
        guard let share = params.baseShare else { return nil }
        let top = slab.topCorners.map { ($0 - slab.normal * params.slabThickness).y }.min()! - 0.002
        guard top - params.floorY > 0.005 else { return nil }
        let u = Vec3(slab.axisU.x, 0, slab.axisU.z).normalized
        return (Vec3(slab.center.x, params.floorY, slab.center.z), u, Vec3(-u.z, 0, u.x),
                Vec3(slab.halfU * share, (top - params.floorY) / 2, slab.halfV * share))
    }

    /// A ball (centre `q`, radius `r`) against a box (its centre and half-sizes, in the same axes): the clearance, the
    /// box's nearest point and the normal there (toward the ball's centre). nil when the centre is inside the box.
    static func boxContact(_ q: Vec3, half h: Vec3, center c: Vec3, radius r: Double) -> (Double, Vec3, Vec3)? {
        let b = Vec3(clamp(q.x, c.x - h.x, c.x + h.x), clamp(q.y, c.y - h.y, c.y + h.y), clamp(q.z, c.z - h.z, c.z + h.z))
        let d = q - b, l = d.length
        guard l > 1e-12 else { return nil }
        return (l - r, b, d / l)
    }

    mutating func simulate(_ first: Segment) {
        var seg = first
        segments = [seg]
        let dt = 0.0005, end = release + params.maxTime
        var t = seg.t0
        while t < end && contacts.count < params.maxContacts {
            let t2 = t + dt
            let p2 = seg.position(at: t2)
            let (c2, _, _, n2, _) = clearance(p2)
            // a contact: the ball reaches the surface while moving into it (a small grace after a bounce lets it leave)
            if c2 < 0 && seg.velocity(at: t2).dot(n2) < 0 && t2 - seg.t0 > 1e-4 {
                var lo = t, hi = t2
                for _ in 0..<40 {
                    let mid = (lo + hi) / 2
                    if clearance(seg.position(at: mid)).0 < 0 { hi = mid } else { lo = mid }
                    if hi - lo < 1e-7 { break }
                }
                let tc = lo
                let pc = seg.position(at: tc)
                let (_, surf, point, n, edge) = clearance(pc)
                let vin = seg.velocity(at: tc)
                let e = (surf == .slab ? params.rebound : params.floorRebound).squareRoot()
                let model = surf == .slab ? params.tangential : params.floorTangential
                var (vout, wout) = model.bounce(velocity: vin, spin: seg.spin, normal: n, restitution: e, radius: params.ballRadius)
                // a ball that barely leaves the floor rolls along it (one that barely leaves the dish settles there; off
                // an edge or the base it carries on along the surface)
                let settles = surf == .slab && !edge
                if surf == .floor && vout.dot(n) < 0.05 { vout = vout - n * vout.dot(n) }
                if settles && vout.dot(n) < 0.05 { vout = .zero; wout = .zero }
                var contact = Contact(time: tc, surface: surf, center: pc, point: point, normal: n, velocityIn: vin, velocityOut: vout,
                                      spinIn: seg.spin, spinOut: wout)
                contact.edge = edge
                contacts.append(contact)
                seg = Segment(t0: tc, p0: pc, v0: vout, spin: wout)
                segments.append(seg)
                t = tc
                // rolling on the floor: no more contacts to find; settled on the slab: it stays there
                if surf == .floor && vout.dot(n) < 0.05 { t = end; break }
                if settles && vout == .zero { break }
                continue
            }
            t = t2
        }
        stoppedAt = min(t, end)
    }

    /// The ball's centre at time t (held before the release; rolling on the floor at the end).
    public func position(at tIn: Double) -> Vec3 {
        guard tIn > release else { return held }
        let rolling = contacts.last.map { $0.surface == .floor && $0.velocityOut.dot($0.normal) < 0.05 } ?? false
        let t = rolling ? tIn : min(tIn, stoppedAt)
        let s = segments.last { $0.t0 <= t } ?? segments[0]
        if let last = contacts.last, last.surface == .floor, s.t0 == last.time, last.velocityOut.dot(last.normal) < 0.05 {
            // rolling: along the floor at its speed then
            return s.p0 + last.velocityOut * (t - s.t0)
        }
        return s.position(at: t)
    }

    /// The first contact (the bounce off the slab, if the ball lands on it).
    public var impact: Contact? { contacts.first }

    /// Where the flight after the first contact comes down to the world height `y` (the ball's centre), ignoring
    /// anything in the way (the arc's own continuation), and when.
    public func arcLanding(level y: Double) -> (time: Double, point: Vec3)? {
        guard segments.count > 1 else { return nil }
        let s = segments[1], G = Units.gravity
        let disc = s.v0.y * s.v0.y + 2 * G * (s.p0.y - y)
        guard disc >= 0 else { return nil }
        let tau = (s.v0.y + disc.squareRoot()) / G
        return (s.t0 + tau, s.position(at: s.t0 + tau))
    }
}
