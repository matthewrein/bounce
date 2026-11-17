import Foundation

/// The ball and how it bounces.
public struct BallSpec: Equatable, Codable {
    /// diameter (metres); the owner's ball is 35 mm
    public var diameter: Double
    /// rebound: the share of the drop height the ball would regain bouncing straight up (0.70 = 70%)
    public var rebound: Double
    public init(diameter: Double = 0.035, rebound: Double = 0.70) { self.diameter = diameter; self.rebound = rebound }
    public var radius: Double { diameter / 2 }
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
        /// perpendicular to the plane through the four top corners (the app's rule)
        case cornerPlane
        /// perpendicular to the dish where the ball lands (leans toward the middle off-centre)
        case dishNormal
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
}
