import XCTest
@testable import BounceCore

/// bounce-score --positions (n11): shots kit.json puts in the wrong slab position are scored against the right one, or
/// as an unmeasured position (what they read, no error); and the scorer's 'settled' numbers (the tilt as the app shows it).
final class KitScorerPositionsTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-positions-\(UUID().uuidString)")
    }

    override func tearDown() { if let r = root { try? FileManager.default.removeItem(at: r) } }

    func testParsingAndMatchingShots() {
        let p = KitScorer.parsePositions("s07=p4, s08=unmeasured,s09-held-high=p1")
        XCTAssertEqual(p, ["s07": "p4", "s08": "unmeasured", "s09-held-high": "p1"])
        XCTAssertNil(KitScorer.parsePositions("s07"))
        XCTAssertNil(KitScorer.parsePositions("s07=,s08=p1"))
        XCTAssertNil(KitScorer.parsePositions(""))
        var o = KitScorer.Options()
        o.positions = ["s07": "p4", "s09": "unmeasured", "s09-held-high": "p1"]
        XCTAssertEqual(o.position(forShot: "s07-ball-3ft"), "p4")
        XCTAssertEqual(o.position(forShot: "s07-ball-5ft"), "p4")
        XCTAssertEqual(o.position(forShot: "s07"), "p4")
        XCTAssertNil(o.position(forShot: "s070-other"), "a key matches whole parts of the id")
        XCTAssertEqual(o.position(forShot: "s09-held-mid"), KitScorer.unmeasured)
        XCTAssertEqual(o.position(forShot: "s09-held-high"), "p1", "the longest key wins")
        XCTAssertNil(o.position(forShot: "s04-level-still"))
    }

    /// The tiny synthetic kit with its level still shot called unmeasured and its tilt-1 still shot put in the level
    /// position: the first reads its tilt with no error, the second is scored against the level truth.
    func testOverridesScoreAgainstTheGivenPosition() throws {
        var ko = KitSyntheticKit.Options()
        ko.framesPerShot = 10
        ko.shots = ["s01-measure", "s03-flat-level", "s04-level-still", "s05-tilt1-flat", "s05-tilt1-still"]
        ko.ballWidth = nil; ko.ballHeight = nil
        let kit = try KitSyntheticKit.build(root: root, options: ko)
        var o = kit.scorerOptions()
        o.positions = KitScorer.parsePositions("s04=unmeasured,s05-tilt1-still=p1")!
        let r = try KitScorer(kitFolder: kit.folder, options: o).score()
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("Slab positions overridden (--positions): s04-level-still unmeasured, s05-tilt1-still p1") },
                      "\(r.notes)")

        let level = try XCTUnwrap(r.shot("s04-level-still"))
        XCTAssertEqual(level.positionId, KitScorer.unmeasured)
        XCTAssertNil(level.trueTiltDegrees)
        XCTAssertNil(level.metric("tiltErrorMedian")?.value)
        XCTAssertEqual(level.metric("tiltErrorMedian")?.note, "the slab's position in this shot has no true tilt (--positions: unmeasured)")
        XCTAssertEqual(try XCTUnwrap(level.metric("tiltReading")?.value), 0, accuracy: 0.5, "reads the level slab, no error")
        XCTAssertNotNil(level.metric("settledRate")?.value)
        XCTAssertNotNil(level.metric("settledTiltReading"))

        let moved = try XCTUnwrap(r.shot("s05-tilt1-still"))
        XCTAssertEqual(moved.positionId, "p1")
        XCTAssertEqual(moved.trueTiltDegrees ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(moved.metric("tiltErrorMedian")?.value), 5, accuracy: 0.6, "the 5 deg slab against the level truth")
        XCTAssertEqual(r.position("p1")?.shots, ["s05-tilt1-still"])
        XCTAssertEqual(r.position("p2")?.shots, [])
        // the settled numbers are in the report and its Markdown
        XCTAssertNotNil(r.aggregate("settledRate"))
        XCTAssertNotNil(r.aggregate("timeToSettle"))
        let md = r.markdown()
        XCTAssertTrue(md.contains("Settled (shown, from, error med / max)"), md)
        XCTAssertTrue(md.contains("| s04-level-still | unmeasured |"), md)
        XCTAssertTrue(md.contains("reads "), md)
    }
}
