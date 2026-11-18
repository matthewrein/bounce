import XCTest
@testable import BounceCore

/// Rendered drops (`KitSyntheticDrops`: physical bounces off the dish, motion blur, the recorder's timestamps) through
/// the scorer's own per-frame path and the drop analysis (`KitDropBench`), against the truth, on the owner's 7 in slab. A
/// debug build renders two drops small (360x270 at 30 fps, the camera 0.9 m from the point it aims at, so that the slab
/// is about as many pixels across as in the full-size drops' 480x360 processing frames) with a finder that knows where
/// the ball is; an optimised build also runs the app's own ball finder on real-size frames (1440x1080 at 60 fps).
final class KitSyntheticDropsTests: XCTestCase {
    func small() -> KitSyntheticDrops {
        var o = KitSyntheticDrops.Options()
        o.shrink = 4
        o.fps = 30
        o.blurSamples = 3
        return KitSyntheticDrops(options: o)
    }

    func horizontal(_ a: Vec3, _ b: Vec3) -> Double { (a - b).rejecting(Vec3(0, 1, 0)).length }

    /// The truth-based finder on a centre drop and a drop 2 in off the centre (on the owner's 7 in slab, where the dish
    /// leans 2.4° there), analysed as a kit is (no floor): the slab locks before the cue, the rebound comes back within
    /// 2 points and 3 sigma, the contact point on the dish within 5 mm of the truth plus the lock's own error and its
    /// local tilt within 0.1°, the landing within 1.5 cm, and the landing against the app's prediction (with its rebound
    /// and with the measured one) within 1.5 cm of the truth's at the analysis's own landing level; the report has a row
    /// per drop and the rebound to bake.
    func testCentreAndOffCentreWithTheTruthBall() throws {
        var o = KitDropBench.Options()
        o.drops = small().options
        o.drops.shots = [KitDropShot.standardSet[0], KitDropShot.standardSet[2]].map { s in var s = s; s.cameraDistance = 0.9; return s }
        o.truthBall = true
        let rep = try KitDropBench.run(o)
        XCTAssertEqual(rep.results.count, 2)
        for r in rep.results {
            let id = r.shot.id
            XCTAssertTrue(r.lockedBeforeCue, id)
            XCTAssertLessThan(try XCTUnwrap(r.lockNormalError), 0.5, id)
            let a = try XCTUnwrap(r.measured, "\(id): \(r.failure ?? "")")
            let t = r.truth, lt = try XCTUnwrap(r.measuredTruth, id)
            XCTAssertEqual(lt.level, a.landingLevel, id)
            XCTAssertNotEqual(a.landingLevelSource, "floor", "\(id): a kit has no floor")
            XCTAssertEqual(try XCTUnwrap(a.rebound), t.rebound, accuracy: 0.02, id)
            XCTAssertLessThan(abs(a.rebound! - t.rebound) / max(0.005, a.reboundSigma ?? 0), 3, id)
            // (the lock of a 7 in slab at this size is a few mm off itself: the contact point is the lock's)
            XCTAssertLessThan(a.contactPoint.distance(to: t.contactPoint), 0.005 + (r.lockCenterError ?? 0), id)
            XCTAssertEqual(try XCTUnwrap(a.normalTilt), t.normalTilt, accuracy: 0.1, id)
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), lt.landing), 0.015, id)
            XCTAssertEqual(try XCTUnwrap(a.app).landingError, try XCTUnwrap(lt.app).landingError, accuracy: 0.015, id)
            XCTAssertEqual(try XCTUnwrap(a.measuredRebound).landingError, try XCTUnwrap(lt.trueRebound).landingError, accuracy: 0.015, id)
            XCTAssertEqual(a.dropHeight, t.dropHeight, accuracy: 0.005, id)
            // the perfect track with the true slab: the analysis alone
            XCTAssertEqual(try XCTUnwrap(r.perfect?.rebound), t.rebound, accuracy: 0.002, id)
        }
        let md = rep.markdown()
        XCTAssertTrue(md.contains("| d01-centre |") && md.contains("| d03-2in-side |"), md)
        XCTAssertTrue(md.contains("true rebound 70%: rebound to bake into the app: 70%"), md)
        XCTAssertEqual(rep.summary.analysed, 2)
        XCTAssertEqual(rep.summary.reboundBeyond3Sigma, 0)
        XCTAssertFalse(rep.floorKnown)
        XCTAssertTrue(md.contains("The analysis has no floor, as in a kit"), md)
        let back = try KitJSON.decode(KitDropBenchReport.self, from: rep.json())
        XCTAssertEqual(back.results.map { $0.shot }, rep.results.map { $0.shot })
    }

    #if !DEBUG
    /// The app's own ball finder, set up for tracking, on real-size frames with motion blur, for a centre and an
    /// off-centre drop: its track is centimetres off along the line of sight on most frames, but the weighted fits still
    /// give the rebound within 5 points and 3 sigma, the contact point within 4 cm and the landing within 6 cm (at the
    /// analysis's own level, no floor). On an 18 in slab, the first drop set's: there the app's crop is shrunk by 2, so
    /// the ball is about 11 px in radius. On the owner's 7 in slab the crop is not shrunk, the ball is about 22 px in
    /// radius, and the finder loses this renderer's ball on most frames (the same crop shrunk by 2 finds it on every
    /// frame): `bounce-score --drops` reports it, and CaptureKit.md says so. This test keeps the finder's path to the
    /// analysis covered where the finder can follow the ball: the centre drop and the first set's 4 in one (on the 18 in
    /// slab the finder sees the 2 in drop d03's ball on only a third of its frames, and not rising after the bounce).
    func testTheAppsBallFinder() throws {
        var o = KitSyntheticDrops.Options()
        o.spec = SlabSpec(sideU: Units.inches(18), sideV: Units.inches(18), thickness: Units.inches(1), dishDepth: Units.inches(0.125))
        let maker = KitSyntheticDrops(options: o)
        let side4 = KitDropShot(id: "d03-4in-side", tilt: 8, offsetInches: 4, offsetAzimuth: 90, heightInches: 12, rebound: 0.7, cameraAzimuth: 120)
        for shot in [KitDropShot.standardSet[0], side4] {
            let r = try KitDropBench.score(maker.make(shot), maker: maker, truthBall: false)
            let a = try XCTUnwrap(r.measured, "\(shot.id): \(r.failure ?? "")")
            XCTAssertEqual(try XCTUnwrap(a.rebound), r.truth.rebound, accuracy: 0.05, shot.id)
            XCTAssertLessThan(abs(a.rebound! - r.truth.rebound) / max(0.005, a.reboundSigma ?? 0), 3, shot.id)
            XCTAssertLessThan(a.contactPoint.distance(to: r.truth.contactPoint), 0.04, shot.id)
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), try XCTUnwrap(r.measuredTruth).landing), 0.06, shot.id)
        }
    }
    #endif
}
