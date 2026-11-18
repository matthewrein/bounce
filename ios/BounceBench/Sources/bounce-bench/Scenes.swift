import BounceCore
import Foundation

/// SplitMix64 with Gaussian draws (deterministic sensor noise).
struct BenchRandom {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1p-53 }
    mutating func gaussian() -> Double {
        let u = max(1e-12, uniform()), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// One camera frame as the phone would have it: the full 1920x1440 image as ARKit's bi-planar 4:2:0 buffer (luma plane,
/// interleaved CbCr plane at half size), a LiDAR depth map (256x192), and the truth (the slab, the ball, the cameras).
struct BenchScene {
    enum Kind: String, Codable { case slab, nothing }
    /// what the bench painted into the render (ScenePaint): nothing, a hand over a corner of the slab, floor clutter, or a
    /// floor of slab-sized tiles
    enum Variant: String, Codable { case plain, hand, clutter, tiles }
    var name: String
    var kind: Kind
    var variant: Variant
    var feet: Double?
    var ballHeight: Double?
    var scene: SyntheticScene
    /// the full camera image's camera, and the app's processing frame's (the full image shrunk by 4: 480x360)
    var full: CameraView
    var processing: CameraView
    var luma: [UInt8]
    var lumaStride: Int
    var cbcr: [UInt8]
    var cbcrStride: Int
    var depth: DepthMap
    var depthIntrinsics: CameraIntrinsics

    static let fullIntrinsics = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
    static let factor = 4

    var width: Int { full.intrinsics.width }
    var height: Int { full.intrinsics.height }
    /// gravity in the camera's axes (the same for the full and the processing frame)
    var downCam: Vec3 { full.directionToCamera(ARKitConvention.worldDown) }
    /// the slab's true top-corner outline in the processing frame (nil for the empty view, or if not all in view)
    var truthOutline: [Vec2]? {
        guard kind == .slab, let q = scene.corners(in: processing), q.allSatisfy({ processing.intrinsics.contains($0, margin: 1) }) else { return nil }
        return q
    }
    /// the slab's centre in the processing frame (a tap there)
    var tapPoint: Vec2? { kind == .slab ? processing.project(world: scene.slab.center) : nil }
    /// the ball's centre in the full image, if held and in view
    var ballPixel: Vec2? { scene.ball.flatMap { full.project(world: $0) }.flatMap { full.intrinsics.contains($0) ? $0 : nil } }

    static func processingIntrinsics(_ K: CameraIntrinsics) -> CameraIntrinsics {
        let s = K.scaled(by: 1 / Double(factor))
        return CameraIntrinsics(fx: s.fx, fy: s.fy, cx: s.cx, cy: s.cy, width: K.width / factor, height: K.height / factor)
    }

    /// The same frame in a buffer of its own (the same pixels at another address): the timings rotate among several, so
    /// each run reads its camera buffer from memory, not from a cache the run before filled, as the phone's ISP-written
    /// buffer arrives.
    func copy() -> BenchScene {
        var c = self
        c.luma = luma.withUnsafeBufferPointer { Array($0) }
        c.cbcr = cbcr.withUnsafeBufferPointer { Array($0) }
        return c
    }

    /// `n` copies (at least 8 x 4 MB = 33 MB, more than an M1's or a phone's L2 and system cache).
    func ring(_ n: Int = 8) -> [BenchScene] { (0..<max(1, n)).map { _ in copy() } }

    /// The slab (8 degrees tilt) seen from `feet` away along the line of sight, 50 degrees above level (a phone held
    /// to look down at it), a ball held `ballHeight` metres over its top (nil: none); `feet` nil: the floor alone, the
    /// slab out of view. Rendered one sample a pixel (softened like a camera's optics), the variant painted in
    /// (ScenePaint), then sensor noise of 1.5 grey levels.
    static func make(feet: Double?, ballHeight: Double?, variant: Variant, seed: UInt64) -> BenchScene {
        var s = makeGeometry(feet: feet, ballHeight: ballHeight, variant: variant)
        let K = s.full.intrinsics
        var rgb = s.scene.renderRGB(view: s.full)
        switch variant {
        case .plain: break
        case .hand: ScenePaint.hand(&rgb, view: s.full, scene: s.scene)
        case .clutter, .tiles:
            ScenePaint.floor(&rgb, view: s.full, scene: s.scene, slabInView: s.kind == .slab, dense: variant == .tiles, seed: seed &+ 7)
        }
        var rng = BenchRandom(seed)
        for i in 0..<(K.width * K.height) {
            let n = rng.gaussian() * 1.5
            for c in 0..<3 { rgb[i * 3 + c] = UInt8(max(0, min(255, (Double(rgb[i * 3 + c]) + n).rounded()))) }
        }
        let ycc = SyntheticScene.ycc(rgb: rgb, width: K.width, height: K.height)
        // the camera buffer's two planes (bytes per row as ARKit's 1920-wide buffers have them)
        let cw = ycc.chromaWidth, ch = ycc.chromaHeight
        var cbcr = [UInt8](repeating: 128, count: cw * 2 * ch)
        for i in 0..<(cw * ch) { cbcr[2 * i] = ycc.cb[i]; cbcr[2 * i + 1] = ycc.cr[i] }
        s.luma = ycc.y; s.lumaStride = K.width
        s.cbcr = cbcr; s.cbcrStride = cw * 2
        (s.depth, s.depthIntrinsics) = depthMap(scene: s.scene, view: s.full, seed: seed &+ 1)
        return s
    }
    /// LiDAR's view (256x192, ARKit's sceneDepth size): the slab's top plane over its footprint, the floor elsewhere,
    /// with 2 mm of noise, all at high confidence.
    static func depthMap(scene sc: SyntheticScene, view: CameraView, seed: UInt64) -> (DepthMap, CameraIntrinsics) {
        let W = 256, H = 192
        let Kd = view.intrinsics.scaled(by: Double(W) / Double(view.intrinsics.width))
        let o = view.position, R = view.worldFromCamera.rotation, s = sc.slab
        var d = [Float](repeating: 0, count: W * H)
        var rng = BenchRandom(seed)
        for y in 0..<H {
            for x in 0..<W {
                let dir = R * Kd.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5))   // camera z = 1 along it
                var z = Double.infinity
                let den = dir.dot(s.normal)
                if abs(den) > 1e-9 {
                    let t = (s.center - o).dot(s.normal) / den
                    let rel = o + dir * t - s.center
                    if t > 0, abs(rel.dot(s.axisU)) <= s.halfU, abs(rel.dot(s.axisV)) <= s.halfV { z = t }
                }
                if !z.isFinite, dir.y < -1e-9 { z = -o.y / dir.y }
                d[y * W + x] = z.isFinite && z > 0 && z < 5 ? Float(z + rng.gaussian() * 0.002) : 0
            }
        }
        return (DepthMap(width: W, height: H, depth: d, confidence: [UInt8](repeating: 2, count: W * H)), Kd)
    }

    /// a ball held over the slab, as high as still keeps it in the picture at this distance
    static func heldHeight(feet f: Double) -> Double { f == 2 ? 0.2 : f == 4 ? 0.3 : 0.45 }

    /// The ball's height over the slab every 0.05 s of a drop from `h0` (the ball let go at rest), down to 1 cm.
    static func dropHeights(from h0: Double) -> [Double] {
        var hs: [Double] = [], t = 0.0
        while true {
            let h = h0 - 0.5 * 9.81 * t * t
            if h <= 0.01 { hs.append(0.01); break }
            hs.append(h)
            t += 0.05
        }
        return hs
    }

    /// The scenes the bench runs on. Plain: the slab at 2, 4 and 6 ft with a ball held over it and without, and an empty
    /// view. Harder (`extras`): a hand over a corner (2 and 4 ft, ball held); floor clutter (2 and 4 ft without a ball,
    /// and the empty view); a floor of slab-sized tiles (4 ft, and the empty view); and a drop (the ball at 0.05 s steps
    /// from held to the slab, 2 and 4 ft). Rendered once (or read from `cache`, a folder for the rendered buffers; never
    /// committed). `keep`: which to make (feet, or nil for the empty view).
    static func all(quick: Bool, extras: Bool, keep: (Double?) -> Bool, cache: URL?, log: (String) -> Void) -> SceneSet {
        var specs: [(Double?, Double?, Variant, UInt64)] = []
        var i: UInt64 = 0
        for f in [2.0, 4, 6] {
            specs.append((f, heldHeight(feet: f), .plain, 1000 + i)); i += 1
            specs.append((f, nil, .plain, 1000 + i)); i += 1
        }
        specs.append((nil, nil, .plain, 1000 + i))
        if extras {
            specs += [(2, heldHeight(feet: 2), .hand, 2000), (4, heldHeight(feet: 4), .hand, 2001),
                      (2, nil, .clutter, 2002), (4, nil, .clutter, 2003), (nil, nil, .clutter, 2004),
                      (4, nil, .tiles, 2005), (nil, nil, .tiles, 2006)]
        }
        var out = SceneSet()
        func get(_ f: Double?, _ b: Double?, _ v: Variant, _ seed: UInt64) -> BenchScene {
            let t0 = nowNs()
            if let c = cache, let sc = load(c, feet: f, ball: b, variant: v, seed: seed) {
                log("scene \(sc.name): read from the cache")
                return sc
            }
            let sc = make(feet: f, ballHeight: b, variant: v, seed: seed)
            log(String(format: "scene %@: rendered in %.1f s", sc.name, msSince(t0) / 1000))
            if let c = cache { save(sc, c, seed: seed) }
            return sc
        }
        for s in specs where keep(s.0) { out.scenes.append(get(s.0, s.1, s.2, s.3)) }
        if extras {
            for f in [2.0, 4] where keep(f) {
                out.drops[f] = dropHeights(from: heldHeight(feet: f)).enumerated().map { j, h in get(f, h, .plain, 3000 + UInt64(f) * 100 + UInt64(j)) }
            }
        }
        return out
    }

    private static func key(feet: Double?, ball: Double?, variant: Variant, seed: UInt64) -> String {
        "scene-v1-" + (variant == .plain ? "" : variant.rawValue + "-")
            + "\(feet.map { String(format: "%.1f", $0) } ?? "none")-\(ball.map { String(format: "%.3f", $0) } ?? "none")-\(seed)"
    }

    /// The cache keeps only the pixels and the depth (the cameras and the scene are made again, cheaply).
    static func save(_ s: BenchScene, _ dir: URL, seed: UInt64) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let k = key(feet: s.feet, ball: s.ballHeight, variant: s.variant, seed: seed)
        try? Data(s.luma).write(to: dir.appendingPathComponent(k + ".luma"))
        try? Data(s.cbcr).write(to: dir.appendingPathComponent(k + ".cbcr"))
        try? s.depth.data.write(to: dir.appendingPathComponent(k + ".bdp"))
    }

    static func load(_ dir: URL, feet: Double?, ball: Double?, variant: Variant, seed: UInt64) -> BenchScene? {
        // (the plain scenes' first cache files named the ball's height to 2 decimals)
        let keys = [key(feet: feet, ball: ball, variant: variant, seed: seed)]
            + (variant == .plain ? ["scene-v1-\(feet.map { String(format: "%.1f", $0) } ?? "none")-\(ball.map { String(format: "%.2f", $0) } ?? "none")-\(seed)"] : [])
        for k in keys {
            guard let l = try? Data(contentsOf: dir.appendingPathComponent(k + ".luma")),
                  let c = try? Data(contentsOf: dir.appendingPathComponent(k + ".cbcr")),
                  let d = try? Data(contentsOf: dir.appendingPathComponent(k + ".bdp")), let dm = DepthMap(data: d),
                  l.count == 1920 * 1440, c.count == 1920 * 720 else { continue }
            var s = makeGeometry(feet: feet, ballHeight: ball, variant: variant)
            s.luma = [UInt8](l); s.cbcr = [UInt8](c); s.depth = dm
            return s
        }
        return nil
    }

    /// The scene's cameras and truth with blank pixels (no rendering).
    static func makeGeometry(feet: Double?, ballHeight: Double?, variant: Variant = .plain) -> BenchScene {
        let K = fullIntrinsics
        let slab = SyntheticScene.slabPose(tilt: 8, heading: 35, yaw: 20)
        var sc = SyntheticScene(slab: slab)
        sc.supersample = 1
        let view: CameraView
        if let f = feet {
            let az = Units.radians(25), el = Units.radians(50)
            let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * Units.feet(f)
            view = SyntheticScene.camera(at: pos, lookingAt: slab.center + Vec3(0.01, 0.04 + 0.1 * Units.feet(f) / 1.8, -0.01),
                                         intrinsics: K, roll: 3)
            if let h = ballHeight { sc.ball = slab.center + Vec3(0.012, h + sc.ballRadius, -0.015) }
        } else {
            view = SyntheticScene.camera(at: Vec3(1.5, 0.9, 1.5), lookingAt: Vec3(2.0, 0, 2.3), intrinsics: K, roll: 3)
        }
        var name: String
        if let f = feet { name = String(format: "%.0f ft, ", f) + (ballHeight.map { String(format: "ball held %.2f m over", $0) } ?? "no ball") } else { name = "empty view" }
        switch variant {
        case .plain: break
        case .hand: name += ", a hand over a corner"
        case .clutter: name += ", cluttered floor"
        case .tiles: name += ", slab-sized floor tiles"
        }
        let dk = K.scaled(by: 256.0 / Double(K.width))
        return BenchScene(name: name, kind: feet == nil ? .nothing : .slab, variant: variant, feet: feet, ballHeight: ballHeight, scene: sc, full: view,
                          processing: CameraView(worldFromCamera: view.worldFromCamera, intrinsics: processingIntrinsics(K)),
                          luma: [], lumaStride: K.width, cbcr: [], cbcrStride: K.width,
                          depth: DepthMap(width: 1, height: 1, depth: [0], confidence: [0]), depthIntrinsics: dk)
    }

    /// The same frame as ARKit would report it after its world frame moved by `shift` under the lock (relocalisation):
    /// the same pixels, the camera's reported pose moved by `shift` (world coordinates).
    func worldShifted(_ shift: Vec3) -> BenchScene {
        var c = self
        let T = RigidTransform(rotation: .identity, translation: shift)
        c.full = CameraView(worldFromCamera: T * full.worldFromCamera, intrinsics: full.intrinsics)
        c.processing = CameraView(worldFromCamera: T * processing.worldFromCamera, intrinsics: processing.intrinsics)
        return c
    }
}

/// The rendered scenes: the still frames, and the drops (feet -> the frames of a drop, held first).
struct SceneSet {
    var scenes: [BenchScene] = []
    var drops: [Double: [BenchScene]] = [:]

    func scene(feet: Double?, ball: Bool, variant: BenchScene.Variant = .plain) -> BenchScene? {
        scenes.first { $0.feet == feet && ($0.ballHeight != nil) == ball && $0.variant == variant }
    }
}
