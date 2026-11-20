import Foundation

#if os(macOS) || os(Linux)

/// Writes a video frame by frame through ffmpeg, rate-controlled the way the phone's encoder is (an average bitrate, a
/// key frame every second, full-range 4:2:0 samples tagged full range), so a synthetic clip is as large as the phone's.
/// `noise` adds the camera's sensor noise (ffmpeg's temporal noise filter): without it a clean render costs the encoder
/// almost nothing and the clip comes out far smaller than a real one. Frames are written as they come; nothing is held.
public final class KitVideoStreamWriter {
    public enum Codec: String { case hevc, h264 }

    public let url: URL
    public let width: Int
    public let height: Int
    public private(set) var frames = 0
    private let process: Process
    private let input: FileHandle
    private let errText: PipeDrain
    private var failed: Error? = nil
    private var closed = false

    public init(url: URL, width: Int, height: Int, fps: Double, codec: Codec, bitrate: Int, keyFrameInterval: Int,
                noise: Int = 0, preset: String = "ultrafast") throws {
        guard let exe = KitFFmpeg.find("ffmpeg") else { throw KitVideoError.toolMissing("ffmpeg") }
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { throw KitVideoError.badFrame("odd or empty size \(width)x\(height)") }
        self.url = url; self.width = width; self.height = height
        signal(SIGPIPE, SIG_IGN)
        var args = ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "\(width)x\(height)",
                    "-r", String(format: "%.6g", fps), "-color_range", "pc", "-i", "pipe:0"]
        if noise > 0 { args += ["-vf", "noise=alls=\(noise):allf=t"] }
        let rate = String(bitrate)
        args += ["-c:v", codec == .hevc ? "libx265" : "libx264", "-preset", preset, "-b:v", rate,
                 "-maxrate", String(bitrate * 3 / 2), "-bufsize", String(bitrate * 2),
                 "-g", String(keyFrameInterval), "-pix_fmt", "yuv420p", "-color_range", "pc", "-an"]
        if codec == .hevc { args += ["-x265-params", "log-level=error", "-tag:v", "hvc1"] } else { args += ["-profile:v", "high"] }
        args += [url.path]
        process = Process()
        process.executableURL = exe
        process.arguments = args
        let inPipe = Pipe(), err = Pipe()
        process.standardInput = inPipe; process.standardError = err; process.standardOutput = FileHandle.nullDevice
        errText = PipeDrain(err.fileHandleForReading)
        input = inPipe.fileHandleForWriting
        try process.run()
    }

    deinit {
        if !closed { try? input.close(); process.terminate() }
    }

    /// One frame (full-range YCbCr 4:2:0 of the writer's size).
    public func append(_ f: YCCImage) throws {
        if let e = failed { throw e }
        guard !closed else { throw KitVideoError.badFrame("the writer is finished") }
        guard f.width == width, f.height == height else { throw KitVideoError.badFrame("frames differ in size") }
        var d = Data(capacity: f.y.count + 2 * f.cb.count)
        d.append(contentsOf: f.y); d.append(contentsOf: f.cb); d.append(contentsOf: f.cr)
        do { try input.write(contentsOf: d) } catch { failed = error; throw error }
        frames += 1
    }

    /// Completes the file; returns its size in bytes.
    @discardableResult
    public func finish() throws -> Int64 {
        guard !closed else { return KitFiles.fileSize(url.path) }
        closed = true
        try? input.close()
        process.waitUntilExit()
        let e = errText.finish()
        if process.terminationStatus != 0 {
            throw KitVideoError.ffmpegFailed(KitFFmpeg.lastLine(e, hide: [url.path, url.deletingLastPathComponent().path])
                                             ?? "exit status \(process.terminationStatus)")
        }
        if let f = failed { throw f }
        return KitFiles.fileSize(url.path)
    }
}

/// A synthetic kit the size of a real one, written in exactly the format the phone writes, for the hand-off dry run
/// (`ios/tools/handoff-dryrun.sh`): every shot through `KitStore` as `KitSession` makes it (the measurements form,
/// flat-phone shots with their CoreMotion stream, video shots, a retried shot, skipped shots, the entered heights),
/// each video shot at its plan length, 1440x1080 from a 1920x1440 camera, 30 frames a second (drops 60), encoded
/// like the phone (`KitPhoneVideo`: HEVC at its bitrate, or H.264 at 1.5 times it) with the camera's noise, LiDAR
/// depth about once a second, and frames.jsonl lines as `KitRecorder` writes them (pose, `K`, tracking, exposure,
/// light estimate, luma, blur, depth, the live result). The scene and its truth are `KitSyntheticKit`'s (slab
/// positions level, 5° and 10°, the ball on the floor, in the dish, held and dropped), so the scores can be checked.
///
/// To stay quick, a shot renders a new picture only `renderFps` times a second while nothing moves fast (the camera
/// then holds still between renders, and frames.jsonl, motion.jsonl and the picture agree), and every frame while a
/// dropped ball is in the air. `timeScale` runs the plan faster, as the UI tests do (kit.json records it).
public final class KitSyntheticPhoneKit {
    public struct Options {
        public var codec: KitVideoStreamWriter.Codec = .hevc
        /// the plan's time scale: 1 is a real kit; less makes every recording shorter (kit.json records it)
        public var timeScale = 1.0
        /// when the kit was started: its id ("slab-kit-20261119-083000")
        public var date = Date(timeIntervalSince1970: 1_795_077_000)   // 2026-11-19T08:30:00Z
        /// the phone has LiDAR (depth files about once a second, as on a Pro model)
        public var lidar = true
        /// new pictures a second while nothing moves fast
        public var renderFps = 5.0
        /// the camera's format (ARKit's 4:3 format at 60 fps)
        public var cameraWidth = 1920
        public var cameraHeight = 1440
        /// shots the owner skips (the optional third tilt is skipped unless `thirdTilt`)
        public var skip: Set<String> = ["s12-no-slab"]
        public var thirdTilt = false
        /// shots taken twice (Retry): the second attempt replaces the first
        public var retry: Set<String> = ["s04-level-still"]
        /// held shots whose height the owner does not enter
        public var noHeight: Set<String> = ["s09-held-high"]
        /// the camera's sensor noise (ffmpeg's noise strength; 0 for none)
        public var noise = 6
        /// ffmpeg's speed preset (the size follows the bitrate whatever the preset)
        public var preset = "ultrafast"
        public var build = "synthetic-phone-kit"
        /// the scene: slab tilts, heading, rebound, camera bump, motion frame
        public var scene = KitSyntheticKit.Options()
        /// progress lines (shot ids and numbers only)
        public var log: ((String) -> Void)? = nil
        public init() {}
    }

    /// What one video shot wrote.
    public struct ShotStats {
        public var shotId: String
        public var frames: Int
        public var renders: Int
        public var videoBytes: Int64
        public var depthFiles: Int
        public var motionSamples: Int
    }

    public let store: KitStore
    public let options: Options
    let scene: KitSyntheticKit
    /// what each shot really showed (flat-phone and video shots)
    public private(set) var truth: [String: KitSyntheticKit.ShotTruth] = [:]
    public private(set) var stats: [ShotStats] = []
    public var folder: URL { store.folder }
    public var kitId: String { store.kitId }
    var rng: KitSplitMix

    init(store: KitStore, options: Options) {
        self.store = store; self.options = options
        var so = options.scene
        so.thirdTilt = options.thirdTilt
        scene = KitSyntheticKit(store: store, options: so)
        rng = KitSplitMix(seed: options.scene.seed &+ 101)
    }

    /// The device kit.json records: a LiDAR phone (or not) with ARKit's 4:3 format at 60 fps.
    public static func device(_ o: Options) -> KitDevice {
        let fmt = KitCameraFormat(width: o.cameraWidth, height: o.cameraHeight, fps: 60)
        return KitDevice(modelIdentifier: "synthetic", systemVersion: "18.0", hasLiDAR: o.lidar, cameraFormat: fmt, highFrameRateFormat: fmt)
    }

    /// Makes the kit in a new folder under `root` (finished, as after the last shot).
    public static func build(root: URL, options: Options = Options()) throws -> KitSyntheticPhoneKit {
        guard KitFFmpeg.find("ffmpeg") != nil else { throw KitVideoError.toolMissing("ffmpeg") }
        // standard-v1, the plan the hand-off dry run was written for (standard-v2 bundles and checks the same way)
        let plan = options.timeScale == 1 ? KitPlan.standardV1 : KitPlan.standardV1.scaled(by: options.timeScale)
        let store = try KitStore.create(root: root, plan: plan, device: device(options),
                                        measurements: KitMeasurements(settings: RecordingSettings()), build: options.build, date: options.date)
        let kit = KitSyntheticPhoneKit(store: store, options: options)
        do { try kit.make() } catch { try? FileManager.default.removeItem(at: store.folder); throw error }
        return kit
    }

    func included(_ s: KitShotSpec) -> Bool {
        if s.optional && !options.thirdTilt { return false }
        return !options.skip.contains(s.id)
    }

    func make() throws {
        let plan = store.plan, tilts = options.scene.tilts
        var clock = 5000.0
        var tiltIndex = 0, current = scene.slab(tilt: tilts[0])
        func date() -> Date { options.date.addingTimeInterval(clock - 5000) }
        for (n, s) in plan.shots.enumerated() {
            if s.isForm {
                clock += 60   // the owner measures
                if included(s) {
                    try store.commitMeasurements(KitSyntheticKit.trueMeasurements, date: date())
                } else { try store.skipShot(s.id, date: date()) }
                continue
            }
            if let p = s.startsPosition, included(s) || !s.optional {
                let k = Int(p.id.dropFirst()).map { $0 - 1 } ?? tiltIndex
                tiltIndex = min(max(0, k), tilts.count - 1)
                current = scene.slab(tilt: tilts[tiltIndex])
            }
            guard included(s) else {
                if store.record(s.id)?.status != .skipped { try store.skipShot(s.id, date: date()) }
                clock += 5
                continue
            }
            let tilt = tilts[tiltIndex]
            if s.isFlat {
                clock += try makeFlat(s, slab: current, tilt: tilt, start: clock, date: date()) + 20
                continue
            }
            if options.retry.contains(s.id) {
                clock += try makeVideo(s, slab: current, tilt: tilt, start: clock, date: date(), number: n + 1) + 10
            }
            clock += try makeVideo(s, slab: current, tilt: tilt, start: clock, date: date(), number: n + 1) + 15
            if s.asksHeight, !options.noHeight.contains(s.id), let h = truth[s.id]?.heldHeight {
                try store.setHeight(s.id, inches: (Units.toInches(h) * 100).rounded() / 100, date: date())   // read off a ruler
            }
        }
        try store.finish(date: date())
    }

    // MARK: flat-phone shots

    /// The phone lying on the slab (`KitSyntheticKit.flatStream`: laid down, still, turned around, still again), sped up
    /// with the plan: every k-th sample at 100 Hz, its rotation rate k times as fast.
    func flatStream(slab: SlabPose, start: Double) -> [KitMotionSample] {
        let full = scene.flatStream(slab: slab, start: start)
        let k = max(1, Int((1 / options.timeScale).rounded()))
        guard k > 1 else { return full }
        var out: [KitMotionSample] = []
        for (j, i) in stride(from: k - 1, to: full.count, by: k).enumerated() {
            var x = full[i]
            x.time = start + Double(j + 1) * 0.01
            x.rotationRate = full[(i - k + 1)...i].reduce(Vec3.zero) { $0 + $1.rotationRate }
            out.append(x)
        }
        return out
    }

    /// A flat-phone shot as `KitSession` records it: the CoreMotion stream through `KitFlatSession`, motion.jsonl, and
    /// shot.json with the result and its check.
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
        truth[s.id] = KitSyntheticKit.ShotTruth(shotId: s.id, kind: .flat, slab: slab, tiltDegrees: tilt)
        options.log?(String(format: "%@: flat phone, %d motion samples, true tilt %@ (slab %.1f°)", s.id, stream.count,
                            result.isUsable ? (result.tiltDegrees.map { String(format: "%.2f°", $0) } ?? "?") : "not usable", tilt))
        return duration
    }

    // MARK: video shots

    /// The camera path, the ball and the stretch of the shot (s from its start) where every frame is rendered.
    struct Motion {
        var kind: KitSyntheticKit.ShotTruth.Kind
        var path: (Double) -> CameraView
        var ball: (Double) -> Vec3?
        var fast: ClosedRange<Double>? = nil
        var drop: KitSyntheticKit.DropTruth? = nil
        var heldHeight: Double? = nil
        var brightness = 1.0
    }

    /// The same camera paths and balls as `KitSyntheticKit.makeVideo`, over the shot's real length.
    func motion(_ s: KitShotSpec, slab: SlabPose, start: Double, seconds: Double, K: CameraIntrinsics, number: Int) throws -> Motion {
        let k = scene.kind(s)
        let R = KitSyntheticKit.ball.radius, up = Vec3(0, 1, 0), spec = KitSyntheticKit.spec
        let az0 = 15 + Double((number * 37) % 40), span = max(seconds, 0.5)
        let sc = scene
        var m = Motion(kind: k, path: { t in sc.orbit(slab.center, distance: 1.0, azimuth: az0, elevation: 42, t: t, K: K) }, ball: { _ in nil })
        switch k {
        case .still, .flat:
            if s.diagram == .dimLight { m.brightness = options.scene.dim }
            if s.diagram == .brightLight { m.brightness = options.scene.bright }
        case .arc, .noBall:
            m.path = { t in sc.orbit(slab.center, distance: 1.05, azimuth: az0 - 50 + 110 * t / span, elevation: 38 + 4 * sin(t), t: t, K: K) }
        case .scan:
            m.path = { t in sc.orbit(slab.center, distance: 1.2, azimuth: 160 * t / span, elevation: 35 + 8 * sin(t * 1.3), t: t, K: K) }
        case .ballFloor:
            let b = Vec3(-1.3, R, 0.9), away = Vec3(b.x, 0, b.z).normalized
            let d = s.diagram == .ballFloorNear ? Units.feet(3) : Units.feet(5), e = Units.radians(38)
            m.ball = { _ in b }
            m.path = { t in
                let pos = b - away * (d * cos(e)) + up * (d * sin(e)) + Vec3(sin(t * 2.1), sin(t * 1.7), 0) * 0.002
                return SyntheticScene.camera(at: pos, lookingAt: b, intrinsics: K)
            }
        case .ballOnSlab:
            let c = slab.center - slab.normal * spec.dishDepth + slab.normal * R
            m.ball = { _ in c }
        case .held:
            let h = Units.inches(s.nominalHeightInches ?? 12)
            let b = slab.center - slab.normal * spec.dishDepth + up * (R + h)
            m.heldHeight = Bounce.drop(ballCenter: b, pose: slab, spec: spec, ball: KitSyntheticKit.ball, down: ARKitConvention.worldDown)?.dropHeight
            m.ball = { t in b + Vec3(sin(t * 3.1), sin(t * 2.3), sin(t * 2.7)) * 0.0015 }
            let aim = slab.center + up * (h * 0.4)
            m.path = { t in sc.orbit(aim, distance: 1.0 + h * 0.25, azimuth: az0, elevation: 40, t: t, K: K) }
        case .drop:
            let edge = s.diagram == .dropEdge
            let d = try scene.dropTruth(slab: slab, u: edge ? 0.6 * slab.halfU : 0, v: edge ? 0.3 * slab.halfV : 0,
                                        height: Units.inches(s.nominalHeightInches ?? 12), cue: start + (s.kind.releaseCue ?? 2))
            m.drop = d.truth
            m.ball = { t in d.position(start + t) }
            let aim = slab.center + up * 0.12
            m.path = { t in sc.orbit(aim, distance: 1.15, azimuth: az0, elevation: 35, t: t, K: K) }
            m.fast = (d.truth.release - start - 0.25)...(d.end - start)
        case .away:
            m.path = { t in SyntheticScene.camera(at: Vec3(0.2 + 0.03 * t, 1.1, 1.6), lookingAt: Vec3(0.4 + 0.1 * t, 0, 3.4), intrinsics: K) }
        }
        return m
    }

    /// The time a frame's picture is rendered at: the frame's own while the ball flies, else the start of its slot.
    func renderTime(_ t: Double, _ m: Motion) -> Double {
        if let f = m.fast, f.contains(t) { return t }
        return (t * options.renderFps + 1e-9).rounded(.down) / options.renderFps
    }

    /// The app's live result on a frame, as the phone would have shown it: searching, then confirming and locked on
    /// shots with the slab in view (its corners and tilt), and the ball's circle once locked.
    func live(_ m: Motion, s: KitShotSpec, t: Double, view: CameraView, slab: SlabPose, ball: Vec3?, tilt: Double) -> KitLiveResult {
        let slabShown = s.expect.slab == .required || (s.expect.slab == .any && m.kind != .away)
        guard slabShown, t >= 0.4 else { return KitLiveResult(state: .searching) }
        let corners = slab.topCorners.compactMap { view.project(world: $0) }
        guard corners.count == 4 else { return KitLiveResult(state: .searching) }
        if t < 0.8 { return KitLiveResult(state: .confirming, corners: corners) }
        var circle: (center: Vec2, radius: Double)? = nil
        if let b = ball, let c = view.project(world: b) {
            let z = view.toCamera(b).z
            if z > 0.05 { circle = (c, view.intrinsics.fx * KitSyntheticKit.ball.radius / z) }
        }
        return KitLiveResult(state: .locked, tilt: tilt + 0.1 * sin(t), corners: corners, ball: circle)
    }

    /// LiDAR depth for a view (z along the optical axis, metres): the floor, the slab's top with its dish, the ball;
    /// a few millimetres of noise; nothing beyond 5 m.
    func depthMap(view: CameraView, slab: SlabPose, ball: Vec3?) -> DepthMap {
        let W = KitPhoneVideo.depthWidth, H = KitPhoneVideo.depthHeight
        let s = Double(W) / Double(view.intrinsics.width)
        let K = CameraIntrinsics(fx: view.intrinsics.fx * s, fy: view.intrinsics.fy * s, cx: view.intrinsics.cx * s, cy: view.intrinsics.cy * s,
                                 width: W, height: H)
        let o = view.position, Rw = view.worldFromCamera.rotation, n = slab.normal, R = KitSyntheticKit.ball.radius
        let dish = KitSyntheticKit.spec.dishDepth
        var depth = [Float](repeating: .nan, count: W * H), conf = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let d = Rw * K.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5))   // camera z of o + d * s is s
                var best = Double.infinity
                if d.y < 0 { best = -o.y / d.y }
                let nd = n.dot(d)
                if abs(nd) > 1e-9 {
                    var z = n.dot(slab.center - o) / nd
                    let (u, v) = slab.local(o + d * z)
                    if z > 0, abs(u) <= slab.halfU, abs(v) <= slab.halfV {
                        let dd = Dish.at(pose: slab, depth: dish, u: u, v: v).depth
                        z = n.dot(slab.center - n * dd - o) / nd
                        if z > 0 && z < best { best = z }
                    }
                }
                if let b = ball {
                    let oc = o - b, a = d.dot(d), bq = 2 * d.dot(oc), c = oc.dot(oc) - R * R
                    let disc = bq * bq - 4 * a * c
                    if disc >= 0 {
                        let z = (-bq - disc.squareRoot()) / (2 * a)
                        if z > 0 && z < best { best = z }
                    }
                }
                guard best.isFinite, best > 0.1, best < 5 else { continue }
                let i = y * W + x
                depth[i] = Float(best + rng.gauss() * (0.002 + 0.002 * best))
                conf[i] = best < 3 ? 2 : 1
            }
        }
        return DepthMap(width: W, height: H, depth: depth, confidence: conf)
    }

    func makeVideo(_ s: KitShotSpec, slab: SlabPose, tilt: Double, start: Double, date: Date, number: Int) throws -> Double {
        guard let seconds = s.kind.videoSeconds else { return 0 }
        let fps = KitPhoneVideo.fps(s)
        let size = KitPhoneVideo.videoSize(cameraWidth: options.cameraWidth, cameraHeight: options.cameraHeight)
        let K = scene.intrinsics(width: size.width, height: size.height)
        let m = try motion(s, slab: slab, start: start, seconds: seconds, K: K, number: number)
        // the recorder keeps frames until the shot's seconds of frame time, less a quarter frame
        let n = max(2, Int((seconds * fps - 0.25).rounded(.up)))
        let times = (0..<n).map { Double($0) / fps }
        let rtimes = times.map { renderTime($0, m) }
        var tr = KitSyntheticKit.ShotTruth(shotId: s.id, kind: m.kind, slab: slab, tiltDegrees: tilt)
        tr.brightness = m.brightness
        tr.heldHeight = m.heldHeight
        tr.drop = m.drop
        tr.times = times.map { start + $0 }
        tr.views = rtimes.map(m.path)
        tr.balls = rtimes.map(m.ball)

        var man = try store.newShotManifest(s.id, startedAt: date, duration: Double(n) / fps)
        man.startTime = start
        man.motionSessionId = "m1"; man.arSessionId = "a1"
        if let d = m.drop { man.releaseTime = d.cue }
        let folder = try store.beginShot(s.id)
        let hevc = options.codec == .hevc
        let rate = KitPhoneVideo.bitrate(width: size.width, height: size.height, fps: fps, hevc: hevc)
        let videoURL = folder.appendingPathComponent(KitClipFiles.video)
        let writer = try KitVideoStreamWriter(url: videoURL, width: size.width, height: size.height, fps: fps, codec: options.codec,
                                              bitrate: rate, keyFrameInterval: KitPhoneVideo.keyFrameInterval(fps: fps),
                                              noise: options.noise, preset: options.preset)
        let framesFile = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.frames))

        // the frames, rendering each distinct picture once (in parallel, a batch at a time)
        var lines: [KitFrame] = []
        var renders = 0, depthFiles = 0
        var lastDepth = -Double.infinity
        var prevPose: RigidTransform? = nil
        let exposure = m.brightness < 1 ? 1.0 / 30 : (m.brightness > 1 ? 1.0 / 120 : 1.0 / 60)
        var i = 0
        let batch = 8
        while i < n {
            // the next `batch` distinct pictures
            var groups: [(first: Int, count: Int)] = []
            var j = i
            while j < n && groups.count < batch {
                var c = 1
                while j + c < n && rtimes[j + c] == rtimes[j] { c += 1 }
                groups.append((j, c)); j += c
            }
            var images = [YCCImage?](repeating: nil, count: groups.count)
            let views = groups.map { tr.views[$0.first] }, balls = groups.map { tr.balls[$0.first] }, bright = m.brightness
            images.withUnsafeMutableBufferPointer { buf in
                let b = buf
                DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                    var sc = SyntheticScene(spec: KitSyntheticKit.spec, slab: slab, ball: balls[g])
                    sc.supersample = 1
                    sc.ballRadius = KitSyntheticKit.ball.radius
                    b[g] = KitSyntheticKit.image(sc, view: views[g], brightness: bright)
                }
            }
            renders += groups.count
            for (g, grp) in groups.enumerated() {
                guard let img = images[g] else { continue }
                let luma = img.y.withUnsafeBufferPointer { KitImageStats.meanLuma(bytes: $0, width: img.width, height: img.height, bytesPerRow: img.width) }
                for f in grp.first..<(grp.first + grp.count) {
                    try writer.append(img)
                    let t = times[f], v = tr.views[f]
                    let pose = v.worldFromCamera
                    var blur: Double? = nil
                    if let p = prevPose, f > 0 {
                        blur = KitMotionBlur.pixels(previous: p, current: pose, dt: 1 / fps, exposure: exposure, focal: K.fx)
                    }
                    prevPose = pose
                    let arkit = RigidTransform(rotation: pose.rotation * ARKitConvention.cvToARKitCamera, translation: v.position)
                    var line = KitFrame(index: f, time: start + t, pose: arkit.columnMajor4x4.map { Float($0) },
                                        intrinsics: [K.fx, K.fy, K.cx, K.cy].map { Float($0) },
                                        tracking: m.kind == .scan && t < 1 ? .limitedInitializing : .normal,
                                        exposure: exposure, exposureOffset: 0, ambientLumens: 1000 * m.brightness, colorTemperature: 4200,
                                        luma: luma, blur: blur,
                                        live: live(m, s: s, t: t, view: v, slab: slab, ball: tr.balls[f], tilt: tilt))
                    if options.lidar, t - lastDepth >= KitPhoneVideo.depthInterval - 0.25 / fps {
                        let name = KitDepth.fileName(frame: f)
                        let dir = folder.appendingPathComponent(KitClipFiles.depthFolder)
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try KitDepth(depthMap: depthMap(view: v, slab: slab, ball: tr.balls[f])).data.write(to: dir.appendingPathComponent(name))
                        line.depthFile = name
                        lastDepth = t
                        depthFiles += 1
                    }
                    try framesFile.append(line)
                    lines.append(line)
                }
            }
            i = j
        }
        try framesFile.close()
        let bytes = try writer.finish()

        // motion.jsonl at 100 Hz from the same (held between renders) camera path, through the fixed CoreMotion-to-ARKit link
        let mw = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.motion))
        var prev: Mat3? = nil
        var samples = 0
        var t = -0.05
        while t <= Double(n) / fps + 0.05 {
            let Rwa = m.path(renderTime(max(0, t), m)).worldFromCamera.rotation * ARKitConvention.cvToARKitCamera
            let q = scene.link.attitude(worldFromARKitCamera: Rwa)
            let M = q.matrix
            let rr = prev.map { KitQuaternion(matrix: $0.transposed * M).rotationVector / 0.01 } ?? .zero
            let g = M.transposed * Vec3(0, 0, -1)
            try mw.append(KitMotionSample(time: start + t, gravity: g, userAcceleration: Vec3(rng.gauss(), rng.gauss(), rng.gauss()) * 0.003,
                                          rotationRate: rr, attitude: q))
            samples += 1
            prev = M
            t += 0.01
        }
        try mw.close()

        man.video = KitVideoInfo(codec: options.codec.rawValue, width: size.width, height: size.height, fps: fps, bitrate: rate,
                                 frameCount: n, fileBytes: bytes)
        man.cameraFormat = store.manifest.device.cameraFormat
        man.hasDepth = depthFiles > 0
        man.depthFrames = depthFiles > 0 ? depthFiles : nil
        man.motionSamples = samples
        man.quality = KitQuality.evaluate(shot: s, stats: lines.map { KitFrameStat(frame: $0) },
                                          expectedFrames: KitQuality.expectedFrames(shot: s, fps: fps), reference: store.qualityReference)
        man.notes = "synthetic: a rendered scene with known truth, for the hand-off dry run"
        try store.commitShot(s.id, manifest: man, date: date)
        truth[s.id] = tr
        stats.append(ShotStats(shotId: s.id, frames: n, renders: renders, videoBytes: bytes, depthFiles: depthFiles, motionSamples: samples))
        options.log?(String(format: "%@: %d frames at %.0f fps (%d pictures), %.2f MB %@, %d depth", s.id, n, fps, renders,
                            Double(bytes) / 1e6, options.codec.rawValue, depthFiles))
        return Double(n) / fps
    }
}

#endif
