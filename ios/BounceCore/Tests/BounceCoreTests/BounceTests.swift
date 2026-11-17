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
}
