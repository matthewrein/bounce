import Foundation

/// Finds the slab's top-corner outline in a frame. The real one is SlabFinder; tests can plug in others (they need only
/// the first `detect`: the others have defaults that ignore the finer image and keep nothing).
public protocol SlabDetecting {
    /// Outlines (top corners, pixels of `frame`) best first, each starting at any corner and running either way round
    /// (`PoseFit.cornerOrder` maps them onto the pose). `seed`: a point the owner tapped (kept by the tracker and passed
    /// on every search until it locks); `near`: a predicted outline to search around (in the pose's corner order).
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline]
    /// The same, with a finer luma image of part of the view (`detail`: a full-resolution crop around where the slab is
    /// expected) for the edge steps of the outlines it covers. Default: the plain `detect`, ignoring it.
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                detail: DetailImage?) -> [DetectedOutline]
    /// Refine one outline this frame's search found (pixels of `frame`) on a finer image around it: the slab's outline
    /// there, best first, as `detect` would return it while following that outline. Default: nothing (the tracker keeps
    /// the outline as found).
    func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?,
                detail: DetailImage) -> [DetectedOutline]
    /// Drop anything kept from earlier calls in pixels of the processing frame (e.g. SlabFinderDetector's edge memory):
    /// the frame's size changed. Default: nothing kept.
    func forgetPixelMemory()
    /// The tracker's settings, at the start and whenever they change: the ones for the detector's own work
    /// (`TrackerSettings.maxSweepRegions`, `sweepSkipsFinds`, `sweepSameOutlinePixels`, `tapHints`). Default: none used.
    func apply(_ settings: TrackerSettings)
    /// Look for a slab grown from a tapped point (pixels of `frame`; `TrackerSettings.tapHints`: while the tracker follows
    /// a lock elsewhere, or where a search found nothing under the finger), without changing what the detector keeps for
    /// the outline it follows. Default: the plain `detect` with the seed.
    func probe(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2) -> [DetectedOutline]
}

extension SlabDetecting {
    public func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                       detail: DetailImage?) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near)
    }
    public func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?,
                       detail: DetailImage) -> [DetectedOutline] { [] }
    public func forgetPixelMemory() {}
    public func apply(_ settings: TrackerSettings) {}
    public func probe(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: nil)
    }
}

/// One outline a detector found.
public struct DetectedOutline: Equatable, Codable {
    public var quad: [Vec2]
    /// detector's own confidence, higher is better (only compared between outlines of one frame)
    public var score: Double
    /// per-side edge modes, for diagnostics (e.g. "top", "fromCutBottom", "silhouette"); side j runs from quad[j] to [j+1]
    public var sideModes: [String]
    /// With a side profile (`SlabSpec.hasProfile`): each side's line noise as the detector knows it (pixels of the frame
    /// the detector ran on, per side like `sideModes`; empty when not given): a parallel shift (`SideEdge.topSigmaPixels`:
    /// the edge's definition, the profile, a one-edge ambiguity, the edge points' scatter; not motion blur) and a turn about
    /// the side's middle, as its ends' displacement (`SideEdge.turnSigmaPixels`)
    public var sideSigmas: [Double]
    public var sideTurnSigmas: [Double]
    /// With a side profile: the part of each side's `sideSigmas` that is this frame's own (`SideEdge.frameSigmaPixels`:
    /// the edge points' scatter about the line, at least the still-frame jitter); the rest (the edge's definition, the
    /// profile, a one-edge ambiguity) is the same error from frame to frame and view to view. Empty: not given (all of
    /// it counts as the frame's own, as before).
    public var sideFrameSigmas: [Double]
    /// With a side profile: on a side whose face shows but whose two edges were not both seen, how far outward (pixels
    /// like `sideSigmas`, negative inward) the middle of its two possible readings lies from the line given
    /// (`SideEdge.ambiguityShiftPixels`; 0 elsewhere). Recorded for diagnostics: the outline and the tilt's honest estimate
    /// keep the likelier reading, and `sideSigmas` covers both (`SlabTracker` sideNoise says why).
    public var sideShifts: [Double]
    /// the side profile the detector has learned on this slab (`ProfileLearning`: the face's drop and side run, metres);
    /// nil when none was learned or there is no profile
    public var faceDrop: Double?
    public var sideRun: Double?

    public init(quad: [Vec2], score: Double = 1, sideModes: [String] = [], sideSigmas: [Double] = [], sideTurnSigmas: [Double] = [],
                faceDrop: Double? = nil, sideRun: Double? = nil, sideShifts: [Double] = [], sideFrameSigmas: [Double] = []) {
        self.quad = quad; self.score = score; self.sideModes = sideModes
        self.sideSigmas = sideSigmas; self.sideTurnSigmas = sideTurnSigmas; self.faceDrop = faceDrop; self.sideRun = sideRun
        self.sideShifts = sideShifts; self.sideFrameSigmas = sideFrameSigmas
    }

    // JSON (recordings): {"quad": [[x, y], ...] (pixels of the frame the detector ran on), "score": s, "sideModes": [...],
    // and with a side profile "sideSigmas", "sideTurnSigmas", "sideFrameSigmas", "sideShifts": [...], "faceDrop", "sideRun": m};
    // the later keys are absent in older recordings (and written only when set, so a detection without them writes what it
    // wrote before)
    enum CodingKeys: String, CodingKey { case quad, score, sideModes, sideSigmas, sideTurnSigmas, faceDrop, sideRun, sideShifts, sideFrameSigmas }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quad = try c.decode([[Double]].self, forKey: .quad).map { Vec2($0[0], $0[1]) }
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 1
        sideModes = try c.decodeIfPresent([String].self, forKey: .sideModes) ?? []
        sideSigmas = try c.decodeIfPresent([Double].self, forKey: .sideSigmas) ?? []
        sideTurnSigmas = try c.decodeIfPresent([Double].self, forKey: .sideTurnSigmas) ?? []
        faceDrop = try c.decodeIfPresent(Double.self, forKey: .faceDrop)
        sideRun = try c.decodeIfPresent(Double.self, forKey: .sideRun)
        sideShifts = try c.decodeIfPresent([Double].self, forKey: .sideShifts) ?? []
        sideFrameSigmas = try c.decodeIfPresent([Double].self, forKey: .sideFrameSigmas) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quad.map { [$0.x, $0.y] }, forKey: .quad)
        try c.encode(score, forKey: .score)
        if !sideModes.isEmpty { try c.encode(sideModes, forKey: .sideModes) }
        if !sideSigmas.isEmpty { try c.encode(sideSigmas, forKey: .sideSigmas) }
        if !sideTurnSigmas.isEmpty { try c.encode(sideTurnSigmas, forKey: .sideTurnSigmas) }
        try c.encodeIfPresent(faceDrop, forKey: .faceDrop)
        try c.encodeIfPresent(sideRun, forKey: .sideRun)
        if !sideShifts.isEmpty { try c.encode(sideShifts, forKey: .sideShifts) }
        if !sideFrameSigmas.isEmpty { try c.encode(sideFrameSigmas, forKey: .sideFrameSigmas) }
    }
}

/// Something done to the tracker between frames besides handing it a frame (making it, changing its settings, a reset,
/// a world-frame discontinuity). The tracker reports them with the next frame (`TrackerOutput.controls`), so a
/// recording can store them and a replay can do the same at the same moment.
public struct TrackerControl: Codable, Equatable {
    public enum Kind: String, Codable {
        /// the tracker was made, with `settings`
        case start
        /// its settings were replaced by `settings`
        case settings
        /// `SlabTracker.reset()`
        case reset
        /// `SlabTracker.noteWorldDiscontinuity(reason)`
        case worldDiscontinuity
    }
    public var kind: Kind
    public var settings: TrackerSettings?
    public var reason: String?
    public init(kind: Kind, settings: TrackerSettings? = nil, reason: String? = nil) {
        self.kind = kind; self.settings = settings; self.reason = reason
    }
}

/// One run of the slab detector as the tracker saw it, for diagnostics (`SlabTracker.detectionLog`). Poses are in world
/// coordinates (ARKit's gravity-aligned world: metres, y up); pixels are the processing frame's.
public struct DetectionRecord: Codable, Equatable {
    /// frame timestamp (s, the camera's clock)
    public var time: Double
    /// the tracker's state when it ran
    public var state: TrackerState
    /// outlines the detector returned, and the shape-check verdicts (`ShapeCheck.Verdict.key`) of those it rejected
    public var found: Int
    public var rejected: [String]
    /// what it led to: the counters it bumped (`SlabTracker.counts` keys), e.g. "recheckAgree", "recheckDisagree",
    /// "relocks", "locks", "confirmRestarts", "cutFlips", "recheckMiss", "recheckInner" (the top found where the lock
    /// has the cut face's bottom), "recheckOuterBetter" (the top found a band outside the lock), "recheckInnerWorse" (an
    /// outline a band inside the lock, ignored), "relocksToTop"
    public var outcome: [String]
    /// the outline the tracker used, if any: its pose's centre and normal (world), tilt from level (degrees), the
    /// normal's standard deviation at 1 px corner noise (degrees), the fit's rms corner misfit (pixels), the distance
    /// from the camera to the centre (m)
    public var center: [Double]?
    public var normal: [Double]?
    public var tiltDegrees: Double?
    public var sigmaDegrees: Double?
    public var rmsPixels: Double?
    public var distance: Double?
    /// its side lengths in the image (pixels, pose order: side i runs from corner i to i+1) and their aspect (mean of
    /// sides 0 and 2 over mean of sides 1 and 3)
    public var sidesPixels: [Double]?
    public var aspect: Double?
    /// the detector's per-side edge modes, in pose order
    public var sideModes: [String]?
    /// where the edge steps of the outline used read their pixels: "crop" (a re-check following the lock's outline, on
    /// the full-resolution crop around it, `SlabImageCrop`, which covered the outline found), "refined" (a search's find
    /// refined on a crop around it); nil: the processing frame alone (no crop, a refine pass that missed, or a re-check
    /// whose find lay outside the crop around the lock: counted as "slabCropMisses")
    public var edges: String?
    /// the detection in the tilt's honest uncertainty (`HonestTilt`), if it was added: its own standard deviation
    /// (degrees, with its sides' noise), its misfit against what that noise allows (chi-square), and whether that misfit
    /// left it out
    public var viewSigmaDegrees: Double?
    public var misfitChi2: Double?
    public var misfitExcluded: Bool?

    public init(time: Double, state: TrackerState, found: Int, rejected: [String] = [], outcome: [String] = []) {
        self.time = time; self.state = state; self.found = found; self.rejected = rejected; self.outcome = outcome
    }
}

/// Finds the ball above the slab. The real one is BallLocator; tests can plug in others.
/// (The defaults: nothing waits for a second scan; the owner's taps are not used.)
extension BallLocating {
    public var awaitsConfirmation: Bool { false }
    public func setSearchHints(_ hints: BallSearchHints) {}
}

public protocol BallLocating: AnyObject {
    /// The ball's centre in camera (CV) axes if a ball is held over the slab. `image`: a luma image (often a
    /// higher-resolution crop around the slab) with its own intrinsics; `slab`: the slab pose in the same camera axes.
    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)?
    /// The last scan left something to be confirmed by the next one (half an outline that is reported only once it shows
    /// up twice in the same place): the tracker scans again at the usual rate, not the idle one (`idleBallAfter`).
    var awaitsConfirmation: Bool { get }
    func reset()
    /// What the owner's taps say for the next scan (`BallSearchHints`, pixels of the image `locate` is given): where to
    /// look first and at what size, and where to pass over a ball. The tracker sets it before every scan.
    func setSearchHints(_ hints: BallSearchHints)
}

public struct TrackerSettings: Equatable {
    public var spec: SlabSpec = .standard
    public var ball: BallSpec = BallSpec()
    public var defaultDropHeight: Double = Units.feet(3)
    public var launchRule: Bounce.LaunchRule = .cornerPlane
    /// seconds between re-detections while locked, and between searches while not (0: every frame)
    public var recheckInterval: Double = 0.3
    public var searchInterval: Double = 0
    /// The shortest time between two runs of the slab detector, whatever asks for one (s): the intervals above, and the
    /// runs forced on the next frame by a tap, a reset, a world-frame discontinuity (reported by the app, a jump of the
    /// camera, tracking resumed) or a change of the processing frame's size. A forced run still happens, on the first
    /// frame this much after the last run (`detectionDue`), so a discontinuity reported on frame after frame cannot run
    /// the detector on every frame. 0: no minimum (the default, so older recordings, whose settings lack it, replay as
    /// the phone ran them); the app's is `RecordingSettings.appMinDetectionGap`.
    public var minDetectionGap: Double = 0
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
    /// and move the lock's centre with this weight onto where the line of sight through it meets the depth plane (raised
    /// by the dish's offset): LiDAR's range, folded in without its tilt. The default is the normal's own default: until
    /// n11 the normal's weight moved both, and a recording whose settings lack this key reads it as its own
    /// `depthNormalWeight` (`TrackerSettings.init(from:)`), so it replays as the phone ran it. Fusion runs while either
    /// weight is above 0. The app's values (`RecordingSettings.trackerSettings`): normal 0, centre 0.5.
    public var depthCentreWeight: Double = 0.5
    /// The slab search's own work (`SlabFinderDetector`): the most regions its sweep grows (nil: the finder's own, 48);
    /// whether it skips starting points inside an outline it already found (`SlabFinder.Options.skipSeedsInFinds`); and
    /// how close (pixels, mean corner distance) an outline must be to one that failed refinement from the same start to be skipped
    /// (`sameOutlinePixels`; 0: none). The defaults are the finder's own, so older recordings, whose settings lack
    /// them, replay as the phone ran them; the app's are in `RecordingSettings.trackerSettings`.
    public var maxSweepRegions: Int? = nil
    public var sweepSkipsFinds = false
    public var sweepSameOutlinePixels: Double = 0
    /// the ball finder runs at most this often (s)
    public var ballInterval: Double = 0.1
    /// While no ball is shown and none is about to be (the ball finder follows none and has no half outline waiting
    /// for its second scan: `BallLocating.awaitsConfirmation`), after this long (s) of scans that found none, the ball
    /// finder runs only every `idleBallInterval` (its scan of the whole space above the slab costs tens of ms on a
    /// textured floor), until it finds one, or the lock changes (a new lock, a re-lock, a lost lock, a discontinuity). 0:
    /// never (the default, so older recordings replay as the phone ran them); the app's is
    /// `RecordingSettings.appIdleBallAfter`. A followed ball is looked for every `ballInterval` as before.
    public var idleBallAfter: Double = 0
    public var idleBallInterval: Double = 0.3
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
    /// The other way round: the lock was made from outlines caught at the bottom of the cut face (it can confirm on
    /// them when the near edge flips from the start), and a re-detection finds the top edge, the lock being its flip.
    /// This many such re-detections that agree with each other, within `topRelockSeconds`, re-lock onto the top;
    /// flipped re-detections between them agree with the lock and do not count against them, and the cradle check does
    /// not apply. Of two outlines a band apart the inner one is taken for the top (as the edge refiner does) unless the
    /// pose fits say otherwise: an inner outline that fits the square clearly worse than the lock's measurements is a
    /// side put a band inside the top and is ignored, and an outer one that fits clearly better is the top, the lock
    /// resting on such an inner outline (see `SlabTracker.clearlyWorseFit`). Far away the fits cannot tell them apart.
    public var topRelockCount: Int = 2
    public var topRelockSeconds: Double = 3

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

    // Tap hints (n15): what a tap means is decided by what is under the finger (`SlabTracker.tapKind`, `TapHints`).
    /// Off (the default, so older recordings replay as the phone ran them): every tap looks for the slab there and starts
    /// the search over (n11). On (the app's, `RecordingSettings.trackerSettings`): while the slab is locked, a tap on the
    /// ball's ring dismisses it (`TrackerTapKind.dismissBall`: dropped at once, its spot passed over), a tap where a ball
    /// held over the slab could be looks for the ball there first (`ball`), and any other tap looks for a slab there
    /// without giving the lock up unless another slab is found there twice in a row (`slab`). While it is not locked, the
    /// search's outlines under the finger come first, and a candidate being confirmed is given up for one there only when
    /// it is found twice; only where the search has no outline at all is the slab grown from the tapped point (and the
    /// points around it, `SlabFinder.Options.tapSearchesAround`), through the search's own light-independent screens
    /// (`tapScreens`), on the scheduled searches: before the lock a slab tap runs no search of its own. A slab tap never
    /// moves the detections' schedule, and lasts `tapSlabFirstSeconds` unless what is being confirmed lies under the
    /// finger. (Any tap still ends the searches' back-off, `idleSearchAfter`, as in n11.)
    public var tapHints = false
    /// how far from the finger a tap still counts: this share of the processing frame's shorter side (about a fingertip)
    public var tapSlackFraction: Double = 0.05
    /// a ball tap looks there first for this long (s); a ball found there keeps it on that ball (`TapHints.recentred`)
    /// until this long passes without one found there
    public var tapBallSeconds: Double = 2
    /// a dismissed ring's spot is passed over for this long (s); at most this many spots are kept (the oldest goes first)
    public var tapDismissSeconds: Double = 20
    public var tapDismissMax: Int = 4
    /// A slab tap lasts this long (s of normal tracking), unless the candidate being confirmed lies under the finger (then
    /// until the lock, at most `seedTimeout`).
    public var tapSlabFirstSeconds: Double = 1

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

    // Searching with nothing to find (the floor, a cluttered room): a still camera's searches that keep finding nothing
    // would go on finding nothing, each one costing a slab search (tens to hundreds of ms on a cluttered floor).
    /// After this long (s) of searches that found no candidate, from a camera that has kept still (and with no tap's
    /// seed), search only every `idleSearchInterval` until the camera moves, a search finds a candidate, a tap, a reset
    /// or a world-frame discontinuity, or tracking is limited. 0: never back off (the default, so older recordings,
    /// whose settings lack it, replay as the phone ran them); the app's is `RecordingSettings.appIdleSearchAfter`.
    public var idleSearchAfter: Double = 0
    /// the backed-off interval between searches (s)
    public var idleSearchInterval: Double = 0.36
    /// The camera has kept still while its view direction stays within this angle (degrees) and its position within
    /// `idleSearchMoveDistance` (m) of where it was on the first of those empty searches: a camera that turns or moves
    /// further sees something else, and searches at the usual rate again from its next frame.
    public var idleSearchMoveDegrees: Double = 4
    public var idleSearchMoveDistance: Double = 0.04

    // The tilt's honest uncertainty and when to show it (n11), apart from the lock: `SlabTracker.tiltSigmaDegrees`,
    // `angleSettled`, `HonestTilt`.
    public var settle = SettleSettings()
    /// While the tilt is settled (`TrackerOutput.angleSettled`), the readouts and the bounce use its honest normal
    /// (`SlabTracker.settledNormal`, from the lock's views each kept to its newest detections) with the lock's centre; the
    /// lock still draws the outline. Off (the default, so older recordings replay as the phone ran them): the lock's pose,
    /// as before. The app's is on (`RecordingSettings.trackerSettings`).
    public var readoutsFromSettledNormal = false
    /// The lock keeps a view's older detections (views of the slab: directions from it to the camera within
    /// `SettleSettings.groupDegrees`) only while they agree with the view's newest `SettleSettings.perGroup` (within
    /// `matchSigmas`): a still view's early detections taken on the wrong edge (before the edges settled on the top) age
    /// out of the outline and the path within about a second instead of `historySize` re-checks, and detections that
    /// agree still average the lock's jitter down. Off (the default, so older recordings replay as the phone ran them):
    /// the newest `historySize`, as before. The app's is on (`RecordingSettings.trackerSettings`).
    public var lockKeepsNewestPerView = false

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
    /// Full-resolution luma for the slab's edge steps, on request: given an outline (pixels of `frame`), the crop of the
    /// full camera image around it with its intrinsics (`SlabImageCrop.provider` plans and cuts it), or nil when the
    /// camera cannot provide one. The tracker calls it at most once a frame, only on a frame where its detector runs:
    /// before the detector runs when it follows the lock's outline (a re-check), else after a search (searching,
    /// confirming, or a re-check over the whole view) found the slab, around that find, which the detector then refines
    /// on it (`SlabDetecting.refine`): the processing frame finds the slab, the camera's pixels place its edges. What it
    /// got is in `TrackerOutput.slabDetail` (for the recording). nil: no such pixels (the processing frame alone, as
    /// before; recordings without them replay that way).
    public var slabDetail: (([Vec2]) -> SlabDetail?)?
    /// the camera's exposure for this frame (s), if known: with the camera's turn since the last frame it gives the motion
    /// blur that widens a detection's edge noise (`SettleSettings.blurShare`); nil: `SettleSettings.defaultExposure`
    public var exposureDuration: Double?

    public init(timestamp: Double, view: CameraView, frame: ColorFrame, depth: DepthMap? = nil, depthIntrinsics: CameraIntrinsics? = nil,
                ballImage: Plane? = nil, ballIntrinsics: CameraIntrinsics? = nil, tap: Vec2? = nil, floorY: Double? = nil, trackingNormal: Bool = true,
                slabDetail: (([Vec2]) -> SlabDetail?)? = nil, exposureDuration: Double? = nil) {
        self.timestamp = timestamp; self.view = view; self.frame = frame; self.depth = depth; self.depthIntrinsics = depthIntrinsics
        self.ballImage = ballImage; self.ballIntrinsics = ballIntrinsics; self.tap = tap; self.floorY = floorY; self.trackingNormal = trackingNormal
        self.slabDetail = slabDetail; self.exposureDuration = exposureDuration
    }
}

public enum TrackerState: String, Codable { case searching, confirming, locked }

/// What a run of the slab detector was for: a search (searching for the slab, or confirming one), or a re-check of the
/// lock.
public enum TrackerDetectionKind: String, Codable { case search, recheck }

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

/// Count, smallest, largest and last of a value, and the median of its latest `window` values.
public struct RunningStats: Equatable, Codable {
    public var count: Int = 0
    public var min: Double = .infinity
    public var max: Double = -.infinity
    public var median: Double = .nan
    public var last: Double = .nan
    /// the latest values, for the median (not written)
    private var recent: [Double] = []
    public static let window = 101
    public init() {}
    public mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        count += 1; min = Swift.min(min, v); max = Swift.max(max, v); last = v
        recent.append(v)
        if recent.count > RunningStats.window { recent.removeFirst(recent.count - RunningStats.window) }
        let s = recent.sorted(), k = s.count
        median = k % 2 == 1 ? s[k / 2] : (s[k / 2 - 1] + s[k / 2]) / 2
    }
    /// rounded to 4 significant decimals, for reports
    public var rounded: RunningStats {
        var r = self
        func r4(_ v: Double) -> Double { v.isFinite ? (v * 10000).rounded() / 10000 : v }
        r.min = r4(min); r.max = r4(max); r.median = r4(median); r.last = r4(last); r.recent = []
        return r
    }
    enum CodingKeys: String, CodingKey { case count, min, max, median, last }
}

/// LiDAR's checks of the lock's top (`SlabTracker.depthChecks`): how many, how many were used, why the others were not
/// ("points", "angle", "inliers", "offset": `SlabTracker` depth gates), and what they read: the lock's centre above the
/// depth plane less the dish's offset (mm; 0 when LiDAR and the picture agree on the range), the depth plane's angle to
/// the image normal (degrees), and k, LiDAR's range to the corner plane along the line of sight through the lock's centre
/// over the picture's (1 when they agree; the offset gate allows `depthMaxOffsetFraction` of the range).
public struct DepthCheckSummary: Equatable, Codable {
    public var checks = 0
    public var used = 0
    public var rejected: [String: Int] = [:]
    public var offsetMm = RunningStats()
    public var angleDegrees = RunningStats()
    public var rangeRatio = RunningStats()
    public init() {}
    /// rounded, for reports
    public var rounded: DepthCheckSummary {
        var r = self
        r.offsetMm = offsetMm.rounded; r.angleDegrees = angleDegrees.rounded; r.rangeRatio = rangeRatio.rounded
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
    /// what was done to the tracker since the previous frame, in order (see `TrackerControl`); a recording stores these
    public var controls: [TrackerControl] = []
    /// the slab detector's own outlines on this frame (pixels of the processing frame, as the detector returned them,
    /// before any checks), or nil if the detector did not run on this frame
    public var detections: [DetectedOutline]? = nil
    /// the ball finder ran on this frame (`ball` is then its result, nil if it found none; otherwise `ball` is the last
    /// result, kept)
    public var ballSearched: Bool = false
    /// the ball finder ran on this frame and holds something for its next scan to confirm (`BallLocating
    /// .awaitsConfirmation`): the idle ball rate does not start (a recording keeps it, so a replay that uses the phone's
    /// ball result follows the same rate)
    public var ballAwaitsConfirmation: Bool = false
    /// what the slab detector's run on this frame was for (nil: it did not run; then `detections` is nil too)
    public var detectionKind: TrackerDetectionKind? = nil
    /// the full-resolution crop the tracker got for the slab's edges on this frame (`TrackerFrame.slabDetail`), if any
    public var slabDetail: SlabDetail? = nil
    /// a search's find refined on that crop: the detector's own outlines from `SlabDetecting.refine` (pixels of the
    /// processing frame), or nil if there was no such pass on this frame
    public var refinedDetections: [DetectedOutline]? = nil
    /// While locked: the tilt's honest standard deviation (degrees, both axes; `SlabTracker.tiltSigmaDegrees`), nil before
    /// any view; whether it is settled enough to show (`angleSettled`: false while the lock is unconfirmed); and how many
    /// views of the slab it rests on (`viewGroups`)
    public var tiltSigmaDegrees: Double? = nil
    public var angleSettled: Bool = false
    public var viewGroups: Int = 0
    /// this frame's tap and what it was taken for (`TrackerSettings.tapHints`), for the app's brief feedback; nil: no tap
    public var tap: TrackerTap? = nil
    /// a ball tap's search is on (`SlabTracker.ballHint`), and how many dismissed rings' spots are passed over
    public var ballHintActive: Bool = false
    public var dismissedSpots: Int = 0
}

/// The per-frame logic shared by the app and the replay tests: search, confirm, lock the slab in world space so its
/// outline holds still as the phone moves, re-check it now and then, re-lock if it was moved, and work out the bounce.
///
/// Measurements carry their own uncertainty (from the pose fit, scaled by the detector's corner noise as the lock's
/// history shows it), so the agreement gates follow the noise: a slab 5 ft away at the processing frame's 480 px is
/// measured far less precisely in depth than one at 2 ft. Re-detections that disagree with the lock are checked before
/// they can move it: a side taken at the bottom of its cut face (the box model), a far-away lookalike, a jump that LiDAR
/// contradicts, or a tilt change the cradle cannot make, are not moves. The other way round, a lock made from outlines
/// caught at the bottom of the cut face moves to the top edge as soon as a couple of re-checks find it (the pose fits
/// decide which of two outlines a band apart is the top where they can, else the inner one is).
public final class SlabTracker {
    /// Changing the settings is reported with the next frame (`TrackerOutput.controls`).
    public var settings: TrackerSettings {
        didSet {
            if settings != oldValue { pendingControls.append(TrackerControl(kind: .settings, settings: settings)) }
            honest.settings = settings.settle
            detector.apply(settings)
        }
    }
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
    /// LiDAR's checks of the lock's top since the tracker was made: how many, why those not used were not, and what they
    /// read (for diagnostics)
    public private(set) var depthChecks = DepthCheckSummary()
    /// how well the lock pins the normal (degrees), for the corner noise its measurements show
    public private(set) var lockSigmaDegrees: Double?
    /// The tilt's honest standard deviation (degrees, both axes together) while locked: the lock's views of the slab,
    /// each its newest few detections with one view's uncertainty, combined (`HonestTilt`). nil before any view. Apart
    /// from the lock's own estimate (`lockSigmaDegrees`, which gates the lock).
    public var tiltSigmaDegrees: Double? { state == .locked ? honest.sigmaDegrees : nil }
    /// The tilt is settled enough to show: its honest deviation at or under `SettleSettings.settleDegrees` on two
    /// refreshes in a row, and not yet back above `unsettleDegrees`; false while the lock is unconfirmed. A new lock, a
    /// re-lock (a move), a world-frame discontinuity or losing the lock starts it again.
    public var angleSettled: Bool { state == .locked && unconfirmed == nil && honest.settled }
    /// the honest estimate's normal (world), and how many views of the slab it rests on
    public var settledNormal: Vec3? { state == .locked ? honest.normal : nil }
    /// the honest estimate's covariance across its normal (world, rad^2) while locked, and how many times it has been
    /// refreshed (for scoring it once per refresh)
    var settledCovariance: Mat3? { state == .locked ? honest.cov : nil }
    var honestRefreshes: Int { honest.refreshCount }
    public var viewGroupCount: Int { state == .locked ? honest.groups.count : 0 }
    /// rectangular slabs: the long side's direction (world) the evidence so far favours
    public private(set) var longSideWorld: Vec3?
    /// where a tap said to look (world), until it locks or times out
    public var seedPoint: Vec3? { seed?.world }
    /// a ball tap: where along the tapped line of sight a ball is looked for first (once one is found there, along the
    /// line through it), until `TrackerSettings.tapBallSeconds` pass without a ball found there; nil: none
    /// (`TrackerSettings.tapHints`)
    public private(set) var ballHint: BallTapHint?
    /// the spots of dismissed rings (world), oldest first, until they expire or the lock changes
    public private(set) var dismissedSpots: [DismissedBallSpot] = []
    /// how long a slab tap took to lead to a lock, and a ball tap to the first ball found in its box (s; the right ball
    /// or not), for diagnostics
    public private(set) var tapSlabLockSeconds = RunningStats()
    public private(set) var tapBallFoundSeconds = RunningStats()
    /// after a world-frame discontinuity, until the lock is seen again where it should be
    public var lockUnconfirmed: Bool { unconfirmed != nil }
    /// the last `detectionLogSize` runs of the slab detector, oldest first (for diagnostics)
    public private(set) var detectionLog: [DetectionRecord] = []
    public static let detectionLogSize = 20

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
        /// the fit's rms corner misfit (pixels)
        var rms: Double = 0
        /// the camera it was measured from (its intrinsics are those of `quad`'s pixels), and the frame's motion blur there
        /// (pixels, `KitMotionBlur`)
        var camera: CameraView? = nil
        var blur: Double = 0
        /// The detector's own noise of each side's line (pixels of `quad`, pose side order: side i from corner i to i+1):
        /// parallel to itself (`sideSigmasPixels`: the edge's definition, its profile, a one-edge ambiguity, its fit; not
        /// motion blur, which the tracker adds), and turned about its middle (`sideTurnSigmasPixels`, at its ends). nil: not
        /// given; the honest uncertainty then uses the corner noise the re-checks show (`HonestTilt`).
        var sideSigmasPixels: [Double]? = nil
        var sideTurnSigmasPixels: [Double]? = nil
        /// the part of `sideSigmasPixels` that is this frame's own (`DetectedOutline.sideFrameSigmas`); nil: not given (all
        /// of it is)
        var sideFrameSigmasPixels: [Double]? = nil
        /// the covariance of the normal's own error in this detection (world, rad^2: what differs from frame to frame of one
        /// view; `HonestTilt.Detection.ownCovariance`), once the honest estimate has taken it; nil before, or when it
        /// could not
        var ownNormalCov: Mat3? = nil
        /// the side profile the detector has learned (`DetectedOutline.faceDrop`, `sideRun`), if any
        var profile: (faceDrop: Double, sideRun: Double)? = nil
        /// grown from a slab tap (`SlabDetecting.probe`), not found by the search itself: it may confirm and lock the slab,
        /// but the tilt's honest estimate leaves it out (`honestRestart`)
        var fromTap = false
        var pose: SlabPose { est.pose }
        mutating func swapSides() { if let a = alt { alt = est; est = a } }
    }

    struct DepthEstimate { var normal: Vec3; var offset: Double; var count: Int; var time: Double }

    private var hist: [Measurement] = []
    private var lockEstimate: Estimate?
    /// the tilt's honest uncertainty over the lock's detections (see `tiltSigmaDegrees`)
    private var honest: HonestTilt
    /// the last detection added to it (for the detection log)
    private var honestNote: (time: Double, detection: HonestTilt.Detection?)?
    /// the previous frame's camera (for motion blur) and this frame's blur (pixels of the processing frame)
    private var previousCamera: (time: Double, pose: RigidTransform)?
    private var frameBlur = 0.0
    private var candidates: [Measurement] = []             // while confirming
    private var movers: [Measurement] = []                 // disagreeing re-detections while locked
    private var partners: [Measurement] = []               // re-detections a band from the lock, taken for the top
    private var recent: [Measurement] = []                 // the latest re-detections near the lock, agreeing or not
    private var implausible = 0                            // re-locks held back as implausible since the last one
    private var noiseSamples: [Double] = []                // re-checks' squared distances from the lock (see cornerNoiseEstimate)
    private var lastCheck = -Double.infinity, lastGood = -Double.infinity, lastBall = -Double.infinity, lastBallSeen = -Double.infinity
    /// when the detector last ran (never reset: `minDetectionGap` counts from it whatever happened since); with tap hints a
    /// tap's own look on its frame is not counted, so it leaves the schedule as it was
    private var lastDetectionRun = -Double.infinity
    /// the processing frame's intrinsics on the last frame (a change of its size is a discontinuity)
    private var lastProcessing: CameraIntrinsics?
    /// this frame's full-resolution crop and refine pass, if any (see TrackerOutput.slabDetail, refinedDetections)
    private var frameDetail: SlabDetail?
    private var frameRefined: [DetectedOutline]?
    private var previousTime: Double?
    private var lastMeasured: (normal: Vec3, time: Double)?
    private var ballState: (center: Vec3, circle: Vec2, radius: Double)?  // world centre
    private var misses = 0
    private var unconfirmed: (elapsed: Double, rechecks: Int)?
    private var pendingDiscontinuity: String?
    private var lastNormalFrame: (time: Double, position: Vec3)?
    private var limitedSince: Double?
    private var seed: (world: Vec3, age: Double)?
    /// the seed's distance along the tapped line was only guessed (no floor, lock or candidate to put it at the slab's
    /// height): as the phone moves it drifts off the tapped thing, so with tap hints it lasts `tapSlabFirstSeconds`
    private var seedDepthGuessed = false
    private var tapResetPending = false
    /// With tap hints, while a slab tap lasts: the outlines under the finger that disagree with the candidate being
    /// confirmed, agreeing with each other (`tapChallenge`); and while locked, the probes' finds of another slab under the
    /// finger, in a row (`probeTappedSlab`). `tapSwitchFinds` of them give up what the tracker has.
    private var tapChallengers: [Measurement] = []
    private var probeHits: [Measurement] = []
    /// how many finds under the finger in a row, agreeing with each other and not with the candidate being confirmed (or
    /// the lock), a slab tap needs to give that up: one outline grown on the floor that passes the checks is not enough
    static let tapSwitchFinds = 2
    /// when the slab tap that has not led to a lock yet was made, and when the ball tap
    private var slabTapTime: Double?
    private var ballTapTime: Double?
    private var sideEvidence = 0.0
    private var depthEstimate: DepthEstimate?
    private var fusing = false
    private var lastRecheckKind = "ok"
    /// the side profile the detector has learned on the slab it follows (the latest detection used that carries one; nil
    /// when none or after the detector's memory was dropped): the box model's bands (`cutFlip`, `fitsTell`) use it
    private var learnedProfile: (faceDrop: Double, sideRun: Double)?
    private var lastHintTime = -Double.infinity
    private var weakRejections = 0                         // outlines rejected as ill-conditioned in this detection
    private var pendingControls: [TrackerControl] = []     // since the last frame (see TrackerOutput.controls)
    private var detectionBumps: [String]? = nil            // counters bumped by the detection running now
    private var rejectedNow: [String] = []                 // verdict keys rejected by the detection running now

    public init(settings: TrackerSettings = TrackerSettings(), detector: SlabDetecting, ballLocator: BallLocating? = nil) {
        self.settings = settings; self.detector = detector; self.ballLocator = ballLocator
        honest = HonestTilt(settings: settings.settle)
        pendingControls = [TrackerControl(kind: .start, settings: settings)]
        detector.apply(settings)
    }

    func bump(_ k: String) {
        counts[k, default: 0] += 1
        detectionBumps?.append(k)
    }

    /// Whether the next frame at time t will run the slab detector (so the caller knows to prepare its image), if its
    /// tracking state is normal. `tap`: the frame brings a slab tap (`tapSeedsSlab`), which asks for a run on that frame
    /// without tap hints (n11), and with them only while locked (a look under the finger, `probeTappedSlab`): before the
    /// lock a tap with hints is a hint for the scheduled searches alone, never a search of its own (one more search, on a
    /// frame the schedule would not have searched, changes which frames are measured and can cost a marginal shot its
    /// lock). A run is due when the interval for the state has passed since the last scheduled one (or something forced
    /// one: a tap, a reset, a discontinuity), and never sooner than `minDetectionGap` after the last run (a clock that
    /// went backwards does not hold it back). (This decides it exactly, which a replay relies on.)
    public func detectionDue(at t: Double, tap: Bool) -> Bool {
        let since = t - lastDetectionRun
        if since >= 0 && since < settings.minDetectionGap { return false }
        let interval = state == .locked && !sidesUndecided ? settings.recheckInterval
            : state == .searching && searchIdle ? max(settings.searchInterval, settings.idleSearchInterval) : settings.searchInterval
        let tapRuns = tap && (!settings.tapHints || state == .locked)
        return tapRuns || t - lastCheck >= interval
    }

    /// whether searches are backed off (`TrackerSettings.idleSearchAfter`): set after each frame
    public private(set) var searchIdle = false
    /// the first of the latest run of empty searches from a still camera: its time and the camera's position and view
    /// direction (world)
    private var emptySearches: (time: Double, position: Vec3, forward: Vec3)?

    /// After a frame (`process`): whether the next searches are backed off. `searched`: the detector searched on this
    /// frame (not a re-check).
    private func updateSearchIdle(_ f: TrackerFrame, searched: Bool) {
        guard settings.idleSearchAfter > 0, state == .searching, seed == nil, f.trackingNormal else {
            emptySearches = nil; searchIdle = false
            return
        }
        let pos = f.view.position, fwd = f.view.worldFromCamera.applyDirection(Vec3(0, 0, 1))
        if let e = emptySearches {
            let turned = Units.degrees(acos(clamp(e.forward.dot(fwd), -1, 1)))
            if turned > settings.idleSearchMoveDegrees || pos.distance(to: e.position) > settings.idleSearchMoveDistance {
                // the camera moved on: another view, searched at the usual rate (from this search, if it was one)
                emptySearches = searched ? (f.timestamp, pos, fwd) : nil
                searchIdle = false
                return
            }
        } else if searched {
            emptySearches = (f.timestamp, pos, fwd)
        }
        if let e = emptySearches, searched { searchIdle = f.timestamp - e.time >= settings.idleSearchAfter }
    }

    /// The same for a frame without a tap.
    public func detectionDue(at t: Double) -> Bool { detectionDue(at: t, tap: false) }

    /// Whether `process` will run the slab detector on the next frame (time t; `tap`: it brings a tap; `trackingNormal`:
    /// its tracking state is normal), exactly: the detector is all that reads the frame's colour image
    /// (`TrackerFrame.frame`), so a caller may hand a blank one otherwise (the app converts the colour frame only then).
    /// (A tap, and a reset still pending from an earlier tap, only ever make a run due sooner, and `detectionDue` with
    /// `tap` already counts them; `process` then runs the detector only if tracking is normal.)
    public func detectorWillRun(at t: Double, tap: Bool, trackingNormal: Bool) -> Bool {
        trackingNormal && detectionDue(at: t, tap: tap)
    }

    /// a rectangular slab whose long side the evidence has not settled yet: re-check at the search rate to gather it
    private var sidesUndecided: Bool {
        settings.spec.sideU != settings.spec.sideV && settings.sideDecidedEvidence > 0 && abs(sideEvidence) < settings.sideDecidedEvidence
    }

    /// Whether the next frame at time t will run the ball finder (so the caller knows to prepare its image).
    public func ballDue(at t: Double) -> Bool {
        ballLocator != nil && state == .locked && t - lastBall >= currentBallInterval
    }

    /// the ball finder's interval now: `ballInterval`, or `idleBallInterval` once its scans have found nothing for
    /// `idleBallAfter`
    private var currentBallInterval: Double {
        guard ballHint == nil, settings.idleBallAfter > 0, let since = emptyBallScans, lastBall - since >= settings.idleBallAfter else { return settings.ballInterval }
        return max(settings.ballInterval, settings.idleBallInterval)
    }
    /// the first of the latest run of ball scans that found no ball (and left nothing waiting for a second scan)
    private var emptyBallScans: Double?

    /// Forget the slab and search again.
    public func reset() {
        forget()
        emptySearches = nil; searchIdle = false
        seed = nil; slabTapTime = nil; tapResetPending = false; noiseSamples = []; endTapChallenge()
        bump("reset")
        pendingControls.append(TrackerControl(kind: .reset))
    }

    /// ARKit's world frame may have moved under the lock: call when an interruption ends, when ARKit relocalises, or on
    /// any other reason to doubt the stored world coordinates. The lock is kept but must be seen where it should be (or a
    /// consistent slab elsewhere in view re-locks it) within `unconfirmedTimeout` seconds of normal tracking, or it
    /// expires ("lost"). The next frame runs a detection. The tracker notices large jumps of the camera's position and a
    /// long spell of limited tracking by itself.
    public func noteWorldDiscontinuity(_ reason: String = "world-frame") {
        pendingDiscontinuity = reason
        lastCheck = -.infinity
        emptySearches = nil; searchIdle = false
        pendingControls.append(TrackerControl(kind: .worldDiscontinuity, reason: reason))
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

    /// The lock's history after a new detection joins it: `trimmed`, and with `lockKeepsNewestPerView` a view's older
    /// detections only while they agree with what that view shows now. A view (as `HonestTilt` groups them: directions
    /// from the slab to the camera within `SettleSettings.groupDegrees` of the view's newest) shows its newest
    /// `SettleSettings.perGroup` detections; an older one whose normal is beyond `matchSigmas` of their estimate (the
    /// tracker's own gate) in the detections' own noise (`Measurement.ownNormalCov`: the detector's per-side noise less
    /// what every view shares; without it the corner noise the tracker has measured) goes, so a still view's early
    /// detections on the wrong edge age out within about a second, while detections that agree keep averaging the lock's
    /// jitter down. Those that went
    /// come back, newest first, while the rest cannot pin the normal to `maxLockSigmaDegrees`. A measurement without its
    /// camera is kept.
    private func trimmedLock(_ ms: [Measurement]) -> [Measurement] {
        let out = trimmed(ms)
        let k = max(1, settings.settle.perGroup)
        guard settings.lockKeepsNewestPerView, out.count > k else { return out }
        let lim = Units.radians(settings.settle.groupDegrees)
        var views: [(direction: Vec3, newest: [Int])] = []
        var viewOf = [Int?](repeating: nil, count: out.count)
        for i in out.indices.reversed() {
            guard let c = out[i].camera else { continue }
            let v = (c.position - out[i].pose.center).normalized
            guard v.isFinite else { continue }
            var j = views.firstIndex { $0.direction.angle(to: v) < lim }
            if j == nil { views.append((v, [])); j = views.count - 1 }
            viewOf[i] = j
            if views[j!].newest.count < k { views[j!].newest.append(i) }
        }
        let now = views.map { v in SlabTracker.estimate(v.newest.map { out[$0] }) }
        // what the view's newest show (their mean's own error: theirs averaged, over their number)
        let nowOwn: [Mat3?] = views.map { v in
            let cs = v.newest.compactMap { out[$0].ownNormalCov }
            guard cs.count == v.newest.count, !cs.isEmpty else { return nil }
            return mscale(cs.reduce(Mat3(rows: [0, 0, 0, 0, 0, 0, 0, 0, 0])) { madd($0, $1) }, 1 / Double(cs.count * cs.count))
        }
        let s2 = max(pow(cornerNoiseEstimate, 2), 1e-12), gate = pow(settings.matchSigmas, 2)
        var keep = [Bool](repeating: true, count: out.count)
        for i in out.indices {
            guard let j = viewOf[i], !views[j].newest.contains(i), let e = now[j] else { continue }
            // against the view's newest, in the two detections' own noise (one view: what they share is the same error),
            // or without it, in the tracker's corner-noise model
            let C: Mat3
            if let a = out[i].ownNormalCov, let b = nowOwn[j] { C = madd(a, b) } else { C = mscale(madd(out[i].est.ncov, e.ncov), s2) }
            let m2 = SlabTracker.mahalanobis2(out[i].pose.normal, e.pose.normal, C)
            if !(m2 <= gate) { keep[i] = false }
        }
        guard keep.contains(false) else { return out }
        let s = cornerNoiseEstimate
        func pinned(_ x: [Bool]) -> Bool {
            guard let e = SlabTracker.estimate(out.indices.filter { x[$0] }.map { out[$0] }) else { return false }
            return Units.degrees(e.sigma) * s <= settings.maxLockSigmaDegrees
        }
        // those that went come back, newest first, while the rest cannot pin the normal
        for i in out.indices.reversed() where !keep[i] {
            if pinned(keep) { break }
            keep[i] = true
        }
        return out.indices.filter { keep[$0] }.map { out[$0] }
    }

    // MARK: one frame

    /// One frame. Cheap when locked and no re-check is due: projects the lock and works out the bounce.
    public func process(_ f: TrackerFrame) -> TrackerOutput {
        let t = f.timestamp
        let dt = previousTime.map { clamp(t - $0, 0, 0.5) } ?? 0
        previousTime = t
        lastFrameTime = t
        // the camera's turn since the last frame, over this frame's exposure: its motion blur
        frameBlur = 0
        if let p = previousCamera, t > p.time, t - p.time < 0.5 {
            frameBlur = KitMotionBlur.pixels(previous: p.pose, current: f.view.worldFromCamera, dt: t - p.time,
                                             exposure: f.exposureDuration ?? settings.settle.defaultExposure, focal: f.view.intrinsics.focal)
        }
        previousCamera = (t, f.view.worldFromCamera)
        bump("frames")
        var events: [String] = []
        let downW = ARKitConvention.worldDown
        let downCam = f.view.directionToCamera(downW)
        var measurementQuad: [Vec2]? = nil
        let controls = pendingControls
        pendingControls = []
        var detections: [DetectedOutline]? = nil
        var detectionKind: TrackerDetectionKind? = nil
        frameDetail = nil; frameRefined = nil

        // the ball tap's search and the dismissed spots age (before this frame's tap)
        ageTapHints(dt, &events)
        // a tap: look for the slab there until it locks; with tracking limited, start over once it is normal again. With
        // tap hints, what is under the finger decides (`tapMeaning`): the ball's ring, the space over the locked slab
        var tapNote: TrackerTap? = nil
        var tapLooks = false
        if let tp = f.tap {
            switch tapMeaning(tp, f.view) {
            case .slab:
                tapNote = TrackerTap(kind: .slab, pixel: tp)
                tapLooks = tapSlab(tp, f, &events)
            case .ball(let h):
                tapNote = TrackerTap(kind: .ball, pixel: tp)
                tapBall(h, tp, f, &events)
            case let .dismiss(center, r):
                tapNote = TrackerTap(kind: .dismissBall, pixel: tp, ballCenter: center, ballRadiusPixels: r)
                dismissBall(center, r, f, &events)
            }
        }
        if tapResetPending {
            if f.trackingNormal { forget(); bump("reset"); tapResetPending = false } else if f.tap != nil { events.append("tap-deferred") }
        }

        let due = detectionDue(at: t)
        // with tap hints, a slab tap while locked is looked at on its own frame (the app converts the image for it,
        // `tapSeedsSlab`, `detectionDue(at:tap:)`) and leaves the re-checks' schedule as it was; before the lock it only
        // steers the scheduled searches (`tapSlab` returns false then): the search runs on the same frames as without the
        // tap, so a tap on something that is not the slab leaves the tracker where it would have been
        let tapNow = tapLooks && detectionDue(at: t, tap: true)

        // the processing frame changed size (the camera's video format changed: ARKit re-ran with another one): what is
        // kept in its pixels is rescaled or dropped, and the lock must be seen again (a discontinuity, below)
        var resized = false
        if let old = lastProcessing, old.width != f.view.intrinsics.width || old.height != f.view.intrinsics.height {
            processingFrameChanged(from: old, to: f.view.intrinsics)
            resized = true
        }
        lastProcessing = f.view.intrinsics

        // world-frame discontinuities: reported by the app, a jump of the camera, a long spell of limited tracking, or
        // a new video format
        var discontinuity = pendingDiscontinuity
        pendingDiscontinuity = nil
        if resized { discontinuity = discontinuity ?? "frame-size" }
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
            if s.age > seedLifetime(f.view) { seed = nil; slabTapTime = nil; endTapChallenge(); probeHits = []; events.append("seed-expired") }
        }

        // LiDAR's view of the lock's top: for occlusion and re-lock checks, and folded in below
        func depthCheck(_ s: SlabPose) -> DepthCheck? {
            guard let d = f.depth, let dk = f.depthIntrinsics else { return nil }
            return PlaneFit.checkSlabTop(depth: d, depthIntrinsics: dk, view: f.view, slab: s, down: downW)
        }
        var chk: DepthCheck? = nil, chkFor: SlabPose? = nil
        if state == .locked, let s = imageSlab, f.depth != nil { chk = depthCheck(s); chkFor = s }

        if (due || tapNow) && f.trackingNormal {
            // a slab tap away from the lock: look there first (on the tap's frame and the re-checks while it lasts),
            // keeping the lock unless another slab is found there twice
            if state == .locked, settings.tapHints, seed != nil { probeTappedSlab(f, downCam, &events) }
            // (a probe on the tap's own frame does not move the schedule: `lastCheck`, and the gap after a run, count from
            // the scheduled runs only, so the next one comes on the frame it would have come on without the tap. Only the
            // detection itself sets `lastCheck`; it runs when one is due, or when the lock went on the probe's frame)
            if due { lastDetectionRun = t }
            if due || state != .locked {
                lastCheck = t
                detectionKind = state == .locked ? .recheck : .search
                detections = detect(f, downCam, chk, depthCheck, &events, &measurementQuad)
            }
        }
        // a tap, a discontinuity (reported, or noticed here) or a candidate searches at the usual rate again; so does a
        // camera that moved
        if f.tap != nil || discontinuity != nil { emptySearches = nil; searchIdle = false }
        updateSearchIdle(f, searched: detectionKind == .search)

        // LiDAR: the depth plane, averaged in world space over frames that pass its gates, folded into the image lock
        slab = imageSlab
        var fused = false
        if state == .locked, let s = imageSlab {
            if f.depth != nil {
                if chkFor != s { chk = depthCheck(s) }
                if let c = chk {
                    depth = c
                    bump("depthChecks")
                    let why = depthRejection(c, s, f, maxAngle: settings.depthMaxAngleDegrees)
                    noteDepthCheck(c, s, f, rejected: why)
                    if why == nil { addDepth(c, t) } else { bump("depthRejected") }
                }
            }
            if settings.depthNormalWeight > 0 || settings.depthCentreWeight > 0, let e = depthEstimate, t - e.time <= settings.depthHoldSeconds {
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
        out.controls = controls
        out.detections = detections
        out.detectionKind = detectionKind
        out.slabDetail = frameDetail
        out.refinedDetections = frameRefined
        out.tiltSigmaDegrees = tiltSigmaDegrees
        out.angleSettled = angleSettled
        out.viewGroups = viewGroupCount
        out.tap = tapNote
        // a re-lock (the slab moved, or its outline moved onto the top): the ball tap and the dismissed spots go
        if events.contains("relocked") { clearTapBall() }
        out.ballHintActive = ballHint != nil; out.dismissedSpots = dismissedSpots.count
        guard state == .locked, let s = slab else { return out }
        out.outline = project(s, f.view)

        // the ball
        if let loc = ballLocator, let img = f.ballImage, let bk = f.ballIntrinsics, f.timestamp - lastBall >= currentBallInterval {
            lastBall = f.timestamp
            out.ballSearched = true
            let sc = s.transformed(by: f.view.cameraFromWorld)
            // the owner's taps, in this scan's image (none without tap hints)
            let hints = settings.tapHints ? ballSearchHints(f, bk) : BallSearchHints()
            loc.setSearchHints(hints)
            if let b = loc.locate(image: img, intrinsics: bk, slab: sc, spec: settings.spec, ball: settings.ball, down: downCam) {
                if hints.avoids(b.circle) {
                    // a finder that does not pass over dismissed spots itself: the tracker does
                    ballState = nil; bump("tapDismissPassed")
                } else {
                    ballState = (f.view.toWorld(b.center), b.circle, b.radius); bump("ballFrames"); lastBallSeen = t
                    // found where the owner tapped the ball (the right ball or not: the owner can dismiss its ring): the
                    // search stays on it, re-centred on it, until `tapBallSeconds` pass without a find in its box
                    if let h = ballHint, let r = hints.region, r.contains(b.circle) {
                        if !h.found {
                            bump("tapBallFound"); out.events.append("tap-ball-found")
                            if let t0 = ballTapTime { tapBallFoundSeconds.add(t - t0) }
                            ballTapTime = nil
                        }
                        ballHint = TapHints.recentred(h, on: f.view.toWorld(b.center), from: f.view.position)
                    }
                }
            } else { ballState = nil }
            // nothing shown or about to be: the run of empty scans goes on (or starts)
            let awaits = loc.awaitsConfirmation
            out.ballAwaitsConfirmation = awaits
            if ballState == nil && !awaits { emptyBallScans = emptyBallScans ?? t } else { emptyBallScans = nil }
        }
        // a new lock, a re-lock or a discontinuity: the ball is looked for at the usual rate again
        if events.contains(where: { $0 == "locked" || $0 == "relocked" || $0.hasPrefix("lock-unconfirmed") }) { emptyBallScans = nil }
        out.ball = ballState

        // the bounce, in world coordinates: from the lock, or once the tilt is settled (and the settings say so) from the
        // lock's centre with the settled normal
        var shown = s
        if settings.readoutsFromSettledNormal, out.angleSettled, let n = honest.normal, n.isFinite {
            let u = s.axisU.rejecting(n).normalized
            shown = SlabPose(center: s.center, normal: n, axisU: u, axisV: n.cross(u), halfU: s.halfU, halfV: s.halfV)
        }
        let floorBelow = f.floorY.map { s.center.y - $0 }.flatMap { $0 > 0.005 && $0 < 1.0 ? $0 : nil }
        let res = Bounce.compute(pose: shown, spec: settings.spec, ball: settings.ball, down: downW, ballCenter: ballState?.center,
                                 defaultDropHeight: settings.defaultDropHeight, rule: settings.launchRule, floorBelowCenter: floorBelow)
        out.path = res.path; out.drop = res.drop
        out.readouts = Readouts(tiltDegrees: Units.degrees(shown.tilt(down: downW)), apexHeight: res.path.apexHeight, landingDistance: res.path.range,
                                airTime: res.path.airTime, dropHeight: res.drop?.dropHeight ?? settings.defaultDropHeight, dropFromBall: res.drop != nil)
        out.ballHintActive = ballHint != nil; out.dismissedSpots = dismissedSpots.count
        return out
    }

    // MARK: detection

    /// Runs the detector and acts on what it found; returns the detector's raw outlines.
    private func detect(_ f: TrackerFrame, _ downCam: Vec3, _ chk: DepthCheck?, _ depthCheck: (SlabPose) -> DepthCheck?,
                        _ events: inout [String], _ measurementQuad: inout [Vec2]?) -> [DetectedOutline] {
        let t = f.timestamp
        var record = DetectionRecord(time: t, state: state, found: 0)
        detectionBumps = []; rejectedNow = []
        var used: Measurement? = nil
        var found: [DetectedOutline] = []
        var edges: String? = nil
        defer {
            record.found = found.count
            record.rejected = rejectedNow
            record.outcome = (detectionBumps ?? []).filter { !["searches", "rechecks", "detections", "slabCrops", "slabRefines"].contains($0) && !$0.hasPrefix("reject:") }
            if let m = used {
                let p = m.pose, sides = (0..<4).map { m.quad[$0].distance(to: m.quad[($0 + 1) % 4]) }
                record.center = p.center.array; record.normal = p.normal.array
                record.tiltDegrees = Units.degrees(p.tilt(down: ARKitConvention.worldDown))
                record.sigmaDegrees = Units.degrees(m.est.sigma); record.rmsPixels = m.rms
                record.distance = p.center.distance(to: f.view.position)
                record.sidesPixels = sides
                record.aspect = (sides[0] + sides[2]) / max(sides[1] + sides[3], 1e-9)
                record.sideModes = m.sideModes.isEmpty ? nil : m.sideModes
                record.edges = edges
            }
            if let h = honestNote, h.time == t, let d = h.detection {
                record.viewSigmaDegrees = d.sigmaDegrees; record.misfitChi2 = d.chi2; record.misfitExcluded = d.excluded
            }
            detectionLog.append(record)
            if detectionLog.count > SlabTracker.detectionLogSize { detectionLog.removeFirst(detectionLog.count - SlabTracker.detectionLogSize) }
            detectionBumps = nil
        }
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
        // following the lock's outline: full-resolution pixels around it for the edge steps, up front
        var askedForDetail = false
        if let provide = f.slabDetail, let q = near {
            askedForDetail = true
            frameDetail = provide(q)
            if frameDetail != nil { bump("slabCrops") }
        }
        // A tapped search with tap hints: the whole view's search, its outlines made and counted as without a tap; those
        // under the finger come first (`choose`). Only where the search has no outline at all, the slab grown from the
        // tapped point (and around it), through the search's own light-independent screens (`SlabFinder.Options.
        // tapScreens`): the tap fills in where the search has nothing, and never sets aside what it found elsewhere (a
        // tap on the floor costs nothing then). Without tap hints, n11's: the grown slab alone.
        let tappedFirst = settings.tapHints && seedPx != nil
        found = detector.detect(frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam,
                                seed: tappedFirst ? nil : seedPx, near: near, detail: frameDetail?.image)
        bump(state == .locked ? "rechecks" : "searches")
        let reference = referenceNormal(t).map { f.view.directionToCamera($0) }
        weakRejections = 0
        var options = found.compactMap { measure($0, f, downCam, reference) }
        // how many the search had seen too nearly face-on, of how many (before any grown from the tap)
        let sweptCount = found.count, sweptWeak = weakRejections
        if tappedFirst, options.isEmpty, let sp = seedPx {
            // (`probe`: the edge memory the search just left is kept)
            let grown = detector.probe(frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam, seed: sp)
            bump("tapSlabGrown")
            for o in grown {
                guard var m = measure(o, f, downCam, reference), SlabTracker.contains(m.quad, sp, slack: 0.25) else { continue }
                m.fromTap = true; options.append(m); found.append(o)
            }
            if !options.isEmpty { bump("tapSlabGrownUsed") }
        }
        guard var chosen = choose(options, f, seedPx: seedPx) else {
            switch state {
            case .confirming:
                // an outline seen too nearly face-on to pin the tilt is still the slab: keep what is being confirmed
                if sweptWeak > 0 && sweptWeak == sweptCount { bump("confirmWeak"); break }
                candidates = []; state = .searching; events.append("candidate-lost"); endTapChallenge()
            case .locked:
                miss(f, inView: inView, chk: chk, found: found, lockQ: lockQ, &events)
            case .searching: break
            }
            return found
        }
        // a re-check given the crop around the lock's outline up front: its edges came from the crop only if the crop
        // covers the outline used and the edge steps' reach around it (the finder's own rule); one found further off
        // (the slab moved, the lock drifted) was measured on the processing frame (counted, not labelled "crop")
        if let d = frameDetail {
            if FinderRun.detailCovers(chosen.quad, frameWidth: f.view.intrinsics.width, frameHeight: f.view.intrinsics.height,
                                      detail: d.image, map: ImageMap(from: f.view.intrinsics, to: d.intrinsics)) {
                edges = "crop"
            } else {
                bump("slabCropMisses")
            }
        }
        // a search's find (searching or confirming, or a re-check over the whole view): found on the processing frame,
        // then refined on full-resolution pixels around it, the detector following that one outline as it follows a
        // lock, so no measurement that feeds the lock is left on the processing frame's coarse edges
        if !askedForDetail, let provide = f.slabDetail, let d = provide(chosen.quad) {
            frameDetail = d
            bump("slabCrops")
            let raw = detector.refine(outline: chosen.quad, frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam,
                                      detail: d.image)
            frameRefined = raw
            // the refined outline: the first that passes the shape checks and lies where the find was (not another object)
            let tol = max(2, 0.15 * ShapeCheck.meanSide(chosen.quad))
            let found0 = chosen.quad
            if var m = raw.lazy.compactMap({ self.measure($0, f, downCam, reference, counting: false) })
                .first(where: { SlabTracker.rmsDistance(SlabTracker.aligned($0.quad, to: found0), found0) <= tol }) {
                m.fromTap = chosen.fromTap
                chosen = m; edges = "refined"; bump("slabRefines")
            } else {
                bump("slabRefineMisses")
            }
        }
        bump("detections")
        used = chosen
        if settings.spec.hasProfile, let p = chosen.profile { learnedProfile = p }
        measurementQuad = chosen.quad
        lastSideModes = chosen.sideModes
        switch state {
        case .searching:
            let m = applySideEvidence(chosen, &events)
            lastMeasured = (m.pose.normal, t)
            candidates = [m]; state = .confirming; events.append("candidate")
            tryLock(t, &events)
        case .confirming:
            // with tap hints, an outline under the finger that is not the candidate does not restart it at once
            if settings.tapHints, let sp = seedPx, SlabTracker.contains(chosen.quad, sp, slack: 0.25), tapChallenge(chosen, f, &events) { break }
            confirm(applySideEvidence(chosen, &events), f, &events)
        case .locked:
            recheck(chosen, f, inView: inView, chk: chk, depthCheck: depthCheck, found: found, lockQ: lockQ, &events)
        }
        return found
    }

    /// rms distance between corresponding corners
    static func rmsDistance(_ a: [Vec2], _ b: [Vec2]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return (zip(a, b).reduce(0) { $0 + pow($1.0.distance(to: $1.1), 2) } / Double(a.count)).squareRoot()
    }

    /// A detected outline's pose(s), checked; nil (and counted, unless `counting` is false) if it fails the shape check.
    private func measure(_ o: DetectedOutline, _ f: TrackerFrame, _ downCam: Vec3, _ previousNormal: Vec3?, counting: Bool = true) -> Measurement? {
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
        guard verdict == .ok, let fit = chosen else { if counting { reject(verdict, f.timestamp) }; return nil }
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
        var m = Measurement(est: est(fit), alt: other.map(est), quad: fit.cornersInPoseOrder(o.quad),
                            sideModes: o.sideModes.count == 4 ? fit.sidesInPoseOrder(o.sideModes) : o.sideModes, time: f.timestamp,
                            rms: fit.rmsPixels, camera: f.view, blur: frameBlur)
        if o.sideSigmas.count == 4 { m.sideSigmasPixels = fit.sidesInPoseOrder(o.sideSigmas) }
        if o.sideTurnSigmas.count == 4 { m.sideTurnSigmasPixels = fit.sidesInPoseOrder(o.sideTurnSigmas) }
        if o.sideFrameSigmas.count == 4 { m.sideFrameSigmasPixels = fit.sidesInPoseOrder(o.sideFrameSigmas) }
        if let h = o.faceDrop, let r = o.sideRun { m.profile = (h, r) }
        return m
    }

    private func reject(_ v: ShapeCheck.Verdict, _ t: Double) {
        bump("reject:" + v.key)
        rejectedNow.append(v.key)
        if let x = v.value { rejectionValues[v.key, default: ValueSummary()].add(x) }
        if case .illConditioned = v { lastHintTime = t; weakRejections += 1 }
    }

    /// Which of a frame's outlines to use: one on the tapped point, else one that agrees with what is being confirmed or
    /// with the lock (or is its cut-face flip), else one near the lock, else the detector's best.
    private func choose(_ ms: [Measurement], _ f: TrackerFrame, seedPx: Vec2?) -> Measurement? {
        guard let first = ms.first else { return nil }
        if settings.tapHints, let sp = seedPx {
            // with tap hints, the outlines under the finger come first: while searching, one of them; while confirming,
            // one that agrees with what is being confirmed (as without the tap: taking another would only start over),
            // else any that agrees, else one under the finger (`tapChallenge` decides on it), else as without the tap
            let under = ms.filter { SlabTracker.contains($0.quad, sp, slack: 0.25) }
            if state == .searching, let m = under.first { return m }
            if state == .confirming, let ref = SlabTracker.estimate(candidates) {
                let s = cornerNoiseEstimate
                func agreeing(_ m: Measurement) -> Bool { agrees(ref, m.est, noise: s) || cutFlip(m.quad, of: ref.pose, f, noise: s) != nil }
                if let m = under.first(where: agreeing) ?? ms.first(where: agreeing) ?? under.first { return m }
            }
        } else if let sp = seedPx, let m = ms.first(where: { SlabTracker.contains($0.quad, sp, slack: 0.25) }) { return m }
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
        let fit = SlabTracker.meanRms(candidates)
        // one side caught at the bottom of its cut face: keep the inner (top) outline, unless this one fits the square
        // clearly better (the candidates have a side a band inside the top)
        if let sides = cutFlip(m.quad, of: ref.pose, f, noise: s) {
            if m.rms < fit - SlabTracker.clearlyBetterFit * s && fitsTell(ref.pose, sides, f, noise: s) {
                bump("confirmRestarts"); candidates = [m]; lastMeasured = (m.pose.normal, t); events.append("candidate-restart")
                return
            }
            bump("cutFlips"); note("candidate-cutflip", &events)
            return
        }
        // the candidates are this outline's flip: it is the top, unless it fits clearly worse (a side a band inside)
        if let rq = project(ref.pose, f.view), let sides = cutFlip(rq, of: m.pose, f, noise: s, closer: SlabTracker.innerCloser) {
            bump("cutFlips")
            if m.rms > fit + SlabTracker.clearlyWorseFit * s && fitsTell(m.pose, sides, f, noise: s) { note("candidate-cutflip", &events); return }
            bump("confirmRestarts")
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
        hist = candidates; refreshLock(); slab = imageSlab; state = .locked; candidates = []; movers = []; recent = []; partners = []; implausible = 0
        lastGood = t; misses = 0; unconfirmed = nil; seed = nil; depthEstimate = nil; lastRecheckKind = "ok"
        endTapChallenge(); probeHits = []
        hist = honestRestart(with: hist)
        events.append("locked"); bump("locks")
        if let t0 = slabTapTime { tapSlabLockSeconds.add(t - t0); bump("tapSlabLocks") }
        slabTapTime = nil
    }

    // MARK: re-checks while locked

    private func recheck(_ m0: Measurement, _ f: TrackerFrame, inView: Bool, chk: DepthCheck?, depthCheck: (SlabPose) -> DepthCheck?,
                         found: [DetectedOutline], lockQ: [Vec2]?, _ events: inout [String]) {
        guard let L = lockEstimate else { return }
        let t = f.timestamp, s = cornerNoiseEstimate
        // the near edge caught at the bottom of its cut face: the lock is where it was, but this outline is not the top
        if let sides = cutFlip(m0.quad, of: L.pose, f, noise: s) {
            // unless it fits the square clearly better than the lock's own measurements: then the lock has a side a band
            // inside the top, and this is the top
            if m0.rms < SlabTracker.meanRms(hist) - SlabTracker.clearlyBetterFit * s && fitsTell(L.pose, sides, f, noise: s) {
                topRecheck(applySideEvidence(m0, &events), f, outer: true, chk: chk, depthCheck: depthCheck, &events)
                return
            }
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
        // the other way round: the lock is this outline's cut-face flip (it was confirmed on outlines caught at the
        // bottom of the cut face) and this one is the top
        if let lq = project(L2.pose, f.view), let sides = cutFlip(lq, of: m.pose, f, noise: s, closer: SlabTracker.innerCloser) {
            if m.rms > SlabTracker.meanRms(hist) + SlabTracker.clearlyWorseFit * s && fitsTell(m.pose, sides, f, noise: s) {
                // it fits clearly worse than the lock's measurements: a side put a band inside the top
                bump("recheckInnerWorse"); lastGood = t; misses = 0
                if unconfirmed != nil { confirmLock(&events) }
                note("recheck-inner-worse", &events)
                return
            }
            topRecheck(m, f, outer: false, chk: chk, depthCheck: depthCheck, &events)
            return
        }
        recent.append(m)
        if recent.count > max(2, settings.slideWindow) { recent.removeFirst(recent.count - max(2, settings.slideWindow)) }
        // a re-check of the locked slab (agreeing with the lock or not; not a cut-face flip, a band apart, or far off):
        // one more detection for the tilt's honest uncertainty
        let own = honestAdd(m)
        let agreed = agrees(L2, m.est, noise: s)
        if agreed {
            // the detector's noise, from how far agreeing re-checks land from the lock (before this one joins it); not
            // from the others, or a sustained systematic error would widen the gates enough to let itself in
            noiseSamples.append(SlabTracker.mahalanobis2(m.pose.normal, L2.pose.normal, madd(m.est.ncov, L2.ncov)))
            if noiseSamples.count > 60 { noiseSamples.removeFirst(noiseSamples.count - 60) }
            var mh = m
            mh.ownNormalCov = own
            hist.append(mh)
            hist = trimmedLock(hist)
            refreshLock()
            // a re-check nearer the would-be move than the lock still counts toward it
            if let me = SlabTracker.estimate(movers), m.pose.normal.angle(to: me.pose.normal) < m.pose.normal.angle(to: L2.pose.normal) {
                movers.append(m)
            } else {
                movers = []; implausible = 0
            }
            // against a lock on the wrong edge of a band, its re-checks on that edge agree with it: they do not count
            // against the top re-checks gathered so far, anything else does
            if let e = SlabTracker.estimate(partners), !bandApart(m, e.pose, f, noise: s) { partners = [] }
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
    /// the evidence). `top`: they are the top, a band from the lock's outline (`topRecheck`; no cradle check).
    @discardableResult
    private func tryRelock(to ms: [Measurement], _ f: TrackerFrame, chk: DepthCheck?, depthCheck: (SlabPose) -> DepthCheck?, slide: Bool,
                           top: Bool = false, _ events: inout [String]) -> Bool {
        guard let L = lockEstimate, let M = SlabTracker.estimate(ms) else { return false }
        var depthAgrees = false
        if let lc = chk, let mc = depthCheck(M.pose) {
            if lc.angleToImageDegrees < 4 && mc.angleToImageDegrees > lc.angleToImageDegrees + 4 {
                bump("relockRejectedDepth"); events.append("relock-rejected-depth")
                movers = []; recent = []; partners = []
                return false
            }
            depthAgrees = mc.angleToImageDegrees < 4
        }
        if !top, unconfirmed == nil, !depthAgrees, !plausibleSlide(from: L, to: M) {
            implausible += 1
            if implausible == 1 { bump("relockImplausible"); events.append("relock-implausible") }
            if implausible < 2 * settings.moveCount { return false }
        }
        hist = ms; refreshLock(); movers = []; recent = []; partners = []; implausible = 0
        lastGood = f.timestamp; misses = 0; unconfirmed = nil; depthEstimate = nil; lastRecheckKind = "ok"
        hist = honestRestart(with: ms)
        events.append("relocked"); bump("relocks"); if slide { bump("slides") }; if top { bump("relocksToTop") }
        ballLocator?.reset(); ballState = nil
        return true
    }

    /// A re-check a band from the lock on a side whose cut face shows, taken for the top: the lock is its cut-face flip
    /// (`outer` false: the lock was confirmed on flipped outlines), or it is the lock's flip and fits the square clearly
    /// better (`outer` true: the lock has a side a band inside the top). The slab is where the lock is, and
    /// `topRelockCount` of these that agree with each other within `topRelockSeconds` re-lock onto them; re-checks on
    /// the lock's edge between them agree with the lock and leave them be.
    private func topRecheck(_ m: Measurement, _ f: TrackerFrame, outer: Bool, chk: DepthCheck?, depthCheck: (SlabPose) -> DepthCheck?,
                            _ events: inout [String]) {
        let t = f.timestamp, s = cornerNoiseEstimate
        lastGood = t; misses = 0
        if unconfirmed != nil { confirmLock(&events) }
        bump(outer ? "recheckOuterBetter" : "recheckInner")
        partners.removeAll { t - $0.time > settings.topRelockSeconds }
        if let e = SlabTracker.estimate(partners), agrees(e, m.est, noise: s) { partners.append(m) } else { partners = [m] }
        if partners.count >= max(1, settings.topRelockCount),
           tryRelock(to: partners, f, chk: chk, depthCheck: depthCheck, slide: false, top: true, &events) { return }
        note(outer ? "recheck-outer" : "recheck-inner", &events)
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
        emptyBallScans = nil
        state = .searching; slab = nil; imageSlab = nil; lockEstimate = nil; lockSigmaDegrees = nil; hist = []; depth = nil
        movers = []; recent = []; partners = []; implausible = 0; candidates = []; unconfirmed = nil; depthEstimate = nil; fusing = false; misses = 0
        longSideWorld = nil; sideEvidence = 0; lastMeasured = nil; ballState = nil; ballLocator?.reset()
        honest.reset()
        clearTapBall(); endTapChallenge(); probeHits = []
        events.append("lost"); bump("lost")
    }

    /// Everything but the tap's seed (and the backed-off searches, which `reset`, a tap and a discontinuity end).
    private func forget() {
        emptyBallScans = nil
        state = .searching; hist = []; slab = nil; imageSlab = nil; lockEstimate = nil; lockSigmaDegrees = nil; candidates = []; movers = []
        recent = []; partners = []; implausible = 0
        depth = nil; lastCheck = -.infinity; lastGood = -.infinity; ballState = nil; ballLocator?.reset()
        unconfirmed = nil; misses = 0; depthEstimate = nil; fusing = false; longSideWorld = nil; sideEvidence = 0; lastMeasured = nil
        lastRecheckKind = "ok"; learnedProfile = nil
        honest.reset()
        clearTapBall(); endTapChallenge(); probeHits = []
    }

    /// The processing frame changed size (ARKit re-ran with another video format; the caller also treats it as a
    /// world-frame discontinuity). What the tracker keeps in its pixels is moved to the new frame's: the measurements'
    /// uncertainties and misfits (stated for 1 pixel of corner noise) are rescaled by the new pixel's size (the focal
    /// lengths' ratio), their outlines mapped, the side evidence (pose-fit costs in pixels) rescaled; what cannot be
    /// carried over is dropped: the corner noise measured in the old pixels (`cornerNoiseEstimate` falls back to the
    /// assumed `cornerNoisePixels` until re-checks in the new frame measure it again: a detector's noise in pixels does
    /// not simply scale with the pixel), the detector's edge memory, the ball finder's state.
    private func processingFrameChanged(from old: CameraIntrinsics, to new: CameraIntrinsics) {
        bump("frameSizeChanges")
        let r = new.focal / old.focal
        if r.isFinite && r > 0 {
            let map = ImageMap(from: old, to: new)
            func scaled(_ e: Estimate) -> Estimate {
                var x = e
                x.sigma = e.sigma / r; x.ncov = mscale(e.ncov, 1 / (r * r)); x.cov = mscale(e.cov, 1 / (r * r)); x.cost = e.cost * r * r
                return x
            }
            func rescaled(_ m: Measurement) -> Measurement {
                var x = m
                x.est = scaled(m.est); x.alt = m.alt.map(scaled); x.quad = m.quad.map(map.forward); x.rms = m.rms * r
                x.camera = m.camera.map { CameraView(worldFromCamera: $0.worldFromCamera, intrinsics: new) }
                x.blur = m.blur * r
                x.sideSigmasPixels = m.sideSigmasPixels?.map { $0 * r }; x.sideTurnSigmasPixels = m.sideTurnSigmasPixels?.map { $0 * r }
                x.sideFrameSigmasPixels = m.sideFrameSigmasPixels?.map { $0 * r }
                return x
            }
            hist = hist.map(rescaled); candidates = candidates.map(rescaled); movers = movers.map(rescaled)
            recent = recent.map(rescaled); partners = partners.map(rescaled)
            sideEvidence = min(settings.sideEvidenceCap, sideEvidence * r * r)
        }
        noiseSamples = []
        previousCamera = nil
        ballState = nil; ballLocator?.reset()
        detector.forgetPixelMemory()
        learnedProfile = nil
        if !hist.isEmpty { refreshLock() }
    }

    private func onDiscontinuity(_ reason: String, _ events: inout [String]) {
        bump("discontinuities")
        lastMeasured = nil
        seed = nil   // its world point is in the old frame
        slabTapTime = nil; endTapChallenge(); probeHits = []
        clearTapBall()   // so are the ball tap's line and the dismissed spots
        switch state {
        case .locked:
            unconfirmed = (0, 0); movers = []; recent = []; partners = []; implausible = 0; depthEstimate = nil; lastCheck = -.infinity
            // the views were seen in the old world frame: the tilt settles again from the next re-checks
            honest.reset()
            events.append("lock-unconfirmed: " + reason)
        case .confirming:
            candidates = []; state = .searching; events.append("candidate-lost: " + reason)
        case .searching: break
        }
    }

    // MARK: the tilt's honest uncertainty

    /// Start the honest estimate again from these detections (a new lock, a re-lock, the sides swapped). They do not
    /// count toward settling: taken in one moment from one view (or in the search, before the edge memory), they cannot
    /// show a transient, so the tilt shows only after `SettleSettings.settleRefreshes` re-checks of the lock agree.
    /// Returns them with their own normal covariance (`Measurement.ownNormalCov`).
    /// Outlines grown from a slab tap (`Measurement.fromTap`) are left out of it: grown from another starting point than
    /// the search's, their edges can differ from what the search and the re-checks see, and a view the phone does not
    /// come back to would keep them in the shown tilt (the owner's second kit: a walk-around tapped one second in showed
    /// its tilt 1.9 deg off, against 1.1 without the tap).
    private func honestRestart(with ms: [Measurement]) -> [Measurement] {
        honest.reset()
        return ms.map { m in var x = m; if !m.fromTap { x.ownNormalCov = honestAdd(m, counts: false) }; return x }
    }

    /// Add one detection of the locked slab to the honest estimate (and refresh it); `counts`: a re-check, which may count
    /// toward settling. Returns the covariance of the detection's own normal error (`Measurement.ownNormalCov`), if it
    /// could be worked out.
    @discardableResult
    private func honestAdd(_ m: Measurement, counts: Bool = true) -> Mat3? {
        var d: HonestTilt.Detection? = nil
        let s = cornerNoiseEstimate
        if let v = m.camera, let sn = sideNoise(m, v) {
            d = HonestTilt.detection(pose: m.pose, quad: sn.quad, view: v, parallel: sn.parallel, turn: sn.turn, shared: sn.shared, cornerNoise: sn.perCorner ? s : nil, settings: settings.settle)
        }
        honest.add(d, cornerNoise: s, counts: counts)
        honestNote = (m.time, d)
        return d.map { $0.ownCovariance(cornerNoise: s) }
    }

    /// A detection's outline matched corner by corner to its pose (the pose may be its other side assignment), with each
    /// side's noise (pixels), parallel and turn: the detector's own (`Measurement.sideSigmasPixels`), with their floors
    /// (`SettleSettings.parallelFloorRadians`, `turnFloorRadians`); or, without it (`perCorner`), the corner noise the
    /// re-checks show (`cornerNoiseEstimate`, at least 0.25 px: above the floors at a processing frame's focal length),
    /// which `HonestTilt` splits equally into a shift and a turn of each side (s^2 / 2 each: the same normal covariance as
    /// independent corner noise) and keeps following as the re-checks measure it. The frame's motion blur adds to the
    /// parallel part (`SettleSettings.blurShare`). A one-edge side stays on the detector's likelier reading, as in the lock
    /// (its sigma, half a band, covers the other): the likelier one was right on 95% of the owner's first kit's sides with a
    /// band (image-only check), so centring every such side between its two readings (`DetectedOutline.sideShifts`)
    /// moved the estimate half a band off on most of them. Replayed, centring showed the 4.7 ft room scan 1.1 deg off
    /// (0.7 without) and left the honest uncertainty overconfident (2-D error in its sigma: median 0.96 and 95th
    /// percentile 2.43 against 1.17 and 2.18 without; an honest one gives 1.18 and 2.45).
    /// `shared`: the part of each side's parallel noise that is the same in every view (the detector's sigma less its
    /// frame's own part, `Measurement.sideFrameSigmasPixels`; nil when not given: all of it the detection's own).
    private func sideNoise(_ m: Measurement, _ v: CameraView) -> (quad: [Vec2], parallel: [Double], turn: [Double], shared: [Double]?,
                                                                 perCorner: Bool)? {
        guard m.quad.count == 4 else { return nil }
        let st = settings.settle, focal = v.intrinsics.focal
        let j0 = st.parallelFloorRadians * focal, t0 = st.turnFloorRadians * focal, b = st.blurShare * m.blur
        var par: [Double], turn: [Double], shared: [Double]? = nil
        let perCorner: Bool
        if let p = m.sideSigmasPixels, p.count == 4 {
            perCorner = false
            par = p.map { (pow(max($0, j0), 2) + b * b).squareRoot() }
            turn = (m.sideTurnSigmasPixels.flatMap { $0.count == 4 ? $0 : nil } ?? [t0, t0, t0, t0]).map { max($0, t0) }
            if let fr = m.sideFrameSigmasPixels, fr.count == 4 {
                // the whole (floored) less the frame's own (floored the same way, and no more than the whole)
                shared = (0..<4).map { i in
                    let whole = max(p[i], j0), own = min(max(fr[i], j0), whole)
                    return max(0, whole * whole - own * own).squareRoot()
                }
            }
        } else {
            perCorner = true
            par = [b, b, b, b]; turn = [0, 0, 0, 0]
        }
        // the outline in the pose's corner order, and its sides with it
        guard let T = project(m.pose, v) else { return (m.quad, par, turn, shared, perCorner) }
        var best = (rev: false, k: 0), bd = Double.infinity
        for rev in [false, true] {
            let r = rev ? Array(m.quad.reversed()) : m.quad
            for k in 0..<4 {
                let d = (0..<4).reduce(0) { $0 + r[($1 + k) % 4].distance(to: T[$1]) }
                if d < bd { bd = d; best = (rev, k) }
            }
        }
        guard best.rev || best.k != 0 else { return (m.quad, par, turn, shared, perCorner) }
        let r = best.rev ? Array(m.quad.reversed()) : m.quad
        let q = (0..<4).map { r[($0 + best.k) % 4] }
        // side i of the matched outline is the original side (i + k) (or, reversed, (2 - i - k)) mod 4
        let side = (0..<4).map { i in best.rev ? ((2 - i - best.k) % 4 + 4) % 4 : (i + best.k) % 4 }
        return (q, side.map { par[$0] }, side.map { turn[$0] }, shared.map { sh in side.map { sh[$0] } }, perCorner)
    }

    // MARK: the box model's cut-face flip

    /// If `quad` (any start, either way round) is `ref`'s outline in this view with one side, or two neighbouring ones,
    /// taken at the bottom of the cut face instead of the top edge (the near edge flipping on a real phone), the pose
    /// sides that flipped.
    ///
    /// `closer`: `quad` must lie nearer the flipped outline than this fraction of its distance from `ref`'s top outline
    /// (rms over the corners). Taking a flip for the top lets it into the lock's average and pulls the tilt by degrees,
    /// while taking the top for a flip only skips one re-check, so asking whether a new outline is the reference's flip is
    /// lenient (`flipCloser`); asking the other way round, whether a reference is a new outline's flip (which moves the
    /// lock or the candidates onto that outline), is strict (`innerCloser`).
    func cutFlip(_ quad: [Vec2], of ref: SlabPose, _ f: TrackerFrame, noise s: Double, closer: Double = SlabTracker.flipCloser) -> Set<Int>? {
        guard quad.count == 4 else { return nil }
        let box = SlabBoxView(pose: ref.transformed(by: f.view.cameraFromWorld), spec: boxSpec, intrinsics: f.view.intrinsics)
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
            if d < tol && d < closer * d0 && d < (best?.d ?? .infinity) { best = (sides, d) }
        }
        return best?.sides
    }

    /// The slab the box model's bands come from: the settings' spec, with the side profile the detector has learned on
    /// this slab when the spec has a profile (with no profile, the settings' spec exactly, as before).
    var boxSpec: SlabSpec {
        guard settings.spec.hasProfile, let p = learnedProfile else { return settings.spec }
        return settings.spec.withProfile(faceDrop: p.faceDrop, sideRun: p.sideRun)
    }

    /// See `cutFlip`. At 1.5 m (a band of about 4 px) and 0.5 px corner noise, with a half enough flipped re-checks
    /// passed for the top to pull the lock 3-6 deg off when the near edge flipped on most re-checks; with 0.7 it stayed
    /// within about 1 deg, at the cost of skipping about 1 clean re-check in 160 at 1.5 px noise.
    static let flipCloser = 0.7
    static let innerCloser = 0.5

    /// Which of two outlines a band apart is the top, from how well each fits the slab's square (the pose fit's rms
    /// corner misfit): the top fits to the corner noise, an outline with a side a band off does not. At 0.5 px noise the
    /// misfit is about 0.3 px for the top, 1.1 for the cut-face flip and 1.0 for a side a band inside at 0.64 m; 0.3,
    /// 0.6 and 0.55 at 1 m; about 0.3 for all three at 1.5 m (a band of 4 px). In units of the corner noise (pixels):
    /// an inner outline that fits worse than the reference's measurements by `clearlyWorseFit` is not the top, an outer
    /// one that fits better by `clearlyBetterFit` is; both only where the fits can tell (`fitsTell`), else the rule that
    /// the inner one is the top decides (comparing misfits that noise dominates picks the luckiest outline, and a lock
    /// made from those then judges the real top by an unfairly low misfit).
    static let clearlyWorseFit = 0.3
    static let clearlyBetterFit = 0.5
    /// the fits can tell where an outline with the sides a band off misfits by at least this many corner noises
    static let fitsTellMisfit = 0.8

    /// Whether the pose fits can tell p's top outline from the one with these sides a band off in this view: that one,
    /// noise-free, misfits the square by `fitsTellMisfit` corner noises or more.
    func fitsTell(_ p: SlabPose, _ sides: Set<Int>, _ f: TrackerFrame, noise s: Double) -> Bool {
        let box = SlabBoxView(pose: p.transformed(by: f.view.cameraFromWorld), spec: boxSpec, intrinsics: f.view.intrinsics)
        guard let F = box.outlineWithCutBottom(onSides: sides),
              let fit = PoseSolver.solve(corners: F, intrinsics: f.view.intrinsics, spec: settings.spec,
                                         down: f.view.directionToCamera(ARKitConvention.worldDown)) else { return false }
        return fit.rmsPixels >= SlabTracker.fitsTellMisfit * s
    }

    /// mean rms corner misfit of measurements' pose fits (pixels)
    static func meanRms(_ ms: [Measurement]) -> Double { ms.isEmpty ? 0 : ms.reduce(0) { $0 + $1.rms } / Double(ms.count) }

    /// Whether m's outline and a pose's lie a band apart on a side whose cut face shows (either is the other's flip).
    func bandApart(_ m: Measurement, _ p: SlabPose, _ f: TrackerFrame, noise s: Double) -> Bool {
        if cutFlip(m.quad, of: p, f, noise: s) != nil { return true }
        guard let q = project(p, f.view) else { return false }
        return cutFlip(q, of: m.pose, f, noise: s, closer: SlabTracker.innerCloser) != nil
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
        candidates = swapped(candidates); movers = swapped(movers); recent = swapped(recent); partners = swapped(partners)
        if state == .locked && !hist.isEmpty {
            hist = swapped(hist)
            refreshLock(); depthEstimate = nil
            hist = honestRestart(with: hist)
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

    /// What a tap means, with tap hints (`TrackerSettings.tapHints`): decided by what is under the finger.
    private enum TapMeaning {
        case slab
        case ball(BallTapHint)
        case dismiss(Vec3, Double)
    }

    /// What a tap at pixel p of the processing frame (camera `view`) would be taken for now: with tap hints, while the
    /// slab is locked, the ball's ring under the finger (within half again its radius and the finger's slack) is
    /// dismissed; a line of sight that passes where a ball held over the slab could be (`TapHints.ballRange`, the
    /// slab's footprint grown by the finger's slack) looks for the ball; anything else (and every tap while not locked,
    /// or without tap hints) looks for the slab.
    public func tapKind(_ p: Vec2, view: CameraView) -> TrackerTapKind {
        switch tapMeaning(p, view) {
        case .slab: return .slab
        case .ball: return .ball
        case .dismiss: return .dismissBall
        }
    }

    /// Whether a tap at p looks for the slab (pass it to `detectionDue(at:tap:)` and `detectorWillRun`; the app also reads
    /// the frame's LiDAR depth for it, which places the tapped point): a slab tap does, unless (with tap hints) it is on
    /// the outline being confirmed (the search goes on as it was) or on the lock's outline (nothing to look for); a ball
    /// tap or a dismissed ring does not. Without tap hints it makes the detector run on its frame; with them only while
    /// locked (a probe), and before the lock it steers the scheduled searches alone.
    public func tapSeedsSlab(_ p: Vec2, view: CameraView) -> Bool {
        tapKind(p, view: view) == .slab && !tapOnCandidate(p, view) && !tapOnLock(p, view)
    }

    /// With tap hints, while confirming: whether p lies on the outline being confirmed (a quarter of its size to spare).
    private func tapOnCandidate(_ p: Vec2, _ v: CameraView) -> Bool {
        guard settings.tapHints, state == .confirming, let e = SlabTracker.estimate(candidates), let q = project(e.pose, v) else { return false }
        return SlabTracker.contains(q, p, slack: 0.25)
    }

    /// With tap hints, while locked: whether p lies on the lock's outline (a quarter of its size to spare).
    private func tapOnLock(_ p: Vec2, _ v: CameraView) -> Bool {
        guard settings.tapHints, state == .locked, let s = imageSlab, let q = project(s, v) else { return false }
        return SlabTracker.contains(q, p, slack: 0.25)
    }

    /// How long the slab tap's seed lasts (s of normal tracking): n11's `seedTimeout`; with tap hints
    /// `tapSlabFirstSeconds`, or `seedTimeout` while the candidate being confirmed lies under the finger (and the seed's
    /// place was not guessed): a tap on something that is not the slab costs at most its first second.
    private func seedLifetime(_ v: CameraView) -> Double {
        guard settings.tapHints else { return settings.seedTimeout }
        let first = min(settings.seedTimeout, settings.tapSlabFirstSeconds)
        guard !seedDepthGuessed, state == .confirming, let sw = seed?.world, let p = v.project(world: sw), tapOnCandidate(p, v) else { return first }
        return settings.seedTimeout
    }

    private func tapMeaning(_ p: Vec2, _ v: CameraView) -> TapMeaning {
        guard settings.tapHints, state == .locked, let s = slab else { return .slab }
        let K = v.intrinsics, slack = TapHints.slack(fraction: settings.tapSlackFraction, width: K.width, height: K.height)
        if let b = ballState {
            let bc = v.toCamera(b.center)
            if let c = K.project(bc), let r = Bounce.imageRadius(ballCenter: bc, intrinsics: K, ball: settings.ball),
               c.distance(to: p) <= 1.5 * r + slack { return .dismiss(b.center, r) }
        }
        let (o, d) = v.ray(through: p)
        let range = s.center.distance(to: v.position)
        if let rg = TapHints.ballRange(origin: o, direction: d, slab: s, ball: settings.ball, down: ARKitConvention.worldDown,
                                       slack: slack * range / K.focal) {
            return .ball(BallTapHint(origin: o, direction: d, near: rg.lowerBound, far: rg.upperBound))
        }
        return .slab
    }

    /// A slab tap. Without tap hints, n11's: look there, starting the search over (once tracking is normal; event "tap",
    /// which also lets the camera's focus and exposure adjust again, `CaptureLockGate`). With them: while locked, a tap on
    /// the lock's outline does nothing; one elsewhere looks there on its own frame and the re-checks while it lasts
    /// (`probeTappedSlab`, returns true: probe on this frame), the re-checks' schedule left as it was, and keeps the lock
    /// (event "tap-slab") unless another slab is found there twice in a row ("tap" then). While confirming, a tap on the
    /// outline being confirmed keeps it ("tap-slab"); one elsewhere keeps it too ("tap-slab"), the outlines under the
    /// finger first on the scheduled searches while it lasts, unless another slab is found there twice (`tapChallenge`:
    /// "tap"). While searching, the scheduled searches look there first while it lasts ("tap"). Before the lock nothing
    /// runs on the tap's own frame (one more search, on a frame the schedule would not have searched, changes which frames
    /// are measured: on the owner's clips a stray tap that did so could cost a marginal shot its lock), so a tap on
    /// something that is not the slab leaves the search as it was. Returns whether to look on this frame (a probe, while
    /// locked), which never moves the detections' schedule.
    private func tapSlab(_ tp: Vec2, _ f: TrackerFrame, _ events: inout [String]) -> Bool {
        seed = (seedPoint(for: tp, f), 0)
        seedDepthGuessed = seedHeight(f) == nil
        // with tap hints and no height known, LiDAR's depth under the finger, when the frame has it
        if settings.tapHints, seedDepthGuessed, let w = seedFromDepth(tp, f) { seed = (w, 0); seedDepthGuessed = false }
        guard settings.tapHints else { lastCheck = -.infinity; events.append("tap"); tapResetPending = true; return false }
        bump("tapSlab")
        // (with tap hints nothing here moves the detections' schedule: `process` probes on the tap's frame when this
        // returns true, only while locked)
        switch state {
        case .locked:
            events.append("tap-slab")
            probeHits = []
            if tapOnLock(tp, f.view) { seed = nil; bump("tapSlabOnLock"); return false }
            return true
        case .confirming:
            slabTapTime = f.timestamp
            events.append("tap-slab")
            // a tap on the outline being confirmed: the search goes on as it was (`tapSeedsSlab`); one elsewhere: the
            // scheduled searches look under the finger first (no search of its own: taking one now would only measure
            // other frames than without the tap)
            if tapOnCandidate(tp, f.view) {
                bump("tapSlabOnCandidate")
                return false
            }
            bump("tapSlabOffCandidate")
            tapChallengers = []
            return false
        case .searching:
            // nothing to start over: the scheduled searches look under the finger first while it lasts (event "tap" all
            // the same: the camera's focus and exposure may adjust)
            slabTapTime = f.timestamp
            events.append("tap")
            return false
        }
    }

    /// While confirming with a slab tap on, the outline chosen when it lies under the finger: one that agrees with the
    /// candidate (or is its cut-face flip) confirms it as usual (returns false); another is kept aside, and
    /// `tapSwitchFinds` of those that agree with each other start the confirmation over on them (event "tap"; the search
    /// starts over there). Returns whether it took the outline.
    private func tapChallenge(_ m: Measurement, _ f: TrackerFrame, _ events: inout [String]) -> Bool {
        guard let ref = SlabTracker.estimate(candidates) else { return false }
        let s = cornerNoiseEstimate
        if agrees(ref, m.est, noise: s) || cutFlip(m.quad, of: ref.pose, f, noise: s) != nil { return false }
        if let e = SlabTracker.estimate(tapChallengers), agrees(e, m.est, noise: s) { tapChallengers.append(m) } else { tapChallengers = [m] }
        bump("tapSlabChallenges")
        guard tapChallengers.count >= SlabTracker.tapSwitchFinds else { events.append("tap-slab-find"); return true }
        candidates = tapChallengers
        endTapChallenge()
        lastMeasured = (m.pose.normal, f.timestamp)
        bump("tapSlabSwitched"); bump("confirmRestarts"); events.append("tap"); events.append("candidate-restart")
        tryLock(f.timestamp, &events)
        return true
    }

    /// The outlines kept aside by `tapChallenge` go (the tap expired, the candidate was lost or locked, the search started
    /// over).
    private func endTapChallenge() {
        tapChallengers = []
    }

    /// A ball tap: look along the tapped line of sight first (`ballSearchHints`) for `tapBallSeconds` (from the latest
    /// ball found there), at the usual scan rate, starting with the next frame; a dismissed spot under the finger is taken
    /// back.
    private func tapBall(_ h: BallTapHint, _ tp: Vec2, _ f: TrackerFrame, _ events: inout [String]) {
        ballHint = h; ballTapTime = f.timestamp
        bump("tapBall"); events.append("tap-ball")
        let K = f.view.intrinsics, slack = TapHints.slack(fraction: settings.tapSlackFraction, width: K.width, height: K.height)
        let before = dismissedSpots.count
        dismissedSpots.removeAll { spot in TapHints.avoidCircle(spot, view: f.view).map { $0.covers(tp, margin: slack) } ?? false }
        if dismissedSpots.count < before { bump("tapDismissLifted"); events.append("dismiss-lifted") }
        lastBall = -.infinity; emptyBallScans = nil
    }

    /// A tap on the ball's ring: the ring is wrong. It goes at once (and the ball finder forgets it), and its spot is
    /// passed over (`TapHints.dismissedSpot`) for `tapDismissSeconds`, at most `tapDismissMax` spots; the space over the
    /// slab is scanned again on the next frame.
    private func dismissBall(_ center: Vec3, _ r: Double, _ f: TrackerFrame, _ events: inout [String]) {
        if let s = slab {
            dismissedSpots.append(TapHints.dismissedSpot(ballCenter: center, ringRadiusPixels: r, view: f.view, slab: s, ball: settings.ball))
            let most = max(1, settings.tapDismissMax)
            if dismissedSpots.count > most { dismissedSpots.removeFirst(dismissedSpots.count - most) }
        }
        ballState = nil; ballLocator?.reset(); ballHint = nil; ballTapTime = nil
        lastBall = -.infinity; emptyBallScans = nil
        bump("tapDismiss"); events.append("tap-dismiss")
    }

    /// The ball tap's search and the dismissed spots age by the frame's time step; those past their time go.
    private func ageTapHints(_ dt: Double, _ events: inout [String]) {
        if var h = ballHint {
            h.age += dt
            ballHint = h
            // (counted apart: a tap whose box never found a ball, and one whose box lost what it found)
            if h.age > settings.tapBallSeconds { ballHint = nil; ballTapTime = nil; bump(h.found ? "tapBallLost" : "tapBallExpired"); events.append("tap-ball-expired") }
        }
        guard !dismissedSpots.isEmpty else { return }
        let before = dismissedSpots.count
        dismissedSpots = dismissedSpots.compactMap { var x = $0; x.age += dt; return x.age > settings.tapDismissSeconds ? nil : x }
        if dismissedSpots.count < before { bump("tapDismissExpired") }
    }

    /// The ball tap's search and the dismissed spots end (the lock changed, was lost or reset, or the world frame jumped).
    private func clearTapBall() {
        ballHint = nil; ballTapTime = nil; dismissedSpots = []
    }

    /// The owner's taps for one ball scan, in the ball finder's image (intrinsics `bk`, the frame's camera): the ball
    /// tap's place and sizes, and the dismissed spots.
    private func ballSearchHints(_ f: TrackerFrame, _ bk: CameraIntrinsics) -> BallSearchHints {
        guard ballHint != nil || !dismissedSpots.isEmpty else { return BallSearchHints() }
        let v = CameraView(worldFromCamera: f.view.worldFromCamera, intrinsics: bk)
        let pk = f.view.intrinsics
        let slack = TapHints.slack(fraction: settings.tapSlackFraction, width: pk.width, height: pk.height) * bk.focal / pk.focal
        var h = BallSearchHints()
        if let b = ballHint, let r = TapHints.searchRegion(b, view: v, ball: settings.ball, slack: slack) { h.region = r.region; h.radii = r.radii }
        h.avoid = dismissedSpots.compactMap { TapHints.avoidCircle($0, view: v) }
        return h
    }

    /// A slab tap while locked, away from the lock's outline (its frame, and the re-checks while its seed lasts,
    /// `tapSlabFirstSeconds`): grow a slab from the tapped point through the search's screens (`SlabDetecting.probe`, which
    /// leaves the edge memory of the lock's outline alone). If one that passes the shape checks lies under the finger and
    /// is the lock (or its cut-face flip), the tap is done. If it is another slab, and LiDAR (when the frame has depth)
    /// sees a slab's top where it puts it, it is a find; `tapSwitchFinds` finds in a row that agree with each other give
    /// the lock up and confirm them (event "tap": the search starts over there). Anything else keeps the lock: one outline
    /// grown on the floor that passes the checks is not enough.
    private func probeTappedSlab(_ f: TrackerFrame, _ downCam: Vec3, _ events: inout [String]) {
        guard let sw = seed?.world, let sp = f.view.project(world: sw), f.view.intrinsics.contains(sp) else { return }
        bump("tapSlabProbes")
        let found = detector.probe(frame: f.frame, intrinsics: f.view.intrinsics, spec: settings.spec, down: downCam, seed: sp)
        guard var m = found.lazy.compactMap({ self.measure($0, f, downCam, nil, counting: false) })
                .first(where: { SlabTracker.contains($0.quad, sp, slack: 0.25) }) else { probeHits = []; return }
        let s = cornerNoiseEstimate
        if let L = lockEstimate, agrees(L, m.est, noise: s) || cutFlip(m.quad, of: L.pose, f, noise: s) != nil {
            seed = nil; probeHits = []; bump("tapSlabIsLock"); events.append("tap-slab-is-lock")
            return
        }
        if let d = f.depth, let dk = f.depthIntrinsics {
            guard let c = PlaneFit.checkSlabTop(depth: d, depthIntrinsics: dk, view: f.view, slab: m.pose, down: ARKitConvention.worldDown),
                  depthUsable(c, m.pose, f, maxAngle: settings.depthMaxAngleDegrees) else {
                probeHits = []; bump("tapSlabProbeDepthRejected")
                return
            }
        }
        m.fromTap = true
        if let e = SlabTracker.estimate(probeHits), agrees(e, m.est, noise: s) { probeHits.append(m) } else { probeHits = [m] }
        bump("tapSlabProbeFinds")
        guard probeHits.count >= SlabTracker.tapSwitchFinds else { events.append("tap-slab-find"); return }
        let hits = probeHits
        forget(); bump("reset"); bump("tapSlabElsewhere"); events.append("tap"); events.append("tap-slab-elsewhere")
        candidates = hits; state = .confirming; lastMeasured = (m.pose.normal, f.timestamp); events.append("candidate")
        slabTapTime = f.timestamp
        tryLock(f.timestamp, &events)
    }

    /// The tapped point in the world: where its ray meets the height of a slab on the floor (or of the current lock),
    /// else 1.2 m along it.
    private func seedPoint(for px: Vec2, _ f: TrackerFrame) -> Vec3 {
        let (o, d) = f.view.ray(through: px)
        let y = seedHeight(f)
        if let y = y, d.y < -1e-3 {
            let s = (y - o.y) / d.y
            if s > 0.1 && s < 8 { return o + d * s }
        }
        return o + d * 1.2
    }

    /// The tapped point's place from LiDAR, when the frame has depth: the median of the depths in a 5 x 5 patch around the
    /// tapped pixel (at least 5 between 0.1 and 8 m), along the tapped line (world); nil without.
    private func seedFromDepth(_ px: Vec2, _ f: TrackerFrame) -> Vec3? {
        guard let d = f.depth, let dk = f.depthIntrinsics, let q = dk.project(f.view.intrinsics.ray(px)) else { return nil }
        let cx = Int(q.x.rounded(.down)), cy = Int(q.y.rounded(.down))
        var zs: [Float] = []
        for y in (cy - 2)...(cy + 2) where y >= 0 && y < d.height {
            for x in (cx - 2)...(cx + 2) where x >= 0 && x < d.width {
                let z = d.depth[y * d.width + x]
                if z.isFinite && z > 0.1 && z < 8 { zs.append(z) }
            }
        }
        guard zs.count >= 5 else { return nil }
        zs.sort()
        return f.view.toWorld(f.view.intrinsics.unproject(px, depth: Double(zs[zs.count / 2])))
    }

    /// The height a tapped slab's top is put at: the floor's (ARKit's plane) plus the slab, else the lock's or the
    /// candidates' (nil: none known).
    private func seedHeight(_ f: TrackerFrame) -> Double? {
        f.floorY.map { $0 + settings.spec.thickness + 0.04 } ?? imageSlab?.center.y ?? candidates.last?.pose.center.y
    }

    // MARK: LiDAR

    /// the corner plane lies above the plane through the dish's inner 70% by the dish's mean depth there, D (1 - 0.7^2 / 3)
    private var dishOffset: Double { settings.spec.dishDepth * (1 - 0.49 / 3) }

    /// Whether a frame's depth check describes the slab's top where the lock is: most points inside the top on one plane,
    /// near the image normal, and the lock's centre the dish's depth above it (a hand above the top, or the ground below
    /// where the slab was, fail this).
    private func depthUsable(_ c: DepthCheck, _ s: SlabPose, _ f: TrackerFrame, maxAngle: Double) -> Bool {
        depthRejection(c, s, f, maxAngle: maxAngle) == nil
    }

    /// Why a frame's depth check is not used (`depthUsable`), or nil: "points" (too few on the plane), "angle" (too far
    /// from the image normal), "inliers" (too small a share of the points inside the top on it), "offset" (the lock's
    /// centre not the dish's depth above it, within the share of the range).
    private func depthRejection(_ c: DepthCheck, _ s: SlabPose, _ f: TrackerFrame, maxAngle: Double) -> String? {
        if c.points < 60 { return "points" }
        if !(c.angleToImageDegrees < maxAngle) { return "angle" }
        if let fr = c.inlierFraction, fr < settings.depthMinInlierFraction { return "inliers" }
        let range = s.center.distance(to: f.view.position)
        return abs(c.centreOffset - dishOffset) <= max(0.01, settings.depthMaxOffsetFraction * range) ? nil : "offset"
    }

    /// The depth checks while locked, for diagnostics: what they were and why they were not used.
    private func noteDepthCheck(_ c: DepthCheck, _ s: SlabPose, _ f: TrackerFrame, rejected why: String?) {
        var d = depthChecks
        d.checks += 1
        if let w = why { d.rejected[w, default: 0] += 1 } else { d.used += 1 }
        d.offsetMm.add((c.centreOffset - dishOffset) * 1000)
        d.angleDegrees.add(c.angleToImageDegrees)
        // LiDAR's range to the corner plane (the depth plane raised by the dish's offset) along the line of sight through
        // the lock's centre, over the picture's range to that centre
        let o = f.view.position, los = s.center - o, r = los.length
        let raised = Plane3(point: c.plane.point + c.plane.normal * dishOffset, normal: c.plane.normal)
        if r > 1e-6, let p = raised.intersect(origin: o, direction: los / r) { d.rangeRatio.add(p.distance(to: o) / r) }
        depthChecks = d
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

    /// The lock with LiDAR's smoothed plane folded in: its normal with `depthNormalWeight` (0: the image's normal is
    /// kept exactly), its centre with `depthCentreWeight` toward where the line of sight through it meets the depth plane
    /// raised by the dish's offset.
    private func fuse(_ s: SlabPose, _ e: DepthEstimate, _ f: TrackerFrame) -> SlabPose {
        let wn = settings.depthNormalWeight, wc = settings.depthCentreWeight
        let plane = Plane3(point: e.normal * e.offset, normal: e.normal)
        var n = s.normal, u = s.axisU
        if wn > 0 { n = (s.normal * (1 - wn) + e.normal * wn).normalized; u = s.axisU.rejecting(n).normalized }
        var c = s.center
        if let p = plane.intersect(origin: f.view.position, direction: (s.center - f.view.position).normalized) {
            c = p + e.normal * dishOffset
        }
        return SlabPose(center: s.center * (1 - wc) + c * wc, normal: n, axisU: u, axisV: n.cross(u), halfU: s.halfU, halfV: s.halfV)
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
