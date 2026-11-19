import Foundation

/// The ball and how it bounces.
public struct BallSpec: Equatable, Codable {
    /// diameter (metres); the default (35 mm) is the size first assumed, which tests and old recordings keep; the owner's
    /// ball is `ownerBall`
    public var diameter: Double
    /// rebound: the share of the drop height the ball would regain bouncing straight up (0.70 = 70%): e², e the
    /// restitution (`restitution`), which is what the app's setting gives since n12
    public var rebound: Double
    /// k_t: the share of the velocity along the surface the ball keeps through an impact (friction and spin), used by the
    /// impact rule (`Bounce.LaunchRule.impact`); nil (every ball written before n12): `ownerTangential`
    public var tangential: Double?
    public init(diameter: Double = 0.035, rebound: Double = 0.70, tangential: Double? = nil) {
        self.diameter = diameter; self.rebound = rebound; self.tangential = tangential
    }
    /// A ball by its restitution e (the rebound is e²).
    public init(diameter: Double, restitution e: Double, tangential: Double? = nil) {
        self.init(diameter: diameter, rebound: e * e, tangential: tangential)
    }
    public var radius: Double { diameter / 2 }
    /// e: the speed along the surface's normal after an impact over before (the square root of the rebound)
    public var restitution: Double { max(0, rebound).squareRoot() }
    /// the share of the along-surface velocity kept (`tangential`, else `ownerTangential`)
    public var tangentialFactor: Double { tangential ?? BallSpec.ownerTangential }

    /// The owner's ball, as the app runs it (`AppSettings.ball`, `RecordingSettings()`, the synthetic kits): 30 mm, the
    /// owner's word ("I used a 30mm ball"), and measured on the owner's first kit as 30.1 ± 0.6 mm (its outline fitted
    /// as a cone from the camera on the floor at 3 ft and at 5 ft: 30.10 and 30.12 mm). The app had assumed 35 mm (16%
    /// too big, which put the held ball 16% too far away and its drop height off by centimetres). It bounces with the
    /// restitution measured on the owner's first kit and the tangential share that keeps the distance the owner matched
    /// (`ownerRestitution`, `ownerTangential`).
    public static let ownerBall = BallSpec(diameter: ownerDiameterMm / 1000, restitution: ownerRestitution, tangential: ownerTangential)
    /// the owner's ball's diameter (mm): change it here
    public static let ownerDiameterMm = 30.0
    /// The owner's ball's restitution on the slab: 0.9, measured on the owner's first kit (its drops' first bounces
    /// 0.896, 0.912, 0.903 and 0.917 one by one, each ± 0.01-0.03 and fitted assuming the ball was let go from rest;
    /// 0.89-0.91 without that; its later bounces 0.917-0.924, and the flight times between them 0.93; the second kit's
    /// are not measured well: one usable first bounce, seen for 4 frames of its fall). The owner had said about 0.8 and
    /// does not have an exact figure ("whatever you calculate is probably good"); n12 used 0.8. The app's setting starts
    /// here (`RecordingSettings.restitution`, AppSettings.defaultRestitution).
    public static let ownerRestitution = 0.9
    /// The share of the along-surface velocity the owner's ball keeps through a bounce off the slab (k_t): 0.2. It is not
    /// measured. It is the share that, with the restitution 0.9 (`ownerRestitution`), keeps the owner's finding that n11's
    /// Rebound at 100% (the old launch along the slab's normal, with no speed along the surface) matched the real
    /// distance: on a tilted slab the new bounce's range over that one's is about e (e + k_t), 0.9 x 1.1 = 0.99 (the
    /// predicted distance 0.94-1.00 x n11's at 100% on 0.5-12° slabs from 1 and 3 ft). n12 used 0.4 with e 0.8 (0.96).
    /// The kits' drops, all on a near-level slab, fit it only loosely, 0.39 ± 0.21 over both kits with a poor fit
    /// (chi²/dof 122/11 and 33/7; single bounces from -1.9 to 2.8), and on their landings anything from 0 to 0.6 does
    /// about as well. (A solid ball that rolls off keeps 5/7, a thin shell 0.6.) A drop on a tilted slab measures it.
    public static let ownerTangential = 0.2
}

/// Where a ball held above the slab would land if let go, and from how high.
public struct DropPoint: Equatable {
    /// the ball's centre (same frame as the pose)
    public var ballCenter: Vec3
    /// where it lands on the dish, straight below its centre
    public var landing: Vec3
    /// how far it falls before touching (centre height above the landing point minus its radius), metres
    public var dropHeight: Double
    /// the dish's own normal at the landing point
    public var dishNormal: Vec3
    /// landing point in the slab's (u, v) coordinates
    public var u: Double
    public var v: Double
    /// whether it lands on the slab (within 5% of its edges)
    public var onSlab: Bool
    /// The impact rule (`Bounce.impactDrop`): the ball's centre when it first touches the dish and the point it touches
    /// (`landing` is then that point, `dishNormal` the dish's normal there and `dropHeight` how far the centre fell);
    /// nil for the older rules, which take the point straight below the centre.
    public var impactCenter: Vec3? = nil
}

/// A bounce off the slab: the path the ball takes after it hits.
public struct BouncePath: Equatable {
    /// where the ball is launched from (on the slab's surface)
    public var start: Vec3
    /// launch direction (unit)
    public var direction: Vec3
    /// launch speed (m/s)
    public var speed: Double
    /// gravity's direction (unit)
    public var down: Vec3
    /// time until it falls to the end level (s)
    public var airTime: Double
    /// time of the highest point (s; 0 if it starts out going down)
    public var apexTime: Double
    /// how far the highest point lies above the start (m)
    public var apexHeight: Double

    /// position t seconds after the bounce
    public func position(at t: Double) -> Vec3 {
        start + direction * (speed * t) + down * (0.5 * Units.gravity * t * t)
    }
    public var apex: Vec3 { position(at: apexTime) }
    public var landing: Vec3 { position(at: airTime) }
    /// horizontal distance from the start to where it lands (m)
    public var range: Double { let d = landing - start; return d.rejecting(down).length }
    /// points along the path for drawing
    public func samples(count n: Int = 48) -> [Vec3] { (0...n).map { position(at: airTime * Double($0) / Double(n)) } }
}

public enum Bounce {
    /// Which way the ball leaves the slab.
    public enum LaunchRule: String, Codable {
        /// perpendicular to the plane through the four top corners, at the speed of the rebound (the app's rule until
        /// n11; recordings made with it replay with it)
        case cornerPlane
        /// perpendicular to the dish where the ball lands (leans toward the middle off-centre; a developer experiment
        /// until n11)
        case dishNormal
        /// a real impact (the app's rule from n12, `Bounce.impact`): the falling ball touches the dish (the measured
        /// spherical cap, `KitDish.sphericalCap`) where it first meets it, and its velocity there is split along the
        /// dish's local normal, reversed and scaled by the restitution e, and along the surface, scaled by the ball's
        /// tangential share k_t (`BallSpec.restitution`, `tangentialFactor`)
        case impact
    }

    /// What a ball's image radius means.
    public enum RadiusModel {
        /// the radius of a circle fitted to the ball's outline in the image. Off the optical axis a sphere's image is an
        /// ellipse, f tan(a)/cos(t) across and f tan(a)/cos^2(t) along the radial direction (a: the ball's angular
        /// radius, t: its angle from the axis); a circle fit lands near their mean.
        case imageCircle
        /// f tan(a): the radius the ball would have at the centre of the image (the web test bed's ground truth)
        case onAxis
    }

    /// Ball centre in camera (CV) coordinates from its image circle: distance from its known size along the ray
    /// through the circle's centre. (The web app took f R / r as the depth along the axis, which puts a ball off
    /// the middle of the picture a few per cent too far away.)
    public static func ballCenter(pixel: Vec2, radiusPixels r: Double, intrinsics K: CameraIntrinsics, ball: BallSpec,
                                  model: RadiusModel = .imageCircle) -> Vec3? {
        guard r > 0.5 else { return nil }
        let ray = K.ray(pixel), c = 1 / ray.length // cos of the angle from the axis
        let stretch = model == .imageCircle ? (1 / c + 1 / (c * c)) / 2 : 1
        let tanA = r / (K.focal * stretch)
        let dist = ball.radius * (1 + tanA * tanA).squareRoot() / tanA // R / sin(a)
        return ray.normalized * dist
    }

    /// Drop a ball straight down (along `down`) onto the slab's dished top. Everything in one frame (camera or world).
    /// Port of the web app's ballDrop.
    public static func drop(ballCenter B: Vec3, pose: SlabPose, spec: SlabSpec, ball: BallSpec, down gIn: Vec3) -> DropPoint? {
        let g = gIn.normalized, den = g.dot(pose.normal)
        // the ball must be above the face, and the face must not be turned away from gravity
        guard den < -1e-3 else { return nil }
        let sd = (pose.center - B).dot(pose.normal) / den
        guard sd > 0 else { return nil }
        var H = B + g * sd
        var (u, v) = pose.local(H)
        var extra = 0.0
        for _ in 0..<3 {
            let dh = Dish.at(pose: pose, depth: spec.dishDepth, u: u, v: v)
            extra = dh.depth / -den
            (u, v) = pose.local(B + g * (sd + extra))
        }
        H = B + g * (sd + extra)
        let dh = Dish.at(pose: pose, depth: spec.dishDepth, u: u, v: v)
        let on = abs(u) <= pose.halfU * 1.05 && abs(v) <= pose.halfV * 1.05
        return DropPoint(ballCenter: B, landing: H, dropHeight: max(0.006, sd + extra - ball.radius), dishNormal: dh.normal, u: u, v: v, onSlab: on)
    }

    /// The dish the impact rule bounces off: the measured shape, a spherical cap `dishDepth` deep at the centre whose rim
    /// is the circle inscribed in the flat top (`KitDish.sphericalCap`; the top flat outside it). Measured on the owner's
    /// first kit (its top's height map from many views, inside 88 mm of the centre): the dish curves 0.385 ± 0.013 /m
    /// (four positions: 0.364, 0.436, 0.370, 0.405), the cap 1/8 in deep over the 180.2 mm top 0.391 /m, the bowl through
    /// the four corners (`Dish.at`, the older rules') 0.196 /m. So off the centre the dish leans about twice as much as
    /// the older rules took: 2.2° at 2 in from the middle.
    public static func impactDish(_ spec: SlabSpec) -> KitDish { KitDish(spec: spec, shape: .sphericalCap) }

    /// Drop a ball straight down (along `down`) until it first touches the dish (`impactDish`): where it touches, its
    /// centre then, the dish's normal there (from the point toward the centre) and how far the centre fell. Off the
    /// middle of a dish (or on a tilted slab) the ball touches it to the side of the point straight below its centre, on
    /// the slope that faces it. The top runs on, flat, past the slab's outline: a ball beyond the edges gets a point
    /// there with `onSlab` false (the caller decides). nil when the ball cannot come down on the top: the fall line does
    /// not meet its face, or the ball is already more than a diameter below it.
    public static func impactDrop(ballCenter B: Vec3, pose: SlabPose, spec: SlabSpec, ball: BallSpec, down gIn: Vec3) -> DropPoint? {
        let g = gIn.normalized, den = g.dot(pose.normal), r = ball.radius
        guard den < -1e-3 else { return nil }
        let dish = impactDish(spec)
        func clearance(_ s: Double) -> Double { dish.contact(center: pose.toSlab(B + g * s), radius: r).clearance }
        // the centre's fall to the corner plane, then on down past the dish's depth: the ball is in it by then
        let sPlane = (pose.center - B).dot(pose.normal) / den
        guard sPlane > -2 * r else { return nil }
        var s = 0.0
        if clearance(0) > 0 {
            var lo = 0.0, hi = max(0, sPlane) + (spec.dishDepth + 2 * r) / -den
            guard clearance(hi) < 0 else { return nil }
            // the first touch: the clearance falls along the fall line; bisect it to 0.1 µm
            for _ in 0..<80 {
                let m = (lo + hi) / 2
                if clearance(m) > 0 { lo = m } else { hi = m }
                if hi - lo < 1e-7 { break }
            }
            s = (lo + hi) / 2
        }
        // (a ball already touching the dish touches it where it is)
        let C = B + g * s
        let k = dish.contact(center: pose.toSlab(C), radius: r)
        let point = pose.fromSlab(k.point), n = pose.directionFromSlab(k.normal).normalized
        let on = abs(k.point.x) <= pose.halfU * 1.05 && abs(k.point.y) <= pose.halfV * 1.05
        return DropPoint(ballCenter: B, landing: point, dropHeight: max(0.006, s), dishNormal: n, u: k.point.x, v: k.point.y,
                         onSlab: on, impactCenter: C)
    }

    /// The velocity after an impact: `v` split along the surface's unit normal `n` (pointing out of it) and along the
    /// surface; the part along the normal reversed and scaled by `restitution`, the part along it by `tangential`.
    /// Unchanged when the ball is not moving into the surface.
    public static func impact(velocity v: Vec3, normal nIn: Vec3, restitution e: Double, tangential k: Double) -> Vec3 {
        let n = nIn.normalized, vn = v.dot(n)
        guard vn < 0 else { return v }
        return n * (-e * vn) + (v - n * vn) * k
    }

    /// A flight from `start` with velocity `velocity`, ending where it has fallen to `endHeight` below the start.
    public static func path(start: Vec3, velocity: Vec3, down gIn: Vec3, endHeight: Double, maxTime: Double = 4) -> BouncePath {
        let g = gIn.normalized, G = Units.gravity
        let speed = velocity.length
        let dir = speed > 1e-12 ? velocity / speed : -g
        let vup = -velocity.dot(g)
        let fall = max(0, endHeight)
        var T = (vup + (vup * vup + 2 * G * fall).squareRoot()) / G
        if !T.isFinite || T < 0 { T = 0 }
        T = min(maxTime, T)
        let apexT = vup > 0 ? min(T, vup / G) : 0
        let apexH = vup > 0 ? vup * vup / (2 * G) : 0
        return BouncePath(start: start, direction: dir, speed: speed, down: g, airTime: T, apexTime: apexT, apexHeight: apexH)
    }

    /// The bounce. The ball falls `dropHeight` onto `start`, leaves along `direction` with the speed that would carry it
    /// `rebound` x `dropHeight` straight up, and the path ends where it has fallen to `endHeight` below the start
    /// (e.g. the floor, or the slab's lowest corner). Port of the web app's update().
    public static func path(start: Vec3, direction nIn: Vec3, dropHeight: Double, rebound: Double, down gIn: Vec3,
                            endHeight: Double, maxTime: Double = 4) -> BouncePath {
        let g = gIn.normalized, n = nIn.normalized, G = Units.gravity
        let v0 = (2 * G * max(0, dropHeight) * max(0, rebound)).squareRoot()
        let vup = -v0 * n.dot(g)
        let fall = max(0, endHeight)
        var T = (vup + (vup * vup + 2 * G * fall).squareRoot()) / G
        if !T.isFinite || T < 0 { T = 0 }
        T = min(maxTime, T)
        let apexT = vup > 0 ? min(T, vup / G) : 0
        let apexH = vup > 0 ? vup * vup / (2 * G) : 0
        return BouncePath(start: start, direction: n, speed: v0, down: g, airTime: T, apexTime: apexT, apexHeight: apexH)
    }

    /// The whole calculation for one moment: drop point from the ball if it is over the slab, otherwise the middle of the
    /// dish and the default drop height; launch per `rule`; the path ends `belowStart` metres below the start if given
    /// (e.g. down to the floor), else at the height of the slab's lowest top corner.
    public static func compute(pose: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3, ballCenter: Vec3?,
                               defaultDropHeight: Double, rule: LaunchRule = .cornerPlane, floorBelowCenter: Double? = nil) -> (path: BouncePath, drop: DropPoint?) {
        if rule == .impact {
            return computeImpact(pose: pose, spec: spec, ball: ball, down: down, ballCenter: ballCenter, defaultDropHeight: defaultDropHeight,
                                 floorBelowCenter: floorBelowCenter)
        }
        let g = down.normalized
        var start = pose.center - pose.normal * spec.dishDepth
        var dropH = defaultDropHeight
        var dir = pose.normal
        var dp: DropPoint? = nil
        if let B = ballCenter, let d = Bounce.drop(ballCenter: B, pose: pose, spec: spec, ball: ball, down: g), d.onSlab {
            start = d.landing; dropH = d.dropHeight; dp = d
            if rule == .dishNormal { dir = d.dishNormal }
        }
        // heights measured up from the slab's centre
        let h0 = -(start - pose.center).dot(g)
        let endLevel: Double
        if let floor = floorBelowCenter {
            endLevel = -floor
        } else {
            endLevel = pose.topCorners.map { -($0 - pose.center).dot(g) }.min() ?? 0
        }
        let p = path(start: start, direction: dir, dropHeight: dropH, rebound: ball.rebound, down: g, endHeight: h0 - endLevel)
        return (p, dp)
    }
    /// The impact rule's calculation (`LaunchRule.impact`; `compute` with that rule). The ball held over the slab falls
    /// straight down until it first touches the dish (`impactDrop`), else (no ball over the slab) a ball dropped from the
    /// default height onto the middle of the dish; it comes in at the speed of its fall, sqrt(2 g h), and leaves with
    /// `impact` about the dish's normal where it touched, with the ball's restitution and tangential share. The path is
    /// the ball's lowest point (its centre a radius above it), from the moment it leaves, down to the same end level as
    /// the older rules (the floor `floorBelowCenter` below the slab's centre when given, else the lowest top corner).
    static func computeImpact(pose: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3, ballCenter: Vec3?,
                              defaultDropHeight: Double, floorBelowCenter: Double?) -> (path: BouncePath, drop: DropPoint?) {
        let g = down.normalized, r = ball.radius
        let bottom = pose.center - pose.normal * spec.dishDepth
        // no ball: touching the middle of the dish, where its normal is the slab's
        var center = bottom + pose.normal * r
        var normal = pose.normal
        var fall = defaultDropHeight
        var dp: DropPoint? = nil
        if let B = ballCenter, let d = impactDrop(ballCenter: B, pose: pose, spec: spec, ball: ball, down: g), d.onSlab, let c = d.impactCenter {
            center = c; normal = d.dishNormal; fall = d.dropHeight; dp = d
        }
        let vin = g * (2 * Units.gravity * max(0, fall)).squareRoot()
        let vout = impact(velocity: vin, normal: normal, restitution: ball.restitution, tangential: ball.tangentialFactor)
        let start = center + g * r
        let h0 = -(start - pose.center).dot(g)
        let endLevel: Double
        if let floor = floorBelowCenter {
            endLevel = -floor
        } else {
            endLevel = pose.topCorners.map { -($0 - pose.center).dot(g) }.min() ?? 0
        }
        return (path(start: start, velocity: vout, down: g, endHeight: h0 - endLevel), dp)
    }
}
