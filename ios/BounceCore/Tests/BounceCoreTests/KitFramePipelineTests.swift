import XCTest
@testable import BounceCore

/// A detector that reports the slab's true outline in whatever view it is told about.
final class TrueOutlineDetector: SlabDetecting {
    var slab: SlabPose
    var view: CameraView?
    private(set) var calls = 0
    init(slab: SlabPose) { self.slab = slab }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        calls += 1
        guard let v = view else { return [] }
        let q = slab.topCorners.compactMap { CameraView(worldFromCamera: v.worldFromCamera, intrinsics: intrinsics).project(world: $0) }
        return q.count == 4 ? [DetectedOutline(quad: q)] : []
    }
}

final class KitFramePipelineTests: XCTestCase {
    /// A deterministic, textured full-range frame (luma and chroma vary across the image).
    static func texturedFrame(width w: Int, height h: Int, seed: Int = 1) -> YCCImage {
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 0, count: cw * ch), cr = cb
        for j in 0..<h { for i in 0..<w { y[j * w + i] = UInt8((i * 7 + j * 13 + (i * j + seed) % 29) % 256) } }
        for j in 0..<ch { for i in 0..<cw { cb[j * cw + i] = UInt8(90 + (i * 3 + j) % 70); cr[j * cw + i] = UInt8(100 + (i + j * 5) % 60) } }
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }

    /// The app's own conversions (ARController.handle with FrameConversion.ycc and .lumaCrop), on the video frame as if it
    /// were the camera buffer: the reference the pipeline must match.
    struct AppPath {
        static func ycc(_ img: YCCImage, factor k: Int) -> YCCImage {
            let cw = img.chromaWidth
            var cbcr = [UInt8](repeating: 0, count: cw * img.chromaHeight * 2)
            for i in 0..<(cw * img.chromaHeight) { cbcr[2 * i] = img.cb[i]; cbcr[2 * i + 1] = img.cr[i] }
            return img.y.withUnsafeBufferPointer { l in cbcr.withUnsafeBufferPointer { c in
                YCCImage.fromBiplanar(luma: l, lumaWidth: img.width, lumaHeight: img.height, lumaBytesPerRow: img.width, cbcr: c,
                                      cbcrBytesPerRow: cw * 2, factor: k)
            } }
        }

        static func lumaCrop(_ img: YCCImage, x0: Int, y0: Int, width cw: Int, height chh: Int, factor k: Int) -> Plane? {
            let w = img.width, h = img.height, lb = img.width
            let ax = max(0, min(w - 1, x0)), ay = max(0, min(h - 1, y0))
            let ow = min(cw, w - ax) / k, oh = min(chh, h - ay) / k
            guard ow > 8, oh > 8 else { return nil }
            var d = [Float](repeating: 0, count: ow * oh)
            let inv = 1 / Float(k * k)
            for yy in 0..<oh {
                for xx in 0..<ow {
                    var s = 0
                    for dy in 0..<k { let r = (ay + yy * k + dy) * lb + ax + xx * k; for dx in 0..<k { s += Int(img.y[r + dx]) } }
                    d[yy * ow + xx] = Float(s) * inv
                }
            }
            return Plane(width: ow, height: oh, data: d)
        }

        /// The TrackerFrame ARController.handle builds (no tap, no recording).
        static func trackerFrame(full: CameraView, img: YCCImage, t: Double, normal: Bool, tracker: SlabTracker,
                                 depth: (DepthMap, CameraIntrinsics)?) -> TrackerFrame {
            let factor = max(1, full.intrinsics.width / 480)
            let K = full.intrinsics.scaled(by: 1 / Double(factor))
            let pview = CameraView(worldFromCamera: full.worldFromCamera,
                                   intrinsics: CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy,
                                                                width: full.intrinsics.width / factor, height: full.intrinsics.height / factor))
            let needImage = tracker.detectionDue(at: t)
            let ycc: YCCImage? = needImage ? AppPath.ycc(img, factor: factor) : nil
            let colorFrame = ycc?.colorFrame ?? ColorFrame(gray: Plane(width: 2, height: 2))
            var d: (DepthMap, CameraIntrinsics)? = nil
            if tracker.state == .locked { d = depth }
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
            if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab {
                let q = s.topCorners.compactMap { full.project(world: $0) }
                if q.count == 4 {
                    let up = s.topCorners.compactMap { full.project(world: $0 + Vec3(0, 1.2, 0)) }
                    let pts = q + up, side = ShapeCheck.meanSide(q)
                    let x0 = Int(pts.map { $0.x }.min()! - side), x1 = Int(pts.map { $0.x }.max()! + side)
                    let y0 = Int(pts.map { $0.y }.min()! - side), y1 = Int(pts.map { $0.y }.max()! + side)
                    let cx0 = max(0, x0), cy0 = max(0, y0)
                    let cw = min(full.intrinsics.width, x1) - cx0, chh = min(full.intrinsics.height, y1) - cy0
                    if cw > 32, chh > 32 {
                        let k = max(1, Int(ceil(Double(max(cw, chh)) / 900)))
                        if let p = AppPath.lumaCrop(img, x0: cx0, y0: cy0, width: cw, height: chh, factor: k) {
                            ballImage = p
                            ballK = full.intrinsics.cropped(x0: Double(cx0), y0: Double(cy0), scale: 1 / Double(k), width: p.width, height: p.height)
                        }
                    }
                }
            }
            return TrackerFrame(timestamp: t, view: pview, frame: colorFrame, depth: d?.0, depthIntrinsics: d?.1, ballImage: ballImage,
                                ballIntrinsics: ballK, tap: nil, floorY: nil, trackingNormal: normal)
        }
    }

    final class NullBall: BallLocating {
        func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? { nil }
        func reset() {}
    }

    /// A 1440x1080 video frame (the app's 1920x1440 camera image scaled down): the pipeline hands the tracker exactly what
    /// the app's path would, frame after frame, through searching, confirming and locked (image conversion only when a
    /// detection is due, the ball finder's crop while locked, depth while locked).
    func testPipelineEqualsTheAppPathOnASyntheticFrame() throws {
        let W = 1440, H = 1080
        let videoK = CameraIntrinsics(fx: 1130.5, fy: 1130.5, cx: 721.25, cy: 539.5, width: W, height: H)
        let slab = SyntheticScene.slabPose(tilt: 8, heading: 30)
        let pipeline = KitFramePipeline(videoWidth: W, videoHeight: H, cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60))
        XCTAssertEqual(pipeline.boxFactor, 3)
        XCTAssertEqual(pipeline.processingWidth, 480); XCTAssertEqual(pipeline.processingHeight, 360)
        // a depth map stored as BDP2, as the kit keeps it
        let dw = 64, dh = 48
        let dm = DepthMap(width: dw, height: dh, depth: (0..<(dw * dh)).map { Float(1 + $0 % 50) / 100 }, confidence: [UInt8](repeating: 2, count: dw * dh))
        let bdp2 = try KitDepth(data: try KitDepth(depthMap: dm).data)
        let appDepth = (bdp2.depthMap, videoK.scaled(by: Double(dw) / Double(W)))

        let detA = TrueOutlineDetector(slab: slab), detB = TrueOutlineDetector(slab: slab)
        let app = SlabTracker(settings: RecordingSettings().trackerSettings, detector: detA, ballLocator: NullBall())
        let kit = SlabTracker(settings: RecordingSettings().trackerSettings, detector: detB, ballLocator: NullBall())
        var converted = 0, crops = 0, depths = 0
        for i in 0..<24 {
            let t = 100 + Double(i) / 30
            let view = SyntheticScene.camera(at: slab.center + Vec3(0.3 + 0.01 * Double(i), 0.65, 0.6), lookingAt: slab.center, intrinsics: videoK)
            let arkit = RigidTransform(rotation: view.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: view.position)
            let f = KitFrame(index: i, time: t, pose: arkit.columnMajor4x4.map { Float($0) },
                             intrinsics: [videoK.fx, videoK.fy, videoK.cx, videoK.cy].map { Float($0) },
                             tracking: i == 5 ? .limitedExcessiveMotion : .normal, depthFile: KitDepth.fileName(frame: i))
            // the app sees ARKit's Float values too
            let full = try XCTUnwrap(f.view(videoWidth: W, videoHeight: H))
            let img = KitFramePipelineTests.texturedFrame(width: W, height: H, seed: i)
            let expected = AppPath.trackerFrame(full: full, img: img, t: t, normal: f.tracking.isNormal, tracker: app, depth: appDepth)
            let got = try XCTUnwrap(pipeline.frame(image: img, kitFrame: f, tracker: kit, depth: { KitFramePipeline.depth(bdp2, video: full.intrinsics) }))
            XCTAssertEqual(got.tracker.timestamp, expected.timestamp)
            XCTAssertEqual(got.tracker.view, expected.view, "frame \(i)")
            XCTAssertEqual(got.tracker.frame, expected.frame, "frame \(i): the processing image")
            XCTAssertEqual(got.tracker.ballImage, expected.ballImage, "frame \(i): the ball finder's image")
            XCTAssertEqual(got.tracker.ballIntrinsics, expected.ballIntrinsics, "frame \(i)")
            XCTAssertEqual(got.tracker.depth, expected.depth, "frame \(i): depth")
            XCTAssertEqual(got.tracker.depthIntrinsics, expected.depthIntrinsics, "frame \(i)")
            XCTAssertEqual(got.tracker.trackingNormal, expected.trackingNormal)
            XCTAssertNil(got.tracker.floorY)
            XCTAssertNil(got.tracker.tap)
            if got.converted { converted += 1 }
            if got.tracker.ballImage != nil { crops += 1; XCTAssertNotNil(got.ballCrop) }
            if got.tracker.depth != nil { depths += 1 }
            detA.view = expected.view; detB.view = got.tracker.view
            let oa = app.process(expected), ob = kit.process(got.tracker)
            XCTAssertEqual(oa.state, ob.state, "frame \(i)")
            XCTAssertEqual(oa.readouts?.tiltDegrees, ob.readouts?.tiltDegrees)
        }
        XCTAssertEqual(kit.state, .locked)
        XCTAssertGreaterThan(converted, 3)
        XCTAssertLessThan(converted, 24, "not every frame is converted")
        XCTAssertGreaterThan(crops, 2, "the ball finder's crops were made while locked")
        XCTAssertGreaterThan(depths, 2)
        XCTAssertEqual(Units.degrees(kit.slab!.tilt(down: ARKitConvention.worldDown)), 8, accuracy: 0.01)
    }

    /// A 1280x960 video is resized (area average) to 480x360, with the intrinsics scaled per axis.
    func testNonIntegerVideoSizeIsResized() throws {
        let p = KitFramePipeline(videoWidth: 1280, videoHeight: 960, cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60))
        XCTAssertNil(p.boxFactor)
        XCTAssertEqual(p.processingWidth, 480); XCTAssertEqual(p.processingHeight, 360)
        let K = p.processingIntrinsics(CameraIntrinsics(fx: 1000, fy: 1000, cx: 640, cy: 480, width: 1280, height: 960))
        XCTAssertEqual(K, CameraIntrinsics(fx: 375, fy: 375, cx: 240, cy: 180, width: 480, height: 360))
        let img = KitFramePipelineTests.texturedFrame(width: 1280, height: 960)
        let out = p.processingImage(img)
        XCTAssertEqual(out.width, 480); XCTAssertEqual(out.height, 360)
        XCTAssertEqual(out.cb.count, 240 * 180)
        let mean = { (b: [UInt8]) -> Double in Double(b.reduce(0) { $0 + Int($1) }) / Double(b.count) }
        XCTAssertEqual(mean(out.y), mean(img.y), accuracy: 1.0, "area averaging keeps the mean")
        XCTAssertEqual(mean(out.cb), mean(img.cb), accuracy: 1.0)
        // a uniform image stays uniform
        let flat = YCCImage(width: 1280, height: 960, y: [UInt8](repeating: 77, count: 1280 * 960),
                            cb: [UInt8](repeating: 140, count: 640 * 480), cr: [UInt8](repeating: 110, count: 640 * 480))
        let fo = p.processingImage(flat)
        XCTAssertTrue(fo.y.allSatisfy { $0 == 77 }); XCTAssertTrue(fo.cb.allSatisfy { $0 == 140 }); XCTAssertTrue(fo.cr.allSatisfy { $0 == 110 })
    }

    /// Without the camera format: 480 px wide at the video's aspect; a video smaller than that is used as it is.
    func testProcessingSizes() {
        let a = KitFramePipeline(videoWidth: 1440, videoHeight: 1080)
        XCTAssertEqual(a.processingWidth, 480); XCTAssertEqual(a.processingHeight, 360); XCTAssertEqual(a.boxFactor, 3)
        let b = KitFramePipeline(videoWidth: 320, videoHeight: 240, cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60))
        XCTAssertEqual(b.processingWidth, 320); XCTAssertEqual(b.processingHeight, 240); XCTAssertEqual(b.boxFactor, 1)
        let c = KitFramePipeline(videoWidth: 480, videoHeight: 360, cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60))
        XCTAssertEqual(c.boxFactor, 1)
        let img = KitFramePipelineTests.texturedFrame(width: 480, height: 360)
        XCTAssertEqual(c.processingImage(img), img)
        // a frame without a usable pose is not processed
        let f = KitFrame(index: 0, time: 0, pose: [Float](repeating: .nan, count: 16), intrinsics: [400, 400, 240, 180])
        XCTAssertNil(c.frame(image: img, kitFrame: f, tracker: SlabTracker(detector: NullSlabDetector())))
    }
}
