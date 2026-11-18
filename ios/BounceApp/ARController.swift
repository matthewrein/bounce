import ARKit
import AVFoundation
import BounceCore
import CoreMotion
import Foundation
import UIKit
import simd

/// One frame from the camera or from the demo, with its pixels read only when needed (and only while the call that
/// receives it runs: nothing here keeps an ARFrame alive).
struct SourceFrame {
    let timestamp: Double
    /// the camera for the full image (ARKit: the captured image; demo: the rendered frame), CV axes, world y up
    let fullView: BounceCore.CameraView
    /// the detectors' image is the full image shrunk by this factor
    let factor: Int
    let trackingNormal: Bool
    let trackingText: String
    /// normalised image coordinates -> normalised view coordinates (ARKit's display transform, or aspect-fill for the demo)
    let displayTransform: CGAffineTransform
    let ycc: () -> YCCImage?
    /// full-resolution luma crop: (x0, y0, width, height, shrink factor)
    let lumaCrop: (Int, Int, Int, Int, Int) -> Plane?
    let depth: () -> (DepthMap, CameraIntrinsics)?
    let exposureDuration: Double?

    // for the capture kit's recorder (KitRecorder), read only while a kit shot records
    /// the frame's time on the system's uptime clock, the clock of CoreMotion (ARKit: the frame's timestamp; demo: when
    /// the frame was rendered)
    let clock: Double
    /// ARKit's world-from-camera transform as ARKit gives it (ARKit camera axes, column-major Floats)
    let arkitPose: [Float]
    let kitTracking: KitTracking
    /// exposure offset (EV) and ARKit's light estimate (lumens, kelvin), if known
    let exposureOffset: Double?
    let ambientLumens: Double?
    let colorTemperature: Double?
    /// mean luma (0-255) of the full image, every 8th pixel, straight from the camera buffer's Y plane
    let meanLuma: () -> Double?
    /// scales the full image into a bi-planar 4:2:0 buffer of the video's size, synchronously; false if it cannot
    let fillVideo: (CVPixelBuffer) -> Bool
}

/// Runs the AR session (or the demo) and feeds every frame through BounceCore's tracker on a background queue, then
/// hands the overlay (already in view points), the readouts and the developer line to the UI. Records a session
/// (Settings > Developer) in the recording format's version 2: a line for every frame the tracker processed.
final class ARController: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var depthSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    static var smoothedDepthSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) }

    let session = ARSession()
    weak var model: AppModel?

    private let queue = DispatchQueue(label: "slabbounce.processing", qos: .userInteractive)
    /// The app's one CMMotionManager (Apple recommends a single one per app): 60 Hz, read by session recordings; while
    /// the capture kit is open, 100 Hz in the xArbitraryZVertical frame with a handler on `motionQueue`.
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "slabbounce.motion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    private let lock = NSLock()

    // shared with the main thread (guarded by `lock`)
    private var viewport = CGSize(width: 390, height: 844)
    private var pendingTap: CGPoint? = nil
    private var pendingSettings: AppSettings? = nil
    private var resetRequested = false
    /// the capture kit's motion handler (motion queue) and the latest 100 Hz sample, while the kit is open
    private var kitMotionHandler: ((KitMotionSample) -> Void)? = nil
    private var latestKitMotion: CMDeviceMotion? = nil
    /// ids of the current ARKit run and CoreMotion run (new ones whenever either restarts), for the kit's shot.json
    private var arRunId = UUID().uuidString
    private var motionRunId = UUID().uuidString
    /// Settings > Developer > Pre-flight, while it runs: it sees every camera frame and motion sample
    private var preflightTap: PreflightTap? = nil
    /// CoreMotion errors in the current motion run (the first few are logged)
    private var motionErrors = 0

    // main thread
    /// the capture kit is open: ARKit runs its 4:3 format with the highest frame rate, CoreMotion at 100 Hz
    private var kitMode = false
    /// the camera (not the demo) is running
    private var cameraRunning = false
    /// the format the capture kit chose (nil in the demo or before the camera ran in kit mode)
    private(set) var kitCameraFormat: KitCameraFormat? = nil

    // processing-queue state
    private var tracker: SlabTracker
    private var settings = AppSettings()
    private var floorYs: [UUID: Double] = [:]
    private var captureLocked = false
    private var lastTracking = "not started"
    private var sawRelocalizing = false
    private var lastOutput: TrackerOutput? = nil
    private var lastView: BounceCore.CameraView? = nil
    private var lastBallCrop: BallImageCrop? = nil
    private var lastFloorY: Double? = nil
    private var lastFrameTime = 0.0
    private var lastDisplayTransform: CGAffineTransform = .identity
    private var lastLens: CameraIntrinsics? = nil
    private var videoFormat: DiagnosticsReport.VideoFormat? = nil
    private var frameTimes: [Double] = []
    private var msAverage = 0.0
    private var recentEvents: [String] = []
    private var recorder: SessionRecorder? = nil
    private var recordRequested = false
    private var cadence = RecordingCadence()
    /// the capture kit's shot recorder, while a kit shot records (it says when it has enough frames)
    private var kitRecorder: KitRecorder? = nil

    // the demo (no camera)
    private var demoTimer: DispatchSourceTimer? = nil
    private var demoScript: DemoScript? = nil
    private var demoStart = 0.0
    private(set) var isDemo = false

    override init() {
        tracker = SlabTracker(settings: AppSettings().tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    // MARK: control (main thread)

    func start(settings s: AppSettings) {
        let c = makeConfiguration()
        queue.async {
            self.unlockCapture()
            self.settings = s
            self.tracker = SlabTracker(settings: s.tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
            self.floorYs = [:]
            self.sawRelocalizing = false
            self.lastBallCrop = nil
        }
        noteFormat(c.videoFormat)
        session.run(c, options: [.resetTracking, .removeExistingAnchors])
        cameraRunning = true
        newRunId(ar: true, motion: false)
        startMotion()
    }

    /// The session's configuration: gravity-aligned world tracking, horizontal planes, LiDAR depth where the phone has
    /// it, and the video format (the app's, or the capture kit's while the kit is open).
    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = [.horizontal]
        c.isAutoFocusEnabled = true
        // LiDAR depth where the phone has it: the tracker reads the smoothed map, the raw one while that has none yet
        if ARController.depthSupported { c.frameSemantics.insert(.sceneDepth) }
        if ARController.smoothedDepthSupported { c.frameSemantics.insert(.smoothedSceneDepth) }
        if let f = kitMode ? ARController.kitVideoFormat() : ARController.appVideoFormat() { c.videoFormat = f }
        if kitMode {
            let vf = c.videoFormat
            kitCameraFormat = KitCameraFormat(width: Int(vf.imageResolution.width), height: Int(vf.imageResolution.height),
                                              fps: Double(vf.framesPerSecond))
        }
        return c
    }

    /// 4:3 formats up to 1920 wide
    private static var fourByThreeFormats: [ARConfiguration.VideoFormat] {
        ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) < 0.01 && $0.imageResolution.width <= 1920 }
    }

    /// The app's format: the highest-resolution 4:3 format up to 1920 wide (usually 1920x1440); the detectors use a
    /// quarter of it.
    static func appVideoFormat() -> ARConfiguration.VideoFormat? {
        fourByThreeFormats.max { $0.imageResolution.width < $1.imageResolution.width }
    }

    /// The capture kit's format: 4:3 up to 1920 wide with the highest frame rate (then the highest resolution).
    static func kitVideoFormat() -> ARConfiguration.VideoFormat? {
        fourByThreeFormats.max { a, b in
            a.framesPerSecond != b.framesPerSecond ? a.framesPerSecond < b.framesPerSecond : a.imageResolution.width < b.imageResolution.width
        }
    }

    private func noteFormat(_ vf: ARConfiguration.VideoFormat) {
        let format = DiagnosticsReport.VideoFormat(width: Int(vf.imageResolution.width), height: Int(vf.imageResolution.height),
                                                   framesPerSecond: vf.framesPerSecond)
        queue.async { self.videoFormat = format }
    }

    func stop() {
        session.pause()
        cameraRunning = false
        motion.stopDeviceMotionUpdates()
        lock.lock(); latestKitMotion = nil; lock.unlock()
        queue.async { self.unlockCapture(); self.kitRecorder = nil }
        stopDemo()
    }

    // MARK: the capture kit (main thread; Settings > Developer > Capture kit)

    /// The capture kit opened (or closed). Open: ARKit's 4:3 format with the highest frame rate, re-run WITHOUT
    /// resetting tracking, and CoreMotion at 100 Hz in the xArbitraryZVertical frame, every sample handed to `handler`
    /// (on the motion queue). Closed: the app's format and 60 Hz motion again. New run ids either way. In the demo only
    /// the mode is noted (there is no camera or motion; `start` applies it when the camera runs).
    func setKitMode(_ on: Bool, motion handler: ((KitMotionSample) -> Void)?) {
        kitMode = on
        if !on { kitCameraFormat = nil }
        lock.lock(); kitMotionHandler = on ? handler : nil; lock.unlock()
        newRunId(ar: true, motion: true)
        guard cameraRunning else { return }
        let c = makeConfiguration()
        let current = session.configuration?.videoFormat
        if current?.imageResolution != c.videoFormat.imageResolution || current?.framesPerSecond != c.videoFormat.framesPerSecond {
            noteFormat(c.videoFormat)
            session.run(c, options: [])   // no reset: the world, and the slab's lock, carry on
        }
        startMotion()
    }

    /// Ids of the current ARKit run and CoreMotion run: the kit writes them into every shot.json.
    var runIds: (ar: String, motion: String) {
        lock.lock(); defer { lock.unlock() }
        return (arRunId, motionRunId)
    }

    private func newRunId(ar: Bool, motion m: Bool) {
        lock.lock()
        if ar { arRunId = UUID().uuidString }
        if m { motionRunId = UUID().uuidString }
        lock.unlock()
    }

    /// Device motion: 100 Hz with a handler while the kit is open (or the pre-flight runs), else 60 Hz read by the
    /// session recordings.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.stopDeviceMotionUpdates()
        lock.lock(); latestKitMotion = nil; motionErrors = 0; let push = kitMode || preflightTap != nil; lock.unlock()
        newRunId(ar: false, motion: true)
        if push {
            motion.deviceMotionUpdateInterval = 1.0 / 100
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] m, e in
                if let e = e { self?.motionFailed(e) }
                guard let self = self, let m = m else { return }
                self.kitMotion(m)
            }
        } else {
            motion.deviceMotionUpdateInterval = 1.0 / 60
            motion.startDeviceMotionUpdates()
        }
    }

    /// One 100 Hz sample (motion queue): kept for the session recording, handed to the kit. Only while the kit is open:
    /// a sample CoreMotion had already queued when the kit closed (or the app stopped) is dropped, so no stale sample is
    /// kept for later.
    private func kitMotion(_ m: CMDeviceMotion) {
        let q = m.attitude.quaternion
        let s = KitMotionSample(time: m.timestamp, gravity: Vec3(m.gravity.x, m.gravity.y, m.gravity.z),
                                userAcceleration: Vec3(m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z),
                                rotationRate: Vec3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                                attitude: KitQuaternion(x: q.x, y: q.y, z: q.z, w: q.w))
        lock.lock()
        let h = kitMotionHandler, p = preflightTap
        if h != nil || p != nil { latestKitMotion = m }
        lock.unlock()
        h?(s)
        p?.motionSample(s)
    }

    /// CoreMotion reported an error (motion queue): the first few of each run go to the log.
    private func motionFailed(_ e: Error) {
        lock.lock(); motionErrors += 1; let n = motionErrors; lock.unlock()
        if n <= 5 { AppLog.error("motion", "device motion error (\(n) in this run)", e) }
    }

    /// The latest device motion, whichever way it is running (the kit's cached sample only while the kit is open).
    private func currentMotion() -> CMDeviceMotion? {
        lock.lock(); let k = kitMotionHandler != nil || preflightTap != nil ? latestKitMotion : nil; lock.unlock()
        return k ?? motion.deviceMotion
    }

    /// The kit's shot recorder takes frames from the next one on, until it has enough (it detaches itself) or is detached.
    func attachKitRecorder(_ r: KitRecorder) { queue.async { self.kitRecorder = r } }
    func detachKitRecorder() { queue.async { self.kitRecorder = nil } }

    // MARK: the pre-flight (main thread; Settings > Developer > Pre-flight)

    /// While `tap` is set, it sees every camera frame and every device-motion sample (motion then runs at 100 Hz with a
    /// handler, as for the kit); nil ends it and motion goes back to how it ran. The session and its video format are
    /// left as they are.
    func setPreflight(_ tap: PreflightTap?) {
        lock.lock(); preflightTap = tap; lock.unlock()
        guard !kitMode else { return }   // the kit's 100 Hz run already hands every sample over
        if tap != nil || cameraRunning { startMotion() } else { motion.stopDeviceMotionUpdates() }
    }

    private func preflightTapNow() -> PreflightTap? { lock.lock(); defer { lock.unlock() }; return preflightTap }

    /// CoreMotion's device motion exists here (not in the Simulator)
    var motionAvailable: Bool { motion.isDeviceMotionAvailable }

    /// the running camera format's frame rate (nil while the camera is not running)
    var videoFps: Double? { cameraRunning ? session.configuration.map { Double($0.videoFormat.framesPerSecond) } : nil }

    /// the demo's frame interval (s)
    static let demoFrameInterval = 0.08

    /// Run the synthetic demo scene instead of the camera (no ARKit needed: works in the Simulator).
    func startDemo(script: DemoScript, settings s: AppSettings) {
        session.pause()
        cameraRunning = false
        newRunId(ar: true, motion: false)
        queue.async {
            self.unlockCapture()
            self.settings = s
            self.tracker = SlabTracker(settings: s.tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
            self.lastBallCrop = nil
            self.videoFormat = nil
            self.demoScript = script
            self.demoStart = CACurrentMediaTime()
            self.isDemo = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(Int(ARController.demoFrameInterval * 1000)), leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.demoTick() }
            self.demoTimer?.cancel()
            self.demoTimer = t
            t.resume()
        }
    }

    func stopDemo() {
        queue.async {
            self.demoTimer?.cancel(); self.demoTimer = nil; self.demoScript = nil; self.isDemo = false
        }
    }

    func update(settings s: AppSettings) {
        lock.lock(); pendingSettings = s; lock.unlock()
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lock.lock(); viewport = size; lock.unlock()
    }

    func tap(at p: CGPoint) {
        lock.lock(); pendingTap = p; lock.unlock()
    }

    func resetTracking() {
        lock.lock(); resetRequested = true; lock.unlock()
    }

    // MARK: sources (processing queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !isDemo else { return }
        let camera = frame.camera
        var text = "normal", normal = false, relocalizing = false
        var kt = KitTracking.normal
        switch camera.trackingState {
        case .normal: normal = true
        case .notAvailable: text = "not available"; kt = .notAvailable
        case .limited(let r):
            switch r {
            case .initializing: text = "limited: initializing"; kt = .limitedInitializing
            case .excessiveMotion: text = "limited: moving too fast"; kt = .limitedExcessiveMotion
            case .insufficientFeatures: text = "limited: too few features"; kt = .limitedInsufficientFeatures
            case .relocalizing: text = "limited: relocalizing"; relocalizing = true; kt = .limitedRelocalizing
            @unknown default: text = "limited"; kt = .limitedOther
            }
        }
        // ARKit relocalised: its world frame may have moved under the lock
        if relocalizing { sawRelocalizing = true }
        if normal && sawRelocalizing {
            sawRelocalizing = false
            tracker.noteWorldDiscontinuity("relocalized")
            note("relocalized")
        }
        // the pre-flight sees every frame ARKit delivers (ahead of any early return), with the app's work per frame
        if let p = preflightTapNow() { p.frame(frame, tracking: kt, processingMs: msAverage) }
        let full = FrameConversion.view(camera)
        let factor = max(1, full.intrinsics.width / 480)   // about 480 px wide for the detectors
        lock.lock(); let vp = viewport; lock.unlock()
        let pb = frame.capturedImage
        let sf = SourceFrame(
            timestamp: frame.timestamp, fullView: full, factor: factor, trackingNormal: normal, trackingText: text,
            displayTransform: frame.displayTransform(for: .portrait, viewportSize: vp),
            ycc: { FrameConversion.ycc(pb, factor: factor) },
            lumaCrop: { x0, y0, w, h, k in FrameConversion.lumaCrop(pb, x0: x0, y0: y0, width: w, height: h, factor: k) },
            depth: {
                guard let sd = frame.smoothedSceneDepth ?? frame.sceneDepth, let d = FrameConversion.depth(sd) else { return nil }
                return (d, full.intrinsics.scaled(by: Double(d.width) / Double(full.intrinsics.width)))
            },
            exposureDuration: camera.exposureDuration,
            clock: frame.timestamp, arkitPose: FrameConversion.columnMajorFloats(camera.transform), kitTracking: kt,
            exposureOffset: Double(camera.exposureOffset),
            ambientLumens: frame.lightEstimate.map { Double($0.ambientIntensity) },
            colorTemperature: frame.lightEstimate.map { Double($0.ambientColorTemperature) },
            meanLuma: { FrameConversion.meanLuma(pb) },
            fillVideo: { dst in FrameConversion.scale(pb, into: dst) })
        handle(sf, viewport: vp)
    }

    private func demoTick() {
        guard let script = demoScript else { return }
        let t = CACurrentMediaTime() - demoStart
        let scene = script.scene(at: t, spec: AppSettings.slab), view = script.view(at: t)
        let K = view.intrinsics
        let rgb = scene.renderRGB(view: view)
        let img = SyntheticScene.ycc(rgb: rgb, width: K.width, height: K.height)
        lock.lock(); let vp = viewport; lock.unlock()
        // the frame fills the view (aspect fill, centred), as the camera feed does
        let s = max(vp.width / CGFloat(K.width), vp.height / CGFloat(K.height))
        let ox = (vp.width - CGFloat(K.width) * s) / 2, oy = (vp.height - CGFloat(K.height) * s) / 2
        let tr = CGAffineTransform(a: CGFloat(K.width) * s / vp.width, b: 0, c: 0, d: CGFloat(K.height) * s / vp.height,
                                   tx: ox / vp.width, ty: oy / vp.height)
        let sf = SourceFrame(
            timestamp: t, fullView: view, factor: 1, trackingNormal: true, trackingText: "demo", displayTransform: tr,
            ycc: { img },
            lumaCrop: { x0, y0, w, h, k in
                let p = img.luma.cropped(x0: x0, y0: y0, width: w, height: h)
                return k > 1 ? p.downscaled(by: k) : p
            },
            depth: { nil }, exposureDuration: nil,
            clock: demoStart + t, arkitPose: FrameConversion.arkitPose(view), kitTracking: .normal,
            exposureOffset: nil, ambientLumens: nil, colorTemperature: nil,
            meanLuma: { img.y.withUnsafeBufferPointer { KitImageStats.meanLuma(bytes: $0, width: img.width, height: img.height, bytesPerRow: img.width, step: 8) } },
            fillVideo: { dst in FrameConversion.fill(dst, from: img) })
        let cg = DemoImage.cgImage(rgb: rgb, width: K.width, height: K.height)
        handle(sf, viewport: vp, background: cg)
    }

    // MARK: processing (processing queue)

    private func handle(_ f: SourceFrame, viewport vp: CGSize, background: CGImage? = nil) {
        let t0 = CACurrentMediaTime()
        lock.lock()
        let tapView = pendingTap, newSettings = pendingSettings, reset = resetRequested
        pendingTap = nil; pendingSettings = nil; resetRequested = false
        lock.unlock()
        lastFrameTime = f.timestamp

        // what is done to the tracker between frames (it reports each with this frame, so a recording keeps them)
        if let s = newSettings, s != settings {
            settings = s
            tracker.settings = s.tracker
        }
        if reset { tracker.reset(); unlockCapture(); note("reset") }

        lastTracking = f.trackingText
        lastLens = f.fullView.intrinsics
        lastDisplayTransform = f.displayTransform
        let full = f.fullView, K = full.intrinsics.scaled(by: 1 / Double(f.factor))
        let pview = BounceCore.CameraView(worldFromCamera: full.worldFromCamera,
                                          intrinsics: CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy,
                                                                       width: full.intrinsics.width / f.factor, height: full.intrinsics.height / f.factor))
        lastView = pview

        // a tap in the view -> processing-image pixels
        var tap: Vec2? = nil
        if let p = tapView {
            let n = CGPoint(x: p.x / vp.width, y: p.y / vp.height).applying(f.displayTransform.inverted())
            tap = Vec2(Double(n.x) * Double(pview.intrinsics.width), Double(n.y) * Double(pview.intrinsics.height))
        }

        // a recording starts on the first frame after it was asked for (when the frame size is known)
        if recordRequested, recorder == nil {
            recordRequested = false
            startRecorder(frameWidth: pview.intrinsics.width, frameHeight: pview.intrinsics.height)
        }

        // only convert the image when it will be used: a detection is due, a tap, or the recording wants it
        let t = f.timestamp
        let recImg = recorder != nil && cadence.needsImage(at: t, tracker: tracker)
        let needImage = tap != nil || tracker.detectionDue(at: t) || recImg
        let ycc: YCCImage? = needImage ? f.ycc() : nil
        let colorFrame = ycc?.colorFrame ?? ColorFrame(gray: Plane(width: 2, height: 2))

        // LiDAR depth, when the slab is locked (or for the recording)
        var depth: (DepthMap, CameraIntrinsics)? = nil
        if tracker.state == .locked || recImg { depth = f.depth() }

        // a full-resolution crop around the slab and the space above it, for the ball
        var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil, crop: BallImageCrop? = nil
        if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let c = BallImageCrop.plan(slab: s, full: full),
           let p = f.lumaCrop(c.x0, c.y0, c.width, c.height, c.factor), p.width == c.imageWidth, p.height == c.imageHeight {
            ballImage = p
            ballK = c.intrinsics(full: full.intrinsics)
            crop = c
        }

        let fy = floorY()
        lastFloorY = fy
        let tf = TrackerFrame(timestamp: t, view: pview, frame: colorFrame, depth: depth?.0, depthIntrinsics: depth?.1,
                              ballImage: ballImage, ballIntrinsics: ballK, tap: tap, floorY: fy, trackingNormal: f.trackingNormal)
        let out = tracker.process(tf)
        lastOutput = out
        if out.ballSearched { lastBallCrop = crop }
        if !out.events.isEmpty {
            recentEvents.append(contentsOf: out.events.map { String(format: "%.2f ", t) + $0 })
            trimEvents()
        }
        // a new search: focus, exposure and white balance back to automatic; a new lock: hold them
        if out.events.contains("tap") || out.events.contains("lost") || out.events.contains("lock-expired") { unlockCapture() }
        if out.events.contains("locked") { lockCapture() }   // (a relock is the same scene: keep the current lock)

        // recording: a line for every frame, with the pixels a replay needs (the cadence decides which)
        if let rec = recorder {
            var r = cadence.record(tf, output: out, tracker: tracker, image: ycc, ballCrop: crop)
            if let m = currentMotion(), !isDemo {
                r.frame.userAcceleration = [m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z]
                r.frame.rotationRate = [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z]
                let q = m.attitude.quaternion
                r.frame.attitude = [q.x, q.y, q.z, q.w]
            }
            r.frame.exposureDuration = f.exposureDuration
            r.frame.locked = captureLocked
            rec.append(r.frame, image: r.image, depth: r.depth, ball: r.ball)
        }

        // the capture kit's shot recorder (the frame's video picture, its numbers and the live result)
        if let kit = kitRecorder,
           !kit.consume(f, output: out, processingWidth: pview.intrinsics.width, ballRadius: tracker.settings.ball.radius) {
            kitRecorder = nil
        }

        // overlay, projected for the view, the readouts and the developer line
        let ov = overlay(out, view: full, processing: pview.intrinsics.width, pview.intrinsics.height, viewport: vp)
        let hud = makeHUD(out)
        let dev = makeDeveloperStatus(out)
        let dt = (CACurrentMediaTime() - t0) * 1000
        msAverage = msAverage == 0 ? dt : msAverage * 0.95 + dt * 0.05
        frameTimes.append(t)
        if frameTimes.count > 60 { frameTimes.removeFirst() }
        Task { @MainActor [weak model] in model?.publish(overlay: ov, hud: hud, developer: dev, background: background) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { for a in anchors { floorYs[a.identifier] = nil } }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as NSError).code
        AppLog.error("arkit", "the AR session failed", error)
        preflightTapNow()?.arkit.sessionFailed(code: code)
        queue.async { self.note("session error \(code)") }
        let msg = "Camera stopped: \(error.localizedDescription)"
        Task { @MainActor [weak model] in
            guard let m = model else { return }
            var h = m.hud; h.status = msg; h.locked = false
            m.publish(overlay: OverlayState(), hud: h, developer: m.developer, background: nil)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        AppLog.warn("arkit", "session interrupted (a call, or another app took the camera)")
        preflightTapNow()?.arkit.interrupted()
        queue.async { self.note("interrupted") }
        // a kit shot being recorded is thrown away (it stays pending)
        Task { @MainActor [weak model] in model?.cameraInterrupted() }
    }

    /// After an interruption ARKit's world frame may have moved under the lock: the tracker keeps it, unconfirmed, until
    /// it sees the slab where it should be.
    func sessionInterruptionEnded(_ session: ARSession) {
        newRunId(ar: true, motion: false)   // ARKit's world may have moved: shots after this are another run
        AppLog.info("arkit", "interruption ended")
        queue.async {
            guard !self.isDemo else { return }
            self.tracker.noteWorldDiscontinuity("interruption")
            self.note("interruption ended")
        }
    }

    private func updatePlanes(_ anchors: [ARAnchor]) {
        for case let p as ARPlaneAnchor in anchors where p.alignment == .horizontal {
            floorYs[p.identifier] = Double(p.transform.columns.3.y)
        }
    }

    /// The floor under the slab: the lowest horizontal plane between 1 cm and 60 cm below the slab's centre. (The demo's
    /// floor is at y = 0.)
    private func floorY() -> Double? {
        guard let s = tracker.slab else { return nil }
        if isDemo { return 0 }
        let cand = floorYs.values.filter { s.center.y - $0 > 0.01 && s.center.y - $0 < 0.6 }
        return cand.min()
    }

    /// An event for diagnostics, prefixed with the camera clock (words and numbers only: never paths or names).
    private func note(_ text: String) {
        recentEvents.append(String(format: "%.2f ", lastFrameTime) + text)
        trimEvents()
    }

    private func trimEvents() {
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }

    // MARK: capture locks

    /// Lock focus, exposure and white balance once the slab is found, so the image stops changing under the detector.
    private func lockCapture() {
        guard !captureLocked, !isDemo else { return }
        if let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                captureLocked = true
                note("capture locked")
            } catch {
                note("capture lock failed: error \((error as NSError).code)")
                AppLog.error("arkit", "capture lock failed", error)
            }
        }
    }

    private func unlockCapture() {
        guard captureLocked else { return }
        if let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch {
                note("capture unlock failed: error \((error as NSError).code)")
                AppLog.error("arkit", "capture unlock failed", error)
            }
        }
        captureLocked = false
    }

    // MARK: overlay

    /// World point -> view point (through the full image and the display transform).
    private func toView(_ p: Vec3, _ view: BounceCore.CameraView, _ vp: CGSize) -> CGPoint? {
        guard let q = view.project(world: p) else { return nil }
        let n = CGPoint(x: q.x / Double(view.intrinsics.width), y: q.y / Double(view.intrinsics.height)).applying(lastDisplayTransform)
        return CGPoint(x: n.x * vp.width, y: n.y * vp.height)
    }

    private func overlay(_ out: TrackerOutput, view: BounceCore.CameraView, processing pw: Int, _ ph: Int, viewport vp: CGSize) -> OverlayState {
        var o = OverlayState()
        if let m = out.measurement, out.state != .locked {
            // a detection that is not locked yet (processing pixels -> normalised image -> view)
            o.measured = m.map { q in
                let n = CGPoint(x: q.x / Double(pw), y: q.y / Double(ph)).applying(lastDisplayTransform)
                return CGPoint(x: n.x * vp.width, y: n.y * vp.height)
            }
        }
        guard out.state == .locked, let s = out.slab else { return o }
        o.outline = s.topCorners.compactMap { toView($0, view, vp) }
        if let path = out.path {
            o.path = path.samples(count: 40).compactMap { toView($0, view, vp) }
            o.start = toView(path.start, view, vp)
            if path.apexHeight > 0.005 { o.apex = toView(path.apex, view, vp) }
            o.landing = toView(path.landing, view, vp)
            o.normalTip = toView(path.start + path.direction * 0.08, view, vp)
        }
        if let b = out.ball {
            o.ball = toView(b.center, view, vp)
            let r = tracker.settings.ball.radius
            if let c = o.ball, let edge = toView(b.center + view.worldFromCamera.applyDirection(Vec3(1, 0, 0)) * r, view, vp) {
                o.ballRadius = CGFloat(hypot(edge.x - c.x, edge.y - c.y))
            }
        }
        return o
    }

    /// The main screen's status: the tracker's state, passively (no advice or instructions).
    private func makeHUD(_ out: TrackerOutput) -> HUDState {
        var h = HUDState()
        switch out.state {
        case .searching: h.status = "Looking for the slab"
        case .confirming: h.status = "Checking"
        case .locked:
            if out.lockUnconfirmed {
                h.status = "Checking"
            } else {
                h.status = out.ball != nil ? "Slab locked · ball in view" : "Slab locked"
            }
        }
        h.locked = out.state == .locked && !out.lockUnconfirmed
        if let r = out.readouts {
            h.tilt = String(format: "%.1f°", r.tiltDegrees)
            h.apex = Format.length(r.apexHeight)
            h.landing = Format.length(r.landingDistance)
            h.air = String(format: "%.2f s", r.airTime)
            h.drop = Format.length(r.dropHeight) + (r.dropFromBall ? " (ball)" : "")
        }
        h.demo = isDemo
        return h
    }

    /// The live developer line (Settings > Developer): the tracker's state, the unconfirmed lock and the tracker's hint.
    private func makeDeveloperStatus(_ out: TrackerOutput) -> DeveloperStatus {
        var d = DeveloperStatus()
        d.state = out.state.rawValue
        d.lockUnconfirmed = out.lockUnconfirmed
        d.hint = out.hint
        d.tracking = lastTracking
        if let c = out.depth {
            d.depth = String(format: "LiDAR: %.1f° tilt, %.1f° from image", c.tiltDegrees, c.angleToImageDegrees)
        }
        if let rec = recorder {
            d.recordedFrames = rec.frameCount
            d.recordingFailure = rec.failure
        }
        return d
    }

    // MARK: diagnostics and recording

    func diagnosticsJSON(settings s: AppSettings) -> String {
        var json = "{}"
        queue.sync {
            let fps: Double = frameTimes.count > 1 ? Double(frameTimes.count - 1) / max(1e-6, frameTimes.last! - frameTimes.first!) : 0
            let out = lastOutput
            var counts = tracker.counts
            if let rec = recorder {
                counts["recordedFrames"] = rec.frameCount
                counts["recordingPixelsDropped"] = rec.droppedPixels
            }
            var rep = DiagnosticsReport(build: appBuild, device: Device.model, system: "iOS \(UIDevice.current.systemVersion)",
                                        time: ISO8601DateFormatter().string(from: Date()), settings: s.recording,
                                        state: tracker.state.rawValue, tracking: lastTracking, fps: fps, msProcess: msAverage,
                                        lens: lastLens, depthSupported: ARController.depthSupported, depth: out?.depth,
                                        captureLocked: captureLocked, slab: out?.slab, outline: out?.outline, sideModes: tracker.lastSideModes,
                                        ball: out?.ball, readouts: out?.readouts, counts: counts, recentEvents: recentEvents,
                                        recording: recorder?.name, rejectionValues: tracker.rejectionValues,
                                        cornerNoisePixels: tracker.cornerNoiseEstimate, lockSigmaDegrees: out?.lockSigmaDegrees)
            rep.addTracker(tracker, view: lastView, lens: lastLens, output: out, ballCrop: lastBallCrop, floorY: lastFloorY)
            rep.videoFormat = videoFormat
            rep.thermalState = ARController.thermalState
            rep.frameTime = out != nil ? lastFrameTime : nil
            json = rep.json(pretty: true)
        }
        return json
    }

    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    func startRecording() {
        queue.async { if self.recorder == nil { self.recordRequested = true } }
    }

    /// Start the recorder (processing queue). The tracker searches afresh, so a replay starts where the phone did.
    private func startRecorder(frameWidth w: Int, frameHeight h: Int) {
        let session = RecordingSession(build: appBuild, device: Device.model, frameWidth: w, frameHeight: h, settings: settings.recording,
                                       notes: isDemo ? "Slab Bounce recording (demo scene)" : "Slab Bounce recording",
                                       createdAt: ISO8601DateFormatter().string(from: Date()),
                                       tracker: tracker.settings, everyFrame: true, trackerStateAtStart: tracker.state)
        do {
            recorder = try SessionRecorder(session: session)
            cadence = RecordingCadence()
            tracker.reset()
            unlockCapture()
            note("recording started")
            AppLog.info("session-rec", "recording started (\(w)x\(h) processing frames)")
        } catch {
            note("recording failed to start: error \((error as NSError).code)")
            AppLog.error("session-rec", "recording failed to start", error)
            let msg = "Could not start the recording: \(SessionRecorder.describe(error))"
            Task { @MainActor [weak model] in model?.recordingDidFail(msg) }
        }
    }

    func stopRecording(_ done: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            self.recordRequested = false
            guard let rec = self.recorder else { done(.failure(SessionRecorder.RecorderError.notRecording)); return }
            self.recorder = nil
            self.note("recording stopped")
            rec.finish { [weak self] result, zipBytes in
                if let b = zipBytes, let me = self { me.queue.async { me.note("recording saved: \(b / 1_000_000) MB") } }
                done(result)
            }
        }
    }
}

/// Lengths for the readouts: inches under 2 ft, feet and inches above.
enum Format {
    static func length(_ m: Double) -> String {
        let inches = Units.toInches(m)
        if abs(inches) < 24 { return String(format: "%.1f in", inches) }
        let ft = Int(inches / 12), rest = inches - Double(ft) * 12
        return String(format: "%d ft %.0f in", ft, rest)
    }
}

enum Device {
    /// e.g. "iPhone15,2" (on the Simulator, the Mac's model)
    static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The demo's frames as images for the screen.
enum DemoImage {
    static func cgImage(rgb: [UInt8], width w: Int, height h: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2] }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
