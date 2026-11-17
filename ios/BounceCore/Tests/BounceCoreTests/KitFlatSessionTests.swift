import XCTest
@testable import BounceCore

final class KitFlatSessionTests: XCTestCase {
    struct Run {
        var phases: [KitFlatSession.Phase] = []
        var changeTimes: [Double] = []
        var prompts: [KitFlatSession.Phase: Set<String>] = [:]
        var progress: [Double] = []
    }

    /// Feed samples, recording each phase change.
    @discardableResult
    func feed(_ s: KitFlatSession, _ samples: [KitMotionSample], into run: inout Run) -> Run {
        if run.phases.isEmpty { run.phases = [s.phase] }
        for x in samples {
            let changed = s.feed(x)
            if changed {
                XCTAssertNotEqual(s.phase, run.phases.last, "a reported change is a new phase")
                run.phases.append(s.phase); run.changeTimes.append(x.time)
            }
            run.prompts[s.phase, default: []].insert(s.prompt)
            run.progress.append(s.progress)
        }
        return run
    }

    let fullOrder: [KitFlatSession.Phase] = [.waitingForStillA, .readingA, .waitingForLift, .waitingForStillB, .readingB, .done]

    func testFullSessionWithHandling() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(9, 130), bump: KitFlatSim.vec(1.8, 20), seed: 31)
        sim.yawDrift = 0.02
        let s = KitFlatSession()
        var run = Run()
        feed(s, sim.handle(1.0, from: 0, to: 0, lift: 8, jitter: 0.5), into: &run)   // laying it down
        XCTAssertEqual(s.phase, .waitingForStillA)
        feed(s, sim.still(5, psi: 0), into: &run)
        feed(s, sim.handle(2.0, from: 0, to: 180, lift: 12, jitter: 0.5), into: &run) // pick up, turn around, lay down
        feed(s, sim.still(5, psi: 180), into: &run)
        XCTAssertEqual(run.phases, fullOrder)
        // still after 1 s, then a 3 s reading; lifted as soon as the hand moves; still again 1 s after laying down
        XCTAssertEqual(run.changeTimes[0], 2.0, accuracy: 0.03)
        XCTAssertEqual(run.changeTimes[1], 5.0, accuracy: 0.03)
        XCTAssertEqual(run.changeTimes[2], 6.0, accuracy: 0.1)
        XCTAssertEqual(run.changeTimes[3], 9.0, accuracy: 0.05)
        XCTAssertEqual(run.changeTimes[4], 12.0, accuracy: 0.05)
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.method, .twoReading)
        XCTAssertEqual(try XCTUnwrap(r.tiltDegrees), 9, accuracy: 0.05)
        XCTAssertLessThan(kitAzimuthError(try XCTUnwrap(r.downhillAzimuthDegrees), 130), 0.5)
        XCTAssertEqual(try XCTUnwrap(r.turnDegrees), 180, accuracy: 0.3)
        XCTAssertEqual(s.readingA?.samples ?? 0, 300, accuracy: 2)
        XCTAssertLessThan(try XCTUnwrap(s.readingA?.spreadDegrees), 0.15)
        XCTAssertEqual(s.restarts, 0)
        XCTAssertTrue(s.isDone)
        XCTAssertTrue(s.prompt.hasPrefix("Done: the slab tilts 9.0°"), s.prompt)
        XCTAssertEqual(KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r).verdict, .good)
        // progress only goes up, and each phase has its own words
        XCTAssertEqual(run.progress, run.progress.sorted())
        XCTAssertEqual(run.progress.last, 1)
        XCTAssertEqual(Set(run.prompts.values.flatMap { $0 }).count, 5)
        // after done, more samples change nothing
        XCTAssertFalse(s.feed(KitMotionSample(time: 100, gravity: Vec3(0, 0, -1))))
        XCTAssertFalse(s.advance(to: 200))
    }

    func testNeverStillTimesOutAfterEightSeconds() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(3, 0), bump: .zero, seed: 32)
        let s = KitFlatSession()
        var run = Run()
        // held in the hand the whole time: jitter, never still
        for _ in 0..<5 { feed(s, sim.handle(2.0, from: 0, to: 0, lift: 2, jitter: 0.6), into: &run) }
        XCTAssertEqual(run.phases, [.waitingForStillA, .done])
        XCTAssertEqual(run.changeTimes[0], 8.0, accuracy: 0.02)
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.method, .failed)
        XCTAssertTrue(r.reasons[0].contains("did not lie still within 8 s"), r.reasons[0])
        XCTAssertEqual(s.prompt, "No reading: the phone did not lie still within 8 s.", "the prompt gives the reason")
        XCTAssertEqual(KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r).verdict, .poor)
    }

    func testAPhoneLyingScreenDownEndsTheShotAtOnce() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(5, 0), bump: KitFlatSim.vec(1, 100), seed: 39)
        let s = KitFlatSession()
        var run = Run()
        feed(s, sim.stillHeld(8, psi: 0, hand: KitFlatSim.screenDown), into: &run)
        XCTAssertEqual(run.phases, [.waitingForStillA, .readingA, .done], "no second reading is asked for")
        XCTAssertEqual(run.changeTimes[1], 4.0, accuracy: 0.03)
        let r = try XCTUnwrap(s.result)
        XCTAssertEqual(r.method, .failed)
        XCTAssertFalse(r.isUsable)
        XCTAssertEqual(try XCTUnwrap(r.readingA?.tiltDegrees), 175, accuracy: 2)
        XCTAssertTrue(s.prompt.hasPrefix("The phone was not lying flat, screen up"), s.prompt)
        let q = KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r)
        XCTAssertEqual(q.verdict, .poor)
        XCTAssertEqual(q.check("flat")?.passed, false)
        // turned around onto its screen for reading B: reading A stands alone
        var sim2 = KitFlatSim(slab: KitFlatSim.vec(5, 0), bump: KitFlatSim.vec(1, 100), seed: 40)
        let t = KitFlatSession()
        var run2 = Run()
        feed(t, sim2.still(5, psi: 0), into: &run2)
        feed(t, sim2.handle(2.0, from: 0, to: 0, lift: 12, jitter: 0.5), into: &run2)
        feed(t, sim2.stillHeld(5, psi: 0, hand: KitFlatSim.endOverEnd), into: &run2)
        XCTAssertEqual(run2.phases, fullOrder)
        XCTAssertEqual(t.result?.method, .uncorrected)
        XCTAssertTrue(t.prompt.hasPrefix("Done (one reading)"), t.prompt)
    }

    func testNeverTurnedFallsBackToOneReading() throws {
        for withBump in [false, true] {
            var sim = KitFlatSim(slab: KitFlatSim.vec(5, 200), bump: KitFlatSim.vec(1.5, 45), seed: 33)
            let bump = KitBump(degrees: [sim.bump.x, sim.bump.y], uncertaintyDegrees: 0.03)
            let s = KitFlatSession(knownBump: withBump ? bump : nil)
            var run = Run()
            feed(s, sim.still(25, psi: 0), into: &run)
            XCTAssertEqual(run.phases, [.waitingForStillA, .readingA, .waitingForLift, .done])
            XCTAssertEqual(run.changeTimes[2], 4.0 + 15, accuracy: 0.03, "gives up 15 s after reading A")
            let r = try XCTUnwrap(s.result)
            XCTAssertEqual(r.method, withBump ? .bumpCorrected : .uncorrected)
            XCTAssertEqual(r.reasons[0], "The phone was not turned around in time.")
            if withBump { XCTAssertEqual(try XCTUnwrap(r.tiltDegrees), 5, accuracy: 0.05) }
            XCTAssertTrue(s.prompt.hasPrefix("Done (one reading)"))
            let q = KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r)
            XCTAssertEqual(q.verdict, .fair)
            XCTAssertEqual(q.check("turn")?.passed, false)
        }
    }

    func testLiftedButNeverLaidStillAgain() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(2, 0), bump: .zero, seed: 34)
        let s = KitFlatSession()
        var run = Run()
        feed(s, sim.still(4.5, psi: 0), into: &run)
        for _ in 0..<10 { feed(s, sim.handle(2.0, from: 0, to: 20, lift: 10, jitter: 0.8), into: &run) }
        XCTAssertEqual(run.phases, [.waitingForStillA, .readingA, .waitingForLift, .waitingForStillB, .done])
        XCTAssertEqual(run.changeTimes.last ?? 0, 4.0 + 15, accuracy: 0.03)
        XCTAssertEqual(s.result?.method, .uncorrected)
        XCTAssertEqual(s.result?.reasons.first, "The phone did not lie still again after turning.")
    }

    func testAKnockDuringAReadingRestartsIt() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(4, 300), bump: KitFlatSim.vec(1, 90), seed: 35)
        let s = KitFlatSession()
        var run = Run()
        feed(s, sim.still(2.5, psi: 0), into: &run)
        XCTAssertEqual(s.phase, .readingA)
        let p = s.progress
        XCTAssertGreaterThan(p, 0.05); XCTAssertLessThan(p, 0.45)
        feed(s, sim.handle(0.2, from: 0, to: 0, lift: 2, jitter: 0), into: &run) // someone bumps the table
        XCTAssertEqual(s.phase, .waitingForStillA)
        XCTAssertEqual(s.restarts, 1)
        XCTAssertEqual(s.prompt, "It moved. Let go of the phone and keep the slab still.")
        feed(s, sim.still(4.5, psi: 0), into: &run)
        XCTAssertEqual(run.phases, [.waitingForStillA, .readingA, .waitingForStillA, .readingA, .waitingForLift])
        XCTAssertLessThan(try XCTUnwrap(s.readingA?.spreadDegrees), 0.15, "the knock is not in the reading")
        XCTAssertEqual(try XCTUnwrap(s.readingA?.start), 2.7 + 1.0, accuracy: 0.03)
    }

    func testStillnessRule() {
        // rotation rate just under / just over 0.05 rad/s
        for (rate, still) in [(0.049, true), (0.051, false)] {
            let s = KitFlatSession()
            for i in 0..<300 { s.feed(KitMotionSample(time: Double(i) / 100, gravity: Vec3(0, 0, -1), rotationRate: Vec3(0, 0, rate))) }
            XCTAssertEqual(s.phase == .readingA, still, "rate \(rate)")
        }
        // gravity wandering by 0.14 degrees from the mean is still; by 0.16 it is not
        for (amp, still) in [(0.14, true), (0.16, false)] {
            let s = KitFlatSession()
            for i in 0..<300 {
                let a = Units.radians(amp) * (i % 2 == 0 ? 1 : -1)
                s.feed(KitMotionSample(time: Double(i) / 100, gravity: Vec3(sin(a), 0, -cos(a))))
            }
            XCTAssertEqual(s.phase == .readingA, still, "amplitude \(amp)")
        }
        // still, but not yet for a whole second
        let s = KitFlatSession()
        for i in 0..<95 { s.feed(KitMotionSample(time: Double(i) / 100, gravity: Vec3(0, 0, -1))) }
        XCTAssertEqual(s.phase, .waitingForStillA)
        for i in 95..<101 { s.feed(KitMotionSample(time: Double(i) / 100, gravity: Vec3(0, 0, -1))) }
        XCTAssertEqual(s.phase, .readingA)
    }

    func testScaledTimings() throws {
        let settings = KitPlan.standard.scaled(by: 0.25).flatSettings
        XCTAssertEqual(settings.stillSeconds, 0.25); XCTAssertEqual(settings.readingSeconds, 0.75)
        var sim = KitFlatSim(slab: KitFlatSim.vec(3, 10), bump: KitFlatSim.vec(1, 180), seed: 36)
        let s = KitFlatSession(settings: settings)
        var run = Run()
        feed(s, sim.still(1.3, psi: 0), into: &run)
        feed(s, sim.handle(0.8, from: 0, to: 180, lift: 10, jitter: 0.3), into: &run)
        feed(s, sim.still(1.3, psi: 180), into: &run)
        XCTAssertEqual(run.phases, fullOrder)
        XCTAssertEqual(run.changeTimes[1], 1.0, accuracy: 0.03)
        XCTAssertEqual(s.result?.method, .twoReading)
        XCTAssertEqual(try XCTUnwrap(s.result?.tiltDegrees), 3, accuracy: 0.1)
        // and the timeout for A is 2 s
        let t = KitFlatSession(settings: settings)
        var run2 = Run()
        let held = sim.handle(3, from: 0, to: 0, lift: 2, jitter: 0.6)
        feed(t, held, into: &run2)
        XCTAssertEqual(t.result?.method, .failed)
        XCTAssertEqual((run2.changeTimes.first ?? 0) - (held.first?.time ?? 0), 2.0, accuracy: 0.02, "2 s after its first sample")
    }

    func testAdvanceAppliesTimeoutsWithoutSamples() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(2, 0), bump: .zero, seed: 37)
        let s = KitFlatSession()
        let samples = sim.still(4.5, psi: 0)
        for x in samples { s.feed(x) }
        XCTAssertEqual(s.phase, .waitingForLift)
        XCTAssertEqual(try XCTUnwrap(s.secondsLeft), 15 - 0.5, accuracy: 0.02)
        XCTAssertFalse(s.advance(to: 4.0 + 14.9))
        XCTAssertTrue(s.advance(to: 4.0 + 15.01))
        XCTAssertEqual(s.result?.method, .uncorrected)
        XCTAssertNil(s.secondsLeft)
        // before any sample: advance starts the clock
        let t = KitFlatSession()
        XCTAssertFalse(t.advance(to: 100))
        XCTAssertEqual(t.startTime, 100)
        XCTAssertEqual(t.secondsLeft, 8)
        XCTAssertTrue(t.advance(to: 108))
        XCTAssertEqual(t.result?.method, .failed)
        // a start time given up front
        let u = KitFlatSession(startTime: 50)
        XCTAssertTrue(u.advance(to: 58.5))
    }

    func testFinishEarly() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(2, 0), bump: .zero, seed: 38)
        let s = KitFlatSession()
        for x in sim.still(2, psi: 0) { s.feed(x) }
        XCTAssertEqual(s.phase, .readingA)
        XCTAssertEqual(s.finish().method, .failed)
        XCTAssertEqual(s.result?.reasons, ["Stopped before the phone lay still."])
        XCTAssertTrue(s.isDone)
        let t = KitFlatSession()
        for x in sim.still(5, psi: 0) { t.feed(x) }
        let r = t.finish()
        XCTAssertEqual(r.method, .uncorrected)
        XCTAssertEqual(r.reasons.first, "Stopped before the second reading.")
        XCTAssertEqual(t.finish(), r, "finishing twice returns the same result")
    }

    func testBadAndOutOfOrderSamplesAreIgnored() {
        let s = KitFlatSession()
        XCTAssertFalse(s.feed(KitMotionSample(time: 1, gravity: Vec3(0, 0, -1))))
        XCTAssertFalse(s.feed(KitMotionSample(time: 0.5, gravity: Vec3(0, 0, -1))))
        XCTAssertFalse(s.feed(KitMotionSample(time: 1, gravity: Vec3(0, 0, -1))))
        XCTAssertFalse(s.feed(KitMotionSample(time: 2, gravity: Vec3(.nan, 0, -1))))
        XCTAssertFalse(s.feed(KitMotionSample(time: .infinity, gravity: Vec3(0, 0, -1))))
        XCTAssertEqual(s.sampleCount, 1)
        XCTAssertEqual(s.lastTime, 1)
        XCTAssertEqual(s.progress, 0)
    }
}
