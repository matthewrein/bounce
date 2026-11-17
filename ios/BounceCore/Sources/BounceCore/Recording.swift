import Foundation

/// A recorded session: what the camera saw and where it was, frame by frame, so a session on the phone can be replayed
/// through the same detector and maths on any computer (`swift test`).
///
/// On disk a recording is a folder `<name>.bouncerec/` holding
///   - `session.json`  `RecordingSession`: build, device, settings, frame size
///   - `frames.jsonl`  one `RecordedFrame` per line
///   - `f<NNNNNN>.byc` the frame's image: luma plus half-size chroma (`YCCImage`, format "BYC1")
///   - `d<NNNNNN>.bdp` optional LiDAR depth (`DepthMap`, format "BDP1")
/// The app shares it as a single zip (`ZipWriter`). Recordings can show the owner's surroundings: they are private and
/// are never committed to the repository.
public struct RecordingSession: Codable, Equatable {
    public var format: String = "bouncerec"
    public var version: Int = 1
    public var build: String
    public var device: String
    public var frameWidth: Int
    public var frameHeight: Int
    public var settings: RecordingSettings
    public var notes: String?
    public var createdAt: String?

    public init(build: String, device: String, frameWidth: Int, frameHeight: Int, settings: RecordingSettings, notes: String? = nil, createdAt: String? = nil) {
        self.build = build; self.device = device; self.frameWidth = frameWidth; self.frameHeight = frameHeight
        self.settings = settings; self.notes = notes; self.createdAt = createdAt
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

    public init(sideUInches: Double = 7, sideVInches: Double = 7, thicknessInches: Double = 1, dishInches: Double = 0.125,
                ballDiameterMm: Double = 35, dropHeightFeet: Double = 3, reboundPercent: Double = 70) {
        self.sideUInches = sideUInches; self.sideVInches = sideVInches; self.thicknessInches = thicknessInches; self.dishInches = dishInches
        self.ballDiameterMm = ballDiameterMm; self.dropHeightFeet = dropHeightFeet; self.reboundPercent = reboundPercent
    }

    public var slab: SlabSpec {
        SlabSpec(sideU: Units.inches(sideUInches), sideV: Units.inches(sideVInches), thickness: Units.inches(thicknessInches), dishDepth: Units.inches(dishInches))
    }
    public var ball: BallSpec { BallSpec(diameter: ballDiameterMm / 1000, rebound: reboundPercent / 100) }
    public var dropHeight: Double { Units.feet(dropHeightFeet) }
}

/// One frame's record. Camera poses are ARKit's `camera.transform` (world-from-camera, ARKit camera axes, metres,
/// gravity-aligned world with y up), column-major. Intrinsics describe the stored frame image (not the full camera image).
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
    /// LiDAR depth file for this frame, and the intrinsics of the depth map (optional)
    public var depthFile: String?
    public var depthIntrinsics: CameraIntrinsics?

    public init(index: Int, timestamp: Double, file: String, worldFromCamera: [Double], intrinsics: CameraIntrinsics, trackingNormal: Bool = true) {
        self.index = index; self.timestamp = timestamp; self.file = file; self.worldFromCamera = worldFromCamera
        self.intrinsics = intrinsics; self.trackingNormal = trackingNormal
    }

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
}

/// Reads a recording folder.
public struct RecordingReader {
    public let folder: URL
    public let session: RecordingSession
    public let frames: [RecordedFrame]

    public init(folder: URL) throws {
        self.folder = folder
        let dec = JSONDecoder()
        session = try dec.decode(RecordingSession.self, from: Data(contentsOf: folder.appendingPathComponent("session.json")))
        let text = try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        frames = try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try dec.decode(RecordedFrame.self, from: Data($0.utf8)) }
    }

    public func image(for f: RecordedFrame) throws -> YCCImage {
        guard let img = YCCImage(data: try Data(contentsOf: folder.appendingPathComponent(f.file))) else {
            throw RecordingError.badFile(f.file)
        }
        return img
    }

    public func depth(for f: RecordedFrame) throws -> DepthMap? {
        guard let name = f.depthFile else { return nil }
        guard let d = DepthMap(data: try Data(contentsOf: folder.appendingPathComponent(name))) else { throw RecordingError.badFile(name) }
        return d
    }
}

public enum RecordingError: Error, Equatable { case badFile(String), notOpen }

/// Writes a recording folder frame by frame. Not thread-safe: call from one queue.
public final class RecordingWriter {
    public let folder: URL
    private var handle: FileHandle?
    private let enc: JSONEncoder
    public private(set) var frameCount = 0

    public init(folder: URL, session: RecordingSession) throws {
        self.folder = folder
        enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pretty = JSONEncoder(); pretty.outputFormatting = [.sortedKeys, .prettyPrinted]
        try pretty.encode(session).write(to: folder.appendingPathComponent("session.json"))
        let lines = folder.appendingPathComponent("frames.jsonl")
        _ = FileManager.default.createFile(atPath: lines.path, contents: nil)
        handle = try FileHandle(forWritingTo: lines)
    }

    /// Append a frame (its image and optional depth are written as files next to the index).
    public func append(_ frameIn: RecordedFrame, image: YCCImage, depth: DepthMap? = nil) throws {
        guard let h = handle else { throw RecordingError.notOpen }
        var frame = frameIn
        frame.index = frameCount
        frame.file = String(format: "f%06d.byc", frameCount)
        try image.data.write(to: folder.appendingPathComponent(frame.file))
        if let d = depth {
            frame.depthFile = String(format: "d%06d.bdp", frameCount)
            try d.data.write(to: folder.appendingPathComponent(frame.depthFile!))
        } else {
            frame.depthFile = nil
        }
        var line = try enc.encode(frame)
        line.append(10)
        h.write(line)
        frameCount += 1
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}
