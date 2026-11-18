import ARKit
import AVFoundation
import BounceCore
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import UIKit

/// What the pre-flight watches while it runs, handed to ARController (`setPreflight`): every camera frame's tracking state
/// and depth (processing queue), every device-motion sample (motion queue), and those samples again for the recorder's
/// test clip. Thread-safe.
final class PreflightTap {
    let arkit: PreflightARKitMeter
    let motion: PreflightMotionMeter
    private let lock = NSLock()
    private var recorder: KitRecorder? = nil

    init(arkit: PreflightARKitMeter, motion: PreflightMotionMeter) {
        self.arkit = arkit
        self.motion = motion
    }

    /// The recorder test's recorder, while it records (its motion.jsonl gets the samples).
    func setRecorder(_ r: KitRecorder?) {
        lock.lock(); recorder = r; lock.unlock()
    }

    /// A camera frame (ARKit's delegate queue, during the delegate call: nothing here keeps the frame). About once a
    /// second its depth map is looked at closely (valid and confident shares, median).
    func frame(_ frame: ARFrame, tracking: KitTracking) {
        let d = frame.smoothedSceneDepth ?? frame.sceneDepth
        arkit.frame(time: frame.timestamp, tracking: tracking, hasDepth: d != nil)
        if let d = d, arkit.wantsDepthSample(time: frame.timestamp), let map = FrameConversion.depth(d) {
            arkit.depth(PreflightDepthSample(map), time: frame.timestamp)
        }
    }

    /// A device-motion sample (motion queue).
    func motionSample(_ s: KitMotionSample) {
        motion.sample(time: s.time, gravity: s.gravity)
        lock.lock(); let r = recorder; lock.unlock()
        r?.appendMotion(s)
    }
}

/// A value set once from any queue and read from another.
private final class PreflightBox<T> {
    private let lock = NSLock()
    private var value: T? = nil
    func set(_ v: T) { lock.lock(); if value == nil { value = v }; lock.unlock() }
    var current: T? { lock.lock(); defer { lock.unlock() }; return value }
}

/// The recorder's test: about 2 s of the live frames (camera, or the demo's) through the capture kit's own recorder
/// (`KitRecorder`, attached the way a kit shot attaches it: the same codec choice, pixel buffer pool, encoder settings,
/// frames.jsonl and motion.jsonl) into a scratch folder in the temporary directory; then the clip is read back with
/// AVFoundation (its duration and size, and every frame decoded) and the folder is deleted. Nothing is kept.
enum PreflightRecorderTest {
    static let folderPrefix = "preflight-"

    /// Scratch folders an earlier pre-flight left behind (the app was killed during it).
    static func removeLeftovers() {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for n in names where n.hasPrefix(folderPrefix) {
            do { try FileManager.default.removeItem(at: tmp.appendingPathComponent(n, isDirectory: true)) } catch {
                AppLog.warn("preflight", "could not remove an earlier test clip", error)
            }
        }
    }

    /// Record, read back, delete. Runs off the main thread; returns what it saw (never throws).
    static func run(controller: ARController, tap: PreflightTap, sourceFps: Double, wantsDepth: Bool,
                    simulator: Bool) async -> PreflightRecorderObservation {
        let seconds = Preflight.recorderSeconds
        removeLeftovers()
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            AppLog.error("preflight", "could not make the test clip's folder", error)
            return PreflightRecorderObservation(ran: false, error: "could not make a scratch folder", requestedSeconds: seconds, simulator: simulator)
        }
        let box = PreflightBox<KitRecorder.Result>()
        let rec: KitRecorder
        do {
            rec = try KitRecorder(folder: folder, video: true, duration: seconds, highFrameRate: false, sourceFps: sourceFps,
                                  wantsDepth: wantsDepth, label: "pre-flight clip", onStart: { _ in }, completion: { r in box.set(r) })
        } catch {
            AppLog.error("preflight", "could not start the test recorder", error)
            let cleaned = PreflightRecorderTest.removeFolder(folder)
            return PreflightRecorderObservation(ran: false, error: "could not start the recorder", requestedSeconds: seconds,
                                                cleanedUp: cleaned, simulator: simulator)
        }
        let depthWords = wantsDepth ? ", with depth" : ""
        AppLog.info("preflight", String(format: "test clip started: %.0f s at %.1f frames a second", seconds, sourceFps) + depthWords)
        tap.setRecorder(rec)
        controller.attachKitRecorder(rec)
        let t0 = CACurrentMediaTime()
        var askedToFinish = false
        var cancelled = false
        while box.current == nil {
            if Task.isCancelled { cancelled = true; break }
            let t = CACurrentMediaTime() - t0
            // no frames coming (no camera, or it stopped): stop with what there is; then give up on it
            if !askedToFinish && t > seconds + 3 { askedToFinish = true; rec.finish() }
            if t > seconds + 8 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        tap.setRecorder(nil)
        controller.detachKitRecorder()
        guard let r = box.current else {
            rec.cancel()
            let cleaned = PreflightRecorderTest.removeFolder(folder)
            if cancelled {
                AppLog.info("preflight", "test clip cancelled")
                return PreflightRecorderObservation(ran: false, error: "stopped before it finished", requestedSeconds: seconds,
                                                    cleanedUp: cleaned, simulator: simulator)
            }
            AppLog.error("preflight", "the test recorder never reported (no frames, or the encoder hung)")
            return PreflightRecorderObservation(ran: false, error: "the recorder never finished", requestedSeconds: seconds,
                                                cleanedUp: cleaned, simulator: simulator)
        }
        let frameLines = (try? KitJSONL.read(KitFrame.self, from: folder.appendingPathComponent(KitClipFiles.frames)).count) ?? 0
        let motionLines = try? KitJSONL.read(KitMotionSample.self, from: folder.appendingPathComponent(KitClipFiles.motion)).count
        let videoURL = folder.appendingPathComponent(KitClipFiles.video)
        let fileBytes = r.video?.fileBytes ?? KitFiles.size(of: videoURL)
        var back: ReadBack? = nil
        if r.frames > 0, fm.fileExists(atPath: videoURL.path) {
            back = await Task.detached(priority: .userInitiated) { await PreflightRecorderTest.readBack(videoURL) }.value
        }
        let cleaned = PreflightRecorderTest.removeFolder(folder)
        let obs = PreflightRecorderObservation(
            ran: r.frames > 0, error: r.error, requestedSeconds: seconds, framesWritten: r.frames, frameLines: frameLines,
            motionLines: motionLines, codec: r.video?.codec, width: r.video?.width, height: r.video?.height,
            fps: r.video?.fps ?? (r.keptFps > 0 ? r.keptFps : nil), fileBytes: fileBytes,
            readBackSeconds: back?.seconds, readBackFrames: back?.frames, readBackWidth: back?.width, readBackHeight: back?.height,
            cleanedUp: cleaned, simulator: simulator)
        var line = "test clip: \(r.frames) frames written, \(frameLines) frame lines, "
        line += motionLines.map { "\($0) motion lines, " } ?? "no motion file, "
        line += "\(fileBytes) bytes, read back "
        if let b = back, let n = b.frames { line += "\(n) frames" } else { line += "nothing" }
        if let secs = back?.seconds { line += String(format: " over %.2f s", secs) }
        if let w = back?.width, let h = back?.height { line += " at \(w)x\(h)" }
        if !cleaned { line += ", scratch folder not removed" }
        AppLog.info("preflight", line)
        return obs
    }

    struct ReadBack {
        var seconds: Double? = nil
        var frames: Int? = nil
        var width: Int? = nil
        var height: Int? = nil
    }

    /// The clip as AVFoundation reads it: duration, the video track's size, and how many frames decode.
    static func readBack(_ url: URL) async -> ReadBack {
        let asset: AVAsset = AVURLAsset(url: url)
        var out = ReadBack()
        do {
            let duration = try await asset.load(.duration)
            if duration.isNumeric { out.seconds = duration.seconds }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                AppLog.error("preflight", "the test clip has no video track")
                return out
            }
            let size = try await track.load(.naturalSize)
            out.width = Int(size.width.rounded())
            out.height = Int(size.height.rounded())
            out.frames = try decodedFrames(asset: asset, track: track)
        } catch {
            AppLog.error("preflight", "could not read the test clip back", error)
        }
        return out
    }

    /// Decode every frame of the track (bi-planar 4:2:0, as the kit's scorer reads it) and count them.
    static func decodedFrames(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PreflightTestError.readerRefused }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? PreflightTestError.readerRefused }
        var n = 0
        while let sb = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sb) != nil { n += 1 }
        }
        if reader.status == .failed { throw reader.error ?? PreflightTestError.readerFailed }
        return n
    }

    enum PreflightTestError: Error, CustomStringConvertible {
        case readerRefused, readerFailed
        var description: String { self == .readerRefused ? "the clip reader would not start" : "the clip reader failed" }
    }

    /// Remove the scratch folder; true when it is gone.
    @discardableResult
    static func removeFolder(_ folder: URL) -> Bool {
        do { try FileManager.default.removeItem(at: folder) } catch {
            AppLog.warn("preflight", "could not remove the test clip", error)
        }
        return !FileManager.default.fileExists(atPath: folder.path)
    }
}

/// Settings > Developer > Pre-flight: about ten seconds watching the running session (the camera, or the demo), then a
/// pass / warn / fail / not available line per item (BounceCore's `Preflight` judges). Only the Run button starts it, and
/// it changes nothing: not the video format, not the session, and a kit cannot be open while it runs. While it runs,
/// motion is read at the capture kit's 100 Hz (from the app's one motion manager, in ARController); afterwards it goes
/// back to how it ran.
@MainActor
final class PreflightRunner: ObservableObject {
    @Published private(set) var running = false
    /// 0...1 over the ten seconds
    @Published private(set) var progress = 0.0
    @Published private(set) var secondsLeft = 0.0
    /// the window is over and the test clip is still being read back
    @Published private(set) var checkingClip = false
    @Published private(set) var report: PreflightReport? = nil
    /// a passing remark (the demo is on; the run was stopped)
    @Published private(set) var note: String? = nil
    @Published private(set) var copied = false

    private weak var model: AppModel?
    private let controller: ARController
    private var task: Task<Void, Never>? = nil
    private var recorderTask: Task<PreflightRecorderObservation, Never>? = nil
    private var runId = 0
    private var stopReason: String? = nil

    init(model: AppModel, controller: ARController) {
        self.model = model
        self.controller = controller
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Run (only ever from the button).
    func run() {
        guard !running, let m = model, !m.kitOpen, !m.isRecording else { return }
        runId += 1
        let id = runId
        running = true
        m.preflightRunning = true
        report = nil; copied = false; progress = 0; secondsLeft = Preflight.seconds; checkingClip = false; stopReason = nil
        let simulator = PreflightRunner.isSimulator, demo = m.demoRunning
        var notes: [String] = []
        if demo && !simulator {
            notes.append("The demo scene is on, so the camera is off: ARKit and LiDAR see nothing and the recorder records the demo. Turn the demo off for a real check.")
        }
        if m.arUnsupported && !simulator { notes.append("This phone cannot run ARKit, so the camera never starts.") }
        note = notes.isEmpty ? nil : notes.joined(separator: " ")

        let start = CACurrentMediaTime()
        let expectedFps = demo ? nil : controller.videoFps
        let tap = PreflightTap(arkit: PreflightARKitMeter(start: start, supported: ARController.isSupported, expectedFps: expectedFps,
                                                          depthSupported: ARController.depthSupported),
                               motion: PreflightMotionMeter(start: start, available: controller.motionAvailable))
        let camera = PreflightRunner.cameraAccess()
        let kitFormat: KitCameraFormat? = ARController.isSupported
            ? ARController.kitVideoFormat().map { KitCameraFormat(width: Int($0.imageResolution.width), height: Int($0.imageResolution.height),
                                                                  fps: Double($0.framesPerSecond)) }
            : nil
        let estimate = PreflightStorageEstimate.fullKit(plan: .standard, format: kitFormat, hevc: !simulator, hasLiDAR: ARController.depthSupported)
        let sourceFps = demo ? 1 / ARController.demoFrameInterval : (expectedFps ?? 30)
        let wantsDepth = ARController.depthSupported && !demo
        let source = demo ? "demo scene" : "camera"
        let video = expectedFps.map { String(format: "video at %.0f frames a second", $0) } ?? "no camera format"
        let motionWords = controller.motionAvailable ? "available" : "not available"
        AppLog.info("preflight", "started: camera access \(camera.rawValue), \(source), \(video), motion \(motionWords)")
        controller.setPreflight(tap)
        let ctrl = controller
        // the recorder's test from 1 s in (the first frames have come), beside the meters
        let rt = Task.detached(priority: .userInitiated) { () -> PreflightRecorderObservation in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled {
                return PreflightRecorderObservation(ran: false, error: "stopped before it started", requestedSeconds: Preflight.recorderSeconds, simulator: simulator)
            }
            return await PreflightRecorderTest.run(controller: ctrl, tap: tap, sourceFps: sourceFps, wantsDepth: wantsDepth, simulator: simulator)
        }
        recorderTask = rt
        task = Task { [weak self] in
            await self?.watch(id: id, start: start, tap: tap, recorder: rt, camera: camera, simulator: simulator, demo: demo, estimate: estimate)
        }
    }

    /// Stop a run (the app left the foreground, Settings closed): no result, the test clip deleted.
    func cancel(_ reason: String) {
        guard running else { return }
        stopReason = reason
        task?.cancel()
        recorderTask?.cancel()
    }

    private func watch(id: Int, start: Double, tap: PreflightTap, recorder: Task<PreflightRecorderObservation, Never>,
                       camera: PreflightCameraAccess, simulator: Bool, demo: Bool, estimate: PreflightStorageEstimate) async {
        while !Task.isCancelled {
            let t = CACurrentMediaTime() - start
            progress = min(1, t / Preflight.seconds)
            secondsLeft = max(0, Preflight.seconds - t)
            if t >= Preflight.seconds { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let end = CACurrentMediaTime()
        controller.setPreflight(nil)
        if Task.isCancelled {
            recorder.cancel()
            _ = await recorder.value   // its scratch folder is gone once it returns
            finish(id: id, report: nil)
            return
        }
        progress = 1
        secondsLeft = 0
        let (arkit, lidar) = tap.arkit.observations(end: end)
        let motion = tap.motion.observation(end: end)
        let storage = PreflightStorageObservation(freeBytes: PreflightRunner.freeBytes(), estimate: estimate)
        checkingClip = true
        let rec = await recorder.value
        checkingClip = false
        if Task.isCancelled || stopReason != nil {
            finish(id: id, report: nil)
            return
        }
        let o = PreflightObservations(build: appBuild, device: Device.model, system: "iOS \(UIDevice.current.systemVersion)",
                                      time: ISO8601DateFormatter().string(from: Date()), simulator: simulator, demo: demo, camera: camera,
                                      arkit: arkit, lidar: lidar, motion: motion, storage: storage, recorder: rec)
        let r = Preflight.evaluate(o)
        AppLog.info("preflight", r.headline + String(format: " (%.1f s)", CACurrentMediaTime() - start))
        for i in r.items {
            let level: DevLog.Level = i.status == .fail ? .error : i.status == .warn ? .warn : .info
            AppLog.shared.log(level, "preflight", i.line + (i.numbers.isEmpty ? "" : " [" + i.numbersLine + "]"))
        }
        finish(id: id, report: r)
    }

    private func finish(id: Int, report r: PreflightReport?) {
        guard id == runId else { return }
        running = false
        model?.preflightRunning = false
        task = nil
        recorderTask = nil
        checkingClip = false
        if let r = r {
            report = r
        } else {
            let why = stopReason ?? "it was cancelled"
            note = "Stopped: \(why). Tap Run to try again."
            AppLog.warn("preflight", "stopped: \(why)")
        }
        stopReason = nil
    }

    /// Copy results: the plain lines, then the JSON with every number the app saw.
    func copy() {
        guard let r = report else { return }
        UIPasteboard.general.string = r.text + "\n" + r.json()
        copied = true
        AppLog.info("preflight", "results copied")
    }

    /// The camera permission, as AVFoundation reports it (asking nothing); no camera at all in the Simulator (whatever
    /// it may list, it has no camera ARKit can use).
    static func cameraAccess() -> PreflightCameraAccess {
        guard !isSimulator, AVCaptureDevice.default(for: .video) != nil else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }

    /// Bytes free for important use on the app's volume (the plain free space if that is not known).
    nonisolated static func freeBytes() -> Int64? {
        let url = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        do {
            let v = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let b = v.volumeAvailableCapacityForImportantUsage, b > 0 { return b }
            if let b = v.volumeAvailableCapacity { return Int64(b) }
            return v.volumeAvailableCapacityForImportantUsage
        } catch {
            AppLog.warn("preflight", "free space unknown", error)
            return nil
        }
    }
}
