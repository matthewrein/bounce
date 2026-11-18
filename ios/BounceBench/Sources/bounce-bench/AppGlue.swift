import BounceCore
import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// The app's per-frame work around the tracker that runs BounceCore code (ARController.session(_:didUpdate:), process
/// and handle): the hand-off and its frame numbers on every frame, the video-format watch, the capture-lock gate, the overlay's projections (the
/// outline, the path's 41 samples, its start, apex, landing and normal tip, the ball), the HUD's strings, the event list,
/// and the developer line's frame numbers once a second (FramePacer.report). Replicated here: CoreGraphics' display
/// transform is six numbers, the viewport an iPhone's. Not here: reading the capture device's adjusting flags, the
/// motion manager, publishing to the main thread (app-only calls with no BounceCore part).
struct AppGlue {
    /// the delegate's hand-off (its frame numbers: the pacer behind it)
    let handoff = FrameHandoff<Int>()
    var formatWatch = VideoFormatWatch()
    var gate = CaptureLockGate()
    var framesLineTime = -Double.infinity
    var framesLine: String? = nil
    var recentEvents: [String] = []
    var hud: [String] = []
    var overlay: [Vec2] = []
    /// ARKit's displayTransform for a portrait view of the landscape image (normalised image -> normalised view)
    let ta = 0.0, tb = 1.0, tc = -1.0, td = 0.0, ttx = 1.0, tty = 0.0
    let vpW = 393.0, vpH = 852.0

    /// On arrival (ARKit's delegate, 30 ms after capture): the format watch and the hand-off (every frame is processed
    /// in these runs: the previous one was finished first).
    mutating func arrived(t: Double, width: Int, height: Int) {
        _ = formatWatch.note(width: width, height: height, at: t)
        _ = handoff.deliver(0, captureTime: t, now: t + 0.03, nominalInterval: 1.0 / 60)
        handoff.delegateReturned(entered: t + 0.03, now: t + 0.03 + 0.00002)
    }

    @inline(__always) func toView(_ p: Vec3, _ view: CameraView) -> Vec2? {
        guard let q = view.project(world: p) else { return nil }
        let nx = q.x / Double(view.intrinsics.width), ny = q.y / Double(view.intrinsics.height)
        return Vec2((ta * nx + tc * ny + ttx) * vpW, (tb * nx + td * ny + tty) * vpH)
    }

    /// After tracker.process: the capture-lock gate, the overlay, the HUD, the events, the developer line, the pacer.
    mutating func after(_ out: TrackerOutput, full: CameraView, t: Double, processSeconds: Double, ballRadius: Double) {
        if !out.events.isEmpty {
            recentEvents.append(contentsOf: out.events.map { String(format: "%.2f ", t) + $0 })
            if recentEvents.count > 40 { recentEvents.removeFirst(recentEvents.count - 40) }
        }
        _ = gate.note(events: out.events, at: t)
        _ = gate.update(at: t, adjusting: CaptureLockGate.Adjusting(focus: false, exposure: false, whiteBalance: false))
        overlay.removeAll(keepingCapacity: true)
        if out.state == .locked, let s = out.slab {
            overlay += s.topCorners.compactMap { toView($0, full) }
            if let path = out.path {
                overlay += path.samples(count: 40).compactMap { toView($0, full) }
                for p in [path.start, path.apex, path.landing, path.start + path.direction * 0.08] { if let v = toView(p, full) { overlay.append(v) } }
            }
            if let b = out.ball, let c = toView(b.center, full),
               let e = toView(b.center + full.worldFromCamera.applyDirection(Vec3(1, 0, 0)) * ballRadius, full) {
                overlay.append(c); overlay.append(Vec2(hypot(e.x - c.x, e.y - c.y), 0))
            }
        } else if let m = out.measurement {
            overlay += m.map { Vec2($0.x / 480 * vpW, $0.y / 360 * vpH) }
        }
        hud.removeAll(keepingCapacity: true)
        if let r = out.readouts {
            hud.append(String(format: "%.1f°", r.tiltDegrees))
            hud.append(String(format: "%.2f m", r.apexHeight))
            hud.append(String(format: "%.2f m", r.landingDistance))
            hud.append(String(format: "%.2f s", r.airTime))
            hud.append(String(format: "%.2f m", r.dropHeight) + (r.dropFromBall ? " (ball)" : ""))
        }
        if let c = out.depth { hud.append(String(format: "%d pts %.1f°", c.points, c.angleToImageDegrees)) }
        if t - framesLineTime >= 1 || t < framesLineTime {
            framesLine = AppGlue.framesLine(handoff.report)
            framesLineTime = t
        }
        _ = handoff.finished(captureTime: t, seconds: processSeconds, now: t + 0.03 + processSeconds, output: out)
    }

    /// ARController.framesLine, verbatim.
    static func framesLine(_ r: FramePacingReport) -> String? {
        let w = r.recent
        guard w.framesReceived > 0, w.seconds > 0 else { return nil }
        func ms(_ m: FramePacingReport.Millis?) -> String { m.map { String(format: "%.0f/%.0f", $0.p50, $0.p95) } ?? "-" }
        func p95(_ m: FramePacingReport.Millis?) -> String { m.map { String(format: "%.0f", $0.p95) } ?? "-" }
        func share(_ n: Int) -> String { String(format: "%.0f", 100 * Double(n) / Double(w.framesReceived)) }
        let rate = String(format: "%.1f", Double(w.framesReceived) / w.seconds)
        let runs = String(format: "%.1f", w.searchesPerSecond + w.rechecksPerSecond)
        let k = w.processingByKind
        let queued: Int = w.framesQueuedOnDelegate ?? 0
        let dropped: Int = (w.framesDroppedBusy ?? 0) + w.framesSkippedLate
        let queuedText: String = queued > 0 ? ", " + share(queued) + "% queued behind it" : ""
        let delegate: String = "delegate " + p95(w.delegateMs) + " ms p95" + queuedText
        return "frames: \(rate)/s in, \(share(dropped))% dropped busy, "
            + "held \(w.maxFramesHeld.map { String($0) } ?? "-"), wait \(ms(w.handoffWaitMs)) ms, \(share(w.framesLateButIdle))% late from ARKit, "
            + delegate + ", "
            + "\(w.cameraGaps) gaps, \(w.pauses) pauses, delivery \(ms(w.deliveryLatencyMs)) ms, process \(ms(w.processingMs)) ms "
            + "(p50/p95; p95 plain \(p95(k.plain)), ball \(p95(k.ball)), search \(p95(k.search)), re-check \(p95(k.recheck))), "
            + "detector \(runs)/s"
    }
}

/// The capture kit recorder's work on the processing queue for each frame it keeps (KitRecorder.consume): the camera
/// image scaled into the kit's 1440x1080 video buffer (FrameConversion.scale: vImage's Lanczos scale of luma and CbCr; on
/// Linux a pure-Swift Lanczos-3 stand-in, much slower than vImage), the mean luma (KitImageStats.meanLuma, every 8th
/// pixel), and the depth copied once a second. The encoder and disk writes are on the kit's own queues (not here).
final class KitWork {
    static let dw = 1440, dh = 1080
    var dl = [UInt8](repeating: 0, count: dw * dh), dc = [UInt8](repeating: 0, count: dw * dh / 2)
    var lastDepth = -Double.infinity
    #if !canImport(Accelerate)
    let standIn = LanczosStandIn(srcW: 1920, srcH: 1440, dstW: dw, dstH: dh)
    #endif

    func consume(_ s: BenchScene, t: Double) {
        scale(s)
        s.luma.withUnsafeBufferPointer { blackHole(KitImageStats.meanLuma(bytes: $0, width: s.width, height: s.height, bytesPerRow: s.lumaStride, step: 8)) }
        if t - lastDepth >= 1 { blackHole(s.depthFromBuffers()); lastDepth = t }
    }

    func scale(_ s: BenchScene, oneCore: Bool = false) {
        #if canImport(Accelerate)
        s.luma.withUnsafeBufferPointer { lp in s.cbcr.withUnsafeBufferPointer { cp in
            dl.withUnsafeMutableBufferPointer { dlp in dc.withUnsafeMutableBufferPointer { dcp in
                blackHole(AppReplicas.kitVideoScale(luma: lp, cbcr: cp, width: s.width, height: s.height, lumaStride: s.lumaStride, cbcrStride: s.cbcrStride,
                                                    into: dlp, dcp, dw: KitWork.dw, dh: KitWork.dh, oneCore: oneCore))
            } }
        } }
        #else
        s.luma.withUnsafeBufferPointer { lp in s.cbcr.withUnsafeBufferPointer { cp in
            dl.withUnsafeMutableBufferPointer { dlp in dc.withUnsafeMutableBufferPointer { dcp in
                standIn.scale(luma: lp.baseAddress!, lumaStride: s.lumaStride, cbcr: cp.baseAddress!, cbcrStride: s.cbcrStride,
                              intoLuma: dlp.baseAddress!, cbcr: dcp.baseAddress!)
            } }
        } }
        #endif
    }
}

/// A separable Lanczos-3 scale in plain Swift (Float, precomputed taps): the Linux stand-in for vImage's
/// vImageScale_Planar8 and vImageScale_CbCr8 (the same filter, without vImage's SIMD; several times slower).
final class LanczosStandIn {
    struct Taps { var first: [Int]; var w: [Float]; var n: Int }
    let srcW: Int, srcH: Int, dstW: Int, dstH: Int
    let lx: Taps, ly: Taps, cx: Taps, cy: Taps
    var tmp: [Float]

    init(srcW: Int, srcH: Int, dstW: Int, dstH: Int) {
        self.srcW = srcW; self.srcH = srcH; self.dstW = dstW; self.dstH = dstH
        lx = LanczosStandIn.taps(src: srcW, dst: dstW); ly = LanczosStandIn.taps(src: srcH, dst: dstH)
        cx = LanczosStandIn.taps(src: srcW / 2, dst: dstW / 2); cy = LanczosStandIn.taps(src: srcH / 2, dst: dstH / 2)
        tmp = [Float](repeating: 0, count: dstW * srcH)
    }

    static func taps(src: Int, dst: Int) -> Taps {
        let scale = Double(src) / Double(dst), support = 3 * max(1, scale)
        let n = Int((2 * support).rounded(.up))
        var first = [Int](repeating: 0, count: dst), w = [Float](repeating: 0, count: dst * n)
        func lanczos(_ x: Double) -> Double {
            if x == 0 { return 1 }
            if abs(x) >= 3 { return 0 }
            let px = Double.pi * x
            return 3 * sin(px) * sin(px / 3) / (px * px)
        }
        for o in 0..<dst {
            let c = (Double(o) + 0.5) * scale - 0.5
            let f = Int((c - support).rounded(.up))
            first[o] = f
            var sum = 0.0, ws = [Double](repeating: 0, count: n)
            for j in 0..<n { ws[j] = lanczos((Double(f + j) - c) / max(1, scale)); sum += ws[j] }
            for j in 0..<n { w[o * n + j] = Float(ws[j] / sum) }
        }
        return Taps(first: first, w: w, n: n)
    }

    /// planes: `channels` interleaved bytes per pixel
    private func pass(_ src: UnsafePointer<UInt8>, _ stride: Int, _ W: Int, _ H: Int, _ channels: Int, _ tx: Taps, _ ty: Taps, _ ow: Int, _ oh: Int,
                      _ dst: UnsafeMutablePointer<UInt8>, _ dstStride: Int) {
        tmp.withUnsafeMutableBufferPointer { tp in
            let t = tp.baseAddress!
            tx.w.withUnsafeBufferPointer { wx in
                for y in 0..<H {
                    let row = src + y * stride, out = t + y * ow * channels
                    for o in 0..<ow {
                        let f = tx.first[o], wo = wx.baseAddress! + o * tx.n
                        for ch in 0..<channels {
                            var acc: Float = 0
                            for j in 0..<tx.n { let x = min(W - 1, max(0, f + j)); acc += wo[j] * Float(row[x * channels + ch]) }
                            out[o * channels + ch] = acc
                        }
                    }
                }
            }
            ty.w.withUnsafeBufferPointer { wy in
                for o in 0..<oh {
                    let f = ty.first[o], wo = wy.baseAddress! + o * ty.n, out = dst + o * dstStride
                    for x in 0..<(ow * channels) {
                        var acc: Float = 0
                        for j in 0..<ty.n { let y = min(H - 1, max(0, f + j)); acc += wo[j] * t[y * ow * channels + x] }
                        out[x] = UInt8(max(0, min(255, acc.rounded())))
                    }
                }
            }
        }
    }

    func scale(luma: UnsafePointer<UInt8>, lumaStride: Int, cbcr: UnsafePointer<UInt8>, cbcrStride: Int,
               intoLuma dl: UnsafeMutablePointer<UInt8>, cbcr dc: UnsafeMutablePointer<UInt8>) {
        pass(luma, lumaStride, srcW, srcH, 1, lx, ly, dstW, dstH, dl, dstW)
        pass(cbcr, cbcrStride, srcW / 2, srcH / 2, 2, cx, cy, dstW / 2, dstH / 2, dc, dstW)
    }
}
