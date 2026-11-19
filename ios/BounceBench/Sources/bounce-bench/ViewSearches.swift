import BounceCore
import Foundation

/// Does the search the app runs still find the slab on a cluttered floor seen from other sides? The bench's own scenes
/// see the slab from one side (25 deg); a cut to the sweep (a lower cap on the regions it grows) was once tuned on them
/// and missed the slab from 200 deg, where it is only reached at region 33-48. Here the clutter generator's floor is
/// rendered around the slab (2 and 3 ft; 25, 110 and 200 deg; 50 and 40 deg up; a new clutter seed each view) and one
/// cold search runs on each view, with the app's sweep options and with the finder's own: found = an outline within
/// 3 px (mean corner distance) of the slab's.
struct ViewSearch: Codable {
    var feet: Double
    var azimuthDegrees: Double
    var elevationDegrees: Double
    var seed: UInt64
    /// the nearest outline's mean corner distance from the slab's (px; nil: no outline) and whether that is within 3 px,
    /// with the app's sweep options and with the finder's own
    var appError: Double?
    var appFound: Bool
    var appFirstError: Double?
    var ownError: Double?
    var ownFound: Bool
    var appMs: Double
    var ownMs: Double
}

enum ViewSearches {
    static func meanCorner(_ a: [Vec2], _ b: [Vec2]) -> Double {
        guard a.count == 4, b.count == 4 else { return .infinity }
        var best = Double.infinity
        for rev in [false, true] {
            let q = rev ? Array(a.reversed()) : a
            for s in 0..<4 {
                var d = 0.0
                for i in 0..<4 { d += q[(i + s) % 4].distance(to: b[i]) }
                best = min(best, d / 4)
            }
        }
        return best
    }

    /// One view: the slab (8 deg tilt) on the clutter generator's floor, rendered at 1920x1440 with 1.5 grey levels of
    /// noise and shrunk by 4 as the app does; its processing frame, view, the slab's outline and the down direction.
    static func render(feet: Double, azDeg: Double, elDeg: Double, heading: Double, seed: UInt64)
        -> (frame: ColorFrame, view: CameraView, truth: [Vec2]?, down: Vec3) {
        let K = BenchScene.fullIntrinsics
        // the app's own slab (RecordingSettings), as the app's tracker settings expect it
        let rs = RecordingSettings()
        let slab = SyntheticScene.slabPose(tilt: 8, heading: heading, yaw: 20, spec: rs.slab)
        var sc = SyntheticScene(spec: rs.slab, slab: slab)
        sc.ballRadius = rs.ball.radius
        sc.supersample = 1
        let az = Units.radians(azDeg), el = Units.radians(elDeg)
        let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * Units.feet(feet)
        let view = SyntheticScene.camera(at: pos, lookingAt: slab.center + Vec3(0.01, 0.04 + 0.1 * Units.feet(feet) / 1.8, -0.01), intrinsics: K, roll: 3)
        var rgb = sc.renderRGB(view: view)
        ScenePaint.floor(&rgb, view: view, scene: sc, slabInView: true, dense: false, seed: seed)
        var rng = BenchRandom(seed &+ 99)
        for i in 0..<(K.width * K.height) {
            let n = rng.gaussian() * 1.5
            for c in 0..<3 { rgb[i * 3 + c] = UInt8(max(0, min(255, (Double(rgb[i * 3 + c]) + n).rounded()))) }
        }
        let ycc = SyntheticScene.ycc(rgb: rgb, width: K.width, height: K.height)
        let cw = ycc.chromaWidth, ch = ycc.chromaHeight
        var cbcr = [UInt8](repeating: 128, count: cw * 2 * ch)
        for i in 0..<(cw * ch) { cbcr[2 * i] = ycc.cb[i]; cbcr[2 * i + 1] = ycc.cr[i] }
        let small = ycc.y.withUnsafeBufferPointer { l in cbcr.withUnsafeBufferPointer { c in
            YCCImage.fromBiplanar(luma: l, lumaWidth: K.width, lumaHeight: K.height, lumaBytesPerRow: K.width, cbcr: c, cbcrBytesPerRow: cw * 2, factor: 4) } }
        let pv = CameraView(worldFromCamera: view.worldFromCamera, intrinsics: BenchScene.processingIntrinsics(K))
        let truth = sc.corners(in: pv).flatMap { q in q.allSatisfy { pv.intrinsics.contains($0, margin: 1) } ? q : nil }
        return (small.colorFrame, pv, truth, pv.directionToCamera(ARKitConvention.worldDown))
    }

    static func run(quick: Bool, log: (String) -> Void) -> [ViewSearch] {
        let spec = RecordingSettings().trackerSettings.spec
        var out: [ViewSearch] = []
        let feetList: [Double] = quick ? [2] : [2, 3]
        let azList: [Double] = quick ? [25, 200] : [25, 110, 200]
        let ks = quick ? [0] : [0, 1]
        for feet in feetList {
            for az in azList {
                for k in ks {
                    // the clutter seed: 5000 + 100 x feet + 10 x the azimuth's place (25, 110, 200) + the view's number
                    let seed = UInt64(5000 + Int(feet) * 100 + ([25.0, 110, 200].firstIndex(of: az) ?? 0) * 10 + k)
                    let el = [50.0, 40][k]
                    let v = render(feet: feet, azDeg: az, elDeg: el, heading: 35 + Double(k) * 23, seed: seed)
                    guard let t = v.truth else { log("  view search \(feet) ft az \(az): the slab is not all in view"); continue }
                    func search(_ f: SlabFinder) -> (err: Double?, first: Double?, ms: Double) {
                        let t0 = nowNs()
                        let c = f.find(frame: v.frame, intrinsics: v.view.intrinsics, spec: spec, down: v.down)
                        let ms = msSince(t0)
                        let ds = c.map { meanCorner($0.quad, t) }
                        return (ds.min(), ds.first, ms)
                    }
                    let a = search(StageBench.appFinder()), o = search(SlabFinder())
                    let r = ViewSearch(feet: feet, azimuthDegrees: az, elevationDegrees: el, seed: seed, appError: a.err, appFound: (a.err ?? .infinity) < 3,
                                       appFirstError: a.first, ownError: o.err, ownFound: (o.err ?? .infinity) < 3, appMs: a.ms, ownMs: o.ms)
                    out.append(r)
                    log(String(format: "  view search %.0f ft az %.0f el %.0f: app %@ (%.1f px, %.0f ms), finder's own %@ (%.1f px, %.0f ms)",
                               feet, az, el, r.appFound ? "found" : "MISSED", a.err ?? .nan, a.ms, r.ownFound ? "found" : "MISSED", o.err ?? .nan, o.ms))
                }
            }
        }
        return out
    }
}
