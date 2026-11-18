import XCTest
@testable import BounceCore

final class PreflightTests: XCTestCase {
    // MARK: observations of a good phone run

    func goodARKit() -> PreflightARKitObservation {
        PreflightARKitObservation(supported: true, expectedFps: 60, window: 10, frames: 541, firstFrame: 0.5, lastFrame: 9.5,
                                  changes: [PreflightTrackingChange(t: 0.5, state: .limitedInitializing),
                                            PreflightTrackingChange(t: 1.5, state: .normal)])
    }

    func goodLiDAR() -> PreflightLiDARObservation {
        PreflightLiDARObservation(supported: true, frames: 541, framesWithDepth: 530,
                                  samples: (0..<9).map { _ in PreflightDepthSample(validShare: 0.98, confidentShare: 0.8, medianMeters: 1.3) })
    }

    func goodMotion() -> PreflightMotionObservation {
        PreflightMotionObservation(available: true, requestedHz: 100, window: 10, samples: 991, firstSample: 0.05, lastSample: 9.95,
                                   nonAdvancing: 0, maxGap: 0.012, gravityMedian: 1.0, gravityMin: 0.999, gravityMax: 1.001)
    }

    func goodRecorder() -> PreflightRecorderObservation {
        PreflightRecorderObservation(ran: true, requestedSeconds: 2, framesWritten: 60, frameLines: 60, motionLines: 200, codec: "hevc",
                                     width: 1440, height: 1080, fps: 30, fileBytes: 900_000, readBackSeconds: 2.0, readBackFrames: 60,
                                     readBackWidth: 1440, readBackHeight: 1080)
    }

    func observations(camera: PreflightCameraAccess = .authorized, arkit: PreflightARKitObservation? = nil, lidar: PreflightLiDARObservation? = nil,
                      motion: PreflightMotionObservation? = nil, freeBytes: Int64? = 30_000_000_000, recorder: PreflightRecorderObservation? = nil,
                      simulator: Bool = false, demo: Bool = false) -> PreflightObservations {
        PreflightObservations(build: "1.0 (n8)", device: "iPhone16,1", system: "iOS 18.1", time: "2026-11-18T07:00:00Z", simulator: simulator,
                              demo: demo, camera: camera, arkit: arkit ?? goodARKit(), lidar: lidar ?? goodLiDAR(), motion: motion ?? goodMotion(),
                              storage: PreflightStorageObservation(freeBytes: freeBytes, estimate: .fullKit()), recorder: recorder ?? goodRecorder())
    }

    func status(_ r: PreflightReport, _ c: PreflightCheck) -> PreflightStatus? { r.item(c)?.status }

    // MARK: the whole report

    func testAGoodPhoneRunPassesEverything() throws {
        let r = Preflight.evaluate(observations())
        XCTAssertEqual(r.items.map { $0.check }, PreflightCheck.allCases)
        for i in r.items { XCTAssertEqual(i.status, .pass, i.line) }
        XCTAssertEqual(r.overall, .pass)
        XCTAssertEqual(r.headline, "Ready: 6 pass")
        XCTAssertEqual(r.item(.arkit)?.detail, "Normal after 1.0 s, 60 frames a second.")
        XCTAssertEqual(r.item(.arkit)?.numbers["fps"], 60)
        XCTAssertEqual(r.item(.motion)?.detail, "100 samples a second, gravity 1.000 g.")
        XCTAssertTrue(r.text.hasPrefix("Pre-flight, build 1.0 (n8), iPhone16,1, iOS 18.1, 2026-11-18T07:00:00Z\nReady: 6 pass\nPASS  Camera permission: Allowed.\n"),
                      r.text)
        // the copy is words and numbers: JSON round-trips, with every observation in it
        let decoded = try JSONDecoder().decode(PreflightReport.self, from: Data(r.json().utf8))
        XCTAssertEqual(decoded, r)
        XCTAssertFalse(r.json().contains("/var/"))
    }

    func testTheSimulatorIsNotAvailableRatherThanFailed() {
        let sim = observations(camera: .noCamera, arkit: PreflightARKitObservation(supported: false, expectedFps: nil, window: 10),
                               lidar: PreflightLiDARObservation(supported: false),
                               motion: PreflightMotionObservation(available: false, requestedHz: 100, window: 10),
                               recorder: PreflightRecorderObservation(ran: false, requestedSeconds: 2, simulator: true), simulator: true)
        let r = Preflight.evaluate(sim)
        XCTAssertEqual(r.items.map { $0.status }, [.notAvailable, .notAvailable, .notAvailable, .notAvailable, .pass, .notAvailable])
        XCTAssertEqual(r.overall, .pass)
        XCTAssertEqual(r.headline, "Ready: 1 pass, 5 not available")
        // with the demo scene on, the recorder records its frames (H.264 is normal there)
        var demoRec = goodRecorder()
        demoRec.codec = "h264"; demoRec.simulator = true; demoRec.fps = 12.5; demoRec.framesWritten = 25; demoRec.frameLines = 25
        demoRec.readBackFrames = 25; demoRec.readBackSeconds = 2.0
        var withDemo = sim
        withDemo.demo = true
        withDemo.recorder = demoRec
        XCTAssertEqual(status(Preflight.evaluate(withDemo), .recorder), .pass)
        // the same missing pieces on a phone fail
        var phone = sim
        phone.simulator = false
        phone.recorder.simulator = false
        // the report's simulator flag reaches the recorder's item even when the recorder's own is not set
        var simOnlyTop = sim
        simOnlyTop.recorder.simulator = false
        XCTAssertEqual(status(Preflight.evaluate(simOnlyTop), .recorder), .notAvailable)
        let p = Preflight.evaluate(phone)
        XCTAssertEqual(p.items.map { $0.status }, [.fail, .fail, .notAvailable, .fail, .pass, .fail])
        XCTAssertEqual(p.overall, .fail)
        XCTAssertEqual(p.headline, "Not ready: 4 fail, 1 pass, 1 not available")
    }

    func testOverallIsTheWorstItem() {
        var o = observations()
        o.camera = .notDetermined
        let w = Preflight.evaluate(o)
        XCTAssertEqual(w.overall, .warn)
        XCTAssertEqual(w.headline, "Ready, with warnings: 1 warn, 5 pass")
        o.camera = .denied
        XCTAssertEqual(Preflight.evaluate(o).overall, .fail)
        XCTAssertTrue(Preflight.evaluate(o).text.contains("FAIL  Camera permission: Turned off."))
    }

    // MARK: each item's edges

    func testCamera() {
        XCTAssertEqual(Preflight.camera(.authorized, simulator: false).status, .pass)
        XCTAssertEqual(Preflight.camera(.notDetermined, simulator: false).status, .warn)
        XCTAssertEqual(Preflight.camera(.denied, simulator: false).status, .fail)
        XCTAssertEqual(Preflight.camera(.restricted, simulator: false).status, .fail)
        XCTAssertEqual(Preflight.camera(.noCamera, simulator: false).status, .fail)
        XCTAssertEqual(Preflight.camera(.noCamera, simulator: true).status, .notAvailable)
    }

    func testARKitFrameRate() {
        func at(_ fps: Double, expected: Double? = 60) -> PreflightStatus {
            var a = goodARKit()
            a.expectedFps = expected
            a.lastFrame = 0.5 + Double(a.frames - 1) / fps
            a.window = max(10, a.lastFrame!)
            return Preflight.arkit(a, simulator: false).status
        }
        XCTAssertEqual(at(60), .pass)
        XCTAssertEqual(at(54.1), .pass)       // 0.9 x 60 = 54
        XCTAssertEqual(at(53.9), .warn)
        XCTAssertEqual(at(30.1), .warn)       // 0.5 x 60 = 30
        XCTAssertEqual(at(29.9), .fail)
        XCTAssertEqual(at(29.9, expected: 30), .pass, "a 30 fps format at 30 fps")
        XCTAssertEqual(at(27.1, expected: nil), .pass, "unknown format: judged against 30")
        XCTAssertEqual(at(26.9, expected: nil), .warn)
    }

    func testARKitTracking() {
        var a = goodARKit()
        // normal after 5.0 s passes, after 5.1 s warns
        a.changes = [PreflightTrackingChange(t: 0.5, state: .limitedInitializing), PreflightTrackingChange(t: 5.5, state: .normal)]
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .pass)
        a.changes[1].t = 5.6
        let slow = Preflight.arkit(a, simulator: false)
        XCTAssertEqual(slow.status, .warn)
        XCTAssertEqual(slow.detail, "Took 5.1 s to become normal.")
        // never normal fails, naming the reason it was limited for longest
        a.changes = [PreflightTrackingChange(t: 0.5, state: .limitedInitializing), PreflightTrackingChange(t: 2, state: .limitedInsufficientFeatures)]
        let never = Preflight.arkit(a, simulator: false)
        XCTAssertEqual(never.status, .fail)
        XCTAssertTrue(never.detail.contains("never became normal (too few features"), never.detail)
        // normal, then limited: 81% normal passes, 79% warns (80% is the line)
        a.changes = [PreflightTrackingChange(t: 0.5, state: .normal), PreflightTrackingChange(t: 2.5, state: .limitedExcessiveMotion),
                     PreflightTrackingChange(t: 4.3, state: .normal)]
        XCTAssertEqual(a.normalShareAfterFirstNormal ?? 0, 1 - 1.8 / 9.5, accuracy: 1e-9)
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .pass)
        a.changes[2].t = 4.5
        let dropped = Preflight.arkit(a, simulator: false)
        XCTAssertEqual(dropped.status, .warn)
        XCTAssertEqual(dropped.detail, "Limited 21% of the time after that (moving too fast).")
        // an interruption warns; a session error or no frames fail; not supported on a phone fails
        a = goodARKit(); a.interruptions = 1
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .warn)
        a = goodARKit(); a.errorCode = 102
        XCTAssertEqual(Preflight.arkit(a, simulator: false).detail, "The AR session failed (error 102).")
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .fail)
        a = goodARKit(); a.frames = 0; a.firstFrame = nil; a.lastFrame = nil; a.changes = []
        XCTAssertEqual(Preflight.arkit(a, simulator: false).detail, "No camera frames in 10 s.")
        a.supported = false
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .fail)
        XCTAssertEqual(Preflight.arkit(a, simulator: true).status, .notAvailable)
    }

    func testLiDAR() {
        var l = goodLiDAR()
        let a = goodARKit()
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .pass)
        XCTAssertEqual(Preflight.lidar(l, arkit: a).detail, "Depth on 98% of the frames, 80% of it sure.")
        // depth on half the frames passes, fewer warns
        l.framesWithDepth = 271
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .pass)
        l.framesWithDepth = 270
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .warn)
        // confident share: median of the samples, 0.4 passes
        l = goodLiDAR()
        l.samples = [0.1, 0.4, 0.9].map { PreflightDepthSample(validShare: 1, confidentShare: $0, medianMeters: 1) }
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .pass)
        l.samples[1].confidentShare = 0.39
        let unsure = Preflight.lidar(l, arkit: a)
        XCTAssertEqual(unsure.status, .warn)
        XCTAssertTrue(unsure.detail.hasPrefix("Only 39% of the depth was sure"), unsure.detail)
        l.samples = []
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .warn)
        // no depth at all on a LiDAR phone fails; no LiDAR is not available, never a fail
        l = goodLiDAR(); l.framesWithDepth = 0
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .fail)
        l.frames = 0
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .fail)
        XCTAssertEqual(Preflight.lidar(PreflightLiDARObservation(supported: false, frames: 500), arkit: a).status, .notAvailable)
    }

    func testDepthSamplesFromAMap() {
        // 10 pixels: 2 without depth (0, NaN), 8 with; 6 of those medium or high confidence
        let depth: [Float] = [0, .nan, 1, 2, 3, 4, 5, 6, 7, 8]
        let conf: [UInt8] = [2, 2, 0, 0, 1, 1, 2, 2, 2, 2]
        let s = PreflightDepthSample(DepthMap(width: 5, height: 2, depth: depth, confidence: conf))
        XCTAssertEqual(s.validShare, 0.8, accuracy: 1e-12)
        XCTAssertEqual(s.confidentShare, 0.6, accuracy: 1e-12)
        XCTAssertEqual(s.medianMeters, 5)
        let empty = PreflightDepthSample(DepthMap(width: 1, height: 1, depth: [0], confidence: [2]))
        XCTAssertEqual(empty.validShare, 0)
        XCTAssertNil(empty.medianMeters)
    }

    func testMotion() {
        func rate(_ hz: Double) -> PreflightStatus {
            var m = goodMotion()
            m.lastSample = m.firstSample! + Double(m.samples - 1) / hz
            m.window = max(10, m.lastSample!)
            return Preflight.motion(m, simulator: false).status
        }
        XCTAssertEqual(rate(100), .pass)
        XCTAssertEqual(rate(90.1), .pass)
        XCTAssertEqual(rate(89.9), .warn)
        XCTAssertEqual(rate(50.1), .warn)
        XCTAssertEqual(rate(49.9), .fail)
        // gravity within 0.05 g passes, within 0.15 warns, else fails
        func gravity(_ g: Double) -> PreflightStatus {
            var m = goodMotion(); m.gravityMedian = g
            return Preflight.motion(m, simulator: false).status
        }
        XCTAssertEqual(gravity(1.049), .pass)
        XCTAssertEqual(gravity(0.951), .pass)
        XCTAssertEqual(gravity(1.051), .warn)
        XCTAssertEqual(gravity(0.851), .warn)
        XCTAssertEqual(gravity(1.151), .fail)
        XCTAssertEqual(gravity(0.0), .fail)
        var m = goodMotion(); m.gravityMedian = nil
        XCTAssertEqual(Preflight.motion(m, simulator: false).status, .fail)
        // time stamps that do not advance fail; a long gap, a late start or an early stop warn
        m = goodMotion(); m.nonAdvancing = 1
        XCTAssertEqual(Preflight.motion(m, simulator: false).status, .fail)
        XCTAssertEqual(Preflight.motion(m, simulator: false).detail, "Time stamps did not advance 1 time.")
        m = goodMotion(); m.maxGap = 0.25
        XCTAssertEqual(Preflight.motion(m, simulator: false).status, .pass)
        m.maxGap = 0.26
        XCTAssertEqual(Preflight.motion(m, simulator: false).detail, "A gap of 0.26 s.")
        m = goodMotion(); m.lastSample = 8.4
        XCTAssertEqual(Preflight.motion(m, simulator: false).status, .warn, "stopped 1.6 s early")
        m = goodMotion(); m.firstSample = 1.6
        XCTAssertEqual(Preflight.motion(m, simulator: false).status, .warn)
        // nothing at all
        m = PreflightMotionObservation(available: true, requestedHz: 100, window: 10)
        XCTAssertEqual(Preflight.motion(m, simulator: false).detail, "No motion data in 10 s.")
        XCTAssertEqual(Preflight.motion(PreflightMotionObservation(available: false, requestedHz: 100, window: 10), simulator: false).status, .fail)
        XCTAssertEqual(Preflight.motion(PreflightMotionObservation(available: false, requestedHz: 100, window: 10), simulator: true).status, .notAvailable)
    }

    func testStorage() {
        let e = PreflightStorageEstimate.fullKit()
        func free(_ b: Int64?) -> PreflightItem { Preflight.storage(PreflightStorageObservation(freeBytes: b, estimate: e)) }
        XCTAssertEqual(free(e.totalBytes).status, .pass)
        XCTAssertEqual(free(e.totalBytes - 1).status, .warn)
        XCTAssertEqual(free(e.minimumBytes).status, .warn)
        XCTAssertEqual(free(e.minimumBytes - 1).status, .fail)
        XCTAssertEqual(free(nil).status, .warn)
        XCTAssertTrue(free(e.minimumBytes - 1).detail.hasPrefix("Only "), free(0).detail)
        XCTAssertEqual(free(30_000_000_000).numbers["freeMB"], 30_000)
    }

    func testTheStorageEstimateFollowsTheKitsRecorder() throws {
        let e = PreflightStorageEstimate.fullKit()
        // the plan's video: 160 s kept at 30 fps and 24 s of drops at 60 fps, all optional shots included
        XCTAssertEqual(e.videoSeconds, 184, accuracy: 1e-9)
        XCTAssertEqual(PreflightStorageEstimate.videoSize(format: .init(width: 1920, height: 1440, fps: 60)).width, 1440)
        XCTAssertEqual(PreflightStorageEstimate.videoSize(format: .init(width: 1920, height: 1440, fps: 60)).height, 1080)
        XCTAssertEqual(PreflightStorageEstimate.videoSize(format: .init(width: 1280, height: 960, fps: 60)).height, 960)
        // KitRecorder.bitrate: 3.5 / 6 Mbit/s at 1440 x 1080, H.264 1.5 x, at least 0.3
        XCTAssertEqual(PreflightStorageEstimate.bitrate(width: 1440, height: 1080, fps: 30, hevc: true), 3_500_000)
        XCTAssertEqual(PreflightStorageEstimate.bitrate(width: 1440, height: 1080, fps: 60, hevc: true), 6_000_000)
        XCTAssertEqual(PreflightStorageEstimate.bitrate(width: 1440, height: 1080, fps: 60, hevc: false), 9_000_000)
        XCTAssertEqual(PreflightStorageEstimate.bitrate(width: 160, height: 120, fps: 30, hevc: true), 300_000)
        XCTAssertEqual(PreflightStorageEstimate.keepEvery(sourceFps: 60, highFrameRate: false), 2)
        XCTAssertEqual(PreflightStorageEstimate.keepEvery(sourceFps: 60, highFrameRate: true), 1)
        XCTAssertEqual(PreflightStorageEstimate.keepEvery(sourceFps: 12.5, highFrameRate: false), 1)
        let video: Int64 = 160 * 3_500_000 / 8 + 24 * 6_000_000 / 8
        XCTAssertEqual(e.videoBytes, video)
        // the whole: kit, a retry, its bundle and the margin; between a few hundred MB and a GB
        XCTAssertEqual(e.kitBytes, e.videoBytes + e.frameDataBytes + e.motionBytes + e.depthBytes + e.manifestBytes)
        XCTAssertEqual(e.totalBytes, e.kitBytes + e.retryBytes + e.bundleBytes + e.marginBytes)
        XCTAssertGreaterThan(e.totalBytes, 300_000_000)
        XCTAssertLessThan(e.totalBytes, 1_000_000_000)
        XCTAssertLessThan(e.minimumBytes, e.totalBytes)
        // H.264 and no LiDAR change it the expected way
        XCTAssertGreaterThan(PreflightStorageEstimate.fullKit(hevc: false).videoBytes, e.videoBytes)
        XCTAssertEqual(PreflightStorageEstimate.fullKit(hasLiDAR: false).depthBytes, 0)
        // the per-line allowances hold for fully filled lines
        let frame = KitFrame(index: 123_456, time: 123_456.123_456_789, pose: (0..<16).map { (i: Int) -> Float in Float(i) * -0.123_456_7 },
                             intrinsics: [1_234.567, 1_234.567, 719.123, 539.456], tracking: .limitedInsufficientFeatures,
                             exposure: 0.016_666_667, exposureOffset: -0.123_456, ambientLumens: 1_234.567, colorTemperature: 5_432.1,
                             luma: 123.456_789, blur: 12.345_678, depthFile: "d123456.bdp2",
                             live: KitLiveResult(state: .locked, tilt: 12.345_678, corners: [Vec2(1_234.567, 890.123), Vec2(1_234.567, 890.123),
                                                                                              Vec2(1_234.567, 890.123), Vec2(1_234.567, 890.123)],
                                                 ball: (center: Vec2(1_234.567, 890.123), radius: 45.678)))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertLessThan(try enc.encode(frame).count + 1, PreflightStorageEstimate.frameLineBytes)
        let motion = KitMotionSample(time: 123_456.123_456_789, gravity: Vec3(-0.123_456_789, 0.987_654_321, -0.012_345_678),
                                     userAcceleration: Vec3(-0.123_456_789, 0.987_654_321, -0.012_345_678),
                                     rotationRate: Vec3(-0.123_456_789, 0.987_654_321, -0.012_345_678),
                                     attitude: KitQuaternion(x: -0.123_456_789, y: 0.987_654_321, z: -0.012_345_678, w: 0.5))
        XCTAssertLessThan(try enc.encode(motion).count + 1, PreflightStorageEstimate.motionLineBytes)
    }

    func testRecorder() {
        let good = goodRecorder()
        XCTAssertEqual(Preflight.recorder(good, demo: false).status, .pass)
        XCTAssertEqual(Preflight.recorder(good, demo: false).detail, "Wrote and read back 60 frames (hevc 1440x1080, 2.00 s, 0.9 MB).")
        var r = good
        // read-back frames: one off passes, 90% warns, less fails
        r.readBackFrames = 59
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .pass)
        r.readBackFrames = 54
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        r.readBackFrames = 53
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .fail)
        r.readBackFrames = 0
        XCTAssertEqual(Preflight.recorder(r, demo: false).detail, "The clip was written but could not be read back.")
        r.readBackFrames = nil
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .fail)
        // duration: within 0.25 s plus two frames passes, within half warns, else fails
        r = good
        r.readBackSeconds = 2.0 + 0.25 + 2.0 / 30 - 0.001
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .pass)
        r.readBackSeconds = 2.0 + 0.25 + 2.0 / 30 + 0.001
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        r.readBackSeconds = 1.0
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        r.readBackSeconds = 0.99
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .fail)
        // smaller problems warn
        r = good; r.frameLines = 59
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        r = good; r.codec = "h264"
        XCTAssertEqual(Preflight.recorder(r, demo: false).detail, "HEVC could not be used: H.264 instead (bigger files).")
        r.simulator = true
        XCTAssertEqual(Preflight.recorder(r, demo: true).status, .pass)
        r = good; r.readBackWidth = 1920
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        r = good; r.cleanedUp = false
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .warn)
        // failures
        r = good; r.error = "the video encoder stopped (error -11800)"
        XCTAssertEqual(Preflight.recorder(r, demo: false).detail, "The recording failed: the video encoder stopped (error -11800).")
        r = good; r.fileBytes = 0
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .fail)
        r = PreflightRecorderObservation(ran: false, error: "no camera frames arrived", requestedSeconds: 2)
        XCTAssertEqual(Preflight.recorder(r, demo: false).detail, "Did not run: no camera frames arrived.")
        XCTAssertEqual(Preflight.recorder(r, demo: false).status, .fail)
    }

    // MARK: the meters

    func testTheARKitMeterCollectsStatesAndDepth() {
        let start = 1000.0
        let m = PreflightARKitMeter(start: start, supported: true, expectedFps: 60, depthSupported: true)
        var sampled = 0
        for i in 0..<600 {
            let t = start + 0.2 + Double(i) / 60
            let state: KitTracking = i < 60 ? .limitedInitializing : (i < 300 || i >= 330 ? .normal : .limitedExcessiveMotion)
            m.frame(time: t, tracking: state, hasDepth: i % 10 != 0)
            if m.wantsDepthSample(time: t) {
                m.depth(PreflightDepthSample(validShare: 1, confidentShare: 0.9, medianMeters: 1.2), time: t)
                sampled += 1
            }
        }
        m.interrupted()
        let (a, l) = m.observations(end: start + 10.2)
        XCTAssertEqual(a.frames, 600)
        XCTAssertEqual(a.window, 10.2, accuracy: 1e-9)
        XCTAssertEqual(a.firstFrame ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(a.fps ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(a.changes.map { $0.state }, [.limitedInitializing, .normal, .limitedExcessiveMotion, .normal])
        XCTAssertEqual(a.secondsToNormal ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(a.interruptions, 1)
        XCTAssertEqual(l.framesWithDepth, 540)
        XCTAssertEqual(sampled, 10)
        XCTAssertEqual(l.samples.count, 10)
        XCTAssertEqual(Preflight.arkit(a, simulator: false).status, .warn, "the interruption")
        XCTAssertEqual(Preflight.lidar(l, arkit: a).status, .pass)
    }

    func testTheMotionMeterCountsGapsAndStampsThatDoNotAdvance() {
        let m = PreflightMotionMeter(start: 50, available: true)
        for i in 0..<1000 where i < 400 || i >= 440 {
            m.sample(time: 50 + Double(i) / 100, gravity: Vec3(0, -0.6, -0.8))
        }
        m.sample(time: 50 + 9.99, gravity: Vec3(0, 0, -1)) // the same stamp again
        let o = m.observation(end: 60)
        XCTAssertEqual(o.samples, 961)
        XCTAssertEqual(o.nonAdvancing, 1)
        XCTAssertEqual(o.maxGap ?? 0, 0.41, accuracy: 1e-9)
        XCTAssertEqual(o.gravityMedian ?? 0, 1, accuracy: 1e-12)
        XCTAssertEqual(o.firstSample, 0)
        XCTAssertEqual(o.lastSample ?? 0, 9.99, accuracy: 1e-9)
        let item = Preflight.motion(o, simulator: false)
        XCTAssertEqual(item.status, .fail)
        XCTAssertEqual(item.detail, "Time stamps did not advance 1 time; a gap of 0.41 s.")
        // thread-safe: samples from many queues all count
        let n = PreflightMotionMeter(start: 0, available: true)
        DispatchQueue.concurrentPerform(iterations: 4) { q in
            for i in 0..<250 { n.sample(time: Double(q * 250 + i) / 100, gravity: Vec3(0, 0, -1)) }
        }
        XCTAssertEqual(n.observation(end: 10).samples, 1000)
    }
}
