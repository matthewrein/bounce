import XCTest
@testable import BounceCore

/// standard-v2 (n20k): the drops on a tilted slab with a reading of their own right before them, the rule that holds a
/// drop back without it, and the tilt check that flags a slab moved after its reading. standard-v1 stays as it was.
final class KitTiltedDropsTests: XCTestCase {
    var root: URL!
    let t0 = Date(timeIntervalSince1970: 1_794_929_400) // 2026-11-17 15:30:00 UTC
    let fm = FileManager.default
    let v2 = KitPlan.standard, v1 = KitPlan.standardV1
    let drops = ["s10-drop1", "s10-drop2", "s10-drop3", "s11-drop-edge"]

    override func setUp() {
        root = fm.temporaryDirectory.appendingPathComponent("kittilted-\(UUID().uuidString)").appendingPathComponent("Kits")
    }
    override func tearDown() { try? fm.removeItem(at: root.deletingLastPathComponent()) }

    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func newKit(plan: KitPlan = .standard) throws -> KitStore {
        try KitStore.create(root: root, plan: plan, device: KitManifestTests.device, measurements: KitMeasurements(settings: RecordingSettings()),
                            build: "1.0 (7)", date: t0)
    }

    func twoReading(_ tilt: Double) -> KitTrueTilt {
        KitTrueTilt(method: .twoReading, tiltDegrees: tilt, downhillAzimuthDegrees: 90, uncertaintyDegrees: 0.02, bumpDegrees: [1.2, -0.5],
                    turnDegrees: 181, reasons: ["Two readings."])
    }

    /// Record a shot with fake files and commit it (a flat-phone shot when `flat` is given), with a tilt check if given.
    @discardableResult
    func capture(_ store: KitStore, _ id: String, at s: Double, flat: KitTrueTilt? = nil, stats: [KitFrameStat]? = nil) throws -> KitShotManifest {
        let folder = try store.beginShot(id)
        try Data(repeating: 1, count: 300).write(to: folder.appendingPathComponent(KitClipFiles.motion))
        var m = try store.newShotManifest(id, startedAt: at(s), duration: 5)
        m.quality = KitQualityReport(checks: [], frames: 150, medianLuma: 120)
        m.flat = flat
        if flat == nil {
            try Data(repeating: 1, count: 1000).write(to: folder.appendingPathComponent(KitClipFiles.video))
            m.video = KitVideoInfo(codec: "hevc", width: 1280, height: 960, fps: 30, bitrate: 3_000_000, frameCount: 150, fileBytes: 1000)
            if let st = stats { m.tiltCheck = store.tiltCheck(forShot: id, stats: st) }
        } else {
            m.motionSamples = 1200
        }
        return try store.commitShot(id, manifest: m, date: at(s + 6))
    }

    /// A shot's frames: the slab locked, the app's tilt about `tilt` (small wobble), its honest deviation, settled or not.
    func frames(_ n: Int, tilt: Double, sigma: Double?, settled: Bool, locked: Bool = true) -> [KitFrameStat] {
        (0..<n).map { i in
            KitFrameStat(t: Double(i) / 30, slabFound: locked, slabLocked: locked, appTiltDegrees: tilt + 0.05 * sin(Double(i)),
                         appTiltSigmaDegrees: sigma, appTiltSettled: settled)
        }
    }

    /// A v2 kit taken up to the drops' reading (its next shot): level, tilt 1, tilt 2 read (0.4°, 5.1°, 10.2°); the
    /// optional third tilt and every other shot before the reading skipped.
    func kitBeforeTheDrops() throws -> KitStore {
        let store = try newKit()
        let tilts: [String: Double] = ["s03-flat-level": 0.4, "s05-tilt1-flat": 5.1, "s05-tilt2-flat": 10.2]
        var s = 10.0
        for spec in v2.shots.prefix(while: { $0.id != "s10-flat" }) where store.record(spec.id)?.status == .pending {
            if let t = tilts[spec.id] { try capture(store, spec.id, at: s, flat: twoReading(t)) } else { try store.skipShot(spec.id, date: at(s)) }
            s += 1
        }
        XCTAssertEqual(store.progress.nextShotId, "s10-flat")
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3"])
        return store
    }

    // MARK: the plans

    func testPlanV2PutsAReadingRightBeforeTheDrops() throws {
        XCTAssertEqual(v2.id, "standard-v2")
        XCTAssertEqual(v2.stepCount, 12, "still 12 steps")
        XCTAssertEqual(v2.steps.map { $0.number }, Array(1...12))
        XCTAssertEqual(v2.shotCount, 29)
        XCTAssertEqual(v2.requiredShots.count, 26)
        XCTAssertEqual(v2.optionalShots.map { $0.id }, ["s05-tilt3-flat", "s05-tilt3-still", "s05-tilt3-arc"])
        XCTAssertEqual(Set(v2.shots.map { $0.id }).count, v2.shotCount, "shot ids are unique")
        for s in v2.shots {
            XCTAssertTrue(s.id.hasPrefix(String(format: "s%02d-", s.step)), s.id)
            XCTAssertNotNil(s.id.range(of: "^[a-z0-9-]+$", options: .regularExpression), "ids are safe folder names: \(s.id)")
        }
        let flatIndex = try XCTUnwrap(v2.index(of: "s10-flat"))
        XCTAssertEqual(v2.index(of: "s10-drop1"), flatIndex + 1, "the reading comes right before the first drop")
        let flat = try XCTUnwrap(v2.shot("s10-flat"))
        XCTAssertTrue(flat.isFlat)
        XCTAssertFalse(flat.optional, "the drops' reading is required")
        XCTAssertEqual(flat.step, 10)
        XCTAssertEqual(flat.countdown, 5)
        XCTAssertEqual(flat.startsPosition, KitPositionSpec(id: "p5", label: "drops"))
        XCTAssertEqual(flat.diagram, .flatPhoneTilted)
        XCTAssertEqual(v2.shots.filter { $0.isFlat }.map { $0.startsPosition?.id }, ["p1", "p2", "p3", "p4", "p5"])
        // unmissable words: leave it tilted, do not level it, do not touch it until the drops are done
        XCTAssertTrue(flat.instruction.contains("Leave it tilted: do not level it."), flat.instruction)
        XCTAssertTrue(flat.instruction.contains("Lay the phone flat in its middle, top pointing away. Let go."), flat.instruction)
        XCTAssertTrue(flat.detail?.contains("do not touch the slab until the drops are done") ?? false)
        XCTAssertEqual(flat.warning, "Leave the slab tilted for the drops: do not level it.")
        for id in drops {
            let d = try XCTUnwrap(v2.shot(id))
            XCTAssertTrue(d.instruction.hasPrefix("Leave the slab tilted. Hold the ball about 1 ft over"), d.instruction)
            XCTAssertTrue(d.detail?.hasPrefix("Do not level it or touch it: the drops use the tilt just measured.") ?? false, id)
            XCTAssertEqual(d.warning, "Do not level the slab or touch it until the drops are done.")
            XCTAssertTrue(d.requiresTruth, id)
            XCTAssertEqual(v2.positionShot(for: id)?.id, "s10-flat", id)
        }
        XCTAssertEqual(v2.shots.filter { $0.requiresTruth }.map { $0.id }, drops)
        XCTAssertEqual(v2.shots.filter { $0.warning != nil }.map { $0.id }, ["s08-ball-centre", "s10-flat"] + drops)
        // the ball resting on the slab: the owner levelled the slab there in both v1 kits; now: leave it tilted, or skip
        let ball = try XCTUnwrap(v2.shot("s08-ball-centre"))
        XCTAssertTrue(ball.instruction.hasPrefix("Leave the slab tilted. Rest the ball in the slab's dish"), ball.instruction)
        XCTAssertTrue(ball.detail?.hasPrefix("If the ball will not stay on the tilted slab, tap Skip rather than levelling the slab.") ?? false)
        XCTAssertEqual(ball.warning, "Do not level the slab for the ball: if it will not stay, tap Skip.")
        XCTAssertFalse(ball.requiresTruth)
        var v1Ball = try XCTUnwrap(v1.shot("s08-ball-centre"))
        v1Ball.instruction = ball.instruction; v1Ball.detail = ball.detail; v1Ball.warning = ball.warning
        XCTAssertEqual(ball, v1Ball, "only its words change: same kind, expectations, position")
        // every other shot is v1's, in v1's order
        XCTAssertEqual(v2.shots.map { $0.id }.filter { $0 != "s10-flat" }, v1.shots.map { $0.id })
        for s in v1.shots where !drops.contains(s.id) && s.id != "s08-ball-centre" { XCTAssertEqual(v2.shot(s.id), s, s.id) }
        XCTAssertEqual(v2.lightReferenceShotId, v1.lightReferenceShotId)
        XCTAssertEqual(v2.recordingSeconds(), v1.recordingSeconds() + 12, accuracy: 1e-9)
        XCTAssertEqual(Set(v2.shots.map { $0.diagram }), Set(KitDiagram.allCases))
        XCTAssertEqual(v2.positionShot(for: "s12-no-ball")?.id, "s10-flat")
        XCTAssertEqual(v2.positionShot(for: "s09-held-low")?.id, "s05-tilt3-flat")
        XCTAssertNil(v2.positionShot(for: "s02-scan"))
        XCTAssertEqual(v2.positionShot(for: "s03-flat-level")?.id, "s03-flat-level")
        XCTAssertEqual(try JSONDecoder().decode(KitPlan.self, from: JSONEncoder().encode(v2)), v2)
    }

    func testPlanV1IsUnchangedAndBothAreKnown() throws {
        XCTAssertEqual(v1.id, "standard-v1")
        XCTAssertEqual(v1.shotCount, 28)
        XCTAssertNil(v1.shot("s10-flat"))
        XCTAssertFalse(v1.shots.contains { $0.requiresTruth || $0.warning != nil })
        XCTAssertEqual(v1.step(10)?.title, "Bounces")
        XCTAssertEqual(v1.shot("s10-drop1")?.instruction, "Hold the ball about 1 ft over the middle of the slab and let go at the high beep (Drop now).")
        XCTAssertEqual(v1.shot("s08-ball-centre")?.instruction,
                       "Rest the ball in the slab's dish, as near the middle as it will stay. Hold still, slab in the middle of the screen.")
        XCTAssertEqual(v1.shot("s10-drop1")?.detail, "Keep the slab and the floor around it in view until the recording stops.")
        XCTAssertEqual(v1.shot("s11-drop-edge")?.instruction,
                       "Hold the ball about 1 ft over the slab, just inside one edge, and let go at the high beep (Drop now).")
        XCTAssertEqual(KitPlan.named("standard-v1"), v1)
        XCTAssertEqual(KitPlan.named("standard-v2"), v2)
        XCTAssertEqual(KitPlan.named("standard-v1", timeScale: 0.25), v1.scaled(by: 0.25))
        XCTAssertEqual(KitPlan.named("standard-v2", timeScale: 0.25), v2.scaled(by: 0.25))
        XCTAssertEqual(KitPlan.named("standard-v2", timeScale: 0.25)?.shot("s10-flat")?.countdown, 1.25)
        XCTAssertNil(KitPlan.named("standard-v3"))
        XCTAssertNil(KitPlan.named("standard-v2", timeScale: 0))
    }

    func testNewKitsUseV2AndOldKitsResumeOnV1() throws {
        let fresh = try KitStore.create(root: root, device: KitManifestTests.device, measurements: KitMeasurements(settings: RecordingSettings()),
                                        build: "1.0 (7)", date: t0)
        XCTAssertEqual(fresh.manifest.planId, "standard-v2")
        XCTAssertEqual(fresh.manifest.shots.count, 29)
        XCTAssertEqual(try KitStore.load(folder: fresh.folder).plan, v2)
        // a v1 kit on the phone: resumes on v1, with v1's 28 records, and its drops are never held back
        let old = try KitStore.create(root: root, plan: v1, device: KitManifestTests.device, measurements: KitMeasurements(settings: RecordingSettings()),
                                      build: "n20", date: at(100))
        try capture(old, "s05-tilt2-flat", at: 10, flat: twoReading(10))
        let loaded = try KitStore.load(folder: old.folder)
        XCTAssertEqual(loaded.plan, v1)
        XCTAssertEqual(loaded.manifest.shots.map { $0.id }, v1.shots.map { $0.id }, "no s10-flat added to a v1 kit")
        XCTAssertEqual(loaded.positionId(forShot: "s10-drop1"), "p3", "v1's drops keep the last tilt's position, as before")
        for id in drops { XCTAssertNil(loaded.missingTruth(forShot: id), id) }
        XCTAssertTrue(KitStore.list(root: root).allSatisfy { $0.loadable })
    }

    // MARK: the rule: no drop without the reading right before it

    func testTheDropsGetTheirOwnReadingsTruth() throws {
        let store = try kitBeforeTheDrops()
        try capture(store, "s09-held-low", at: 50)
        XCTAssertEqual(store.positionId(forShot: "s09-held-low"), "p3")
        let flat = try capture(store, "s10-flat", at: 60, flat: twoReading(9.8))
        XCTAssertEqual(flat.positionId, "p5")
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3", "p5"])
        XCTAssertEqual(store.manifest.position("p5")?.label, "drops")
        for id in drops {
            XCTAssertNil(store.missingTruth(forShot: id), id)
            XCTAssertEqual(store.positionId(forShot: id), "p5", id)
            XCTAssertEqual(try store.newShotManifest(id, startedAt: at(70), duration: 6).trueTilt?.tiltDegrees, 9.8, id)
        }
        let d1 = try capture(store, "s10-drop1", at: 70)
        XCTAssertEqual(d1.positionId, "p5")
        XCTAssertEqual(d1.trueTilt?.tiltDegrees, 9.8, "the drop carries the reading taken right before it, not tilt 2's 10.2")
        XCTAssertEqual(store.record("s10-drop1")?.positionId, "p5")
        XCTAssertEqual(store.positionId(forShot: "s12-no-ball"), "p5")
        XCTAssertEqual(try KitStore.load(folder: store.folder).record("s10-drop1")?.positionId, "p5")
        // the shots before the drops' reading keep tilt 2
        XCTAssertEqual(store.record("s09-held-low")?.positionId, "p3")
    }

    func testASkippedReadingHoldsTheDropsBackButTheyCanBeSkipped() throws {
        let store = try kitBeforeTheDrops()
        try store.skipShot("s10-flat", date: at(60))
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3", "p5"], "a skipped reading still starts the drops' position")
        XCTAssertNil(store.manifest.position("p5")?.groundTruth)
        XCTAssertEqual(store.positionId(forShot: "s10-drop1"), "p5", "never tilt 2's position")
        for id in drops {
            let m = try XCTUnwrap(store.missingTruth(forShot: id), id)
            XCTAssertEqual(m, KitMissingTruth(shotId: id, flatShotId: "s10-flat", reason: .skipped))
        }
        let m = try XCTUnwrap(store.missingTruth(forShot: "s10-drop1"))
        XCTAssertEqual(m.message, "Take the phone-on-slab reading first: the drops need the slab's tilt measured right before them.")
        XCTAssertEqual(m.why, "It was skipped.")
        XCTAssertEqual(store.progress.nextShotId, "s10-drop1")
        // never trapped: the drop itself can be skipped
        try store.skipShot("s10-drop1", date: at(70))
        XCTAssertEqual(store.record("s10-drop1")?.status, .skipped)
        XCTAssertEqual(store.progress.nextShotId, "s10-drop2")
        // the reading taken after all (the drop screen's "Take the reading"): the drops may be recorded
        try capture(store, "s10-flat", at: 80, flat: twoReading(11.5))
        XCTAssertEqual(store.manifest.positions.map { $0.id }, ["p1", "p2", "p3", "p5"], "the same set-up, now with its true tilt")
        XCTAssertNil(store.missingTruth(forShot: "s10-drop2"))
        XCTAssertEqual(try capture(store, "s10-drop2", at: 90).trueTilt?.tiltDegrees, 11.5)
        // other shots are never held back
        for s in v2.shots where !s.requiresTruth { XCTAssertNil(store.missingTruth(forShot: s.id), s.id) }
    }

    func testAFailedOrMissingReadingHoldsTheDropsBack() throws {
        let store = try kitBeforeTheDrops()
        // not taken yet: held back (the drop would otherwise have had tilt 2's position)
        XCTAssertEqual(store.missingTruth(forShot: "s10-drop1")?.reason, .notTaken)
        XCTAssertEqual(store.missingTruth(forShot: "s10-drop1")?.why, "It has not been taken since the slab was set up.")
        // taken, but the reading failed
        try capture(store, "s10-flat", at: 60, flat: .failed("The phone moved."))
        XCTAssertNil(store.manifest.position("p5")?.groundTruth)
        XCTAssertEqual(store.missingTruth(forShot: "s10-drop1"), KitMissingTruth(shotId: "s10-drop1", flatShotId: "s10-flat", reason: .failed))
        XCTAssertEqual(store.missingTruth(forShot: "s10-drop1")?.why, "Its reading gave no tilt.")
        // retaken with a usable reading
        try capture(store, "s10-flat", at: 70, flat: twoReading(9.9))
        XCTAssertNil(store.missingTruth(forShot: "s10-drop1"))
    }

    func testTheSlabMovedOnResumeStartsANewSetUpThatNeedsItsOwnReading() throws {
        let store = try kitBeforeTheDrops()
        try capture(store, "s10-flat", at: 60, flat: twoReading(9.8))
        try capture(store, "s10-drop1", at: 70)
        // quit, resumed, "Has the slab moved since drops?" Yes
        let resumed = try KitStore.load(folder: store.folder)
        XCTAssertEqual(resumed.positionInProgress?.id, "p5")
        let next = try XCTUnwrap(try resumed.restartPosition(forShot: "s10-drop2", date: at(100)))
        XCTAssertEqual(next.id, "p5#2")
        XCTAssertNil(next.groundTruth)
        XCTAssertEqual(resumed.record("s10-flat")?.status, .pending)
        XCTAssertEqual(resumed.progress.nextShotId, "s10-flat")
        XCTAssertEqual(resumed.missingTruth(forShot: "s10-drop2"), KitMissingTruth(shotId: "s10-drop2", flatShotId: "s10-flat", reason: .notTaken),
                       "the earlier set-up's reading does not count for the new one")
        XCTAssertEqual(resumed.record("s10-drop1")?.positionId, "p5", "the drop already taken keeps its set-up and reading")
        try capture(resumed, "s10-flat", at: 110, flat: twoReading(12.1))
        XCTAssertNil(resumed.missingTruth(forShot: "s10-drop2"))
        let d2 = try capture(resumed, "s10-drop2", at: 120)
        XCTAssertEqual(d2.positionId, "p5#2")
        XCTAssertEqual(d2.trueTilt?.tiltDegrees, 12.1)
        XCTAssertEqual(resumed.manifest.position("p5")?.groundTruth?.tiltDegrees, 9.8)
    }

    // MARK: the tilt check

    func testTiltCheckFlagsTheOwnersKits() throws {
        // the owner's kits: the slab put back level for the drops (the app read about 0.3°), the kit holding 17.2° and 12°
        for truth in [17.2, 12.0] {
            let c = try XCTUnwrap(KitTiltCheck.make(stats: frames(120, tilt: 0.3, sigma: 0.8, settled: true), truthDegrees: truth))
            XCTAssertEqual(c.appTiltDegrees, 0.3, accuracy: 0.06)
            XCTAssertEqual(c.appSigmaDegrees, 0.8)
            XCTAssertTrue(c.appSettled)
            XCTAssertEqual(c.appFrames, 120)
            XCTAssertEqual(c.truthTiltDegrees, truth)
            XCTAssertEqual(c.differenceDegrees, truth - c.appTiltDegrees, accuracy: 1e-12)
            XCTAssertTrue(c.disagrees, "\(truth)")
        }
        let c = KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: 0.8, appSettled: true, appFrames: 120, truthTiltDegrees: 17.2)
        XCTAssertTrue(c.disagrees)
        XCTAssertEqual(c.differenceDegrees, 16.9, accuracy: 1e-9)
        // a drop offers "Take the reading again", so it is told to retake the reading; any other shot is only asked
        XCTAssertEqual(c.message(offersRetake: true),
                       "The app reads 0.3° but the phone-on-slab reading says 17.2°: has the slab moved? Retake the reading.")
        XCTAssertEqual(c.message(offersRetake: false), "The app reads 0.3° but the phone-on-slab reading says 17.2°: has the slab moved since its reading?")
        XCTAssertEqual(c.line(shot: "s10-drop1"), "s10-drop1: the app read 0.3°, the phone-on-slab reading 17.2° (16.9° apart)")
        // even unsettled, a sure reading that far off flags (16.9° against 2 x 2.5°)
        XCTAssertTrue(KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: 2.5, appSettled: false, appFrames: 40, truthTiltDegrees: 17.2).disagrees)
    }

    func testTiltCheckDoesNotFlagAgreementOrAnUnsureReading() throws {
        // 1.2° against 1.0°, sigma 2.5: agrees
        let near = KitTiltCheck(appTiltDegrees: 1.2, appSigmaDegrees: 2.5, appSettled: false, appFrames: 30, truthTiltDegrees: 1.0)
        XCTAssertFalse(near.disagrees)
        XCTAssertNil(near.message(offersRetake: true))
        XCTAssertNil(near.message(offersRetake: false))
        XCTAssertEqual(near.differenceDegrees, 0.2, accuracy: 1e-12)
        XCTAssertFalse(try XCTUnwrap(KitTiltCheck.make(stats: frames(30, tilt: 1.2, sigma: 2.5, settled: false), truthDegrees: 1.0)).disagrees)
        // a still, unsettled single view: 4.5° off but its sigma is 3°: not raised
        XCTAssertFalse(KitTiltCheck(appTiltDegrees: 5, appSigmaDegrees: 3, appSettled: false, appFrames: 30, truthTiltDegrees: 0.5).disagrees)
        // within 3° never counts, however sure
        XCTAssertFalse(KitTiltCheck(appTiltDegrees: 12.9, appSigmaDegrees: 0.1, appSettled: true, appFrames: 30, truthTiltDegrees: 10).disagrees)
        XCTAssertTrue(KitTiltCheck(appTiltDegrees: 13.2, appSigmaDegrees: 0.1, appSettled: true, appFrames: 30, truthTiltDegrees: 10).disagrees)
        // no sigma: only a settled tilt can raise it
        XCTAssertFalse(KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: nil, appSettled: false, appFrames: 30, truthTiltDegrees: 17.2).disagrees)
        XCTAssertTrue(KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: nil, appSettled: true, appFrames: 30, truthTiltDegrees: 17.2).disagrees)
        // no check without a true tilt, or without enough locked frames
        XCTAssertNil(KitTiltCheck.make(stats: frames(30, tilt: 0.3, sigma: 0.8, settled: true), truthDegrees: nil))
        XCTAssertNil(KitTiltCheck.make(stats: frames(2, tilt: 0.3, sigma: 0.8, settled: true), truthDegrees: 17.2))
        XCTAssertNil(KitTiltCheck.make(stats: frames(30, tilt: 0.3, sigma: 0.8, settled: true, locked: false), truthDegrees: 17.2))
        XCTAssertNil(KitTiltCheck.make(stats: (0..<30).map { KitFrameStat(t: Double($0), slabLocked: true) }, truthDegrees: 17.2))
    }

    func testTiltCheckPrefersTheSettledFrames() throws {
        // the lock's first frames read 8° (unsettled, sigma 6°), then the tilt settles at 0.3° (sigma 0.7°)
        let stats = frames(20, tilt: 8, sigma: 6, settled: false) + frames(12, tilt: 0.3, sigma: 0.7, settled: true)
        let c = try XCTUnwrap(KitTiltCheck.make(stats: stats, truthDegrees: 17.2))
        XCTAssertEqual(c.appTiltDegrees, 0.3, accuracy: 0.06)
        XCTAssertEqual(c.appSigmaDegrees, 0.7)
        XCTAssertTrue(c.appSettled)
        XCTAssertEqual(c.appFrames, 12)
        XCTAssertTrue(c.disagrees)
        // too few settled frames: every locked frame counts
        let few = frames(20, tilt: 8, sigma: 6, settled: false) + frames(2, tilt: 0.3, sigma: 0.7, settled: true)
        let d = try XCTUnwrap(KitTiltCheck.make(stats: few, truthDegrees: 17.2))
        XCTAssertFalse(d.appSettled)
        XCTAssertEqual(d.appFrames, 22)
        XCTAssertEqual(d.appSigmaDegrees, 6)
        XCTAssertFalse(d.disagrees, "9.2° apart against 2 x 6°")
        // the same reading against another true tilt
        XCTAssertEqual(c.against(truthDegrees: 0.5)?.disagrees, false)
        XCTAssertNil(c.against(truthDegrees: nil))
    }

    func testTheStoreKeepsTheTiltCheckAndTheSummaryListsFlaggedShots() throws {
        let store = try kitBeforeTheDrops()
        // the slab left at tilt 2 (10.2°): the app agrees on the hold-still shots... (here the held ball)
        let held = try capture(store, "s09-held-low", at: 50, stats: frames(60, tilt: 10.0, sigma: 0.6, settled: true))
        XCTAssertEqual(held.tiltCheck?.truthTiltDegrees, 10.2)
        XCTAssertEqual(held.tiltCheck?.disagrees, false)
        // ...then the slab is levelled for the drops after their reading of 17.2° (the owner's case)
        try capture(store, "s10-flat", at: 60, flat: twoReading(17.2))
        let d1 = try capture(store, "s10-drop1", at: 70, stats: frames(150, tilt: 0.3, sigma: 0.8, settled: true))
        let check = try XCTUnwrap(d1.tiltCheck)
        XCTAssertTrue(check.disagrees)
        XCTAssertEqual(check.truthTiltDegrees, 17.2)
        XCTAssertEqual(store.record("s10-drop1")?.tiltCheck, check, "kit.json carries it")
        XCTAssertEqual(try store.shotManifest("s10-drop1")?.tiltCheck, check, "shot.json carries it")
        XCTAssertEqual(try KitStore.load(folder: store.folder).record("s10-drop1")?.tiltCheck, check)
        let summary = store.summary()
        XCTAssertEqual(summary.tiltCheckLines.count, 1)
        XCTAssertTrue(summary.tiltCheckLines[0].hasPrefix("Tilt check: s10-drop1: the app read 0.3°, the phone-on-slab reading 17.2°"),
                      summary.tiltCheckLines[0])
        XCTAssertTrue(summary.lines.contains(summary.tiltCheckLines[0]))
        // the hand-off check and the scorer list it too
        let arrival = try XCTUnwrap(KitArrival.check(kitFolder: store.folder))
        XCTAssertTrue(arrival.lines.contains { $0.hasPrefix("note: tilt check: s10-drop1: the app read 0.3°") }, "\(arrival.lines)")
        // no check where the plan expects no slab, for a flat-phone shot, or without a true tilt
        XCTAssertNil(store.tiltCheck(forShot: "s07-ball-3ft", stats: frames(60, tilt: 0.3, sigma: 0.8, settled: true)))
        XCTAssertNil(store.tiltCheck(forShot: "s10-flat", stats: frames(60, tilt: 0.3, sigma: 0.8, settled: true)))
        try store.skipShot("s05-tilt1-flat", date: at(80))
        XCTAssertNil(store.tiltCheck(forShot: "s05-tilt1-still", stats: frames(60, tilt: 0.3, sigma: 0.8, settled: true)))
        // a check made against another true tilt is kept only against the one the shot is committed with
        let folder = try store.beginShot("s10-drop2")
        try Data(repeating: 1, count: 10).write(to: folder.appendingPathComponent(KitClipFiles.motion))
        var m = try store.newShotManifest("s10-drop2", startedAt: at(90), duration: 6)
        m.tiltCheck = KitTiltCheck(appTiltDegrees: 17, appSigmaDegrees: 0.5, appSettled: true, appFrames: 50, truthTiltDegrees: 0)
        let d2 = try store.commitShot("s10-drop2", manifest: m, date: at(96))
        XCTAssertEqual(d2.tiltCheck?.truthTiltDegrees, 17.2)
        XCTAssertEqual(d2.tiltCheck?.disagrees, false)
        // skipping a shot drops its record's check
        try store.skipShot("s10-drop1", date: at(100))
        XCTAssertNil(store.record("s10-drop1")?.tiltCheck)
        XCTAssertTrue(store.summary().tiltCheckLines.isEmpty)
    }

    /// A small standard-v2 synthetic kit through the scorer: the drops' position carries its own reading (the slab left at
    /// tilt 2, where the reading finds it), and a shot flagged on the phone is named in the report's notes.
    func testTheScorerReadsAV2Kit() throws {
        var o = KitSyntheticKit.Options()
        o.plan = .standard
        o.framesPerShot = 6
        o.ballWidth = nil; o.ballHeight = nil
        o.shots = ["s01-measure", "s10-flat", "s12-no-ball"]
        let kit = try KitSyntheticKit.build(root: root, options: o)
        defer { kit.remove() }
        let m = kit.store.manifest
        XCTAssertEqual(m.planId, "standard-v2")
        XCTAssertEqual(m.positions.map { $0.id }, ["p1", "p2", "p3", "p5"])
        XCTAssertEqual(try XCTUnwrap(m.position("p5")?.groundTruth?.tiltDegrees), 10, accuracy: 0.1, "the slab stayed at tilt 2")
        XCTAssertEqual(m.record("s12-no-ball")?.positionId, "p5")
        XCTAssertEqual(kit.truth["s12-no-ball"]?.tiltDegrees, 10)
        // the phone flagged the shot (as if the slab had been levelled after the reading)
        let url = kit.store.shotFolder("s12-no-ball").appendingPathComponent(KitStore.shotManifestFile)
        var sm = try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: url))
        sm.tiltCheck = KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: 0.8, appSettled: true, appFrames: 6, truthTiltDegrees: 10)
        try KitJSON.encode(sm).write(to: url)
        let r = try KitScorer(kitFolder: kit.folder, options: kit.scorerOptions()).score()
        XCTAssertEqual(r.planId, "standard-v2")
        let shot = try XCTUnwrap(r.shot("s12-no-ball"))
        XCTAssertEqual(shot.positionId, "p5")
        XCTAssertEqual(try XCTUnwrap(shot.trueTiltDegrees), 10, accuracy: 0.1)
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("Tilt check on the phone: the app's tilt disagreed with the true tilt on s12-no-ball: the app read 0.3°") },
                      "\(r.notes)")
    }

    // MARK: manifests written before n20k

    /// kit.json and shot.json as n20 (standard-v1) wrote them: no tiltCheck anywhere.
    static let oldKitJSON = """
    {
      "build" : "n20",
      "createdAt" : "2026-01-01T12:00:00Z",
      "device" : { "hasLiDAR" : true, "modelIdentifier" : "iPhone16,1", "systemVersion" : "18.1" },
      "format" : "bouncekit",
      "kitId" : "slab-kit-20260101-120000",
      "measurements" : { "ballDiameterMm" : 35, "dishInches" : 0.125, "slabDepthInches" : 7, "slabThicknessInches" : 1, "slabWidthInches" : 7 },
      "measurementsEnteredAt" : "2026-11-19T17:41:00Z",
      "planId" : "standard-v1",
      "positions" : [
        { "groundTruth" : { "method" : "twoReading", "reasons" : [ "Two readings." ], "tiltDegrees" : 17.2 },
          "id" : "p4", "label" : "tilt 3", "shotId" : "s05-tilt3-flat", "startedAt" : "2026-11-19T17:50:00Z" }
      ],
      "shots" : [
        { "attempts" : 1, "id" : "s10-drop1", "optional" : false, "positionId" : "p4", "status" : "captured", "step" : 10,
          "folder" : "shots/s10-drop1", "verdict" : "good", "duration" : 6.01, "frames" : 360, "bytes" : 5000000,
          "capturedAt" : "2026-11-19T18:00:00Z" },
        { "attempts" : 0, "id" : "s11-drop-edge", "optional" : false, "status" : "pending", "step" : 11 }
      ],
      "updatedAt" : "2026-11-19T18:00:00Z",
      "version" : 1
    }
    """

    static let oldShotJSON = """
    {
      "attempt" : 1, "build" : "n20", "device" : { "hasLiDAR" : true, "modelIdentifier" : "iPhone16,1", "systemVersion" : "18.1" },
      "duration" : 6.01, "format" : "bouncekit-shot", "hasDepth" : true, "kitId" : "slab-kit-20260101-120000",
      "measurements" : { "ballDiameterMm" : 35, "slabDepthInches" : 7, "slabThicknessInches" : 1, "slabWidthInches" : 7 },
      "positionId" : "p4", "releaseCue" : 2, "shotId" : "s10-drop1", "startedAt" : "2026-11-19T17:59:54Z", "step" : 10,
      "trueTilt" : { "method" : "twoReading", "reasons" : [ "Two readings." ], "tiltDegrees" : 17.2 }, "version" : 1
    }
    """

    func testManifestsWithoutATiltCheckStillRead() throws {
        let m = try KitJSON.decode(KitManifest.self, from: Data(KitTiltedDropsTests.oldKitJSON.utf8))
        XCTAssertEqual(m.planId, "standard-v1")
        XCTAssertNil(m.record("s10-drop1")?.tiltCheck)
        XCTAssertEqual(m.position(forShot: "s10-drop1")?.groundTruth?.tiltDegrees, 17.2)
        XCTAssertEqual(KitPlan.named(m.planId), v1)
        let s = try KitJSON.decode(KitShotManifest.self, from: Data(KitTiltedDropsTests.oldShotJSON.utf8))
        XCTAssertNil(s.tiltCheck)
        XCTAssertEqual(s.trueTilt?.tiltDegrees, 17.2)
        // written again, still no tiltCheck key (nil is left out), and back the same
        let again = try KitJSON.encode(m)
        XCTAssertFalse(String(decoding: again, as: UTF8.self).contains("tiltCheck"))
        XCTAssertEqual(try KitJSON.decode(KitManifest.self, from: again), m)
        // a record with a check round-trips
        var withCheck = m
        withCheck.shots[0].tiltCheck = KitTiltCheck(appTiltDegrees: 0.3, appSigmaDegrees: 0.8, appSettled: true, appFrames: 120, truthTiltDegrees: 17.2)
        let data = try KitJSON.encode(withCheck)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"disagrees\" : true"))
        XCTAssertEqual(try KitJSON.decode(KitManifest.self, from: data), withCheck)
    }
}
