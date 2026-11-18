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
    /// skips frames that queued behind slower processing, and counts how frames came and went (diagnostics' framePacing)
    private var pacer = FramePacer()
    /// notices the camera's video format changing between frames (ARKit re-ran with another one), and knows each frame's
    /// nominal frame rate (the format asked for, once the frames show it)
    private var formatWatch = VideoFormatWatch()
    /// locks focus, exposure and white balance once the slab is locked and the camera has stopped adjusting them
    private var captureGate = CaptureLockGate()
    /// the last full-resolution crop the slab's edges were read from (diagnostics)
    private var lastSlabCrop: SlabImageCrop? = nil
    /// late frames handed to the capture kit's recorder anyway (diagnostics' counts)
    private var kitFramesWhileLate = 0
    /// the developer line's frame numbers and when they were worked out (camera clock): once a second is enough
    private var framesLine: String? = nil
    private var framesLineTime = -Double.infinity
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
            self.resetFramePipeline()
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

    /// The format the session is about to run with (call just before `session.run`). Frames captured from now on may be
    /// in it; frames captured before are in the previous one (ARFrame.timestamp and CACurrentMediaTime share a clock).
    /// The format watch notes the change on the first frame that shows it (its size, or for a change of the frame rate
    /// alone the frames' spacing), not on the old run's frames ARKit still delivers after the ask; the pacer counts the
    /// camera's stop while ARKit re-runs as a pause, not as frames it missed. (Queued on the processing queue before
    /// `session.run`, so it is known before any frame captured after the ask is handled.)
    private func noteFormat(_ vf: ARConfiguration.VideoFormat) {
        let format = DiagnosticsReport.VideoFormat(width: Int(vf.imageResolution.width), height: Int(vf.imageResolution.height),
                                                   framesPerSecond: vf.framesPerSecond)
        let asked = CACurrentMediaTime()
        queue.async {
            self.videoFormat = format
            self.formatWatch.expect(VideoFormatWatch.Format(width: format.width, height: format.height,
                                                            framesPerSecond: format.framesPerSecond > 0 ? Double(format.framesPerSecond) : nil),
                                    askedAt: asked)
            self.pacer.expectPause(at: asked)
        }
    }

    /// A new camera run or demo (processing queue): the frame numbers, the format watch and the capture lock gate start
    /// afresh.
    private func resetFramePipeline() {
        pacer = FramePacer()
        formatWatch = VideoFormatWatch()
        captureGate = CaptureLockGate()
        lastSlabCrop = nil
        kitFramesWhileLate = 0
        framesLine = nil
        framesLineTime = -.infinity
    }

    func stop() {
        session.pause()
        cameraRunning = false
        motion.stopDeviceMotionUpdates()
        lock.lock(); latestKitMotion = nil; lock.unlock()
        queue.async { _ = self.captureGate.disarm(reason: "stopped"); self.unlockCapture(); self.kitRecorder = nil }
        stopDemo()
    }

    // MARK: the capture kit (main thread; Settings > Developer > Capture kit)

    /// The capture kit opened (or closed). Open: ARKit's 4:3 format with the highest frame rate, re-run WITHOUT
    /// resetting tracking, and CoreMotion at 100 Hz in the xArbitraryZVertical frame, every sample handed to `handler`
    /// (on the motion queue). Closed: the app's format and 60 Hz motion again. New run ids either way. In the demo only
    /// the mode is noted (there is no camera or motion; `start` applies it when the camera runs). Whether ARKit's world,
    /// and the slab's lock in it, carry over such a re-run is not verified: the frames themselves show the new format
    /// (`session(_:didUpdate:)`, `formatChanged`), which is then handled as a world discontinuity.
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
            // Tracking is not reset, but that ARKit's world (and so the slab's lock) carries over a re-run with another
            // format is unverified: the first frame that shows the new format (its size; for a change of the frame rate
            // alone, frames spaced at the new rate) is a world discontinuity (the lock stays unconfirmed until it is seen
            // again in the new format) and releases the capture locks (formatChanged).
            session.run(c, options: [])
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

    /// Device motion: 100 Hz with a handler while the kit is open, else 60 Hz read by the session recordings.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.stopDeviceMotionUpdates()
        lock.lock(); latestKitMotion = nil; lock.unlock()
        newRunId(ar: false, motion: true)
        if kitMode {
            motion.deviceMotionUpdateInterval = 1.0 / 100
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] m, _ in
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
        let h = kitMotionHandler
        if h != nil { latestKitMotion = m }
        lock.unlock()
        h?(s)
    }

    /// The latest device motion, whichever way it is running (the kit's cached sample only while the kit is open).
    private func currentMotion() -> CMDeviceMotion? {
        lock.lock(); let k = kitMotionHandler != nil ? latestKitMotion : nil; lock.unlock()
        return k ?? motion.deviceMotion
    }

    /// The kit's shot recorder takes frames from the next one on, until it has enough (it detaches itself) or is detached.
    func attachKitRecorder(_ r: KitRecorder) { queue.async { self.kitRecorder = r } }
    func detachKitRecorder() { queue.async { self.kitRecorder = nil } }

    /// the demo's frame interval (s)
    static let demoFrameInterval = 0.08

    /// Run the synthetic demo scene instead of the camera (no ARKit needed: works in the Simulator).
    func startDemo(script: DemoScript, settings s: AppSettings) {
        session.pause()
        cameraRunning = false
        newRunId(ar: true, motion: false)
        queue.async {
            self.unlockCapture()
            self.resetFramePipeline()
            self.settings = s
            self.tracker = SlabTracker(settings: s.tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
            self.lastBallCrop = nil
            self.videoFormat = nil
            // the demo's frames come from a timer, which drops ticks while a frame takes longer than its interval: no
            // camera missed them
            self.pacer.rule.countsCameraGaps = false
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
        // when the frame reached the handler, before anything else (the pacer judges its lateness by it)
        let arrival = CACurrentMediaTime()
        guard !isDemo else { return }
        let camera = frame.camera
        let t = frame.timestamp
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
        // ARKit relocalised: its world frame may have moved under the lock (every frame delivered, processed or not)
        if relocalizing { sawRelocalizing = true }
        if normal && sawRelocalizing {
            sawRelocalizing = false
            tracker.noteWorldDiscontinuity("relocalized")
            note("relocalized", at: t)
        }
        // the video format, from the frames themselves (whatever re-ran the session): a change is a world discontinuity,
        // noted on the first frame that shows the new format (its size, or the spacing of frames at the new rate)
        let w = Int(camera.imageResolution.width), h = Int(camera.imageResolution.height)
        if let ch = formatWatch.note(width: w, height: h, at: t) { formatChanged(ch) }
        let fps = formatWatch.current?.framesPerSecond

        // Late (it queued behind slower processing, and a newer frame is most likely waiting): skipped before any pixel is
        // read, and nothing keeps it. While a capture kit shot records, the kit's video matters more than the tracker:
        // the frame still goes to the kit's recorder (a scale into its video buffer; the recorder takes only the frames its
        // video's rate needs, and drops what its encoder cannot take), with the last tracker result, which is what the
        // screen still shows. The pacer is told how long the skipped frame's handling took, so the next frame's wait
        // behind it is not taken for ARKit's latency (nor for an idle handler, which is never skipped). (A nominal
        // interval of 0 for an unknown frame rate: the pacer keeps the last one.)
        guard pacer.frameArrived(captureTime: t, now: arrival, nominalInterval: fps.map { 1 / $0 } ?? 0) == .process else {
            if let kit = kitRecorder, let out = lastOutput, let pv = lastView {
                lock.lock(); let vp = viewport; lock.unlock()
                let sf = sourceFrame(frame, trackingNormal: normal, trackingText: text, kitTracking: kt, viewport: vp)
                kitFramesWhileLate += 1
                if !kit.consume(sf, output: out, processingWidth: pv.intrinsics.width, ballRadius: tracker.settings.ball.radius) {
                    kitRecorder = nil
                }
            }
            pacer.skippedFrameHandled(seconds: CACurrentMediaTime() - arrival)
            return
        }
        lock.lock(); let vp = viewport; lock.unlock()
        let sf = sourceFrame(frame, trackingNormal: normal, trackingText: text, kitTracking: kt, viewport: vp)
        let out = handle(sf, viewport: vp)
        pacer.frameProcessed(captureTime: t, seconds: CACurrentMediaTime() - arrival, output: out)
    }

    /// An ARFrame as a SourceFrame: its pixels are read only through the closures, while the delegate call runs.
    private func sourceFrame(_ frame: ARFrame, trackingNormal normal: Bool, trackingText text: String, kitTracking kt: KitTracking,
                             viewport vp: CGSize) -> SourceFrame {
        let camera = frame.camera
        let full = FrameConversion.view(camera)
        let factor = max(1, full.intrinsics.width / 480)   // about 480 px wide for the detectors
        let pb = frame.capturedImage
        return SourceFrame(
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
    }

    /// The camera's video format changed between two frames (ARKit re-ran with another one: the capture kit opening or
    /// closing, or any other re-run). That ARKit's world, and so the slab's lock, carried over is not known: the tracker
    /// is told of a world discontinuity (it keeps the lock unconfirmed until it sees the slab where the lock says, and
    /// rescales or drops what it kept in pixels of the old size), and the capture locks are released (the re-run may have
    /// reset the camera's modes anyway), to be taken again, settled, once the lock is confirmed in the new format.
    private func formatChanged(_ ch: VideoFormatWatch.Change) {
        tracker.noteWorldDiscontinuity(VideoFormatWatch.discontinuityReason)
        note(ch.description, at: ch.at)
        if let c = captureGate.captureReconfigured(at: ch.at) { apply(c) }
        unlockCapture()
        lastBallCrop = nil
        lastSlabCrop = nil
    }

    private func demoTick() {
        let arrival = CACurrentMediaTime()
        guard let script = demoScript else { return }
        let t = arrival - demoStart
        // counted like the camera's frames: rendered when handled, so never late (the processing time includes the
        // rendering); ticks the timer dropped while a frame took longer than its interval are not counted as camera gaps
        // (`countsCameraGaps` is off in the demo)
        guard pacer.frameArrived(captureTime: t, now: t, nominalInterval: ARController.demoFrameInterval) == .process else { return }
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
        let out = handle(sf, viewport: vp, background: cg)
        pacer.frameProcessed(captureTime: t, seconds: CACurrentMediaTime() - arrival, output: out)
    }

    // MARK: processing (processing queue)

    /// Process a frame: the tracker, the capture locks, the recordings, and what the screen shows. Returns the tracker's
    /// result (the pacer reads which detectors ran).
    private func handle(_ f: SourceFrame, viewport vp: CGSize, background: CGImage? = nil) -> TrackerOutput {
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
        if reset { tracker.reset(); _ = captureGate.disarm(reason: "reset"); unlockCapture(); note("reset") }

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

        // only convert the image when it will be used: the slab detector will run (a detection is due, or a tap asks for
        // one, never sooner than the tracker's minimum gap after the last run), or the recording wants it
        let t = f.timestamp
        let recImg = recorder != nil && cadence.needsImage(at: t, tracker: tracker)
        let needImage = tracker.detectionDue(at: t, tap: tap != nil) || recImg
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

        // full-resolution pixels for the slab's edges, on request: when its detector runs, the tracker asks (at most once)
        // for a crop around the outline it follows or has just found, cut here from the camera image's luma (the demo:
        // from its own image), and places the slab's edges on it
        let cut = f.lumaCrop
        let slabDetail = SlabImageCrop.provider(processing: pview.intrinsics, full: full.intrinsics) { c in
            cut(c.x0, c.y0, c.width, c.height, c.factor)
        }

        let fy = floorY()
        lastFloorY = fy
        let tf = TrackerFrame(timestamp: t, view: pview, frame: colorFrame, depth: depth?.0, depthIntrinsics: depth?.1,
                              ballImage: ballImage, ballIntrinsics: ballK, tap: tap, floorY: fy, trackingNormal: f.trackingNormal,
                              slabDetail: slabDetail)
        let out = tracker.process(tf)
        lastOutput = out
        if out.ballSearched { lastBallCrop = crop }
        if let d = out.slabDetail { lastSlabCrop = d.crop }
        if !out.events.isEmpty {
            recentEvents.append(contentsOf: out.events.map { String(format: "%.2f ", t) + $0 })
            trimEvents()
        }
        // the capture locks: a new search ("tap", "lost", "lock-expired") puts focus, exposure and white balance back to
        // automatic; a new lock ("locked"; a relock is the same scene and keeps the current lock) holds them once the
        // camera reports none of them adjusting any more (or at the gate's timeout). The device is read once a frame; no
        // device, no lock (as in the demo).
        if let c = captureGate.note(events: out.events, at: t) { apply(c) }
        if !isDemo, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            let adjusting = CaptureLockGate.Adjusting(focus: device.isAdjustingFocus, exposure: device.isAdjustingExposure,
                                                      whiteBalance: device.isAdjustingWhiteBalance)
            if let c = captureGate.update(at: t, adjusting: adjusting) { apply(c) }
        }

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
            rec.append(r.frame, image: r.image, depth: r.depth, ball: r.ball, slab: r.slab)
        }

        // the capture kit's shot recorder (the frame's video picture, its numbers and the live result)
        if let kit = kitRecorder,
           !kit.consume(f, output: out, processingWidth: pview.intrinsics.width, ballRadius: tracker.settings.ball.radius) {
            kitRecorder = nil
        }

        // overlay, projected for the view, the readouts and the developer line
        let ov = overlay(out, view: full, processing: pview.intrinsics.width, pview.intrinsics.height, viewport: vp)
        let hud = makeHUD(out)
        // the frame numbers for the developer line, once a second (camera clock; again at once if the clock went back)
        if t - framesLineTime >= 1 || t < framesLineTime {
            framesLine = ARController.framesLine(pacer.report)
            framesLineTime = t
        }
        let dev = makeDeveloperStatus(out)
        let dt = (CACurrentMediaTime() - t0) * 1000
        msAverage = msAverage == 0 ? dt : msAverage * 0.95 + dt * 0.05
        frameTimes.append(t)
        if frameTimes.count > 60 { frameTimes.removeFirst() }
        Task { @MainActor [weak model] in model?.publish(overlay: ov, hud: hud, developer: dev, background: background) }
        return out
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { for a in anchors { floorYs[a.identifier] = nil } }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as NSError).code
        queue.async { self.note("session error \(code)") }
        let msg = "Camera stopped: \(error.localizedDescription)"
        Task { @MainActor [weak model] in
            guard let m = model else { return }
            var h = m.hud; h.status = msg; h.locked = false
            m.publish(overlay: OverlayState(), hud: h, developer: m.developer, background: nil)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // the frames stop: a pause, not frames the camera missed
        let at = CACurrentMediaTime()
        queue.async { self.note("interrupted"); self.pacer.expectPause(at: at) }
        // a kit shot being recorded is thrown away (it stays pending)
        Task { @MainActor [weak model] in model?.cameraInterrupted() }
    }

    /// After an interruption ARKit's world frame may have moved under the lock: the tracker keeps it, unconfirmed, until
    /// it sees the slab where it should be.
    func sessionInterruptionEnded(_ session: ARSession) {
        newRunId(ar: true, motion: false)   // ARKit's world may have moved: shots after this are another run
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

    /// An event for diagnostics, prefixed with the camera clock (words and numbers only: never paths or names): `t`, or
    /// the last processed frame's time.
    private func note(_ text: String, at t: Double? = nil) {
        recentEvents.append(String(format: "%.2f ", t ?? lastFrameTime) + text)
        trimEvents()
    }

    private func trimEvents() {
        if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
    }

    // MARK: capture locks

    /// What the capture lock gate says to do.
    private func apply(_ c: CaptureLockGate.Command) {
        switch c {
        case .lock(let how):
            lockCapture(how)
        case .unlock(let reason):
            if captureLocked { note("capture unlocked: " + reason) }
            unlockCapture()
        }
    }

    /// Lock focus, exposure and white balance once the slab is locked and the camera has settled (`CaptureLockGate`), so
    /// the image stops changing under the detector. `how`: how the gate got there, noted ("capture locked after 0.42 s
    /// settled", or "capture locked at the 2.5 s timeout: exposure still adjusting").
    private func lockCapture(_ how: CaptureLockGate.Lock) {
        guard !captureLocked, !isDemo else { return }
        if let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                captureLocked = true
                note(how.description)
            } catch {
                note("capture lock failed: error \((error as NSError).code)")
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
        d.frames = framesLine
        return d
    }

    /// The developer line's frame numbers over the last 10 s of camera time, e.g. "frames: 58.9/s in, 3% late-skipped,
    /// 1% late from ARKit, 0 gaps, 0 pauses, delivery 21/34 ms, process 6/19 ms (p50/p95; p95 plain 6, ball 9, search 80,
    /// re-check 25), detector 8.3/s": frames delivered a second; the share skipped because they waited behind slower
    /// processing, and the share ARKit itself delivered late to an idle handler (processed: not the app's delay); gaps in
    /// the camera's frames, and pauses (interruptions, re-runs with another format); how long after capture frames
    /// reached the app; how long processing took, overall and (95th percentile) by what ran: nothing ("plain"), the ball
    /// finder alone, a slab search, a re-check of the lock; and slab detector runs a second (searches and re-checks).
    static func framesLine(_ r: FramePacingReport) -> String? {
        let w = r.recent
        guard w.framesReceived > 0, w.seconds > 0 else { return nil }
        func ms(_ m: FramePacingReport.Millis?) -> String { m.map { String(format: "%.0f/%.0f", $0.p50, $0.p95) } ?? "-" }
        func p95(_ m: FramePacingReport.Millis?) -> String { m.map { String(format: "%.0f", $0.p95) } ?? "-" }
        func share(_ n: Int) -> String { String(format: "%.0f", 100 * Double(n) / Double(w.framesReceived)) }
        let rate = String(format: "%.1f", Double(w.framesReceived) / w.seconds)
        let runs = String(format: "%.1f", w.searchesPerSecond + w.rechecksPerSecond)
        let k = w.processingByKind
        return "frames: \(rate)/s in, \(share(w.framesSkippedLate))% late-skipped, \(share(w.framesLateButIdle))% late from ARKit, "
            + "\(w.cameraGaps) gaps, \(w.pauses) pauses, delivery \(ms(w.deliveryLatencyMs)) ms, process \(ms(w.processingMs)) ms "
            + "(p50/p95; p95 plain \(p95(k.plain)), ball \(p95(k.ball)), search \(p95(k.search)), re-check \(p95(k.recheck))), "
            + "detector \(runs)/s"
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
            if kitFramesWhileLate > 0 { counts["kitFramesWhileLate"] = kitFramesWhileLate }
            var rep = DiagnosticsReport(build: appBuild, device: Device.model, system: "iOS \(UIDevice.current.systemVersion)",
                                        time: ISO8601DateFormatter().string(from: Date()), settings: s.recording,
                                        state: tracker.state.rawValue, tracking: lastTracking, fps: fps, msProcess: msAverage,
                                        lens: lastLens, depthSupported: ARController.depthSupported, depth: out?.depth,
                                        captureLocked: captureLocked, slab: out?.slab, outline: out?.outline, sideModes: tracker.lastSideModes,
                                        ball: out?.ball, readouts: out?.readouts, counts: counts, recentEvents: recentEvents,
                                        recording: recorder?.name, rejectionValues: tracker.rejectionValues,
                                        cornerNoisePixels: tracker.cornerNoiseEstimate, lockSigmaDegrees: out?.lockSigmaDegrees)
            rep.addTracker(tracker, view: lastView, lens: lastLens, output: out, ballCrop: lastBallCrop, floorY: lastFloorY,
                           slabCrop: lastSlabCrop)
            rep.videoFormat = videoFormat
            // how the frames came and went (delivered, processed, skipped as late, missed by the camera, latencies, detector
            // runs), how the last capture lock came about, and video format changes
            rep.framePacing = pacer.report
            rep.captureLockSettle = captureGate.lastLock
            rep.videoFormatChanges = formatWatch.changes
            rep.videoFormatChange = formatWatch.lastChange
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
            _ = captureGate.disarm(reason: "recording")
            unlockCapture()
            note("recording started")
        } catch {
            note("recording failed to start: error \((error as NSError).code)")
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
