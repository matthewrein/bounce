import Foundation

/// The rotation from CoreMotion's reference frame to ARKit's world, for one run of CoreMotion updates and one ARSession
/// (CaptureKit.md, "The downhill direction and ARKit's world"). With it, a flat-phone shot's slab normal
/// (`KitTrueTilt.slabNormalInMotionFrame`, known in CoreMotion's frame) is compared with the tracker's normal in ARKit's
/// world: the downhill direction is scored, not only the tilt's size.
///
/// Both frames are gravity-aligned (CoreMotion's `xArbitraryZVertical`: z up; ARKit's `.gravity` world: y up), so the
/// rotation is a fixed axis swap and a turn about the vertical (the reference frame's arbitrary heading):
/// `world = Ry(yaw) · A0 · ref`, where A0 takes ref x to world x, ref y to world -z and ref z to world y.
///
/// It is estimated from a video shot that has both streams: at each video frame, the attitude (device to reference
/// frame, interpolated to the frame's time) and ARKit's camera pose (ARKit camera to world) give
/// `world-from-ref = R_world←camera · D^T · R_ref←device^T`, with D the fixed device-from-ARKit-camera axes (ARKit's camera
/// x runs along the phone's long axis toward the Home button, that is device -y; its y is device x; z is device z, out
/// of the screen). The yaw is the circular mean over the frames; the spread of the per-frame yaws (RMS) and how far each
/// per-frame rotation's vertical is from the world's (median) say how well the two streams agree. The attitude
/// convention is the documented one (`KitMotionSample.attitude`: device to reference frame) unless the opposite fits
/// gravity clearly better (`attitudeConjugated`).
public struct KitMotionLink: Codable, Equatable {
    /// the reference frame's heading in ARKit's world (degrees)
    public var yawDegrees: Double
    /// video frames matched with a motion sample
    public var samples: Int
    /// RMS spread of the per-frame yaws (degrees)
    public var yawSpreadDegrees: Double
    /// median angle between the reference frame's vertical carried into the world and the world's vertical (degrees)
    public var gravityMismatchDegrees: Double
    /// the attitudes read as the opposite quaternion convention to the documented one
    public var attitudeConjugated: Bool
    /// the video shot it was estimated from
    public var shotId: String

    /// Limits for a usable link.
    public static let minSamples = 10
    public static let maxGravityMismatchDegrees = 2.0
    public static let maxYawSpreadDegrees = 3.0
    /// a motion sample farther than this from a frame's time (s) does not match it
    public static let maxGap = 0.02

    /// device axes from ARKit camera axes (v_device = D v_camera)
    public static let deviceFromARKitCamera = Mat3(columns: Vec3(0, -1, 0), Vec3(1, 0, 0), Vec3(0, 0, 1))
    /// ARKit world from CoreMotion's reference frame at yaw 0
    public static let worldFromReferenceAtZeroYaw = Mat3(columns: Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0))

    public init(yawDegrees: Double, samples: Int, yawSpreadDegrees: Double, gravityMismatchDegrees: Double, attitudeConjugated: Bool,
                shotId: String) {
        self.yawDegrees = yawDegrees; self.samples = samples; self.yawSpreadDegrees = yawSpreadDegrees
        self.gravityMismatchDegrees = gravityMismatchDegrees; self.attitudeConjugated = attitudeConjugated; self.shotId = shotId
    }

    /// world-from-reference rotation
    public var rotation: Mat3 { KitMotionLink.ry(Units.radians(yawDegrees)) * KitMotionLink.worldFromReferenceAtZeroYaw }

    /// A direction in CoreMotion's reference frame, in ARKit's world.
    public func toWorld(_ v: Vec3) -> Vec3 { rotation * v }

    static func ry(_ a: Double) -> Mat3 {
        let c = cos(a), s = sin(a)
        return Mat3(rows: [c, 0, s, 0, 1, 0, -s, 0, c])
    }

    /// The attitude (device to reference frame) at time t, interpolated between the two nearest samples (normalised
    /// linear interpolation of sign-aligned quaternions); nil when no sample lies within `maxGap` on either side.
    static func attitude(at t: Double, in motion: [KitMotionSample], maxGap: Double) -> KitQuaternion? {
        guard !motion.isEmpty else { return nil }
        var lo = 0, hi = motion.count - 1
        if t <= motion[0].time { return t >= motion[0].time - maxGap ? motion[0].attitude.normalized : nil }
        if t >= motion[hi].time { return t <= motion[hi].time + maxGap ? motion[hi].attitude.normalized : nil }
        while hi - lo > 1 { let m = (lo + hi) / 2; if motion[m].time <= t { lo = m } else { hi = m } }
        let a = motion[lo], b = motion[hi], span = b.time - a.time
        guard a.attitude.isFinite, b.attitude.isFinite else { return nil }
        if span > 2 * maxGap {
            // a gap in the samples: only a sample close enough counts
            if t - a.time <= maxGap { return a.attitude.normalized }
            if b.time - t <= maxGap { return b.attitude.normalized }
            return nil
        }
        let f = span > 0 ? (t - a.time) / span : 0
        let qa = a.attitude.normalized, qb0 = b.attitude.normalized
        let qb = qa.dot(qb0) < 0 ? KitQuaternion(x: -qb0.x, y: -qb0.y, z: -qb0.z, w: -qb0.w) : qb0
        return KitQuaternion(x: qa.x + (qb.x - qa.x) * f, y: qa.y + (qb.y - qa.y) * f, z: qa.z + (qb.z - qa.z) * f,
                             w: qa.w + (qb.w - qa.w) * f).normalized
    }

    /// The outcome of estimating a link.
    public enum Estimate: Equatable {
        case linked(KitMotionLink)
        /// why not, in plain English
        case failed(String)

        public var link: KitMotionLink? { if case let .linked(l) = self { return l } else { return nil } }
        public var reason: String? { if case let .failed(r) = self { return r } else { return nil } }
    }

    /// Estimates the link from one video shot's frames (ARKit poses) and motion samples (same clock). Frames with ARKit
    /// tracking not "normal" are left out.
    public static func estimate(frames: [KitFrame], motion: [KitMotionSample], shotId: String) -> Estimate {
        let ms = motion.filter { $0.time.isFinite && $0.attitude.isFinite }.sorted { $0.time < $1.time }
        var pairs: [(world: Mat3, att: KitQuaternion)] = []
        for f in frames where f.tracking.isNormal {
            guard let w = f.worldFromCamera, let q = attitude(at: f.time, in: ms, maxGap: maxGap) else { continue }
            pairs.append((w.rotation, q))
        }
        guard pairs.count >= minSamples else {
            return .failed("only \(pairs.count) video frames of \(shotId) have a motion sample at the same time (at least \(minSamples) needed)")
        }
        let D = deviceFromARKitCamera, Dt = D.transposed, A0t = worldFromReferenceAtZeroYaw.transposed
        func fit(conjugated: Bool) -> (yaw: Double, spread: Double, mismatch: Double) {
            var yaws: [Double] = [], mism: [Double] = []
            for p in pairs {
                let q = conjugated ? p.att.conjugate : p.att
                let W = p.world * Dt * q.matrix.transposed      // world from reference
                mism.append(Units.degrees(KitFlatTilt.angle(W * Vec3(0, 0, 1), Vec3(0, 1, 0))))
                let B = W * A0t                                   // about Ry(yaw)
                yaws.append(atan2(B[0, 2] - B[2, 0], B[0, 0] + B[2, 2]))
            }
            let mean = atan2(yaws.reduce(0) { $0 + sin($1) }, yaws.reduce(0) { $0 + cos($1) })
            let dev = yaws.map { remainder($0 - mean, 2 * .pi) }
            let rms = (dev.reduce(0) { $0 + $1 * $1 } / Double(dev.count)).squareRoot()
            return (mean, Units.degrees(rms), KitStats.median(mism))
        }
        let a = fit(conjugated: false), b = fit(conjugated: true)
        // the opposite convention only when it fits gravity clearly better
        let useB = b.mismatch + 1 < a.mismatch
        let r = useB ? b : a
        guard r.mismatch <= maxGravityMismatchDegrees else {
            return .failed(String(format: "CoreMotion's vertical and ARKit's disagree by %.1f° in %@", r.mismatch, shotId))
        }
        guard r.spread <= maxYawSpreadDegrees else {
            return .failed(String(format: "the heading between CoreMotion and ARKit wanders by %.1f° (RMS) over %@", r.spread, shotId))
        }
        var yaw = Units.degrees(r.yaw)
        if yaw < 0 { yaw += 360 }
        return .linked(KitMotionLink(yawDegrees: yaw, samples: pairs.count, yawSpreadDegrees: r.spread,
                                     gravityMismatchDegrees: r.mismatch, attitudeConjugated: useB, shotId: shotId))
    }

    /// The attitude (device to reference frame) of a camera pose under a link: the inverse of `estimate`, for synthetic
    /// kits and tests. `worldFromCamera`: ARKit's world-from-ARKit-camera rotation.
    public func attitude(worldFromARKitCamera R: Mat3) -> KitQuaternion {
        KitQuaternion(matrix: rotation.transposed * R * KitMotionLink.deviceFromARKitCamera.transposed)
    }
}
