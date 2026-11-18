import Foundation

/// One rendered drop of the drop set (`KitSyntheticDrops`).
public struct KitDropShot: Codable, Equatable {
    public var id: String
    /// the slab's tilt (degrees) and its downhill direction (degrees from +x toward +z, ARKit's world)
    public var tilt: Double
    public var heading: Double = 35
    /// where the ball is held: over the dish this far from the slab's centre (inches), in this direction from the slab's
    /// downhill one (degrees, anticlockwise seen from above)
    public var offsetInches: Double
    public var offsetAzimuth: Double
    /// the ball's bottom above the dish straight below it when let go (inches): what the app calls the drop height
    public var heightInches: Double
    /// the slab's true restitution, as a rebound (e²)
    public var rebound: Double
    /// where the camera stands, from the downhill direction (degrees, anticlockwise seen from above), its elevation
    /// (degrees) and distance (m; nil: about enough to keep the held ball, the slab and the landing in view)
    public var cameraAzimuth: Double
    public var cameraElevation: Double = 28
    public var cameraDistance: Double? = nil
    /// the camera aims this far downhill of the slab's centre (m)
    public var aimDownhill: Double = 0.08
    /// the ball's velocity and spin when let go (m/s and rad/s, world): a hand that does not let go cleanly
    public var releaseVelocity: Vec3 = .zero
    public var releaseSpin: Vec3 = .zero
    /// frames of the 60 fps part the recorder dropped (their indices, before dropping)
    public var droppedFrames: [Int] = []
    /// each frame's timestamp is off its nominal time by up to this much (s, uniform)
    public var jitter: Double = 0.0004

    public init(id: String, tilt: Double, heading: Double = 35, offsetInches: Double, offsetAzimuth: Double, heightInches: Double,
                rebound: Double, cameraAzimuth: Double, cameraElevation: Double = 28, cameraDistance: Double? = nil, aimDownhill: Double = 0.08,
                releaseVelocity: Vec3 = .zero, droppedFrames: [Int] = [], jitter: Double = 0.0004) {
        self.id = id; self.tilt = tilt; self.heading = heading; self.offsetInches = offsetInches; self.offsetAzimuth = offsetAzimuth
        self.heightInches = heightInches; self.rebound = rebound; self.cameraAzimuth = cameraAzimuth; self.cameraElevation = cameraElevation
        self.cameraDistance = cameraDistance; self.aimDownhill = aimDownhill; self.releaseVelocity = releaseVelocity; self.droppedFrames = droppedFrames; self.jitter = jitter
    }

    /// The standard drop set: centre and off-centre (0, 2, 4 and 6.5 in from the centre, every side of it), rebounds 0.5,
    /// 0.6, 0.7, 0.85, tilts 0-12°, heights 6-36 in, cameras from the side, at 45° and from behind and in front of the
    /// bounce, with a sloppy release, dropped frames and a ball that leaves the view in some.
    public static let standardSet: [KitDropShot] = [
        KitDropShot(id: "d01-centre", tilt: 5, offsetInches: 0, offsetAzimuth: 0, heightInches: 12, rebound: 0.7, cameraAzimuth: 90),
        KitDropShot(id: "d02-2in-downhill", tilt: 5, offsetInches: 2, offsetAzimuth: 0, heightInches: 12, rebound: 0.7, cameraAzimuth: 60),
        KitDropShot(id: "d03-4in-side", tilt: 8, offsetInches: 4, offsetAzimuth: 90, heightInches: 12, rebound: 0.7, cameraAzimuth: 120),
        KitDropShot(id: "d04-6in-uphill", tilt: 12, offsetInches: 6.5, offsetAzimuth: 180, heightInches: 18, rebound: 0.7, cameraAzimuth: 90),
        KitDropShot(id: "d05-6in-side-low-tilt", tilt: 2, offsetInches: 6.5, offsetAzimuth: 270, heightInches: 12, rebound: 0.85,
                    cameraAzimuth: 45),
        KitDropShot(id: "d06-centre-dropped-frames", tilt: 10, offsetInches: 0, offsetAzimuth: 0, heightInches: 24, rebound: 0.5,
                    cameraAzimuth: 135, droppedFrames: [9, 10, 23, 41, 42]),
        KitDropShot(id: "d07-4in-6in-drop", tilt: 3, offsetInches: 4, offsetAzimuth: 45, heightInches: 6, rebound: 0.85, cameraAzimuth: 90),
        KitDropShot(id: "d08-2in-36in-drop", tilt: 12, offsetInches: 2, offsetAzimuth: 225, heightInches: 36, rebound: 0.5, cameraAzimuth: 70),
        KitDropShot(id: "d09-6in-push", tilt: 8, offsetInches: 6.5, offsetAzimuth: 135, heightInches: 24, rebound: 0.85, cameraAzimuth: 100,
                    releaseVelocity: Vec3(0.03, 0, -0.02)),
        KitDropShot(id: "d10-level-4in", tilt: 0, offsetInches: 4, offsetAzimuth: 0, heightInches: 12, rebound: 0.7, cameraAzimuth: 90),
        KitDropShot(id: "d11-6in-from-behind", tilt: 6, offsetInches: 6.5, offsetAzimuth: 0, heightInches: 9, rebound: 0.6, cameraAzimuth: 180),
        KitDropShot(id: "d12-4in-leaves-view", tilt: 10, offsetInches: 4, offsetAzimuth: 315, heightInches: 30, rebound: 0.7, cameraAzimuth: 95,
                    cameraElevation: 24, cameraDistance: 1.3, aimDownhill: -0.45),
    ]
}

/// A rendered drop's truth: what the ball did (`KitDropPhysics`) and what the app predicts from the true slab.
public struct KitDropTruth: Codable, Equatable {
    public var cue: Double
    public var release: Double
    public var held: Vec3
    /// how far the ball's centre fell from the release to the impact (m)
    public var dropHeight: Double
    public var impactTime: Double
    public var impactCenter: Vec3
    public var contactPoint: Vec3
    public var localNormal: Vec3
    /// the contact point in the slab's axes from its centre (m), and the local normal's angle from the slab's (degrees)
    public var offsetU: Double
    public var offsetV: Double
    public var normalTilt: Double
    public var velocityIn: Vec3
    public var velocityOut: Vec3
    /// e² (the slab's rebound) and the tangential velocity's share kept (along the incoming one)
    public var rebound: Double
    public var tangentialRatio: Double?
    public var apexHeight: Double
    /// where the bounce's arc comes down to the landing level (the floor plus a radius), carried on through anything in
    /// the way, and when
    public var landingLevel: Double
    public var landing: Vec3
    public var landingTime: Double
    /// the ball's next contact after the bounce
    public var nextContact: KitDropContact?
    /// the app's prediction from the true slab and the held ball, with its own rebound setting and with the true one
    public var app: KitDropComparison?
    public var trueRebound: KitDropComparison?
}

/// The truth compared at a landing level (the ball's centre's height, world y): where the bounce's arc comes down to it,
/// carried on through anything in the way, and the app's prediction compared there with its own rebound and with the
/// true one. An analysis is scored against the truth at its own landing level.
public struct KitDropLevelTruth: Codable, Equatable {
    public var level: Double
    public var landing: Vec3
    public var app: KitDropComparison?
    public var trueRebound: KitDropComparison?
}

/// Drops onto the slab rendered with known, physical truth (`KitDropPhysics`: the bounce reflects about the dish's LOCAL
/// normal with the restitution of its rebound, the velocity along the surface as a solid sphere rolling off; not the
/// app's model), for scoring the drop analysis (`KitDropAnalysis`) through the scorer's own per-frame path
/// (`KitDropBench`). Each drop is a shot as a kit records it: a few frames at 6 fps for the tracker to lock, the release
/// cue at 2 s, then 60 fps from just before the release until the ball has landed; every frame with its own timestamp
/// (a little jitter, and frames the recorder dropped are missing) and exposure motion blur (the ball rendered at
/// `blurSamples` instants over the exposure and averaged; the timestamp is the exposure's middle). The slab is the
/// owner's as described: about 18 in square, 1 in thick, dished 1/8 in at the centre (a spherical cap,
/// `KitDish.Shape.sphericalCap`), on a base whose top centre is 4.5 in over the floor. The renderer (`SyntheticScene`)
/// draws the top as the plane through its corners; where a ball in the dish sinks below that plane it is drawn over it.
public final class KitSyntheticDrops {
    public struct Options {
        /// the slab (sides, thickness, dish depth) and its dish's shape
        public var spec = SlabSpec(sideU: Units.inches(18), sideV: Units.inches(18), thickness: Units.inches(1), dishDepth: Units.inches(0.125))
        public var dishShape = KitDish.Shape.sphericalCap
        /// the slab top's centre over the floor (m)
        public var centreHeight = Units.inches(4.5)
        public var ballDiameter = 0.035
        /// how the bounce treats the velocity along the surface
        public var tangential = KitTangentialModel.rolling(mu: 0.4)
        /// the video's size (a real kit's 1440 x 1080) and rate, and the lock frames' rate
        public var width = 1440
        public var height = 1080
        public var fps = 60.0
        public var lockFps = 6.0
        /// the camera's focal length over the image width (an iPhone's wide camera: about 0.78)
        public var focalShare = 0.78
        /// exposure (s; 0: no motion blur) and the instants rendered over it
        public var exposure = 1.0 / 120
        public var blurSamples = 7
        /// the frames are rendered at `width` x `height` divided by this (the tests' fast mode; 1 for the real size)
        public var shrink = 1
        public var shots = KitDropShot.standardSet
        public var seed: UInt64 = 11
        public init() {}
    }

    /// One drop made: its truth, camera per frame, frames.jsonl lines and the ball's positions over each exposure.
    public struct Drop {
        public var shot: KitDropShot
        public var slab: SlabPose
        public var physics: KitDropPhysics
        public var truth: KitDropTruth
        public var start: Double
        public var frames: [KitFrame]
        public var views: [CameraView]
        /// per frame, the ball's centre at each instant of the exposure
        public var exposures: [[Vec3]]
    }

    public let options: Options
    public var dish: KitDish { KitDish(spec: options.spec, shape: options.dishShape) }
    public var ball: BallSpec { BallSpec(diameter: options.ballDiameter, rebound: 0.7) }

    public init(options: Options = Options()) { self.options = options }

    /// The tracker's settings for the drops: the app's, with the slab measured (the scene's) and the app's rebound.
    public var settings: TrackerSettings {
        var s = RecordingSettings().trackerSettings
        s.spec = options.spec
        s.ball.diameter = options.ballDiameter
        return s
    }

    func intrinsics() -> CameraIntrinsics {
        let w = options.width / max(1, options.shrink), h = options.height / max(1, options.shrink)
        let f = options.focalShare * Double(w)
        return CameraIntrinsics(fx: f, fy: f, cx: Double(w) / 2, cy: Double(h) / 2, width: w, height: h)
    }

    /// The slab of a drop: tilted downhill toward `heading`, sliding in its cradle (about 0.27 in per degree).
    func slab(_ shot: KitDropShot) -> SlabPose {
        let shift = Units.inches(0.27 * shot.tilt), hd = Units.radians(shot.heading)
        return SyntheticScene.slabPose(x: -shift * cos(hd), z: -shift * sin(hd), height: options.centreHeight, tilt: shot.tilt,
                                       heading: shot.heading, spec: options.spec)
    }

    /// Makes drop `shot` starting at uptime `start`.
    public func make(_ shot: KitDropShot, start: Double = 1000) -> Drop {
        let pose = slab(shot), up = Vec3(0, 1, 0), R = options.ballDiameter / 2
        let hd = Units.radians(shot.heading)
        let downhill = Vec3(cos(hd), 0, sin(hd))
        func around(_ deg: Double) -> Vec3 { downhill.rotated(by: up * Units.radians(deg)) }
        // held over the dish point `offset` from the centre (horizontally), its bottom `height` above the dish there
        // (offsets are for the 18 in slab: a smaller one has them scaled to its half-width)
        let scale = min(1, Units.toInches(min(options.spec.halfU, options.spec.halfV)) / 9)
        let off = around(shot.offsetAzimuth) * Units.inches(shot.offsetInches * scale)
        var surface = pose.center + off
        for _ in 0..<6 {   // down the vertical line onto the dish: h(y) = the height over the corner plane plus the dish's depth
            let q = pose.toSlab(surface)
            let f = q.z + dish.surface(u: q.x, v: q.y).depth
            surface.y -= f / pose.normal.y
        }
        let held = surface + up * (R + Units.inches(shot.heightInches))
        let cue = start + 2, release = cue + 0.15
        var params = KitDropPhysics.Params()
        params.ballRadius = R; params.rebound = shot.rebound; params.tangential = options.tangential
        let phys = KitDropPhysics(slab: pose, dish: dish, held: held, release: release, releaseVelocity: shot.releaseVelocity,
                                  releaseSpin: shot.releaseSpin, params: params)
        let truth = KitSyntheticDrops.truth(phys, cue: cue, settings: settings)

        // frames: 6 fps to lock, 60 fps from 0.25 s before the release until the ball has landed (0.25 s after its next
        // contact or its arc's landing, at most 2.5 s)
        var rng = KitSplitMix(seed: options.seed &+ shot.id.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) })
        var times = stride(from: 0.0, to: release - start - 0.25, by: 1 / options.lockFps).map { start + $0 }
        let endT = min(release + 2.5, max(truth.landingTime, truth.nextContact?.time ?? 0) + 0.25)
        var k = 0
        var t = max((times.last ?? start) + 1 / options.fps, release - 0.25)
        while t <= endT {
            if !shot.droppedFrames.contains(k) {
                times.append(t + (rng.uniform() * 2 - 1) * shot.jitter)
            }
            k += 1
            t += 1 / options.fps
        }
        // the camera: it looks at the space over the slab and downhill of it from `cameraAzimuth`
        let h = Units.inches(shot.heightInches)
        let aim = pose.center + up * (0.08 + 0.35 * h) + downhill * shot.aimDownhill
        let dist = shot.cameraDistance ?? clamp(0.95 + 1.0 * h, 1.0, 2.0)
        let el = Units.radians(shot.cameraElevation)
        let K = intrinsics()
        let views = times.map { tt -> CameraView in
            let s = tt - start
            let pos = aim + around(shot.cameraAzimuth) * (dist * cos(el)) + up * (dist * sin(el))
                + Vec3(sin(s * 2.1), sin(s * 1.7 + 1), sin(s * 2.9 + 2)) * 0.002
            return SyntheticScene.camera(at: pos, lookingAt: aim, intrinsics: K, roll: 1.0 * sin(s * 0.9))
        }
        let n = max(1, options.blurSamples)
        let exposures = times.map { tt -> [Vec3] in
            guard options.exposure > 0, n > 1 else { return [phys.position(at: tt)] }
            return (0..<n).map { phys.position(at: tt + (Double($0) / Double(n - 1) - 0.5) * options.exposure) }
        }
        let frames = times.enumerated().map { (i, tt) -> KitFrame in
            let v = views[i]
            let arkit = RigidTransform(rotation: v.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: v.position)
            return KitFrame(index: i, time: tt, pose: arkit.columnMajor4x4.map { Float($0) },
                            intrinsics: [K.fx, K.fy, K.cx, K.cy].map { Float($0) }, tracking: .normal,
                            exposure: options.exposure > 0 ? options.exposure : 1.0 / 60, ambientLumens: 1000, colorTemperature: 4200)
        }
        return Drop(shot: shot, slab: pose, physics: phys, truth: truth, start: start, frames: frames, views: views, exposures: exposures)
    }

    /// The truth of drop `d` compared at the world height `level` (nil without a bounce off the slab that gets that low).
    public func truth(_ d: Drop, level: Double) -> KitDropLevelTruth? {
        KitSyntheticDrops.truth(d.physics, level: level, settings: settings)
    }

    static func truth(_ phys: KitDropPhysics, level: Double, settings: TrackerSettings) -> KitDropLevelTruth? {
        guard let c = phys.impact, let land = phys.arcLanding(level: level) else { return nil }
        let vy = c.velocityOut.y, G = Units.gravity
        let apex = vy > 0 ? vy * vy / (2 * G) : 0
        var t = KitDropLevelTruth(level: level, landing: land.point, app: nil, trueRebound: nil)
        if c.surface == .slab {
            var s = settings
            let p = KitBouncePrediction.app(pose: phys.slab, settings: s, held: phys.held)
            t.app = KitDropAnalysis.compare(p, rebound: s.ball.rebound, impactCenter: c.center, velocityOut: c.velocityOut, landing: land.point,
                                            apex: apex, level: level)
            s.ball.rebound = phys.params.rebound
            let pt = KitBouncePrediction.app(pose: phys.slab, settings: s, held: phys.held)
            t.trueRebound = KitDropAnalysis.compare(pt, rebound: s.ball.rebound, impactCenter: c.center, velocityOut: c.velocityOut,
                                                    landing: land.point, apex: apex, level: level)
        }
        return t
    }

    /// What really happened, and the app's prediction from the true slab and held ball.
    static func truth(_ phys: KitDropPhysics, cue: Double, settings: TrackerSettings) -> KitDropTruth {
        let R = phys.params.ballRadius, up = Vec3(0, 1, 0), G = Units.gravity
        let level = phys.params.floorY + R
        guard let c = phys.impact else {
            // never touched anything (cannot happen over the slab): a truth that says so
            return KitDropTruth(cue: cue, release: phys.release, held: phys.held, dropHeight: 0, impactTime: .nan, impactCenter: phys.held,
                                contactPoint: phys.held, localNormal: up, offsetU: .nan, offsetV: .nan, normalTilt: .nan, velocityIn: .zero,
                                velocityOut: .zero, rebound: .nan, tangentialRatio: nil, apexHeight: .nan, landingLevel: level,
                                landing: phys.held, landingTime: phys.release, nextContact: nil, app: nil, trueRebound: nil)
        }
        let q = phys.slab.toSlab(c.point), n = c.normal
        let tin = c.velocityIn - n * c.velocityIn.dot(n), tout = c.velocityOut - n * c.velocityOut.dot(n)
        let k: Double? = tin.length >= 0.05 ? tout.dot(tin.normalized) / tin.length : nil
        let vy = c.velocityOut.y
        let apex = vy > 0 ? vy * vy / (2 * G) : 0
        let land = phys.arcLanding(level: level) ?? (c.time, c.center)
        let next = phys.contacts.count > 1 ? phys.contacts[1] : nil
        var t = KitDropTruth(cue: cue, release: phys.release, held: phys.held, dropHeight: phys.held.y - c.center.y, impactTime: c.time,
                             impactCenter: c.center, contactPoint: c.point, localNormal: n, offsetU: q.x, offsetV: q.y,
                             normalTilt: Units.degrees(n.angle(to: phys.slab.normal)), velocityIn: c.velocityIn, velocityOut: c.velocityOut,
                             rebound: phys.params.rebound, tangentialRatio: k, apexHeight: apex, landingLevel: level, landing: land.point,
                             landingTime: land.time,
                             nextContact: next.map { KitDropContact(time: $0.time, center: $0.center, surface: $0.surface == .slab ? .slab : .floor) },
                             app: nil, trueRebound: nil)
        let lt = truth(phys, level: level, settings: settings)
        t.app = lt?.app
        t.trueRebound = lt?.trueRebound
        return t
    }

    /// The ball's track as a perfect finder would give it: its centre on every frame (the exposure's middle).
    public static func perfectTrack(_ d: Drop) -> [KitBallSample] {
        d.frames.enumerated().map { KitBallSample(t: $1.time, p: d.physics.position(at: $1.time), c: d.views[$0].position) }
    }

    // MARK: rendering

    /// Every frame of a drop, rendered (in parallel).
    public func render(_ d: Drop) -> [YCCImage] {
        let n = d.frames.count
        var out = [YCCImage?](repeating: nil, count: n)
        let spec = options.spec, R = options.ballDiameter / 2, dish = self.dish
        out.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: n) { i in
                b[i] = KitSyntheticDrops.renderFrame(slab: d.slab, spec: spec, dish: dish, balls: d.exposures[i], radius: R, view: d.views[i])
            }
        }
        return out.map { $0! }
    }

    /// One frame: `SyntheticScene` (one sample a pixel, softened as its renders are), with the ball averaged over the
    /// instants of its exposure inside the box it sweeps, and drawn where it sinks into the dish below the plane the
    /// renderer draws the top as.
    static func renderFrame(slab: SlabPose, spec: SlabSpec, dish: KitDish, balls: [Vec3], radius: Double, view: CameraView) -> YCCImage {
        let K = view.intrinsics, W = K.width, H = K.height
        var base = SyntheticScene(spec: spec, slab: slab, ball: nil)
        base.supersample = 1
        let scenes = balls.map { b -> SyntheticScene in var s = base; s.ball = b; s.ballRadius = radius; return s }
        let geo = base.prepare()
        // the box the ball sweeps (pixels)
        var x0 = W, y0 = H, x1 = -1, y1 = -1
        for b in balls {
            let c = view.toCamera(b)
            guard c.z > 0.05, let p = K.project(c) else { continue }
            let r = K.focal * radius / c.z * 1.25 + 4
            x0 = min(x0, Int(floor(p.x - r))); y0 = min(y0, Int(floor(p.y - r)))
            x1 = max(x1, Int(ceil(p.x + r))); y1 = max(y1, Int(ceil(p.y + r)))
        }
        x0 = max(0, x0); y0 = max(0, y0); x1 = min(W - 1, x1); y1 = min(H - 1, y1)
        let o = view.position, Rot = view.worldFromCamera.rotation
        var rgb = [UInt8](repeating: 0, count: W * H * 3)
        let inv = 1 / Double(max(1, scenes.count))
        for y in 0..<H {
            for x in 0..<W {
                let d = (Rot * K.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5))).normalized
                var c = (0.0, 0.0, 0.0)
                if x >= x0 && x <= x1 && y >= y0 && y <= y1 {
                    for sc in scenes {
                        let v = traceInDish(sc, o, d, geo, dish: dish)
                        c.0 += v.0; c.1 += v.1; c.2 += v.2
                    }
                    c = (c.0 * inv, c.1 * inv, c.2 * inv)
                } else {
                    c = base.trace(o, d, geo)
                }
                let i = (y * W + x) * 3
                rgb[i] = UInt8(clamp(pow(c.0, 1 / 1.6) * 255, 0, 255))
                rgb[i + 1] = UInt8(clamp(pow(c.1, 1 / 1.6) * 255, 0, 255))
                rgb[i + 2] = UInt8(clamp(pow(c.2, 1 / 1.6) * 255, 0, 255))
            }
        }
        SyntheticScene.soften(&rgb, W, H)
        return SyntheticScene.ycc(rgb: rgb, width: W, height: H)
    }

    /// `SyntheticScene.trace`, except that a ball sunk into the dish below the corner plane shows where the plane hides it
    /// (the renderer has no dish; the region above a spherical dish is convex, so nothing else lies between).
    static func traceInDish(_ sc: SyntheticScene, _ o: Vec3, _ d: Vec3, _ g: SyntheticScene.Prepared, dish: KitDish) -> (Double, Double, Double) {
        let c = sc.trace(o, d, g)
        guard let b = sc.ball else { return c }
        let oc = o - b, bb = oc.dot(d), cc = oc.lengthSquared - sc.ballRadius * sc.ballRadius, disc = bb * bb - cc
        guard disc > 0 else { return c }
        let tb = -bb - disc.squareRoot()
        let n = sc.slab.normal, den = d.dot(n)
        guard tb > 1e-4, abs(den) > 1e-9 else { return c }
        let tp = (sc.slab.center - o).dot(n) / den
        guard tp > 1e-4, tp < tb else { return c }
        let ph = sc.slab.toSlab(o + d * tp)
        guard abs(ph.x) <= sc.slab.halfU && abs(ph.y) <= sc.slab.halfV else { return c }
        let p = o + d * tb, q = sc.slab.toSlab(p)
        guard -q.z < dish.surface(u: q.x, v: q.y).depth else { return c }
        // the ball's shading, as `SyntheticScene.trace` has it
        let nn = (p - b).normalized
        let r = d - nn * (2 * d.dot(nn))
        let sky = r.y > 0 ? 0.55 + 0.4 * r.y : 0.25 + 0.15 * (1 + r.y)
        let v = min(1, sky + pow(max(0, r.dot(sc.light)), 40))
        return (v * 0.97, v * 0.96, v * 0.94)
    }
}
