import BounceCore
import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// The app's own per-frame helpers that live in the app (ios/BounceApp/FrameConversion.swift), not in BounceCore, done
/// here on plain buffers so they can be timed off the phone:
///   - `FrameConversion.lumaCrop`: a k x k block-average crop of the camera image's luma plane as Floats. The app uses
///     vDSP (Accelerate): each source row converted UInt8 -> Float, the k rows summed, then the blocks' k columns and a
///     scale. `vDSP` below is that code verbatim on a raw pointer (macOS only: Accelerate). Pure Swift stand-ins, for
///     Linux and to compare: `perPixel` (integer sums pixel by pixel, as BounceCore's `KitFramePipeline.lumaCrop`) and
///     `rows` (the app's row-convert-and-add scheme in plain Swift loops on unsafe pointers). All give the same values.
///   - `FrameConversion.depth`: ARKit's depth and confidence buffers copied into a `DepthMap`, element by element.
enum AppReplicas {
    enum CropVariant: String, CaseIterable, Codable {
        case perPixel = "per-pixel (pure Swift)"
        case rows = "row convert + add (pure Swift)"
        case vDSP = "vDSP (the app's code; macOS)"

        static var available: [CropVariant] {
            #if canImport(Accelerate)
            return [.perPixel, .rows, .vDSP]
            #else
            return [.perPixel, .rows]
            #endif
        }
        /// what the phone runs where this host can run it, else the fastest pure Swift stand-in
        static var app: CropVariant {
            #if canImport(Accelerate)
            return .vDSP
            #else
            return .rows
            #endif
        }
    }

    /// The crop's output size, as the app computes it (nil: 8 pixels or less either way).
    @inline(__always)
    static func cropGeometry(w: Int, h: Int, x0: Int, y0: Int, cw: Int, chh: Int, k: Int) -> (ax: Int, ay: Int, ow: Int, oh: Int)? {
        guard k >= 1 else { return nil }
        let ax = max(0, min(w - 1, x0)), ay = max(0, min(h - 1, y0))
        let ow = min(cw, w - ax) / k, oh = min(chh, h - ay) / k
        guard ow > 8, oh > 8 else { return nil }
        return (ax, ay, ow, oh)
    }

    static func lumaCrop(_ v: CropVariant, luma: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int, bytesPerRow lb: Int,
                         x0: Int, y0: Int, width cw: Int, height chh: Int, factor k: Int) -> Plane? {
        switch v {
        case .perPixel: return perPixel(luma, w, h, lb, x0, y0, cw, chh, k)
        case .rows: return rows(luma, w, h, lb, x0, y0, cw, chh, k)
        case .vDSP:
            #if canImport(Accelerate)
            return vdsp(luma, w, h, lb, x0, y0, cw, chh, k)
            #else
            return rows(luma, w, h, lb, x0, y0, cw, chh, k)
            #endif
        }
    }

    static func perPixel(_ src: UnsafeBufferPointer<UInt8>, _ w: Int, _ h: Int, _ lb: Int, _ x0: Int, _ y0: Int, _ cw: Int, _ chh: Int,
                         _ k: Int) -> Plane? {
        guard let g = cropGeometry(w: w, h: h, x0: x0, y0: y0, cw: cw, chh: chh, k: k) else { return nil }
        var d = [Float](repeating: 0, count: g.ow * g.oh)
        let inv = 1 / Float(k * k)
        for yy in 0..<g.oh {
            for xx in 0..<g.ow {
                var s = 0
                for dy in 0..<k { let r = (g.ay + yy * k + dy) * lb + g.ax + xx * k; for dx in 0..<k { s += Int(src[r + dx]) } }
                d[yy * g.ow + xx] = Float(s) * inv
            }
        }
        return Plane(width: g.ow, height: g.oh, data: d)
    }

    static func rows(_ src: UnsafeBufferPointer<UInt8>, _ w: Int, _ h: Int, _ lb: Int, _ x0: Int, _ y0: Int, _ cw: Int, _ chh: Int,
                     _ k: Int) -> Plane? {
        guard let g = cropGeometry(w: w, h: h, x0: x0, y0: y0, cw: cw, chh: chh, k: k), let base = src.baseAddress else { return nil }
        let ow = g.ow, oh = g.oh, n = ow * k
        var d = [Float](repeating: 0, count: ow * oh)
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { acc.deallocate() }
        let inv = 1 / Float(k * k)
        d.withUnsafeMutableBufferPointer { out in
            let o = out.baseAddress!
            for yy in 0..<oh {
                let first = base + (g.ay + yy * k) * lb + g.ax, dst = o + yy * ow
                if k == 1 {
                    for x in 0..<ow { dst[x] = Float(first[x]) }
                    continue
                }
                for x in 0..<n { acc[x] = Float(first[x]) }
                for dy in 1..<k { let r = first + dy * lb; for x in 0..<n { acc[x] += Float(r[x]) } }
                for x in 0..<ow {
                    var s: Float = 0
                    let a = acc + x * k
                    for dx in 0..<k { s += a[dx] }
                    dst[x] = s * inv
                }
            }
        }
        return Plane(width: ow, height: oh, data: d)
    }

    #if canImport(Accelerate)
    /// `FrameConversion.lumaCrop` as the app has it, on a raw luma plane instead of a CVPixelBuffer.
    static func vdsp(_ srcBuf: UnsafeBufferPointer<UInt8>, _ w: Int, _ h: Int, _ lb: Int, _ x0: Int, _ y0: Int, _ cw: Int, _ chh: Int,
                     _ k: Int) -> Plane? {
        guard k >= 1, let src = srcBuf.baseAddress else { return nil }
        let ax = max(0, min(w - 1, x0)), ay = max(0, min(h - 1, y0))
        let ow = min(cw, w - ax) / k, oh = min(chh, h - ay) / k
        guard ow > 8, oh > 8 else { return nil }
        var d = [Float](repeating: 0, count: ow * oh)
        let n = ow * k
        let acc = UnsafeMutablePointer<Float>.allocate(capacity: n), row = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { acc.deallocate(); row.deallocate() }
        d.withUnsafeMutableBufferPointer { out in
            guard let o = out.baseAddress else { return }
            var inv = 1 / Float(k * k)
            for yy in 0..<oh {
                let first = src + (ay + yy * k) * lb + ax, dst = o + yy * ow
                if k == 1 {
                    vDSP_vfltu8(first, 1, dst, 1, vDSP_Length(ow))
                    continue
                }
                vDSP_vfltu8(first, 1, acc, 1, vDSP_Length(n))
                for dy in 1..<k {
                    vDSP_vfltu8(first + dy * lb, 1, row, 1, vDSP_Length(n))
                    vDSP_vadd(acc, 1, row, 1, acc, 1, vDSP_Length(n))
                }
                vDSP_vadd(acc, vDSP_Stride(k), acc + 1, vDSP_Stride(k), dst, 1, vDSP_Length(ow))
                for dx in 2..<k { vDSP_vadd(dst, 1, acc + dx, vDSP_Stride(k), dst, 1, vDSP_Length(ow)) }
                vDSP_vsmul(dst, 1, &inv, dst, 1, vDSP_Length(ow))
            }
        }
        return Plane(width: ow, height: oh, data: d)
    }

    /// `FrameConversion.scale` (the capture kit's recorder, per recorded frame): vImage's Lanczos scale of the camera
    /// image's luma and interleaved chroma into the kit's video buffer (1440x1080 from 1920x1440). vImage splits the work
    /// over the cores by default (the app's call); `oneCore` asks it not to (kvImageDoNotTile), for one core's time.
    static func kitVideoScale(luma: UnsafeBufferPointer<UInt8>, cbcr: UnsafeBufferPointer<UInt8>, width W: Int, height H: Int,
                              lumaStride: Int, cbcrStride: Int, into dl: UnsafeMutableBufferPointer<UInt8>, _ dc: UnsafeMutableBufferPointer<UInt8>,
                              dw: Int, dh: Int, oneCore: Bool = false) -> Bool {
        guard let lp = luma.baseAddress, let cp = cbcr.baseAddress else { return false }
        let flags = vImage_Flags(oneCore ? kvImageDoNotTile : kvImageNoFlags)
        var sb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: lp), height: vImagePixelCount(H), width: vImagePixelCount(W), rowBytes: lumaStride)
        var db = vImage_Buffer(data: UnsafeMutableRawPointer(dl.baseAddress), height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
        guard vImageScale_Planar8(&sb, &db, nil, flags) == kvImageNoError else { return false }
        var sc = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: cp), height: vImagePixelCount(H / 2), width: vImagePixelCount(W / 2), rowBytes: cbcrStride)
        var dcb = vImage_Buffer(data: UnsafeMutableRawPointer(dc.baseAddress), height: vImagePixelCount(dh / 2), width: vImagePixelCount(dw / 2), rowBytes: dw)
        return vImageScale_CbCr8(&sc, &dcb, nil, flags) == kvImageNoError
    }
    #endif

    /// `FrameConversion.depth`: ARKit's Float32 depth rows and confidence rows copied element by element.
    static func depthCopy(depthRows: UnsafeRawPointer, depthStride: Int, confRows: UnsafeRawPointer, confStride: Int, width w: Int, height h: Int) -> DepthMap {
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = depthRows.advanced(by: y * depthStride).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { depth[y * w + x] = row[x] }
        }
        var conf = [UInt8](repeating: 2, count: w * h)
        for y in 0..<h {
            let row = confRows.advanced(by: y * confStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { conf[y * w + x] = row[x] }
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: conf)
    }
}

extension BenchScene {
    /// The app's `FrameConversion.ycc(pb, factor: 4)`: BounceCore's `YCCImage.fromBiplanar` on the camera buffer's planes.
    func processingImage() -> YCCImage {
        luma.withUnsafeBufferPointer { l in
            cbcr.withUnsafeBufferPointer { c in
                YCCImage.fromBiplanar(luma: l, lumaWidth: width, lumaHeight: height, lumaBytesPerRow: lumaStride, cbcr: c,
                                      cbcrBytesPerRow: cbcrStride, factor: BenchScene.factor)
            }
        }
    }

    func lumaCrop(_ v: AppReplicas.CropVariant, x0: Int, y0: Int, width w: Int, height h: Int, factor k: Int) -> Plane? {
        luma.withUnsafeBufferPointer { AppReplicas.lumaCrop(v, luma: $0, width: width, height: height, bytesPerRow: lumaStride, x0: x0, y0: y0,
                                                            width: w, height: h, factor: k) }
    }

    /// The app's `FrameConversion.depth` on this frame's depth (as ARKit's buffers: rows of Float32 and of bytes).
    func depthFromBuffers() -> DepthMap {
        depth.depth.withUnsafeBytes { d in
            depth.confidence.withUnsafeBytes { c in
                AppReplicas.depthCopy(depthRows: d.baseAddress!, depthStride: depth.width * 4, confRows: c.baseAddress!, confStride: depth.width,
                                      width: depth.width, height: depth.height)
            }
        }
    }
}
