import Foundation

/// A single-channel image of Floats (luma 0-255, or a colour difference).
///
/// Coordinates: `self[x, y]` reads pixel (x, y) by index. `sample(_:)` takes continuous image coordinates, where pixel
/// (i, j) covers [i, i+1) x [j, j+1) and its centre is (i + 0.5, j + 0.5) - the same convention as CameraIntrinsics.
public struct Plane: Equatable {
    public let width: Int
    public let height: Int
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        precondition(data.count == width * height)
        self.width = width; self.height = height; self.data = data
    }
    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, data: [Float](repeating: fill, count: width * height))
    }
    /// From 8-bit rows that may be padded (e.g. a CVPixelBuffer plane: `bytesPerRow` >= width).
    public init(bytes: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        var d = [Float](repeating: 0, count: width * height)
        for y in 0..<height { let r = y * bytesPerRow, o = y * width; for x in 0..<width { d[o + x] = Float(bytes[r + x]) } }
        self.init(width: width, height: height, data: d)
    }
    public init(bytes: [UInt8], width: Int, height: Int) {
        self.init(width: width, height: height, data: bytes.map { Float($0) })
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }

    /// Bilinear sample at continuous image coordinates (pixel centres at i + 0.5); clamped at the borders.
    @inline(__always) public func sample(_ x: Double, _ y: Double) -> Float {
        let fx = clamp(x - 0.5, 0, Double(width) - 1.001), fy = clamp(y - 0.5, 0, Double(height) - 1.001)
        let xi = Int(fx), yi = Int(fy), ax = Float(fx - Double(xi)), ay = Float(fy - Double(yi))
        let j = yi * width + xi
        let top = data[j] * (1 - ax) + data[j + 1] * ax
        let bot = data[j + width] * (1 - ax) + data[j + width + 1] * ax
        return top * (1 - ay) + bot * ay
    }
    @inline(__always) public func sample(_ p: Vec2) -> Float { sample(p.x, p.y) }

    /// Area-average downscale by an integer factor.
    public func downscaled(by k: Int) -> Plane {
        precondition(k >= 1)
        if k == 1 { return self }
        let w = width / k, h = height / k
        var d = [Float](repeating: 0, count: w * h)
        let inv = 1 / Float(k * k)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dy in 0..<k { let r = (y * k + dy) * width + x * k; for dx in 0..<k { s += data[r + dx] } }
                d[y * w + x] = s * inv
            }
        }
        return Plane(width: w, height: h, data: d)
    }

    /// Resample to an arbitrary size (area average when shrinking, bilinear otherwise).
    public func resized(width w: Int, height h: Int) -> Plane {
        if w == width && h == height { return self }
        var d = [Float](repeating: 0, count: w * h)
        let sx = Double(width) / Double(w), sy = Double(height) / Double(h)
        if sx >= 1 && sy >= 1 {
            for y in 0..<h {
                let y0 = Double(y) * sy, y1 = y0 + sy
                for x in 0..<w {
                    let x0 = Double(x) * sx, x1 = x0 + sx
                    var s = 0.0, a = 0.0
                    var yy = Int(y0)
                    while Double(yy) < y1 && yy < height {
                        let wy = min(Double(yy + 1), y1) - max(Double(yy), y0)
                        var xx = Int(x0)
                        while Double(xx) < x1 && xx < width {
                            let wx = min(Double(xx + 1), x1) - max(Double(xx), x0)
                            s += Double(data[yy * width + xx]) * wx * wy; a += wx * wy
                            xx += 1
                        }
                        yy += 1
                    }
                    d[y * w + x] = Float(s / max(a, 1e-12))
                }
            }
        } else {
            for y in 0..<h { for x in 0..<w { d[y * w + x] = sample((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy) } }
        }
        return Plane(width: w, height: h, data: d)
    }

    /// A crop of the image (clamped to the image).
    public func cropped(x0: Int, y0: Int, width w: Int, height h: Int) -> Plane {
        let ax = clamp(x0, 0, width - 1), ay = clamp(y0, 0, height - 1)
        let cw = min(w, width - ax), ch = min(h, height - ay)
        var d = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw { d[y * cw + x] = data[(ay + y) * width + ax + x] } }
        return Plane(width: cw, height: ch, data: d)
    }

    /// 3x3 box blur (edge pixels average what is inside the image).
    public func blurred3() -> Plane {
        var o = [Float](repeating: 0, count: data.count)
        for y in 0..<height {
            for x in 0..<width {
                var s: Float = 0, c: Float = 0
                for dy in -1...1 { let yy = y + dy; if yy < 0 || yy >= height { continue }
                    for dx in -1...1 { let xx = x + dx; if xx < 0 || xx >= width { continue }; s += data[yy * width + xx]; c += 1 } }
                o[y * width + x] = s / c
            }
        }
        return Plane(width: width, height: height, data: o)
    }

    /// Local standard deviation in a (2r+1)^2 window (texture measure), via integral images.
    public func localStdDev(radius r: Int) -> Plane {
        let W1 = width + 1
        var i1 = [Double](repeating: 0, count: W1 * (height + 1)), i2 = i1
        for y in 0..<height {
            var r1 = 0.0, r2 = 0.0
            for x in 0..<width {
                let v = Double(data[y * width + x]); r1 += v; r2 += v * v
                let j = (y + 1) * W1 + x + 1
                i1[j] = i1[j - W1] + r1; i2[j] = i2[j - W1] + r2
            }
        }
        var o = [Float](repeating: 0, count: data.count)
        for y in 0..<height {
            let y0 = max(0, y - r), y1 = min(height, y + r + 1)
            for x in 0..<width {
                let x0 = max(0, x - r), x1 = min(width, x + r + 1), c = Double((x1 - x0) * (y1 - y0))
                let a = y1 * W1 + x1, b = y0 * W1 + x1, d = y1 * W1 + x0, e = y0 * W1 + x0
                let mu = (i1[a] - i1[b] - i1[d] + i1[e]) / c
                o[y * width + x] = Float(max(0, (i2[a] - i2[b] - i2[d] + i2[e]) / c - mu * mu).squareRoot())
            }
        }
        return Plane(width: width, height: height, data: o)
    }

    /// Values at a regular subsample, sorted (for percentiles).
    public func sortedSample(step: Int = 11) -> [Float] {
        var s: [Float] = []
        s.reserveCapacity(data.count / step + 1)
        var i = 0
        while i < data.count { s.append(data[i]); i += step }
        return s.sorted()
    }

    public var bytes: [UInt8] { data.map { UInt8(clamp($0.rounded(), 0, 255)) } }

    // MARK: PGM (binary greyscale, P5) files

    public func pgmData() -> Data {
        var d = Data("P5\n\(width) \(height)\n255\n".utf8)
        d.append(contentsOf: bytes)
        return d
    }

    /// A PGM of an image made by averaging `k` x `k` blocks of 8-bit pixels (a shrunk crop of the camera image, as the
    /// app gives the ball finder) that keeps it exactly: each sample is the block's sum, with maxval 255 k^2 (16-bit
    /// samples for k > 1), so `Plane(pgm:)` reads back the very same Float values (sum x 1/k^2). Any PGM reader shows it
    /// as an ordinary greyscale image. Values that are not such averages are rounded to the nearest 1/k^2.
    public func pgmData(blockSum k: Int) -> Data {
        precondition(k >= 1 && k <= 16)
        if k == 1 { return pgmData() }
        let kk = Float(k * k), maxval = 255 * k * k, mf = Float(maxval)
        // the samples into a byte array first (appending to Data a byte at a time is what made this slow: it runs on the
        // recorder's queue for every ball crop a session recording keeps)
        var out = Array("P5\n\(width) \(height)\n\(maxval)\n".utf8)
        let head = out.count
        out.append(contentsOf: repeatElement(0, count: 2 * data.count))
        out.withUnsafeMutableBufferPointer { o in
            data.withUnsafeBufferPointer { d in
                for i in 0..<d.count {
                    let s = UInt16(clamp((d[i] * kk).rounded(), 0, mf))
                    o[head + 2 * i] = UInt8(s >> 8); o[head + 2 * i + 1] = UInt8(s & 255)
                }
            }
        }
        return Data(out)
    }

    /// Whether every value is an average of k x k 8-bit pixels (so `pgmData(blockSum: k)` keeps it exactly).
    public func isBlockAverage(of k: Int) -> Bool {
        let kk = Float(k * k), inv = 1 / kk
        return data.allSatisfy { v in let s = (v * kk).rounded(); return s >= 0 && s <= 255 * kk && s * inv == v }
    }

    /// Samples this image (whose pixels `intrinsics` describe) at the pixel centres of another image of the same camera
    /// (`target`: e.g. a crop of the full camera image), bilinearly: the same view at another scale and offset. Used to
    /// approximate a full-resolution crop from the smaller processing frame.
    public func resampled(from intrinsics: CameraIntrinsics, to target: CameraIntrinsics) -> Plane {
        var d = [Float](repeating: 0, count: target.width * target.height)
        let sx = intrinsics.fx / target.fx, sy = intrinsics.fy / target.fy
        for y in 0..<target.height {
            let py = (Double(y) + 0.5 - target.cy) * sy + intrinsics.cy
            for x in 0..<target.width {
                d[y * target.width + x] = sample((Double(x) + 0.5 - target.cx) * sx + intrinsics.cx, py)
            }
        }
        return Plane(width: target.width, height: target.height, data: d)
    }

    /// Reads a binary PGM (P5). 8-bit samples become 0-255 as they are; 16-bit ones (maxval above 255) are scaled to
    /// 0-255 (sample x 255 / maxval), which for `pgmData(blockSum:)` gives back the block averages exactly.
    public init?(pgm: Data) {
        // header: "P5" whitespace width whitespace height whitespace maxval single-whitespace, then bytes
        var fields: [Int] = [], i = 0
        let b = [UInt8](pgm)
        guard b.count > 2, b[0] == UInt8(ascii: "P"), b[1] == UInt8(ascii: "5") else { return nil }
        i = 2
        while fields.count < 3 && i < b.count {
            while i < b.count && (b[i] == 32 || b[i] == 10 || b[i] == 13 || b[i] == 9) { i += 1 }
            if i < b.count && b[i] == UInt8(ascii: "#") { while i < b.count && b[i] != 10 { i += 1 }; continue }
            var v = 0, any = false
            while i < b.count && b[i] >= 48 && b[i] <= 57 { v = v * 10 + Int(b[i] - 48); i += 1; any = true }
            guard any else { return nil }
            fields.append(v)
        }
        guard fields.count == 3, fields[2] > 0, fields[2] <= 65535 else { return nil }
        i += 1 // the single whitespace after maxval
        let w = fields[0], h = fields[1], maxval = fields[2]
        guard w > 0, h > 0 else { return nil }
        if maxval == 255 {
            guard b.count - i >= w * h else { return nil }
            self.init(bytes: Array(b[i..<(i + w * h)]), width: w, height: h)
            return
        }
        let scale = 255 / Float(maxval), two = maxval > 255
        guard b.count - i >= w * h * (two ? 2 : 1) else { return nil }
        var d = [Float](repeating: 0, count: w * h)
        for j in 0..<(w * h) {
            let s = two ? Int(b[i + 2 * j]) << 8 | Int(b[i + 2 * j + 1]) : Int(b[i + j])
            d[j] = Float(s) * scale
        }
        self.init(width: w, height: h, data: d)
    }
}

/// A colour frame at processing resolution, in the web detector's units: luma Y (0-255) and the colour differences
/// Cb = B - Y and Cr = R - Y (roughly -230...230).
public struct ColorFrame: Equatable {
    public var y: Plane
    public var cb: Plane
    public var cr: Plane
    public init(y: Plane, cb: Plane, cr: Plane) {
        precondition(y.width == cb.width && y.height == cb.height && y.width == cr.width && y.height == cr.height)
        self.y = y; self.cb = cb; self.cr = cr
    }
    public var width: Int { y.width }
    public var height: Int { y.height }

    /// A grey frame (no colour), e.g. from a luma-only recording.
    public init(gray: Plane) {
        self.init(y: gray, cb: Plane(width: gray.width, height: gray.height), cr: Plane(width: gray.width, height: gray.height))
    }

    /// From full-range video YCbCr planes (ARKit's 420f: Y at full size, Cb/Cr at half size, centred on 128):
    /// B - Y = (Cb - 128) / 0.564, R - Y = (Cr - 128) / 0.713 (BT.601).
    public init(lumaFull: Plane, cbHalf: Plane, crHalf: Plane, scale k: Int) {
        let y = lumaFull.downscaled(by: k)
        var cb = cbHalf.resized(width: y.width, height: y.height), cr = crHalf.resized(width: y.width, height: y.height)
        for i in 0..<cb.data.count { cb.data[i] = (cb.data[i] - 128) / 0.564; cr.data[i] = (cr.data[i] - 128) / 0.713 }
        self.init(y: y, cb: cb, cr: cr)
    }

    /// From 8-bit RGB (e.g. a decoded test image).
    public init(rgb: [UInt8], width: Int, height: Int) {
        precondition(rgb.count == width * height * 3)
        var y = [Float](repeating: 0, count: width * height), cb = y, cr = y
        for i in 0..<(width * height) {
            let r = Float(rgb[i * 3]), g = Float(rgb[i * 3 + 1]), b = Float(rgb[i * 3 + 2])
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            y[i] = l; cb[i] = b - l; cr[i] = r - l
        }
        self.init(y: Plane(width: width, height: height, data: y), cb: Plane(width: width, height: height, data: cb),
                  cr: Plane(width: width, height: height, data: cr))
    }
}
