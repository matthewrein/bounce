import XCTest
@testable import BounceCore

#if os(macOS) || os(Linux)
/// The video decoder on small clips encoded here (H.264 and HEVC, full and limited range). Skipped without ffmpeg
/// (CI's Linux container has none).
final class KitVideoDecoderTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(KitFFmpeg.isAvailable, "ffmpeg and ffprobe are not installed")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kit-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { if let d = dir { try? FileManager.default.removeItem(at: d) } }

    /// Frames of one flat colour each (full range): luma levels from near black to near white.
    static let levels: [(y: UInt8, cb: UInt8, cr: UInt8)] = [(18, 128, 128), (60, 100, 150), (110, 140, 120), (160, 128, 128), (205, 110, 160), (240, 128, 128)]
    static func frames(width w: Int = 128, height h: Int = 96) -> [YCCImage] {
        levels.map { l in
            YCCImage(width: w, height: h, y: [UInt8](repeating: l.y, count: w * h), cb: [UInt8](repeating: l.cb, count: (w / 2) * (h / 2)),
                     cr: [UInt8](repeating: l.cr, count: (w / 2) * (h / 2)))
        }
    }

    func mean(_ b: [UInt8]) -> Double { Double(b.reduce(0) { $0 + Int($1) }) / Double(b.count) }

    func roundTrip(_ codec: KitVideoEncoder.Codec, fullRange: Bool) throws {
        let url = dir.appendingPathComponent("\(codec.rawValue)-\(fullRange ? "full" : "limited").mp4")
        let input = KitVideoDecoderTests.frames()
        try KitVideoEncoder.encode(input, fps: 30, codec: codec, fullRange: fullRange, crf: 12, to: url)
        let probe = try KitVideoDecoder.probe(url)
        XCTAssertEqual(probe.codec, codec == .h264 ? "h264" : "hevc")
        XCTAssertEqual(probe.width, 128); XCTAssertEqual(probe.height, 96)
        XCTAssertEqual(probe.frames, input.count)
        XCTAssertEqual(probe.isFullRange, fullRange, "range tag \(probe.colorRange ?? "none"), pixel format \(probe.pixelFormat)")
        let dec = try KitVideoDecoder(url: url, expectedFrames: input.count)
        var got: [YCCImage] = []
        while let f = try dec.next() { got.append(f) }
        XCTAssertEqual(got.count, input.count, "every frame, none repeated or dropped")
        try dec.finish()
        for (g, e) in zip(got, input) {
            XCTAssertEqual(g.width, 128); XCTAssertEqual(g.height, 96)
            // decoded to full range: the levels come back within a couple of steps, whatever the stream's range
            XCTAssertEqual(mean(g.y), mean(e.y), accuracy: 2.5, "\(codec) \(fullRange ? "full" : "limited") luma")
            XCTAssertEqual(mean(g.cb), mean(e.cb), accuracy: 2.5)
            XCTAssertEqual(mean(g.cr), mean(e.cr), accuracy: 2.5)
        }
    }

    func testH264FullRange() throws { try roundTrip(.h264, fullRange: true) }
    func testH264LimitedRange() throws { try roundTrip(.h264, fullRange: false) }
    func testHEVCFullRange() throws { try roundTrip(.hevc, fullRange: true) }
    func testHEVCLimitedRange() throws { try roundTrip(.hevc, fullRange: false) }

    /// A limited-range stream read as if it were full range keeps its compressed levels (16 for black): the range tag
    /// matters, and the decoder follows it.
    func testRangeOverrideShowsTheDifference() throws {
        let url = dir.appendingPathComponent("limited.mp4")
        try KitVideoEncoder.encode(KitVideoDecoderTests.frames(), fps: 30, codec: .h264, fullRange: false, crf: 12, to: url)
        let raw = try KitVideoDecoder(url: url, fullRange: true)
        let first = try XCTUnwrap(raw.next())
        raw.close()
        XCTAssertEqual(mean(first.y), 16 + 18 * 219 / 255, accuracy: 2.5, "the stream's own levels")
    }

    /// frames.jsonl with another number of lines than the video has frames is an error, before decoding.
    func testFrameCountMismatchIsAnError() throws {
        let url = dir.appendingPathComponent("six.mp4")
        try KitVideoEncoder.encode(KitVideoDecoderTests.frames(), fps: 30, codec: .h264, fullRange: true, to: url)
        XCTAssertThrowsError(try KitVideoDecoder(url: url, expectedFrames: 7)) { e in
            XCTAssertEqual(e as? KitVideoError, .frameCountMismatch(video: 6, frames: 7))
            XCTAssertEqual("\(e)", "the video has 6 frames but frames.jsonl has 7 lines")
        }
        // stopping early is fine
        let d = try KitVideoDecoder(url: url, expectedFrames: 6)
        XCTAssertNotNil(try d.next())
        d.close()
        XCTAssertNil(try d.next())
    }

    /// A file that is not a video says so, without the folder it is in.
    func testNotAVideo() throws {
        let url = dir.appendingPathComponent("video.mp4")
        try Data("not a video".utf8).write(to: url)
        XCTAssertThrowsError(try KitVideoDecoder(url: url)) { e in
            guard case .probeFailed(let why)? = e as? KitVideoError else { return XCTFail("\(e)") }
            XCTAssertFalse(why.contains(self.dir.path), "no folders in messages: \(why)")
        }
    }
}
#endif
