import XCTest
@testable import BounceCore

/// The capture kit scorer cuts the slab's full-resolution crop from the decoded video the way the phone cuts it from the
/// camera image: the same rectangle, shrink factor and intrinsics (planned on the camera format the phone had), its
/// pixels from the video.
final class KitSlabCropTests: XCTestCase {
    let W = 1440, H = 1080
    var s: Double { 1920.0 / Double(W) }
    var videoK: CameraIntrinsics { CameraIntrinsics(fx: 1130.5, fy: 1130.5, cx: 721.25, cy: 539.5, width: W, height: H) }
    var phoneK: CameraIntrinsics {
        CameraIntrinsics(fx: videoK.fx * s, fy: videoK.fy * s, cx: videoK.cx * s, cy: videoK.cy * s, width: 1920, height: 1440)
    }
    var pipeline: KitFramePipeline { KitFramePipeline(videoWidth: W, videoHeight: H, cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60)) }

    /// a textured image: luma varies smoothly and with fine detail
    func image() -> YCCImage {
        var y = [UInt8](repeating: 0, count: W * H)
        for j in 0..<H { for x in 0..<W { y[j * W + x] = UInt8(40 + (x * 3 + j * 5) % 150 + (x / 7 + j / 11) % 30) } }
        return YCCImage(width: W, height: H, y: y, cb: [UInt8](repeating: 128, count: (W / 2) * (H / 2)), cr: [UInt8](repeating: 128, count: (W / 2) * (H / 2)))
    }

    func testTheSlabCropHasThePhonesGeometry() throws {
        let slab = SyntheticScene.slabPose(tilt: 8, heading: 30)
        let img = image(), luma = Plane(bytes: img.y, width: W, height: H)
        var factors: Set<Int> = []
        for (i, d) in [1.5, 0.42].enumerated() {
            let video = SyntheticScene.camera(at: slab.center + Vec3(0.3, 0.65, 0.6) * d, lookingAt: slab.center, intrinsics: videoK)
            let pview = CameraView(worldFromCamera: video.worldFromCamera, intrinsics: pipeline.processingIntrinsics(videoK))
            XCTAssertEqual(pview.intrinsics.width, 480)
            let q = slab.topCorners.map { pview.project(world: $0)! }
            let expected = try XCTUnwrap(SlabImageCrop.plan(outline: q, processing: pview.intrinsics, full: phoneK), "case \(i)")
            let got = try XCTUnwrap(pipeline.slabDetail(img, outline: q, processing: pview, video: video), "case \(i)")
            XCTAssertEqual(got.crop, expected, "case \(i): the phone's rectangle and factor")
            XCTAssertEqual(got.intrinsics, expected.intrinsics(full: phoneK), "case \(i): the phone's crop intrinsics")
            XCTAssertEqual(got.luma.width, expected.imageWidth); XCTAssertEqual(got.luma.height, expected.imageHeight)
            factors.insert(expected.factor)
            // the pixels: where a crop pixel covers less than a video pixel, the video sampled at its centre (bilinear);
            // where it covers more, the video's mean over its patch
            let k = Double(expected.factor), step = k / s
            for (px, py) in [(3, 4), (got.luma.width / 2, got.luma.height / 3), (got.luma.width - 4, got.luma.height - 5)] {
                let cx = (Double(expected.x0) + (Double(px) + 0.5) * k) / s, cy = (Double(expected.y0) + (Double(py) + 0.5) * k) / s
                if step < 1 {
                    XCTAssertEqual(Double(got.luma[px, py]), Double(luma.sample(cx, cy)), accuracy: 1e-3, "case \(i) pixel (\(px), \(py))")
                } else {
                    let ax = Double(expected.x0) / s + Double(px) * step, ay = Double(expected.y0) / s + Double(py) * step
                    var sum = 0.0
                    for a in 0..<40 { for b in 0..<40 {
                        let x = Int(ax + (Double(a) + 0.5) * step / 40), yy = Int(ay + (Double(b) + 0.5) * step / 40)
                        sum += Double(img.y[yy * W + x])
                    } }
                    XCTAssertEqual(Double(got.luma[px, py]), sum / 1600, accuracy: 0.6, "case \(i) pixel (\(px), \(py))")
                }
            }
        }
        XCTAssertTrue(factors.contains(1) && factors.contains { $0 >= 2 }, "both kinds of crop: \(factors)")

        // a video at the camera's own size: the app's block average exactly
        let same = KitFramePipeline(videoWidth: W, videoHeight: H)
        let video = SyntheticScene.camera(at: slab.center + Vec3(0.3, 0.65, 0.6), lookingAt: slab.center, intrinsics: videoK)
        let pview = CameraView(worldFromCamera: video.worldFromCamera, intrinsics: same.processingIntrinsics(videoK))
        let q = slab.topCorners.map { pview.project(world: $0)! }
        let got = try XCTUnwrap(same.slabDetail(img, outline: q, processing: pview, video: video))
        let c = try XCTUnwrap(SlabImageCrop.plan(outline: q, processing: pview.intrinsics, full: videoK))
        XCTAssertEqual(got.crop, c)
        XCTAssertEqual(got.luma, KitFramePipelineTests.AppPath.lumaCrop(img, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor))
    }

    /// The scorer's frames carry the provider: a search's find is refined on the crop the phone would have cut.
    func testTheScorersTrackerGetsTheCrop() throws {
        let slab = SyntheticScene.slabPose(tilt: 8, heading: 30)
        let det = TrueOutlineDetector(slab: slab)
        let tracker = SlabTracker(settings: RecordingSettings().trackerSettings, detector: det)
        let video = SyntheticScene.camera(at: slab.center + Vec3(0.3, 0.65, 0.6), lookingAt: slab.center, intrinsics: videoK)
        let arkit = RigidTransform(rotation: video.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: video.position)
        let f = KitFrame(index: 0, time: 5, pose: arkit.columnMajor4x4.map { Float($0) },
                         intrinsics: [videoK.fx, videoK.fy, videoK.cx, videoK.cy].map { Float($0) }, tracking: .normal, depthFile: nil)
        let pf = try XCTUnwrap(pipeline.frame(image: image(), kitFrame: f, tracker: tracker))
        XCTAssertNotNil(pf.tracker.slabDetail)
        det.view = pf.tracker.view
        let out = tracker.process(pf.tracker)
        let d = try XCTUnwrap(out.slabDetail)
        let found = try XCTUnwrap(out.detections?.first?.quad)
        let phone = pipeline.cameraView(try XCTUnwrap(f.view(videoWidth: W, videoHeight: H))).intrinsics
        XCTAssertEqual(d.crop, SlabImageCrop.plan(outline: found, processing: pf.tracker.view.intrinsics, full: phone))
        XCTAssertNotNil(out.refinedDetections)
        // no image (the video frame could not be read): no crop either
        let none = try XCTUnwrap(pipeline.frame(image: nil, kitFrame: f, tracker: tracker))
        XCTAssertNil(none.tracker.slabDetail)
    }
}
