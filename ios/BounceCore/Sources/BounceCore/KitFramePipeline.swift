import Foundation

/// A capture kit's video frame turned into the `TrackerFrame` the app would have built for it (ARController.handle),
/// so the scorer runs the app's own per-frame path on a kit's clips.
///
/// Per frame, as the app does it:
///   - the processing frame (about 480 px wide, what the slab finder sees) is the image shrunk by an integer factor with
///     a box filter, luma and chroma (`YCCImage.fromBiplanar`, the app's `FrameConversion.ycc`), converted only when the
///     tracker will run its detector on this frame (`SlabTracker.detectionDue`); other frames get the app's 2x2 blank;
///   - its camera is the frame's ARKit pose in BounceCore's CV axes (`ARKitConvention`) with the video intrinsics scaled
///     to the processing frame;
///   - while the slab is locked and the ball finder is due (`SlabTracker.ballDue`), the ball finder's image is a crop of
///     the full-resolution luma around the lock and the space above it (`BallImageCrop.plan`), shrunk by the app's
///     integer block average (`FrameConversion.lumaCrop`), with the crop's intrinsics;
///   - while locked, LiDAR depth when the frame has it (BDP2 read as a `DepthMap`, metres) with the video intrinsics
///     scaled by depth width / video width;
///   - `trackingNormal` from the frame's ARKit tracking state ("normal").
///
/// How this differs from the phone, so a score is read for what it is:
///   - **Compression.** The kit's frames went through the video encoder (HEVC at about 3-5 Mbit/s, or H.264): blocking,
///     ringing and smoothed fine texture that the phone's camera buffer did not have, and chroma subsampled again.
///   - **Resolution.** The app shrinks the full camera image (usually 1920x1440, shrunk by 4); the kit's video is the
///     camera image scaled down first (1280x960 or 1440x1080). From 1440x1080 the processing frame is the same 480x360
///     by an integer box factor (3); from 1280x960 the factor is not an integer and the frame is resized by area
///     averaging (`Plane.resized`, closest to the app's box filter; a bilinear `Plane.resampled` would alias at a 2.67x
///     shrink), with the intrinsics scaled per axis. A video smaller than the app's processing frame is used at its own
///     size. The ball finder's crop is cut from the video (a third or a quarter fewer pixels across the ball than the
///     phone's 1920 px image), with the same `maxSide`, so its image can be smaller than the phone's.
///   - **Frames.** Ordinary shots keep every other ARKit frame (30 fps), drops every frame (60 fps), while the app
///     processes every frame at 60 fps: the tracker's search, confirm and re-check moments fall on other frames.
///   - **Depth.** The kit keeps LiDAR depth on about one frame a second (millimetres), the app reads it on every locked
///     frame.
///   - **Floor.** The app gives the tracker ARKit's floor plane under the slab (`floorY`); the kit does not record plane
///     anchors, so it is nil here: the app's bounce path then ends at the slab's lowest corner instead of the floor (this
///     changes the readouts' landing distance and air time, not the slab or the ball).
///   - **Inputs.** No taps, resets or settings changes happen in a kit shot; each shot starts a new tracker.
public struct KitFramePipeline {
    /// the video frame's size (pixels): what frames.jsonl's `K` describes
    public let videoWidth: Int
    public let videoHeight: Int
    /// the processing frame the detectors run on
    public let processingWidth: Int
    public let processingHeight: Int
    /// the integer box factor from the video to the processing frame, as the app shrinks its camera image; nil when the
    /// sizes do not allow one (then the frame is resized by area averaging)
    public let boxFactor: Int?
    /// the ball finder's crop: how far above the slab it reaches (m) and its largest side before shrinking (pixels), as
    /// in the app
    public var ballReach = 1.2
    public var ballMaxSide = 900

    /// `cameraFormat`: the full camera image the app processed (shot.json); the processing frame is that image shrunk by
    /// the app's factor (`max(1, width / 480)`). Without it, 480 px wide at the video's aspect.
    public init(videoWidth: Int, videoHeight: Int, cameraFormat: KitCameraFormat? = nil) {
        precondition(videoWidth > 0 && videoHeight > 0)
        self.videoWidth = videoWidth; self.videoHeight = videoHeight
        var pw: Int, ph: Int
        if let c = cameraFormat, c.width > 0, c.height > 0 {
            let k = max(1, c.width / 480)
            pw = c.width / k; ph = c.height / k
        } else {
            pw = 480; ph = max(1, Int((480 * Double(videoHeight) / Double(videoWidth)).rounded()))
        }
        if pw > videoWidth || ph > videoHeight { pw = videoWidth; ph = videoHeight }
        processingWidth = pw; processingHeight = ph
        let kx = videoWidth / pw, ky = videoHeight / ph
        boxFactor = kx == ky && kx >= 1 && videoWidth / kx == pw && videoHeight / ky == ph ? kx : nil
    }

    /// The processing frame's intrinsics from the video frame's.
    public func processingIntrinsics(_ video: CameraIntrinsics) -> CameraIntrinsics {
        if let k = boxFactor {
            // as the app: the full image's intrinsics scaled by 1/factor, its size divided by the factor
            let K = video.scaled(by: 1 / Double(k))
            return CameraIntrinsics(fx: K.fx, fy: K.fy, cx: K.cx, cy: K.cy, width: video.width / k, height: video.height / k)
        }
        let sx = Double(processingWidth) / Double(video.width), sy = Double(processingHeight) / Double(video.height)
        return CameraIntrinsics(fx: video.fx * sx, fy: video.fy * sy, cx: video.cx * sx, cy: video.cy * sy,
                                width: processingWidth, height: processingHeight)
    }

    /// The frame's camera for the video image and for the processing frame (CV axes, ARKit's world); nil when the frame's
    /// pose or intrinsics are not usable.
    public func views(_ f: KitFrame) -> (video: CameraView, processing: CameraView)? {
        guard let v = f.view(videoWidth: videoWidth, videoHeight: videoHeight) else { return nil }
        return (v, CameraView(worldFromCamera: v.worldFromCamera, intrinsics: processingIntrinsics(v.intrinsics)))
    }

    /// The processing frame's image from a video frame (the app's `FrameConversion.ycc` on the camera buffer).
    public func processingImage(_ img: YCCImage) -> YCCImage {
        precondition(img.width == videoWidth && img.height == videoHeight, "the frame is not the video's size")
        if let k = boxFactor {
            if k == 1 { return img }
            // the camera buffer's two planes: luma, and Cb/Cr interleaved at half size
            let cw = img.chromaWidth, ch = img.chromaHeight
            var cbcr = [UInt8](repeating: 128, count: cw * ch * 2)
            for i in 0..<(cw * ch) { cbcr[2 * i] = img.cb[i]; cbcr[2 * i + 1] = img.cr[i] }
            return img.y.withUnsafeBufferPointer { yb in
                cbcr.withUnsafeBufferPointer { cb in
                    YCCImage.fromBiplanar(luma: yb, lumaWidth: img.width, lumaHeight: img.height, lumaBytesPerRow: img.width,
                                          cbcr: cb, cbcrBytesPerRow: cw * 2, factor: k)
                }
            }
        }
        let w = processingWidth, h = processingHeight, cw = (w + 1) / 2, ch = (h + 1) / 2
        let y = Plane(bytes: img.y, width: img.width, height: img.height).resized(width: w, height: h).bytes
        let cb = Plane(bytes: img.cb, width: img.chromaWidth, height: img.chromaHeight).resized(width: cw, height: ch).bytes
        let cr = Plane(bytes: img.cr, width: img.chromaWidth, height: img.chromaHeight).resized(width: cw, height: ch).bytes
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }

    /// The app's crop of the full-resolution luma (`FrameConversion.lumaCrop`): `k` x `k` block averages (integer sums
    /// times 1/k^2) of the image's pixels from (x0, y0); nil when it would be 8 pixels or less either way.
    public static func lumaCrop(_ img: YCCImage, x0: Int, y0: Int, width cw: Int, height chh: Int, factor k: Int) -> Plane? {
        let w = img.width, h = img.height
        let ax = max(0, min(w - 1, x0)), ay = max(0, min(h - 1, y0))
        let ow = min(cw, w - ax) / k, oh = min(chh, h - ay) / k
        guard ow > 8, oh > 8 else { return nil }
        var d = [Float](repeating: 0, count: ow * oh)
        let inv = 1 / Float(k * k)
        img.y.withUnsafeBufferPointer { src in
            for yy in 0..<oh {
                for xx in 0..<ow {
                    var s = 0
                    for dy in 0..<k { let r = (ay + yy * k + dy) * w + ax + xx * k; for dx in 0..<k { s += Int(src[r + dx]) } }
                    d[yy * ow + xx] = Float(s) * inv
                }
            }
        }
        return Plane(width: ow, height: oh, data: d)
    }

    /// The ball finder's image while the slab `slab` (world) is locked: the app's crop of the video frame's luma, its
    /// intrinsics, and where it was cut from. nil when the slab does not project or the crop is too small.
    public func ballImage(_ img: YCCImage, slab: SlabPose, video: CameraView) -> (image: Plane, intrinsics: CameraIntrinsics, crop: BallImageCrop)? {
        guard let c = BallImageCrop.plan(slab: slab, full: video, reach: ballReach, maxSide: ballMaxSide),
              let p = KitFramePipeline.lumaCrop(img, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor) else { return nil }
        let K = video.intrinsics.cropped(x0: Double(c.x0), y0: Double(c.y0), scale: 1 / Double(c.factor), width: p.width, height: p.height)
        return (p, K, c)
    }

    /// LiDAR depth from a BDP2 file, with its intrinsics (the video frame's, scaled by depth width / video width).
    public static func depth(_ d: KitDepth, video: CameraIntrinsics) -> (DepthMap, CameraIntrinsics) {
        (d.depthMap, d.intrinsics(video: video))
    }

    /// One frame through the pipeline.
    public struct Frame {
        /// what the tracker gets
        public var tracker: TrackerFrame
        /// the camera for the video image (CV axes)
        public var video: CameraView
        /// the detector runs on this frame (its image was converted)
        public var converted: Bool
        /// where the ball finder's image was cut from, if it got one
        public var ballCrop: BallImageCrop?
    }

    /// The `TrackerFrame` the app would build for this video frame, given the tracker it is about to be handed to (its
    /// state decides what is converted, as in the app). `image`: the decoded video frame (nil if it could not be read:
    /// the detector then gets the blank). `depth`: loads this frame's depth, called only while the slab is locked.
    /// nil when the frame's pose or intrinsics are not usable.
    public func frame(image: YCCImage?, kitFrame f: KitFrame, tracker: SlabTracker,
                      depth: () -> (DepthMap, CameraIntrinsics)? = { nil }) -> Frame? {
        guard let vs = views(f) else { return nil }
        let video = vs.video, pview = vs.processing, t = f.time
        // only convert the image when the detector will run on it
        let converted = image != nil && tracker.detectionDue(at: t)
        let colorFrame = converted ? processingImage(image!).colorFrame : KitFramePipeline.blank
        // LiDAR depth, when the slab is locked
        let d: (DepthMap, CameraIntrinsics)? = tracker.state == .locked ? depth() : nil
        // the ball finder's crop of the full-resolution image, when it is due
        var ballPlane: Plane? = nil, ballK: CameraIntrinsics? = nil, crop: BallImageCrop? = nil
        if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let img = image,
           let b = ballImage(img, slab: s, video: video) {
            ballPlane = b.image; ballK = b.intrinsics; crop = b.crop
        }
        let tf = TrackerFrame(timestamp: t, view: pview, frame: colorFrame, depth: d?.0, depthIntrinsics: d?.1,
                              ballImage: ballPlane, ballIntrinsics: ballK, tap: nil, floorY: nil, trackingNormal: f.tracking.isNormal)
        return Frame(tracker: tf, video: video, converted: converted, ballCrop: crop)
    }

    /// The app's stand-in for a frame it did not convert.
    public static let blank = ColorFrame(gray: Plane(width: 2, height: 2))
}

/// Where the scorer's video frames come from, one at a time in order: the video decoder (`KitVideoDecoder`, macOS and
/// Linux), or frames held in memory (a synthetic kit).
public protocol KitFrameSource: AnyObject {
    /// the frame's size (pixels)
    var width: Int { get }
    var height: Int { get }
    /// the next frame, nil after the last one
    func next() throws -> YCCImage?
    /// stop early (frees the decoder)
    func close()
}

/// Frames in memory, or made on demand.
public final class KitArrayFrameSource: KitFrameSource {
    public let width: Int
    public let height: Int
    private let count: Int
    private let make: (Int) -> YCCImage
    private var i = 0

    public init(width: Int, height: Int, frames: [YCCImage]) {
        self.width = width; self.height = height; count = frames.count; make = { frames[$0] }
    }

    /// `count` frames, frame `i` made by `make(i)` when it is read.
    public init(width: Int, height: Int, count: Int, make: @escaping (Int) -> YCCImage) {
        self.width = width; self.height = height; self.count = count; self.make = make
    }

    public func next() throws -> YCCImage? {
        guard i < count else { return nil }
        defer { i += 1 }
        return make(i)
    }

    public func close() { i = count }
}
