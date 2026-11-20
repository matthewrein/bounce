import XCTest
@testable import BounceCore

/// A recording must let a replay run exactly what the phone ran (review #20-#23): the tracker settings the phone used,
/// every frame it processed, what was done to the tracker between frames, the floor, the ball finder's images, and the
/// phone's own results to compare with.
final class ReplayPhoneTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-replay-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func sim() -> AppLoopSim {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var s = AppLoopSim(world: World(slab: slab, lens: .processing))
        s.ball = slab.center + Vec3(0.01, 0.35, -0.005)
        return s
    }

    /// The standard session, run and recorded once for the tests that only replay it.
    static var shared: (folder: URL, run: AppLoopSim.Run)? = nil
    static let sharedFolder = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-replay-shared-\(UUID().uuidString)")
    func standard() throws -> (folder: URL, run: AppLoopSim.Run) {
        if let s = ReplayPhoneTests.shared { return s }
        let folder = ReplayPhoneTests.sharedFolder.appendingPathComponent("s.bouncerec")
        let s = (folder, try sim().run(recordingTo: folder))
        ReplayPhoneTests.shared = s
        return s
    }
    override class func tearDown() {
        try? FileManager.default.removeItem(at: sharedFolder)
        shared = nil
        super.tearDown()
    }

    /// The app's 60 fps loop, recorded every frame, replays to the same result on every frame: the same events at the
    /// same moments, the same lock (time and pose), outlines, readouts, ball and LiDAR fusion, through taps, a settings
    /// change, a reset, a world-frame discontinuity and limited tracking.
    func testAPhoneSessionReplaysExactly() throws {
        let (folder, phone) = try standard()
        let rec = try RecordingReader(folder: folder)
        XCTAssertEqual(rec.session.version, 2)
        XCTAssertEqual(rec.session.everyFrame, true)
        XCTAssertEqual(rec.frames.count, phone.outputs.count, "a line for every processed frame")
        // the session exercised what it should
        let allEvents = phone.outputs.flatMap { $0.events }
        for e in ["tap", "locked", "lock-unconfirmed: interruption", "depth-fused"] { XCTAssertTrue(allEvents.contains(e), "\(e) in \(allEvents)") }
        XCTAssertTrue(rec.frames.contains { $0.controls?.contains { $0.kind == .reset } == true })
        XCTAssertTrue(rec.frames.contains { $0.controls?.contains { $0.kind == .settings && $0.settings?.launchRule == .dishNormal } == true })
        XCTAssertTrue(rec.frames.contains { $0.controls?.contains { $0.kind == .worldDiscontinuity } == true })
        XCTAssertEqual(rec.frames.first?.controls?.first?.kind, .start)
        XCTAssertTrue(rec.frames.contains { $0.tap != nil })
        XCTAssertTrue(rec.frames.contains { $0.floorY == 0 })
        XCTAssertTrue(rec.frames.contains { !$0.trackingNormal })
        XCTAssertGreaterThan(phone.ballFrames, 5)
        XCTAssertTrue(phone.outputs.contains { $0.readouts?.dropFromBall == true }, "the ball was seen")
        XCTAssertEqual(phone.detector.blankCalls, 0, "the app converted the image on every frame the detector ran on")
        // pixels only where needed: fewer images than lines, depth on every locked frame (mostly the part under the top)
        let images = rec.frames.filter { $0.hasImage }.count
        XCTAssertLessThan(images, rec.frames.count / 2)
        let partial = rec.frames.filter { $0.depthFile != nil && ($0.depthIntrinsics?.width ?? 0) < 100 }.count
        XCTAssertGreaterThan(partial, 50)

        let det = CornerCodeDetector(), loc = DiscBallLocator()
        let r = try ReplayRunner(reader: rec).replay(detector: det, ballLocator: loc)
        XCTAssertEqual(r.steps.count, phone.outputs.count)
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertEqual(r.report.compared, rec.frames.count)
        XCTAssertTrue(r.report.substitutionCounts.isEmpty, r.report.description)
        XCTAssertEqual(r.report.notes, [], r.report.description)
        XCTAssertNotNil(r.report.phoneLockTime)
        XCTAssertEqual(r.report.replayLockTime, r.report.phoneLockTime)
        for (st, o) in zip(r.steps, phone.outputs) {
            XCTAssertEqual(st.output.events, o.events, "t \(st.frame.timestamp)")
            XCTAssertEqual(st.output.state, o.state)
        }
        // the replay ran the detector and the ball finder as often as the phone, and ended exactly where it did
        XCTAssertEqual(det.calls, phone.detector.calls)
        XCTAssertEqual(loc.calls, phone.ballLocator.calls, "the ball finder saw the same images with the same intrinsics")
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
        XCTAssertEqual(r.tracker.counts, phone.tracker.counts)
        XCTAssertEqual(r.tracker.settings, phone.tracker.settings)
    }

    /// The old way (#21): a frame every 0.2 s on its own timer, no settings, controls or results. Its replay detects on
    /// other frames than the phone did, so it locks at another time and ends on another pose; and there is nothing to
    /// compare with, which the report says.
    func testAVersion1RecordingCannotReproduceThePhone() throws {
        let folder = tmp.appendingPathComponent("v1.bouncerec")
        var s = sim(); s.version1 = true
        let phone = try s.run(recordingTo: folder)
        let rec = try RecordingReader(folder: folder)
        XCTAssertLessThan(rec.frames.count, phone.outputs.count / 5)
        let r = try ReplayRunner(reader: rec).replay(detector: CornerCodeDetector(), ballLocator: DiscBallLocator())
        let phoneLock = zip(phone.times, phone.outputs).first { $0.1.events.contains("locked") }!.0
        XCTAssertNotEqual(r.report.replayLockTime, phoneLock)
        XCTAssertNotEqual(r.tracker.counts["searches"], phone.tracker.counts["searches"])
        XCTAssertFalse(r.report.agrees)
        XCTAssertEqual(r.report.compared, 0)
        XCTAssertTrue(r.report.notes.contains { $0.contains("only some of the frames") }, "\(r.report.notes)")
        XCTAssertTrue(r.report.notes.contains { $0.contains("nothing to compare") }, "\(r.report.notes)")
    }

    /// When the phone's disk fell behind and pixels were dropped, the replay uses the phone's own detections and ball
    /// results for those frames, stays in step, and says where it did.
    func testMissingPixelsAreReplacedByThePhonesResults() throws {
        let folder = tmp.appendingPathComponent("drop.bouncerec")
        // drop the pixels of every 7th frame (some of them detection and ball frames)
        let phone = try sim().run(recordingTo: folder, dropPixels: Set(stride(from: 3, to: 600, by: 7)))
        let rec = try RecordingReader(folder: folder)
        let r = try ReplayRunner(reader: rec).replay(detector: CornerCodeDetector(), ballLocator: DiscBallLocator())
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertGreaterThanOrEqual(r.report.substitutionCounts["detections"] ?? 0, 3, r.report.description)
        XCTAssertGreaterThan(r.report.substitutionCounts["ball"] ?? 0, 0, r.report.description)
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
    }

    /// The app made a new tracker part-way (the camera restarted), with new detectors: the replay does the same at the same
    /// frame, so a detector that remembers things between frames starts afresh there too (`replay(makeDetector:)`).
    /// Handing the replay one detector for the whole recording would carry its memory across, and the report shows it.
    func testANewTrackerMidRecordingIsReplayedWithNewDetectors() throws {
        let folder = tmp.appendingPathComponent("restart.bouncerec")
        var s = sim()
        s.restartAt = 4.2; s.resetAt = nil; s.discontinuityAt = nil; s.limited = nil; s.ball = nil
        s.makeDetector = { DriftingCodeDetector() }
        let phone = try s.run(recordingTo: folder)
        let rec = try RecordingReader(folder: folder)
        let starts = rec.frames.filter { $0.controls?.contains { $0.kind == .start } == true }
        XCTAssertEqual(starts.count, 2, "the recording's first frame and the restart")
        XCTAssertEqual(starts.last!.controls!.first { $0.kind == .start }!.settings, phone.tracker.settings)
        let r = try ReplayRunner(reader: rec).replay(makeDetector: { DriftingCodeDetector() }, makeBallLocator: { DiscBallLocator() })
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
        let one = try ReplayRunner(reader: rec).replay(detector: DriftingCodeDetector(), ballLocator: DiscBallLocator())
        XCTAssertFalse(one.report.agrees)
        XCTAssertGreaterThanOrEqual(one.steps[one.report.firstDifference!].frame.timestamp, 4.2)
    }

    /// Replaying only the tracker on the phone's own detector outputs (no detector, no images) is exact too.
    func testTheTrackerAloneReplaysFromThePhonesDetections() throws {
        let (folder, phone) = try standard()
        var o = ReplayRunner.Options(); o.detections = .recorded; o.ball = .recorded
        let r = try ReplayRunner(reader: try RecordingReader(folder: folder)).replay(detector: NullSlabDetector(), options: o)
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertTrue(r.report.substitutionCounts.isEmpty, r.report.description)
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
    }

    /// A replay that differs from the phone (here a detector with a different noise draw) is reported: which frame
    /// first, and what.
    func testTheReportSaysWhereTheReplayDiffers() throws {
        let (folder, _) = try standard()
        let rec = try RecordingReader(folder: folder)
        let r = try ReplayRunner(reader: rec).replay(detector: ShiftedCodeDetector(), ballLocator: DiscBallLocator())
        XCTAssertFalse(r.report.agrees)
        let i = try XCTUnwrap(r.report.firstDifference)
        // the first difference is the first frame the detector ran on: its outlines differ
        let firstDetection = rec.frames.firstIndex { $0.output?.detections != nil }!
        XCTAssertEqual(i, firstDetection)
        XCTAssertTrue(r.report.firstDifferences.contains { $0.hasPrefix("detections:") }, "\(r.report.firstDifferences)")
        XCTAssertGreaterThan(r.report.differenceCounts["detections"] ?? 0, 10)
        XCTAssertGreaterThan(r.report.maxTiltDifference, 0.01)
        XCTAssertTrue(r.report.description.contains("first difference at step \(i)"), r.report.description)
    }

    /// The ball finder's image (#22): written exactly, read back exactly, and handed to the ball finder with its own
    /// intrinsics on exactly the frames the phone ran it; a frame with only the crop's place is rebuilt from the frame's
    /// image when asked; otherwise the phone's result stands in.
    func testTheBallFindersImageReachesTheReplayExactly() throws {
        let (folder, phone) = try standard()
        let rec = try RecordingReader(folder: folder)
        let ballFrames = rec.frames.filter { $0.ballFile != nil }
        XCTAssertEqual(ballFrames.count, phone.ballLocator.calls.count)
        XCTAssertGreaterThan(ballFrames.count, 5)
        for f in ballFrames {
            let p = try XCTUnwrap(try rec.ball(for: f))
            let crop = try XCTUnwrap(f.ballCrop)
            XCTAssertGreaterThan(crop.factor, 1, "a shrunk crop, kept exactly")
            XCTAssertEqual(f.ballIntrinsics, crop.intrinsics(full: AppLoopSim(world: sim().world).full))
            XCTAssertEqual(p.width, f.ballIntrinsics!.width); XCTAssertEqual(p.height, f.ballIntrinsics!.height)
            XCTAssertTrue(p.isBlockAverage(of: crop.factor))
        }

        // only the crop's place recorded (no pixels): the phone's results keep the replay exact
        let folder2 = tmp.appendingPathComponent("noball.bouncerec")
        var s2 = sim(); s2.ballPixels = .none
        let phone2 = try s2.run(recordingTo: folder2)
        let rec2 = try RecordingReader(folder: folder2)
        XCTAssertTrue(rec2.frames.allSatisfy { $0.ballFile == nil })
        XCTAssertEqual(rec2.frames.filter { $0.ballIntrinsics != nil && $0.ballCrop != nil }.count, phone2.ballLocator.calls.count)
        // (the slab detector's outlines from the recording: this part is about the ball)
        var o2 = ReplayRunner.Options(); o2.detections = .recorded
        let loc = DiscBallLocator()
        let r = try ReplayRunner(reader: rec2).replay(detector: CornerCodeDetector(), ballLocator: loc, options: o2)
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertEqual(r.report.substitutionCounts["ball"], phone2.ballLocator.calls.count)
        XCTAssertEqual(loc.calls.count, 0)

        // the frame's image kept instead: the replay rebuilds each crop from it, with the crop's size and intrinsics, for
        // the ball finder to run on; its ball lands near the phone's (a coarser image of the same view)
        let folder3 = tmp.appendingPathComponent("frameball.bouncerec")
        var s3 = sim(); s3.ballPixels = .frame; s3.imagesFromFull = true
        let phone3 = try s3.run(recordingTo: folder3)
        let rec3 = try RecordingReader(folder: folder3)
        var o = o2; o.rebuildBallCrops = true
        let loc3 = DiscBallLocator()
        let r3 = try ReplayRunner(reader: rec3).replay(detector: CornerCodeDetector(), ballLocator: loc3, options: o)
        let rebuilt = r3.steps.filter { $0.substitutions.contains("ball: rebuilt from the frame's image") }
        XCTAssertEqual(rebuilt.count, phone3.ballLocator.calls.count, r3.report.description)
        XCTAssertEqual(loc3.calls.count, rebuilt.count)
        for (c, st) in zip(loc3.calls, rebuilt) {
            XCTAssertEqual(c.intrinsics, st.frame.ballIntrinsics)
            XCTAssertEqual(c.width, st.frame.ballIntrinsics!.width); XCTAssertEqual(c.height, st.frame.ballIntrinsics!.height)
        }
        var seen = 0
        for st in rebuilt {
            guard let a = st.phone?.ballCenter, let b = st.output.ball?.center else { continue }
            XCTAssertLessThan(a.distance(to: b), 0.1, "t \(st.frame.timestamp)")
            seen += 1
        }
        XCTAssertGreaterThan(seen, 3)
        // without rebuilding, that recording replays exactly on the phone's ball results
        let r4 = try ReplayRunner(reader: rec3).replay(detector: CornerCodeDetector(), ballLocator: DiscBallLocator(), options: o2)
        XCTAssertTrue(r4.report.agrees, r4.report.description)
    }

    /// Without settings the replay uses the recording's (#33): the phone's exact tracker settings when it has them,
    /// else those the app builds from the owner's settings (launch rule, search interval, sizes, drop height).
    func testReplayWithoutSettingsUsesTheRecordingsSettings() throws {
        // the owner's settings as a build before n12 wrote them: a rebound, no restitution
        var owner = RecordingSettings(sideUInches: 7.2, sideVInches: 6.8, thicknessInches: 1.1, dishInches: 0.2, ballDiameterMm: 40,
                                      dropHeightFeet: 2.5, reboundPercent: 60, dishBounce: true, restitution: nil, tangential: nil)
        let folder = tmp.appendingPathComponent("v1.bouncerec")
        let w = try RecordingWriter(folder: folder, session: RecordingSession(build: "t", device: "d", frameWidth: 8, frameHeight: 6, settings: owner))
        let K = CameraIntrinsics(fx: 8, fy: 8, cx: 4, cy: 3, width: 8, height: 6)
        try w.append(RecordedFrame(index: 0, timestamp: 0, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K),
                     image: CornerCodeImage.make(width: 8, height: 6, outline: nil, salt: 0))
        w.close()
        let (_, tr) = try ReplayRunner(reader: try RecordingReader(folder: folder)).run(detector: NullSlabDetector())
        XCTAssertEqual(tr.settings.spec, owner.slab)
        XCTAssertEqual(tr.settings.ball, owner.ball)
        XCTAssertEqual(tr.settings.ball, BallSpec(diameter: 0.04, rebound: 0.6))
        XCTAssertEqual(tr.settings.defaultDropHeight, Units.feet(2.5), accuracy: 1e-12)
        XCTAssertEqual(tr.settings.launchRule, .dishNormal)
        XCTAssertEqual(tr.settings.searchInterval, RecordingSettings.appSearchInterval)
        XCTAssertEqual(tr.settings, owner.trackerSettings)
        // a version 1 session.json (no dishBounce, no restitution, no tracker) still reads, with the corner-plane rule
        owner.dishBounce = nil
        XCTAssertEqual(owner.trackerSettings.launchRule, .cornerPlane)
        // one with a restitution (n12 on) bounces by the impact rule, with the rebound it writes the restitution's square
        var n12 = owner
        n12.restitution = 0.75
        XCTAssertEqual(n12.trackerSettings.launchRule, .impact)
        XCTAssertEqual(n12.ball, BallSpec(diameter: 0.04, restitution: 0.75, tangential: BallSpec.ownerTangential))

        // the phone's exact settings win
        var exact = owner.trackerSettings
        exact.recheckInterval = 0.25; exact.matchSigmas = 2.5; exact.cradleRadius = nil
        let folder2 = tmp.appendingPathComponent("v2.bouncerec")
        let w2 = try RecordingWriter(folder: folder2, session: RecordingSession(build: "t", device: "d", frameWidth: 8, frameHeight: 6,
                                                                                settings: owner, tracker: exact, everyFrame: true))
        try w2.append(RecordedFrame(index: 0, timestamp: 0, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K), image: nil)
        w2.close()
        let (_, tr2) = try ReplayRunner(reader: try RecordingReader(folder: folder2)).run(detector: NullSlabDetector())
        XCTAssertEqual(tr2.settings, exact)
        XCTAssertNil(tr2.settings.cradleRadius)
    }

    /// The slab finder a replay runs gets the recording's tracker settings for its sweep (`SlabDetecting.apply`: the app's
    /// sweepSkipsFinds and sweepSameOutlinePixels), at the start and at each settings change, as the phone's finder did:
    /// the replay's wrapper passes them on.
    func testTheReplaysSlabFinderGetsTheRecordingsSweepSettings() throws {
        let app = RecordingSettings().trackerSettings
        let phone = SlabFinderDetector(), inReplay = SlabFinderDetector()
        _ = SlabTracker(settings: app, detector: phone)
        _ = SlabTracker(settings: app, detector: ReplaySlabDetector(inReplay))
        XCTAssertTrue(phone.finder.options.skipSeedsInFinds)
        XCTAssertEqual(inReplay.finder.options.maxSweepRegions, phone.finder.options.maxSweepRegions)
        XCTAssertEqual(inReplay.finder.options.skipSeedsInFinds, phone.finder.options.skipSeedsInFinds)
        XCTAssertEqual(inReplay.finder.options.sameOutlinePixels, phone.finder.options.sameOutlinePixels)

        // a whole replay: a recording made with the app's settings, then a settings change that turns the sweep's options off
        final class Spy: SlabDetecting {
            let inner = SlabFinderDetector()
            private(set) var applied: [TrackerSettings] = []
            func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] { [] }
            func apply(_ settings: TrackerSettings) { applied.append(settings); inner.apply(settings) }
        }
        var off = app
        off.sweepSkipsFinds = false; off.sweepSameOutlinePixels = 0
        let K = CameraIntrinsics(fx: 8, fy: 8, cx: 4, cy: 3, width: 8, height: 6)
        let folder = tmp.appendingPathComponent("sweep.bouncerec")
        let w = try RecordingWriter(folder: folder, session: RecordingSession(build: "t", device: "d", frameWidth: 8, frameHeight: 6, settings: RecordingSettings(),
                                                                              tracker: app, everyFrame: true, trackerStateAtStart: .searching))
        var f0 = RecordedFrame(index: 0, timestamp: 0, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K)
        f0.controls = [TrackerControl(kind: .start, settings: app)]
        try w.append(f0, image: nil)
        var f1 = RecordedFrame(index: 1, timestamp: 1.0 / 60, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K)
        f1.controls = [TrackerControl(kind: .settings, settings: off)]
        try w.append(f1, image: nil)
        w.close()
        let spy = Spy()
        _ = try ReplayRunner(reader: try RecordingReader(folder: folder)).replay(makeDetector: { spy })
        XCTAssertEqual(spy.applied.first, app, "the recording's settings at the start")
        XCTAssertEqual(spy.applied.last, off, "and the settings change")
        XCTAssertFalse(spy.inner.finder.options.skipSeedsInFinds)
        XCTAssertEqual(spy.inner.finder.options.sameOutlinePixels, 0)
    }

    /// A ball finder that holds half an outline for its next scan to confirm (as BallLocator does with a partial disc):
    /// the phone's idle ball rate reads that after each scan (`BallLocating.awaitsConfirmation`) and scans again at the
    /// usual rate; the recording keeps it (`RecordedOutput.ballAwaitsConfirmation`), and a replay follows the same rate,
    /// running the finder (the replay's wrapper passes the flag on) or using the phone's results (the recorded flag).
    func testTheBallFindersWaitForASecondScanReplaysExactly() throws {
        final class TwoScanDisc: BallLocating {
            let inner = DiscBallLocator()
            private var pending = false, confirmed = false
            var awaitsConfirmation: Bool { pending }
            func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
                guard let r = inner.locate(image: image, intrinsics: intrinsics, slab: slab, spec: spec, ball: ball, down: down) else {
                    pending = false; confirmed = false; return nil
                }
                if confirmed { return r }
                if pending { pending = false; confirmed = true; return r }
                pending = true
                return nil
            }
            func reset() { pending = false; confirmed = false; inner.reset() }
        }
        var s = sim()
        s.ballFrom = 3.0; s.duration = 5
        s.tapAt = nil; s.settingsAt = nil; s.resetAt = nil; s.discontinuityAt = nil; s.limited = nil
        s.ballLocator = TwoScanDisc()
        XCTAssertGreaterThan(RecordingSettings().trackerSettings.idleBallAfter, 0, "the app's idle ball rate is on")
        let folder = tmp.appendingPathComponent("twoscan.bouncerec")
        let phone = try s.run(recordingTo: folder)
        // the phone: empty scans every 0.3 s before the ball, then the half outline, and its confirmation 0.1 s later
        let waits = try XCTUnwrap(phone.outputs.firstIndex { $0.ballAwaitsConfirmation })
        let scans = phone.outputs.indices.filter { phone.outputs[$0].ballSearched }
        let k = try XCTUnwrap(scans.firstIndex(of: waits))
        XCTAssertGreaterThan(k, 1)
        XCTAssertEqual(phone.times[scans[k]] - phone.times[scans[k - 1]], 0.3, accuracy: 0.03, "idle before the ball")
        XCTAssertEqual(phone.times[scans[k + 1]] - phone.times[scans[k]], 0.1, accuracy: 0.02, "the usual rate while it waits")
        // confirmed on the next scan: the finder reports it there; the ball gate (n15) shows it from its third find, and the
        // recording keeps what it held back, so a replay with the phone's results gates them as the phone did
        XCTAssertNotNil(phone.outputs[scans[k + 1]].ballFound, "confirmed on the next scan")
        XCTAssertNil(phone.outputs[scans[k + 1]].ball, "held back by the gate")
        XCTAssertEqual(phone.outputs[scans[k + 3]].ballGateVerdict, .accepted)
        XCTAssertNotNil(phone.outputs[scans[k + 3]].ball, "shown on the gate's third find")
        let rec = try RecordingReader(folder: folder)
        XCTAssertEqual(rec.frames[waits].output?.ballAwaitsConfirmation, true, "the recording keeps it")
        XCTAssertNil(rec.frames[scans[k - 1]].output?.ballAwaitsConfirmation)
        XCTAssertNotNil(rec.frames[scans[k + 1]].output?.ballFound, "the recording keeps what the gate held back")

        let run = try ReplayRunner(reader: rec).replay(detector: CornerCodeDetector(), ballLocator: TwoScanDisc())
        XCTAssertTrue(run.report.agrees, run.report.description)
        var o = ReplayRunner.Options(); o.ball = .recorded; o.detections = .recorded
        let recorded = try ReplayRunner(reader: rec).replay(detector: NullSlabDetector(), ballLocator: TwoScanDisc(), options: o)
        XCTAssertTrue(recorded.report.agrees, recorded.report.description)
    }
}

/// CornerCodeDetector with every corner moved half a pixel: a different detector, for the divergence report.
final class ShiftedCodeDetector: SlabDetecting {
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        CornerCodeImage.decode(frame).map { q in
            [DetectedOutline(quad: q.enumerated().map { $0.element + Vec2($0.offset % 2 == 0 ? 0.5 : -0.5, 0.4) }, sideModes: ["top", "top", "top", "top"])]
        } ?? []
    }
}
