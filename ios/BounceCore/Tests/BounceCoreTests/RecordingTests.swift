import XCTest
@testable import BounceCore

final class RecordingTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testYCCRoundTripAndColour() {
        let w = 5, h = 3, cw = 3, ch = 2
        let img = YCCImage(width: w, height: h, y: (0..<(w * h)).map { UInt8($0 * 10) }, cb: [UInt8](repeating: 128, count: cw * ch), cr: [UInt8](repeating: 200, count: cw * ch))
        let back = YCCImage(data: img.data)!
        XCTAssertEqual(back, img)
        let cf = back.colorFrame
        XCTAssertEqual(cf.width, 5)
        XCTAssertEqual(cf.cb[0, 0], 0, accuracy: 1e-4)
        XCTAssertEqual(cf.cr[4, 2], (200 - 128) / 0.713, accuracy: 1e-3)
        XCTAssertNil(YCCImage(data: Data([1, 2, 3])))
    }

    func testBiplanarDownscale() {
        // 8x4 luma, 4x2 chroma (interleaved CbCr), padded rows
        let W = 8, H = 4, lb = 10, cbb = 12
        var luma = [UInt8](repeating: 0, count: lb * H), cbcr = [UInt8](repeating: 0, count: cbb * 2)
        for y in 0..<H { for x in 0..<W { luma[y * lb + x] = UInt8(x * 10 + y) } }
        for y in 0..<2 { for x in 0..<4 { cbcr[y * cbb + x * 2] = UInt8(100 + x); cbcr[y * cbb + x * 2 + 1] = UInt8(150 + y) } }
        let img = luma.withUnsafeBufferPointer { l in cbcr.withUnsafeBufferPointer { c in
            YCCImage.fromBiplanar(luma: l, lumaWidth: W, lumaHeight: H, lumaBytesPerRow: lb, cbcr: c, cbcrBytesPerRow: cbb, factor: 2) } }
        XCTAssertEqual(img.width, 4); XCTAssertEqual(img.height, 2)
        XCTAssertEqual(img.y[0], UInt8((0 + 10 + 1 + 11) / 4))
        XCTAssertEqual(img.chromaWidth, 2); XCTAssertEqual(img.chromaHeight, 1)
        XCTAssertEqual(img.cb[0], UInt8((100 + 101 + 100 + 101) / 4))
        XCTAssertEqual(img.cr[1], UInt8((150 + 150 + 151 + 151) / 4))
    }

    func testDepthRoundTrip() {
        let d = DepthMap(width: 3, height: 2, depth: [0, 0.5, 1.25, 2, 3.5, Float.nan], confidence: [0, 1, 2, 2, 1, 0])
        let back = DepthMap(data: d.data)!
        XCTAssertEqual(back.width, 3)
        XCTAssertEqual(back.depth[2], 1.25)
        XCTAssertTrue(back.depth[5].isNaN)
        XCTAssertEqual(back.confidence, d.confidence)
    }

    func testWriterReaderRoundTrip() throws {
        let folder = tmp.appendingPathComponent("s.bouncerec")
        let session = RecordingSession(build: "test", device: "linux", frameWidth: 4, frameHeight: 2, settings: RecordingSettings())
        let w = try RecordingWriter(folder: folder, session: session)
        let K = CameraIntrinsics(fx: 3, fy: 3, cx: 2, cy: 1, width: 4, height: 2)
        for i in 0..<3 {
            var f = RecordedFrame(index: 99, timestamp: Double(i) / 30, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K)
            f.gravityCamera = [0, 1, 0]
            let img = YCCImage(width: 4, height: 2, y: [UInt8](repeating: UInt8(i), count: 8), cb: [128, 128], cr: [128, 128])
            try w.append(f, image: img, depth: i == 1 ? DepthMap(width: 2, height: 1, depth: [1, 2], confidence: [2, 2]) : nil)
        }
        w.close()
        let r = try RecordingReader(folder: folder)
        XCTAssertEqual(r.session, session)
        XCTAssertEqual(r.frames.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(try r.image(for: r.frames[2]).y[0], 2)
        XCTAssertNil(try r.depth(for: r.frames[0]))
        XCTAssertEqual(try r.depth(for: r.frames[1])?.depth, [1, 2])
        XCTAssertEqual(r.frames[1].timestamp, 1.0 / 30, accuracy: 1e-12)
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum([UInt8]()), 0)
    }

    func testZipIsReadableByUnzip() throws {
        let folder = tmp.appendingPathComponent("rec.bouncerec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: folder.appendingPathComponent("b.bin"))
        let zip = tmp.appendingPathComponent("rec.zip")
        try ZipWriter.zip(folder: folder, to: zip)
        let bytes = [UInt8](try Data(contentsOf: zip))
        XCTAssertEqual(Array(bytes[0..<4]), [0x50, 0x4B, 0x03, 0x04])
        // end of central directory says two entries
        let eocd = bytes.count - 22
        XCTAssertEqual(Array(bytes[eocd..<(eocd + 4)]), [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(Int(bytes[eocd + 10]) | Int(bytes[eocd + 11]) << 8, 2)
        // if an unzip tool is installed, it must accept the archive and get the files back
        let unzip = ["/usr/bin/unzip", "/opt/homebrew/bin/unzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        #if os(Linux) || os(macOS)
        if let u = unzip {
            let p = Process(); p.executableURL = URL(fileURLWithPath: u)
            let out = tmp.appendingPathComponent("out")
            p.arguments = ["-q", zip.path, "-d", out.path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("rec.bouncerec/a.txt"), encoding: .utf8), "hello")
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("rec.bouncerec/b.bin")).count, 1000)
        }
        #endif
    }
}
