import XCTest
@testable import BounceCore

/// A failed or interrupted kit step never loses earlier steps. The app is "killed" just before every file operation
/// of a step (a copy of the kit folder taken there is exactly what the disk holds after such a kill), each copy is
/// opened again, and the kit must be either as it was before the step or as it is after it, with nothing left over.
/// A full disk is a file operation that throws; a failed bundle leaves the kit as it was.
final class KitStepSafetyTests: XCTestCase {
    var tmp: URL!
    var root: URL!
    let t0 = Date(timeIntervalSince1970: 1_794_929_400) // 2026-11-17 15:30:00 UTC
    let fm = FileManager.default

    override func setUp() {
        tmp = fm.temporaryDirectory.appendingPathComponent("kitsafety-\(UUID().uuidString)")
        root = tmp.appendingPathComponent("Kits")
    }
    override func tearDown() { try? fm.removeItem(at: tmp) }

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // MARK: making a kit

    func newKit(at date: Date? = nil, ops: KitFileOps = .standard) throws -> KitStore {
        try KitStore.create(root: root, device: KitManifestTests.device, measurements: KitMeasurements(settings: RecordingSettings()),
                            build: "1.0 (7)", date: date ?? t0, ops: ops)
    }

    func write(_ folder: URL, _ name: String, bytes n: Int, fill: UInt8) throws {
        let u = folder.appendingPathComponent(name)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: n).write(to: u)
    }

    func twoReading(_ tilt: Double) -> KitTrueTilt {
        KitTrueTilt(method: .twoReading, tiltDegrees: tilt, downhillAzimuthDegrees: 90, uncertaintyDegrees: 0.02, bumpDegrees: [1.2, -0.5],
                    turnDegrees: 181, readingA: nil, readingB: nil, reasons: ["Two readings."])
    }

    /// What the recorder leaves in the attempt folder (`fill` tells the attempts apart), and the manifest to commit.
    func record(_ store: KitStore, _ id: String, at s: Double, fill: UInt8, flat: KitTrueTilt? = nil, verdict: KitVerdict = .good) throws -> KitShotManifest {
        let folder = try store.beginShot(id)
        if flat == nil {
            try write(folder, KitClipFiles.video, bytes: 900 + Int(fill), fill: fill)
            try write(folder, KitClipFiles.frames, bytes: 200, fill: fill)
        }
        try write(folder, KitClipFiles.motion, bytes: 300, fill: fill)
        var m = try store.newShotManifest(id, startedAt: at(s), duration: 5)
        let checks = verdict == .good ? [] : [KitQualityCheck(id: "x", passed: false, severity: verdict == .poor ? .poor : .fair, message: "Something.")]
        m.quality = KitQualityReport(checks: checks, frames: 150, medianLuma: 100 + Double(fill), medianAmbient: nil)
        m.flat = flat
        if flat == nil {
            m.video = KitVideoInfo(codec: "hevc", width: 1440, height: 1080, fps: 30, bitrate: 3_500_000, frameCount: 150, fileBytes: Int64(900 + Int(fill)))
        } else {
            m.motionSamples = 1200
        }
        return m
    }

    @discardableResult
    func capture(_ store: KitStore, _ id: String, at s: Double, fill: UInt8, flat: KitTrueTilt? = nil, verdict: KitVerdict = .good) throws -> KitShotManifest {
        let m = try record(store, id, at: s, fill: fill, flat: flat, verdict: verdict)
        return try store.commitShot(id, manifest: m, date: at(s + 6))
    }

    /// Measurements, the room scan, the level true tilt, both level shots and tilt 1's true tilt.
    func kitWithEarlierSteps() throws -> KitStore {
        let store = try newKit()
        try store.commitMeasurements(KitManifestTests.measurements, date: at(1))
        try capture(store, "s02-scan", at: 10, fill: 1)
        try capture(store, "s03-flat-level", at: 20, fill: 2, flat: twoReading(1.0))
        try capture(store, "s04-level-still", at: 30, fill: 3)
        try capture(store, "s04-level-arc", at: 40, fill: 4, verdict: .fair)
        try capture(store, "s05-tilt1-flat", at: 50, fill: 5, flat: twoReading(5.0))
        return store
    }

    // MARK: what a kit holds

    struct ShotState: Equatable {
        var status: KitShotStatus
        var attempts: Int
        var verdict: KitVerdict?
        var height: Double?
        var positionId: String?
        var frames: Int?
        var bytes: Int64?
        /// every file in shots/<id>/, hidden ones included
        var files: [String: Data]
    }

    /// Everything a step can change, without the time stamps.
    struct KitState: Equatable {
        var shots: [String: ShotState]
        var positions: [String]
        var trueTilts: [String: Double]
        var measurements: KitMeasurements
        var measurementsEntered: Bool
        var finished: Bool
        var lightLuma: Double?
    }

    func state(_ s: KitStore) -> KitState {
        var shots: [String: ShotState] = [:]
        for r in s.manifest.shots {
            let folder = s.shotFolder(r.id)
            var files: [String: Data] = [:]
            for rel in KitFiles.regularFiles(in: folder) { files[rel] = try? Data(contentsOf: folder.appendingPathComponent(rel)) }
            shots[r.id] = ShotState(status: r.status, attempts: r.attempts, verdict: r.verdict, height: r.enteredHeightInches,
                                    positionId: r.positionId, frames: r.frames, bytes: r.bytes, files: files)
        }
        var tilts: [String: Double] = [:]
        for p in s.manifest.positions { if let t = p.groundTruth?.tiltDegrees { tilts[p.id] = t } }
        return KitState(shots: shots, positions: s.manifest.positions.map { $0.id }, trueTilts: tilts, measurements: s.manifest.measurements,
                        measurementsEntered: s.manifest.measurementsEntered, finished: s.manifest.isFinished,
                        lightLuma: s.manifest.lightReferenceLuma)
    }

    /// The kit as a fresh `load` from disk sees it.
    func stateOnDisk(_ folder: URL) throws -> KitState { state(try KitStore.load(folder: folder)) }

    func describeDifference(_ a: KitState, _ b: KitState) -> String {
        var out: [String] = []
        for id in Set(a.shots.keys).union(b.shots.keys).sorted() where a.shots[id] != b.shots[id] {
            let x = a.shots[id], y = b.shots[id]
            func show(_ s: ShotState?) -> String {
                s.map { "\($0.status) a\($0.attempts) \(String(describing: $0.verdict)) h\(String(describing: $0.height)) \(String(describing: $0.positionId)) "
                    + "f\(String(describing: $0.frames)) b\(String(describing: $0.bytes)) \($0.files.mapValues { $0.count })" } ?? "-"
            }
            out.append("\(id): \(show(x)) vs \(show(y))")
        }
        if a.positions != b.positions { out.append("positions \(a.positions) vs \(b.positions)") }
        if a.trueTilts != b.trueTilts { out.append("true tilts \(a.trueTilts) vs \(b.trueTilts)") }
        if a.measurementsEntered != b.measurementsEntered || a.measurements != b.measurements { out.append("measurements") }
        if a.finished != b.finished { out.append("finished \(a.finished) vs \(b.finished)") }
        if a.lightLuma != b.lightLuma { out.append("light \(String(describing: a.lightLuma)) vs \(String(describing: b.lightLuma))") }
        return out.joined(separator: "; ")
    }

    /// Nothing left over: kit.json and shots/ only, every shot folder a plain committed one, no hidden files anywhere.
    func assertClean(_ folder: URL, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: folder.path))?.sorted(), ["kit.json", "shots"], context, file: file, line: line)
        for name in (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("shots").path)) ?? [] {
            XCTAssertFalse(name.hasPrefix(".") || name.contains("."), "\(context): leftover shots/\(name)", file: file, line: line)
        }
        for rel in KitFiles.regularFiles(in: folder) {
            XCTAssertFalse(rel.split(separator: "/").contains { $0.hasPrefix(".") }, "\(context): leftover \(rel)", file: file, line: line)
        }
    }

    // MARK: killing the app before every file operation

    /// Runs `body` on the kit with file operations that first copy the kit folder: the disk as a kill just before that
    /// operation leaves it. Returns the copies, oldest first, each named after the operation it came before.
    func killedBeforeEveryOperation(_ folder: URL, _ body: (KitStore) throws -> Void) throws -> [(op: String, folder: URL)] {
        let snapRoot = tmp.appendingPathComponent("kills-\(UUID().uuidString)")
        var snaps: [(op: String, folder: URL)] = []
        let fm = self.fm
        let ops = KitFileOps.observed { op, url in
            let dst = snapRoot.appendingPathComponent(String(format: "%03d", snaps.count)).appendingPathComponent(folder.lastPathComponent)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: folder, to: dst)
            snaps.append((op: "\(op) \(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)", folder: dst))
        }
        let store = try KitStore.load(folder: folder, ops: ops)
        try body(store)
        return snaps
    }

    /// Every kill leaves the kit as it was before the step or as it is after it (never a mix, never an earlier shot
    /// lost), with nothing left over, and opening it again changes nothing more. Returns how many kills gave each.
    @discardableResult
    func assertEveryKillIsSafe(_ snaps: [(op: String, folder: URL)], before: KitState, after: KitState, _ name: String,
                               file: StaticString = #filePath, line: UInt = #line) throws -> (before: Int, after: Int) {
        XCTAssertFalse(snaps.isEmpty, name, file: file, line: line)
        XCTAssertNotEqual(before, after, "\(name): the step changes something", file: file, line: line)
        var counts = (before: 0, after: 0)
        for (i, s) in snaps.enumerated() {
            let context = "\(name), killed before #\(i) (\(s.op))"
            let loaded = try KitStore.load(folder: s.folder)
            let st = state(loaded)
            if st == before { counts.before += 1 } else if st == after { counts.after += 1 } else {
                XCTFail("\(context): neither before nor after: \(describeDifference(st, before)) | vs after: \(describeDifference(st, after))",
                        file: file, line: line)
            }
            assertClean(s.folder, context, file: file, line: line)
            XCTAssertFalse(loaded.unsavedRepairOnLoad, context, file: file, line: line)
            let again = try KitStore.load(folder: s.folder)
            XCTAssertEqual(again.manifest, loaded.manifest, "\(context): opening it again changes nothing", file: file, line: line)
            XCTAssertEqual(again.discardedOnLoad, [], context, file: file, line: line)
            XCTAssertEqual(again.repairedOnLoad, [], context, file: file, line: line)
        }
        XCTAssertGreaterThan(counts.before, 0, "\(name): a kill before the step keeps the kit as it was", file: file, line: line)
        return counts
    }

    func testAKillAtAnyPointOfACommitKeepsEveryEarlierShot() throws {
        let store = try kitWithEarlierSteps()
        // a first capture
        var before = try stateOnDisk(store.folder)
        var snaps = try killedBeforeEveryOperation(store.folder) { s in
            try capture(s, "s05-tilt1-still", at: 60, fill: 6)
        }
        var after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s05-tilt1-still"]?.status, .captured)
        var counts = try assertEveryKillIsSafe(snaps, before: before, after: after, "first capture")
        XCTAssertGreaterThan(counts.after, 0, "a commit whose files are in place counts")

        // a retry of a video shot: the earlier capture stays until the new one is in
        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in
            try capture(s, "s02-scan", at: 70, fill: 7, verdict: .poor)
        }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s02-scan"]?.attempts, 2)
        XCTAssertNotEqual(after.shots["s02-scan"]?.files, before.shots["s02-scan"]?.files)
        counts = try assertEveryKillIsSafe(snaps, before: before, after: after, "retry of the room scan")
        XCTAssertGreaterThan(counts.after, 0)

        // a retry of a true tilt: the slab position's true tilt follows the files that are in place
        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in
            try capture(s, "s03-flat-level", at: 80, fill: 8, flat: twoReading(1.4))
        }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(before.trueTilts["p1"], 1.0)
        XCTAssertEqual(after.trueTilts["p1"], 1.4)
        try assertEveryKillIsSafe(snaps, before: before, after: after, "retry of the level true tilt")

        // a retry of the light reference shot (its brightness is the reference for the dim and bright shots)
        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in
            try capture(s, "s04-level-still", at: 90, fill: 9)
        }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.lightLuma, 109)
        try assertEveryKillIsSafe(snaps, before: before, after: after, "retry of the light reference")
    }

    func testAKillAtAnyPointOfASkipOrRestartKeepsEveryEarlierShot() throws {
        let store = try kitWithEarlierSteps()
        try capture(store, "s05-tilt1-still", at: 60, fill: 6)
        try capture(store, "s05-tilt3-flat", at: 70, fill: 7, flat: twoReading(15))
        try capture(store, "s05-tilt3-still", at: 80, fill: 8)

        // skipping a captured shot
        var before = try stateOnDisk(store.folder)
        var snaps = try killedBeforeEveryOperation(store.folder) { s in try s.skipShot("s04-level-arc", date: self.at(100)) }
        var after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s04-level-arc"]?.status, .skipped)
        XCTAssertEqual(after.shots["s04-level-arc"]?.files, [:])
        try assertEveryKillIsSafe(snaps, before: before, after: after, "skip of a captured shot")

        // skipping the optional third tilt after capturing two of its shots
        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in try s.skipShot("s05-tilt3-flat", date: self.at(110)) }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s05-tilt3-still"]?.status, .skipped)
        XCTAssertFalse(after.positions.contains("p4"))
        try assertEveryKillIsSafe(snaps, before: before, after: after, "skip of the third tilt")

        // the slab moved (Resume): tilt 1's true tilt is taken again
        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in
            XCTAssertNotNil(try s.restartPosition(forShot: "s05-tilt1-arc", date: self.at(120)))
        }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s05-tilt1-flat"]?.status, .pending)
        XCTAssertEqual(after.positions, ["p1", "p2", "p2#2"])
        try assertEveryKillIsSafe(snaps, before: before, after: after, "slab moved")
        XCTAssertEqual(try KitStore.load(folder: store.folder).manifest.position("p2")?.groundTruth?.tiltDegrees, 5.0,
                       "the earlier set-up keeps its true tilt")
    }

    func testAKillAtAnyPointOfAHeightTheMeasurementsOrFinishing() throws {
        let store = try kitWithEarlierSteps()
        try capture(store, "s09-held-low", at: 60, fill: 6)
        var before = try stateOnDisk(store.folder)
        var snaps = try killedBeforeEveryOperation(store.folder) { s in try s.setHeight("s09-held-low", inches: 4.25, date: self.at(70)) }
        var after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.shots["s09-held-low"]?.height, 4.25)
        let counts = try assertEveryKillIsSafe(snaps, before: before, after: after, "entered height")
        XCTAssertGreaterThan(counts.after, 0, "a height in shot.json counts")

        before = after
        let m = KitMeasurements(slabWidthInches: 8, slabDepthInches: 7.5, slabThicknessInches: 1.1, dishInches: nil, ballDiameterMm: 36)
        snaps = try killedBeforeEveryOperation(store.folder) { s in try s.commitMeasurements(m, date: self.at(80)) }
        after = try stateOnDisk(store.folder)
        XCTAssertEqual(after.measurements, m)
        try assertEveryKillIsSafe(snaps, before: before, after: after, "measurements again")

        before = after
        snaps = try killedBeforeEveryOperation(store.folder) { s in try s.finish(date: self.at(90)) }
        after = try stateOnDisk(store.folder)
        XCTAssertTrue(after.finished)
        try assertEveryKillIsSafe(snaps, before: before, after: after, "finish")
    }

    func testAKillWhileCreatingAKitLeavesNothingToResume() throws {
        let earlier = try kitWithEarlierSteps()
        let snapRoot = tmp.appendingPathComponent("create-kills")
        var snaps: [URL] = []
        let ops = KitFileOps.observed { [fm, root] _, _ in
            let dst = snapRoot.appendingPathComponent("\(snaps.count)")
            try fm.createDirectory(at: snapRoot, withIntermediateDirectories: true)
            try fm.copyItem(at: root!, to: dst)
            snaps.append(dst)
        }
        let made = try newKit(at: at(1000), ops: ops)
        XCTAssertGreaterThan(snaps.count, 1)
        for (i, s) in snaps.enumerated() {
            let listed = KitStore.list(root: s)
            XCTAssertEqual(listed.map { $0.kitId }, [earlier.kitId], "kill #\(i): only complete kits are listed")
            XCTAssertEqual(KitStore.resumable(root: s)?.kitId, earlier.kitId, "kill #\(i): the earlier kit is still offered")
        }
        XCTAssertEqual(KitStore.list(root: root).map { $0.kitId }, [made.kitId, earlier.kitId])
    }

    // MARK: a shot that fails, the app killed mid-shot, retries

    func testAShotThatFailsOrIsKilledMidwayLosesNothing() throws {
        let store = try kitWithEarlierSteps()
        let before = try stateOnDisk(store.folder)
        XCTAssertEqual(store.progress.nextShotId, "s05-tilt1-still")

        // the recorder fails half-way (a write error, the camera stopped): the app throws the attempt away
        let a = try store.beginShot("s05-tilt1-still")
        try write(a, KitClipFiles.video, bytes: 500, fill: 9)
        try write(a, KitClipFiles.frames, bytes: 20, fill: 9)
        try store.discardAttempt("s05-tilt1-still")
        XCTAssertEqual(state(store), before)
        XCTAssertEqual(try stateOnDisk(store.folder), before)
        XCTAssertEqual(store.progress.nextShotId, "s05-tilt1-still", "the failed shot is next again")

        // a commit that throws half-way (shot.json cannot be written): nothing changes, the recording stays to retry
        var failWrites = true
        let flaky = try KitStore.load(folder: store.folder, ops: .observed { op, url in
            if failWrites, op == "write", url.lastPathComponent.hasPrefix(".shot.json") { throw POSIXError(.EIO) }
        })
        let m = try record(flaky, "s05-tilt1-still", at: 200, fill: 10)
        XCTAssertThrowsError(try flaky.commitShot("s05-tilt1-still", manifest: m, date: at(206)))
        XCTAssertEqual(state(flaky), before)
        XCTAssertTrue(fm.fileExists(atPath: flaky.attemptFolder("s05-tilt1-still").appendingPathComponent(KitClipFiles.video).path))
        failWrites = false
        // the retry goes through, numbered as the first capture (attempts that were never saved do not count)
        let saved = try flaky.commitShot("s05-tilt1-still", manifest: m, date: at(207))
        XCTAssertEqual(saved.attempt, 1)
        XCTAssertEqual(flaky.record("s05-tilt1-still")?.status, .captured)

        // killed mid-shot (a first try of the next shot, and a retry of an earlier one): opening the kit again keeps
        // every saved shot and points at the first unfinished one
        let mid = try stateOnDisk(store.folder)
        try write(try flaky.beginShot("s05-tilt1-arc"), KitClipFiles.video, bytes: 700, fill: 11)
        try write(try flaky.beginShot("s02-scan"), KitClipFiles.video, bytes: 700, fill: 12)
        let reopened = try KitStore.load(folder: store.folder)
        XCTAssertEqual(reopened.discardedOnLoad, ["s02-scan", "s05-tilt1-arc"])
        XCTAssertEqual(state(reopened), mid)
        XCTAssertEqual(reopened.progress.nextShotId, "s05-tilt1-arc")
        XCTAssertEqual(KitStore.resumable(root: root)?.kitId, store.kitId)
        assertClean(store.folder, "after reopening")
    }

    func testARetakeThatComesBackWorseKeepsTheEarlierTake() throws {
        let store = try kitWithEarlierSteps()
        let before = try stateOnDisk(store.folder)
        XCTAssertEqual(before.trueTilts["p1"], 1.0)

        // Retry on the level flat-phone shot, and the phone is bumped: the reading fails. Committing it would clear p1's
        // true tilt (and delete the reading it came from), so the app asks first and throws the attempt away
        let failed = KitTrueTilt.failed("The phone moved during reading A.")
        let flat = try record(store, "s03-flat-level", at: 300, fill: 20, flat: failed, verdict: .poor)
        XCTAssertEqual(store.retakeLoss("s03-flat-level", manifest: flat),
                       "the new reading has no usable true tilt (The phone moved during reading A), and the earlier one has its true tilt of 1.00°")
        try store.discardAttempt("s03-flat-level")
        XCTAssertEqual(state(store), before)
        XCTAssertEqual(try stateOnDisk(store.folder), before)
        assertClean(store.folder, "after a failed flat-phone retake")

        // a video retake whose check is poor while the earlier take's was good (or fair): kept out the same way
        let scan = try record(store, "s02-scan", at: 310, fill: 21, verdict: .poor)
        XCTAssertEqual(store.retakeLoss("s02-scan", manifest: scan), "the new take's check is poor (Something), and the earlier take's is good")
        try store.discardAttempt("s02-scan")
        let arc = try record(store, "s04-level-arc", at: 320, fill: 22, verdict: .poor)
        XCTAssertEqual(store.retakeLoss("s04-level-arc", manifest: arc), "the new take's check is poor (Something), and the earlier take's is fair")
        try store.discardAttempt("s04-level-arc")
        XCTAssertEqual(try stateOnDisk(store.folder), before)

        // a retake at least as good is committed as before: a fair arc after a fair one, a usable reading
        let arc2 = try record(store, "s04-level-arc", at: 330, fill: 23, verdict: .fair)
        XCTAssertNil(store.retakeLoss("s04-level-arc", manifest: arc2))
        try store.commitShot("s04-level-arc", manifest: arc2, date: at(336))
        let flat2 = try record(store, "s03-flat-level", at: 340, fill: 24, flat: twoReading(1.1))
        XCTAssertNil(store.retakeLoss("s03-flat-level", manifest: flat2))
        try store.commitShot("s03-flat-level", manifest: flat2, date: at(346))
        XCTAssertEqual(try stateOnDisk(store.folder).trueTilts["p1"], 1.1)

        // a first capture is never held back, poor or not, and a poor retake of a poor take replaces it
        let still = try record(store, "s05-tilt1-still", at: 350, fill: 25, verdict: .poor)
        XCTAssertNil(store.retakeLoss("s05-tilt1-still", manifest: still))
        try store.commitShot("s05-tilt1-still", manifest: still, date: at(356))
        let still2 = try record(store, "s05-tilt1-still", at: 360, fill: 26, verdict: .poor)
        XCTAssertNil(store.retakeLoss("s05-tilt1-still", manifest: still2))
        try store.discardAttempt("s05-tilt1-still")

        // what committing a failed reading anyway does (the loss the check prevents): the position's true tilt is gone
        let failedAgain = try record(store, "s05-tilt1-flat", at: 370, fill: 27, flat: failed, verdict: .poor)
        XCTAssertNotNil(store.retakeLoss("s05-tilt1-flat", manifest: failedAgain))
        try store.commitShot("s05-tilt1-flat", manifest: failedAgain, date: at(376))
        XCTAssertNil(try stateOnDisk(store.folder).trueTilts["p2"])
        // once the position has no true tilt, a failed retake loses nothing more
        let failedThird = try record(store, "s05-tilt1-flat", at: 380, fill: 28, flat: failed, verdict: .poor)
        XCTAssertNil(store.retakeLoss("s05-tilt1-flat", manifest: failedThird))
        try store.discardAttempt("s05-tilt1-flat")
    }

    func testKitFoldersThatCannotBeReadAreNamedForTheLog() throws {
        let good = try newKit()
        let broken = root.appendingPathComponent("slab-kit-broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent(KitStore.manifestFile))
        try fm.createDirectory(at: root.appendingPathComponent("slab-kit-empty"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("stray.txt"))
        XCTAssertEqual(KitStore.list(root: root).map { $0.kitId }, [good.kitId])
        let bad = KitStore.unreadable(root: root)
        XCTAssertEqual(bad.map { $0.name }, ["slab-kit-broken", "slab-kit-empty"])
        for b in bad { XCTAssertFalse(DevLog.describe(b.error).contains(root.path), DevLog.describe(b.error)) }
        XCTAssertEqual(KitStore.unreadable(root: tmp.appendingPathComponent("nowhere")).count, 0)
    }

    func testResumePointsAtTheFirstUnfinishedStep() throws {
        let store = try newKit()
        try store.skipShot("s01-measure", date: at(1))
        try capture(store, "s02-scan", at: 10, fill: 1)
        // s03 fails (never committed); s04-level-still is captured out of order (a retry from the end screen)
        _ = try store.beginShot("s03-flat-level")
        try store.discardAttempt("s03-flat-level")
        try capture(store, "s04-level-still", at: 30, fill: 3)
        let reopened = try KitStore.load(folder: store.folder)
        XCTAssertEqual(reopened.progress.nextShotId, "s03-flat-level")
        XCTAssertEqual(reopened.progress.label, "Step 3 of 12")
        XCTAssertEqual(reopened.progress.done, 3)
        XCTAssertNil(reopened.positionInProgress)
    }

    // MARK: a full disk

    /// File operations that fail writes (ENOSPC) while `full` is set.
    final class Disk {
        var full = false
        var failedWrites = 0
        lazy var ops = KitFileOps.observed { [unowned self] op, _ in
            if self.full, op == "write" { self.failedWrites += 1; throw POSIXError(.ENOSPC) }
        }
    }

    func assertNoTemporaryFiles(_ folder: URL, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for rel in KitFiles.regularFiles(in: folder) {
            XCTAssertFalse(rel.split(separator: "/").contains { $0.hasPrefix(".") }, "\(context): \(rel)", file: file, line: line)
        }
    }

    func testAFullDiskFailsTheStepAndKeepsEverythingElse() throws {
        let store = try kitWithEarlierSteps()
        try capture(store, "s09-held-low", at: 60, fill: 6)
        let disk = Disk()
        let s = try KitStore.load(folder: store.folder, ops: disk.ops)

        /// the step fails with the disk full, changes nothing in memory or on disk, then works once there is room
        func check(_ name: String, attempt: Bool = false, _ step: () throws -> Void) throws {
            let memory = s.manifest, onDisk = try Data(contentsOf: s.manifestURL)
            disk.full = true
            let failed = disk.failedWrites
            XCTAssertThrowsError(try step(), name) { e in
                XCTAssertEqual((e as? POSIXError)?.code, .ENOSPC, name)
                XCTAssertEqual(DevLog.describe(e).contains("28"), true, "\(name): the log says why")
            }
            XCTAssertGreaterThan(disk.failedWrites, failed, name)
            XCTAssertEqual(s.manifest, memory, "\(name): nothing changed in memory")
            XCTAssertEqual(try Data(contentsOf: s.manifestURL), onDisk, "\(name): kit.json is untouched")
            assertNoTemporaryFiles(s.folder, name)
            disk.full = false
            try step()
            XCTAssertNotEqual(s.manifest, memory, "\(name): goes through with room")
        }

        try check("first capture") {
            if !fm.fileExists(atPath: s.attemptFolder("s05-tilt1-still").path) { _ = try record(s, "s05-tilt1-still", at: 100, fill: 20) }
            let m = try s.newShotManifest("s05-tilt1-still", startedAt: at(100), duration: 5)
            try s.commitShot("s05-tilt1-still", manifest: m, date: at(106))
        }
        let scanBefore = state(s).shots["s02-scan"]
        try check("retry") {
            if !fm.fileExists(atPath: s.attemptFolder("s02-scan").path) { _ = try record(s, "s02-scan", at: 110, fill: 21) }
            var m = try s.newShotManifest("s02-scan", startedAt: at(110), duration: 20)
            XCTAssertEqual(state(s).shots["s02-scan"]?.files, scanBefore?.files, "the earlier capture is still there")
            m.quality = KitQualityReport(checks: [], frames: 600, medianLuma: 99, medianAmbient: nil)
            try s.commitShot("s02-scan", manifest: m, date: at(131))
        }
        try check("height") { try s.setHeight("s09-held-low", inches: 3.75, date: at(140)) }
        try check("skip") { try s.skipShot("s04-level-arc", date: at(150)) }
        try check("slab moved") { try s.restartPosition(forShot: "s05-tilt1-arc", date: at(160)) }
        try check("measurements") {
            try s.commitMeasurements(KitMeasurements(slabWidthInches: 8, slabDepthInches: 8, slabThicknessInches: 1, dishInches: 0.1, ballDiameterMm: 35),
                                     date: at(170))
        }
        try check("finish") { try s.finish(date: at(180)) }
        XCTAssertEqual(try stateOnDisk(s.folder), state(s), "what is saved is what the app shows")

        // a new kit on a full disk: nothing is left half-made, the earlier kit stays
        disk.full = true
        XCTAssertThrowsError(try newKit(at: at(5000), ops: disk.ops))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [store.kitId])
        disk.full = false
    }

    func testAKitWhoseRepairCannotBeSavedStillOpens() throws {
        let store = try kitWithEarlierSteps()
        // killed after moving a retry into place, before kit.json was saved
        let kitJSON = try Data(contentsOf: store.manifestURL)
        try capture(store, "s02-scan", at: 100, fill: 30)
        try kitJSON.write(to: store.manifestURL)
        let disk = Disk()
        disk.full = true
        let s = try KitStore.load(folder: store.folder, ops: disk.ops)
        XCTAssertTrue(s.unsavedRepairOnLoad)
        XCTAssertEqual(s.repairedOnLoad, ["s02-scan"])
        XCTAssertEqual(s.record("s02-scan")?.attempts, 2, "repaired in memory")
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), kitJSON, "kit.json as it was")
        // opening it again repairs it the same way
        XCTAssertEqual(try KitStore.load(folder: store.folder, ops: disk.ops).manifest, s.manifest)
        // the next change that can be saved saves it all
        disk.full = false
        try s.skipShot("s05-tilt1-still", date: at(200))
        XCTAssertFalse(s.unsavedRepairOnLoad)
        let again = try KitStore.load(folder: store.folder)
        XCTAssertEqual(again.repairedOnLoad, [])
        XCTAssertEqual(again.record("s02-scan")?.attempts, 2)
    }

    // MARK: writes cut short

    func testAWriteCutShortLeavesTheOldFileAndIsCleanedUp() throws {
        let store = try kitWithEarlierSteps()
        try capture(store, "s09-held-low", at: 60, fill: 6)
        let before = try stateOnDisk(store.folder)
        let kitJSON = try Data(contentsOf: store.manifestURL)
        // what a kill mid-write leaves: half a kit.json and half a shot.json in temporary files, and the temporary
        // file of the system's own atomic write (earlier builds)
        try kitJSON.prefix(kitJSON.count / 2).write(to: store.folder.appendingPathComponent(".kit.json.writing-DEAD"))
        try Data("{\"kitId\"".utf8).write(to: store.shotFolder("s09-held-low").appendingPathComponent(".shot.json.writing-DEAD"))
        try Data("{".utf8).write(to: store.folder.appendingPathComponent(".dat.nosync1a2b.XyZ"))
        XCTAssertEqual(KitBundle.files(in: store.folder).filter { $0.contains("writing") || $0.contains("nosync") }, [], "never bundled")
        let loaded = try KitStore.load(folder: store.folder)
        XCTAssertEqual(state(loaded), before)
        assertClean(store.folder, "after load")
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), kitJSON, "nothing to repair: kit.json untouched")

        // the atomic write itself: a rename that fails leaves the old file and no temporary file
        let target = tmp.appendingPathComponent("file.json")
        try Data("old".utf8).write(to: target)
        let failing = KitFileOps.observed { op, _ in if op == "replace" { throw POSIXError(.EIO) } }
        XCTAssertThrowsError(try failing.writeAtomically(Data("new".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).filter { $0.hasPrefix(".") }, [])
        try KitFileOps.standard.writeAtomically(Data("new".utf8), to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
        XCTAssertTrue(KitFileOps.isLeftoverTemp(".kit.json.writing-1234"))
        XCTAssertTrue(KitFileOps.isLeftoverTemp(".shot.json.writing-1234"))
        XCTAssertFalse(KitFileOps.isLeftoverTemp("kit.json"))
        XCTAssertFalse(KitFileOps.isLeftoverTemp("video.mp4"))
    }

    func testKitJSONKeepsItsFormat() throws {
        // kits recorded by n7 open unchanged: the store still writes plain KitJSON, nothing else in the kit folder
        let store = try kitWithEarlierSteps()
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), try KitJSON.encode(store.manifest))
        XCTAssertEqual(try KitJSON.encode(XCTUnwrap(try store.shotManifest("s02-scan"))),
                       try Data(contentsOf: store.shotFolder("s02-scan").appendingPathComponent(KitClipFiles.shotManifest)))
        // a kit.json written the way n7 wrote it (Foundation's atomic write) loads with nothing to repair
        let n7 = try kitWithEarlierStepsCopy(store)
        try KitJSON.encode(store.manifest).write(to: n7.appendingPathComponent(KitStore.manifestFile), options: .atomic)
        let loaded = try KitStore.load(folder: n7)
        XCTAssertEqual(loaded.manifest, store.manifest)
        XCTAssertEqual(loaded.repairedOnLoad, [])
        XCTAssertEqual(loaded.discardedOnLoad, [])
    }

    func kitWithEarlierStepsCopy(_ store: KitStore) throws -> URL {
        let dst = tmp.appendingPathComponent("copy").appendingPathComponent(store.kitId)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: store.folder, to: dst)
        return dst
    }

    // MARK: the bundle

    func testAFailedBundleLeavesTheKitAsItWasAndCanBeMadeAgain() throws {
        let store = try kitWithEarlierSteps()
        try store.finish(date: at(100))
        let outbox = tmp.appendingPathComponent("outbox").appendingPathComponent(store.kitId)
        let before = try stateOnDisk(store.folder)
        let kitFiles = KitFiles.regularFiles(in: store.folder)
        // the build fails part-way: after the compressed copies are written, its parts folder cannot be made
        let failing: KitDeflater = { [fm] data in
            for name in (try? fm.contentsOfDirectory(atPath: outbox.path)) ?? [] where name.hasPrefix(".") {
                let parts = outbox.appendingPathComponent(name).appendingPathComponent("parts")
                if !fm.fileExists(atPath: parts.path) { _ = fm.createFile(atPath: parts.path, contents: Data("x".utf8)) }
            }
            return KitTestDeflate.fixedHuffman(data)
        }
        XCTAssertThrowsError(try KitBundle.build(kitFolder: store.folder, outbox: outbox, deflate: failing))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path), [], "no parts and no working files left")
        XCTAssertEqual(KitFiles.regularFiles(in: store.folder), kitFiles, "the kit folder is untouched")
        XCTAssertEqual(try stateOnDisk(store.folder), before)
        assertClean(store.folder, "after a failed bundle")
        // a build killed part-way leaves its hidden working folder: the next build (or the app at launch) removes it
        let dead = outbox.appendingPathComponent(".\(store.kitId)-bundle-DEAD")
        try fm.createDirectory(at: dead, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: dead.appendingPathComponent("000001.deflate"))
        // made again
        let r = try KitBundle.build(kitFolder: store.folder, outbox: outbox, deflate: KitTestDeflate.fixedHuffman)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outbox.path).sorted(), r.parts.map { $0.name }.sorted())
        let entries = Set(r.parts.flatMap { $0.entries })
        XCTAssertEqual(entries, Set(kitFiles.map { store.kitId + "/" + $0 }), "every kit file in the bundle")
        XCTAssertEqual(try stateOnDisk(store.folder), before)
    }
}
