import XCTest
@testable import BounceCore

/// One full-resolution crop from Fixtures/balls: 300x720 luma around the slab and the space above it, cut from a
/// 720x1280 render.
struct BallCrop {
    let name: String
    let luma: Plane
    /// the crop's own intrinsics (the full frame's, shifted to the crop)
    let K: CameraIntrinsics
    let corners: [Vec2]
    let down: Vec3
    let spec: SlabSpec
    let ball: BallSpec
    /// true ball: projection of its centre (crop pixels), f tan(angular radius), drop height to the dish (m)
    let truthCenter: Vec2?
    let truthOnAxis: Double
    let truthDrop: Double
    let floorBall: Bool

    /// the true radius stretched for its angle off the axis, as RadiusModel.imageCircle reads a fitted circle
    var truthImageRadius: Double {
        guard let c = truthCenter else { return .nan }
        let cosT = 1 / K.ray(c).length
        return truthOnAxis * (1 / cosT + 1 / (cosT * cosT)) / 2
    }

    /// The slab's pose solved from the true corners (camera axes of this crop).
    var slab: SlabPose { PoseSolver.solve(corners: corners, intrinsics: K, spec: spec, down: down)!.pose }

    /// Where the locator looks, and the image's up there.
    var window: (region: ImageRect, radii: ClosedRange<Double>, up: Vec2) {
        let s = slab
        let w = BallLocator.searchWindow(intrinsics: K, slab: s, ball: ball, down: down, heights: 0.05...1.5)!
        return (w.region, w.radii, BallLocator.imageUp(at: w.region.center, depth: s.center.length, intrinsics: K, down: down))
    }

    /// The crop turned a quarter turn clockwise: pixel (i, j) moves to (H - 1 - j, i), a point (x, y) to (H - y, x), and
    /// camera axes (X, Y, Z) to (-Y, X, Z). (An ARKit frame from a phone held upright arrives turned like this.)
    func turnedClockwise() -> BallCrop {
        let W = luma.width, H = luma.height
        var p = Plane(width: H, height: W)
        for j in 0..<H { for i in 0..<W { p[H - 1 - j, i] = luma[i, j] } }
        let K2 = CameraIntrinsics(fx: K.fy, fy: K.fx, cx: Double(H) - K.cy, cy: K.cx, width: H, height: W)
        func pt(_ q: Vec2) -> Vec2 { Vec2(Double(H) - q.y, q.x) }
        return BallCrop(name: name, luma: p, K: K2, corners: corners.map(pt), down: Vec3(-down.y, down.x, down.z), spec: spec, ball: ball,
                        truthCenter: truthCenter.map(pt), truthOnAxis: truthOnAxis, truthDrop: truthDrop, floorBall: floorBall)
    }

    /// The same crop with other luma.
    func with(luma l: Plane) -> BallCrop {
        BallCrop(name: name, luma: l, K: K, corners: corners, down: down, spec: spec, ball: ball, truthCenter: truthCenter,
                 truthOnAxis: truthOnAxis, truthDrop: truthDrop, floorBall: floorBall)
    }

    static func all() throws -> [BallCrop] {
        let dir = Fixtures.root.appendingPathComponent("balls")
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("ball_crops.json"))) as! [[String: Any]]
        return try rows.map { r in
            let file = r["file"] as! String
            let luma = Plane(pgm: try Data(contentsOf: dir.appendingPathComponent(file)))!
            let o = r["cropOrigin"] as! [Double]
            let K = CameraIntrinsics(verticalFovDegrees: dbl(r["fovDeg"]), width: Int(dbl(r["fullWidth"])), height: Int(dbl(r["fullHeight"])))
                .cropped(x0: o[0], y0: o[1], scale: 1, width: luma.width, height: luma.height)
            let spec = SlabSpec(sideU: Units.inches(dbl(r["sideUInches"])), sideV: Units.inches(dbl(r["sideVInches"])),
                                thickness: Units.inches(dbl(r["thicknessInches"])), dishDepth: Units.inches(dbl(r["dishInches"])))
            let b = r["ball"] as? [String: Any]
            return BallCrop(name: String(file.dropFirst(5).dropLast(4)), luma: luma, K: K, corners: vec2s(r["corners"])!, down: vec3(r["down"])!,
                            spec: spec, ball: BallSpec(diameter: dbl(r["ballDiameterMm"]) / 1000),
                            truthCenter: b.map { Vec2(dbl($0["x"]), dbl($0["y"])) }, truthOnAxis: b.map { dbl($0["rOnAxis"]) } ?? .nan,
                            truthDrop: b.map { dbl($0["dropMetres"]) } ?? .nan, floorBall: (r["floorBall"] as? Bool) ?? false)
        }
    }
}

/// Ways to spoil a picture a little, as a phone's sensor and light would.
enum Perturbation: CustomStringConvertible {
    case noise(sigma: Double, seed: UInt64)
    case gain(Float)
    case blur

    func apply(_ p: Plane) -> Plane {
        var q = p
        switch self {
        case let .noise(sigma, seed):
            var rng = SeededRandom(seed)
            for i in 0..<q.data.count { q.data[i] += Float(rng.gaussian() * sigma) }
        case let .gain(g):
            for i in 0..<q.data.count { q.data[i] *= g }
        case .blur:
            // [1 2 1] / 4 across and down (a Gaussian of about 0.7 px)
            let W = p.width, H = p.height
            var t = p
            for y in 0..<H { for x in 1..<(W - 1) { t[x, y] = (p[x - 1, y] + 2 * p[x, y] + p[x + 1, y]) / 4 } }
            for y in 1..<(H - 1) { for x in 0..<W { q[x, y] = (t[x, y - 1] + 2 * t[x, y] + t[x, y + 1]) / 4 } }
        }
        return q
    }

    var description: String {
        switch self {
        case let .noise(sigma, seed): return String(format: "noise %.0f/%d", sigma, seed)
        case let .gain(g): return String(format: "gain %.1f", g)
        case .blur: return "blur"
        }
    }

    /// The set the perturbed-fixture tests use (chosen before the tests were first run).
    static let standardSet: [Perturbation] = [.noise(sigma: 2, seed: 1), .noise(sigma: 2, seed: 2), .noise(sigma: 2, seed: 3),
                                              .noise(sigma: 4, seed: 1), .noise(sigma: 4, seed: 2), .noise(sigma: 4, seed: 3),
                                              .gain(0.6), .gain(0.4), .blur]
}

/// A sphere rendered through a pinhole camera (3x3 samples per pixel) over a textured background.
struct SphereScene {
    var K: CameraIntrinsics
    var center: Vec3
    var radius: Double
    /// luma of the surface at a unit normal (camera axes); nil shows the background through it (an outline that blends in)
    var surface: (Vec3) -> Float?
    var background: (Double, Double) -> Float = { x, y in 118 + 6 * Float(sin(x * 0.7) * sin(y * 0.45)) }

    func render(noise sigma: Double = 0, seed: UInt64 = 1) -> Plane {
        var img = Plane(width: K.width, height: K.height)
        var rng = SeededRandom(seed)
        let rr = Bounce.imageRadius(ballCenter: center, intrinsics: K, ball: BallSpec(diameter: 2 * radius))! * 1.6 + 3
        let pc = K.project(center)!
        for y in 0..<K.height {
            for x in 0..<K.width {
                var v: Float
                if abs(Double(x) + 0.5 - pc.x) > rr || abs(Double(y) + 0.5 - pc.y) > rr {
                    v = background(Double(x) + 0.5, Double(y) + 0.5)
                } else {
                    v = 0
                    for sy in 0..<3 {
                        for sx in 0..<3 {
                            let px = Double(x) + (Double(sx) + 0.5) / 3, py = Double(y) + (Double(sy) + 0.5) / 3
                            let d = K.ray(Vec2(px, py)).normalized, b = d.dot(center)
                            let disc = b * b - center.lengthSquared + radius * radius
                            var s: Float? = nil
                            if disc >= 0 { s = surface((d * (b - disc.squareRoot()) - center) / radius) }
                            v += s ?? background(px, py)
                        }
                    }
                    v /= 9
                }
                if sigma > 0 { v += Float(rng.gaussian() * sigma) }
                img[x, y] = v
            }
        }
        return img
    }

    /// A polished ball (whole outline) painted over a picture: only the pixels near it are rendered (3x3 samples each);
    /// where a sample misses the ball it takes the picture's own pixel.
    static func paint(ballAt center: Vec3, radius: Double, up: Vec3, K: CameraIntrinsics, over base: Plane) -> Plane {
        var img = base
        let surface = mirrorSurface(up: up, lowerVisible: true)
        guard let pc = K.project(center), let r = Bounce.imageRadius(ballCenter: center, intrinsics: K, ball: BallSpec(diameter: 2 * radius)) else { return img }
        let reach = r * 1.6 + 3
        for y in max(0, Int(pc.y - reach))..<min(K.height, Int(pc.y + reach) + 1) {
            for x in max(0, Int(pc.x - reach))..<min(K.width, Int(pc.x + reach) + 1) {
                var v: Float = 0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 3, Double(y) + (Double(sy) + 0.5) / 3)).normalized, b = d.dot(center)
                        let disc = b * b - center.lengthSquared + radius * radius
                        v += disc >= 0 ? (surface((d * (b - disc.squareRoot()) - center) / radius) ?? base[x, y]) : base[x, y]
                    }
                }
                img[x, y] = v / 9
            }
        }
        return img
    }

    /// A polished ball as seen from above: the upper half reflects the room (a bright window and light-and-dark bands),
    /// the lower half the floor; `lowerVisible: false` makes the lower half the background's own luma.
    static func mirrorSurface(up: Vec3, lowerVisible: Bool) -> (Vec3) -> Float? {
        let light = (up + Vec3(0.3, 0, -0.4)).normalized
        return { n in
            let h = n.dot(up)
            if h < 0 { return lowerVisible ? 78 + 10 * Float(h) : nil }
            if n.dot(light) > 0.96 { return 250 }
            return 185 + 40 * Float(sin(9 * n.x) * cos(5 * n.z))
        }
    }
}

/// The floor seen through a pinhole camera (2x2 samples per pixel): a pattern on the floor, the slab drawn as a 6 cm box
/// on it (a 1 in slab on its base), and optionally a flat round print anywhere.
struct FloorScene {
    var K: CameraIntrinsics
    var slab: SlabPose
    /// floor luma at (u, w): metres across the line of sight and along it, from the point under the slab's centre
    var pattern: (Double, Double) -> Float
    /// a flat round print: its centre, unit normal, two unit axes in its plane, radius and luma
    var print: (center: Vec3, normal: Vec3, e1: Vec3, e2: Vec3, radius: Double, luma: Float)? = nil

    var floorPoint: Vec3 { slab.center - slab.normal * 0.06 }
    var along: Vec3 { slab.center.rejecting(slab.normal).normalized }
    var side: Vec3 { slab.normal.cross(along).normalized }

    /// how far along the ray `d` (from the camera) it enters the slab's box, if it does
    func slabHit(_ d: Vec3) -> (t: Double, top: Bool)? {
        let oc = Vec3.zero - slab.center
        var t0 = -Double.infinity, t1 = Double.infinity, top = false
        for (k, (o, dd, lo, hi)) in [(oc.dot(slab.axisU), d.dot(slab.axisU), -slab.halfU, slab.halfU),
                                     (oc.dot(slab.axisV), d.dot(slab.axisV), -slab.halfV, slab.halfV),
                                     (oc.dot(slab.normal), d.dot(slab.normal), -0.06, 0.0)].enumerated() {
            if abs(dd) < 1e-12 { if o < lo || o > hi { return nil }; continue }
            var a = (lo - o) / dd, b = (hi - o) / dd
            if a > b { swap(&a, &b) }
            if a > t0 { t0 = a; top = k == 2 }
            t1 = min(t1, b)
        }
        return t0 <= t1 && t0 > 0 ? (t0, top) : nil
    }

    /// whether a point is hidden from the camera by the slab
    func hiddenBySlab(_ q: Vec3) -> Bool { slabHit(q.normalized).map { $0.t < q.length - 1e-6 } ?? false }

    func render(noise sigma: Double, seed: UInt64) -> Plane {
        var img = Plane(width: K.width, height: K.height)
        var rng = SeededRandom(seed)
        let n = slab.normal, f0 = floorPoint, al = along, sd = side
        for y in 0..<K.height {
            for x in 0..<K.width {
                var acc: Float = 0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 2, Double(y) + (Double(sy) + 0.5) / 2))
                        var best = Double.infinity, value: Float = 150
                        if let h = slabHit(d) { best = h.t; value = h.top ? 140 + 8 * Float(sin(Double(x) * 0.9) * sin(Double(y) * 0.7)) : 50 }
                        let dn = d.dot(n)
                        if dn < 0 {
                            let t = f0.dot(n) / dn
                            if t > 0, t < best { best = t; let q = d * t - f0; value = pattern(q.dot(sd), q.dot(al)) }
                        }
                        if let pr = print {
                            let dm = d.dot(pr.normal)
                            if abs(dm) > 1e-9 {
                                let t = pr.center.dot(pr.normal) / dm
                                if t > 0, t <= best + 1e-9 {
                                    let q = d * t - pr.center, a = q.dot(pr.e1), b = q.dot(pr.e2)
                                    if a * a + b * b < pr.radius * pr.radius { value = pr.luma }
                                }
                            }
                        }
                        acc += value
                    }
                }
                img[x, y] = acc / 4 + Float(rng.gaussian() * sigma)
            }
        }
        return img
    }
}

final class BallFinderTests: XCTestCase {
    // MARK: fixtures

    /// The held ball is found in every crop that has one, at the true centre (2 px) and size (15% of the true radius
    /// stretched for its angle off the axis), searching where the locator would.
    func testHeldBallFoundInEveryCrop() throws {
        var lines: [String] = []
        for c in try BallCrop.all() where c.truthCenter != nil {
            let w = c.window, t = c.truthCenter!, rt = c.truthImageRadius
            let found = BallFinder.find(luma: c.luma, radiusRange: w.radii, roi: w.region, intrinsics: c.K, up: w.up)
            guard let i = found.indices.min(by: { found[$0].center.distance(to: t) < found[$1].center.distance(to: t) }) else {
                XCTFail("\(c.name): nothing found"); continue
            }
            let b = found[i], dc = b.center.distance(to: t), dr = (b.radius - rt) / rt
            lines.append(String(format: "%-26@ centre off %.2f px, radius %.2f vs %.2f (%+.1f%%), %d spokes%@, rank %d of %d",
                                c.name as NSString, dc, b.radius, rt, 100 * dr, b.support, b.partial ? " partial" : "", i + 1, found.count))
            XCTAssertLessThan(dc, 2, c.name)
            XCTAssertLessThan(abs(dr), 0.15, c.name)
        }
        print("held ball, finder:\n  " + lines.joined(separator: "\n  "))
        XCTAssertEqual(lines.count, 7)
    }

    /// The locator, fed each crop twice in a row with the slab pose solved from the true corners, reports the ball and
    /// its drop height to within 2.5 cm. (ball_held_offcenter_d4_60 was at -2.7 cm, the circle pulled in by edges just
    /// inside the blended top, until the finder read the lower half of the outline on its own; see
    /// BallFinder.outermost.)
    func testLocatorDropHeight() throws {
        var lines: [String] = [], errs: [Double] = []
        for c in try BallCrop.all() where c.truthCenter != nil {
            let loc = BallLocator(), slab = c.slab
            let first = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
            guard let o = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down) else {
                XCTFail("\(c.name): no ball"); continue
            }
            let e = o.drop.dropHeight - c.truthDrop
            errs.append(abs(e))
            lines.append(String(format: "%-26@ drop %.3f m vs %.3f (%+.1f cm), centre off %.2f px, %@, first scan %@",
                                c.name as NSString, o.drop.dropHeight, c.truthDrop, 100 * e, o.circle.center.distance(to: c.truthCenter!),
                                o.circle.partial ? "partial" : "full", first == nil ? "nothing (needs a second)" : "reported"))
            XCTAssertLessThan(abs(e), 0.025, c.name)
            XCTAssertLessThan(o.circle.center.distance(to: c.truthCenter!), 2, c.name)
            XCTAssertTrue(o.drop.onSlab)
            XCTAssertEqual(o.missedUpdates, 0)
            // a partial find is never reported on the first scan
            if let f = first { XCTAssertFalse(f.circle.partial, c.name) }
        }
        errs.sort()
        print("held ball, locator:\n  " + lines.joined(separator: "\n  ")
              + String(format: "\n  drop error median %.1f cm, worst %.1f cm", 100 * errs[errs.count / 2], 100 * errs.last!))
        XCTAssertEqual(errs.count, 7)
    }

    /// No ball over the slab where there is none: the bare scene, a ball lying on the floor beside the slab, printed
    /// circles and a tin on the floor mat.
    func testNoBallReportedOverSlab() throws {
        let crops = try BallCrop.all().filter { $0.truthCenter == nil }
        XCTAssertEqual(Set(crops.map(\.name)), ["d4_t10_h90_mat_60", "distract_floorball_60", "distract_mat_circles_60"])
        for c in crops {
            let loc = BallLocator(), slab = c.slab
            for k in 0..<3 {
                let o = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                XCTAssertNil(o, "\(c.name) scan \(k): \(o.map { "\($0.circle)" } ?? "")")
            }
        }
    }

    /// A ball on the floor that the finder does find is rejected because its straight drop does not land on the slab.
    /// (This crop has two floor balls: the far one, about 2.4 half-sides off the slab, is found; the one just beside
    /// the slab's corner is not found at all, so it does not test the drop rule; testFloorBallBesideOrBehindTheSlab does.)
    func testFloorBallIsFoundButDoesNotLandOnTheSlab() throws {
        let c = try BallCrop.all().first { $0.floorBall }!
        let w = c.window, slab = c.slab
        let found = BallFinder.find(luma: c.luma, radiusRange: w.radii, roi: w.region, intrinsics: c.K, up: w.up).filter { !$0.partial }
        XCTAssertFalse(found.isEmpty)
        var lines: [String] = []
        for b in found {
            let B = Bounce.ballCenter(pixel: b.center, radiusPixels: b.radius, intrinsics: c.K, ball: c.ball)!
            let d = Bounce.drop(ballCenter: B, pose: slab, spec: c.spec, ball: c.ball, down: c.down)
            lines.append("\(b) -> " + (d.map { String(format: "lands at (u, v) = (%.2f, %.2f) m, slab half-side %.3f m", $0.u, $0.v, slab.halfU) } ?? "not above the slab"))
            XCTAssertFalse(d?.onSlab ?? false)
        }
        print("floor balls:\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: synthetic spheres

    /// A ball well away from the axis: 29 degrees off it a sphere's outline is an ellipse stretched by 15% along the
    /// line from the image centre. With the intrinsics, the finder measures it in a camera turned to look straight at
    /// it, where it is a circle, and the ball's position comes back to within a few millimetres.
    func testOffAxisSphereComesBackWhereItIs() {
        // A level camera. (Seen from well above, the lower hemisphere is only a crescent along the bottom of the
        // outline; if that crescent matches the background exactly, the bright gibbous rest is fitted better by an
        // inscribed circle touching the crescent's edge than by the true outline - an ambiguity the web app's finder
        // shares; it does not occur on the rendered fixtures.)
        let K = CameraIntrinsics(fx: 420, fy: 420, cx: 320, cy: 240, width: 640, height: 480)
        let up = Vec3(0, -1, 0)
        let dir = Vec3(tan(Units.radians(24)), -tan(Units.radians(17)), 1).normalized // about 29 degrees off the axis
        for lower in [true, false] {
            let truth = dir * 0.42
            let scene = SphereScene(K: K, center: truth, radius: 0.0175, surface: SphereScene.mirrorSurface(up: up, lowerVisible: lower))
            let img = scene.render(noise: 1.5)
            let rTrue = Bounce.imageRadius(ballCenter: truth, intrinsics: K, ball: BallSpec())!
            var errs: [String: Double] = [:]
            for (name, k) in [("intrinsics", Optional(K)), ("plain", nil)] {
                let found = BallFinder.find(luma: img, radiusRange: (rTrue * 0.6)...(rTrue * 1.6), intrinsics: k,
                                            up: BallLocator.imageUp(at: K.project(truth)!, depth: 0.42, intrinsics: K, down: -up))
                guard let b = found.first else { XCTFail("\(name), lower visible \(lower): nothing found"); continue }
                // Read with the intrinsics the outline is a circle, whole or (lower half blending in) upper half only. As a
                // plain image circle it is an ellipse 15% longer than wide, which is not one circle: which part of it the
                // finder then rests on is not asked of the plain reading.
                if k != nil { XCTAssertEqual(b.partial, !lower, name) }
                let B = Bounce.ballCenter(pixel: b.center, radiusPixels: b.radius, intrinsics: K, ball: BallSpec())!
                errs[name] = B.distance(to: truth)
            }
            print(String(format: "sphere 29 deg off the axis, %@: centre error %.1f mm with intrinsics, %.1f mm as a plain circle",
                         lower ? "whole outline" : "upper outline only", 1000 * (errs["intrinsics"] ?? .nan), 1000 * (errs["plain"] ?? .nan)))
            if lower {
                // the whole outline: an ellipse 15% longer than wide; fitted as a circle in the image it puts the ball
                // a couple of per cent off, measured in a camera turned to it the ball comes back within a few mm
                XCTAssertLessThan(errs["intrinsics"] ?? 1, 0.42 * 0.01)
                XCTAssertLessThan(errs["intrinsics"] ?? 1, errs["plain"] ?? 0)
            } else {
                // half an outline: noisier (radius and centre trade off along the missing half)
                XCTAssertLessThan(errs["intrinsics"] ?? 1, 0.42 * 0.025)
            }
        }
    }

    /// The upper outline alone (the web app's partial find) needs two scans in a row, and those are matched relative
    /// to the slab: here the phone moves between them, so the ball moves 20 px in the image, yet the second scan reports
    /// it. A plain disc of the same size, with no mirror-like inside, is never reported.
    func testPartialBallNeedsTwoScansAndFollowsTheSlab() {
        // a level camera, so the ball's lower half fills the lower half of its outline (see the note on the gibbous
        // shape in testOffAxisSphereComesBackWhereItIs)
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let g = Vec3(0, 1, 0), up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let B1 = K.ray(Vec2(205, 170)).normalized * 0.5
        // a level slab 0.45 m below the ball
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        let slab1 = SlabPose(center: B1 - n * (0.45 + ball.radius), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
        // the phone turns 2 degrees and moves 1 cm between the scans
        let move = RigidTransform(rotation: Mat3.rotation(Vec3(0.2, 1, 0.1).normalized * Units.radians(2)), translation: Vec3(0.01, 0.002, 0))
        let B2 = move.apply(B1), slab2 = slab1.transformed(by: move), g2 = move.applyDirection(g)
        let img1 = SphereScene(K: K, center: B1, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: false)).render(noise: 1)
        let img2 = SphereScene(K: K, center: B2, radius: ball.radius, surface: SphereScene.mirrorSurface(up: move.applyDirection(up), lowerVisible: false)).render(noise: 1, seed: 2)
        let shift = K.project(B1)!.distance(to: K.project(B2)!), r = Bounce.imageRadius(ballCenter: B1, intrinsics: K, ball: ball)!
        XCTAssertGreaterThan(shift, r * 0.5) // compared in the image, the two finds would not count as the same ball

        let loc = BallLocator()
        XCTAssertNil(loc.update(luma: img1, intrinsics: K, slab: slab1, spec: spec, ball: ball, down: g))
        let o = loc.update(luma: img2, intrinsics: K, slab: slab2, spec: spec, ball: ball, down: g2)
        XCTAssertNotNil(o)
        if let o {
            XCTAssertTrue(o.circle.partial)
            XCTAssertLessThan(o.center.distance(to: B2), 0.02)
            XCTAssertEqual(o.drop.dropHeight, 0.45, accuracy: 0.03)
        }
        // the same scene with a plain grey disc: a round outline, but no highlight or detail inside
        let disc = SphereScene(K: K, center: B1, radius: ball.radius, surface: { n in n.dot(up) >= 0 ? 60 : nil }).render(noise: 1)
        let loc2 = BallLocator()
        for _ in 0..<3 { XCTAssertNil(loc2.update(luma: disc, intrinsics: K, slab: slab1, spec: spec, ball: ball, down: g)) }
    }

    /// A ball whose whole outline shows is reported on the first scan, followed in a box around it, held over for a
    /// couple of missed scans and then dropped.
    func testFollowHoldAndLose() {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let g = Vec3(0, 0.75, 0.66).normalized, up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let B = K.ray(Vec2(190, 180)).normalized * 0.5
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        let slab = SlabPose(center: B - n * (0.4 + ball.radius), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
        let img = SphereScene(K: K, center: B, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: true)).render(noise: 1)
        let empty = SphereScene(K: K, center: B, radius: ball.radius, surface: { _ in nil }).render(noise: 1)
        let loc = BallLocator()
        let o1 = loc.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
        XCTAssertNotNil(o1)
        XCTAssertEqual(o1?.circle.partial, false)
        XCTAssertLessThan(o1?.center.distance(to: B) ?? 1, 0.010)
        XCTAssertEqual(o1?.drop.dropHeight ?? 0, 0.4, accuracy: 0.015)
        XCTAssertNotNil(loc.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g))
        // gone: held over for maxMissedUpdates scans, then dropped
        for k in 1...loc.options.maxMissedUpdates {
            let o = loc.update(luma: empty, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
            XCTAssertEqual(o?.missedUpdates, k)
        }
        XCTAssertNil(loc.update(luma: empty, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g))
        XCTAssertNil(loc.current)
        // back again
        XCTAssertNotNil(loc.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g))
        loc.reset()
        XCTAssertNil(loc.current)
    }

    /// A followed ball that moved further than the follow box (4 radii) between two scans, a hand moving quickly or a
    /// ball let go, is found on the same scan in the whole search window, not held over where it was.
    func testFollowedBallThatJumpsIsFoundAtOnce() {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let g = Vec3(0, 0.75, 0.66).normalized, up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let B1 = K.ray(Vec2(190, 150)).normalized * 0.5
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        let slab = SlabPose(center: B1 - n * (0.4 + ball.radius), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
        let B2 = B1 - n * 0.2
        let img1 = SphereScene(K: K, center: B1, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: true)).render(noise: 1)
        let img2 = SphereScene(K: K, center: B2, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: true)).render(noise: 1, seed: 2)
        let r = Bounce.imageRadius(ballCenter: B1, intrinsics: K, ball: ball)!
        XCTAssertGreaterThan(K.project(B1)!.distance(to: K.project(B2)!), 4 * r * 1.2, "beyond the follow box")
        let loc = BallLocator()
        XCTAssertNotNil(loc.update(luma: img1, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g))
        let o = loc.update(luma: img2, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
        XCTAssertEqual(o?.missedUpdates, 0, "found, not held over")
        XCTAssertLessThan(o?.center.distance(to: B2) ?? 1, 0.01)
        XCTAssertEqual(o?.drop.dropHeight ?? 0, 0.2, accuracy: 0.015)
    }

    /// A large image (the ball some 60 px across) is searched at a reduced scale, and the ball still comes back in the
    /// image's own pixels.
    func testLargeBallSearchedAtReducedScale() {
        let K = CameraIntrinsics(fx: 1450, fy: 1450, cx: 720, cy: 960, width: 1440, height: 1920)
        let g = Vec3(0, 0.7, 0.71).normalized, up = -g
        let ball = BallSpec(), spec = SlabSpec.standard
        let B = K.ray(Vec2(760, 700)).normalized * 0.42
        let n = up, u = Vec3(1, 0, 0).rejecting(n).normalized
        let slab = SlabPose(center: B - n * (0.25 + ball.radius), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
        let window = BallLocator.searchWindow(intrinsics: K, slab: slab, ball: ball, down: g, heights: 0.05...1.5)!
        XCTAssertGreaterThan(window.radii.lowerBound, 24) // so the search runs at half size or less
        let img = SphereScene(K: K, center: B, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: true)).render(noise: 1)
        let o = BallLocator().update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
        XCTAssertNotNil(o)
        if let o {
            XCTAssertLessThan(o.circle.center.distance(to: K.project(B)!), 1.5)
            XCTAssertEqual(o.circle.radius, Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball)!, accuracy: 2)
            XCTAssertEqual(o.drop.dropHeight, 0.25, accuracy: 0.02)
        }
    }

    // MARK: pieces

    func testImageRadiusInvertsBallCenter() {
        let K = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        for B in [Vec3(0, 0, 1), Vec3(0.35, -0.3, 1.1), Vec3(-0.5, 0.4, 0.6)] {
            for model in [Bounce.RadiusModel.imageCircle, .onAxis] {
                let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: BallSpec(), model: model)!
                let back = Bounce.ballCenter(pixel: K.project(B)!, radiusPixels: r, intrinsics: K, ball: BallSpec(), model: model)!
                XCTAssertEqual(back.distance(to: B), 0, accuracy: 1e-9)
            }
        }
        XCTAssertNil(Bounce.imageRadius(ballCenter: Vec3(0, 0, -1), intrinsics: K, ball: BallSpec()))
    }

    func testLocalFrameRoundTripAndSphereIsACircle() {
        let K = CameraIntrinsics(fx: 800, fy: 800, cx: 400, cy: 300, width: 800, height: 600)
        let p = Vec2(690, 80)
        let F = LocalFrame(at: p, intrinsics: K, up: Vec2(0, -1))
        XCTAssertEqual(F.image(0, 0).distance(to: p), 0, accuracy: 1e-9)
        // a sphere centred on the frame's axis: its outline is a circle of radius f tan(a) in the frame
        let B = K.ray(p).normalized * 0.5, R = 0.0175, a = asin(R / 0.5)
        for k in 0..<12 {
            let th = Double(k) * .pi / 6, s = K.focal * tan(a)
            let q = F.image(s * cos(th), s * sin(th))
            // the ray through q grazes the sphere
            let d = K.ray(q).normalized
            XCTAssertEqual((B - d * d.dot(B)).length, R, accuracy: 1e-9)
        }
        XCTAssertLessThan(F.up.y, -0.9)
    }

    /// A ball remembered relative to the slab stays put when the next pose names the slab's sides differently.
    func testCarryAcrossRelabelledSlabAxes() {
        let n = Vec3(0, -0.6, -0.8), u = Vec3(1, 0, 0), v = n.cross(u)
        let old = SlabPose(center: Vec3(0, 0.3, 1.2), normal: n, axisU: u, axisV: v, halfU: 0.09, halfV: 0.09)
        let B = old.center + n * 0.5 + u * 0.03 - v * 0.02
        let r = B - old.center, local = Vec3(r.dot(u), r.dot(v), r.dot(n))
        // same slab, sides named a quarter turn round, seen after the camera moved a little
        let move = RigidTransform(rotation: Mat3.rotation(Vec3(0, 1, 0) * 0.02), translation: Vec3(0.01, 0, 0))
        var new = old.transformed(by: move)
        (new.axisU, new.axisV) = (new.axisV, -new.axisU)
        XCTAssertEqual(BallLocator.carry(local, from: old, to: new).distance(to: move.apply(B)), 0, accuracy: 1e-9)
    }

    // MARK: the fixtures turned, spoiled; balls on the floor; pitched cameras (limits set before these were first run)

    /// The held-ball tests on the crops turned a quarter turn either way, as the phone's camera delivers its frames:
    /// the same limits as upright (centre 2 px, radius 15%, drop height 2.5 cm). (Failed when added: offcenter turned
    /// 270, satin turned 270 and dim turned 90 were 2.7-3.3 cm off.)
    func testHeldBallOnTurnedCrops() throws {
        var lines: [String] = []
        for c0 in try BallCrop.all() where c0.truthCenter != nil {
            let cw = c0.turnedClockwise()
            for (turn, c) in [("90", cw), ("270", cw.turnedClockwise().turnedClockwise())] {
                let w = c.window, t = c.truthCenter!, rt = c.truthImageRadius
                let found = BallFinder.find(luma: c.luma, radiusRange: w.radii, roi: w.region, intrinsics: c.K, up: w.up)
                let b = found.min { $0.center.distance(to: t) < $1.center.distance(to: t) }
                let loc = BallLocator(), slab = c.slab
                loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                let o = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                let label = "\(c.name) turned \(turn)"
                lines.append(String(format: "%-36@ up (%+.2f, %+.2f): centre off %@, radius %@, drop %@", label as NSString, w.up.x, w.up.y,
                                    b.map { String(format: "%.2f px", $0.center.distance(to: t)) } ?? "-",
                                    b.map { String(format: "%+.1f%%%@", 100 * ($0.radius / rt - 1), $0.partial ? " partial" : "") } ?? "-",
                                    o.map { String(format: "%+.1f cm", 100 * ($0.drop.dropHeight - c.truthDrop)) } ?? "none"))
                guard let b, let o else { XCTFail("\(label): not found"); continue }
                XCTAssertLessThan(b.center.distance(to: t), 2, label)
                XCTAssertLessThan(abs(b.radius / rt - 1), 0.15, label)
                XCTAssertLessThan(abs(o.drop.dropHeight - c.truthDrop), 0.025, label)
            }
        }
        print("turned crops:\n  " + lines.joined(separator: "\n  "))
    }

    /// The crops with noise (2 and 4 grey levels, three seeds each), darker (x0.6, x0.4) and blurred: the held ball is
    /// missed in at most 6 of the 63 runs, never reported more than 4 cm off in drop height, the median error is at most
    /// 1.5 cm; and no ball is ever reported over the slab in the crops without one. (Failed when added: with noise, a
    /// printed circle on the mat in distract_mat_circles was reported as a partial find on two scans in a row, its
    /// circle made up of the print's top, the mat's straight edge and crossings of the noise; partial readings now
    /// count only edges that run across the spokes.)
    func testPerturbedCrops() throws {
        let crops = try BallCrop.all()
        var errs: [Double] = [], missed: [String] = [], falses: [String] = []
        var table: [String] = []
        for c0 in crops {
            var row: [String] = []
            for pert in Perturbation.standardSet {
                let c = c0.with(luma: pert.apply(c0.luma)), slab = c.slab
                let loc = BallLocator()
                if c.truthCenter == nil {
                    for k in 0..<3 {
                        if let o = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down) {
                            falses.append("\(c.name) \(pert) scan \(k): \(o.circle)")
                        }
                    }
                    continue
                }
                loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                if let o = loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down) {
                    let e = o.drop.dropHeight - c.truthDrop
                    errs.append(abs(e)); row.append(String(format: "%+5.1f", 100 * e))
                } else {
                    missed.append("\(c.name) \(pert)"); row.append("  -  ")
                }
            }
            if c0.truthCenter != nil { table.append(String(format: "%-26@ ", c0.name as NSString) + row.joined(separator: " ")) }
        }
        errs.sort()
        let median = errs.isEmpty ? .nan : errs[errs.count / 2]
        print("perturbed crops, drop error (cm) per perturbation [\(Perturbation.standardSet.map(\.description).joined(separator: ", "))]:\n  "
              + table.joined(separator: "\n  ")
              + String(format: "\n  %d runs: missed %d, reported %d, median error %.1f cm, worst %.1f cm, over 2.5 cm %d; false reports %d",
                       errs.count + missed.count, missed.count, errs.count, 100 * median, 100 * (errs.last ?? .nan),
                       errs.filter { $0 > 0.025 }.count, falses.count))
        XCTAssertEqual(errs.count + missed.count, 63)
        XCTAssertLessThanOrEqual(missed.count, 6, "missed: \(missed)")
        XCTAssertLessThanOrEqual(errs.last ?? 0, 0.04)
        XCTAssertLessThanOrEqual(median, 0.015)
        XCTAssertTrue(falses.isEmpty, "\(falses)")
    }

    /// A clean polished ball held 0.45 m over the slab and seen by a camera pitched 30-50 degrees down, at three places in
    /// the picture, with its whole outline showing (its lower half darker than the floor): the locator, fed the
    /// picture twice, reports it every time within 2% in radius, 1.5 cm in drop height and 10 mm in position.
    func testPitchedCameraCleanBall() {
        var lines: [String] = []
        for r in pitchedScenes(lowerVisible: true) {
            lines.append(r.line)
            guard let o = r.found else { XCTFail("\(r.label): not found"); continue }
            XCTAssertLessThan(abs(o.circle.radius / r.radius - 1), 0.02, r.label)
            XCTAssertLessThan(abs(o.drop.dropHeight - 0.45), 0.015, r.label)
            XCTAssertLessThan(o.center.distance(to: r.ball), 0.010, r.label)
        }
        print("pitched camera, whole outline:\n  " + lines.joined(separator: "\n  "))
    }

    /// The same scenes with the ball's lower half the very floor behind it (the web app's premise for its partial find):
    /// whenever the locator reports the ball, its drop height is within 2.5 cm and its position within 15 mm, and it is
    /// reported in at least 5 of the 9 scenes. (Failed when added: a circle inscribed in the outline, touching its top
    /// and the edge of the reflected floor, was reported in 7 of the 9 scenes. The upper outline's reading now
    /// replaces a reading it encloses; see BallFinder.outermost. On other noise, image positions, distances and
    /// steeper pitches this scene is still read wrongly at times; see the commit message.)
    func testPitchedCameraBallWhoseLowerHalfBlends() {
        var lines: [String] = [], reported = 0
        for r in pitchedScenes(lowerVisible: false) {
            lines.append(r.line)
            guard let o = r.found else { continue }
            reported += 1
            XCTAssertLessThan(abs(o.drop.dropHeight - 0.45), 0.025, r.label)
            XCTAssertLessThan(o.center.distance(to: r.ball), 0.015, r.label)
        }
        XCTAssertGreaterThanOrEqual(reported, 5)
        print("pitched camera, lower half blends:\n  " + lines.joined(separator: "\n  "))
    }

    func pitchedScenes(lowerVisible: Bool) -> [(label: String, ball: Vec3, radius: Double, found: BallObservation?, line: String)] {
        let K = CameraIntrinsics(fx: 500, fy: 500, cx: 200, cy: 240, width: 400, height: 480)
        let ball = BallSpec(), spec = SlabSpec.standard
        var out: [(label: String, ball: Vec3, radius: Double, found: BallObservation?, line: String)] = []
        for pitch in [30.0, 40, 50] {
            let p = Units.radians(pitch), g = Vec3(0, cos(p), sin(p)), up = -g
            for at in [Vec2(200, 170), Vec2(140, 120), Vec2(280, 300)] {
                let B = K.ray(at).normalized * 0.5
                let u = Vec3(1, 0, 0).rejecting(up).normalized
                let slab = SlabPose(center: B - up * (0.45 + ball.radius), normal: up, axisU: u, axisV: up.cross(u), halfU: spec.halfU, halfV: spec.halfV)
                let img = SphereScene(K: K, center: B, radius: ball.radius, surface: SphereScene.mirrorSurface(up: up, lowerVisible: lowerVisible)).render(noise: 1)
                let loc = BallLocator()
                loc.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
                let o = loc.update(luma: img, intrinsics: K, slab: slab, spec: spec, ball: ball, down: g)
                let rt = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball)!
                let label = String(format: "pitch %.0f at (%.0f, %.0f)", pitch, at.x, at.y)
                let line = label + ": " + (o.map { String(format: "radius %+.1f%%%@, drop %+.1f cm, position %.1f mm", 100 * ($0.circle.radius / rt - 1),
                                                          $0.circle.partial ? " (partial)" : "", 100 * ($0.drop.dropHeight - 0.45),
                                                          1000 * $0.center.distance(to: B)) } ?? "not reported")
                out.append((label, B, rt, o, line))
            }
        }
        return out
    }

    /// A ball lying on the floor (6 cm below the slab's top: a 1 in slab on its base) just beside the slab, and one
    /// behind it, which the camera sees above the slab: each is found in the picture (centre within 2 px), and the
    /// locator never reports it, because its straight drop does not land on the slab.
    func testFloorBallBesideOrBehindTheSlab() {
        let K = CameraIntrinsics(fx: 600, fy: 600, cx: 320, cy: 240, width: 640, height: 480)
        let ball = BallSpec()
        var lines: [String] = []
        for pitch in [40.0, 55] {
            let v = SyntheticView.make(pitch: pitch, distance: 1.2, tilt: 0, yaw: 0, intrinsics: K)
            let slab = v.pose, n = slab.normal, R = ball.radius
            let away = slab.center.rejecting(n).normalized          // along the floor, away from the camera
            let side = n.cross(away).normalized
            let floorLift = n * (R - 0.06)
            for (name, B) in [("beside", slab.center + side * (slab.halfU + 0.02 + R) + floorLift),
                              ("behind", slab.center + away * (slab.halfV * 1.5 + 0.03 + R) + floorLift)] {
                let img = SphereScene(K: K, center: B, radius: R, surface: SphereScene.mirrorSurface(up: n, lowerVisible: true)).render(noise: 1)
                let t = K.project(B)!, rt = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball)!
                let found = BallFinder.find(luma: img, radiusRange: (rt * 0.7)...(rt * 1.3), intrinsics: K,
                                            up: BallLocator.imageUp(at: t, depth: B.length, intrinsics: K, down: v.down))
                let b = found.min { $0.center.distance(to: t) < $1.center.distance(to: t) }
                let loc = BallLocator()
                var reports: [String] = []
                for _ in 0..<3 {
                    if let o = loc.update(luma: img, intrinsics: K, slab: slab, spec: v.spec, ball: ball, down: v.down) { reports.append("\(o.circle)") }
                }
                let label = String(format: "pitch %.0f, %@", pitch, name)
                var line = label + ": found "
                if let b {
                    line += String(format: "%.2f px off, radius %+.1f%%", b.center.distance(to: t), 100 * (b.radius / rt - 1))
                    if let Bf = Bounce.ballCenter(pixel: b.center, radiusPixels: b.radius, intrinsics: K, ball: ball) {
                        if let d = Bounce.drop(ballCenter: Bf, pose: slab, spec: v.spec, ball: ball, down: v.down) {
                            line += String(format: "; its drop lands at (u, v) = (%.3f, %.3f) m (half-side %.3f)", d.u, d.v, slab.halfU)
                        } else {
                            line += "; below the slab's top"
                        }
                    }
                } else {
                    line += "nothing"
                }
                lines.append(line + "; locator: " + (reports.isEmpty ? "nothing" : reports.joined(separator: ", ")))
                XCTAssertLessThan(b?.center.distance(to: t) ?? 99, 2, label)
                XCTAssertTrue(reports.isEmpty, label)
            }
        }
        print("floor balls by the slab:\n  " + lines.joined(separator: "\n  "))
    }

    /// Light discs printed on a gridded floor mat (3.6-5 cm across, about the ball's size), each beside the straight
    /// edge of a dark mat, around the slab, seen from 1.2 m with the camera pitched 40 and 55 degrees, with noise of 2
    /// and 4 grey levels: no ball is ever reported over the slab. (A synthetic counterpart of distract_mat_circles. The
    /// finder does find most of these discs as round outlines, from part of the outline; seen from 55 degrees a disc is
    /// foreshortened by only 15%. Two rules each keep them out on their own: their outline is that of a disc lying
    /// level (`BallFinder.flatness`), and their size puts them 2-18 cm over the slab, under the `minPartialHeight`
    /// (0.2 m) a partial find needs; that floor was set after this scene, written as a probe, showed 17 such reports.
    /// With neither rule there are 14 reports.)
    func testPrintedDiscsBesideAMatEdge() {
        let K = CameraIntrinsics(fx: 600, fy: 600, cx: 320, cy: 240, width: 640, height: 480)
        let ball = BallSpec()
        var reports: [String] = [], pictures = 0
        for pitch in [40.0, 55] {
            let v = SyntheticView.make(pitch: pitch, distance: 1.2, tilt: 0, yaw: 0, intrinsics: K)
            let slab = v.pose, n = slab.normal
            let floor = slab.center - n * 0.06                                 // a 1 in slab on its base
            let along = slab.center.rejecting(n).normalized, side = n.cross(along).normalized
            for (dx, dz, rDisc) in [(0.0, 0.16, 0.022), (0.12, 0.14, 0.018), (-0.12, 0.10, 0.025), (0.05, 0.22, 0.02)] {
                let disc = floor + side * dx + along * dz, matEdge = dz - rDisc - 0.004
                for sigma in [2.0, 4.0] {
                    for seed in [UInt64(1), 2, 3] {
                        // the floor seen through each pixel (2x2 samples): grid lines every 2.5 cm, the disc, the mat
                        var img = Plane(width: K.width, height: K.height)
                        var rng = SeededRandom(seed &+ UInt64(dx * 1000 + 500) &+ UInt64(pitch))
                        for y in 0..<K.height {
                            for x in 0..<K.width {
                                var acc: Float = 0
                                for sy in 0..<2 {
                                    for sx in 0..<2 {
                                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 2, Double(y) + (Double(sy) + 0.5) / 2))
                                        let t = floor.dot(n) / d.dot(n)
                                        var value: Float = 118
                                        if t > 0 {
                                            let q = d * t - floor, u = q.dot(side), w = q.dot(along)
                                            if abs((u * 100).truncatingRemainder(dividingBy: 2.5)) < 0.15 || abs((w * 100).truncatingRemainder(dividingBy: 2.5)) < 0.15 { value = 100 }
                                            if (d * t - disc).length < rDisc { value = 190 }
                                            if w < matEdge && w > matEdge - 0.08 && abs(u - dx) < 0.1 { value = 25 }
                                        }
                                        acc += value
                                    }
                                }
                                img[x, y] = acc / 4 + Float(rng.gaussian() * sigma)
                            }
                        }
                        pictures += 1
                        let loc = BallLocator()
                        for k in 0..<3 {
                            if let o = loc.update(luma: img, intrinsics: K, slab: slab, spec: v.spec, ball: ball, down: v.down), o.missedUpdates == 0 {
                                reports.append(String(format: "pitch %.0f, disc at (%.2f, %.2f) m, noise %.0f/%d, scan %d: ", pitch, dx, dz, sigma, seed, k) + "\(o.circle), drop \(String(format: "%.2f", o.drop.dropHeight)) m")
                            }
                        }
                    }
                }
            }
        }
        print("printed discs: \(pictures) pictures, \(reports.count) reports" + (reports.isEmpty ? "" : ":\n  " + reports.joined(separator: "\n  ")))
        XCTAssertEqual(pictures, 48)
        XCTAssertTrue(reports.isEmpty, "\(reports)")
    }

    /// A clean polished ball whose whole outline shows, held 0.3-0.9 m over the slab (the owner's 1-3 ft), the slab 3, 4
    /// and 5 ft away, the camera pitched 30-60 degrees, over the slab's middle and 5 cm either side, on whole 720x1280
    /// frames over a lightly textured floor: the locator reports it on the first scan, as a whole outline, within 2% in
    /// radius and 1.5 cm in drop height on both of two scans (the limits of testPitchedCameraCleanBall) and within 2% of
    /// its distance in position (what a 2% error in radius means in depth). (Limits set before it was first run; the
    /// scenes are the reviewer's sweep, in which the radius had come out 3.7-6.3% large at 4-5 ft.) A debug build runs
    /// a few of the scenes.
    func testCleanBallAtThreeToFiveFeet() {
        let K = CameraIntrinsics(verticalFovDegrees: 72.5, width: 720, height: 1280)
        var floor = Plane(width: K.width, height: K.height)
        var rng = SeededRandom(9)
        for y in 0..<K.height { for x in 0..<K.width { floor[x, y] = 118 + 6 * Float(sin(Double(x) * 0.7) * sin(Double(y) * 0.45)) + Float(rng.gaussian() * 2) } }
        let ball = BallSpec()
        #if DEBUG
        let feetSet = [4.0], pitches = [30.0, 50], heights = [0.3, 0.6], lats = [0.0]
        #else
        let feetSet = [3.0, 4, 5], pitches = [30.0, 40, 50, 60], heights = [0.3, 0.45, 0.6, 0.9], lats = [-0.05, 0.0, 0.05]
        #endif
        var n = 0, worstR = 0.0, worstD = 0.0
        for feet in feetSet {
            for pitch in pitches {
                let v = SyntheticView.make(pitch: pitch, distance: Units.feet(feet), tilt: 0, intrinsics: K)
                for h in heights {
                    for lat in lats {
                        let B = v.pose.center + v.pose.normal * (h + ball.radius) + v.pose.axisU * lat
                        guard B.z > 0.1, let p = K.project(B), let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball),
                              p.x > r * 1.7, p.x < Double(K.width) - r * 1.7, p.y > r * 1.7, p.y < Double(K.height) - r * 1.7 else { continue }
                        let img = SphereScene.paint(ballAt: B, radius: ball.radius, up: -v.down, K: K, over: floor)
                        let td = Bounce.drop(ballCenter: B, pose: v.pose, spec: v.spec, ball: ball, down: v.down)!.dropHeight
                        let loc = BallLocator()
                        let o1 = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down)
                        let o2 = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down)
                        n += 1
                        let label = String(format: "%.0f ft, pitch %.0f, %.2f m up, %+.2f m across", feet, pitch, h, lat)
                        guard let o1, let o2 else { XCTFail("\(label): not reported on the first scan"); continue }
                        XCTAssertFalse(o1.circle.partial, label)
                        for o in [o1, o2] {
                            worstR = max(worstR, abs(o.circle.radius / r - 1)); worstD = max(worstD, abs(o.drop.dropHeight - td))
                            XCTAssertLessThan(abs(o.circle.radius / r - 1), 0.02, label)
                            XCTAssertLessThan(abs(o.drop.dropHeight - td), 0.015, label)
                            XCTAssertLessThan(o.center.distance(to: B), 0.02 * B.length, label)
                        }
                    }
                }
            }
        }
        print(String(format: "clean ball at 3-5 ft: %d scenes, worst radius %.1f%%, worst drop %.1f cm", n, 100 * worstR, 100 * worstD))
        XCTAssertGreaterThan(n, 0)
    }

    /// The capture kit's held shots without the video, at each crop factor the app uses for the phone's camera:
    /// SyntheticScene's polished ball (it reflects a dark floor below the horizon and a bright sky above, so just inside
    /// its upper limb the reflection sweeps from what lies behind the ball to the sky, and the edge found along the top
    /// sits about a pixel inside the outline) held 4, 12 and 24 in over a slab tilted 10 degrees, seen as the kit's s09
    /// shots are (1.0 m plus a quarter of the height from a point 0.4 of the height over the slab) from 40, 50 and 65
    /// degrees up, by a 1920x1440 camera. As the app does it: the full camera image cut to the app's ball crop
    /// (`BallImageCrop.plan`) and shrunk by its factor in block averages (as ARController's), which is 1 or 2 here,
    /// never 3. Over three scans the locator reports the ball held 12 and 24 in on the second and third (the first too
    /// where the whole outline is read: a half outline needs two scans); the ball held 4 in, under the least height for
    /// a ball found from half its outline (`BallLocator.Options.minPartialHeight`), is reported where its whole outline
    /// is read. Every drop height reported is never low by more than 10 mm nor high by more than 20 mm. (Before the
    /// directed step test, `BallFinder.upperStepsIn`, the whole outline's circle, pulled in by that top edge, read 15-37
    /// mm low; e74b53e's crop shrank these views by 3 at 50 and 65 degrees, and the ball read up to 29 mm high there. The
    /// size now comes from the lower half's reading, which on these renders reads 0-3% large: up to 19 mm high at 50
    /// degrees. That renderer's look is not a polished ball's on real footage (on a ball that reflects the scene, with
    /// Fresnel, the same poses read about 11 mm low; see CaptureKit.md), so the limits are not tuned to it.) A debug build
    /// runs one azimuth at 40 degrees, rendered at the crop's own scale.
    func testHeldPolishedBallAtThePhonesScale() {
        let f = 0.78 * 1920, Kf = CameraIntrinsics(fx: f, fy: f, cx: 960, cy: 720, width: 1920, height: 1440)
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35), spec = SlabSpec.standard, ball = BallSpec()
        let up = Vec3(0, 1, 0), down = ARKitConvention.worldDown
        #if DEBUG
        let elevations = [40.0], azimuths = [32.0], fullImage = false
        #else
        let elevations = [40.0, 50, 65], azimuths = [20.0, 32, 50], fullImage = true
        #endif
        var lines: [String] = [], worst = 0.0, factors = Set<Int>()
        for el in elevations {
            for inches in [4.0, 12, 24] {
                let h = Units.inches(inches)
                let B = slab.center - slab.normal * spec.dishDepth + up * (ball.radius + h)
                let truth = Bounce.drop(ballCenter: B, pose: slab, spec: spec, ball: ball, down: down)!.dropHeight
                for az in azimuths {
                    let a = Units.radians(az), e = Units.radians(el), aim = slab.center + up * (h * 0.4)
                    let full = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * (1.0 + h * 0.25), lookingAt: aim, intrinsics: Kf)
                    guard let crop = BallImageCrop.plan(slab: slab, full: full) else { XCTFail("no crop"); continue }
                    XCTAssertLessThanOrEqual(crop.factor, 2)
                    factors.insert(crop.factor)
                    let view = CameraView(worldFromCamera: full.worldFromCamera, intrinsics: crop.intrinsics(full: Kf))
                    let K = view.intrinsics
                    let luma: Plane
                    if fullImage {
                        // the crop at full resolution, then k x k block averages
                        let Kc = Kf.cropped(x0: Double(crop.x0), y0: Double(crop.y0), scale: 1, width: crop.width, height: crop.height)
                        var scene = SyntheticScene(slab: slab, ball: B); scene.supersample = 1
                        let p = SyntheticScene.ycc(rgb: scene.renderRGB(view: CameraView(worldFromCamera: full.worldFromCamera, intrinsics: Kc)),
                                                   width: crop.width, height: crop.height).luma
                        luma = crop.factor > 1 ? p.downscaled(by: crop.factor) : p
                    } else {
                        luma = SyntheticScene.ycc(rgb: SyntheticScene(slab: slab, ball: B).renderRGB(view: view), width: K.width, height: K.height).luma
                    }
                    XCTAssertEqual(luma.width, K.width); XCTAssertEqual(luma.height, K.height)
                    let sc = slab.transformed(by: view.cameraFromWorld), g = view.cameraFromWorld.applyDirection(down)
                    let rt = Bounce.imageRadius(ballCenter: view.toCamera(B), intrinsics: K, ball: ball)!
                    let loc = BallLocator()
                    let scans = (0..<3).map { _ in loc.update(luma: luma, intrinsics: K, slab: sc, spec: spec, ball: ball, down: g) }
                    let label = String(format: "%.0f deg up, %.0f in, azimuth %.0f", el, inches, az)
                    lines.append(label + String(format: " (crop factor %d, radius %.1f px): ", crop.factor, rt) + scans.map { o in
                        o.map { String(format: "drop %+.1f mm, radius %+.1f%%%@", 1000 * ($0.drop.dropHeight - truth), 100 * ($0.circle.radius / rt - 1),
                                       $0.circle.partial ? " partial" : "") } ?? "nothing"
                    }.joined(separator: "; "))
                    for (k, o) in scans.enumerated() {
                        guard let o else {
                            if k > 0 && inches > 6 { XCTFail("\(label): not reported on scan \(k + 1)") }
                            continue
                        }
                        XCTAssertEqual(o.missedUpdates, 0, label)
                        XCTAssertLessThan(o.circle.center.distance(to: K.project(view.toCamera(B))!), 0.25 * rt, label)
                        worst = max(worst, abs(o.drop.dropHeight - truth))
                        XCTAssertGreaterThan(o.drop.dropHeight - truth, -0.010, label)
                        XCTAssertLessThan(o.drop.dropHeight - truth, 0.020, label)
                    }
                }
            }
        }
        print("held polished ball at the phone's scale (crop factors \(factors.sorted())):\n  " + lines.joined(separator: "\n  ")
              + String(format: "\n  worst drop error %.1f mm", 1000 * worst))
    }

    /// A shiny lid with pressed rings lying on the slab (`ReflectingScene`: 60-80 mm across, a jar lid, a coaster, a
    /// medallion), alone and with a polished ball held 4 or 12 in over the slab (at its centre or off it), seen from
    /// 0.75 m at 55-70 degrees by the phone's camera at the scale of a crop shrunk by 3 (640 x 480 for its 1920 x 1440
    /// image, the ball 12-16 px across). The lid's outer rim gives a lower half's reading and an inner ring an upper one
    /// that closes it over the top, and its whole outline, an ellipse, reads as a circle whose top lies inside the circle
    /// its lower half makes: each such find stays partial (`BallFinder.outermost`), so it is held to the locator's
    /// rules for half an outline and ranks below a ball whose outline was read whole. Over three scans the ball is
    /// reported on every scan, where it is (within a quarter of its radius), and the lid never is; alone, the lid is
    /// never reported, and the capture kit's tracking finder takes a half outline of it under 0.2 m on one of three
    /// frames at most (`BallLocator.Options.stillPartialCeiling`). (Before, those finds were whole ones counting the whole rim's support: in scenes like these the
    /// lid took the ball's place on 38 of 120 scans, about 20 cm low for a ball held 12 in up. Poses where a lid's whole
    /// outline is taken for a ball, which the level-disc test does not tell from one, are a separate matter.) A debug
    /// build runs two poses.
    func testRingedLidOnTheSlabIsNotTakenForTheBall() {
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35), spec = SlabSpec.standard, ball = BallSpec()
        let K = CameraIntrinsics(fx: 0.78 * 640, fy: 0.78 * 640, cx: 320, cy: 240, width: 640, height: 480)
        let up = Vec3(0, 1, 0), down = ARKitConvention.worldDown
        // lid diameter, camera elevation and azimuth, lid offset along the slab's axes, ring depth
        var lids: [(Double, Double, Double, Double, Double, Double)] = [(0.06, 55, 80, -0.05, 0.05, 0.35), (0.06, 60, 140, -0.05, 0.05, 0.25)]
        #if !DEBUG
        lids += [(0.06, 60, 220, 0, 0, 0.35), (0.06, 60, 255, 0.06, -0.04, 0.35), (0.06, 70, 185, 0.06, -0.04, 0.25),
                 (0.07, 60, 220, 0, 0, 0.35), (0.07, 65, 150, 0.06, -0.04, 0.35), (0.08, 60, 10, -0.05, 0.05, 0.35)]
        #endif
        var lines: [String] = [], scenes = 0
        for (D, el, az, ou, ov, rings) in lids {
            let a = Units.radians(az), e = Units.radians(el), aim = slab.center + up * 0.1
            let view = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * 0.75, lookingAt: aim, intrinsics: K)
            let sc = slab.transformed(by: view.cameraFromWorld), g = view.cameraFromWorld.applyDirection(down)
            var balls: [(String, Vec3?)] = [("no ball", nil)]
            for (inches, bu, bv) in [(4.0, 0.0, 0.0), (12.0, 0.0, 0.0), (12.0, -0.06, -0.05)] where !(ou == 0 && ov == 0 && bu == 0 && bv == 0) {
                balls.append((String(format: "ball %.0f in at (%+.2f, %+.2f)", inches, bu, bv),
                              slab.center + slab.axisU * bu + slab.axisV * bv - slab.normal * spec.dishDepth + up * (ball.radius + Units.inches(inches))))
            }
            for (name, B) in balls {
                var scene = ReflectingScene(slab: slab)
                scene.putLid(diameter: D, u: ou, v: ov, rings: rings)
                scene.ball = B
                let luma = scene.renderLuma(view: view)
                let label = String(format: "lid %.0f mm at (%+.2f, %+.2f), %.0f deg up, azimuth %.0f, %@", 1000 * D, ou, ov, el, az, name)
                let at = B.flatMap { view.project(world: $0) }, r = B.flatMap { Bounce.imageRadius(ballCenter: view.toCamera($0), intrinsics: K, ball: ball) } ?? 0
                let loc = BallLocator()
                var outs: [String] = []
                for k in 0..<3 {
                    let o = loc.update(luma: luma, intrinsics: K, slab: sc, spec: spec, ball: ball, down: g)
                    outs.append(o.map { "\($0.circle) \(String(format: "%.3f m", $0.drop.dropHeight))" } ?? "nothing")
                    if let at {
                        guard let o else { XCTFail("\(label): the ball not reported on scan \(k + 1)"); continue }
                        XCTAssertLessThan(o.circle.center.distance(to: at), 0.25 * r, "\(label), scan \(k + 1): \(o.circle) is not the ball")
                    } else {
                        XCTAssertNil(o, "\(label), scan \(k + 1): the lid reported as a ball")
                    }
                }
                if B == nil {
                    // the capture kit's tracking finder (`BallLocator.Options.tracking`): a half outline low over the slab
                    // is taken on a single frame, but not again where one was on the frame before
                    let tracking = BallLocator(options: .tracking())
                    let taken = (0..<3).compactMap { _ in tracking.update(luma: luma, intrinsics: K, slab: sc, spec: spec, ball: ball, down: g) }
                    let low = taken.filter { $0.circle.partial && $0.drop.dropHeight < 0.2 }.count
                    XCTAssertLessThanOrEqual(low, 1, "\(label): the tracking finder took a half outline lying on the slab \(low) times")
                    outs.append("tracking: " + (taken.isEmpty ? "nothing" : taken.map { "\($0.circle) \(String(format: "%.3f m", $0.drop.dropHeight))" }.joined(separator: ", ")))
                }
                scenes += 1
                lines.append(label + ": " + outs.joined(separator: "; "))
            }
        }
        print("ringed lid on the slab, \(scenes) scenes:\n  " + lines.joined(separator: "\n  "))
    }

    /// No ball, on floors of square tiles (2-5 cm, grout 2 and 4 mm in two shades) with the slab on them, seen from
    /// 0.75-1.5 m with the camera pitched 45-75 degrees, with noise of 2 grey levels: nothing is ever reported over three
    /// scans. (A tile's outline read from its centre was taken for a ball's; limit set before it was first run: there is
    /// no ball. A debug build runs one view, two tile sizes and the darker grout.)
    func testNoBallOnTiledFloors() {
        let K = CameraIntrinsics(fx: 600, fy: 600, cx: 320, cy: 240, width: 640, height: 480)
        #if DEBUG
        let views: [(Double, Double)] = [(60.0, 1.0)], tiles = [0.03, 0.05], darks: [Float] = [80]
        #else
        let views: [(Double, Double)] = [45.0, 60, 75].flatMap { p in [0.75, 1.0, 1.5].map { (p, $0) } }
        let tiles = [0.02, 0.03, 0.04, 0.05], darks: [Float] = [100, 80]
        #endif
        var reports: [String] = [], n = 0
        for (pitch, dist) in views {
            let v = SyntheticView.make(pitch: pitch, distance: dist, tilt: 0, yaw: 0, intrinsics: K)
            for tile in tiles {
                for grout in [0.002, 0.004] {
                    for dark in darks {
                        let scene = FloorScene(K: K, slab: v.pose) { u, w in
                            let a = (u + 10).truncatingRemainder(dividingBy: tile), b = (w + 10).truncatingRemainder(dividingBy: tile)
                            return a < grout || b < grout ? dark : 120
                        }
                        n += 1
                        let img = scene.render(noise: 2, seed: UInt64(n))
                        let loc = BallLocator()
                        for k in 0..<3 {
                            if let o = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: BallSpec(), down: v.down), o.missedUpdates == 0 {
                                reports.append(String(format: "pitch %.0f, %.2f m, tiles %.0f cm, grout %.0f mm of %.0f, scan %d: ", pitch, dist, 100 * tile, 1000 * grout, dark, k) + "\(o.circle)")
                            }
                        }
                    }
                }
            }
        }
        print("tiled floors without a ball: \(n) pictures, \(reports.count) reports" + (reports.isEmpty ? "" : ":\n  " + reports.joined(separator: "\n  ")))
        XCTAssertTrue(reports.isEmpty, "\(reports)")
    }

    /// Plain light round prints (a sticker or a coaster: one shade throughout) where a ball held 0.1-0.6 m over the slab
    /// would be seen, and as large: standing behind the slab facing the camera, or lying on the floor behind it in full
    /// view, the camera 0.75-1.5 m away and pitched 35-65 degrees, with noise of 2 grey levels: none is ever reported over
    /// three scans. A polished ball is never plain inside (it reflects the room in its upper half and the floor in its
    /// lower half), and a disc lying level is foreshortened along up where a sphere is not. (These are the plain discs
    /// of the reviewer's probes, which I ran before writing this test; its limit is the target. Textured prints are not
    /// covered: see the commit message. A debug build runs one distance and one pitch.)
    func testPlainPrintsWhereABallWouldBe() {
        let K = CameraIntrinsics(fx: 600, fy: 600, cx: 320, cy: 240, width: 640, height: 480)
        let R = BallSpec().radius
        #if DEBUG
        let dists = [1.0], pitches = [50.0]
        #else
        let dists = [0.75, 1.0, 1.5], pitches = [35.0, 50, 65]
        #endif
        let grid: (Double, Double) -> Float = { u, w in
            abs((u * 100).truncatingRemainder(dividingBy: 2.5)) < 0.15 || abs((w * 100).truncatingRemainder(dividingBy: 2.5)) < 0.15 ? 100 : 118
        }
        var reports: [String] = [], n = 0
        for pitch in pitches {
            for dist in dists {
                let v = SyntheticView.make(pitch: pitch, distance: dist, tilt: 0, yaw: 0, intrinsics: K)
                let base = FloorScene(K: K, slab: v.pose, pattern: grid)
                let nn = v.pose.normal
                for h in [0.1, 0.3, 0.6] {
                    for lat in [0.0, 0.06] {
                        let B = v.pose.center + nn * (h + R) + base.side * lat
                        var prints: [(String, (center: Vec3, normal: Vec3, e1: Vec3, e2: Vec3, radius: Double, luma: Float))] = []
                        // lying on the floor where the line of sight to the ball meets it
                        let tf = base.floorPoint.dot(nn) / B.dot(nn)
                        if tf > 1 { prints.append(("lying", (B * tf, nn, base.side, base.along, R * tf, 200))) }
                        // standing further along the line of sight, facing the camera
                        for t in [1.3, 1.8] {
                            let P = B * t, m = -P.normalized
                            let e1 = nn.cross(m).normalized, e2 = m.cross(e1).normalized
                            if (P - base.floorPoint).dot(nn) > R * t * 1.05 { prints.append(("facing", (P, m, e1, e2, R * t, 200))) }
                        }
                        for (kind, pr) in prints {
                            // the whole print in view: clear of the frame's edges and not hidden by the slab
                            let rim = (0..<24).map { pr.center + (pr.e1 * cos(Double($0) * .pi / 12) + pr.e2 * sin(Double($0) * .pi / 12)) * pr.radius }
                            guard rim.allSatisfy({ q in K.project(q).map { $0.x > 20 && $0.x < 620 && $0.y > 20 && $0.y < 460 } ?? false }),
                                  !rim.contains(where: base.hiddenBySlab) else { continue }
                            var scene = base
                            scene.print = pr
                            n += 1
                            let img = scene.render(noise: 2, seed: UInt64(n))
                            let loc = BallLocator()
                            for k in 0..<3 {
                                if let o = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: BallSpec(), down: v.down), o.missedUpdates == 0 {
                                    reports.append(String(format: "%@ print, pitch %.0f, %.2f m, as a ball %.1f m up, %+.2f m across, scan %d: ", kind, pitch, dist, h, lat, k) + "\(o.circle)")
                                }
                            }
                        }
                    }
                }
            }
        }
        print("plain prints where a ball would be: \(n) pictures, \(reports.count) reports" + (reports.isEmpty ? "" : ":\n  " + reports.joined(separator: "\n  ")))
        XCTAssertGreaterThan(n, 0)
        XCTAssertTrue(reports.isEmpty, "\(reports)")
    }

    // MARK: timing

    /// Time per update() on the 300x720 crops (meaningful in a release build: swift test -c release -Xswiftc
    /// -enable-testing --filter BallFinderTests/testTiming). The crops cut the search region short; see
    /// testTimeOnFullFrames for whole frames.
    func testTiming() throws {
        let crops = try BallCrop.all().filter { $0.truthCenter != nil }
        var search: [Double] = [], follow: [Double] = []
        for c in crops {
            let slab = c.slab, loc = BallLocator()
            for _ in 0..<3 {
                loc.reset()
                let t0 = DispatchTime.now().uptimeNanoseconds
                loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                search.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
            for _ in 0..<3 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                loc.update(luma: c.luma, intrinsics: c.K, slab: slab, spec: c.spec, ball: c.ball, down: c.down)
                follow.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
        }
        search.sort(); follow.sort()
        print(String(format: "update(): searching the column over the slab median %.2f ms (max %.2f), following a ball median %.2f ms (max %.2f)",
                     search[search.count / 2], search.last!, follow[follow.count / 2], follow.last!))
    }

    /// Time per update() on whole frames: 720x1280 (the web app's frames and the fixtures' source) and 1920x1440 (an
    /// ARKit frame, the phone held upright so the frame is turned), the slab 3, 4 and 5 ft away, the camera pitched 40,
    /// 55 and 70 degrees, a gridded floor with noise, and a ball held 0.3 m over the slab's middle. Meaningful in a
    /// release build; a debug build runs one pose per frame size only. Also: whatever is reported is the ball (its
    /// centre within 2% of its distance); it is reported wherever the line of sight to it is at least 30 degrees from
    /// the vertical (closer to the vertical a level disc's outline is foreshortened by less than 14%, and the finder may
    /// not tell a sphere from one); and the floor alone gives no report over three scans. (These checks were added with
    /// this round's changes, their limits set before they were first run: a grid cell had been reported instead of the
    /// ball in two poses, and on the bare floor in five.)
    func testTimeOnFullFrames() {
        #if DEBUG
        let poses: [(Double, Double)] = [(4, 55)]
        #else
        let poses: [(Double, Double)] = [3.0, 4, 5].flatMap { f in [40.0, 55, 70].map { (f, $0) } }
        #endif
        let frames = [("720x1280", CameraIntrinsics(verticalFovDegrees: 72.5, width: 720, height: 1280), 0.0),
                      ("1920x1440", CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440), 90.0)]
        let ball = BallSpec()
        for (name, K, roll) in frames {
            // the floor: a 2 px grid line every 24 px (36 in the larger frame) and noise of 2 grey levels
            let cell = K.width > 1000 ? 36 : 24
            var floor = Plane(width: K.width, height: K.height)
            var rng = SeededRandom(5)
            for y in 0..<K.height { for x in 0..<K.width { floor[x, y] = (x % cell < 2 || y % cell < 2 ? 90 : 120) + Float(rng.gaussian() * 2) } }
            var search: [Double] = [], follow: [Double] = [], found = 0, lines: [String] = []
            for (feet, pitch) in poses {
                do {
                    let v = SyntheticView.make(pitch: pitch, roll: roll, distance: Units.feet(feet), tilt: 0, intrinsics: K)
                    let B = v.pose.center + v.pose.normal * (0.3 + ball.radius)
                    let img = SphereScene.paint(ballAt: B, radius: ball.radius, up: -v.down, K: K, over: floor)
                    let loc = BallLocator()
                    var ts: [Double] = []
                    for _ in 0..<3 {
                        loc.reset()
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down)
                        ts.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    }
                    search += ts
                    let o = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down)
                    var tf: [Double] = []
                    for _ in 0..<3 {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down)
                        tf.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    }
                    follow += tf
                    if o != nil { found += 1 }
                    let label = String(format: "%@, %.0f ft, pitch %.0f", name, feet, pitch)
                    if let o { XCTAssertLessThan(o.center.distance(to: B), 0.02 * B.length, "\(label): \(o.circle) is not the ball") }
                    if abs(B.normalized.dot(v.down.normalized)) <= cos(Units.radians(30)) { XCTAssertNotNil(o, "\(label): ball not reported") }
                    let bare = BallLocator()
                    for k in 0..<3 {
                        if let e = bare.update(luma: floor, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down) {
                            XCTFail("\(label), no ball, scan \(k): \(e.circle)")
                        }
                    }
                    let bands = BallLocator.searchBands(intrinsics: K, slab: v.pose, ball: ball, down: v.down, heights: 0.05...1.5)
                    lines.append(String(format: "%.0f ft, pitch %.0f: search %.1f ms, follow %.1f ms, ball %@; bands %@", feet, pitch, ts.min()!, tf.min()!,
                                        o == nil ? "missed" : "found",
                                        bands.map { String(format: "r %.0f-%.0f /%d in %.0fx%.0f", $0.radii.lowerBound, $0.radii.upperBound, $0.scale, $0.region.width, $0.region.height) }.joined(separator: ", ")))
                }
            }
            search.sort(); follow.sort()
            print("\(name): update() searching median \(String(format: "%.1f", search[search.count / 2])) ms (max \(String(format: "%.1f", search.last!))), "
                  + "following median \(String(format: "%.1f", follow[follow.count / 2])) ms (max \(String(format: "%.1f", follow.last!))); ball found in \(found) of \(poses.count)\n  "
                  + lines.joined(separator: "\n  "))
        }
    }
}

extension Mat3 {
    /// rotation by a rotation vector (axis * angle)
    static func rotation(_ w: Vec3) -> Mat3 {
        Mat3(columns: Vec3(1, 0, 0).rotated(by: w), Vec3(0, 1, 0).rotated(by: w), Vec3(0, 0, 1).rotated(by: w))
    }
}
