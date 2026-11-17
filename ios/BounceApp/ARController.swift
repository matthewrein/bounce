import ARKit
import AVFoundation
import BounceCore
import CoreMotion
import Foundation
import UIKit
import simd

/// Runs the AR session and feeds every camera frame through BounceCore's tracker on a background queue, then hands the
/// overlay (already projected into view points) and the readouts to the UI.
final class ARController: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var depthSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    let session = ARSession()
    weak var model: AppModel?

    private let queue = DispatchQueue(label: "slabbounce.processing", qos: .userInteractive)
    private let motion = CMMotionManager()
    private let lock = NSLock()

    // shared with the main thread (guarded by `lock`)
    private var viewport = CGSize(width: 390, height: 844)
    private var pendingTap: CGPoint? = nil
    private var pendingSettings: AppSettings? = nil
    private var resetRequested = false

    // processing-queue state
    private var tracker: SlabTracker
    private var settings = AppSettings()
    private var config = ARWorldTrackingConfiguration()
    private var floorYs: [UUID: Double] = [:]
    private var captureLocked = false
    private var lastTracking = "not started"
    private var lastOutput: TrackerOutput? = nil
    private var lastDisplayTransform: CGAffineTransform = .identity
    private var lastImageSize = CGSize(width: 1920, height: 1440)
    private var lastLens: CameraIntrinsics? = nil
    private var frameTimes: [Double] = []
    private var msAverage = 0.0
    private var recentEvents: [String] = []
    private var recorder: SessionRecorder? = nil
    private var recordRequest: AppSettings? = nil
    private var lastRecorded = -Double.infinity

    override init() {
        tracker = SlabTracker(settings: AppSettings().tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    // MARK: control (main thread)

    func start(settings s: AppSettings) {
        queue.async {
            self.settings = s
            self.tracker = SlabTracker(settings: s.tracker, detector: Detectors.slab(), ballLocator: Detectors.ball())
        }
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        c.planeDetection = [.horizontal]
        c.isAutoFocusEnabled = true
        if ARController.depthSupported { c.frameSemantics.insert(.sceneDepth) }
        // the highest-resolution 4:3 format (usually 1920x1440); the detectors work on a quarter of it
        if let f = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({ abs($0.imageResolution.width / $0.imageResolution.height - 4.0 / 3.0) < 0.01 && $0.imageResolution.width <= 1920 })
            .max(by: { $0.imageResolution.width < $1.imageResolution.width }) {
            c.videoFormat = f
        }
        config = c
        session.run(c, options: [.resetTracking, .removeExistingAnchors])
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 60
            motion.startDeviceMotionUpdates()
        }
    }

    func stop() {
        session.pause()
        motion.stopDeviceMotionUpdates()
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

    // MARK: frames (processing queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        lock.lock()
        let vp = viewport, tapView = pendingTap, newSettings = pendingSettings, reset = resetRequested
        pendingTap = nil; pendingSettings = nil; resetRequested = false
        lock.unlock()

        if let s = newSettings, s != settings {
            settings = s
            tracker.settings = s.tracker
            if s.tracker.spec != tracker.settings.spec { tracker.reset() }
        }
        if reset { tracker.reset(); unlockCapture(); recentEvents.append("reset") }

        let camera = frame.camera
        switch camera.trackingState {
        case .normal: lastTracking = "normal"
        case .notAvailable: lastTracking = "not available"
        case .limited(let r):
            switch r {
            case .initializing: lastTracking = "limited: initializing"
            case .excessiveMotion: lastTracking = "limited: moving too fast"
            case .insufficientFeatures: lastTracking = "limited: too few features"
            case .relocalizing: lastTracking = "limited: relocalizing"
            @unknown default: lastTracking = "limited"
            }
        }
        let trackingNormal: Bool
        if case .normal = camera.trackingState { trackingNormal = true } else { trackingNormal = false }

        let fullView = FrameConversion.view(camera)
        lastLens = fullView.intrinsics
        let W = fullView.intrinsics.width
        let factor = max(1, W / 480)                       // about 480 px wide for the detectors
        let K = fullView.intrinsics.scaled(by: 1 / Double(factor))
        let pview = BounceCore.CameraView(worldFromCamera: fullView.worldFromCamera,
                                          intrinsics: CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, width: W / factor,
                                                                       height: fullView.intrinsics.height / factor))
        lastImageSize = CGSize(width: fullView.intrinsics.width, height: fullView.intrinsics.height)
        lastDisplayTransform = frame.displayTransform(for: .portrait, viewportSize: vp)

        // a tap in the view -> processing-image pixels
        var tap: Vec2? = nil
        if let p = tapView {
            let n = CGPoint(x: p.x / vp.width, y: p.y / vp.height).applying(lastDisplayTransform.inverted())
            tap = Vec2(Double(n.x) * Double(pview.intrinsics.width), Double(n.y) * Double(pview.intrinsics.height))
        }

        // a recording starts on the first frame after it was asked for (when the frame size is known)
        if let req = recordRequest, recorder == nil {
            recordRequest = nil
            do {
                recorder = try SessionRecorder(settings: req.recording, frameWidth: pview.intrinsics.width, frameHeight: pview.intrinsics.height)
                lastRecorded = -Double.infinity
                recentEvents.append("recording started")
            } catch {
                recentEvents.append("recording failed: \(error.localizedDescription)")
            }
        }
        // only convert the image when it will be used: a detection is due, or we are recording
        let recordDue = recorder != nil && frame.timestamp - lastRecorded >= 0.1
        let needImage = tap != nil || tracker.detectionDue(at: frame.timestamp) || recordDue
        var ycc: YCCImage? = nil
        if needImage { ycc = FrameConversion.ycc(frame.capturedImage, factor: factor) }
        let colorFrame = ycc?.colorFrame ?? ColorFrame(gray: Plane(width: 2, height: 2))

        // LiDAR depth, when the slab is locked (or for the recording)
        var depth: DepthMap? = nil, depthK: CameraIntrinsics? = nil
        if let sd = frame.sceneDepth, tracker.state == .locked || recordDue {
            depth = FrameConversion.depth(sd)
            if let d = depth { depthK = fullView.intrinsics.scaled(by: Double(d.width) / Double(fullView.intrinsics.width)) }
        }

        // a full-resolution crop around the slab and the space above it, for the ball
        var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
        if tracker.state == .locked, tracker.ballDue(at: frame.timestamp), let s = tracker.slab,
           let q = Optional(s.topCorners.compactMap { fullView.project(world: $0) }), q.count == 4 {
            // the box around the slab, stretched toward "up" in the image to reach a ball held up to ~1.2 m above it
            let up = s.topCorners.map { fullView.project(world: $0 + Vec3(0, 1.2, 0)) }.compactMap { $0 }
            let pts = q + up
            let side = ShapeCheck.meanSide(q)
            let x0 = Int(pts.map { $0.x }.min()! - side), x1 = Int(pts.map { $0.x }.max()! + side)
            let y0 = Int(pts.map { $0.y }.min()! - side), y1 = Int(pts.map { $0.y }.max()! + side)
            let cx0 = max(0, x0), cy0 = max(0, y0), cw = min(fullView.intrinsics.width, x1) - cx0, chh = min(fullView.intrinsics.height, y1) - cy0
            if cw > 32, chh > 32 {
                let k = max(1, Int(ceil(Double(max(cw, chh)) / 900)))
                if let p = FrameConversion.lumaCrop(frame.capturedImage, x0: cx0, y0: cy0, width: cw, height: chh, factor: k) {
                    ballImage = p
                    ballK = fullView.intrinsics.cropped(x0: Double(cx0), y0: Double(cy0), scale: 1 / Double(k), width: p.width, height: p.height)
                }
            }
        }

        let tf = TrackerFrame(timestamp: frame.timestamp, view: pview, frame: colorFrame, depth: depth, depthIntrinsics: depthK,
                              ballImage: ballImage, ballIntrinsics: ballK, tap: tap, floorY: floorY(), trackingNormal: trackingNormal)
        let out = tracker.process(tf)
        lastOutput = out
        if !out.events.isEmpty {
            recentEvents.append(contentsOf: out.events.map { String(format: "%.2f ", frame.timestamp) + $0 })
            if recentEvents.count > 30 { recentEvents.removeFirst(recentEvents.count - 30) }
        }
        if out.events.contains("locked") || out.events.contains("relocked") { lockCapture() }
        if out.events.contains("lost") { unlockCapture() }

        // recording
        if recordDue, let rec = recorder, let img = ycc {
            lastRecorded = frame.timestamp
            var rf = RecordedFrame(index: 0, timestamp: frame.timestamp, file: "", worldFromCamera: FrameConversion.columnMajor(camera.transform),
                                   intrinsics: pview.intrinsics, trackingNormal: trackingNormal)
            rf.gravityCamera = pview.directionToCamera(ARKitConvention.worldDown).array
            if let m = motion.deviceMotion {
                rf.userAcceleration = [m.userAcceleration.x, m.userAcceleration.y, m.userAcceleration.z]
                rf.rotationRate = [m.rotationRate.x, m.rotationRate.y, m.rotationRate.z]
                let q = m.attitude.quaternion
                rf.attitude = [q.x, q.y, q.z, q.w]
            }
            rf.exposureDuration = camera.exposureDuration
            rf.locked = captureLocked
            rf.depthIntrinsics = depthK
            rec.append(rf, image: img, depth: depth)
        }

        // overlay, projected for the view, and the readouts
        let ov = overlay(out, view: fullView, processing: pview.intrinsics.width, pview.intrinsics.height, viewport: vp)
        let hud = makeHUD(out)
        let dt = (CACurrentMediaTime() - t0) * 1000
        msAverage = msAverage == 0 ? dt : msAverage * 0.95 + dt * 0.05
        frameTimes.append(frame.timestamp)
        if frameTimes.count > 60 { frameTimes.removeFirst() }
        Task { @MainActor [weak model] in model?.publish(overlay: ov, hud: hud) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) { for a in anchors { floorYs[a.identifier] = nil } }

    func session(_ session: ARSession, didFailWithError error: Error) {
        recentEvents.append("session error: \(error.localizedDescription)")
        let msg = "Camera stopped: \(error.localizedDescription)"
        Task { @MainActor [weak model] in
            guard let m = model else { return }
            var h = m.hud; h.status = msg; m.publish(overlay: OverlayState(), hud: h)
        }
    }

    private func updatePlanes(_ anchors: [ARAnchor]) {
        for case let p as ARPlaneAnchor in anchors where p.alignment == .horizontal {
            floorYs[p.identifier] = Double(p.transform.columns.3.y)
        }
    }

    /// The floor under the slab: the lowest horizontal plane between 1 cm and 60 cm below the slab's centre.
    private func floorY() -> Double? {
        guard let s = tracker.slab else { return nil }
        let cand = floorYs.values.filter { s.center.y - $0 > 0.01 && s.center.y - $0 < 0.6 }
        return cand.min()
    }

    // MARK: capture locks

    /// Lock focus, exposure and white balance once the slab is found, so the image stops changing under the detector.
    private func lockCapture() {
        guard !captureLocked else { return }
        if #available(iOS 16.0, *), let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
                captureLocked = true
                recentEvents.append("capture locked")
            } catch {
                recentEvents.append("capture lock failed: \(error.localizedDescription)")
            }
        }
    }

    private func unlockCapture() {
        guard captureLocked else { return }
        if #available(iOS 16.0, *), let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                device.unlockForConfiguration()
            } catch {
                recentEvents.append("capture unlock failed: \(error.localizedDescription)")
            }
        }
        captureLocked = false
    }

    // MARK: overlay

    /// World point -> view point (through the captured image and ARKit's display transform).
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
            if let c = o.ball, let edge = toView(b.center + view.worldFromCamera.applyDirection(Vec3(1, 0, 0)) * settings.ballMm / 2000, view, vp) {
                o.ballRadius = CGFloat(hypot(edge.x - c.x, edge.y - c.y))
            }
            o.dropTop = o.ball
        }
        return o
    }

    private func makeHUD(_ out: TrackerOutput) -> HUDState {
        var h = HUDState()
        switch out.state {
        case .searching: h.status = lastTracking == "normal" ? "Looking for the slab" : "Move the phone slowly (\(lastTracking))"
        case .confirming: h.status = "Found it, checking"
        case .locked: h.status = out.ball != nil ? "Slab locked, ball in view" : "Slab locked"
        }
        h.locked = out.state == .locked
        if let r = out.readouts {
            h.tilt = String(format: "%.1f°", r.tiltDegrees)
            h.apex = Format.length(r.apexHeight)
            h.landing = Format.length(r.landingDistance)
            h.air = String(format: "%.2f s", r.airTime)
            h.drop = Format.length(r.dropHeight) + (r.dropFromBall ? " (ball)" : "")
        }
        if let d = out.depth {
            h.depth = String(format: "LiDAR: %.1f° tilt, %.1f° from image", d.tiltDegrees, d.angleToImageDegrees)
        }
        if let rec = recorder { h.recording = "Recording \(rec.frameCount) frames" }
        return h
    }

    // MARK: diagnostics and recording

    func diagnosticsJSON(settings s: AppSettings) -> String {
        var json = "{}"
        queue.sync {
            let fps: Double = frameTimes.count > 1 ? Double(frameTimes.count - 1) / max(1e-6, frameTimes.last! - frameTimes.first!) : 0
            let out = lastOutput
            var counts = tracker.counts
            counts["recordedFrames"] = recorder?.frameCount
            let rep = DiagnosticsReport(build: appBuild, device: Device.model, system: "iOS \(UIDevice.current.systemVersion)",
                                        time: ISO8601DateFormatter().string(from: Date()), settings: s.recording,
                                        state: tracker.state.rawValue, tracking: lastTracking, fps: fps, msProcess: msAverage,
                                        lens: lastLens, depthSupported: ARController.depthSupported, depth: out?.depth,
                                        captureLocked: captureLocked, slab: out?.slab, outline: out?.outline, sideModes: tracker.lastSideModes,
                                        ball: out?.ball, readouts: out?.readouts, counts: counts, recentEvents: recentEvents,
                                        recording: recorder?.name)
            json = rep.json(pretty: true)
        }
        return json
    }

    func startRecording(settings s: AppSettings) -> Bool {
        queue.async { if self.recorder == nil { self.recordRequest = s } }
        return true
    }

    func stopRecording(_ done: @escaping (URL?) -> Void) {
        queue.async {
            self.recordRequest = nil
            guard let rec = self.recorder else { done(nil); return }
            self.recorder = nil
            rec.finish(done)
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
    /// e.g. "iPhone15,2"
    static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
