import Foundation

// The capture kit's per-clip files (CaptureKit.md, "Clip format"): frames.jsonl (KitFrame per video frame),
// motion.jsonl (KitMotionSample per CoreMotion update) and depth/dNNNNNN.bdp2 (KitDepth). The JSONL writer and reader
// are here too.

/// Errors reading or writing the kit's clip files.
public enum KitFormatError: Error, Equatable, CustomStringConvertible {
    /// a line of a JSONL file that is not the expected JSON (1-based line number)
    case badLine(file: String, line: Int)
    /// a depth file that is not BDP2, or is cut short
    case badDepth(String)
    /// a value that does not fit the format (e.g. a depth map wider than 65,535)
    case outOfRange(String)
    /// writing after close
    case closed

    public var description: String {
        switch self {
        case let .badLine(file, line): return "\(file): line \(line) is not valid"
        case let .badDepth(why): return "depth file: \(why)"
        case let .outOfRange(why): return "out of range: \(why)"
        case .closed: return "the file is closed"
        }
    }
}

/// The names of a shot's files inside its folder (shots/<shotId>/), for the app that writes them and the scorer that
/// reads them. Flat-phone shots have only `motion` and `shotManifest`.
public enum KitClipFiles {
    /// the frames, HEVC (or H.264) in an MP4 container
    public static let video = "video.mp4"
    /// one `KitFrame` per encoded video frame
    public static let frames = "frames.jsonl"
    /// one `KitMotionSample` per CoreMotion update
    public static let motion = "motion.jsonl"
    /// `KitShotManifest`
    public static let shotManifest = "shot.json"
    /// LiDAR depth files (`KitDepth`), named by `KitDepth.fileName(frame:)`
    public static let depthFolder = "depth"

    /// depth/dNNNNNN.bdp2 in a shot folder, for video frame `frame`
    public static func depthURL(shotFolder: URL, frame: Int) -> URL {
        depthURL(shotFolder: shotFolder, file: KitDepth.fileName(frame: frame))
    }

    /// depth/<file> in a shot folder (a `KitFrame.depthFile`)
    public static func depthURL(shotFolder: URL, file: String) -> URL {
        shotFolder.appendingPathComponent(depthFolder).appendingPathComponent(file)
    }
}

/// A unit quaternion (x, y, z, w), Hamilton convention: `a * b` rotates by b, then by a. As Codable it is the array
/// [x, y, z, w], like CoreMotion's `CMQuaternion`.
public struct KitQuaternion: Equatable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) { self.x = x; self.y = y; self.z = z; self.w = w }
    public static let identity = KitQuaternion(x: 0, y: 0, z: 0, w: 1)

    /// rotation by `angle` radians about `axis` (need not be unit)
    public init(axis: Vec3, angle: Double) {
        let u = axis.normalized, s = sin(angle / 2)
        self.init(x: u.x * s, y: u.y * s, z: u.z * s, w: cos(angle / 2))
    }

    /// rotation by a rotation vector (axis x angle, radians)
    public init(rotationVector r: Vec3) {
        let a = r.length
        self = a < 1e-15 ? .identity : KitQuaternion(axis: r, angle: a)
    }

    /// From a rotation matrix (Shepperd's method; the matrix should be orthonormal).
    public init(matrix m: Mat3) {
        let t = m[0, 0] + m[1, 1] + m[2, 2]
        if t > 0 {
            let s = (t + 1).squareRoot() * 2
            self.init(x: (m[2, 1] - m[1, 2]) / s, y: (m[0, 2] - m[2, 0]) / s, z: (m[1, 0] - m[0, 1]) / s, w: s / 4)
        } else if m[0, 0] > m[1, 1] && m[0, 0] > m[2, 2] {
            let s = max(1e-300, (1 + m[0, 0] - m[1, 1] - m[2, 2])).squareRoot() * 2
            self.init(x: s / 4, y: (m[0, 1] + m[1, 0]) / s, z: (m[0, 2] + m[2, 0]) / s, w: (m[2, 1] - m[1, 2]) / s)
        } else if m[1, 1] > m[2, 2] {
            let s = max(1e-300, (1 + m[1, 1] - m[0, 0] - m[2, 2])).squareRoot() * 2
            self.init(x: (m[0, 1] + m[1, 0]) / s, y: s / 4, z: (m[1, 2] + m[2, 1]) / s, w: (m[0, 2] - m[2, 0]) / s)
        } else {
            let s = max(1e-300, (1 + m[2, 2] - m[0, 0] - m[1, 1])).squareRoot() * 2
            self.init(x: (m[0, 2] + m[2, 0]) / s, y: (m[1, 2] + m[2, 1]) / s, z: s / 4, w: (m[1, 0] - m[0, 1]) / s)
        }
        self = normalized
    }

    public var norm: Double { (x * x + y * y + z * z + w * w).squareRoot() }
    public var normalized: KitQuaternion {
        let n = norm
        return n > 0 ? KitQuaternion(x: x / n, y: y / n, z: z / n, w: w / n) : .identity
    }
    public var conjugate: KitQuaternion { KitQuaternion(x: -x, y: -y, z: -z, w: w) }
    public var vector: Vec3 { Vec3(x, y, z) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
    public func dot(_ b: KitQuaternion) -> Double { x * b.x + y * b.y + z * b.z + w * b.w }

    public static func * (a: KitQuaternion, b: KitQuaternion) -> KitQuaternion {
        KitQuaternion(x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                      y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                      z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
                      w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    /// the rotation as a matrix (`matrix * v` == `rotate(v)`)
    public var matrix: Mat3 {
        let q = normalized
        let xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z, xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z
        let wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z
        return Mat3(rows: [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy),
                           2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx),
                           2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)])
    }

    public func rotate(_ v: Vec3) -> Vec3 { matrix * v }

    /// rotation angle in [0, pi] (radians)
    public var angle: Double { 2 * atan2(vector.length, abs(w)) }

    /// rotation vector (axis x angle, angle in [0, pi])
    public var rotationVector: Vec3 {
        let q = w < 0 ? KitQuaternion(x: -x, y: -y, z: -z, w: -w) : self
        let s = q.vector.length
        if s < 1e-15 { return .zero }
        return q.vector / s * (2 * atan2(s, q.w))
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let v = try (0..<4).map { _ in try c.decode(Double.self) }
        guard c.isAtEnd else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "a quaternion has 4 numbers") }
        self.init(x: v[0], y: v[1], z: v[2], w: v[3])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(z); try c.encode(w)
    }

    public var description: String { String(format: "(%.5f, %.5f, %.5f, %.5f)", x, y, z, w) }
}

/// ARKit's tracking state, as frames.jsonl spells it. Unknown "limited:" reasons read as `.limitedOther`, anything else
/// unknown as `.notAvailable`, so a newer app's files still read.
public enum KitTracking: String, Codable, CaseIterable {
    case normal
    case limitedInitializing = "limited:initializing"
    case limitedExcessiveMotion = "limited:excessiveMotion"
    case limitedInsufficientFeatures = "limited:insufficientFeatures"
    case limitedRelocalizing = "limited:relocalizing"
    case limitedOther = "limited:other"
    case notAvailable

    public var isNormal: Bool { self == .normal }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = KitTracking(rawValue: s) ?? (s.hasPrefix("limited") ? .limitedOther : .notAvailable)
    }
}

/// The live tracker's state as frames.jsonl spells it ("searching", "confirming", "locked"). Kits are captured once and
/// scored for a long time by newer code, so a state this build does not know reads as `.other` with its spelling kept
/// (and written back as it was), instead of making the whole clip unreadable.
public enum KitLiveState: Equatable, Codable, CustomStringConvertible {
    case searching, confirming, locked
    /// a state this build does not know, as spelled in the file
    case other(String)

    public init(rawValue s: String) {
        switch s {
        case "searching": self = .searching
        case "confirming": self = .confirming
        case "locked": self = .locked
        default: self = .other(s)
        }
    }

    /// From the tracker's own state (the app's live result).
    public init(_ t: TrackerState) {
        switch t {
        case .searching: self = .searching
        case .confirming: self = .confirming
        case .locked: self = .locked
        }
    }

    public var rawValue: String {
        switch self {
        case .searching: return "searching"
        case .confirming: return "confirming"
        case .locked: return "locked"
        case let .other(s): return s
        }
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The app's live result on one frame (what the owner saw on screen). When written, a non-finite tilt is left out, and
/// so are corners or a ball with any non-finite number (a degenerate pose on one frame must not stop the recording).
public struct KitLiveResult: Codable, Equatable {
    public var state: KitLiveState
    /// the slab's tilt the app showed (degrees)
    public var tilt: Double?
    /// the slab's four top corners in video pixels, outline order: [[x, y] x 4]
    public var corners: [[Double]]?
    /// the ball's image circle in video pixels: [x, y, r]
    public var ball: [Double]?

    enum CodingKeys: String, CodingKey { case state, tilt, corners, ball }

    /// `state`: `KitLiveState(tracker.state)` in the app.
    public init(state: KitLiveState, tilt: Double? = nil, corners: [Vec2]? = nil, ball: (center: Vec2, radius: Double)? = nil) {
        self.state = state; self.tilt = tilt
        self.corners = corners.map { $0.map { [$0.x, $0.y] } }
        self.ball = ball.map { [$0.center.x, $0.center.y, $0.radius] }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        if let t = tilt, t.isFinite { try c.encode(t, forKey: .tilt) }
        if let k = corners, k.allSatisfy({ $0.allSatisfy { $0.isFinite } }) { try c.encode(k, forKey: .corners) }
        if let b = ball, b.allSatisfy({ $0.isFinite }) { try c.encode(b, forKey: .ball) }
    }

    public var cornerPoints: [Vec2]? {
        guard let c = corners, c.count == 4, c.allSatisfy({ $0.count == 2 }) else { return nil }
        return c.map { Vec2($0[0], $0[1]) }
    }
    public var ballCircle: (center: Vec2, radius: Double)? {
        guard let b = ball, b.count == 3 else { return nil }
        return (Vec2(b[0], b[1]), b[2])
    }
    /// the slab was found on this frame (confirming or locked; a state this build does not know counts as not found)
    public var slabFound: Bool { state == .confirming || state == .locked }
}

/// One line of frames.jsonl: one encoded video frame. Short keys keep the file small (see the table in CaptureKit.md);
/// optional values are left out when nil, and non-finite optional numbers are left out too.
public struct KitFrame: Codable, Equatable {
    /// video frame number, from 0 (`i`)
    public var index: Int
    /// ARFrame timestamp, seconds of system uptime: the same clock as CoreMotion (`t`)
    public var time: Double
    /// world-from-camera, ARKit camera axes, column-major 4x4: ARKit's own Float values (`pose`)
    public var pose: [Float]
    /// [fx, fy, cx, cy] for the video frame's pixels (`K`)
    public var intrinsics: [Float]
    /// (`track`)
    public var tracking: KitTracking
    /// exposure duration, seconds (`exp`)
    public var exposure: Double?
    /// exposure offset, EV (`expOff`)
    public var exposureOffset: Double?
    /// ARKit's light estimate, ambient intensity in lumens (`amb`; about 1000 in a well-lit room)
    public var ambientLumens: Double?
    /// ambient colour temperature, kelvin (`ct`)
    public var colorTemperature: Double?
    /// mean luma 0-255 of this frame's camera image (`luma`; `KitImageStats.meanLuma(bytes:...)` on the Y plane, every
    /// recorded frame)
    public var luma: Double?
    /// estimated motion blur in video pixels (`blur`; `KitMotionBlur`)
    public var blur: Double?
    /// depth file name in the shot's depth/ folder, if this frame has one (`depth`; `KitClipFiles.depthURL`)
    public var depthFile: String?
    /// the app's live result (`live`)
    public var live: KitLiveResult?

    enum CodingKeys: String, CodingKey {
        case index = "i", time = "t", pose, intrinsics = "K", tracking = "track", exposure = "exp", exposureOffset = "expOff"
        case ambientLumens = "amb", colorTemperature = "ct", luma, blur, depthFile = "depth", live
    }

    public init(index: Int, time: Double, pose: [Float], intrinsics: [Float], tracking: KitTracking = .normal,
                exposure: Double? = nil, exposureOffset: Double? = nil, ambientLumens: Double? = nil, colorTemperature: Double? = nil,
                luma: Double? = nil, blur: Double? = nil, depthFile: String? = nil, live: KitLiveResult? = nil) {
        self.index = index; self.time = time; self.pose = pose; self.intrinsics = intrinsics; self.tracking = tracking
        self.exposure = exposure; self.exposureOffset = exposureOffset; self.ambientLumens = ambientLumens
        self.colorTemperature = colorTemperature; self.luma = luma; self.blur = blur; self.depthFile = depthFile; self.live = live
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func opt(_ v: Double?, _ k: CodingKeys) throws { if let v = v, v.isFinite { try c.encode(v, forKey: k) } }
        try c.encode(index, forKey: .index)
        try c.encode(time, forKey: .time)
        try c.encode(pose, forKey: .pose)
        try c.encode(intrinsics, forKey: .intrinsics)
        try c.encode(tracking, forKey: .tracking)
        try opt(exposure, .exposure); try opt(exposureOffset, .exposureOffset); try opt(ambientLumens, .ambientLumens)
        try opt(colorTemperature, .colorTemperature); try opt(luma, .luma); try opt(blur, .blur)
        try c.encodeIfPresent(depthFile, forKey: .depthFile)
        try c.encodeIfPresent(live, forKey: .live)
    }

    /// ARKit's world-from-camera transform (ARKit camera axes); nil unless `pose` holds 16 finite numbers.
    public var worldFromCamera: RigidTransform? {
        guard pose.count == 16, pose.allSatisfy({ $0.isFinite }) else { return nil }
        return RigidTransform(columnMajor4x4: pose.map(Double.init))
    }

    /// The video frame's intrinsics; nil unless `K` holds 4 finite numbers.
    public func cameraIntrinsics(videoWidth: Int, videoHeight: Int) -> CameraIntrinsics? {
        guard intrinsics.count == 4, intrinsics.allSatisfy({ $0.isFinite }) else { return nil }
        return CameraIntrinsics(fx: Double(intrinsics[0]), fy: Double(intrinsics[1]), cx: Double(intrinsics[2]), cy: Double(intrinsics[3]),
                                width: videoWidth, height: videoHeight)
    }

    /// The camera view in BounceCore's CV axes, for the detectors and the tracker.
    public func view(videoWidth: Int, videoHeight: Int) -> CameraView? {
        guard let t = worldFromCamera, let k = cameraIntrinsics(videoWidth: videoWidth, videoHeight: videoHeight) else { return nil }
        return CameraView(worldFromCamera: ARKitConvention.worldFromCVCamera(arkitCameraTransform: t), intrinsics: k)
    }

    /// This frame's depth file in a shot folder, if it has one.
    public func depthURL(shotFolder: URL) -> URL? { depthFile.map { KitClipFiles.depthURL(shotFolder: shotFolder, file: $0) } }
}

/// One line of motion.jsonl: one CoreMotion device-motion update, device axes (x right, y toward the top, z out of the
/// screen), reference frame `xArbitraryZVertical`.
///
/// JSON: `{"t": s, "g": [x,y,z], "ua": [x,y,z], "rr": [x,y,z], "q": [x,y,z,w]}`. Numbers are written rounded (time to
/// 10 microseconds, vectors to 1e-6, the quaternion to 1e-7), far below the sensors' noise, to keep lines short.
public struct KitMotionSample: Codable, Equatable {
    /// CMDeviceMotion timestamp, seconds of system uptime (the same clock as ARFrame.timestamp)
    public var time: Double
    /// gravity (units of g)
    public var gravity: Vec3
    /// user acceleration (units of g)
    public var userAcceleration: Vec3
    /// rotation rate (rad/s)
    public var rotationRate: Vec3
    /// `CMAttitude.quaternion` as given: the rotation taking device-axes vectors into the reference frame
    /// (`v_ref = q v_device q*`). `KitFlatTilt` checks this convention against gravity and copes with the opposite one.
    public var attitude: KitQuaternion

    enum CodingKeys: String, CodingKey { case time = "t", gravity = "g", userAcceleration = "ua", rotationRate = "rr", attitude = "q" }

    public init(time: Double, gravity: Vec3, userAcceleration: Vec3 = .zero, rotationRate: Vec3 = .zero, attitude: KitQuaternion = .identity) {
        self.time = time; self.gravity = gravity; self.userAcceleration = userAcceleration; self.rotationRate = rotationRate; self.attitude = attitude
    }

    static func round(_ v: Double, _ scale: Double) -> Double { (v * scale).rounded() / scale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func vec(_ k: CodingKeys) throws -> Vec3 {
            let a = try c.decode([Double].self, forKey: k)
            guard a.count == 3 else { throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "expected 3 numbers") }
            return Vec3(a[0], a[1], a[2])
        }
        time = try c.decode(Double.self, forKey: .time)
        gravity = try vec(.gravity)
        userAcceleration = try vec(.userAcceleration)
        rotationRate = try vec(.rotationRate)
        attitude = try c.decode(KitQuaternion.self, forKey: .attitude)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func vec(_ v: Vec3) -> [Double] { [v.x, v.y, v.z].map { Self.round($0, 1e6) } }
        try c.encode(Self.round(time, 1e5), forKey: .time)
        try c.encode(vec(gravity), forKey: .gravity)
        try c.encode(vec(userAcceleration), forKey: .userAcceleration)
        try c.encode(vec(rotationRate), forKey: .rotationRate)
        try c.encode([attitude.x, attitude.y, attitude.z, attitude.w].map { Self.round($0, 1e7) }, forKey: .attitude)
    }
}

/// Appends JSON lines to a file through a buffer (one `write` per ~64 KB, not per line). Not thread-safe: call from one
/// queue. Errors writing the file throw; `close()` flushes. Lines are compact JSON with sorted keys.
public final class KitJSONLWriter {
    public let url: URL
    public private(set) var lineCount = 0
    private var handle: FileHandle?
    private var buffer = Data()
    private let bufferLimit: Int
    private let encoder: JSONEncoder

    /// Creates (or empties) the file.
    public init(url: URL, bufferSize: Int = 64 * 1024) throws {
        self.url = url
        bufferLimit = max(1, bufferSize)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(bufferLimit + 1024)
    }

    /// Encode one value as a line. Throws if it cannot be encoded (e.g. a NaN) or the buffer cannot be written.
    public func append<T: Encodable>(_ value: T) throws {
        guard handle != nil else { throw KitFormatError.closed }
        var line = try encoder.encode(value)
        line.append(10)
        buffer.append(line)
        lineCount += 1
        if buffer.count >= bufferLimit { try flush() }
    }

    /// Write out the buffer.
    public func flush() throws {
        guard let h = handle else { throw KitFormatError.closed }
        guard !buffer.isEmpty else { return }
        try h.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// Flush and close. Closing twice is fine.
    public func close() throws {
        guard let h = handle else { return }
        defer { handle = nil }
        try flush()
        try h.close()
    }

    deinit { try? close() }
}

/// Reads JSONL files.
public enum KitJSONL {
    /// Decode every line. A last line cut short (no newline at the end and not valid JSON: the app was killed while
    /// writing it) is dropped; any other bad line throws `KitFormatError.badLine`. Blank lines are skipped.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, name: String = "jsonl") throws -> (items: [T], droppedLastLine: Bool) {
        let dec = JSONDecoder()
        var items: [T] = []
        let bytes = [UInt8](data)
        var start = 0, lineNo = 0
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 10 { end += 1 }
            lineNo += 1
            let terminated = end < bytes.count
            let line = bytes[start..<end]
            start = end + 1
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            do {
                items.append(try dec.decode(T.self, from: Data(line)))
            } catch {
                if !terminated { return (items, true) }
                throw KitFormatError.badLine(file: name, line: lineNo)
            }
        }
        return (items, false)
    }

    /// Read a JSONL file (see `decode`).
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        try decode(type, from: Data(contentsOf: url), name: url.lastPathComponent).items
    }
}

/// LiDAR depth in the kit's compact format ("BDP2"): the magic "BDP2", width and height as little-endian UInt16, then
/// width x height little-endian UInt16 depths in millimetres (0 = no depth), then width x height confidence bytes (ARKit:
/// 0 low, 1 medium, 2 high). A third of the size of the debug recordings' BDP1. Depths beyond 65.535 m, at or below 0,
/// and NaN or infinite ones are stored as 0 (none).
public struct KitDepth: Equatable {
    public let width: Int
    public let height: Int
    public var millimetres: [UInt16]
    public var confidence: [UInt8]

    public static let magic: [UInt8] = [66, 68, 80, 50] // "BDP2"

    public init(width: Int, height: Int, millimetres: [UInt16], confidence: [UInt8]) throws {
        guard width > 0, height > 0, width <= 65535, height <= 65535 else {
            throw KitFormatError.outOfRange("depth size \(width)x\(height)")
        }
        guard millimetres.count == width * height, confidence.count == width * height else {
            throw KitFormatError.badDepth("expected \(width * height) values")
        }
        self.width = width; self.height = height; self.millimetres = millimetres; self.confidence = confidence
    }

    /// From a depth map in metres.
    public init(depthMap d: DepthMap) throws {
        try self.init(width: d.width, height: d.height, millimetres: d.depth.map(KitDepth.millimetres(fromMetres:)), confidence: d.confidence)
    }

    /// Metres to the stored millimetres (0 for no depth or out of range).
    public static func millimetres(fromMetres m: Float) -> UInt16 {
        guard m.isFinite, m > 0 else { return 0 }
        let mm = (Double(m) * 1000).rounded()
        return mm > 65535 ? 0 : UInt16(mm)
    }

    /// Parse a BDP2 file.
    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 8, Array(b[0..<4]) == KitDepth.magic else { throw KitFormatError.badDepth("not BDP2") }
        let w = Int(b[4]) | Int(b[5]) << 8, h = Int(b[6]) | Int(b[7]) << 8, n = w * h
        guard w > 0, h > 0 else { throw KitFormatError.badDepth("empty") }
        guard b.count >= 8 + n * 3 else { throw KitFormatError.badDepth("cut short") }
        var mm = [UInt16](repeating: 0, count: n)
        for i in 0..<n { mm[i] = UInt16(b[8 + 2 * i]) | UInt16(b[9 + 2 * i]) << 8 }
        try self.init(width: w, height: h, millimetres: mm, confidence: Array(b[(8 + 2 * n)..<(8 + 3 * n)]))
    }

    public var data: Data {
        var d = Data(KitDepth.magic)
        d.reserveCapacity(8 + millimetres.count * 3)
        d.append(contentsOf: [UInt8(width & 255), UInt8(width >> 8), UInt8(height & 255), UInt8(height >> 8)])
        var raw = [UInt8](repeating: 0, count: millimetres.count * 2)
        for (i, v) in millimetres.enumerated() { raw[2 * i] = UInt8(v & 255); raw[2 * i + 1] = UInt8(v >> 8) }
        d.append(contentsOf: raw)
        d.append(contentsOf: confidence)
        return d
    }

    /// As a depth map in metres (0 mm reads as NaN: no depth).
    public var depthMap: DepthMap {
        DepthMap(width: width, height: height, depth: millimetres.map { $0 == 0 ? Float.nan : Float($0) / 1000 }, confidence: confidence)
    }

    /// The depth map's intrinsics: the video frame's, scaled by depth width / video width.
    public func intrinsics(video k: CameraIntrinsics) -> CameraIntrinsics {
        let s = Double(width) / Double(k.width)
        return CameraIntrinsics(fx: k.fx * s, fy: k.fy * s, cx: k.cx * s, cy: k.cy * s, width: width, height: height)
    }

    /// "d000123.bdp2" for video frame 123
    public static func fileName(frame: Int) -> String { String(format: "d%06d.bdp2", frame) }
}
