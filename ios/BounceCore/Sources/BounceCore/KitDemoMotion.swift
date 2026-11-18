import Foundation

// A phone lying flat on the demo's slab, for the capture kit's flat-phone shot where there is no CoreMotion (the
// Simulator, the UI tests). See CaptureKit.md, "True tilt from the phone lying flat".

/// CoreMotion-like samples of a phone lying on a tilted slab, from the exact model the flat-phone solver uses:
/// phone-in-reference `R = Y · T · Rz(psi) · H · B`, with Y the reference frame's arbitrary heading, T the slab's tilt,
/// psi the phone's turn about the slab's normal, H the owner's hand (identity while the phone lies on the slab) and B
/// the rest on a (fake) camera bump. Gravity in device axes is `Rᵀ (0,0,-1)`; the attitude is R as a quaternion (the
/// documented convention of `KitMotionSample.attitude`).
///
/// The phone lies still with its top pointing away until the shot asks for the turn (`KitFlatSession.Phase`
/// `.waitingForLift`). `turnDelay` seconds later it is picked up, turned by `turnDegrees` over `turnSeconds` (lifted a
/// little on the way), and laid down again, still. Noise-free, so the shot's result is the model's truth.
public struct KitDemoFlatPhone: Equatable {
    /// the slab's tilt (degrees)
    public var tiltDegrees: Double
    /// which way it slopes down, in phone-A axes (from the phone's right toward its top), degrees
    public var downhillAzimuthDegrees: Double
    /// the fake camera bump, [x, y] degrees in phone axes (`defaultBump` is 1.5°)
    public var bump: Vec2
    /// how far the phone is turned between the readings (degrees)
    public var turnDegrees: Double = 180
    /// seconds from the turn prompt to the phone being picked up
    public var turnDelay: Double = 1
    /// seconds the turn takes, hand to slab
    public var turnSeconds: Double = 0.4
    /// how far the hand lifts and tilts the phone during the turn (degrees)
    public var liftDegrees: Double = 15
    /// the reference frame's arbitrary heading (degrees)
    public var headingDegrees: Double = 25

    /// when the turn starts (set once the session asks for it)
    public private(set) var turnStart: Double? = nil

    /// a camera bump of 1.5°
    public static let defaultBump = Vec2(0.9, -1.2)

    public init(tiltDegrees: Double, downhillAzimuthDegrees: Double = 90, bump: Vec2 = KitDemoFlatPhone.defaultBump) {
        self.tiltDegrees = tiltDegrees; self.downhillAzimuthDegrees = downhillAzimuthDegrees; self.bump = bump
    }

    /// the slab's tilt vector in phone-A axes (degrees)
    public var slabVector: Vec2 {
        let a = Units.radians(downhillAzimuthDegrees)
        return Vec2(tiltDegrees * cos(a), tiltDegrees * sin(a))
    }

    static func rz(_ degrees: Double) -> Mat3 {
        let a = Units.radians(degrees), c = cos(a), s = sin(a)
        return Mat3(rows: [c, -s, 0, s, c, 0, 0, 0, 1])
    }

    static func rx(_ degrees: Double) -> Mat3 {
        let a = Units.radians(degrees), c = cos(a), s = sin(a)
        return Mat3(rows: [1, 0, 0, 0, c, -s, 0, s, c])
    }

    /// The phone's orientation in the reference frame at turn `psi` (degrees), with the hand tilting it by `hand` degrees.
    public func rotation(psi: Double, hand: Double = 0) -> Mat3 {
        KitDemoFlatPhone.rz(headingDegrees) * KitFlatTilt.tiltMatrix(slabVector * (Double.pi / 180)) * KitDemoFlatPhone.rz(psi)
            * KitDemoFlatPhone.rx(hand) * KitFlatTilt.tiltMatrix(bump * (Double.pi / 180))
    }

    /// The sample at time `t` (seconds of uptime; call in time order), given the flat-phone session's phase now.
    public mutating func sample(at t: Double, phase: KitFlatSession.Phase) -> KitMotionSample {
        if turnStart == nil, phase == .waitingForLift { turnStart = t + turnDelay }
        var psi = 0.0, hand = 0.0, rate = Vec3.zero
        if let t0 = turnStart, t >= t0 {
            let f = turnSeconds > 0 ? min(1, (t - t0) / turnSeconds) : 1
            psi = turnDegrees * f
            if f < 1 {
                hand = liftDegrees * sin(.pi * f)
                // the turn's rate about the slab's normal, and the hand's about x (rad/s)
                let dpsi = Units.radians(turnDegrees) / max(turnSeconds, 1e-3)
                let dhand = Units.radians(liftDegrees) * .pi * cos(.pi * f) / max(turnSeconds, 1e-3)
                rate = Vec3(dhand, 0, dpsi)
            }
        }
        let R = rotation(psi: psi, hand: hand)
        return KitMotionSample(time: t, gravity: R.transposed * Vec3(0, 0, -1), userAcceleration: .zero, rotationRate: rate,
                               attitude: KitQuaternion(matrix: R))
    }
}
