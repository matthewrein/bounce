import XCTest
@testable import BounceCore

/// The demo's flat phone (the capture kit's flat-phone shot in the Simulator) drives a real `KitFlatSession` through
/// both readings to the demo slab's tilt: the UI test checks the app's result against that tilt within 0.3°.
final class KitDemoMotionTests: XCTestCase {
    /// Run a session on the demo phone at 100 Hz (as the app's demo feed does) until it is done or `limit` s pass.
    func run(_ phone: inout KitDemoFlatPhone, settings: KitFlatSettings, start: Double = 1000, limit: Double = 60)
        -> (session: KitFlatSession, changes: [(KitFlatSession.Phase, Double)]) {
        let s = KitFlatSession(settings: settings, knownBump: nil, startTime: start)
        var changes: [(KitFlatSession.Phase, Double)] = []
        var t = start
        while !s.isDone && t < start + limit {
            t += 0.01
            if s.feed(phone.sample(at: t, phase: s.phase)) { changes.append((s.phase, t)) }
        }
        return (s, changes)
    }

    func testTheDemoPhoneGivesTheDemoTiltAtFullAndFastTimings() throws {
        for scale in [1.0, 0.25] {
            var phone = KitDemoFlatPhone(tiltDegrees: 8, downhillAzimuthDegrees: 125)
            XCTAssertEqual(phone.bump.length, 1.5, accuracy: 1e-9, "a 1.5° camera bump")
            let settings = KitPlan.standard.scaled(by: scale).flatSettings
            let (s, changes) = run(&phone, settings: settings)
            XCTAssertEqual(changes.map { $0.0 }, [.readingA, .waitingForLift, .waitingForStillB, .readingB, .done], "scale \(scale)")
            let r = try XCTUnwrap(s.result)
            XCTAssertEqual(r.method, .twoReading, "scale \(scale): \(r.reasons)")
            XCTAssertEqual(try XCTUnwrap(r.tiltDegrees), 8, accuracy: 0.02, "scale \(scale)")
            XCTAssertEqual(try XCTUnwrap(r.turnDegrees), 180, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(r.bumpDegrees).count, 2)
            XCTAssertEqual(Vec2(r.bumpDegrees![0], r.bumpDegrees![1]).length, 1.5, accuracy: 0.05, "the bump is solved out")
            XCTAssertLessThan(kitAzimuthError(try XCTUnwrap(r.downhillAzimuthDegrees), 125), 0.5)
            XCTAssertEqual(KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r).verdict, .good)
            // the turn comes about turnDelay after the prompt, and the whole shot fits well inside the timeouts
            let lift = try XCTUnwrap(changes.first { $0.0 == .waitingForLift }?.1)
            let lifted = try XCTUnwrap(changes.first { $0.0 == .waitingForStillB }?.1)
            XCTAssertEqual(lifted - lift, phone.turnDelay, accuracy: 0.05)
            XCTAssertLessThan(try XCTUnwrap(changes.last?.1) - 1000, 2 * settings.timeoutA + settings.timeoutB)
        }
    }

    func testOtherTiltsAndALevelSlab() throws {
        for (tilt, az) in [(0.0, 0.0), (3.0, 10.0), (15.0, 250.0)] {
            var phone = KitDemoFlatPhone(tiltDegrees: tilt, downhillAzimuthDegrees: az)
            let (s, _) = run(&phone, settings: KitPlan.standard.scaled(by: 0.25).flatSettings)
            let r = try XCTUnwrap(s.result)
            XCTAssertEqual(r.method, .twoReading, "tilt \(tilt): \(r.reasons)")
            XCTAssertEqual(try XCTUnwrap(r.tiltDegrees), tilt, accuracy: 0.02, "tilt \(tilt)")
        }
    }

    func testTheSamplesFollowTheModel() {
        var phone = KitDemoFlatPhone(tiltDegrees: 8)
        let a = phone.sample(at: 1, phase: .readingA)
        let g = KitFlatTilt.gravity(slabDegrees: phone.slabVector, bumpDegrees: phone.bump, turnDegrees: 180)
        XCTAssertLessThan(KitFlatTilt.angle(a.gravity, g.a), 1e-9)
        XCTAssertEqual(a.rotationRate, .zero)
        XCTAssertNil(phone.turnStart)
        _ = phone.sample(at: 2, phase: .waitingForLift)
        XCTAssertEqual(phone.turnStart, 3)
        let turning = phone.sample(at: 3.2, phase: .waitingForLift)
        XCTAssertGreaterThan(turning.rotationRate.length, 0.5, "the turn reads as a lift")
        let b = phone.sample(at: 5, phase: .waitingForStillB)
        XCTAssertLessThan(KitFlatTilt.angle(b.gravity, g.b), 1e-9)
        XCTAssertEqual(b.rotationRate, .zero)
        // the attitude is R itself: it carries device-axes gravity onto the reference frame's down
        XCTAssertLessThan(KitFlatTilt.angle(b.attitude.rotate(b.gravity), Vec3(0, 0, -1)), 1e-9)
    }
}
