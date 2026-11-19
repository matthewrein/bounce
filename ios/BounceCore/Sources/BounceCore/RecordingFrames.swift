import Foundation

/// Where the ball finder's image comes from: the full camera image's pixels from (x0, y0), `width` x `height` of them,
/// shrunk by averaging `factor` x `factor` blocks. The app makes it around the slab and the space above it (`plan`).
public struct BallImageCrop: Codable, Equatable {
    /// the crop's rectangle in the full camera image (pixels of ARKit's captured image, sensor orientation)
    public var x0: Int
    public var y0: Int
    public var width: Int
    public var height: Int
    /// the shrink factor: the ball finder's image is width / factor x height / factor pixels
    public var factor: Int

    public init(x0: Int, y0: Int, width: Int, height: Int, factor: Int) {
        self.x0 = x0; self.y0 = y0; self.width = width; self.height = height; self.factor = factor
    }

    /// size of the ball finder's image (pixels)
    public var imageWidth: Int { width / factor }
    public var imageHeight: Int { height / factor }

    /// The intrinsics of the ball finder's image, given the full camera image's.
    public func intrinsics(full: CameraIntrinsics) -> CameraIntrinsics {
        full.cropped(x0: Double(x0), y0: Double(y0), scale: 1 / Double(factor), width: imageWidth, height: imageHeight)
    }

    /// A point in the ball finder's image -> the full camera image (pixels; continuous coordinates).
    public func toFull(_ p: Vec2) -> Vec2 { Vec2(Double(x0) + p.x * Double(factor), Double(y0) + p.y * Double(factor)) }

    /// The crop the app gives the ball finder: the slab's top corners and the part of each vertical line from a corner
    /// `reach` metres up (world up, so it works in any orientation of the phone) that is in view, grown by the slab's
    /// mean side in the image on every side, clamped to the image, and shrunk by the least whole factor that leaves it
    /// no more pixels than a square `maxSide` pixels a side (the finder's work goes with the pixels it searches; a bound
    /// on the longer side alone shrank a full-width 1920 x 1440 crop by 3 where 2 keeps fewer pixels than a 900 x 900
    /// crop, and the ball a third smaller). nil if the slab does not project or the crop would be under 33 pixels
    /// either way.
    /// In view: in front of the camera by at least `near` metres and inside the picture. `near` is the nearest a ball
    /// held over the slab comes to the phone (the phone in one hand, the ball in the other: 0.3 m). With the camera less
    /// than `reach` over the slab, the top of each line is behind the camera or out of the picture: the line is then
    /// taken up to where it leaves the picture. (Dropping the points behind the camera shrank the crop to the slab, and
    /// cut off a ball held over it, whenever all four were behind it; cutting each line only where it came within 2 cm
    /// of the camera's plane took ends far out of the picture to the side, and ran the crop to the image's full width
    /// without taking in any more of the space a held ball can be seen in.)
    /// - Parameters: slab: the lock (world); full: the camera for the full camera image (world-from-camera, CV axes).
    public static func plan(slab: SlabPose, full: CameraView, reach: Double = 1.2, maxSide: Int = 900, near: Double = 0.3) -> BallImageCrop? {
        let q = slab.topCorners.compactMap { full.project(world: $0) }
        guard q.count == 4 else { return nil }
        let K = full.intrinsics
        // the view as half-spaces n . P + c >= 0 in the camera's axes: in front of `near`, and inside the picture's
        // four edges
        let W = Double(K.width), H = Double(K.height)
        let planes: [(Vec3, Double)] = [(Vec3(0, 0, 1), -near), (Vec3(K.fx, 0, K.cx), 0), (Vec3(-K.fx, 0, W - K.cx), 0),
                                         (Vec3(0, K.fy, K.cy), 0), (Vec3(0, -K.fy, H - K.cy), 0)]
        var up: [Vec2] = []
        for P in slab.topCorners {
            let a = full.toCamera(P), d = full.toCamera(P + Vec3(0, reach, 0)) - a
            var t0 = 0.0, t1 = 1.0
            for (n, c) in planes {
                let fa = n.dot(a) + c, fd = n.dot(d)
                if abs(fd) < 1e-12 { if fa < 0 { t1 = -1 }; continue }
                let t = -fa / fd
                if fd > 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            }
            guard t0 <= t1 else { continue }
            for t in [t0, t1] { if let p = K.project(a + d * t) { up.append(p) } }
        }
        let pts = q + up, side = ShapeCheck.meanSide(q)
        // (bounded before the conversion: a point just in front of the camera's plane projects arbitrarily far out)
        func px(_ v: Double) -> Int { Int(min(1e7, max(-1e7, v))) }
        let x0 = px(pts.map { $0.x }.min()! - side), x1 = px(pts.map { $0.x }.max()! + side)
        let y0 = px(pts.map { $0.y }.min()! - side), y1 = px(pts.map { $0.y }.max()! + side)
        let cx0 = max(0, x0), cy0 = max(0, y0)
        let cw = min(full.intrinsics.width, x1) - cx0, ch = min(full.intrinsics.height, y1) - cy0
        guard cw > 32, ch > 32 else { return nil }
        let m = Double(max(1, maxSide))
        var k = max(1, Int(ceil((Double(cw) * Double(ch)).squareRoot() / m)))
        while (cw / k) * (ch / k) > Int(m * m) { k += 1 }
        return BallImageCrop(x0: cx0, y0: cy0, width: cw, height: ch, factor: k)
    }
}

/// The tracker's result on one frame, as a recording stores it (the phone's, to compare a replay with). World
/// coordinates are ARKit's gravity-aligned world (metres, y up); pixels are the processing frame's.
public struct RecordedOutput: Codable, Equatable {
    public var state: TrackerState
    /// `TrackerOutput.events` (nil: none)
    public var events: [String]?
    /// the lock (world), with LiDAR folded in when it was
    public var slab: SlabPose?
    /// the lock's top corners in this frame (processing pixels, pose order)
    public var outline: [[Double]]?
    public var readouts: Readouts?
    /// this frame's own detection, if the tracker used one (processing pixels, pose order)
    public var measurement: [[Double]]?
    /// the detector's raw outlines, if it ran on this frame (nil: it did not run)
    public var detections: [DetectedOutline]?
    /// the ball finder ran on this frame (then `ball` is its result)
    public var ballSearched: Bool?
    /// after this frame's scan the ball finder held something for its next scan to confirm (`TrackerOutput
    /// .ballAwaitsConfirmation`; nil: no, or a recording from before it, whose settings never read it)
    public var ballAwaitsConfirmation: Bool?
    /// the ball: world centre x, y, z (m), then its circle's x, y and radius in the ball finder's image (pixels)
    public var ball: [Double]?
    public var depthFused: Bool?
    public var lockUnconfirmed: Bool?
    /// where the slab's full-resolution crop was cut on this frame (`TrackerOutput.slabDetail`), and the outlines of a
    /// search's refine pass on it (`TrackerOutput.refinedDetections`); nil: none
    public var slabCrop: SlabImageCrop?
    public var refinedDetections: [DetectedOutline]?
    /// the tilt's honest standard deviation (degrees) and whether it was settled enough to show (`TrackerOutput
    /// .tiltSigmaDegrees`, `angleSettled`; nil: not settled, or a recording from before n11)
    public var tiltSigmaDegrees: Double?
    public var angleSettled: Bool?

    public init(state: TrackerState) { self.state = state }

    public init(_ o: TrackerOutput) {
        state = o.state
        events = o.events.isEmpty ? nil : o.events
        slab = o.slab
        outline = o.outline?.map { [$0.x, $0.y] }
        readouts = o.readouts
        measurement = o.measurement?.map { [$0.x, $0.y] }
        detections = o.detections
        ballSearched = o.ballSearched ? true : nil
        ballAwaitsConfirmation = o.ballAwaitsConfirmation ? true : nil
        ball = o.ball.map { [$0.center.x, $0.center.y, $0.center.z, $0.circle.x, $0.circle.y, $0.radius] }
        depthFused = o.depthFused ? true : nil
        lockUnconfirmed = o.lockUnconfirmed ? true : nil
        slabCrop = o.slabDetail?.crop
        refinedDetections = o.refinedDetections
        tiltSigmaDegrees = o.tiltSigmaDegrees
        angleSettled = o.angleSettled ? true : nil
    }

    /// the slab's tilt from level (degrees), while locked
    public var tiltDegrees: Double? { readouts?.tiltDegrees }
    /// the ball's world centre
    public var ballCenter: Vec3? { ball.flatMap { $0.count >= 3 ? Vec3($0[0], $0[1], $0[2]) : nil } }

    /// How this result (a replay's) differs from `phone`'s, one line per field that differs beyond `tol`, each starting
    /// with the field's name and a colon (e.g. "state: phone locked, replay confirming"). Empty when they agree.
    public func differences(from phone: RecordedOutput, tolerances tol: ReplayTolerances = ReplayTolerances()) -> [String] {
        var d: [String] = []
        func f(_ v: Double) -> String { String(format: "%.4g", v) }
        if state != phone.state { d.append("state: phone \(phone.state.rawValue), replay \(state.rawValue)") }
        if (events ?? []) != (phone.events ?? []) {
            d.append("events: phone [\((phone.events ?? []).joined(separator: ", "))], replay [\((events ?? []).joined(separator: ", "))]")
        }
        switch (phone.slab, slab) {
        case (nil, nil): break
        case (.some, nil): d.append("slab: phone has one, replay none")
        case (nil, .some): d.append("slab: replay has one, phone none")
        case let (.some(a), .some(b)):
            let ang = Units.degrees(a.normal.angle(to: b.normal)), dist = a.center.distance(to: b.center)
            if ang > tol.normalDegrees || dist > tol.centre {
                d.append("slab: normals \(f(ang)) deg apart, centres \(f(dist * 1000)) mm apart")
            }
        }
        if let a = phone.tiltDegrees, let b = tiltDegrees, abs(a - b) > tol.tiltDegrees {
            d.append("tilt: phone \(f(a)), replay \(f(b)) deg")
        }
        if let a = phone.outline, let b = outline {
            let m = RecordedOutput.maxDistance(a, b)
            if m > tol.pixels { d.append("outline: corners up to \(f(m)) px apart") }
        }
        if let a = phone.readouts, let b = readouts {
            if a.dropFromBall != b.dropFromBall { d.append("readouts: drop from the ball on the phone \(a.dropFromBall), replay \(b.dropFromBall)") }
            let pairs = [("drop height", a.dropHeight, b.dropHeight), ("landing distance", a.landingDistance, b.landingDistance),
                         ("apex height", a.apexHeight, b.apexHeight), ("air time", a.airTime, b.airTime)]
            for (name, x, y) in pairs where !(abs(x - y) <= tol.readout) {
                d.append("readouts: \(name) phone \(f(x)), replay \(f(y))")
            }
        }
        switch (phone.detections, detections) {
        case (nil, nil): break
        case (.some, nil): d.append("detector: ran on the phone, not in the replay")
        case (nil, .some): d.append("detector: ran in the replay, not on the phone")
        case let (.some(a), .some(b)):
            if a.count != b.count {
                d.append("detections: phone found \(a.count), replay \(b.count)")
            } else {
                let m = zip(a, b).map { RecordedOutput.maxDistance($0.quad.map { [$0.x, $0.y] }, $1.quad.map { [$0.x, $0.y] }) }.max() ?? 0
                if m > tol.pixels { d.append("detections: corners up to \(f(m)) px apart") }
            }
        }
        if (phone.ballSearched ?? false) != (ballSearched ?? false) {
            d.append("ball finder: ran \((phone.ballSearched ?? false) ? "on the phone, not in the replay" : "in the replay, not on the phone")")
        }
        switch (phone.ballCenter, ballCenter) {
        case (nil, nil): break
        case (.some, nil): d.append("ball: phone saw one, replay none")
        case (nil, .some): d.append("ball: replay saw one, phone none")
        case let (.some(a), .some(b)):
            if a.distance(to: b) > tol.centre { d.append("ball: centres \(f(a.distance(to: b) * 1000)) mm apart") }
        }
        if (phone.depthFused ?? false) != (depthFused ?? false) { d.append("depth: fused on the phone \(phone.depthFused ?? false), replay \(depthFused ?? false)") }
        // what the phone showed: the tilt, or "settling" (recordings from before n11 do not say: not compared)
        if let a = phone.angleSettled ?? (phone.tiltSigmaDegrees != nil ? false : nil), a != (angleSettled ?? false) {
            d.append("settled: phone \(a), replay \(angleSettled ?? false)")
        }
        if (phone.lockUnconfirmed ?? false) != (lockUnconfirmed ?? false) {
            d.append("lock unconfirmed: phone \(phone.lockUnconfirmed ?? false), replay \(lockUnconfirmed ?? false)")
        }
        if (phone.slabCrop == nil) != (slabCrop == nil) {
            d.append("slab crop: \(phone.slabCrop != nil ? "cut on the phone, not in the replay" : "cut in the replay, not on the phone")")
        }
        switch (phone.refinedDetections, refinedDetections) {
        case (nil, nil): break
        case (.some, nil), (nil, .some): d.append("refined: the refine pass ran \(phone.refinedDetections != nil ? "on the phone only" : "in the replay only")")
        case let (.some(a), .some(b)):
            let m = a.count == b.count
                ? zip(a, b).map { RecordedOutput.maxDistance($0.quad.map { [$0.x, $0.y] }, $1.quad.map { [$0.x, $0.y] }) }.max() ?? 0 : .infinity
            if m > tol.pixels { d.append("refined: outlines differ (phone \(a.count), replay \(b.count), corners up to \(f(m)) px apart)") }
        }
        return d
    }

    /// largest distance between corresponding points (pixels); infinity when the counts differ
    static func maxDistance(_ a: [[Double]], _ b: [[Double]]) -> Double {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { (($0[0] - $1[0]) * ($0[0] - $1[0]) + ($0[1] - $1[1]) * ($0[1] - $1[1])).squareRoot() }.max() ?? 0
    }
}

/// How close a replay must come to the phone's results to count as the same. A replay on the same kind of machine runs
/// the same arithmetic and matches exactly; on another (a Mac or Linux against an iPhone) the maths library may differ
/// in the last digits.
public struct ReplayTolerances: Equatable {
    public var tiltDegrees = 0.01
    public var normalDegrees = 0.01
    /// slab and ball centres (m)
    public var centre = 0.0005
    /// outlines and detections (pixels)
    public var pixels = 0.05
    /// readouts (m, s)
    public var readout = 0.001
    public init() {}
}

/// What to store of one processed frame (`RecordingCadence.record`): its line, and the pixels a replay needs.
public struct FrameRecord {
    public var frame: RecordedFrame
    public var image: YCCImage?
    public var depth: DepthMap?
    public var ball: Plane?
    /// the slab's full-resolution crop, on frames whose detector run used one (always kept: a replay needs it)
    public var slab: Plane? = nil
}

/// What a recording keeps of each frame the app processes, so a replay runs exactly what the phone ran:
///   - every frame gets a line: its camera, tracking state, tap, floor height, the controls before it and the
///     tracker's result (a replay runs the tracker on the same frames at the same times, and compares);
///   - the image on every frame the detector ran on (it ran on that image), on taps and controls, and otherwise every
///     `imageInterval` seconds (to look at, and for replays with other settings);
///   - LiDAR depth: the whole map with an image or a detection (a re-lock checks other poses), else only the part
///     under the lock's top, which is all the tracker read (a few kB instead of 250 kB, so it can be kept on every
///     frame at the camera's rate);
///   - for the ball finder, on every frame it ran on, what `ballPixels` says (its crop's place and intrinsics always);
///   - the slab's full-resolution crop on every frame the detector used one (`TrackerOutput.slabDetail`).
/// Use: before processing a frame, convert its image if the tracker needs it (`detectionDue`, a tap) or
/// `needsImage(at:tracker:)`; after, `record` it and append the result (`RecordingWriter.append(record.frame, image:
/// depth:ball:)`). If the disk falls behind, drop pixels rather than lines: a replay uses the phone's recorded
/// detections and ball results where a frame's pixels are missing, and says so.
public struct RecordingCadence {
    /// What to keep for the ball finder on the frames it ran on.
    public enum BallPixels: String, Codable {
        /// its image exactly (a shrunk crop of the full camera image, 16-bit; a few hundred kB a frame): a replay runs the
        /// ball finder on what the phone's saw
        case crop
        /// the processing frame's image instead (smaller, and also useful to look at): a replay can rebuild an
        /// approximate crop from it (`ReplayRunner.Options.rebuildBallCrops`) or use the phone's results
        case frame
        /// nothing: a replay uses the phone's results
        case none
    }

    public var imageInterval: Double
    public var ballPixels: BallPixels
    public private(set) var lastImageTime = -Double.infinity

    public init(imageInterval: Double = 0.2, ballPixels: BallPixels = .crop) { self.imageInterval = imageInterval; self.ballPixels = ballPixels }

    /// Whether to convert this frame's image for the recording even if the tracker does not need it (time-based).
    public func imageDue(at t: Double) -> Bool { t - lastImageTime >= imageInterval }

    /// Whether to convert this frame's image for the recording: time-based, or (`ballPixels == .frame`) the ball finder
    /// will run on this frame. Call before processing the frame.
    public func needsImage(at t: Double, tracker: SlabTracker) -> Bool {
        imageDue(at: t) || (ballPixels == .frame && tracker.state == .locked && tracker.ballDue(at: t))
    }

    /// The record of a processed frame. `image`: the processing image, if the app converted it; `ballCrop`: where the
    /// ball finder's image (in `tf.ballImage`) was cut from, if there was one.
    public mutating func record(_ tf: TrackerFrame, output: TrackerOutput, tracker: SlabTracker, image: YCCImage?,
                                ballCrop: BallImageCrop? = nil) -> FrameRecord {
        var rf = RecordedFrame(processed: tf, output: output, ballCrop: ballCrop)
        let t = tf.timestamp
        let ballRan = output.ballSearched && tf.ballImage != nil
        let keepImage = image != nil && (output.detections != nil || tf.tap != nil || !output.controls.isEmpty || imageDue(at: t)
                                         || (ballRan && ballPixels == .frame))
        if keepImage { lastImageTime = t }
        var depth: DepthMap? = nil
        if let d = tf.depth, let dk = tf.depthIntrinsics {
            if keepImage || output.detections != nil {
                depth = d
            } else if tracker.state == .locked, let s = tracker.imageSlab,
                      let part = PlaneFit.depthRegion(depth: d, depthIntrinsics: dk, view: tf.view, slab: s) {
                depth = part.0; rf.depthIntrinsics = part.1
            }
        }
        if depth == nil { rf.depthIntrinsics = nil }
        if !ballRan { rf.ballIntrinsics = nil; rf.ballCrop = nil }
        let ball = ballRan && ballPixels == .crop ? tf.ballImage : nil
        return FrameRecord(frame: rf, image: keepImage ? image : nil, depth: depth, ball: ball, slab: output.slabDetail?.luma)
    }
}

extension PlaneFit {
    /// The part of a depth map `checkSlabTop` reads for this slab (the bounding box of its shrunk top, plus `margin`
    /// pixels), with the intrinsics of that part: checking it gives the same result as checking the whole map. nil if
    /// the top does not project into the map.
    public static func depthRegion(depth: DepthMap, depthIntrinsics K: CameraIntrinsics, view: CameraView, slab: SlabPose,
                                   inner: Double = 0.7, margin: Int = 2) -> (DepthMap, CameraIntrinsics)? {
        let poly = slabCornerSigns.map { slab.point(u: $0.0 * slab.halfU * inner, v: $0.1 * slab.halfV * inner) }
            .compactMap { K.project(view.toCamera($0)) }
        guard poly.count == 4 else { return nil }
        let x0 = max(0, Int(floor(poly.map { $0.x }.min()!)) - margin), x1 = min(depth.width - 1, Int(ceil(poly.map { $0.x }.max()!)) + margin)
        let y0 = max(0, Int(floor(poly.map { $0.y }.min()!)) - margin), y1 = min(depth.height - 1, Int(ceil(poly.map { $0.y }.max()!)) + margin)
        guard x1 >= x0, y1 >= y0 else { return nil }
        let part = depth.cropped(x0: x0, y0: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        return (part, K.cropped(x0: Double(x0), y0: Double(y0), scale: 1, width: part.width, height: part.height))
    }
}
