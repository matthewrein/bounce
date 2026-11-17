import XCTest
@testable import BounceCore

final class KitPlanTests: XCTestCase {
    let plan = KitPlan.standard

    func testStandardPlanShape() {
        XCTAssertEqual(plan.id, "standard-v1")
        XCTAssertEqual(plan.timeScale, 1)
        XCTAssertEqual(plan.stepCount, 12)
        XCTAssertEqual(plan.steps.map { $0.number }, Array(1...12))
        // the table in CaptureKit.md: 25 shots, plus 3 optional for the third tilt
        XCTAssertEqual(plan.shotCount, 28)
        XCTAssertEqual(plan.requiredShots.count, 25)
        XCTAssertEqual(plan.optionalShots.map { $0.id }, ["s05-tilt3-flat", "s05-tilt3-still", "s05-tilt3-arc"])
        XCTAssertEqual(Set(plan.shots.map { $0.id }).count, plan.shotCount, "shot ids are unique")
        var lastStep = 0
        for s in plan.shots {
            XCTAssertTrue(s.id.hasPrefix(String(format: "s%02d-", s.step)), s.id)
            XCTAssertGreaterThanOrEqual(s.step, lastStep, "plan order follows the steps")
            lastStep = s.step
            XCTAssertFalse(s.title.isEmpty); XCTAssertFalse(s.instruction.isEmpty)
            XCTAssertNotNil(s.id.range(of: "^[a-z0-9-]+$", options: .regularExpression), "ids are safe folder names: \(s.id)")
        }
        for n in 1...12 { XCTAssertFalse(plan.shots(inStep: n).isEmpty, "step \(n) has shots") }
        let ids = plan.shots.map { $0.id }
        XCTAssertEqual(Array(ids.prefix(5)), ["s01-measure", "s02-scan", "s03-flat-level", "s04-level-still", "s04-level-arc"])
        XCTAssertEqual(plan.shots(inStep: 5).map { $0.id }, ["s05-tilt1-flat", "s05-tilt1-still", "s05-tilt1-arc", "s05-tilt2-flat",
                                                               "s05-tilt2-still", "s05-tilt2-arc", "s05-tilt3-flat", "s05-tilt3-still", "s05-tilt3-arc"])
        XCTAssertEqual(Array(ids.suffix(14)), ["s06-dim", "s06-bright", "s07-ball-3ft", "s07-ball-5ft", "s08-ball-centre", "s09-held-low",
                                               "s09-held-mid", "s09-held-high", "s10-drop1", "s10-drop2", "s10-drop3", "s11-drop-edge",
                                               "s12-no-slab", "s12-no-ball"])
    }

    func testKindsCountdownsAndPositions() {
        let form = plan.shots.filter { $0.isForm }
        XCTAssertEqual(form.map { $0.id }, ["s01-measure"])
        XCTAssertEqual(form[0].countdown, 0)
        let flats = plan.shots.filter { $0.isFlat }
        XCTAssertEqual(flats.map { $0.id }, ["s03-flat-level", "s05-tilt1-flat", "s05-tilt2-flat", "s05-tilt3-flat"])
        XCTAssertEqual(flats.map { $0.startsPosition?.id }, ["p1", "p2", "p3", "p4"])
        XCTAssertEqual(flats.map { $0.startsPosition?.label }, ["level", "tilt 1", "tilt 2", "tilt 3"])
        for f in flats { XCTAssertEqual(f.countdown, 5) }
        for s in plan.shots where s.isVideo {
            XCTAssertEqual(s.countdown, 3, s.id)
            XCTAssertNil(s.startsPosition)
            XCTAssertGreaterThan(s.kind.videoSeconds ?? 0, 0)
        }
        let hfr = plan.shots.filter { $0.kind.highFrameRate }.map { $0.id }
        XCTAssertEqual(hfr, ["s10-drop1", "s10-drop2", "s10-drop3", "s11-drop-edge"])
        for id in hfr {
            let cue = plan.shot(id)?.kind.releaseCue
            XCTAssertEqual(cue, 2)
            XCTAssertLessThan(cue ?? 99, plan.shot(id)?.kind.videoSeconds ?? 0)
        }
        XCTAssertEqual(plan.shots.filter { $0.kind.releaseCue != nil }.count, 4)
        XCTAssertEqual(plan.shot("s02-scan")?.kind.videoSeconds, 20)
        XCTAssertEqual(plan.shot("s04-level-arc")?.kind.videoSeconds, 20)
        XCTAssertEqual(plan.shot("s05-tilt2-arc")?.kind.videoSeconds, 15)
        XCTAssertEqual(plan.shot("s06-dim")?.kind.videoSeconds, 6)
    }

    func testExpectations() {
        func e(_ id: String) -> KitExpectations { plan.shot(id)?.expect ?? KitExpectations() }
        XCTAssertEqual(e("s02-scan").minTrackingShare, 0.6)
        XCTAssertEqual(e("s02-scan").motion, .moving)
        XCTAssertEqual(e("s04-level-still"), KitExpectations(slab: .required, ball: .forbidden, light: .normal, motion: .still))
        XCTAssertEqual(e("s04-level-arc").motion, .moving)
        XCTAssertEqual(e("s06-dim").light, .dim)
        XCTAssertEqual(e("s06-bright").light, .bright)
        XCTAssertEqual(e("s07-ball-3ft").slab, .forbidden); XCTAssertEqual(e("s07-ball-3ft").ball, .required)
        XCTAssertEqual(e("s08-ball-centre").slab, .required); XCTAssertEqual(e("s08-ball-centre").ball, .required)
        XCTAssertEqual(e("s10-drop1").ball, .required)
        XCTAssertEqual(e("s12-no-slab").slab, .forbidden); XCTAssertEqual(e("s12-no-slab").ball, .forbidden)
        XCTAssertEqual(e("s12-no-ball").slab, .required); XCTAssertEqual(e("s12-no-ball").ball, .forbidden)
        for s in plan.shots where s.expect.light != .normal { XCTAssertTrue(s.id.hasPrefix("s06-")) }
        XCTAssertEqual(plan.lightReferenceShotId, "s04-level-still")
        XCTAssertNotNil(plan.shot(plan.lightReferenceShotId))
    }

    func testHeightsAndDiagrams() {
        let asks = plan.shots.filter { $0.asksHeight }
        XCTAssertEqual(asks.map { $0.id }, ["s09-held-low", "s09-held-mid", "s09-held-high"])
        XCTAssertEqual(asks.map { $0.nominalHeightInches }, [4, 12, 24])
        XCTAssertEqual(plan.shot("s10-drop2")?.nominalHeightInches, 12)
        // every picture the app must draw is used, and every shot has one
        let used = Set(plan.shots.map { $0.diagram })
        XCTAssertEqual(used, Set(KitDiagram.allCases))
    }

    func testLookups() {
        XCTAssertEqual(plan.index(of: "s01-measure"), 0)
        XCTAssertEqual(plan.index(of: "s12-no-ball"), plan.shotCount - 1)
        XCTAssertNil(plan.index(of: "nope"))
        XCTAssertEqual(plan.shot("s08-ball-centre")?.step, 8)
        XCTAssertNil(plan.shot("s99"))
        XCTAssertEqual(plan.step(4)?.title, "Slab only, level")
        XCTAssertNil(plan.step(13))
        XCTAssertEqual(plan.progressLabel(step: 4), "Step 4 of 12")
        XCTAssertEqual(plan.shots(inStep: 9).count, 3)
        XCTAssertTrue(plan.shots(inStep: 13).isEmpty)
    }

    func testTimeScale() {
        let fast = plan.scaled(by: 0.25)
        XCTAssertEqual(fast.timeScale, 0.25)
        XCTAssertEqual(fast.id, plan.id)
        XCTAssertEqual(fast.shotCount, plan.shotCount)
        XCTAssertEqual(fast.shot("s04-level-arc")?.kind.videoSeconds, 5)
        XCTAssertEqual(fast.shot("s04-level-arc")?.countdown, 0.75)
        XCTAssertEqual(fast.shot("s03-flat-level")?.countdown, 1.25)
        XCTAssertEqual(fast.shot("s01-measure")?.countdown, 0)
        XCTAssertEqual(fast.shot("s10-drop1")?.kind.releaseCue, 0.5)
        XCTAssertEqual(fast.shot("s10-drop1")?.kind.highFrameRate, true)
        XCTAssertEqual(fast.flatSettings.readingSeconds, 0.75)
        XCTAssertEqual(fast.flatSettings.timeoutA, 2)
        XCTAssertEqual(fast.flatSettings.stillSpreadDegrees, plan.flatSettings.stillSpreadDegrees, "thresholds do not scale")
        XCTAssertEqual(fast.scaled(by: 0.5).timeScale, 0.125)
        XCTAssertEqual(fast.recordingSeconds(), plan.recordingSeconds() * 0.25, accuracy: 1e-9)
        XCTAssertEqual(KitPlan.named("standard-v1"), plan)
        XCTAssertEqual(KitPlan.named("standard-v1", timeScale: 0.25), fast)
        XCTAssertNil(KitPlan.named("other"))
        XCTAssertNil(KitPlan.named("standard-v1", timeScale: 0))
    }

    func testRecordingTimeIsAboutThreeMinutes() {
        let s = plan.recordingSeconds()
        XCTAssertGreaterThan(s, 150); XCTAssertLessThan(s, 240)
        XCTAssertEqual(plan.recordingSeconds(includingOptional: true) - s, 12 + 5 + 15, accuracy: 1e-9)
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(KitPlan.self, from: data), plan)
        let kinds: [KitShotKind] = [.form, .flat, .video(seconds: 6, highFrameRate: true, releaseCue: 2), .video(seconds: 5, highFrameRate: false, releaseCue: nil)]
        for k in kinds { XCTAssertEqual(try JSONDecoder().decode(KitShotKind.self, from: JSONEncoder().encode(k)), k) }
    }
}
