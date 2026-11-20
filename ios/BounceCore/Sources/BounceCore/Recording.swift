import Foundation

/// A recorded session: what the camera saw and where it was, frame by frame, so a session on the phone can be replayed
/// through the same detector and maths on any computer (`swift test`), and the replay checked against what the phone
/// did (`ReplayRunner`).
///
/// On disk a recording is a folder `<name>.bouncerec/` holding
///   - `session.json`  `RecordingSession`: build, device, settings (the owner's, and the tracker's exactly), frame size
///   - `frames.jsonl`  one `RecordedFrame` per line
///   - `f<NNNNNN>.byc` the frame's image: luma plus half-size chroma (`YCCImage`, format "BYC1")
///   - `d<NNNNNN>.bdp` optional LiDAR depth (`DepthMap`, format "BDP1"), the whole map or the part the tracker read
///   - `b<NNNNNN>.pgm` optional: the image the ball finder was given (a crop of the full camera image; a PGM that keeps
///                     the crop's shrunk pixels exactly, see `Plane.pgmData(blockSum:)`)
///   - `s<NNNNNN>.pgm` optional: the full-resolution crop the slab's edge steps read (`SlabImageCrop`; kept exactly the
///                     same way)
/// NNNNNN is the frame's line number in frames.jsonl.
///
/// Version 1 has a line only for frames with an image, taken every 0.1-0.2 s regardless of what the tracker did.
/// Version 2 (`everyFrame`) has a line for every frame the tracker processed, with what was done to the tracker before it
/// (`controls`: settings changes, resets, world-frame discontinuities), its inputs (tap, floor height) and the tracker's
/// result on the phone (`output`); pixels are kept where a replay needs them (`RecordingCadence`): every frame the
/// detector ran on, depth where the tracker read it, each ball finder image. Frames without an image have an empty
/// `file`. Readers handle both versions; fields added later are optional.
///
/// The app shares it as a single zip (`ZipWriter`). Recordings can show the owner's surroundings: they are private and
/// are never committed to the repository.
public struct RecordingSession: Codable, Equatable {
    /// the version this build writes (see above); readers accept 1 and 2
    public static let currentVersion = 2

    public var format: String = "bouncerec"
    public var version: Int = RecordingSession.currentVersion
    public var build: String
    public var device: String
    public var frameWidth: Int
    public var frameHeight: Int
    public var settings: RecordingSettings
    public var notes: String?
    public var createdAt: String?
    /// the tracker's settings when the recording started, exactly (later changes are frames' `controls`); nil in
    /// version 1, where a replay falls back to `settings.trackerSettings`
    public var tracker: TrackerSettings?
    /// frames.jsonl has a line for every frame the tracker processed (nil or false: only some of them)
    public var everyFrame: Bool?
    /// the tracker's state when the recording started: unless the first frame resets it (or starts a new tracker), a
    /// replay that starts from searching differs from the phone at first when this is not "searching"
    public var trackerStateAtStart: TrackerState?

    public init(build: String, device: String, frameWidth: Int, frameHeight: Int, settings: RecordingSettings, notes: String? = nil, createdAt: String? = nil,
                tracker: TrackerSettings? = nil, everyFrame: Bool? = nil, trackerStateAtStart: TrackerState? = nil) {
        self.build = build; self.device = device; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.settings = settings; self.notes = notes; self.createdAt = createdAt
        self.tracker = tracker; self.everyFrame = everyFrame; self.trackerStateAtStart = trackerStateAtStart
    }
}

/// The settings in the owner's units, as the app shows them.
public struct RecordingSettings: Codable, Equatable {
    public var sideUInches: Double
    public var sideVInches: Double
    public var thicknessInches: Double
    public var dishInches: Double
    public var ballDiameterMm: Double
    public var dropHeightFeet: Double
    /// the rebound (the share of the drop height a straight-up bounce regains: e², percent); the app's setting until n11.
    /// With `restitution` set it is that restitution's square (`reboundPercent(restitution:)`), kept for older readers;
    /// the ball is then the restitution's (`ball`)
    public var reboundPercent: Double
    /// launch the ball along the dish's normal where it lands (Settings' "dish bounce"), not the corner plane's; nil in
    /// version 1 recordings (which did not say: the corner plane)
    public var dishBounce: Bool?
    /// The ball's restitution e, the app's setting from n12 (`BallSpec.restitution`): with it the app bounces the ball
    /// by the impact rule (`Bounce.LaunchRule.impact`) with this e and `tangential`. nil in every recording made before
    /// n12: they replay with `reboundPercent` and the launch rule they ran (the corner plane, or `dishBounce`).
    public var restitution: Double?
    /// The ball's tangential share k_t under the impact rule (`BallSpec.tangential`; nil: `BallSpec.ownerTangential`).
    public var tangential: Double?
    /// The slab's side profile (`SlabSpec.faceDrop`, `sideRun`, `edgeRadius` in inches; `nearFeatureAngle` in degrees).
    /// nil means 0: every recording made before the profile existed has none (the old box with vertical cut faces, and
    /// the edge refiner's original rules), so it replays as it ran.
    public var faceDropInches: Double?
    public var sideRunInches: Double?
    public var edgeRadiusInches: Double?
    public var nearFeatureDegrees: Double?

    /// New settings default to the owner's slab and ball (`SlabSpec.ownerSlab`, `BallSpec.ownerBall`: their constants are
    /// the one place to change them), a 3 ft drop, and the owner's restitution (0.9) and tangential share (0.2) with the
    /// impact rule (the rebound is then 81%, 0.9²). With a restitution, `reboundPercent` is set to its square whatever is
    /// passed, so the two never disagree in a file; `restitution: nil` gives the rule of the builds before n12 (the
    /// corner plane, or `dishBounce`) at the `reboundPercent` passed.
    public init(sideUInches: Double = SlabSpec.ownerFlatTopInches, sideVInches: Double = SlabSpec.ownerFlatTopInches,
                thicknessInches: Double = SlabSpec.ownerThicknessInches, dishInches: Double = SlabSpec.ownerDishInches,
                ballDiameterMm: Double = BallSpec.ownerDiameterMm, dropHeightFeet: Double = 3,
                reboundPercent: Double = RecordingSettings.reboundPercent(restitution: BallSpec.ownerRestitution), dishBounce: Bool? = nil,
                faceDropInches: Double? = SlabSpec.ownerFaceDropInches, sideRunInches: Double? = SlabSpec.ownerSideRunInches,
                edgeRadiusInches: Double? = SlabSpec.ownerEdgeRadiusInches, nearFeatureDegrees: Double? = nil,
                restitution: Double? = BallSpec.ownerRestitution, tangential: Double? = BallSpec.ownerTangential) {
        self.sideUInches = sideUInches; self.sideVInches = sideVInches; self.thicknessInches = thicknessInches; self.dishInches = dishInches
        self.ballDiameterMm = ballDiameterMm; self.dropHeightFeet = dropHeightFeet
        self.reboundPercent = restitution.map { RecordingSettings.reboundPercent(restitution: $0) } ?? reboundPercent
        self.dishBounce = dishBounce
        self.faceDropInches = faceDropInches; self.sideRunInches = sideRunInches; self.edgeRadiusInches = edgeRadiusInches
        self.nearFeatureDegrees = nearFeatureDegrees
        self.restitution = restitution; self.tangential = tangential
    }

    /// The rebound percent a restitution gives (100 e²), as written beside it: rounded to 1e-9 so that 0.8 writes 64, not
    /// 64.00000000000001.
    public static func reboundPercent(restitution e: Double) -> Double { (100 * e * e * 1e9).rounded() / 1e9 }

    /// how often the app searches for the slab while it has none (s): the search costs tens of ms on the phone
    public static let appSearchInterval = 0.12
    /// The app's shortest time between two runs of the slab detector (s; `TrackerSettings.minDetectionGap`): at most
    /// 20 runs a second, so the detector cannot run on every frame at 60 (or 30) fps however often something forces a
    /// run (a discontinuity reported frame after frame, taps); a forced run waits at most this long. The scheduled
    /// intervals (0.12 s searching, 0.3 s re-checking) are longer and unaffected.
    public static let appMinDetectionGap = 0.05
    /// The app's slab sweep skips starting points inside what it already found, and refines one outline per start once
    /// (`TrackerSettings.sweepSkipsFinds`, `sweepSameOutlinePixels`): the same outlines, a plain floor's search at 2 ft
    /// in about a quarter of the time. It keeps the finder's own cap on the regions grown (48, `maxSweepRegions` unset):
    /// on cluttered floors seen from some sides the slab is only reached at region 33-48, and a lower cap (32 was tried)
    /// then misses it and can lock a slab-sized patch of the floor instead.
    public static let appSweepSameOutlinePixels = 1.5
    /// The app backs its searches off after this long (s) of searches from a still camera that found nothing
    /// (`TrackerSettings.idleSearchAfter`): then every 0.36 s instead of 0.12 until the camera moves, a tap, a candidate.
    public static let appIdleSearchAfter = 1.0
    /// The app's ball finder, with no ball shown or about to be, slows to every 0.3 s after this long (s) of scans that
    /// found none (`TrackerSettings.idleBallAfter`); a followed ball is looked for every 0.1 s as before.
    public static let appIdleBallAfter = 0.5

    /// The tracker settings the app runs with for these settings (AppSettings.tracker should use this, so the app and
    /// a replay of an older recording build them the same way).
    public var trackerSettings: TrackerSettings {
        var t = TrackerSettings()
        t.spec = slab
        t.ball = ball
        t.defaultDropHeight = dropHeight
        t.launchRule = launchRule
        t.searchInterval = RecordingSettings.appSearchInterval
        t.minDetectionGap = RecordingSettings.appMinDetectionGap
        t.sweepSkipsFinds = true
        t.sweepSameOutlinePixels = RecordingSettings.appSweepSameOutlinePixels
        t.idleSearchAfter = RecordingSettings.appIdleSearchAfter
        t.idleBallAfter = RecordingSettings.appIdleBallAfter
        t.depthNormalWeight = RecordingSettings.appDepthNormalWeight
        t.depthCentreWeight = RecordingSettings.appDepthCentreWeight
        t.readoutsFromSettledNormal = true
        t.lockKeepsNewestPerView = true
        t.tapHints = true
        t.tapSetsBall = true
        return t
    }

    /// LiDAR's plane is not folded into the slab's tilt (`TrackerSettings.depthNormalWeight` 0): on the owner's first kit
    /// (slab-kit-20261118-205900) the smoothed depth plane of the slab's small raised top read 4-20 deg off the true
    /// plane from a standstill (it smears the top into the floor), barely moved over 5 s, and the depth checks a correct
    /// lock would pass were a median 4.9 deg off (max 7.9): blending it in at the old 0.5 added about 2.4 deg and, on one
    /// arc, moved the lock from +0.18 to -2.10 deg. Its range is still used.
    public static let appDepthNormalWeight = 0.0
    /// LiDAR moves the lock's centre half way to its own range (`TrackerSettings.depthCentreWeight`), the weight it had
    /// before n11. Half and half while the slab's size is not measured with a ruler: the picture's range scales with the
    /// assumed size, now the 180.2 mm flat top read from the owner's first kit's pictures (± 1.5 mm, 0.8%), and LiDAR's
    /// range is off by 1-2% beyond 1 m on the same kit (2.6% per metre in one shot, 0.7-0.9% in another). Replayed with
    /// that size, LiDAR's range to the top came out a median 0.9% longer than the picture's (shot medians 0.2-2.9%), about
    /// what LiDAR reads long against the floor, so neither is clearly better. Once a ruler gives the size (the picture's
    /// range then good to about 0.3%), this should become the variance weight picture^2 / (picture^2 + LiDAR^2), well
    /// under a half beyond 1 m.
    public static let appDepthCentreWeight = 0.5

    /// The launch rule: the old developer experiment when a recording says so, else the impact rule with a restitution
    /// (n12 on), else the corner plane (every recording before n12).
    public var launchRule: Bounce.LaunchRule { dishBounce == true ? .dishNormal : restitution != nil ? .impact : .cornerPlane }

    public var slab: SlabSpec {
        SlabSpec(sideU: Units.inches(sideUInches), sideV: Units.inches(sideVInches), thickness: Units.inches(thicknessInches), dishDepth: Units.inches(dishInches),
                 faceDrop: Units.inches(faceDropInches ?? 0), sideRun: Units.inches(sideRunInches ?? 0), edgeRadius: Units.inches(edgeRadiusInches ?? 0),
                 nearFeatureAngle: Units.radians(nearFeatureDegrees ?? 0))
    }
    public var ball: BallSpec {
        guard let e = restitution else { return BallSpec(diameter: ballDiameterMm / 1000, rebound: reboundPercent / 100) }
        return BallSpec(diameter: ballDiameterMm / 1000, restitution: e, tangential: tangential ?? BallSpec.ownerTangential)
    }
    public var dropHeight: Double { Units.feet(dropHeightFeet) }
}

/// One frame's record. Camera poses are ARKit's `camera.transform` (world-from-camera, ARKit camera axes, metres,
/// gravity-aligned world with y up), column-major. Intrinsics describe the processing frame the tracker ran on (the full
/// camera image shrunk; also the stored image's), not the full camera image. Points in pixels (tap, outlines) are the
/// processing frame's unless said otherwise.
public struct RecordedFrame: Codable, Equatable {
    public var index: Int
    public var timestamp: Double
    public var file: String
    public var worldFromCamera: [Double]
    public var intrinsics: CameraIntrinsics
    /// ARKit tracking was "normal" (not limited / not available)
    public var trackingNormal: Bool
    /// gravity in CV camera axes from the motion sensor (optional; ARKit's world already carries it)
    public var gravityCamera: [Double]?
    /// device motion (optional): user acceleration (g), rotation rate (rad/s), attitude quaternion (x, y, z, w)
    public var userAcceleration: [Double]?
    public var rotationRate: [Double]?
    public var attitude: [Double]?
    /// exposure (optional): duration (s), ISO; and whether focus / exposure / white balance were locked
    public var exposureDuration: Double?
    public var iso: Double?
    public var locked: Bool?
    /// LiDAR depth file for this frame, and the intrinsics of the depth map (optional). In version 2 the map may be only
    /// the part of the phone's that the tracker read (the lock's top); its intrinsics then describe that part.
    public var depthFile: String?
    public var depthIntrinsics: CameraIntrinsics?

    // Version 2: the tracker's other inputs, and its result on the phone.

    /// a tap passed to the tracker on this frame (processing pixels)
    public var tap: [Double]?
    /// the floor height passed to the tracker (world y, metres; ARKit's plane under the slab), if any
    public var floorY: Double?
    /// what was done to the tracker before this frame, in order (`TrackerOutput.controls`)
    public var controls: [TrackerControl]?
    /// the ball finder's image on this frame: its file (`b<NNNNNN>.pgm`), the intrinsics of its pixels, and where it
    /// was cut from the full camera image (optional: the intrinsics alone say where it looks)
    public var ballFile: String?
    public var ballIntrinsics: CameraIntrinsics?
    public var ballCrop: BallImageCrop?
    /// the tracker's result on the phone for this frame (what a replay is compared with)
    public var output: RecordedOutput?
    /// the full-resolution crop the slab finder's edge steps read on this frame (`TrackerOutput.slabDetail`; where it was
    /// cut is `output.slabCrop`): its file (`s<NNNNNN>.pgm`) and the intrinsics of its pixels. The intrinsics are kept
    /// even when the pixels were dropped (the disk fell behind), so a replay knows the phone had them.
    public var slabFile: String?
    public var slabIntrinsics: CameraIntrinsics?

    public init(index: Int, timestamp: Double, file: String, worldFromCamera: [Double], intrinsics: CameraIntrinsics, trackingNormal: Bool = true) {
        self.index = index; self.timestamp = timestamp; self.file = file; self.worldFromCamera = worldFromCamera
        self.intrinsics = intrinsics; self.trackingNormal = trackingNormal
    }

    /// The record of a frame the tracker processed: its camera (as ARKit's transform), gravity, tracking state, tap,
    /// floor height, the controls before it and the tracker's output. The app adds motion and exposure; the writer sets
    /// the index and files. `ballCrop`: where the ball finder's image was cut from, if the frame had one.
    public init(processed tf: TrackerFrame, output: TrackerOutput, ballCrop: BallImageCrop? = nil) {
        let w = tf.view.worldFromCamera
        let arkit = RigidTransform(rotation: w.rotation * ARKitConvention.cvToARKitCamera, translation: w.translation)
        self.init(index: 0, timestamp: tf.timestamp, file: "", worldFromCamera: arkit.columnMajor4x4, intrinsics: tf.view.intrinsics,
                  trackingNormal: tf.trackingNormal)
        gravityCamera = tf.view.directionToCamera(ARKitConvention.worldDown).array
        tap = tf.tap.map { [$0.x, $0.y] }
        floorY = tf.floorY
        controls = output.controls.isEmpty ? nil : output.controls
        depthIntrinsics = tf.depthIntrinsics
        if tf.ballImage != nil { ballIntrinsics = tf.ballIntrinsics; self.ballCrop = ballCrop }
        slabIntrinsics = output.slabDetail?.intrinsics
        exposureDuration = tf.exposureDuration
        self.output = RecordedOutput(output)
    }

    /// whether the frame's image was recorded (version 2 frames without one have an empty `file`)
    public var hasImage: Bool { !file.isEmpty }

    /// the tap as a point
    public var tapPoint: Vec2? { tap.flatMap { $0.count == 2 ? Vec2($0[0], $0[1]) : nil } }

    /// The camera view in BounceCore's CV axes.
    public var view: CameraView {
        CameraView(worldFromCamera: ARKitConvention.worldFromCVCamera(arkitCameraTransform: RigidTransform(columnMajor4x4: worldFromCamera)),
                   intrinsics: intrinsics)
    }
}

/// An 8-bit YCbCr 4:2:0 image ("BYC1"): magic "BYC1", width and height as little-endian UInt16, then width*height luma
/// bytes, then Cb and Cr planes of ceil(w/2) x ceil(h/2) bytes each (full range, centred on 128).
public struct YCCImage: Equatable {
    public var width: Int
    public var height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]
    public var chromaWidth: Int { (width + 1) / 2 }
    public var chromaHeight: Int { (height + 1) / 2 }

    public init(width: Int, height: Int, y: [UInt8], cb: [UInt8], cr: [UInt8]) {
        precondition(y.count == width * height && cb.count == ((width + 1) / 2) * ((height + 1) / 2) && cr.count == cb.count)
        self.width = width; self.height = height; self.y = y; self.cb = cb; self.cr = cr
    }

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 66, b[1] == 89, b[2] == 67, b[3] == 49 else { return nil }
        let w = Int(b[4]) | Int(b[5]) << 8, h = Int(b[6]) | Int(b[7]) << 8
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        guard w > 0, h > 0, b.count >= 8 + w * h + 2 * cw * ch else { return nil }
        let o1 = 8 + w * h, o2 = o1 + cw * ch
        self.init(width: w, height: h, y: Array(b[8..<o1]), cb: Array(b[o1..<o2]), cr: Array(b[o2..<(o2 + cw * ch)]))
    }

    public var data: Data {
        var d = Data([66, 89, 67, 49, UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
        d.append(contentsOf: y); d.append(contentsOf: cb); d.append(contentsOf: cr)
        return d
    }

    public var luma: Plane { Plane(bytes: y, width: width, height: height) }

    /// Colour frame at this image's size (chroma upsampled), in the detector's units.
    ///
    /// The chroma planes are upsampled bilinearly as `Plane.resized` does (`Plane.sample` at each pixel centre), with
    /// each output column's and row's source index and weight worked out once (the same Double arithmetic `sample`
    /// does per pixel), then the same Float interpolation and colour-difference scaling as
    /// `ColorFrame(lumaFull:cbHalf:crHalf:scale:)`: the very same Floats, about a third of the time (it runs on every
    /// frame the slab detector runs on).
    public var colorFrame: ColorFrame {
        let w = width, h = height, cw = chromaWidth, ch = chromaHeight
        let sx = Double(cw) / Double(w), sy = Double(ch) / Double(h)
        // where resized would not sample bilinearly (the same size, or shrinking both ways), or a plane too small to
        // interpolate across: the general path
        guard !((cw == w && ch == h) || (sx >= 1 && sy >= 1)), cw >= 2, ch >= 2 else {
            return ColorFrame(lumaFull: luma, cbHalf: Plane(bytes: cb, width: cw, height: ch),
                              crHalf: Plane(bytes: cr, width: cw, height: ch), scale: 1)
        }
        // per output column (row): the source index and weight Plane.sample takes at the pixel's centre
        func axis(_ n: Int, _ s: Double, _ size: Int) -> (i: [Int], a: [Float]) {
            var ii = [Int](repeating: 0, count: n), aa = [Float](repeating: 0, count: n)
            for x in 0..<n {
                let f = clamp((Double(x) + 0.5) * s - 0.5, 0, Double(size) - 1.001)
                let i = Int(f)
                ii[x] = i; aa[x] = Float(f - Double(i))
            }
            return (ii, aa)
        }
        let (xi, ax) = axis(w, sx, cw), (yi, ay) = axis(h, sy, ch)
        func plane(_ src: [UInt8], _ scale: Float) -> Plane {
            let s = src.map { Float($0) }
            var d = [Float](repeating: 0, count: w * h)
            s.withUnsafeBufferPointer { sp in
                d.withUnsafeMutableBufferPointer { dp in
                    xi.withUnsafeBufferPointer { xip in
                        ax.withUnsafeBufferPointer { axp in
                            for yy in 0..<h {
                                let r = yi[yy] * cw, b = ay[yy], o = yy * w
                                for x in 0..<w {
                                    let j = r + xip[x], a = axp[x]
                                    let top = sp[j] * (1 - a) + sp[j + 1] * a
                                    let bot = sp[j + cw] * (1 - a) + sp[j + cw + 1] * a
                                    dp[o + x] = ((top * (1 - b) + bot * b) - 128) / scale
                                }
                            }
                        }
                    }
                }
            }
            return Plane(width: w, height: h, data: d)
        }
        return ColorFrame(y: luma, cb: plane(cb, 0.564), cr: plane(cr, 0.713))
    }

    /// Build from separate luma and interleaved CbCr planes (as a CVPixelBuffer's two planes), downscaling by an integer
    /// factor k (luma averaged over k x k blocks, chroma over (k/2) x (k/2) blocks of the half-size plane: the integer
    /// sums divided, truncating). It runs on every frame the slab detector runs on (and every recorded image), so it
    /// works a row of blocks at a time through row pointers, and for the app's factor 4 sums two luma blocks, or a row
    /// of four CbCr pairs, from one 8-byte load in 16-bit lanes: the same sums and divisions, so the same bytes.
    public static func fromBiplanar(luma: UnsafeBufferPointer<UInt8>, lumaWidth W: Int, lumaHeight H: Int, lumaBytesPerRow lb: Int,
                                    cbcr: UnsafeBufferPointer<UInt8>, cbcrBytesPerRow cbb: Int, factor k: Int) -> YCCImage {
        let w = W / k, h = H / k, cw = (w + 1) / 2, chh = (h + 1) / 2
        var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 128, count: cw * chh), cr = cb
        guard w > 0, h > 0, let L = luma.baseAddress, let C = cbcr.baseAddress else { return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr) }
        precondition(luma.count >= (h * k - 1) * lb + w * k && (H / 2 == 0 || cbcr.count >= (min(H / 2, chh * k) - 1) * cbb + 2 * min(W / 2, cw * k)),
                     "fromBiplanar: the planes are smaller than their sizes say")
        let kk = k * k
        var sums = [Int](repeating: 0, count: w)
        y.withUnsafeMutableBufferPointer { yo in
            sums.withUnsafeMutableBufferPointer { s in
                for yy in 0..<h {
                    for x in 0..<w { s[x] = 0 }
                    for dy in 0..<k {
                        let row = L + (yy * k + dy) * lb
                        if k == 4 {
                            // two blocks from one 8-byte load: byte pairs summed in 16-bit lanes, then the lanes paired
                            let raw = UnsafeRawPointer(row)
                            var x = 0
                            while x + 1 < w {
                                let v = raw.loadUnaligned(fromByteOffset: x * 4, as: UInt64.self).littleEndian
                                let t = (v & 0x00FF_00FF_00FF_00FF) &+ ((v >> 8) & 0x00FF_00FF_00FF_00FF)
                                s[x] &+= Int(t & 0xFFFF) &+ Int((t >> 16) & 0xFFFF)
                                s[x + 1] &+= Int((t >> 32) & 0xFFFF) &+ Int(t >> 48)
                                x += 2
                            }
                            if x < w { let p = row + x * 4; s[x] &+= Int(p[0]) &+ Int(p[1]) &+ Int(p[2]) &+ Int(p[3]) }
                        } else {
                            for x in 0..<w { let p = row + x * k; var t = 0; for dx in 0..<k { t &+= Int(p[dx]) }; s[x] &+= t }
                        }
                    }
                    let o = yy * w
                    for x in 0..<w { yo[o + x] = UInt8(truncatingIfNeeded: s[x] / kk) }
                }
            }
        }
        // chroma: output chroma pixel (cx, cy) covers luma pixels [2cx*k, 2cx*k + 2k) -> half-size chroma [cx*k, cx*k + k),
        // clipped to the plane
        let CW = W / 2, CH = H / 2
        cb.withUnsafeMutableBufferPointer { bo in
            cr.withUnsafeMutableBufferPointer { ro in
                for yy in 0..<chh {
                    let r0 = yy * k, r1 = min(CH, r0 + k)
                    for xx in 0..<cw {
                        let c0 = xx * k, c1 = min(CW, c0 + k)
                        guard r1 > r0, c1 > c0 else { continue }
                        var sb = 0, sr = 0
                        if k == 4 && c1 - c0 == 4 {
                            // a row's four CbCr pairs in one 8-byte load: Cb in the even bytes, Cr in the odd ones
                            var lb: UInt64 = 0, lr: UInt64 = 0
                            for r in r0..<r1 {
                                let v = UnsafeRawPointer(C + r * cbb).loadUnaligned(fromByteOffset: 2 * c0, as: UInt64.self).littleEndian
                                lb &+= v & 0x00FF_00FF_00FF_00FF; lr &+= (v >> 8) & 0x00FF_00FF_00FF_00FF
                            }
                            sb = Int(lb & 0xFFFF) &+ Int((lb >> 16) & 0xFFFF) &+ Int((lb >> 32) & 0xFFFF) &+ Int(lb >> 48)
                            sr = Int(lr & 0xFFFF) &+ Int((lr >> 16) & 0xFFFF) &+ Int((lr >> 32) & 0xFFFF) &+ Int(lr >> 48)
                        } else {
                            for r in r0..<r1 {
                                let p = C + r * cbb
                                for c in c0..<c1 { sb &+= Int(p[2 * c]); sr &+= Int(p[2 * c + 1]) }
                            }
                        }
                        let n = (r1 - r0) * (c1 - c0)
                        bo[yy * cw + xx] = UInt8(truncatingIfNeeded: sb / n); ro[yy * cw + xx] = UInt8(truncatingIfNeeded: sr / n)
                    }
                }
            }
        }
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }
}

/// A LiDAR depth map ("BDP1"): magic "BDP1", width and height as little-endian UInt16, then width*height little-endian
/// Float32 depths (metres along the camera's axis, 0 = none), then width*height confidence bytes (0 low, 1 medium, 2 high).
public struct DepthMap: Equatable {
    public var width: Int
    public var height: Int
    public var depth: [Float]
    public var confidence: [UInt8]

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]) {
        precondition(depth.count == width * height && confidence.count == width * height)
        self.width = width; self.height = height; self.depth = depth; self.confidence = confidence
    }

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 66, b[1] == 68, b[2] == 80, b[3] == 49 else { return nil }
        let w = Int(b[4]) | Int(b[5]) << 8, h = Int(b[6]) | Int(b[7]) << 8, n = w * h
        guard w > 0, h > 0, b.count >= 8 + n * 5 else { return nil }
        var d = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let o = 8 + i * 4
            d[i] = Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        self.init(width: w, height: h, depth: d, confidence: Array(b[(8 + n * 4)..<(8 + n * 5)]))
    }

    public var data: Data {
        // the whole file in a byte array first (appending to Data four bytes at a time is what made this slow)
        var b = [UInt8](repeating: 0, count: 8 + depth.count * 5)
        b[0] = 66; b[1] = 68; b[2] = 80; b[3] = 49
        b[4] = UInt8(width & 255); b[5] = UInt8(width >> 8); b[6] = UInt8(height & 255); b[7] = UInt8(height >> 8)
        b.withUnsafeMutableBufferPointer { o in
            depth.withUnsafeBufferPointer { dp in
                for i in 0..<dp.count {
                    let u = dp[i].bitPattern, j = 8 + 4 * i
                    o[j] = UInt8(u & 255); o[j + 1] = UInt8((u >> 8) & 255); o[j + 2] = UInt8((u >> 16) & 255); o[j + 3] = UInt8(u >> 24)
                }
            }
            confidence.withUnsafeBufferPointer { cp in
                for i in 0..<cp.count { o[8 + 4 * depth.count + i] = cp[i] }
            }
        }
        return Data(b)
    }

    @inline(__always) public func at(_ x: Int, _ y: Int) -> (depth: Float, confidence: UInt8) {
        let i = y * width + x
        return (depth[i], confidence[i])
    }

    /// The part starting at (x0, y0), clamped to the map (at least 1 x 1).
    public func cropped(x0: Int, y0: Int, width w: Int, height h: Int) -> DepthMap {
        let ax = clamp(x0, 0, width - 1), ay = clamp(y0, 0, height - 1)
        let cw = max(1, min(w, width - ax)), ch = max(1, min(h, height - ay))
        var d = [Float](repeating: 0, count: cw * ch), c = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw { d[y * cw + x] = depth[(ay + y) * width + ax + x]; c[y * cw + x] = confidence[(ay + y) * width + ax + x] }
        }
        return DepthMap(width: cw, height: ch, depth: d, confidence: c)
    }
}

/// Reads a recording folder (version 1 or 2).
public struct RecordingReader {
    public let folder: URL
    public let session: RecordingSession
    public let frames: [RecordedFrame]
    /// lines of frames.jsonl that could not be read and were left out (e.g. the last one, cut short when the phone's disk
    /// filled up while recording)
    public let skippedLines: Int

    public init(folder: URL) throws {
        self.folder = folder
        let dec = RecordingReader.decoder
        session = try dec.decode(RecordingSession.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        let data = try Data(contentsOf: folder.appendingPathComponent("frames.jsonl"))
        // invalid UTF-8 (a line cut mid-character) must not lose the whole file
        let text = String(decoding: data, as: UTF8.self)
        var frames: [RecordedFrame] = [], skipped = 0
        for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let f = try? dec.decode(RecordedFrame.self, from: Data(line.utf8)) { frames.append(f) } else { skipped += 1 }
        }
        if frames.isEmpty && skipped > 0 { throw RecordingError.badFile("frames.jsonl") }
        self.frames = frames
        skippedLines = skipped
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    public func image(for f: RecordedFrame) throws -> YCCImage {
        guard f.hasImage else { throw RecordingError.noImage(f.index) }
        guard let img = YCCImage(data: try Data(contentsOf: folder.appendingPathComponent(f.file))) else {
            throw RecordingError.badFile(f.file)
        }
        return img
    }

    /// The ball finder's image on this frame, exactly as the phone gave it (nil if the frame has none recorded).
    public func ball(for f: RecordedFrame) throws -> Plane? {
        guard let name = f.ballFile else { return nil }
        guard let p = Plane(pgm: try Data(contentsOf: folder.appendingPathComponent(name))) else { throw RecordingError.badFile(name) }
        return p
    }

    /// The slab's full-resolution crop on this frame, exactly as the phone cut it (nil if the frame has none recorded).
    public func slab(for f: RecordedFrame) throws -> Plane? {
        guard let name = f.slabFile else { return nil }
        guard let p = Plane(pgm: try Data(contentsOf: folder.appendingPathComponent(name))) else { throw RecordingError.badFile(name) }
        return p
    }

    public func depth(for f: RecordedFrame) throws -> DepthMap? {
        guard let name = f.depthFile else { return nil }
        guard let d = DepthMap(data: try Data(contentsOf: folder.appendingPathComponent(name))) else { throw RecordingError.badFile(name) }
        return d
    }
}

public enum RecordingError: Error, Equatable, LocalizedError {
    case badFile(String), notOpen
    /// the frame (index) has no recorded image
    case noImage(Int)
    /// the recording reached its size limit (bytes)
    case limitReached(Int64)

    public var errorDescription: String? {
        switch self {
        case .badFile(let f): return "the recording's file \(f) could not be read"
        case .notOpen: return "the recording is closed"
        case .noImage(let i): return "frame \(i) has no image"
        case .limitReached(let b): return "the recording reached its size limit (\(b / 1_000_000) MB)"
        }
    }
}

/// Writes a recording folder frame by frame. Not thread-safe: call from one queue.
///
/// Every write throws on failure (a full disk, any IO error); nothing here traps. After a failed write of the index
/// line the writer stays failed (later appends throw the same error), so frames.jsonl holds at most one cut-short line
/// at its end, which `RecordingReader` skips.
public final class RecordingWriter {
    public let folder: URL
    private var handle: FileHandle?
    private let enc: JSONEncoder
    private var failure: Error?
    public private(set) var frameCount = 0
    /// bytes written so far (session.json, frames.jsonl and the frames' files)
    public private(set) var bytesWritten: Int64 = 0
    /// Refuse a frame (throw `RecordingError.limitReached`, writing nothing of it) that would take the recording past this
    /// many bytes; nil: no limit. Keeps a recording well inside what the phone can zip and share.
    public var byteLimit: Int64?
    /// Keep ball finder images exactly (16-bit block sums for a shrunk crop, `Plane.pgmData(blockSum:)`); false: 8-bit,
    /// half the size, each pixel rounded to a whole grey level (a replay's ball finder then sees slightly different
    /// pixels from the phone's).
    public var exactBallImages = true

    public init(folder: URL, session: RecordingSession, byteLimit: Int64? = nil) throws {
        self.folder = folder
        self.byteLimit = byteLimit
        enc = RecordingWriter.encoder(pretty: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let s = try RecordingWriter.encoder(pretty: true).encode(session)
        try s.write(to: folder.appendingPathComponent("session.json"))
        bytesWritten = Int64(s.count)
        let lines = folder.appendingPathComponent("frames.jsonl")
        guard FileManager.default.createFile(atPath: lines.path, contents: nil) else { throw RecordingError.badFile("frames.jsonl") }
        handle = try FileHandle(forWritingTo: lines)
    }

    /// For tests: index lines go to `lines` (e.g. a handle that fails every write).
    init(folder: URL, session: RecordingSession, lines: FileHandle) throws {
        self.folder = folder
        enc = RecordingWriter.encoder(pretty: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingWriter.encoder(pretty: true).encode(session).write(to: folder.appendingPathComponent("session.json"))
        handle = lines
    }

    static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        // a degenerate readout must not stop the recording
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    /// Append a frame: its image (if any), depth, ball finder image and slab crop are written as files next to the
    /// index, then its line. The frame's index and file names are set here.
    public func append(_ frameIn: RecordedFrame, image: YCCImage?, depth: DepthMap? = nil, ball: Plane? = nil, slab: Plane? = nil) throws {
        if let e = failure { throw e }
        guard let h = handle else { throw RecordingError.notOpen }
        var frame = frameIn
        frame.index = frameCount
        let imageData = image?.data, depthData = depth?.data
        let exact = exactBallImages
        let ballData = ball.map { b -> Data in
            guard exact else { return b.pgmData() }
            // the crop's own shrink factor keeps its pixels exactly; otherwise the finest that does
            let k = [frame.ballCrop?.factor ?? 1, 1, 2, 3, 4].first { $0 >= 1 && $0 <= 16 && b.isBlockAverage(of: $0) } ?? 16
            return b.pgmData(blockSum: k)
        }
        // the slab crop the same way, with its own shrink factor
        let slabData = slab.map { b -> Data in
            guard exact else { return b.pgmData() }
            let k = [frame.output?.slabCrop?.factor ?? 1, 1, 2, 3, 4].first { $0 >= 1 && $0 <= 16 && b.isBlockAverage(of: $0) } ?? 16
            return b.pgmData(blockSum: k)
        }
        frame.file = imageData != nil ? String(format: "f%06d.byc", frameCount) : ""
        frame.depthFile = depthData != nil ? String(format: "d%06d.bdp", frameCount) : nil
        if depthData == nil { frame.depthIntrinsics = nil }
        frame.ballFile = ballData != nil ? String(format: "b%06d.pgm", frameCount) : nil
        frame.slabFile = slabData != nil ? String(format: "s%06d.pgm", frameCount) : nil
        var line = try enc.encode(frame)
        line.append(10)
        let fileBytes: Int = (imageData?.count ?? 0) + (depthData?.count ?? 0) + (slabData?.count ?? 0)
        let size = Int64(line.count + fileBytes + (ballData?.count ?? 0))
        if let limit = byteLimit, bytesWritten + size > limit { throw RecordingError.limitReached(limit) }
        if let d = imageData { try d.write(to: folder.appendingPathComponent(frame.file)) }
        if let d = depthData { try d.write(to: folder.appendingPathComponent(frame.depthFile!)) }
        if let d = ballData { try d.write(to: folder.appendingPathComponent(frame.ballFile!)) }
        if let d = slabData { try d.write(to: folder.appendingPathComponent(frame.slabFile!)) }
        do {
            try h.write(contentsOf: line)
        } catch {
            failure = error
            throw error
        }
        bytesWritten += size
        frameCount += 1
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}
