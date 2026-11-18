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

    /// Pre-filled from the app's settings, for the form and for a kit whose step 1 is not done yet. The dish is left
    /// empty (nil): the settings always hold one, usually the default, and a value the owner did not measure must not
    /// be recorded as if they had.
    public init(settings s: RecordingSettings) {
        self.init(slabWidthInches: s.sideUInches, slabDepthInches: s.sideVInches, slabThicknessInches: s.thicknessInches,
                  dishInches: nil, ballDiameterMm: s.ballDiameterMm)
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

/// A slab position: where the slab lay from one flat-phone shot to the next. If the slab was set up again for the same
/// plan position (the owner said it had moved, on resume: `KitStore.restartPosition`), that is a new **generation** with
/// its own entry and true tilt: "p2" is the first, "p2#2" the second, and so on. Shots keep the generation they were
/// captured in.
public struct KitSlabPosition: Codable, Equatable {
    /// "p1", "p2", ... (from the plan), with "#2", "#3" ... for later generations
    public var id: String
    /// "level", "tilt 1", ...
    public var label: String
    /// the flat-phone shot that started it
    public var shotId: String
    /// the slab's true tilt here; nil if the flat-phone shot was skipped, failed or is not taken yet
    public var groundTruth: KitTrueTilt?
    /// when it started (ISO)
    public var startedAt: String?
    /// 2, 3, ... when the slab was set up again; nil for the first
    public var generation: Int?

    public init(id: String, label: String, shotId: String, groundTruth: KitTrueTilt? = nil, startedAt: String? = nil, generation: Int? = nil) {
        self.id = id; self.label = label; self.shotId = shotId; self.groundTruth = groundTruth; self.startedAt = startedAt
        self.generation = generation
    }

    /// the plan's position id ("p2" for "p2#3")
    public var planPositionId: String { id.split(separator: "#", maxSplits: 1).first.map(String.init) ?? id }
    /// 1 for the first time the slab was set up there
    public var generationNumber: Int { max(1, generation ?? 1) }
    /// "p2" for generation 1, "p2#3" for generation 3
    public static func id(plan: String, generation: Int) -> String { generation <= 1 ? plan : "\(plan)#\(generation)" }
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
    /// the measured height of the ball's bottom above the slab right under it (inches; a ruler stood on the slab under the
    /// ball, so in the dish: the app's drop height), if the owner entered one
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
    /// the owner's measurements once step 1 is done (`measurementsEnteredAt`); before that, the app's settings
    public var measurements: KitMeasurements
    /// when the owner entered the measurements (step 1). nil: `measurements` are the app's settings, not measured for
    /// this kit, and the scorer must not score sizes against them.
    public var measurementsEnteredAt: String?
    /// slab positions started so far (with later generations after their first), in plan order, with their true tilts
    public var positions: [KitSlabPosition]
    /// one record per shot, in plan order
    public var shots: [KitShotRecord]
    /// the level hold-still shot's median luma: the reference for the dim and bright shots
    public var lightReferenceLuma: Double?
    /// the level hold-still shot's median ARKit light estimate (lumens), if most of its frames had one
    public var lightReferenceAmbient: Double?
    public var notes: String?

    public init(kitId: String, planId: String, timeScale: Double? = nil, build: String, createdAt: String, device: KitDevice,
                measurements: KitMeasurements, positions: [KitSlabPosition] = [], shots: [KitShotRecord] = []) {
        self.kitId = kitId; self.planId = planId; self.timeScale = timeScale; self.build = build; self.createdAt = createdAt
        self.updatedAt = createdAt; self.device = device; self.measurements = measurements; self.positions = positions; self.shots = shots
    }

    public func record(_ id: String) -> KitShotRecord? { shots.first { $0.id == id } }
    /// a position by id ("p2", or "p2#2" for a later generation)
    public func position(_ id: String) -> KitSlabPosition? { positions.first { $0.id == id } }
    /// the latest generation of a plan position ("p2")
    public func currentPosition(plan id: String) -> KitSlabPosition? { positions.last { $0.planPositionId == id } }
    /// the slab position a captured shot belongs to, and so its true tilt (`groundTruth`)
    public func position(forShot id: String) -> KitSlabPosition? { record(id)?.positionId.flatMap { position($0) } }
    public var isFinished: Bool { finishedAt != nil }
    /// step 1 was done: the measurements are the owner's
    public var measurementsEntered: Bool { measurementsEnteredAt != nil }
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
    /// when the recording started (ISO, to the second; for people)
    public var startedAt: String
    /// when the recording started, in seconds of system uptime (the clock of the frames' `t` and of motion samples):
    /// the origin of the video's timestamps and of `releaseCue`. Set by the app.
    public var startTime: Double?
    /// recording length (s)
    public var duration: Double
    public var build: String
    public var device: KitDevice
    public var measurements: KitMeasurements
    /// the measurements were entered by the owner (step 1) when this shot was taken; false: the app's settings
    public var measurementsEntered: Bool?
    /// the slab position (with its generation, "p2#2") and its true tilt (copied from kit.json at capture time)
    public var positionId: String?
    public var trueTilt: KitTrueTilt?
    /// the run of CoreMotion updates the motion samples come from: shots with the same id share one reference frame
    /// (heading). An opaque id the app makes (e.g. a counter per kit); set by the app.
    public var motionSessionId: String?
    /// the ARKit session run the poses come from (a new id after every reset): shots with the same id share one world
    /// frame. Set by the app.
    public var arSessionId: String?
    /// the video (nil for flat-phone shots)
    public var video: KitVideoInfo?
    /// the ARKit camera format it was recorded with (full size)
    public var cameraFormat: KitCameraFormat?
    /// LiDAR depth files are present
    public var hasDepth: Bool
    public var depthFrames: Int?
    public var motionSamples: Int?
    /// the measured height of the ball's bottom above the slab right under it (inches; a ruler stood on the slab under the
    /// ball, so in the dish: the app's drop height)
    public var enteredHeightInches: Double?
    public var quality: KitQualityReport?
    /// drops: seconds after `startTime` when the plan has the app beep to let go (the plan's value)
    public var releaseCue: Double?
    /// drops: when the beep actually played, seconds of system uptime. Set by the app; the scorer uses it, or
    /// `startTime + releaseCue` without it.
    public var releaseTime: Double?
    /// flat-phone shots: the result
    public var flat: KitTrueTilt?
    public var notes: String?

    public init(kitId: String, shotId: String, step: Int, attempt: Int, startedAt: String, startTime: Double? = nil, duration: Double,
                build: String, device: KitDevice, measurements: KitMeasurements, measurementsEntered: Bool? = nil,
                positionId: String? = nil, trueTilt: KitTrueTilt? = nil, motionSessionId: String? = nil, arSessionId: String? = nil,
                video: KitVideoInfo? = nil, cameraFormat: KitCameraFormat? = nil, hasDepth: Bool = false, depthFrames: Int? = nil,
                motionSamples: Int? = nil, enteredHeightInches: Double? = nil, quality: KitQualityReport? = nil,
                releaseCue: Double? = nil, releaseTime: Double? = nil, flat: KitTrueTilt? = nil, notes: String? = nil) {
        self.kitId = kitId; self.shotId = shotId; self.step = step; self.attempt = attempt; self.startedAt = startedAt
        self.startTime = startTime; self.duration = duration; self.build = build; self.device = device; self.measurements = measurements
        self.measurementsEntered = measurementsEntered; self.positionId = positionId; self.trueTilt = trueTilt
        self.motionSessionId = motionSessionId; self.arSessionId = arSessionId; self.video = video; self.cameraFormat = cameraFormat
        self.hasDepth = hasDepth; self.depthFrames = depthFrames; self.motionSamples = motionSamples
        self.enteredHeightInches = enteredHeightInches; self.quality = quality; self.releaseCue = releaseCue
        self.releaseTime = releaseTime; self.flat = flat; self.notes = notes
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
