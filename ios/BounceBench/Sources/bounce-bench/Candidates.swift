import BounceCore
import Foundation

/// Prototypes of behaviour-preserving cuts, timed next to the code they would replace and checked to give exactly the
/// same output (bit for bit) on the bench's frames. Nothing here is used by the app: they show what a cut would save on
/// each machine the bench runs on, before anyone changes BounceCore.
enum Candidates {
    /// `YCCImage.fromBiplanar` with row pointers and the k x k block sums done a row of blocks at a time (the same integer
    /// sums and divisions, so the same bytes).
    static func fromBiplanar(luma: UnsafeBufferPointer<UInt8>, lumaWidth W: Int, lumaHeight H: Int, lumaBytesPerRow lb: Int,
                             cbcr: UnsafeBufferPointer<UInt8>, cbcrBytesPerRow cbb: Int, factor k: Int) -> YCCImage {
        let w = W / k, h = H / k, cw = (w + 1) / 2, chh = (h + 1) / 2
        var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 128, count: cw * chh), cr = cb
        let kk = k * k
        let L = luma.baseAddress!, C = cbcr.baseAddress!
        var sums = [Int](repeating: 0, count: w)
        y.withUnsafeMutableBufferPointer { yo in
            sums.withUnsafeMutableBufferPointer { s in
                for yy in 0..<h {
                    for x in 0..<w { s[x] = 0 }
                    for dy in 0..<k {
                        let row = L + (yy * k + dy) * lb
                        if k == 4 {
                            // two blocks from one 8-byte load: byte pairs summed in 16-bit lanes, then the lanes paired
                            let raw = UnsafeRawPointer(row)
                            var x = 0
                            while x + 1 < w {
                                let v = raw.loadUnaligned(fromByteOffset: x * 4, as: UInt64.self).littleEndian
                                let t = (v & 0x00FF_00FF_00FF_00FF) &+ ((v >> 8) & 0x00FF_00FF_00FF_00FF)
                                s[x] &+= Int(t & 0xFFFF) &+ Int((t >> 16) & 0xFFFF)
                                s[x + 1] &+= Int((t >> 32) & 0xFFFF) &+ Int(t >> 48)
                                x += 2
                            }
                            if x < w { let p = row + x * 4; s[x] &+= Int(p[0]) &+ Int(p[1]) &+ Int(p[2]) &+ Int(p[3]) }
                        } else {
                            for x in 0..<w { let p = row + x * k; var t = 0; for dx in 0..<k { t &+= Int(p[dx]) }; s[x] &+= t }
                        }
                    }
                    let o = yy * w
                    for x in 0..<w { yo[o + x] = UInt8(truncatingIfNeeded: s[x] / kk) }
                }
            }
        }
        // chroma: output chroma pixel (cx, cy) covers half-size chroma [cx*k, cx*k + k) x [cy*k, cy*k + k), clipped
        let CW = W / 2, CH = H / 2
        cb.withUnsafeMutableBufferPointer { bo in
            cr.withUnsafeMutableBufferPointer { ro in
                for yy in 0..<chh {
                    let r0 = yy * k, r1 = min(CH, r0 + k)
                    for xx in 0..<cw {
                        let c0 = xx * k, c1 = min(CW, c0 + k)
                        guard r1 > r0, c1 > c0 else { continue }
                        var sb = 0, sr = 0
                        if k == 4 && c1 - c0 == 4 {
                            // a row's four CbCr pairs in one 8-byte load: Cb in the even bytes, Cr in the odd ones
                            var lb: UInt64 = 0, lr: UInt64 = 0
                            for r in r0..<r1 {
                                let v = UnsafeRawPointer(C + r * cbb).loadUnaligned(fromByteOffset: 2 * c0, as: UInt64.self).littleEndian
                                lb &+= v & 0x00FF_00FF_00FF_00FF; lr &+= (v >> 8) & 0x00FF_00FF_00FF_00FF
                            }
                            sb = Int(lb & 0xFFFF) &+ Int((lb >> 16) & 0xFFFF) &+ Int((lb >> 32) & 0xFFFF) &+ Int(lb >> 48)
                            sr = Int(lr & 0xFFFF) &+ Int((lr >> 16) & 0xFFFF) &+ Int((lr >> 32) & 0xFFFF) &+ Int(lr >> 48)
                        } else {
                            for r in r0..<r1 {
                                let p = C + r * cbb
                                for c in c0..<c1 { sb &+= Int(p[2 * c]); sr &+= Int(p[2 * c + 1]) }
                            }
                        }
                        let n = (r1 - r0) * (c1 - c0)
                        bo[yy * cw + xx] = UInt8(truncatingIfNeeded: sb / n); ro[yy * cw + xx] = UInt8(truncatingIfNeeded: sr / n)
                    }
                }
            }
        }
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }

    /// `YCCImage.colorFrame` with the chroma upsampling done by tables: per output column and row, the source index and
    /// weight `Plane.sample` computes (the same Double arithmetic, done once per column and row instead of per pixel), then
    /// the same Float interpolation and colour-difference scaling, so the same Floats.
    static func colorFrame(_ img: YCCImage) -> ColorFrame {
        let w = img.width, h = img.height, cw = img.chromaWidth, ch = img.chromaHeight
        let y = Plane(width: w, height: h, data: img.y.map { Float($0) })
        let sx = Double(cw) / Double(w), sy = Double(ch) / Double(h)
        // Plane.resized(width:height:) samples bilinearly unless it shrinks both ways (or keeps the size)
        if (cw == w && ch == h) || (sx >= 1 && sy >= 1) { return img.colorFrame }
        func axis(_ n: Int, _ s: Double, _ size: Int) -> (i: [Int], a: [Float]) {
            var ii = [Int](repeating: 0, count: n), aa = [Float](repeating: 0, count: n)
            for x in 0..<n {
                let f = clampD((Double(x) + 0.5) * s - 0.5, 0, Double(size) - 1.001)
                let i = Int(f)
                ii[x] = i; aa[x] = Float(f - Double(i))
            }
            return (ii, aa)
        }
        let (xi, ax) = axis(w, sx, cw), (yi, ay) = axis(h, sy, ch)
        func plane(_ src: [UInt8], _ scale: Float) -> Plane {
            let s = src.map { Float($0) }
            var d = [Float](repeating: 0, count: w * h)
            s.withUnsafeBufferPointer { sp in
                d.withUnsafeMutableBufferPointer { dp in
                    for yy in 0..<h {
                        let r = yi[yy] * cw, b = ay[yy], o = yy * w
                        for x in 0..<w {
                            let j = r + xi[x], a = ax[x]
                            let top = sp[j] * (1 - a) + sp[j + 1] * a
                            let bot = sp[j + cw] * (1 - a) + sp[j + cw + 1] * a
                            dp[o + x] = ((top * (1 - b) + bot * b) - 128) / scale
                        }
                    }
                }
            }
            return Plane(width: w, height: h, data: d)
        }
        return ColorFrame(y: y, cb: plane(img.cb, 0.564), cr: plane(img.cr, 0.713))
    }

    @inline(__always) static func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    /// `Plane.pgmData(blockSum:)` writing into a byte array first (Data's per-byte appends are what it pays for).
    static func pgmData(_ p: Plane, blockSum k: Int) -> Data {
        if k == 1 { return p.pgmData() }
        let kk = Float(k * k), maxval = 255 * k * k, mf = Float(maxval)
        var out = Array("P5\n\(p.width) \(p.height)\n\(maxval)\n".utf8)
        let head = out.count
        out.append(contentsOf: repeatElement(0, count: 2 * p.data.count))
        out.withUnsafeMutableBufferPointer { o in
            p.data.withUnsafeBufferPointer { d in
                for i in 0..<d.count {
                    let s = UInt16(min(max((d[i] * kk).rounded(), 0), mf))
                    o[head + 2 * i] = UInt8(s >> 8); o[head + 2 * i + 1] = UInt8(s & 255)
                }
            }
        }
        return Data(out)
    }

    /// `DepthMap.data` with the floats copied as little-endian bytes in one go.
    static func depthData(_ m: DepthMap) -> Data {
        var d = Data([66, 68, 80, 49, UInt8(m.width & 255), UInt8(m.width >> 8), UInt8(m.height & 255), UInt8(m.height >> 8)])
        var bytes = [UInt8](repeating: 0, count: m.depth.count * 4)
        for (i, v) in m.depth.enumerated() {
            let u = v.bitPattern
            bytes[4 * i] = UInt8(u & 255); bytes[4 * i + 1] = UInt8((u >> 8) & 255); bytes[4 * i + 2] = UInt8((u >> 16) & 255); bytes[4 * i + 3] = UInt8(u >> 24)
        }
        d.append(contentsOf: bytes)
        d.append(contentsOf: m.confidence)
        return d
    }
}

/// Checks the conversion prototypes against what they would replace on random inputs: sizes, factors 1-4, padded rows
/// (bytes per row past the width, as a CVPixelBuffer may have them), odd sizes for the colour frame. Returns the cases run
/// and the first failures (an empty list: identical output on every case).
enum CandidateChecks {
    static func run(cases: Int = 300, seed: UInt64 = 0xC0FFEE) -> (cases: Int, fromBiplanarFailures: [String], colorFrameFailures: [String]) {
        var rng = BenchRandom(seed)
        func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(rng.next() % UInt64(hi - lo + 1)) }
        var fb: [String] = [], cf: [String] = []
        for _ in 0..<cases {
            // the camera's planes: even sizes (4:2:0), rows padded by 0-40 bytes
            let W = 2 * int(8, 260), H = 2 * int(8, 200), k = int(1, 4)
            let lb = W + int(0, 40), cbb = W + 2 * int(0, 20)
            var luma = [UInt8](repeating: 0, count: lb * H), cbcr = [UInt8](repeating: 0, count: cbb * H / 2)
            for i in 0..<luma.count { luma[i] = UInt8(truncatingIfNeeded: rng.next()) }
            for i in 0..<cbcr.count { cbcr[i] = UInt8(truncatingIfNeeded: rng.next()) }
            guard W / k >= 2, H / k >= 2 else { continue }
            let (a, b) = luma.withUnsafeBufferPointer { l in cbcr.withUnsafeBufferPointer { c in
                (YCCImage.fromBiplanar(luma: l, lumaWidth: W, lumaHeight: H, lumaBytesPerRow: lb, cbcr: c, cbcrBytesPerRow: cbb, factor: k),
                 Candidates.fromBiplanar(luma: l, lumaWidth: W, lumaHeight: H, lumaBytesPerRow: lb, cbcr: c, cbcrBytesPerRow: cbb, factor: k))
            } }
            if a != b && fb.count < 5 { fb.append("\(W)x\(H) k\(k) rows \(lb)/\(cbb)") }
            // the colour frame on an image of any size (odd ones too)
            let w = int(3, 300), h = int(3, 240), cw = (w + 1) / 2, ch = (h + 1) / 2
            let img = YCCImage(width: w, height: h, y: (0..<(w * h)).map { _ in UInt8(truncatingIfNeeded: rng.next()) },
                               cb: (0..<(cw * ch)).map { _ in UInt8(truncatingIfNeeded: rng.next()) },
                               cr: (0..<(cw * ch)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if img.colorFrame != Candidates.colorFrame(img) && cf.count < 5 { cf.append("\(w)x\(h)") }
        }
        return (cases, fb, cf)
    }
}

extension StageBench {
    /// Times the cut prototypes against what they would replace, on the 4 ft frame, and checks they agree exactly (on
    /// this frame and on random inputs).
    func candidates() {
        guard let s = scene(feet: 4, ball: true) ?? all.scenes.first(where: { $0.kind == .slab }) else { return }
        let ring = s.ring()
        let ref = s.processingImage()
        let fast = s.luma.withUnsafeBufferPointer { l in s.cbcr.withUnsafeBufferPointer { c in
            Candidates.fromBiplanar(luma: l, lumaWidth: s.width, lumaHeight: s.height, lumaBytesPerRow: s.lumaStride, cbcr: c,
                                    cbcrBytesPerRow: s.cbcrStride, factor: BenchScene.factor)
        } }
        let chk = CandidateChecks.run(cases: quick ? 60 : 300)
        func verdict(_ same: Bool, _ failures: [String]?) -> String {
            guard same else { return "OUTPUT DIFFERS on this frame: not a valid cut as written" }
            guard let fs = failures else { return "identical output on this frame" }
            return fs.isEmpty ? "identical output on this frame and on \(chk.cases) random inputs (sizes, factors 1-4, padded rows; odd sizes for the colour frame)"
                : "identical on this frame but DIFFERS on random inputs (\(fs.joined(separator: ", "))): not valid as written"
        }
        timeCandidate("bi-planar -> 480x360 YCCImage, row pointers (vs YCCImage.fromBiplanar)", input: "1920x1440, 8 buffers in turn",
                      note: verdict(fast == ref, chk.fromBiplanarFailures)) { i in
            let r = ring[i % ring.count]
            r.luma.withUnsafeBufferPointer { l in r.cbcr.withUnsafeBufferPointer { c in
                blackHole(Candidates.fromBiplanar(luma: l, lumaWidth: r.width, lumaHeight: r.height, lumaBytesPerRow: r.lumaStride, cbcr: c,
                                                  cbcrBytesPerRow: r.cbcrStride, factor: BenchScene.factor))
            } }
        }
        let cfRef = ref.colorFrame, cfFast = Candidates.colorFrame(ref)
        timeCandidate("YCCImage -> ColorFrame, tabled 2x chroma upsampling (vs ycc.colorFrame)", input: "480x360",
                      note: verdict(cfRef == cfFast, chk.colorFrameFailures)) { _ in
            blackHole(Candidates.colorFrame(ref))
        }
        if let c = BallImageCrop.plan(slab: s.scene.slab, full: s.full),
           let p = s.lumaCrop(.rows, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor), c.factor > 1 {
            timeCandidate("ball crop -> exact PGM via a byte array (vs Plane.pgmData(blockSum:))", input: "\(fmtSize(p)) factor \(c.factor)",
                          note: verdict(Candidates.pgmData(p, blockSum: c.factor) == p.pgmData(blockSum: c.factor), nil)) { _ in
                blackHole(Candidates.pgmData(p, blockSum: c.factor))
            }
        }
        timeCandidate("depth map -> BDP1 via a byte array (vs DepthMap.data)", input: "256x192",
                      note: verdict(Candidates.depthData(s.depth) == s.depth.data, nil)) { _ in
            blackHole(Candidates.depthData(s.depth))
        }
    }

    private func timeCandidate(_ name: String, input: String, note: String, _ body: (Int) -> Void) {
        timeStage("candidate", name, input: input, .fast, role: .candidate, note: note, body)
    }
}
