import Foundation

/// Finds the slab's top-corner outline in a frame. The real one is SlabFinder; tests can plug in others.
public protocol SlabDetecting {
    /// Outlines (top corners, pixels of `frame`) best first, each starting at any corner and running either way round
    /// (`PoseFit.cornerOrder` maps them onto the pose). `seed`: a point the owner tapped (kept by the tracker and passed
    /// on every search until it locks); `near`: a predicted outline to search around (in the pose's corner order).
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline]
}

/// One outline a detector found.
public struct DetectedOutline: Equatable {
    public var quad: [Vec2]
    /// detector's own confidence, higher is better (only compared between outlines of one frame)
    public var score: Double
    /// per-side edge modes, for diagnostics (e.g. "top", "fromCutBottom", "silhouette"); side j runs from quad[j] to [j+1]
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
    /// consistent detections needed before locking (more while they cannot yet pin the normal: `maxLockSigmaDegrees`)
    public var confirmCount: Int = 3
    /// The smallest agreement gates (centre distance, normal angle): measurements this close always agree. The gates
    /// widen with the measurements' own uncertainty (`matchSigmas`), up to `maxMatchDistance` / `maxMatchAngleDegrees`.
    public var matchDistance: Double = 0.025
    public var matchAngleDegrees: Double = 4
    /// re-detections that disagree with the lock but agree with each other before re-locking (the slab was moved)
    public var moveCount: Int = 4
    /// seconds of failed re-detections, with the slab in view and tracking normal, before giving up the lock
    public var lostAfter: Double = 4
    /// how many recent measurements make up the lock (up to three times as many while fewer cannot pin its normal to
    /// `maxLockSigmaDegrees`, as from nearly straight above)
    public var historySize: Int = 15
    /// use LiDAR depth when present: fuse its (smoothed) plane's normal with this weight (0 = only report it)
    public var depthNormalWeight: Double = 0.5
    /// the ball finder runs at most this often (s)
    public var ballInterval: Double = 0.1
    /// Shape checks for every detection. The tracker's default also refuses fits that cannot pin the normal (views
    /// from nearly straight above): `maxNormalSigmaDegrees` 10 at 1 px corner noise.
    public var shapeLimits: ShapeCheck.Limits = TrackerSettings.defaultShapeLimits

    // Measurement noise. Each fit reports its uncertainty for 1 px corner noise (PoseFit.normalCovariance,
    // centreCovariance); the gates scale it by the detector's corner noise, measured from the re-checks once there are
    // enough of them (SlabTracker.cornerNoiseEstimate).
    /// the detector's corner noise (pixels of the processing frame) assumed before the tracker has measured it
    public var cornerNoisePixels: Double = 1
    /// Agreement gates in standard deviations of the two measurements' combined uncertainty (a Mahalanobis distance:
    /// the normal's uncertainty is far larger in one direction across it than the other, the centre's along the line
    /// of sight). 3 lets about 1 in 100 same-pose pairs fail on the normal.
    public var matchSigmas: Double = 3
    /// the gates never widen beyond these
    public var maxMatchDistance: Double = 0.08
    public var maxMatchAngleDegrees: Double = 10
    /// lock only once the confirming detections pin the normal to this (combined standard deviation, degrees)
    public var maxLockSigmaDegrees: Double = 1.5

    // Small slides: re-checks that pass the gates but sit consistently off the lock.
    /// how many recent re-checks are compared with the rest of the lock's history
    public var slideWindow: Int = 4
    /// how far apart (standard deviations of the two means, Mahalanobis) counts as a slide; 4.3 is about 1 false slide
    /// in 10,000 re-checks of a still slab
    public var slideSigmas: Double = 4.3

    // Moves and false moves.
    /// a re-detection disagreeing with the lock counts toward a re-lock only within this distance of it (and only while
    /// the lock is in view); larger jumps are left to a tap or to the lost rule
    public var moveRadius: Double = 0.2
    /// The cradle: distance from the sphere its bottom rocks in to the top's centre (about 17.2 in less the thickness).
    /// A slide that changes the tilt by an angle moves the centre about this far times that angle; a re-lock whose
    /// normal turns by degrees while its centre hardly moves (the near edge caught on the cut face) needs three times
    /// the usual evidence. nil: no such check.
    public var cradleRadius: Double? = Units.inches(16.2)
    /// a re-detection within this many pixels (rms over the corners) of the lock's outline with a side taken at the
    /// bottom of its cut face (the box model) is that flip, not a move
    public var cutFlipTolerancePixels: Double = 2

    // Losing the lock.
    /// consecutive in-view misses needed (as well as `lostAfter`) before the lock is lost
    public var minMissesForLost: Int = 3

    // World-frame discontinuities (ARKit relocalisation, an interruption, a pose snap).
    /// after one, a lock that is not seen where it should be within this many seconds of normal tracking expires
    public var unconfirmedTimeout: Double = 5
    /// a jump of the camera's reported position by more than this between consecutive frames is a discontinuity
    public var poseJumpDistance: Double = 0.25
    /// so is tracking returning to normal after being limited for this long (s)
    public var limitedResumeSeconds: Double = 2

    /// a tap seeds the search for this many seconds of normal tracking, until it locks
    public var seedTimeout: Double = 6

    // LiDAR.
    /// the depth plane is averaged over about this long (s) in world space before it is fused
    public var depthSmoothingSeconds: Double = 0.5
    /// and fused for this long after its last good frame
    public var depthHoldSeconds: Double = 1
    /// a frame's depth plane is used only if this share of the points inside the top lie on it
    public var depthMinInlierFraction: Double = 0.7
    /// and if the lock's centre sits where the dish says above it, within this share of the range (min 1 cm)
    public var depthMaxOffsetFraction: Double = 0.02
    /// and if it is within this angle of the image normal
    public var depthMaxAngleDegrees: Double = 8

    /// Rectangular slabs: which outline side is the long one is decided by a running sum of the two assignments' cost
    /// differences over detections (one frame at the processing frame's resolution says little: for a 7.2 x 6.8 in slab
    /// at 1 px noise it is wrong almost half the time). The sum is capped at this (cost units of the solver's 2.5 px
    /// sigma) so that a slab really turned by 90 degrees can win it back.
    public var sideEvidenceCap: Double = 4
    /// how much of the sum each new detection keeps (1: all of it)
    public var sideEvidenceDecay: Double = 1
    /// the evidence must favour the other side by this much before the tracker swaps (fewer swaps back and forth early on)
    public var sideFlipMargin: Double = 0.15
    /// until the evidence reaches this, re-check a locked rectangular slab at the search rate (more detections, sooner
    /// settled); 0 = always at the re-check rate
    public var sideDecidedEvidence: Double = 1

    public static let defaultShapeLimits: ShapeCheck.Limits = { var l = ShapeCheck.Limits(); l.maxNormalSigmaDegrees = 10; return l }()

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

/// Count, smallest, largest and last of a value (e.g. the misfit of rejected outlines).
public struct ValueSummary: Equatable, Codable {
    public var count: Int = 0
    public var min: Double = .infinity
    public var max: Double = -.infinity
    public var last: Double = 0
    public init() {}
    public mutating func add(_ v: Double) { count += 1; min = Swift.min(min, v); max = Swift.max(max, v); last = v }
    /// rounded to 4 significant decimals, for reports
    public var rounded: ValueSummary {
        var r = self
        func r4(_ v: Double) -> Double { v.isFinite ? (v * 10000).rounded() / 10000 : v }
        r.min = r4(min); r.max = r4(max); r.last = r4(last)
        return r
    }
}

public struct TrackerOutput {
    public var state: TrackerState
    /// the locked slab in world coordinates
    public var slab: SlabPose?
    /// its top corners projected into this frame (pixels of the processing frame)
    public var outline: [Vec2]?
    /// this frame's own detection, if one ran and succeeded (in the pose's corner order, like `outline`)
    public var measurement: [Vec2]?
    public var ball: (center: Vec3, circle: Vec2, radius: Double)?
    public var drop: DropPoint?
    public var path: BouncePath?
    public var readouts: Readouts?
    public var depth: DepthCheck?
    /// What changed this frame (for diagnostics), e.g. "locked", "relocked", "lost", "recheck-disagree",
    /// "depth-fused" (fusion turned on). Steady states are not repeated every frame; `SlabTracker.counts` counts them.
    public var events: [String]
    /// LiDAR's smoothed plane is folded into `slab` this frame
    public var depthFused: Bool = false
    /// after a world-frame discontinuity: the lock has not yet been seen where it should be (it expires if it is not)
    public var lockUnconfirmed: Bool = false
    /// how well the lock pins the normal (standard deviation, degrees) for the corner noise its measurements show
    public var lockSigmaDegrees: Double? = nil
    /// advice for the owner while it cannot lock, e.g. `SlabTracker.overheadHint`
    public var hint: String? = nil
}

/// The per-frame logic shared by the app and the replay tests: search, confirm, lock the slab in world space so its
/// outline holds still as the phone moves, re-check it now and then, re-lock if it was moved, and work out the bounce.
///
/// Measurements carry their own uncertainty (from the pose fit, scaled by the detector's corner noise as the lock's
/// history shows it), so the agreement gates follow the noise: a slab 5 ft away at the processing frame's 480 px is
/// measured far less precisely in depth than one at 2 ft. Re-detections that disagree with the lock are checked before
/// they can move it: a side taken at the bottom of its cut face (the box model), a far-away lookalike, a jump that LiDAR
/// contradicts, or a tilt change the cradle cannot make, are not moves.
public final class SlabTracker {
    public var settings: TrackerSettings
    public let detector: SlabDetecting
    public let ballLocator: BallLocating?
    public private(set) var state: TrackerState = .searching
    /// recent accepted measurements (world) that make up the lock
    public var history: [SlabPose] { hist.map { $0.pose } }
    public private(set) var slab: SlabPose?               // the lock (world), with LiDAR folded in when present
    public private(set) var imageSlab: SlabPose?          // the lock from the image alone (average of `history`)
    public private(set) var depth: DepthCheck?
    public private(set) var counts: [String: Int] = [:]
    /// the last detection's per-side edge modes, in the pose's side order (side i runs from outline corner i to i+1)
    public private(set) var lastSideModes: [String] = []
    public private(set) var lastFrameTime: Double = 0
    /// the values behind the rejection counters, per kind ("misfit", "tooTilted", "illConditioned")
    public private(set) var rejectionValues: [String: ValueSummary] = [:]
    /// how well the lock pins the normal (degrees), for the corner noise its measurements show
    public private(set) var lockSigmaDegrees: Double?
    /// rectangular slabs: the long side's direction (world) the evidence so far favours
    public private(set) var longSideWorld: Vec3?
    /// where a tap said to look (world), until it locks or times out
    public var seedPoint: Vec3? { seed?.world }
    /// after a world-frame discontinuity, until the lock is seen again where it should be
    public var lockUnconfirmed: Bool { unconfirmed != nil }

    /// The advice shown while views from nearly straight above cannot pin the tilt.
    public static let overheadHint = "Hard to see the tilt from straight above: view the slab at more of an angle"

    /// One pose estimate (world) with its uncertainty for 1 px corner noise.
    struct Estimate {
        var pose: SlabPose
        /// the normal's angular standard deviation (radians, both axes)
        var sigma: Double
        /// the normal's covariance (world axes, rad^2; nothing along the normal)
        var ncov: Mat3
        /// the centre's covariance (world axes, m^2)
        var cov: Mat3
        var cost: Double
    }

    /// One detection: its estimate, the other side assignment for a rectangular slab, and the outline in pose order.
    struct Measurement {
        var est: Estimate
        var alt: Estimate?
        var quad: [Vec2]
        var sideModes: [String]
        var time: Double
        var pose: SlabPose { est.pose }
        mutating func swapSides() { if let a = alt { alt = est; est = a } }
    }

    struct DepthEstimate { var normal: Vec3; var offset: Double; var count: Int; var time: Double }

    private var hist: [Measurement] = []
    private var lockEstimate: Estimate?
    private var candidates: [Measurement] = []             // while confirming
    private var movers: [Measurement] = []                 // disagreeing re-detections while locked
    private var recent: [Measurement] = []                 // the latest re-detections near the lock, agreeing or not
    private var implausible = 0                            // re-locks held back as implausible since the last one
    private var noiseSamples: [Double] = []                // re-checks' squared distances from the lock (see cornerNoiseEstimate)
    private var lastCheck = -Double.infinity, lastGood = -Double.infinity, lastBall = -Double.infinity, lastBallSeen = -Double.infinity
    private var previousTime: Double?
    private var lastMeasured: (normal: Vec3, time: Double)?
    private var ballState: (center: Vec3, circle: Vec2, radius: Double)?  // world centre
    private var misses = 0
    private var unconfirmed: (elapsed: Double, rechecks: Int)?
    private var pendingDiscontinuity: String?
    private var lastNormalFrame: (time: Double, position: Vec3)?
    private var limitedSince: Double?
    private var seed: (world: Vec3, age: Double)?
    private var tapResetPending = false
    private var sideEvidence = 0.0
    private var depthEstimate: DepthEstimate?
    private var fusing = false
    private var lastRecheckKind = "ok"
    private var lastHintTime = -Double.infinity
    private var weakRejections = 0                         // outlines rejected as ill-conditioned in this detection

    public init(settings: TrackerSettings = TrackerSettings(), detector: SlabDetecting, ballLocator: BallLocating? = nil) {
        self.settings = settings; self.detector = detector; self.ballLocator = ballLocator
    }

    func bump(_ k: String) { counts[k, default: 0] += 1 }

    /// Whether the next frame at time t will run the slab detector (so the caller knows to prepare its image).
    public func detectionDue(at t: Double) -> Bool {
        t - lastCheck >= (state == .locked && !sidesUndecided ? settings.recheckInterval : settings.searchInterval)
    }

    /// a rectangular slab whose long side the evidence has not settled yet: re-check at the search rate to gather it
    private var sidesUndecided: Bool {
        settings.spec.sideU != settings.spec.sideV && settings.sideDecidedEvidence > 0 && abs(sideEvidence) < settings.sideDecidedEvidence
    }

    /// Whether the next frame at time t will run the ball finder (so the caller knows to prepare its image).
    public func ballDue(at t: Double) -> Bool {
        ballLocator != nil && state == .locked && t - lastBall >= settings.ballInterval
    }

    /// Forget the slab and search again.
    public func reset() {
        forget()
        seed = nil; tapResetPending = false; noiseSamples = []
        bump("reset")
    }

    /// ARKit's world frame may have moved under the lock: call when an interruption ends, when ARKit relocalises, or on
    /// any other reason to doubt the stored world coordinates. The lock is kept but must be seen where it should be (or a
    /// consistent slab elsewhere in view re-locks it) within `unconfirmedTimeout` seconds of normal tracking, or it
    /// expires ("lost"). The next frame runs a detection. The tracker notices large jumps of the camera's position and a
    /// long spell of limited tracking by itself.
    public func noteWorldDiscontinuity(_ reason: String = "world-frame") {
        pendingDiscontinuity = reason
        lastCheck = -.infinity
    }

    /// The detector's corner noise (pixels of the processing frame) as the re-checks show it: how far each one's
    /// normal lay from the lock, in its own covariance's terms, over the last 60 re-checks near the lock. That is s^2
    /// times chi-square with 2 degrees of freedom (median 2 ln 2). The assumed `cornerNoisePixels` until there are 8.
    public var cornerNoiseEstimate: Double {
        guard noiseSamples.count >= 8 else { return settings.cornerNoisePixels }
        let r = noiseSamples.sorted()
        return clamp((r[r.count / 2] / (2 * log(2.0))).squareRoot(), 0.25, 4)
    }

    // MARK: pose estimates

    /// Robust average of poses: the centre is the per-axis median, the normal the mean of the normals within twice the
    /// match angle of the median-centred pose, the in-plane axes from the most recent pose turned onto that normal.
    static func average(_ poses: [SlabPose]) -> SlabPose? {
        average(poses, weights: poses.map { _ in 1 }, keepWithin: poses.map { _ in Units.radians(6) })
    }

    /// The same with weights on the normals (inverse variance) and per-pose outlier limits.
    static func average(_ poses: [SlabPose], weights: [Double], keepWithin: [Double]) -> SlabPose? {
        guard let last = poses.last else { return nil }
        func med(_ v: [Double]) -> Double { let s = v.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
        let c = Vec3(med(poses.map { $0.center.x }), med(poses.map { $0.center.y }), med(poses.map { $0.center.z }))
        var n = Vec3.zero
        for (p, w) in zip(poses, weights) { n += p.normal * w }
        n = n.normalized
        // drop normals far from the mean and average again
        var m = Vec3.zero
        for (i, p) in poses.enumerated() where p.normal.angle(to: n) < keepWithin[i] { m += p.normal * weights[i] }
        if m.length > 0 { n = m.normalized }
        let u = last.axisU.rejecting(n).normalized
        return SlabPose(center: c, normal: n, axisU: u, axisV: n.cross(u), halfU: last.halfU, halfV: last.halfV)
    }

    /// The combined estimate of several measurements: inverse-variance mean normal, median centre.
    static func estimate(_ ms: [Measurement]) -> Estimate? {
        guard !ms.isEmpty else { return nil }
        let sig = ms.map { max($0.est.sigma, Units.radians(0.05)) }
        let w = sig.map { 1 / ($0 * $0) }
        let keepWithin = sig.map { max(Units.radians(6), 3 * $0) }
        guard var p = average(ms.map { $0.pose }, weights: w, keepWithin: keepWithin) else { return nil }
        // the normal: each measurement weighted by its own (direction-dependent) information, across the first guess
        let n0 = p.normal
        var J = zeroMat3, b = Vec3.zero
        for (i, m) in ms.enumerated() where m.pose.normal.angle(to: n0) < keepWithin[i] {
            let Ji = information(m.est.ncov, n0)
            J = madd(J, Ji); b = b + Ji * (m.pose.normal - n0).rejecting(n0)
        }
        let C = covariance(fromInformation: J, n0)
        let n = (n0 + C * b).normalized, u = p.axisU.rejecting(n).normalized
        p = SlabPose(center: p.center, normal: n, axisU: u, axisV: n.cross(u), halfU: p.halfU, halfV: p.halfV)
        var cov = zeroMat3
        for m in ms { cov = madd(cov, m.est.cov) }
        let count = Double(ms.count)
        return Estimate(pose: p, sigma: max(0, trace(C)).squareRoot(), ncov: C, cov: mscale(cov, 1 / (count * count)), cost: 0)
    }

    /// The information (inverse covariance) of a normal's direction across n, from its covariance; a small floor keeps
    /// exact measurements finite.
    static func information(_ C: Mat3, _ n: Vec3) -> Mat3 {
        let P = outer(n, n), fl = pow(Units.radians(0.05), 2)
        guard let Ai = madd(madd(C, mscale(madd(.identity, mscale(P, -1)), fl)), P).inverse else { return zeroMat3 }
        return madd(Ai, mscale(P, -1))
    }

    /// The covariance across n from summed information.
    static func covariance(fromInformation J: Mat3, _ n: Vec3) -> Mat3 {
        let P = outer(n, n)
        guard let Ai = madd(J, P).inverse else { return zeroMat3 }
        return madd(Ai, mscale(P, -1))
    }

    /// (b - a) across a, squared, in units of the covariance C (chi-square with 2 degrees of freedom when C is right).
    static func mahalanobis2(_ b: Vec3, _ a: Vec3, _ C: Mat3) -> Double {
        let d = (b - a).rejecting(a)
        return d.dot(information(C, a) * d)
    }

    /// Does b agree with a (same place, same facing), given their uncertainties and corner noise s (pixels)?
    func agrees(_ a: Estimate, _ b: Estimate, noise s: Double) -> Bool {
        let ang = Units.degrees(a.pose.normal.angle(to: b.pose.normal))
        if ang > max(settings.matchAngleDegrees, settings.maxMatchAngleDegrees) { return false }
        if ang > settings.matchAngleDegrees,
           SlabTracker.mahalanobis2(b.pose.normal, a.pose.normal, mscale(madd(a.ncov, b.ncov), s * s)) > pow(settings.matchSigmas, 2) { return false }
        let d = b.pose.center - a.pose.center, len = d.length
        if len <= settings.matchDistance { return true }
        if len > max(settings.matchDistance, settings.maxMatchDistance) { return false }
        let floorSigma = settings.matchDistance / max(settings.matchSigmas, 1)
        let S = madd(mscale(madd(a.cov, b.cov), s * s), mscale(.identity, floorSigma * floorSigma))
        guard let Si = S.inverse else { return false }
        return d.dot(Si * d) <= pow(settings.matchSigmas + 1, 2)   // three degrees of freedom
    }

    /// Does pose b agree with pose a (same place, same facing), with the fixed smallest gates?
    func agrees(_ a: SlabPose, _ b: SlabPose) -> Bool {
        a.center.distance(to: b.center) < settings.matchDistance && Units.degrees(a.normal.angle(to: b.normal)) < settings.matchAngleDegrees
    }

    private func refreshLock() {
        lockEstimate = SlabTracker.estimate(hist)
        imageSlab = lockEstimate?.pose
        lockSigmaDegrees = lockEstimate.map { Units.degrees($0.sigma) * cornerNoiseEstimate }
    }

    /// The newest `historySize` measurements, or more (up to three times as many) while fewer could not pin the normal
    /// to `maxLockSigmaDegrees`.
    private func trimmed(_ ms: [Measurement]) -> [Measurement] {
        let n = max(1, settings.historySize)
        guard ms.count > n else { return ms }
        var out = Array(ms.suffix(3 * n))
        let s = cornerNoiseEstimate
        while out.count > n, let e = SlabTracker.estimate(Array(out.dropFirst())), Units.degrees(e.sigma) * s <= settings.maxLockSigmaDegrees {
            out.removeFirst()
        }
        return out
    }

    // MARK: one frame

    /// One frame. Cheap when locked and no re-check is due: projects the lock and works out the bounce.
    public func process(_ f: TrackerFrame) -> TrackerOutput {
        let t = f.timestamp
        let dt = previousTime.map { clamp(t - $0, 0, 0.5) } ?? 0
        previousTime = t
        lastFrameTime = t
        bump("frames")
        var events: [String] = []
        let downW = ARKitConvention.worldDown
        let downCam = f.view.directionToCamera(downW)
        var measurementQuad: [Vec2]? = nil

        // a tap: look for the slab there until it locks; with tracking limited, start over once it is normal again
        if let tp = f.tap {
            seed = (seedPoint(for: tp, f), 0)
            tapResetPending = true
            lastCheck = -.infinity
            events.append("tap")
        }
        if tapResetPending {
            if f.trackingNormal { forget(); bump("reset"); tapResetPending = false } else if f.tap != nil { events.append("tap-deferred") }
        }

        let due = detectionDue(at: t)

        // world-frame discontinuities: reported by the app, a jump of the camera, or a long spell of limited tracking
        var discontinuity = pendingDiscontinuity
        pendingDiscontinuity = nil
        if f.trackingNormal {
            if let last = lastNormalFrame, t - last.time < 0.25,
               f.view.position.distance(to: last.position) > max(settings.poseJumpDistance, 3 * (t - last.time)) {
                discontinuity = discontinuity ?? "pose-jump"
            }
            if let since = limitedSince, t - since >= settings.limitedResumeSeconds { discontinuity = discontinuity ?? "tracking-resumed" }
            limitedSince = nil
            lastNormalFrame = (t, f.view.position)
        } else if limitedSince == nil {
            limitedSince = t
        }
        if let reason = discontinuity { onDiscontinuity(reason, &events) }

        // clocks: time with tracking limited does not count toward losing the lock, nor toward an unconfirmed lock's expiry
        if state == .locked && !f.trackingNormal { lastGood = max(lastGood, t) }
        if state == .locked, f.trackingNormal, var u = unconfirmed {
            u.elapsed += dt
            unconfirmed = u
            if u.elapsed > settings.unconfirmedTimeout { events.append("lock-expired"); lose(&events) }
        }
        if f.trackingNormal, var s = seed {
            s.age += dt
            seed = s
            if s.age > settings.seedTimeout { seed = nil; events.append("seed-expired") }
        }

        // LiDAR's view of the lock's top: for occlusion and re-lock checks, and folded in below
        func depthCheck(_ s: SlabPose) -> DepthCheck? {
            guard let d = f.depth, let dk = f.depthIntrinsics else { return nil }
            return PlaneFit.checkSlabTop(depth: d, depthIntrinsics: dk, view: f.view, slab: s, down: downW)
        }
        var chk: DepthCheck? = nil, chkFor: SlabPose? = nil
        if state == .locked, let s = imageSlab, f.depth != nil { chk = depthCheck(s); chkFor = s }

        if due && f.trackingNormal {
            lastCheck = t
            detect(f, downCam, chk, depthCheck, &events, &measurementQuad)
        }

        // LiDAR: the depth plane, averaged in world space over frames that pass its gates, folded into the image lock
        slab = imageSlab
        var fused = false
        if state == .locked, let s = imageSlab {
            if f.depth != nil {
                if chkFor != s { chk = depthCheck(s) }
                if let c = chk {
                    depth = c
                    bump("depthChecks")
                    if depthUsable(c, s, f, maxAngle: settings.depthMaxAngleDegrees) { addDepth(c, t) } else { bump("depthRejected") }
                }
            }
            if settings.depthNormalWeight > 0, let e = depthEstimate, t - e.time <= settings.depthHoldSeconds {
                slab = fuse(s, e, f)
                fused = true
                bump("depthFused")
            }
        }
        if fused != fusing {
            if state == .locked { events.append(fused ? "depth-fused" : "depth-unfused") }
            fusing = fused
        }

        var out = TrackerOutput(state: state, slab: slab, outline: nil, measurement: measurementQuad, ball: nil, drop: nil, path: nil,
                                readouts: nil, depth: depth, events: events)
        out.depthFused = fused
        out.lockUnconfirmed = state == .locked && unconfirmed != nil
        out.lockSigmaDegrees = state == .locked ? lockSigmaDegrees : nil
        out.hint = state != .locked && t - lastHintTime < 2 ? SlabTracker.overheadHint : nil
        guard state == .locked, let s = slab else { return out }
        out.outline = project(s, f.view)

        // the ball
        if let loc = ballLocator, let img = f.ballImage, let bk = f.ballIntrinsics, f.timestamp - lastBall >= settings.ballInterval {
            lastBall = f.timestamp
            let sc = s.transformed(by: f.view.cameraFromWorld)
            if let b = loc.locate(image: img, intrinsics: bk, slab: sc, spec: settings.spec, ball: settings.ball, down: downCam) {
                ballState = (f.view.toWorld(b.center), b.circle, b.radius); bump("ballFrames"); lastBallSeen = t
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

    // MARK: detection

    private func detect(_ f: TrackerFrame, _ downCam: Vec3, _ chk: DepthCheck?, _ depthCheck: (SlabPose) -> DepthCheck?,
                        _ events: inout [String], _ measurementQuad: inout [Vec2]?) {
        let t = f.timestamp
        let lockQ = imageSlab.flatMap { project($0, f.view) }
        let inView = lockQ.map { q in q.allSatisfy { f.view.intrinsics.contains($0, margin: 2) } } ?? false
        var near: [Vec2]? = state == .locked ? lockQ : nil
        if state == .locked, var u = unconfirmed {
            // the lock may be stale: also look over the whole view
            u.rechecks += 1
            unconfirmed = u
            if !inView || u.rechecks % 2 == 0 { near = nil }
        }
        let seedPx: Vec2? = state == .locked ? nil : seed.flatMap { f.view.project(world: $0.world) }.flatMap { f.view.intrinsics.contains($0) ? $0 : nil }
        let found = detector.detect(frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam, seed: seedPx, near: near)
        bump(state == .locked ? "rechecks" : "searches")
        let reference = referenceNormal(t).map { f.view.directionToCamera($0) }
        weakRejections = 0
        let options = found.compactMap { measure($0, f, downCam, reference) }
        guard let chosen = choose(options, f, seedPx: seedPx) else {
            switch state {
            case .confirming:
                // an outline seen too nearly face-on to pin the tilt is still the slab: keep what is being confirmed
                if weakRejections > 0 && weakRejections == found.count { bump("confirmWeak"); break }
                candidates = []; state = .searching; events.append("candidate-lost")
            case .locked:
                miss(f, inView: inView, chk: chk, found: found, lockQ: lockQ, &events)
            case .searching: break
            }
            return
        }
        bump("detections")
        measurementQuad = chosen.quad
        lastSideModes = chosen.sideModes
        switch state {
        case .searching:
            let m = applySideEvidence(chosen, &events)
            lastMeasured = (m.pose.normal, t)
            candidates = [m]; state = .confirming; events.append("candidate")
            tryLock(t, &events)
        case .confirming:
            confirm(applySideEvidence(chosen, &events), f, &events)
        case .locked:
            recheck(chosen, f, inView: inView, chk: chk, depthCheck: depthCheck, found: found, lockQ: lockQ, &events)
        }
    }

    /// A detected outline's pose(s), checked; nil (and counted) if it fails the shape check.
    private func measure(_ o: DetectedOutline, _ f: TrackerFrame, _ downCam: Vec3, _ previousNormal: Vec3?) -> Measurement? {
        let fits = PoseSolver.solveAssignments(corners: o.quad, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam,
                                               previousNormal: previousNormal)
        var chosen = fits.first, other: PoseFit? = nil
        if fits.count == 2 {
            var first = fits[0].bestCost <= fits[1].bestCost
            if let H = longSideWorld, let a = fits[0].longSide, let b = fits[1].longSide {
                let w = f.view.worldFromCamera
                first = abs(w.applyDirection(a).dot(H)) >= abs(w.applyDirection(b).dot(H))
            }
            chosen = first ? fits[0] : fits[1]; other = first ? fits[1] : fits[0]
        }
        let verdict = ShapeCheck.check(chosen, outline: o.quad, down: downCam, limits: settings.shapeLimits)
        guard verdict == .ok, let fit = chosen else { reject(verdict, f.timestamp); return nil }
        let w = f.view.worldFromCamera, R = w.rotation, Rt = R.transposed
        func est(_ p: PoseFit) -> Estimate {
            let pose = p.pose.transformed(by: w)
            guard p.normalSigmaDegrees > 0 else {
                // the solver could not say how well the corners pin it: treat it as a poorly pinned measurement
                let sg = Units.radians(5), n = pose.normal
                let across = Mat3(rows: [1 - n.x * n.x, -n.x * n.y, -n.x * n.z, -n.y * n.x, 1 - n.y * n.y, -n.y * n.z, -n.z * n.x, -n.z * n.y, 1 - n.z * n.z])
                return Estimate(pose: pose, sigma: sg, ncov: mscale(across, sg * sg / 2), cov: mscale(.identity, 0.03 * 0.03), cost: p.bestCost)
            }
            return Estimate(pose: pose, sigma: Units.radians(p.normalSigmaDegrees), ncov: R * p.normalCovariance * Rt,
                            cov: R * p.centreCovariance * Rt, cost: p.bestCost)
        }
        return Measurement(est: est(fit), alt: other.map(est), quad: fit.cornersInPoseOrder(o.quad),
                           sideModes: o.sideModes.count == 4 ? fit.sidesInPoseOrder(o.sideModes) : o.sideModes, time: f.timestamp)
    }

    private func reject(_ v: ShapeCheck.Verdict, _ t: Double) {
        bump("reject:" + v.key)
        if let x = v.value { rejectionValues[v.key, default: ValueSummary()].add(x) }
        if case .illConditioned = v { lastHintTime = t; weakRejections += 1 }
    }

    /// Which of a frame's outlines to use: one on the tapped point, else one that agrees with what is being confirmed or
    /// with the lock (or is its cut-face flip), else one near the lock, else the detector's best.
    private func choose(_ ms: [Measurement], _ f: TrackerFrame, seedPx: Vec2?) -> Measurement? {
        guard let first = ms.first else { return nil }
        if let sp = seedPx, let m = ms.first(where: { SlabTracker.contains($0.quad, sp, slack: 0.25) }) { return m }
        switch state {
        case .searching: return first
        case .confirming:
            guard let ref = SlabTracker.estimate(candidates) else { return first }
            let s = cornerNoiseEstimate
            return ms.first { agrees(ref, $0.est, noise: s) || cutFlip($0.quad, of: ref.pose, f, noise: s) != nil } ?? first
        case .locked:
            guard let ref = lockEstimate else { return first }
            let s = cornerNoiseEstimate
            return ms.first { agrees(ref, $0.est, noise: s) || cutFlip($0.quad, of: ref.pose, f, noise: s) != nil }
                ?? ms.first { $0.pose.center.distance(to: ref.pose.center) <= settings.moveRadius }
                ?? first
        }
    }

    /// The normal to prefer between the two mirror-image solutions (world): the lock's, or the confirming candidates'
    /// (not one noisy measurement's, which would let a run of mirror solutions follow each other), else the last
    /// measurement's.
    private func referenceNormal(_ t: Double) -> Vec3? {
        if state == .locked, let n = lockEstimate?.pose.normal { return n }
        if state == .confirming, let e = SlabTracker.estimate(candidates) { return e.pose.normal }
        if let m = lastMeasured, t - m.time < 1.5 { return m.normal }
        return nil
    }

    // MARK: confirming

    private func confirm(_ m: Measurement, _ f: TrackerFrame, _ events: inout [String]) {
        let t = f.timestamp, s = cornerNoiseEstimate
        guard let ref = SlabTracker.estimate(candidates) else { candidates = [m]; return }
        // one side caught at the bottom of its cut face: keep the inner (top) outline
        if cutFlip(m.quad, of: ref.pose, f, noise: s) != nil {
            bump("cutFlips"); note("candidate-cutflip", &events)
            return
        }
        if let rq = project(ref.pose, f.view), cutFlip(rq, of: m.pose, f, noise: s) != nil {
            bump("cutFlips"); bump("confirmRestarts")
            candidates = [m]; lastMeasured = (m.pose.normal, t); events.append("candidate-restart")
            return
        }
        lastMeasured = (m.pose.normal, t)
        if agrees(ref, m.est, noise: s) {
            candidates.append(m)
            candidates = trimmed(candidates)
            tryLock(t, &events)
        } else {
            candidates = [m]; events.append("candidate-restart"); bump("confirmRestarts")
        }
    }

    private func tryLock(_ t: Double, _ events: inout [String]) {
        guard candidates.count >= max(1, settings.confirmCount), let e = SlabTracker.estimate(candidates) else { return }
        if Units.degrees(e.sigma) * cornerNoiseEstimate <= settings.maxLockSigmaDegrees {
            lock(t, &events)
        } else {
            bump("lockWaits")
            // still not pinned after many agreeing views: tell the owner why
            if candidates.count >= 2 * max(1, settings.confirmCount) { lastHintTime = t }
        }
    }

    private func lock(_ t: Double, _ events: inout [String]) {
        hist = candidates; refreshLock(); slab = imageSlab; state = .locked; candidates = []; movers = []; recent = []; implausible = 0
        lastGood = t; misses = 0; unconfirmed = nil; seed = nil; depthEstimate = nil; lastRecheckKind = "ok"
        events.append("locked"); bump("locks")
    }

    // MARK: re-checks while locked

    private func recheck(_ m0: Measurement, _ f: TrackerFrame, inView: Bool, chk: DepthCheck?, depthCheck: (SlabPose) -> DepthCheck?,
                         found: [DetectedOutline], lockQ: [Vec2]?, _ events: inout [String]) {
        guard let L = lockEstimate else { return }
        let t = f.timestamp, s = cornerNoiseEstimate
        // the near edge caught at the bottom of its cut face: the lock is where it was, but this outline is not the top
        if cutFlip(m0.quad, of: L.pose, f, noise: s) != nil {
            bump("recheckCutFlip"); lastGood = t; misses = 0
            if unconfirmed != nil { confirmLock(&events) }
            note("recheck-cutflip", &events)
            return
        }
        let nearLock = m0.pose.center.distance(to: L.pose.center) <= settings.moveRadius
        // a lookalike far away, or anything while the lock is out of view: not a move (a tap or the lost rule handles that)
        if unconfirmed == nil && !(inView && nearLock) {
            bump("recheckDisagree"); bump("recheckFar"); note("recheck-far", &events)
            if inView { miss(f, inView: inView, chk: chk, found: [], lockQ: lockQ, &events) } else { lastGood = t; misses = 0 }
            return
        }
        let m = applySideEvidence(m0, &events)
        guard let L2 = lockEstimate else { return }  // the side evidence may have swapped the lock
        lastMeasured = (m.pose.normal, t)
        recent.append(m)
        if recent.count > max(2, settings.slideWindow) { recent.removeFirst(recent.count - max(2, settings.slideWindow)) }
        let agreed = agrees(L2, m.est, noise: s)
        if agreed {
            // the detector's noise, from how far agreeing re-checks land from the lock (before this one joins it); not
            // from the others, or a sustained systematic error would widen the gates enough to let itself in
            noiseSamples.append(SlabTracker.mahalanobis2(m.pose.normal, L2.pose.normal, madd(m.est.ncov, L2.ncov)))
            if noiseSamples.count > 60 { noiseSamples.removeFirst(noiseSamples.count - 60) }
            hist.append(m)
            hist = trimmed(hist)
            refreshLock()
            // a re-check nearer the would-be move than the lock still counts toward it
            if let me = SlabTracker.estimate(movers), m.pose.normal.angle(to: me.pose.normal) < m.pose.normal.angle(to: L2.pose.normal) {
                movers.append(m)
            } else {
                movers = []; implausible = 0
            }
            lastGood = t; misses = 0
            bump("recheckAgree"); note("ok", &events)
            if unconfirmed != nil { confirmLock(&events) }
        } else {
            bump("recheckDisagree")
            if let me = SlabTracker.estimate(movers), agrees(me, m.est, noise: s) { movers.append(m) } else { movers = [m]; implausible = 0 }
        }
        var relocked = false
        if movers.count >= settings.moveCount {
            relocked = tryRelock(to: movers, f, chk: chk, depthCheck: depthCheck, slide: false, &events)
        } else if let r = detectSlide() {
            relocked = tryRelock(to: r, f, chk: chk, depthCheck: depthCheck, slide: true, &events)
        }
        if !agreed && !relocked { note("recheck-disagree", &events) }
    }

    /// Re-detections that agree with each other but not with the lock (the slab was moved, or slid a little): re-lock
    /// onto them, unless LiDAR contradicts them or the cradle could not have made the change (then only after three times
    /// the evidence).
    @discardableResult
    private func tryRelock(to ms: [Measurement], _ f: TrackerFrame, chk: DepthCheck?, depthCheck: (SlabPose) -> DepthCheck?, slide: Bool,
                           _ events: inout [String]) -> Bool {
        guard let L = lockEstimate, let M = SlabTracker.estimate(ms) else { return false }
        var depthAgrees = false
        if let lc = chk, let mc = depthCheck(M.pose) {
            if lc.angleToImageDegrees < 4 && mc.angleToImageDegrees > lc.angleToImageDegrees + 4 {
                bump("relockRejectedDepth"); events.append("relock-rejected-depth")
                movers = []; recent = []
                return false
            }
            depthAgrees = mc.angleToImageDegrees < 4
        }
        if unconfirmed == nil, !depthAgrees, !plausibleSlide(from: L, to: M) {
            implausible += 1
            if implausible == 1 { bump("relockImplausible"); events.append("relock-implausible") }
            if implausible < 2 * settings.moveCount { return false }
        }
        hist = ms; refreshLock(); movers = []; recent = []; implausible = 0
        lastGood = f.timestamp; misses = 0; unconfirmed = nil; depthEstimate = nil; lastRecheckKind = "ok"
        events.append("relocked"); bump("relocks"); if slide { bump("slides") }
        ballLocator?.reset(); ballState = nil
        return true
    }

    /// In the cradle the top's centre moves about `cradleRadius` times the change of tilt, opposite the way the normal
    /// leans. A near edge flipping to the cut face's bottom turns the normal by degrees with the centre almost still.
    private func plausibleSlide(from L: Estimate, to M: Estimate) -> Bool {
        guard let R = settings.cradleRadius else { return true }
        let dn = M.pose.normal - L.pose.normal, a = dn.length
        guard Units.degrees(a) > 3 else { return true }
        let dir = dn / -a, along = (M.pose.center - L.pose.center).dot(dir)
        let s = cornerNoiseEstimate
        let tol = 0.01 + 2 * s * max(0, dir.dot(madd(M.cov, L.cov) * dir)).squareRoot()
        return along >= 0.5 * R * a - tol
    }

    /// A small slide: the newest `slideWindow` re-checks near the lock (agreeing with it or not) sit consistently off
    /// the measurements before them, by more than `slideSigmas` standard deviations of the two means. Then the lock
    /// moves to them now instead of creeping there over the whole history. Returns them.
    private func detectSlide() -> [Measurement]? {
        let k = max(2, settings.slideWindow)
        guard recent.count >= k, let t0 = recent.first?.time else { return nil }
        let older = hist.filter { $0.time < t0 }
        guard older.count >= 3, let eR = SlabTracker.estimate(recent), let eO = SlabTracker.estimate(older) else { return nil }
        let s = cornerNoiseEstimate
        let ang = eR.pose.normal.angle(to: eO.pose.normal)
        let angStep = Units.degrees(ang) > 0.5
            && SlabTracker.mahalanobis2(eR.pose.normal, eO.pose.normal, mscale(madd(eR.ncov, eO.ncov), s * s)) > pow(settings.slideSigmas, 2)
        let d = eR.pose.center - eO.pose.center
        var centreStep = false
        if d.length > 0.005, let Si = madd(mscale(madd(eR.cov, eO.cov), s * s), mscale(.identity, 4e-6)).inverse {
            centreStep = d.dot(Si * d) > pow(settings.slideSigmas + 1.5, 2)   // three degrees of freedom
        }
        guard angStep || centreStep else { return nil }
        // every one of the recent re-checks sits on the new side
        let consistent = recent.allSatisfy { m in
            angStep ? m.pose.normal.angle(to: eR.pose.normal) < m.pose.normal.angle(to: eO.pose.normal)
                    : m.pose.center.distance(to: eR.pose.center) < m.pose.center.distance(to: eO.pose.center)
        }
        return consistent ? recent : nil
    }

    /// No usable outline this re-check.
    private func miss(_ f: TrackerFrame, inView: Bool, chk: DepthCheck?, found: [DetectedOutline], lockQ: [Vec2]?, _ events: inout [String]) {
        let t = f.timestamp
        guard inView else {
            // out of view: the lock in world space stays valid (unless a discontinuity left it unconfirmed)
            if unconfirmed == nil { lastGood = t; misses = 0 }
            return
        }
        if unconfirmed == nil {
            // hidden rather than gone: a ball held over it, LiDAR still sees the top where the lock is, or the detector
            // found a misshapen outline there (a hand over a corner)
            let ball = ballState != nil && t - lastBallSeen < 1
            let lidar = chk.map { c in imageSlab.map { depthUsable(c, $0, f, maxAngle: 5) } ?? false } ?? false
            let partial = lockQ.map { q in
                found.contains { o in
                    guard o.quad.count == 4 else { return false }
                    let c = o.quad.reduce(Vec2.zero) { $0 + $1 } / 4, r = ShapeCheck.meanSide(o.quad) / max(ShapeCheck.meanSide(q), 1e-9)
                    return SlabTracker.contains(q, c, slack: 0) && r > 0.6 && r < 1.6
                }
            } ?? false
            if ball || lidar || partial {
                lastGood = t; misses = 0
                bump("recheckMissExcused")
                return
            }
        }
        bump("recheckMiss")
        misses += 1
        if t - lastGood > settings.lostAfter && misses >= settings.minMissesForLost { lose(&events) }
    }

    private func confirmLock(_ events: inout [String]) {
        unconfirmed = nil
        events.append("lock-confirmed")
    }

    /// Re-check outcomes that repeat (a sustained disagreement or flip) are reported once, when they start.
    private func note(_ kind: String, _ events: inout [String]) {
        if kind != lastRecheckKind && kind != "ok" { events.append(kind) }
        lastRecheckKind = kind
    }

    private func lose(_ events: inout [String]) {
        state = .searching; slab = nil; imageSlab = nil; lockEstimate = nil; lockSigmaDegrees = nil; hist = []; depth = nil
        movers = []; recent = []; implausible = 0; candidates = []; unconfirmed = nil; depthEstimate = nil; fusing = false; misses = 0
        longSideWorld = nil; sideEvidence = 0; lastMeasured = nil; ballState = nil; ballLocator?.reset()
        events.append("lost"); bump("lost")
    }

    /// Everything but the tap's seed.
    private func forget() {
        state = .searching; hist = []; slab = nil; imageSlab = nil; lockEstimate = nil; lockSigmaDegrees = nil; candidates = []; movers = []
        recent = []; implausible = 0
        depth = nil; lastCheck = -.infinity; lastGood = -.infinity; ballState = nil; ballLocator?.reset()
        unconfirmed = nil; misses = 0; depthEstimate = nil; fusing = false; longSideWorld = nil; sideEvidence = 0; lastMeasured = nil
        lastRecheckKind = "ok"
    }

    private func onDiscontinuity(_ reason: String, _ events: inout [String]) {
        bump("discontinuities")
        lastMeasured = nil
        seed = nil   // its world point is in the old frame
        switch state {
        case .locked:
            unconfirmed = (0, 0); movers = []; recent = []; implausible = 0; depthEstimate = nil; lastCheck = -.infinity
            events.append("lock-unconfirmed: " + reason)
        case .confirming:
            candidates = []; state = .searching; events.append("candidate-lost: " + reason)
        case .searching: break
        }
    }

    // MARK: the box model's cut-face flip

    /// If `quad` (any start, either way round) is `ref`'s outline in this view with one side, or two neighbouring ones,
    /// taken at the bottom of the cut face instead of the top edge (the near edge flipping on a real phone), the pose
    /// sides that flipped.
    func cutFlip(_ quad: [Vec2], of ref: SlabPose, _ f: TrackerFrame, noise s: Double) -> Set<Int>? {
        guard quad.count == 4 else { return nil }
        let box = SlabBoxView(pose: ref.transformed(by: f.view.cameraFromWorld), spec: settings.spec, intrinsics: f.view.intrinsics)
        guard let T = box.topOutline else { return nil }
        let Q = SlabTracker.aligned(quad, to: T)
        func rms(_ a: [Vec2], _ b: [Vec2]) -> Double { (zip(a, b).reduce(0) { $0 + pow($1.0.distance(to: $1.1), 2) } / 4).squareRoot() }
        let d0 = rms(Q, T), tol = max(settings.cutFlipTolerancePixels, 2.5 * s)
        let vis = (0..<4).filter { i in
            let w = box.cutBandWidth(side: i)
            return box.cutFaceVisible(side: i) && max(w.start, w.end) >= max(1.5, 1.5 * s)
        }
        var options: [Set<Int>] = vis.map { [$0] }
        for i in vis where vis.contains((i + 1) % 4) { options.append([i, (i + 1) % 4]) }
        var best: (sides: Set<Int>, d: Double)? = nil
        for sides in options {
            guard let F = box.outlineWithCutBottom(onSides: sides) else { continue }
            let d = rms(Q, F)
            if d < tol && d < 0.5 * d0 && d < (best?.d ?? .infinity) { best = (sides, d) }
        }
        return best?.sides
    }

    /// `q` turned (start and direction) to correspond corner by corner with `ref`.
    static func aligned(_ q: [Vec2], to ref: [Vec2]) -> [Vec2] {
        var best = q, bd = Double.infinity
        for rev in [false, true] {
            let r = rev ? Array(q.reversed()) : q
            for k in 0..<4 {
                let c = (0..<4).map { r[($0 + k) % 4] }
                let d = zip(c, ref).reduce(0) { $0 + $1.0.distance(to: $1.1) }
                if d < bd { bd = d; best = c }
            }
        }
        return best
    }

    /// Whether p lies inside the convex outline q grown about its centre by `slack` of its size.
    static func contains(_ q: [Vec2], _ p: Vec2, slack: Double) -> Bool {
        guard q.count == 4 else { return false }
        let c = q.reduce(Vec2.zero) { $0 + $1 } / 4, g = q.map { c + ($0 - c) * (1 + slack) }
        var sign = 0.0
        for i in 0..<4 {
            let z = (g[(i + 1) % 4] - g[i]).cross(p - g[i])
            if z == 0 { continue }
            if sign == 0 { sign = z } else if (z > 0) != (sign > 0) { return false }
        }
        return true
    }

    // MARK: a rectangular slab's long side

    /// Which outline side is the long one cannot be told from one noisy frame. Keep the direction the evidence favours
    /// (a leaky sum of the cost differences between the two assignments) and measure with the assignment that matches
    /// it; when the evidence turns, swap every stored measurement to its other assignment.
    private func applySideEvidence(_ m0: Measurement, _ events: inout [String]) -> Measurement {
        var m = m0
        guard let alt = m.alt, let a = SlabTracker.longSide(m.est.pose), let b = SlabTracker.longSide(alt.pose) else { return m }
        if longSideWorld == nil { longSideWorld = a; sideEvidence = 0 }
        let H = longSideWorld!
        if abs(b.dot(H)) > abs(a.dot(H)) { m.swapSides() }
        let agree = m.est.cost, other = m.alt!.cost
        sideEvidence = min(settings.sideEvidenceCap, settings.sideEvidenceDecay * sideEvidence + (other - agree))
        guard sideEvidence < -settings.sideFlipMargin else { return m }
        // the other side is the long one after all
        sideEvidence = -sideEvidence
        m.swapSides()
        longSideWorld = SlabTracker.longSide(m.est.pose)
        bump("sideSwaps")
        // swap every stored measurement to its other assignment (those whose other fit failed cannot be, and go)
        func swapped(_ ms: [Measurement]) -> [Measurement] {
            let keep = ms.filter { $0.alt != nil }.map { m -> Measurement in var x = m; x.swapSides(); return x }
            return keep.isEmpty ? ms : keep
        }
        candidates = swapped(candidates); movers = swapped(movers); recent = swapped(recent)
        if state == .locked && !hist.isEmpty {
            hist = swapped(hist)
            refreshLock(); depthEstimate = nil
            events.append("relocked"); bump("relocks")
        } else {
            events.append("sides-swapped")
        }
        return m
    }

    static func longSide(_ p: SlabPose) -> Vec3? {
        if p.halfU == p.halfV { return nil }
        return p.halfU > p.halfV ? p.axisU : p.axisV
    }

    // MARK: the tap

    /// The tapped point in the world: where its ray meets the height of a slab on the floor (or of the current lock),
    /// else 1.2 m along it.
    private func seedPoint(for px: Vec2, _ f: TrackerFrame) -> Vec3 {
        let (o, d) = f.view.ray(through: px)
        let y = f.floorY.map { $0 + settings.spec.thickness + 0.04 } ?? imageSlab?.center.y ?? candidates.last?.pose.center.y
        if let y = y, d.y < -1e-3 {
            let s = (y - o.y) / d.y
            if s > 0.1 && s < 8 { return o + d * s }
        }
        return o + d * 1.2
    }

    // MARK: LiDAR

    /// the corner plane lies above the plane through the dish's inner 70% by the dish's mean depth there, D (1 - 0.7^2 / 3)
    private var dishOffset: Double { settings.spec.dishDepth * (1 - 0.49 / 3) }

    /// Whether a frame's depth check describes the slab's top where the lock is: most points inside the top on one plane,
    /// near the image normal, and the lock's centre the dish's depth above it (a hand above the top, or the ground below
    /// where the slab was, fail this).
    private func depthUsable(_ c: DepthCheck, _ s: SlabPose, _ f: TrackerFrame, maxAngle: Double) -> Bool {
        guard c.points >= 60, c.angleToImageDegrees < maxAngle else { return false }
        if let fr = c.inlierFraction, fr < settings.depthMinInlierFraction { return false }
        let range = s.center.distance(to: f.view.position)
        return abs(c.centreOffset - dishOffset) <= max(0.01, settings.depthMaxOffsetFraction * range)
    }

    private func addDepth(_ c: DepthCheck, _ t: Double) {
        let n = c.plane.normal
        guard var e = depthEstimate else { depthEstimate = DepthEstimate(normal: n, offset: n.dot(c.plane.point), count: 1, time: t); return }
        // a running mean at first, then an exponential average over about depthSmoothingSeconds
        let a = max(1 / Double(e.count + 1), 1 - exp(-max(0, t - e.time) / max(settings.depthSmoothingSeconds, 1e-3)))
        let nn = (e.normal * (1 - a) + n * a).normalized
        e.offset = e.offset * (1 - a) + nn.dot(c.plane.point) * a
        e.normal = nn; e.count += 1; e.time = t
        depthEstimate = e
    }

    private func fuse(_ s: SlabPose, _ e: DepthEstimate, _ f: TrackerFrame) -> SlabPose {
        let w = settings.depthNormalWeight
        let plane = Plane3(point: e.normal * e.offset, normal: e.normal)
        let n = (s.normal * (1 - w) + e.normal * w).normalized, u = s.axisU.rejecting(n).normalized
        var c = s.center
        if let p = plane.intersect(origin: f.view.position, direction: (s.center - f.view.position).normalized) {
            c = p + e.normal * dishOffset
        }
        return SlabPose(center: s.center * (1 - w) + c * w, normal: n, axisU: u, axisV: n.cross(u), halfU: s.halfU, halfV: s.halfV)
    }

    /// A world pose's top corners in a view's image.
    public func project(_ s: SlabPose, _ view: CameraView) -> [Vec2]? {
        let q = s.topCorners.compactMap { view.project(world: $0) }
        return q.count == 4 ? q : nil
    }
}

fileprivate let zeroMat3 = Mat3(rows: [0, 0, 0, 0, 0, 0, 0, 0, 0])
fileprivate func madd(_ a: Mat3, _ b: Mat3) -> Mat3 { Mat3(rows: zip(a.m, b.m).map { $0 + $1 }) }
fileprivate func mscale(_ a: Mat3, _ s: Double) -> Mat3 { Mat3(rows: a.m.map { $0 * s }) }
fileprivate func outer(_ a: Vec3, _ b: Vec3) -> Mat3 { Mat3(rows: [a.x * b.x, a.x * b.y, a.x * b.z, a.y * b.x, a.y * b.y, a.y * b.z, a.z * b.x, a.z * b.y, a.z * b.z]) }
fileprivate func trace(_ a: Mat3) -> Double { a[0, 0] + a[1, 1] + a[2, 2] }
