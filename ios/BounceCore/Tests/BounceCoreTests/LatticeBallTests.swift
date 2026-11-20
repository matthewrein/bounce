import XCTest
@testable import BounceCore

/// The ball finder on renders of the owner's ball as it is: a mildly polished titanium lattice (`LatticeBall`), held
/// in the fingertips (`LatticePaint.grip`) over the floors of the kits (a wooden floor, a white play mat with black
/// prints), at the scale of the app's ball crop (the phone's 1920 x 1440 image cut around the slab and shrunk by 2).
/// The real clips are the measure (see the track's report); these renders check the same rules where the truth is
/// known exactly.
final class LatticeBallTests: XCTestCase {
    /// the app's ball crop of the phone's camera at its usual shrink by 2
    static let K = CameraIntrinsics(fx: 690, fy: 690, cx: 400, cy: 350, width: 800, height: 700)

    enum Floor: CaseIterable { case wood, mat }

    /// The floor seen through each pixel (2 x 2 samples), the slab's top drawn as a grey box: wood (planks with grain) or
    /// the play mat (white with a fine waffle, a black road and printed rings, discs and curves), with sensor noise.
    static func floorPicture(_ kind: Floor, view v: SyntheticView, prints: [(u: Double, w: Double, kind: Int)] = [], noise: Double = 2,
                      seed: UInt64 = 1) -> Plane {
        let K = v.intrinsics
        var img = Plane(width: K.width, height: K.height)
        var rng = SeededRandom(seed)
        let n = -v.down.normalized, slab = v.pose
        let f0 = slab.center - n * 0.052
        let along = slab.center.rejecting(n).normalized, side = n.cross(along).normalized
        for y in 0..<K.height {
            for x in 0..<K.width {
                var acc: Float = 0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 2, Double(y) + (Double(sy) + 0.5) / 2))
                        var value: Float = 150
                        // the slab's top (a plain grey square)
                        let dn = d.dot(slab.normal)
                        if abs(dn) > 1e-9 {
                            let t = slab.center.dot(slab.normal) / dn, q = d * t - slab.center
                            if t > 0, abs(q.dot(slab.axisU)) < slab.halfU, abs(q.dot(slab.axisV)) < slab.halfV { acc += 105; continue }
                        }
                        let df = d.dot(n)
                        if df < 0 {
                            let t = f0.dot(n) / df, q = d * t - f0, u = q.dot(side), w = q.dot(along)
                            switch kind {
                            case .wood:
                                let plank = Int((w / 0.09).rounded(.down))
                                value = 138 + 10 * Float(sin(Double(plank) * 2.1)) + 5 * Float(sin(u * 260 + Double(plank)) * sin(w * 40))
                                if abs(w - Double(plank) * 0.09) < 0.0012 { value = 95 }
                            case .mat:
                                value = 205 + 6 * Float(sin(u * 2400) * sin(w * 2400))
                                if abs(w - 0.15) < 0.025 { value = 38 }
                                for p in prints {
                                    let r = ((u - p.u) * (u - p.u) + (w - p.w) * (w - p.w)).squareRoot()
                                    switch p.kind {
                                    case 0: if r < 0.016 { value = 34 }                                   // a black disc
                                    case 1: if r < 0.004 || (r > 0.009 && r < 0.017) { value = 34 }       // a wheel
                                    case 2: if r > 0.03 && r < 0.07 && w < p.w { value = 36 }             // a road's turn
                                    default: break
                                    }
                                }
                            }
                        }
                        acc += value
                    }
                }
                img[x, y] = acc / 4 + Float(rng.gaussian() * noise)
            }
        }
        return img
    }

    /// The renderers' lattice (`LatticeBall`) seen from 1 m on a grid of rays over its disc: the background shows through
    /// some of it (the owner: "the background shows through"), most of it is metal, the ring next to the outline is
    /// nearly closed (the shell is seen edge on there), and the metal is dark titanium, lit unevenly (struts and glints).
    func testTheLatticeShowsHolesAndANearlyWholeOutline() {
        let ball = LatticeBall(radius: 0.015), centre = Vec3(0, 0, 1), light = Vec3(0.3, 1, -0.5).normalized
        var solid = 0, through = 0, outerSolid = 0, outer = 0
        var lumas: [Double] = []
        let n = 120
        for j in 0..<n {
            for i in 0..<n {
                let x = (Double(i) + 0.5) / Double(n) * 2 - 1, y = (Double(j) + 0.5) / Double(n) * 2 - 1
                let rho = (x * x + y * y).squareRoot()
                guard rho < 0.995 else { continue }
                let d = Vec3(x * 0.015, y * 0.015, 1).normalized
                switch ball.trace(.zero, d, center: centre, light: light) {
                case let .solid(_, c)?:
                    solid += 1; lumas.append(0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2)
                    if rho > 0.9 { outerSolid += 1 }
                case .through?: through += 1
                case nil: break
                }
                if rho > 0.9 { outer += 1 }
            }
        }
        let share = Double(through) / Double(solid + through), outerShare = Double(outerSolid) / Double(outer)
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let sd = (lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)).squareRoot()
        print(String(format: "lattice: %.1f%% see-through, outer ring %.0f%% metal, metal %.2f +- %.2f", 100 * share, 100 * outerShare, mean, sd))
        XCTAssertGreaterThan(share, 0.01, "the background shows through")
        XCTAssertLessThan(share, 0.5, "mostly metal")
        XCTAssertGreaterThan(outerShare, 0.6, "the outline is nearly whole")
        XCTAssertLessThan(mean, 0.5, "dark titanium")
        XCTAssertGreaterThan(sd / mean, 0.25, "struts, holes and glints")
    }

    /// The lattice ball held in the fingertips 10, 30 and 60 cm over the slab's middle, the slab 1 m away seen 50-60
    /// degrees down, over the wooden floor and the white mat: the locator reports it on the second scan (part of an
    /// outline needs two), where it is (within a quarter of its radius), at its size (8%), its drop height within 2 cm.
    /// (The finder of n11 found none of these over the mat: the mirror test wants a highlight well above the background,
    /// and the lattice is darker than the mat; and the fingers leave no half of the outline whole.)
    func testLatticeBallHeldInTheFingers() {
        let K = Self.K, ball = BallSpec()
        var lines: [String] = [], found = 0, scenes = 0
        for pitch in [50.0, 60] {
            let v = SyntheticView.make(pitch: pitch, distance: 1.0, tilt: 2, intrinsics: K)
            for kind in Floor.allCases {
                let base = Self.floorPicture(kind, view: v, seed: UInt64(pitch))
                for h in [0.1, 0.3, 0.6] {
                    let B = v.pose.center + v.pose.normal * (h + ball.radius)
                    guard let p = K.project(B), let r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: ball),
                          p.x > 2 * r, p.y > 2 * r, p.x < Double(K.width) - 2 * r, p.y < Double(K.height) - 2 * r else { continue }
                    let up = -v.down
                    let img = LatticePaint.paint(ballAt: B, radius: ball.radius, up: up, K: K, over: base,
                                                 fingers: LatticePaint.grip(ballAt: B, radius: ball.radius, up: up))
                    let td = Bounce.drop(ballCenter: B, pose: v.pose, spec: v.spec, ball: ball, down: v.down)!.dropHeight
                    let loc = BallLocator()
                    let scans = (0..<2).map { _ in loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down) }
                    scenes += 1
                    let label = String(format: "%@, pitch %.0f, %.1f m up (r %.1f px)", kind == .wood ? "wood" : "mat", pitch, h, r)
                    lines.append(label + ": " + scans.map { o in o.map { String(format: "%@ r %+.1f%% off %.2f r drop %+.1f cm", $0.circle.partial ? "part" : "whole",
                                                                                        100 * ($0.circle.radius / r - 1), $0.circle.center.distance(to: p) / r,
                                                                                        100 * ($0.drop.dropHeight - td)) } ?? "nothing" }.joined(separator: "; "))
                    guard let o = scans[1] else { XCTFail("\(label): not reported by the second scan"); continue }
                    found += 1
                    XCTAssertLessThan(o.circle.center.distance(to: p), 0.25 * r, label)
                    XCTAssertLessThan(abs(o.circle.radius / r - 1), 0.08, label)
                    XCTAssertLessThan(abs(o.drop.dropHeight - td), 0.02, label)
                }
            }
        }
        print("lattice ball held in the fingers: \(found) of \(scenes)\n  " + lines.joined(separator: "\n  "))
        XCTAssertGreaterThanOrEqual(scenes, 8)
    }

    /// The play mat's prints next to the slab, where a ball held over it would be seen (black discs 32 mm across, wheels
    /// of a printed car, the turn of a printed road), and a smooth toy ball lying on the mat: over three scans the
    /// locator reports none of them, at either pitch.
    func testPrintsAndAToyBallOnTheMatAreNotTheBall() {
        let K = Self.K, ball = BallSpec()
        var reports: [String] = [], pictures = 0
        for pitch in [45.0, 60] {
            let v = SyntheticView.make(pitch: pitch, distance: 1.0, tilt: 2, intrinsics: K)
            let prints: [(u: Double, w: Double, kind: Int)] = [(-0.16, 0.02, 0), (0.15, -0.05, 1), (-0.13, -0.12, 1), (0.17, 0.08, 2),
                                                               (0.02, -0.17, 0), (-0.2, 0.12, 2), (0.22, -0.16, 1)]
            var base = Self.floorPicture(.mat, view: v, prints: prints, seed: UInt64(pitch) + 7)
            // a smooth green toy ball, 40 mm across, lying on the mat beside the slab (its luma, shaded, no holes)
            let n = -v.down.normalized, along = v.pose.center.rejecting(n).normalized, side = n.cross(along).normalized
            let toy = v.pose.center - n * 0.052 + side * 0.14 + along * 0.13 + n * 0.02
            base = SphereScene.paintSmooth(ballAt: toy, radius: 0.02, light: (n + side * 0.4).normalized, K: K, over: base, luma: 118)
            for seed in [UInt64(1), 2] {
                var img = base
                var rng = SeededRandom(seed)
                for i in 0..<img.data.count { img.data[i] += Float(rng.gaussian() * 1.5) }
                pictures += 1
                let loc = BallLocator()
                for k in 0..<3 {
                    if let o = loc.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down), o.missedUpdates == 0 {
                        reports.append(String(format: "pitch %.0f, seed %d, scan %d: ", pitch, seed, k) + "\(o.circle), drop \(String(format: "%.2f", o.drop.dropHeight)) m")
                    }
                }
            }
        }
        print("mat prints and a toy ball: \(pictures) pictures, \(reports.count) reports" + (reports.isEmpty ? "" : ":\n  " + reports.joined(separator: "\n  ")))
        XCTAssertEqual(pictures, 4)
        XCTAssertTrue(reports.isEmpty, "\(reports)")
    }

    /// The lattice ball falling past the slab, blurred over an exposure of 11 ms as the kits' drops were (2.4 m/s at the
    /// end of a fall from 1 ft: about twice its radius of streak): the capture kit's tracking finder (every frame on its
    /// own) finds it where it is at the exposure's middle on 8 of the 15 frames (from 300 mm down to 213 mm, and at
    /// 70 mm), at least 6: the bar leaves two frames to the last-bit differences of another platform's maths (pow, sin,
    /// atan2 in the renders and the fits), as the macOS CI leg runs it.
    func testFallingLatticeBallIsTracked() {
        let K = Self.K, ball = BallSpec(), g = 9.81
        let v = SyntheticView.make(pitch: 55, distance: 1.0, tilt: 2, intrinsics: K)
        let base = Self.floorPicture(.mat, view: v, seed: 5)
        let n = -v.down.normalized, top = v.pose.center + n * ball.radius
        let tracking = BallLocator(options: .tracking())
        var found = 0, frames = 0, lines: [String] = []
        // from 0.3 m over the slab, frames every 1/60 s until just above the dish
        var t = 0.0
        while true {
            let h0 = 0.3 - 0.5 * g * t * t
            if h0 < 0.03 { break }
            let path = (0..<7).map { k -> Vec3 in
                let tt = t - 0.0057 + 0.0114 * Double(k) / 6
                return top + n * max(0.0, 0.3 - 0.5 * g * max(0, tt) * max(0, tt))
            }
            let mid = top + n * h0
            let img = LatticePaint.paint(ballAt: mid, radius: ball.radius, up: n, K: K, over: base, path: path, samples: 3)
            let r = Bounce.imageRadius(ballCenter: mid, intrinsics: K, ball: ball)!, p = K.project(mid)!
            frames += 1
            if let o = tracking.update(luma: img, intrinsics: K, slab: v.pose, spec: v.spec, ball: ball, down: v.down),
               o.circle.center.distance(to: p) < 0.5 * r {
                found += 1
                lines.append(String(format: "%.0f mm: found, off %.2f r, r %+.0f%%", 1000 * h0, o.circle.center.distance(to: p) / r, 100 * (o.circle.radius / r - 1)))
            } else {
                lines.append(String(format: "%.0f mm: not found", 1000 * h0))
            }
            t += 1.0 / 60
        }
        print("falling lattice ball: \(found) of \(frames) frames\n  " + lines.joined(separator: "\n  "))
        XCTAssertGreaterThanOrEqual(frames, 12)
        XCTAssertGreaterThanOrEqual(found, 6)
    }
}

extension SphereScene {
    /// A smooth, matte ball (a toy ball: no holes, no polish) painted over a picture, Lambert-shaded toward `light`
    /// (camera axes), 3 x 3 samples a pixel.
    static func paintSmooth(ballAt center: Vec3, radius: Double, light: Vec3, K: CameraIntrinsics, over base: Plane, luma: Float) -> Plane {
        var img = base
        guard let pc = K.project(center), let r = Bounce.imageRadius(ballCenter: center, intrinsics: K, ball: BallSpec(diameter: 2 * radius)) else { return img }
        let reach = r * 1.4 + 3
        for y in max(0, Int(pc.y - reach))..<min(K.height, Int(pc.y + reach) + 1) {
            for x in max(0, Int(pc.x - reach))..<min(K.width, Int(pc.x + reach) + 1) {
                var v: Float = 0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let d = K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 3, Double(y) + (Double(sy) + 0.5) / 3)).normalized, b = d.dot(center)
                        let disc = b * b - center.lengthSquared + radius * radius
                        if disc >= 0 {
                            let nrm = (d * (b - disc.squareRoot()) - center) / radius
                            v += luma * Float(0.55 + 0.45 * max(0, nrm.dot(light)))
                        } else { v += base[x, y] }
                    }
                }
                img[x, y] = v / 9
            }
        }
        return img
    }
}
