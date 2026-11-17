import Foundation

/// Finds the slab's top-corner outline in a frame. The real one is SlabFinder; tests can plug in others.
public protocol SlabDetecting {
    /// Outlines (top corners, pixels of `frame`) best first. `near`: a predicted outline to search around.
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline]
}

/// One outline a detector found.
public struct DetectedOutline: Equatable {
    public var quad: [Vec2]
    /// detector's own confidence, higher is better (only compared between outlines of one frame)
    public var score: Double
    /// per-side edge modes, for diagnostics (e.g. "top", "fromCutBottom", "silhouette")
    public var sideModes: [String]
    public init(quad: [Vec2], score: Double = 1, sideModes: [String] = []) { self.quad = quad; self.score = score; self.sideModes = sideModes }
}

/// Finds the ball above the slab. The real one is BallLocator; tests can plug in others.
public protocol BallLocating: AnyObject {
    /// The ball's centre in camera (CV) axes if a ball is held over the slab. `image`: a luma image (often a
    /// higher-resolution crop around the slab) with its own intrinsics; `slab`: the slab pose in the same camera axes.
    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)?
    func reset()
}

public struct TrackerSettings: Equatable {
    public var spec: SlabSpec = .standard
    public var ball: BallSpec = BallSpec()
    public var defaultDropHeight: Double = Units.feet(3)
    public var launchRule: Bounce.LaunchRule = .cornerPlane
    /// seconds between re-detections while locked, and between searches while not (0: every frame)
    public var recheckInterval: Double = 0.3
    public var searchInterval: Double = 0
    /// consistent detections needed before locking, and how consistent (centre distance, normal angle)
    public var confirmCount: Int = 3
    public var matchDistance: Double = 0.025
    public var matchAngleDegrees: Double = 4
    /// re-detections that disagree with the lock but agree with each other before re-locking (the slab was moved)
    public var moveCount: Int = 4
    /// seconds of failed re-detections, with the slab in view, before giving up the lock
    public var lostAfter: Double = 4
    /// how many recent measurements make up the lock
    public var historySize: Int = 15
    /// use LiDAR depth when present: fuse its plane's normal with this weight (0 = only report it)
    public var depthNormalWeight: Double = 0.5
    /// the ball finder runs at most this often (s)
    public var ballInterval: Double = 0.1
    public var shapeLimits = ShapeCheck.Limits()
    public init() {}
}

/// One camera frame for the tracker.
public struct TrackerFrame {
    public var timestamp: Double
    /// the processing frame and its camera (intrinsics of `frame`'s pixels; world-from-camera in CV axes)
    public var view: CameraView
    public var frame: ColorFrame
    /// optional LiDAR depth and the intrinsics of its pixels (same camera pose as `view`)
    public var depth: DepthMap?
    public var depthIntrinsics: CameraIntrinsics?
    /// optional luma image for the ball finder (e.g. a full-resolution crop) and its intrinsics
    public var ballImage: Plane?
    public var ballIntrinsics: CameraIntrinsics?
    /// a tapped point (pixels of `frame`): look for the slab there
    public var tap: Vec2?
    /// world height of the floor, if known (ARKit plane detection): the bounce path ends there
    public var floorY: Double?
    /// ARKit tracking state is normal (poses are good)
    public var trackingNormal: Bool

    public init(timestamp: Double, view: CameraView, frame: ColorFrame, depth: DepthMap? = nil, depthIntrinsics: CameraIntrinsics? = nil,
                ballImage: Plane? = nil, ballIntrinsics: CameraIntrinsics? = nil, tap: Vec2? = nil, floorY: Double? = nil, trackingNormal: Bool = true) {
        self.timestamp = timestamp; self.view = view; self.frame = frame; self.depth = depth; self.depthIntrinsics = depthIntrinsics
        self.ballImage = ballImage; self.ballIntrinsics = ballIntrinsics; self.tap = tap; self.floorY = floorY; self.trackingNormal = trackingNormal
    }
}

public enum TrackerState: String, Codable { case searching, confirming, locked }

/// What the app shows.
public struct Readouts: Equatable, Codable {
    public var tiltDegrees: Double
    /// apex height above the launch point (m)
    public var apexHeight: Double
    /// horizontal distance from launch to landing (m)
    public var landingDistance: Double
    public var airTime: Double
    /// drop height used (m), and whether it came from the ball
    public var dropHeight: Double
    public var dropFromBall: Bool
}

public struct TrackerOutput {
    public var state: TrackerState
    /// the locked slab in world coordinates
    public var slab: SlabPose?
    /// its top corners projected into this frame (pixels of the processing frame)
    public var outline: [Vec2]?
    /// this frame's own detection, if one ran and succeeded
    public var measurement: [Vec2]?
    public var ball: (center: Vec3, circle: Vec2, radius: Double)?
    public var drop: DropPoint?
    public var path: BouncePath?
    public var readouts: Readouts?
    public var depth: DepthCheck?
    /// what happened this frame (for diagnostics), e.g. "locked", "recheck-ok", "relocked", "lost"
    public var events: [String]
}

/// The per-frame logic shared by the app and the replay tests: search, confirm, lock the slab in world space so its
/// outline holds still as the phone moves, re-check it now and then, re-lock if it was moved, and work out the bounce.
public final class SlabTracker {
    public var settings: TrackerSettings
    public let detector: SlabDetecting
    public let ballLocator: BallLocating?
    public private(set) var state: TrackerState = .searching
    public private(set) var history: [SlabPose] = []     // recent accepted measurements (world)
    public private(set) var slab: SlabPose?               // the lock (world), with LiDAR folded in when present
    public private(set) var imageSlab: SlabPose?          // the lock from the image alone (average of `history`)
    public private(set) var depth: DepthCheck?
    public private(set) var counts: [String: Int] = [:]
    public private(set) var lastSideModes: [String] = []
    public private(set) var lastFrameTime: Double = 0
    private var candidates: [SlabPose] = []                 // while confirming
    private var movers: [SlabPose] = []                     // disagreeing re-detections while locked
    private var lastCheck = -Double.infinity, lastGood = -Double.infinity, lastBall = -Double.infinity
    private var previousNormalCam: Vec3?
    private var ballState: (center: Vec3, circle: Vec2, radius: Double)?  // world centre

    public init(settings: TrackerSettings = TrackerSettings(), detector: SlabDetecting, ballLocator: BallLocating? = nil) {
        self.settings = settings; self.detector = detector; self.ballLocator = ballLocator
    }

    func bump(_ k: String) { counts[k, default: 0] += 1 }

    /// Whether the next frame at time t will run the slab detector (so the caller knows to prepare its image).
    public func detectionDue(at t: Double) -> Bool {
        t - lastCheck >= (state == .locked ? settings.recheckInterval : settings.searchInterval)
    }

    /// Whether the next frame at time t will run the ball finder (so the caller knows to prepare its image).
    public func ballDue(at t: Double) -> Bool {
        ballLocator != nil && state == .locked && t - lastBall >= settings.ballInterval
    }

    /// Forget the slab and search again.
    public func reset() {
        state = .searching; history = []; slab = nil; imageSlab = nil; candidates = []; movers = []; depth = nil
        lastCheck = -.infinity; lastGood = -.infinity; previousNormalCam = nil; ballState = nil; ballLocator?.reset()
        bump("reset")
    }

    /// Does pose b agree with pose a (same place, same facing)?
    func agrees(_ a: SlabPose, _ b: SlabPose) -> Bool {
        a.center.distance(to: b.center) < settings.matchDistance && Units.degrees(a.normal.angle(to: b.normal)) < settings.matchAngleDegrees
    }

    /// Robust average of poses: the centre is the per-axis median, the normal the mean of the normals within twice the
    /// match angle of the median-centred pose, the in-plane axes from the most recent pose turned onto that normal.
    static func average(_ poses: [SlabPose]) -> SlabPose? {
        guard let last = poses.last else { return nil }
        func med(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
        let c = Vec3(med(poses.map { $0.center.x }), med(poses.map { $0.center.y }), med(poses.map { $0.center.z }))
        var n = Vec3.zero
        for p in poses { n += p.normal }
        n = n.normalized
        // drop normals far from the mean and average again
        let keep = poses.filter { $0.normal.angle(to: n) < Units.radians(6) }
        if !keep.isEmpty { n = keep.reduce(Vec3.zero) { $0 + $1.normal }.normalized }
        let u = last.axisU.rejecting(n).normalized
        return SlabPose(center: c, normal: n, axisU: u, axisV: n.cross(u), halfU: last.halfU, halfV: last.halfV)
    }

    /// One frame. Cheap when locked and no re-check is due: projects the lock and works out the bounce.
    public func process(_ f: TrackerFrame) -> TrackerOutput {
        lastFrameTime = f.timestamp
        bump("frames")
        var events: [String] = []
        let downW = ARKitConvention.worldDown
        let downCam = f.view.directionToCamera(downW)
        var measurementQuad: [Vec2]? = nil

        if f.tap != nil { reset(); events.append("tap") }

        // when to run the detector
        let due = detectionDue(at: f.timestamp)
        if due && f.trackingNormal {
            lastCheck = f.timestamp
            let near = state == .locked ? imageSlab.flatMap { s in project(s, f.view) } : nil
            let found = detector.detect(frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam, seed: f.tap, near: near)
            bump(state == .locked ? "rechecks" : "searches")
            var measured: SlabPose? = nil
            for o in found {
                let fit = PoseSolver.solve(corners: o.quad, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam, previousNormal: previousNormalCam)
                let verdict = ShapeCheck.check(fit, outline: o.quad, down: downCam, limits: settings.shapeLimits)
                guard verdict == .ok, let fit = fit else { bump("reject:\(verdict)"); continue }
                measured = fit.pose.transformed(by: f.view.worldFromCamera)
                measurementQuad = o.quad
                lastSideModes = o.sideModes
                previousNormalCam = fit.pose.normal
                break
            }
            if let m = measured {
                bump("detections")
                switch state {
                case .searching:
                    candidates = [m]; state = .confirming; events.append("candidate")
                    if settings.confirmCount <= 1 { lock(candidates, &events) }
                case .confirming:
                    if let last = candidates.last, agrees(last, m) {
                        candidates.append(m)
                        if candidates.count >= settings.confirmCount { lock(candidates, &events) }
                    } else {
                        candidates = [m]; events.append("candidate-restart"); bump("confirmRestarts")
                    }
                case .locked:
                    if let s = imageSlab, agrees(s, m) {
                        history.append(m)
                        if history.count > settings.historySize { history.removeFirst(history.count - settings.historySize) }
                        imageSlab = SlabTracker.average(history)
                        movers = []; lastGood = f.timestamp
                        events.append("recheck-ok"); bump("recheckAgree")
                    } else {
                        bump("recheckDisagree")
                        if let last = movers.last, agrees(last, m) { movers.append(m) } else { movers = [m] }
                        if movers.count >= settings.moveCount {
                            history = movers; imageSlab = SlabTracker.average(history); movers = []; lastGood = f.timestamp
                            events.append("relocked"); bump("relocks"); ballLocator?.reset(); ballState = nil
                        } else { events.append("recheck-disagree") }
                    }
                }
            } else {
                switch state {
                case .confirming:
                    candidates = []; state = .searching; events.append("candidate-lost")
                case .locked:
                    // only count it as a miss when the slab should be in view
                    if let s = imageSlab, let q = project(s, f.view), q.allSatisfy({ f.view.intrinsics.contains($0, margin: 2) }) {
                        bump("recheckMiss")
                        if f.timestamp - lastGood > settings.lostAfter {
                            state = .searching; slab = nil; imageSlab = nil; history = []; depth = nil; events.append("lost"); bump("lost")
                        }
                    } else {
                        lastGood = f.timestamp // out of view: the lock in world space stays valid
                    }
                case .searching: break
                }
            }
        }

        // LiDAR check of the top, folded into the image lock (fresh each frame, so it never compounds)
        slab = imageSlab
        if state == .locked, let s = imageSlab, let d = f.depth, let dk = f.depthIntrinsics,
           let chk = PlaneFit.checkSlabTop(depth: d, depthIntrinsics: dk, view: f.view, slab: s, down: downW) {
            depth = chk
            bump("depthChecks")
            if settings.depthNormalWeight > 0, chk.points >= 60, chk.rms < 0.006, chk.angleToImageDegrees < 8 {
                let w = settings.depthNormalWeight
                let n = (s.normal * (1 - w) + chk.plane.normal * w).normalized, u = s.axisU.rejecting(n).normalized
                // the corner plane lies above the plane through the dish's inner 70% by the dish's mean depth there,
                // D (1 - 0.7^2 / 3) for the paraboloid
                var c = s.center
                if let p = chk.plane.intersect(origin: f.view.position, direction: (s.center - f.view.position).normalized) {
                    c = p + chk.plane.normal * (settings.spec.dishDepth * (1 - 0.49 / 3))
                }
                slab = SlabPose(center: s.center * (1 - w) + c * w, normal: n, axisU: u, axisV: n.cross(u), halfU: s.halfU, halfV: s.halfV)
                events.append("depth-fused")
            }
        }

        var out = TrackerOutput(state: state, slab: slab, outline: nil, measurement: measurementQuad, ball: nil, drop: nil, path: nil,
                                readouts: nil, depth: depth, events: events)
        guard state == .locked, let s = slab else { return out }
        out.outline = project(s, f.view)

        // the ball
        if let loc = ballLocator, let img = f.ballImage, let bk = f.ballIntrinsics, f.timestamp - lastBall >= settings.ballInterval {
            lastBall = f.timestamp
            let sc = s.transformed(by: f.view.cameraFromWorld)
            if let b = loc.locate(image: img, intrinsics: bk, slab: sc, spec: settings.spec, ball: settings.ball, down: downCam) {
                ballState = (f.view.toWorld(b.center), b.circle, b.radius); bump("ballFrames")
            } else { ballState = nil }
        }
        out.ball = ballState

        // the bounce, in world coordinates
        let floorBelow = f.floorY.map { s.center.y - $0 }.flatMap { $0 > 0.005 && $0 < 1.0 ? $0 : nil }
        let res = Bounce.compute(pose: s, spec: settings.spec, ball: settings.ball, down: downW, ballCenter: ballState?.center,
                                 defaultDropHeight: settings.defaultDropHeight, rule: settings.launchRule, floorBelowCenter: floorBelow)
        out.path = res.path; out.drop = res.drop
        out.readouts = Readouts(tiltDegrees: Units.degrees(s.tilt(down: downW)), apexHeight: res.path.apexHeight, landingDistance: res.path.range,
                                airTime: res.path.airTime, dropHeight: res.drop?.dropHeight ?? settings.defaultDropHeight, dropFromBall: res.drop != nil)
        return out
    }

    private func lock(_ poses: [SlabPose], _ events: inout [String]) {
        history = poses; imageSlab = SlabTracker.average(poses); slab = imageSlab; state = .locked; candidates = []; movers = []
        lastGood = lastFrameTime; events.append("locked"); bump("locks")
    }

    /// A world pose's top corners in a view's image.
    public func project(_ s: SlabPose, _ view: CameraView) -> [Vec2]? {
        let q = s.topCorners.compactMap { view.project(world: $0) }
        return q.count == 4 ? q : nil
    }
}
