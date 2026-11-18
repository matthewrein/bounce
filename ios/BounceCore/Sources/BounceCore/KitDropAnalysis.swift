import Foundation

/// A prediction of the bounce compared with the measured one, both carried down to the same landing level.
public struct KitDropComparison: Codable, Equatable {
    /// the rebound the prediction used (the app's setting, or the one measured on this drop)
    public var rebound: Double
    /// the drop height the prediction used (m: the app's, from the held ball and the lock)
    public var dropHeight: Double
    /// the predicted ball centre at launch, launch velocity and landing (world)
    public var start: Vec3
    public var velocity: Vec3
    public var landing: Vec3
    /// angle between the predicted and the measured launch directions (degrees)
    public var directionError: Double
    public var directionErrorSigma: Double?
    /// horizontal distance from the predicted to the actual landing (m)
    public var landingError: Double
    public var landingErrorSigma: Double?
    /// the actual minus the predicted landing distance, each from its own launch point (m; positive: further)
    public var rangeError: Double
    public var rangeErrorSigma: Double?
    /// the actual minus the predicted direction of the landing from the launch point, seen from above (degrees,
    /// anticlockwise positive); nil when either lands within 1 cm of its launch point
    public var bearingError: Double?
    public var bearingErrorSigma: Double?
    /// the predicted minus the measured apex above the launch point (m)
    public var apexError: Double
}

/// Where the outgoing arc ended, if the track shows it: the ball's next contact.
public struct KitDropContact: Codable, Equatable {
    public enum Surface: String, Codable { case slab, floor, unknown }
    public var time: Double
    /// the ball's centre then (world)
    public var center: Vec3
    public var surface: Surface
}

/// A recorded drop measured from the ball's track and the locked slab (`KitScorer`'s dense track: the ball's centre in
/// ARKit's world on every frame it was found, with misses, wrong frames, frames the recorder dropped and the ball
/// leaving the view), and compared with what the app predicts for the same release point.
///
/// Definitions (world, metres, y up, g = 9.80665 m/s²; CaptureKit.md, "Drops measured on the dish"):
///   - the samples are sorted by their own timestamps (frames dropped by the recorder are gaps, not shifts); repeated
///     timestamps keep the first; non-finite samples are dropped;
///   - **noise**: the finder's error lies along the line of sight (it takes the distance from the ball's size), so every
///     fit is `KitDropFit`: free fall with gravity known, weighted least squares in which a sample's error along its
///     line of sight counts kappa² as much as across it; kappa is the held ball's spread across over along (0.03-1),
///     else re-estimated from the fall; every distance below is weighted so;
///   - **held**: the median of the ball's centre from 1.5 s before the release cue to 0.05 s after it, when seen there
///     on at least 2 frames; otherwise the release is taken from the fall alone (a note says so);
///   - **the fall and the impact** are segmented as in `KitBounceAnalysis` (running median of five heights, here the
///     line of sight's elevation at the held ball's distance, which the distance error does not move; the fall starts
///     1.5 cm below the held height and goes on falling; the impact is the lowest point before the ball rises 1 cm
///     again); a ball that never rises 1 cm but stays on the dish (or at one height) for 3 or more samples has
///     **rolled** (no bounce measured);
///   - **fall fit**: the arc most of the falling samples agree on (`KitDropFit.consensus`, 15 mm), refitted robustly
///     with a prior that the ball was let go, not thrown (horizontal velocity 0 ± 0.1 m/s); **rise fit**: the consensus
///     of the lowest sample and the next eight (also through where the fall meets the dish), grown while the next
///     samples fit, skipping up to three wrong frames, and ended by the next contact or the end of the track (the ball
///     left the view);
///   - **impact time**: where the two fits' heights meet (`impactTime`); the **impact centre** the mean of the fits
///     there; the **contact point** where the ball touches the dish (`KitDish`, the dish geometry with the lock's pose,
///     not a flat plane) when the impact centre is slid along its line of sight (the finder's error lies there; not
///     when the sight runs within 10° of the slab's plane, or without a camera) and the **local normal** the dish's
///     normal there; `impactClearance` the gap between the
///     ball at the impact centre and the dish (positive: the track turns round above the dish: the finder reads the
///     ball high or the lock sits low); `offsetU`/`offsetV` the contact point in the lock's axes from its centre (a
///     square slab's axes may be any of its edges), `offsetDownhill`/`offsetLeft` down its slope and to the left;
///     `normalTilt` the local normal's angle from the slab's normal;
///   - **release**: the held point (else the fall fit where its vertical speed is 0) and the fall fit's time of zero
///     vertical speed; **drop height**: the release point's height above the impact centre (how far the centre fell);
///   - **restitution** e = -(v_out . n) / (v_in . n) about the local normal n, v_in and v_out the fits' velocities at
///     the impact; **rebound** = e², exactly `BallSpec.rebound` (the share of the drop height a straight-up bounce
///     regains); `speedRebound` = |v_out|² / |v_in|² (what `KitBounceAnalysis` calls the rebound; the same for a
///     straight drop on a level surface); `tangentialRatio`: the velocity along the surface after over before, along
///     the incoming direction (nil when the incoming one is under 5 cm/s); `sideways`: how far the outgoing velocity
///     leans out of the plane of incidence (degrees; spin from the release, or a wrong normal);
///   - **landing**: where the rise fit comes down to the landing level: the floor plus a radius when ARKit's floor is
///     known (`floorY`); else the ball's next contact when it is seen 3 cm or more below the impact and not on the slab
///     (the floor, seen); else `fixedLandingDrop` below the impact centre; extrapolated past the last fitted sample when
///     the ball left the view or came down on something higher first (`landingExtrapolation`, seconds, and notes);
///   - **predictions**: `app` is the app's bounce (`predict(held, appRebound)`: `Bounce.compute` with the lock and the
///     same held ball, so the same release point and the app's drop height) and `measuredRebound` the same with the
///     rebound measured here (so what is left is the model's error, not the rebound's), each carried down to the same
///     landing level (`KitDropComparison`);
///   - **uncertainties** (1 sigma): each fit's 6 x 6 parameter covariance (its sample times, lines of sight and prior,
///     and a sample's noise across the line of sight: the larger of the two fits', at least 0.5 mm) carried through
///     every derived number by its numerical derivatives; frames whose errors are correlated make them optimistic. The
///     held point's from the spread of the held samples.
public struct KitDropAnalysis: Codable, Equatable {
    public enum Kind: String, Codable {
        case bounce
        /// the ball stayed on the slab after its fall: no bounce to measure
        case rolled
    }

    public var kind: Kind
    // the release
    /// the ball was seen held before the cue (else the release comes from the fall alone)
    public var heldSeen: Bool
    public var releaseTime: Double
    public var releasePoint: Vec3
    public var dropHeight: Double
    public var dropHeightSigma: Double
    /// the app's drop height for the held ball (m), if it predicted
    public var appDropHeight: Double?
    // the fall
    public var fallSamples: Int
    public var fallRejected: Int
    public var fallRms: Double
    // the impact
    public var impactTime: Double
    public var impactTimeSigma: Double
    public var impactCenter: Vec3
    public var contactPoint: Vec3
    public var offsetU: Double?
    public var offsetV: Double?
    public var offsetSigma: Double?
    /// the contact point from the slab's centre down the slope and to its left, looking downhill (m; nil on a level
    /// slab: a square slab's axes may be any of its edges, the slope is not)
    public var offsetDownhill: Double?
    public var offsetLeft: Double?
    public var localNormal: Vec3
    public var normalTilt: Double?
    public var impactClearance: Double?
    public var impactClearanceSigma: Double?
    public var velocityIn: Vec3
    // the bounce
    public var velocityOut: Vec3?
    public var restitution: Double?
    public var restitutionSigma: Double?
    public var rebound: Double?
    public var reboundSigma: Double?
    public var speedRebound: Double?
    public var tangentialRatio: Double?
    public var tangentialRatioSigma: Double?
    public var sideways: Double?
    public var sidewaysSigma: Double?
    /// the launch direction's angle from straight up (degrees)
    public var launchTilt: Double?
    public var riseSamples: Int
    public var riseRejected: Int
    public var riseRms: Double?
    /// the rise fit's highest point above the impact centre (m)
    public var apexHeight: Double?
    // the landing
    /// the ball's centre's height at the landing (world y) and where it comes from ("floor" or "fixed")
    public var landingLevel: Double
    public var landingLevelSource: String
    public var landing: Vec3?
    /// horizontal (m)
    public var landingSigma: Double?
    public var landingTime: Double?
    /// how far past the last fitted sample the landing lies (s; 0 when it was seen)
    public var landingExtrapolation: Double?
    /// the ball's next contact, when the track shows the rise ending before the landing level
    public var nextContact: KitDropContact?
    /// the track ends (the ball left the view or was lost) before the landing
    public var leftView: Bool
    // against the predictions
    public var app: KitDropComparison?
    public var measuredRebound: KitDropComparison?
    public var notes: [String]

    public enum Outcome: Equatable {
        case analyzed(KitDropAnalysis)
        case failed(String)
        public var analysis: KitDropAnalysis? { if case let .analyzed(a) = self { return a } else { return nil } }
        public var reason: String? { if case let .failed(r) = self { return r } else { return nil } }
    }

    /// The setting: the lock and the dish, the ball, the floor and the app's prediction.
    public struct Context {
        /// the lock before the release (world); nil: the impact is taken on a level surface (no offset, no tilt)
        public var slab: SlabPose?
        public var dish: KitDish?
        public var ballRadius: Double = BallSpec().radius
        /// ARKit's floor (world y), if known
        public var floorY: Double? = nil
        /// the landing level below the impact centre when the floor is not known (m)
        public var fixedLandingDrop = 0.1
        /// the app's rebound setting
        public var appRebound: Double = BallSpec().rebound
        /// the app's bounce for a ball held at a point, with a given rebound (nil: no comparison)
        public var predict: ((Vec3, Double) -> KitBouncePrediction?)? = nil
        public init(slab: SlabPose? = nil, dish: KitDish? = nil) { self.slab = slab; self.dish = dish }
    }

    typealias Fit = KitDropFit

    /// Analyses a drop. `cue`: the release cue (uptime s, the frames' clock).
    public static func analyze(track: [KitBallSample], cue: Double, context ctx: Context) -> Outcome {
        // clean: finite, by time, one sample per timestamp
        var s: [KitBallSample] = []
        for x in track.filter({ $0.t.isFinite && $0.p.isFinite }).sorted(by: { $0.t < $1.t }) where s.last.map({ x.t - $0.t > 1e-6 }) ?? true {
            s.append(x)
        }
        guard s.count >= 8 else { return .failed("the ball was seen on only \(s.count) frames") }
        let G = Units.gravity, R = ctx.ballRadius
        var notes: [String] = []
        func median3(_ v: [KitBallSample]) -> Vec3 {
            Vec3(KitStats.median(v.map { $0.p.x }), KitStats.median(v.map { $0.p.y }), KitStats.median(v.map { $0.p.z }))
        }
        // held
        let hold = s.filter { $0.t >= cue - 1.5 && $0.t <= cue + 0.05 }
        let held: Vec3? = hold.count >= 2 ? median3(hold) : nil
        // the heights the fall and the bounce are found on: from the line of sight's elevation at the held ball's distance
        // from the camera (the finder's error lies along the line of sight; its direction is good), else the heights
        let dRef = KitStats.median((hold.isEmpty ? s : hold).compactMap { x in x.c.map { (x.p - $0).rejecting(Vec3(0, 1, 0)).length } })
        func segHeight(_ x: KitBallSample) -> Double {
            guard let c = x.c, dRef > 0.05 else { return x.p.y }
            let d = x.p - c, hz = d.rejecting(Vec3(0, 1, 0)).length
            return hz > 1e-6 ? c.y + dRef * d.y / hz : x.p.y
        }
        let y = KitBounceAnalysis.runningMedian(s.map(segHeight))
        // the finder's noise across and along the line of sight, from the held ball (else a guess, refined on the fall)
        var kappa = 0.3
        if hold.count >= 5, let h = held {
            let dev = hold.compactMap { x -> (Double, Double)? in
                guard let d = Fit.sight(x) else { return nil }
                let r = x.p - h, al = r.dot(d)
                return (al, (r - d * al).length)
            }
            if dev.count >= 5 {
                let al = dev.map { $0.0 }, mAl = KitStats.median(al)
                let sAlong = 1.4826 * KitStats.median(al.map { abs($0 - mAl) }), sAcross = KitStats.median(dev.map { $0.1 }) / 1.1774
                kappa = clamp(max(0.0003, sAcross) / max(0.0003, sAlong, sAcross), 0.03, 1)
            }
        }
        let refY: Double, refT: Double
        if !hold.isEmpty { refY = KitStats.median(hold.map(segHeight)); refT = cue - 0.3 } else {
            let w = s.indices.filter { s[$0].t >= cue - 0.3 && s[$0].t <= cue + 1.0 }
            guard let top = w.max(by: { y[$0] < y[$1] }) else { return .failed("the ball was not seen around the release cue") }
            refY = y[top]; refT = s[top].t - 1e-6
            notes.append("the ball was not seen held before the cue: the release is taken from the fall alone")
        }
        // the fall: 1.5 cm below the reference, and on down 5 cm within 0.15 s
        var k1: Int? = nil
        for i in s.indices where s[i].t > refT && refY - y[i] > 0.015 {
            if i + 1 < s.count && refY - y[i + 1] <= 0.015 { continue }
            let next = s.indices.filter { s[$0].t > s[i].t && s[$0].t <= s[i].t + 0.15 }
            if !next.isEmpty && !next.contains(where: { refY - y[$0] > 0.05 }) { continue }
            k1 = i; break
        }
        guard let fallIndex = k1 else { return .failed("the ball did not fall after the release cue") }
        // the lowest point before it rises 1 cm again
        var jm = fallIndex, rose = false, j = fallIndex
        while j < s.count && s[j].t - s[fallIndex].t < 1.5 {
            if y[j] < y[jm] { jm = j } else if y[j] > y[jm] + 0.01 { rose = true; break }
            j += 1
        }
        let jEnd = j
        jm = (max(fallIndex, jm - 1)...min(max(fallIndex, jEnd - 1), jm + 2)).min(by: { segHeight(s[$0]) < segHeight(s[$1]) }) ?? jm
        var k0 = fallIndex
        while k0 > 0 && s[k0 - 1].t > refT && refY - y[k0 - 1] > 0.004 { k0 -= 1 }
        let t0 = s[jm].t
        // the fall: the arc most of its samples agree on (within 15 mm: a wrong frame near the release, where it weighs
        // most, cannot bend it), then fitted robustly to those; the noise's split re-estimated from it when the held ball
        // did not give it
        let falling = Array(s[k0..<jm])
        guard jm - k0 >= 3 else { return .failed("too few frames of the fall (\(jm - k0)) before the impact") }
        var fallStart = Fit.consensus(falling, t0: t0, kappa: kappa, gate: 0.015)?.kept ?? falling
        if hold.count < 5, let f = Fit.robust(fallStart, t0: t0, kappa: kappa) {
            kappa = f.fit.noiseSplit(f.kept) ?? kappa
            fallStart = Fit.consensus(falling, t0: t0, kappa: kappa, gate: 0.015)?.kept ?? falling
        }
        guard let pre0 = Fit.robust(fallStart, t0: t0, kappa: kappa) else {
            return .failed("too few frames of the fall (\(jm - k0)) before the impact")
        }
        // a ball let go: its horizontal velocity 0 ± 0.1 m/s (a prior, which a fall seen over a short way needs when the
        // finder's distances are poor)
        let still = max(0.0005 * 0.0005, pre0.fit.noiseAcross(pre0.kept)) / (0.1 * 0.1)
        let preR = Fit.robust(pre0.kept, t0: t0, kappa: kappa, still: still) ?? pre0
        var pre = preR.fit, preKept = preR.kept

        // where on the dish a ball centre is: contact point, normal, clearance (world)
        let slab = ctx.slab, dish = ctx.dish ?? slab.map { KitDish(shape: .sphericalCap, depth: 0, halfU: $0.halfU, halfV: $0.halfV) }
        func onDish(_ c: Vec3) -> (point: Vec3, normal: Vec3, clearance: Double?, u: Double?, v: Double?) {
            guard let p = slab, let d = dish else { return (c - Vec3(0, R, 0), Vec3(0, 1, 0), nil, nil, nil) }
            let k = d.contact(center: p.toSlab(c), radius: R)
            return (p.fromSlab(k.point), p.directionFromSlab(k.normal).normalized, k.clearance, k.point.x, k.point.y)
        }

        guard rose else {
            // no bounce: did it stay on the slab (or at one height)?
            let after = s.filter { $0.t > s[jm].t && $0.t <= s[jm].t + 0.6 }
            let low: Bool
            if slab != nil { low = after.count >= 3 && KitStats.median(after.compactMap { onDish($0.p).clearance }.map { abs($0) }) < 0.02 }
            else { low = after.count >= 3 && (after.map { $0.p.y }.max()! - after.map { $0.p.y }.min()!) < 0.015 }
            guard low else { return .failed("no bounce found: the ball was not seen rising after its fall") }
            // the impact: where the fall fit meets the dish (or the height it stayed at)
            let level = KitStats.median(after.map { $0.p.y })
            var ti = s[jm].t
            var lo = preKept.first!.t, hi = s[jm].t + 0.05
            func gap(_ t: Double) -> Double { onDish(pre.position(t)).clearance ?? (pre.position(t).y - level) }
            if gap(lo) > 0 && gap(hi) < 0 {
                for _ in 0..<50 { let m = (lo + hi) / 2; if gap(m) > 0 { lo = m } else { hi = m } }
                ti = (lo + hi) / 2
            }
            let c = pre.position(ti), d = onDish(c)
            let release = held ?? pre.position(pre.t0 + pre.b.y / G)
            var a = KitDropAnalysis(kind: .rolled, heldSeen: held != nil, releaseTime: pre.t0 + pre.b.y / G, releasePoint: release,
                                    dropHeight: release.y - c.y, dropHeightSigma: 0, fallSamples: preKept.count,
                                    fallRejected: jm - k0 - preKept.count, fallRms: pre.rms, impactTime: ti, impactTimeSigma: 0,
                                    impactCenter: c, contactPoint: d.point, offsetU: d.u, offsetV: d.v, localNormal: d.normal,
                                    normalTilt: slab.map { Units.degrees(d.normal.angle(to: $0.normal)) }, impactClearance: nil,
                                    velocityIn: pre.velocity(ti), riseSamples: 0, riseRejected: 0,
                                    landingLevel: c.y, landingLevelSource: "none", leftView: false, notes: notes)
            a.notes.append("the ball did not bounce: it stayed on the slab (rolled or slid) after its fall; no rebound measured")
            return .analyzed(a)
        }

        // the rise: started from the arc the samples about the impact agree on (the lowest and the next eight; with the
        // lock, also arcs from where the fall meets the dish, so that two wrong frames among a few cannot outvote the
        // rest), then grown while the next ones fit
        let gate = max(0.015, 5 * pre.rms)
        var anchor: KitBallSample? = nil
        if slab != nil {
            var lo = preKept.last?.t ?? s[jm].t, hi = s[jm].t + 0.1
            func gap(_ t: Double) -> Double { onDish(pre.position(t)).clearance ?? 0 }
            if gap(lo) > 0 && gap(hi) < 0 {
                for _ in 0..<50 { let m = (lo + hi) / 2; if gap(m) > 0 { lo = m } else { hi = m } }
                anchor = KitBallSample(t: (lo + hi) / 2, p: pre.position((lo + hi) / 2))
            }
        }
        var post: Fit? = nil
        var kept: [KitBallSample] = []
        var riseRejected = 0
        let firstN = min(s.count, jm + 9)
        if jm + 4 <= s.count,
           let start = Fit.consensus(Array(s[jm..<firstN]), t0: t0, kappa: kappa, gate: max(0.008, 3 * pre.rms), anchor: anchor) {
            var f = start.fit
            kept = start.kept
            riseRejected = firstN - (jm + 1) - kept.filter { $0.t > s[jm].t }.count
            var i = firstN
            func fits(_ x: KitBallSample, _ f: Fit) -> Bool { f.distance(x) <= max(gate, 4 * f.rms) }
            // a wrong frame or two are skipped when one of the next three (within 0.08 s) fits again; a contact ends it
            // (a frame after one is centimetres off, and so are the next)
            while i < s.count {
                if fits(s[i], f) { kept.append(s[i]); i += 1 }
                else if let jn = ((i + 1)..<min(s.count, i + 4)).first(where: { s[$0].t - s[i].t < 0.08 && fits(s[$0], f) }) {
                    riseRejected += jn - i; i = jn; continue
                } else { break }
                if let g = Fit.fit(kept, t0: t0, kappa: kappa) { f = g }
            }
            while kept.count > 3, let last = kept.last, f.distance(last) > max(0.006, 3 * f.rms) {
                kept.removeLast()
                if let g = Fit.fit(kept, t0: t0, kappa: kappa) { f = g }
            }
            post = f
        }
        guard let rise = post, kept.count >= 3, kept.last!.t - kept.first!.t >= 0.04 else {
            return .failed("too few frames after the impact to fit the bounce")
        }
        // the lowest sample, unless the rise took it, goes with the fall if it fits it
        if kept.first?.t != s[jm].t {
            let dPre = pre.distance(s[jm]), dPost = rise.distance(s[jm])
            if dPre <= gate && dPre <= dPost { preKept.append(s[jm]); if let f = Fit.fit(preKept, t0: t0, kappa: kappa, still: still) { pre = f } }
        }

        // the end of the rise: the next contact (the arc the samples after it make, met with the rise's), or the end of the
        // track (the ball left the view or was lost)
        let floorLevel = ctx.floorY.map { $0 + R }
        let release: Vec3 = held ?? pre.position(pre.t0 + pre.b.y / G)
        let lastT = kept.last!.t
        let dbApprox = pre.b.y - rise.b.y
        let tiApprox = abs(dbApprox) > 1e-6 ? t0 + (rise.a.y - pre.a.y) / dbApprox : s[jm].t
        // (the samples the end of the rise left out, and those after it)
        let following = s.filter { $0.t > lastT && $0.t <= lastT + 0.6 }
        var next: KitDropContact? = nil
        if let nx = following.first, nx.t - lastT < 0.25 {
            var tc = (lastT + nx.t) / 2
            let arc = Array(following.prefix(12))
            if arc.count >= 4, let nf = Fit.robust(arc, t0: nx.t, kappa: kappa), nf.kept.count >= 4 {
                // the two arcs' heights differ linearly in time
                func gap(_ t: Double) -> Double { rise.position(t).y - nf.fit.position(t).y }
                let ta = lastT, tb = nx.t, fa = gap(ta), fb = gap(tb)
                if abs(fb - fa) > 1e-9 { tc = clamp(ta - fa * (tb - ta) / (fb - fa), lastT, nx.t) }
            } else {
                // where the rise comes down to the lowest of the next few samples
                let low = following.prefix(3).map(segHeight).min() ?? segHeight(nx)
                let v = rise.velocity(tiApprox), p0 = rise.position(tiApprox)
                let disc = v.y * v.y + 2 * G * (p0.y - low)
                if disc >= 0 { tc = clamp(tiApprox + (v.y + disc.squareRoot()) / G, lastT, nx.t) }
            }
            let c = rise.position(tc)
            var surface = KitDropContact.Surface.unknown
            if let p = slab, let dd = dish {
                let q = p.toSlab(c)
                if abs(q.x) <= p.halfU && abs(q.y) <= p.halfV && abs(dd.contact(center: q, radius: R).clearance) < 0.03 { surface = .slab }
            }
            if surface == .unknown, let fl = floorLevel, abs(c.y - fl) < 0.03 { surface = .floor }
            next = KitDropContact(time: tc, center: c, surface: surface)
        }
        // the landing level: the floor; else where the ball came down next, when that is clearly lower than the impact and
        // not on the slab (the floor, seen); else a fixed level below the impact
        var levelSource = "fixed"
        var levelFromTrack: Double? = nil
        if floorLevel != nil { levelSource = "floor" }
        else if let nc = next, nc.surface != .slab, rise.position(tiApprox).y - nc.center.y > 0.03 {
            levelFromTrack = nc.center.y; levelSource = "next bounce"
        }

        // where the ball touched the dish: its centre at the fits' meeting slid along the line of sight (where the
        // finder's error lies; the lock and the dish are good to millimetres) until it touches; unchanged without a
        // camera or a lock, or when the line of sight runs within 10° of the slab's plane
        let camera = s.filter { $0.c != nil }.min(by: { abs($0.t - tiApprox) < abs($1.t - tiApprox) })?.c
        func onDishAlongSight(_ q: Vec3) -> Vec3 {
            guard let cam = camera, let p = slab, onDish(q).clearance != nil else { return q }
            let dir = (q - cam).normalized
            guard abs(dir.dot(p.normal)) > sin(Units.radians(10)) else { return q }
            let r0 = (q - cam).length
            func gap(_ r: Double) -> Double { onDish(cam + dir * r).clearance ?? 0 }
            // the clearance falls along the ray into the dish: bracket its zero within 0.25 m of the meeting point
            var lo = max(0.05, r0 - 0.25), hi = r0 + 0.25
            guard gap(lo) > 0, gap(hi) < 0 else { return q }
            for _ in 0..<60 { let m = (lo + hi) / 2; if gap(m) > 0 { lo = m } else { hi = m } }
            return cam + dir * ((lo + hi) / 2)
        }

        // everything that follows from the two fits (for the numbers and, by differences, their uncertainties)
        struct Derived {
            var ti = 0.0, center = Vec3.zero, point = Vec3.zero, normal = Vec3(0, 1, 0)
            var u: Double?, v: Double?, clearance: Double?, tilt: Double?, downhill: Double?, left: Double?
            var vin = Vec3.zero, vout = Vec3.zero, e = 0.0, speedRebound = 0.0, k: Double?, sideways: Double?
            var apex = 0.0, level = 0.0, tl = 0.0, landing = Vec3.zero
            var app: KitDropComparison?, measured: KitDropComparison?
            var drop = 0.0
            var scalars: [Double?] {
                [ti, u, v, clearance, e, e * e, k, sideways, apex, landing.x, landing.z, drop,
                 app?.directionError, app?.landingError, app?.rangeError, app?.bearingError,
                 measured?.directionError, measured?.landingError, measured?.rangeError, measured?.bearingError]
            }
        }
        let up = Vec3(0, 1, 0)
        let wrap = KitDropAnalysis.wrap, landingOf = KitDropAnalysis.landing
        func compare(_ p: KitBouncePrediction, rebound: Double, d: Derived) -> KitDropComparison {
            KitDropAnalysis.compare(p, rebound: rebound, impactCenter: d.center, velocityOut: d.vout, landing: d.landing, apex: d.apex, level: d.level)
        }
        func derive(_ pre: Fit, _ rise: Fit, predict: Bool) -> Derived? {
            var d = Derived()
            let db = pre.b.y - rise.b.y
            guard abs(db) > 1e-6 else { return nil }
            d.ti = t0 + (rise.a.y - pre.a.y) / db
            d.center = (pre.position(d.ti) + rise.position(d.ti)) / 2
            d.clearance = onDish(d.center).clearance
            let c = onDish(onDishAlongSight(d.center))
            d.point = c.point; d.normal = c.normal; d.u = c.u; d.v = c.v
            d.tilt = slab.map { Units.degrees(c.normal.angle(to: $0.normal)) }
            if let p = slab {
                let down = Vec3(0, -1, 0).rejecting(p.normal)
                if down.length > sin(Units.radians(0.3)) {
                    let dh = down.normalized, rel = c.point - p.center
                    d.downhill = rel.dot(dh); d.left = rel.dot(p.normal.cross(dh))
                }
            }
            d.vin = pre.velocity(d.ti); d.vout = rise.velocity(d.ti)
            let n = d.normal, vinN = d.vin.dot(n)
            guard vinN < -1e-6 else { return nil }
            d.e = -d.vout.dot(n) / vinN
            d.speedRebound = d.vout.lengthSquared / max(1e-12, d.vin.lengthSquared)
            let tin = d.vin - n * vinN, tout = d.vout - n * d.vout.dot(n)
            if tin.length >= 0.05 {
                let th = tin.normalized, side = n.cross(th)
                d.k = tout.dot(th) / tin.length
                d.sideways = Units.degrees(atan2(tout.dot(side), d.vout.dot(n)))
            }
            let ta = rise.t0 + rise.b.y / G
            d.apex = rise.position(max(d.ti, ta)).y - d.center.y
            d.level = floorLevel ?? levelFromTrack ?? (d.center.y - ctx.fixedLandingDrop)
            let (tau, l) = landingOf(rise.position(d.ti), d.vout, d.level)
            d.tl = d.ti + tau; d.landing = l
            d.drop = release.y - d.center.y
            if predict, let pr = ctx.predict {
                if let p = pr(release, ctx.appRebound) { d.app = compare(p, rebound: ctx.appRebound, d: d) }
                let r = max(0, d.e * d.e)
                if let p = pr(release, r) { d.measured = compare(p, rebound: r, d: d) }
            }
            return d
        }
        guard let d = derive(pre, rise, predict: true) else {
            return .failed("the track does not hold together as a drop: the fall's and the bounce's fits do not meet")
        }
        let lo = (preKept.map { $0.t }.max() ?? s[jm].t) - 0.02, hi = (kept.first?.t ?? s[jm].t) + 0.02
        guard d.ti >= lo && d.ti <= hi else {
            return .failed("the track does not hold together as a drop: the fall's and the bounce's fits do not meet between the frames around the impact")
        }
        // the speed in must be the fall's
        let expected = 2 * G * d.drop, got = d.vin.lengthSquared
        guard d.drop > 0.02, abs(got - expected) <= 0.3 * expected else {
            return .failed(String(format: "the track does not hold together as a drop: the speed into the bounce (%.2f m/s) does not match a fall of %.0f mm",
                                  d.vin.length, d.drop * 1000))
        }
        if abs(got - expected) > 0.12 * expected {
            notes.append(String(format: "the speed into the bounce (%.2f m/s) is %.0f%% off a fall of %.0f mm from the held point (a push at the release, or the held point read off)",
                                d.vin.length, 100 * (got.squareRoot() / expected.squareRoot() - 1), d.drop * 1000))
        }
        guard d.e * d.e <= 1.1, d.e > 0 else {
            return .failed(String(format: "the track does not hold together as a drop: it gives a rebound of %.0f%%", d.e * d.e * 100))
        }

        // uncertainties: each fit's per-axis covariance through the derivatives of every number
        // the noise across the line of sight: the larger of the two fits' (the same finder and camera; a fit to a few
        // samples can look better than it is), at least 0.5 mm; each fit's parameters' covariance scales with it
        let s2 = max(0.0005 * 0.0005, pre.noiseAcross(preKept), rise.noiseAcross(kept))
        let base = d.scalars
        var variance = [Double](repeating: 0, count: base.count)
        let h = 1e-5
        for which in 0..<2 {
            let f0 = which == 0 ? pre : rise
            // the numbers' derivatives by the fit's six parameters (a, then b)
            var jac = [[Double]](repeating: [Double](repeating: 0, count: base.count), count: 6)
            for k in 0..<6 {
                var f1 = f0
                var av = f1.a.array, bv = f1.b.array
                if k < 3 { av[k] += h } else { bv[k - 3] += h }
                f1.a = Vec3(av); f1.b = Vec3(bv)
                guard let dd = which == 0 ? derive(f1, rise, predict: true) : derive(pre, f1, predict: true) else { continue }
                let sc = dd.scalars
                for q in base.indices {
                    guard let x0 = base[q], let x1 = sc[q] else { continue }
                    var diff = x1 - x0
                    if q == 15 || q == 19 { diff = wrap(diff) }  // bearings
                    jac[k][q] = diff / h
                }
            }
            for q in base.indices {
                var v = 0.0
                for k in 0..<6 { for l in 0..<6 { v += jac[k][q] * f0.unitCov[k][l] * jac[l][q] } }
                variance[q] += s2 * v
            }
        }
        func sigma(_ q: Int) -> Double? { base[q] == nil ? nil : max(0, variance[q]).squareRoot() }
        // the held point's spread
        var heldSigma = 0.0
        if let hp = held, hold.count >= 2 {
            let dev = hold.map { abs($0.p.y - hp.y) }
            heldSigma = 1.4826 * KitStats.median(dev) / Double(hold.count).squareRoot()
        } else {
            // from the fall fit's apex: about twice the uncertainty of its height at the impact
            heldSigma = 2 * (s2 * pre.unitCov[1][1]).squareRoot()
        }
        var app = d.app, meas = d.measured
        app?.directionErrorSigma = sigma(12); app?.landingErrorSigma = sigma(13); app?.rangeErrorSigma = sigma(14)
        let appBearing = app?.bearingError, measBearing = meas?.bearingError
        app?.bearingErrorSigma = appBearing == nil ? nil : sigma(15)
        meas?.directionErrorSigma = sigma(16); meas?.landingErrorSigma = sigma(17); meas?.rangeErrorSigma = sigma(18)
        meas?.bearingErrorSigma = measBearing == nil ? nil : sigma(19)

        var leftView = false
        if let nc = next {
            if levelSource != "next bounce" && nc.time < d.tl - 0.01 {
                let on = nc.surface == .slab ? "on the slab" : nc.surface == .floor ? "on the floor" : "on something"
                notes.append(String(format: "the ball came down %@ %.2f s after the bounce, %.0f mm above the landing level: the landing is the arc carried on",
                                    on, nc.time - d.ti, (nc.center.y - d.level) * 1000))
            }
        } else if d.tl > lastT + 0.02 {
            leftView = true
            notes.append(String(format: "the ball was not seen after %.2f s of its %.2f s flight (it left the view or was lost): the landing is extrapolated",
                                lastT - d.ti, d.tl - d.ti))
        }
        let extrapolation = max(0, d.tl - lastT)
        if extrapolation > 0.5 * (d.tl - d.ti) {
            notes.append(String(format: "%.0f%% of the flight to the landing is extrapolated", 100 * extrapolation / max(1e-9, d.tl - d.ti)))
        }
        if rise.rms > 3 * max(0.002, pre.rms) {
            notes.append(String(format: "the bounce's arc fits %.1f mm RMS, the fall's %.1f mm: spin or a wrong frame bends it", rise.rms * 1000, pre.rms * 1000))
        }
        if let sw = d.sideways, abs(sw) > 3 {
            notes.append(String(format: "the bounce leaves %.1f° out of the plane of incidence (spin from the release, or the slab's normal read off)", sw))
        }
        if slab == nil { notes.append("no lock before the release: the impact is taken on a level surface (no offset, no dish)") }

        let launchTilt = Units.degrees(d.vout.angle(to: up))
        let a = KitDropAnalysis(kind: .bounce, heldSeen: held != nil, releaseTime: pre.t0 + pre.b.y / G, releasePoint: release,
                                dropHeight: d.drop, dropHeightSigma: ((sigma(11) ?? 0) * (sigma(11) ?? 0) + heldSigma * heldSigma).squareRoot(),
                                appDropHeight: app?.dropHeight,
                                fallSamples: preKept.count, fallRejected: max(0, jm - k0 - preR.kept.count), fallRms: pre.rms,
                                impactTime: d.ti, impactTimeSigma: sigma(0) ?? 0, impactCenter: d.center, contactPoint: d.point,
                                offsetU: d.u, offsetV: d.v,
                                offsetSigma: d.u == nil ? nil : (pow(sigma(1) ?? 0, 2) + pow(sigma(2) ?? 0, 2)).squareRoot(),
                                offsetDownhill: d.downhill, offsetLeft: d.left,
                                localNormal: d.normal, normalTilt: d.tilt, impactClearance: d.clearance, impactClearanceSigma: sigma(3),
                                velocityIn: d.vin, velocityOut: d.vout, restitution: d.e, restitutionSigma: sigma(4),
                                rebound: d.e * d.e, reboundSigma: sigma(5), speedRebound: d.speedRebound,
                                tangentialRatio: d.k, tangentialRatioSigma: sigma(6), sideways: d.sideways, sidewaysSigma: sigma(7),
                                launchTilt: launchTilt, riseSamples: kept.count, riseRejected: riseRejected, riseRms: rise.rms,
                                apexHeight: d.apex, landingLevel: d.level, landingLevelSource: levelSource,
                                landing: d.landing, landingSigma: (pow(sigma(9) ?? 0, 2) + pow(sigma(10) ?? 0, 2)).squareRoot(),
                                landingTime: d.tl, landingExtrapolation: extrapolation, nextContact: next, leftView: leftView,
                                app: app, measuredRebound: meas, notes: notes)
        return .analyzed(a)
    }

    /// An angle wrapped to -180...180 degrees.
    static func wrap(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    /// The direction of a horizontal vector seen from above (degrees from +x, anticlockwise positive: toward -z).
    static func bearing(_ d: Vec3) -> Double { Units.degrees(atan2(-d.z, d.x)) }

    /// Where free flight from `start` with velocity `v` comes down to the world height `level` (the later crossing), and
    /// after how long (s); a flight that never gets that low ends at its apex.
    public static func landing(start: Vec3, velocity v: Vec3, level: Double) -> (Double, Vec3) {
        let G = Units.gravity
        let disc = max(0, v.y * v.y + 2 * G * (start.y - level))
        let tau = max(0, (v.y + disc.squareRoot()) / G)
        return (tau, start + v * tau + Vec3(0, -G, 0) * (0.5 * tau * tau))
    }

    /// A prediction against a bounce: launched from `impactCenter` with `velocityOut`, its highest point `apex` above
    /// it, landing at `landing` on the level `level`.
    public static func compare(_ p: KitBouncePrediction, rebound: Double, impactCenter: Vec3, velocityOut: Vec3, landing: Vec3, apex: Double,
                               level: Double) -> KitDropComparison {
        let up = Vec3(0, 1, 0), G = Units.gravity
        let (_, pl) = KitDropAnalysis.landing(start: p.start, velocity: p.velocity, level: level)
        let mDist = (landing - impactCenter).rejecting(up), pDist = (pl - p.start).rejecting(up)
        let be: Double? = mDist.length > 0.01 && pDist.length > 0.01 ? wrap(bearing(mDist) - bearing(pDist)) : nil
        let pApex = p.velocity.y > 0 ? p.velocity.y * p.velocity.y / (2 * G) : 0
        return KitDropComparison(rebound: rebound, dropHeight: p.dropHeight, start: p.start, velocity: p.velocity, landing: pl,
                                 directionError: Units.degrees(p.velocity.angle(to: velocityOut)),
                                 landingError: (landing - pl).rejecting(up).length, rangeError: mDist.length - pDist.length,
                                 bearingError: be, apexError: pApex - apex)
    }

    /// Drops as a Markdown table: per drop its drop height (inches; the app's in brackets), where it hit the dish (its
    /// contact point along the slab's axes from the centre, inches), the dish's local normal's tilt from the slab's,
    /// the measured rebound, the launch direction's angle from the app's, and the landing against the app's prediction
    /// with its rebound and with the measured one (distance, actual minus predicted range, and direction seen from
    /// above, anticlockwise positive); uncertainties are 1 sigma. Then the rebound to bake into the app.
    public static func markdownTable(_ drops: [(String, KitDropAnalysis)]) -> String {
        var md: [String] = []
        md.append("| Shot | Drop height | Impact u, v (in) | Downhill, left (in) | Local tilt | Rebound | Launch vs app | "
                  + "Landing vs app (app's rebound) | Landing vs app (measured rebound) | Notes |")
        md.append("|---|---|---|---|---|---|---|---|---|---|")
        func inch(_ m: Double) -> String { String(format: "%.1f", Units.toInches(m)) }
        func landing(_ c: KitDropComparison?) -> String {
            guard let c = c else { return "n/a" }
            var s = String(format: "%.0f", c.landingError * 1000) + (c.landingErrorSigma.map { String(format: " ± %.0f", $0 * 1000) } ?? "") + " mm"
            s += String(format: " (%+.0f mm range", c.rangeError * 1000)
            if let b = c.bearingError { s += String(format: ", %+.1f°", b) }
            return s + ")"
        }
        for (id, a) in drops {
            let dh = inch(a.dropHeight) + " in" + (a.appDropHeight.map { " (app " + inch($0) + ")" } ?? "")
            let off: String
            if let u = a.offsetU, let v = a.offsetV {
                off = String(format: "%+.1f, %+.1f", Units.toInches(u), Units.toInches(v)) + (a.offsetSigma.map { String(format: " ± %.1f", Units.toInches($0)) } ?? "")
            } else { off = "n/a" }
            let slope = a.offsetDownhill.map { String(format: "%+.1f, %+.1f", Units.toInches($0), Units.toInches(a.offsetLeft ?? 0)) } ?? "level"
            let tilt = a.normalTilt.map { String(format: "%.2f°", $0) } ?? "n/a"
            let reb = a.rebound.map { String(format: "%.1f%%", $0 * 100) + (a.reboundSigma.map { String(format: " ± %.1f", $0 * 100) } ?? "") }
                ?? "none (\(a.kind.rawValue))"
            let dir = a.app.map { String(format: "%.1f°", $0.directionError) + ($0.directionErrorSigma.map { String(format: " ± %.1f", $0) } ?? "") } ?? "n/a"
            var notes: [String] = []
            if let x = a.landingExtrapolation, x > 0.02 { notes.append(String(format: "landing extrapolated %.2f s", x)) }
            notes += a.notes
            md.append("| \(id) | \(dh) | \(off) | \(slope) | \(tilt) | \(reb) | \(dir) | \(landing(a.app)) | \(landing(a.measuredRebound)) | "
                      + KitScoreReport.cell(notes.joined(separator: "; ")) + " |")
        }
        md.append("")
        md.append(bakeLine(drops.map { $0.1 }) + ".")
        return md.joined(separator: "\n")
    }

    /// The rebound to bake into the app from several drops: the bounces' rebounds (e², `BallSpec.rebound`), those more
    /// than max(0.1, 3 sigma) from their median left out, averaged with weights 1 / sigma² (sigma at least 0.01); its
    /// uncertainty the larger of the weighted mean's and the spread's (standard deviation / sqrt(n)). nil without a
    /// bounce.
    public static func reboundToBake(_ drops: [KitDropAnalysis]) -> (rebound: Double, sigma: Double, count: Int)? {
        let r = drops.compactMap { d -> (Double, Double)? in
            guard d.kind == .bounce, let x = d.rebound, x.isFinite else { return nil }
            return (x, max(0.01, d.reboundSigma ?? 0.05))
        }
        guard !r.isEmpty else { return nil }
        let m = KitStats.median(r.map { $0.0 })
        let use = r.filter { abs($0.0 - m) <= max(0.1, 3 * $0.1) }
        guard !use.isEmpty else { return nil }
        let w = use.map { 1 / ($0.1 * $0.1) }, sw = w.reduce(0, +)
        let mean = zip(use, w).reduce(0) { $0 + $1.0.0 * $1.1 } / sw
        var sigma = (1 / sw).squareRoot()
        if use.count >= 2 {
            let mu = use.reduce(0) { $0 + $1.0 } / Double(use.count)
            let sd = (use.reduce(0) { $0 + ($1.0 - mu) * ($1.0 - mu) } / Double(use.count - 1)).squareRoot()
            sigma = max(sigma, sd / Double(use.count).squareRoot())
        }
        return (mean, sigma, use.count)
    }

    /// "rebound to bake into the app: 71% ± 1% (from 4 drops)", or why there is none.
    public static func bakeLine(_ drops: [KitDropAnalysis]) -> String {
        guard let b = reboundToBake(drops) else { return "rebound to bake into the app: none (no bounce measured)" }
        return String(format: "rebound to bake into the app: %.0f%% ± %.0f%% (from %d drop%@)", b.rebound * 100, max(1, b.sigma * 100), b.count,
                      b.count == 1 ? "" : "s")
    }
}

/// Free fall with gravity known, p(t) = a + b (t - t0) + g (t - t0)² / 2, fitted to ball samples by weighted least
/// squares: a sample's error along its line of sight (from the camera, `KitBallSample.c`) counts kappa² as much as its
/// error across it, since the finder takes the ball's distance from its size, far less precisely than its place in the
/// picture (kappa = 1, or a sample without a camera: plain least squares). With gravity known in metres, the arc's
/// curvature in the picture pins its distance down, so a fall seen over a few frames is good to millimetres even when
/// each frame's distance is centimetres off.
struct KitDropFit {
    var a: Vec3
    var b: Vec3
    var t0: Double
    var kappa: Double
    /// RMS of the samples' weighted distances from the fit (m, as across the line of sight)
    var rms = 0.0
    /// the covariance of (a, b) for a unit noise across the line of sight (6 x 6)
    var unitCov: [[Double]] = []

    static let g = Vec3(0, -Units.gravity, 0)

    func position(_ t: Double) -> Vec3 { let s = t - t0; return a + b * s + KitDropFit.g * (0.5 * s * s) }
    func velocity(_ t: Double) -> Vec3 { b + KitDropFit.g * (t - t0) }

    /// the unit direction from the camera to the sample, if its camera is known
    static func sight(_ x: KitBallSample) -> Vec3? {
        guard let c = x.c else { return nil }
        let d = x.p - c, l = d.length
        return l > 1e-6 ? d / l : nil
    }

    /// a sample's distance from a point, its part along the line of sight scaled by kappa
    static func distance(_ x: KitBallSample, _ q: Vec3, kappa: Double) -> Double {
        let r = x.p - q
        guard let d = sight(x) else { return r.length }
        let al = r.dot(d)
        return ((r - d * al).lengthSquared + kappa * kappa * al * al).squareRoot()
    }

    func distance(_ x: KitBallSample) -> Double { KitDropFit.distance(x, position(x.t), kappa: kappa) }

    /// The weighted fit (at least 3 samples); `covariance` false skips the covariance (for trial fits). `still`: the
    /// weight (in units of a sample's noise across the line of sight, squared) of a prior that the horizontal velocity
    /// is 0 (a ball let go, not thrown).
    static func fit(_ s: [KitBallSample], t0: Double, kappa: Double, covariance: Bool = true, still: Double = 0) -> KitDropFit? {
        guard s.count >= 3 else { return nil }
        var A = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6), B = [Double](repeating: 0, count: 6)
        A[3][3] += still; A[5][5] += still
        let k2 = 1 - kappa * kappa
        for x in s {
            let tau = x.t - t0, yv = (x.p - g * (0.5 * tau * tau)).array
            var W: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
            if let d = sight(x) {
                let dv = d.array
                for i in 0..<3 { for j in 0..<3 { W[i][j] -= k2 * dv[i] * dv[j] } }
            }
            for i in 0..<3 {
                var wy = 0.0
                for j in 0..<3 {
                    let w = W[i][j]
                    A[i][j] += w; A[i][j + 3] += tau * w; A[i + 3][j] += tau * w; A[i + 3][j + 3] += tau * tau * w
                    wy += w * yv[j]
                }
                B[i] += wy; B[i + 3] += tau * wy
            }
        }
        guard let x = solveLinear(A, B) else { return nil }
        var f = KitDropFit(a: Vec3(x[0], x[1], x[2]), b: Vec3(x[3], x[4], x[5]), t0: t0, kappa: kappa)
        f.rms = (s.reduce(0) { let d = f.distance($1); return $0 + d * d } / Double(s.count)).squareRoot()
        if covariance {
            var inv: [[Double]] = []
            for k in 0..<6 {
                var e = [Double](repeating: 0, count: 6)
                e[k] = 1
                guard let col = solveLinear(A, e) else { return nil }
                inv.append(col)
            }
            f.unitCov = inv
        }
        return f
    }

    /// The fit less the samples far off it: while the worst lies more than max(`floor`, 5 x the median distance) off, it
    /// is dropped and the rest refitted, up to a quarter of them.
    static func robust(_ s: [KitBallSample], t0: Double, kappa: Double, floor: Double = 0.006, still: Double = 0)
        -> (fit: KitDropFit, kept: [KitBallSample])? {
        var kept = s
        guard var f = fit(kept, t0: t0, kappa: kappa, still: still) else { return nil }
        var dropped = 0
        while dropped < s.count / 4 && kept.count > 3 {
            let d = kept.map { f.distance($0) }
            guard let worst = d.indices.max(by: { d[$0] < d[$1] }), d[worst] > max(floor, 5 * KitStats.median(d)) else { break }
            kept.remove(at: worst)
            dropped += 1
            guard let g = fit(kept, t0: t0, kappa: kappa, still: still) else { return nil }
            f = g
        }
        return (f, kept)
    }

    /// The arc `samples` agree on: every arc through three of them (and through `anchor` and two of them), scored by the
    /// sum over the samples of min(d², gate²) (d: a sample's weighted distance from it; MSAC), the best refitted to the
    /// samples within `gate` of it (not the anchor). At least 3 must agree. Over 2000 trios, an even spread of them.
    static func consensus(_ samples: [KitBallSample], t0: Double, kappa: Double, gate: Double, anchor: KitBallSample? = nil)
        -> (fit: KitDropFit, kept: [KitBallSample])? {
        guard samples.count >= 3 else { return nil }
        let points = samples + (anchor.map { [$0] } ?? [])
        let n = points.count
        let trios = n * (n - 1) * (n - 2) / 6
        let step = max(1, trios / 2000)
        var best: (cost: Double, kept: [KitBallSample])? = nil
        var count = 0
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                for k in (j + 1)..<max(j + 1, n) {
                    count += 1
                    if count % step != 0 { continue }
                    guard points[k].t - points[i].t >= 0.015,
                          let f = fit([points[i], points[j], points[k]], t0: t0, kappa: kappa, covariance: false) else { continue }
                    var kept: [KitBallSample] = [], cost = 0.0
                    for x in samples {
                        let d = f.distance(x)
                        if d <= gate { kept.append(x) }
                        cost += min(d * d, gate * gate)
                    }
                    if kept.count >= 3 && (best == nil || cost < best!.cost) { best = (cost, kept) }
                }
            }
        }
        guard let b = best, let f = fit(b.kept, t0: t0, kappa: kappa) else { return nil }
        return (f, b.kept)
    }

    /// The noise's split from the residuals: (robust) across over along the line of sight, as a kappa (0.03-1); nil with
    /// under 5 samples that know their camera.
    func noiseSplit(_ samples: [KitBallSample]) -> Double? {
        let r = samples.compactMap { x -> (Double, Double)? in
            guard let d = KitDropFit.sight(x) else { return nil }
            let e = x.p - position(x.t), al = e.dot(d)
            return (abs(al), (e - d * al).length)
        }
        guard r.count >= 5 else { return nil }
        let along = 1.4826 * KitStats.median(r.map { $0.0 }), across = KitStats.median(r.map { $0.1 }) / 1.1774
        return clamp(max(0.0003, across) / max(0.0003, along, across), 0.03, 1)
    }

    /// The variance of a sample's error across the line of sight (per axis), from the weighted residuals.
    func noiseAcross(_ samples: [KitBallSample]) -> Double {
        let n = Double(samples.count)
        return samples.reduce(0) { let d = distance($1); return $0 + d * d } / max(1, 3 * n - 6)
    }
}
