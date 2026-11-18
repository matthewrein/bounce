import XCTest
@testable import BounceCore

/// Rendered drops (`KitSyntheticDrops`: physical bounces off the dish, motion blur, the recorder's timestamps) through
/// the scorer's own per-frame path and the drop analysis (`KitDropBench`), against the truth. A debug build renders two
/// drops small (360x270 at 30 fps) with a finder that knows where the ball is; an optimised build also runs the app's
/// own ball finder on real-size frames (1440x1080 at 60 fps).
final class KitSyntheticDropsTests: XCTestCase {
    func small() -> KitSyntheticDrops {
        var o = KitSyntheticDrops.Options()
        o.shrink = 4
        o.fps = 30
        o.blurSamples = 3
        return KitSyntheticDrops(options: o)
    }

    func horizontal(_ a: Vec3, _ b: Vec3) -> Double { (a - b).rejecting(Vec3(0, 1, 0)).length }

    /// The truth-based finder on a centre drop and a drop 4 in off the centre: the slab locks before the cue, the
    /// rebound comes back within 2 points, the contact point on the dish within 5 mm and its local tilt within 0.1°, the
    /// landing within 1.5 cm, and the landing against the app's prediction (with its rebound and with the measured
    /// one) within 1.5 cm of the truth's; the report has a row per drop and the rebound to bake.
    func testCentreAndOffCentreWithTheTruthBall() throws {
        var o = KitDropBench.Options()
        o.drops = small().options
        o.drops.shots = [KitDropShot.standardSet[0], KitDropShot.standardSet[2]]
        o.truthBall = true
        let rep = try KitDropBench.run(o)
        XCTAssertEqual(rep.results.count, 2)
        for r in rep.results {
            let id = r.shot.id
            XCTAssertTrue(r.lockedBeforeCue, id)
            XCTAssertLessThan(try XCTUnwrap(r.lockNormalError), 0.5, id)
            let a = try XCTUnwrap(r.measured, "\(id): \(r.failure ?? "")")
            let t = r.truth
            XCTAssertEqual(try XCTUnwrap(a.rebound), t.rebound, accuracy: 0.02, id)
            XCTAssertLessThan(a.contactPoint.distance(to: t.contactPoint), 0.005, id)
            XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.1, id)
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), t.landing), 0.015, id)
            XCTAssertEqual(try XCTUnwrap(a.app).landingError, try XCTUnwrap(t.app).landingError, accuracy: 0.015, id)
            XCTAssertEqual(try XCTUnwrap(a.measuredRebound).landingError, try XCTUnwrap(t.trueRebound).landingError, accuracy: 0.015, id)
            XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.005, id)
            // the perfect track with the true slab: the analysis alone
            XCTAssertEqual(try XCTUnwrap(r.perfect?.rebound), t.rebound, accuracy: 0.002, id)
        }
        let md = rep.markdown()
        XCTAssertTrue(md.contains("| d01-centre |") && md.contains("| d03-4in-side |"), md)
        XCTAssertTrue(md.contains("true rebound 70%: rebound to bake into the app: 70%"), md)
        XCTAssertEqual(rep.summary.analysed, 2)
        let back = try KitJSON.decode(KitDropBenchReport.self, from: rep.json())
        XCTAssertEqual(back.results.map { $0.shot }, rep.results.map { $0.shot })
    }

    #if !DEBUG
    /// The app's own ball finder, set up for tracking, on real-size frames with motion blur: its track is centimetres
    /// off along the line of sight on most frames (on the 18 in slab the crop is shrunk by 2, so the ball is about 10 px
    /// across), but the weighted fits still give the rebound within 5 points, the contact point within 4 cm and the
    /// landing within 6 cm, for a centre and an off-centre drop.
    func testTheAppsBallFinder() throws {
        let maker = KitSyntheticDrops()
        for shot in [KitDropShot.standardSet[0], KitDropShot.standardSet[2]] {
            let r = try KitDropBench.score(maker.make(shot), maker: maker, truthBall: false)
            let a = try XCTUnwrap(r.measured, "\(shot.id): \(r.failure ?? "")")
            XCTAssertEqual(try XCTUnwrap(a.rebound), r.truth.rebound, accuracy: 0.05, shot.id)
            XCTAssertLessThan(a.contactPoint.distance(to: r.truth.contactPoint), 0.04, shot.id)
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), r.truth.landing), 0.06, shot.id)
        }
    }
    #endif
}
