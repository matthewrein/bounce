import Foundation

/// The JSON behind the app's "Copy diagnostics" button. Everything is plain numbers and strings so it can be pasted into
/// a message and read back later.
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
    public struct Depth: Codable, Equatable {
        public var points: Int, rms: Double, angleToImageDegrees: Double, centreOffsetMm: Double, tiltDegrees: Double
        public init(_ d: DepthCheck) {
            points = d.points; rms = DiagnosticsReport.r4(d.rms); angleToImageDegrees = DiagnosticsReport.r2(d.angleToImageDegrees)
            centreOffsetMm = DiagnosticsReport.r2(d.centreOffset * 1000); tiltDegrees = DiagnosticsReport.r2(d.tiltDegrees)
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

    public init(build: String, device: String, system: String, time: String, settings: RecordingSettings, state: String, tracking: String,
                fps: Double, msProcess: Double, lens: CameraIntrinsics?, depthSupported: Bool, depth: DepthCheck?, captureLocked: Bool,
                slab: SlabPose?, outline: [Vec2]?, sideModes: [String], ball: (center: Vec3, circle: Vec2, radius: Double)?, readouts: Readouts?,
                counts: [String: Int], recentEvents: [String], recording: String?) {
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
    }

    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    static func r4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }

    public func json(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        // Readouts may hold non-finite values if something degenerate slipped through; encode them as strings
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
