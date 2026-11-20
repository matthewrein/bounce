import Foundation

/// When the app shows a ball (n15): the ball finder's results pass this gate before the app shows them (the ring, "ball in
/// view") or takes the drop height and the drop point from them. A wrong ball moves the drop point and the whole path, so
/// the gate would rather show no ball than a wrong one. A finder's result is shown only:
/// - once the ball has been seen `sightings` times within `window` seconds at one place: each newer sighting's centre (from
///   the ball's 30 mm size and the camera's pose, in world space) within `acrossMetres` of the others' across the line
///   of sight, and within `alongFraction` of the range along it (or the size's own noise, `radiusNoiseRadians`, where that is
///   larger: far away a few pixels of radius are a large share of it). A single find, or one that wanders, never shows: a
///   held ball stays put; a print on the floor seen from a moving phone does not (its distance from its size is wrong, so
///   its place in the room drifts as the phone moves), and a passing hand or thumb does not;
/// - over the slab: its centre straight above the top face (within `topMargin`), its bottom `minHeight` to `maxHeight` over
///   it. Nothing at or under the slab's surface or beside the slab is shown. (The app's finder already keeps to these
///   limits, a little tighter, so on the app's path this re-checks it: on the kits it refused nothing. A look-alike whose
///   size is wrong reads as being in the air over the slab and passes it; agreement and LiDAR are what stop those.);
/// - unless LiDAR says the place is a surface: where the ball would be near enough for LiDAR to resolve it (its radius
///   at least `lidarMinRadiusPixels` of the depth map's pixels, about 0.55 m away), a depth at its centre more than
///   `lidarSurfaceMetres` beyond the ball's centre is the floor or a print, not a ball in the air. Searches without a
///   reading (frames without depth; the kits store it once a second) do not take that place for the ball for
///   `lidarMemorySeconds`; a later reading at the ball overrules it.
/// Once shown, the ball stays shown while each new find agrees with the last one shown (the same test), and the finder's
/// hold-over of a ball it missed for a scan or two is shown with it (while it agrees with it); a ball not seen for
/// `keepSeconds` must be seen `sightings` times again. (No new screen, nothing to tap: point and go.)
///
/// What it does not stop: a look-alike that stays put (a toy or a stool's cut-out at the picture's edge) agrees with
/// itself, and beyond LiDAR's reach only the over-the-slab test applies to it; the kits show it for about 0.4 s.
///
/// The numbers come from the owner's two kits: the app's finder on the lock the phone had while recording, on the app's
/// schedule (a search every 0.1 s, every 0.3 s when idle), against the ball's place marked by hand (see each).
public struct BallGateSettings: Equatable {
    /// Finds of one ball (not the finder's hold-overs) needed before it is shown, within `window` seconds. 3: with two the
    /// drifting prints of the second kit's slab-only arcs showed on 14 searches, with three on none; four would find the
    /// held ball on 271 instead of 291 of the kits' 466 searches with it in view, for one fewer false ball.
    public var sightings = 3
    public var window = 0.5
    /// Two finds agree across the line of sight within this (m). A true held ball's finds 0.1 s apart moved at most 4.2 mm
    /// across it (290 finds, both kits, 99th percentile 3.3 mm); the second kit's false prints drifted 3-7 mm a search as
    /// the phone walked (6-14 mm over two).
    public var acrossMetres = 0.006
    /// ... and along it within this share of the range (true: at most 5.0%, 99th percentile 4.5%) ...
    public var alongFraction = 0.06
    /// ... or, if larger, the share a radius off by this angle makes (radians: 2 px at the kits' 1024 px focal length, the
    /// largest step of a true held ball's radius between finds; a ball 1.3 m away is 12 px across its radius, so the share
    /// grows with the range: 6.5% at 0.5 m, 17% at 1.3 m)
    public var radiusNoiseRadians = 0.00195
    /// the ball's bottom over the top face (m): at least a ball's diameter and some (the owner's "held low" read
    /// 0.116 m at the lowest), at most what the finder reports (its 1.5 m ceiling plus 0.3 m)
    public var minHeight = 0.05
    public var maxHeight = 1.8
    /// its centre straight above the top face, or this far beyond its edges (m; true held balls were within 71% of the
    /// half side)
    public var topMargin = 0.01
    /// a shown ball not found again for this long (s) is let go
    public var keepSeconds = 0.35
    /// LiDAR's check (see the type): nil turns it off. 0.15 m: on the kits' held balls LiDAR read -0.050 to +0.052 m from
    /// the ball's centre (only 25 finds with depth, the kits storing it once a second; the ball 5.2-8.4 depth pixels in
    /// radius); the false black-and-white label at the first kit's picture edge read +1.33 m. On the phone it runs on
    /// every search with depth; Copy diagnostics counts its refusals (`ballGate.surface`).
    public var lidarSurfaceMetres: Double? = 0.15
    /// only where the ball's radius spans this many depth pixels (about 0.55 m away on the phone's 256 x 192 map): the
    /// kits verify LiDAR on a held ball only that near; farther away it may not resolve the ball and reads what is behind
    public var lidarMinRadiusPixels = 5.0
    public var lidarMemorySeconds = 1.0
    public init() {}
}

extension BallGateSettings: Codable {
    /// Every stored property (a test checks this list against the struct's properties).
    static let codingFields: [SettingsField<BallGateSettings>] = [
        .init("sightings", \.sightings),
        .init("window", \.window),
        .init("acrossMetres", \.acrossMetres),
        .init("alongFraction", \.alongFraction),
        .init("radiusNoiseRadians", \.radiusNoiseRadians),
        .init("minHeight", \.minHeight),
        .init("maxHeight", \.maxHeight),
        .init("topMargin", \.topMargin),
        .init("keepSeconds", \.keepSeconds),
        .init(optional: "lidarSurfaceMetres", \.lidarSurfaceMetres),
        .init("lidarMinRadiusPixels", \.lidarMinRadiusPixels),
        .init("lidarMemorySeconds", \.lidarMemorySeconds),
    ]

    public init(from decoder: Decoder) throws {
        self.init()
        try SettingsField.decode(into: &self, BallGateSettings.codingFields, from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try SettingsField.encode(self, BallGateSettings.codingFields, to: encoder)
    }
}

/// The gate's state (`BallGateSettings`): the tracker keeps one and resets it with the ball finder.
public struct BallGate {
    public var settings: BallGateSettings

    /// One find: its centre (world), the camera's position then, and when.
    struct Sighting {
        var time: Double
        var center: Vec3
        var camera: Vec3
    }
    /// recent finds over the slab (within `window`)
    private var recent: [Sighting] = []
    /// the last find shown, while shown
    private var shown: Sighting?
    /// places LiDAR showed to be a surface (within `lidarMemorySeconds`)
    private var surfaces: [Sighting] = []

    /// What the gate made of one search's result.
    public enum Verdict: String, Equatable {
        /// nothing found
        case none
        /// shown: just accepted, a find agreeing with the shown ball, or the finder's hold-over of it
        case accepted, kept, heldOver
        /// not shown: waiting for more finds that agree, a hold-over of a ball not shown, not over the slab's top, too low or
        /// too high, LiDAR's surface
        case waiting, notShownHeldOver, offTop, tooLow, tooHigh, surface
        public var shows: Bool { self == .accepted || self == .kept || self == .heldOver }
        /// refused for its place, whatever the agreement: not over the slab's top at a drop height, or LiDAR's surface
        /// (a ball a tap accepted is not shown there either: `SlabTracker`'s tap to set the ball)
        public var refusesPlace: Bool { self == .offTop || self == .tooLow || self == .tooHigh || self == .surface }
    }

    public init(settings: BallGateSettings) { self.settings = settings }

    public mutating func reset() { recent = []; shown = nil; surfaces = [] }

    /// Whether a ball is shown now (its last find was accepted and has not been let go).
    public var showing: Bool { shown != nil }

    /// One search. `center`: the finder's ball (world; nil: none found), `heldOver`: it is the finder's hold-over of a ball
    /// it missed (`BallLocating.heldOver`), not a find; `slab`: the lock (world), `down`: gravity (world), `camera`: the
    /// camera's position (world); `lidarExcess`: LiDAR's depth at the ball's centre less the centre's own (m), where the
    /// frame has depth and the ball is near enough for it (`BallGate.lidarExcess`), else nil.
    public mutating func update(time t: Double, center: Vec3?, heldOver: Bool, slab: SlabPose, spec: SlabSpec, ball: BallSpec,
                                down: Vec3, camera: Vec3, lidarExcess: Double?) -> Verdict {
        let s = settings
        if let sh = shown, t - sh.time > s.keepSeconds { shown = nil }
        surfaces.removeAll { t - $0.time > s.lidarMemorySeconds }
        recent.removeAll { t - $0.time > s.window }
        guard let B = center, B.isFinite else { return .none }
        let x = Sighting(time: t, center: B, camera: camera)
        let R = ball.radius
        // LiDAR: a surface there now. A reading at the ball overrules what an earlier reading said of that place (one
        // reading that mixed in the background behind a held ball hides it for that search only); the memory stands in
        // only where this search has no reading (frames without depth, a ball too far for the map).
        if let limit = s.lidarSurfaceMetres, let e = lidarExcess {
            if e > limit {
                surfaces.append(x); shown = nil
                recent.removeAll { BallGate.agree($0, x, s, radius: R) }
                return .surface
            }
            surfaces.removeAll { BallGate.agree($0, x, s, radius: R) }
        } else if surfaces.contains(where: { BallGate.agree($0, x, s, radius: R) }) {
            shown = nil; return .surface
        }
        // the finder's hold-over: shown only with the shown ball it holds over
        if heldOver {
            guard let sh = shown, BallGate.agree(sh, x, s, radius: R) else { return .notShownHeldOver }
            return .heldOver
        }
        // over the slab's top, at a drop height (the finder checks this too; a find that fails it is not the shown ball,
        // and ends it as a find elsewhere does)
        guard let d = Bounce.drop(ballCenter: B, pose: slab, spec: spec, ball: ball, down: down) else { shown = nil; return .tooLow }
        guard abs(d.u) <= slab.halfU + s.topMargin, abs(d.v) <= slab.halfV + s.topMargin else { shown = nil; return .offTop }
        // (`Bounce.drop` reports at least 6 mm: a centre less than a radius over the face reads as touching it)
        guard d.dropHeight >= s.minHeight else { shown = nil; return .tooLow }
        guard d.dropHeight <= s.maxHeight else { shown = nil; return .tooHigh }
        recent.append(x)
        if let sh = shown, BallGate.agree(sh, x, s, radius: R) { shown = x; return .kept }
        // the shown ball, if any, was not found here: it is no longer shown
        shown = nil
        if recent.filter({ BallGate.agree($0, x, s, radius: R) }).count >= s.sightings { shown = x; return .accepted }
        return .waiting
    }

    /// Whether find `b` agrees with the earlier `a` (see `BallGateSettings`): across `b`'s line of sight, and along it
    /// (`radius`: the ball's, m, for the share of the range a few pixels of its image radius make).
    static func agree(_ a: Sighting, _ b: Sighting, _ s: BallGateSettings, radius: Double) -> Bool {
        let los = b.center - b.camera, range = los.length
        guard range > 1e-6, radius > 0 else { return false }
        let dir = los / range, d = b.center - a.center
        let along = d.dot(dir), across = (d - dir * along).length
        let alongShare = max(s.alongFraction, s.radiusNoiseRadians * range / radius)
        return across <= s.acrossMetres && abs(along) <= alongShare * range
    }

    /// LiDAR's depth at a ball's centre less the centre's own depth (m; camera axes, depth along the optical axis), where
    /// the map resolves the ball: its radius at least `minRadiusPixels` of the map's pixels. The median of the depths
    /// within half the radius (at least the nearest pixel), confident or not. nil when too far, out of the map, or no depth.
    public static func lidarExcess(depth: DepthMap, intrinsics K: CameraIntrinsics, ballCenter B: Vec3, ballRadius R: Double,
                                   minRadiusPixels: Double) -> Double? {
        guard B.z > 0.05, let p = K.project(B) else { return nil }
        let rd = R * K.fx / B.z
        guard rd >= minRadiusPixels else { return nil }
        let reach = max(0.71, 0.5 * rd), n = Int(ceil(reach)) + 1
        let cx = Int(floor(p.x)), cy = Int(floor(p.y))
        var v: [Double] = []
        for y in (cy - n)...(cy + n) where y >= 0 && y < depth.height {
            for x in (cx - n)...(cx + n) where x >= 0 && x < depth.width {
                guard Vec2(Double(x) + 0.5, Double(y) + 0.5).distance(to: p) <= reach else { continue }
                let (d, _) = depth.at(x, y)
                if d.isFinite && d > 0.05 { v.append(Double(d)) }
            }
        }
        guard !v.isEmpty else { return nil }
        v.sort()
        return v[v.count / 2] - B.z
    }
}
