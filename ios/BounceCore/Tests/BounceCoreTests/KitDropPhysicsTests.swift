import XCTest
@testable import BounceCore

/// The physical truth of rendered drops: the dish as a spherical cap, a falling ball's contact with it, and the bounce
/// about the dish's local normal (independent of the app's model).
final class KitDropPhysicsTests: XCTestCase {
    let spec18 = SlabSpec(sideU: Units.inches(18), sideV: Units.inches(18), thickness: Units.inches(1), dishDepth: Units.inches(0.125))

    /// 1/8 in deep over a 9 in half-width: a sphere of 324 in; its surface leans 1.06° 6 in out and 1.59° at the rim; the
    /// app's paraboloid (through the corners) leans half as much near the middle.
    func testTheDishIsASphericalCap() {
        let d = KitDish(spec: spec18)
        XCTAssertEqual(Units.toInches(d.sphereRadius), (81 + 0.015625) / 0.25, accuracy: 1e-9)
        XCTAssertEqual(Units.toInches(d.surface(u: 0, v: 0).depth), 0.125, accuracy: 1e-9)
        XCTAssertEqual(d.surface(u: Units.inches(9), v: 0).depth, 0, accuracy: 1e-9, "the rim meets the corner plane")
        XCTAssertEqual(d.surface(u: Units.inches(8), v: Units.inches(8)).depth, 0, "flat outside the rim")
        func tilt(_ n: Vec3) -> Double { Units.degrees(n.angle(to: Vec3(0, 0, 1))) }
        XCTAssertEqual(tilt(d.surface(u: Units.inches(6), v: 0).normal), Units.degrees(asin(6 / 324.0625)), accuracy: 1e-6)
        XCTAssertEqual(tilt(d.surface(u: 0, v: Units.inches(6)).normal), 1.061, accuracy: 0.001)
        XCTAssertEqual(tilt(d.surface(u: Units.inches(8.99), v: 0).normal), 1.59, accuracy: 0.01)
        // leaning toward the middle
        XCTAssertLessThan(d.surface(u: Units.inches(4), v: 0).normal.x, 0)
        XCTAssertGreaterThan(d.surface(u: 0, v: Units.inches(-4)).normal.y, 0)
        let p = KitDish(spec: spec18, shape: .paraboloid)
        XCTAssertEqual(tilt(p.surface(u: Units.inches(6), v: 0).normal), 0.53, accuracy: 0.01)
        // the paraboloid is the app's Dish.at
        let pose = SyntheticScene.slabPose(tilt: 0, heading: 0, yaw: 0, spec: spec18)
        let app = Dish.at(pose: pose, depth: spec18.dishDepth, u: 0.1, v: -0.05)
        XCTAssertEqual(p.surface(u: 0.1, v: -0.05).depth, app.depth, accuracy: 1e-12)
    }

    /// A ball's clearance from the dish: 0 when it rests anywhere in it, the gap above that, the rim's edge for a ball
    /// over the rim, the flat top outside it.
    func testContact() {
        let d = KitDish(spec: spec18), r = 0.0175
        for (u, v) in [(0.0, 0.0), (0.1, 0.05), (-0.15, 0.0), (0.0, 0.2)] {
            let s = d.surface(u: u, v: v)
            let resting = Vec3(u, v, -s.depth) + s.normal * r
            let c = d.contact(center: resting, radius: r)
            XCTAssertEqual(c.clearance, 0, accuracy: 1e-9, "(\(u), \(v))")
            XCTAssertLessThan(c.normal.angle(to: s.normal), 1e-9)
            XCTAssertEqual(d.contact(center: resting + s.normal * 0.01, radius: r).clearance, 0.01, accuracy: 1e-9)
        }
        // outside the rim: the flat top
        XCTAssertEqual(d.contact(center: Vec3(0.21, 0.21, 0.03), radius: r).clearance, 0.03 - r, accuracy: 1e-12)
        // over the rim: its edge
        let a = d.rimRadius
        let c = d.contact(center: Vec3(a - 0.0002, 0, 0.0195), radius: r)
        XCTAssertEqual(c.point.x, a, accuracy: 1e-9)
        XCTAssertEqual(c.clearance, (0.0002 * 0.0002 + 0.0195 * 0.0195).squareRoot() - r, accuracy: 1e-9)
    }

    /// Dropped straight onto a level slab's centre, the ball goes straight up and regains `rebound` of its drop height;
    /// the contact is where its centre is the sphere's radius minus its own from the sphere's centre.
    func testStraightBounceRegainsTheRebound() throws {
        let pose = SyntheticScene.slabPose(tilt: 0, heading: 0, yaw: 0, spec: spec18)
        let d = KitDish(spec: spec18), r = 0.0175
        let held = pose.center + Vec3(0, r - spec18.dishDepth + 0.3, 0)
        var p = KitDropPhysics.Params()
        p.rebound = 0.7
        let phys = KitDropPhysics(slab: pose, dish: d, held: held, release: 10, params: p)
        let c = try XCTUnwrap(phys.impact)
        XCTAssertEqual(c.surface, .slab)
        XCTAssertEqual(c.center.y, pose.center.y - spec18.dishDepth + r, accuracy: 1e-6)
        XCTAssertEqual(c.time - 10, (2 * 0.3 / Units.gravity).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(c.velocityOut.y * c.velocityOut.y / (2 * Units.gravity), 0.7 * 0.3, accuracy: 1e-5)
        XCTAssertEqual(Vec3(c.velocityOut.x, 0, c.velocityOut.z).length, 0, accuracy: 1e-9)
        // off-centre on a level slab: the vertical line meets the sphere of centres |P - C| = Rs - r
        let off = Vec3(Units.inches(6), 0, 0)
        let phys2 = KitDropPhysics(slab: pose, dish: d, held: held + off, release: 10, params: p)
        let c2 = try XCTUnwrap(phys2.impact)
        let C = pose.center + Vec3(0, d.sphereRadius - spec18.dishDepth, 0)
        XCTAssertEqual((c2.center - C).length, d.sphereRadius - r, accuracy: 1e-6)
        XCTAssertEqual(Units.degrees(c2.normal.angle(to: Vec3(0, 1, 0))), 1.06, accuracy: 0.01)
    }

    /// The bounce off the local normal: the normal component reversed and scaled by e = sqrt(rebound); along the
    /// surface 5/7 kept when the ball rolls off (no spin in), all of it without friction, and less than 5/7 when it
    /// slides (low friction); never more energy out than in.
    func testTheBounceAboutTheLocalNormal() {
        let n = Vec3(0.2, 1, -0.1).normalized, v = Vec3(0, -2.4, 0), e = 0.7.squareRoot(), r = 0.0175
        let vn = v.dot(n), vt = v - n * vn
        for (model, k) in [(KitTangentialModel.rolling(mu: 0.4), 5.0 / 7), (.smooth, 1.0), (.ratio(0.3), 0.3)] {
            let out = model.bounce(velocity: v, spin: .zero, normal: n, restitution: e, radius: r)
            XCTAssertEqual(out.velocity.dot(n), -e * vn, accuracy: 1e-12)
            let ot = out.velocity - n * out.velocity.dot(n)
            XCTAssertEqual((ot - vt * k).length, 0, accuracy: 1e-12, "\(model)")
            XCTAssertLessThanOrEqual(out.velocity.lengthSquared, v.lengthSquared)
        }
        // rolling off: the contact point does not slip, and the spin goes with it
        let roll = KitTangentialModel.rolling(mu: 0.4).bounce(velocity: v, spin: .zero, normal: n, restitution: e, radius: r)
        let slip = roll.velocity + roll.spin.cross(n * -r)
        XCTAssertEqual((slip - n * slip.dot(n)).length, 0, accuracy: 1e-9)
        // sliding: friction 0.01 cannot stop the slip
        let slide = KitTangentialModel.rolling(mu: 0.01).bounce(velocity: v, spin: .zero, normal: n, restitution: e, radius: r)
        let st = slide.velocity - n * slide.velocity.dot(n)
        XCTAssertEqual(st.length, vt.length - 0.01 * (1 + e) * -vn, accuracy: 1e-9)
    }

    /// On a tilted slab the physical bounce leans further downhill than the slab's normal (the app's launch): about
    /// 1.85 x the surface's tilt for a ball that rolls off at a rebound of 0.7.
    func testAPhysicalBounceGoesFurtherDownhillThanTheApp() throws {
        let pose = SyntheticScene.slabPose(tilt: 10, heading: 0, yaw: 0, spec: spec18)
        let d = KitDish(spec: spec18)
        let held = pose.center + Vec3(0, 0.35, 0)
        let phys = KitDropPhysics(slab: pose, dish: d, held: held, release: 0)
        let c = try XCTUnwrap(phys.impact)
        let lean = Units.degrees(c.velocityOut.angle(to: Vec3(0, 1, 0)))
        // tan(phi) = (5/7) tan(10°) / e, out at 10° + phi from vertical
        let phi = Units.degrees(atan(5.0 / 7 * tan(Units.radians(10)) / 0.7.squareRoot()))
        XCTAssertEqual(lean, 10 + phi, accuracy: 0.1)
        XCTAssertGreaterThan(c.velocityOut.x, 0, "downhill (+x)")
        // the ball flies on and comes down on the floor
        let floor = try XCTUnwrap(phys.contacts.dropFirst().first)
        XCTAssertEqual(floor.surface, .floor)
        XCTAssertEqual(floor.center.y, 0.0175, accuracy: 1e-6)
        let arc = try XCTUnwrap(phys.arcLanding(level: 0.0175))
        XCTAssertEqual(arc.time, floor.time, accuracy: 1e-6)
    }

    /// The rendered drops' truth: the impact where the drop aimed, the local normal's tilt, the true rebound, and the
    /// app's prediction from the true slab: with the true rebound it still misses (the model), by far more downhill.
    func testDropTruth() throws {
        let maker = KitSyntheticDrops()
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            let t = d.truth
            XCTAssertEqual(t.rebound, shot.rebound)
            let off = (t.offsetU * t.offsetU + t.offsetV * t.offsetV).squareRoot()
            XCTAssertEqual(Units.toInches(off), shot.offsetInches, accuracy: 0.4, shot.id)
            XCTAssertEqual(t.normalTilt, Units.degrees(asin(off / maker.dish.sphereRadius)), accuracy: 0.02, shot.id)
            XCTAssertEqual(t.dropHeight, Units.inches(shot.heightInches), accuracy: 0.004, shot.id)
            // e about the local normal is the rebound's square root
            let e = -t.velocityOut.dot(t.localNormal) / t.velocityIn.dot(t.localNormal)
            XCTAssertEqual(e * e, shot.rebound, accuracy: 1e-9, shot.id)
            let app = try XCTUnwrap(t.trueRebound, shot.id)
            if shot.tilt >= 5 { XCTAssertGreaterThan(app.rangeError, 0.02, "\(shot.id): the ball goes further than the app says") }
            XCTAssertEqual(t.landingLevel, 0.0175)
            XCTAssertGreaterThan(d.frames.count, 40, shot.id)
            XCTAssertTrue(zip(d.frames, d.frames.dropFirst()).allSatisfy { $0.time < $1.time }, shot.id)
        }
    }
}
