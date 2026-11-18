import AVFoundation
import BounceCore
import CoreMedia
import CoreVideo
import Foundation

/// Records one capture-kit shot into its attempt folder (CaptureKit.md, "Clip format"): video.mp4, frames.jsonl (one
/// `KitFrame` per encoded video frame: line n = video frame n), motion.jsonl (every CoreMotion sample while it runs)
/// and LiDAR depth about once a second. A flat-phone shot records motion.jsonl only (`video: false`).
///
/// ARController hands it every camera (or demo) frame on its processing queue (`consume`). The camera picture is scaled
/// there, synchronously, into a buffer from the recorder's own pool, so nothing refers to the ARFrame once that call
/// returns; everything else (the encoder, the files) happens on the recorder's serial queue. A frame is appended only
/// when the encoder is ready for it, and only appended frames get a line. Ordinary shots keep 30 of ARKit's 60 frames a
/// second (the first frame of each 1/30 s slot of time), high-frame-rate shots (drops) every frame. The recording stops by itself after the shot's seconds of
/// frame time; `finish` then completes the video asynchronously and reports a `Result` on the recorder's queue.
final class KitRecorder {
    struct Result {
        var frames: Int = 0
        var stats: [KitFrameStat] = []
        /// uptime of video frame 0 (the origin of the video's timestamps), and of the last frame
        var startTime: Double? = nil
        var endTime: Double? = nil
        var video: KitVideoInfo? = nil
        /// frames per second kept in the file
        var keptFps: Double = 0
        var depthFrames: Int = 0
        var motionSamples: Int = 0
        /// frames the encoder was not ready for (not in the file)
        var notAppended: Int = 0
        /// why the recording failed, in plain words (no paths)
        var error: String? = nil
    }

    /// the video's size: the camera picture scaled to at most this wide (1920x1440 -> 1440x1080, 3 x the app's 480x360)
    static let maxVideoWidth = 1440
    /// LiDAR depth about once a second
    static let depthInterval = 1.0

    let folder: URL
    let recordsVideo: Bool
    /// recording length (frame time, s); ignored without video (the flat-phone shot ends itself)
    let duration: Double
    let keepEvery: Int
    let keptFps: Double
    let wantsDepth: Bool

    private let io = DispatchQueue(label: "slabbounce.kit.recorder", qos: .userInitiated)
    private let lock = NSLock()
    private let completion: (Result) -> Void
    /// called once (on the recorder's queue) with the uptime of video frame 0
    private let onStart: (Double) -> Void

    // shared (lock)
    private var cancelled = false
    /// finish() was called: no more frames
    private var ended = false

    // processing queue
    /// ordinary shots keep the first frame of each 1 / keptFps slot of time, counted from the first frame offered
    private var slotOrigin: Double? = nil
    private var lastSlot = -1
    private var firstClock: Double? = nil
    private var lastDepthClock = -Double.infinity
    private var previous: (pose: RigidTransform, clock: Double)? = nil
    private var pool: CVPixelBufferPool? = nil
    private var videoSize: (width: Int, height: Int)? = nil
    private var stopped = false

    // recorder queue
    private var writer: AVAssetWriter? = nil
    private var input: AVAssetWriterInput? = nil
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
    private var codec = "hevc"
    private var bitrate = 0
    private var framesFile: KitJSONLWriter? = nil
    private var motionFile: KitJSONLWriter? = nil
    private var result = Result()
    private var lastPts: CMTime? = nil
    private var finishing = false

    /// `sourceFps`: the camera's frame rate (ARKit's kit format, usually 60; the demo's about 12).
    init(folder: URL, video: Bool, duration: Double, highFrameRate: Bool, sourceFps: Double, wantsDepth: Bool,
         onStart: @escaping (Double) -> Void, completion: @escaping (Result) -> Void) throws {
        self.folder = folder
        recordsVideo = video
        self.duration = duration
        keepEvery = highFrameRate ? 1 : max(1, Int((sourceFps / 30).rounded()))
        keptFps = sourceFps / Double(keepEvery)
        self.wantsDepth = wantsDepth
        self.onStart = onStart
        self.completion = completion
        motionFile = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.motion))
        if video { framesFile = try KitJSONLWriter(url: folder.appendingPathComponent(KitClipFiles.frames)) }
        result.keptFps = video ? keptFps : 0
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    private var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || ended }

    // MARK: frames (ARController's processing queue)

    /// Take a frame. Returns false once the recorder wants no more (it has its seconds, or was cancelled): the caller
    /// then detaches it.
    func consume(_ f: SourceFrame, output out: TrackerOutput, processingWidth: Int, ballRadius: Double) -> Bool {
        guard recordsVideo, !isEnded, !stopped else { return false }
        let pose = f.fullView.worldFromCamera
        let prev = previous
        previous = (pose, f.clock)
        if let t0 = firstClock, f.clock - t0 >= duration - 0.25 / keptFps {
            stopped = true
            finish()
            return false
        }
        // Decimation by time, not by count: a frame lost before it got here (ARKit's queue fell behind, the phone
        // throttled) then costs no kept frame, as long as another frame falls in the same slot. A quarter slot of
        // slack keeps ARKit's timestamp jitter from moving a frame into the next slot.
        var slot = 0
        if keepEvery > 1 {
            let origin = slotOrigin ?? f.clock
            slotOrigin = origin
            slot = Int(((f.clock - origin) * keptFps + 0.25).rounded(.down))
            guard slot > lastSlot else { return true }
        }

        // the video's size and the pool, from the first frame
        let full = f.fullView.intrinsics
        if videoSize == nil {
            let w = min(KitRecorder.maxVideoWidth, full.width) / 2 * 2
            let h = Int((Double(full.height) * Double(w) / Double(full.width)).rounded()) / 2 * 2
            videoSize = (w, h)
            pool = KitRecorder.makePool(width: w, height: h)
        }
        guard let size = videoSize, let pool = pool else { return true }
        var pbOut: CVPixelBuffer? = nil
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        // no buffer (the encoder holds a dozen already): this frame is not recorded
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &pbOut) == kCVReturnSuccess,
              let pb = pbOut, f.fillVideo(pb) else { return true }
        if keepEvery > 1 { lastSlot = slot }
        if firstClock == nil { firstClock = f.clock }

        // the frame's numbers, in the video's pixels
        let s = Double(size.width) / Double(full.width)
        let K = full.scaled(by: s)
        var blur: Double? = nil
        if let p = prev, let e = f.exposureDuration, e > 0, f.clock > p.clock {
            blur = KitMotionBlur.pixels(previous: p.pose, current: pose, dt: f.clock - p.clock, exposure: e, focal: K.fx)
        }
        let luma = f.meanLuma()
        let live = KitRecorder.liveResult(out, view: f.fullView, scale: s, processingWidth: processingWidth, ballRadius: ballRadius)
        let frame = KitFrame(index: 0, time: f.clock, pose: f.arkitPose, intrinsics: [Float(K.fx), Float(K.fy), Float(K.cx), Float(K.cy)],
                             tracking: f.kitTracking, exposure: f.exposureDuration, exposureOffset: f.exposureOffset,
                             ambientLumens: f.ambientLumens, colorTemperature: f.colorTemperature, luma: luma, blur: blur, live: live)
        let stat = KitFrameStat(t: f.clock, trackingNormal: f.kitTracking.isNormal, luma: luma, blurPixels: blur,
                                slabFound: live.slabFound, slabLocked: live.state == .locked, ballFound: out.ball != nil,
                                ambientLumens: f.ambientLumens)
        var depthMap: DepthMap? = nil
        if wantsDepth, f.clock - lastDepthClock >= KitRecorder.depthInterval - 0.25 / keptFps, let d = f.depth()?.0 {
            depthMap = d
            lastDepthClock = f.clock
        }
        let depth = depthMap
        io.async { self.write(pb, size: size, frame: frame, stat: stat, depth: depth) }
        return true
    }

    /// What the app showed on this frame, in the video's pixels: the tracker's state and tilt, the slab's corners (the
    /// lock's, projected; or this frame's detection while confirming) and the ball's circle.
    static func liveResult(_ out: TrackerOutput, view: BounceCore.CameraView, scale s: Double, processingWidth: Int, ballRadius: Double) -> KitLiveResult {
        var corners: [Vec2]? = nil
        if out.state == .locked, let slab = out.slab {
            let p = slab.topCorners.compactMap { view.project(world: $0) }
            if p.count == 4 { corners = p.map { $0 * s } }
        } else if let m = out.measurement, m.count == 4, processingWidth > 0 {
            let k = Double(view.intrinsics.width) * s / Double(processingWidth)
            corners = m.map { $0 * k }
        }
        var ball: (center: Vec2, radius: Double)? = nil
        if let b = out.ball, let c = view.project(world: b.center),
           let e = view.project(world: b.center + view.worldFromCamera.applyDirection(Vec3(1, 0, 0)) * ballRadius) {
            ball = (c * s, c.distance(to: e) * s)
        }
        return KitLiveResult(state: KitLiveState(out.state), tilt: out.readouts?.tiltDegrees, corners: corners, ball: ball)
    }

    // MARK: motion (any queue)

    /// One CoreMotion sample (100 Hz) for motion.jsonl.
    func appendMotion(_ s: KitMotionSample) {
        io.async {
            guard !self.finishing, let file = self.motionFile else { return }
            do {
                try file.append(s)
                self.result.motionSamples += 1
            } catch {
                if self.result.error == nil { self.result.error = "could not write the motion samples" }
            }
        }
    }

    // MARK: finishing

    /// Stop now and complete the files (also called by `consume` once the shot has its seconds). Reports once.
    func finish() {
        lock.lock(); ended = true; lock.unlock()
        io.async { self.finishOnQueue() }
    }

    /// Throw the recording away: nothing more is written and nothing is reported. Blocks until the recorder's queue has
    /// stopped writing, so the caller can delete the attempt folder right after.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        io.sync {
            // a video already being finished is left to finish (cancelling it then is not allowed); it reports nothing
            if !self.finishing, let w = self.writer, w.status == .writing { w.cancelWriting() }
            self.finishing = true
            try? self.framesFile?.close()
            try? self.motionFile?.close()
        }
    }

    private func finishOnQueue() {
        guard !finishing else { return }
        finishing = true
        if let w = writer, let input = input, w.status == .writing {
            input.markAsFinished()
            w.finishWriting {
                self.io.async { self.complete(videoOK: w.status == .completed) }
            }
        } else {
            complete(videoOK: false)
        }
    }

    private func complete(videoOK: Bool) {
        do { try framesFile?.close() } catch { if result.error == nil { result.error = "could not write the frame list" } }
        do { try motionFile?.close() } catch { if result.error == nil { result.error = "could not write the motion samples" } }
        guard !isCancelled else { return }
        if recordsVideo {
            if result.frames == 0 {
                if result.error == nil { result.error = "no camera frames were recorded" }
            } else if !videoOK {
                if result.error == nil { result.error = "the video could not be finished" + KitRecorder.code(writer?.error) }
            } else if let size = videoSize {
                let bytes = KitFiles.size(of: folder.appendingPathComponent(KitClipFiles.video))
                result.video = KitVideoInfo(codec: codec, width: size.width, height: size.height, fps: keptFps, bitrate: bitrate,
                                            frameCount: result.frames, fileBytes: bytes)
            }
        }
        completion(result)
    }

    // MARK: writing (recorder queue)

    private func write(_ pb: CVPixelBuffer, size: (width: Int, height: Int), frame: KitFrame, stat: KitFrameStat, depth: DepthMap?) {
        guard !finishing, !isCancelled, result.error == nil else { return }
        if writer == nil { setUpWriter(width: size.width, height: size.height) }
        guard let w = writer, let input = input, let adaptor = adaptor else { return }
        guard w.status == .writing else {
            result.error = "the video encoder stopped" + KitRecorder.code(w.error)
            return
        }
        guard input.isReadyForMoreMediaData else { result.notAppended += 1; return }
        let start = result.startTime ?? frame.time
        let pts = CMTime(seconds: frame.time - start, preferredTimescale: 1_000_000_000)
        if let last = lastPts, CMTimeCompare(pts, last) <= 0 { result.notAppended += 1; return }
        guard adaptor.append(pb, withPresentationTime: pts) else {
            result.error = "the video encoder stopped" + KitRecorder.code(w.error)
            return
        }
        lastPts = pts
        if result.startTime == nil {
            result.startTime = frame.time
            onStart(frame.time)
        }
        result.endTime = frame.time
        var line = frame
        line.index = result.frames
        if let d = depth {
            // depth is extra: a frame whose depth cannot be written keeps its line without it
            do {
                let folderURL = folder.appendingPathComponent(KitClipFiles.depthFolder)
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                let name = KitDepth.fileName(frame: line.index)
                try KitDepth(depthMap: d).data.write(to: folderURL.appendingPathComponent(name))
                line.depthFile = name
                result.depthFrames += 1
            } catch {}
        }
        do {
            try framesFile?.append(line)
        } catch {
            result.error = "could not write the frame list"
            return
        }
        result.stats.append(stat)
        result.frames += 1
    }

    /// The codecs to try, in order: HEVC, then H.264 where HEVC cannot be applied. The Simulator (the demo and the UI
    /// tests) goes straight to H.264: its HEVC encoder may accept the settings and then fail on the first frame.
    static var codecs: [AVVideoCodecType] {
        #if targetEnvironment(simulator)
        return [.h264]
        #else
        return [.hevc, .h264]
        #endif
    }

    /// HEVC where the phone can encode it at this size, else H.264.
    private func setUpWriter(width: Int, height: Int) {
        let url = folder.appendingPathComponent(KitClipFiles.video)
        for type in KitRecorder.codecs {
            try? FileManager.default.removeItem(at: url)
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { continue }
            let rate = KitRecorder.bitrate(width: width, height: height, fps: keptFps, hevc: type == .hevc)
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: Int(keptFps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(keptFps.rounded())),
            ]
            if type == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let settings: [String: Any] = [
                AVVideoCodecKey: type,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compression,
            ]
            guard w.canApply(outputSettings: settings, forMediaType: .video) else { continue }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
            guard w.canAdd(input) else { continue }
            w.add(input)
            guard w.startWriting() else { continue }
            w.startSession(atSourceTime: .zero)
            writer = w; self.input = input; self.adaptor = adaptor
            codec = type == .hevc ? "hevc" : "h264"
            bitrate = rate
            return
        }
        try? FileManager.default.removeItem(at: url)
        result.error = "the phone could not start the video encoder"
    }

    // MARK: helpers

    /// Target bitrate (bits/s): HEVC about 3.5 Mbit/s at 30 fps and 6 Mbit/s at 60 fps for 1440x1080, in proportion to
    /// the pixels for other sizes; H.264 1.5 times as much.
    static func bitrate(width: Int, height: Int, fps: Double, hevc: Bool) -> Int {
        let base = fps > 45 ? 6_000_000.0 : 3_500_000.0
        let pixels = Double(width * height) / Double(1440 * 1080)
        return Int(max(300_000, base * pixels * (hevc ? 1 : 1.5)))
    }

    /// The pool the camera pictures are scaled into: bi-planar 4:2:0, full range (as ARKit's), IOSurface-backed.
    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        var pool: CVPixelBufferPool? = nil
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        return pool
    }

    /// " (error 123)" for an encoder error: a number only, never a path or a localized text.
    static func code(_ e: Error?) -> String {
        guard let e = e else { return "" }
        return " (error \((e as NSError).code))"
    }
}
