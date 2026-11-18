import Foundation

/// A complete capture kit with known truth, rendered with `SyntheticScene`, for scoring the scorer itself and for CI
/// (CaptureKit.md, "Scoring"). Every shot of the standard plan is made as the app would make it, through `KitStore`
/// (kit.json, shot.json, frames.jsonl, motion.jsonl):
///   - measurements: the true slab (7 x 7 in, 1 in thick, 1/8 in dish) and ball (35 mm), entered;
///   - slab positions level, 5° and 10° (15° for the optional third tilt, skipped unless asked), the slab sliding in
///     its cradle; each starts with a flat-phone shot: a CoreMotion stream of the phone laid on the slab (on a camera
///     bump), turned around and laid down again, run through `KitFlatSession` as on the phone;
///   - video shots with camera paths: still (3-4 ft, a little hand sway), a half-circle arc, the room scan; dim and
///     bright light (the picture's brightness scaled); the ball on the floor 3 ft and 5 ft away with the slab out of
///     view; the ball resting in the dish; the ball held 4 in, 1 ft and 2 ft over the slab (the heights entered); drops
///     from 1 ft (centre) and near an edge, with the ball's physical path: free fall from the release, a bounce off the
///     dish along the corner plane's normal at the rebound (0.7) of its speed squared (the app's own bounce model, so a
///     perfect tracker predicts it exactly), then bounces on the floor; the negatives (the camera turned away from the
///     slab; the slab without the ball);
///   - every video shot's CoreMotion stream (100 Hz) is consistent with its camera path through a fixed
///     CoreMotion-to-ARKit rotation (`KitMotionLink`), and all shots share one motion and one ARKit session.
/// To stay fast, a shot has a few frames (`framesPerShot` at `fps`, 6 by default, so the tracker can lock within a
/// second), and drops are recorded at 60 fps only from just before the release until the ball is on the floor. The
/// frames are rendered when the scorer asks for them (`frames(_:)`), at the video size (480x360 by default: the app's
/// processing frame, so nothing is scaled), or written as video.mp4 when `video` is set and ffmpeg is installed.
/// `truth` holds what really happened, shot by shot.
public final class KitSyntheticKit {
    public struct Options {
        /// frames of an ordinary video shot, and their rate
        public var framesPerShot = 12
        public var fps = 6.0
        /// drops: the rate around the release and the bounce
        public var dropFps = 60.0
        /// the video frames' size (rendered at this size)
        public var width = 480
        public var height = 360
        /// the camera's focal length over the image width (an iPhone's wide camera: about 0.78)
        public var focalShare = 0.78
        /// only these shots (nil: every shot of the plan); the others are skipped
        public var shots: Set<String>? = nil
        /// take the optional third tilt
        public var thirdTilt = false
        /// the slab positions' tilts (degrees): level, tilt 1, tilt 2, tilt 3
        public var tilts: [Double] = [0, 5, 10, 15]
        /// the slab's downhill direction (degrees from +x toward +z, ARKit's world)
        public var heading = 35.0
        public var rebound = 0.7
        /// the camera bump under the phone lying flat (degrees, phone axes)
        public var bump = Vec2(1.2, -0.8)
        /// CoreMotion's reference heading in ARKit's world (degrees)
        public var motionYaw = 37.0
        /// the picture's brightness in the dim and bright shots (the phone's auto-exposure makes up for most of a change in
        /// the room's light, so these are mild)
        public var dim = 0.6
        public var bright = 1.15
        /// write video.mp4 with this ffmpeg encoder ("h264" or "hevc"; needs ffmpeg) instead of rendering on demand
        public var video: String? = nil
        public var seed: UInt64 = 7
        public init() {}
    }

    /// What one shot really showed.
    public struct ShotTruth {
        public enum Kind: String { case flat, scan, still, arc, ballFloor, ballOnSlab, held, drop, away, noBall }
        public var shotId: String
        public var kind: Kind
        /// the slab where it lay (world) and its tilt (degrees)
        public var slab: SlabPose
        public var tiltDegrees: Double
        /// per video frame: time (uptime s), camera (video intrinsics), the ball's centre if any
        public var times: [Double] = []
        public var views: [CameraView] = []
        public var balls: [Vec3?] = []
        /// the picture's brightness (1 normal)
        public var brightness = 1.0
        /// held shots: the ball's drop height as the app defines it (its bottom above the dish below it, m)
        public var heldHeight: Double? = nil
        /// drops
        public var drop: DropTruth? = nil
    }

    /// A drop as it happened (world, uptime s).
    public struct DropTruth {
        public var held: Vec3
        public var cue: Double
        public var release: Double
        public var impactTime: Double
        public var impactPoint: Vec3
        public var velocityIn: Vec3
        public var velocityOut: Vec3
        /// where the bounce comes back to the impact height, and its apex above the impact point (m)
        public var landing: Vec3
        public var apexHeight: Double
        public var rebound: Double
    }

    public let store: KitStore
    public let options: Options
    public private(set) var truth: [String: ShotTruth] = [:]
    public var folder: URL { store.folder }
    public var kitId: String { store.kitId }
    /// the CoreMotion-to-ARKit rotation the motion streams were made with
    public let link: KitMotionLink

    let intrinsics: CameraIntrinsics
    var rng: KitSplitMix

    init(store: KitStore, options: Options) {
        self.store = store; self.options = options
        let f = options.focalShare * Double(options.width)
        intrinsics = CameraIntrinsics(fx: f, fy: f, cx: Double(options.width) / 2, cy: Double(options.height) / 2,
                                      width: options.width, height: options.height)
        link = KitMotionLink(yawDegrees: options.motionYaw, samples: 0, yawSpreadDegrees: 0, gravityMismatchDegrees: 0,
                             attitudeConjugated: false, shotId: "synthetic")
        rng = KitSplitMix(seed: options.seed)
    }

    /// The date the synthetic kit is made on (fixed, so its id is always the same).
    public static let date = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01T00:00:00Z

    /// Makes the kit in a new folder under `root`.
    public static func build(root: URL, options: Options = Options()) throws -> KitSyntheticKit {
        let fullH = Int((1920 * Double(options.height) / Double(options.width)).rounded())
        let fmt = KitCameraFormat(width: 1920, height: fullH, fps: 60)
        let device = KitDevice(modelIdentifier: "synthetic", systemVersion: "0", hasLiDAR: false, cameraFormat: fmt, highFrameRateFormat: fmt)
        let store = try KitStore.create(root: root, plan: .standard, device: device, measurements: KitMeasurements(settings: RecordingSettings()),
                                        build: "synthetic", date: date)
        let kit = KitSyntheticKit(store: store, options: options)
        try kit.make()
        return kit
    }

    /// Deletes the kit's folder.
    public func remove() { try? FileManager.default.removeItem(at: folder) }

    // MARK: making the shots

    func included(_ s: KitShotSpec) -> Bool {
        if s.optional && !options.thirdTilt { return false }
        return options.shots?.contains(s.id) ?? true
    }

    /// The slab of a plan position, sliding in its cradle (about 0.27 in per degree, as `DemoScript`).
    func slab(tilt: Double) -> SlabPose {
        let shift = Units.inches(0.27 * tilt), hd = Units.radians(options.heading)
        return SyntheticScene.slabPose(x: -shift * cos(hd), z: -shift * sin(hd), tilt: tilt, heading: options.heading)
    }

    func make() throws {
        let plan = store.plan
        var clock = 5000.0                      // uptime (s)
        var tiltIndex = 0, current = slab(tilt: options.tilts[0])
        var shotNo = 0
        for s in plan.shots {
            shotNo += 1
            let date = KitSyntheticKit.date.addingTimeInterval(clock - 5000)
            if s.isForm {
                if included(s) {
                    try store.commitMeasurements(KitMeasurements(slabWidthInches: 7, slabDepthInches: 7, slabThicknessInches: 1, dishInches: 0.125,
                                                                 ballDiameterMm: 35), date: date)
                } else { try store.skipShot(s.id, date: date) }
                continue
            }
            if let p = s.startsPosition {
                // the slab is moved to this position, unless the optional group is skipped
                if included(s) || !s.optional {
                    let k = Int(p.id.dropFirst()).map { $0 - 1 } ?? tiltIndex
                    tiltIndex = min(max(0, k), options.tilts.count - 1)
                    current = slab(tilt: options.tilts[tiltIndex])
                }
            }
            guard included(s) else {
                if store.record(s.id)?.status != .skipped { try store.skipShot(s.id, date: date) }
                continue
            }
            let tilt = options.tilts[tiltIndex]
            if s.isFlat {
                clock += try makeFlat(s, slab: current, tilt: tilt, start: clock, date: date) + 15
            } else {
                clock += try makeVideo(s, slab: current, tilt: tilt, start: clock, date: date, number: shotNo) + 15
            }
        }
        try store.finish(date: KitSyntheticKit.date.addingTimeInterval(clock - 5000))
    }

    // MARK: flat-phone shots

    /// The phone lying on the slab: laid down, still, turned around, still again (100 Hz).
    func flatStream(slab: SlabPose, start: Double) -> [KitMotionSample] {
        let nRef = link.rotation.transposed * slab.normal
        let z = Vec3(0, 0, 1), axis = z.cross(nRef)
        let T = axis.length < 1e-12 ? Mat3.identity : KitQuaternion(axis: axis, angle: KitFlatTilt.angle(z, nRef)).matrix
        let B = KitFlatTilt.tiltMatrix(options.bump * (Double.pi / 180))
        let psiA = Units.radians(30.0)
        func R(_ psi: Double, hand: Vec3 = .zero) -> Mat3 {
            T * KitFlatTilt.rz(psi) * KitQuaternion(rotationVector: hand).matrix * B
        }
        var out: [KitMotionSample] = []
        var t = 0.0, prev: Mat3? = nil
        func emit(_ M: Mat3) {
            t += 0.01
            let noise = Vec3(rng.gauss(), rng.gauss(), rng.gauss()) * Units.radians(0.01)
            let q = (KitQuaternion(rotationVector: noise) * KitQuaternion(matrix: M)).normalized
            let g = (M.transposed * Vec3(0, 0, -1)).rotated(by: Vec3(rng.gauss(), rng.gauss(), rng.gauss()) * Units.radians(0.02))
            let rr = prev.map { KitQuaternion(matrix: $0.transposed * M).rotationVector / 0.01 } ?? .zero
            out.append(KitMotionSample(time: start + t, gravity: g, userAcceleration: .zero, rotationRate: rr, attitude: q))
            prev = M
        }
        // laid down: from 10° in the hand to flat over a second
        for i in 1...100 { let s = Double(i) / 100; emit(R(psiA, hand: Vec3(Units.radians(10) * (1 - s), Units.radians(3) * (1 - s), 0))) }
        for _ in 0..<500 { emit(R(psiA)) }
        // picked up, turned around, laid down (2 s)
        for i in 1...200 {
            let s = Double(i) / 200, env = sin(.pi * s)
            emit(R(psiA + .pi * s, hand: Vec3(Units.radians(12) * env, Units.radians(4) * env, 0)))
        }
        for _ in 0..<500 { emit(R(psiA + .pi)) }
        return out
    }

    func makeFlat(_ s: KitShotSpec, slab: SlabPose, tilt: Double, start: Double, date: Date) throws -> Double {
        let stream = flatStream(slab: slab, start: start)
        let session = KitFlatSession(settings: store.plan.flatSettings, knownBump: store.knownBump, startTime: start)
        for x in stream { _ = session.feed(x); if session.isDone { break } }
        let result = session.result ?? session.finish()
        let duration = (stream.last?.time ?? start) - start
        var m = try store.newShotManifest(s.id, startedAt: date, duration: duration)
        m.startTime = start; m.motionSessionId = "m1"; m.arSessionId = "a1"
        m.motionSamples = stream.count; m.flat = result
        m.quality = KitQuality.evaluate(shot: s, flat: result)
        let folder = try store.beginShot(s.id)
        let w = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.motion))
        for x in stream { try w.append(x) }
        try w.close()
        try store.commitShot(s.id, manifest: m, date: date)
        truth[s.id] = ShotTruth(shotId: s.id, kind: .flat, slab: slab, tiltDegrees: tilt)
        return duration
    }

    // MARK: video shots

    /// A camera `distance` from `target` at an azimuth and elevation (degrees), with a small sway.
    func orbit(_ target: Vec3, distance d: Double, azimuth az: Double, elevation el: Double, sway: Double = 0.002, t: Double = 0) -> CameraView {
        let a = Units.radians(az), e = Units.radians(el)
        let pos = target + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * d
            + Vec3(sin(t * 2.1), sin(t * 1.7 + 1), sin(t * 2.9 + 2)) * sway
        return SyntheticScene.camera(at: pos, lookingAt: target, intrinsics: intrinsics, roll: 1.0 * sin(t * 0.9))
    }

    func kind(_ s: KitShotSpec) -> ShotTruth.Kind {
        switch s.diagram {
        case .roomScan: return .scan
        case .walkArc: return .arc
        case .ballFloorNear, .ballFloorFar: return .ballFloor
        case .ballOnSlab: return .ballOnSlab
        case .ballHeldLow, .ballHeldMid, .ballHeldHigh: return .held
        case .dropCentre, .dropEdge: return .drop
        case .noSlab: return .away
        case .noBall: return .noBall
        case .flatPhone, .flatPhoneTilted: return .flat
        case .measure, .holdStill, .dimLight, .brightLight: return .still
        }
    }

    func makeVideo(_ s: KitShotSpec, slab: SlabPose, tilt: Double, start: Double, date: Date, number: Int) throws -> Double {
        let k = kind(s)
        var tr = ShotTruth(shotId: s.id, kind: k, slab: slab, tiltDegrees: tilt)
        let n = max(2, options.framesPerShot), fps = options.fps
        var times = (0..<n).map { Double($0) / fps }
        let R = BallSpec().radius, up = Vec3(0, 1, 0)
        let spec = SlabSpec.standard
        let az0 = 15 + Double((number * 37) % 40)
        let path: (Double) -> CameraView
        var ball: (Double) -> Vec3? = { _ in nil }
        switch k {
        case .still, .flat:
            path = { t in self.orbit(slab.center, distance: 1.0, azimuth: az0, elevation: 42, t: t) }
            if s.diagram == .dimLight { tr.brightness = options.dim }
            if s.diagram == .brightLight { tr.brightness = options.bright }
        case .arc, .noBall:
            let span = Double(n) / fps
            path = { t in self.orbit(slab.center, distance: 1.05, azimuth: az0 - 50 + 110 * t / span, elevation: 38 + 4 * sin(t), t: t) }
        case .scan:
            let span = Double(n) / fps
            path = { t in self.orbit(slab.center, distance: 1.2, azimuth: 160 * t / span, elevation: 35 + 8 * sin(t * 1.3), t: t) }
        case .ballFloor:
            // the ball on the floor away from the slab; the camera between them, looking away from the slab
            let b = Vec3(-1.3, R, 0.9), away = Vec3(b.x, 0, b.z).normalized
            let d = s.diagram == .ballFloorNear ? Units.feet(3) : Units.feet(5), e = Units.radians(38)
            ball = { _ in b }
            path = { t in
                let pos = b - away * (d * cos(e)) + up * (d * sin(e)) + Vec3(sin(t * 2.1), sin(t * 1.7), 0) * 0.002
                return SyntheticScene.camera(at: pos, lookingAt: b, intrinsics: self.intrinsics)
            }
        case .ballOnSlab:
            let c = slab.center - slab.normal * spec.dishDepth + slab.normal * R
            ball = { _ in c }
            path = { t in self.orbit(slab.center, distance: 1.0, azimuth: az0, elevation: 42, t: t) }
        case .held:
            let h = Units.inches(s.nominalHeightInches ?? 12)
            let b = slab.center - slab.normal * spec.dishDepth + up * (R + h)
            tr.heldHeight = Bounce.drop(ballCenter: b, pose: slab, spec: spec, ball: BallSpec(), down: ARKitConvention.worldDown)?.dropHeight
            ball = { t in b + Vec3(sin(t * 3.1), sin(t * 2.3), sin(t * 2.7)) * 0.0015 }
            let aim = slab.center + up * (h * 0.4)
            path = { t in self.orbit(aim, distance: 1.0 + h * 0.25, azimuth: az0, elevation: 40, t: t) }
        case .drop:
            let edge = s.diagram == .dropEdge
            let d = try dropTruth(slab: slab, u: edge ? 0.6 * slab.halfU : 0, v: edge ? 0.3 * slab.halfV : 0,
                                  height: Units.inches(s.nominalHeightInches ?? 12), cue: start + (s.kind.releaseCue ?? 2))
            tr.drop = d.truth
            ball = { t in d.position(start + t) }
            let aim = slab.center + up * 0.12
            path = { t in self.orbit(aim, distance: 1.15, azimuth: az0, elevation: 35, t: t) }
            // a few frames to lock, then 60 fps from just before the release until the ball is on the floor
            let rel = d.truth.release - start, endT = d.end - start
            times = stride(from: 0.0, to: rel - 0.25, by: 1 / fps).map { $0 }
            let t1 = times.last.map { $0 + 1 / options.dropFps } ?? 0
            times += stride(from: max(t1, rel - 0.25), through: endT, by: 1 / options.dropFps).map { $0 }
        case .away:
            path = { t in SyntheticScene.camera(at: Vec3(0.2 + 0.03 * t, 1.1, 1.6), lookingAt: Vec3(0.4 + 0.1 * t, 0, 3.4), intrinsics: self.intrinsics) }
        }
        tr.times = times.map { start + $0 }
        tr.views = times.map(path)
        tr.balls = times.map(ball)

        // frames.jsonl as the app writes it, motion.jsonl at 100 Hz from the same camera path
        let duration = (times.last ?? 0) + 0.1
        var frames: [KitFrame] = []
        for (i, t) in times.enumerated() {
            let v = tr.views[i]
            let arkit = RigidTransform(rotation: v.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: v.position)
            let K = v.intrinsics
            frames.append(KitFrame(index: i, time: start + t, pose: arkit.columnMajor4x4.map { Float($0) },
                                   intrinsics: [K.fx, K.fy, K.cx, K.cy].map { Float($0) }, tracking: .normal, exposure: 1.0 / 60,
                                   ambientLumens: 1000 * tr.brightness, colorTemperature: 4200,
                                   luma: previewLuma(tr, frame: i)))
        }
        var motion: [KitMotionSample] = []
        var prev: Mat3? = nil
        var t = 0.0
        while t <= duration {
            let Rwa = path(t).worldFromCamera.rotation * ARKitConvention.cvToARKitCamera
            let q = link.attitude(worldFromARKitCamera: Rwa)
            let M = q.matrix
            let rr = prev.map { KitQuaternion(matrix: $0.transposed * M).rotationVector / 0.01 } ?? .zero
            motion.append(KitMotionSample(time: start + t, gravity: M.transposed * Vec3(0, 0, -1), userAcceleration: .zero, rotationRate: rr, attitude: q))
            prev = M
            t += 0.01
        }

        var m = try store.newShotManifest(s.id, startedAt: date, duration: duration)
        m.startTime = start; m.motionSessionId = "m1"; m.arSessionId = "a1"
        if let d = tr.drop { m.releaseTime = d.cue }
        let rate = k == .drop ? options.dropFps : fps
        let folder = try store.beginShot(s.id)
        var bytes: Int64 = 0
        var codec = "memory"
        #if os(macOS) || os(Linux)
        if let c = options.video {
            let url = folder.appendingPathComponent(KitClipFiles.video)
            try KitVideoEncoder.encode(render(tr), fps: rate, codec: c == "hevc" ? .hevc : .h264, fullRange: false, to: url)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64((attrs?[.size] as? Int) ?? 0)
            codec = c
        }
        #endif
        m.video = KitVideoInfo(codec: codec, width: options.width, height: options.height, fps: rate, bitrate: 0, frameCount: frames.count, fileBytes: bytes)
        m.cameraFormat = store.manifest.device.cameraFormat
        m.motionSamples = motion.count
        m.quality = KitQuality.evaluate(shot: s, stats: frames.map { KitFrameStat(frame: $0) }, expectedFrames: frames.count,
                                        reference: store.qualityReference)
        let fw = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.frames))
        for f in frames { try fw.append(f) }
        try fw.close()
        let mw = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.motion))
        for x in motion { try mw.append(x) }
        try mw.close()
        try store.commitShot(s.id, manifest: m, date: date)
        if let h = tr.heldHeight { try store.setHeight(s.id, inches: Units.toInches(h), date: date) }
        truth[s.id] = tr
        return duration
    }

    /// A drop's path: held, let go 0.15 s after the cue, falling onto the dish at (u, v), bouncing off along the corner
    /// plane's normal with the app's rebound model, then bouncing on the floor (or the slab) with half its vertical speed.
    func dropTruth(slab: SlabPose, u: Double, v: Double, height h: Double, cue: Double)
        throws -> (truth: DropTruth, position: (Double) -> Vec3, end: Double) {
        let spec = SlabSpec.standard, ballSpec = BallSpec(diameter: 0.035, rebound: options.rebound), R = ballSpec.radius
        let down = ARKitConvention.worldDown, up = -down, G = Units.gravity, g = down * G
        let surface = slab.point(u: u, v: v) - slab.normal * Dish.at(pose: slab, depth: spec.dishDepth, u: u, v: v).depth
        let held = surface + up * (R + h)
        guard let dp = Bounce.drop(ballCenter: held, pose: slab, spec: spec, ball: ballSpec, down: down) else {
            throw KitStoreError.wrongKind("the synthetic drop misses the slab")
        }
        let release = cue + 0.15
        let tFall = (2 * dp.dropHeight / G).squareRoot()
        let impactTime = release + tFall
        let impact = held + down * dp.dropHeight
        let vin = down * (G * tFall)
        let vout = slab.normal * ((options.rebound).squareRoot() * vin.length)
        let tl = 2 * vout.dot(up) / G
        let landing = impact + vout.rejecting(up) * tl
        let truth = DropTruth(held: held, cue: cue, release: release, impactTime: impactTime, impactPoint: impact, velocityIn: vin,
                              velocityOut: vout, landing: landing, apexHeight: pow(vout.dot(up), 2) / (2 * G), rebound: options.rebound)
        // the flight after the impact, with bounces on whatever is below (the slab's top inside its outline, else the floor)
        func ground(_ p: Vec3) -> Double {
            let (a, b) = slab.local(p)
            guard abs(a) <= slab.halfU && abs(b) <= slab.halfV else { return 0 }
            // height of the corner plane above (x, z)
            let n = slab.normal
            return slab.center.y - ((p.x - slab.center.x) * n.x + (p.z - slab.center.z) * n.z) / n.y
        }
        var segs: [(t0: Double, p0: Vec3, v0: Vec3)] = [(impactTime, impact, vout)]
        var t = impactTime, p = impact, vel = vout
        let dt = 0.0005
        let stop = impactTime + 2.0
        while t < stop {
            let p2 = p + vel * dt + g * (0.5 * dt * dt), v2 = vel + g * dt
            if v2.y < 0 && p2.y - R <= ground(p2) && t - segs.last!.t0 > 0.02 {
                let nv = Vec3(v2.x * 0.8, -v2.y * 0.5, v2.z * 0.8)
                segs.append((t + dt, Vec3(p2.x, ground(p2) + R, p2.z), nv))
                if segs.count > 6 { break }
            }
            t += dt; p = p2; vel = v2
        }
        let floorTime = segs.count > 1 ? segs[1].t0 : impactTime + tl
        func position(_ time: Double) -> Vec3 {
            if time <= release { return held }
            if time <= impactTime { let s = time - release; return held + g * (0.5 * s * s) }
            let sg = segs.last { $0.t0 <= time } ?? segs[0]
            let s = time - sg.t0
            var q = sg.p0 + sg.v0 * s + g * (0.5 * s * s)
            if q.y < R { q.y = R }
            return q
        }
        return (truth, position, floorTime + 0.2)
    }

    // MARK: rendering

    func scene(_ tr: ShotTruth, frame i: Int) -> SyntheticScene {
        var sc = SyntheticScene(slab: tr.slab, ball: i < tr.balls.count ? tr.balls[i] : nil)
        sc.supersample = 1
        return sc
    }

    static func image(_ sc: SyntheticScene, view: CameraView, brightness: Double) -> YCCImage {
        var rgb = sc.renderRGB(view: view)
        if brightness != 1 { for j in 0..<rgb.count { rgb[j] = UInt8(clamp((Double(rgb[j]) * brightness).rounded(), 0, 255)) } }
        return SyntheticScene.ycc(rgb: rgb, width: view.intrinsics.width, height: view.intrinsics.height)
    }

    /// Mean luma of a quarter-size render (what the app writes as `luma`, cheaply).
    func previewLuma(_ tr: ShotTruth, frame i: Int) -> Double {
        let v = tr.views[i], K = v.intrinsics.scaled(by: 0.25)
        let img = KitSyntheticKit.image(scene(tr, frame: i), view: CameraView(worldFromCamera: v.worldFromCamera, intrinsics: K),
                                        brightness: tr.brightness)
        return img.y.withUnsafeBufferPointer { KitImageStats.meanLuma(bytes: $0, width: img.width, height: img.height, bytesPerRow: img.width, step: 1) } ?? 0
    }

    /// Every frame of a shot, rendered (in parallel).
    func render(_ tr: ShotTruth) -> [YCCImage] {
        let n = tr.views.count
        var out = [YCCImage?](repeating: nil, count: n)
        out.withUnsafeMutableBufferPointer { buf in
            let b = buf
            DispatchQueue.concurrentPerform(iterations: n) { i in
                b[i] = KitSyntheticKit.image(scene(tr, frame: i), view: tr.views[i], brightness: tr.brightness)
            }
        }
        return out.map { $0! }
    }

    /// The scorer's frames for a shot: its video.mp4 if one was written, else the frames rendered now.
    public func frames(_ input: KitScorer.ShotInput) throws -> KitFrameSource {
        guard let tr = truth[input.shotId] else { throw KitScoreError.unreadable(KitClipFiles.video) }
        #if os(macOS) || os(Linux)
        if options.video != nil { return try KitScorer.videoFrames(input) }
        #endif
        return KitArrayFrameSource(width: options.width, height: options.height, frames: render(tr))
    }

    /// Scorer options for this kit: its frames, and (with `truthBall`) a ball finder that knows where the ball is.
    public func scorerOptions(truthBall: Bool = false) -> KitScorer.Options {
        var o = KitScorer.Options()
        o.source = "synthetic"
        o.frames = { try self.frames($0) }
        if truthBall { let t = truth; o.makeBallLocator = { KitTruthBallLocator(truth: t) } }
        return o
    }
}

/// A ball finder that knows where a synthetic kit's ball is: on each frame it returns the true ball, as seen in the
/// image it is given (nil when the ball is not wholly inside it). For testing the ball metrics without a real finder.
public final class KitTruthBallLocator: BallLocating, KitFrameAware {
    let truth: [String: KitSyntheticKit.ShotTruth]
    var current: (shot: String, frame: Int, view: CameraView)?
    /// the ball's radius (m)
    public var radius = BallSpec().radius

    public init(kit: KitSyntheticKit) { truth = kit.truth }
    public init(truth: [String: KitSyntheticKit.ShotTruth]) { self.truth = truth }

    public func prepare(shotId: String, frameIndex: Int, time: Double, view: CameraView) { current = (shotId, frameIndex, view) }

    public func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        guard let c = current, let tr = truth[c.shot], c.frame < tr.balls.count, let w = tr.balls[c.frame] else { return nil }
        let cam = c.view.toCamera(w)
        guard cam.z > 0.05, let px = intrinsics.project(cam) else { return nil }
        let r = intrinsics.focal * radius / cam.z
        guard px.x - r >= 0, px.y - r >= 0, px.x + r <= Double(intrinsics.width), px.y + r <= Double(intrinsics.height) else { return nil }
        return (cam, px, r)
    }

    public func reset() {}
}

/// A small deterministic random source (SplitMix64).
struct KitSplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
