import Foundation

extension KitFramePipeline {
    /// The slab's full-resolution crop around an outline (pixels of the processing frame `processing`), as the app cuts
    /// it from the camera image (`SlabImageCrop.provider` with `FrameConversion.lumaCrop`): planned on the camera image
    /// the phone had (`cameraView`), so its rectangle, shrink factor and intrinsics are the phone's. Its pixels come from
    /// the video: with the video at the camera's own size, the app's integer block average exactly; else area averages of
    /// the video over the same patches of the scene (`areaAverage`) where a crop pixel covers at least a video pixel, and
    /// bilinear samples of the video where it covers less (the kit's video is smaller than the camera image, so a
    /// factor-1 crop asks for finer pixels than the video has: an area average would only repeat each video pixel in
    /// blocks, which puts stair steps into the edge profiles). nil when the outline does not give a usable crop.
    public func slabDetail(_ img: YCCImage, outline: [Vec2], processing: CameraView, video: CameraView) -> SlabDetail? {
        let cam = cameraView(video)
        guard let c = SlabImageCrop.plan(outline: outline, processing: processing.intrinsics, full: cam.intrinsics) else { return nil }
        let K = c.intrinsics(full: cam.intrinsics)
        let p: Plane
        if cam.intrinsics.width == videoWidth && cam.intrinsics.height == videoHeight {
            guard let q = KitFramePipeline.lumaCrop(img, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor) else { return nil }
            p = q
        } else {
            // camera pixel x is video pixel x / s
            let s = Double(cameraWidth) / Double(videoWidth), step = Double(c.factor) / s
            if step >= 1 {
                guard let q = KitFramePipeline.areaAverage(img, x0: Double(c.x0) / s, y0: Double(c.y0) / s, step: step,
                                                           width: c.imageWidth, height: c.imageHeight) else { return nil }
                p = q
            } else {
                p = Plane(bytes: img.y, width: img.width, height: img.height).resampled(from: video.intrinsics, to: K)
            }
        }
        guard p.width == c.imageWidth, p.height == c.imageHeight else { return nil }
        return SlabDetail(crop: c, luma: p, intrinsics: K)
    }
}
