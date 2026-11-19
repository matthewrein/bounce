import Foundation

/// The JSON behind the app's "Copy diagnostics" button. Everything is plain numbers and strings so it can be pasted into
/// a message and read back later. `frames` (written into the JSON too) says which coordinate frame and units each field
/// uses: world coordinates are ARKit's gravity-aligned world (metres, y up); pixels are the full camera image's (`lens`),
/// the tracker's processing frame's (`processing`) or the ball crop's (`ballCrop`), as each field says.
public struct DiagnosticsReport: Codable, Equatable {
    public struct Pose: Codable, Equatable {
        public var center: [Double]
        public var normal: [Double]
        public var halfSides: [Double]
        public init(_ p: SlabPose) {
            center = p.center.array.map(DiagnosticsReport.r4); normal = p.normal.array.map(DiagnosticsReport.r4)
            halfSides = [DiagnosticsReport.r4(p.halfU), DiagnosticsReport.r4(p.halfV)]
        }
    }
    public struct Lens: Codable, Equatable {
        public var fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int, verticalFovDegrees: Double
        public init(_ k: CameraIntrinsics) {
            fx = DiagnosticsReport.r2(k.fx); fy = DiagnosticsReport.r2(k.fy); cx = DiagnosticsReport.r2(k.cx); cy = DiagnosticsReport.r2(k.cy)
            width = k.width; height = k.height; verticalFovDegrees = DiagnosticsReport.r2(k.verticalFovDegrees)
        }
    }
    /// The tracker's processing frame: the full camera image (`lens`) shrunk by `factor`, `width` x `height` pixels.
    public struct Processing: Codable, Equatable {
        public var width: Int, height: Int, factor: Double
        public init(width: Int, height: Int, factor: Double) { self.width = width; self.height = height; self.factor = factor }
    }
    /// Where the camera was on the last processed frame, relative to the slab.
    public struct Camera: Codable, Equatable {
        /// position and viewing direction (world: metres; unit vector)
        public var position: [Double]
        public var forward: [Double]
        /// gravity's direction in the processing image (unit 2-D vector, pixels' axes): (0, 1) straight down the
        /// image; (1, 0) along +x, as ARKit's landscape image is when the phone is held upright in portrait
        public var downInImage: [Double]
        /// distance from the camera to the lock's centre (m), and the angle (degrees) between the line of sight and the
        /// slab's normal (0: looking straight down onto the top; the tilt is hard to see below about 15)
        public var distanceToSlab: Double?
        public var viewAngleDegrees: Double?
        public init(view: CameraView, slab: SlabPose?) {
            position = view.position.array.map(DiagnosticsReport.r4)
            let fwd = view.worldFromCamera.applyDirection(Vec3(0, 0, 1)).normalized
            forward = fwd.array.map(DiagnosticsReport.r4)
            let d = view.directionToCamera(ARKitConvention.worldDown), d2 = Vec2(d.x, d.y).normalized
            downInImage = [DiagnosticsReport.r4(d2.x), DiagnosticsReport.r4(d2.y)]
            if let s = slab {
                let los = s.center - view.position
                distanceToSlab = DiagnosticsReport.r4(los.length)
                viewAngleDegrees = DiagnosticsReport.r2(Units.degrees((-los.normalized).angle(to: s.normal)))
            }
        }
    }
    /// The camera's video format (ARKit's `videoFormat`): its image size and frame rate.
    public struct VideoFormat: Codable, Equatable {
        public var width: Int, height: Int, framesPerSecond: Int
        public init(width: Int, height: Int, framesPerSecond: Int) { self.width = width; self.height = height; self.framesPerSecond = framesPerSecond }
    }

    public struct Depth: Codable, Equatable {
        public var points: Int, rms: Double, angleToImageDegrees: Double, centreOffsetMm: Double, tiltDegrees: Double
        /// share of the depth points inside the top that lie on its plane
        public var inlierFraction: Double?
        public init(_ d: DepthCheck) {
            points = d.points; rms = DiagnosticsReport.r4(d.rms); angleToImageDegrees = DiagnosticsReport.r2(d.angleToImageDegrees)
            centreOffsetMm = DiagnosticsReport.r2(d.centreOffset * 1000); tiltDegrees = DiagnosticsReport.r2(d.tiltDegrees)
            inlierFraction = d.inlierFraction.map(DiagnosticsReport.r2)
        }
    }

    public var build: String
    public var device: String
    public var system: String
    public var time: String
    public var settings: RecordingSettings
    public var state: String
    public var tracking: String
    public var fps: Double
    public var msProcess: Double
    public var lens: Lens?
    public var depthSupported: Bool
    public var depth: Depth?
    public var captureLocked: Bool
    public var slab: Pose?
    public var tiltDegrees: Double?
    public var outline: [[Double]]?
    public var sideModes: [String]
    public var ball: [Double]?
    public var readouts: Readouts?
    public var counts: [String: Int]
    public var recentEvents: [String]
    public var recording: String?
    /// the values behind the rejection counters (e.g. "misfit": fractions of the side, "tooTilted": degrees), per kind:
    /// count, smallest, largest and last, rounded (SlabTracker.rejectionValues)
    public var rejectionValues: [String: ValueSummary]?
    /// the slab detector's corner noise (pixels of the processing frame) as the tracker measured it
    /// (SlabTracker.cornerNoiseEstimate), and how well the lock pins the normal (degrees, TrackerOutput.lockSigmaDegrees)
    public var cornerNoisePixels: Double?
    public var lockSigmaDegrees: Double?

    // Added for reading a bad session (all optional, so older reports still decode).
    /// which frame and units each field uses
    public var frames: [String: String]?
    /// the processing frame (see `Processing`)
    public var processing: Processing?
    /// the camera on the last frame, relative to the lock
    public var camera: Camera?
    /// the lock from the image alone (world), beside `slab` (which has LiDAR folded in when `depthFused`)
    public var imageSlab: Pose?
    public var depthFused: Bool?
    /// the last detections (`SlabTracker.detectionLog`, rounded): world poses, processing pixels
    public var history: [DetectionRecord]?
    /// where the ball finder's image was cut from (full camera image pixels and shrink factor); `ball`'s circle is in its
    /// pixels. `ballFull`: that circle (x, y, radius) in the full camera image's pixels.
    public var ballCrop: BallImageCrop?
    public var ballFull: [Double]?
    /// the tracker's settings, exactly (launch rule, intervals, gates ...)
    public var tracker: TrackerSettings?
    /// the floor under the slab (world y, m) as ARKit's planes give it, and how far below the lock's centre it is (m)
    public var floorY: Double?
    public var floorBelowSlab: Double?
    public var videoFormat: VideoFormat?
    /// ProcessInfo's thermal state: nominal, fair, serious, critical
    public var thermalState: String?
    /// the last processed frame's timestamp (s, the camera's clock: the same as `recentEvents` and recordings)
    public var frameTime: Double?
    /// how the camera's frames came and went: delivered, processed, skipped as late, missed by the camera, delivery
    /// latency, processing time, detector runs per second (`FramePacer.report`)
    public var framePacing: FramePacingReport?
    /// how the last capture lock (focus, exposure, white balance) came about: settled, or at the timeout with what was
    /// still adjusting (`CaptureLockGate`)
    public var captureLockSettle: CaptureLockGate.Lock?
    /// the last full-resolution crop the slab's edge steps read (full camera image pixels and shrink factor)
    public var slabCrop: SlabImageCrop?
    /// video format changes seen (`VideoFormatWatch`), and the last one
    public var videoFormatChanges: Int?
    public var videoFormatChange: VideoFormatWatch.Change?
    /// LiDAR's checks of the lock's top since the tracker was made (`SlabTracker.depthChecks`): used, rejected per
    /// reason, and running summaries of the centre's offset from LiDAR's plane less the dish's (mm), the plane's angle to
    /// the image normal (deg) and LiDAR's range over the picture's (k); nil before the first check
    public var depthChecks: DepthCheckSummary?

    /// The frame and units of every field, as written into `frames`.
    public static let fieldFrames: [String: String] = [
        "world": "ARKit's gravity-aligned world: metres, y up (it can shift on relocalisation)",
        "lens": "the full camera image (ARKit's captured image, sensor landscape orientation): pixels",
        "processing": "the tracker's image: the full camera image shrunk by factor; outline, history and depth pixels are its",
        "slab": "world: centre (m), unit normal out of the top, half side lengths (m); LiDAR folded in when depthFused",
        "imageSlab": "world: the lock from the image alone",
        "tiltDegrees": "the lock's tilt from level (degrees)",
        "outline": "processing pixels: the lock's top corners projected, pose order",
        "sideModes": "the last detection's edge modes per side, pose order (side i from outline corner i to i+1)",
        "ball": "world centre x, y, z (m), then the circle x, y, radius in the ball crop's pixels (ballCrop)",
        "ballCrop": "full camera image pixels: x0, y0, width, height; the crop is shrunk by factor",
        "ballFull": "the ball's circle x, y, radius in full camera image pixels",
        "camera": "world position (m) and viewing direction; distance to the lock (m); angle of the line of sight from the slab normal (deg); gravity in the processing image",
        "depth": "LiDAR plane: points, rms (m), tilt from level and angle to the image normal (deg), lock centre above it (mm), inlier share",
        "history": "per detection: time (camera clock, s), state, outlines found and rejected, outcome counters, chosen pose centre and normal (world), tilt and sigma (deg), fit rms (px), distance (m), sides (processing px, pose order), aspect",
        "readouts": "tilt (deg), apex height, landing distance, drop height (m), air time (s)",
        "recentEvents": "prefixed with the camera clock (s), as frameTime and recordings",
        "floorY": "world y of the floor (m); floorBelowSlab: the lock's centre above it (m)",
        "lockSigmaDegrees": "how well the lock pins the normal (deg, 1 sigma); cornerNoisePixels: the detector's corner noise (processing px)",
        "framePacing": "camera clock: frames received / processed / dropped busy (replaced in the hand-off while processing was busy) / skipped late (the demo: waited behind processing) / late but idle (ARKit's own delay) / missed by the camera; the most frames the app held (maxFramesHeld, at most 2) and the processed frames' wait in the hand-off; pauses (s); latencies and processing times in ms (p50, p95, max), processing also by what ran; detector runs per second; recent window and total",
        "captureLockSettle": "camera clock (s): when the capture lock was armed and taken, how long it waited, whether it timed out and what was still adjusting",
        "slabCrop": "full camera image pixels: x0, y0, width, height; the crop is shrunk by factor",
        "depthChecks": "LiDAR's checks of the lock's top while locked: checks, used, rejected per reason (points, angle, inliers, offset); offsetMm: the lock's centre above LiDAR's plane less the dish's offset (mm); angleDegrees: LiDAR's plane to the image normal (deg); rangeRatio: LiDAR's range to the corner plane over the picture's along the line of sight (k); each count, min, max, median of the latest 101, last",
        "videoFormatChange": "the last video format change (full image size, nominal fps), the camera clock of the frame it was noted on, and what showed it (basis: size, frame-steps, time)",
    ]

    public init(build: String, device: String, system: String, time: String, settings: RecordingSettings, state: String, tracking: String,
                fps: Double, msProcess: Double, lens: CameraIntrinsics?, depthSupported: Bool, depth: DepthCheck?, captureLocked: Bool,
                slab: SlabPose?, outline: [Vec2]?, sideModes: [String], ball: (center: Vec3, circle: Vec2, radius: Double)?, readouts: Readouts?,
                counts: [String: Int], recentEvents: [String], recording: String?, rejectionValues: [String: ValueSummary]? = nil,
                cornerNoisePixels: Double? = nil, lockSigmaDegrees: Double? = nil) {
        self.build = build; self.device = device; self.system = system; self.time = time; self.settings = settings
        self.state = state; self.tracking = tracking; self.fps = DiagnosticsReport.r2(fps); self.msProcess = DiagnosticsReport.r2(msProcess)
        self.lens = lens.map(Lens.init); self.depthSupported = depthSupported; self.depth = depth.map(Depth.init); self.captureLocked = captureLocked
        self.slab = slab.map(Pose.init)
        self.tiltDegrees = slab.map { DiagnosticsReport.r2(Units.degrees($0.tilt(down: ARKitConvention.worldDown))) }
        self.outline = outline?.map { [DiagnosticsReport.r2($0.x), DiagnosticsReport.r2($0.y)] }
        self.sideModes = sideModes
        self.ball = ball.map { [DiagnosticsReport.r4($0.center.x), DiagnosticsReport.r4($0.center.y), DiagnosticsReport.r4($0.center.z),
                                DiagnosticsReport.r2($0.circle.x), DiagnosticsReport.r2($0.circle.y), DiagnosticsReport.r2($0.radius)] }
        self.readouts = readouts; self.counts = counts; self.recentEvents = recentEvents; self.recording = recording
        self.rejectionValues = rejectionValues?.mapValues { $0.rounded }
        self.cornerNoisePixels = cornerNoisePixels.map(DiagnosticsReport.r2); self.lockSigmaDegrees = lockSigmaDegrees.map(DiagnosticsReport.r2)
        self.frames = DiagnosticsReport.fieldFrames
    }

    /// Fill in what the tracker knows beyond its output: the image-only lock, the last detections, its exact settings,
    /// the camera relative to the lock, the processing frame's size (from `view`, the processing frame's camera, and
    /// `lens`, the full image's), the ball crop's frame and the floor.
    public mutating func addTracker(_ tracker: SlabTracker, view: CameraView?, lens: CameraIntrinsics? = nil, output: TrackerOutput? = nil,
                                    ballCrop: BallImageCrop? = nil, floorY: Double? = nil, slabCrop: SlabImageCrop? = nil) {
        self.slabCrop = slabCrop ?? output?.slabDetail?.crop
        imageSlab = tracker.imageSlab.map(Pose.init)
        depthFused = output?.depthFused
        history = tracker.detectionLog.suffix(15).map(DiagnosticsReport.rounded)
        self.tracker = tracker.settings
        depthChecks = tracker.depthChecks.checks > 0 ? tracker.depthChecks.rounded : nil
        if let v = view {
            camera = Camera(view: v, slab: tracker.slab)
            let full = lens ?? self.lens.map { CameraIntrinsics(fx: $0.fx, fy: $0.fy, cx: $0.cx, cy: $0.cy, width: $0.width, height: $0.height) }
            processing = Processing(width: v.intrinsics.width, height: v.intrinsics.height,
                                    factor: DiagnosticsReport.r4(full.map { Double($0.width) / Double(max(1, v.intrinsics.width)) } ?? 1))
        }
        if let c = ballCrop {
            self.ballCrop = c
            if let b = ball, b.count == 6 {
                let p = c.toFull(Vec2(b[3], b[4]))
                ballFull = [DiagnosticsReport.r2(p.x), DiagnosticsReport.r2(p.y), DiagnosticsReport.r2(b[5] * Double(c.factor))]
            }
        }
        self.floorY = floorY.map(DiagnosticsReport.r4)
        if let y = floorY, let s = tracker.slab { floorBelowSlab = DiagnosticsReport.r4(s.center.y - y) }
    }

    static func rounded(_ r: DetectionRecord) -> DetectionRecord {
        var o = r
        o.time = r4(r.time)
        o.center = r.center?.map(r4); o.normal = r.normal?.map(r4)
        o.tiltDegrees = r.tiltDegrees.map(r2); o.sigmaDegrees = r.sigmaDegrees.map(r2); o.rmsPixels = r.rmsPixels.map(r2)
        o.distance = r.distance.map(r4); o.sidesPixels = r.sidesPixels?.map(r2); o.aspect = r.aspect.map(r4)
        return o
    }

    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

    /// Read a report back (non-finite numbers are written as "inf", "-inf" and "nan").
    public static func decode(json: String) throws -> DiagnosticsReport {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(DiagnosticsReport.self, from: Data(json.utf8))
    }

    public func json(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        // Readouts may hold non-finite values if something degenerate slipped through; encode them as strings
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
