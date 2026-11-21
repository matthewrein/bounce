import XCTest
@testable import BounceCore

/// The hand-off (CaptureKit.md, "When the kit is uploaded"): the phone's video rule and the bundle's size budget, the
/// arrival check of a kit unzipped from its parts, and the phone-sized synthetic kit of the dry run.
final class KitHandoffTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("kit-handoff-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { if let r = root { try? fm.removeItem(at: r) } }

    /// A file of the app (ios/BounceApp), read as text: the app cannot be compiled here.
    static func appSource(_ name: String) -> String? {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u = u.deletingLastPathComponent() }   // .../ios
        return try? String(contentsOf: u.appendingPathComponent("BounceApp").appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: the phone's video and the bundle's budget

    /// The text of BounceCore's source files that declare `type` (KitPhoneVideo.swift left out), or nil if none does.
    static func coreSource(declaring type: String) -> String? {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").appendingPathComponent("BounceCore")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let texts = files.filter { $0.hasSuffix(".swift") && $0 != "KitPhoneVideo.swift" }.sorted()
            .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
            .filter { t in ["struct", "enum", "class", "extension"].contains { t.contains("\($0) \(type)") } }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    func testPhoneVideoRuleIsTheApps() throws {
        guard let src = KitHandoffTests.appSource("KitRecorder.swift") else { throw XCTSkip("the app's source is not next to the package") }
        for needle in ["static let maxVideoWidth = \(KitPhoneVideo.maxWidth)",
                       "static let depthInterval = \(KitPhoneVideo.depthInterval)",
                       "let w = min(KitRecorder.maxVideoWidth, full.width) / 2 * 2",
                       "let h = Int((Double(full.height) * Double(w) / Double(full.width)).rounded()) / 2 * 2",
                       "AVVideoMaxKeyFrameIntervalKey: max(1, Int(keptFps.rounded()))"] {
            XCTAssertTrue(src.contains(needle), "KitRecorder.swift no longer says \"\(needle)\": make KitPhoneVideo match it")
        }
        // the bitrate and frame-keeping rules: in KitRecorder, or in the BounceCore type it calls for them (the
        // pre-flight's storage estimate holds the same rule)
        var rules = src
        for type in ["PreflightStorageEstimate"] where src.contains(type + ".bitrate(") || src.contains(type + ".keepEvery(") {
            let core = try XCTUnwrap(KitHandoffTests.coreSource(declaring: type), "KitRecorder calls \(type), which BounceCore does not declare")
            rules += "\n" + core
        }
        for needle in ["let base = fps > 45 ? 6_000_000.0 : 3_500_000.0",
                       "let pixels = Double(width * height) / Double(1440 * 1080)",
                       "return Int(max(300_000, base * pixels * (hevc ? 1 : 1.5)))",
                       "highFrameRate ? 1 : max(1, Int((sourceFps / 30).rounded()))"] {
            XCTAssertTrue(rules.contains(needle), "KitRecorder.swift (or the rule it calls) no longer says \"\(needle)\": make KitPhoneVideo match it")
        }
        XCTAssertTrue(KitPhoneVideo.videoSize(cameraWidth: 1920, cameraHeight: 1440) == (1440, 1080))
        XCTAssertTrue(KitPhoneVideo.videoSize(cameraWidth: 1280, cameraHeight: 960) == (1280, 960))
        XCTAssertTrue(KitPhoneVideo.videoSize(cameraWidth: 1920, cameraHeight: 1080) == (1440, 810))
        XCTAssertEqual(KitPhoneVideo.bitrate(width: 1440, height: 1080, fps: 30, hevc: true), 3_500_000)
        XCTAssertEqual(KitPhoneVideo.bitrate(width: 1440, height: 1080, fps: 60, hevc: true), 6_000_000)
        XCTAssertEqual(KitPhoneVideo.bitrate(width: 1440, height: 1080, fps: 30, hevc: false), 5_250_000)
        XCTAssertEqual(KitPhoneVideo.bitrate(width: 1440, height: 1080, fps: 60, hevc: false), 9_000_000)
        XCTAssertEqual(KitPhoneVideo.bitrate(width: 160, height: 120, fps: 30, hevc: true), 300_000)
    }

    /// The worst case of CaptureKit.md, "Bundle": a real kit's largest single file is the room scan's video (20 s,
    /// H.264 where HEVC is unavailable: 5.25 Mbit/s, about 13.3 MB). It fits in a part with room to spare even if the
    /// encoder overshoots its average bitrate by half, so no file of a real kit needs an oversized part of its own (which
    /// Safari could not upload); the frame lists, depth files and motion samples are far smaller.
    func testNoFileOfARealKitNeedsAPartOfItsOwn() throws {
        let kitId = "slab-kit-20261117-153000"
        let capacity = KitBundle.defaultLimit - KitZipWriter.endRecordBytes
            - KitZipWriter.entryCost(name: kitId + "/kit.json", payloadBytes: 100_000)
        for hevc in [true, false] {
            let w = try XCTUnwrap(KitPhoneVideo.largestVideoBytes(plan: .standard, hevc: hevc, overshoot: 1.5))
            XCTAssertEqual(w.shotId, "s02-scan")
            let cost = KitZipWriter.entryCost(name: kitId + "/shots/s02-scan/video.mp4", payloadBytes: w.bytes)
            XCTAssertLessThan(cost, capacity, "\(hevc ? "HEVC" : "H.264"): the largest video, 1.5 times over its bitrate, does not fit in a part")
        }
        let h264 = try XCTUnwrap(KitPhoneVideo.largestVideoBytes(plan: .standard, hevc: false))
        XCTAssertGreaterThan(Double(capacity) / Double(h264.bytes), 1.75, "the margin for the encoder's overshoot")
        // the third tilt's shots are shorter than the scan
        XCTAssertLessThanOrEqual(KitPlan.standardV1.optionalShots.compactMap { $0.kind.videoSeconds }.max() ?? 0, 20)

        // the longest frames.jsonl: every field filled in, at the longest shot's frame count, stored as is
        let corners = (0..<4).map { Vec2(1439.123456 - Double($0), 1079.123456 - Double($0)) }
        let line = KitFrame(index: 999_999, time: 123_456.123456, pose: (0..<16).map { _ in Float(-0.123456789) },
                            intrinsics: [1234.5678, 1234.5678, 719.12345, 539.12345], tracking: .limitedInsufficientFeatures,
                            exposure: 0.0166666, exposureOffset: -0.123456, ambientLumens: 1234.5678, colorTemperature: 4567.891,
                            luma: 123.456789, blur: 12.345678, depthFile: KitDepth.fileName(frame: 999_999),
                            live: KitLiveResult(state: .confirming, tilt: 12.3456789, corners: corners, ball: (Vec2(1234.5678, 987.6543), 98.7654)))
        let lineBytes = Int64(try KitJSON.encode(line).count + 1)
        let frames = KitPlan.standardV1.shots.compactMap { s in s.kind.videoSeconds.map { $0 * KitPhoneVideo.fps(s) } }.max() ?? 0
        XCTAssertLessThan(lineBytes * Int64(frames.rounded(.up)), capacity / 10)
        // depth files are small and many; the motion of a flat-phone shot left running for ten minutes at 100 Hz
        XCTAssertLessThan(KitPhoneVideo.depthFileBytes, capacity / 100)
        let sample = KitMotionSample(time: 123_456.12345, gravity: Vec3(-0.123456, -0.123456, -0.987654),
                                     userAcceleration: Vec3(-0.123456, -0.123456, -0.123456), rotationRate: Vec3(-1.234567, -1.234567, -1.234567),
                                     attitude: KitQuaternion(x: -0.1234567, y: -0.1234567, z: -0.1234567, w: 0.9876543))
        XCTAssertLessThan(Int64(try KitJSON.encode(sample).count + 1) * 100 * 600, capacity)
    }

    // MARK: the arrival check

    func tinyKit() throws -> KitSyntheticKit {
        var o = KitSyntheticKit.Options()
        o.framesPerShot = 3
        o.shots = ["s01-measure", "s02-scan", "s03-flat-level", "s04-level-still", "s09-held-low", "s09-held-mid"]
        o.ballWidth = nil; o.ballHeight = nil
        return try KitSyntheticKit.build(root: root, options: o)
    }

    func testArrivalCheckFindsWhatIsMissing() throws {
        let kit = try tinyKit()
        let r = try XCTUnwrap(KitArrival.check(kitFolder: kit.folder))
        XCTAssertTrue(r.complete, "\(r.problems)")
        XCTAssertEqual(r.kitId, kit.kitId)
        XCTAssertTrue(r.finished)
        XCTAssertEqual(Set(r.captured), ["s01-measure", "s02-scan", "s03-flat-level", "s04-level-still", "s09-held-low", "s09-held-mid"])
        XCTAssertEqual(r.captured.count + r.skipped.count, KitPlan.standardV1.shotCount)
        XCTAssertTrue(r.pending.isEmpty)
        XCTAssertTrue(r.skipped.contains("s05-tilt3-flat"))
        XCTAssertEqual(r.videoFiles, 0, "the in-memory synthetic kit renders its frames when scored")
        XCTAssertTrue(r.lines.contains { $0.hasPrefix("shots: 6 of 28 captured, 22 skipped") }, "\(r.lines)")
        XCTAssertTrue(r.lines.last?.contains("every captured shot has all its files") ?? false)
        XCTAssertFalse(r.lines.joined().contains(root.path), "no paths")

        let shots = kit.folder.appendingPathComponent(KitStore.shotsFolder)
        // a frame list one line short
        let frames = shots.appendingPathComponent("s04-level-still").appendingPathComponent(KitClipFiles.frames)
        let text = try String(contentsOf: frames, encoding: .utf8)
        try (text.split(separator: "\n").dropLast().joined(separator: "\n") + "\n").write(to: frames, atomically: true, encoding: .utf8)
        // the part holding a whole shot did not arrive
        try fm.removeItem(at: shots.appendingPathComponent("s09-held-mid"))
        // motion samples cut short
        let motion = shots.appendingPathComponent("s03-flat-level").appendingPathComponent(KitClipFiles.motion)
        let mtext = try String(contentsOf: motion, encoding: .utf8).split(separator: "\n")
        try (mtext.prefix(mtext.count / 2).joined(separator: "\n") + "\n").write(to: motion, atomically: true, encoding: .utf8)
        let r2 = try XCTUnwrap(KitArrival.check(kitFolder: kit.folder))
        XCTAssertFalse(r2.complete)
        XCTAssertEqual(r2.problems.count, 3, "\(r2.problems)")
        XCTAssertTrue(r2.problems.contains { $0.hasPrefix("s04-level-still: frames.jsonl has 2 lines, the video 3 frames") }, "\(r2.problems)")
        XCTAssertTrue(r2.problems.contains { $0.hasPrefix("s09-held-mid: shot.json is missing") }, "\(r2.problems)")
        XCTAssertTrue(r2.problems.contains { $0.hasPrefix("s03-flat-level: motion.jsonl has") }, "\(r2.problems)")
        XCTAssertTrue(r2.lines.contains { $0.hasPrefix("contents: 3 problems") })

        // shot.json from another attempt than kit.json's (parts from two builds of the bundle)
        let sj = shots.appendingPathComponent("s02-scan").appendingPathComponent(KitClipFiles.shotManifest)
        var sm = try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: sj))
        sm.attempt += 1
        try KitJSON.encode(sm).write(to: sj)
        XCTAssertTrue(KitArrival.check(kitFolder: kit.folder)?.problems.contains { $0.hasPrefix("s02-scan: shot.json is attempt 2 but kit.json says 1") } ?? false)

        // not a kit
        XCTAssertNil(KitArrival.check(kitFolder: root))
        XCTAssertEqual(KitArrival.readProblem(kitFolder: root), "there is no kit.json")
    }

    /// kit.json is the authority, not this checkout's plan: a phone running another build (a shot added to the plan or
    /// taken out) still checks out, with the differences noted; a kit.json this checkout cannot decode says where.
    func testArrivalCheckFollowsKitJsonNotThisCheckoutsPlan() throws {
        let kit = try tinyKit()
        let manifestURL = kit.folder.appendingPathComponent(KitStore.manifestFile)
        var m = try KitJSON.decode(KitManifest.self, from: Data(contentsOf: manifestURL))
        // the phone's plan had no s05-tilt3-flat, and had a shot this checkout does not know (a copy of s04-level-still)
        m.shots.removeAll { $0.id == "s05-tilt3-flat" }
        var extra = try XCTUnwrap(m.record("s04-level-still"))
        extra.id = "s99-new-shot"; extra.folder = KitStore.shotsFolder + "/s99-new-shot"
        m.shots.append(extra)
        try KitJSON.encode(m).write(to: manifestURL)
        let shots = kit.folder.appendingPathComponent(KitStore.shotsFolder)
        try fm.copyItem(at: shots.appendingPathComponent("s04-level-still"), to: shots.appendingPathComponent("s99-new-shot"))
        let sj = shots.appendingPathComponent("s99-new-shot").appendingPathComponent(KitClipFiles.shotManifest)
        var sm = try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: sj))
        sm.shotId = "s99-new-shot"
        try KitJSON.encode(sm).write(to: sj)

        let r = try XCTUnwrap(KitArrival.check(kitFolder: kit.folder))
        XCTAssertTrue(r.complete, "\(r.problems)")
        XCTAssertTrue(r.captured.contains("s99-new-shot"))
        XCTAssertFalse(r.skipped.contains("s05-tilt3-flat"))
        XCTAssertEqual(r.captured.count + r.skipped.count, KitPlan.standardV1.shotCount)
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("in this checkout's plan but not in kit.json") && $0.contains("s05-tilt3-flat") }, "\(r.notes)")
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("in kit.json but not in this checkout's plan") && $0.contains("s99-new-shot") }, "\(r.notes)")
        XCTAssertTrue(r.lines.contains { $0.hasPrefix("note: in kit.json but not") })
        // the unknown shot is checked from its shot.json like any video shot
        try fm.removeItem(at: shots.appendingPathComponent("s99-new-shot").appendingPathComponent(KitClipFiles.frames))
        let r2 = try XCTUnwrap(KitArrival.check(kitFolder: kit.folder))
        XCTAssertEqual(r2.problems, ["s99-new-shot: frames.jsonl is missing"])

        // a kit.json from a newer build this checkout cannot decode: no report, and readProblem says where it stopped
        XCTAssertNil(KitArrival.readProblem(kitFolder: kit.folder))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var records = try XCTUnwrap(json["shots"] as? [[String: Any]])
        records[2]["status"] = "deferred"
        json["shots"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        XCTAssertNil(KitArrival.check(kitFolder: kit.folder))
        let why = try XCTUnwrap(KitArrival.readProblem(kitFolder: kit.folder))
        XCTAssertTrue(why.hasPrefix("this checkout cannot read kit.json at shots[2].status"), why)
        XCTAssertFalse(why.contains(root.path), "no paths")
        // not JSON at all
        try Data("{".utf8).write(to: manifestURL)
        XCTAssertTrue(KitArrival.readProblem(kitFolder: kit.folder)?.hasPrefix("this checkout cannot read kit.json") ?? false)
    }

    // MARK: the phone-sized synthetic kit (needs ffmpeg)

    func testPhoneKitIsWrittenAsThePhoneWritesIt() throws {
        try XCTSkipUnless(KitFFmpeg.isAvailable, "ffmpeg and ffprobe are not installed")
        var o = KitSyntheticPhoneKit.Options()
        o.timeScale = 0.05
        o.cameraWidth = 320; o.cameraHeight = 240   // small, to stay quick; the dry run writes 1440x1080
        o.renderFps = 2
        let kept: Set<String> = ["s01-measure", "s02-scan", "s03-flat-level", "s04-level-still", "s09-held-low", "s10-drop1"]
        o.skip = Set(KitPlan.standardV1.shots.map { $0.id }).subtracting(kept)
        o.retry = ["s04-level-still"]
        o.noHeight = []
        let kit = try KitSyntheticPhoneKit.build(root: root.appendingPathComponent("AppSupport"), options: o)
        let m = kit.store.manifest
        XCTAssertEqual(kit.kitId, "slab-kit-20261119-083000")
        XCTAssertEqual(m.timeScale, 0.05)
        XCTAssertTrue(m.isFinished)
        XCTAssertTrue(m.measurementsEntered)
        XCTAssertTrue(m.device.hasLiDAR)
        XCTAssertEqual(m.record("s04-level-still")?.attempts, 2, "the retried shot")
        XCTAssertNotNil(m.record("s09-held-low")?.enteredHeightInches)
        XCTAssertEqual(m.position("p1")?.groundTruth?.tiltDegrees ?? -1, 0, accuracy: 0.1, "the flat-phone shot, sped up with the plan")

        let r = try XCTUnwrap(KitArrival.check(kitFolder: kit.folder))
        XCTAssertTrue(r.complete, "\(r.problems)")
        XCTAssertEqual(Set(r.captured), kept)
        XCTAssertEqual(r.videoFiles, 4)

        // the scan: HEVC at the phone's bitrate for its size, 30 fps, tagged full range, a frame list line per frame
        let scan = try XCTUnwrap(try kit.store.shotManifest("s02-scan"))
        let v = try XCTUnwrap(scan.video)
        let frames = Int((20 * 0.05 * 30 - 0.25).rounded(.up))
        XCTAssertEqual(v.codec, "hevc"); XCTAssertEqual(v.width, 320); XCTAssertEqual(v.height, 240); XCTAssertEqual(v.fps, 30)
        XCTAssertEqual(v.bitrate, KitPhoneVideo.bitrate(width: 320, height: 240, fps: 30, hevc: true))
        XCTAssertEqual(v.frameCount, frames)
        let folder = kit.store.shotFolder("s02-scan")
        let url = folder.appendingPathComponent(KitClipFiles.video)
        XCTAssertEqual(v.fileBytes, KitFiles.fileSize(url.path))
        let probe = try KitVideoDecoder.probe(url)
        XCTAssertEqual(probe.codec, "hevc")
        XCTAssertEqual(probe.frames, frames)
        XCTAssertTrue(probe.isFullRange)
        let lines = try KitJSONL.read(KitFrame.self, from: folder.appendingPathComponent(KitClipFiles.frames))
        XCTAssertEqual(lines.count, frames)
        XCTAssertEqual(lines.map { $0.index }, Array(0..<frames))
        XCTAssertEqual(lines.first?.tracking, .limitedInitializing, "ARKit settles during the scan's first second")
        XCTAssertTrue(lines.allSatisfy { $0.luma != nil && $0.exposure != nil && $0.live != nil && $0.pose.count == 16 })
        XCTAssertEqual(lines.last?.live?.state, .locked)
        // LiDAR depth about once a second
        let depth = lines.compactMap { $0.depthFile }
        XCTAssertEqual(depth.count, 1)
        XCTAssertEqual(scan.depthFrames, 1)
        let d = try KitDepth(data: Data(contentsOf: KitClipFiles.depthURL(shotFolder: folder, file: depth[0])))
        XCTAssertEqual(d.width, KitPhoneVideo.depthWidth); XCTAssertEqual(d.height, KitPhoneVideo.depthHeight)
        XCTAssertGreaterThan(d.millimetres.filter { $0 > 0 }.count, d.millimetres.count / 2)
        XCTAssertGreaterThanOrEqual(scan.motionSamples ?? 0, 100)

        // the drop: every frame of ARKit's 60, the beep's time
        let drop = try XCTUnwrap(try kit.store.shotManifest("s10-drop1"))
        XCTAssertEqual(drop.video?.fps, 60)
        XCTAssertEqual(drop.video?.frameCount, Int((6 * 0.05 * 60 - 0.25).rounded(.up)))
        XCTAssertNotNil(drop.releaseTime)
        XCTAssertEqual(drop.motionSessionId, scan.motionSessionId)

        // the bundle, as the app makes it; unzipping every part rebuilds the kit
        let outbox = root.appendingPathComponent("Documents/Kits").appendingPathComponent(kit.kitId)
        // parts just large enough for the largest file stored as is, so this small kit too comes in several
        let files = KitBundle.files(in: kit.folder)
        let largest = files.map { KitFiles.fileSize(kit.folder.appendingPathComponent($0).path) }.max() ?? 0
        let limit = largest + KitFiles.fileSize(kit.folder.appendingPathComponent(KitStore.manifestFile).path) + 8_192
        let b = try KitBundle.build(kitFolder: kit.folder, outbox: outbox, limit: limit, deflate: KitTestDeflate.fixedHuffman)
        XCTAssertGreaterThan(b.parts.count, 1)
        XCTAssertTrue(b.oversized.isEmpty)
        XCTAssertTrue(b.parts.allSatisfy { $0.bytes <= limit })
        if let unzip = KitBundleTests.unzip {
            let out = root.appendingPathComponent("rebuilt")
            for p in b.parts {
                let t = Process(); t.executableURL = URL(fileURLWithPath: unzip)
                t.arguments = ["-o", "-qq", p.url.path, "-d", out.path]
                try t.run(); t.waitUntilExit()
                XCTAssertEqual(t.terminationStatus, 0)
            }
            let rebuilt = out.appendingPathComponent(kit.kitId)
            XCTAssertEqual(KitFiles.regularFiles(in: rebuilt), KitBundle.files(in: kit.folder))
            for f in KitBundle.files(in: kit.folder) {
                XCTAssertTrue(fm.contentsEqual(atPath: rebuilt.appendingPathComponent(f).path, andPath: kit.folder.appendingPathComponent(f).path), f)
            }
            XCTAssertTrue(KitArrival.check(kitFolder: rebuilt)?.complete ?? false)
            // a video cut short and a depth file lost on the way are caught
            let vh = try FileHandle(forWritingTo: rebuilt.appendingPathComponent("shots/s02-scan/video.mp4"))
            try vh.truncate(atOffset: 1000); try vh.close()
            try fm.removeItem(at: KitClipFiles.depthURL(shotFolder: rebuilt.appendingPathComponent("shots/s02-scan"), file: depth[0]))
            let bad = try XCTUnwrap(KitArrival.check(kitFolder: rebuilt))
            XCTAssertTrue(bad.problems.contains { $0.hasPrefix("s02-scan: video.mp4 has 1000 bytes") }, "\(bad.problems)")
            XCTAssertTrue(bad.problems.contains { $0.hasPrefix("s02-scan: 1 of its 1 depth files are missing") }, "\(bad.problems)")
        }
    }
}
