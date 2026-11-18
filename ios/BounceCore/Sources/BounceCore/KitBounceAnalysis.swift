import Foundation

/// One position of the ball (its centre, ARKit's world, metres) at one moment (s, the frames' clock).
public struct KitBallSample: Codable, Equatable {
    public var t: Double
    public var p: Vec3
    public init(t: Double, p: Vec3) { self.t = t; self.p = p }
}

/// What the app predicted for a drop: the bounce `Bounce.compute` works out from the tracker's lock and the held ball,
/// with the ball's centre in place of the launch point on the dish (its radius above it).
public struct KitBouncePrediction: Codable, Equatable {
    /// the ball's centre when it leaves the slab (world)
    public var start: Vec3
    /// its velocity then (m/s, world)
    public var velocity: Vec3
    /// the drop height the app used (m)
    public var dropHeight: Double
    /// the drop came from the held ball (false: the ball was not over the slab, and the app used its default height)
    public var fromBall: Bool
    /// how high the bounce rises above its start (m)
    public var apexHeight: Double

    public init(start: Vec3, velocity: Vec3, dropHeight: Double, fromBall: Bool, apexHeight: Double) {
        self.start = start; self.velocity = velocity; self.dropHeight = dropHeight; self.fromBall = fromBall; self.apexHeight = apexHeight
    }

    /// The app's bounce for a ball held at `held` (world) over the slab `pose` (world), with the tracker's settings.
    public static func app(pose: SlabPose, settings: TrackerSettings, held: Vec3) -> KitBouncePrediction {
        let down = ARKitConvention.worldDown
        let r = Bounce.compute(pose: pose, spec: settings.spec, ball: settings.ball, down: down, ballCenter: held,
                               defaultDropHeight: settings.defaultDropHeight, rule: settings.launchRule)
        let p = r.path
        return KitBouncePrediction(start: p.start - down * settings.ball.radius, velocity: p.direction * p.speed,
                                   dropHeight: r.drop?.dropHeight ?? settings.defaultDropHeight, fromBall: r.drop != nil,
                                   apexHeight: p.apexHeight)
    }

    /// Where the predicted bounce comes back down to the height it started at (world).
    public var landing: Vec3 {
        let up = -ARKitConvention.worldDown, vup = velocity.dot(up)
        guard vup > 0 else { return start }
        let T = 2 * vup / Units.gravity
        return start + velocity.rejecting(up) * T
    }
}

/// A drop measured from the ball's track (the ball finder run on every frame), and compared with the app's prediction.
///
/// Definitions (world, metres, y up, g = 9.80665 m/s²):
///   - **held**: the median of the ball's centre from 1.5 s before the release cue to 0.05 s after it;
///   - the fall and the impact are found on the track's heights smoothed by a running median of five samples, so that
///     a single frame whose ball was read wrong (a reflected ring taken for the outline, the size read from the wrong
///     half) neither starts the fall nor is taken for the impact: **the fall** starts with the first sample after
///     (cue - 0.3 s) at least 1.5 cm below the held height whose next sample is too, and which goes on to fall at least
///     5 cm below the held height within 0.15 s (where the track has samples then); **the impact** is the lowest
///     sample about the lowest smoothed point before the ball rises 1 cm again;
///   - **pre-impact fit**: free fall `p(t) = a + b t + g t²/2` (least squares, gravity known) on the falling samples,
///     less those far off it (`robustFit`: more than max(6 mm, 5 x the median distance) off, the worst first, at most a
///     quarter of them); the release is where its vertical speed is 0;
///   - **post-impact fit**: the same model on the samples after the impact, started from the first five that fit
///     (robustly, as above), grown one sample at a time while each new sample lies within max(15 mm, 5 x the
///     pre-impact fit's RMS, 4 x its own RMS) of the fit's prediction; a single sample off is skipped, two in a row end
///     the flight (the next bounce, on the floor), and samples at the end more than max(6 mm, 3 x RMS) off the final
///     fit are dropped; at least 3 samples;
///   - **impact time**: where the two fits' heights meet; **impact point**: the mean of the two fits there;
///   - **velocity in / out**: the fits' velocities at the impact; **rebound** = |v_out|² / |v_in|² (the app's rebound:
///     the share of the drop height a straight-up bounce would regain);
///   - **apex**: the post-impact fit's highest point, its height above the impact point;
///   - **landing**: where the post-impact fit comes back down to the impact point's height; the landing distance is
///     horizontal, from the impact point. Beyond the last fitted sample the fit is extrapolated
///     (`landingExtrapolation`, seconds).
/// A track that does not hold together as a drop is not analysed (`.failed`, with the reason), rather than give numbers
/// that are only the track's errors: the two fits must meet between the frames around the impact (within 0.02 s);
/// the speed in must match the fall (|v_in|² within 20% of 2 g x the fall height); the rebound must be between 0 and
/// 1.1; and the landing may be extrapolated over at most half the flight.
/// Against the prediction (`KitBouncePrediction`, from the lock before the release and the held ball):
///   - **landingError**: horizontal distance between the predicted landing (where the predicted bounce comes back to
///     its own start height) and the measured one;
///   - **landingDistanceError**: predicted minus measured landing distance (each from its own start);
///   - **apexError**: predicted minus measured apex height;
///   - **impactHeightError**: the predicted launch's height (the ball's centre a radius above the dish, straight below
///     the held ball) minus the measured impact point's (m, signed). Both lie straight below the held ball, so only the
///     height says anything about the lock (its plane and the dish depth); the horizontal distance between them is
///     about 0 whatever the lock.
public struct KitBounceAnalysis: Codable, Equatable {
    public var held: Vec3
    /// when the ball was let go (s), from the pre-impact fit
    public var releaseTime: Double
    public var impactTime: Double
    /// the ball's centre at the impact (world)
    public var impactPoint: Vec3
    public var velocityIn: Vec3
    public var velocityOut: Vec3
    public var rebound: Double
    /// held centre to impact centre (m)
    public var fallHeight: Double
    /// above the impact point (m)
    public var apexHeight: Double
    public var apex: Vec3
    /// where the bounce comes back to the impact height (world)
    public var landing: Vec3
    /// horizontal, from the impact point (m)
    public var landingDistance: Double
    /// how far past the last fitted sample the landing lies (s; 0 when it was seen)
    public var landingExtrapolation: Double
    public var preSamples: Int
    public var postSamples: Int
    /// RMS misfit of the fits (m)
    public var preRms: Double
    public var postRms: Double
    public var prediction: KitBouncePrediction?
    public var landingError: Double?
    public var landingDistanceError: Double?
    public var apexError: Double?
    public var impactHeightError: Double?
    public var notes: [String]

    /// The outcome of analysing a drop.
    public enum Outcome: Equatable {
        case analyzed(KitBounceAnalysis)
        /// why not, in plain English
        case failed(String)
        public var analysis: KitBounceAnalysis? { if case let .analyzed(a) = self { return a } else { return nil } }
        public var reason: String? { if case let .failed(r) = self { return r } else { return nil } }
    }

    /// Free fall through samples, gravity known: per axis p(tau) = a + b tau + g tau²/2 with tau = t - t0.
    struct Fit {
        var a: Vec3
        var b: Vec3
        var t0: Double
        var rms: Double
        static let g = Vec3(0, -Units.gravity, 0)

        func position(_ t: Double) -> Vec3 { let s = t - t0; return a + b * s + Fit.g * (0.5 * s * s) }
        func velocity(_ t: Double) -> Vec3 { b + Fit.g * (t - t0) }

        static func fit(_ s: ArraySlice<KitBallSample>, t0: Double) -> Fit? {
            guard s.count >= 3 else { return nil }
            var st = 0.0, stt = 0.0, sy = Vec3.zero, sty = Vec3.zero
            let n = Double(s.count)
            for x in s {
                let tau = x.t - t0, y = x.p - g * (0.5 * tau * tau)
                st += tau; stt += tau * tau; sy += y; sty += y * tau
            }
            let den = n * stt - st * st
            guard abs(den) > 1e-12 else { return nil }
            let b = (sty * n - sy * st) / den, a = (sy - b * st) / n
            var f = Fit(a: a, b: b, t0: t0, rms: 0)
            f.rms = (s.reduce(0) { $0 + ($1.p - f.position($1.t)).lengthSquared } / n).squareRoot()
            return f
        }

        /// The fit less the samples far off it: while the worst sample lies more than max(`floor`, 5 x the median
        /// distance of the samples from the fit) off, it is dropped and the rest refitted, up to a quarter of them (a
        /// distance's median is 0.67 standard deviations of an error along one direction, as a size's error is along the
        /// line of sight: 5 medians are 3.4 of them). Returns the fit and the samples kept, in order.
        static func robust(_ s: [KitBallSample], t0: Double, floor: Double = 0.006) -> (fit: Fit, kept: [KitBallSample])? {
            var kept = s
            guard var f = fit(kept[...], t0: t0) else { return nil }
            var dropped = 0
            while dropped < s.count / 4 && kept.count > 3 {
                let d = kept.map { ($0.p - f.position($0.t)).length }
                guard let worst = d.indices.max(by: { d[$0] < d[$1] }), d[worst] > max(floor, 5 * KitStats.median(d)) else { break }
                kept.remove(at: worst)
                dropped += 1
                guard let g = fit(kept[...], t0: t0) else { return nil }
                f = g
            }
            return (f, kept)
        }
    }

    /// Running median of five (fewer at the ends).
    static func runningMedian(_ v: [Double]) -> [Double] {
        v.indices.map { i in KitStats.median(Array(v[max(0, i - 2)...min(v.count - 1, i + 2)])) }
    }

    /// Analyses a drop. `track`: the ball's centre over the shot (any order; non-finite samples are dropped); `cue`: when
    /// the app beeped (`releaseTime`, or `startTime + releaseCue`); `predict`: the app's prediction for a ball held at a
    /// point (nil: no comparison).
    public static func analyze(track: [KitBallSample], cue: Double, predict: ((Vec3) -> KitBouncePrediction?)? = nil) -> Outcome {
        let s = track.filter { $0.t.isFinite && $0.p.isFinite }.sorted { $0.t < $1.t }
        guard s.count >= 8 else { return .failed("the ball was seen on only \(s.count) frames") }
        func median(_ v: [Double]) -> Double { KitStats.median(v) }
        // held
        let hold = s.filter { $0.t >= cue - 1.5 && $0.t <= cue + 0.05 }
        guard hold.count >= 2 else { return .failed("the ball was not seen held before the release cue") }
        let held = Vec3(median(hold.map { $0.p.x }), median(hold.map { $0.p.y }), median(hold.map { $0.p.z }))
        // the fall and the impact, on the smoothed heights
        let y = runningMedian(s.map { $0.p.y })
        var k1: Int? = nil
        for i in s.indices where s[i].t > cue - 0.3 && held.y - y[i] > 0.015 {
            if i + 1 < s.count && held.y - y[i + 1] <= 0.015 { continue }
            // and goes on falling: 1.5 cm down a ball let go falls 10 cm more in the next 0.1 s, so within 0.15 s it is
            // at least 5 cm below where it was held (a run of frames read a little low is not a fall)
            let next = s.indices.filter { s[$0].t > s[i].t && s[$0].t <= s[i].t + 0.15 }
            if !next.isEmpty && !next.contains(where: { held.y - y[$0] > 0.05 }) { continue }
            k1 = i; break
        }
        guard let fallIndex = k1 else { return .failed("the ball did not fall after the release cue") }
        // the impact: the lowest point before the ball rises 1 cm again
        var jm = fallIndex, rose = false
        var j = fallIndex
        while j < s.count && s[j].t - s[fallIndex].t < 1.5 {
            if y[j] < y[jm] { jm = j } else if y[j] > y[jm] + 0.01 { rose = true; break }
            j += 1
        }
        guard rose else { return .failed("no bounce found: the ball was not seen rising after its fall") }
        // (the median of five flattens the bottom of the V the impact makes: the lowest sample is the lowest smoothed
        // point, or one of the next two, or the one before; a wrong frame there is dropped by the fits below)
        jm = (max(fallIndex, jm - 1)...min(j - 1, jm + 2)).min(by: { s[$0].p.y < s[$1].p.y }) ?? jm
        // the falling samples: from the first one clearly below the held height
        var k0 = fallIndex
        while k0 > 0 && s[k0 - 1].t > cue - 0.3 && held.y - y[k0 - 1] > 0.004 { k0 -= 1 }
        let t0 = s[jm].t
        guard let preR = Fit.robust(Array(s[k0..<jm]), t0: t0) else { return .failed("too few frames of the fall (\(jm - k0)) before the impact") }
        var pre = preR.fit, preKept = preR.kept
        // the post-impact samples, grown while they fit: within max(15 mm, 5 x the fall's misfit, 4 x the fit's own
        // misfit) of the fit's prediction; a single sample off is skipped, two in a row end the flight (the floor)
        let gate = max(0.015, 5 * pre.rms)
        var post: Fit? = nil
        var kept: [KitBallSample] = []
        if jm + 4 <= s.count, let start = Fit.robust(Array(s[(jm + 1)..<min(s.count, jm + 6)]), t0: t0) {
            var f = start.fit
            kept = start.kept
            var i = min(s.count, jm + 6)
            func fits(_ x: KitBallSample, _ f: Fit) -> Bool { (x.p - f.position(x.t)).length <= max(gate, 4 * f.rms) }
            while i < s.count {
                if fits(s[i], f) { kept.append(s[i]); i += 1 }
                else if i + 1 < s.count && fits(s[i + 1], f) { i += 1; continue }
                else { break }
                if let g = Fit.fit(kept[...], t0: t0) { f = g }
            }
            // samples at the end that the whole flight's fit does not take (the first moment of the next bounce)
            while kept.count > 3, let last = kept.last, (last.p - f.position(last.t)).length > max(0.006, 3 * f.rms) {
                kept.removeLast()
                if let g = Fit.fit(kept[...], t0: t0) { f = g }
            }
            post = f
        }
        guard var postFit = post else { return .failed("too few frames after the impact to fit the bounce") }
        // the lowest sample belongs to whichever fit it is nearer (if it is not far off both)
        var preEnd = jm, postStart = jm + 1
        let dPre = (s[jm].p - pre.position(s[jm].t)).length, dPost = (s[jm].p - postFit.position(s[jm].t)).length
        if min(dPre, dPost) <= gate {
            if dPre <= dPost { preEnd = jm + 1; preKept.append(s[jm]); if let f = Fit.fit(preKept[...], t0: t0) { pre = f } }
            else { postStart = jm; kept.insert(s[jm], at: 0); if let f = Fit.fit(kept[...], t0: t0) { postFit = f } }
        }
        let notes: [String] = []
        // impact: where the heights meet (the difference of two free falls is linear in time)
        let db = pre.b.y - postFit.b.y
        let ti: Double
        if abs(db) > 1e-6 {
            ti = t0 + (postFit.a.y - pre.a.y) / db
        } else {
            ti = (s[preEnd - 1].t + s[postStart].t) / 2
        }
        let lo = (preKept.last?.t ?? s[preEnd - 1].t) - 0.02, hi = (kept.first?.t ?? s[postStart].t) + 0.02
        guard ti >= lo && ti <= hi else {
            return .failed("the track does not hold together as a drop: the fall's and the bounce's fits do not meet between the frames around the impact")
        }
        let impact = (pre.position(ti) + postFit.position(ti)) / 2
        let vin = pre.velocity(ti), vout = postFit.velocity(ti)
        guard vin.lengthSquared > 1e-6 else { return .failed("the ball hardly moved before the impact") }
        let G = Units.gravity
        // the speed in must be the fall's: |v_in|² = 2 g x the fall height (from rest at the held height)
        let fall = held.y - impact.y, expected = 2 * G * fall
        guard fall > 0.02, abs(vin.lengthSquared - expected) <= 0.2 * expected else {
            return .failed(String(format: "the track does not hold together as a drop: the speed into the bounce (%.2f m/s) does not match a fall of %.0f mm",
                                  vin.length, fall * 1000))
        }
        let rebound = vout.lengthSquared / vin.lengthSquared
        guard rebound >= 0, rebound <= 1.1 else {
            return .failed(String(format: "the track does not hold together as a drop: it gives a rebound of %.0f%%", rebound * 100))
        }
        let tr = pre.t0 + pre.b.y / G
        // apex and landing, from the post-impact fit
        let ta = postFit.t0 + postFit.b.y / G
        let apexT = max(ti, ta)
        let apex = postFit.position(apexT)
        let tl = ta > ti ? 2 * ta - ti : ti
        let landing = postFit.position(tl)
        let up = Vec3(0, 1, 0)
        let landDist = (landing - impact).rejecting(up).length
        let lastPost = kept.last?.t ?? s[postStart].t
        let extrapolation = max(0, tl - lastPost)
        guard extrapolation <= 0.5 * (tl - ti) else {
            return .failed(String(format: "the bounce was seen for too little of its flight: %.0f%% of it is extrapolated",
                                  100 * extrapolation / max(1e-9, tl - ti)))
        }
        var a = KitBounceAnalysis(held: held, releaseTime: tr, impactTime: ti, impactPoint: impact, velocityIn: vin, velocityOut: vout,
                                  rebound: rebound, fallHeight: fall,
                                  apexHeight: apex.y - impact.y, apex: apex, landing: landing, landingDistance: landDist,
                                  landingExtrapolation: extrapolation, preSamples: preKept.count, postSamples: kept.count,
                                  preRms: pre.rms, postRms: postFit.rms, prediction: nil, landingError: nil, landingDistanceError: nil,
                                  apexError: nil, impactHeightError: nil, notes: notes)
        if let p = predict?(held) {
            a.prediction = p
            if !p.fromBall { a.notes.append("the held ball was not over the slab: the app predicted from its default drop height") }
            let pl = p.landing
            a.landingError = (pl - landing).rejecting(up).length
            a.landingDistanceError = (pl - p.start).rejecting(up).length - landDist
            a.apexError = p.apexHeight - a.apexHeight
            a.impactHeightError = p.start.dot(up) - impact.dot(up)
        }
        return .analyzed(a)
    }
}
