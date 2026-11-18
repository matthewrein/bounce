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

    /// Two-tone frames (full range): the top half at `a`, the bottom half at `b`, neutral chroma.
    static func twoTone(_ a: UInt8, _ b: UInt8, width w: Int = 128, height h: Int = 96) -> YCCImage {
        var y = [UInt8](repeating: a, count: w * h)
        for i in (w * h / 2)..<(w * h) { y[i] = b }
        return YCCImage(width: w, height: h, y: y, cb: [UInt8](repeating: 128, count: (w / 2) * (h / 2)),
                        cr: [UInt8](repeating: 128, count: (w / 2) * (h / 2)))
    }

    /// The camera's mean luma of a full-range frame, as frames.jsonl has it (every 8th pixel).
    static func cameraLuma(_ f: YCCImage) -> Double? {
        f.y.withUnsafeBufferPointer { KitImageStats.meanLuma(bytes: $0, width: f.width, height: f.height, bytesPerRow: f.width) }
    }

    /// A stream without a range tag (the phone's encoder may leave it out) is read the way its samples say, not as
    /// limited range: full-range samples with a black base are full range (and the scorer's decoder keeps the black
    /// black); without samples outside 16-235, the camera's own mean luma (frames.jsonl) decides; an untagged
    /// limited-range stream is still read as limited.
    func testUntaggedStreamsAreJudgedFromTheirSamples() throws {
        // full range with a black base (luma 4) and a highlight (250): the samples say full range
        let base = (0..<4).map { _ in KitVideoDecoderTests.twoTone(4, 250) }
        let u1 = dir.appendingPathComponent("untagged-base.mp4")
        try KitVideoEncoder.encode(base, fps: 30, codec: .h264, fullRange: true, tagRange: false, crf: 12, to: u1)
        let p1 = try KitVideoDecoder.probe(u1)
        XCTAssertNil(p1.colorRange, "no range tag")
        XCTAssertFalse(p1.isFullRange, "an untagged stream reads as limited by its tag alone")
        let c1 = try KitVideoDecoder.rangeCheck(url: u1, luma: base.map { KitVideoDecoderTests.cameraLuma($0) })
        XCTAssertTrue(c1.fullRange, c1.reason)
        XCTAssertGreaterThan(c1.outsideShare, 0.3)
        let d1 = try KitVideoDecoder(url: u1, fullRange: c1.fullRange)
        let f1 = try XCTUnwrap(d1.next())
        d1.close()
        XCTAssertLessThan(Double(f1.y[0]), 10, "the black base stays black, not crushed or lifted")

        // full range within 16-235 (dark and light, away from mid-grey): the camera's mean luma decides
        let mid = (0..<4).map { _ in KitVideoDecoderTests.twoTone(30, 60) }
        let luma = mid.map { KitVideoDecoderTests.cameraLuma($0) }
        let u2 = dir.appendingPathComponent("untagged-full.mp4")
        try KitVideoEncoder.encode(mid, fps: 30, codec: .h264, fullRange: true, tagRange: false, crf: 12, to: u2)
        let c2 = try KitVideoDecoder.rangeCheck(url: u2, luma: luma)
        XCTAssertTrue(c2.fullRange, c2.reason)
        XCTAssertLessThan(try XCTUnwrap(c2.fullLumaError), 1.5)

        // the same pictures as an untagged limited-range stream: limited
        let u3 = dir.appendingPathComponent("untagged-limited.mp4")
        try KitVideoEncoder.encode(mid, fps: 30, codec: .h264, fullRange: false, tagRange: false, crf: 12, to: u3)
        let c3 = try KitVideoDecoder.rangeCheck(url: u3, luma: luma)
        XCTAssertFalse(c3.fullRange, c3.reason)
        XCTAssertLessThan(try XCTUnwrap(c3.limitedLumaError), 1.5)

        // the scorer's frames: the untagged full-range clip is read as full range, with a note saying so
        let shot = dir.appendingPathComponent("shot")
        try FileManager.default.createDirectory(at: shot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: u1, to: shot.appendingPathComponent(KitClipFiles.video))
        let frames = base.enumerated().map { i, f in
            KitFrame(index: i, time: Double(i) / 30, pose: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], intrinsics: [100, 100, 64, 48],
                     luma: KitVideoDecoderTests.cameraLuma(f))
        }
        let m = KitShotManifest(kitId: "k", shotId: "s04-level-still", step: 4, attempt: 1, startedAt: "2026-01-01T00:00:00Z", duration: 1,
                                build: "test", device: KitDevice(modelIdentifier: "test", systemVersion: "0", hasLiDAR: false),
                                measurements: KitMeasurements(settings: RecordingSettings()))
        let src = try KitScorer.videoFrames(KitScorer.ShotInput(shotId: "s04-level-still", folder: shot, manifest: m, frames: frames))
        defer { src.close() }
        let dec = try XCTUnwrap(src as? KitVideoDecoder)
        XCTAssertTrue(dec.rangeNote?.hasPrefix("the video has no colour range tag") ?? false, dec.rangeNote ?? "no note")
        XCTAssertLessThan(Double(try XCTUnwrap(dec.next()).y[0]), 10)
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
