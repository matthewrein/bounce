import BounceCore
import Foundation

/// What the bench paints into a SyntheticScene render (before the sensor noise) to make harder frames than its one clean
/// floor: a hand over a corner of the slab, and floor clutter (wood planks, rugs, papers, shoes, slab-sized squares) or a
/// floor of slab-sized tiles. The clutter lies flat on the floor (y = 0), projected through the camera, with 2x2 samples
/// a pixel at its edges and a [1 2 1] softening like the render's; it leaves the slab, its base and shadow, and the ball
/// alone. SyntheticScene itself is unchanged.
enum ScenePaint {
    // MARK: noise

    @inline(__always) static func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 73856093 ^ y &* 19349663 ^ s &* 83492791))
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33; h = h &* 0xc4ceb3fe1a85ec53; h ^= h >> 33
        return Double(h & 0xFFFF) / 65535
    }

    /// value noise in [0, 1] with cell size 1
    @inline(__always) static func noise(_ a: Double, _ b: Double, _ s: Int) -> Double {
        let fa0 = a.rounded(.down), fb0 = b.rounded(.down)
        let ia = Int(fa0), ib = Int(fb0), fa = a - fa0, fb = b - fb0
        let ua = fa * fa * (3 - 2 * fa), ub = fb * fb * (3 - 2 * fb)
        let v00 = hash(ia, ib, s), v10 = hash(ia + 1, ib, s), v01 = hash(ia, ib + 1, s), v11 = hash(ia + 1, ib + 1, s)
        return (v00 * (1 - ua) + v10 * ua) * (1 - ub) + (v01 * (1 - ua) + v11 * ua) * ub
    }

    typealias RGB = (Double, Double, Double)

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let i = Int((h * 6).rounded(.down)) % 6, f = h * 6 - (h * 6).rounded(.down)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let c: RGB
        switch i {
        case 0: c = (v, t, p)
        case 1: c = (q, v, p)
        case 2: c = (p, v, t)
        case 3: c = (p, q, v)
        case 4: c = (t, p, v)
        default: c = (v, p, q)
        }
        return (c.0 * 255, c.1 * 255, c.2 * 255)
    }

    // MARK: floor clutter

    struct Patch {
        enum Style { case plain, speckle, wood, rug, tiles }
        var cx: Double, cz: Double, cosA: Double, sinA: Double, halfU: Double, halfV: Double
        var style: Style
        var colour: RGB
        var colour2: RGB
        var seed: Int

        @inline(__always) func local(_ x: Double, _ z: Double) -> (Double, Double) {
            let dx = x - cx, dz = z - cz
            return (dx * cosA + dz * sinA, -dx * sinA + dz * cosA)
        }
        @inline(__always) func contains(_ x: Double, _ z: Double) -> Bool {
            let (u, v) = local(x, z)
            return abs(u) <= halfU && abs(v) <= halfV
        }

        func colourAt(_ x: Double, _ z: Double) -> RGB {
            let (u, v) = local(x, z)
            func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t) }
            func scale(_ a: RGB, _ k: Double) -> RGB { (a.0 * k, a.1 * k, a.2 * k) }
            switch style {
            case .plain:
                return scale(colour, 0.94 + 0.06 * ScenePaint.noise(u * 40, v * 40, seed))
            case .speckle:
                let n = ScenePaint.noise(u * 900, v * 900, seed)
                return scale(n > 0.7 ? colour2 : colour, 0.9 + 0.1 * ScenePaint.noise(u * 120, v * 120, seed + 1))
            case .wood:
                // grain along v, wavy, with darker rings and plank seams across it every 0.6 m
                let w = v * 6 + 2.5 * ScenePaint.noise(u * 9, v * 1.5, seed)
                let ring = 0.5 + 0.5 * sin(w * 2 * .pi * 3 + u * 40)
                let seam = abs((v + 5 * halfV).truncatingRemainder(dividingBy: 0.6) - 0.3) > 0.297 ? 0.55 : 1.0
                return scale(mix(colour, colour2, ring * 0.6), seam * (0.92 + 0.08 * ScenePaint.noise(u * 300, v * 60, seed + 2)))
            case .rug:
                // a border band, then a woven field with a coarse pattern
                let border = halfU - abs(u) < 0.06 || halfV - abs(v) < 0.06
                if border { return scale(colour2, 0.9 + 0.1 * ScenePaint.noise(u * 500, v * 500, seed)) }
                let weave = 0.85 + 0.15 * ScenePaint.noise(u * 700, v * 700, seed + 3)
                let motif = (Int(((u + 4) / 0.12).rounded(.down)) + Int(((v + 4) / 0.12).rounded(.down))) % 2 == 0 ? 1.0 : 0.82
                return scale(colour, weave * motif)
            case .tiles:
                // slab-sized tiles (0.17 m) with dark grout; each tile its own colour from a few floor-tile shades
                let s = 0.17
                let iu = Int(((u + 50) / s).rounded(.down)), iv = Int(((v + 50) / s).rounded(.down))
                let fu = (u + 50) / s - Double(iu), fv = (v + 50) / s - Double(iv)
                if fu < 0.05 || fv < 0.05 { return (70, 68, 64) }
                let palette: [RGB] = [(178, 96, 70), (205, 190, 160), (140, 140, 135), (95, 120, 150), (210, 210, 200), (120, 90, 60), (160, 175, 120)]
                let pick = Int(ScenePaint.hash(iu, iv, seed) * Double(palette.count)) % palette.count
                let shade = 0.85 + 0.3 * ScenePaint.hash(iv, iu, seed + 9)
                return scale(palette[pick], shade * (0.95 + 0.05 * ScenePaint.noise(u * 400, v * 400, seed + 4)))
            }
        }
    }

    /// The floor's visible extent (x, z bounds), from rays through a grid of the picture's points, at most `reach` away.
    static func visibleFloor(_ view: CameraView, reach: Double = 5) -> (x0: Double, x1: Double, z0: Double, z1: Double)? {
        let K = view.intrinsics, o = view.position, R = view.worldFromCamera.rotation
        var x0 = Double.infinity, x1 = -Double.infinity, z0 = Double.infinity, z1 = -Double.infinity
        for j in 0...8 {
            for i in 0...8 {
                let q = Vec2(Double(K.width) * Double(i) / 8, Double(K.height) * Double(j) / 8)
                let d = R * K.ray(q)
                guard d.y < -1e-6 else { continue }
                var t = -o.y / d.y
                let dl = d.length
                if t * dl > reach { t = reach / dl }
                let p = o + d * t
                x0 = min(x0, p.x); x1 = max(x1, p.x); z0 = min(z0, p.z); z1 = max(z1, p.z)
            }
        }
        return x0 < x1 && z0 < z1 ? (x0, x1, z0, z1) : nil
    }

    /// Paints floor clutter (`dense` false: about 40 objects of every kind; true: a floor of slab-sized tiles, built to
    /// make the slab search grow as many regions as it may) into a render of `view`.
    static func floor(_ rgb: inout [UInt8], view: CameraView, scene: SyntheticScene, slabInView: Bool, dense: Bool, seed: UInt64,
                      count: Int = 40, keepScale: Double = 1.8) {
        guard let b = visibleFloor(view) else { return }
        var rng = BenchRandom(seed)
        var patches: [Patch] = []
        func uni(_ a: Double, _ c: Double) -> Double { a + (c - a) * rng.uniform() }
        let s = scene.slab, keep = max(s.halfU, s.halfV) * keepScale + 0.04
        func clearOfSlab(_ x: Double, _ z: Double, _ r: Double) -> Bool {
            !slabInView || ((x - s.center.x) * (x - s.center.x) + (z - s.center.z) * (z - s.center.z)).squareRoot() > keep + r * 0.6
        }
        if dense {
            let a = Units.radians(20)
            patches.append(Patch(cx: (b.x0 + b.x1) / 2, cz: (b.z0 + b.z1) / 2, cosA: cos(a), sinA: sin(a), halfU: 50, halfV: 50, style: .tiles,
                                 colour: (0, 0, 0), colour2: (0, 0, 0), seed: Int(truncatingIfNeeded: rng.next() & 0xFFFF)))
        } else {
            var tries = 0
            while patches.count < count && tries < 10 * count {
                tries += 1
                let kind = rng.uniform()
                let style: Patch.Style, hu: Double, hv: Double, c1: RGB, c2: RGB
                let hue = rng.uniform()
                if kind < 0.25 {
                    // slab-sized squares and boxes, plain or speckled, any colour
                    style = rng.uniform() < 0.5 ? .plain : .speckle
                    hu = uni(0.06, 0.14); hv = hu * uni(0.7, 1.4)
                    c1 = hsv(hue, uni(0.15, 0.7), uni(0.35, 0.9)); c2 = hsv(rng.uniform(), uni(0.1, 0.5), uni(0.2, 0.95))
                } else if kind < 0.45 {
                    style = .wood
                    hu = uni(0.05, 0.1); hv = uni(0.3, 0.7)
                    let v0 = uni(0.45, 0.75)
                    c1 = hsv(uni(0.05, 0.1), uni(0.45, 0.65), v0); c2 = hsv(uni(0.05, 0.09), uni(0.5, 0.75), v0 * 0.7)
                } else if kind < 0.6 {
                    style = .rug
                    hu = uni(0.3, 0.6); hv = hu * uni(0.6, 1.5)
                    c1 = hsv(hue, uni(0.3, 0.7), uni(0.35, 0.75)); c2 = hsv(rng.uniform(), uni(0.2, 0.6), uni(0.2, 0.8))
                } else if kind < 0.8 {
                    // shoes and other small things, dark or bright
                    style = .plain
                    hu = uni(0.04, 0.06); hv = uni(0.11, 0.15)
                    c1 = rng.uniform() < 0.5 ? hsv(hue, uni(0, 0.3), uni(0.12, 0.3)) : hsv(hue, uni(0.2, 0.8), uni(0.6, 0.95)); c2 = c1
                } else {
                    // papers and books
                    style = rng.uniform() < 0.6 ? .plain : .speckle
                    hu = uni(0.1, 0.12); hv = uni(0.14, 0.16)
                    c1 = rng.uniform() < 0.6 ? (238, 236, 228) : hsv(hue, uni(0.3, 0.7), uni(0.4, 0.8)); c2 = (60, 60, 60)
                }
                let x = uni(b.x0, b.x1), z = uni(b.z0, b.z1), r = (hu * hu + hv * hv).squareRoot()
                guard clearOfSlab(x, z, r) else { continue }
                let a = uni(0, .pi)
                patches.append(Patch(cx: x, cz: z, cosA: cos(a), sinA: sin(a), halfU: hu, halfV: hv, style: style, colour: c1, colour2: c2,
                                     seed: Int(truncatingIfNeeded: rng.next() & 0xFFFF)))
            }
            // the big ones under the small ones
            patches.sort { $0.halfU * $0.halfV > $1.halfU * $1.halfV }
        }
        paint(&rgb, view: view, scene: scene, patches: patches, keepAround: slabInView ? (s.center.x, s.center.z, keep) : nil)
    }

    static func paint(_ rgb: inout [UInt8], view: CameraView, scene: SyntheticScene, patches: [Patch], keepAround: (Double, Double, Double)?) {
        let K = view.intrinsics, W = K.width, H = K.height, o = view.position, R = view.worldFromCamera.rotation
        // the ball's picture (left alone)
        var ballPx: (Vec2, Double)? = nil
        if let bc = scene.ball, let p = view.project(world: bc) {
            let z = view.toCamera(bc).z
            if z > 0 { ballPx = (p, K.fx * scene.ballRadius / z + 3) }
        }
        let sub: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        @inline(__always) func floorPoint(_ q: Vec2) -> (Double, Double)? {
            if let (bp, br) = ballPx, q.distance(to: bp) <= br { return nil }
            let d = R * K.ray(q)
            guard d.y < -1e-6 else { return nil }
            let t = -o.y / d.y
            let x = o.x + d.x * t, z = o.z + d.z * t
            if let (kx, kz, kr) = keepAround, ((x - kx) * (x - kx) + (z - kz) * (z - kz)).squareRoot() <= kr { return nil }
            return (x, z)
        }
        var ids = [UInt8](repeating: 255, count: W * H * 4)
        for (pi, p) in patches.enumerated() {
            // the patch's picture: its corners projected (the whole picture if one is behind the camera)
            var x0 = 0, x1 = W - 1, y0 = 0, y1 = H - 1
            let cs = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { (su, sv) -> Vec3 in
                let u = su * p.halfU, v = sv * p.halfV
                return Vec3(p.cx + u * p.cosA - v * p.sinA, 0, p.cz + u * p.sinA + v * p.cosA)
            }
            let qs = cs.compactMap { c -> Vec2? in view.toCamera(c).z > 0.01 ? view.project(world: c) : nil }
            if qs.count == 4 {
                x0 = max(0, Int(qs.map(\.x).min()!.rounded(.down)) - 1); x1 = min(W - 1, Int(qs.map(\.x).max()!.rounded(.up)) + 1)
                y0 = max(0, Int(qs.map(\.y).min()!.rounded(.down)) - 1); y1 = min(H - 1, Int(qs.map(\.y).max()!.rounded(.up)) + 1)
                if x0 > x1 || y0 > y1 { continue }
            }
            for y in y0...y1 {
                for x in x0...x1 {
                    for (si, s) in sub.enumerated() {
                        guard let (fx, fz) = floorPoint(Vec2(Double(x) + s.0, Double(y) + s.1)), p.contains(fx, fz) else { continue }
                        ids[(y * W + x) * 4 + si] = UInt8(pi)
                    }
                }
            }
        }
        // composite: each pixel the mean of its four samples (a patch's colour, or the render's)
        var painted = [Bool](repeating: false, count: W * H)
        for i in 0..<(W * H) where ids[i * 4] != 255 || ids[i * 4 + 1] != 255 || ids[i * 4 + 2] != 255 || ids[i * 4 + 3] != 255 {
            painted[i] = true
            let x = i % W, y = i / W
            var r = 0.0, g = 0.0, bb = 0.0
            for (si, s) in sub.enumerated() {
                let id = ids[i * 4 + si]
                if id != 255, let (fx, fz) = floorPoint(Vec2(Double(x) + s.0, Double(y) + s.1)) {
                    let c = patches[Int(id)].colourAt(fx, fz)
                    r += c.0; g += c.1; bb += c.2
                } else {
                    r += Double(rgb[i * 3]); g += Double(rgb[i * 3 + 1]); bb += Double(rgb[i * 3 + 2])
                }
            }
            rgb[i * 3] = UInt8(max(0, min(255, (r / 4).rounded())))
            rgb[i * 3 + 1] = UInt8(max(0, min(255, (g / 4).rounded())))
            rgb[i * 3 + 2] = UInt8(max(0, min(255, (bb / 4).rounded())))
        }
        soften(&rgb, W, H, where: painted)
    }

    /// The render's [1 2 1] x [1 2 1] softening, on the painted pixels and the ring around them.
    static func soften(_ img: inout [UInt8], _ W: Int, _ H: Int, where mask: [Bool]) {
        var near = [Bool](repeating: false, count: W * H)
        for y in 0..<H {
            for x in 0..<W where mask[y * W + x] {
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < W, yy < H { near[yy * W + xx] = true }
                } }
            }
        }
        let src = img
        for y in 0..<H {
            for x in 0..<W where near[y * W + x] {
                for c in 0..<3 {
                    var v = 0
                    for dy in -1...1 {
                        let yy = min(H - 1, max(0, y + dy)), wy = dy == 0 ? 2 : 1
                        for dx in -1...1 {
                            let xx = min(W - 1, max(0, x + dx)), wx = dx == 0 ? 2 : 1
                            v += wy * wx * Int(src[(yy * W + xx) * 3 + c])
                        }
                    }
                    img[(y * W + x) * 3 + c] = UInt8((v + 8) / 16)
                }
            }
        }
    }

    // MARK: a hand over a corner

    /// A hand reaching in from the bottom of the picture over the slab's nearest corner and the first part of one side
    /// (the palm an ellipse, the forearm a band to the picture's edge), in skin tones with soft shading; the ball is left
    /// in view.
    static func hand(_ rgb: inout [UInt8], view: CameraView, scene: SyntheticScene) {
        guard let q = scene.corners(in: view) else { return }
        let K = view.intrinsics, W = K.width, H = K.height
        let i = q.indices.max { q[$0].y < q[$1].y }!
        let a = q[i], n1 = q[(i + 1) % 4], n3 = q[(i + 3) % 4]
        let b = a.distance(to: n1) >= a.distance(to: n3) ? n1 : n3
        let side = a.distance(to: b), u = (b - a) / side, v = u.perpendicular
        let centroid = q.reduce(Vec2(0, 0)) { $0 + $1 } / 4
        let c = a + u * (0.2 * side) + (a - centroid).normalized * (0.05 * side)
        let ra = 0.45 * side, rb = 0.27 * side
        let armDir = (Vec2(0, 1) * 0.7 + (a - centroid).normalized * 0.3).normalized, armPerp = armDir.perpendicular
        let armHalf = 0.21 * side
        var ballPx: (Vec2, Double)? = nil
        if let bc = scene.ball, let p = view.project(world: bc) {
            let z = view.toCamera(bc).z
            if z > 0 { ballPx = (p, K.fx * scene.ballRadius / z + 2) }
        }
        let skin: RGB = (200, 152, 124)
        // nil: not the hand; else its shade
        func shade(_ p: Vec2) -> Double? {
            if let (bp, br) = ballPx, p.distance(to: bp) <= br { return nil }
            let d = p - c
            let e = (d.dot(u) / ra) * (d.dot(u) / ra) + (d.dot(v) / rb) * (d.dot(v) / rb)
            if e <= 1 { return 0.78 + 0.22 * (1 - e) }
            let al = d.dot(armDir), ac = d.dot(armPerp)
            if al >= 0 && abs(ac) <= armHalf { return 0.8 + 0.15 * (1 - (ac / armHalf) * (ac / armHalf)) }
            return nil
        }
        let reach = ra + rb
        let far = c + armDir * Double(W + H)
        let x0 = max(0, Int(min(c.x - reach, far.x - armHalf).rounded(.down))), x1 = min(W - 1, Int(max(c.x + reach, far.x + armHalf).rounded(.up)))
        let y0 = max(0, Int(min(c.y - reach, far.y - armHalf).rounded(.down))), y1 = min(H - 1, Int(max(c.y + reach, far.y + armHalf).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let sub: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        var painted = [Bool](repeating: false, count: W * H)
        for y in y0...y1 {
            for x in x0...x1 {
                var r = 0.0, g = 0.0, bb = 0.0, hit = 0
                let i = y * W + x
                for s in sub {
                    if let k = shade(Vec2(Double(x) + s.0, Double(y) + s.1)) {
                        let t = 0.97 + 0.03 * noise(Double(x) * 0.3, Double(y) * 0.3, 77)
                        r += skin.0 * k * t; g += skin.1 * k * t; bb += skin.2 * k * t; hit += 1
                    } else {
                        r += Double(rgb[i * 3]); g += Double(rgb[i * 3 + 1]); bb += Double(rgb[i * 3 + 2])
                    }
                }
                guard hit > 0 else { continue }
                painted[i] = true
                rgb[i * 3] = UInt8(max(0, min(255, (r / 4).rounded())))
                rgb[i * 3 + 1] = UInt8(max(0, min(255, (g / 4).rounded())))
                rgb[i * 3 + 2] = UInt8(max(0, min(255, (bb / 4).rounded())))
            }
        }
        soften(&rgb, W, H, where: painted)
    }
}
