import Foundation

// Tap hints (n12): the owner may tap the slab, the ball, or a ball ring that is wrong. Nothing asks for a tap and nothing
// needs one: a tap only makes the search look somewhere first, or takes back a ball the finder got wrong. What a tap
// means is decided by what is under the finger (`SlabTracker`, `TrackerSettings.tapHints`): a ring shown there is
// dismissed; a place where a ball held over the locked slab could be is searched for the ball first; anywhere else the
// slab is looked for there. The geometry is here; the tracker keeps the state.

/// What a tap was taken for.
public enum TrackerTapKind: String, Codable {
    /// look for the slab there (the only kind before n12, and the only one with `TrackerSettings.tapHints` off)
    case slab
    /// look for the ball there first (the slab is locked, and a ball held over it could be under the finger)
    case ball
    /// the ball ring under the finger is wrong: drop it and pass over that spot
    case dismissBall
}

/// A tap this frame and what it was taken for (`TrackerOutput.tap`), for the app's brief feedback.
public struct TrackerTap: Equatable {
    public var kind: TrackerTapKind
    /// the tapped point (pixels of the processing frame)
    public var pixel: Vec2
    /// a dismissed ring: the ball's centre as it was shown (world), and its radius in the processing frame (pixels)
    public var ballCenter: Vec3?
    public var ballRadiusPixels: Double?
    public init(kind: TrackerTapKind, pixel: Vec2, ballCenter: Vec3? = nil, ballRadiusPixels: Double? = nil) {
        self.kind = kind; self.pixel = pixel; self.ballCenter = ballCenter; self.ballRadiusPixels = ballRadiusPixels
    }
}

/// A ball tap: the tapped line of sight (world), and the stretch of it where the centre of a ball held over the locked
/// slab can be (`TapHints.ballRange`).
public struct BallTapHint: Equatable {
    public var origin: Vec3
    public var direction: Vec3
    /// distances along the line (m) between which the ball's centre can be
    public var near: Double
    public var far: Double
    /// seconds since the tap, or since the latest ball found in its box
    public var age: Double = 0
    /// a ball has been found in its box (the search then stays on it: `TapHints.recentred`)
    public var found = false
    public init(origin: Vec3, direction: Vec3, near: Double, far: Double) {
        self.origin = origin; self.direction = direction; self.near = near; self.far = far
    }
    public func point(at s: Double) -> Vec3 { origin + direction * s }
}

/// A dismissed ring's spot (world), passed over by the ball finder until it expires or the slab's lock changes. How far
/// away the thing taken for a ball is, is not known: its size put it where a 30 mm ball would be (`near`), but most
/// false rings are things on the floor or on the slab, farther along the same line of sight (`far`: where it meets the
/// plane of the slab's top; the floor is about the slab's height below that). The spot is that stretch of the line,
/// with a radius at each end (a capsule), so it stays over the thing wherever along it the thing is as the phone moves.
public struct DismissedBallSpot: Equatable {
    public var near: Vec3
    public var far: Vec3
    /// how far around each end (m)
    public var nearRadius: Double
    public var farRadius: Double
    /// seconds since it was dismissed
    public var age: Double = 0
    public init(near: Vec3, far: Vec3, nearRadius: Double, farRadius: Double) {
        self.near = near; self.far = far; self.nearRadius = nearRadius; self.farRadius = farRadius
    }
}

/// Where the ball finder passes over any ball in one scan's image: a dismissed spot as seen there, the image of its
/// stretch of line with the radius growing from one end's to the other's (a circle while the phone has not moved).
public struct BallSearchAvoid: Equatable {
    public var start: Vec2
    public var end: Vec2
    public var startRadius: Double
    public var endRadius: Double
    public init(start: Vec2, end: Vec2, startRadius: Double, endRadius: Double) {
        self.start = start; self.end = end; self.startRadius = startRadius; self.endRadius = endRadius
    }
    public init(center: Vec2, radius: Double) { self.init(start: center, end: center, startRadius: radius, endRadius: radius) }
    /// whether p lies within it, grown by `margin` pixels
    public func covers(_ p: Vec2, margin: Double = 0) -> Bool {
        let d = end - start, l2 = d.dot(d)
        let t = l2 > 1e-12 ? clamp((p - start).dot(d) / l2, 0, 1) : 0
        return p.distance(to: start + d * t) < startRadius + (endRadius - startRadius) * t + margin
    }
}

/// What the owner's taps tell the ball finder for one scan (pixels of the ball finder's image): where to look first and
/// at what size (a ball tap), and where to pass over a ball (dismissed rings). Empty: nothing (no taps).
public struct BallSearchHints: Equatable {
    /// look here first, for balls of these radii
    public var region: ImageRect? = nil
    public var radii: ClosedRange<Double>? = nil
    /// pass over a ball centred in any of these
    public var avoid: [BallSearchAvoid] = []
    public init(region: ImageRect? = nil, radii: ClosedRange<Double>? = nil, avoid: [BallSearchAvoid] = []) {
        self.region = region; self.radii = radii; self.avoid = avoid
    }
    public var isEmpty: Bool { region == nil && avoid.isEmpty }
    public func avoids(_ p: Vec2) -> Bool { avoid.contains { $0.covers(p) } }
}

public enum TapHints {
    /// The heights (m, the ball's bottom over the slab's top face) at which a tapped ball is looked for: from resting on
    /// it to well over the highest drop the owner holds (the ball finder decides what it reports; this only says where
    /// to look first).
    public static let ballHeights: ClosedRange<Double> = 0.0...1.8

    /// How far from the finger a tap still counts, in pixels of an image of `width` x `height`: `fraction` of its
    /// shorter side.
    public static func slack(fraction: Double, width: Int, height: Int) -> Double {
        max(2, fraction * Double(min(width, height)))
    }

    /// Where along a line of sight (world; `direction` of unit length) the centre of a ball held over the slab (world
    /// pose) could be: the distances at which a ball's straight drop (along `down`) lands within the slab's footprint
    /// (scaled by `footprint`, plus `slack` metres for the finger) with its bottom `heights` over the top face. nil when
    /// the line passes no such place.
    public static func ballRange(origin o: Vec3, direction d: Vec3, slab: SlabPose, ball: BallSpec, down: Vec3,
                                 heights: ClosedRange<Double> = ballHeights, footprint: Double = 1.05, slack: Double = 0) -> ClosedRange<Double>? {
        let up = -down.normalized, n = slab.normal
        let un = up.dot(n)
        // a top face turned far from gravity has no "over it"
        guard un > 0.2, d.isFinite, d.length > 0.5 else { return nil }
        let R = ball.radius
        let hu = slab.halfU * footprint + slack, hv = slab.halfV * footprint + slack
        var lo = Double.infinity, hi = -Double.infinity
        // log-spaced distances, 2% apart, from 5 cm to 8 m
        let s0 = 0.05, s1 = 8.0, steps = 300
        for i in 0...steps {
            let s = s0 * pow(s1 / s0, Double(i) / Double(steps))
            let B = o + d * s
            // the straight drop's distance down to the top face's plane, and where it lands there
            let t = (B - slab.center).dot(n) / un
            let h = t - R
            guard h >= heights.lowerBound, h <= heights.upperBound else { continue }
            let (u, v) = slab.local(B - up * t)
            guard abs(u) <= hu, abs(v) <= hv else { continue }
            lo = min(lo, s); hi = max(hi, s)
        }
        return lo <= hi ? lo...hi : nil
    }

    /// The ball tap as a place to look in one scan's image (`view`: the camera for the ball finder's image, world): the
    /// box the tapped line's possible ball centres project into, padded by their largest radius and the finger's `slack`
    /// (pixels of that image), and the radii a ball has along it (imageCircle sense, 20% to spare either way, as the
    /// locator's own window). nil when none of it is in front of the camera.
    public static func searchRegion(_ h: BallTapHint, view: CameraView, ball: BallSpec, slack: Double) -> (region: ImageRect, radii: ClosedRange<Double>)? {
        let K = view.intrinsics
        var box = ImageRect.empty, rLo = Double.infinity, rHi = -Double.infinity
        let n = 12
        for i in 0...n {
            let s = h.near + (h.far - h.near) * Double(i) / Double(n)
            let B = view.toCamera(h.point(at: s))
            guard B.z > 0.05, let p = K.project(B), let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball) else { continue }
            box = box.union(p); rLo = min(rLo, r); rHi = max(rHi, r)
        }
        guard rLo <= rHi else { return nil }
        let region = box.expanded(by: rHi * 1.2 + slack).clamped(width: K.width, height: K.height)
        return region.isEmpty ? nil : (region, (rLo / 1.2)...(rHi * 1.2))
    }

    /// A ball tap's search once a ball was found in its box (centre `ball`, world, seen from `camera`): the line of sight
    /// through that ball, over the distances its size can put it at (a quarter either way, as the finder's own radius
    /// window), the time counted again from now. So the search keeps the place and the size it found, follows a ball
    /// that moves a little (held) or falls, and ends `TrackerSettings.tapBallSeconds` after the last find there.
    public static func recentred(_ h: BallTapHint, on ball: Vec3, from camera: Vec3) -> BallTapHint {
        let v = ball - camera, d = v.length
        guard d > 0.05, d.isFinite else { var x = h; x.age = 0; x.found = true; return x }
        var x = BallTapHint(origin: camera, direction: v / d, near: d / 1.25, far: d * 1.25)
        x.found = true
        return x
    }

    /// A dismissed spot as seen by a camera (`view`, world): its stretch of line and radii in that camera's image
    /// (pixels). nil when either end is behind the camera.
    public static func avoidCircle(_ spot: DismissedBallSpot, view: CameraView) -> BallSearchAvoid? {
        let a = view.toCamera(spot.near), b = view.toCamera(spot.far), K = view.intrinsics
        guard a.z > 0.05, b.z > 0.05, let p = K.project(a), let q = K.project(b) else { return nil }
        return BallSearchAvoid(start: p, end: q, startRadius: spot.nearRadius * K.focal / a.z, endRadius: spot.farRadius * K.focal / b.z)
    }

    /// The spot of a dismissed ring (`DismissedBallSpot`): from the ball's centre as it was shown out along its line of
    /// sight to where that meets the plane of the slab's top, when it does within 10 m in front and beyond the ball
    /// (else the ball's centre alone); around each end half again the ring's own size at that distance, at least the
    /// ball's diameter.
    public static func dismissedSpot(ballCenter b: Vec3, ringRadiusPixels r: Double, view: CameraView, slab: SlabPose, ball: BallSpec) -> DismissedBallSpot {
        let o = view.position, toBall = b - o, len = toBall.length
        var far = b
        if len > 1e-6, let p = Plane3(point: slab.center, normal: slab.normal).intersect(origin: o, direction: toBall / len) {
            let s = (p - o).dot(toBall / len)
            if s > len && s < 10 { far = p }
        }
        func size(_ w: Vec3) -> Double {
            let z = view.toCamera(w).z
            return max(z > 0.05 ? 1.5 * r * z / view.intrinsics.focal : 0, ball.diameter)
        }
        return DismissedBallSpot(near: b, far: far, nearRadius: size(b), farRadius: size(far))
    }
}
