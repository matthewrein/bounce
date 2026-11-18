import Foundation

// Pre-flight (Settings > Developer > Pre-flight), a developer tool for the first run on a phone: for about ten seconds
// the app watches the camera permission, ARKit's tracking, LiDAR depth, CoreMotion, the free space and a short test
// recording, and this file turns what it saw into one verdict per item, each pass / warn / fail / not available with
// one plain line and its numbers. Nothing here touches the camera: the app collects `PreflightObservations` (the
// meters below help, from any queue) and calls `Preflight.evaluate`. The thresholds are the static constants of
// `Preflight`, each documented. Words and numbers only: no paths, names or pictures.

/// One item's verdict.
public enum PreflightStatus: String, Codable, CaseIterable {
    case pass, warn, fail
    /// the phone (or the Simulator) does not have it, and the app does not need it (e.g. no LiDAR)
    case notAvailable

    /// "PASS", "WARN", "FAIL", "N/A"
    public var tag: String { self == .notAvailable ? "N/A" : rawValue.uppercased() }

    /// fail > warn > pass > not available
    var rank: Int {
        switch self {
        case .notAvailable: return 0
        case .pass: return 1
        case .warn: return 2
        case .fail: return 3
        }
    }
}

/// The items, in the order they are shown.
public enum PreflightCheck: String, Codable, CaseIterable {
    case camera, arkit, lidar, motion, storage, recorder

    public var title: String {
        switch self {
        case .camera: return "Camera permission"
        case .arkit: return "ARKit tracking"
        case .lidar: return "LiDAR depth"
        case .motion: return "Motion data"
        case .storage: return "Free storage"
        case .recorder: return "Recorder"
        }
    }
}

/// One line of the result.
public struct PreflightItem: Codable, Equatable {
    public var check: PreflightCheck
    public var title: String
    public var status: PreflightStatus
    /// one short line in plain words
    public var detail: String
    /// the numbers behind it (finite values only, rounded), e.g. "fps": 59.9
    public var numbers: [String: Double]

    public init(check: PreflightCheck, status: PreflightStatus, detail: String, numbers: [String: Double] = [:]) {
        self.check = check; title = check.title; self.status = status; self.detail = detail
        self.numbers = numbers.filter { $0.value.isFinite }.mapValues { ($0 * 1000).rounded() / 1000 }
    }

    /// "PASS  Camera permission: Allowed."
    public var line: String { "\(status.tag.padding(toLength: 5, withPad: " ", startingAt: 0)) \(title): \(detail)" }

    /// "fps 59.9, normalShare 0.95"
    public var numbersLine: String {
        numbers.keys.sorted().map { k in
            let v = numbers[k] ?? 0
            return "\(k) " + (v == v.rounded() && abs(v) < 1e15 ? String(format: "%.0f", v) : String(format: "%g", v))
        }.joined(separator: ", ")
    }
}

// MARK: what the app observes

/// AVCaptureDevice's authorization for video, or no camera at all (the Simulator).
public enum PreflightCameraAccess: String, Codable {
    case authorized, notDetermined, denied, restricted, noCamera
}

/// A change of ARKit's tracking state, seconds from the start of the pre-flight.
public struct PreflightTrackingChange: Codable, Equatable {
    public var t: Double
    public var state: KitTracking
    public init(t: Double, state: KitTracking) { self.t = t; self.state = state }
}

public struct PreflightARKitObservation: Codable, Equatable {
    /// ARWorldTrackingConfiguration.isSupported
    public var supported: Bool
    /// the video format's frame rate (what frames should arrive at); nil if not known
    public var expectedFps: Double?
    /// how long the pre-flight watched (s)
    public var window: Double
    /// camera frames that arrived
    public var frames: Int
    /// first and last frame, seconds from the start
    public var firstFrame: Double?
    public var lastFrame: Double?
    /// the first frame's tracking state and every change after it
    public var changes: [PreflightTrackingChange]
    /// the session failed with this error code
    public var errorCode: Int?
    /// the session was interrupted this many times
    public var interruptions: Int
    /// the longest gap between two frames (s), and the gaps longer than `Preflight.maxFrameGap` added up (s)
    public var maxGap: Double?
    public var longGapSeconds: Double?
    /// how late frames reached the app after they were captured (s): median and largest
    public var latencyMedian: Double?
    public var latencyMax: Double?
    /// the app's own work per frame (ms, its running average), averaged over the frames
    public var processingMs: Double?

    public init(supported: Bool, expectedFps: Double?, window: Double, frames: Int = 0, firstFrame: Double? = nil, lastFrame: Double? = nil,
                changes: [PreflightTrackingChange] = [], errorCode: Int? = nil, interruptions: Int = 0, maxGap: Double? = nil,
                longGapSeconds: Double? = nil, latencyMedian: Double? = nil, latencyMax: Double? = nil, processingMs: Double? = nil) {
        self.supported = supported; self.expectedFps = expectedFps; self.window = window; self.frames = frames
        self.firstFrame = firstFrame; self.lastFrame = lastFrame; self.changes = changes; self.errorCode = errorCode
        self.interruptions = interruptions; self.maxGap = maxGap; self.longGapSeconds = longGapSeconds
        self.latencyMedian = latencyMedian; self.latencyMax = latencyMax; self.processingMs = processingMs
    }

    /// frames a second between the first and the last frame
    public var fps: Double? {
        guard frames >= 2, let a = firstFrame, let b = lastFrame, b > a else { return nil }
        return Double(frames - 1) / (b - a)
    }

    /// seconds spent in each state from the first frame to the end of the window
    public var secondsByState: [KitTracking: Double] {
        var out: [KitTracking: Double] = [:]
        for (i, c) in changes.enumerated() {
            let end = i + 1 < changes.count ? changes[i + 1].t : max(window, lastFrame ?? c.t)
            out[c.state, default: 0] += max(0, end - c.t)
        }
        return out
    }

    /// seconds from the first frame to the first normal tracking; nil if never normal
    public var secondsToNormal: Double? {
        guard let first = changes.first?.t, let n = changes.first(where: { $0.state.isNormal }) else { return nil }
        return n.t - first
    }

    /// share of the time normal after tracking first became normal (1 when it never dropped); nil if never normal
    public var normalShareAfterFirstNormal: Double? {
        guard let i = changes.firstIndex(where: { $0.state.isNormal }) else { return nil }
        let end = max(window, lastFrame ?? 0)
        let total = end - changes[i].t
        guard total > 0 else { return 1 }
        var normal = 0.0
        for k in i..<changes.count where changes[k].state.isNormal {
            let e = k + 1 < changes.count ? changes[k + 1].t : end
            normal += max(0, e - changes[k].t)
        }
        return min(1, normal / total)
    }
}

/// One depth map looked at closely.
public struct PreflightDepthSample: Codable, Equatable {
    /// share of the map's pixels with a depth (finite and above zero)
    public var validShare: Double
    /// share with a depth and medium or high confidence (ARConfidenceLevel 1 or 2)
    public var confidentShare: Double
    /// median of the valid depths (m)
    public var medianMeters: Double?

    public init(validShare: Double, confidentShare: Double, medianMeters: Double?) {
        self.validShare = validShare; self.confidentShare = confidentShare; self.medianMeters = medianMeters
    }

    /// The shares and the median of a depth map (every pixel; LiDAR maps are 256 x 192).
    public init(_ map: DepthMap) {
        let n = map.depth.count
        var valid: [Float] = []
        valid.reserveCapacity(n)
        var confident = 0
        for i in 0..<n {
            let d = map.depth[i]
            guard d.isFinite, d > 0 else { continue }
            valid.append(d)
            if i < map.confidence.count, map.confidence[i] >= 1 { confident += 1 }
        }
        validShare = n > 0 ? Double(valid.count) / Double(n) : 0
        confidentShare = n > 0 ? Double(confident) / Double(n) : 0
        if valid.isEmpty { medianMeters = nil } else {
            valid.sort()
            medianMeters = Double(valid[valid.count / 2])
        }
    }
}

public struct PreflightLiDARObservation: Codable, Equatable {
    /// the phone offers scene depth (ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth))
    public var supported: Bool
    /// camera frames that arrived, and how many carried a depth map
    public var frames: Int
    public var framesWithDepth: Int
    /// depth maps looked at closely (about one a second)
    public var samples: [PreflightDepthSample]
    /// the first and the last frame with depth, seconds from the start; the longest gap between two of them (s), and
    /// those gaps longer than `Preflight.maxFrameGap` added up (s)
    public var firstDepthFrame: Double?
    public var lastDepthFrame: Double?
    public var maxDepthGap: Double?
    public var longDepthGapSeconds: Double?

    public init(supported: Bool, frames: Int = 0, framesWithDepth: Int = 0, samples: [PreflightDepthSample] = [],
                firstDepthFrame: Double? = nil, lastDepthFrame: Double? = nil, maxDepthGap: Double? = nil, longDepthGapSeconds: Double? = nil) {
        self.supported = supported; self.frames = frames; self.framesWithDepth = framesWithDepth; self.samples = samples
        self.firstDepthFrame = firstDepthFrame; self.lastDepthFrame = lastDepthFrame; self.maxDepthGap = maxDepthGap
        self.longDepthGapSeconds = longDepthGapSeconds
    }
}

public struct PreflightMotionObservation: Codable, Equatable {
    /// CMMotionManager.isDeviceMotionAvailable
    public var available: Bool
    /// the rate asked for (Hz): the capture kit's 100
    public var requestedHz: Double
    /// how long the pre-flight watched (s)
    public var window: Double
    public var samples: Int
    /// first and last sample, seconds from the start
    public var firstSample: Double?
    public var lastSample: Double?
    /// timestamps that did not advance (equal to or before the one before)
    public var nonAdvancing: Int
    /// the longest gap between two samples (s)
    public var maxGap: Double?
    /// |gravity| in g: median, smallest, largest. CoreMotion's gravity is its estimate of the direction, scaled to 1 g,
    /// so this reads 1 whatever the sensor does: information only, never a verdict.
    public var gravityMedian: Double?
    public var gravityMin: Double?
    public var gravityMax: Double?
    /// |gravity + user acceleration| in g, what the accelerometer itself reads: median, smallest, largest. Held still or
    /// in a hand its median is 1 g; a sensor that reads wrong (or nothing) shows here.
    public var accelMedian: Double?
    public var accelMin: Double?
    public var accelMax: Double?

    public init(available: Bool, requestedHz: Double, window: Double, samples: Int = 0, firstSample: Double? = nil, lastSample: Double? = nil,
                nonAdvancing: Int = 0, maxGap: Double? = nil, gravityMedian: Double? = nil, gravityMin: Double? = nil, gravityMax: Double? = nil,
                accelMedian: Double? = nil, accelMin: Double? = nil, accelMax: Double? = nil) {
        self.available = available; self.requestedHz = requestedHz; self.window = window; self.samples = samples
        self.firstSample = firstSample; self.lastSample = lastSample; self.nonAdvancing = nonAdvancing; self.maxGap = maxGap
        self.gravityMedian = gravityMedian; self.gravityMin = gravityMin; self.gravityMax = gravityMax
        self.accelMedian = accelMedian; self.accelMin = accelMin; self.accelMax = accelMax
    }

    /// samples a second between the first and the last
    public var rate: Double? {
        guard samples >= 2, let a = firstSample, let b = lastSample, b > a else { return nil }
        return Double(samples - 1) / (b - a)
    }
}

/// What a full capture kit needs on the phone, estimated from the plan (`fullKit`).
public struct PreflightStorageEstimate: Codable, Equatable {
    /// seconds of video in the plan (optional shots included)
    public var videoSeconds: Double
    public var videoBytes: Int64
    /// frames.jsonl, motion.jsonl, depth files, shot.json and kit.json
    public var frameDataBytes: Int64
    public var motionBytes: Int64
    public var depthBytes: Int64
    public var manifestBytes: Int64
    /// the kit folder when every shot is taken
    public var kitBytes: Int64
    /// the largest shot: a retry is recorded beside the capture it replaces
    public var retryBytes: Int64
    /// the bundle parts written next to the kit (Documents/Kits), counted as large as the kit
    public var bundleBytes: Int64
    /// `Preflight.storageMarginShare` of kit + bundle, plus `Preflight.storageReserveBytes` for the system
    public var marginBytes: Int64
    /// kit + retry + bundle + margin: what free space should be
    public var totalBytes: Int64
    /// kit + retry + reserve: below this even the kit cannot be finished
    public var minimumBytes: Int64

    /// A frames.jsonl line at most (bytes): a fully filled `KitFrame` encodes to about 1 KB (a test checks the bound).
    public static let frameLineBytes = 1500
    /// A motion.jsonl line at most (bytes).
    public static let motionLineBytes = 400
    /// A LiDAR depth file (BDP2: 256 x 192 x 3 bytes and a header), stored about once a second.
    public static let depthFileBytes = 256 * 192 * 3 + 16
    /// The capture kit's motion rate (Hz).
    public static let motionHz = 100.0
    /// Motion recorded for one flat-phone shot (s): the plan counts 12; a reading that starts over runs longer.
    public static let flatSeconds = 40.0
    /// shot.json (and a share of kit.json) per shot
    public static let manifestBytesPerShot = 16_000

    /// The kit's video size and bitrate rule, as `KitRecorder` records: the camera picture scaled to at most 1440 wide
    /// (even sizes); ordinary shots keep about 30 frames a second (every `keepEvery`-th of the camera's), drops every
    /// frame; HEVC at about 3.5 Mbit/s at 30 fps and 6 Mbit/s above 45 fps for 1440 x 1080, in proportion to the pixels,
    /// H.264 1.5 times as much, at least 0.3 Mbit/s.
    public static func videoSize(format: KitCameraFormat) -> (width: Int, height: Int) {
        let w = min(1440, format.width) / 2 * 2
        let h = Int((Double(format.height) * Double(w) / Double(max(1, format.width))).rounded()) / 2 * 2
        return (w, h)
    }

    public static func keepEvery(sourceFps: Double, highFrameRate: Bool) -> Int {
        highFrameRate ? 1 : max(1, Int((sourceFps / 30).rounded()))
    }

    public static func bitrate(width: Int, height: Int, fps: Double, hevc: Bool) -> Int {
        let base = fps > 45 ? 6_000_000.0 : 3_500_000.0
        let pixels = Double(width * height) / Double(1440 * 1080)
        return Int(max(300_000, base * pixels * (hevc ? 1 : 1.5)))
    }

    /// The kit's camera format when the app does not know it yet: 1920 x 1440 at 60 frames a second.
    public static let assumedFormat = KitCameraFormat(width: 1920, height: 1440, fps: 60)

    /// Every shot of `plan` (optional ones included) at the kit's camera format.
    public static func fullKit(plan: KitPlan = .standard, format: KitCameraFormat? = nil, hevc: Bool = true, hasLiDAR: Bool = true) -> PreflightStorageEstimate {
        let f = format ?? assumedFormat
        let size = videoSize(format: f)
        var seconds = 0.0, video = 0.0, frames = 0.0, motion = 0.0, depth = 0.0, manifests = 0.0, largest = 0.0
        for s in plan.shots where !s.isForm {
            var shot = 0.0
            switch s.kind {
            case let .video(sec, hfr, _):
                let kept = f.fps / Double(keepEvery(sourceFps: f.fps, highFrameRate: hfr))
                let v = Double(bitrate(width: size.width, height: size.height, fps: kept, hevc: hevc)) / 8 * sec
                let fr = kept * sec * Double(frameLineBytes)
                let mo = motionHz * sec * Double(motionLineBytes)
                let de = hasLiDAR ? (sec + 1).rounded(.up) * Double(depthFileBytes) : 0
                seconds += sec; video += v; frames += fr; motion += mo; depth += de
                shot = v + fr + mo + de
            case .flat:
                let mo = motionHz * flatSeconds * plan.timeScale * Double(motionLineBytes)
                motion += mo
                shot = mo
            case .form:
                break
            }
            manifests += Double(manifestBytesPerShot)
            largest = max(largest, shot + Double(manifestBytesPerShot))
        }
        func b(_ x: Double) -> Int64 { Int64(x.rounded(.up)) }
        let kit = b(video) + b(frames) + b(motion) + b(depth) + b(manifests)
        let bundle = kit
        let margin = b(Preflight.storageMarginShare * Double(kit + bundle)) + Preflight.storageReserveBytes
        return PreflightStorageEstimate(videoSeconds: seconds, videoBytes: b(video), frameDataBytes: b(frames), motionBytes: b(motion),
                                        depthBytes: b(depth), manifestBytes: b(manifests), kitBytes: kit, retryBytes: b(largest),
                                        bundleBytes: bundle, marginBytes: margin, totalBytes: kit + b(largest) + bundle + margin,
                                        minimumBytes: kit + b(largest) + Preflight.storageReserveBytes)
    }
}

public struct PreflightStorageObservation: Codable, Equatable {
    /// bytes free for important use on the app's volume (volumeAvailableCapacityForImportantUsage); nil if not known
    public var freeBytes: Int64?
    public var estimate: PreflightStorageEstimate
    public init(freeBytes: Int64?, estimate: PreflightStorageEstimate) { self.freeBytes = freeBytes; self.estimate = estimate }
}

/// The recorder's test: a short clip written into a scratch folder with the kit's recorder, then read back.
public struct PreflightRecorderObservation: Codable, Equatable {
    /// it ran (false: there were no frames to record, e.g. the Simulator without the demo scene)
    public var ran: Bool
    /// why the recording failed, in plain words, if it did
    public var error: String?
    /// seconds asked for
    public var requestedSeconds: Double
    /// frames the recorder wrote, and lines in its frames.jsonl and motion.jsonl
    public var framesWritten: Int
    public var frameLines: Int
    public var motionLines: Int?
    /// "hevc" or "h264", the picture size and frames a second as written
    public var codec: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    /// bytes of the video file
    public var fileBytes: Int64
    /// read back from the file: duration (s), frames, picture size; nil if it could not be read
    public var readBackSeconds: Double?
    public var readBackFrames: Int?
    public var readBackWidth: Int?
    public var readBackHeight: Int?
    /// the scratch folder was removed afterwards
    public var cleanedUp: Bool
    /// running in the Simulator (H.264 is expected there)
    public var simulator: Bool
    /// recorded as a drop shot records (every camera frame kept, the higher bitrate)
    public var highFrameRate: Bool?
    /// frames lost on the way: the encoder was not ready, the pool had no buffer, the picture could not be scaled
    public var notAppended: Int?
    public var poolMisses: Int?
    public var fillFailures: Int?
    /// LiDAR depth was asked for (as a kit shot asks on a LiDAR phone), and the depth files written
    public var depthRequested: Bool?
    public var depthFrames: Int?

    public init(ran: Bool, error: String? = nil, requestedSeconds: Double, framesWritten: Int = 0, frameLines: Int = 0, motionLines: Int? = nil,
                codec: String? = nil, width: Int? = nil, height: Int? = nil, fps: Double? = nil, fileBytes: Int64 = 0,
                readBackSeconds: Double? = nil, readBackFrames: Int? = nil, readBackWidth: Int? = nil, readBackHeight: Int? = nil,
                cleanedUp: Bool = true, simulator: Bool = false, highFrameRate: Bool? = nil, notAppended: Int? = nil, poolMisses: Int? = nil,
                fillFailures: Int? = nil, depthRequested: Bool? = nil, depthFrames: Int? = nil) {
        self.ran = ran; self.error = error; self.requestedSeconds = requestedSeconds; self.framesWritten = framesWritten
        self.frameLines = frameLines; self.motionLines = motionLines; self.codec = codec; self.width = width; self.height = height
        self.fps = fps; self.fileBytes = fileBytes; self.readBackSeconds = readBackSeconds; self.readBackFrames = readBackFrames
        self.readBackWidth = readBackWidth; self.readBackHeight = readBackHeight; self.cleanedUp = cleanedUp; self.simulator = simulator
        self.highFrameRate = highFrameRate; self.notAppended = notAppended; self.poolMisses = poolMisses; self.fillFailures = fillFailures
        self.depthRequested = depthRequested; self.depthFrames = depthFrames
    }

    /// frames lost before the file (encoder not ready, no buffer, not scaled)
    public var droppedFrames: Int { (notAppended ?? 0) + (poolMisses ?? 0) + (fillFailures ?? 0) }
}

/// Everything the app saw during the pre-flight.
public struct PreflightObservations: Codable, Equatable {
    public var build: String
    /// hardware model identifier ("iPhone16,1"), never the device's name
    public var device: String
    public var system: String
    /// ISO-8601, UTC
    public var time: String
    public var simulator: Bool
    /// the demo scene was on (the recorder then records its frames)
    public var demo: Bool
    public var camera: PreflightCameraAccess
    public var arkit: PreflightARKitObservation
    public var lidar: PreflightLiDARObservation
    public var motion: PreflightMotionObservation
    public var storage: PreflightStorageObservation
    public var recorder: PreflightRecorderObservation

    public init(build: String, device: String, system: String, time: String, simulator: Bool, demo: Bool, camera: PreflightCameraAccess,
                arkit: PreflightARKitObservation, lidar: PreflightLiDARObservation, motion: PreflightMotionObservation,
                storage: PreflightStorageObservation, recorder: PreflightRecorderObservation) {
        self.build = build; self.device = device; self.system = system; self.time = time; self.simulator = simulator; self.demo = demo
        self.camera = camera; self.arkit = arkit; self.lidar = lidar; self.motion = motion; self.storage = storage; self.recorder = recorder
    }
}

/// The result: one item per check, in order, and an overall verdict.
public struct PreflightReport: Codable, Equatable {
    public var items: [PreflightItem]
    /// the worst item (not available counts as nothing); pass when every item is pass or not available
    public var overall: PreflightStatus
    /// "Ready: 5 pass, 1 not available" / "Not ready: 1 fail, 1 warn, 4 pass"
    public var headline: String
    public var observations: PreflightObservations

    public func item(_ c: PreflightCheck) -> PreflightItem? { items.first { $0.check == c } }

    /// Plain text for Copy: a header, the headline, then one line per item with its numbers.
    public var text: String {
        let o = observations
        var lines = ["Pre-flight, build \(o.build), \(o.device), \(o.system), \(o.time)\(o.simulator ? ", Simulator" : "")\(o.demo ? ", demo scene" : "")",
                     headline]
        for i in items {
            lines.append(i.line)
            if !i.numbers.isEmpty { lines.append("      " + i.numbersLine) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The report as JSON (sorted keys): the items and every observation.
    public func json(pretty: Bool = true) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? e.encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: the verdicts

public enum Preflight {
    /// how long the pre-flight watches (s)
    public static let seconds = 10.0
    /// the recorder's test clip (s)
    public static let recorderSeconds = 2.0

    // ARKit
    /// frame rate against the format's: at least this share passes, ...
    public static let fpsPassShare = 0.9
    /// ... at least this share warns, below it fails
    public static let fpsWarnShare = 0.5
    /// frame rate assumed when the format's is not known (every ARKit format has at least 30)
    public static let fallbackFps = 30.0
    /// tracking should become normal within this many seconds of the first frame (else warn)
    public static let maxSecondsToNormal = 5.0
    /// once normal, it should stay normal at least this share of the time (else warn)
    public static let minNormalShare = 0.8
    /// frames (and depth) should start within this of the start and run to within this of the end (s), else warn: the
    /// frame rate alone is measured between the first and the last frame, so it cannot see frames that stopped
    public static let frameEdgeSlack = 1.5
    /// a gap between two frames (or two depth maps) longer than this warns (s)
    public static let maxFrameGap = 0.25
    /// frames missing (a late start, an early stop, and the gaps longer than `maxFrameGap`) for more than this share
    /// of the window fail
    public static let maxMissingShare = 0.5
    /// when the frame rate or the frames' coverage is off, the app's own processing is called behind (rather than the
    /// camera or ARKit) when its work per frame is longer than a frame, or frames reach it later than this many frames
    /// after they were captured
    public static let behindLatencyFrames = 3.0

    // LiDAR
    /// at least this share of the frames should carry a depth map (else warn)
    public static let minDepthFrameShare = 0.5
    /// the median depth map should have at least this share of confident pixels (else warn: aimed too close or at
    /// glass, a mirror, the sky)
    public static let minConfidentShare = 0.4

    // motion
    /// samples a second against the rate asked for: at least this share passes, ...
    public static let motionPassShare = 0.9
    /// ... at least this share warns, below it fails
    public static let motionWarnShare = 0.5
    /// the accelerometer's median |gravity + user acceleration| should be 1 g within this (pass), ...
    public static let accelPassTolerance = 0.05
    /// ... or within this (warn); further off fails
    public static let accelWarnTolerance = 0.15
    /// a gap between samples longer than this warns (s)
    public static let maxMotionGap = 0.25
    /// samples should run to within this of the end and start within this of the start (s), else warn
    public static let motionEdgeSlack = 1.5

    // storage
    /// margin on kit + bundle
    public static let storageMarginShare = 0.2
    /// room the system needs to keep working (bytes)
    public static let storageReserveBytes: Int64 = 200_000_000

    // recorder
    /// read-back frames may differ from those written by this many (pass); a share of at least `recorderWarnShare`
    /// read back warns, less fails
    public static let recorderFrameSlack = 1
    public static let recorderWarnShare = 0.9
    /// frames written against the clip's seconds x its frame rate: at least this share passes, ...
    public static let recorderWrittenPassShare = 0.9
    /// ... at least this share warns, below it fails. (Any frame dropped on the way also warns.)
    public static let recorderWrittenWarnShare = 0.5
    /// the clip's duration may differ from the one asked for by this many seconds plus two frames (pass); within
    /// half of it warns, further off fails
    public static let recorderDurationSlack = 0.25

    /// Every item, in order.
    public static func evaluate(_ o: PreflightObservations) -> PreflightReport {
        var rec = o.recorder
        rec.simulator = rec.simulator || o.simulator
        let items = [camera(o.camera, simulator: o.simulator), arkit(o.arkit, simulator: o.simulator), lidar(o.lidar, arkit: o.arkit),
                     motion(o.motion, simulator: o.simulator), storage(o.storage), recorder(rec, demo: o.demo)]
        let worst = items.map { $0.status }.max { $0.rank < $1.rank } ?? .pass
        let overall: PreflightStatus = worst == .notAvailable ? .pass : worst
        var parts: [String] = []
        for s in [PreflightStatus.fail, .warn, .pass, .notAvailable] {
            let n = items.filter { $0.status == s }.count
            if n > 0 { parts.append("\(n) \(s == .notAvailable ? "not available" : s.rawValue)") }
        }
        let headline = (overall == .fail ? "Not ready: " : overall == .warn ? "Ready, with warnings: " : "Ready: ") + parts.joined(separator: ", ")
        return PreflightReport(items: items, overall: overall, headline: headline, observations: o)
    }

    public static func camera(_ a: PreflightCameraAccess, simulator: Bool) -> PreflightItem {
        switch a {
        case .authorized: return PreflightItem(check: .camera, status: .pass, detail: "Allowed.")
        case .notDetermined:
            return PreflightItem(check: .camera, status: .warn, detail: "Not answered yet: the phone asks when the camera first starts.")
        case .denied:
            return PreflightItem(check: .camera, status: .fail, detail: "Turned off. Settings > Privacy & Security > Camera > Slab Bounce.")
        case .restricted:
            return PreflightItem(check: .camera, status: .fail, detail: "Blocked on this phone (Screen Time or a profile).")
        case .noCamera:
            return simulator ? PreflightItem(check: .camera, status: .notAvailable, detail: "No camera in the Simulator.")
                             : PreflightItem(check: .camera, status: .fail, detail: "No camera found.")
        }
    }

    static func reasonWords(_ t: KitTracking) -> String {
        switch t {
        case .normal: return "normal"
        case .limitedInitializing: return "starting up"
        case .limitedExcessiveMotion: return "moving too fast"
        case .limitedInsufficientFeatures: return "too few features (aim at the room, not a blank surface)"
        case .limitedRelocalizing: return "relocalizing"
        case .limitedOther: return "limited"
        case .notAvailable: return "not available"
        }
    }

    public static func arkit(_ o: PreflightARKitObservation, simulator: Bool) -> PreflightItem {
        guard o.supported else {
            return simulator ? PreflightItem(check: .arkit, status: .notAvailable, detail: "No ARKit in the Simulator.")
                             : PreflightItem(check: .arkit, status: .fail, detail: "This phone cannot run ARKit world tracking.")
        }
        var n: [String: Double] = ["frames": Double(o.frames), "window": o.window, "interruptions": Double(o.interruptions)]
        if let e = o.expectedFps { n["expectedFps"] = e }
        if let code = o.errorCode {
            n["errorCode"] = Double(code)
            return PreflightItem(check: .arkit, status: .fail, detail: "The AR session failed (error \(code)).", numbers: n)
        }
        guard o.frames > 0 else {
            return PreflightItem(check: .arkit, status: .fail, detail: String(format: "No camera frames in %.0f s.", o.window), numbers: n)
        }
        let expected = o.expectedFps ?? fallbackFps
        let fps = o.fps ?? 0
        n["fps"] = fps
        let byState = o.secondsByState
        let worstLimited = byState.filter { !$0.key.isNormal }.max { $0.value < $1.value }?.key
        if let s = o.secondsToNormal { n["secondsToNormal"] = s }
        if let s = o.normalShareAfterFirstNormal { n["normalShare"] = s }
        n["secondsNormal"] = byState[.normal] ?? 0
        if let g = o.maxGap { n["maxGap"] = g }
        if let l = o.latencyMedian { n["latencyMedianMs"] = l * 1000 }
        if let l = o.latencyMax { n["latencyMaxMs"] = l * 1000 }
        if let p = o.processingMs { n["processingMs"] = p }
        var problems: [String] = [], status = PreflightStatus.pass
        func worse(_ s: PreflightStatus, _ why: String) { if s.rank > status.rank { status = s }; problems.append(why) }

        // frames should come from the start to the end: a stall after the first seconds keeps the rate between the
        // first and the last frame looking fine
        let coverage = coverageProblems(what: "frames", first: o.firstFrame, last: o.lastFrame, maxGap: o.maxGap,
                                        longGapSeconds: o.longGapSeconds, window: o.window)
        if coverage.missing > 0 { n["missingSeconds"] = coverage.missing }
        for p in coverage.problems { worse(coverage.status, p) }
        if fps < fpsWarnShare * expected {
            worse(.fail, String(format: "only %.1f frames a second (expected %.0f)", fps, expected))
        } else if fps < fpsPassShare * expected {
            worse(.warn, String(format: "%.1f frames a second (expected %.0f)", fps, expected))
        }
        // too few frames: say whether the app's own processing fell behind or the frames came late from the camera
        if !problems.isEmpty, let why = processingWords(o, expectedFps: expected) { problems.append(why) }
        if let s = o.secondsToNormal {
            if s > maxSecondsToNormal { worse(.warn, String(format: "took %.1f s to become normal", s)) }
            if let share = o.normalShareAfterFirstNormal, share < minNormalShare {
                worse(.warn, String(format: "limited %.0f%% of the time after that (%@)", (1 - share) * 100,
                                    reasonWords(worstLimited ?? .limitedOther)))
            }
        } else {
            worse(.fail, "tracking never became normal (\(reasonWords(worstLimited ?? .limitedOther)))")
        }
        if o.interruptions > 0 { worse(.warn, "interrupted \(o.interruptions) time\(o.interruptions == 1 ? "" : "s")") }
        if status == .pass {
            return PreflightItem(check: .arkit, status: .pass,
                                 detail: String(format: "Normal after %.1f s, %.0f frames a second.", o.secondsToNormal ?? 0, fps), numbers: n)
        }
        return PreflightItem(check: .arkit, status: status, detail: sentence(problems), numbers: n)
    }

    public static func lidar(_ o: PreflightLiDARObservation, arkit: PreflightARKitObservation) -> PreflightItem {
        guard o.supported else {
            return PreflightItem(check: .lidar, status: .notAvailable, detail: "No LiDAR on this phone: the app works without it.")
        }
        var n: [String: Double] = ["frames": Double(o.frames), "framesWithDepth": Double(o.framesWithDepth), "samples": Double(o.samples.count)]
        guard o.frames > 0 else {
            return PreflightItem(check: .lidar, status: .fail, detail: "No camera frames, so no depth.", numbers: n)
        }
        guard o.framesWithDepth > 0 else {
            return PreflightItem(check: .lidar, status: .fail, detail: "The phone has LiDAR but no depth arrived.", numbers: n)
        }
        let share = Double(o.framesWithDepth) / Double(o.frames)
        n["depthFrameShare"] = share
        if let g = o.maxDepthGap { n["maxDepthGap"] = g }
        var problems: [String] = [], status = PreflightStatus.pass
        func worse(_ s: PreflightStatus, _ why: String) { if s.rank > status.rank { status = s }; problems.append(why) }
        // depth should come from the start to the end, like the frames
        let coverage = coverageProblems(what: "depth", first: o.firstDepthFrame, last: o.lastDepthFrame, maxGap: o.maxDepthGap,
                                        longGapSeconds: o.longDepthGapSeconds, window: arkit.window)
        if coverage.missing > 0 { n["missingSeconds"] = coverage.missing }
        for p in coverage.problems { worse(coverage.status, p) }
        if share < minDepthFrameShare {
            worse(.warn, String(format: "depth on only %.0f%% of the frames", share * 100))
        }
        if o.samples.isEmpty {
            worse(.warn, "no depth map was checked")
        } else {
            let conf = median(o.samples.map { $0.confidentShare }), valid = median(o.samples.map { $0.validShare })
            n["confidentShare"] = conf
            n["validShare"] = valid
            let depths = o.samples.compactMap { $0.medianMeters }
            if !depths.isEmpty { n["medianMeters"] = median(depths) }
            if conf < minConfidentShare {
                worse(.warn, String(format: "only %.0f%% of the depth was sure (aim at the slab or the room from 0.5 to 3 m)", conf * 100))
            }
        }
        if status == .pass {
            return PreflightItem(check: .lidar, status: .pass,
                                 detail: String(format: "Depth on %.0f%% of the frames, %.0f%% of it sure.", share * 100, (n["confidentShare"] ?? 0) * 100),
                                 numbers: n)
        }
        return PreflightItem(check: .lidar, status: status, detail: sentence(problems), numbers: n)
    }

    public static func motion(_ o: PreflightMotionObservation, simulator: Bool) -> PreflightItem {
        guard o.available else {
            return simulator ? PreflightItem(check: .motion, status: .notAvailable, detail: "No motion sensors in the Simulator.")
                             : PreflightItem(check: .motion, status: .fail, detail: "Device motion is not available on this phone.")
        }
        var n: [String: Double] = ["samples": Double(o.samples), "requestedHz": o.requestedHz, "window": o.window,
                                   "nonAdvancing": Double(o.nonAdvancing)]
        guard o.samples > 0 else {
            return PreflightItem(check: .motion, status: .fail, detail: String(format: "No motion data in %.0f s.", o.window), numbers: n)
        }
        let rate = o.rate ?? 0
        n["rate"] = rate
        // gravity is CoreMotion's estimate scaled to 1 g: shown, never judged
        if let g = o.gravityMedian { n["gravity"] = g }
        if let g = o.gravityMin { n["gravityMin"] = g }
        if let g = o.gravityMax { n["gravityMax"] = g }
        if let a = o.accelMedian { n["accel"] = a }
        if let a = o.accelMin { n["accelMin"] = a }
        if let a = o.accelMax { n["accelMax"] = a }
        if let g = o.maxGap { n["maxGap"] = g }
        var problems: [String] = [], status = PreflightStatus.pass
        func worse(_ s: PreflightStatus, _ why: String) { if s.rank > status.rank { status = s }; problems.append(why) }
        if rate < motionWarnShare * o.requestedHz {
            worse(.fail, String(format: "only %.0f samples a second (asked for %.0f)", rate, o.requestedHz))
        } else if rate < motionPassShare * o.requestedHz {
            worse(.warn, String(format: "%.0f samples a second (asked for %.0f)", rate, o.requestedHz))
        }
        if o.nonAdvancing > 0 { worse(.fail, "time stamps did not advance \(o.nonAdvancing) time\(o.nonAdvancing == 1 ? "" : "s")") }
        if o.gravityMedian == nil { worse(.fail, "no gravity readings") }
        // the accelerometer itself: |gravity + user acceleration| has a median of 1 g in a hand or on a table
        if let a = o.accelMedian {
            let off = abs(a - 1)
            if off > accelWarnTolerance { worse(.fail, String(format: "the accelerometer reads %.3f g (1 expected)", a)) }
            else if off > accelPassTolerance { worse(.warn, String(format: "the accelerometer reads %.3f g (1 expected)", a)) }
        } else if o.gravityMedian != nil {
            worse(.warn, "no accelerometer readings")
        }
        if let gap = o.maxGap, gap > maxMotionGap { worse(.warn, String(format: "a gap of %.2f s", gap)) }
        if let last = o.lastSample, o.window - last > motionEdgeSlack {
            worse(.warn, String(format: "stopped %.1f s before the end", o.window - last))
        }
        if let first = o.firstSample, first > motionEdgeSlack { worse(.warn, String(format: "started %.1f s late", first)) }
        if status == .pass {
            return PreflightItem(check: .motion, status: .pass,
                                 detail: String(format: "%.0f samples a second, the accelerometer reads %.3f g.", rate, o.accelMedian ?? 0), numbers: n)
        }
        return PreflightItem(check: .motion, status: status, detail: sentence(problems), numbers: n)
    }

    public static func storage(_ o: PreflightStorageObservation) -> PreflightItem {
        let e = o.estimate
        var n: [String: Double] = ["needMB": mb(e.totalBytes), "minimumMB": mb(e.minimumBytes), "kitMB": mb(e.kitBytes),
                                   "bundleMB": mb(e.bundleBytes)]
        guard let free = o.freeBytes else {
            return PreflightItem(check: .storage, status: .warn,
                                 detail: String(format: "Free space unknown; a full kit needs about %.0f MB.", mb(e.totalBytes)), numbers: n)
        }
        n["freeMB"] = mb(free)
        if free >= e.totalBytes {
            return PreflightItem(check: .storage, status: .pass,
                                 detail: String(format: "%.1f GB free; a full kit and its bundle need about %.0f MB.", Double(free) / 1e9, mb(e.totalBytes)),
                                 numbers: n)
        }
        if free >= e.minimumBytes {
            return PreflightItem(check: .storage, status: .warn,
                                 detail: String(format: "%.0f MB free: enough for the kit (%.0f MB) but maybe not its bundle; about %.0f MB is safe.",
                                                mb(free), mb(e.minimumBytes), mb(e.totalBytes)), numbers: n)
        }
        return PreflightItem(check: .storage, status: .fail,
                             detail: String(format: "Only %.0f MB free; a full kit needs about %.0f MB. Free some space first.", mb(free), mb(e.totalBytes)),
                             numbers: n)
    }

    public static func recorder(_ o: PreflightRecorderObservation, demo: Bool) -> PreflightItem {
        var n: [String: Double] = ["requestedSeconds": o.requestedSeconds, "framesWritten": Double(o.framesWritten),
                                   "frameLines": Double(o.frameLines), "fileBytes": Double(o.fileBytes)]
        guard o.ran else {
            if o.simulator && !demo {
                return PreflightItem(check: .recorder, status: .notAvailable,
                                     detail: "No camera in the Simulator: turn on the demo scene to test the recorder.", numbers: n)
            }
            return PreflightItem(check: .recorder, status: .fail, detail: o.error.map { "Did not run: \($0)." } ?? "Did not run: no camera frames.",
                                 numbers: n)
        }
        if let m = o.motionLines { n["motionLines"] = Double(m) }
        if let f = o.fps { n["fps"] = f }
        if let w = o.width, let h = o.height { n["width"] = Double(w); n["height"] = Double(h) }
        if let s = o.readBackSeconds { n["readBackSeconds"] = s }
        if let f = o.readBackFrames { n["readBackFrames"] = Double(f) }
        if let e = o.error { return PreflightItem(check: .recorder, status: .fail, detail: "The recording failed: \(e).", numbers: n) }
        guard o.framesWritten > 0, o.fileBytes > 0 else {
            return PreflightItem(check: .recorder, status: .fail, detail: "Nothing was written.", numbers: n)
        }
        guard let back = o.readBackFrames, back > 0 else {
            return PreflightItem(check: .recorder, status: .fail, detail: "The clip was written but could not be read back.", numbers: n)
        }
        var problems: [String] = [], status = PreflightStatus.pass
        func worse(_ s: PreflightStatus, _ why: String) { if s.rank > status.rank { status = s }; problems.append(why) }
        // as many frames as the clip's seconds at its frame rate, none lost on the way (a phone too hot or too slow for
        // the encoder shows here, before a kit shot loses frames the same way)
        if let fps = o.fps, fps > 0, o.requestedSeconds > 0 {
            let expected = o.requestedSeconds * fps
            n["expectedFrames"] = expected.rounded()
            let share = Double(o.framesWritten) / expected
            if share < recorderWrittenWarnShare {
                worse(.fail, String(format: "only %d of about %.0f frames were recorded", o.framesWritten, expected))
            } else if share < recorderWrittenPassShare {
                worse(.warn, String(format: "%d of about %.0f frames were recorded", o.framesWritten, expected))
            }
        }
        if o.droppedFrames > 0 {
            n["droppedFrames"] = Double(o.droppedFrames)
            var why: [String] = []
            if let k = o.notAppended, k > 0 { why.append("\(k) encoder not ready") }
            if let k = o.poolMisses, k > 0 { why.append("\(k) no buffer") }
            if let k = o.fillFailures, k > 0 { why.append("\(k) not scaled") }
            worse(.warn, "\(o.droppedFrames) frame\(o.droppedFrames == 1 ? "" : "s") dropped (\(why.joined(separator: ", ")))")
        }
        // a LiDAR phone's kit shots carry depth: the recorder must write it
        if o.depthRequested == true {
            n["depthFrames"] = Double(o.depthFrames ?? 0)
            if (o.depthFrames ?? 0) == 0 { worse(.fail, "no depth was written, so kit shots would have none") }
        }
        if abs(back - o.framesWritten) > recorderFrameSlack {
            let share = Double(back) / Double(o.framesWritten)
            worse(share >= recorderWarnShare && back <= o.framesWritten + recorderFrameSlack ? .warn : .fail,
                  "read back \(back) of \(o.framesWritten) frames")
        }
        if let secs = o.readBackSeconds {
            let frame = o.fps.map { $0 > 0 ? 2 / $0 : 0 } ?? 0
            let off = abs(secs - o.requestedSeconds)
            if off > recorderDurationSlack + frame {
                worse(off <= 0.5 * o.requestedSeconds ? .warn : .fail, String(format: "the clip is %.2f s long (asked for %.1f)", secs, o.requestedSeconds))
            }
        } else {
            worse(.warn, "its length could not be read")
        }
        if o.frameLines != o.framesWritten { worse(.warn, "the frame list has \(o.frameLines) lines for \(o.framesWritten) frames") }
        if let w = o.width, let h = o.height, let rw = o.readBackWidth, let rh = o.readBackHeight, w != rw || h != rh {
            worse(.warn, "the picture reads back as \(rw)x\(rh), written as \(w)x\(h)")
        }
        if o.codec == "h264" && !o.simulator { worse(.warn, "HEVC could not be used: H.264 instead (bigger files)") }
        if !o.cleanedUp { worse(.warn, "the test clip could not be removed") }
        if status == .pass {
            let size = o.width.flatMap { w in o.height.map { "\(w)x\($0)" } } ?? "?"
            let rate = o.fps.map { String(format: " at %.0f fps", $0) } ?? ""
            let depth = o.depthRequested == true ? ", \(o.depthFrames ?? 0) depth maps" : ""
            let what = "\(o.codec ?? "video") \(size)\(rate)"
            return PreflightItem(check: .recorder, status: .pass,
                                 detail: "Wrote and read back \(back) frames (\(what), "
                                    + String(format: "%.2f s, %.1f MB", o.readBackSeconds ?? 0, Double(o.fileBytes) / 1e6) + depth + ").",
                                 numbers: n)
        }
        return PreflightItem(check: .recorder, status: status, detail: sentence(problems), numbers: n)
    }

    // MARK: helpers

    /// Did frames (or depth maps) come from the start of the window to its end? A late start, an early stop and gaps
    /// longer than `maxFrameGap` are missing time: each one past its slack warns, and more than `maxMissingShare` of the
    /// window missing fails. Returns the status for the problems found (pass when none), the problems in words, and the
    /// missing seconds.
    static func coverageProblems(what: String, first: Double?, last: Double?, maxGap: Double?, longGapSeconds: Double?,
                                 window: Double) -> (status: PreflightStatus, problems: [String], missing: Double) {
        guard let a = first, let b = last, window > 0 else { return (.pass, [], 0) }
        let late = max(0, a), early = max(0, window - b)
        let missing = late + early + max(0, longGapSeconds ?? 0)
        var p: [String] = []
        if early > frameEdgeSlack { p.append("\(what) stopped " + String(format: "%.1f s before the end", early)) }
        if late > frameEdgeSlack { p.append("\(what) started " + String(format: "%.1f s late", late)) }
        if let g = maxGap, g > maxFrameGap { p.append(String(format: "a gap of %.2f s between ", g) + what) }
        let failed = missing > maxMissingShare * window
        if failed && p.isEmpty { p.append("\(what) missing for " + String(format: "%.1f s of %.0f", missing, window)) }
        return (failed ? .fail : (p.isEmpty ? .pass : .warn), p, missing)
    }

    /// When frames are too few: is the app's own processing behind (its work per frame is longer than a frame, or frames
    /// reach it more than `behindLatencyFrames` frames after capture), or does it keep up (so the camera or ARKit is the
    /// cause)? nil when neither number is known.
    static func processingWords(_ o: PreflightARKitObservation, expectedFps: Double) -> String? {
        let frameMs = 1000 / max(1, expectedFps)
        let lateMs = o.latencyMedian.map { $0 * 1000 }
        let work = o.processingMs
        guard lateMs != nil || work != nil else { return nil }
        let behind = (work.map { $0 > frameMs } ?? false) || (lateMs.map { $0 > behindLatencyFrames * frameMs } ?? false)
        var nums: [String] = []
        if let l = lateMs { nums.append(String(format: "frames reach it %.0f ms after capture", l)) }
        if let w = work { nums.append(String(format: "%.0f ms of work a frame for a %.0f ms frame", w, frameMs)) }
        return (behind ? "the app's processing is behind, not the camera (" : "the app keeps up, so the camera or ARKit is the cause (")
            + nums.joined(separator: ", ") + ")"
    }

    /// "a; b" -> "A; b."
    static func sentence(_ parts: [String]) -> String {
        let s = parts.joined(separator: "; ")
        guard let f = s.first else { return "" }
        return f.uppercased() + s.dropFirst() + "."
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func mb(_ bytes: Int64) -> Double { (Double(bytes) / 1e6).rounded() }
}

// MARK: meters (the app feeds them from any queue)

/// Collects ARKit's frames during the pre-flight: their tracking states, whether each carried depth, and a closer look
/// at about one depth map a second. Thread-safe. Times are the frames' timestamps (system uptime).
public final class PreflightARKitMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Double
    private let supported: Bool
    private let expectedFps: Double?
    private let depthSupported: Bool
    private var frames = 0, framesWithDepth = 0
    private var first: Double? = nil, last: Double? = nil
    private var maxGap: Double? = nil, longGaps = 0.0
    private var firstDepth: Double? = nil, lastDepth: Double? = nil
    private var maxDepthGap: Double? = nil, longDepthGaps = 0.0
    private var changes: [PreflightTrackingChange] = []
    private var lastSampleTime = -Double.infinity
    private var samples: [PreflightDepthSample] = []
    private var errorCode: Int? = nil
    private var interruptions = 0
    private var latencies: [Double] = []
    private var processingSum = 0.0, processingCount = 0

    /// `start`: uptime when the pre-flight began.
    public init(start: Double, supported: Bool, expectedFps: Double?, depthSupported: Bool) {
        self.start = start; self.supported = supported; self.expectedFps = expectedFps; self.depthSupported = depthSupported
    }

    /// A frame: its timestamp, its tracking state, whether it carried a depth map; how late it reached the app (s, the
    /// uptime when it arrived minus its timestamp) and the app's own work per frame then (ms), when known.
    public func frame(time: Double, tracking: KitTracking, hasDepth: Bool, latency: Double? = nil, processingMs: Double? = nil) {
        let t = max(0, time - start)
        lock.lock(); defer { lock.unlock() }
        frames += 1
        if first == nil { first = t }
        if let l = last, t > l {
            let g = t - l
            maxGap = max(maxGap ?? 0, g)
            if g > Preflight.maxFrameGap { longGaps += g }
        }
        last = max(last ?? t, t)
        if hasDepth {
            framesWithDepth += 1
            if firstDepth == nil { firstDepth = t }
            if let l = lastDepth, t > l {
                let g = t - l
                maxDepthGap = max(maxDepthGap ?? 0, g)
                if g > Preflight.maxFrameGap { longDepthGaps += g }
            }
            lastDepth = max(lastDepth ?? t, t)
        }
        if changes.last?.state != tracking { changes.append(PreflightTrackingChange(t: t, state: tracking)) }
        if let l = latency, l.isFinite, latencies.count < 10_000 { latencies.append(max(0, l)) }
        if let p = processingMs, p.isFinite, p > 0 { processingSum += p; processingCount += 1 }
    }

    /// Is a closer look at this frame's depth map due (about one a second)? If so, pass it to `depth`.
    public func wantsDepthSample(time: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return time - lastSampleTime >= 1
    }

    public func depth(_ sample: PreflightDepthSample, time: Double) {
        lock.lock(); defer { lock.unlock() }
        samples.append(sample)
        lastSampleTime = time
    }

    public func sessionFailed(code: Int) { lock.lock(); errorCode = code; lock.unlock() }
    public func interrupted() { lock.lock(); interruptions += 1; lock.unlock() }

    /// What was seen until `end` (uptime).
    public func observations(end: Double) -> (arkit: PreflightARKitObservation, lidar: PreflightLiDARObservation) {
        lock.lock(); defer { lock.unlock() }
        let lat = latencies.sorted()
        let a = PreflightARKitObservation(supported: supported, expectedFps: expectedFps, window: max(0, end - start), frames: frames,
                                          firstFrame: first, lastFrame: last, changes: changes, errorCode: errorCode, interruptions: interruptions,
                                          maxGap: maxGap, longGapSeconds: frames > 0 ? longGaps : nil,
                                          latencyMedian: lat.isEmpty ? nil : Preflight.median(lat), latencyMax: lat.last,
                                          processingMs: processingCount > 0 ? processingSum / Double(processingCount) : nil)
        let l = PreflightLiDARObservation(supported: depthSupported, frames: frames, framesWithDepth: framesWithDepth, samples: samples,
                                          firstDepthFrame: firstDepth, lastDepthFrame: lastDepth, maxDepthGap: maxDepthGap,
                                          longDepthGapSeconds: framesWithDepth > 0 ? longDepthGaps : nil)
        return (a, l)
    }
}

/// Collects CoreMotion's device-motion samples during the pre-flight. Thread-safe. Times are the samples' timestamps
/// (system uptime).
public final class PreflightMotionMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Double
    private let available: Bool
    private let requestedHz: Double
    private var count = 0
    private var first: Double? = nil, last: Double? = nil
    private var previous: Double? = nil
    private var nonAdvancing = 0
    private var maxGap: Double? = nil
    private var magnitudes: [Double] = []
    private var accelMagnitudes: [Double] = []

    public init(start: Double, available: Bool, requestedHz: Double = PreflightStorageEstimate.motionHz) {
        self.start = start; self.available = available; self.requestedHz = requestedHz
    }

    /// One sample: its timestamp, gravity and user acceleration (in g; CoreMotion's split of what the accelerometer
    /// reads, so their sum is the accelerometer's reading).
    public func sample(time: Double, gravity: Vec3, userAcceleration: Vec3? = nil) {
        let t = time - start
        lock.lock(); defer { lock.unlock() }
        count += 1
        if first == nil { first = max(0, t) }
        if let p = previous {
            if time <= p { nonAdvancing += 1 } else { maxGap = max(maxGap ?? 0, time - p) }
        }
        previous = max(previous ?? time, time)
        last = max(last ?? 0, t)
        let g = gravity.length
        if g.isFinite { magnitudes.append(g) }
        if let u = userAcceleration {
            let a = (gravity + u).length
            if a.isFinite { accelMagnitudes.append(a) }
        }
    }

    /// What was seen until `end` (uptime).
    public func observation(end: Double) -> PreflightMotionObservation {
        lock.lock(); defer { lock.unlock() }
        let s = magnitudes.sorted(), a = accelMagnitudes.sorted()
        return PreflightMotionObservation(available: available, requestedHz: requestedHz, window: max(0, end - start), samples: count,
                                          firstSample: first, lastSample: last, nonAdvancing: nonAdvancing, maxGap: maxGap,
                                          gravityMedian: s.isEmpty ? nil : Preflight.median(s), gravityMin: s.first, gravityMax: s.last,
                                          accelMedian: a.isEmpty ? nil : Preflight.median(a), accelMin: a.first, accelMax: a.last)
    }
}
