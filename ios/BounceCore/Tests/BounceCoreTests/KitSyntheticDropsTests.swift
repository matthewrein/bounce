import XCTest
@testable import BounceCore

/// Rendered drops (`KitSyntheticDrops`: physical bounces off the dish, motion blur, the recorder's timestamps) through
/// the scorer's own per-frame path and the drop analysis (`KitDropBench`), against the truth, on the owner's 7 in slab. A
/// debug build renders two drops small (360x270 at 30 fps, the camera where the set has it, the slab about 1 m away)
/// with a finder that knows where the ball is; an optimised build also runs the app's own ball finder on real-size
/// frames (1440x1080 at 60 fps).
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
    /// leans 2.4° there), analysed as a kit is (no floor): the slab locks before the cue (its normal within 0.5° and its
    /// centre within 6 mm: at this size the lock of a 7 in slab is a few mm off), the rebound comes back within 2 points
    /// and 3 sigma, the contact point on the dish within 5 mm of the truth plus the lock's own error and its local tilt
    /// within 0.1°, the landing within 1.5 cm, and the landing against the app's prediction (with its rebound
    /// and with the measured one) within 1.5 cm of the truth's at the analysis's own landing level; the report has a row
    /// per drop and the rebound to bake.
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
            // (bounded: the contact check below allows for it)
            XCTAssertLessThan(try XCTUnwrap(r.lockCenterError), 0.006, id)
            // the camera about 1 m from the slab, as the kit asks (3 to 4 ft); the finder's crop and the ball's size in it
            XCTAssertEqual(try XCTUnwrap(r.cameraDistance), 1.0, accuracy: 0.1, id)
            XCTAssertFalse(try XCTUnwrap(r.ballCropFactors, id).isEmpty, id)
            XCTAssertGreaterThan(try XCTUnwrap(r.ballImageRadius, id), 3, id)
            XCTAssertLessThanOrEqual(try XCTUnwrap(r.ballImageRadiusMin, id), r.ballImageRadius!, id)
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
        XCTAssertTrue(md.contains("| Camera to slab, crop shrink, ball radius (finder px) |"), md)
        XCTAssertTrue(md.contains("true rebound 70%: rebound to bake into the app: 70%"), md)
        XCTAssertEqual(rep.summary.analysed, 2)
        XCTAssertEqual(rep.summary.reboundBeyond3Sigma, 0)
        XCTAssertFalse(rep.floorKnown)
        XCTAssertTrue(md.contains("The analysis has no floor, as in a kit"), md)
        let back = try KitJSON.decode(KitDropBenchReport.self, from: rep.json())
        XCTAssertEqual(back.results.map { $0.shot }, rep.results.map { $0.shot })
    }

    #if !DEBUG
    /// The app's own ball finder, set up for tracking, on real-size frames with motion blur, on the owner's 7 in slab with
    /// the camera about 1 m from it (as the kit asks): the finder reads the rendered ball on only part of the frames and
    /// its track is centimetres off along the line of sight on most of them (CaptureKit.md, "Rendered drops"), but the
    /// weighted fits still give the rebound within 3 sigma, the contact point within 4 cm and the landing within 6 cm (at
    /// the analysis's own level, no floor), for two of the drops it measures: the 6 in drop 2 in out (its rebound within
    /// 5 points: 89% for 85%) and the drop 1 in downhill (within 8 points: it reads 75% for 70%). A change that loses
    /// either, or reads it worse, fails here; `bounce-score --drops` has the whole set. (With the app's own tangential
    /// share in the render instead of the rolling ball, `Options.tangential = .ratio(...)`, the analysis refuses one of
    /// the two. At n12's 0.4 it is the 6 in drop, "too little of the fall was seen (9 mm of 105 mm)": the finder loses
    /// the ball from 0.11 s to 0.24 s after the impact, over the bounce's apex above the dish (31 samples against 38), and
    /// the analysis then takes the descent after that gap, onto the next contact at 0.32 s, for the fall. At the 0.2 of
    /// n13 on it is the drop 1 in downhill, "too little of the fall was seen (26 mm of 219 mm)", and the 6 in drop reads
    /// 77% for 85%. Open: the finder near the apex, and a fall that a gap in the track can move.)
    func testTheAppsBallFinder() throws {
        let maker = KitSyntheticDrops()
        XCTAssertEqual(maker.options.spec, SlabSpec.standard)
        for (shot, tolerance) in [(KitDropShot.standardSet[6], 0.05), (KitDropShot.standardSet[1], 0.08)] {
            let r = try KitDropBench.score(maker.make(shot), maker: maker, truthBall: false)
            XCTAssertEqual(try XCTUnwrap(r.cameraDistance), 1.0, accuracy: 0.1, shot.id)
            let a = try XCTUnwrap(r.measured, "\(shot.id): \(r.failure ?? "")")
            XCTAssertEqual(try XCTUnwrap(a.rebound), r.truth.rebound, accuracy: tolerance, shot.id)
            XCTAssertLessThan(abs(a.rebound! - r.truth.rebound) / max(0.005, a.reboundSigma ?? 0), 3, shot.id)
            XCTAssertLessThan(a.contactPoint.distance(to: r.truth.contactPoint), 0.04, shot.id)
            XCTAssertLessThan(horizontal(try XCTUnwrap(a.landing), try XCTUnwrap(r.measuredTruth).landing), 0.06, shot.id)
        }
    }
    #endif
}
