import ARKit
import BounceCore
import CoreVideo
import Foundation
import simd

/// Conversions from ARKit / CoreVideo types to BounceCore's plain types.
enum FrameConversion {
    /// ARKit's camera.transform (world from ARKit camera) as a BounceCore transform.
    static func rigid(_ m: simd_float4x4) -> RigidTransform {
        let c = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        var a: [Double] = []
        a.reserveCapacity(16)
        for col in c { a.append(Double(col.x)); a.append(Double(col.y)); a.append(Double(col.z)); a.append(Double(col.w)) }
        return RigidTransform(columnMajor4x4: a)
    }

    static func columnMajor(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
    }

    /// The captured image's intrinsics (pixels of `camera.imageResolution`).
    static func intrinsics(_ camera: ARCamera) -> CameraIntrinsics {
        let k = camera.intrinsics
        let a = [k.columns.0, k.columns.1, k.columns.2].flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
        return CameraIntrinsics(columnMajor3x3: a, width: Int(camera.imageResolution.width), height: Int(camera.imageResolution.height))
    }

    /// The camera as BounceCore sees it (CV axes) for the full captured image.
    static func view(_ camera: ARCamera) -> BounceCore.CameraView {
        BounceCore.CameraView(worldFromCamera: ARKitConvention.worldFromCVCamera(arkitCameraTransform: rigid(camera.transform)),
                              intrinsics: intrinsics(camera))
    }

    static func vec(_ v: simd_float3) -> Vec3 { Vec3(Double(v.x), Double(v.y), Double(v.z)) }
    static func simd(_ v: Vec3) -> simd_float3 { simd_float3(Float(v.x), Float(v.y), Float(v.z)) }

    /// The captured image (bi-planar 4:2:0 YCbCr) shrunk by an integer factor.
    static func ycc(_ pb: CVPixelBuffer, factor k: Int) -> YCCImage? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let lb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        guard let y0 = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c0 = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let luma = UnsafeBufferPointer(start: y0.assumingMemoryBound(to: UInt8.self), count: lb * h)
        let chroma = UnsafeBufferPointer(start: c0.assumingMemoryBound(to: UInt8.self), count: cb * ch)
        return YCCImage.fromBiplanar(luma: luma, lumaWidth: w, lumaHeight: h, lumaBytesPerRow: lb, cbcr: chroma, cbcrBytesPerRow: cb, factor: k)
    }

    /// A crop of the full-resolution luma plane, shrunk by an integer factor, as a Float plane.
    static func lumaCrop(_ pb: CVPixelBuffer, x0: Int, y0: Int, width cw: Int, height chh: Int, factor k: Int) -> Plane? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), lb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)
        let ax = max(0, min(w - 1, x0)), ay = max(0, min(h - 1, y0))
        let ow = min(cw, w - ax) / k, oh = min(chh, h - ay) / k
        guard ow > 8, oh > 8 else { return nil }
        var d = [Float](repeating: 0, count: ow * oh)
        let inv = 1 / Float(k * k)
        for yy in 0..<oh {
            for xx in 0..<ow {
                var s = 0
                for dy in 0..<k { let r = (ay + yy * k + dy) * lb + ax + xx * k; for dx in 0..<k { s += Int(src[r + dx]) } }
                d[yy * ow + xx] = Float(s) * inv
            }
        }
        return Plane(width: ow, height: oh, data: d)
    }

    /// LiDAR depth (metres, Float32) and confidence (0-2) as a BounceCore DepthMap.
    static func depth(_ d: ARDepthData) -> DepthMap? {
        let dm = d.depthMap
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm), rb = CVPixelBufferGetBytesPerRow(dm)
        guard CVPixelBufferGetPixelFormatType(dm) == kCVPixelFormatType_DepthFloat32, let base = CVPixelBufferGetBaseAddress(dm) else { return nil }
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { depth[y * w + x] = row[x] }
        }
        var conf = [UInt8](repeating: 2, count: w * h)
        if let cm = d.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(cm, .readOnly) }
            if CVPixelBufferGetWidth(cm) == w, CVPixelBufferGetHeight(cm) == h, let cb = CVPixelBufferGetBaseAddress(cm) {
                let crb = CVPixelBufferGetBytesPerRow(cm)
                for y in 0..<h {
                    let row = cb.advanced(by: y * crb).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w { conf[y * w + x] = row[x] }
                }
            }
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: conf)
    }
}
