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
        /// the held ball: the hand's velocity before the release (a hand that sinks while it waits), its own noise across
        /// and along the line of sight (nil: as the moving ball's) and an offset along the line of sight (its size read off)
        var drift = Vec3.zero
        var heldAcross: Double? = nil
        var heldAlong: Double? = nil
        var heldAlongOffset = 0.0
        /// share of the fall's frames missed (nil: `miss`)
        var missFall: Double? = nil
        /// offsets along the line of sight through the whole fall and the whole bounce (a finder whose distance is off by
        /// a few centimetres on each)
        var alongOffsetFall = 0.0
        var alongOffsetRise = 0.0
        /// nothing seen before this long after the release (nil: from the start)
        var startAfter: Double? = nil
        /// after the track ends (`tail`): one stray detection this long after, this far off the ball
        var stray: (after: Double, offset: Vec3)? = nil
    }

    /// The ball's centre on each frame of a drop, as a finder would give it.
    func track(_ d: KitSyntheticDrops.Drop, _ n: Noise = Noise()) -> [KitBallSample] {
        var rng = SeededRandom(n.seed)
        var out: [KitBallSample] = []
        var k = 0
        let t = d.truth
        for (i, f) in d.frames.enumerated() {
            if let tail = n.tail, f.time > t.impactTime + tail {
                if let st = n.stray, let last = out.last?.t,
                   let fs = d.frames.enumerated().first(where: { $0.element.time > last + st.after }) {
                    out.append(KitBallSample(t: fs.element.time, p: d.physics.position(at: fs.element.time) + st.offset, c: d.views[fs.offset].position))
                }
                break
            }
            let held = f.time < t.release
            var p = d.physics.position(at: f.time)
            if held { p = p + n.drift * (f.time - t.release) }
            let sight = (p - d.views[i].position).normalized
            let a = sight.anyPerpendicular.normalized, b = sight.cross(a)
            let ac = held ? (n.heldAcross ?? n.across) : n.across, al = held ? (n.heldAlong ?? n.along) : n.along
            let off = held ? n.heldAlongOffset : f.time < t.impactTime ? n.alongOffsetFall : n.alongOffsetRise
            var q = p + a * (rng.gaussian() * ac) + b * (rng.gaussian() * ac) + sight * (rng.gaussian() * al + off)
            if f.time >= t.cue {
                if n.wrong.contains(k) { q = q + sight * n.wrongBy }
                k += 1
            }
            let inFall = f.time >= t.release && f.time <= t.impactTime
            if f.time > t.cue - 0.3 && rng.next() < (inFall ? (n.missFall ?? n.miss) : n.miss) { continue }
            if let sa = n.startAfter, f.time < t.release + sa { continue }
            out.append(KitBallSample(t: f.time, p: q, c: d.views[i].position))
        }
        return out
    }

    /// The truth compared at an analysis's own landing level.
    func truth(_ d: KitSyntheticDrops.Drop, _ a: KitDropAnalysis) throws -> KitDropLevelTruth {
        try XCTUnwrap(maker.truth(d, level: a.landingLevel), d.shot.id)
    }

    /// |error| / sigma, the sigma at least `floor`.
    func z(_ e: Double, _ s: Double?, floor: Double = 1e-9) -> Double { abs(e) / max(floor, s ?? 0) }

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
    /// itself adds next to nothing, for every drop of the set, centre and off-centre (up to 3.3 in out on the 7 in top,
    /// where the dish leans 3.9°), with ARKit's floor (the phone) and without it (a kit); the drop within a radius of the
    /// edge is measured but left out of the rebound to bake. The landing is where the ball came down on the slab again
    /// when it did (the real landing; the arc carried on to the app's end level as well), else on the floor (known, or
    /// seen), else at the lock's lowest top corner; each is compared with the truth at that level.
    func testAPerfectTrackGivesTheTruth() throws {
        for floor in [true, false] {
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            var c = context(d)
            if !floor { c.floorY = nil }
            let r = KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: c)
            let a = try XCTUnwrap(r.analysis, "\(shot.id): \(r.reason ?? "")")
            let t = d.truth, lt = try truth(d, a)
            XCTAssertEqual(a.kind, .bounce, shot.id)
            XCTAssertEqual(try XCTUnwrap(a.rebound), t.rebound, accuracy: 0.002, shot.id)
            XCTAssertEqual(a.impactTime, t.impactTime, accuracy: 0.0005, shot.id)
            XCTAssertLessThan(a.impactCenter.distance(to: t.impactCenter), 0.0005, shot.id)
            XCTAssertLessThan(offsetError(a, t), 0.0005, shot.id)
            XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.005, shot.id)
            XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.001, shot.id)
            XCTAssertEqual(abs(try XCTUnwrap(a.impactClearance)), 0, accuracy: 0.0005, shot.id)
            if shot.id.contains("edge") {
                XCTAssertTrue(a.bakeExcluded?.contains("the slab's edge") ?? false, "\(shot.id): \(a.bakeExcluded ?? "baked")")
            } else {
                XCTAssertNil(a.bakeExcluded, shot.id)
            }
            if let nc = t.nextContact, nc.surface == .slab {
                XCTAssertEqual(a.landingLevelSource, "slab", shot.id)
                XCTAssertEqual(a.landingLevel, nc.center.y, accuracy: 0.002, shot.id)
                XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), nc.center), 0.005, "\(shot.id): the second contact on the slab")
                let co = try XCTUnwrap(a.carriedOn, shot.id)
                XCTAssertEqual(co.levelSource, floor ? "floor" : "lowest corner", shot.id)
                let et = try XCTUnwrap(maker.truth(d, level: co.level), shot.id)
                XCTAssertLessThan(horizontal(co.landing, et.landing), 0.002, shot.id)
                XCTAssertEqual(try XCTUnwrap(co.app).landingError, try XCTUnwrap(et.app).landingError, accuracy: 0.003, shot.id)
            } else {
                XCTAssertNil(a.carriedOn, shot.id)
                if floor { XCTAssertEqual(a.landingLevelSource, "floor", shot.id) }
                else { XCTAssertTrue(["next bounce", "lowest corner"].contains(a.landingLevelSource), "\(shot.id): \(a.landingLevelSource)") }
            }
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), lt.landing), 0.002, shot.id)
            if let k = t.tangentialRatio, shot.tilt >= 3 { XCTAssertEqual(try XCTUnwrap(a.tangentialRatio), k, accuracy: 0.01, shot.id) }
            XCTAssertEqual(abs(a.sideways ?? 0), 0, accuracy: 0.2, shot.id)
            // the comparisons are the truth's
            let app = try XCTUnwrap(a.app), tapp = try XCTUnwrap(lt.app)
            XCTAssertEqual(app.landingError, tapp.landingError, accuracy: 0.003, shot.id)
            XCTAssertEqual(app.rangeError, tapp.rangeError, accuracy: 0.003, shot.id)
            XCTAssertEqual(app.directionError, tapp.directionError, accuracy: 0.1, shot.id)
            let mr = try XCTUnwrap(a.measuredRebound), tr = try XCTUnwrap(lt.trueRebound)
            XCTAssertEqual(mr.landingError, tr.landingError, accuracy: 0.003, shot.id)
            XCTAssertEqual(mr.rebound, t.rebound, accuracy: 0.002, shot.id)
            XCTAssertEqual(a.appDropHeight ?? 0, Units.inches(shot.heightInches), accuracy: 0.004, shot.id)
        }
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
                let t = d.truth, lt = try truth(d, a)
                let eR = abs(try XCTUnwrap(a.rebound) - t.rebound), eO = offsetError(a, t)
                let eL = horizontal(try XCTUnwrap(a.landing), lt.landing)
                let eA = abs(try XCTUnwrap(a.app).landingError - lt.app!.landingError)
                worst = (max(worst.rebound, eR), max(worst.offset, eO), max(worst.landing, eL), max(worst.app, eA))
                XCTAssertLessThan(eR, 0.04, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eO, 0.006, "\(shot.id) seed \(seed)")
                XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.1, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eL, 0.025, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(eA, 0.025, "\(shot.id) seed \(seed)")
                XCTAssertLessThan(abs(try XCTUnwrap(a.measuredRebound).landingError - lt.trueRebound!.landingError), 0.025, "\(shot.id) seed \(seed)")
                XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.006, "\(shot.id) seed \(seed)")
            }
        }
        print(String(format: "noisy tracks, worst: rebound %.1f points, impact %.1f mm, landing %.1f mm, against the app %.1f mm",
                     worst.rebound * 100, worst.offset * 1000, worst.landing * 1000, worst.app * 1000))
    }

    /// The finder's distance from the ball's size is centimetres off on a small ball (3 cm along the line of sight here,
    /// 1 mm across): weighing each sample's error along its line of sight less (the arc's curvature in the picture, with
    /// gravity known, gives the distance; the fall's horizontal velocity is taken as 0 ± 0.1 m/s), the rebound still
    /// comes within 4 points or 2.5 sigma (sigma under 10 points: a 6 in drop seen over 0.15 s), the contact point within
    /// 6 mm (slid along the line of sight onto the dish) and the landing within 5 cm.
    func testDistanceNoiseAlongTheLineOfSight() throws {
        var worst = (rebound: 0.0, offset: 0.0, landing: 0.0)
        for shot in KitDropShot.standardSet {
            let d = maker.make(shot)
            for seed in UInt64(1)...2 {
                let r = KitDropAnalysis.analyze(track: track(d, Noise(across: 0.001, along: 0.03, seed: seed)), cue: d.truth.cue, context: context(d))
                let a = try XCTUnwrap(r.analysis, "\(shot.id) seed \(seed): \(r.reason ?? "")")
                let eR = abs(try XCTUnwrap(a.rebound) - d.truth.rebound), eO = offsetError(a, d.truth)
                let eL = horizontal(try XCTUnwrap(a.landing), try truth(d, a).landing)
                worst = (max(worst.rebound, eR), max(worst.offset, eO), max(worst.landing, eL))
                XCTAssertLessThan(eR, max(0.04, 2.5 * (a.reboundSigma ?? 0)), "\(shot.id) seed \(seed): sigma \(a.reboundSigma ?? 0)")
                XCTAssertLessThan(a.reboundSigma ?? 1, 0.1, "\(shot.id) seed \(seed)")
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
            if horizontal(a.landing!, try truth(d, a).landing) <= 3 * sL * 1.5 { within.landing += 1 }
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
            let eL = horizontal(try XCTUnwrap(a.landing), try truth(d, a).landing)
            XCTAssertLessThan(eL, 0.06, "seed \(seed)")
            XCTAssertLessThan(eL, 4 * max(0.005, try XCTUnwrap(a.landingSigma)), "seed \(seed): sigma \(a.landingSigma ?? 0)")
        }
    }

    /// A low tilt and a lively ball: it comes down on the slab again. The analysis finds that next contact, on the
    /// slab, and lands the bounce there (the real landing, compared with the app's arc at that height), with the arc
    /// carried on to the app's own end level as well (the floor here; a kit's lowest top corner).
    func testTwoBouncesOnTheSlab() throws {
        let d = maker.make(KitDropShot.standardSet[4])   // 2°, 0.85, 3 in out
        let nc = try XCTUnwrap(d.truth.nextContact)
        XCTAssertEqual(nc.surface, .slab, "the drop comes down on the slab")
        for floor in [true, false] {
            var c = context(d)
            if !floor { c.floorY = nil }
            let a = try XCTUnwrap(KitDropAnalysis.analyze(track: track(d, Noise(across: 0.001, along: 0.002)), cue: d.truth.cue, context: c).analysis)
            let next = try XCTUnwrap(a.nextContact)
            XCTAssertEqual(next.surface, .slab)
            XCTAssertEqual(next.time, nc.time, accuracy: 0.01)
            XCTAssertEqual(a.landingLevelSource, "slab")
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), nc.center), 0.01)
            XCTAssertEqual(try XCTUnwrap(a.app).landingError, try XCTUnwrap(try truth(d, a).app).landingError, accuracy: 0.01)
            let co = try XCTUnwrap(a.carriedOn)
            XCTAssertEqual(co.levelSource, floor ? "floor" : "lowest corner")
            XCTAssertEqual(try XCTUnwrap(co.app).landingError, try XCTUnwrap(maker.truth(d, level: co.level)?.app).landingError, accuracy: 0.015)
            XCTAssertTrue(a.notes.contains { $0.contains("came down on the slab again") }, "\(a.notes)")
            XCTAssertFalse(a.leftView)
            XCTAssertEqual(a.rebound ?? 0, 0.85, accuracy: 0.03)
        }
        let md = KitDropAnalysis.markdownTable([("d05", try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d),
                                                                                             cue: d.truth.cue, context: context(d)).analysis))])
        XCTAssertTrue(md.contains("landed on the slab again (compared there); carried on to the floor"), md)
    }

    /// Without the floor (a kit has none) the landing level is where the ball came down next when that is clearly lower
    /// than the impact (the floor, seen), else the app's own end level: the lock's lowest top corner (a ball's centre: a
    /// radius over it).
    func testLandingLevelWithoutTheFloor() throws {
        let d = maker.make(KitDropShot.standardSet[2])   // flies off the slab onto the floor
        var c = context(d)
        c.floorY = nil
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: c).analysis)
        XCTAssertEqual(a.landingLevelSource, "next bounce")
        XCTAssertEqual(a.landingLevel, 0.0175, accuracy: 0.003, "the floor's bounce, seen")
        let cut = KitSyntheticDrops.perfectTrack(d).filter { $0.t < d.truth.impactTime + 0.2 }
        let b = try XCTUnwrap(KitDropAnalysis.analyze(track: cut, cue: d.truth.cue, context: c).analysis)
        XCTAssertEqual(b.landingLevelSource, "lowest corner")
        XCTAssertEqual(b.landingLevel, d.slab.topCorners.map { $0.y }.min()! + maker.ball.radius, accuracy: 1e-9)
        XCTAssertTrue(b.leftView)
        XCTAssertLessThan(horizontal(try XCTUnwrap(b.landing), try truth(d, b).landing), 0.003)
        // without a lock: a fixed 0.1 m below the impact
        c.slab = nil
        let e = try XCTUnwrap(KitDropAnalysis.analyze(track: cut, cue: d.truth.cue, context: c).analysis)
        XCTAssertEqual(e.landingLevelSource, "fixed")
        XCTAssertEqual(e.landingLevel, e.impactCenter.y - 0.1, accuracy: 1e-9)
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

    /// A hand that sinks 8 mm/s while it waits for the beep, and 40% of the fall's frames missed: the last held frames
    /// lie below the hold's median, but the fall starts where the ball leaves the hand's own level just before, so held
    /// frames never make a fall of their own. Every drop is measured within 3 sigma (or refused), with the impact at the
    /// true first one and the drop height from where the hand let go.
    func testAHandThatSinksBeforeTheRelease() throws {
        var analysed = 0, worstZ = 0.0
        for shot in [KitDropShot.standardSet[0], KitDropShot.standardSet[6]] {   // 12 in at 70%, 6 in at 85%
            let d = maker.make(shot)
            for seed in UInt64(1)...10 {
                let n = Noise(across: 0.001, along: 0.015, miss: 0.1, seed: seed, drift: Vec3(0, -0.008, 0), missFall: 0.4)
                let r = KitDropAnalysis.analyze(track: track(d, n), cue: d.truth.cue, context: context(d))
                guard let a = r.analysis else { continue }
                analysed += 1
                let id = "\(shot.id) seed \(seed)"
                XCTAssertEqual(a.impactTime, d.truth.impactTime, accuracy: 0.02, id)
                let zr = z(try XCTUnwrap(a.rebound) - d.truth.rebound, a.reboundSigma, floor: 0.01)
                worstZ = max(worstZ, zr)
                XCTAssertLessThan(zr, 3, "\(id): \(a.rebound ?? 0) ± \(a.reboundSigma ?? 0)")
                XCTAssertLessThan(z(a.dropHeight - d.truth.dropHeight, a.dropHeightSigma, floor: 0.003), 3, id)
                XCTAssertLessThan(abs(try XCTUnwrap(a.impactClearance)), 0.03, id)
            }
        }
        XCTAssertGreaterThanOrEqual(analysed, 16)
        print(String(format: "sinking hand: %d of 20 analysed, worst rebound z %.1f", analysed, worstZ))
    }

    /// The held ball not seen (outside the crop) and the first 40 ms of the fall missed, on lively drops: the drop is
    /// the first descent after the cue, never the arc after the first bounce. With the whole first fall missed, the ball
    /// is seen rising before the fall found, and the drop is refused rather than measured on its second bounce.
    func testHeldBallNotSeenTakesTheFirstFall() throws {
        for shot in [KitDropShot.standardSet[6], KitDropShot.standardSet[10], KitDropShot.standardSet[0]] {
            let d = maker.make(shot)
            for seed in UInt64(1)...6 {
                let n = Noise(across: 0.001, along: 0.015, miss: 0.1, seed: seed, missFall: 0.4, startAfter: 0.04)
                let r = KitDropAnalysis.analyze(track: track(d, n), cue: d.truth.cue, context: context(d))
                guard let a = r.analysis else { continue }
                let id = "\(shot.id) seed \(seed)"
                XCTAssertFalse(a.heldSeen, id)
                XCTAssertEqual(a.impactTime, d.truth.impactTime, accuracy: 0.02, "\(id): the first impact, not a later one")
                XCTAssertLessThan(z(try XCTUnwrap(a.rebound) - d.truth.rebound, a.reboundSigma, floor: 0.01), 3, id)
            }
            // nothing seen until after the first impact
            let late = KitSyntheticDrops.perfectTrack(d).filter { $0.t > d.truth.impactTime + 0.03 }
            let r = KitDropAnalysis.analyze(track: late, cue: d.truth.cue, context: context(d))
            XCTAssertTrue(r.reason?.contains("its first fall and bounce were missed") ?? false, "\(shot.id): \(r.reason ?? "analysed")")
        }
    }

    /// A still, sharp held ball reads 0.2 mm both ways, the blurred moving one 2 cm along its line of sight: the weights
    /// come from the fall's and the bounce's own residuals (never more trusting than the held ball), so the rebound is
    /// within 3 sigma on every drop, not a confident wrong one.
    func testTheWeightsComeFromTheMovingBall() throws {
        var analysed = 0
        for shot in [KitDropShot.standardSet[2], KitDropShot.standardSet[9], KitDropShot.standardSet[1]] {
            let d = maker.make(shot)
            for seed in UInt64(1)...8 {
                let n = Noise(across: 0.001, along: 0.02, miss: 0.1, seed: seed, heldAcross: 0.0002, heldAlong: 0.0002, missFall: 0.4)
                let r = KitDropAnalysis.analyze(track: track(d, n), cue: d.truth.cue, context: context(d))
                guard let a = r.analysis else { continue }
                analysed += 1
                let id = "\(shot.id) seed \(seed)"
                XCTAssertLessThan(try XCTUnwrap(a.kappa), 0.3, id)
                XCTAssertLessThan(z(try XCTUnwrap(a.rebound) - d.truth.rebound, a.reboundSigma, floor: 0.01), 3,
                                  "\(id): \(a.rebound ?? 0) ± \(a.reboundSigma ?? 0)")
            }
        }
        XCTAssertGreaterThanOrEqual(analysed, 20)
    }

    /// A finder whose distance is 6 cm off through the whole fall and right through the bounce (errors the residuals do
    /// not show): the two fits then miss each other at the impact, and the uncertainties are scaled up by that, so the
    /// rebound stays within 3 sigma.
    func testDistanceOffThroughTheFall() throws {
        for shot in [KitDropShot.standardSet[10], KitDropShot.standardSet[0], KitDropShot.standardSet[2]] {
            let d = maker.make(shot)
            for seed in UInt64(1)...4 {
                let n = Noise(across: 0.001, along: 0.01, seed: seed, alongOffsetFall: 0.06)
                let a = try XCTUnwrap(KitDropAnalysis.analyze(track: track(d, n), cue: d.truth.cue, context: context(d)).analysis, shot.id)
                let id = "\(shot.id) seed \(seed)"
                XCTAssertLessThan(z(try XCTUnwrap(a.rebound) - d.truth.rebound, a.reboundSigma), 3, "\(id): \(a.rebound ?? 0) ± \(a.reboundSigma ?? 0)")
                XCTAssertLessThan(z(a.impactTime - d.truth.impactTime, a.impactTimeSigma), 3, id)
            }
        }
    }

    /// The held ball read 2.5 cm too far along its line of sight (the crop clipping its top, or its size read off): the
    /// held point is cross-checked against where the fall fit starts, said so, and the disagreement goes into the drop
    /// height's and the app comparisons' uncertainties (they start from the held reading, as the app's would).
    func testHeldReadingOffAlongTheLineOfSight() throws {
        for shot in [KitDropShot.standardSet[0], KitDropShot.standardSet[2]] {
            let d = maker.make(shot)
            for seed in UInt64(1)...4 {
                let n = Noise(across: 0.001, along: 0.004, seed: seed, heldAlongOffset: 0.025)
                let a = try XCTUnwrap(KitDropAnalysis.analyze(track: track(d, n), cue: d.truth.cue, context: context(d)).analysis, shot.id)
                let id = "\(shot.id) seed \(seed)"
                XCTAssertTrue(a.notes.contains { $0.contains("the held ball reads") }, "\(id): \(a.notes)")
                XCTAssertGreaterThan(try XCTUnwrap(a.heldOffset), 0.015, id)
                XCTAssertLessThan(z(a.dropHeight - d.truth.dropHeight, a.dropHeightSigma), 3, "\(id): \(a.dropHeight - d.truth.dropHeight) ± \(a.dropHeightSigma)")
                let app = try XCTUnwrap(a.app), tapp = try XCTUnwrap(try truth(d, a).app)
                XCTAssertLessThan(z(app.landingError - tapp.landingError, app.landingErrorSigma), 3, id)
            }
        }
    }

    /// The ball lost 0.15 s after the bounce, then one stray detection 12 cm off: that is not a next contact (it needs an
    /// arc of its own that the bounce comes down onto); the ball left the view, the landing is extrapolated and said so,
    /// and without a floor the landing level is the app's own, not the stray's.
    func testAStrayDetectionAfterTheBallIsLost() throws {
        let d = maker.make(KitDropShot.standardSet[2])
        var c = context(d)
        c.floorY = nil
        for seed in UInt64(1)...4 {
            let n = Noise(across: 0.001, along: 0.004, tail: 0.15, seed: seed, stray: (0.05, Vec3(0.12, -0.05, 0.03)))
            let tr = track(d, n)
            XCTAssertGreaterThan(tr.last!.t, d.truth.impactTime + 0.17)
            let a = try XCTUnwrap(KitDropAnalysis.analyze(track: tr, cue: d.truth.cue, context: c).analysis)
            XCTAssertNil(a.nextContact, "seed \(seed)")
            XCTAssertTrue(a.leftView, "seed \(seed)")
            XCTAssertTrue(a.notes.contains { $0.contains("the landing is extrapolated") }, "seed \(seed): \(a.notes)")
            XCTAssertFalse(a.notes.contains { $0.contains("came down on") }, "seed \(seed): \(a.notes)")
            XCTAssertEqual(a.landingLevelSource, "lowest corner", "seed \(seed)")
        }
    }

    /// A ball let go beyond the slab's outline lands on the floor beside it: refused (the track turns round far below the
    /// top), not measured as a bounce on the dish's extension. One that lands on the top within a radius of its edge is
    /// measured, but said so and left out of the rebound to bake (the bounce may be off the edge).
    func testAMissAndAnEdgeHit() throws {
        var off = KitDropShot.standardSet[0]
        off.offsetInches = 5   // the 7 in top's edge is about 3.7 in out this way
        off.offsetAzimuth = 0
        let dm = maker.make(off)
        XCTAssertEqual(dm.physics.impact?.surface, .floor)
        let r = KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(dm), cue: dm.truth.cue, context: context(dm))
        XCTAssertNil(r.analysis)
        XCTAssertTrue(r.reason?.contains("missed the slab") ?? false, r.reason ?? "analysed")
        // the edge: the offset whose contact lies 3-12 mm inside the outline
        var edge: KitSyntheticDrops.Drop? = nil
        for tenth in 28...38 {
            var s = KitDropShot.standardSet[0]
            s.offsetInches = Double(tenth) / 10
            let d = maker.make(s)
            guard let imp = d.physics.impact, imp.surface == .slab else { continue }
            let q = d.slab.toSlab(imp.point), inside = -max(abs(q.x) - d.slab.halfU, abs(q.y) - d.slab.halfV)
            if inside > 0.003 && inside < 0.012 { edge = d; break }
        }
        let de = try XCTUnwrap(edge, "a drop near the edge")
        let a = try XCTUnwrap(KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(de), cue: de.truth.cue, context: context(de)).analysis)
        XCTAssertTrue(a.bakeExcluded?.contains("the slab's edge") ?? false, "\(a.bakeExcluded ?? "baked")")
        XCTAssertNil(KitDropAnalysis.reboundToBake([a]))
    }

    /// A rebound over 100% is more than the ball can regain: a track that clearly gives one is refused.
    func testAReboundOverOneIsRefused() {
        var shot = KitDropShot.standardSet[0]
        shot.rebound = 1.06
        let d = maker.make(shot)
        let r = KitDropAnalysis.analyze(track: KitSyntheticDrops.perfectTrack(d), cue: d.truth.cue, context: context(d))
        XCTAssertTrue(r.reason?.contains("more than the ball can regain") ?? false, r.reason ?? "analysed")
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
        // a drop the analysis marked (a rebound over 100%, a hit on the edge, a fall that moves sideways) is left out
        var odd = drop(0.95, 0.01)
        odd.bakeExcluded = "a rebound of 105% ± 4 is more than the ball can regain (the track's error)"
        XCTAssertEqual(try XCTUnwrap(KitDropAnalysis.reboundToBake([drop(0.70, 0.01), drop(0.72, 0.02), odd])).count, 2)
        XCTAssertNil(KitDropAnalysis.reboundToBake([odd]))
        XCTAssertTrue(KitDropAnalysis.markdownTable([("x", odd)]).contains("left out of the rebound to bake"))
    }
}
