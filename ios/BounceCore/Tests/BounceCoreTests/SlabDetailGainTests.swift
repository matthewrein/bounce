import XCTest
@testable import BounceCore

/// What refining the slab's edges on the camera's full-resolution pixels gains over the processing frame alone, measured
/// on the synthetic slab rendered at the phone's full size (1920x1440) and processed as the app does (shrunk by 4 to
/// 480x360 for finding; the crop `SlabImageCrop` plans cut from the full image for the edges).
final class SlabDetailGainTests: XCTestCase {
    /// the phone's camera (an iPhone's wide camera in ARKit's 4:3 format) and the app's processing frame
    static let full = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
    static let factor = 4
    static var processing: CameraIntrinsics {
        let K = full.scaled(by: 1 / Double(factor))
        return CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, width: full.width / factor, height: full.height / factor)
    }

    /// One rendered view: the processing frame (as the app's `FrameConversion.ycc` makes it: 4 x 4 block averages of the
    /// camera image) and the camera image itself in a window around the slab (rendering all 2.8 Mpx would take too long
    /// in a debug build; outside the window the processing frame is rendered directly, 2 x 2 samples a pixel).
    struct View {
        var scene: SyntheticScene
        var view: CameraView               // the full image's camera
        var processingImage: YCCImage
        var window: (x0: Int, y0: Int, w: Int, h: Int)
        var windowLuma: [UInt8]

        var pview: CameraView { CameraView(worldFromCamera: view.worldFromCamera, intrinsics: SlabDetailGainTests.processing) }
        var down: Vec3 { pview.directionToCamera(ARKitConvention.worldDown) }
        var truthFull: [Vec2] { scene.corners(in: view)! }
        var truthNormal: Vec3 { view.directionToCamera(scene.slab.normal) }

        /// the app's `FrameConversion.lumaCrop` on the camera image (nil outside the rendered window)
        func cut(_ c: SlabImageCrop) -> Plane? {
            let k = c.factor, w = c.imageWidth, h = c.imageHeight
            guard c.x0 >= window.x0, c.y0 >= window.y0, c.x0 + w * k <= window.x0 + window.w, c.y0 + h * k <= window.y0 + window.h else { return nil }
            var d = [Float](repeating: 0, count: w * h)
            let inv = 1 / Float(k * k)
            for yy in 0..<h {
                for xx in 0..<w {
                    var s = 0
                    for dy in 0..<k {
                        let r = (c.y0 - window.y0 + yy * k + dy) * window.w + (c.x0 - window.x0 + xx * k)
                        for dx in 0..<k { s += Int(windowLuma[r + dx]) }
                    }
                    d[yy * w + xx] = Float(s) * inv
                }
            }
            return Plane(width: w, height: h, data: d)
        }

        var provider: ([Vec2]) -> SlabDetail? {
            SlabImageCrop.provider(processing: SlabDetailGainTests.processing, full: SlabDetailGainTests.full) { self.cut($0) }
        }
    }

    static func render(feet: Double, tilt: Double, heading: Double, azimuth: Double, elevation: Double, supersample: Int = 2,
                       noise: Double = 0, seed: UInt64 = 1) -> View {
        let slab = SyntheticScene.slabPose(tilt: tilt, heading: heading, yaw: 15 + azimuth / 3)
        let az = Units.radians(azimuth), el = Units.radians(elevation)
        let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * Units.feet(feet)
        let view = SyntheticScene.camera(at: pos, lookingAt: slab.center + Vec3(0.03, 0, -0.02), intrinsics: full, roll: 4)
        var sc = SyntheticScene(slab: slab)
        // the window: the slab and its base, grown by a side and more, aligned to the 4 x 4 blocks
        let pts = (slab.topCorners + slab.topCorners.map { $0 - slab.normal * sc.spec.thickness - Vec3(0, 0.03, 0) }).compactMap { view.project(world: $0) }
        let side = ShapeCheck.meanSide(Array(pts.prefix(4)))
        func down4(_ v: Double) -> Int { max(0, Int(floor(v / 4)) * 4) }
        let x0 = down4(pts.map { $0.x }.min()! - side - 64), y0 = down4(pts.map { $0.y }.min()! - side - 64)
        let x1 = min(full.width, Int(ceil((pts.map { $0.x }.max()! + side + 64) / 4)) * 4)
        let y1 = min(full.height, Int(ceil((pts.map { $0.y }.max()! + side + 64) / 4)) * 4)
        let ww = x1 - x0, wh = y1 - y0
        // the camera image in the window: `supersample`^2 samples a pixel, softened like a camera's optics ([1 2 1]), with
        // sensor noise (Gaussian, `noise` grey levels)
        sc.supersample = supersample
        var wrgb = sc.renderRGB(view: CameraView(worldFromCamera: view.worldFromCamera,
                                                 intrinsics: full.cropped(x0: Double(x0), y0: Double(y0), scale: 1, width: ww, height: wh)))
        if supersample > 1 { SyntheticScene.soften(&wrgb, ww, wh) }
        if noise > 0 {
            var rng = SeededRandom(seed)
            for i in 0..<(ww * wh) {
                let n = rng.gaussian() * noise
                for ch in 0..<3 { wrgb[i * 3 + ch] = UInt8(clamp((Double(wrgb[i * 3 + ch]) + n).rounded(), 0, 255)) }
            }
        }
        let wy = SyntheticScene.ycc(rgb: wrgb, width: ww, height: wh).y
        // the processing frame: rendered directly, then the window's part replaced by the camera image's 4 x 4 averages
        sc.supersample = 2
        let pK = processing
        var prgb = sc.renderRGB(view: CameraView(worldFromCamera: view.worldFromCamera, intrinsics: pK))
        for py in (y0 / 4)..<(y1 / 4) {
            for px in (x0 / 4)..<(x1 / 4) {
                for ch in 0..<3 {
                    var s = 0
                    for dy in 0..<4 { for dx in 0..<4 { s += Int(wrgb[((py * 4 - y0 + dy) * ww + (px * 4 - x0 + dx)) * 3 + ch]) } }
                    prgb[(py * pK.width + px) * 3 + ch] = UInt8(s / 16)
                }
            }
        }
        return View(scene: sc, view: view, processingImage: SyntheticScene.ycc(rgb: prgb, width: pK.width, height: pK.height),
                    window: (x0, y0, ww, wh), windowLuma: wy)
    }

    struct Errors { var cornersPx: Double; var normalDeg: Double; var tiltDeg: Double }

    /// An outline's errors (processing pixels in, full image pixels out): rms corner distance, the solved pose's normal
    /// and tilt against the truth.
    static func errors(_ q: [Vec2], _ v: View) -> Errors? {
        let map = ImageMap(from: processing, to: full)
        let truth = v.truthFull
        let a = SlabTracker.aligned(q.map(map.forward), to: truth)
        let rms = SlabTracker.rmsDistance(a, truth)
        guard let fit = PoseSolver.solve(corners: q, intrinsics: processing, spec: .standard, down: v.down) else { return nil }
        let up = -v.down
        let tiltTrue = Units.degrees(v.truthNormal.angle(to: up)), tiltFit = Units.degrees(fit.pose.normal.angle(to: up))
        return Errors(cornersPx: rms, normalDeg: Units.degrees(fit.pose.normal.angle(to: v.truthNormal)), tiltDeg: abs(tiltFit - tiltTrue))
    }

    static func nearest(_ outlines: [DetectedOutline], _ v: View) -> DetectedOutline? {
        let truthP = v.truthFull.map { $0 / Double(factor) }
        return outlines.min { SlabTracker.rmsDistance(SlabTracker.aligned($0.quad, to: truthP), truthP)
                              < SlabTracker.rmsDistance(SlabTracker.aligned($1.quad, to: truthP), truthP) }
            .flatMap { SlabTracker.rmsDistance(SlabTracker.aligned($0.quad, to: truthP), truthP) < 6 ? $0 : nil }
    }

    func testFullResolutionEdgesBeatTheProcessingFrame() throws {
        // 3-6 ft, tilts of 3 and 8 degrees, from several sides and heights
        let cases: [(feet: Double, tilt: Double, heading: Double, az: Double, el: Double)] = [
            (3, 3, 20, 10, 50), (3, 8, 200, -25, 42),
            (4, 3, 120, 35, 45), (4, 8, 300, 0, 55),
            (5, 3, 250, -15, 40), (5, 8, 60, 20, 48),
            (6, 3, 160, 5, 44), (6, 8, 330, -30, 52),
        ]
        var coarse: [Errors] = [], refined: [Errors] = [], cropped: [Errors] = [], secondPass: [Errors] = []
        var lines: [String] = []
        var tracked: View? = nil
        for c in cases {
            let t0 = Date()
            let v = SlabDetailGainTests.render(feet: c.feet, tilt: c.tilt, heading: c.heading, azimuth: c.az, elevation: c.el, noise: 2)
            let frame = v.processingImage.colorFrame, pK = SlabDetailGainTests.processing
            // the search on the processing frame alone (what every measurement was before)
            let det = SlabFinderDetector()
            let found = det.detect(frame: frame, intrinsics: pK, spec: .standard, down: v.down, seed: nil, near: nil)
            let hit = try XCTUnwrap(SlabDetailGainTests.nearest(found, v), "\(c): the search finds the slab")
            let e0 = try XCTUnwrap(SlabDetailGainTests.errors(hit.quad, v))
            // the tracker's refine pass: the crop planned around the find, the finder following that outline on it
            let crop = try XCTUnwrap(SlabImageCrop.plan(outline: hit.quad, processing: pK, full: SlabDetailGainTests.full))
            let detail = try XCTUnwrap(v.cut(crop).map { DetailImage(luma: $0, intrinsics: crop.intrinsics(full: SlabDetailGainTests.full)) },
                                       "\(c): the crop lies in the rendered window")
            let r = det.refine(outline: hit.quad, frame: frame, intrinsics: pK, spec: .standard, down: v.down, detail: detail)
            let e1 = try XCTUnwrap(SlabDetailGainTests.nearest(r, v).flatMap { SlabDetailGainTests.errors($0.quad, v) }, "\(c): refined")
            // the same second pass on the processing frame alone (so the gain is the pixels', not the second pass's)
            let det2 = SlabFinderDetector()
            _ = det2.detect(frame: frame, intrinsics: pK, spec: .standard, down: v.down, seed: nil, near: nil)
            let r2 = det2.detect(frame: frame, intrinsics: pK, spec: .standard, down: v.down, seed: nil, near: hit.quad)
            let e2 = try XCTUnwrap(SlabDetailGainTests.nearest(r2, v).flatMap { SlabDetailGainTests.errors($0.quad, v) })
            // a re-check of the lock: the finder following the lock's outline (here the true one), the crop around it cut
            // up front
            let det3 = SlabFinderDetector()
            _ = det3.detect(frame: frame, intrinsics: pK, spec: .standard, down: v.down, seed: nil, near: nil)
            let truthP = v.truthFull.map { $0 / Double(SlabDetailGainTests.factor) }
            let pre = try XCTUnwrap(v.provider(truthP))
            let r3 = det3.detect(frame: frame, intrinsics: pK, spec: .standard, down: v.down, seed: nil, near: truthP, detail: pre.image)
            let e3 = try XCTUnwrap(SlabDetailGainTests.nearest(r3, v).flatMap { SlabDetailGainTests.errors($0.quad, v) })
            // a find a band off on some side (the box model took the cut face's bottom for the top edge: corners several
            // pixels off on the processing frame and the camera's alike) is not a matter of resolution: reported, left
            // out of the means
            if e0.cornersPx > 3 && e1.cornersPx > 3 {
                lines.append(String(format: "%.0f ft tilt %.0f: the find is a band off (corners %.1f px, normal %.1f deg) on both: left out", c.feet, c.tilt,
                                    e0.cornersPx, e0.normalDeg))
                continue
            }
            coarse.append(e0); refined.append(e1); secondPass.append(e2); cropped.append(e3)
            if crop.factor == 1 { XCTAssertLessThanOrEqual(e1.cornersPx, e0.cornersPx + 0.05, "\(c)") }
            else { XCTAssertLessThanOrEqual(e1.cornersPx, e0.cornersPx + 0.15, "\(c): a shrunk crop is no worse") }
            lines.append(String(format: "%.0f ft tilt %.0f: corners %.2f -> %.2f px (re-check %.2f, 2nd pass alone %.2f); normal %.2f -> %.2f deg (%.2f, %.2f); tilt %.2f -> %.2f deg (%.2f, %.2f); crop %dx%d /%d; %.1f s",
                                c.feet, c.tilt, e0.cornersPx, e1.cornersPx, e3.cornersPx, e2.cornersPx, e0.normalDeg, e1.normalDeg, e3.normalDeg, e2.normalDeg,
                                e0.tiltDeg, e1.tiltDeg, e3.tiltDeg, e2.tiltDeg, crop.width, crop.height, crop.factor, Date().timeIntervalSince(t0)))
            if c.feet == 6 && c.tilt == 8 { tracked = v }
        }
        func mean(_ e: [Errors], _ k: KeyPath<Errors, Double>) -> Double { e.map { $0[keyPath: k] }.reduce(0, +) / Double(e.count) }
        func worst(_ e: [Errors], _ k: KeyPath<Errors, Double>) -> Double { e.map { $0[keyPath: k] }.max()! }
        for l in lines { print("detail gain: " + l) }
        print(String(format: "detail gain, mean over %d views: corners %.2f -> %.2f px (re-check %.2f, 2nd pass alone %.2f); normal %.2f -> %.2f deg (%.2f, %.2f); tilt %.2f -> %.2f deg (%.2f, %.2f); worst normal %.2f -> %.2f deg",
                     coarse.count, mean(coarse, \.cornersPx), mean(refined, \.cornersPx), mean(cropped, \.cornersPx), mean(secondPass, \.cornersPx),
                     mean(coarse, \.normalDeg), mean(refined, \.normalDeg), mean(cropped, \.normalDeg), mean(secondPass, \.normalDeg),
                     mean(coarse, \.tiltDeg), mean(refined, \.tiltDeg), mean(cropped, \.tiltDeg), mean(secondPass, \.tiltDeg),
                     worst(coarse, \.normalDeg), worst(refined, \.normalDeg)))
        // the gain, locked in (measured: see the printed lines)
        XCTAssertGreaterThanOrEqual(coarse.count, 6)
        XCTAssertLessThan(mean(refined, \.cornersPx), 0.7 * mean(coarse, \.cornersPx))
        XCTAssertLessThan(mean(cropped, \.cornersPx), 0.7 * mean(coarse, \.cornersPx))
        XCTAssertLessThan(mean(refined, \.normalDeg), 0.8 * mean(coarse, \.normalDeg))
        XCTAssertLessThan(mean(cropped, \.normalDeg), 0.8 * mean(coarse, \.normalDeg))
        XCTAssertLessThan(worst(refined, \.normalDeg), worst(coarse, \.normalDeg))
        XCTAssertLessThan(mean(refined, \.cornersPx), 0.7 * mean(secondPass, \.cornersPx), "the gain is the pixels', not the second pass's")

        // through the tracker: the lock made from one still view, with and without the camera's pixels
        let v = try XCTUnwrap(tracked)
        var locks: [Bool: SlabPose] = [:]
        for withPixels in [false, true] {
            // the app's tracker settings on the scene's slab (rendered as the old box: this test is about full-resolution edges)
            var settings = RecordingSettings().trackerSettings
            settings.spec = v.scene.spec
            let tr = SlabTracker(settings: settings, detector: SlabFinderDetector())
            for i in 0..<45 {
                _ = tr.process(TrackerFrame(timestamp: Double(i) / 30, view: v.pview, frame: v.processingImage.colorFrame,
                                            slabDetail: withPixels ? v.provider : nil))
            }
            XCTAssertEqual(tr.state, .locked, "with pixels \(withPixels)")
            locks[withPixels] = tr.imageSlab
            if withPixels { XCTAssertTrue(tr.detectionLog.allSatisfy { $0.edges != nil }, "\(tr.detectionLog.map { $0.edges ?? "-" })") }
            else { XCTAssertTrue(tr.detectionLog.allSatisfy { $0.edges == nil }) }
        }
        let n0 = try XCTUnwrap(locks[false]).normal, n1 = try XCTUnwrap(locks[true]).normal
        let truthW = v.scene.slab.normal
        print(String(format: "detail gain, the tracker's lock at 6 ft, 8 deg: normal error %.2f deg on the processing frame alone, %.2f deg with full-resolution edges",
                     Units.degrees(n0.angle(to: truthW)), Units.degrees(n1.angle(to: truthW))))
        XCTAssertLessThan(Units.degrees(n1.angle(to: truthW)), 0.5 * Units.degrees(n0.angle(to: truthW)))
    }
}
