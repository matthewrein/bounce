import XCTest
@testable import BounceCore

/// The physical truth of rendered drops: the dish as a spherical cap, a falling ball's contact with it, and the bounce
/// about the dish's local normal (independent of the app's model).
final class KitDropPhysicsTests: XCTestCase {
    let spec = SlabSpec.standard

    /// The owner's top: 1/8 in deep over a 3.5 in half-width, a sphere of 49 in; its surface leans 1.17° 1 in out,
    /// 3.5° 3 in out and 4.1° at the rim; the app's paraboloid (through the corners) leans half as much near the middle.
    func testTheDishIsASphericalCap() {
        let d = KitDish(spec: spec)
        XCTAssertEqual(Units.toInches(d.sphereRadius), (12.25 + 0.015625) / 0.25, accuracy: 1e-9)
        XCTAssertEqual(Units.toInches(d.sphereRadius), 49.06, accuracy: 0.01)
        XCTAssertEqual(Units.toInches(d.surface(u: 0, v: 0).depth), 0.125, accuracy: 1e-9)
        XCTAssertEqual(d.surface(u: Units.inches(3.5), v: 0).depth, 0, accuracy: 1e-9, "the rim meets the corner plane")
        XCTAssertEqual(d.surface(u: Units.inches(3), v: Units.inches(3)).depth, 0, "flat outside the rim")
        func tilt(_ n: Vec3) -> Double { Units.degrees(n.angle(to: Vec3(0, 0, 1))) }
        XCTAssertEqual(tilt(d.surface(u: Units.inches(3), v: 0).normal), Units.degrees(asin(3 / 49.0625)), accuracy: 1e-6)
        XCTAssertEqual(tilt(d.surface(u: Units.inches(3), v: 0).normal), 3.506, accuracy: 0.001)
        XCTAssertEqual(tilt(d.surface(u: 0, v: Units.inches(1)).normal), 1.168, accuracy: 0.001)
        XCTAssertEqual(tilt(d.surface(u: Units.inches(3.49), v: 0).normal), 4.08, accuracy: 0.01)
        // leaning toward the middle
        XCTAssertLessThan(d.surface(u: Units.inches(2), v: 0).normal.x, 0)
        XCTAssertGreaterThan(d.surface(u: 0, v: Units.inches(-2)).normal.y, 0)
        let p = KitDish(spec: spec, shape: .paraboloid)
        XCTAssertEqual(tilt(p.surface(u: Units.inches(3), v: 0).normal), 1.75, accuracy: 0.01)
        // the paraboloid is the app's Dish.at
        let pose = SyntheticScene.slabPose(tilt: 0, heading: 0, yaw: 0, spec: spec)
        let app = Dish.at(pose: pose, depth: spec.dishDepth, u: 0.05, v: -0.03)
        XCTAssertEqual(p.surface(u: 0.05, v: -0.03).depth, app.depth, accuracy: 1e-12)
        XCTAssertEqual(p.surface(u: 0.05, v: -0.03).normal.angle(to: Vec3(0, 0, 1)), app.normal.angle(to: pose.normal), accuracy: 1e-9)
    }

    /// A ball's clearance from the dish: 0 when it rests anywhere in it, the gap above that, the rim's edge for a ball
    /// over the rim, the flat top outside it.
    func testContact() {
        let d = KitDish(spec: spec), r = 0.0175
        for (u, v) in [(0.0, 0.0), (0.03, 0.02), (-0.05, 0.0), (0.0, 0.07)] {
            let s = d.surface(u: u, v: v)
            let resting = Vec3(u, v, -s.depth) + s.normal * r
            let c = d.contact(center: resting, radius: r)
            XCTAssertEqual(c.clearance, 0, accuracy: 1e-9, "(\(u), \(v))")
            XCTAssertLessThan(c.normal.angle(to: s.normal), 1e-9)
            XCTAssertEqual(d.contact(center: resting + s.normal * 0.01, radius: r).clearance, 0.01, accuracy: 1e-9)
        }
        // outside the rim (toward a corner, still on the top): the flat top
        XCTAssertEqual(d.contact(center: Vec3(0.08, 0.08, 0.03), radius: r).clearance, 0.03 - r, accuracy: 1e-12)
        // over the rim: its edge
        let a = d.rimRadius
        let c = d.contact(center: Vec3(a - 0.0002, 0, 0.0195), radius: r)
        XCTAssertEqual(c.point.x, a, accuracy: 1e-9)
        XCTAssertEqual(c.clearance, (0.0002 * 0.0002 + 0.0195 * 0.0195).squareRoot() - r, accuracy: 1e-9)
    }

    /// Dropped straight onto a level slab's centre, the ball goes straight up and regains `rebound` of its drop height;
    /// the contact is where its centre is the sphere's radius minus its own from the sphere's centre.
    func testStraightBounceRegainsTheRebound() throws {
        let pose = SyntheticScene.slabPose(tilt: 0, heading: 0, yaw: 0, spec: spec)
        let d = KitDish(spec: spec), r = 0.0175
        let held = pose.center + Vec3(0, r - spec.dishDepth + 0.3, 0)
        var p = KitDropPhysics.Params()
        p.rebound = 0.7
        let phys = KitDropPhysics(slab: pose, dish: d, held: held, release: 10, params: p)
        let c = try XCTUnwrap(phys.impact)
        XCTAssertEqual(c.surface, .slab)
        XCTAssertEqual(c.center.y, pose.center.y - spec.dishDepth + r, accuracy: 1e-6)
        XCTAssertEqual(c.time - 10, (2 * 0.3 / Units.gravity).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(c.velocityOut.y * c.velocityOut.y / (2 * Units.gravity), 0.7 * 0.3, accuracy: 1e-5)
        XCTAssertEqual(Vec3(c.velocityOut.x, 0, c.velocityOut.z).length, 0, accuracy: 1e-9)
        // off-centre on a level slab: the vertical line meets the sphere of centres |P - C| = Rs - r, and the normal is
        // along it (3 in out on the 7 in top: 3.56°, a little more than the surface's 3.51° straight below the centre)
        let off = Vec3(Units.inches(3), 0, 0)
        let phys2 = KitDropPhysics(slab: pose, dish: d, held: held + off, release: 10, params: p)
        let c2 = try XCTUnwrap(phys2.impact)
        let C = pose.center + Vec3(0, d.sphereRadius - spec.dishDepth, 0)
        XCTAssertEqual((c2.center - C).length, d.sphereRadius - r, accuracy: 1e-6)
        XCTAssertEqual(Units.degrees(c2.normal.angle(to: Vec3(0, 1, 0))), Units.degrees(asin(off.x / (d.sphereRadius - r))), accuracy: 1e-4)
        XCTAssertEqual(Units.degrees(c2.normal.angle(to: Vec3(0, 1, 0))), 3.56, accuracy: 0.01)
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

    /// On a tilted slab the physical bounce leans further downhill than the slab's normal (the launch of the app's rule
    /// until n11): about 1.85 x the surface's tilt for a solid ball that rolls off at a rebound of 0.7. (Dropped over the centre of the 7 in
    /// top it touches the dish 3 mm uphill of the middle, where the surface leans 0.14° more than the slab.)
    func testAPhysicalBounceGoesFurtherDownhillThanTheApp() throws {
        let pose = SyntheticScene.slabPose(tilt: 10, heading: 0, yaw: 0, spec: spec)
        let d = KitDish(spec: spec)
        let held = pose.center + Vec3(0, 0.35, 0)
        let phys = KitDropPhysics(slab: pose, dish: d, held: held, release: 0)
        let c = try XCTUnwrap(phys.impact)
        let lean = Units.degrees(c.velocityOut.angle(to: Vec3(0, 1, 0)))
        // the surface's tilt t there; tan(phi) = (5/7) tan(t) / e, out at t + phi from vertical
        let t = Units.degrees(c.normal.angle(to: Vec3(0, 1, 0)))
        XCTAssertEqual(t, 10, accuracy: 0.2)
        let phi = Units.degrees(atan(5.0 / 7 * tan(Units.radians(t)) / 0.7.squareRoot()))
        XCTAssertEqual(lean, t + phi, accuracy: 0.01)
        XCTAssertGreaterThan(lean, 1.8 * 10)
        XCTAssertGreaterThan(c.velocityOut.x, 0, "downhill (+x)")
        // the ball flies on and comes down on the floor
        let floor = try XCTUnwrap(phys.contacts.dropFirst().first)
        XCTAssertEqual(floor.surface, .floor)
        XCTAssertEqual(floor.center.y, 0.0175, accuracy: 1e-6)
        let arc = try XCTUnwrap(phys.arcLanding(level: 0.0175))
        XCTAssertEqual(arc.time, floor.time, accuracy: 1e-6)
    }

    /// The rendered drops' truth, on the owner's 7 in slab by default: the impact where the drop aimed, on the top, the
    /// local normal's tilt, the true rebound, and the app's prediction from the true slab: with the true rebound it
    /// still misses (the model). The rendered ball rolls off, keeping 5/7 of its speed along the dish, and leaves at about
    /// lean + atan(5/7 tan(lean) / e) from vertical, lean the local normal's tilt; the app's impact rule leaves about the
    /// same local normal (the same contact, for a drop let go from rest) keeping its tangential share
    /// (`BallSpec.ownerTangential`, 0.4), at lean + atan(0.4 tan(lean) / e). So where the dish leans the ball goes
    /// further than the app says, down the local slope (on a level slab's middle the two would agree).
    func testDropTruth() throws {
        let maker = KitSyntheticDrops()
        XCTAssertEqual(maker.options.spec, SlabSpec.standard, "the owner's slab")
        var further = 0
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
            XCTAssertEqual(d.physics.impact?.surface, .slab, shot.id)
            XCTAssertLessThan(off, maker.dish.rimRadius, "\(shot.id): on the dish, inside its rim")
            let app = try XCTUnwrap(t.trueRebound, shot.id)
            let lean = Units.degrees(t.localNormal.angle(to: Vec3(0, 1, 0)))
            // (every drop of the set lands on a lean of 2° or more: on the slab's tilt, or off the dish's middle; 8 mm to
            // 16 cm further, the most on the steepest)
            if shot.releaseVelocity == .zero && shot.releaseSpin == .zero && lean > 2 {
                XCTAssertGreaterThan(app.rangeError, 0.005, "\(shot.id): the ball goes further than the app says"); further += 1
            }
            XCTAssertEqual(t.landingLevel, 0.0175)
            XCTAssertGreaterThan(d.frames.count, 40, shot.id)
            XCTAssertTrue(zip(d.frames, d.frames.dropFirst()).allSatisfy { $0.time < $1.time }, shot.id)
            // the set's balls touch the dish and the floor only (d11's contact is within a ball's radius of the edge, on
            // the dish): none of them clips the slab's edges or cut faces or the base on the way down
            XCTAssertFalse(d.physics.contacts.contains { $0.edge || $0.surface == .base }, "\(shot.id): \(d.physics.contacts.map { $0.surface })")
        }
        XCTAssertEqual(further, 11, "all but d09, which was pushed")
    }

    /// The set's truth worked out again from first principles, without `KitDish`, the physics' stepping or
    /// `KitDropAnalysis.compare` (which the analysis shares with the simulator, so an error in them would cancel in
    /// "measured minus true"): the dish is the sphere through the inscribed circle of the top and 1/8 in below its
    /// centre; the ball's centre meets the dish where it comes within the sphere's radius less its own of the sphere's
    /// centre (the free fall from the held ball, its release velocity included, solved by bisection); the contact point
    /// is on the line from the sphere's centre through the ball's, the normal along it; the bounce reverses e = sqrt
    /// (rebound) of the normal velocity and keeps 5/7 of the tangential one (a solid sphere that rolls off, with the
    /// friction to do so); the landing is where that arc comes down to the floor plus a radius. Against the app's
    /// prediction (its launch point and velocity, from `KitBouncePrediction.app`, the app's own model under test), the
    /// landing error and the range error are the horizontal distances, worked out here.
    func testDropTruthFromFirstPrinciples() throws {
        let maker = KitSyntheticDrops()
        let G = 9.80665, r = maker.options.ballDiameter / 2, up = Vec3(0, 1, 0)
        let a = Units.inches(3.5), D = Units.inches(0.125), Rs = (a * a + D * D) / (2 * D)
        func horizontal(_ v: Vec3) -> Double { (v.x * v.x + v.z * v.z).squareRoot() }
        func land(_ p: Vec3, _ v: Vec3, _ level: Double) -> Vec3 {
            let tau = (v.y + (v.y * v.y + 2 * G * (p.y - level)).squareRoot()) / G
            return p + v * tau - up * (0.5 * G * tau * tau)
        }
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot), t = d.truth, pose = d.slab, id = shot.id
            let C = pose.center + pose.normal * (Rs - D)
            let v0 = shot.releaseVelocity
            func centre(_ s: Double) -> Vec3 { t.held + v0 * s - up * (0.5 * G * s * s) }
            var lo = 0.0, hi = 2.0
            XCTAssertLessThan((centre(lo) - C).length, Rs - r, id)
            for _ in 0..<200 { let mid = (lo + hi) / 2; if (centre(mid) - C).length < Rs - r { lo = mid } else { hi = mid } }
            let P = centre(lo), n = (C - P).normalized, contact = C - n * Rs
            // on the cap, inside its rim (where the dish is the sphere)
            let q = contact - pose.center
            let rho = (pow(q.dot(pose.axisU), 2) + pow(q.dot(pose.axisV), 2)).squareRoot()
            XCTAssertLessThan(rho, a, id)
            XCTAssertEqual(t.impactTime - t.release, lo, accuracy: 1e-6, id)
            XCTAssertLessThan((t.impactCenter - P).length, 1e-5, id)
            XCTAssertLessThan((t.contactPoint - contact).length, 1e-5, id)
            XCTAssertLessThan(t.localNormal.angle(to: n), 1e-5, id)
            XCTAssertEqual(t.normalTilt, Units.degrees(n.angle(to: pose.normal)), accuracy: 1e-3, id)
            // the bounce
            let vin = v0 - up * (G * lo), vn = vin.dot(n), vt = vin - n * vn, e = shot.rebound.squareRoot()
            XCTAssertLessThan(vt.length * 2 / 7, 0.4 * (1 + e) * -vn, "\(id): friction enough to roll off")
            let vout = n * (-e * vn) + vt * (5.0 / 7)
            XCTAssertLessThan((t.velocityIn - vin).length, 1e-5, id)
            XCTAssertLessThan((t.velocityOut - vout).length, 1e-5, id)
            // the landing at the floor plus a radius, and the app's prediction against it
            let level = r
            XCTAssertEqual(t.landingLevel, level, accuracy: 1e-12, id)
            let L = land(P, vout, level)
            XCTAssertLessThan(horizontal(t.landing - L), 2e-5, id)
            for (rebound, cmp) in [(maker.settings.ball.rebound, t.app), (shot.rebound, t.trueRebound)] {
                var s = maker.settings
                s.ball.rebound = rebound
                let ap = KitBouncePrediction.app(pose: pose, settings: s, held: t.held)
                let AL = land(ap.start, ap.velocity, level)
                let c = try XCTUnwrap(cmp, id)
                XCTAssertEqual(c.landingError, horizontal(L - AL), accuracy: 2e-5, id)
                XCTAssertEqual(c.rangeError, horizontal(L - P) - horizontal(AL - ap.start), accuracy: 2e-5, id)
                XCTAssertLessThan(horizontal(c.landing - AL), 1e-9, id)
            }
        }
    }

    /// A ball whose centre comes down outside the slab's outline meets the slab's body, not the floor under it: within
    /// its radius of the top's edge it bounces off that edge (the normal from the edge to its centre); a little further
    /// out it falls past the cut face onto the edge of the base (5% wider than the slab, 2 mm under it, as rendered);
    /// further out still, onto the floor.
    func testTheSlabsEdgesAndTheBase() throws {
        let pose = SyntheticScene.slabPose(tilt: 0, heading: 0, yaw: 0, spec: spec)   // the top's centre 2.6 in over the floor
        let d = KitDish(spec: spec), r = 0.0175, hu = spec.halfU
        let topY = pose.center.y, baseTop = topY - spec.thickness - 0.002
        func drop(out x: Double) throws -> KitDropPhysics.Contact {
            let held = pose.center + Vec3(hu + x, 0.3, 0)
            return try XCTUnwrap(KitDropPhysics(slab: pose, dish: d, held: held, release: 0).impact)
        }
        for x in [0.005, 0.015] {
            let c = try drop(out: x)
            XCTAssertEqual(c.surface, .slab, "\(x)")
            XCTAssertTrue(c.edge, "\(x)")
            XCTAssertLessThan((c.point - (pose.center + Vec3(hu, 0, 0))).length, 1e-9, "\(x): the top's edge")
            XCTAssertEqual(c.center.y - topY, (r * r - x * x).squareRoot(), accuracy: 1e-6)
            XCTAssertLessThan(c.normal.angle(to: Vec3(x, (r * r - x * x).squareRoot(), 0)), 1e-4)
            XCTAssertGreaterThan(c.velocityOut.x, 0, "\(x): off the edge, outward")
        }
        // past the cut face (2 mm clear of it) onto the base's edge, 0.05 hu further out
        let b = try drop(out: r + 0.002)
        XCTAssertEqual(b.surface, .base)
        XCTAssertFalse(b.edge)
        let dx = hu + r + 0.002 - 1.05 * hu
        XCTAssertEqual(b.point.x, pose.center.x + 1.05 * hu, accuracy: 1e-9)
        XCTAssertEqual(b.point.y, baseTop, accuracy: 1e-9)
        XCTAssertEqual(b.center.y - baseTop, (r * r - dx * dx).squareRoot(), accuracy: 1e-6)
        // clear of the base: the floor
        let f = try drop(out: 0.05 * hu + r + 0.002)
        XCTAssertEqual(f.surface, .floor)
        XCTAssertEqual(f.center.y, r, accuracy: 1e-6)
        // without a base it falls past onto the floor
        var p = KitDropPhysics.Params()
        p.baseShare = nil
        let nb = try XCTUnwrap(KitDropPhysics(slab: pose, dish: d, held: pose.center + Vec3(hu + r + 0.002, 0.3, 0), release: 0, params: p).impact)
        XCTAssertEqual(nb.surface, .floor)
    }
}
