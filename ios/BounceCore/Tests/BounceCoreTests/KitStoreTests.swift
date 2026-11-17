import XCTest
@testable import BounceCore

final class KitStoreTests: XCTestCase {
    var root: URL!
    let t0 = Date(timeIntervalSince1970: 1_794_929_400) // 2026-11-17 15:30:00 UTC
    let fm = FileManager.default

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("kitstore-\(UUID().uuidString)").appendingPathComponent("Kits")
    }
    override func tearDown() { try? fm.removeItem(at: root.deletingLastPathComponent()) }

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func newKit(plan: KitPlan = .standard, at date: Date? = nil) throws -> KitStore {
        try KitStore.create(root: root, plan: plan, device: KitManifestTests.device, measurements: KitMeasurements(settings: RecordingSettings()),
                            build: "1.0 (7)", date: date ?? t0)
    }

    func write(_ folder: URL, _ name: String, bytes n: Int, fill: UInt8 = 1) throws {
        let u = folder.appendingPathComponent(name)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: n).write(to: u)
    }

    func quality(_ verdict: KitVerdict, luma: Double = 120, ambient: Double? = nil) -> KitQualityReport {
        let sev: KitSeverity = verdict == .poor ? .poor : .fair
        let checks = verdict == .good ? [] : [KitQualityCheck(id: "x", passed: false, severity: sev, message: "Something.")]
        return KitQualityReport(checks: checks, frames: 150, medianLuma: luma, medianAmbient: ambient)
    }

    /// Record a video shot with fake files and commit it.
    @discardableResult
    func capture(_ store: KitStore, _ id: String, at s: Double, verdict: KitVerdict = .good, luma: Double = 120, ambient: Double? = nil,
                 videoBytes: Int = 1000, flat: KitTrueTilt? = nil) throws -> KitShotManifest {
        let folder = try store.beginShot(id)
        if flat == nil {
            try write(folder, KitClipFiles.video, bytes: videoBytes)
            try write(folder, KitClipFiles.frames, bytes: 200)
        }
        try write(folder, KitClipFiles.motion, bytes: 300)
        var m = try store.newShotManifest(id, startedAt: at(s), duration: 5)
        m.quality = quality(verdict, luma: luma, ambient: ambient)
        m.flat = flat
        if flat == nil { m.video = KitVideoInfo(codec: "hevc", width: 1280, height: 960, fps: 30, bitrate: 3_000_000, frameCount: 150, fileBytes: Int64(videoBytes)) }
        else { m.motionSamples = 1200 }
        return try store.commitShot(id, manifest: m, date: at(s + 6))
    }

    func twoReading(_ tilt: Double, bump: [Double] = [1.2, -0.5], readings: KitFlatReading? = nil) -> KitTrueTilt {
        KitTrueTilt(method: .twoReading, tiltDegrees: tilt, downhillAzimuthDegrees: 90, uncertaintyDegrees: 0.02, bumpDegrees: bump, turnDegrees: 181,
                    readingA: readings, readingB: readings, reasons: ["Two readings."])
    }

    func reading(spread: Double = 0.05, tilt: Double = 1) -> KitFlatReading {
        KitFlatReading(samples: 300, start: 0, end: 3, gravity: Vec3(0, 0, -1), spreadDegrees: spread, rmsDegrees: spread / 3,
                       attitude: .identity, maxRotationRate: 0.01, tiltDegrees: tilt, azimuthDegrees: 0)
    }

    /// kit.json cannot be written while this runs (a folder in its place); restored afterwards
    func withKitJSONBlocked(_ store: KitStore, _ body: () throws -> Void) throws {
        let data = try Data(contentsOf: store.manifestURL)
        try fm.removeItem(at: store.manifestURL)
        try fm.createDirectory(at: store.manifestURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: store.manifestURL); try? data.write(to: store.manifestURL) }
        try body()
    }

    func testCreateLoadAndList() throws {
        let store = try newKit()
        XCTAssertEqual(store.kitId, "slab-kit-20261117-153000")
        XCTAssertEqual(store.folder.lastPathComponent, store.kitId)
        XCTAssertTrue(fm.fileExists(atPath: store.manifestURL.path))
        XCTAssertEqual(store.manifest.shots.count, 28)
        XCTAssertTrue(store.manifest.shots.allSatisfy { $0.status == .pending && $0.attempts == 0 })
        XCTAssertEqual(store.manifest.shots.filter { $0.optional }.count, 3)
        XCTAssertEqual(store.manifest.createdAt, "2026-11-17T15:30:00Z")
        XCTAssertNil(store.manifest.timeScale)
        let p = store.progress
        XCTAssertEqual(p.nextShotId, "s01-measure"); XCTAssertEqual(p.nextIndex, 0)
        XCTAssertEqual(p.label, "Step 1 of 12")
        XCTAssertEqual(p.done, 0); XCTAssertEqual(p.total, 28); XCTAssertFalse(p.isComplete); XCTAssertEqual(p.fraction, 0)
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.manifest, store.manifest)
        XCTAssertEqual(loaded.plan, KitPlan.standard)
        // a second kit in the same second gets its own folder
        let again = try newKit()
        XCTAssertEqual(again.kitId, "slab-kit-20261117-153000-2")
        let later = try newKit(at: at(3600))
        XCTAssertEqual(KitStore.list(root: root).map { $0.kitId }, [later.kitId, again.kitId, store.kitId], "newest first")
        // junk in the root is ignored
        try fm.createDirectory(at: root.appendingPathComponent("not-a-kit"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: root.appendingPathComponent("not-a-kit/kit.json"))
        XCTAssertEqual(KitStore.list(root: root).count, 3)
        XCTAssertEqual(KitStore.list(root: root.appendingPathComponent("nowhere")), [])
        XCTAssertThrowsError(try KitStore.load(folder: root.appendingPathComponent("not-a-kit"))) {
            XCTAssertEqual($0 as? KitStoreError, .notAKit("not-a-kit"))
        }
    }

    func testMeasurementsStep() throws {
        let store = try newKit()
        var bad = store.manifest.measurements
        bad.ballDiameterMm = 500
        XCTAssertThrowsError(try store.commitMeasurements(bad, date: at(1))) {
            XCTAssertEqual($0 as? KitStoreError, .invalidMeasurements(["The ball's diameter must be between 5 and 120 mm."]))
        }
        XCTAssertEqual(store.record("s01-measure")?.status, .pending)
        let m = KitManifestTests.measurements
        try store.commitMeasurements(m, date: at(60))
        XCTAssertEqual(store.manifest.measurements, m)
        XCTAssertEqual(store.record("s01-measure")?.status, .captured)
        XCTAssertEqual(store.record("s01-measure")?.attempts, 1)
        XCTAssertNil(store.record("s01-measure")?.folder)
        XCTAssertEqual(store.manifest.updatedAt, "2026-11-17T15:31:00Z")
        XCTAssertEqual(store.progress.nextShotId, "s02-scan")
        XCTAssertEqual(store.progress.label, "Step 2 of 12")
        XCTAssertEqual(try KitStore.load(folder: store.folder).manifest.measurements, m)
        XCTAssertThrowsError(try store.beginShot("s01-measure"), "the form is not recorded")
        // shot manifests carry the measurements, and say they were entered
        XCTAssertEqual(try store.newShotManifest("s02-scan", startedAt: at(70), duration: 20).measurements, m)
        XCTAssertEqual(store.manifest.measurementsEnteredAt, "2026-11-17T15:31:00Z")
        XCTAssertEqual(try store.newShotManifest("s02-scan", startedAt: at(70), duration: 20).measurementsEntered, true)
    }

    func testMeasurementsNotEnteredAreMarkedSo() throws {
        // a new kit holds the app's settings: not measured for this kit, and no dish at all
        let store = try newKit()
        XCTAssertNil(store.manifest.measurementsEnteredAt)
        XCTAssertFalse(store.manifest.measurementsEntered)
        XCTAssertNil(store.manifest.measurements.dishInches)
        XCTAssertEqual(try store.newShotManifest("s02-scan", startedAt: at(1), duration: 20).measurementsEntered, false)
        let shot = try capture(store, "s02-scan", at: 2)
        XCTAssertEqual(shot.measurementsEntered, false)
        // skipping step 1 after entering them takes the owner's word back
        try store.commitMeasurements(KitManifestTests.measurements, date: at(10))
        XCTAssertTrue(store.manifest.measurementsEntered)
        try store.skipShot("s01-measure", date: at(20))
        XCTAssertFalse(store.manifest.measurementsEntered)
        XCTAssertFalse(try KitStore.load(folder: store.folder).manifest.measurementsEntered)
    }

    func testShotLifecycleAndRetry() throws {
        let store = try newKit()
        let m = try capture(store, "s02-scan", at: 100, videoBytes: 5000)
        var r = try XCTUnwrap(store.record("s02-scan"))
        XCTAssertEqual(r.status, .captured); XCTAssertEqual(r.attempts, 1); XCTAssertEqual(r.folder, "shots/s02-scan")
        XCTAssertEqual(r.verdict, .good); XCTAssertEqual(r.frames, 150); XCTAssertEqual(r.duration, 5)
        XCTAssertEqual(r.capturedAt, "2026-11-17T15:31:46Z")
        let shotJSON = store.shotFolder("s02-scan").appendingPathComponent("shot.json")
        XCTAssertEqual(r.bytes, 5000 + 200 + 300 + KitFiles.fileSize(shotJSON.path))
        XCTAssertEqual(m.attempt, 1); XCTAssertEqual(m.kitId, store.kitId); XCTAssertEqual(m.step, 2)
        XCTAssertEqual(try store.shotManifest("s02-scan"), m)
        XCTAssertFalse(fm.fileExists(atPath: store.attemptFolder("s02-scan").path))
        XCTAssertNil(m.positionId, "no slab position yet")
        // retry: the earlier capture stays until the new one is committed
        let attempt = try store.beginShot("s02-scan")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: attempt.path), [])
        XCTAssertTrue(fm.fileExists(atPath: store.shotFolder("s02-scan").appendingPathComponent(KitClipFiles.video).path))
        try write(attempt, "video.mp4", bytes: 7000)
        var m2 = try store.newShotManifest("s02-scan", startedAt: at(200), duration: 20)
        XCTAssertEqual(m2.attempt, 2)
        m2.quality = quality(.fair)
        try store.commitShot("s02-scan", manifest: m2, date: at(221))
        r = try XCTUnwrap(store.record("s02-scan"))
        XCTAssertEqual(r.attempts, 2); XCTAssertEqual(r.verdict, .fair)
        XCTAssertEqual(KitFiles.fileSize(store.shotFolder("s02-scan").appendingPathComponent("video.mp4").path), 7000)
        XCTAssertFalse(fm.fileExists(atPath: store.shotFolder("s02-scan").appendingPathComponent("frames.jsonl").path), "the old attempt's files are gone")
        XCTAssertEqual(try store.shotManifest("s02-scan")?.attempt, 2)
        XCTAssertNil(r.frames)
        // a discarded attempt leaves the capture alone
        _ = try store.beginShot("s02-scan")
        try store.discardAttempt("s02-scan")
        XCTAssertFalse(fm.fileExists(atPath: store.attemptFolder("s02-scan").path))
        XCTAssertEqual(store.record("s02-scan")?.status, .captured)
        XCTAssertThrowsError(try store.commitShot("s02-scan", manifest: m2, date: at(300))) {
            XCTAssertEqual($0 as? KitStoreError, .notStarted("s02-scan"))
        }
        XCTAssertThrowsError(try store.beginShot("s99-nope")) { XCTAssertEqual($0 as? KitStoreError, .unknownShot("s99-nope")) }
        XCTAssertNil(try store.shotManifest("s04-level-still"))
    }

    func testAppDiedMidShot() throws {
        let store = try newKit()
        try capture(store, "s02-scan", at: 100)
        // a retry of s02 and a first try of s04 are half-recorded when the app dies
        try write(try store.beginShot("s02-scan"), "video.mp4", bytes: 999)
        try write(try store.beginShot("s04-level-still"), "video.mp4", bytes: 999)
        // and a shot folder without shot.json (an interrupted move) is left behind
        try write(store.shotFolder("s04-level-arc"), "video.mp4", bytes: 10)
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.discardedOnLoad, ["s02-scan", "s04-level-arc", "s04-level-still"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.folder.appendingPathComponent("shots").path), ["s02-scan"])
        XCTAssertEqual(loaded.record("s02-scan")?.status, .captured, "the earlier capture survives")
        XCTAssertEqual(KitFiles.fileSize(loaded.shotFolder("s02-scan").appendingPathComponent("video.mp4").path), 1000)
        XCTAssertEqual(loaded.record("s04-level-still")?.status, .pending)
        XCTAssertEqual(loaded.progress.nextShotId, "s01-measure")
        // a captured shot whose files are gone is pending again (attempts kept)
        try fm.removeItem(at: loaded.shotFolder("s02-scan"))
        let again = try KitStore.load(folder: store.folder)
        XCTAssertEqual(again.record("s02-scan")?.status, .pending)
        XCTAssertEqual(again.record("s02-scan")?.attempts, 1)
        XCTAssertEqual(try KitStore.load(folder: store.folder).manifest, again.manifest, "loading is stable")
    }

    func testInterruptedCommitIsFinishedOnLoad() throws {
        let store = try newKit()
        try capture(store, "s02-scan", at: 100)
        // the app died between moving the old capture aside and moving the new one in
        let shots = store.folder.appendingPathComponent("shots")
        try fm.moveItem(at: shots.appendingPathComponent("s02-scan"), to: shots.appendingPathComponent("s02-scan.old"))
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.record("s02-scan")?.status, .captured)
        XCTAssertTrue(fm.fileExists(atPath: loaded.shotFolder("s02-scan").appendingPathComponent("shot.json").path))
        // or after the new one is in: the old copy is dropped
        try fm.copyItem(at: shots.appendingPathComponent("s02-scan"), to: shots.appendingPathComponent("s02-scan.old"))
        _ = try KitStore.load(folder: store.folder)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: shots.path), ["s02-scan"])
    }

    func testSlabPositions() throws {
        let store = try newKit()
        try capture(store, "s02-scan", at: 10)
        XCTAssertNil(store.positionId(forShot: "s04-level-still"))
        XCTAssertNil(store.knownBump)
        let flat = try capture(store, "s03-flat-level", at: 20, flat: twoReading(0.4))
        XCTAssertEqual(flat.positionId, "p1")
        XCTAssertEqual(flat.trueTilt?.tiltDegrees, 0.4)
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1"])
        XCTAssertEqual(store.manifest.positions[0].label, "level")
        XCTAssertEqual(store.manifest.positions[0].shotId, "s03-flat-level")
        XCTAssertEqual(store.record("s03-flat-level")?.frames, 1200)
        XCTAssertEqual(store.knownBump, KitBump(degrees: [1.2, -0.5], uncertaintyDegrees: 0.02))
        let still = try capture(store, "s04-level-still", at: 30, luma: 130)
        XCTAssertEqual(still.positionId, "p1")
        XCTAssertEqual(still.trueTilt?.tiltDegrees, 0.4, "the position's true tilt is copied into shot.json")
        XCTAssertEqual(store.qualityReference.levelStillMedianLuma, 130)
        // a skipped flat-phone shot still starts its position, without a true tilt
        try store.skipShot("s05-tilt1-flat", date: at(40))
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2"])
        XCTAssertNil(store.manifest.position("p2")?.groundTruth)
        let t1 = try capture(store, "s05-tilt1-still", at: 50)
        XCTAssertEqual(t1.positionId, "p2"); XCTAssertNil(t1.trueTilt)
        XCTAssertEqual(store.positionId(forShot: "s04-level-arc"), "p1", "earlier shots keep their position")
        // the second tilt has a single-reading result
        let single = KitTrueTilt(method: .bumpCorrected, tiltDegrees: 9.8, downhillAzimuthDegrees: 80, uncertaintyDegrees: 0.05, bumpDegrees: [1.2, -0.5])
        try capture(store, "s05-tilt2-flat", at: 60, flat: single)
        XCTAssertEqual(store.positionId(forShot: "s05-tilt2-arc"), "p3")
        XCTAssertEqual(store.knownBump?.degrees, [1.2, -0.5], "still the two-reading bump")
        // skipping the optional third tilt skips its group and starts no position: the slab stays at tilt 2
        try store.skipShot("s05-tilt3-flat", date: at(70))
        for id in ["s05-tilt3-flat", "s05-tilt3-still", "s05-tilt3-arc"] { XCTAssertEqual(store.record(id)?.status, .skipped, id) }
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3"])
        let dim = try capture(store, "s06-dim", at: 80, luma: 60)
        XCTAssertEqual(dim.positionId, "p3")
        XCTAssertEqual(dim.trueTilt?.tiltDegrees, 9.8)
        XCTAssertEqual(store.record("s06-dim")?.positionId, "p3")
        XCTAssertEqual(store.positionId(forShot: "s12-no-ball"), "p3")
        // going back to the first tilt's flat-phone shot later gives p2 its true tilt and updates the records
        try capture(store, "s05-tilt1-flat", at: 90, flat: twoReading(5.1))
        XCTAssertEqual(store.manifest.position("p2")?.groundTruth?.tiltDegrees, 5.1)
        XCTAssertEqual(store.record("s05-tilt1-still")?.positionId, "p2")
        XCTAssertEqual(store.knownBump?.degrees, [1.2, -0.5])
        // a failed flat-phone result starts the position without a true tilt
        try capture(store, "s03-flat-level", at: 95, flat: .failed("No reading"))
        XCTAssertNil(store.manifest.position("p1")?.groundTruth)
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3"], "positions stay in plan order")
        // positions survive a reload
        XCTAssertEqual(try KitStore.load(folder: store.folder).manifest.positions, store.manifest.positions)
    }

    func testSkippingAnOptionalTiltAfterCapturingIt() throws {
        let store = try newKit()
        try capture(store, "s05-tilt2-flat", at: 10, flat: twoReading(10))
        try capture(store, "s05-tilt3-flat", at: 20, flat: twoReading(15))
        try capture(store, "s05-tilt3-still", at: 30)
        XCTAssertEqual(store.positionId(forShot: "s06-dim"), "p4")
        try store.skipShot("s05-tilt3-flat", date: at(40))
        XCTAssertEqual(store.positionId(forShot: "s06-dim"), "p3")
        XCTAssertNil(store.manifest.position("p4"))
        XCTAssertEqual(store.record("s05-tilt3-still")?.status, .skipped)
        XCTAssertFalse(fm.fileExists(atPath: store.shotFolder("s05-tilt3-still").path), "a skipped shot's files are removed")
        XCTAssertNil(store.record("s05-tilt3-still")?.folder)
        // skipping the level-still shot drops the light reference
        try capture(store, "s04-level-still", at: 50, luma: 99, ambient: 950)
        XCTAssertEqual(store.qualityReference, KitQualityReference(levelStillMedianLuma: 99, levelStillMedianAmbient: 950))
        XCTAssertEqual(try KitStore.load(folder: store.folder).qualityReference.levelStillMedianAmbient, 950)
        try store.skipShot("s04-level-still", date: at(60))
        XCTAssertEqual(store.qualityReference, KitQualityReference())
    }

    func testEnteredHeights() throws {
        let store = try newKit()
        try capture(store, "s09-held-low", at: 10)
        try store.setHeight("s09-held-low", inches: 4.25, date: at(20))
        XCTAssertEqual(store.record("s09-held-low")?.enteredHeightInches, 4.25)
        XCTAssertEqual(try store.shotManifest("s09-held-low")?.enteredHeightInches, 4.25)
        try store.setHeight("s09-held-low", inches: nil, date: at(30))
        XCTAssertNil(store.record("s09-held-low")?.enteredHeightInches)
        XCTAssertNil(try store.shotManifest("s09-held-low")?.enteredHeightInches)
        for bad in [0.0, -1, 121, .nan, .infinity] {
            XCTAssertThrowsError(try store.setHeight("s09-held-low", inches: bad, date: at(40)), "\(bad)")
        }
        XCTAssertThrowsError(try store.setHeight("s04-level-still", inches: 3, date: at(40))) { XCTAssertTrue($0 is KitStoreError) }
        XCTAssertThrowsError(try store.setHeight("s09-held-mid", inches: 12, date: at(40))) {
            XCTAssertEqual($0 as? KitStoreError, .notCaptured("s09-held-mid"))
        }
        // a retry clears the height entered for the earlier attempt
        try store.setHeight("s09-held-low", inches: 4, date: at(50))
        try capture(store, "s09-held-low", at: 60)
        XCTAssertNil(store.record("s09-held-low")?.enteredHeightInches)
    }

    func testProgressFinishAndResume() throws {
        let store = try newKit(plan: KitPlan.standard)
        try store.commitMeasurements(KitManifestTests.measurements, date: at(1))
        try capture(store, "s02-scan", at: 2)
        try store.skipShot("s03-flat-level", date: at(3))
        var p = store.progress
        XCTAssertEqual(p.nextShotId, "s04-level-still"); XCTAssertEqual(p.label, "Step 4 of 12")
        XCTAssertEqual(p.done, 3); XCTAssertEqual(p.captured, 2); XCTAssertEqual(p.skipped, 1)
        for s in store.plan.shots where store.record(s.id)?.status == .pending { try store.skipShot(s.id, date: at(4)) }
        p = store.progress
        XCTAssertTrue(p.isComplete); XCTAssertEqual(p.label, "All done"); XCTAssertEqual(p.step, 12); XCTAssertEqual(p.fraction, 1)
        let other = try newKit(at: at(10))
        XCTAssertEqual(KitStore.resumable(root: root)?.kitId, other.kitId, "the newest unfinished kit")
        try other.finish(date: at(20))
        XCTAssertTrue(other.isFinished)
        XCTAssertEqual(other.manifest.finishedAt, "2026-11-17T15:30:20Z")
        XCTAssertEqual(KitStore.resumable(root: root)?.kitId, store.kitId)
        try store.finish(date: at(30))
        XCTAssertNil(KitStore.resumable(root: root))
        XCTAssertEqual(KitStore.list(root: root).first?.finished, true)
        // delete
        try other.delete()
        XCTAssertEqual(KitStore.list(root: root).map { $0.kitId }, [store.kitId])
    }

    func testResumeOffersOnlyKitsThisBuildCanOpen() throws {
        let older = try newKit(at: at(-3600))
        let newest = try newKit()
        // the newest kit is from a plan this build no longer knows
        var m = newest.manifest
        m.planId = "standard-v0"
        try KitJSON.encode(m).write(to: newest.manifestURL)
        XCTAssertThrowsError(try KitStore.load(folder: newest.folder))
        let list = KitStore.list(root: root)
        XCTAssertEqual(list.map { $0.kitId }, [newest.kitId, older.kitId], "still listed, so it can be deleted")
        XCTAssertEqual(list.map { $0.loadable }, [false, true])
        XCTAssertEqual(KitStore.resumable(root: root)?.kitId, older.kitId)
        // the app's start-up: resume what can be resumed
        let store = try KitStore.resumable(root: root).map { try KitStore.load(folder: $0.folder) }
        XCTAssertEqual(store?.kitId, older.kitId)
        try older.finish(date: at(1))
        XCTAssertNil(KitStore.resumable(root: root), "nothing to resume: the app starts a new kit")
        // a scaled plan with a bad time scale is not loadable either
        m.planId = "standard-v1"; m.timeScale = -1
        try KitJSON.encode(m).write(to: newest.manifestURL)
        XCTAssertEqual(KitStore.list(root: root).first?.loadable, false)
    }

    func testSummaryForTheEndScreen() throws {
        let store = try newKit()
        try store.commitMeasurements(KitManifestTests.measurements, date: at(1))
        try capture(store, "s02-scan", at: 2)
        try capture(store, "s03-flat-level", at: 3, flat: twoReading(0.42))
        try capture(store, "s04-level-still", at: 4, verdict: .fair)
        try capture(store, "s04-level-arc", at: 5, verdict: .poor)
        try store.skipShot("s05-tilt1-flat", date: at(6))
        try store.skipShot("s05-tilt3-flat", date: at(7))
        let s = store.summary()
        XCTAssertEqual(s.captured, 5); XCTAssertEqual(s.skipped, 4); XCTAssertEqual(s.pending, 19); XCTAssertEqual(s.total, 28)
        XCTAssertEqual(s.bytes, store.bytesOnDisk())
        XCTAssertGreaterThan(s.bytes, 3 * 1500)
        XCTAssertTrue(s.headline.hasPrefix("Captured 5 of 28 shots, skipped 4, 19 not done. 0.0"), s.headline)
        XCTAssertEqual(s.steps.count, 12)
        XCTAssertEqual(s.steps[0].line, "1 Measurements: done.")
        XCTAssertEqual(s.steps[3].line, "4 Slab only, level: all 2 captured (1 fair: Hold still; 1 poor: Walk around).")
        XCTAssertEqual(s.steps[3].fair, ["Hold still"]); XCTAssertEqual(s.steps[3].poor, ["Walk around"])
        XCTAssertEqual(s.steps[4].line, "5 Slab only, tilts: 4 skipped, 5 not done.")
        XCTAssertEqual(s.steps[4].skipped, ["Tilt 1: true tilt", "Tilt 3: true tilt", "Tilt 3: hold still", "Tilt 3: walk around"])
        XCTAssertEqual(s.positionLines, ["Level: 0.42° (two readings).", "Tilt 1: no true tilt (skipped)."])
        XCTAssertEqual(s.lines.count, 1 + 12 + 2)
        // a flat-phone shot that was taken but failed is not called skipped
        try capture(store, "s05-tilt2-flat", at: 8, verdict: .poor, flat: .failed("No reading: the phone did not lie still within 8 s."))
        XCTAssertEqual(store.summary().positionLines.last, "Tilt 2: no true tilt (the reading failed).")
        XCTAssertTrue(store.summary().steps[4].line.contains("1 poor: Tilt 2: true tilt"))
    }

    func testScaledPlanKitsRememberTheirScale() throws {
        let fast = KitPlan.standard.scaled(by: 0.25)
        let store = try newKit(plan: fast)
        XCTAssertEqual(store.manifest.timeScale, 0.25)
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.plan, fast)
        XCTAssertEqual(try loaded.newShotManifest("s10-drop1", startedAt: t0, duration: 1.5).releaseCue, 0.5)
    }

    func testUnsupportedKitsAreRefused() throws {
        let store = try newKit()
        var m = store.manifest
        m.version = 2
        try KitJSON.encode(m).write(to: store.manifestURL)
        XCTAssertThrowsError(try KitStore.load(folder: store.folder)) { XCTAssertEqual($0 as? KitStoreError, .unsupported("version 2")) }
        m.version = 1; m.planId = "future-v9"
        try KitJSON.encode(m).write(to: store.manifestURL)
        XCTAssertThrowsError(try KitStore.load(folder: store.folder)) { XCTAssertEqual($0 as? KitStoreError, .unsupported("plan future-v9")) }
        m.planId = "standard-v1"; m.format = "zip"
        try KitJSON.encode(m).write(to: store.manifestURL)
        XCTAssertThrowsError(try KitStore.load(folder: store.folder)) { XCTAssertEqual($0 as? KitStoreError, .unsupported("format zip")) }
        // a kit.json missing records for some plan shots gets them back as pending
        m.format = "bouncekit"
        m.shots.removeLast(2)
        try KitJSON.encode(m).write(to: store.manifestURL)
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.manifest.shots.count, 28)
        XCTAssertEqual(loaded.record("s12-no-ball")?.status, .pending)
    }

    func testABumpIsReusedOnlyFromSteadyFlatReadings() throws {
        let store = try newKit()
        // the phone moved during the readings (a spread of 0.5°): its bump is not trusted for later single readings
        try capture(store, "s03-flat-level", at: 10, verdict: .poor, flat: twoReading(0.4, readings: reading(spread: 0.5)))
        XCTAssertNotNil(store.manifest.position("p1")?.groundTruth)
        XCTAssertNil(store.knownBump)
        try capture(store, "s05-tilt1-flat", at: 20, flat: twoReading(5, bump: [0.8, 0.1], readings: reading()))
        XCTAssertEqual(store.knownBump?.degrees, [0.8, 0.1])
        // a failed result (the phone lay screen down) gives no true tilt and no bump
        try capture(store, "s05-tilt2-flat", at: 30, verdict: .poor, flat: .failed("The phone was not lying flat, screen up (it read 175°).",
                                                                                    readingA: reading(tilt: 175)))
        XCTAssertNil(store.manifest.position("p3")?.groundTruth)
        XCTAssertEqual(store.knownBump?.degrees, [0.8, 0.1])
    }

    func testACommitWhoseKitJSONCannotBeSavedIsUndone() throws {
        let store = try newKit()
        try capture(store, "s03-flat-level", at: 10, flat: twoReading(1.0))
        let attempt = try store.beginShot("s03-flat-level")
        try write(attempt, KitClipFiles.motion, bytes: 999)
        var m = try store.newShotManifest("s03-flat-level", startedAt: at(20), duration: 12)
        m.flat = twoReading(9.0)
        let before = store.manifest
        try withKitJSONBlocked(store) {
            XCTAssertThrowsError(try store.commitShot("s03-flat-level", manifest: m, date: at(30)))
        }
        XCTAssertEqual(store.manifest, before, "nothing changed in memory")
        XCTAssertEqual(try store.shotManifest("s03-flat-level")?.flat?.tiltDegrees, 1.0, "the earlier capture is back in place")
        XCTAssertEqual(KitFiles.fileSize(store.attemptFolder("s03-flat-level").appendingPathComponent(KitClipFiles.motion).path), 999,
                       "the new recording is kept, to commit again")
        XCTAssertFalse(fm.fileExists(atPath: store.oldFolder("s03-flat-level").path))
        XCTAssertEqual(try KitStore.load(folder: store.folder).manifest.position("p1")?.groundTruth?.tiltDegrees, 1.0)
        // the same commit goes through once kit.json can be written
        _ = try store.beginShot("s03-flat-level")
        try write(store.attemptFolder("s03-flat-level"), KitClipFiles.motion, bytes: 999)
        try store.commitShot("s03-flat-level", manifest: m, date: at(40))
        XCTAssertEqual(store.manifest.position("p1")?.groundTruth?.tiltDegrees, 9.0)
        XCTAssertEqual(store.record("s03-flat-level")?.attempts, 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.folder.appendingPathComponent("shots").path), ["s03-flat-level"])
    }

    func testACommitKilledBeforeKitJSONWasSavedIsRepairedOnLoad() throws {
        let store = try newKit()
        try capture(store, "s03-flat-level", at: 10, flat: twoReading(1.0))
        let before = try Data(contentsOf: store.manifestURL)
        let firstCapture = root.deletingLastPathComponent().appendingPathComponent("first-capture")
        try fm.copyItem(at: store.shotFolder("s03-flat-level"), to: firstCapture)
        try capture(store, "s03-flat-level", at: 20, verdict: .fair, flat: twoReading(9.0))
        // the disk as a kill between moving the retry into place and saving kit.json leaves it
        try before.write(to: store.manifestURL)
        try fm.copyItem(at: firstCapture, to: store.oldFolder("s03-flat-level"))
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.repairedOnLoad, ["s03-flat-level"])
        let r = try XCTUnwrap(loaded.record("s03-flat-level"))
        XCTAssertEqual(r.attempts, 2); XCTAssertEqual(r.verdict, .fair); XCTAssertEqual(r.status, .captured)
        XCTAssertEqual(r.bytes, KitFiles.size(of: loaded.shotFolder("s03-flat-level")))
        XCTAssertEqual(loaded.manifest.position("p1")?.groundTruth?.tiltDegrees, 9.0, "the true tilt the files hold")
        XCTAssertEqual(try loaded.newShotManifest("s04-level-still", startedAt: at(30), duration: 5).trueTilt?.tiltDegrees, 9.0)
        XCTAssertFalse(fm.fileExists(atPath: loaded.oldFolder("s03-flat-level").path))
        let again = try KitStore.load(folder: store.folder)
        XCTAssertEqual(again.repairedOnLoad, [])
        XCTAssertEqual(again.manifest, loaded.manifest, "loading is stable")
        // a first capture whose kit.json was never saved is taken in too, with its light reference
        let before2 = try Data(contentsOf: store.manifestURL)
        try capture(again, "s04-level-still", at: 40, luma: 140, ambient: 900)
        try before2.write(to: store.manifestURL)
        let third = try KitStore.load(folder: store.folder)
        XCTAssertEqual(third.repairedOnLoad, ["s04-level-still"])
        XCTAssertEqual(third.record("s04-level-still")?.status, .captured)
        XCTAssertEqual(third.record("s04-level-still")?.positionId, "p1")
        XCTAssertEqual(third.record("s04-level-still")?.capturedAt, "2026-11-17T15:30:40Z", "the recording's start")
        XCTAssertEqual(third.qualityReference, KitQualityReference(levelStillMedianLuma: 140, levelStillMedianAmbient: 900))
        XCTAssertEqual(third.progress.nextShotId, "s01-measure")
    }

    func testAnEnteredHeightOnlyInShotJSONIsRepairedOnLoad() throws {
        let store = try newKit()
        try capture(store, "s09-held-low", at: 10)
        // killed between writing shot.json and kit.json
        var m = try XCTUnwrap(try store.shotManifest("s09-held-low"))
        m.enteredHeightInches = 4.5
        try KitJSON.encode(m).write(to: store.shotFolder("s09-held-low").appendingPathComponent(KitClipFiles.shotManifest))
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(loaded.repairedOnLoad, ["s09-held-low"])
        XCTAssertEqual(loaded.record("s09-held-low")?.enteredHeightInches, 4.5)
        XCTAssertEqual(loaded.record("s09-held-low")?.attempts, 1)
    }

    func testSkipsThatFailOrAreKilledHalfWay() throws {
        let store = try newKit()
        try capture(store, "s02-scan", at: 10)
        // a skip whose kit.json cannot be saved puts the files back
        try withKitJSONBlocked(store) {
            XCTAssertThrowsError(try store.skipShot("s02-scan", date: at(20)))
        }
        XCTAssertEqual(store.record("s02-scan")?.status, .captured)
        XCTAssertTrue(fm.fileExists(atPath: store.shotFolder("s02-scan").appendingPathComponent(KitClipFiles.video).path))
        XCTAssertFalse(fm.fileExists(atPath: store.trashFolder("s02-scan").path))
        // killed after renaming the files to trash, before kit.json was saved: never bundled; kit.json does not know of
        // the skip, so it did not happen and the files go back
        try fm.moveItem(at: store.shotFolder("s02-scan"), to: store.trashFolder("s02-scan"))
        XCTAssertEqual(KitBundle.files(in: store.folder), ["kit.json"])
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertFalse(fm.fileExists(atPath: store.trashFolder("s02-scan").path))
        XCTAssertEqual(loaded.record("s02-scan")?.status, .captured)
        XCTAssertTrue(fm.fileExists(atPath: loaded.shotFolder("s02-scan").appendingPathComponent(KitClipFiles.video).path))
        // killed after saving, before deleting the trash: it goes
        try loaded.skipShot("s02-scan", date: at(40))
        try fm.createDirectory(at: loaded.trashFolder("s02-scan"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: loaded.trashFolder("s02-scan").appendingPathComponent(KitClipFiles.shotManifest))
        let again = try KitStore.load(folder: store.folder)
        XCTAssertEqual(again.record("s02-scan")?.status, .skipped)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.folder.appendingPathComponent("shots").path), [])
    }

    func testTheSlabMovedOnResume() throws {
        let store = try newKit()
        try capture(store, "s03-flat-level", at: 10, flat: twoReading(0.3))
        try capture(store, "s04-level-still", at: 20)
        try capture(store, "s04-level-arc", at: 30)
        try capture(store, "s05-tilt1-flat", at: 40, flat: twoReading(5.0))
        try capture(store, "s05-tilt1-still", at: 50)
        // the owner quits; the next day the app resumes in the middle of tilt 1
        let resumed = try KitStore.load(folder: store.folder)
        XCTAssertEqual(resumed.progress.nextShotId, "s01-measure")
        try resumed.skipShot("s01-measure", date: at(86_400))
        try resumed.skipShot("s02-scan", date: at(86_401))
        XCTAssertEqual(resumed.progress.nextShotId, "s05-tilt1-arc")
        XCTAssertEqual(resumed.positionInProgress?.id, "p2")
        XCTAssertEqual(resumed.positionInProgress?.label, "tilt 1")
        // "Has the slab moved?" Yes.
        let p = try XCTUnwrap(try resumed.restartPosition(forShot: "s05-tilt1-arc", date: at(86_410)))
        XCTAssertEqual(p.id, "p2#2"); XCTAssertEqual(p.generation, 2); XCTAssertEqual(p.planPositionId, "p2")
        XCTAssertNil(p.groundTruth)
        XCTAssertEqual(resumed.progress.nextShotId, "s05-tilt1-flat", "the true tilt is taken again first")
        XCTAssertNil(resumed.positionInProgress)
        XCTAssertEqual(resumed.record("s05-tilt1-flat")?.status, .pending)
        XCTAssertEqual(resumed.record("s05-tilt1-flat")?.attempts, 1)
        XCTAssertFalse(fm.fileExists(atPath: resumed.shotFolder("s05-tilt1-flat").path))
        XCTAssertEqual(resumed.manifest.positions.map { $0.id }, ["p1", "p2", "p2#2"])
        XCTAssertEqual(resumed.manifest.position("p2")?.groundTruth?.tiltDegrees, 5.0, "the first set-up keeps its true tilt")
        XCTAssertEqual(resumed.summary().positionLines.last, "Tilt 1 (set up again): no true tilt (not taken yet).")
        // asking again before anything is taken does not pile up set-ups
        try resumed.restartPosition(forShot: "s05-tilt1-flat", date: at(86_420))
        XCTAssertEqual(resumed.manifest.positions.map { $0.id }, ["p1", "p2", "p2#2"])
        // the new true tilt is for the shots taken from now on, not for the one taken before the slab moved
        let flat = try capture(resumed, "s05-tilt1-flat", at: 86_500, flat: twoReading(6.5))
        XCTAssertEqual(flat.positionId, "p2#2"); XCTAssertEqual(flat.attempt, 2)
        let arc = try capture(resumed, "s05-tilt1-arc", at: 86_600)
        XCTAssertEqual(arc.positionId, "p2#2"); XCTAssertEqual(arc.trueTilt?.tiltDegrees, 6.5)
        XCTAssertEqual(resumed.record("s05-tilt1-still")?.positionId, "p2")
        XCTAssertEqual(resumed.manifest.position(forShot: "s05-tilt1-still")?.groundTruth?.tiltDegrees, 5.0)
        XCTAssertEqual(resumed.manifest.position(forShot: "s05-tilt1-arc")?.groundTruth?.tiltDegrees, 6.5)
        XCTAssertEqual(resumed.positionId(forShot: "s05-tilt1-still"), "p2")
        XCTAssertEqual(resumed.positionId(forShot: "s06-dim"), "p2#2")
        XCTAssertEqual(try resumed.shotManifest("s05-tilt1-still")?.trueTilt?.tiltDegrees, 5.0, "kit.json and shot.json agree")
        // a retry of the earlier shot is taken at the new set-up
        try capture(resumed, "s05-tilt1-still", at: 86_700)
        XCTAssertEqual(resumed.record("s05-tilt1-still")?.positionId, "p2#2")
        XCTAssertEqual(resumed.summary().positionLines, ["Level: 0.30° (two readings).", "Tilt 1: 5.00° (two readings).",
                                                         "Tilt 1 (set up again): 6.50° (two readings)."])
        // a retry of the flat-phone shot right away (same set-up) replaces that set-up's true tilt
        try capture(resumed, "s05-tilt1-flat", at: 86_800, flat: twoReading(6.4))
        XCTAssertEqual(resumed.manifest.positions.map { $0.id }, ["p1", "p2", "p2#2"])
        XCTAssertEqual(resumed.manifest.position(forShot: "s05-tilt1-arc")?.groundTruth?.tiltDegrees, 6.4)
        XCTAssertEqual(try KitStore.load(folder: resumed.folder).manifest, resumed.manifest, "survives a reload")
        // a restart killed before kit.json was saved did not happen: the app asks again on the next resume
        try capture(resumed, "s05-tilt2-flat", at: 86_900, flat: twoReading(10))
        try capture(resumed, "s05-tilt2-still", at: 87_000)
        let beforeRestart = resumed.manifest
        try fm.moveItem(at: resumed.shotFolder("s05-tilt2-flat"), to: resumed.trashFolder("s05-tilt2-flat"))
        let killed = try KitStore.load(folder: resumed.folder)
        XCTAssertEqual(killed.manifest, beforeRestart)
        XCTAssertEqual(killed.positionInProgress?.id, "p3")
        XCTAssertEqual(try killed.shotManifest("s05-tilt2-flat")?.flat?.tiltDegrees, 10)
        // nothing to restart before the slab has a position; unknown shots throw
        let fresh = try newKit(at: at(200_000))
        XCTAssertNil(try fresh.restartPosition(forShot: "s02-scan", date: at(200_001)))
        XCTAssertNil(fresh.positionInProgress)
        XCTAssertThrowsError(try fresh.restartPosition(forShot: "s99", date: at(200_001)))
    }

    func testWritesLeaveNoTemporaryFiles() throws {
        let store = try newKit()
        try store.commitMeasurements(KitManifestTests.measurements, date: at(1))
        try capture(store, "s02-scan", at: 2)
        try store.finish(date: at(3))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.folder.path).sorted(), ["kit.json", "shots"])
        XCTAssertEqual(KitFiles.regularFiles(in: store.folder), ["kit.json", "shots/s02-scan/frames.jsonl", "shots/s02-scan/motion.jsonl",
                                                                 "shots/s02-scan/shot.json", "shots/s02-scan/video.mp4"])
        // a failed write throws instead of trapping: make kit.json a folder
        let blocked = try newKit(at: at(100))
        try fm.removeItem(at: blocked.manifestURL)
        try fm.createDirectory(at: blocked.manifestURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try blocked.finish(date: at(101)))
    }
}
