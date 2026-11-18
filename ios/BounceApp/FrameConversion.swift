import Accelerate
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

    /// ARKit's own Float values, column-major (the capture kit's `KitFrame.pose`).
    static func columnMajorFloats(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    /// A BounceCore camera view (CV axes) as ARKit's world-from-camera transform, column-major (the demo's `KitFrame.pose`).
    static func arkitPose(_ view: BounceCore.CameraView) -> [Float] {
        let t = view.worldFromCamera
        return RigidTransform(rotation: t.rotation * ARKitConvention.cvToARKitCamera, translation: t.translation).columnMajor4x4.map { Float($0) }
    }

    /// Mean luma (0-255) of a camera buffer's Y plane, every 8th pixel in x and y (the capture kit's per-frame light).
    static func meanLuma(_ pb: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bpr * h)
        return KitImageStats.meanLuma(bytes: bytes, width: w, height: h, bytesPerRow: bpr, step: 8)
    }

    /// Scale a bi-planar 4:2:0 camera image into another bi-planar 4:2:0 buffer of any size (vImage, Lanczos; luma and
    /// interleaved chroma each scaled on their own). Synchronous: when it returns, nothing refers to `src`.
    static func scale(_ src: CVPixelBuffer, into dst: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPlaneCount(src) >= 2, CVPixelBufferGetPlaneCount(dst) >= 2 else { return false }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane), let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { return false }
            var sb = vImage_Buffer(data: s, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(src, plane)),
                                   width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(src, plane)),
                                   rowBytes: CVPixelBufferGetBytesPerRowOfPlane(src, plane))
            var db = vImage_Buffer(data: d, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(dst, plane)),
                                   width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(dst, plane)),
                                   rowBytes: CVPixelBufferGetBytesPerRowOfPlane(dst, plane))
            let err = plane == 0 ? vImageScale_Planar8(&sb, &db, nil, vImage_Flags(kvImageNoFlags))
                                 : vImageScale_CbCr8(&sb, &db, nil, vImage_Flags(kvImageNoFlags))
            if err != kvImageNoError { return false }
        }
        return true
    }

    /// Copy a demo frame (YCCImage, planar) into a bi-planar 4:2:0 buffer of the same size.
    static func fill(_ dst: CVPixelBuffer, from img: YCCImage) -> Bool {
        guard CVPixelBufferGetPlaneCount(dst) >= 2, CVPixelBufferGetWidthOfPlane(dst, 0) == img.width,
              CVPixelBufferGetHeightOfPlane(dst, 0) == img.height,
              CVPixelBufferGetWidthOfPlane(dst, 1) == img.chromaWidth, CVPixelBufferGetHeightOfPlane(dst, 1) == img.chromaHeight else { return false }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let y0 = CVPixelBufferGetBaseAddressOfPlane(dst, 0), let c0 = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else { return false }
        let yb = CVPixelBufferGetBytesPerRowOfPlane(dst, 0), cb = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let w = img.width, cw = img.chromaWidth
        img.y.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for row in 0..<img.height { (y0 + row * yb).copyMemory(from: s + row * w, byteCount: w) }
        }
        let c = c0.assumingMemoryBound(to: UInt8.self)
        for row in 0..<img.chromaHeight {
            let d = c + row * cb
            for x in 0..<cw {
                d[2 * x] = img.cb[row * cw + x]
                d[2 * x + 1] = img.cr[row * cw + x]
            }
        }
        return true
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
