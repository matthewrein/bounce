import Foundation
import XCTest
@testable import BounceCore

/// The faster per-frame conversions give exactly the output of what they replaced, bit for bit, on random inputs (any
/// size, factors 1-4, padded rows, odd sizes) and on rendered camera frames. The replaced code is kept here, verbatim,
/// as the reference (`Reference`).
final class SpeedupIdentityTests: XCTestCase {
    /// The code before the speed-ups, verbatim.
    enum Reference {
        static func fromBiplanar(luma: UnsafeBufferPointer<UInt8>, lumaWidth W: Int, lumaHeight H: Int, lumaBytesPerRow lb: Int,
                                 cbcr: UnsafeBufferPointer<UInt8>, cbcrBytesPerRow cbb: Int, factor k: Int) -> YCCImage {
            let w = W / k, h = H / k, cw = (w + 1) / 2, chh = (h + 1) / 2
            var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 128, count: cw * chh), cr = cb
            for yy in 0..<h {
                for xx in 0..<w {
                    var s = 0
                    for dy in 0..<k { let row = (yy * k + dy) * lb + xx * k; for dx in 0..<k { s += Int(luma[row + dx]) } }
                    y[yy * w + xx] = UInt8(s / (k * k))
                }
            }
            let CW = W / 2, CH = H / 2
            for yy in 0..<chh {
                for xx in 0..<cw {
                    var sb = 0, sr = 0, n = 0
                    for dy in 0..<k { let r = yy * k + dy; if r >= CH { continue }
                        for dx in 0..<k { let c = xx * k + dx; if c >= CW { continue }
                            let j = r * cbb + c * 2; sb += Int(cbcr[j]); sr += Int(cbcr[j + 1]); n += 1 } }
                    if n > 0 { cb[yy * cw + xx] = UInt8(sb / n); cr[yy * cw + xx] = UInt8(sr / n) }
                }
            }
            return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
        }

        static func colorFrame(_ img: YCCImage) -> ColorFrame {
            ColorFrame(lumaFull: img.luma, cbHalf: Plane(bytes: img.cb, width: img.chromaWidth, height: img.chromaHeight),
                       crHalf: Plane(bytes: img.cr, width: img.chromaWidth, height: img.chromaHeight), scale: 1)
        }

        static func pgmData(_ p: Plane, blockSum k: Int) -> Data {
            precondition(k >= 1 && k <= 16)
            if k == 1 { return p.pgmData() }
            let kk = Float(k * k), maxval = 255 * k * k
            var d = Data("P5\n\(p.width) \(p.height)\n\(maxval)\n".utf8)
            d.reserveCapacity(d.count + 2 * p.data.count)
            for v in p.data {
                let s = UInt16(clamp((v * kk).rounded(), 0, Float(maxval)))
                d.append(UInt8(s >> 8)); d.append(UInt8(s & 255))
            }
            return d
        }

        static func depthData(_ m: DepthMap) -> Data {
            var d = Data([66, 68, 80, 49, UInt8(m.width & 255), UInt8(m.width >> 8), UInt8(m.height & 255), UInt8(m.height >> 8)])
            d.reserveCapacity(8 + m.depth.count * 5)
            for v in m.depth { let u = v.bitPattern; d.append(contentsOf: [UInt8(u & 255), UInt8((u >> 8) & 255), UInt8((u >> 16) & 255), UInt8(u >> 24)]) }
            d.append(contentsOf: m.confidence)
            return d
        }

        /// FinderRun.chamfer as it was (on the run's own buffers)
        static func chamfer(_ run: FinderRun, t2: Float, roi: FinderRun.ROI) {
            let D = run.dist, C = run.cdist, w = run.w
            let X0 = roi.x0, Y0 = roi.y0, X1 = roi.x1, Y1 = roi.y1
            for x in X0..<X1 { D[Y0 * w + x] = 0; D[(Y1 - 1) * w + x] = 0 }
            for y in (Y0 + 1)..<(Y1 - 1) {
                let row = y * w
                D[row + X0] = 0; D[row + X1 - 1] = 0
                var left = D[row + X0]
                for x in (X0 + 1)..<(X1 - 1) {
                    let i = row + x
                    var d: UInt16 = 0
                    if C[i] < t2 { d = min(min(left, D[i - w]) &+ 3, min(D[i - w - 1], D[i - w + 1]) &+ 4) }
                    D[i] = d; left = d
                }
            }
            for y in stride(from: Y1 - 2, through: Y0 + 1, by: -1) {
                let row = y * w
                var right = D[row + X1 - 1]
                for x in stride(from: X1 - 2, through: X0 + 1, by: -1) {
                    let i = row + x
                    var d = D[i]
                    if d != 0 { d = min(d, min(right, D[i + w]) &+ 3, min(D[i + w + 1], D[i + w - 1]) &+ 4); D[i] = d }
                    right = d
                }
            }
        }
    }

    /// The camera's planes: luma rows padded past the width, interleaved CbCr at half size.
    struct Biplanar {
        var W: Int, H: Int, lb: Int, cbb: Int
        var luma: [UInt8], cbcr: [UInt8]
        init(W: Int, H: Int, lb: Int, cbb: Int, luma: [UInt8], cbcr: [UInt8]) {
            self.W = W; self.H = H; self.lb = lb; self.cbb = cbb; self.luma = luma; self.cbcr = cbcr
        }
        /// From an image of the camera's size (rows padded by `pad` bytes).
        init(_ img: YCCImage, pad: Int) {
            W = img.width; H = img.height; lb = W + pad; cbb = 2 * img.chromaWidth + pad
            luma = [UInt8](repeating: 0, count: lb * H)
            for y in 0..<H { for x in 0..<W { luma[y * lb + x] = img.y[y * W + x] } }
            cbcr = [UInt8](repeating: 0, count: cbb * img.chromaHeight)
            for y in 0..<img.chromaHeight {
                for x in 0..<img.chromaWidth {
                    cbcr[y * cbb + 2 * x] = img.cb[y * img.chromaWidth + x]; cbcr[y * cbb + 2 * x + 1] = img.cr[y * img.chromaWidth + x]
                }
            }
        }
        func convert(factor k: Int, reference: Bool) -> YCCImage {
            luma.withUnsafeBufferPointer { l in cbcr.withUnsafeBufferPointer { c in
                reference
                    ? Reference.fromBiplanar(luma: l, lumaWidth: W, lumaHeight: H, lumaBytesPerRow: lb, cbcr: c, cbcrBytesPerRow: cbb, factor: k)
                    : YCCImage.fromBiplanar(luma: l, lumaWidth: W, lumaHeight: H, lumaBytesPerRow: lb, cbcr: c, cbcrBytesPerRow: cbb, factor: k)
            } }
        }
    }

    /// Rendered camera frames: the slab from 2, 4 and 6 ft, an empty floor (960x720, the camera's 4:3 at half size).
    static let rendered: [YCCImage] = {
        let K = CameraIntrinsics(fx: 725, fy: 725, cx: 480, cy: 360, width: 960, height: 720)
        var out: [YCCImage] = []
        for (i, feet) in [2.0, 4, 6, 3].enumerated() {
            let slab = SyntheticScene.slabPose(tilt: 8, heading: 30 + Double(i) * 40, yaw: 15)
            let az = Units.radians(Double(i) * 50), el = Units.radians(50)
            let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * Units.feet(feet)
            let target = i == 3 ? slab.center + Vec3(1.5, 0, 1.5) : slab.center   // the last one: bare floor
            let view = SyntheticScene.camera(at: pos, lookingAt: target, intrinsics: K, roll: 4)
            var sc = SyntheticScene(slab: slab)
            sc.supersample = 1
            out.append(SyntheticScene.ycc(rgb: sc.renderRGB(view: view), width: K.width, height: K.height))
        }
        return out
    }()

    func testFromBiplanarIsIdenticalOnRandomInputs() {
        var rng = SeededRandom(11)
        func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(rng.next() * Double(hi - lo + 1)) % (hi - lo + 1) }
        for _ in 0..<300 {
            let W = 2 * int(8, 200), H = 2 * int(8, 160), k = int(1, 4)
            guard W / k >= 2, H / k >= 2 else { continue }
            let lb = W + int(0, 40), cbb = W + 2 * int(0, 20)
            let p = Biplanar(W: W, H: H, lb: lb, cbb: cbb, luma: (0..<(lb * H)).map { _ in UInt8(int(0, 255)) },
                             cbcr: (0..<(cbb * H / 2)).map { _ in UInt8(int(0, 255)) })
            XCTAssertEqual(p.convert(factor: k, reference: false), p.convert(factor: k, reference: true), "\(W)x\(H) k\(k) rows \(lb)/\(cbb)")
        }
    }

    func testFromBiplanarIsIdenticalOnRenderedFrames() {
        for (i, img) in SpeedupIdentityTests.rendered.enumerated() {
            let p = Biplanar(img, pad: 2 * i)
            for k in 1...4 { XCTAssertEqual(p.convert(factor: k, reference: false), p.convert(factor: k, reference: true), "frame \(i) k\(k)") }
        }
    }

    func testColorFrameIsIdenticalOnRandomAndRenderedInputs() {
        var rng = SeededRandom(12)
        func byte() -> UInt8 { UInt8(Int(rng.next() * 256) & 255) }
        for n in 0..<120 {
            let w = 3 + Int(rng.next() * 300), h = 3 + Int(rng.next() * 240)
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            let img = YCCImage(width: w, height: h, y: (0..<(w * h)).map { _ in byte() }, cb: (0..<(cw * ch)).map { _ in byte() },
                               cr: (0..<(cw * ch)).map { _ in byte() })
            let a = img.colorFrame, b = Reference.colorFrame(img)
            XCTAssertTrue(a.y.data.map(\.bitPattern) == b.y.data.map(\.bitPattern) && a.cb.data.map(\.bitPattern) == b.cb.data.map(\.bitPattern)
                          && a.cr.data.map(\.bitPattern) == b.cr.data.map(\.bitPattern), "\(n): \(w)x\(h)")
        }
        for (i, full) in SpeedupIdentityTests.rendered.enumerated() {
            for k in [1, 2, 4] {
                let img = Biplanar(full, pad: 0).convert(factor: k, reference: true)
                let a = img.colorFrame, b = Reference.colorFrame(img)
                // bit for bit (Float == is not enough for -0 / +0)
                XCTAssertEqual(a.cb.data.map(\.bitPattern), b.cb.data.map(\.bitPattern), "frame \(i) k\(k)")
                XCTAssertEqual(a.cr.data.map(\.bitPattern), b.cr.data.map(\.bitPattern), "frame \(i) k\(k)")
                XCTAssertEqual(a.y.data.map(\.bitPattern), b.y.data.map(\.bitPattern), "frame \(i) k\(k)")
            }
        }
    }

    func testBlockSumPGMIsIdentical() {
        var rng = SeededRandom(13)
        for n in 0..<60 {
            let w = 1 + Int(rng.next() * 90), h = 1 + Int(rng.next() * 70), k = 1 + Int(rng.next() * 6)
            // block averages (what the app records), plus values that are not (rounded), out of range (clamped), -0
            let kk = Float(k * k)
            var d = (0..<(w * h)).map { _ in Float(Int(rng.next() * 255 * Double(k * k))) / kk }
            if n % 3 == 0 { for i in stride(from: 0, to: d.count, by: 7) { d[i] = Float(rng.uniform(-20, 280)) } }
            if !d.isEmpty { d[0] = -0.0 }
            let p = Plane(width: w, height: h, data: d)
            XCTAssertEqual(p.pgmData(blockSum: k), Reference.pgmData(p, blockSum: k), "\(w)x\(h) k\(k)")
        }
        // a rendered frame's crop at the ball finder's factors
        let img = SpeedupIdentityTests.rendered[0]
        for k in 1...4 {
            let crop = img.luma.cropped(x0: 100, y0: 80, width: 400, height: 300).downscaled(by: k)
            XCTAssertEqual(crop.pgmData(blockSum: k), Reference.pgmData(crop, blockSum: k), "rendered k\(k)")
        }
    }

    func testDepthMapDataIsIdentical() {
        var rng = SeededRandom(14)
        for n in 0..<30 {
            let w = 1 + Int(rng.next() * 256), h = 1 + Int(rng.next() * 192)
            var depth = (0..<(w * h)).map { _ in Float(rng.uniform(0, 5)) }
            if n % 2 == 0 && depth.count > 4 { depth[0] = .nan; depth[1] = .infinity; depth[2] = -0.0; depth[3] = 0 }
            let m = DepthMap(width: w, height: h, depth: depth, confidence: (0..<(w * h)).map { _ in UInt8(Int(rng.next() * 3)) })
            XCTAssertEqual(m.data, Reference.depthData(m), "\(w)x\(h)")
            if n % 2 == 1 { XCTAssertEqual(DepthMap(data: m.data), m) }
        }
    }

    /// The slab finder's chamfer (its 3-4 distance transform over the colour match), on random colour distances and on
    /// rendered frames' own, for whole-frame and smaller search areas and several tolerances.
    func testChamferIsIdentical() {
        var rng = SeededRandom(15)
        func check(_ frame: ColorFrame, _ label: String, refs: [[Float]]) {
            let run = FinderRun(options: SlabFinder.Options(), frame: frame, intrinsics: CameraIntrinsics(fx: 362, fy: 362, cx: Double(frame.width) / 2,
                                cy: Double(frame.height) / 2, width: frame.width, height: frame.height), spec: .standard, down: Vec3(0, 0.77, 0.64),
                                detail: nil, choice: nil)
            let rois: [FinderRun.ROI] = [run.fullROI,
                                         FinderRun.ROI(x0: 20, y0: 13, x1: run.w - 31, y1: run.h - 7, w: run.w, h: run.h),
                                         FinderRun.ROI(x0: run.w / 3, y0: run.h / 4, x1: run.w / 3 + 12, y1: run.h / 4 + 12, w: run.w, h: run.h)]
            for ref in refs {
                for roi in rois where roi.isUsable {   // (the finder runs it only on usable search areas)
                    run.fillColourDistance(ref: ref, roi: roi)
                    for tol in [13.0, 26, 37.7] {
                        let t2 = Float(tol * tol)
                        // both start from the same scrap in the buffer
                        for i in 0..<run.n { run.dist[i] = UInt16(i % 7) }
                        Reference.chamfer(run, t2: t2, roi: roi)
                        let want = Array(run.dist)
                        for i in 0..<run.n { run.dist[i] = UInt16(i % 7) }
                        run.chamfer(t2: t2, roi: roi)
                        XCTAssertEqual(Array(run.dist), want, "\(label) roi \(roi.x0),\(roi.y0)-\(roi.x1),\(roi.y1) tol \(tol)")
                    }
                }
            }
        }
        for (i, img) in SpeedupIdentityTests.rendered.enumerated() {
            let small = Biplanar(img, pad: 0).convert(factor: 2, reference: true)   // 480x360, the app's processing frame
            let f = small.colorFrame
            let run = FinderRun(options: SlabFinder.Options(), frame: f, intrinsics: CameraIntrinsics(fx: 362, fy: 362, cx: 240, cy: 180,
                                width: 480, height: 360), spec: .standard, down: Vec3(0, 0.77, 0.64), detail: nil, choice: nil)
            let refs = [run.patchMean(Vec2(240, 180)), run.patchMean(Vec2(60, 300)), run.patchMean(Vec2(400, 40))]
            check(f, "rendered \(i)", refs: refs)
        }
        for n in 0..<6 {
            let w = 60 + Int(rng.next() * 200), h = 40 + Int(rng.next() * 150)
            let y = Plane(width: w, height: h, data: (0..<(w * h)).map { _ in Float(rng.uniform(0, 255)) })
            let cb = Plane(width: w, height: h, data: (0..<(w * h)).map { _ in Float(rng.uniform(-40, 40)) })
            let cr = Plane(width: w, height: h, data: (0..<(w * h)).map { _ in Float(rng.uniform(-40, 40)) })
            check(ColorFrame(y: y, cb: cb, cr: cr), "random \(n) \(w)x\(h)", refs: [[128, 0, 0, 5], [60, 10, -10, 20]])
        }
    }
    /// The app leaves the colour frame out (a blank) unless the slab detector will run on the frame
    /// (`SlabTracker.detectorWillRun`): it says exactly what `process` then does, through taps (also while tracking is
    /// limited), limited tracking, discontinuities, resets, settings changes, searching, confirming and locked.
    func testDetectorWillRunSaysExactlyWhatProcessDoes() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = BlankCountingDetector(SceneDetector(w, noise: 0.3, seed: 43))
        let tr = SlabTracker(settings: RecordingSettings().trackerSettings, detector: det)
        var rng = SeededRandom(16)
        let image = ColorFrame(gray: Plane(width: 16, height: 12)), blank = ColorFrame(gray: Plane(width: 2, height: 2))
        var ran = 0, limited = 0, taps = 0
        for k in 0..<1500 {
            let t = Double(k) / 60
            let v = w.view(from: Vec3(0.08 * sin(t * 0.7), 0.9, 0.05 * cos(t * 0.5)), at: slab.center)
            det.inner.currentView = v
            if rng.next() < 0.004 { tr.noteWorldDiscontinuity("test") }
            if rng.next() < 0.002 { tr.reset() }
            if rng.next() < 0.003 { var s = tr.settings; s.recheckInterval = rng.next() < 0.5 ? 0.3 : 0.2; tr.settings = s }
            let normal = !(k % 400 >= 330 && k % 400 < 380)
            let tap: Vec2? = rng.next() < 0.01 ? Vec2(240, 180) : nil
            if !normal { limited += 1 }
            if tap != nil { taps += 1 }
            // (as the app asks: only a tap taken for the slab makes the detector run, `SlabTracker.tapSeedsSlab`; with the
            // app's tap hints a tap on the locked slab looks for the ball there instead)
            let will = tr.detectorWillRun(at: t, tap: tap.map { tr.tapSeedsSlab($0, view: v) } ?? false, trackingNormal: normal)
            let out = tr.process(TrackerFrame(timestamp: t, view: v, frame: will ? image : blank, tap: tap, trackingNormal: normal))
            XCTAssertEqual(will, out.detectionKind != nil, "frame \(k) (\(out.state.rawValue), tap \(tap != nil), normal \(normal))")
            if out.detectionKind != nil { ran += 1 }
        }
        XCTAssertEqual(det.blanks, 0, "the detector never had the blank")
        XCTAssertGreaterThan(ran, 100); XCTAssertGreaterThan(limited, 100); XCTAssertGreaterThan(taps, 5)
        XCTAssertGreaterThan(tr.counts["rechecks"] ?? 0, 20, "it was locked for a while")
    }
}
