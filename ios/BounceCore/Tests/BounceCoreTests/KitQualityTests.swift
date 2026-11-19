import XCTest
@testable import BounceCore

final class KitQualityTests: XCTestCase {
    let plan = KitPlan.standard
    func shot(_ id: String) -> KitShotSpec { plan.shot(id) ?? plan.shots[0] }

    /// n frames; the first `share` of each kind true
    func stats(_ n: Int, luma: Double? = 120, blur: Double? = 1, tracking: Double = 1, slab: Double = 1, ball: Double = 0,
               ambient: Double? = nil) -> [KitFrameStat] {
        (0..<n).map { i in
            let f = Double(i) / Double(n)
            return KitFrameStat(t: Double(i) / 30, trackingNormal: f < tracking - 1e-9, luma: luma, blurPixels: blur,
                                slabFound: f < slab - 1e-9, slabLocked: false, ballFound: f < ball - 1e-9, ambientLumens: ambient)
        }
    }

    func testAGoodShot() throws {
        let r = KitQuality.evaluate(shot: shot("s04-level-still"), stats: stats(150), expectedFrames: 150)
        XCTAssertEqual(r.verdict, .good)
        XCTAssertEqual(r.summary, "Good. Every check passed.")
        XCTAssertEqual(r.checks.map { $0.id }, ["frames", "tracking", "light", "blur", "slab", "falsePositives"])
        XCTAssertTrue(r.problems.isEmpty)
        XCTAssertEqual(r.frames, 150)
        XCTAssertEqual(r.medianLuma, 120)
        XCTAssertEqual(r.medianBlur, 1)
        XCTAssertEqual(KitQuality.expectedFrames(shot: shot("s04-level-still"), fps: 30), 150)
        XCTAssertEqual(KitQuality.expectedFrames(shot: shot("s10-drop1"), fps: 60), 360)
        XCTAssertEqual(KitQuality.expectedFrames(shot: shot("s03-flat-level"), fps: 30), 0)
    }

    func testFrames() {
        let s = shot("s04-level-still")
        let ok = KitQuality.evaluate(shot: s, stats: stats(120), expectedFrames: 150)
        XCTAssertEqual(ok.check("frames")?.passed, true, "80% exactly passes")
        let bad = KitQuality.evaluate(shot: s, stats: stats(119), expectedFrames: 150)
        XCTAssertEqual(bad.check("frames")?.passed, false)
        XCTAssertEqual(bad.verdict, .poor)
        XCTAssertTrue(bad.summary.hasPrefix("Poor. The phone dropped frames (only 79% recorded)."), bad.summary)
        XCTAssertTrue(bad.summary.hasSuffix("Retry is suggested."))
        let none = KitQuality.evaluate(shot: s, stats: [], expectedFrames: 150)
        XCTAssertEqual(none.verdict, .poor)
        XCTAssertEqual(none.checks.map { $0.id }, ["frames"])
    }

    func testTracking() {
        let s = shot("s04-level-still")
        XCTAssertEqual(KitQuality.evaluate(shot: s, stats: stats(100, tracking: 0.70), expectedFrames: 100).check("tracking")?.passed, true)
        let bad = KitQuality.evaluate(shot: s, stats: stats(100, tracking: 0.69), expectedFrames: 100)
        XCTAssertEqual(bad.check("tracking")?.passed, false)
        XCTAssertEqual(bad.verdict, .fair)
        XCTAssertTrue(bad.summary.contains("lost track of the room in 31% of frames"), bad.summary)
        XCTAssertTrue(bad.summary.hasSuffix("Next is fine."))
        // the room scan, where tracking settles, needs 60%
        XCTAssertEqual(KitQuality.evaluate(shot: shot("s02-scan"), stats: stats(100, tracking: 0.60), expectedFrames: 100).check("tracking")?.passed, true)
        XCTAssertEqual(KitQuality.evaluate(shot: shot("s02-scan"), stats: stats(100, tracking: 0.59), expectedFrames: 100).check("tracking")?.passed, false)
    }

    func testLight() {
        let level = shot("s04-level-still"), dim = shot("s06-dim"), bright = shot("s06-bright")
        func light(_ s: KitShotSpec, _ luma: Double, ref: Double? = nil, ambient: Double? = nil, refAmbient: Double? = nil) -> KitQualityReport {
            KitQuality.evaluate(shot: s, stats: stats(60, luma: luma, ambient: ambient), expectedFrames: 60,
                                reference: KitQualityReference(levelStillMedianLuma: ref, levelStillMedianAmbient: refAmbient))
        }
        XCTAssertEqual(light(level, 45).check("light")?.passed, true)
        XCTAssertEqual(light(level, 44.9).check("light")?.passed, false)
        XCTAssertTrue(light(level, 30).summary.contains("Too dark (brightness 30 of 255)"))
        XCTAssertNil(light(level, 100, ref: 100).check("lightChange"), "normal shots are not compared")
        XCTAssertEqual(light(dim, 12).check("light")?.passed, true)
        XCTAssertEqual(light(dim, 11).check("light")?.passed, false)
        XCTAssertTrue(light(dim, 8).summary.contains("Too dark even for the dim shot"))
        XCTAssertNil(light(dim, 50).check("lightChange"), "without a reference there is nothing to compare")
        XCTAssertEqual(light(bright, 44, ref: 30).check("light")?.passed, false, "bright shots still need 45")
        // the median, not the mean
        var mixed = stats(61, luma: 120)
        for i in 0..<30 { mixed[i].luma = 0 }
        XCTAssertEqual(KitQuality.evaluate(shot: level, stats: mixed, expectedFrames: 61).medianLuma, 120)
    }

    func testLightChangeUsesTheLightEstimateNotTheAutoExposedPicture() {
        let level = shot("s04-level-still"), dim = shot("s06-dim"), bright = shot("s06-bright")
        func light(_ s: KitShotSpec, _ luma: Double, ref: Double? = nil, ambient: Double? = nil, refAmbient: Double? = nil) -> KitQualityReport {
            KitQuality.evaluate(shot: s, stats: stats(60, luma: luma, ambient: ambient), expectedFrames: 60,
                                reference: KitQualityReference(levelStillMedianLuma: ref, levelStillMedianAmbient: refAmbient))
        }
        XCTAssertEqual(light(level, 120, ambient: 950).medianAmbient, 950)
        XCTAssertNil(light(level, 120).medianAmbient)
        // the camera kept the picture at 120 in both shots, but the light estimate fell to 69%: dimmer
        XCTAssertEqual(light(dim, 120, ref: 120, ambient: 690, refAmbient: 1000).check("lightChange")?.passed, true)
        XCTAssertEqual(light(dim, 120, ref: 120, ambient: 690, refAmbient: 1000).verdict, .good)
        let notDim = light(dim, 120, ref: 120, ambient: 700, refAmbient: 1000)
        XCTAssertEqual(notDim.check("lightChange")?.passed, false, "must be below 70%")
        XCTAssertEqual(notDim.check("lightChange")?.severity, .fair)
        XCTAssertEqual(notDim.check("lightChange")?.value ?? 0, 0.7, accuracy: 1e-12)
        XCTAssertEqual(notDim.summary, "Fair. It doesn't look dimmer than the level shot (light level 700 vs 1000). Dim the room more. Next is fine.")
        XCTAssertEqual(light(bright, 120, ref: 120, ambient: 1101, refAmbient: 1000).verdict, .good)
        let notBright = light(bright, 120, ref: 120, ambient: 1100, refAmbient: 1000)
        XCTAssertEqual(notBright.verdict, .fair, "must be above 110%")
        XCTAssertTrue(notBright.summary.contains("doesn't look brighter than the level shot (light level 1100 vs 1000). Turn on more light."), notBright.summary)
        // without light estimates, the picture's brightness is only reported: auto-exposure would fail good shots
        let lumaOnly = light(bright, 120, ref: 120)
        XCTAssertEqual(lumaOnly.check("lightChange")?.passed, false)
        XCTAssertEqual(lumaOnly.check("lightChange")?.severity, .info)
        XCTAssertEqual(lumaOnly.verdict, .good)
        XCTAssertTrue(lumaOnly.check("lightChange")?.message.contains("brightness 120 vs 120 in the level shot") ?? false)
        XCTAssertEqual(light(dim, 69.9, ref: 100).check("lightChange")?.passed, true)
        XCTAssertEqual(light(dim, 70, ref: 100).check("lightChange")?.passed, false)
        XCTAssertEqual(light(dim, 90, ref: 100).verdict, .good)
        XCTAssertEqual(light(bright, 110.1, ref: 100).check("lightChange")?.passed, true)
        // an estimate on this shot but not on the reference falls back to brightness
        XCTAssertEqual(light(dim, 120, ref: 120, ambient: 900).check("lightChange")?.severity, .info)
        // and so does an estimate on fewer than half the frames
        var few = stats(60, luma: 120, ambient: 900)
        for i in 0..<31 { few[i].ambientLumens = nil }
        let r = KitQuality.evaluate(shot: dim, stats: few, expectedFrames: 60,
                                    reference: KitQualityReference(levelStillMedianLuma: 120, levelStillMedianAmbient: 1000))
        XCTAssertNil(r.medianAmbient)
        XCTAssertEqual(r.check("lightChange")?.severity, .info)
        few[30].ambientLumens = 900
        XCTAssertEqual(KitQuality.evaluate(shot: dim, stats: few, expectedFrames: 60).medianAmbient, 900, "half the frames is enough")
    }

    func testFramesWithoutLumaOrBlurAreNotCounted() {
        // the app measured luma on every third frame only: the light check uses those frames, not a made-up 128
        let s = shot("s04-level-still")
        var st = stats(150, luma: nil, blur: nil)
        for i in stride(from: 0, to: 150, by: 3) { st[i].luma = 15; st[i].blurPixels = 7 }
        let r = KitQuality.evaluate(shot: s, stats: st, expectedFrames: 150)
        XCTAssertEqual(r.medianLuma, 15)
        XCTAssertEqual(r.check("light")?.passed, false)
        XCTAssertEqual(r.medianBlur, 7)
        XCTAssertEqual(r.verdict, .poor, "blur 7 px is over twice the 3 px limit")
        // nothing measured: reported, never failed
        let none = KitQuality.evaluate(shot: s, stats: stats(150, luma: nil, blur: nil), expectedFrames: 150)
        XCTAssertEqual(none.verdict, .good)
        XCTAssertNil(none.medianLuma); XCTAssertNil(none.medianBlur)
        XCTAssertEqual(none.check("light")?.severity, .info)
        XCTAssertEqual(none.check("light")?.message, "Brightness was not measured.")
        XCTAssertEqual(none.check("blur")?.message, "Blur was not measured.")
        XCTAssertNil(KitQuality.evaluate(shot: shot("s06-dim"), stats: stats(60, luma: nil), expectedFrames: 60,
                                         reference: KitQualityReference(levelStillMedianLuma: 100)).check("lightChange"))
        // non-finite numbers count as not measured
        XCTAssertNil(KitFrameStat(t: 0, luma: .nan, blurPixels: .infinity, ambientLumens: .nan).luma)
        XCTAssertNil(KitFrameStat(t: 0, luma: .nan, blurPixels: .infinity).blurPixels)
    }

    func testBlur() {
        func blur(_ id: String, _ b: Double) -> KitQualityReport { KitQuality.evaluate(shot: shot(id), stats: stats(60, blur: b), expectedFrames: 60) }
        XCTAssertEqual(blur("s04-level-still", 3).check("blur")?.passed, true)
        XCTAssertEqual(blur("s04-level-still", 3.1).verdict, .fair)
        XCTAssertEqual(blur("s04-level-still", 6).verdict, .fair)
        XCTAssertEqual(blur("s04-level-still", 6.1).verdict, .poor)
        XCTAssertTrue(blur("s04-level-still", 7).summary.contains("Hold the phone steadier"))
        XCTAssertEqual(blur("s04-level-arc", 6).check("blur")?.passed, true)
        XCTAssertEqual(blur("s04-level-arc", 12).verdict, .fair)
        XCTAssertEqual(blur("s04-level-arc", 12.1).verdict, .poor)
        XCTAssertTrue(blur("s04-level-arc", 9).summary.contains("Walk more slowly"))
    }

    func testSlabAndBall() {
        let s = shot("s08-ball-centre")
        XCTAssertEqual(KitQuality.evaluate(shot: s, stats: stats(100, slab: 0.5, ball: 0.3), expectedFrames: 100).verdict, .good)
        let noSlab = KitQuality.evaluate(shot: s, stats: stats(100, slab: 0.49, ball: 0.3), expectedFrames: 100)
        XCTAssertEqual(noSlab.verdict, .fair)
        XCTAssertEqual(noSlab.check("slab")?.passed, false)
        XCTAssertEqual(noSlab.summary, "Fair. The app found the slab in only 49% of frames. If the slab was in view, Next is fine.",
                       "said once, not twice")
        let noBall = KitQuality.evaluate(shot: s, stats: stats(100, slab: 1, ball: 0.29), expectedFrames: 100)
        XCTAssertEqual(noBall.verdict, .fair)
        XCTAssertEqual(noBall.summary, "Fair. The app found the ball in only 29% of frames. If the ball was in view, Next is fine.")
        // a slab locked counts as found
        XCTAssertTrue(KitFrameStat(t: 0, slabLocked: true).slabFound)
        // ball-only shots do not look for the slab
        let ballOnly = KitQuality.evaluate(shot: shot("s07-ball-3ft"), stats: stats(100, slab: 0, ball: 1), expectedFrames: 100)
        XCTAssertNil(ballOnly.check("slab"))
        XCTAssertEqual(ballOnly.verdict, .good)
    }

    func testFalsePositivesAreReportedAndNeverFail() {
        let r = KitQuality.evaluate(shot: shot("s12-no-slab"), stats: stats(100, slab: 0.25, ball: 0.1), expectedFrames: 100)
        let c = r.check("falsePositives")
        XCTAssertEqual(c?.passed, true)
        XCTAssertEqual(c?.severity, .info)
        XCTAssertEqual(c?.value ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertTrue(c?.message.contains("the app found a slab or ball in 25% of frames") ?? false, c?.message ?? "")
        XCTAssertTrue(c?.message.contains("kept following after it left the picture, is the real slab") ?? false, c?.message ?? "")
        XCTAssertEqual(r.verdict, .good)
        XCTAssertNil(r.check("slab"))
        // slab-only shots report a ball that is not there
        let s = KitQuality.evaluate(shot: shot("s04-level-still"), stats: stats(100, slab: 1, ball: 0.5), expectedFrames: 100)
        XCTAssertEqual(s.check("falsePositives")?.value ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.check("falsePositives")?.message, "For the record: the app saw a ball that isn't there in 50% of frames.")
        XCTAssertEqual(s.verdict, .good)
    }

    func testFormAndFlatShotsAreNotVideoChecked() {
        XCTAssertEqual(KitQuality.evaluate(shot: shot("s01-measure"), stats: [], expectedFrames: 0).verdict, .good)
        XCTAssertTrue(KitQuality.evaluate(shot: shot("s03-flat-level"), stats: stats(10), expectedFrames: 0).checks.isEmpty)
    }

    func reading(spread: Double = 0.05, tilt: Double = 1) -> KitFlatReading {
        KitFlatReading(samples: 300, start: 0, end: 3, gravity: Vec3(0, 0, -1), spreadDegrees: spread, rmsDegrees: spread / 3,
                       attitude: .identity, maxRotationRate: 0.01, tiltDegrees: tilt, azimuthDegrees: 0)
    }

    func flat(_ method: KitTrueTilt.Method = .twoReading, a: KitFlatReading? = nil, b: KitFlatReading? = nil, turn: Double? = 180, bump: [Double]? = [1, 0.5]) -> KitTrueTilt {
        KitTrueTilt(method: method, tiltDegrees: 3, downhillAzimuthDegrees: 0, uncertaintyDegrees: 0.02, bumpDegrees: bump, turnDegrees: turn,
                    readingA: a ?? reading(), readingB: b ?? reading())
    }

    func testFlatChecks() {
        let s = shot("s03-flat-level")
        let good = KitQuality.evaluate(shot: s, flat: flat())
        XCTAssertEqual(good.verdict, .good)
        XCTAssertEqual(good.checks.map { $0.id }, ["still", "still", "flat", "flat", "turn", "bump"])
        XCTAssertEqual(KitQuality.evaluate(shot: s, flat: flat(a: reading(spread: 0.3))).verdict, .good, "0.3 degrees exactly passes")
        let moved = KitQuality.evaluate(shot: s, flat: flat(b: reading(spread: 0.31)))
        XCTAssertEqual(moved.verdict, .poor)
        XCTAssertTrue(moved.summary.contains("moved during reading B"), moved.summary)
        let notFlat = KitQuality.evaluate(shot: s, flat: flat(a: reading(tilt: 26)))
        XCTAssertEqual(notFlat.verdict, .poor)
        XCTAssertTrue(notFlat.summary.contains("not lying flat"))
        XCTAssertEqual(KitQuality.evaluate(shot: s, flat: flat(a: reading(tilt: 25))).verdict, .good)
        for (turn, verdict) in [(120.0, KitVerdict.good), (240, .good), (119, .fair), (241, .fair), (90, .fair), (300, .fair)] {
            XCTAssertEqual(KitQuality.evaluate(shot: s, flat: flat(turn: turn)).verdict, verdict, "turn \(turn)")
        }
        XCTAssertTrue(KitQuality.evaluate(shot: s, flat: flat(turn: 90)).summary.contains("it still works, less precisely"))
        XCTAssertTrue(KitQuality.evaluate(shot: s, flat: flat(.uncorrected, turn: 30, bump: nil)).summary.contains("turned only 30°"))
        let one = KitQuality.evaluate(shot: s, flat: KitTrueTilt(method: .uncorrected, tiltDegrees: 3, readingA: reading()))
        XCTAssertEqual(one.verdict, .fair)
        XCTAssertTrue(one.summary.contains("Only one reading"))
        XCTAssertNil(one.check("bump"))
        XCTAssertEqual(KitQuality.evaluate(shot: s, flat: flat(bump: [3, 4])).verdict, .good, "5 degrees exactly passes")
        let bump = KitQuality.evaluate(shot: s, flat: flat(bump: [3, 4.1]))
        XCTAssertEqual(bump.verdict, .fair)
        XCTAssertTrue(bump.summary.contains("camera bump"))
        let failed = KitQuality.evaluate(shot: s, flat: .failed("No reading"))
        XCTAssertEqual(failed.verdict, .poor)
        XCTAssertEqual(failed.checks.map { $0.id }, ["reading"])
        // the phone lay still, screen down: the owner is told which reading went wrong
        let down = KitQuality.evaluate(shot: s, flat: .failed("The phone was not lying flat, screen up (it read 175°).", readingA: reading(tilt: 175)))
        XCTAssertEqual(down.verdict, .poor)
        XCTAssertEqual(down.checks.map { $0.id }, ["still", "flat"])
        XCTAssertEqual(down.summary, "Poor. In reading A the phone was not lying flat, screen up (175°). Lay it flat in the middle of the slab, screen up. Retry is suggested.")
        // a failed result whose readings look fine still fails, with its reason
        let odd = KitQuality.evaluate(shot: s, flat: .failed("Something else.", readingA: reading()))
        XCTAssertEqual(odd.verdict, .poor)
        XCTAssertEqual(odd.check("reading")?.message, "Something else.")
    }

    func testVerdictOrderAndReportBuilding() {
        XCTAssertLessThan(KitVerdict.good, .fair)
        XCTAssertLessThan(KitVerdict.fair, .poor)
        let checks = [KitQualityCheck(id: "a", passed: false, severity: .fair, message: "Soft."),
                      KitQualityCheck(id: "b", passed: false, severity: .poor, message: "Hard."),
                      KitQualityCheck(id: "c", passed: false, severity: .info, message: "Info.")]
        let r = KitQualityReport(checks: checks)
        XCTAssertEqual(r.verdict, .poor)
        XCTAssertEqual(r.summary, "Poor. Hard. Retry is suggested.")
        XCTAssertEqual(r.problems.map { $0.id }, ["a", "b"])
        XCTAssertEqual(KitQualityReport(checks: [checks[0], checks[2]]).summary, "Fair. Soft. Next is fine.")
        let says = [KitQualityCheck(id: "a", passed: false, severity: .poor, message: "Bad. Retry is suggested.")]
        XCTAssertEqual(KitQualityReport(checks: says).summary, "Poor. Bad. Retry is suggested.")
        XCTAssertEqual(KitQualityReport(checks: [KitQualityCheck(id: "a", passed: false, severity: .fair, message: "")]).summary, "Fair. Next is fine.")
        XCTAssertEqual(KitQualityReport(checks: [checks[2]]).verdict, .good, "info never fails a shot")
    }

    func testFrameStatFromAFrame() {
        var f = KitFrame(index: 0, time: 3, pose: [], intrinsics: [], tracking: .limitedInitializing, ambientLumens: 800, luma: 90, blur: 2.5,
                         live: KitLiveResult(state: .locked, ball: (Vec2(1, 1), 5)))
        var s = KitFrameStat(frame: f)
        XCTAssertEqual(s, KitFrameStat(t: 3, trackingNormal: false, luma: 90, blurPixels: 2.5, slabFound: true, slabLocked: true, ballFound: true, ambientLumens: 800))
        f.live = KitLiveResult(state: .confirming); f.luma = nil; f.blur = nil; f.tracking = .normal
        s = KitFrameStat(frame: f)
        XCTAssertTrue(s.slabFound); XCTAssertFalse(s.slabLocked); XCTAssertFalse(s.ballFound); XCTAssertTrue(s.trackingNormal)
        XCTAssertNil(s.luma, "not measured stays not measured"); XCTAssertNil(s.blurPixels)
        f.live = KitLiveResult(state: .other("lost"))
        XCTAssertFalse(KitFrameStat(frame: f).slabFound, "a state this build does not know is not a find")
        f.live = nil
        XCTAssertFalse(KitFrameStat(frame: f).slabFound)
    }

    func testImageStats() {
        let flat = Plane(width: 40, height: 30, fill: 100)
        XCTAssertEqual(KitImageStats.meanLuma(flat), 100)
        XCTAssertEqual(KitImageStats.sharpness(flat), 0)
        var ramp = Plane(width: 8, height: 8)
        for y in 0..<8 { for x in 0..<8 { ramp[x, y] = Float(x * 10) } }
        XCTAssertEqual(KitImageStats.meanLuma(ramp, step: 1), 35)
        XCTAssertEqual(KitImageStats.meanLuma(ramp, step: 4), (0 + 40) / 2)
        XCTAssertEqual(KitImageStats.sharpness(ramp, step: 1), 10, "central difference of 20 over two pixels, x only, halved")
        var checker = Plane(width: 64, height: 64)
        for y in 0..<64 { for x in 0..<64 { checker[x, y] = ((x / 4 + y / 4) % 2 == 0) ? 200 : 40 } }
        let sharp = KitImageStats.sharpness(checker), soft = KitImageStats.sharpness(checker.blurred3().blurred3())
        XCTAssertGreaterThan(sharp, soft)
        XCTAssertEqual(KitImageStats.meanLuma(Plane(width: 0, height: 0)), 0)
        XCTAssertEqual(KitImageStats.sharpness(Plane(width: 2, height: 2)), 0)
    }

    func testMeanLumaFromTheCameraBuffer() {
        // 6x4 pixels in rows of 8 bytes (padding 255, which must not count)
        var bytes = [UInt8](repeating: 255, count: 8 * 4)
        for y in 0..<4 { for x in 0..<6 { bytes[y * 8 + x] = UInt8(10 * x + y) } }
        bytes.withUnsafeBufferPointer { b in
            // every pixel: mean of 10x + y over x 0..5, y 0..3 = 25 + 1.5
            XCTAssertEqual(KitImageStats.meanLuma(bytes: b, width: 6, height: 4, bytesPerRow: 8, step: 1) ?? -1, 26.5, accuracy: 1e-12)
            // every second pixel: x 0, 2, 4 and y 0, 2: 20 + 1
            XCTAssertEqual(KitImageStats.meanLuma(bytes: b, width: 6, height: 4, bytesPerRow: 8, step: 2) ?? -1, 21, accuracy: 1e-12)
            XCTAssertEqual(KitImageStats.meanLuma(bytes: b, width: 6, height: 4, bytesPerRow: 8, step: 0) ?? -1, 26.5, accuracy: 1e-12)
            // sizes that do not fit the buffer give nil, never a read past its end
            XCTAssertNil(KitImageStats.meanLuma(bytes: b, width: 6, height: 5, bytesPerRow: 8))
            XCTAssertNil(KitImageStats.meanLuma(bytes: b, width: 9, height: 4, bytesPerRow: 8))
            XCTAssertNil(KitImageStats.meanLuma(bytes: b, width: 0, height: 4, bytesPerRow: 8))
            XCTAssertNil(KitImageStats.meanLuma(bytes: b, width: 6, height: 4, bytesPerRow: Int.max / 2))
        }
        // the last row may stop at the image's width (no padding after it)
        let tight = [UInt8](repeating: 50, count: 8 * 3 + 6)
        tight.withUnsafeBufferPointer { XCTAssertEqual(KitImageStats.meanLuma(bytes: $0, width: 6, height: 4, bytesPerRow: 8, step: 1), 50) }
    }

    func testMotionBlur() {
        let a = RigidTransform.identity
        func rot(_ w: Vec3) -> RigidTransform {
            RigidTransform(rotation: Mat3(columns: Vec3(1, 0, 0).rotated(by: w), Vec3(0, 1, 0).rotated(by: w), Vec3(0, 0, 1).rotated(by: w)), translation: Vec3(1, 2, 3))
        }
        // pan at 0.5 rad/s for 1/30 s, 10 ms exposure, 1000 px focal: 5 px
        let pan = rot(Vec3(0, 0.5 / 30, 0))
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: pan, dt: 1.0 / 30, exposure: 0.01, focal: 1000), 5, accuracy: 1e-6)
        let r = KitMotionBlur.rates(previous: a, current: pan, dt: 1.0 / 30)
        XCTAssertEqual(r.axis, 0.5, accuracy: 1e-9); XCTAssertEqual(r.roll, 0, accuracy: 1e-9)
        // roll counts at half a focal length
        let roll = rot(Vec3(0, 0, 0.5 / 30))
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: roll, dt: 1.0 / 30, exposure: 0.01, focal: 1000), 2.5, accuracy: 1e-6)
        // both
        let both = rot(Vec3(0.3 / 30, 0, 0)) // tilt only
        XCTAssertEqual(KitMotionBlur.rates(previous: a, current: both, dt: 1.0 / 30).axis, 0.3, accuracy: 1e-9)
        // relative to the previous pose, wherever that is
        let base = rot(Vec3(0.3, -1.1, 2.0))
        let moved = RigidTransform(rotation: base.rotation * pan.rotation, translation: .zero)
        XCTAssertEqual(KitMotionBlur.pixels(previous: base, current: moved, dt: 1.0 / 30, exposure: 0.01, focal: 1000), 5, accuracy: 1e-6)
        // translation alone does not count; missing numbers give 0
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: RigidTransform(rotation: .identity, translation: Vec3(1, 0, 0)), dt: 0.03, exposure: 0.01, focal: 1000), 0)
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: pan, dt: 0, exposure: 0.01, focal: 1000), 0)
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: pan, dt: 0.03, exposure: 0, focal: 1000), 0)
        XCTAssertEqual(KitMotionBlur.pixels(previous: a, current: pan, dt: 0.03, exposure: .nan, focal: 1000), 0)
    }
}
