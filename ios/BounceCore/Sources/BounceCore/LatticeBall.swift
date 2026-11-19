import Foundation

/// The owner's ball as the renderers draw it: a mildly polished titanium lattice sphere. Its surface is a shell of
/// struts around small holes (a honeycomb of cells about 1.6 mm across, about 19 across the 30 mm ball, as the kits'
/// close-ups show it); through a hole the eye meets the dim inside of the far side of the shell, or, where a hole there
/// lines up, whatever lies behind the ball. The shell has a thickness, so a ray that grazes the rim crosses more of it:
/// the outline is nearly whole but ragged by a hole here and there, and the background shows through near it. The struts
/// are dark grey metal, lit from the scene's light, reflecting a soft sky above and the floor below, with glints where a
/// strut faces the light (each cell's struts lean a little differently).
///
/// The cells are the 3-D Voronoi cells of jittered points on a grid of the cell's size, cut by the sphere; a point of the
/// shell is strut where its two nearest points are nearly equally far (`strut` of the cell apart), hole elsewhere.
public struct LatticeBall: Equatable {
    /// outer radius (m)
    public var radius: Double
    /// hole spacing on the surface (m)
    public var cell = 0.0016
    /// strut width, as a share of the cell
    public var strut = 0.26
    /// the shell's thickness (m)
    public var shell = 0.0012
    /// the pattern's seed (two balls with different seeds have different holes)
    public var seed = 11

    public init(radius: Double, cell: Double = 0.0016, strut: Double = 0.26, shell: Double = 0.0012, seed: Int = 11) {
        self.radius = radius; self.cell = cell; self.strut = strut; self.shell = shell; self.seed = seed
    }

    /// What a ray meets on the ball.
    public enum Hit: Equatable {
        /// the ray stops on the ball this far along, with this colour (linear, 0-1)
        case solid(t: Double, rgb: (Double, Double, Double))
        /// the ray passes through the lattice (holes on both sides) and sees what lies behind
        case through

        public static func == (a: Hit, b: Hit) -> Bool {
            switch (a, b) {
            case let (.solid(t1, c1), .solid(t2, c2)): return t1 == t2 && c1 == c2
            case (.through, .through): return true
            default: return false
            }
        }
    }

    /// Where the 3-D cell pattern puts a point of the shell (`p` relative to the ball's centre, m): whether it is strut,
    /// and a unit vector that is the same all over one cell (each cell's struts lean their own way).
    func pattern(_ p: Vec3) -> (strut: Bool, lean: Vec3) {
        let q = p / cell
        let ix = Int(floor(q.x)), iy = Int(floor(q.y)), iz = Int(floor(q.z))
        var d1 = Double.infinity, d2 = Double.infinity
        var h1 = (0, 0, 0)
        for dz in -1...1 {
            for dy in -1...1 {
                for dx in -1...1 {
                    let cx = ix + dx, cy = iy + dy, cz = iz + dz
                    let fx = Double(cx) + 0.15 + 0.7 * SyntheticScene.hash(cx, cy, cz &* 131 &+ seed)
                    let fy = Double(cy) + 0.15 + 0.7 * SyntheticScene.hash(cy, cz, cx &* 131 &+ seed &+ 1)
                    let fz = Double(cz) + 0.15 + 0.7 * SyntheticScene.hash(cz, cx, cy &* 131 &+ seed &+ 2)
                    let ex = q.x - fx, ey = q.y - fy, ez = q.z - fz
                    let d = (ex * ex + ey * ey + ez * ez).squareRoot()
                    if d < d1 { d2 = d1; d1 = d; h1 = (cx, cy, cz) } else if d < d2 { d2 = d }
                }
            }
        }
        let a = SyntheticScene.hash(h1.0, h1.1, h1.2 &+ seed &+ 7) - 0.5, b = SyntheticScene.hash(h1.1, h1.2, h1.0 &+ seed &+ 8) - 0.5
        let c = SyntheticScene.hash(h1.2, h1.0, h1.1 &+ seed &+ 9) - 0.5
        return (d2 - d1 < strut, Vec3(a, b, c))
    }

    /// The ray from `o` along the unit `d` against the ball centred at `center`. `light`: unit direction toward the light
    /// (world, y up). nil: the ray misses the ball's outer sphere.
    public func trace(_ o: Vec3, _ d: Vec3, center: Vec3, light: Vec3) -> Hit? {
        let R = radius, Ri = max(0, radius - shell)
        let oc = o - center, b = oc.dot(d), c = oc.lengthSquared - R * R, disc = b * b - c
        guard disc > 0 else { return nil }
        let sq = disc.squareRoot(), t0 = -b - sq, t3 = -b + sq
        guard t3 > 1e-4 else { return nil }
        // the inner sphere: where the ray leaves the near shell and enters the far one
        let ci = oc.lengthSquared - Ri * Ri, di = b * b - ci
        // samples of the shell along the ray: its entry and exit of the near shell, and of the far one
        var near: [Double] = [], far: [Double] = []
        if di > 0 {
            let si = di.squareRoot()
            near = [t0, (t0 + (-b - si)) / 2, -b - si]
            far = [-b + si, ((-b + si) + t3) / 2, t3]
        } else {
            // grazing: the ray crosses the shell only, a longer path through it
            for k in 0...6 { near.append(t0 + (t3 - t0) * Double(k) / 6) }
        }
        for t in near where t > 1e-4 {
            let p = o + d * t - center
            let pt = pattern(p * (R / max(1e-9, p.length)))
            if pt.strut { return .solid(t: t, rgb: shade(p, d, lean: pt.lean, light: light, inside: false)) }
        }
        for t in far where t > 1e-4 {
            let p = o + d * t - center
            let pt = pattern(p * (R / max(1e-9, p.length)))
            // the inside of the far side of the shell, seen through a hole
            if pt.strut { return .solid(t: t, rgb: shade(p, d, lean: pt.lean, light: light, inside: true)) }
        }
        return .through
    }

    /// Mildly polished titanium at a strut point `p` (relative to the centre) seen along `d`.
    func shade(_ p: Vec3, _ d: Vec3, lean: Vec3, light: Vec3, inside: Bool) -> (Double, Double, Double) {
        var n = p.normalized
        if inside { n = -n }
        n = (n + lean * 0.5).normalized
        let r = d - n * (2 * d.dot(n))
        // what the polish reflects: a soft sky above, the floor below
        let sky = r.y > 0 ? 0.45 + 0.35 * r.y : 0.22 + 0.1 * (1 + r.y)
        let diffuse = 0.02 + 0.3 * max(0, n.dot(light))
        let spec = 1.0 * pow(max(0, r.dot(light)), 12)
        var v = diffuse + 0.25 * sky + spec
        // the inside is lit only through the holes
        if inside { v *= 0.15 }
        v = min(1, v)
        return (v * 0.96, v * 0.96, v * 0.97)
    }
}
