import Foundation

// The kit's manifests (CaptureKit.md): kit.json (`KitManifest`, the whole kit, updated after every shot) and
// shots/<shotId>/shot.json (`KitShotManifest`, one clip). Plain numbers and strings; no device name, no location, no
// account details. Times are ISO-8601 strings in UTC, made from a Date the caller passes in (no hidden clocks).

/// Time stamps and kit ids.
public enum KitTime {
    static func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) { c.timeZone = utc }
        return c
    }

    /// "2026-11-17T15:30:00Z"
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    public static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// "slab-kit-20261117-153000" (UTC, so the id says nothing about where the owner lives)
    public static func kitId(for date: Date) -> String {
        let c = utcCalendar().dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "slab-kit-%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

/// The owner's measurements (step 1), in the owner's units.
public struct KitMeasurements: Codable, Equatable {
    /// slab top, side to side (inches)
    public var slabWidthInches: Double
    /// slab top, front to back (inches)
    public var slabDepthInches: Double
    /// thickness at an edge (inches)
    public var slabThicknessInches: Double
    /// how far the middle of the top lies below a straightedge across it (inches); nil if not measured
    public var dishInches: Double?
    /// ball diameter (mm)
    public var ballDiameterMm: Double

    public init(slabWidthInches: Double, slabDepthInches: Double, slabThicknessInches: Double, dishInches: Double?, ballDiameterMm: Double) {
        self.slabWidthInches = slabWidthInches; self.slabDepthInches = slabDepthInches; self.slabThicknessInches = slabThicknessInches
        self.dishInches = dishInches; self.ballDiameterMm = ballDiameterMm
    }

    /// Pre-filled from the app's settings.
    public init(settings s: RecordingSettings) {
        self.init(slabWidthInches: s.sideUInches, slabDepthInches: s.sideVInches, slabThicknessInches: s.thicknessInches,
                  dishInches: s.dishInches, ballDiameterMm: s.ballDiameterMm)
    }

    /// The ranges the app's Settings accept.
    public static let sideRange: ClosedRange<Double> = 3...20
    public static let thicknessRange: ClosedRange<Double> = 0.2...4
    public static let dishRange: ClosedRange<Double> = 0...0.75
    public static let ballRange: ClosedRange<Double> = 5...120

    /// What is wrong, in plain English (empty when every value is in range).
    public var problems: [String] {
        func check(_ v: Double, _ r: ClosedRange<Double>, _ what: String, _ unit: String) -> String? {
            guard v.isFinite, r.contains(v) else {
                return "\(what) must be between \(Self.fmt(r.lowerBound)) and \(Self.fmt(r.upperBound)) \(unit)."
            }
            return nil
        }
        var p: [String] = []
        if let m = check(slabWidthInches, Self.sideRange, "The slab's width", "inches") { p.append(m) }
        if let m = check(slabDepthInches, Self.sideRange, "The slab's depth", "inches") { p.append(m) }
        if let m = check(slabThicknessInches, Self.thicknessRange, "The slab's thickness", "inches") { p.append(m) }
        if let d = dishInches, let m = check(d, Self.dishRange, "The dish depth", "inches") { p.append(m) }
        if let m = check(ballDiameterMm, Self.ballRange, "The ball's diameter", "mm") { p.append(m) }
        return p
    }

    public var isValid: Bool { problems.isEmpty }

    static func fmt(_ v: Double) -> String { v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v) }

    /// The slab in metres (an unmeasured dish counts as the app's default, 1/8 in).
    public var slab: SlabSpec {
        SlabSpec(sideU: Units.inches(slabWidthInches), sideV: Units.inches(slabDepthInches), thickness: Units.inches(slabThicknessInches),
                 dishDepth: Units.inches(dishInches ?? RecordingSettings().dishInches))
    }

    /// The ball in metres, with a rebound (the kit does not measure it).
    public func ball(rebound: Double = RecordingSettings().reboundPercent / 100) -> BallSpec {
        BallSpec(diameter: ballDiameterMm / 1000, rebound: rebound)
    }

    /// The app's settings with these measurements (drop height and rebound kept from `base`; an unmeasured dish too).
    public func recordingSettings(base: RecordingSettings = RecordingSettings()) -> RecordingSettings {
        var s = base
        s.sideUInches = slabWidthInches; s.sideVInches = slabDepthInches; s.thicknessInches = slabThicknessInches
        if let d = dishInches { s.dishInches = d }
        s.ballDiameterMm = ballDiameterMm
        return s
    }
}

/// An ARKit video format.
public struct KitCameraFormat: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public init(width: Int, height: Int, fps: Double) { self.width = width; self.height = height; self.fps = fps }
}

/// The phone, without anything that identifies the owner: no device name.
public struct KitDevice: Codable, Equatable {
    /// hardware model identifier, like "iPhone16,1"
    public var modelIdentifier: String
    /// iOS version, like "18.1"
    public var systemVersion: String
    /// scene depth (LiDAR) is available
    public var hasLiDAR: Bool
    /// the ARKit video format chosen for ordinary shots
    public var cameraFormat: KitCameraFormat?
    /// the format chosen for high-frame-rate shots (drops)
    public var highFrameRateFormat: KitCameraFormat?

    public init(modelIdentifier: String, systemVersion: String, hasLiDAR: Bool, cameraFormat: KitCameraFormat? = nil,
                highFrameRateFormat: KitCameraFormat? = nil) {
        self.modelIdentifier = modelIdentifier; self.systemVersion = systemVersion; self.hasLiDAR = hasLiDAR
        self.cameraFormat = cameraFormat; self.highFrameRateFormat = highFrameRateFormat
    }
}

/// The encoded video of one shot.
public struct KitVideoInfo: Codable, Equatable {
    /// "hevc" or "h264"
    public var codec: String
    public var width: Int
    public var height: Int
    /// frames per second kept in the file
    public var fps: Double
    /// target bitrate (bits per second)
    public var bitrate: Int
    public var frameCount: Int
    public var fileBytes: Int64

    public init(codec: String, width: Int, height: Int, fps: Double, bitrate: Int, frameCount: Int, fileBytes: Int64) {
        self.codec = codec; self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
        self.frameCount = frameCount; self.fileBytes = fileBytes
    }
}

/// A slab position: where the slab lay from one flat-phone shot to the next.
public struct KitSlabPosition: Codable, Equatable {
    /// "p1", "p2", ... (from the plan)
    public var id: String
    /// "level", "tilt 1", ...
    public var label: String
    /// the flat-phone shot that started it
    public var shotId: String
    /// the slab's true tilt here; nil if the flat-phone shot was skipped or failed
    public var groundTruth: KitTrueTilt?
    /// when it started (ISO)
    public var startedAt: String?

    public init(id: String, label: String, shotId: String, groundTruth: KitTrueTilt? = nil, startedAt: String? = nil) {
        self.id = id; self.label = label; self.shotId = shotId; self.groundTruth = groundTruth; self.startedAt = startedAt
    }
}

/// Where a shot stands.
public enum KitShotStatus: String, Codable { case pending, captured, skipped }

/// One shot's line in kit.json.
public struct KitShotRecord: Codable, Equatable {
    public var id: String
    public var step: Int
    public var status: KitShotStatus
    /// committed attempts (a retry that is committed counts again)
    public var attempts: Int
    /// "shots/<id>" once captured (nil for the form and for shots not captured)
    public var folder: String?
    /// the slab position it belongs to
    public var positionId: String?
    public var verdict: KitVerdict?
    /// the measured height of the ball's bottom above the slab (inches), if the owner entered one
    public var enteredHeightInches: Double?
    /// recording length (s)
    public var duration: Double?
    /// video frames (or motion samples for a flat-phone shot)
    public var frames: Int?
    /// bytes on disk
    public var bytes: Int64?
    /// when it was captured (ISO)
    public var capturedAt: String?
    /// the plan marks it optional
    public var optional: Bool

    public init(id: String, step: Int, status: KitShotStatus = .pending, attempts: Int = 0, folder: String? = nil, positionId: String? = nil,
                verdict: KitVerdict? = nil, enteredHeightInches: Double? = nil, duration: Double? = nil, frames: Int? = nil,
                bytes: Int64? = nil, capturedAt: String? = nil, optional: Bool = false) {
        self.id = id; self.step = step; self.status = status; self.attempts = attempts; self.folder = folder; self.positionId = positionId
        self.verdict = verdict; self.enteredHeightInches = enteredHeightInches; self.duration = duration; self.frames = frames
        self.bytes = bytes; self.capturedAt = capturedAt; self.optional = optional
    }
}

/// kit.json: the whole kit. Updated after every shot; the authority on positions and statuses (shot.json files carry
/// copies made at capture time).
public struct KitManifest: Codable, Equatable {
    public static let formatName = "bouncekit"
    public static let currentVersion = 1

    public var format: String = KitManifest.formatName
    public var version: Int = KitManifest.currentVersion
    /// "slab-kit-20261117-153000": also the kit's folder name
    public var kitId: String
    public var planId: String
    /// the plan's time scale when it is not 1 (UI tests)
    public var timeScale: Double?
    /// the app's build label
    public var build: String
    public var createdAt: String
    public var updatedAt: String
    public var finishedAt: String?
    public var device: KitDevice
    public var measurements: KitMeasurements
    /// slab positions started so far, in plan order, with their true tilts
    public var positions: [KitSlabPosition]
    /// one record per shot, in plan order
    public var shots: [KitShotRecord]
    /// the level hold-still shot's median luma: the reference for the dim and bright shots
    public var lightReferenceLuma: Double?
    public var notes: String?

    public init(kitId: String, planId: String, timeScale: Double? = nil, build: String, createdAt: String, device: KitDevice,
                measurements: KitMeasurements, positions: [KitSlabPosition] = [], shots: [KitShotRecord] = []) {
        self.kitId = kitId; self.planId = planId; self.timeScale = timeScale; self.build = build; self.createdAt = createdAt
        self.updatedAt = createdAt; self.device = device; self.measurements = measurements; self.positions = positions; self.shots = shots
    }

    public func record(_ id: String) -> KitShotRecord? { shots.first { $0.id == id } }
    public func position(_ id: String) -> KitSlabPosition? { positions.first { $0.id == id } }
    public var isFinished: Bool { finishedAt != nil }
}

/// shot.json: one clip.
public struct KitShotManifest: Codable, Equatable {
    public static let formatName = "bouncekit-shot"

    public var format: String = KitShotManifest.formatName
    public var version: Int = KitManifest.currentVersion
    public var kitId: String
    public var shotId: String
    public var step: Int
    /// 1 for the first committed attempt, 2 after a retry, ...
    public var attempt: Int
    /// when the recording started (ISO)
    public var startedAt: String
    /// recording length (s)
    public var duration: Double
    public var build: String
    public var device: KitDevice
    public var measurements: KitMeasurements
    /// the slab position and its true tilt (copied from kit.json at capture time)
    public var positionId: String?
    public var trueTilt: KitTrueTilt?
    /// the video (nil for flat-phone shots)
    public var video: KitVideoInfo?
    /// the ARKit camera format it was recorded with (full size)
    public var cameraFormat: KitCameraFormat?
    /// LiDAR depth files are present
    public var hasDepth: Bool
    public var depthFrames: Int?
    public var motionSamples: Int?
    /// the measured height of the ball's bottom above the slab (inches)
    public var enteredHeightInches: Double?
    public var quality: KitQualityReport?
    /// drops: seconds after the start when the app beeped to let go
    public var releaseCue: Double?
    /// flat-phone shots: the result
    public var flat: KitTrueTilt?
    public var notes: String?

    public init(kitId: String, shotId: String, step: Int, attempt: Int, startedAt: String, duration: Double, build: String,
                device: KitDevice, measurements: KitMeasurements, positionId: String? = nil, trueTilt: KitTrueTilt? = nil,
                video: KitVideoInfo? = nil, cameraFormat: KitCameraFormat? = nil, hasDepth: Bool = false, depthFrames: Int? = nil,
                motionSamples: Int? = nil, enteredHeightInches: Double? = nil, quality: KitQualityReport? = nil,
                releaseCue: Double? = nil, flat: KitTrueTilt? = nil, notes: String? = nil) {
        self.kitId = kitId; self.shotId = shotId; self.step = step; self.attempt = attempt; self.startedAt = startedAt
        self.duration = duration; self.build = build; self.device = device; self.measurements = measurements
        self.positionId = positionId; self.trueTilt = trueTilt; self.video = video; self.cameraFormat = cameraFormat
        self.hasDepth = hasDepth; self.depthFrames = depthFrames; self.motionSamples = motionSamples
        self.enteredHeightInches = enteredHeightInches; self.quality = quality; self.releaseCue = releaseCue; self.flat = flat; self.notes = notes
    }
}

/// JSON coding for the manifests: pretty, sorted keys (stable diffs, readable on a phone).
public enum KitJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
    public static func encode<T: Encodable>(_ v: T) throws -> Data { try encoder().encode(v) }
    public static func decode<T: Decodable>(_ t: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(t, from: data) }
}
