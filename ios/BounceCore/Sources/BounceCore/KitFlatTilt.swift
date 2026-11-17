import Foundation

// The slab's true tilt from the phone lying flat on it (CaptureKit.md, "True tilt from the phone lying flat").
//
// Gravity in the phone's axes (CoreMotion: x right, y toward the top, z out of the screen) gives the tilt of whatever the
// phone lies on, except that a phone on its back rests on its camera bump. So the owner takes two readings, A with the
// top pointing away and B after turning the phone around. Model: phone-in-world R_k = T · Rz(psi_k) · B, with T the
// slab's tilt, Rz(psi_k) the phone's turn about the slab's normal and B the fixed rest on the bump. The turn
// psi_B - psi_A comes from the attitude readings; the four unknowns (the slab's tilt and the bump, 2 dof each) come from
// the two gravity readings: a small-angle start, then Gauss-Newton on the exact model.
//
// Tilts are given as vectors (degrees): the direction is the way the surface slopes down (where gravity's in-plane part
// points), the length the tilt. "Phone-A axes": the slab's plane seen with the phone's right (x) and top (y) as they lay
// in reading A; azimuths are measured from x toward y.

/// The phone's rest on its camera bump: the tilt the phone reads lying on a level surface, as a vector [x, y] in
/// degrees (phone axes) pointing the way it leans down.
public struct KitBump: Codable, Equatable {
    public var degrees: [Double]
    public var uncertaintyDegrees: Double
    public init(degrees: [Double], uncertaintyDegrees: Double) { self.degrees = degrees; self.uncertaintyDegrees = uncertaintyDegrees }
    public var vector: Vec2 { degrees.count == 2 ? Vec2(degrees[0], degrees[1]) : .zero }
    /// how far the phone leans on its bump (degrees)
    public var magnitude: Double { vector.length }
}

/// Statistics of one flat-phone reading: a window of motion samples with the phone lying still.
public struct KitFlatReading: Codable, Equatable {
    public var samples: Int
    /// first and last sample times (s)
    public var start: Double
    public var end: Double
    /// robust mean gravity direction (unit vector, phone axes)
    public var gravity: Vec3
    /// the largest angle of any sample's gravity from the mean (degrees): how still the phone lay
    public var spreadDegrees: Double
    /// RMS angle of the samples' gravity from the mean (degrees)
    public var rmsDegrees: Double
    /// mean attitude (CoreMotion quaternion, sign-aligned average)
    public var attitude: KitQuaternion
    /// largest rotation rate seen (rad/s)
    public var maxRotationRate: Double
    /// the phone's own tilt: the angle of gravity from straight down through the screen (degrees)
    public var tiltDegrees: Double
    /// which way the phone slopes down, phone axes, from x (right) toward y (top), 0..<360 degrees
    public var azimuthDegrees: Double

    /// Statistics of a window of samples; nil when no sample has a usable gravity reading.
    public static func from(_ window: [KitMotionSample]) -> KitFlatReading? {
        let usable = window.filter { $0.gravity.isFinite && $0.gravity.length > 0.1 }
        guard let first = usable.first, let last = usable.last else { return nil }
        let gs = usable.map { $0.gravity.normalized }
        var mean = gs.reduce(Vec3.zero, +).normalized
        // robust mean: drop samples far from the first mean (a knock), then average again
        let angles = gs.map { KitFlatTilt.angle($0, mean) }
        let cutoff = max(4 * KitStats.median(angles), Units.radians(0.02))
        let kept = gs.filter { KitFlatTilt.angle($0, mean) <= cutoff }
        if !kept.isEmpty { mean = kept.reduce(Vec3.zero, +).normalized }
        let finalAngles = gs.map { KitFlatTilt.angle($0, mean) }
        let spread = finalAngles.max() ?? 0
        let rms = (finalAngles.reduce(0) { $0 + $1 * $1 } / Double(finalAngles.count)).squareRoot()
        // mean attitude: quaternions aligned to the first (q and -q are the same rotation), summed, normalised
        let q0 = first.attitude.normalized
        var sum = KitQuaternion(x: 0, y: 0, z: 0, w: 0)
        for s in usable where s.attitude.isFinite {
            let q = s.attitude.normalized, sign: Double = q.dot(q0) < 0 ? -1 : 1
            sum = KitQuaternion(x: sum.x + sign * q.x, y: sum.y + sign * q.y, z: sum.z + sign * q.z, w: sum.w + sign * q.w)
        }
        let maxRate = usable.map { $0.rotationRate.isFinite ? $0.rotationRate.length : .infinity }.max() ?? 0
        let tilt = Units.degrees(KitFlatTilt.angle(mean, Vec3(0, 0, -1)))
        return KitFlatReading(samples: usable.count, start: first.time, end: last.time, gravity: mean,
                              spreadDegrees: Units.degrees(spread), rmsDegrees: Units.degrees(rms), attitude: sum.normalized,
                              maxRotationRate: maxRate, tiltDegrees: tilt,
                              azimuthDegrees: tilt < 1e-9 ? 0 : KitFlatTilt.azimuth(Vec2(mean.x, mean.y)))
    }
}

/// The slab's true tilt for one slab position: the ground truth the kit's clips are scored against.
public struct KitTrueTilt: Codable, Equatable {
    public enum Method: String, Codable {
        /// two readings with the phone turned around: the camera bump solved out
        case twoReading
        /// one reading, corrected by the bump found earlier in the same kit
        case bumpCorrected
        /// one reading, uncorrected (about 2 degrees uncertain)
        case uncorrected
        /// no usable reading
        case failed
    }

    public var method: Method
    /// the slab's tilt from level (degrees)
    public var tiltDegrees: Double?
    /// which way the slab slopes down, in phone-A axes, from the phone's right toward its top (0..<360 degrees)
    public var downhillAzimuthDegrees: Double?
    /// a rough one-sigma uncertainty of the tilt (degrees)
    public var uncertaintyDegrees: Double?
    /// the bump (two readings: solved; bump-corrected: the one used), [x, y] degrees in phone axes
    public var bumpDegrees: [Double]?
    /// how far the phone was turned between the readings, 0..<360 degrees (about 180 is best)
    public var turnDegrees: Double?
    /// RMS misfit of the exact model to the two gravity readings (degrees)
    public var residualDegrees: Double?
    /// cross-check: the angle between the axis the phone turned about (the slab's normal) and gravity, from the
    /// attitude alone (degrees)
    public var gyroTiltDegrees: Double?
    /// the small-angle start before refinement (degrees), kept for the record
    public var smallAngleTiltDegrees: Double?
    /// how well the attitude readings agree with the gravity readings (degrees; small is good)
    public var attitudeMismatchDegrees: Double?
    /// true when the attitude quaternions read as the opposite convention to the documented one (see KitMotionSample)
    public var attitudeConjugated: Bool?
    public var readingA: KitFlatReading?
    public var readingB: KitFlatReading?
    /// what happened, in plain English
    public var reasons: [String]

    public init(method: Method, tiltDegrees: Double? = nil, downhillAzimuthDegrees: Double? = nil, uncertaintyDegrees: Double? = nil,
                bumpDegrees: [Double]? = nil, turnDegrees: Double? = nil, residualDegrees: Double? = nil, gyroTiltDegrees: Double? = nil,
                smallAngleTiltDegrees: Double? = nil, attitudeMismatchDegrees: Double? = nil, attitudeConjugated: Bool? = nil,
                readingA: KitFlatReading? = nil, readingB: KitFlatReading? = nil, reasons: [String] = []) {
        self.method = method; self.tiltDegrees = tiltDegrees; self.downhillAzimuthDegrees = downhillAzimuthDegrees
        self.uncertaintyDegrees = uncertaintyDegrees; self.bumpDegrees = bumpDegrees; self.turnDegrees = turnDegrees
        self.residualDegrees = residualDegrees; self.gyroTiltDegrees = gyroTiltDegrees; self.smallAngleTiltDegrees = smallAngleTiltDegrees
        self.attitudeMismatchDegrees = attitudeMismatchDegrees; self.attitudeConjugated = attitudeConjugated
        self.readingA = readingA; self.readingB = readingB; self.reasons = reasons
    }

    public static func failed(_ reason: String, readingA: KitFlatReading? = nil) -> KitTrueTilt {
        KitTrueTilt(method: .failed, readingA: readingA, reasons: [reason])
    }

    /// there is a tilt to score against
    public var isUsable: Bool { method != .failed && tiltDegrees != nil }

    /// The bump this result solved, for correcting a later single reading in the same kit (two readings only).
    public var solvedBump: KitBump? {
        guard method == .twoReading, let b = bumpDegrees, b.count == 2 else { return nil }
        return KitBump(degrees: b, uncertaintyDegrees: uncertaintyDegrees ?? 0.1)
    }

    /// The slab's tilt as a vector [x, y] in phone-A axes (degrees), if known.
    public var tiltVector: Vec2? {
        guard let t = tiltDegrees, let a = downhillAzimuthDegrees else { return nil }
        let r = Units.radians(a)
        return Vec2(t * cos(r), t * sin(r))
    }
}

/// The flat-phone maths.
public enum KitFlatTilt {
    /// the turn must be at least this far from 0 (and 360) for the two-reading solve (degrees)
    public static let minTurnDegrees = 60.0
    /// uncertainty of a single uncorrected reading (degrees)
    public static let uncorrectedUncertainty = 2.0

    // MARK: model

    /// Rotation tilting z by a tilt vector (radians): `R.transposed * (0,0,-1)` leans toward `v` by |v|.
    public static func tiltMatrix(_ v: Vec2) -> Mat3 {
        let w = Vec3(-v.y, v.x, 0)
        return Mat3(columns: Vec3(1, 0, 0).rotated(by: w), Vec3(0, 1, 0).rotated(by: w), Vec3(0, 0, 1).rotated(by: w))
    }

    static func rz(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3(rows: [c, -s, 0, s, c, 0, 0, 0, 1])
    }

    /// The exact model (radians): gravity in the phone's axes for readings A and B, given the slab's tilt vector (phone-A
    /// axes), the bump and the turn psi_B - psi_A.
    public static func gravity(slab s: Vec2, bump b: Vec2, turn psi: Double) -> (a: Vec3, b: Vec3) {
        let T = tiltMatrix(s), B = tiltMatrix(b), tDown = T.transposed * Vec3(0, 0, -1)
        return (B.transposed * tDown, B.transposed * (rz(psi).transposed * tDown))
    }

    /// The same in degrees, for tests and the scorer.
    public static func gravity(slabDegrees s: Vec2, bumpDegrees b: Vec2, turnDegrees psi: Double) -> (a: Vec3, b: Vec3) {
        gravity(slab: s * (Double.pi / 180), bump: b * (Double.pi / 180), turn: Units.radians(psi))
    }

    /// Angle between two vectors (radians), by atan2: accurate for the tiny angles of a phone lying still, where acos is not.
    public static func angle(_ a: Vec3, _ b: Vec3) -> Double { atan2(a.cross(b).length, a.dot(b)) }

    /// Azimuth of a 2-D vector, degrees in 0..<360.
    public static func azimuth(_ v: Vec2) -> Double {
        let a = Units.degrees(atan2(v.y, v.x))
        return a < 0 ? a + 360 : (a >= 360 ? a - 360 : a)
    }

    // MARK: solve

    /// Small-angle solution (radians): with m the in-plane parts of gravity, m_A = t + b and m_B = R(-psi) t + b, so
    /// t = (I - R(-psi))^-1 (m_A - m_B), b = m_A - t. nil when the turn is too close to 0.
    public static func smallAngle(gA: Vec3, gB: Vec3, turn psi: Double) -> (slab: Vec2, bump: Vec2)? {
        let a = gA.normalized, b = gB.normalized
        let c = cos(psi), s = sin(psi), det = 2 - 2 * c
        guard det > 1e-9 else { return nil }
        let d = Vec2(a.x - b.x, a.y - b.y)
        // (I - R(-psi)) = [[1-c, -s], [s, 1-c]]; its inverse is [[1-c, s], [-s, 1-c]] / det
        let t = Vec2(((1 - c) * d.x + s * d.y) / det, (-s * d.x + (1 - c) * d.y) / det)
        return (t, Vec2(a.x, a.y) - t)
    }

    /// Exact solve (radians) by Gauss-Newton from the small-angle start. nil when the turn is too close to 0 or the
    /// inputs are not finite.
    public static func solve(gA: Vec3, gB: Vec3, turn psi: Double) -> (slab: Vec2, bump: Vec2, residual: Double, start: Vec2, iterations: Int, converged: Bool)? {
        guard gA.isFinite, gB.isFinite, psi.isFinite, gA.length > 0, gB.length > 0,
              let start = smallAngle(gA: gA, gB: gB, turn: psi) else { return nil }
        let a = gA.normalized, b = gB.normalized
        func residual(_ p: [Double]) -> [Double] {
            let g = gravity(slab: Vec2(p[0], p[1]), bump: Vec2(p[2], p[3]), turn: psi)
            return [g.a.x - a.x, g.a.y - a.y, g.a.z - a.z, g.b.x - b.x, g.b.y - b.y, g.b.z - b.z]
        }
        var p = [start.slab.x, start.slab.y, start.bump.x, start.bump.y]
        var converged = false, iterations = 0
        let h = 1e-7
        for it in 1...50 {
            iterations = it
            let r = residual(p)
            var J = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 6)
            for k in 0..<4 {
                var pp = p, pm = p
                pp[k] += h; pm[k] -= h
                let rp = residual(pp), rm = residual(pm)
                for i in 0..<6 { J[i][k] = (rp[i] - rm[i]) / (2 * h) }
            }
            var JTJ = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4), JTr = [Double](repeating: 0, count: 4)
            for i in 0..<4 {
                for k in 0..<4 { var s = 0.0; for j in 0..<6 { s += J[j][i] * J[j][k] }; JTJ[i][k] = s }
                var s = 0.0; for j in 0..<6 { s += J[j][i] * r[j] }; JTr[i] = -s
            }
            for i in 0..<4 { JTJ[i][i] *= 1 + 1e-12 }
            guard let dp = solveLinear(JTJ, JTr), dp.allSatisfy({ $0.isFinite }) else { break }
            for k in 0..<4 { p[k] += dp[k] }
            if dp.map(abs).max() ?? 0 < 1e-13 { converged = true; break }
        }
        let g = gravity(slab: Vec2(p[0], p[1]), bump: Vec2(p[2], p[3]), turn: psi)
        let res = ((pow(KitFlatTilt.angle(g.a, a), 2) + pow(KitFlatTilt.angle(g.b, b), 2)) / 2).squareRoot()
        // a step below 1e-10 rad is converged for every purpose here, even if the last one did not reach 1e-13
        if !converged && res < 1e-9 { converged = true }
        return (Vec2(p[0], p[1]), Vec2(p[2], p[3]), res, start.slab, iterations, converged)
    }

    /// The turn between two readings from their mean attitudes, in phone-A axes: the angle (0..<2 pi, radians) about the
    /// axis (unit, z >= 0) that is the slab's normal in phone-A axes. The attitude convention is checked against the
    /// gravity readings (the relative rotation must carry g_B onto g_A); `mismatch` is that misfit (radians), and
    /// `conjugated` says the quaternions read as the opposite convention to the documented one.
    public static func turn(attitudeA qA: KitQuaternion, attitudeB qB: KitQuaternion, gA: Vec3, gB: Vec3)
        -> (angle: Double, axis: Vec3, mismatch: Double, conjugated: Bool) {
        let r1 = qA.normalized.conjugate * qB.normalized   // documented: q takes device axes into the reference frame
        let r2 = qA.normalized * qB.normalized.conjugate   // the opposite convention
        let e1 = KitFlatTilt.angle(r1.matrix * gB.normalized, gA.normalized)
        let e2 = KitFlatTilt.angle(r2.matrix * gB.normalized, gA.normalized)
        let useAlt = e2 < 0.5 * e1
        let r = useAlt ? r2 : r1
        let rv = r.rotationVector, th = rv.length
        guard th > 1e-12 else { return (0, Vec3(0, 0, 1), useAlt ? e2 : e1, useAlt) }
        var axis = rv / th, angle = th
        if axis.z < 0 { axis = -axis; angle = 2 * .pi - th }
        return (angle, axis, useAlt ? e2 : e1, useAlt)
    }

    /// One-sigma noise of a reading's mean direction (radians): RMS over the root of the number of independent samples
    /// (CoreMotion's 100 Hz samples are smoothed; about 10 make one independent sample).
    static func meanNoise(_ r: KitFlatReading) -> Double {
        Units.radians(r.rmsDegrees) / max(1, Double(r.samples) / 10).squareRoot()
    }

    /// Two readings, A then B with the phone turned around between them.
    public static func twoReading(_ a: KitFlatReading, _ b: KitFlatReading, knownBump: KitBump? = nil) -> KitTrueTilt {
        let t = turn(attitudeA: a.attitude, attitudeB: b.attitude, gA: a.gravity, gB: b.gravity)
        let turnDeg = Units.degrees(t.angle)
        guard turnDeg >= minTurnDegrees && turnDeg <= 360 - minTurnDegrees else {
            var r = singleReading(a, knownBump: knownBump)
            r.readingB = b; r.turnDegrees = turnDeg
            r.reasons.insert(String(format: "The phone was turned only %.0f°, too little to solve out the camera bump.", min(turnDeg, 360 - turnDeg)), at: 0)
            return r
        }
        guard let sol = solve(gA: a.gravity, gB: b.gravity, turn: t.angle) else {
            var r = singleReading(a, knownBump: knownBump)
            r.readingB = b; r.turnDegrees = turnDeg
            r.reasons.insert("The two readings could not be solved together.", at: 0)
            return r
        }
        let lever = 2 * sin(t.angle / 2) // >= 1 for turns of 60-300 degrees
        let noise = (pow(meanNoise(a), 2) + pow(meanNoise(b), 2)).squareRoot() / lever
        let attitude = t.mismatch / lever
        let sigma = (noise * noise + attitude * attitude + sol.residual * sol.residual + pow(Units.radians(0.01), 2)).squareRoot()
        let tiltDeg = Units.degrees(sol.slab.length)
        var reasons = [String(format: "Two readings, turned %.0f°: camera bump solved out (%.2f°).", turnDeg, Units.degrees(sol.bump.length))]
        if t.conjugated { reasons.append("The attitude readings used the opposite quaternion convention; handled.") }
        if Units.degrees(t.mismatch) > 0.5 { reasons.append(String(format: "The attitude and gravity readings disagree by %.1f°; the turn may be off.", Units.degrees(t.mismatch))) }
        if !sol.converged { reasons.append("The refinement did not fully converge.") }
        return KitTrueTilt(method: .twoReading, tiltDegrees: tiltDeg,
                           downhillAzimuthDegrees: tiltDeg < 1e-9 ? 0 : azimuth(sol.slab),
                           uncertaintyDegrees: Units.degrees(sigma),
                           bumpDegrees: [Units.degrees(sol.bump.x), Units.degrees(sol.bump.y)],
                           turnDegrees: turnDeg, residualDegrees: Units.degrees(sol.residual),
                           gyroTiltDegrees: Units.degrees(KitFlatTilt.angle(t.axis, -a.gravity)),
                           smallAngleTiltDegrees: Units.degrees(sol.start.length),
                           attitudeMismatchDegrees: Units.degrees(t.mismatch), attitudeConjugated: t.conjugated,
                           readingA: a, readingB: b, reasons: reasons)
    }

    /// One reading: corrected by a bump known from earlier in the kit if there is one, otherwise uncorrected.
    public static func singleReading(_ a: KitFlatReading, knownBump: KitBump?) -> KitTrueTilt {
        if let bump = knownBump, bump.degrees.count == 2, bump.vector.length.isFinite {
            let B = tiltMatrix(bump.vector * (Double.pi / 180))
            let v = B * a.gravity.normalized // = T^T (0,0,-1): gravity in the slab's frame
            let tilt = Units.degrees(KitFlatTilt.angle(v, Vec3(0, 0, -1)))
            let sigma = (pow(Units.degrees(meanNoise(a)), 2) + pow(bump.uncertaintyDegrees, 2) + 0.05 * 0.05).squareRoot()
            return KitTrueTilt(method: .bumpCorrected, tiltDegrees: tilt, downhillAzimuthDegrees: tilt < 1e-9 ? 0 : azimuth(Vec2(v.x, v.y)),
                               uncertaintyDegrees: sigma, bumpDegrees: bump.degrees, readingA: a,
                               reasons: [String(format: "One reading, corrected by the camera bump found earlier (%.2f°).", bump.magnitude)])
        }
        return KitTrueTilt(method: .uncorrected, tiltDegrees: a.tiltDegrees, downhillAzimuthDegrees: a.azimuthDegrees,
                           uncertaintyDegrees: uncorrectedUncertainty, readingA: a,
                           reasons: ["One reading and no camera bump known yet: uncorrected (the bump can add a degree or two)."])
    }

    /// The result for a flat-phone shot from whatever readings it got.
    public static func result(readingA a: KitFlatReading?, readingB b: KitFlatReading?, knownBump: KitBump?) -> KitTrueTilt {
        guard let a = a else { return .failed("No reading: the phone did not lie still.") }
        guard let b = b else { return singleReading(a, knownBump: knownBump) }
        return twoReading(a, b, knownBump: knownBump)
    }
}

/// Timings and thresholds of the flat-phone shot. Seconds scale with the plan's time scale.
public struct KitFlatSettings: Codable, Equatable {
    /// the phone must be still this long before a reading starts
    public var stillSeconds = 1.0
    /// still: gravity spreads less than this over `stillSeconds` (degrees)...
    public var stillSpreadDegrees = 0.15
    /// ...and the rotation rate stays under this (rad/s)
    public var stillRotationRate = 0.05
    /// a reading averages this long
    public var readingSeconds = 3.0
    /// waiting for reading A gives up after this
    public var timeoutA = 8.0
    /// waiting for reading B (lift, turn, lie still) gives up after this
    public var timeoutB = 15.0
    /// lifted: a rotation rate over this (rad/s)...
    public var liftRotationRate = 0.5
    /// ...or gravity moved more than this from reading A (degrees)
    public var liftDegrees = 3.0
    /// a reading restarts if the phone moves: rotation rate over this (rad/s)...
    public var abortRotationRate = 0.2
    /// ...or gravity moving more than this from where it lay still (degrees)
    public var abortDegrees = 1.0

    public init() {}
    public static let standard = KitFlatSettings()

    public func scaled(by s: Double) -> KitFlatSettings {
        var x = self
        x.stillSeconds *= s; x.readingSeconds *= s; x.timeoutA *= s; x.timeoutB *= s
        return x
    }
}

/// The flat-phone shot as it runs: the app feeds it CoreMotion samples (about 100 Hz) and shows `prompt` and
/// `progress`; it beeps when `phase` becomes `.waitingForLift` and when it becomes `.done`. Not thread-safe.
///
/// waitingForStillA -> readingA -> waitingForLift -> waitingForStillB -> readingB -> done. A reading starts once the
/// phone has been still for `stillSeconds`; if the phone moves during a reading, it waits for stillness again. Waiting
/// for A gives up after `timeoutA` (result: failed); waiting for B after `timeoutB` (result: reading A alone).
public final class KitFlatSession {
    public enum Phase: String, Codable, CaseIterable {
        case waitingForStillA, readingA, waitingForLift, waitingForStillB, readingB, done
    }

    public let settings: KitFlatSettings
    /// a bump solved earlier in the kit, to correct a single reading
    public let knownBump: KitBump?
    public private(set) var phase: Phase = .waitingForStillA
    public private(set) var result: KitTrueTilt?
    public private(set) var readingA: KitFlatReading?
    public private(set) var readingB: KitFlatReading?
    public private(set) var sampleCount = 0
    public private(set) var startTime: Double?
    public private(set) var lastTime: Double?
    /// how often a reading restarted because the phone moved
    public private(set) var restarts = 0

    private var deadline = Double.infinity
    private var window: [KitMotionSample] = []
    private var reading: [KitMotionSample] = []
    private var readingStart = 0.0
    private var stillMean = Vec3(0, 0, -1)
    private var movedDuringReading = false

    public init(settings: KitFlatSettings = .standard, knownBump: KitBump? = nil, startTime: Double? = nil) {
        self.settings = settings; self.knownBump = knownBump; self.startTime = startTime
        if let t = startTime { deadline = t + settings.timeoutA }
    }

    public var isDone: Bool { phase == .done }

    /// Feed one sample. Returns true when the phase changed (beep on `.waitingForLift` and `.done`).
    @discardableResult
    public func feed(_ s: KitMotionSample) -> Bool {
        guard phase != .done, s.time.isFinite, s.gravity.isFinite, s.rotationRate.isFinite else { return false }
        if let last = lastTime, s.time <= last { return false }
        if startTime == nil { startTime = s.time; deadline = s.time + settings.timeoutA }
        lastTime = s.time
        sampleCount += 1
        let before = phase
        switch phase {
        case .waitingForStillA, .waitingForStillB:
            window.append(s)
            while let f = window.first, f.time < s.time - settings.stillSeconds - 1e-9 { window.removeFirst() }
            if isStill(window) {
                stillMean = window.map { $0.gravity.normalized }.reduce(.zero, +).normalized
                reading = []; readingStart = s.time; movedDuringReading = false
                phase = phase == .waitingForStillA ? .readingA : .readingB
            } else if s.time >= deadline {
                timeOut()
            }
        case .readingA, .readingB:
            if s.rotationRate.length > settings.abortRotationRate || Units.degrees(KitFlatTilt.angle(s.gravity, stillMean)) > settings.abortDegrees {
                restarts += 1
                window = [s]
                if phase == .readingA { phase = .waitingForStillA; deadline = s.time + settings.timeoutA }
                else { phase = .waitingForStillB; deadline = s.time + settings.timeoutB }
                break
            }
            reading.append(s)
            if s.time - readingStart >= settings.readingSeconds - 1e-6 {
                let r = KitFlatReading.from(reading)
                if phase == .readingA {
                    readingA = r
                    phase = .waitingForLift
                    deadline = s.time + settings.timeoutB
                } else {
                    readingB = r
                    complete(KitFlatTilt.result(readingA: readingA, readingB: readingB, knownBump: knownBump))
                }
            }
        case .waitingForLift:
            let ref = readingA?.gravity ?? stillMean
            if s.rotationRate.length > settings.liftRotationRate || Units.degrees(KitFlatTilt.angle(s.gravity, ref)) > settings.liftDegrees {
                phase = .waitingForStillB
                window = []
            } else if s.time >= deadline {
                timeOut()
            }
        case .done:
            break
        }
        return phase != before
    }

    /// Let time pass without samples (e.g. motion updates stopped): applies the timeouts. Returns true on a phase change.
    @discardableResult
    public func advance(to time: Double) -> Bool {
        guard phase != .done, time.isFinite else { return false }
        if startTime == nil { startTime = time; deadline = time + settings.timeoutA }
        switch phase {
        case .waitingForStillA, .waitingForLift, .waitingForStillB:
            if time >= deadline { timeOut(); return true }
        default: break
        }
        return false
    }

    /// Stop now (the owner tapped Stop, or the app is leaving the screen): the result from what was read so far.
    @discardableResult
    public func finish() -> KitTrueTilt {
        if let r = result { return r }
        if readingA != nil {
            var r = KitFlatTilt.result(readingA: readingA, readingB: nil, knownBump: knownBump)
            r.reasons.insert("Stopped before the second reading.", at: 0)
            complete(r)
        } else {
            complete(.failed("Stopped before the phone lay still."))
        }
        return result ?? .failed("Stopped.")
    }

    /// Seconds left before the current wait gives up (nil while reading or done).
    public var secondsLeft: Double? {
        guard let now = lastTime ?? startTime, deadline.isFinite else { return nil }
        switch phase {
        case .waitingForStillA, .waitingForLift, .waitingForStillB: return max(0, deadline - now)
        default: return nil
        }
    }

    /// 0...1 for a progress bar.
    public var progress: Double {
        func frac() -> Double {
            guard let now = lastTime, settings.readingSeconds > 0 else { return 0 }
            return clamp((now - readingStart) / settings.readingSeconds, 0, 1)
        }
        switch phase {
        case .waitingForStillA: return 0
        case .readingA: return 0.05 + 0.40 * frac()
        case .waitingForLift: return 0.45
        case .waitingForStillB: return 0.5
        case .readingB: return 0.55 + 0.45 * frac()
        case .done: return 1
        }
    }

    /// What the screen says now.
    public var prompt: String {
        switch phase {
        case .waitingForStillA:
            return restarts == 0 ? "Lay the phone flat in the middle of the slab, screen up, top pointing away. Let go."
                                 : "It moved. Let go of the phone and keep the slab still."
        case .readingA, .readingB:
            return "Reading. Don't touch the phone or the slab."
        case .waitingForLift:
            return "Now pick the phone up and turn it around, top toward you."
        case .waitingForStillB:
            return "Lay it flat in the middle again, top toward you, and let go."
        case .done:
            guard let r = result, let t = r.tiltDegrees else { return "No reading: the phone did not lie still." }
            switch r.method {
            case .twoReading: return String(format: "Done: the slab tilts %.1f°.", t)
            default: return String(format: "Done (one reading): the slab tilts about %.1f°.", t)
            }
        }
    }

    private func isStill(_ w: [KitMotionSample]) -> Bool {
        guard w.count >= 5, let f = w.first, let l = w.last, l.time - f.time >= settings.stillSeconds * 0.97 else { return false }
        guard w.allSatisfy({ $0.rotationRate.length < settings.stillRotationRate }) else { return false }
        let mean = w.map { $0.gravity.normalized }.reduce(.zero, +).normalized
        let limit = Units.radians(settings.stillSpreadDegrees)
        return w.allSatisfy { KitFlatTilt.angle($0.gravity, mean) < limit }
    }

    private func timeOut() {
        switch phase {
        case .waitingForStillA:
            complete(.failed(String(format: "No reading: the phone did not lie still within %.0f s.", settings.timeoutA)))
        case .waitingForLift:
            var r = KitFlatTilt.result(readingA: readingA, readingB: nil, knownBump: knownBump)
            r.reasons.insert("The phone was not turned around in time.", at: 0)
            complete(r)
        case .waitingForStillB:
            var r = KitFlatTilt.result(readingA: readingA, readingB: nil, knownBump: knownBump)
            r.reasons.insert("The phone did not lie still again after turning.", at: 0)
            complete(r)
        default:
            break
        }
    }

    private func complete(_ r: KitTrueTilt) {
        result = r
        phase = .done
        deadline = .infinity
    }
}

/// Small statistics helpers for the kit.
public enum KitStats {
    /// median (nil-safe: 0 for an empty list)
    public static func median(_ v: [Double]) -> Double {
        let s = v.filter { !$0.isNaN }.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// the p-th percentile (0...100), linear between ranks; 0 for an empty list
    public static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.filter { !$0.isNaN }.sorted()
        guard !s.isEmpty else { return 0 }
        let x = clamp(p, 0, 100) / 100 * Double(s.count - 1), i = Int(x.rounded(.down)), f = x - Double(i)
        return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
    }
}
