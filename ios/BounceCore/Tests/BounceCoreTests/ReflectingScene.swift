import Foundation
@testable import BounceCore

/// SyntheticScene's slab, floor and base with two things it does not draw, ray traced: a polished ball that reflects
/// the scene itself (the slab, the floor and the base below the horizon, a room above it; optionally with Fresnel, its
/// edge brighter at a grazing angle), and a shiny round lid lying on the slab with pressed concentric rings (a jar lid,
/// a coaster, a medallion). SyntheticScene's own ball reflects a plain sky and a plain dark floor by direction only.
struct ReflectingScene {
    var scene: SyntheticScene
    let geo: SyntheticScene.Prepared
    /// the ball's centre (world), if there is one
    var ball: Vec3?
    var ballRadius = BallSpec().radius
    var reflectance = 0.6
    var fresnel = false
    /// the lid: its centre (world, on the slab's top), radius (m) and the depth of its rings' shading (0: plain)
    var lid: (center: Vec3, radius: Double, rings: Double)? = nil

    init(slab: SlabPose) {
        scene = SyntheticScene(slab: slab, ball: nil)
        geo = scene.prepare()
    }

    /// A lid of diameter `diameter` lying on the slab, `u` and `v` metres from its centre along its axes.
    mutating func putLid(diameter: Double, u: Double, v: Double, rings: Double) {
        let s = scene.slab
        lid = (s.center + s.axisU * u + s.axisV * v + s.normal * 0.002, diameter / 2, rings)
    }

    /// The room above the horizon: walls darker below 0.3 of the way up, with some light and dark round the walls; a
    /// bright ceiling; the light's highlight.
    func room(_ r: Vec3) -> (Double, Double, Double) {
        var v = r.y < 0.3 ? 0.36 + 0.10 * sin(6 * atan2(r.x, r.z)) : 0.78
        v = min(1, v + pow(max(0, r.dot(scene.light)), 40))
        return (v, v, v)
    }

    /// Everything but the ball along a ray (the lid reflects once).
    func shadeWithoutBall(_ o: Vec3, _ d: Vec3, reflected: Bool) -> (Double, Double, Double) {
        if let lid {
            let n = scene.slab.normal, den = d.dot(n)
            if abs(den) > 1e-9 {
                let t = (lid.center - o).dot(n) / den
                if t > 1e-4 {
                    let p = o + d * t, rr = (p - lid.center).length
                    if rr < lid.radius {
                        let r = d - n * (2 * d.dot(n))
                        let c = reflected ? (0.5, 0.5, 0.5) : (r.y > 0 ? room(r) : shadeWithoutBall(p, r, reflected: true))
                        let k = 0.7 * (1 + lid.rings * sin(rr / lid.radius * 14)) * (rr > lid.radius * 0.88 ? 0.6 : 1)
                        return (c.0 * k, c.1 * k, c.2 * k)
                    }
                }
            }
        }
        if d.y > 0 && reflected { return room(d) }
        return scene.trace(o, d, geo)
    }

    func shade(_ o: Vec3, _ d: Vec3) -> (Double, Double, Double) {
        if let b = ball {
            let oc = o - b, bb = oc.dot(d), disc = bb * bb - (oc.lengthSquared - ballRadius * ballRadius)
            if disc > 0 {
                let t = -bb - disc.squareRoot()
                if t > 1e-4 {
                    let p = o + d * t, n = (p - b).normalized
                    let r = d - n * (2 * d.dot(n))
                    let c = r.y > 0 ? room(r) : shadeWithoutBall(p + r * 1e-4, r, reflected: true)
                    let hl = pow(max(0, r.dot(scene.light)), 40)
                    var k = reflectance
                    if fresnel { k += (1 - reflectance) * pow(1 - max(0, min(1, -d.dot(n))), 5) }
                    return (min(1, c.0 * k + hl), min(1, c.1 * k + hl), min(1, c.2 * k + hl))
                }
            }
        }
        return shadeWithoutBall(o, d, reflected: false)
    }

    /// The luma image (BT.601 of gamma-encoded 8-bit RGB, as SyntheticScene's), 2x2 samples a pixel.
    func renderLuma(view: CameraView) -> Plane {
        let K = view.intrinsics, W = K.width, H = K.height
        var img = Plane(width: W, height: H)
        let o = view.position, R = view.worldFromCamera.rotation
        func encode(_ v: Double) -> Double { Foundation.floor(min(255, max(0, pow(v / 4, 1 / 1.6) * 255))) }
        for y in 0..<H {
            for x in 0..<W {
                var s = (0.0, 0.0, 0.0)
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let c = shade(o, (R * K.ray(Vec2(Double(x) + (Double(sx) + 0.5) / 2, Double(y) + (Double(sy) + 0.5) / 2))).normalized)
                        s = (s.0 + c.0, s.1 + c.1, s.2 + c.2)
                    }
                }
                img.data[y * W + x] = Float((0.299 * encode(s.0) + 0.587 * encode(s.1) + 0.114 * encode(s.2)).rounded())
            }
        }
        return img
    }
}
