import XCTest
@testable import BounceCore

final class BounceTests: XCTestCase {
    let down = Vec3(0, -1, 0) // world-style: y up

    func levelPose(at c: Vec3 = .zero) -> SlabPose {
        SlabPose(center: c, normal: Vec3(0, 1, 0), axisU: Vec3(1, 0, 0), axisV: Vec3(0, 0, -1), halfU: Units.inches(3.5), halfV: Units.inches(3.5))
    }

    func testStraightUpOnLevelSlab() {
        // 1 m drop, 70% rebound, level: straight up 0.7 m and back down to the start level
        let p = Bounce.path(start: .zero, direction: Vec3(0, 1, 0), dropHeight: 1, rebound: 0.7, down: down, endHeight: 0)
        XCTAssertEqual(p.apexHeight, 0.7, accuracy: 1e-12)
        XCTAssertEqual(p.speed, (2 * Units.gravity * 0.7).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(p.airTime, 2 * p.speed / Units.gravity, accuracy: 1e-12)
        XCTAssertEqual(p.range, 0, accuracy: 1e-9)
        XCTAssertEqual(p.landing.y, 0, accuracy: 1e-9)
        XCTAssertEqual(p.apex.y, 0.7, accuracy: 1e-9)
    }

    func testTiltedLaunchRangeMatchesProjectileFormula() {
        let th = Units.radians(10)
        let n = Vec3(sin(th), cos(th), 0)
        let p = Bounce.path(start: .zero, direction: n, dropHeight: 0.9, rebound: 0.7, down: down, endHeight: 0)
        let v0 = (2 * Units.gravity * 0.9 * 0.7).squareRoot()
        // classic projectile on level ground: range = v0^2 sin(2 * elevation) / g, elevation = 90 - 10 degrees
        XCTAssertEqual(p.range, v0 * v0 * sin(2 * (Double.pi / 2 - th)) / Units.gravity, accuracy: 1e-9)
        XCTAssertEqual(p.apexHeight, pow(v0 * cos(th), 2) / (2 * Units.gravity), accuracy: 1e-12)
        XCTAssertGreaterThan(p.landing.x, 0) // leans the way the normal leans
    }

    func testEndBelowStartAddsFallTime() {
        let p0 = Bounce.path(start: .zero, direction: Vec3(0, 1, 0), dropHeight: 1, rebound: 0.5, down: down, endHeight: 0)
        let p1 = Bounce.path(start: .zero, direction: Vec3(0, 1, 0), dropHeight: 1, rebound: 0.5, down: down, endHeight: 0.06)
        XCTAssertGreaterThan(p1.airTime, p0.airTime)
        XCTAssertEqual(p1.landing.y, -0.06, accuracy: 1e-9)
        // zero rebound: no flight, it just falls the end height
        let p2 = Bounce.path(start: .zero, direction: Vec3(0, 1, 0), dropHeight: 1, rebound: 0, down: down, endHeight: 0.05)
        XCTAssertEqual(p2.apexHeight, 0)
        XCTAssertEqual(p2.airTime, (2 * 0.05 / Units.gravity).squareRoot(), accuracy: 1e-12)
    }

    func testDropStraightDownOntoDish() {
        let pose = levelPose()
        let spec = SlabSpec.standard, ball = BallSpec()
        // ball centre 0.5 m above the middle: falls 0.5 - dish? No: the dish lies below the corner plane, so it falls
        // 0.5 + dishDepth - radius
        let d = Bounce.drop(ballCenter: Vec3(0, 0.5, 0), pose: pose, spec: spec, ball: ball, down: down)!
        XCTAssertEqual(d.dropHeight, 0.5 + spec.dishDepth - ball.radius, accuracy: 1e-12)
        XCTAssertEqual(d.landing.y, -spec.dishDepth, accuracy: 1e-12)
        XCTAssertTrue(d.onSlab)
        XCTAssertEqual(d.dishNormal.distance(to: pose.normal), 0, accuracy: 1e-12)
        // off-centre: lands at half depth at an edge middle
        let e = Bounce.drop(ballCenter: Vec3(pose.halfU, 0.5, 0), pose: pose, spec: spec, ball: ball, down: down)!
        XCTAssertEqual(e.landing.y, -spec.dishDepth / 2, accuracy: 1e-12)
        XCTAssertLessThan(e.dishNormal.x, 0) // leans back toward the middle
        // beyond the slab: not on it
        let f = Bounce.drop(ballCenter: Vec3(0.2, 0.5, 0), pose: pose, spec: spec, ball: ball, down: down)!
        XCTAssertFalse(f.onSlab)
        // below the slab: nothing
        XCTAssertNil(Bounce.drop(ballCenter: Vec3(0, -0.2, 0), pose: pose, spec: spec, ball: ball, down: down))
    }

    func testDropOnTiltedSlabIsVertical() {
        // tilted 10 deg: the landing point is straight below the ball, on the dish
        let th = Units.radians(10), n = Vec3(sin(th), cos(th), 0), u = Vec3(cos(th), -sin(th), 0)
        let pose = SlabPose(center: .zero, normal: n, axisU: u, axisV: n.cross(u), halfU: Units.inches(3.5), halfV: Units.inches(3.5))
        let spec = SlabSpec.standard, ball = BallSpec()
        let B = Vec3(0.03, 0.6, 0.01)
        let d = Bounce.drop(ballCenter: B, pose: pose, spec: spec, ball: ball, down: down)!
        XCTAssertEqual(d.landing.x, B.x, accuracy: 1e-9)
        XCTAssertEqual(d.landing.z, B.z, accuracy: 1e-9)
        // the landing point lies on the dish surface: corner plane minus the dish depth there (along the normal)
        let dish = Dish.at(pose: pose, depth: spec.dishDepth, u: d.u, v: d.v)
        XCTAssertEqual(pose.height(of: d.landing), -dish.depth, accuracy: 1e-6)
    }

    func testBallCenterFromImageCircle() {
        let K = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let ball = BallSpec()
        // a ball well off the axis: its on-axis-equivalent radius f tan(a) gives back the exact centre
        let truth = Vec3(0.35, -0.3, 1.1)
        let px = K.project(truth)!, d = truth.length
        let r = K.focal * ball.radius / (d * d - ball.radius * ball.radius).squareRoot()
        let c = Bounce.ballCenter(pixel: px, radiusPixels: r, intrinsics: K, ball: ball, model: .onAxis)!
        XCTAssertEqual(c.distance(to: truth), 0, accuracy: 1e-9)
        // as an image circle it looks bigger off the axis; reading it as one puts it back at the right distance
        let cosT = truth.z / d, rImg = r * (1 / cosT + 1 / (cosT * cosT)) / 2
        let c2 = Bounce.ballCenter(pixel: px, radiusPixels: rImg, intrinsics: K, ball: ball)!
        XCTAssertEqual(c2.distance(to: truth), 0, accuracy: 1e-9)
        // the old reading (f R / r as the depth) is off by several per cent here
        let old = K.unproject(px, depth: K.focal * ball.radius / r)
        XCTAssertGreaterThan(old.distance(to: truth) / d, 0.03)
    }

    func testComputeUsesBallOrDefault() {
        let pose = levelPose(), spec = SlabSpec.standard, ball = BallSpec()
        let noBall = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: nil, defaultDropHeight: Units.feet(3))
        XCTAssertNil(noBall.drop)
        XCTAssertEqual(noBall.path.apexHeight, Units.feet(3) * 0.7, accuracy: 1e-9)
        XCTAssertEqual(noBall.path.start.y, -spec.dishDepth, accuracy: 1e-12)
        let withBall = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: Vec3(0.02, 0.4, 0.01), defaultDropHeight: Units.feet(3))
        XCTAssertNotNil(withBall.drop)
        XCTAssertEqual(withBall.path.apexHeight, withBall.drop!.dropHeight * 0.7, accuracy: 1e-9)
        // the dish rule leans the launch toward the middle; the corner-plane rule does not
        let dishRule = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: Vec3(0.06, 0.4, 0), defaultDropHeight: 1, rule: .dishNormal)
        XCTAssertLessThan(dishRule.path.direction.x, 0)
        let planeRule = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: Vec3(0.06, 0.4, 0), defaultDropHeight: 1, rule: .cornerPlane)
        XCTAssertEqual(planeRule.path.direction.x, 0, accuracy: 1e-12)
        // a floor 6 cm below the slab's centre lengthens the flight
        let floor = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: nil, defaultDropHeight: 1, floorBelowCenter: 0.06)
        XCTAssertGreaterThan(floor.path.airTime, noBall.path.airTime)
    }
    // MARK: the impact rule (n12)

    func tiltedPose(_ deg: Double) -> SlabPose {
        let th = Units.radians(deg), n = Vec3(sin(th), cos(th), 0), u = Vec3(cos(th), -sin(th), 0)
        return SlabPose(center: .zero, normal: n, axisU: u, axisV: n.cross(u), halfU: Units.inches(3.5), halfV: Units.inches(3.5))
    }

    /// The velocity split about the normal: reversed and scaled by e along it, scaled by k_t along the surface; a ball
    /// moving away from the surface is left alone.
    func testImpactSplitsTheVelocityAboutTheNormal() {
        let n = Vec3(0.2, 1, -0.1).normalized, v = Vec3(0.3, -2.4, 0.1)
        let out = Bounce.impact(velocity: v, normal: n, restitution: 0.8, tangential: 0.6)
        XCTAssertEqual(out.dot(n), -0.8 * v.dot(n), accuracy: 1e-12)
        XCTAssertEqual((out - n * out.dot(n)).distance(to: (v - n * v.dot(n)) * 0.6), 0, accuracy: 1e-12)
        XCTAssertEqual(Bounce.impact(velocity: Vec3(0, 1, 0), normal: n, restitution: 0.8, tangential: 0.6), Vec3(0, 1, 0))
        // a ball coming in along the normal leaves along it, at e of its speed
        let straight = Bounce.impact(velocity: n * -2, normal: n, restitution: 0.8, tangential: 0)
        XCTAssertEqual(straight.distance(to: n * 1.6), 0, accuracy: 1e-12)
    }

    /// Dropped onto the middle of a level slab: the ball first touches the dish's lowest point, a radius below its
    /// centre, and goes straight back up to e² of its fall.
    func testImpactOnTheMiddleOfALevelSlab() throws {
        let pose = levelPose(), spec = SlabSpec.standard, ball = BallSpec(diameter: 0.03, restitution: 0.8, tangential: 0.6)
        let d = try XCTUnwrap(Bounce.impactDrop(ballCenter: Vec3(0, 0.4, 0), pose: pose, spec: spec, ball: ball, down: down))
        XCTAssertEqual(d.landing.distance(to: Vec3(0, -spec.dishDepth, 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(d.impactCenter).y, -spec.dishDepth + ball.radius, accuracy: 1e-6)
        XCTAssertEqual(d.dropHeight, 0.4 + spec.dishDepth - ball.radius, accuracy: 1e-6)
        XCTAssertEqual(d.dishNormal.distance(to: pose.normal), 0, accuracy: 1e-6)
        let r = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: Vec3(0, 0.4, 0), defaultDropHeight: 1, rule: .impact)
        XCTAssertEqual(r.path.apexHeight, 0.64 * d.dropHeight, accuracy: 1e-6)
        XCTAssertEqual(r.path.range, 0, accuracy: 1e-6)
        // the path is the ball's lowest point: its centre is a radius above it
        XCTAssertEqual(r.path.start.distance(to: try XCTUnwrap(d.impactCenter) + down * ball.radius), 0, accuracy: 1e-12)
        // no ball held: the default drop onto the middle
        let none = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: nil, defaultDropHeight: 1, rule: .impact)
        XCTAssertNil(none.drop)
        XCTAssertEqual(none.path.apexHeight, 0.64, accuracy: 1e-9)
        XCTAssertEqual(none.path.start.y, -spec.dishDepth, accuracy: 1e-12)
    }

    /// Off the middle the ball touches the dish (the measured spherical cap) on its slope and bounces back toward the
    /// middle: its normal there leans about r / R_cap, twice what the old rules' bowl through the corners leans, and the
    /// ball leaves with (e + k_t) of the speed along that lean.
    func testImpactOffTheMiddleLeansTowardIt() throws {
        let pose = levelPose(), spec = SlabSpec.ownerSlab, ball = BallSpec(diameter: 0.03, restitution: 0.8, tangential: 0.6)
        let x = 0.05
        let d = try XCTUnwrap(Bounce.impactDrop(ballCenter: Vec3(x, 0.3, 0), pose: pose, spec: spec, ball: ball, down: down))
        let cap = Bounce.impactDish(spec)
        XCTAssertEqual(cap.sphereRadius, 1.28, accuracy: 0.01, "the 1/8 in cap over the 180.2 mm top")
        // the contact lies on the slope that faces the ball: a little further out than the point below its centre (the
        // dish rises toward its rim)
        XCTAssertGreaterThan(d.landing.x, x)
        XCTAssertEqual(d.landing.x - x, ball.radius * sin(asin(d.landing.x / cap.sphereRadius)), accuracy: 1e-5)
        let lean = Units.degrees(d.dishNormal.angle(to: Vec3(0, 1, 0)))
        XCTAssertEqual(lean, Units.degrees(asin(d.landing.x / cap.sphereRadius)), accuracy: 0.01)
        let old = Units.degrees(Dish.at(pose: pose, depth: spec.dishDepth, u: x, v: 0).normal.angle(to: Vec3(0, 1, 0)))
        XCTAssertEqual(lean / old, 2, accuracy: 0.1, "the cap leans about twice the bowl through the corners")
        XCTAssertLessThan(d.dishNormal.x, 0)
        let r = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: Vec3(x, 0.3, 0), defaultDropHeight: 1, rule: .impact)
        let v = (2 * Units.gravity * d.dropHeight).squareRoot(), phi = Units.radians(lean)
        let vx = r.path.direction.x * r.path.speed
        XCTAssertEqual(vx, -(0.8 + 0.6) * v * sin(phi) * cos(phi), accuracy: 1e-6)
        XCTAssertLessThan(r.path.landing.x, d.landing.x, "it lands toward the middle")
        // beyond the slab: not on it; below it: nothing
        XCTAssertFalse(try XCTUnwrap(Bounce.impactDrop(ballCenter: Vec3(0.2, 0.5, 0), pose: pose, spec: spec, ball: ball, down: down)).onSlab)
        XCTAssertNil(Bounce.impactDrop(ballCenter: Vec3(0, -0.2, 0), pose: pose, spec: spec, ball: ball, down: down))
        // a ball resting in the dish touches it where it is
        let rest = try XCTUnwrap(Bounce.impactDrop(ballCenter: Vec3(0, -spec.dishDepth + ball.radius - 1e-4, 0), pose: pose, spec: spec, ball: ball, down: down))
        XCTAssertEqual(rest.dropHeight, 0.006, accuracy: 1e-12)
    }

    /// On a tilted slab the ball keeps k_t of its speed along the surface: it leaves at more than the tilt from
    /// vertical, downhill, and lands about where the old rule's launch along the normal at a rebound of 100% put it (the
    /// owner's finding: "Rebound 100% matched the distance"): with e 0.8 and k_t 0.6 on a 12° slab, 7% further.
    func testImpactOnATiltedSlabKeepsTheSpeedAlongIt() throws {
        let pose = tiltedPose(12), spec = SlabSpec.standard
        let ball = BallSpec(diameter: 0.03, restitution: 0.8, tangential: 0.6)
        let B = Vec3(0, 0.3, 0)
        let r = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: B, defaultDropHeight: 1, rule: .impact)
        let d = try XCTUnwrap(r.drop)
        // touches the dish uphill of the point straight below its centre, where the dish's normal is the slab's (it is
        // the cap's middle within a few mm), and leaves downhill at more than the tilt from vertical
        XCTAssertLessThan(d.landing.x, 0)
        let v = (2 * Units.gravity * d.dropHeight).squareRoot()
        let n = d.dishNormal, vin = Vec3(0, -v, 0)
        let expect = n * (-0.8 * vin.dot(n)) + (vin - n * vin.dot(n)) * 0.6
        XCTAssertEqual((r.path.direction * r.path.speed).distance(to: expect), 0, accuracy: 1e-9)
        let leave = Units.degrees(atan2(r.path.direction.x, r.path.direction.y))
        XCTAssertGreaterThan(leave, 12 + 6)
        // against the old rule at a rebound of 100% from the same ball, carried to the same end level
        let old = Bounce.compute(pose: pose, spec: spec, ball: BallSpec(diameter: 0.03, rebound: 1), down: down, ballCenter: B,
                                 defaultDropHeight: 1, rule: .cornerPlane, floorBelowCenter: 0.05)
        let new = Bounce.compute(pose: pose, spec: spec, ball: ball, down: down, ballCenter: B, defaultDropHeight: 1, rule: .impact,
                                 floorBelowCenter: 0.05)
        XCTAssertEqual(new.path.range / old.path.range, 1.07, accuracy: 0.05)
    }
    /// The setting (n12): the restitution, 0.8 by default, with the impact rule and the owner's tangential share; a
    /// rebound saved before stands for the restitution sqrt(rebound); recordings and diagnostics made before n12 (no
    /// restitution) decode to the rule and the rebound they ran, and a ball written before has no tangential share and
    /// writes none.
    func testTheRestitutionSettingAndOlderFiles() throws {
        let s = RecordingSettings()
        XCTAssertEqual(s.restitution, 0.8)
        XCTAssertEqual(s.tangential, BallSpec.ownerTangential)
        XCTAssertEqual(s.launchRule, .impact)
        XCTAssertEqual(s.trackerSettings.launchRule, .impact)
        XCTAssertEqual(s.ball.restitution, 0.8, accuracy: 1e-12)
        XCTAssertEqual(s.ball.tangentialFactor, BallSpec.ownerTangential)
        XCTAssertEqual(s.reboundPercent, 64, accuracy: 1e-9)
        XCTAssertEqual(s.ball, BallSpec.ownerBall)
        XCTAssertEqual(RecordingSettings.restitution(reboundPercent: 49), 0.7, accuracy: 1e-12)
        XCTAssertEqual(RecordingSettings.restitution(reboundPercent: 100), 1, accuracy: 1e-12)
        let back = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        // an n11 session.json: no restitution, a 70% rebound, the corner plane
        let old = #"{"sideUInches":7.094,"sideVInches":7.094,"thicknessInches":1,"dishInches":0.125,"ballDiameterMm":30,"dropHeightFeet":3,"reboundPercent":70,"dishBounce":false}"#
        let o = try JSONDecoder().decode(RecordingSettings.self, from: Data(old.utf8))
        XCTAssertNil(o.restitution)
        XCTAssertEqual(o.launchRule, .cornerPlane)
        XCTAssertEqual(o.ball, BallSpec(diameter: 0.03, rebound: 0.7))
        XCTAssertNil(o.ball.tangential)
        // an old tracker's ball: no tangential share, and none written back
        let ballJSON = #"{"diameter":0.035,"rebound":0.7}"#
        let b = try JSONDecoder().decode(BallSpec.self, from: Data(ballJSON.utf8))
        XCTAssertEqual(b, BallSpec())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(b), as: UTF8.self).contains("tangential"))
        // the impact rule round-trips in a tracker's settings
        let t = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(s.trackerSettings))
        XCTAssertEqual(t, s.trackerSettings)
        XCTAssertEqual(t.launchRule, .impact)
        XCTAssertEqual(t.ball.tangential, BallSpec.ownerTangential)
        // the old rules are untouched by the new fields: the same ball with a tangential share, on the corner plane
        let pose = levelPose(), spec = SlabSpec.standard
        let a = Bounce.compute(pose: pose, spec: spec, ball: BallSpec(), down: down, ballCenter: Vec3(0.03, 0.4, 0), defaultDropHeight: 1)
        let c = Bounce.compute(pose: pose, spec: spec, ball: BallSpec(diameter: 0.035, rebound: 0.7, tangential: 0.9), down: down,
                               ballCenter: Vec3(0.03, 0.4, 0), defaultDropHeight: 1)
        XCTAssertEqual(a.path, c.path)
    }
}
