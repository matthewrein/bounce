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

    /// Against the app's prediction from the true slab: a perfect track and the app's own model agree; a ball that
    /// rebounds less than the settings say lands short of the prediction, with a lower apex.
    func testComparesWithTheAppsPrediction() throws {
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35)
        let settings = RecordingSettings().trackerSettings
        let predict: (Vec3) -> KitBouncePrediction? = { KitBouncePrediction.app(pose: slab, settings: settings, held: $0) }
        let same = drop(noise: 0.0005, slab: slab)
        let a = try XCTUnwrap(KitBounceAnalysis.analyze(track: same.track, cue: same.cue, predict: predict).analysis)
        let p = try XCTUnwrap(a.prediction)
        XCTAssertTrue(p.fromBall)
        XCTAssertLessThan(try XCTUnwrap(a.landingError), 0.006)
        XCTAssertLessThan(abs(try XCTUnwrap(a.apexError)), 0.004)
        XCTAssertLessThan(try XCTUnwrap(a.impactPointError), 0.004)
        XCTAssertEqual(p.dropHeight, 0.3, accuracy: 0.003)

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

    func testThePredictionsLandingIsAtItsStartHeight() {
        let p = KitBouncePrediction(start: Vec3(0, 0.1, 0), velocity: Vec3(1, 2, 0), dropHeight: 0.3, fromBall: true, apexHeight: 4 / (2 * Units.gravity))
        let T = 4 / Units.gravity
        XCTAssertEqual(p.landing.x, T, accuracy: 1e-12)
        XCTAssertEqual(p.landing.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(KitBouncePrediction(start: .zero, velocity: Vec3(1, -1, 0), dropHeight: 0, fromBall: false, apexHeight: 0).landing, .zero)
    }
}
