import XCTest
@testable import BounceCore

/// The scorer on a tiny synthetic kit (rendered here, known truth).
final class KitScorerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-score-\(UUID().uuidString)")
    }

    override func tearDown() { if let r = root { try? FileManager.default.removeItem(at: r) } }

    /// The shots of the tiny kit: two slab positions with their true tilts, a still shot in each, a held ball with its
    /// height entered, and the negative without the slab.
    static let tinyShots: Set<String> = ["s01-measure", "s03-flat-level", "s04-level-still", "s05-tilt1-flat", "s05-tilt1-still",
                                         "s09-held-low", "s12-no-slab"]

    func tinyKit(frames: Int = 10, shots: Set<String> = KitScorerTests.tinyShots, video: String? = nil) throws -> KitSyntheticKit {
        var o = KitSyntheticKit.Options()
        o.framesPerShot = frames
        o.shots = shots
        o.video = video
        return try KitSyntheticKit.build(root: root, options: o)
    }

    func testScoresATinySyntheticKit() throws {
        let kit = try tinyKit()
        // the kit is made as the app makes one
        let m = kit.store.manifest
        XCTAssertTrue(m.measurementsEntered)
        XCTAssertNotNil(m.finishedAt)
        XCTAssertEqual(m.positions.map { $0.id }, ["p1", "p2", "p3"])
        XCTAssertNil(m.position("p3")?.groundTruth, "the second tilt's flat-phone shot was skipped")
        XCTAssertEqual(m.record("s09-held-low")?.enteredHeightInches ?? 0, 4, accuracy: 0.05)

        var o = kit.scorerOptions(truthBall: true)
        var lines: [String] = []
        o.log = { lines.append($0) }
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.kitId, "synthetic", "the synthetic kit is not mistaken for a captured one")
        XCTAssertEqual(r.source, "synthetic")
        XCTAssertEqual(r.settings, "app")
        XCTAssertEqual(r.shots.map { $0.shotId }, ["s04-level-still", "s05-tilt1-still", "s09-held-low", "s12-no-slab"])
        XCTAssertTrue(r.shots.allSatisfy { $0.error == nil }, "\(r.shots.compactMap { $0.error })")

        // tilt well under half a degree, against the flat-phone true tilt; the normal's direction too
        let tilt = try XCTUnwrap(r.aggregate("tiltErrorMedian")?.value)
        XCTAssertLessThan(tilt, 0.5)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("tiltErrorP90")?.value), 0.8)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("normalErrorMedian")?.value), 0.6)
        XCTAssertEqual(r.shot("s05-tilt1-still")?.trueTiltDegrees ?? 0, 5, accuracy: 0.05)
        XCTAssertEqual(r.position("p2")?.link?.yawDegrees ?? 0, 37, accuracy: 0.1, "the CoreMotion-to-ARKit link")
        XCTAssertEqual(r.position("p3")?.metric("tiltErrorMedian")?.value, nil)
        // locks quickly and stays locked
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.aggregate("lockRate")?.value), 0.9)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("timeToLock")?.value), 0.8)
        XCTAssertEqual(r.aggregate("neverLocked")?.value, 0)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("cornerRms")?.value), 3)
        XCTAssertLessThan(abs(try XCTUnwrap(r.aggregate("slabSizeError")?.value)), 3)
        // no slab where there is none
        let neg = try XCTUnwrap(r.shot("s12-no-slab"))
        XCTAssertEqual(neg.metric("slabFoundRate")?.value, 0)
        XCTAssertEqual(neg.metric("slabLockedRate")?.value, 0)
        XCTAssertEqual(neg.metric("ballFalsePositiveRate")?.note,
                       "the app looks for the ball only on a lock, and the slab is not in view")
        // the held ball, found by the truth-based finder: the drop height the app works out from it
        let held = try XCTUnwrap(r.shot("s09-held-low"))
        XCTAssertEqual(held.metric("ballDetectionRate")?.value, 1)
        XCTAssertLessThan(abs(try XCTUnwrap(held.metric("dropHeightError")?.value)), 10)
        XCTAssertEqual(r.shot("s04-level-still")?.metric("ballFalsePositiveRate")?.value, 0)
        // progress lines: ids and numbers only
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines.allSatisfy { !$0.contains("/") })

        // JSON: round trip, and no paths in it
        let set = KitScoreSet(reports: [r], scoredAt: "2026-11-17T00:00:00Z", scorer: "test")
        let data = try set.json()
        XCTAssertEqual(try KitScoreSet.read(data), set)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(root.path), "no paths in the report")
        XCTAssertFalse(text.contains(FileManager.default.temporaryDirectory.path))
        let md = set.markdown()
        XCTAssertTrue(md.contains("| s05-tilt1-still | p2 | 10 |"), md)
        XCTAssertFalse(md.contains(root.path))
    }

    /// Without a ball finder the ball metrics are n/a, with the reason; scoring with the kit's measurements is noted.
    func testWithoutABallFinderAndWithTheMeasurements() throws {
        let kit = try tinyKit(frames: 6, shots: ["s01-measure", "s09-held-low"])
        var o = kit.scorerOptions()
        o.makeBallLocator = { nil }
        o.useMeasurements = true
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.settings, "measured")
        let held = try XCTUnwrap(r.shot("s09-held-low"))
        XCTAssertEqual(held.metric("ballDetectionRate")?.note, "no ball finder in this build")
        XCTAssertEqual(held.metric("dropHeightError")?.note, "no ball finder in this build")
        XCTAssertNil(held.metric("tiltErrorMedian")?.value)
        XCTAssertEqual(held.metric("tiltErrorMedian")?.note, "no true tilt for p3 (its flat-phone shot was skipped or failed)")
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("No ball finder in this build") })
        XCTAssertEqual(r.aggregate("ballDetectionRate")?.note, "no ball finder in this build")
        XCTAssertEqual(r.aggregate("landingError")?.note, "no drop scored")
    }

    /// A shot whose video ends early is reported as not scored, and the others are still scored.
    func testAShortVideoIsAnErrorForThatShotOnly() throws {
        let kit = try tinyKit(frames: 6, shots: ["s04-level-still", "s12-no-slab"])
        var o = kit.scorerOptions()
        o.frames = { input in
            let all = try kit.frames(input)
            let n = input.shotId == "s04-level-still" ? 3 : input.frames.count
            var frames: [YCCImage] = []
            for _ in 0..<n { if let f = try all.next() { frames.append(f) } }
            return KitArrayFrameSource(width: all.width, height: all.height, frames: frames)
        }
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertEqual(r.shot("s04-level-still")?.error, "the video ended after 3 frames but frames.jsonl has 6 lines")
        XCTAssertNil(r.shot("s12-no-slab")?.error)
        XCTAssertEqual(r.shot("s12-no-slab")?.metric("slabLockedRate")?.value, 0)
        XCTAssertTrue(r.markdown().contains("could not be: s04-level-still"))
    }

    func testNotAKit() {
        XCTAssertThrowsError(try KitScorer(kitFolder: root).score()) { XCTAssertEqual($0 as? KitScoreError, .notAKit) }
    }

    #if os(macOS) || os(Linux)
    /// With ffmpeg: the synthetic kit written as H.264 and decoded back, as a captured kit is.
    func testThroughEncodedVideo() throws {
        try XCTSkipUnless(KitFFmpeg.isAvailable, "ffmpeg and ffprobe are not installed")
        let kit = try tinyKit(frames: 8, shots: ["s03-flat-level", "s04-level-still"], video: "h264")
        let still = kit.folder.appendingPathComponent("shots/s04-level-still/video.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: still.path))
        XCTAssertEqual(try KitVideoDecoder.probe(still).isFullRange, false)
        var o = KitScorer.Options()
        o.source = "synthetic"
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertNil(r.shot("s04-level-still")?.error)
        XCTAssertLessThan(try XCTUnwrap(r.aggregate("tiltErrorMedian")?.value), 0.5)
    }
    #endif
}
