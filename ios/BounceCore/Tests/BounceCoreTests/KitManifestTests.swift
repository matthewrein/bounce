import XCTest
@testable import BounceCore

final class KitManifestTests: XCTestCase {
    /// 2026-11-17 15:30:00 UTC
    let date = Date(timeIntervalSince1970: 1_794_929_400)

    static let device = KitDevice(modelIdentifier: "iPhone16,1", systemVersion: "18.1", hasLiDAR: true,
                                  cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60),
                                  highFrameRateFormat: KitCameraFormat(width: 1920, height: 1080, fps: 60))
    static let measurements = KitMeasurements(slabWidthInches: 7.1, slabDepthInches: 6.9, slabThicknessInches: 1.05, dishInches: 0.125, ballDiameterMm: 35)

    func testTimesAndKitIds() {
        XCTAssertEqual(KitTime.iso(date), "2026-11-17T15:30:00Z")
        XCTAssertEqual(KitTime.kitId(for: date), "slab-kit-20261117-153000")
        XCTAssertEqual(KitTime.date("2026-11-17T15:30:00Z"), date)
        XCTAssertNil(KitTime.date("yesterday"))
        XCTAssertEqual(KitTime.kitId(for: date.addingTimeInterval(9 * 3600 + 29 * 60 + 59)), "slab-kit-20261118-005959")
    }

    func testMeasurementRanges() {
        XCTAssertTrue(Self.measurements.isValid)
        XCTAssertEqual(Self.measurements.problems, [])
        func m(w: Double = 7, d: Double = 7, t: Double = 1, dish: Double? = 0.125, ball: Double = 35) -> KitMeasurements {
            KitMeasurements(slabWidthInches: w, slabDepthInches: d, slabThicknessInches: t, dishInches: dish, ballDiameterMm: ball)
        }
        for ok in [m(w: 3), m(w: 20), m(d: 3), m(d: 20), m(t: 0.2), m(t: 4), m(dish: nil), m(dish: 0), m(dish: 0.75), m(ball: 5), m(ball: 120)] {
            XCTAssertTrue(ok.isValid, "\(ok)")
        }
        for bad in [m(w: 2.99), m(w: 20.01), m(d: 0), m(t: 0.19), m(t: 4.01), m(dish: -0.01), m(dish: 0.76), m(ball: 4.9), m(ball: 121),
                    m(w: .nan), m(ball: .infinity)] {
            XCTAssertFalse(bad.isValid, "\(bad)")
            XCTAssertEqual(bad.problems.count, 1)
        }
        XCTAssertEqual(m(w: 2).problems, ["The slab's width must be between 3 and 20 inches."])
        XCTAssertEqual(m(t: 5).problems, ["The slab's thickness must be between 0.2 and 4 inches."])
        XCTAssertEqual(m(dish: 1).problems, ["The dish depth must be between 0 and 0.75 inches."])
        XCTAssertEqual(m(ball: 1).problems, ["The ball's diameter must be between 5 and 120 mm."])
        XCTAssertEqual(m(w: 1, ball: 1).problems.count, 2)
    }

    func testConversions() {
        let m = Self.measurements
        let slab = m.slab
        XCTAssertEqual(slab.sideU, 7.1 * 0.0254, accuracy: 1e-12)
        XCTAssertEqual(slab.sideV, 6.9 * 0.0254, accuracy: 1e-12)
        XCTAssertEqual(slab.thickness, 1.05 * 0.0254, accuracy: 1e-12)
        XCTAssertEqual(slab.dishDepth, 0.125 * 0.0254, accuracy: 1e-12)
        XCTAssertEqual(m.ball().diameter, 0.035, accuracy: 1e-12)
        XCTAssertEqual(m.ball().rebound, 0.70, accuracy: 1e-12)
        XCTAssertEqual(m.ball(rebound: 0.5).rebound, 0.5)
        let base = RecordingSettings(sideUInches: 5, sideVInches: 5, thicknessInches: 2, dishInches: 0.3, ballDiameterMm: 40, dropHeightFeet: 2, reboundPercent: 60)
        let s = m.recordingSettings(base: base)
        XCTAssertEqual(s.sideUInches, 7.1); XCTAssertEqual(s.sideVInches, 6.9); XCTAssertEqual(s.thicknessInches, 1.05)
        XCTAssertEqual(s.dishInches, 0.125); XCTAssertEqual(s.ballDiameterMm, 35)
        XCTAssertEqual(s.dropHeightFeet, 2); XCTAssertEqual(s.reboundPercent, 60)
        var noDish = m
        noDish.dishInches = nil
        XCTAssertEqual(noDish.recordingSettings(base: base).dishInches, 0.3, "an unmeasured dish keeps the setting")
        XCTAssertEqual(noDish.slab.dishDepth, Units.inches(RecordingSettings().dishInches), accuracy: 1e-12)
        XCTAssertEqual(KitMeasurements(settings: base).slabThicknessInches, 2)
        // the settings always hold a dish (usually the default): it is not taken for a measurement
        XCTAssertNil(KitMeasurements(settings: base).dishInches)
        var unmeasured = m
        unmeasured.dishInches = nil
        XCTAssertEqual(KitMeasurements(settings: s), unmeasured)
    }

    func testPositionGenerations() {
        XCTAssertEqual(KitSlabPosition.id(plan: "p2", generation: 1), "p2")
        XCTAssertEqual(KitSlabPosition.id(plan: "p2", generation: 3), "p2#3")
        let first = KitSlabPosition(id: "p2", label: "tilt 1", shotId: "s05-tilt1-flat")
        let third = KitSlabPosition(id: "p2#3", label: "tilt 1", shotId: "s05-tilt1-flat", generation: 3)
        XCTAssertEqual(first.planPositionId, "p2"); XCTAssertEqual(first.generationNumber, 1)
        XCTAssertEqual(third.planPositionId, "p2"); XCTAssertEqual(third.generationNumber, 3)
        var m = makeManifest()
        m.positions += [first, third]
        m.shots[3].status = .captured; m.shots[3].positionId = "p1"
        XCTAssertEqual(m.currentPosition(plan: "p2")?.id, "p2#3")
        XCTAssertNil(m.currentPosition(plan: "p4"))
        XCTAssertEqual(m.position(forShot: m.shots[3].id)?.id, "p1")
        XCTAssertNil(m.position(forShot: "s12-no-ball"))
        XCTAssertFalse(m.measurementsEntered)
        m.measurementsEnteredAt = KitTime.iso(date)
        XCTAssertTrue(m.measurementsEntered)
        XCTAssertEqual(try KitJSON.decode(KitManifest.self, from: KitJSON.encode(m)), m)
    }

    func testDeviceCarriesNoName() throws {
        let data = try KitJSON.encode(Self.device)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["modelIdentifier", "systemVersion", "hasLiDAR", "cameraFormat", "highFrameRateFormat"])
        XCTAssertEqual(try KitJSON.decode(KitDevice.self, from: data), Self.device)
    }

    func makeManifest() -> KitManifest {
        let plan = KitPlan.standard
        var m = KitManifest(kitId: KitTime.kitId(for: date), planId: plan.id, build: "1.0 (42)", createdAt: KitTime.iso(date),
                            device: Self.device, measurements: Self.measurements,
                            shots: plan.shots.map { KitShotRecord(id: $0.id, step: $0.step, optional: $0.optional) })
        let tilt = KitTrueTilt(method: .twoReading, tiltDegrees: 5.25, downhillAzimuthDegrees: 90, uncertaintyDegrees: 0.03,
                               bumpDegrees: [1.2, -0.4], turnDegrees: 178, residualDegrees: 0, gyroTiltDegrees: 5.3, reasons: ["Two readings."])
        m.positions = [KitSlabPosition(id: "p1", label: "level", shotId: "s03-flat-level", groundTruth: tilt, startedAt: KitTime.iso(date))]
        m.shots[1].status = .captured; m.shots[1].attempts = 2; m.shots[1].folder = "shots/s02-scan"; m.shots[1].verdict = .fair
        m.shots[1].bytes = 123_456; m.shots[1].frames = 600; m.shots[1].duration = 20.01
        return m
    }

    func testKitManifestRoundTrip() throws {
        let m = makeManifest()
        XCTAssertEqual(m.format, "bouncekit")
        XCTAssertEqual(m.version, 1)
        let data = try KitJSON.encode(m)
        let back = try KitJSON.decode(KitManifest.self, from: data)
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.record("s02-scan")?.verdict, .fair)
        XCTAssertEqual(back.position("p1")?.groundTruth?.tiltDegrees, 5.25)
        XCTAssertNil(back.position("p9"))
        XCTAssertFalse(back.isFinished)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"format\" : \"bouncekit\""))
        XCTAssertTrue(json.contains("\"status\" : \"captured\""))
        XCTAssertFalse(json.contains("\"name\""), "no device or owner names anywhere")
        XCTAssertFalse(json.contains("\"timeScale\""), "time scale 1 is left out")
    }

    func testShotManifestRoundTrip() throws {
        let q = KitQualityReport(checks: [KitQualityCheck(id: "frames", passed: true, severity: .poor, value: 1, threshold: 0.8, message: "ok")],
                                 frames: 150, medianLuma: 120, medianBlur: 1.5)
        let s = KitShotManifest(kitId: "slab-kit-x", shotId: "s10-drop1", step: 10, attempt: 1, startedAt: KitTime.iso(date), duration: 6.02,
                                build: "1.0 (42)", device: Self.device, measurements: Self.measurements, positionId: "p3",
                                trueTilt: makeManifest().positions[0].groundTruth,
                                video: KitVideoInfo(codec: "hevc", width: 1280, height: 960, fps: 60, bitrate: 5_000_000, frameCount: 361, fileBytes: 3_700_000),
                                cameraFormat: KitCameraFormat(width: 1920, height: 1440, fps: 60), hasDepth: true, depthFrames: 6,
                                motionSamples: 602, quality: q, releaseCue: 2, notes: "synthetic")
        XCTAssertEqual(s.format, "bouncekit-shot")
        var back = try KitJSON.decode(KitShotManifest.self, from: KitJSON.encode(s))
        XCTAssertEqual(back, s)
        // the uptime clock's start and release, and the motion and ARKit runs, are kept
        back.startTime = 12_345.678_9; back.releaseTime = 12_347.701; back.motionSessionId = "m1"; back.arSessionId = "a2"
        back.measurementsEntered = true
        let again = try KitJSON.decode(KitShotManifest.self, from: KitJSON.encode(back))
        XCTAssertEqual(again, back)
        XCTAssertEqual(again.startTime, 12_345.678_9)
        XCTAssertEqual(again.releaseTime, 12_347.701)
        XCTAssertEqual(back.quality?.verdict, .good)
        XCTAssertEqual(back.video?.frameCount, 361)
    }
}
