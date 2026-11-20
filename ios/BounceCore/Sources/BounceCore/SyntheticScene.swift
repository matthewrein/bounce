import Foundation

/// A synthetic camera view of the slab on its black base, rendered by ray casting in plain Swift: a floor like a
/// cutting mat, a dark base under the slab, the slab as a box (grey top, lighter cut faces, 1 in thick; with a side
/// profile in the spec, sloped faces and a rounded edge down to the base, `SlabSpec`) and optionally a polished ball. The
/// app's demo mode and end-to-end UI tests run it through the same tracker as the camera, with the truth known exactly.
/// (Detector quality is measured on the web test bed's three.js renders, not on this.)
public struct SyntheticScene {
    public var spec: SlabSpec
    /// the slab's top-corner plane in world coordinates (y up, metres; the floor is y = 0)
    public var slab: SlabPose
    /// a held ball's centre (world), if any
    public var ball: Vec3?
    public var ballRadius: Double = 0.0175
    /// How the ball is drawn: the owner's open titanium lattice (`LatticeBall`, the default), or a polished solid sphere
    /// reflecting the sky and the floor (what the renders showed before the owner said what the ball is, until n14; the
    /// lattice finder's kill-switch test, `LatticeKillSwitchTests`, draws it to check that with
    /// `BallFinder.Options.lattice` off the finder finds what n14 found).
    public enum BallLook: Equatable { case lattice, polished }
    public var ballLook: BallLook = .lattice
    /// light direction (toward the light), world
    public var light = Vec3(0.3, 1, 0.4).normalized
    /// supersampling per axis (2 gives smooth edges)
    public var supersample = 2

    public init(spec: SlabSpec = .standard, slab: SlabPose, ball: Vec3? = nil) {
        self.spec = spec; self.slab = slab; self.ball = ball
    }

    /// A slab resting with its top centre `height` above the floor at (x, z), tilted `tilt` degrees toward `heading`
    /// (degrees from +x toward +z), turned `yaw` degrees about the vertical.
    public static func slabPose(x: Double = 0, z: Double = 0, height: Double = Units.inches(2.6), tilt: Double, heading: Double,
                                yaw: Double = 15, spec: SlabSpec = .standard) -> SlabPose {
        let th = Units.radians(tilt), hd = Units.radians(heading), yw = Units.radians(yaw)
        let n = Vec3(sin(th) * cos(hd), cos(th), sin(th) * sin(hd))
        let u = Vec3(cos(yw), 0, sin(yw)).rejecting(n).normalized
        return SlabPose(center: Vec3(x, height, z), normal: n, axisU: u, axisV: n.cross(u), halfU: spec.halfU, halfV: spec.halfV)
    }

    /// A camera at `position` looking at `target`, in BounceCore's CV axes, for an image of the given intrinsics.
    public static func camera(at position: Vec3, lookingAt target: Vec3, intrinsics: CameraIntrinsics, roll: Double = 0) -> CameraView {
        let fwd = (target - position).normalized
        var right = fwd.cross(Vec3(0, 1, 0)).normalized
        if roll != 0 { right = right.rotated(by: fwd * Units.radians(roll)) }
        let down = fwd.cross(right)
        return CameraView(worldFromCamera: RigidTransform(rotation: Mat3(columns: right, down, fwd), translation: position), intrinsics: intrinsics)
    }

    /// The four true top corners seen from a view (pixels).
    public func corners(in view: CameraView) -> [Vec2]? {
        let q = slab.topCorners.compactMap { view.project(world: $0) }
        return q.count == 4 ? q : nil
    }

    // MARK: rendering

    @inline(__always) static func hash(_ x: Int, _ y: Int, _ s: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 73856093 ^ y &* 19349663 ^ s &* 83492791))
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33; h = h &* 0xc4ceb3fe1a85ec53; h ^= h >> 33
        return Double(h & 0xFFFF) / 65535
    }
    /// value noise in [0, 1] at (a, b) with cell size 1
    @inline(__always) static func noise(_ a: Double, _ b: Double, _ s: Int) -> Double {
        let ia = Int(floor(a)), ib = Int(floor(b)), fa = a - floor(a), fb = b - floor(b)
        let ua = fa * fa * (3 - 2 * fa), ub = fb * fb * (3 - 2 * fb)
        let v00 = hash(ia, ib, s), v10 = hash(ia + 1, ib, s), v01 = hash(ia, ib + 1, s), v11 = hash(ia + 1, ib + 1, s)
        return (v00 * (1 - ua) + v10 * ua) * (1 - ub) + (v01 * (1 - ua) + v11 * ua) * ub
    }

    func shadeLambert(_ n: Vec3) -> Double { 0.55 + 0.45 * max(0, n.dot(light)) }

    /// Geometry worked out once per frame, so tracing a ray allocates nothing.
    struct Prepared {
        var c0: Vec3, n: Vec3, T: Double
        var sides: [(a: Vec3, eu: Vec3, len: Double, out: Vec3)]
        var ctr: Vec3, au: Vec3, av: Vec3, hu: Double, hv: Double, baseTop: Double
        /// the side profile (`SlabSpec`), when the spec has one: the cross-section, the face's normal in (x, z), the near
        /// feature angle
        var profile: SideSection? = nil
        var psiN: Double = 0
    }

    func prepare() -> Prepared {
        let c = slab.topCorners, n = slab.normal
        var sides: [(a: Vec3, eu: Vec3, len: Double, out: Vec3)] = []
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4], e = b - a, len = e.length, eu = e / len
            let out = eu.cross(n).dot((a + b) / 2 - slab.center) > 0 ? eu.cross(n) : n.cross(eu)
            sides.append((a, eu, len, out))
        }
        let au = Vec3(slab.axisU.x, 0, slab.axisU.z).normalized
        guard spec.hasProfile else {
            return Prepared(c0: c[0], n: n, T: spec.thickness, sides: sides, ctr: Vec3(slab.center.x, 0, slab.center.z), au: au,
                            av: Vec3(-au.z, 0, au.x), hu: slab.halfU * 1.05, hv: slab.halfV * 1.05,
                            baseTop: c.map { ($0 - n * spec.thickness).y }.min()! - 0.002)
        }
        // with a side profile the base (the cradle) begins at the bottom of the visible faces, a little wider than they reach
        let sec = SideSection(spec: spec), R = spec.sideRun
        let bottoms = (0..<4).map { k in c[k] - n * sec.drop + (sides[(k + 3) % 4].out + sides[k].out) * R }
        return Prepared(c0: c[0], n: n, T: sec.drop, sides: sides, ctr: Vec3(slab.center.x, 0, slab.center.z), au: au,
                        av: Vec3(-au.z, 0, au.x), hu: (slab.halfU + R) * 1.05, hv: (slab.halfV + R) * 1.05,
                        baseTop: bottoms.map { $0.y }.min()! - 0.002, profile: sec, psiN: clamp(spec.nearFeatureAngle, 0, sec.faceAngle))
    }

    /// The nearest hit on a side's profile (`SlabSpec`: the rounded edge, then the planar face down to the bottom of the
    /// visible band) beyond 1e-4 and before `limit`: its distance and colour. The rounding before the near feature angle has
    /// the top's finish and the rest the face's, so a refiner's departure lies where the spec says; each point of it is
    /// shaded by its own normal (a hidden face's rounding, its normal near the top's, shows as a light lip).
    func traceProfileSide(_ o: Vec3, _ d: Vec3, _ sd: (a: Vec3, eu: Vec3, len: Double, out: Vec3), _ g: Prepared, _ sec: SideSection,
                          limit: Double) -> (Double, (Double, Double, Double))? {
        let n = g.n
        var best: (Double, (Double, Double, Double))? = nil
        let fnx = sin(sec.faceAngle), fnz = cos(sec.faceAngle), fn = sd.out * fnx + n * fnz
        func faceColour(_ along: Double, _ down: Double, normal: Vec3? = nil) -> (Double, Double, Double) {
            let gg = 0.66 + 0.1 * (SyntheticScene.noise(along * 1500, down * 1500, 3) - 0.5)
            let sh = gg * shadeLambert(normal ?? fn)
            return (sh, sh * 0.99, sh * 0.96)
        }
        // the planar face
        let e = sec.arcEnd
        let dn = d.dot(fn)
        if abs(dn) > 1e-9 {
            let t = (sd.a + sd.out * e.x + n * e.z - o).dot(fn) / dn
            if t > 1e-4 && t < limit {
                let rel = o + d * t - sd.a, along = rel.dot(sd.eu), x = rel.dot(sd.out), z = rel.dot(n)
                if z <= e.z + 1e-12 && z >= -sec.drop && along >= -max(0, x) && along <= sd.len + max(0, x) {
                    best = (t, faceColour(along, -z))
                }
            }
        }
        // the rounded edge: a cylinder of radius r about the line r below the edge
        if sec.radius > 0 {
            let r = sec.radius, a0 = sd.a - n * r
            let w = o - a0, wp = w - sd.eu * w.dot(sd.eu), dp = d - sd.eu * d.dot(sd.eu)
            let A = dp.dot(dp), B = 2 * wp.dot(dp), C = wp.dot(wp) - r * r, disc = B * B - 4 * A * C
            if A > 1e-12 && disc >= 0 {
                let sq = disc.squareRoot()
                for t in [(-B - sq) / (2 * A), (-B + sq) / (2 * A)] where t > 1e-4 && t < min(limit, best?.0 ?? .infinity) {
                    let p = o + d * t, rel = p - a0, q = rel - sd.eu * rel.dot(sd.eu)
                    let psi = atan2(q.dot(sd.out), q.dot(n))
                    let x = r * sin(psi), along = (p - sd.a).dot(sd.eu)
                    guard psi >= 0 && psi <= sec.faceAngle && along >= -x && along <= sd.len + x else { continue }
                    let an = sd.out * sin(psi) + n * cos(psi)
                    if psi < g.psiN {
                        let rr = p - slab.center, u = clamp(rr.dot(slab.axisU), -slab.halfU, slab.halfU), v = clamp(rr.dot(slab.axisV), -slab.halfV, slab.halfV)
                        let gg = 0.5 + 0.08 * (SyntheticScene.noise(u * 900, v * 900, 1) - 0.5) + 0.05 * (SyntheticScene.noise(u * 60, v * 60, 2) - 0.5)
                        let sh = gg * shadeLambert(an)
                        best = (t, (sh * 0.98, sh, sh * 0.99))
                    } else {
                        best = (t, faceColour(along, -q.dot(n) - r, normal: an))
                    }
                    break
                }
            }
        }
        return best
    }

    /// Nearest surface along a world ray.
    func trace(_ o: Vec3, _ d: Vec3, _ g: Prepared) -> (Double, Double, Double) {
        var bestT = Double.infinity
        var rgb = (0.55, 0.62, 0.58)
        let n = g.n
        // ball
        if let b = ball, ballLook == .lattice {
            if case let .solid(t, c)? = LatticeBall(radius: ballRadius).trace(o, d, center: b, light: light), t < bestT { bestT = t; rgb = c }
        } else if let b = ball {
            let oc = o - b, bb = oc.dot(d), cc = oc.lengthSquared - ballRadius * ballRadius, disc = bb * bb - cc
            if disc > 0 {
                let t = -bb - disc.squareRoot()
                if t > 1e-4 && t < bestT {
                    let p = o + d * t, nn = (p - b).normalized
                    // polished metal: reflects a bright sky above and the dark floor below, with a highlight
                    let r = d - nn * (2 * d.dot(nn))
                    let sky = r.y > 0 ? 0.55 + 0.4 * r.y : 0.25 + 0.15 * (1 + r.y)
                    let v = min(1, sky + pow(max(0, r.dot(light)), 40))
                    bestT = t; rgb = (v * 0.97, v * 0.96, v * 0.94)
                }
            }
        }
        // slab top (the corner plane; the 3 mm dish does not show at this scale)
        let den = d.dot(n)
        if abs(den) > 1e-9 {
            let t = (slab.center - o).dot(n) / den
            if t > 1e-4 && t < bestT {
                let p = o + d * t, rel = p - slab.center, u = rel.dot(slab.axisU), v = rel.dot(slab.axisV)
                if abs(u) <= slab.halfU && abs(v) <= slab.halfV {
                    let gg = 0.5 + 0.08 * (SyntheticScene.noise(u * 900, v * 900, 1) - 0.5) + 0.05 * (SyntheticScene.noise(u * 60, v * 60, 2) - 0.5)
                    let sh = gg * shadeLambert(n)
                    bestT = t; rgb = (sh * 0.98, sh, sh * 0.99)
                }
            }
        }
        // the four cut faces (with a side profile: each side's rounded edge and sloped face)
        if let sec = g.profile {
            for sd in g.sides {
                if let h = traceProfileSide(o, d, sd, g, sec, limit: bestT) { bestT = h.0; rgb = h.1 }
            }
        } else {
            for sd in g.sides {
                let dn = d.dot(sd.out)
                guard abs(dn) > 1e-9 else { continue }
                let t = (sd.a - o).dot(sd.out) / dn
                guard t > 1e-4 && t < bestT else { continue }
                let rel = o + d * t - sd.a, along = rel.dot(sd.eu), down = -rel.dot(n)
                if along >= 0 && along <= sd.len && down >= 0 && down <= g.T {
                    let gg = 0.66 + 0.1 * (SyntheticScene.noise(along * 1500, down * 1500, 3) - 0.5)
                    let sh = gg * shadeLambert(sd.out)
                    bestT = t; rgb = (sh, sh * 0.99, sh * 0.96)
                }
            }
        }
        // the black base: a box from the floor up to just under the slab, about the slab's footprint, slab-aligned
        if g.baseTop > 0.005 {
            let rel = o - g.ctr
            let lo = (rel.dot(g.au), o.y, rel.dot(g.av)), ld = (d.dot(g.au), d.y, d.dot(g.av))
            var tmin = 1e-4, tmax = bestT, axis = -1, sgnHit = 0.0, ok = true
            func slabTest(_ oo: Double, _ dd: Double, _ mn: Double, _ mx: Double, _ k: Int) {
                guard ok else { return }
                if abs(dd) < 1e-12 { if oo < mn || oo > mx { ok = false }; return }
                var t1 = (mn - oo) / dd, t2 = (mx - oo) / dd, sg = -1.0
                if t1 > t2 { swap(&t1, &t2); sg = 1 }
                if t1 > tmin { tmin = t1; axis = k; sgnHit = sg }
                tmax = min(tmax, t2)
                if tmin > tmax { ok = false }
            }
            slabTest(lo.0, ld.0, -g.hu, g.hu, 0); slabTest(lo.1, ld.1, 0, g.baseTop, 1); slabTest(lo.2, ld.2, -g.hv, g.hv, 2)
            if ok && axis >= 0 && tmin < bestT {
                let nrm = (axis == 0 ? g.au : axis == 1 ? Vec3(0, 1, 0) : g.av) * sgnHit
                let p = o + d * tmin
                let gg = 0.07 + 0.02 * SyntheticScene.noise(p.x * 400, (p.y + p.z) * 400, 4)
                let sh = gg * shadeLambert(nrm)
                bestT = tmin; rgb = (sh, sh, sh * 1.05)
            }
        }
        // the floor: a grey-green cutting mat with a grid, and the slab's soft shadow next to the base
        if d.y < -1e-9 {
            let t = -o.y / d.y
            if t > 1e-4 && t < bestT {
                let p = o + d * t
                let fx = p.x / 0.0254, fz = p.z / 0.0254
                let line = (abs(fx - fx.rounded()) < 0.03 || abs(fz - fz.rounded()) < 0.03) ? 0.82 : 1.0
                var gg = (0.42 + 0.06 * (SyntheticScene.noise(p.x * 300, p.z * 300, 5) - 0.5)) * line
                let dx = p.x - slab.center.x, dz = p.z - slab.center.z, sh = (dx * dx + dz * dz).squareRoot()
                if sh < slab.halfU * 1.6 { gg *= 0.75 + 0.25 * min(1, max(0, (sh - slab.halfU * 1.05) / (slab.halfU * 0.55))) }
                rgb = (gg * 0.92, gg, gg * 0.95)
            }
        }
        return rgb
    }

    /// Render the view: an 8-bit RGB image (row-major, 3 bytes a pixel) at the view's intrinsics' size.
    public func renderRGB(view: CameraView) -> [UInt8] {
        let K = view.intrinsics, W = K.width, H = K.height, ss = max(1, supersample)
        var out = [UInt8](repeating: 0, count: W * H * 3)
        let o = view.position, R = view.worldFromCamera.rotation
        let inv = 1 / Double(ss * ss), geo = prepare()
        for y in 0..<H {
            for x in 0..<W {
                var r = 0.0, g = 0.0, b = 0.0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let q = Vec2(Double(x) + (Double(sx) + 0.5) / Double(ss), Double(y) + (Double(sy) + 0.5) / Double(ss))
                        let d = (R * K.ray(q)).normalized
                        let c = trace(o, d, geo)
                        r += c.0; g += c.1; b += c.2
                    }
                }
                let i = (y * W + x) * 3
                // a gentle gamma so mid-greys land where a phone puts them
                out[i] = UInt8(clamp(pow(r * inv, 1 / 1.6) * 255, 0, 255))
                out[i + 1] = UInt8(clamp(pow(g * inv, 1 / 1.6) * 255, 0, 255))
                out[i + 2] = UInt8(clamp(pow(b * inv, 1 / 1.6) * 255, 0, 255))
            }
        }
        if ss == 1 { SyntheticScene.soften(&out, W, H) }
        return out
    }

    /// A [1 2 1] x [1 2 1] blur: soft edges like a camera's, for single-sample renders.
    static func soften(_ img: inout [UInt8], _ W: Int, _ H: Int) {
        var tmp = [UInt16](repeating: 0, count: img.count)
        for y in 0..<H { for x in 0..<W { for c in 0..<3 {
            let l = max(0, x - 1), r = min(W - 1, x + 1)
            tmp[(y * W + x) * 3 + c] = UInt16(img[(y * W + l) * 3 + c]) + 2 * UInt16(img[(y * W + x) * 3 + c]) + UInt16(img[(y * W + r) * 3 + c])
        } } }
        for y in 0..<H { for x in 0..<W { for c in 0..<3 {
            let u = max(0, y - 1), d = min(H - 1, y + 1)
            let v = UInt32(tmp[(u * W + x) * 3 + c]) + 2 * UInt32(tmp[(y * W + x) * 3 + c]) + UInt32(tmp[(d * W + x) * 3 + c])
            img[(y * W + x) * 3 + c] = UInt8((v + 8) / 16)
        } } }
    }

    /// RGB -> YCbCr 4:2:0 (full range, BT.601), as the camera delivers.
    public static func ycc(rgb: [UInt8], width W: Int, height H: Int) -> YCCImage {
        let cw = (W + 1) / 2, ch = (H + 1) / 2
        var y = [UInt8](repeating: 0, count: W * H), cb = [UInt8](repeating: 128, count: cw * ch), cr = cb
        for i in 0..<(W * H) {
            y[i] = UInt8(clamp((0.299 * Double(rgb[i * 3]) + 0.587 * Double(rgb[i * 3 + 1]) + 0.114 * Double(rgb[i * 3 + 2])).rounded(), 0, 255))
        }
        for yy in 0..<ch {
            for xx in 0..<cw {
                var R = 0.0, G = 0.0, B = 0.0, n = 0.0
                for dy in 0..<2 { for dx in 0..<2 {
                    let X = xx * 2 + dx, Y = yy * 2 + dy
                    if X >= W || Y >= H { continue }
                    let j = (Y * W + X) * 3
                    R += Double(rgb[j]); G += Double(rgb[j + 1]); B += Double(rgb[j + 2]); n += 1
                } }
                R /= n; G /= n; B /= n
                let L = 0.299 * R + 0.587 * G + 0.114 * B
                cb[yy * cw + xx] = UInt8(clamp((128 + (B - L) * 0.564).rounded(), 0, 255))
                cr[yy * cw + xx] = UInt8(clamp((128 + (R - L) * 0.713).rounded(), 0, 255))
            }
        }
        return YCCImage(width: W, height: H, y: y, cb: cb, cr: cr)
    }
}

/// The demo: a camera drifting slowly around the slab, an optional held ball, and an optional slide of the slab to a new
/// tilt part-way through. Deterministic in time, so UI tests can check what the app shows against the truth.
public struct DemoScript: Equatable {
    public var tilt: Double = 8
    public var heading: Double = 35
    /// height of a held ball's centre above the slab's top centre (m); 0 for no ball
    public var ballHeight: Double = 0
    /// slide the slab to this tilt at `slideAt` seconds (nil: never)
    public var slideTo: Double? = nil
    public var slideAt: Double = 8
    public var distance: Double = 0.85
    public var elevation: Double = 48
    /// move the camera to this elevation (degrees) over `elevationRamp` seconds from `elevationAt` (nil: never): a phone
    /// held steeply over the slab, then lowered
    public var elevationTo: Double? = nil
    public var elevationAt: Double = 5
    public var elevationRamp: Double = 1.5
    public var width = 360
    public var height = 480
    public var verticalFov = 62.0
    public init() {}

    public var intrinsics: CameraIntrinsics { CameraIntrinsics(verticalFovDegrees: verticalFov, width: width, height: height) }

    public func tiltAt(_ t: Double) -> Double { (slideTo != nil && t >= slideAt) ? slideTo! : tilt }

    /// The scene at time t, with this slab and ball (the app's demo renders the app's own: `AppSettings.slab`, `.ball`).
    public func scene(at t: Double, spec: SlabSpec = .standard, ball: BallSpec = BallSpec()) -> SyntheticScene {
        let tilt = tiltAt(t)
        // sliding the slab in its cradle moves its centre: about 0.27 in per degree (owner's numbers: 3 in for 10 deg)
        let shift = Units.inches(0.27 * tilt)
        let hd = Units.radians(heading)
        let pose = SyntheticScene.slabPose(x: -shift * cos(hd), z: -shift * sin(hd), tilt: tilt, heading: heading, spec: spec)
        var s = SyntheticScene(spec: spec, slab: pose)
        s.supersample = 1
        s.ballRadius = ball.radius
        if ballHeight > 0 { s.ball = pose.center + Vec3(0.012, ballHeight, -0.01) }
        return s
    }

    /// the camera's mean elevation at time t (degrees)
    public func meanElevation(at t: Double) -> Double {
        guard let to = elevationTo else { return elevation }
        let f = clamp((t - elevationAt) / max(elevationRamp, 1e-6), 0, 1)
        return elevation + (to - elevation) * f
    }

    public func view(at t: Double) -> CameraView {
        let az = Units.radians(20 * sin(t * 2 * .pi / 14)), el = Units.radians(meanElevation(at: t) + 4 * sin(t * 2 * .pi / 9))
        let pos = Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * distance + Vec3(0.01 * sin(t * 3.1), 0.008 * sin(t * 2.3), 0)
        return SyntheticScene.camera(at: pos, lookingAt: Vec3(0, 0.05, 0), intrinsics: intrinsics, roll: 1.5 * sin(t * 0.7))
    }
}
