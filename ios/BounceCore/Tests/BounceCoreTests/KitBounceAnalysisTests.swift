import XCTest
@testable import BounceCore

/// The bounce analysis on analytic trajectories (no rendering).
final class KitBounceAnalysisTests: XCTestCase {
    struct Drop {
        var track: [KitBallSample]
        var held: Vec3
        var cue: Double
        var release: Double
        var impactTime: Double
        var impact: Vec3
        var vin: Vec3
        var vout: Vec3
        var landing: Vec3
        var apexHeight: Double
    }

    /// A ball held over a slab tilted 10°, let go 0.13 s after the cue, bouncing off along the corner plane's normal at
    /// `rebound` (the app's model), then off the floor; sampled at `fps` with Gaussian noise `noise` (m) per axis, seen
    /// only from `visibleFrom` before the cue.
    func drop(rebound: Double = 0.7, noise: Double = 0.0015, fps: Double = 60, seed: UInt64 = 5, slab: SlabPose? = nil) -> Drop {
        let s = slab ?? SyntheticScene.slabPose(tilt: 10, heading: 35)
        let R = 0.0175, G = Units.gravity, up = Vec3(0, 1, 0), g = Vec3(0, -G, 0)
        let held = s.center - s.normal * Units.inches(0.125) + up * (R + 0.3)
        let d = Bounce.drop(ballCenter: held, pose: s, spec: .standard, ball: BallSpec(), down: ARKitConvention.worldDown)!
        let cue = 50.0, release = cue + 0.13
        let tf = (2 * d.dropHeight / G).squareRoot(), ti = release + tf
        let impact = held - up * d.dropHeight, vin = g * tf
        let vout = s.normal * (rebound.squareRoot() * vin.length)
        let tl = 2 * vout.y / G
        let landing = impact + Vec3(vout.x, 0, vout.z) * tl
        // the floor: centre at R
        let tFloor = (vout.y + (vout.y * vout.y + 2 * G * (impact.y - R)).squareRoot()) / G
        var rng = SeededRandom(seed)
        var track: [KitBallSample] = []
        var t = cue - 1.0
        while t < ti + tFloor + 0.4 {
            var p: Vec3
            if t <= release { p = held }
            else if t <= ti { let u = t - release; p = held + g * (0.5 * u * u) }
            else if t <= ti + tFloor { let u = t - ti; p = impact + vout * u + g * (0.5 * u * u) }
            else {
                // the floor bounce: half the vertical speed, most of the horizontal
                let u = t - ti - tFloor, vf = vout + g * tFloor
                let p0 = impact + vout * tFloor + g * (0.5 * tFloor * tFloor)
                let v1 = Vec3(vf.x * 0.8, -vf.y * 0.5, vf.z * 0.8)
                p = p0 + v1 * u + g * (0.5 * u * u)
                p.y = max(p.y, R)
            }
            p = p + Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * noise
            track.append(KitBallSample(t: t, p: p))
            t += 1 / fps
        }
        return Drop(track: track, held: held, cue: cue, release: release, impactTime: ti, impact: impact, vin: vin, vout: vout,
                    landing: landing, apexHeight: vout.y * vout.y / (2 * G))
    }

    func horizontal(_ a: Vec3, _ b: Vec3) -> Double { (a - b).rejecting(Vec3(0, 1, 0)).length }

    func testRecoversTheLandingWithinACentimetre() throws {
        for seed in UInt64(1)...30 {
            let d = drop(seed: seed)
            let a = try XCTUnwrap(KitBounceAnalysis.analyze(track: d.track, cue: d.cue).analysis, "seed \(seed)")
            XCTAssertLessThan(horizontal(a.landing, d.landing), 0.01, "seed \(seed): landing within 1 cm")
            XCTAssertLessThan(a.impactPoint.distance(to: d.impact), 0.006, "seed \(seed): impact point")
            XCTAssertEqual(a.impactTime, d.impactTime, accuracy: 1.0 / 60, "seed \(seed)")
            XCTAssertEqual(a.releaseTime, d.release, accuracy: 0.03, "seed \(seed)")
            XCTAssertEqual(a.rebound, 0.7, accuracy: 0.06, "seed \(seed)")
            XCTAssertEqual(a.apexHeight, d.apexHeight, accuracy: 0.006, "seed \(seed)")
            XCTAssertEqual(a.landingDistance, horizontal(d.landing, d.impact), accuracy: 0.01)
            XCTAssertEqual(a.fallHeight, d.held.y - d.impact.y, accuracy: 0.004)
            XCTAssertGreaterThanOrEqual(a.postSamples, 10)
            XCTAssertLessThan(a.preRms, 0.004); XCTAssertLessThan(a.postRms, 0.004)
            XCTAssertNil(a.prediction)
        }
    }

    /// Frames whose ball was read wrong (a size from the wrong half of the outline puts it a few centimetres off along
    /// the line of sight) do not stop the analysis or bend it: every seventh sample 3 cm low, a run of three samples
    /// 16 mm low while the ball is held, and the sample just after the impact 3 cm low. The landing still comes back
    /// within 1.5 cm, the apex within 1 cm and the rebound within 0.06. (Before the smoothed heights and the robust fits
    /// the run while held was taken for the fall, or a low sample for the impact, and the drop was refused.)
    func testWrongFramesAreLeftOut() throws {
        for seed in UInt64(1)...10 {
            let d = drop(seed: seed)
            var track = d.track
            let h = try XCTUnwrap(track.firstIndex { $0.t > d.cue - 0.2 })
            for k in 0..<3 { track[h + k].p.y -= 0.016 }
            for i in stride(from: h + 6, to: track.count, by: 7) { track[i].p.y -= 0.03 }
            let j = try XCTUnwrap(track.firstIndex { $0.t > d.impactTime })
            track[j].p.y -= 0.03
            let r = KitBounceAnalysis.analyze(track: track, cue: d.cue)
            let a = try XCTUnwrap(r.analysis, "seed \(seed): \(r.reason ?? "")")
            XCTAssertLessThan(horizontal(a.landing, d.landing), 0.015, "seed \(seed): landing")
            XCTAssertEqual(a.apexHeight, d.apexHeight, accuracy: 0.01, "seed \(seed)")
            XCTAssertEqual(a.rebound, 0.7, accuracy: 0.06, "seed \(seed)")
            XCTAssertEqual(a.releaseTime, d.release, accuracy: 0.03, "seed \(seed)")
        }
    }

    /// Against the app's prediction from the true slab: a perfect track and the model it follows agree (the rule the app
    /// ran until n11, the corner plane at a 70% rebound, which these analytic drops follow); a ball that rebounds less
    /// than the settings say lands short of the prediction, with a lower apex.
    func testComparesWithTheAppsPrediction() throws {
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35)
        let settings = RecordingSettings(reboundPercent: 70, restitution: nil, tangential: nil).trackerSettings
        XCTAssertEqual(settings.launchRule, .cornerPlane)
        let predict: (Vec3) -> KitBouncePrediction? = { KitBouncePrediction.app(pose: slab, settings: settings, held: $0) }
        let same = drop(noise: 0.0005, slab: slab)
        let a = try XCTUnwrap(KitBounceAnalysis.analyze(track: same.track, cue: same.cue, predict: predict).analysis)
        let p = try XCTUnwrap(a.prediction)
        XCTAssertTrue(p.fromBall)
        XCTAssertLessThan(try XCTUnwrap(a.landingError), 0.006)
        XCTAssertLessThan(abs(try XCTUnwrap(a.apexError)), 0.004)
        XCTAssertLessThan(abs(try XCTUnwrap(a.impactHeightError)), 0.004)
        XCTAssertEqual(p.dropHeight, 0.3, accuracy: 0.003)

        // a lock 10 mm too high shows in the launch height (its horizontal position, straight below the held ball, is
        // the same whatever the lock)
        var high = slab
        high.center = high.center + Vec3(0, 0.01, 0)
        let predictHigh: (Vec3) -> KitBouncePrediction? = { KitBouncePrediction.app(pose: high, settings: settings, held: $0) }
        let h = try XCTUnwrap(KitBounceAnalysis.analyze(track: same.track, cue: same.cue, predict: predictHigh).analysis)
        XCTAssertEqual(try XCTUnwrap(h.impactHeightError), 0.01, accuracy: 0.004)
        XCTAssertLessThan(horizontal(try XCTUnwrap(h.prediction).start, h.impactPoint), 0.004)

        let weak = drop(rebound: 0.45, noise: 0.0005, slab: slab)
        let b = try XCTUnwrap(KitBounceAnalysis.analyze(track: weak.track, cue: weak.cue, predict: predict).analysis)
        XCTAssertEqual(b.rebound, 0.45, accuracy: 0.05)
        XCTAssertGreaterThan(try XCTUnwrap(b.landingError), 0.03, "it lands well short of the prediction")
        XCTAssertGreaterThan(try XCTUnwrap(b.landingDistanceError), 0.03)
        XCTAssertGreaterThan(try XCTUnwrap(b.apexError), 0.03, "the predicted apex is higher")
    }

    func testSaysWhyWhenItCannot() {
        let d = drop()
        XCTAssertEqual(KitBounceAnalysis.analyze(track: Array(d.track.prefix(5)), cue: d.cue).reason, "the ball was seen on only 5 frames")
        // nothing held before the cue
        let late = d.track.filter { $0.t > d.cue + 0.1 }
        XCTAssertEqual(KitBounceAnalysis.analyze(track: late, cue: d.cue).reason, "the ball was not seen held before the release cue")
        // held, never let go
        let still = d.track.filter { $0.t <= d.release }.map { KitBallSample(t: $0.t + 1, p: d.held) } + d.track.filter { $0.t <= d.release }
        XCTAssertEqual(KitBounceAnalysis.analyze(track: still, cue: d.cue).reason, "the ball did not fall after the release cue")
        // the track stops at the impact
        let cut = d.track.filter { $0.t <= d.impactTime }
        XCTAssertEqual(KitBounceAnalysis.analyze(track: cut, cue: d.cue).reason, "no bounce found: the ball was not seen rising after its fall")
        // non-finite samples are dropped, not fatal
        var bad = d.track
        bad[10].p = Vec3(.nan, 0, 0)
        XCTAssertNotNil(KitBounceAnalysis.analyze(track: bad, cue: d.cue).analysis)
    }

    /// A track that does not hold together as a drop gives no numbers: a fall too slow for its height, a bounce that
    /// gains speed, a flight seen too briefly, and the stateful app locator's track (a missed ball held over for two
    /// frames, positions smoothed by half) are all refused with the reason.
    func testRefusesATrackThatIsNotADrop() throws {
        let d = drop(noise: 0.0005)
        // the fall slowed to 70% of its speed (positions of the fall at 0.7 of their time)
        let slow = d.track.map { x -> KitBallSample in
            guard x.t > d.release && x.t <= d.impactTime else { return x }
            let u = (x.t - d.release) * 0.7
            return KitBallSample(t: x.t, p: d.held + Vec3(0, -Units.gravity, 0) * (0.5 * u * u))
        }
        XCTAssertNil(KitBounceAnalysis.analyze(track: slow, cue: d.cue).analysis)
        // a bounce that leaves faster than it came (a rebound of about 1.3)
        let fast = d.track.map { x -> KitBallSample in
            guard x.t > d.impactTime else { return x }
            let u = x.t - d.impactTime
            return KitBallSample(t: x.t, p: d.impact + d.vout * (1.4 * u) + Vec3(0, -Units.gravity, 0) * (0.5 * u * u))
        }
        let rf = KitBounceAnalysis.analyze(track: fast, cue: d.cue)
        XCTAssertNil(rf.analysis, "rebound \(rf.analysis?.rebound ?? 0)")
        XCTAssertTrue(rf.reason?.hasPrefix("the track does not hold together as a drop") ?? false, rf.reason ?? "")
        // the bounce seen for its first 0.1 s only
        let brief = d.track.filter { $0.t <= d.impactTime + 0.1 }
        let rb = KitBounceAnalysis.analyze(track: brief, cue: d.cue)
        XCTAssertTrue(rb.reason?.hasPrefix("the bounce was seen for too little of its flight") ?? false, rb.reason ?? "analysed")
        // the app's locator: each find held over for two frames, positions smoothed by half
        var held: [KitBallSample] = []
        var last = d.track[0].p
        for (i, x) in d.track.enumerated() {
            if i % 3 == 0 { last = last + (x.p - last) * 0.5 }
            held.append(KitBallSample(t: x.t, p: last))
        }
        let rh = KitBounceAnalysis.analyze(track: held, cue: d.cue)
        XCTAssertNil(rh.analysis, "rebound \(rh.analysis?.rebound ?? 0), v_in \(rh.analysis?.velocityIn.length ?? 0)")
    }

    func testThePredictionsLandingIsAtItsStartHeight() {
        let p = KitBouncePrediction(start: Vec3(0, 0.1, 0), velocity: Vec3(1, 2, 0), dropHeight: 0.3, fromBall: true, apexHeight: 4 / (2 * Units.gravity))
        let T = 4 / Units.gravity
        XCTAssertEqual(p.landing.x, T, accuracy: 1e-12)
        XCTAssertEqual(p.landing.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(KitBouncePrediction(start: .zero, velocity: Vec3(1, -1, 0), dropHeight: 0, fromBall: false, apexHeight: 0).landing, .zero)
    }
}
