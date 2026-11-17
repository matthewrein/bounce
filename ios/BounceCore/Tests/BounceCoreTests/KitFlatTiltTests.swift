import XCTest
@testable import BounceCore

/// Simulates CoreMotion on a phone lying on (or handled over) a tilted slab, from the exact model:
/// phone-in-reference R = Y · T · Rz(psi) · H · B, with Y the reference frame's arbitrary heading, T the slab's tilt,
/// psi the phone's turn about the slab's normal, H the owner's hand (identity while the phone lies on the slab) and B
/// the rest on the camera bump. Gravity in device axes is R^T (0,0,-1); the attitude is R as a quaternion.
struct KitFlatSim {
    /// slab tilt vector (degrees), in the slab's frame before the phone's turn: direction = downhill
    var slab: Vec2
    /// camera bump vector (degrees, phone axes)
    var bump: Vec2
    /// heading of the reference frame (degrees)
    var yaw: Double = 37
    /// gravity noise per axis per sample (degrees)
    var gravityNoise = 0.02
    /// attitude noise per axis per sample (degrees)
    var attitudeNoise = 0.01
    /// rotation-rate noise per axis (rad/s)
    var rateNoise = 0.003
    /// the attitude's heading drifts (CoreMotion without a compass), degrees per second
    var yawDrift = 0.0
    /// write the attitude in the opposite quaternion convention
    var conjugate = false
    var rate = 100.0
    var rng: KitTestRandom
    /// time cursor for building streams
    var t = 0.0
    var lastR: Mat3?

    init(slab: Vec2, bump: Vec2, seed: UInt64 = 1) {
        self.slab = slab; self.bump = bump; rng = KitTestRandom(seed: seed)
    }

    static func vec(_ magnitude: Double, _ azimuthDegrees: Double) -> Vec2 {
        let a = Units.radians(azimuthDegrees)
        return Vec2(magnitude * cos(a), magnitude * sin(a))
    }

    static func rotation(_ w: Vec3) -> Mat3 {
        Mat3(columns: Vec3(1, 0, 0).rotated(by: w), Vec3(0, 1, 0).rotated(by: w), Vec3(0, 0, 1).rotated(by: w))
    }

    func rotation(psi: Double, hand: Vec3 = .zero) -> Mat3 {
        KitFlatTilt.rz(Units.radians(yaw)) * KitFlatTilt.tiltMatrix(slab * (Double.pi / 180)) * KitFlatTilt.rz(Units.radians(psi))
            * KitFlatSim.rotation(hand) * KitFlatTilt.tiltMatrix(bump * (Double.pi / 180))
    }

    mutating func noiseVector(_ sigmaDegrees: Double) -> Vec3 {
        let s = Units.radians(sigmaDegrees)
        return Vec3(rng.gauss() * s, rng.gauss() * s, rng.gauss() * s)
    }

    mutating func sample(time: Double, R: Mat3, rotationRate: Vec3) -> KitMotionSample {
        let g = (R.transposed * Vec3(0, 0, -1)).rotated(by: noiseVector(gravityNoise))
        var q = KitQuaternion(matrix: KitFlatTilt.rz(Units.radians(yawDrift * time)) * R)
        q = KitQuaternion(rotationVector: noiseVector(attitudeNoise)) * q
        if conjugate { q = q.conjugate }
        let rr = rotationRate + Vec3(rng.gauss() * rateNoise, rng.gauss() * rateNoise, rng.gauss() * rateNoise)
        return KitMotionSample(time: time, gravity: g, userAcceleration: .zero, rotationRate: rr, attitude: q)
    }

    /// The phone lying still at turn psi for `seconds` from the cursor.
    mutating func still(_ seconds: Double, psi: Double) -> [KitMotionSample] {
        let R = rotation(psi: psi)
        let n = Int((seconds * rate).rounded())
        var out: [KitMotionSample] = []
        for _ in 0..<n { t += 1 / rate; out.append(sample(time: t, R: R, rotationRate: .zero)) }
        lastR = R
        return out
    }

    /// The phone in the owner's hand: turned from `from` to `to` (degrees), lifted and tilted by up to `lift` degrees,
    /// with hand jitter of about `jitter` degrees. It starts and ends lying flat.
    mutating func handle(_ seconds: Double, from: Double, to: Double, lift: Double, jitter: Double) -> [KitMotionSample] {
        let n = Int((seconds * rate).rounded())
        var out: [KitMotionSample] = []
        var j = Vec3.zero
        var prev = lastR ?? rotation(psi: from)
        for i in 1...max(1, n) {
            let s = Double(i) / Double(max(1, n)), env = sin(.pi * s)
            j = j * 0.9 + noiseVector(jitter * 0.45)
            let hand = Vec3(Units.radians(lift) * env, Units.radians(lift) * 0.3 * env, 0) + j * env
            let R = rotation(psi: from + (to - from) * s, hand: hand)
            let rel = KitQuaternion(matrix: prev.transposed * R).rotationVector * rate
            t += 1 / rate
            out.append(sample(time: t, R: R, rotationRate: rel))
            prev = R
        }
        lastR = prev
        return out
    }

    /// A reading's statistics at turn psi (3 s at 100 Hz).
    mutating func reading(psi: Double, seconds: Double = 3) -> KitFlatReading? {
        let s = still(seconds, psi: psi)
        t += 5 // time passes between readings
        return KitFlatReading.from(s)
    }

    /// The phone lying still at turn psi but not on its back: turned by `hand` (a rotation vector in phone axes,
    /// radians) from lying flat. (0, pi, 0) is screen down, top still away; (pi, 0, 0) is flipped end over end, screen
    /// down, top toward the owner; (0, pi / 2, 0) is on its side.
    mutating func stillHeld(_ seconds: Double, psi: Double, hand: Vec3) -> [KitMotionSample] {
        let R = rotation(psi: psi, hand: hand)
        let n = Int((seconds * rate).rounded())
        var out: [KitMotionSample] = []
        for _ in 0..<n { t += 1 / rate; out.append(sample(time: t, R: R, rotationRate: .zero)) }
        lastR = R
        return out
    }

    mutating func reading(psi: Double, hand: Vec3) -> KitFlatReading? {
        let s = stillHeld(3, psi: psi, hand: hand)
        t += 5
        return KitFlatReading.from(s)
    }

    static let screenDown = Vec3(0, Double.pi, 0)
    static let endOverEnd = Vec3(Double.pi, 0, 0)
    static let onItsSide = Vec3(0, Double.pi / 2, 0)
}

/// angle between two azimuths (degrees, 0...180)
func kitAzimuthError(_ a: Double, _ b: Double) -> Double {
    let d = abs((a - b).truncatingRemainder(dividingBy: 360))
    return min(d, 360 - d)
}

final class KitFlatTiltTests: XCTestCase {
    func testNoiselessModelSolvesExactly() throws {
        let cases: [(Double, Double, Double, Double, Double)] = [(0, 0, 0, 0, 180), (5, 30, 1.5, 200, 180), (20, 250, 4, 10, 120),
                                                                  (20, 100, 4, 300, 240), (12, 0, 0, 0, 150), (0.1, 45, 3, 90, 61)]
        for (tilt, az, bumpMag, bumpDir, turn) in cases {
            let s = KitFlatSim.vec(tilt, az), b = KitFlatSim.vec(bumpMag, bumpDir)
            let g = KitFlatTilt.gravity(slabDegrees: s, bumpDegrees: b, turnDegrees: turn)
            let sol = try XCTUnwrap(KitFlatTilt.solve(gA: g.a, gB: g.b, turn: Units.radians(turn)))
            XCTAssertTrue(sol.converged)
            XCTAssertEqual(Units.degrees(sol.slab.x), s.x, accuracy: 1e-7); XCTAssertEqual(Units.degrees(sol.slab.y), s.y, accuracy: 1e-7)
            XCTAssertEqual(Units.degrees(sol.bump.x), b.x, accuracy: 1e-7); XCTAssertEqual(Units.degrees(sol.bump.y), b.y, accuracy: 1e-7)
            XCTAssertLessThan(sol.residual, 1e-9)
        }
        // the bump alone: a level slab reads the bump in both orientations
        let g = KitFlatTilt.gravity(slabDegrees: .zero, bumpDegrees: Vec2(2, 0), turnDegrees: 180)
        XCTAssertEqual(g.a.distance(to: g.b), 0, accuracy: 1e-12)
        XCTAssertEqual(Units.degrees(g.a.angle(to: Vec3(0, 0, -1))), 2, accuracy: 1e-9)
        XCTAssertGreaterThan(g.a.x, 0, "the bump vector points the way the phone leans down")
        XCTAssertNil(KitFlatTilt.solve(gA: g.a, gB: g.b, turn: 0), "no turn, no solve")
        XCTAssertNil(KitFlatTilt.smallAngle(gA: g.a, gB: g.b, turn: 2 * .pi))
    }

    func testTwoReadingsRecoverTheTiltAcrossManyCases() throws {
        var rng = KitTestRandom(seed: 11)
        var worst = (tilt: 0.0, az: 0.0, bump: 0.0, turn: 0.0, gyro: 0.0, sigmaRatio: 0.0)
        var cases = 0
        for tilt in [0.0, 0.3, 1, 3, 5, 8, 12, 16, 20] {
            for k in 0..<12 {
                let az = Double(k) * 30 + rng.uniform() * 30
                let bump = KitFlatSim.vec(rng.uniform() * 4, rng.uniform() * 360)
                let turn = 120 + rng.uniform() * 120
                let psiA = rng.uniform() * 360
                var sim = KitFlatSim(slab: KitFlatSim.vec(tilt, az), bump: bump, seed: UInt64(cases + 100))
                sim.yaw = rng.uniform() * 360
                sim.yawDrift = 0.02
                let a = try XCTUnwrap(sim.reading(psi: psiA)), b = try XCTUnwrap(sim.reading(psi: psiA + turn))
                let r = KitFlatTilt.twoReading(a, b)
                XCTAssertEqual(r.method, .twoReading)
                let t = try XCTUnwrap(r.tiltDegrees)
                worst.tilt = max(worst.tilt, abs(t - tilt))
                if tilt >= 1 { worst.az = max(worst.az, kitAzimuthError(try XCTUnwrap(r.downhillAzimuthDegrees), az - psiA)) }
                let rb = try XCTUnwrap(r.bumpDegrees)
                worst.bump = max(worst.bump, Vec2(rb[0], rb[1]).distance(to: bump))
                worst.turn = max(worst.turn, abs(try XCTUnwrap(r.turnDegrees) - turn))
                worst.gyro = max(worst.gyro, abs(try XCTUnwrap(r.gyroTiltDegrees) - tilt))
                worst.sigmaRatio = max(worst.sigmaRatio, abs(t - tilt) / max(1e-9, try XCTUnwrap(r.uncertaintyDegrees)))
                XCTAssertEqual(r.attitudeConjugated, false)
                XCTAssertLessThan(try XCTUnwrap(r.residualDegrees), 1e-6, "four equations, four unknowns")
                cases += 1
            }
        }
        XCTAssertEqual(cases, 108)
        XCTAssertLessThan(worst.tilt, 0.05, "tilt error")
        XCTAssertLessThan(worst.az, 1.0, "downhill direction error (tilts of 1 degree and more)")
        XCTAssertLessThan(worst.bump, 0.05, "bump error")
        XCTAssertLessThan(worst.turn, 0.3, "turn error (includes the attitude's heading drift)")
        XCTAssertLessThan(worst.gyro, 0.2, "gyro cross-check")
        XCTAssertLessThan(worst.sigmaRatio, 5, "the uncertainty estimate is not wildly optimistic")
    }

    func testRefinementMattersAtLargeTilts() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(20, 60), bump: KitFlatSim.vec(3, 200), seed: 5)
        let a = try XCTUnwrap(sim.reading(psi: 0)), b = try XCTUnwrap(sim.reading(psi: 180))
        let r = KitFlatTilt.twoReading(a, b)
        let exact = abs(try XCTUnwrap(r.tiltDegrees) - 20), small = abs(try XCTUnwrap(r.smallAngleTiltDegrees) - 20)
        XCTAssertLessThan(exact, 0.05)
        XCTAssertGreaterThan(small, 0.2, "the small-angle start alone is off by \(small) degrees")
        XCTAssertGreaterThan(small, 10 * exact)
        // and at small tilts the start is already close
        var sim2 = KitFlatSim(slab: KitFlatSim.vec(1, 60), bump: KitFlatSim.vec(1, 200), seed: 6)
        let r2 = KitFlatTilt.twoReading(try XCTUnwrap(sim2.reading(psi: 0)), try XCTUnwrap(sim2.reading(psi: 180)))
        XCTAssertLessThan(abs(try XCTUnwrap(r2.smallAngleTiltDegrees) - 1), 0.05)
    }

    func testOppositeAttitudeConventionIsDetected() throws {
        for (conj, turn) in [(true, 150.0), (false, 150.0), (true, 215.0)] {
            var sim = KitFlatSim(slab: KitFlatSim.vec(6, 75), bump: KitFlatSim.vec(1.5, 300), seed: 9)
            sim.conjugate = conj
            let a = try XCTUnwrap(sim.reading(psi: 20)), b = try XCTUnwrap(sim.reading(psi: 20 + turn))
            let r = KitFlatTilt.twoReading(a, b)
            XCTAssertEqual(r.attitudeConjugated, conj)
            XCTAssertEqual(try XCTUnwrap(r.turnDegrees), turn, accuracy: 0.1)
            XCTAssertEqual(try XCTUnwrap(r.tiltDegrees), 6, accuracy: 0.05)
            XCTAssertLessThan(kitAzimuthError(try XCTUnwrap(r.downhillAzimuthDegrees), 55), 0.5)
            XCTAssertLessThan(try XCTUnwrap(r.attitudeMismatchDegrees), 0.1)
        }
    }

    func testTooSmallATurnFallsBackToOneReading() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(4, 10), bump: KitFlatSim.vec(1.2, 100), seed: 3)
        let a = try XCTUnwrap(sim.reading(psi: 0)), b = try XCTUnwrap(sim.reading(psi: 30))
        let r = KitFlatTilt.twoReading(a, b)
        XCTAssertEqual(r.method, .uncorrected)
        XCTAssertEqual(try XCTUnwrap(r.turnDegrees), 30, accuracy: 0.1)
        XCTAssertTrue(r.reasons[0].contains("turned only 30°"), r.reasons[0])
        XCTAssertNotNil(r.readingB)
        let known = KitBump(degrees: [sim.bump.x, sim.bump.y], uncertaintyDegrees: 0.02)
        let r2 = KitFlatTilt.twoReading(a, b, knownBump: known)
        XCTAssertEqual(r2.method, .bumpCorrected)
        XCTAssertEqual(try XCTUnwrap(r2.tiltDegrees), 4, accuracy: 0.05)
        // turned the other way by a little: 330 degrees is 30 degrees too
        var sim3 = KitFlatSim(slab: KitFlatSim.vec(4, 10), bump: KitFlatSim.vec(1.2, 100), seed: 4)
        let r3 = KitFlatTilt.twoReading(try XCTUnwrap(sim3.reading(psi: 0)), try XCTUnwrap(sim3.reading(psi: -30)))
        XCTAssertEqual(r3.method, .uncorrected)
        XCTAssertEqual(try XCTUnwrap(r3.turnDegrees), 330, accuracy: 0.1)
        // 60-120 degrees still solves
        var sim4 = KitFlatSim(slab: KitFlatSim.vec(4, 10), bump: KitFlatSim.vec(1.2, 100), seed: 8)
        let r4 = KitFlatTilt.twoReading(try XCTUnwrap(sim4.reading(psi: 0)), try XCTUnwrap(sim4.reading(psi: 90)))
        XCTAssertEqual(r4.method, .twoReading)
        XCTAssertEqual(try XCTUnwrap(r4.tiltDegrees), 4, accuracy: 0.05)
    }

    func testSingleReadingWithAndWithoutTheBump() throws {
        var sim = KitFlatSim(slab: KitFlatSim.vec(7, 40), bump: KitFlatSim.vec(1.7, 250), seed: 12)
        let a = try XCTUnwrap(sim.reading(psi: 0))
        let corrected = KitFlatTilt.singleReading(a, knownBump: KitBump(degrees: [sim.bump.x, sim.bump.y], uncertaintyDegrees: 0.03))
        XCTAssertEqual(corrected.method, .bumpCorrected)
        XCTAssertEqual(try XCTUnwrap(corrected.tiltDegrees), 7, accuracy: 0.05)
        XCTAssertLessThan(kitAzimuthError(try XCTUnwrap(corrected.downhillAzimuthDegrees), 40), 0.5)
        XCTAssertEqual(try XCTUnwrap(corrected.uncertaintyDegrees), 0.06, accuracy: 0.02)
        let raw = KitFlatTilt.singleReading(a, knownBump: nil)
        XCTAssertEqual(raw.method, .uncorrected)
        XCTAssertEqual(raw.uncertaintyDegrees, 2)
        XCTAssertEqual(try XCTUnwrap(raw.tiltDegrees), a.tiltDegrees, accuracy: 1e-12)
        XCTAssertGreaterThan(abs(try XCTUnwrap(raw.tiltDegrees) - 7), 0.5, "the bump spoils an uncorrected reading")
        XCTAssertTrue(raw.isUsable)
        XCTAssertNil(raw.solvedBump, "only a two-reading result gives a bump to reuse")
        // the result helper
        XCTAssertEqual(KitFlatTilt.result(readingA: a, readingB: nil, knownBump: nil).method, .uncorrected)
        let none = KitFlatTilt.result(readingA: nil, readingB: nil, knownBump: nil)
        XCTAssertEqual(none.method, .failed)
        XCTAssertFalse(none.isUsable)
        XCTAssertNil(none.tiltVector)
    }

    func testReadingStatistics() throws {
        let g = Vec3(0, 0, -1).rotated(by: Vec3(sin(Units.radians(120)), -cos(Units.radians(120)), 0) * Units.radians(3))
        let q = KitQuaternion(axis: Vec3(0.1, 0.2, 1), angle: 2)
        var samples = (0..<300).map { i in
            KitMotionSample(time: Double(i) / 100, gravity: g, rotationRate: Vec3(0, 0, 0.001), attitude: i % 2 == 0 ? q : KitQuaternion(x: -q.x, y: -q.y, z: -q.z, w: -q.w))
        }
        var r = try XCTUnwrap(KitFlatReading.from(samples))
        XCTAssertEqual(r.samples, 300)
        XCTAssertEqual(r.tiltDegrees, 3, accuracy: 1e-9)
        XCTAssertEqual(r.azimuthDegrees, 120, accuracy: 1e-6)
        XCTAssertEqual(r.spreadDegrees, 0, accuracy: 1e-6)
        XCTAssertEqual(r.rmsDegrees, 0, accuracy: 1e-6)
        XCTAssertEqual(abs(r.attitude.dot(q)), 1, accuracy: 1e-9, "q and -q average as the same rotation")
        XCTAssertEqual(r.maxRotationRate, 0.001, accuracy: 1e-12)
        XCTAssertEqual(r.start, 0); XCTAssertEqual(r.end, 2.99, accuracy: 1e-12)
        // a knock: one sample 2 degrees off. The mean resists it; the spread reports it.
        samples[150].gravity = g.rotated(by: Vec3(1, 0, 0) * Units.radians(2))
        samples[150].rotationRate = Vec3(0.4, 0, 0)
        r = try XCTUnwrap(KitFlatReading.from(samples))
        XCTAssertEqual(Units.degrees(r.gravity.angle(to: g)), 0, accuracy: 1e-6)
        XCTAssertEqual(r.spreadDegrees, 2, accuracy: 0.01)
        XCTAssertEqual(r.maxRotationRate, 0.4, accuracy: 1e-12)
        XCTAssertNil(KitFlatReading.from([]))
        XCTAssertNil(KitFlatReading.from([KitMotionSample(time: 0, gravity: .zero)]))
        let level = try XCTUnwrap(KitFlatReading.from([KitMotionSample(time: 0, gravity: Vec3(0, 0, -1))]))
        XCTAssertEqual(level.tiltDegrees, 0); XCTAssertEqual(level.azimuthDegrees, 0)
    }

    func testUncertaintyGrowsWithNoise() throws {
        func sigma(_ noise: Double) throws -> Double {
            var sim = KitFlatSim(slab: KitFlatSim.vec(5, 0), bump: KitFlatSim.vec(1, 90), seed: 21)
            sim.gravityNoise = noise
            let r = KitFlatTilt.twoReading(try XCTUnwrap(sim.reading(psi: 0)), try XCTUnwrap(sim.reading(psi: 180)))
            return try XCTUnwrap(r.uncertaintyDegrees)
        }
        let quiet = try sigma(0.02), loud = try sigma(0.3)
        XCTAssertLessThan(quiet, 0.03)
        XCTAssertGreaterThan(loud, 3 * quiet)
    }

    func testAPhoneNotLyingScreenUpGivesNoTrueTilt() throws {
        // screen down for both readings, turned around between them: before, this "solved" to a 175° tilt with a mirrored
        // bump that later corrected other readings the wrong way
        var sim = KitFlatSim(slab: KitFlatSim.vec(5, 0), bump: KitFlatSim.vec(1, 100), seed: 51)
        let downA = try XCTUnwrap(sim.reading(psi: 0, hand: KitFlatSim.screenDown))
        let downB = try XCTUnwrap(sim.reading(psi: 180, hand: KitFlatSim.screenDown))
        XCTAssertGreaterThan(downA.tiltDegrees, 170)
        XCTAssertFalse(downA.isFlat)
        let r = KitFlatTilt.twoReading(downA, downB)
        XCTAssertEqual(r.method, .failed)
        XCTAssertFalse(r.isUsable)
        XCTAssertNil(r.tiltDegrees); XCTAssertNil(r.solvedBump)
        XCTAssertTrue(r.reasons[0].hasPrefix("The phone was not lying flat, screen up (it read 17"), r.reasons[0])
        XCTAssertEqual(r.readingA, downA); XCTAssertEqual(r.readingB, downB)
        XCTAssertEqual(KitFlatTilt.singleReading(downA, knownBump: nil).method, .failed)
        XCTAssertEqual(KitFlatTilt.result(readingA: downA, readingB: nil, knownBump: nil).method, .failed)
        // on its side: also not a reading of the slab
        let side = try XCTUnwrap(sim.reading(psi: 0, hand: KitFlatSim.onItsSide))
        XCTAssertEqual(side.tiltDegrees, 90, accuracy: 7)
        XCTAssertEqual(KitFlatTilt.twoReading(side, downB).method, .failed)

        // reading A screen up, then B flipped end over end (screen down): B is left out, A stands alone
        for known in [nil, KitBump(degrees: [sim.bump.x, sim.bump.y], uncertaintyDegrees: 0.03)] {
            for tilt in [0.3, 5, 10] {
                var s2 = KitFlatSim(slab: KitFlatSim.vec(tilt, 30), bump: KitFlatSim.vec(1, 100), seed: 52)
                let a = try XCTUnwrap(s2.reading(psi: 0)), b = try XCTUnwrap(s2.reading(psi: 0, hand: KitFlatSim.endOverEnd))
                let one = KitFlatTilt.twoReading(a, b, knownBump: known)
                XCTAssertEqual(one.method, known == nil ? .uncorrected : .bumpCorrected, "tilt \(tilt)")
                XCTAssertTrue(one.reasons[0].hasPrefix("Reading B was left out: the phone was not lying flat, screen up"), one.reasons[0])
                XCTAssertEqual(one.readingB, b)
                if known != nil { XCTAssertEqual(try XCTUnwrap(one.tiltDegrees), tilt, accuracy: 0.05) }
                else { XCTAssertEqual(try XCTUnwrap(one.tiltDegrees), a.tiltDegrees, accuracy: 1e-12) }
                // and the quality check asks for a retry
                let q = KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: one)
                XCTAssertEqual(q.verdict, .poor)
                XCTAssertTrue(q.summary.hasPrefix("Poor. In reading B the phone was not lying flat, screen up"), q.summary)
            }
        }
    }

    func testReadingsThatDoNotFitTogetherAreNotSolved() throws {
        // two flat readings sloping opposite ways, turned 90°: the exact model "solves" them only with a 16-26° camera bump
        func reading(_ tilt: Double, _ az: Double, turn: Double) -> KitFlatReading {
            let t = Units.radians(tilt), a = Units.radians(az)
            return KitFlatReading(samples: 300, start: 0, end: 3, gravity: Vec3(sin(t) * cos(a), sin(t) * sin(a), -cos(t)), spreadDegrees: 0.05,
                                  rmsDegrees: 0.02, attitude: KitQuaternion(axis: Vec3(0, 0, 1), angle: Units.radians(turn)), maxRotationRate: 0.01,
                                  tiltDegrees: tilt, azimuthDegrees: az)
        }
        for (tilt, turn) in [(15.0, 90.0), (24, 90), (24, 61), (20, 65)] {
            let a = reading(tilt, 0, turn: 0), b = reading(tilt, 180, turn: turn)
            let r = KitFlatTilt.twoReading(a, b)
            XCTAssertEqual(r.method, .uncorrected, "\(tilt)° turned \(turn)°")
            XCTAssertTrue(r.reasons[0].hasPrefix("The two readings don't fit together"), r.reasons[0])
            XCTAssertEqual(try XCTUnwrap(r.turnDegrees), turn, accuracy: 1e-6)
            let q = KitQuality.evaluate(shot: try XCTUnwrap(KitPlan.standard.shot("s03-flat-level")), flat: r)
            XCTAssertEqual(q.verdict, .poor)
            XCTAssertEqual(q.check("solve")?.passed, false)
        }
        // a real phone's bump (up to 4°) on slabs up to 20° still solves: covered across many cases above; the edge here
        let g = KitFlatTilt.gravity(slabDegrees: KitFlatSim.vec(20, 0), bumpDegrees: KitFlatSim.vec(4, 180), turnDegrees: 180)
        let ok = KitFlatTilt.twoReading(KitFlatReading.from([KitMotionSample(time: 0, gravity: g.a)])!,
                                        KitFlatReading.from([KitMotionSample(time: 0, gravity: g.b, attitude: KitQuaternion(axis: Vec3(0, 0, 1), angle: .pi))])!)
        XCTAssertEqual(ok.method, .twoReading)
        XCTAssertEqual(try XCTUnwrap(ok.tiltDegrees), 20, accuracy: 1e-6)
    }

    func testSlabNormalInTheMotionFrame() throws {
        for conj in [false, true] {
            var sim = KitFlatSim(slab: KitFlatSim.vec(8, 130), bump: KitFlatSim.vec(1.8, 20), seed: 53)
            sim.yaw = 75
            sim.conjugate = conj
            // the slab's normal in CoreMotion's reference frame: heading Y, then the slab's tilt
            let truth = KitFlatTilt.rz(Units.radians(sim.yaw)) * KitFlatTilt.tiltMatrix(sim.slab * (Double.pi / 180)) * Vec3(0, 0, 1)
            let a = try XCTUnwrap(sim.reading(psi: 25)), b = try XCTUnwrap(sim.reading(psi: 205))
            let r = KitFlatTilt.twoReading(a, b)
            XCTAssertEqual(r.attitudeConjugated, conj)
            let n = try XCTUnwrap(r.slabNormalInMotionFrame)
            XCTAssertLessThan(Units.degrees(n.angle(to: truth)), 0.05, "conjugated \(conj)")
            XCTAssertEqual(Units.degrees(n.angle(to: Vec3(0, 0, 1))), try XCTUnwrap(r.tiltDegrees), accuracy: 0.01)
            // one reading corrected by the bump points the same way; uncorrected, it is off by about the bump
            if !conj {
                let known = KitBump(degrees: [sim.bump.x, sim.bump.y], uncertaintyDegrees: 0.03)
                let one = try XCTUnwrap(KitFlatTilt.singleReading(a, knownBump: known).slabNormalInMotionFrame)
                XCTAssertLessThan(Units.degrees(one.angle(to: truth)), 0.1)
                let raw = try XCTUnwrap(KitFlatTilt.singleReading(a, knownBump: nil).slabNormalInMotionFrame)
                XCTAssertEqual(Units.degrees(raw.angle(to: truth)), 1.8, accuracy: 0.1)
            }
        }
        XCTAssertNil(KitTrueTilt.failed("No reading").slabNormalInMotionFrame)
    }

    func testTrueTiltHelpers() throws {
        let t = KitTrueTilt(method: .twoReading, tiltDegrees: 2, downhillAzimuthDegrees: 90, uncertaintyDegrees: 0.04, bumpDegrees: [1, 0])
        let v = try XCTUnwrap(t.tiltVector)
        XCTAssertEqual(v.x, 0, accuracy: 1e-12); XCTAssertEqual(v.y, 2, accuracy: 1e-12)
        XCTAssertEqual(t.solvedBump, KitBump(degrees: [1, 0], uncertaintyDegrees: 0.04))
        XCTAssertEqual(KitBump(degrees: [3, 4], uncertaintyDegrees: 0).magnitude, 5)
        XCTAssertEqual(KitFlatTilt.azimuth(Vec2(0, -1)), 270)
        XCTAssertEqual(KitFlatTilt.azimuth(Vec2(1, 0)), 0)
        let back = try JSONDecoder().decode(KitTrueTilt.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }
}
