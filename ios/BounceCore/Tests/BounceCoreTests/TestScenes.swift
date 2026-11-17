import Foundation
@testable import BounceCore

/// Deterministic random numbers for tests.
struct SeededRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func gaussian() -> Double {
        let u1 = max(1e-12, next()), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A synthetic view of the slab from a phone camera, in CV camera coordinates.
struct SyntheticView {
    var intrinsics: CameraIntrinsics
    var down: Vec3           // gravity in camera coordinates
    var pose: SlabPose       // true pose in camera coordinates
    var spec: SlabSpec

    /// - Parameters: pitch: how far the camera looks down (deg); distance: to the slab's centre (m); tilt / heading:
    ///   the slab's tilt from level and the direction it leans (deg); yaw: the slab's turn about the vertical (deg)
    static func make(pitch: Double = 50, roll: Double = 0, distance: Double = 1.2, tilt: Double = 8, heading: Double = 30,
                     yaw: Double = 15, spec: SlabSpec = .standard, intrinsics: CameraIntrinsics? = nil,
                     offset: Vec2 = .zero) -> SyntheticView {
        let K = intrinsics ?? CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        // world: y up. Camera looks along forward, pitched down.
        let p = Units.radians(pitch), r = Units.radians(roll)
        var fwd = Vec3(0, -sin(p), cos(p))
        var right = Vec3(1, 0, 0)
        var upCam = right.cross(fwd) // camera's "up" (CV -y)
        if r != 0 { right = right.rotated(by: fwd * r); upCam = upCam.rotated(by: fwd * r) }
        fwd = fwd.normalized
        // camera axes in world: x = right, y = -upCam (down the image), z = fwd
        let camFromWorld = Mat3(rows: [right.x, right.y, right.z, -upCam.x, -upCam.y, -upCam.z, fwd.x, fwd.y, fwd.z])
        let toCam = { (v: Vec3) -> Vec3 in camFromWorld * v }
        // slab in world: centre on the line of sight (plus an offset), tilted
        let centreW = fwd * distance + right * offset.x + upCam * offset.y
        let th = Units.radians(tilt), hd = Units.radians(heading), yw = Units.radians(yaw)
        let nW = Vec3(sin(th) * cos(hd), cos(th), sin(th) * sin(hd))
        let u0 = Vec3(cos(yw), 0, sin(yw))
        let uW = u0.rejecting(nW).normalized, vW = nW.cross(uW)
        let pose = SlabPose(center: toCam(centreW), normal: toCam(nW), axisU: toCam(uW), axisV: toCam(vW), halfU: spec.halfU, halfV: spec.halfV)
        return SyntheticView(intrinsics: K, down: toCam(Vec3(0, -1, 0)), pose: pose, spec: spec)
    }

    var corners: [Vec2] { pose.topCorners.map { intrinsics.project($0)! } }

    func noisyCorners(sigma: Double, rng: inout SeededRandom) -> [Vec2] {
        corners.map { Vec2($0.x + rng.gaussian() * sigma, $0.y + rng.gaussian() * sigma) }
    }
}

extension Vec3 {
    var deg: Double { Units.degrees(length) }
}

func angleDeg(_ a: Vec3, _ b: Vec3) -> Double { Units.degrees(a.angle(to: b)) }
