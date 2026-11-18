import BounceCore
import Foundation

/// The code the behaviour-preserving cuts replaced in BounceCore (YCCImage.fromBiplanar and colorFrame,
/// Plane.pgmData(blockSum:), DepthMap.data), verbatim, timed next to BounceCore's own and checked to give exactly the
/// same output (bit for bit) on the bench's frames: what each cut saves on each machine the bench runs on.
/// (FinderRun.chamfer's cut shows in the slab search's own times; its identity is BounceCoreTests' SpeedupIdentityTests.)
enum Candidates {
    static func fromBiplanar(luma: UnsafeBufferPointer<UInt8>, lumaWidth W: Int, lumaHeight H: Int, lumaBytesPerRow lb: Int,
                             cbcr: UnsafeBufferPointer<UInt8>, cbcrBytesPerRow cbb: Int, factor k: Int) -> YCCImage {
        let w = W / k, h = H / k, cw = (w + 1) / 2, chh = (h + 1) / 2
        var y = [UInt8](repeating: 0, count: w * h), cb = [UInt8](repeating: 128, count: cw * chh), cr = cb
        for yy in 0..<h {
            for xx in 0..<w {
                var s = 0
                for dy in 0..<k { let row = (yy * k + dy) * lb + xx * k; for dx in 0..<k { s += Int(luma[row + dx]) } }
                y[yy * w + xx] = UInt8(s / (k * k))
            }
        }
        let CW = W / 2, CH = H / 2
        for yy in 0..<chh {
            for xx in 0..<cw {
                var sb = 0, sr = 0, n = 0
                for dy in 0..<k { let r = yy * k + dy; if r >= CH { continue }
                    for dx in 0..<k { let c = xx * k + dx; if c >= CW { continue }
                        let j = r * cbb + c * 2; sb += Int(cbcr[j]); sr += Int(cbcr[j + 1]); n += 1 } }
                if n > 0 { cb[yy * cw + xx] = UInt8(sb / n); cr[yy * cw + xx] = UInt8(sr / n) }
            }
        }
        return YCCImage(width: w, height: h, y: y, cb: cb, cr: cr)
    }

    static func colorFrame(_ img: YCCImage) -> ColorFrame {
        ColorFrame(lumaFull: img.luma, cbHalf: Plane(bytes: img.cb, width: img.chromaWidth, height: img.chromaHeight),
                   crHalf: Plane(bytes: img.cr, width: img.chromaWidth, height: img.chromaHeight), scale: 1)
    }

    static func pgmData(_ p: Plane, blockSum k: Int) -> Data {
        if k == 1 { return p.pgmData() }
        let kk = Float(k * k), maxval = 255 * k * k
        var d = Data("P5\n\(p.width) \(p.height)\n\(maxval)\n".utf8)
        d.reserveCapacity(d.count + 2 * p.data.count)
        for v in p.data {
            let s = UInt16(clamp((v * kk).rounded(), 0, Float(maxval)))
            d.append(UInt8(s >> 8)); d.append(UInt8(s & 255))
        }
        return d
    }

    static func depthData(_ m: DepthMap) -> Data {
        var d = Data([66, 68, 80, 49, UInt8(m.width & 255), UInt8(m.width >> 8), UInt8(m.height & 255), UInt8(m.height >> 8)])
        d.reserveCapacity(8 + m.depth.count * 5)
        for v in m.depth { let u = v.bitPattern; d.append(contentsOf: [UInt8(u & 255), UInt8((u >> 8) & 255), UInt8((u >> 16) & 255), UInt8(u >> 24)]) }
        d.append(contentsOf: m.confidence)
        return d
    }
}

/// Checks BounceCore's conversions against the code they replaced on random inputs: sizes, factors 1-4, padded rows
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
    /// Times the code the cuts replaced, on the 4 ft frame, next to BounceCore's own (the stages above), and checks they
    /// agree exactly (on this frame and on random inputs).
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
            guard same else { return "OUTPUT DIFFERS on this frame: BounceCore's cut is not identical" }
            guard let fs = failures else { return "identical output on this frame" }
            return fs.isEmpty ? "identical output on this frame and on \(chk.cases) random inputs (sizes, factors 1-4, padded rows; odd sizes for the colour frame)"
                : "identical on this frame but DIFFERS on random inputs (\(fs.joined(separator: ", "))): not valid as written"
        }
        timeCandidate("bi-planar -> 480x360 YCCImage, before the cut (vs YCCImage.fromBiplanar, now with row pointers)", input: "1920x1440, 8 buffers in turn",
                      note: verdict(fast == ref, chk.fromBiplanarFailures)) { i in
            let r = ring[i % ring.count]
            r.luma.withUnsafeBufferPointer { l in r.cbcr.withUnsafeBufferPointer { c in
                blackHole(Candidates.fromBiplanar(luma: l, lumaWidth: r.width, lumaHeight: r.height, lumaBytesPerRow: r.lumaStride, cbcr: c,
                                                  cbcrBytesPerRow: r.cbcrStride, factor: BenchScene.factor))
            } }
        }
        let cfRef = ref.colorFrame, cfFast = Candidates.colorFrame(ref)
        timeCandidate("YCCImage -> ColorFrame, before the cut (vs ycc.colorFrame, now with tabled chroma upsampling)", input: "480x360",
                      note: verdict(cfRef == cfFast, chk.colorFrameFailures)) { _ in
            blackHole(Candidates.colorFrame(ref))
        }
        if let c = BallImageCrop.plan(slab: s.scene.slab, full: s.full),
           let p = s.lumaCrop(.rows, x0: c.x0, y0: c.y0, width: c.width, height: c.height, factor: c.factor), c.factor > 1 {
            timeCandidate("ball crop -> exact PGM, before the cut (vs Plane.pgmData(blockSum:), now via a byte array)", input: "\(fmtSize(p)) factor \(c.factor)",
                          note: verdict(Candidates.pgmData(p, blockSum: c.factor) == p.pgmData(blockSum: c.factor), nil)) { _ in
                blackHole(Candidates.pgmData(p, blockSum: c.factor))
            }
        }
        timeCandidate("depth map -> BDP1, before the cut (vs DepthMap.data, now via a byte array)", input: "256x192",
                      note: verdict(Candidates.depthData(s.depth) == s.depth.data, nil)) { _ in
            blackHole(Candidates.depthData(s.depth))
        }
    }

    private func timeCandidate(_ name: String, input: String, note: String, _ body: (Int) -> Void) {
        timeStage("candidate", name, input: input, .fast, role: .candidate, note: note, body)
    }
}
