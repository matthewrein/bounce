import Foundation
@testable import BounceCore

/// An image that carries the slab detector's answer in its first row (the outline's corners as Float64 bit patterns),
/// so a detector can be a pure function of the image: the same image always gives the same outlines, and a frame the
/// app did not convert (a blank) gives none. Lets replay tests check that the replay hands the detector the same images
/// on the same frames as the phone did.
enum CornerCodeImage {
    static func make(width: Int, height: Int, outline: [Vec2]?, salt: Int, luma: [UInt8]? = nil) -> YCCImage {
        var y = luma ?? [UInt8](repeating: UInt8(40 + salt % 61), count: width * height)
        if let q = outline {
            y[0] = 1
            for (k, v) in q.flatMap({ [$0.x, $0.y] }).enumerated() {
                let b = v.bitPattern
                for j in 0..<8 { y[1 + k * 8 + j] = UInt8((b >> (8 * UInt64(j))) & 255) }
            }
        } else {
            y[0] = 0
        }
        let c = ((width + 1) / 2) * ((height + 1) / 2)
        return YCCImage(width: width, height: height, y: y, cb: [UInt8](repeating: 128, count: c), cr: [UInt8](repeating: 128, count: c))
    }

    static func decode(_ f: ColorFrame) -> [Vec2]? {
        guard f.width >= 65, f.y.data[0] == 1 else { return nil }
        var v: [Double] = []
        for k in 0..<8 {
            var b: UInt64 = 0
            for j in 0..<8 { b |= UInt64(UInt8(f.y.data[1 + k * 8 + j])) << (8 * UInt64(j)) }
            v.append(Double(bitPattern: b))
        }
        return (0..<4).map { Vec2(v[2 * $0], v[2 * $0 + 1]) }
    }
}

/// The slab detector for CornerCodeImage frames: returns the outline the image carries (and counts its calls).
final class CornerCodeDetector: SlabDetecting {
    private(set) var calls = 0
    private(set) var blankCalls = 0
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        calls += 1
        if frame.width < 65 { blankCalls += 1 }
        return CornerCodeImage.decode(frame).map { [DetectedOutline(quad: $0, score: 1, sideModes: ["top", "top", "top", "top"])] } ?? []
    }
}

/// A detector that remembers something between calls (as SlabFinderDetector keeps its edge choices): each call moves
/// the outline its image carries a little further, so a replay matches the phone only if it makes a new one whenever the
/// phone did.
final class DriftingCodeDetector: SlabDetecting {
    private(set) var calls = 0
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        calls += 1
        let d = 0.004 * Double(calls)
        return CornerCodeImage.decode(frame).map { [DetectedOutline(quad: $0.map { $0 + Vec2(d, -d) })] } ?? []
    }
}

/// A ball finder that is a pure function of its image and intrinsics: the bright disc's centroid and area give the
/// circle, and its size the distance. Records what it was given.
final class DiscBallLocator: BallLocating {
    struct Call: Equatable { var width: Int; var height: Int; var intrinsics: CameraIntrinsics; var sum: Double; var slabNormal: Vec3 }
    private(set) var calls: [Call] = []
    private(set) var resets = 0
    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        calls.append(Call(width: image.width, height: image.height, intrinsics: intrinsics, sum: image.data.reduce(0) { $0 + Double($1) },
                          slabNormal: slab.normal))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y] > 150 {
                let w = Double(image[x, y] - 60) / 170
                sx += (Double(x) + 0.5) * w; sy += (Double(y) + 0.5) * w; n += w
            }
        }
        guard n > 4 else { return nil }
        let c = Vec2(sx / n, sy / n), r = (n / .pi).squareRoot()
        guard let B = Bounce.ballCenter(pixel: c, radiusPixels: r, intrinsics: intrinsics, ball: ball, model: .onAxis) else { return nil }
        return (B, c, r)
    }
    func reset() { resets += 1 }
}

/// Runs the app's per-frame loop (ARController.handle) on a synthetic session and records it the way the app should:
/// 60 frames a second, the app's tracker settings, the image converted only when the tracker or the recording needs
/// it, a ball crop (full camera image, shrunk) whenever the ball finder is due, LiDAR depth while locked, ARKit's floor
/// once there is a slab, and taps, a settings change, a reset, a world-frame discontinuity and a spell of limited
/// tracking along the way. (The detector here reads only luma, so the "phone" hands it a grey frame of the image's
/// luma, which is cheaper than the colour conversion in a debug build; the replay converts the image as the app does.)
struct AppLoopSim {
    var world: World
    /// the full camera image (the processing frame is a third of its size: 320 x 240)
    var full = CameraIntrinsics(fx: 725, fy: 725, cx: 480, cy: 360, width: 960, height: 720)
    var factor = 3
    var fps = 60.0
    var duration = 7.0
    var noise = 0.4
    /// the held ball's centre (world) from `ballFrom` seconds on
    var ball: Vec3? = nil
    var ballFrom = 1.5
    var tapAt: Double? = 2.5
    /// a tap on the floor beside the slab at this time (with the app's tap hints a slab tap: it looks there and, finding
    /// nothing, keeps the lock)
    var floorTapAt: Double? = nil
    /// a tap on the slab at this time (before the lock: a slab tap that starts the search over there, its place from the
    /// frame's LiDAR depth, which the app reads on a slab tap's frame)
    var slabTapAt: Double? = nil
    var settingsAt: Double? = 3.0
    var resetAt: Double? = 3.5
    var discontinuityAt: Double? = 5.0
    var limited: ClosedRange<Double>? = 5.5...6.0
    var depthScale = 0.6
    var ballPixels: RecordingCadence.BallPixels = .crop
    /// draw the processing image from the full camera image (the ball shows in it; slower)
    var imagesFromFull = false
    var ballMaxSide = 300
    /// a version 1 recorder instead: a line (with image and whole depth) only every 0.2 s, nothing else
    var version1 = false
    /// the app makes a new tracker (and new detectors) at this time, as when the camera restarts
    var restartAt: Double? = nil
    /// the slab detector to make for each new tracker (default: one CornerCodeDetector for the whole run)
    var makeDetector: (() -> SlabDetecting)? = nil
    /// the ball finder for the whole run (default: the run's DiscBallLocator)
    var ballLocator: BallLocating? = nil
    /// the camera's full-resolution pixels for the slab's edges (`TrackerFrame.slabDetail`), cut from the virtual full
    /// image as `FrameConversion.lumaCrop` would
    var slabCrops = false

    init(world: World) { self.world = world }

    var processing: CameraIntrinsics {
        let K = full.scaled(by: 1 / Double(factor))
        return CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, width: full.width / factor, height: full.height / factor)
    }

    func fullView(_ t: Double) -> CameraView {
        let pos = Vec3(0.12 * sin(t * 0.7), 0.9 + 0.03 * cos(t * 0.9), 0.05 * sin(t * 0.4))
        var w = world; w.intrinsics = full
        return w.view(from: pos, at: world.slab.center + Vec3(0.02 * sin(t * 1.3), 0, 0))
    }

    /// What the phone did, frame by frame.
    struct Run {
        var outputs: [TrackerOutput] = []
        var times: [Double] = []
        var tracker: SlabTracker
        var detector: CornerCodeDetector
        var ballLocator: DiscBallLocator
        var ballFrames = 0
    }

    /// The full camera image's luma at pixel (X, Y): a plain floor (61) and a bright ball (230).
    func fullLuma(_ X: Int, _ Y: Int, ballPx: (Vec2, Double)?) -> UInt8 {
        if let (c, r) = ballPx {
            let dx = Double(X) + 0.5 - c.x, dy = Double(Y) + 0.5 - c.y
            if dx * dx + dy * dy < r * r { return 230 }
        }
        return 61
    }

    /// FrameConversion.lumaCrop on the virtual full image: k x k block averages (integer sums times 1/k^2), worked out
    /// pixel by pixel only around the ball (the rest is plain).
    func lumaCrop(_ c: BallImageCrop, ballPx: (Vec2, Double)?) -> Plane {
        let w = c.imageWidth, h = c.imageHeight, k = c.factor
        let inv = 1 / Float(k * k)
        var d = [Float](repeating: Float(61 * k * k) * inv, count: w * h)
        guard let (bc, r) = ballPx else { return Plane(width: w, height: h, data: d) }
        let xa = max(0, Int(floor((bc.x - r - Double(c.x0)) / Double(k))) - 1), xb = min(w - 1, Int(ceil((bc.x + r - Double(c.x0)) / Double(k))) + 1)
        let ya = max(0, Int(floor((bc.y - r - Double(c.y0)) / Double(k))) - 1), yb = min(h - 1, Int(ceil((bc.y + r - Double(c.y0)) / Double(k))) + 1)
        guard xa <= xb, ya <= yb else { return Plane(width: w, height: h, data: d) }
        for yy in ya...yb {
            for xx in xa...xb {
                var s = 0
                for dy in 0..<k { for dx in 0..<k { s += Int(fullLuma(c.x0 + xx * k + dx, c.y0 + yy * k + dy, ballPx: ballPx)) } }
                d[yy * w + xx] = Float(s) * inv
            }
        }
        return Plane(width: w, height: h, data: d)
    }

    /// LiDAR depth of the slab's (dished) top, everything else 3 m; only the slab's neighbourhood is ray-cast.
    func depth(_ v: CameraView) -> (DepthMap, CameraIntrinsics) {
        let K = v.intrinsics.scaled(by: depthScale), slab = world.slab, spec = SlabSpec.standard
        var d = [Float](repeating: 3, count: K.width * K.height), c = [UInt8](repeating: 2, count: K.width * K.height)
        let q = slab.topCorners.compactMap { K.project(v.toCamera($0)) }
        if q.count == 4 {
            let x0 = max(0, Int(q.map { $0.x }.min()!) - 2), x1 = min(K.width - 1, Int(q.map { $0.x }.max()!) + 2)
            let y0 = max(0, Int(q.map { $0.y }.min()!) - 2), y1 = min(K.height - 1, Int(q.map { $0.y }.max()!) + 2)
            let plane = Plane3(point: slab.center, normal: slab.normal)
            if x1 >= x0 && y1 >= y0 {
                for y in y0...y1 {
                    for x in x0...x1 {
                        let r = v.worldFromCamera.applyDirection(K.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5)))
                        guard var p = plane.intersect(origin: v.position, direction: r) else { continue }
                        var (u, w) = slab.local(p)
                        guard abs(u) < slab.halfU, abs(w) < slab.halfV else { continue }
                        for _ in 0..<4 {
                            let dish = Dish.at(pose: slab, depth: spec.dishDepth, u: u, v: w).depth
                            guard let p2 = Plane3(point: slab.center - slab.normal * dish, normal: slab.normal).intersect(origin: v.position, direction: r) else { break }
                            p = p2; (u, w) = slab.local(p)
                        }
                        d[y * K.width + x] = Float(v.toCamera(p).z); c[y * K.width + x] = 2
                    }
                }
            }
        }
        return (DepthMap(width: K.width, height: K.height, depth: d, confidence: c), K)
    }

    /// Run the session and record it into `folder`. `dropPixels`: frames (line indices) whose image and ball image are
    /// left out (as when the phone's disk falls behind).
    func run(recordingTo folder: URL, dropPixels: Set<Int> = []) throws -> Run {
        // the app's settings on the World's slab and ball (7 in square, `BallSpec()`'s 35 mm), as the session records them
        let appSettings = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 35, dishBounce: false)
        var settings = appSettings.trackerSettings
        settings.spec = .standard
        let det = CornerCodeDetector(), loc = DiscBallLocator()
        let ballLoc: BallLocating = ballLocator ?? loc
        var tracker = SlabTracker(settings: settings, detector: makeDetector?() ?? det, ballLocator: ballLoc)
        let pK = processing
        let session = RecordingSession(build: "sim", device: "sim", frameWidth: pK.width, frameHeight: pK.height,
                                       settings: appSettings, tracker: version1 ? nil : tracker.settings,
                                       everyFrame: version1 ? nil : true, trackerStateAtStart: version1 ? nil : tracker.state)
        let writer = try RecordingWriter(folder: folder, session: session)
        var cadence = RecordingCadence(imageInterval: 0.2, ballPixels: ballPixels)
        var run = Run(tracker: tracker, detector: det, ballLocator: loc)
        var rng = SeededRandom(77)
        let blank = ColorFrame(gray: Plane(width: 2, height: 2))
        var lastV1 = -Double.infinity
        let n = Int(duration * fps)
        for i in 0..<n {
            let t = Double(i) / fps
            let prev = i > 0 ? Double(i - 1) / fps : -1
            func crossed(_ x: Double?) -> Bool { x.map { prev < $0 && t >= $0 } ?? false }
            // the app's controls, between frames
            if crossed(settingsAt) { var s = tracker.settings; s.launchRule = .dishNormal; s.ballInterval = 0.15; tracker.settings = s }
            if crossed(resetAt) { tracker.reset() }
            if crossed(discontinuityAt) { tracker.noteWorldDiscontinuity("interruption") }
            if crossed(restartAt) { tracker = SlabTracker(settings: tracker.settings, detector: makeDetector?() ?? det, ballLocator: ballLoc) }
            let fv = fullView(t)
            let pv = CameraView(worldFromCamera: fv.worldFromCamera, intrinsics: pK)
            let normal = !(limited?.contains(t) ?? false)
            var tap: Vec2? = nil
            if crossed(tapAt) { tap = pv.project(world: world.slab.center) }
            if crossed(floorTapAt) { tap = pv.project(world: Vec3(world.slab.center.x + 0.4, 0, world.slab.center.z + 0.2)) }
            if crossed(slabTapAt) { tap = pv.project(world: world.slab.center) }
            // the detector's answer in this frame's image (noise drawn every frame, whether or not it is converted)
            let truth = world.slab.topCorners.compactMap { pv.project(world: $0) }
            let inView = truth.count == 4 && truth.allSatisfy { pK.contains($0, margin: 2) }
            let noisy = truth.map { Vec2($0.x + rng.gaussian() * noise, $0.y + rng.gaussian() * noise) }
            let recordDue = version1 ? t - lastV1 >= 0.2 : cadence.needsImage(at: t, tracker: tracker)
            // (a tap makes the detector run only when it is taken for the slab, as in the app)
            let slabTap = tap.map { tracker.tapSeedsSlab($0, view: pv) } ?? false
            let needImage = tracker.detectionDue(at: t, tap: slabTap) || recordDue
            let ballW = (ball != nil && t >= ballFrom) ? ball : nil
            let bp: (Vec2, Double)? = ballW.flatMap { b in fv.project(world: b).map { ($0, full.fx * BallSpec().radius / fv.toCamera(b).z) } }
            var luma: [UInt8]? = nil
            if needImage && imagesFromFull {
                let p = lumaCrop(BallImageCrop(x0: 0, y0: 0, width: full.width, height: full.height, factor: factor), ballPx: bp)
                luma = p.data.map { UInt8($0.rounded(.down)) }
            }
            let ycc: YCCImage? = needImage ? CornerCodeImage.make(width: pK.width, height: pK.height, outline: inView ? noisy : nil, salt: i, luma: luma) : nil
            var depth: (DepthMap, CameraIntrinsics)? = nil
            if tracker.state == .locked || recordDue || slabTap { depth = self.depth(pv) }
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil, crop: BallImageCrop? = nil
            if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let c = BallImageCrop.plan(slab: s, full: fv, maxSide: ballMaxSide) {
                ballImage = lumaCrop(c, ballPx: bp); ballK = c.intrinsics(full: full); crop = c
                run.ballFrames += 1
            }
            let floorY: Double? = tracker.slab != nil ? 0.0 : nil
            let slabDetail: (([Vec2]) -> SlabDetail?)? = !slabCrops ? nil : SlabImageCrop.provider(processing: pK, full: full) { c in
                self.lumaCrop(BallImageCrop(x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor), ballPx: bp)
            }
            let tf = TrackerFrame(timestamp: t, view: pv, frame: ycc.map { ColorFrame(gray: $0.luma) } ?? blank, depth: depth?.0, depthIntrinsics: depth?.1,
                                  ballImage: ballImage, ballIntrinsics: ballK, tap: tap, floorY: floorY, trackingNormal: normal, slabDetail: slabDetail)
            let out = tracker.process(tf)
            run.outputs.append(out); run.times.append(t)
            if version1 {
                if recordDue, let img = ycc {
                    lastV1 = t
                    var rf = RecordedFrame(index: 0, timestamp: t, file: "", worldFromCamera:
                        RigidTransform(rotation: pv.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: pv.position).columnMajor4x4,
                        intrinsics: pK, trackingNormal: normal)
                    rf.depthIntrinsics = depth?.1
                    try writer.append(rf, image: img, depth: depth?.0)
                }
            } else {
                var r = cadence.record(tf, output: out, tracker: tracker, image: ycc, ballCrop: crop)
                if dropPixels.contains(i) { r.image = nil; r.ball = nil; r.slab = nil }
                try writer.append(r.frame, image: r.image, depth: r.depth, ball: r.ball, slab: r.slab)
            }
        }
        writer.close()
        run.tracker = tracker
        return run
    }
}
