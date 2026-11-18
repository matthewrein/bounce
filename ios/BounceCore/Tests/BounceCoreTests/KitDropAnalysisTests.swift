import XCTest
@testable import BounceCore

/// The drop analysis on tracks made from the physical drops (`KitDropPhysics`), without rendering: centre and
/// off-centre hits on the dish, with the finder's noise (mostly along the line of sight), missed frames, wrong frames,
/// timestamp jitter, frames the recorder dropped, and the ball leaving the view.
final class KitDropAnalysisTests: XCTestCase {
    let maker = KitSyntheticDrops()

    struct Noise {
        /// per-axis Gaussian noise across the line of sight and along it (m)
        var across = 0.0
        var along = 0.0
        /// share of frames missed
        var miss = 0.0
        /// frames read wrong: their indices among the samples from the cue on, moved this far along the line of sight
        var wrong: [Int] = []
        var wrongBy = 0.04
        /// the track ends this long after the impact (nil: it runs to the end)
        var tail: Double? = nil
        var seed: UInt64 = 1
    }

    /// The ball's centre on each frame of a drop, as a finder would give it.
    func track(_ d: KitSyntheticDrops.Drop, _ n: Noise = Noise()) -> [KitBallSample] {
        var rng = SeededRandom(n.seed)
        var out: [KitBallSample] = []
        var k = 0
        for (i, f) in d.frames.enumerated() {
            if let tail = n.tail, f.time > d.truth.impactTime + tail { break }
            let p = d.physics.position(at: f.time)
            let sight = (p - d.views[i].position).normalized
            let a = sight.anyPerpendicular.normalized, b = sight.cross(a)
            var q = p + a * (rng.gaussian() * n.across) + b * (rng.gaussian() * n.across) + sight * (rng.gaussian() * n.along)
            if f.time >= d.truth.cue {
                if n.wrong.contains(k) { q = q + sight * n.wrongBy }
                k += 1
            }
            if f.time > d.truth.cue - 0.3 && rng.next() < n.miss { continue }
            out.append(KitBallSample(t: f.time, p: q, c: d.views[i].position))
        }
        return out
    }

    func context(_ d: KitSyntheticDrops.Drop) -> KitDropAnalysis.Context {
        var c = KitDropAnalysis.Context(slab: d.slab, dish: maker.dish)
        c.floorY = 0
        let settings = maker.settings
        c.appRebound = settings.ball.rebound
        c.predict = { held, rebound in
            var s = settings
            s.ball.rebound = rebound
            return KitBouncePrediction.app(pose: d.slab, settings: s, held: held)
        }
        return c
    }

    func horizontal(_ a: Vec3, _ b: Vec3) -> Double { (a - b).rejecting(Vec3(0, 1, 0)).length }

    func offsetError(_ a: KitDropAnalysis, _ t: KitDropTruth) -> Double {
        ((a.offsetU! - t.offsetU) * (a.offsetU! - t.offsetU) + (a.offsetV! - t.offsetV) * (a.offsetV! - t.offsetV)).squareRoot()
    }

    /// A perfect track (the true centre on every frame, at its own jittered timestamp) gives the truth back: the analysis
    /// itself adds next to nothing, for every drop of the set, centre and off-centre.
    func testAPerfectTrackGivesTheTruth() throws {
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            let r = KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: context(d))
            let a = try XCTUnwrap(r.analysis, "\(shot.id): \(r.reason ?? "")")
            let t = d.truth
            XCTAssertEqual(a.kind, .bounce, shot.id)
            XCTAssertEqual(try XCTUnwrap(a.rebound), t.rebound, accuracy: 0.002, shot.id)
            XCTAssertEqual(a.impactTime, t.impactTime, accuracy: 0.0005, shot.id)
            XCTAssertLessThan(a.impactCenter.distance(to: t.impactCenter), 0.0005, shot.id)
            XCTAssertLessThan(offsetError(a, t), 0.0005, shot.id)
            XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.005, shot.id)
            XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.001, shot.id)
            XCTAssertEqual(abs(try XCTUnwrap(a.impactClearance)), 0, accuracy: 0.0005, shot.id)
            XCTAssertEqual(a.landingLevelSource, "floor")
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), t.landing), 0.002, shot.id)
            if let k = t.tangentialRatio, shot.tilt >= 3 { XCTAssertEqual(try XCTUnwrap(a.tangentialRatio), k, accuracy: 0.01, shot.id) }
            XCTAssertEqual(abs(a.sideways ?? 0), 0, accuracy: 0.2, shot.id)
            // the comparisons are the truth's
            let app = try XCTUnwrap(a.app), tapp = try XCTUnwrap(t.app)
            XCTAssertEqual(app.landingError, tapp.landingError, accuracy: 0.003, shot.id)
            XCTAssertEqual(app.rangeError, tapp.rangeError, accuracy: 0.003, shot.id)
            XCTAssertEqual(app.directionError, tapp.directionError, accuracy: 0.1, shot.id)
            let mr = try XCTUnwrap(a.measuredRebound), tr = try XCTUnwrap(t.trueRebound)
            XCTAssertEqual(mr.landingError, tr.landingError, accuracy: 0.003, shot.id)
            XCTAssertEqual(mr.rebound, t.rebound, accuracy: 0.002, shot.id)
            XCTAssertEqual(a.appDropHeight ?? 0, Units.inches(shot.heightInches), accuracy: 0.004, shot.id)
        }
    }

    /// With the finder's noise (1 mm across the line of sight, 4 mm along it) every drop of the set is measured: the
    /// rebound within 4 points, the impact point on the dish within 6 mm, the local normal's tilt within 0.1°, the landing
    /// within 2.5 cm, and the comparisons with the app's prediction within 2.5 cm of the true ones.
    func testNoisyTracks() throws {
        var worst = (rebound: 0.0, offset: 0.0, landing: 0.0, app: 0.0)
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            for seed in UInt64(1)...3 {
                let r = KitDropAnalysis.analyze(track: track(d, Noise(across: 0.001, along: 0.004, seed: seed)), cue: d.truth.cue, context: context(d))
                let a = try XCTUnwrap(r.analysis, "\(shot.id) seed \(seed): \(r.reason ?? "")")
                let t = d.truth
                let eR = abs(try XCTUnwrap(a.rebound) - t.rebound), eO = offsetError(a, t)
                let eL = horizontal(try XCTUnwrap(a.landing), t.landing)
                let eA = abs(try XCTUnwrap(a.app).landingError - t.app!.landingError)
                worst = (max(worst.rebound, eR), max(worst.offset, eO), max(worst.landing, eL), max(worst.app, eA))
                XCTAssertLessThan(eR, 0.04, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eO, 0.006, "\(shot.id) seed \(seed)")
                XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.1, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eL, 0.025, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eA, 0.025, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(abs(try XCTUnwrap(a.measuredRebound).landingError - t.trueRebound!.landingError), 0.025, "\(shot.id) seed \(seed)")
                XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.006, "\(shot.id) seed \(seed)")
            }
        }
        print(String(format: "noisy tracks, worst: rebound %.1f points, impact %.1f mm, landing %.1f mm, against the app %.1f mm",
                     worst.rebound * 100, worst.offset * 1000, worst.landing * 1000, worst.app * 1000))
    }

    /// The finder's distance from the ball's size is centimetres off on a small ball (3 cm along the line of sight here,
    /// 1 mm across): weighing each sample's error along its line of sight less (the arc's curvature in the picture, with
    /// gravity known, gives the distance; the fall's horizontal velocity is taken as 0 ± 0.1 m/s), the rebound still
    /// comes within 4 points or 2.5 sigma (sigma under 6 points: a 6 in drop seen over 0.15 s), the contact point within
    /// 6 mm (slid along the line of sight onto the dish) and the landing within 5 cm.
    func testDistanceNoiseAlongTheLineOfSight() throws {
        var worst = (rebound: 0.0, offset: 0.0, landing: 0.0)
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            for seed in UInt64(1)...2 {
                let r = KitDropAnalysis.analyze(track: track(d, Noise(across: 0.001, along: 0.03, seed: seed)), cue: d.truth.cue, context: context(d))
                let a = try XCTUnwrap(r.analysis, "\(shot.id) seed \(seed): \(r.reason ?? "")")
                let eR = abs(try XCTUnwrap(a.rebound) - d.truth.rebound), eO = offsetError(a, d.truth)
                let eL = horizontal(try XCTUnwrap(a.landing), d.truth.landing)
                worst = (max(worst.rebound, eR), max(worst.offset, eO), max(worst.landing, eL))
                XCTAssertLessThan(eR, max(0.04, 2.5 * (a.reboundSigma ?? 0)), "\(shot.id) seed \(seed): sigma \(a.reboundSigma ?? 0)")
                XCTAssertLessThan(a.reboundSigma ?? 1, 0.06, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eO, 0.006, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eL, 0.05, "\(shot.id) seed \(seed)")
            }
        }
        print(String(format: "3 cm along the line of sight, worst: rebound %.1f points, impact %.1f mm, landing %.1f mm",
                     worst.rebound * 100, worst.offset * 1000, worst.landing * 1000))
    }

    /// The uncertainties are honest: over 30 noisy tracks of one off-centre drop, the rebound, the impact point and the
    /// landing are within 3 sigma of the truth at least 85% of the time (and sigma is not absurdly large).
    func testUncertainties() throws {
        let d = maker.make(KitDropShot.standardSet[2])
        var within = (rebound: 0, offset: 0, landing: 0), n = 0
        for seed in UInt64(1)...30 {
            let a = try XCTUnwrap(KitDropAnalysis.analyze(track: track(d, Noise(across: 0.0015, along: 0.0015, seed: seed)), cue: d.truth.cue,
                                                          context: context(d)).analysis)
            n += 1
            let sR = try XCTUnwrap(a.reboundSigma), sO = try XCTUnwrap(a.offsetSigma), sL = try XCTUnwrap(a.landingSigma)
            XCTAssertLessThan(sR, 0.03); XCTAssertLessThan(sO, 0.005); XCTAssertLessThan(sL, 0.02)
            if abs(a.rebound! - d.truth.rebound) <= 3 * sR { within.rebound += 1 }
            if offsetError(a, d.truth) <= 3 * sO * 1.5 { within.offset += 1 }   // two axes: 3 sigma of their root sum
            if horizontal(a.landing!, d.truth.landing) <= 3 * sL * 1.5 { within.landing += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(within.rebound) / Double(n), 0.85)
        XCTAssertGreaterThanOrEqual(Double(within.offset) / Double(n), 0.85)
        XCTAssertGreaterThanOrEqual(Double(within.landing) / Double(n), 0.85)
    }

    /// Real-footage problems at once on an off-centre drop: a third of the frames missed, wrong frames (4 cm along the
    /// line of sight) in the fall and two in a row in the rise, frames the recorder dropped (gaps in the timestamps), and
    /// the ball lost 0.2 s into its 0.45 s flight: still measured, the landing extrapolated and said so.
    func testMissesWrongFramesDroppedFramesAndAMissingTail() throws {
        var shot = KitDropShot.standardSet[2]
        shot.droppedFrames = [5, 12, 13, 30]
        shot.jitter = 0.001
        let d = maker.make(shot)
        let t = d.truth
        let rise = d.frames.filter { $0.time >= t.cue && $0.time <= t.impactTime }.count
        for seed in UInt64(1)...6 {
            let n = Noise(across: 0.001, along: 0.003, miss: 0.33, wrong: [rise / 2, rise + 3, rise + 4], tail: 0.2, seed: seed)
            let r = KitDropAnalysis.analyze(track: track(d, n), cue: t.cue, context: context(d))
            let a = try XCTUnwrap(r.analysis, "seed \(seed): \(r.reason ?? "")")
            XCTAssertEqual(try XCTUnwrap(a.rebound), t.rebound, accuracy: 0.06, "seed \(seed)")
            XCTAssertLessThan(offsetError(a, t), 0.015, "seed \(seed)")
            XCTAssertTrue(a.leftView, "seed \(seed)")
            XCTAssertGreaterThan(try XCTUnwrap(a.landingExtrapolation), 0.2, "seed \(seed)")
            XCTAssertTrue(a.notes.contains { $0.contains("the landing is extrapolated") }, "seed \(seed): \(a.notes)")
            let eL = horizontal(try XCTUnwrap(a.landing), t.landing)
            XCTAssertLessThan(eL, 0.06, "seed \(seed)")
            XCTAssertLessThan(eL, 4 * max(0.005, try XCTUnwrap(a.landingSigma)), "seed \(seed): sigma \(a.landingSigma ?? 0)")
        }
    }

    /// A low tilt and a lively ball: it comes down on the slab again. The analysis finds that next contact, on the
    /// slab, and carries the arc on to the floor's level for the landing.
    func testTwoBouncesOnTheSlab() throws {
        let d = maker.make(KitDropShot.standardSet[4])   // 2°, 0.85, 6.5 in out
        XCTAssertEqual(d.truth.nextContact?.surface, .slab, "the drop comes down on the slab")
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: track(d, Noise(across: 0.001, along: 0.002)), cue: d.truth.cue,
                                                      context: context(d)).analysis)
        let next = try XCTUnwrap(a.nextContact)
        XCTAssertEqual(next.surface, .slab)
        XCTAssertEqual(next.time, d.truth.nextContact!.time, accuracy: 0.01)
        XCTAssertTrue(a.notes.contains { $0.contains("came down on the slab") }, "\(a.notes)")
        XCTAssertEqual(a.rebound ?? 0, 0.85, accuracy: 0.03)
    }

    /// Without the floor (a kit has none) the landing level is where the ball came down next when that is clearly lower
    /// than the impact (the floor, seen), else 0.1 m below the impact.
    func testLandingLevelWithoutTheFloor() throws {
        let d = maker.make(KitDropShot.standardSet[2])   // flies off the slab onto the floor
        var c = context(d)
        c.floorY = nil
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: c).analysis)
        XCTAssertEqual(a.landingLevelSource, "next bounce")
        XCTAssertEqual(a.landingLevel, 0.0175, accuracy: 0.003, "the floor's bounce, seen")
        let cut = KitSyntheticDrops.perfectTrack(d).filter { $0.t < d.truth.impactTime + 0.2 }
        let b = try XCTUnwrap(KitDropAnalysis.analyze(track: cut, cue: d.truth.cue, context: c).analysis)
        XCTAssertEqual(b.landingLevelSource, "fixed")
        XCTAssertEqual(b.landingLevel, b.impactCenter.y - 0.1, accuracy: 1e-9)
        XCTAssertTrue(b.leftView)
    }

    /// The ball not seen held (the hand hid it): the release comes from the fall, and says so.
    func testWithoutTheHeldBall() throws {
        let d = maker.make(KitDropShot.standardSet[1])
        let late = KitSyntheticDrops.perfectTrack(d).filter { $0.t > d.truth.release + 0.04 }
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: late, cue: d.truth.cue, context: context(d)).analysis)
        XCTAssertFalse(a.heldSeen)
        XCTAssertTrue(a.notes.contains { $0.contains("not seen held") })
        XCTAssertEqual(a.dropHeight, d.truth.dropHeight, accuracy: 0.003)
        XCTAssertEqual(a.releaseTime, d.truth.release, accuracy: 0.003)
        XCTAssertEqual(a.rebound ?? 0, d.truth.rebound, accuracy: 0.005)
    }

    /// A ball that hardly bounces (rebound 0.002) stays on the slab: measured as rolled, with no rebound.
    func testABallThatDoesNotBounce() throws {
        var shot = KitDropShot.standardSet[0]
        shot.rebound = 0.002
        let d = maker.make(shot)
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: context(d)).analysis)
        XCTAssertEqual(a.kind, .rolled)
        XCTAssertNil(a.rebound)
        XCTAssertEqual(a.impactTime, d.truth.impactTime, accuracy: 0.002)
        XCTAssertLessThan(offsetError(a, d.truth), 0.003)
        XCTAssertNil(KitDropAnalysis.reboundToBake([a]))
    }

    /// Spin from a sloppy release (30 rad/s about the downhill direction): the bounce leaves out of the plane of
    /// incidence, reported; the rebound (about the normal) is unchanged.
    func testSidewaysFromSpin() throws {
        var shot = KitDropShot.standardSet[0]
        let hd = Units.radians(shot.heading)
        shot.releaseSpin = Vec3(cos(hd), 0, sin(hd)) * 30
        let d = maker.make(shot)
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: context(d)).analysis)
        XCTAssertGreaterThan(abs(a.sideways ?? 0), 3)
        XCTAssertTrue(a.notes.contains { $0.contains("out of the plane of incidence") }, "\(a.notes)")
        XCTAssertEqual(a.rebound ?? 0, d.truth.rebound, accuracy: 0.005)
    }

    func testSaysWhyWhenItCannot() {
        let d = maker.make(KitDropShot.standardSet[0])
        let tr = KitSyntheticDrops.perfectTrack(d)
        let c = context(d)
        XCTAssertEqual(KitDropAnalysis.analyze(track: Array(tr.prefix(5)), cue: d.truth.cue, context: c).reason, "the ball was seen on only 5 frames")
        let still = tr.filter { $0.t <= d.truth.release }
        XCTAssertEqual(KitDropAnalysis.analyze(track: still, cue: d.truth.cue, context: c).reason, "the ball did not fall after the release cue")
        // lost at the impact: no bounce, and nothing after it to say it stayed on the slab
        let cut = tr.filter { $0.t <= d.truth.impactTime }
        XCTAssertEqual(KitDropAnalysis.analyze(track: cut, cue: d.truth.cue, context: c).reason, "no bounce found: the ball was not seen rising after its fall")
        // without a lock: measured on a level surface, said so, no offset
        var nolock = c
        nolock.slab = nil
        let a = KitDropAnalysis.analyze(track: tr, cue: d.truth.cue, context: nolock).analysis
        XCTAssertNotNil(a)
        XCTAssertNil(a?.offsetU)
        XCTAssertTrue(a?.notes.contains { $0.contains("no lock") } ?? false)
    }

    func testReboundToBake() throws {
        func drop(_ r: Double, _ s: Double) -> KitDropAnalysis {
            var a = KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(maker.make(KitDropShot.standardSet[0])),
                                            cue: maker.make(KitDropShot.standardSet[0]).truth.cue, context: KitDropAnalysis.Context()).analysis!
            a.rebound = r; a.reboundSigma = s
            return a
        }
        let b = try XCTUnwrap(KitDropAnalysis.reboundToBake([drop(0.70, 0.01), drop(0.72, 0.02), drop(0.69, 0.01), drop(0.40, 0.01)]))
        XCTAssertEqual(b.count, 3, "the one far from the others is left out")
        let num: Double = 0.70 / 1e-4 + 0.72 / 4e-4 + 0.69 / 1e-4, den: Double = 1 / 1e-4 + 1 / 4e-4 + 1 / 1e-4
        XCTAssertEqual(b.rebound, num / den, accuracy: 1e-9)
        XCTAssertEqual(KitDropAnalysis.bakeLine([drop(0.70, 0.01), drop(0.72, 0.02)]), "rebound to bake into the app: 70% ± 1% (from 2 drops)")
        XCTAssertEqual(KitDropAnalysis.bakeLine([]), "rebound to bake into the app: none (no bounce measured)")
    }
}
