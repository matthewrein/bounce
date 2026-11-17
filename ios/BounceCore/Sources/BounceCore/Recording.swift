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
    public var reboundPercent: Double
    /// launch the ball along the dish's normal where it lands (Settings' "dish bounce"), not the corner plane's; nil in
    /// version 1 recordings (which did not say: the corner plane)
    public var dishBounce: Bool?

    public init(sideUInches: Double = 7, sideVInches: Double = 7, thicknessInches: Double = 1, dishInches: Double = 0.125,
                ballDiameterMm: Double = 35, dropHeightFeet: Double = 3, reboundPercent: Double = 70, dishBounce: Bool? = nil) {
        self.sideUInches = sideUInches; self.sideVInches = sideVInches; self.thicknessInches = thicknessInches; self.dishInches = dishInches
        self.ballDiameterMm = ballDiameterMm; self.dropHeightFeet = dropHeightFeet; self.reboundPercent = reboundPercent
        self.dishBounce = dishBounce
    }

    /// how often the app searches for the slab while it has none (s): the search costs tens of ms on the phone
    public static let appSearchInterval = 0.12

    /// The tracker settings the app runs with for these settings (AppSettings.tracker should use this, so the app and
    /// a replay of an older recording build them the same way).
    public var trackerSettings: TrackerSettings {
        var t = TrackerSettings()
        t.spec = slab
        t.ball = ball
        t.defaultDropHeight = dropHeight
        t.launchRule = launchRule
        t.searchInterval = RecordingSettings.appSearchInterval
        return t
    }

    public var launchRule: Bounce.LaunchRule { dishBounce == true ? .dishNormal : .cornerPlane }

    public var slab: SlabSpec {
        SlabSpec(sideU: Units.inches(sideUInches), sideV: Units.inches(sideVInches), thickness: Units.inches(thicknessInches), dishDepth: Units.inches(dishInches))
    }
    public var ball: BallSpec { BallSpec(diameter: ballDiameterMm / 1000, rebound: reboundPercent / 100) }
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
    public var ballCrop: BallCrop?
    /// the tracker's result on the phone for this frame (what a replay is compared with)
    public var output: RecordedOutput?

    public init(index: Int, timestamp: Double, file: String, worldFromCamera: [Double], intrinsics: CameraIntrinsics, trackingNormal: Bool = true) {
        self.index = index; self.timestamp = timestamp; self.file = file; self.worldFromCamera = worldFromCamera
        self.intrinsics = intrinsics; self.trackingNormal = trackingNormal
    }

    /// The record of a frame the tracker processed: its camera (as ARKit's transform), gravity, tracking state, tap,
    /// floor height, the controls before it and the tracker's output. The app adds motion and exposure; the writer sets
    /// the index and files. `ballCrop`: where the ball finder's image was cut from, if the frame had one.
    public init(processed tf: TrackerFrame, output: TrackerOutput, ballCrop: BallCrop? = nil) {
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
    public var colorFrame: ColorFrame {
        ColorFrame(lumaFull: luma, cbHalf: Plane(bytes: cb, width: chromaWidth, height: chromaHeight),
                   crHalf: Plane(bytes: cr, width: chromaWidth, height: chromaHeight), scale: 1)
    }

    /// Build from separate luma and interleaved CbCr planes (as a CVPixelBuffer's two planes), downscaling by an integer
    /// factor k (luma averaged over k x k blocks, chroma over (k/2) x (k/2) blocks of the half-size plane).
    public static func fromBiplanar(luma: UnsafeBufferPointer<UInt8>, lumaWidth W: Int, lumaHeight H: Int, lumaBytesPerRow lb: Int,
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
        // chroma: output chroma pixel (cx, cy) covers luma pixels [2cx*k, 2cx*k + 2k) -> half-size chroma [cx*k, cx*k + k)
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
        var d = Data([66, 68, 80, 49, UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
        d.reserveCapacity(8 + depth.count * 5)
        for v in depth { let u = v.bitPattern; d.append(contentsOf: [UInt8(u & 255), UInt8((u >> 8) & 255), UInt8((u >> 16) & 255), UInt8(u >> 24)]) }
        d.append(contentsOf: confidence)
        return d
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

    /// Append a frame: its image (if any), depth and ball finder image are written as files next to the index, then its
    /// line. The frame's index and file names are set here.
    public func append(_ frameIn: RecordedFrame, image: YCCImage?, depth: DepthMap? = nil, ball: Plane? = nil) throws {
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
        frame.file = imageData != nil ? String(format: "f%06d.byc", frameCount) : ""
        frame.depthFile = depthData != nil ? String(format: "d%06d.bdp", frameCount) : nil
        if depthData == nil { frame.depthIntrinsics = nil }
        frame.ballFile = ballData != nil ? String(format: "b%06d.pgm", frameCount) : nil
        var line = try enc.encode(frame)
        line.append(10)
        let fileBytes: Int = (imageData?.count ?? 0) + (depthData?.count ?? 0)
        let size = Int64(line.count + fileBytes + (ballData?.count ?? 0))
        if let limit = byteLimit, bytesWritten + size > limit { throw RecordingError.limitReached(limit) }
        if let d = imageData { try d.write(to: folder.appendingPathComponent(frame.file)) }
        if let d = depthData { try d.write(to: folder.appendingPathComponent(frame.depthFile!)) }
        if let d = ballData { try d.write(to: folder.appendingPathComponent(frame.ballFile!)) }
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
