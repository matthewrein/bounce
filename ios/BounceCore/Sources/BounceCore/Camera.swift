import Foundation

/// Pinhole camera intrinsics for one image, in that image's pixels.
///
/// Conventions used throughout BounceCore ("CV" camera axes): x to the right of the image, y down the image, z forward
/// out of the lens. Image coordinates are continuous with the origin at the top-left corner of the top-left pixel, so
/// pixel (i, j) covers [i, i+1) x [j, j+1) and its centre is (i + 0.5, j + 0.5). ARKit's `ARCamera.intrinsics` and
/// `imageResolution` describe the captured image (the sensor's landscape orientation) in this way.
public struct CameraIntrinsics: Equatable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.width = width; self.height = height
    }

    /// Intrinsics from a field of view across the image's height (degrees), principal point in the middle.
    public init(verticalFovDegrees fov: Double, width: Int, height: Int) {
        let f = (Double(height) / 2) / tan(Units.radians(fov) / 2)
        self.init(fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2, width: width, height: height)
    }

    /// From ARKit's 3x3 intrinsics matrix given column-major (simd_float3x3 layout: fx at [0], fy at [4], cx at [6], cy at [7]).
    public init(columnMajor3x3 k: [Double], width: Int, height: Int) {
        precondition(k.count == 9)
        self.init(fx: k[0], fy: k[4], cx: k[6], cy: k[7], width: width, height: height)
    }

    /// The same camera seen through an image resized by `s` (e.g. 0.25 for a quarter-size image).
    public func scaled(by s: Double) -> CameraIntrinsics {
        CameraIntrinsics(fx: fx * s, fy: fy * s, cx: cx * s, cy: cy * s,
                         width: Int((Double(width) * s).rounded()), height: Int((Double(height) * s).rounded()))
    }

    /// The same camera seen through a crop of the image starting at (x0, y0), then resized by `s`.
    public func cropped(x0: Double, y0: Double, scale s: Double, width w: Int, height h: Int) -> CameraIntrinsics {
        CameraIntrinsics(fx: fx * s, fy: fy * s, cx: (cx - x0) * s, cy: (cy - y0) * s, width: w, height: h)
    }

    /// mean focal length in pixels
    public var focal: Double { (fx + fy) / 2 }

    /// Vertical field of view (degrees) across the image height.
    public var verticalFovDegrees: Double { Units.degrees(2 * atan((Double(height) / 2) / fy)) }

    /// Project a point in camera (CV) coordinates; nil if it is behind or at the camera.
    public func project(_ p: Vec3) -> Vec2? {
        guard p.z > 1e-9 else { return nil }
        return Vec2(fx * p.x / p.z + cx, fy * p.y / p.z + cy)
    }

    /// Normalised image coordinates (x/z, y/z) of a pixel.
    public func normalized(_ q: Vec2) -> Vec2 { Vec2((q.x - cx) / fx, (q.y - cy) / fy) }

    /// Direction of the ray through a pixel (z = 1).
    public func ray(_ q: Vec2) -> Vec3 { let n = normalized(q); return Vec3(n.x, n.y, 1) }

    /// The camera-space point at depth z (along the optical axis) seen at pixel q.
    public func unproject(_ q: Vec2, depth z: Double) -> Vec3 { ray(q) * z }

    public func contains(_ q: Vec2, margin: Double = 0) -> Bool {
        q.x >= margin && q.y >= margin && q.x <= Double(width) - margin && q.y <= Double(height) - margin
    }
}

/// Conversions between ARKit's camera axes and BounceCore's CV camera axes.
///
/// ARKit's camera space has x to the right of the captured (landscape) image, y up and z towards the viewer (the camera
/// looks along -z). CV camera space has y down and z forward. So a CV vector is ARKit's with y and z negated.
public enum ARKitConvention {
    /// rotation taking CV camera coordinates to ARKit camera coordinates (its own inverse)
    public static let cvToARKitCamera = Mat3(rows: [1, 0, 0, 0, -1, 0, 0, 0, -1])

    /// World-from-CV-camera transform from ARKit's `camera.transform` (world-from-ARKit-camera).
    public static func worldFromCVCamera(arkitCameraTransform t: RigidTransform) -> RigidTransform {
        RigidTransform(rotation: t.rotation * cvToARKitCamera, translation: t.translation)
    }

    /// ARKit's world (with `.gravity` alignment) has y up, so "down" is -y.
    public static let worldDown = Vec3(0, -1, 0)
}

/// One camera view in the world: where the camera is and what it sees.
public struct CameraView: Equatable, Codable {
    /// CV camera coordinates -> world coordinates (metres)
    public var worldFromCamera: RigidTransform
    public var intrinsics: CameraIntrinsics

    public init(worldFromCamera: RigidTransform, intrinsics: CameraIntrinsics) {
        self.worldFromCamera = worldFromCamera; self.intrinsics = intrinsics
    }

    public var cameraFromWorld: RigidTransform { worldFromCamera.inverse }
    public var position: Vec3 { worldFromCamera.translation }

    public func toCamera(_ p: Vec3) -> Vec3 { cameraFromWorld.apply(p) }
    public func toWorld(_ p: Vec3) -> Vec3 { worldFromCamera.apply(p) }

    /// Project a world point into the image; nil if behind the camera.
    public func project(world p: Vec3) -> Vec2? { intrinsics.project(toCamera(p)) }

    /// World-space ray (origin, unit direction) through an image point.
    public func ray(through q: Vec2) -> (origin: Vec3, direction: Vec3) {
        (position, worldFromCamera.applyDirection(intrinsics.ray(q)).normalized)
    }

    /// A world direction (e.g. gravity) in camera coordinates.
    public func directionToCamera(_ v: Vec3) -> Vec3 { cameraFromWorld.applyDirection(v) }
}
