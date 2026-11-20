import XCTest
@testable import BounceCore

/// The recording format's version 2 additions, reading version 1, and failing cleanly on IO errors (review #20-#23, #32).
final class RecordingFormatTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-format-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    // MARK: settings

    /// Every stored property of TrackerSettings and ShapeCheck.Limits is written (a new setting must be added to the coding
    /// list, or recordings would silently replay with its default), read back exactly, and missing keys keep defaults.
    func testTrackerSettingsAreCodedCompletely() throws {
        let props = Set(Mirror(reflecting: TrackerSettings()).children.compactMap { $0.label })
        XCTAssertEqual(Set(TrackerSettings.codingFields.map { $0.key }), props)
        XCTAssertEqual(TrackerSettings.codingFields.count, props.count)
        let lprops = Set(Mirror(reflecting: ShapeCheck.Limits()).children.compactMap { $0.label })
        XCTAssertEqual(Set(ShapeCheck.Limits.codingFields.map { $0.key }), lprops)
        let sprops = Set(Mirror(reflecting: SettleSettings()).children.compactMap { $0.label })
        XCTAssertEqual(Set(SettleSettings.codingFields.map { $0.key }), sprops)
        // every settling constant survives a round trip, and a file without them keeps the defaults
        var st = SettleSettings()
        st.parallelFloorRadians = 1e-4; st.turnFloorRadians = 3e-4; st.blurShare = 0.3; st.defaultExposure = 0.02; st.groupDegrees = 6
        st.perGroup = 4; st.misfitChi2 = 13.8; st.settleDegrees = 0.8; st.unsettleDegrees = 1.1; st.settleRefreshes = 3; st.holdShown = true
        for c in Mirror(reflecting: st).children {
            let d = Mirror(reflecting: SettleSettings()).children.first { $0.label == c.label }!
            XCTAssertNotEqual(String(describing: c.value), String(describing: d.value), "test changes settle.\(c.label!)")
        }
        XCTAssertEqual(try JSONDecoder().decode(SettleSettings.self, from: JSONEncoder().encode(st)), st)
        XCTAssertEqual(try JSONDecoder().decode(SettleSettings.self, from: Data("{}".utf8)), SettleSettings())

        // every field changed from its default survives a round trip
        var s = TrackerSettings()
        s.spec = SlabSpec(sideU: 0.18, sideV: 0.17, thickness: 0.03, dishDepth: 0.004); s.ball = BallSpec(diameter: 0.04, rebound: 0.6)
        s.defaultDropHeight = 0.7; s.launchRule = .dishNormal; s.recheckInterval = 0.25; s.searchInterval = 0.12; s.minDetectionGap = 0.05; s.confirmCount = 4
        s.matchDistance = 0.02; s.matchAngleDegrees = 3; s.moveCount = 5; s.lostAfter = 3; s.historySize = 12; s.depthNormalWeight = 0.3
        s.depthCentreWeight = 0.35
        s.settle.groupDegrees = 6; s.settle.settleDegrees = 0.9; s.readoutsFromSettledNormal = true; s.lockKeepsNewestPerView = true
        s.ballInterval = 0.15; s.shapeLimits.maxMisfitFraction = 0.04; s.shapeLimits.maxNormalSigmaDegrees = nil; s.shapeLimits.minDistance = 0.3
        s.shapeLimits.maxDistance = 2.5; s.shapeLimits.maxTiltDegrees = 20
        s.cornerNoisePixels = 0.8; s.matchSigmas = 2.5; s.maxMatchDistance = 0.07; s.maxMatchAngleDegrees = 9; s.maxLockSigmaDegrees = 1.2
        s.slideWindow = 5; s.slideSigmas = 4; s.moveRadius = 0.25; s.cradleRadius = nil; s.cutFlipTolerancePixels = 2.5; s.minMissesForLost = 4
        s.topRelockCount = 3; s.topRelockSeconds = 2.5
        s.unconfirmedTimeout = 4; s.poseJumpDistance = 0.3; s.limitedResumeSeconds = 1.5; s.seedTimeout = 5; s.depthSmoothingSeconds = 0.4
        s.depthHoldSeconds = 0.8; s.depthMinInlierFraction = 0.6; s.depthMaxOffsetFraction = 0.03; s.depthMaxAngleDegrees = 7
        s.sideEvidenceCap = 3; s.sideEvidenceDecay = 0.9; s.sideFlipMargin = 0.2; s.sideDecidedEvidence = 2
        s.maxSweepRegions = 30; s.sweepSkipsFinds = true; s.sweepSameOutlinePixels = 1.2
        s.idleSearchAfter = 0.8; s.idleSearchInterval = 0.4; s.idleSearchMoveDegrees = 3; s.idleSearchMoveDistance = 0.05
        s.idleBallAfter = 0.4; s.idleBallInterval = 0.25
        var gate = BallGateSettings(); gate.sightings = 4; gate.acrossMetres = 0.008; gate.lidarSurfaceMetres = nil
        s.ballGate = gate
        s.tapHints = true; s.tapSlackFraction = 0.04; s.tapBallSeconds = 1.5; s.tapDismissSeconds = 15; s.tapDismissMax = 3; s.tapSlabFirstSeconds = 0.8
        s.tapSetsBall = true; s.tapAcceptSeconds = 0.25; s.tapSetMaxHeight = 2.5
        for c in Mirror(reflecting: s).children where c.label != "shapeLimits" {
            let d = Mirror(reflecting: TrackerSettings()).children.first { $0.label == c.label }!
            XCTAssertNotEqual(String(describing: c.value), String(describing: d.value), "test changes \(c.label!)")
        }
        let back = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertNil(back.cradleRadius)
        XCTAssertEqual(back.ballGate, gate)
        XCTAssertNil(back.ballGate?.lidarSurfaceMetres)
        // a file from an older build (fields missing) keeps the defaults
        XCTAssertEqual(try JSONDecoder().decode(TrackerSettings.self, from: Data("{}".utf8)), TrackerSettings())
        let partial = try JSONDecoder().decode(TrackerSettings.self, from: Data(#"{"searchInterval": 0.12, "shapeLimits": {"maxTiltDegrees": 20}}"#.utf8))
        XCTAssertEqual(partial.searchInterval, 0.12)
        XCTAssertEqual(partial.shapeLimits.maxTiltDegrees, 20)
        XCTAssertEqual(partial.shapeLimits.maxNormalSigmaDegrees, ShapeCheck.Limits().maxNormalSigmaDegrees)
        XCTAssertEqual(partial.cradleRadius, TrackerSettings().cradleRadius)
    }

    // MARK: version 1

    /// Recordings in the first format (no tracker settings, no dish bounce, frames without controls or results) still read.
    func testVersion1RecordingsStillRead() throws {
        let rec = try Fixtures.recording("rec_replay_still")
        XCTAssertEqual(rec.session.version, 1)
        XCTAssertNil(rec.session.tracker)
        XCTAssertNil(rec.session.settings.dishBounce)
        XCTAssertNil(rec.session.everyFrame)
        XCTAssertEqual(rec.skippedLines, 0)
        XCTAssertTrue(rec.frames.allSatisfy { $0.hasImage && $0.output == nil && $0.controls == nil && $0.tap == nil && $0.ballFile == nil })

        // a hand-written version 1 folder with exactly the old keys
        let folder = tmp.appendingPathComponent("old.bouncerec")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"format":"bouncerec","version":1,"build":"n1","device":"iPhone15,2","frameWidth":8,"frameHeight":4,"settings":{"sideUInches":7,"sideVInches":7,"thicknessInches":1,"dishInches":0.125,"ballDiameterMm":35,"dropHeightFeet":3,"reboundPercent":70}}"#.utf8)
            .write(to: folder.appendingPathComponent("session.json"))
        try Data(#"""
            {"index":0,"timestamp":12.5,"file":"f000000.byc","worldFromCamera":[1,0,0,0,0,1,0,0,0,0,1,0,0,1,0,1],"intrinsics":{"fx":6,"fy":6,"cx":4,"cy":2,"width":8,"height":4},"trackingNormal":true,"locked":false}

            """#.utf8)
            .write(to: folder.appendingPathComponent("frames.jsonl"))
        try YCCImage(width: 8, height: 4, y: [UInt8](repeating: 9, count: 32), cb: [UInt8](repeating: 128, count: 8), cr: [UInt8](repeating: 128, count: 8))
            .data.write(to: folder.appendingPathComponent("f000000.byc"))
        let old = try RecordingReader(folder: folder)
        XCTAssertEqual(old.session.version, 1)
        XCTAssertEqual(old.frames.count, 1)
        XCTAssertEqual(old.frames[0].timestamp, 12.5)
        XCTAssertEqual(try old.image(for: old.frames[0]).y[0], 9)
        XCTAssertNil(try old.ball(for: old.frames[0]))
        let (steps, tracker) = try ReplayRunner(reader: old).run(detector: NullSlabDetector())
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(tracker.settings, old.session.settings.trackerSettings)
    }

    // MARK: version 2

    /// Every new field of a frame survives the writer and reader, non-finite readouts included.
    func testVersion2FrameFieldsRoundTrip() throws {
        let folder = tmp.appendingPathComponent("v2.bouncerec")
        var ts = TrackerSettings(); ts.searchInterval = 0.12
        let session = RecordingSession(build: "t", device: "d", frameWidth: 8, frameHeight: 6, settings: RecordingSettings(dishBounce: true),
                                       tracker: ts, everyFrame: true, trackerStateAtStart: .locked)
        let w = try RecordingWriter(folder: folder, session: session)
        let K = CameraIntrinsics(fx: 8, fy: 8, cx: 4, cy: 3, width: 8, height: 6)
        let world = World.slabAt(Vec3(0, 0.066, -1), tilt: 5, heading: 20)
        var f = RecordedFrame(index: 7, timestamp: 3.25, file: "x", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K)
        f.tap = [3.5, 2.25]; f.floorY = -0.02
        f.controls = [TrackerControl(kind: .start, settings: ts), TrackerControl(kind: .settings, settings: TrackerSettings()),
                      TrackerControl(kind: .reset), TrackerControl(kind: .worldDiscontinuity, reason: "interruption")]
        var out = RecordedOutput(state: .locked)
        out.events = ["locked", "depth-fused"]; out.slab = world
        out.outline = [[1, 2], [3, 4], [5, 6], [7, 8]]; out.measurement = out.outline
        out.readouts = Readouts(tiltDegrees: 5, apexHeight: 0.4, landingDistance: 0.3, airTime: .infinity, dropHeight: 0.9, dropFromBall: true)
        out.detections = [DetectedOutline(quad: [Vec2(1, 2), Vec2(3, 4), Vec2(5, 6), Vec2(7, 8)], score: 0.5, sideModes: ["top", "fromCutBottom", "top", "top"]),
                          DetectedOutline(quad: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)])]
        out.ballSearched = true; out.ball = [0.1, 0.4, -0.9, 30.5, 12.25, 6]; out.depthFused = true; out.lockUnconfirmed = true
        out.ballAwaitsConfirmation = true
        f.output = out
        let crop = BallImageCrop(x0: 10, y0: 4, width: 40, height: 30, factor: 2)
        f.ballCrop = crop; f.ballIntrinsics = crop.intrinsics(full: K.scaled(by: 4))
        let ball = Plane(width: 20, height: 15, data: (0..<300).map { Float($0 % 7) * 0.25 + 60 })
        try w.append(f, image: nil, depth: DepthMap(width: 2, height: 1, depth: [1, 2], confidence: [2, 2]), ball: ball)
        try w.append(f, image: YCCImage(width: 8, height: 6, y: [UInt8](repeating: 1, count: 48), cb: [UInt8](repeating: 128, count: 12),
                                        cr: [UInt8](repeating: 128, count: 12)))
        w.close()
        let r = try RecordingReader(folder: folder)
        XCTAssertEqual(r.session, session)
        XCTAssertEqual(r.session.settings.launchRule, .dishNormal)
        XCTAssertEqual(r.frames.count, 2)
        let a = r.frames[0], b = r.frames[1]
        XCTAssertFalse(a.hasImage); XCTAssertEqual(a.file, ""); XCTAssertTrue(b.hasImage)
        XCTAssertThrowsError(try r.image(for: a)) { XCTAssertEqual($0 as? RecordingError, .noImage(0)) }
        XCTAssertEqual(a.tapPoint, Vec2(3.5, 2.25))
        XCTAssertEqual(a.floorY, -0.02)
        XCTAssertEqual(a.controls, f.controls)
        XCTAssertEqual(a.output, out)
        XCTAssertEqual(a.output?.readouts?.airTime, .infinity)
        XCTAssertEqual(a.output?.tiltDegrees, 5)
        XCTAssertEqual(a.output?.ballCenter, Vec3(0.1, 0.4, -0.9))
        XCTAssertEqual(a.ballCrop, crop); XCTAssertEqual(a.ballIntrinsics, f.ballIntrinsics)
        XCTAssertEqual(try r.ball(for: a), ball, "kept exactly")
        XCTAssertNil(b.ballFile)
        XCTAssertEqual(try r.depth(for: a)?.depth, [1, 2])
        XCTAssertNil(b.depthFile); XCTAssertNil(b.depthIntrinsics)
        // the session file is readable by eye
        let js = try String(contentsOf: folder.appendingPathComponent("session.json"), encoding: .utf8)
        XCTAssertTrue(js.contains("\"searchInterval\" : 0.12"), js)
    }

    /// A frame's record built from the tracker's own frame and output: the camera comes back exactly, with its inputs and
    /// result.
    func testARecordedFrameHoldsTheTrackersInputsAndResult() throws {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 8)
        let tr = SlabTracker(settings: TrackerSettings(), detector: det)
        let v = w.view(from: Vec3(0.05, 0.9, 0.02), at: slab.center)
        det.currentView = v
        tr.reset()
        let tf = TrackerFrame(timestamp: 1.5, view: v, frame: ColorFrame(gray: Plane(width: 4, height: 4)), tap: Vec2(200, 150), floorY: 0.01,
                              trackingNormal: true)
        let out = tr.process(tf)
        let rf = RecordedFrame(processed: tf, output: out)
        XCTAssertEqual(rf.view, v, "ARKit's transform round-trips exactly")
        XCTAssertEqual(rf.timestamp, 1.5)
        XCTAssertEqual(rf.tapPoint, Vec2(200, 150))
        XCTAssertEqual(rf.floorY, 0.01)
        XCTAssertEqual(rf.controls?.map { $0.kind }, [.start, .reset])
        XCTAssertEqual(rf.output?.state, out.state)
        XCTAssertEqual(rf.output?.events, out.events)
        XCTAssertEqual(rf.output?.detections?.count, 1, "the detector ran on the tap")
        XCTAssertLessThan(angleDeg(Vec3(rf.gravityCamera!), v.directionToCamera(ARKitConvention.worldDown)), 1e-9)
    }

    // MARK: ball images

    /// A shrunk crop is kept exactly: its block sums as 16-bit samples, read back to the very same Float values; plain
    /// 8-bit images are unchanged.
    func testBallImagesAreKeptExactly() throws {
        var rng = SeededRandom(5)
        let full = (0..<(60 * 45)).map { _ in UInt8(rng.uniform(0, 255.99)) }
        let fullPlane = Plane(bytes: full, width: 60, height: 45)
        for k in 1...4 {
            let p = fullPlane.downscaled(by: k)
            XCTAssertTrue(p.isBlockAverage(of: k))
            let d = p.pgmData(blockSum: k)
            let header = "P5\n\(p.width) \(p.height)\n\(255 * k * k)\n"
            XCTAssertEqual(String(decoding: d.prefix(header.utf8.count), as: UTF8.self), header)
            XCTAssertEqual(d.count, header.utf8.count + p.width * p.height * (k == 1 ? 1 : 2), "8-bit samples for k = 1, else 16-bit")
            let back = try XCTUnwrap(Plane(pgm: d))
            XCTAssertEqual(back, p, "k \(k)")
        }
        // a plane that is not a block average is rounded to the nearest 1/k^2
        let odd = Plane(width: 2, height: 1, data: [10.1, 200.6])
        XCTAssertFalse(odd.isBlockAverage(of: 2))
        let r = try XCTUnwrap(Plane(pgm: odd.pgmData(blockSum: 2)))
        XCTAssertEqual(r.data[0], 10, accuracy: 0.125); XCTAssertEqual(r.data[1], 200.5, accuracy: 0.125)
        // the 8-bit option rounds to whole grey levels (half the size)
        let folder = tmp.appendingPathComponent("b8.bouncerec")
        let w = try RecordingWriter(folder: folder, session: RecordingSession(build: "t", device: "d", frameWidth: 4, frameHeight: 2, settings: RecordingSettings()))
        w.exactBallImages = false
        var f = RecordedFrame(index: 0, timestamp: 0, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4,
                              intrinsics: CameraIntrinsics(fx: 3, fy: 3, cx: 2, cy: 1, width: 4, height: 2))
        f.ballIntrinsics = f.intrinsics
        let half = fullPlane.downscaled(by: 2)
        try w.append(f, image: nil, ball: half)
        w.close()
        let back = try XCTUnwrap(try RecordingReader(folder: folder).ball(for: try RecordingReader(folder: folder).frames[0]))
        XCTAssertEqual(back.data, half.data.map { $0.rounded() })
    }

    /// The approximate rebuild of a crop from a smaller image of the same camera samples it where the crop's pixels lie.
    func testResamplingFindsTheSameViewAtAnotherScale() {
        let full = CameraIntrinsics(fx: 725, fy: 725, cx: 480, cy: 360, width: 960, height: 720)
        // a smooth image: luma = x / 4 + y / 8 in full-image pixels
        let small = full.scaled(by: 1.0 / 3)
        var d = [Float](repeating: 0, count: small.width * small.height)
        for y in 0..<small.height { for x in 0..<small.width { d[y * small.width + x] = Float((Double(x) + 0.5) * 3 / 4 + (Double(y) + 0.5) * 3 / 8) } }
        let p = Plane(width: small.width, height: small.height, data: d)
        let crop = BallImageCrop(x0: 300, y0: 120, width: 200, height: 160, factor: 2)
        let K = crop.intrinsics(full: full)
        let r = p.resampled(from: small, to: K)
        XCTAssertEqual(r.width, 100); XCTAssertEqual(r.height, 80)
        for (x, y) in [(5, 5), (50, 40), (90, 70)] {
            let F = crop.toFull(Vec2(Double(x) + 0.5, Double(y) + 0.5))
            XCTAssertEqual(Double(r[x, y]), F.x / 4 + F.y / 8, accuracy: 0.01)
        }
    }

    /// The crop the app gives the ball finder (#33): its intrinsics put a world point at (full - x0) / k, and a k x k
    /// block average of the full image shows a feature exactly there (pixel centres at (j + 0.5) k).
    func testBallCropPlanAndItsIntrinsics() throws {
        let full = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let slab = World.slabAt(Vec3(0, 0.066, -1.2), tilt: 6, heading: 30)
        var w = World(slab: slab); w.intrinsics = full
        let v = w.view(from: Vec3(0, 0.95, 0), at: slab.center)
        // (a smaller bound than the app's, so that the crop is shrunk)
        let c = try XCTUnwrap(BallImageCrop.plan(slab: slab, full: v, maxSide: 500))
        XCTAssertLessThanOrEqual((c.width / c.factor) * (c.height / c.factor), 500 * 500)
        XCTAssertGreaterThan(c.factor, 1)
        XCTAssertGreaterThanOrEqual(c.x0, 0); XCTAssertLessThanOrEqual(c.x0 + c.width, full.width)
        let K = c.intrinsics(full: full)
        XCTAssertEqual(K.width, c.width / c.factor)
        // the slab's corners and a ball 0.5 m above it are inside the crop
        for p in slab.topCorners + [slab.center + Vec3(0, 0.5, 0)] {
            let q = K.project(v.toCamera(p))!, F = full.project(v.toCamera(p))!
            XCTAssertTrue(K.contains(q), "\(q)")
            XCTAssertEqual(q.x, (F.x - Double(c.x0)) / Double(c.factor), accuracy: 1e-9)
            XCTAssertEqual(q.y, (F.y - Double(c.y0)) / Double(c.factor), accuracy: 1e-9)
            XCTAssertEqual(c.toFull(q).x, F.x, accuracy: 1e-9)
        }
        // a bright 6x6 square at full pixels [600, 606) x [400, 406), cropped from (300, 200) and shrunk by 3: its centre
        // (603, 403) lands at ((603 - 300) / 3, (403 - 200) / 3) = (101, 67.667) in the crop
        var img = Plane(width: 900, height: 600, fill: 10)
        for y in 400..<406 { for x in 600..<606 { img[x, y] = 250 } }
        let cr = img.cropped(x0: 300, y0: 200, width: 600, height: 400).downscaled(by: 3)
        var sx = 0.0, sy = 0.0, s = 0.0
        for y in 0..<cr.height { for x in 0..<cr.width { let m = Double(cr[x, y] - 10); sx += (Double(x) + 0.5) * m; sy += (Double(y) + 0.5) * m; s += m } }
        let K2 = CameraIntrinsics(fx: 1000, fy: 1000, cx: 450, cy: 300, width: 900, height: 600).cropped(x0: 300, y0: 200, scale: 1.0 / 3, width: 200, height: 133)
        let want = K2.project(Vec3((603 - 450) / 1000.0, (403 - 300) / 1000.0, 1))!
        XCTAssertEqual(sx / s, want.x, accuracy: 1e-6); XCTAssertEqual(sy / s, want.y, accuracy: 1e-6)
    }

    /// A phone held less than `reach` (1.2 m) over the slab has the points straight above the slab's corners behind it:
    /// the crop still takes in the space above the slab. (It shrank to the slab when all four were behind the camera,
    /// and cut off a ball held over it: the demo's 2.6 s without the ball, its camera 0.6 m above the slab.) Over the
    /// demo's 6 s, and from 0.45-0.6 m at 30-60 degrees with the ball 10-60 cm over the slab, the ball's whole outline
    /// is inside the crop wherever it is inside the camera's picture.
    func testBallCropTakesInTheSpaceAboveTheSlabFromClose() throws {
        var d = DemoScript(); d.ballHeight = 0.30
        var behind = 0
        for i in 0..<75 {
            let t = Double(i) * 0.08, v = d.view(at: t), s = d.scene(at: t)
            if s.slab.topCorners.allSatisfy({ v.toCamera($0 + Vec3(0, 1.2, 0)).z <= 0.02 }) { behind += 1 }
            let c = try XCTUnwrap(BallImageCrop.plan(slab: s.slab, full: v))
            let K = c.intrinsics(full: v.intrinsics)
            let B = v.toCamera(s.ball!), p = K.project(B)!, r = Bounce.imageRadius(ballCenter: B, intrinsics: K, ball: BallSpec())!
            XCTAssertTrue(p.x >= r && p.y >= r && p.x + r <= Double(K.width) && p.y + r <= Double(K.height), String(format: "t %.2f: ball at (%.0f, %.0f) r %.1f, crop %dx%d", t, p.x, p.y, r, K.width, K.height))
        }
        XCTAssertGreaterThan(behind, 20, "the demo's camera is that close for much of its run")
        let full = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let slab = SyntheticScene.slabPose(tilt: 8, heading: 30), up = Vec3(0, 1, 0), R = BallSpec().radius
        var poses = 0, closeOnes = 0
        for dist in [0.45, 0.6] {
            for el in [30.0, 45, 60] {
                for az in [0.0, 70, 140] {
                    for h in [0.1, 0.3, 0.6] {
                        let a = Units.radians(az), e = Units.radians(el), aim = slab.center + up * (0.4 * h)
                        let v = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * dist, lookingAt: aim, intrinsics: full)
                        let B = v.toCamera(slab.center + up * (h + R))
                        guard slab.topCorners.allSatisfy({ v.project(world: $0).map { full.contains($0) } ?? false }),
                              let pf = full.project(B), let rf = Bounce.imageRadius(ballCenter: B, intrinsics: full, ball: BallSpec()),
                              pf.x >= rf, pf.y >= rf, pf.x + rf <= 1920, pf.y + rf <= 1440 else { continue }
                        poses += 1
                        if slab.topCorners.allSatisfy({ v.toCamera($0 + up * 1.2).z <= 0.02 }) { closeOnes += 1 }
                        let c = try XCTUnwrap(BallImageCrop.plan(slab: slab, full: v))
                        let K = c.intrinsics(full: full)
                        let p = K.project(B)!, r = rf / Double(c.factor)
                        XCTAssertTrue(p.x >= r && p.y >= r && p.x + r <= Double(K.width) && p.y + r <= Double(K.height),
                                      String(format: "%.2f m at %.0f deg, azimuth %.0f, ball %.1f m up", dist, el, az, h))
                    }
                }
            }
        }
        XCTAssertGreaterThan(closeOnes, 5)
        print("ball crop from close: \(behind) of 75 demo frames and \(closeOnes) of \(poses) poses with every point above the corners behind the camera")
    }

    /// The crop keeps the ball large from close as well: for the phone's 1920 x 1440 camera, 0.45-1.2 m from a point over
    /// a slab tilted 10 degrees, 35-75 degrees up, with a ball 5-90 cm over the slab in the picture, the ball's whole
    /// outline is in the crop, the crop is shrunk by 1 or 2 (never 3: its pixels are bounded, not its longer side), and
    /// by no more than the crop each earlier plan made where that held the ball, except where the earlier one stopped at
    /// the slab because the points above its corners were behind the camera (4766aba: dropped; then the crop took in
    /// only the slab and a ball held low over it, and cut off one held higher). (e74b53e cut those lines 2 cm from the
    /// camera's plane, which ran the crop to the full width and shrank it by 3 in most of these poses: a ball 4 in up,
    /// 1 m away at 65 degrees, was 9 px across where 4766aba's crop had it at 28 and read 2.5 cm high.)
    func testBallCropKeepsTheBallLargeFromClose() throws {
        let f = 0.78 * 1920, full = CameraIntrinsics(fx: f, fy: f, cx: 960, cy: 720, width: 1920, height: 1440)
        let slab = SyntheticScene.slabPose(tilt: 10, heading: 35), up = Vec3(0, 1, 0), R = BallSpec().radius
        // the earlier plans: the points above the corners behind the camera dropped (`near` nil), or each line cut 2 cm
        // from the camera's plane; both shrunk by their longer side's 900 px
        func earlier(_ v: CameraView, near: Double?) -> BallImageCrop? {
            let q = slab.topCorners.compactMap { v.project(world: $0) }
            var pts = q
            for P in slab.topCorners {
                let a = v.toCamera(P), b = v.toCamera(P + up * 1.2)
                guard let n = near else { if let p = full.project(b) { pts.append(p) }; continue }
                guard a.z > n else { continue }
                if let p = full.project(b.z < n ? a + (b - a) * ((a.z - n) / (a.z - b.z)) : b) { pts.append(p) }
            }
            let side = ShapeCheck.meanSide(q)
            func px(_ x: Double) -> Int { Int(min(1e7, max(-1e7, x))) }
            let x0 = max(0, px(pts.map(\.x).min()! - side)), x1 = min(1920, px(pts.map(\.x).max()! + side))
            let y0 = max(0, px(pts.map(\.y).min()! - side)), y1 = min(1440, px(pts.map(\.y).max()! + side))
            return BallImageCrop(x0: x0, y0: y0, width: x1 - x0, height: y1 - y0, factor: max(1, Int(ceil(Double(max(x1 - x0, y1 - y0)) / 900))))
        }
        func holds(_ c: BallImageCrop, _ B: Vec3, _ rf: Double) -> Bool {
            let K = c.intrinsics(full: full)
            return K.project(B).map { K.contains($0, margin: rf / Double(c.factor)) } ?? false
        }
        var poses = 0, factors = [0, 0, 0, 0], larger = 0, slabOnly = 0, radii: [Double] = [], radiiN8: [Double] = []
        for dist in [0.45, 0.6, 0.8, 1.0, 1.2] {
            for el in [35.0, 45, 55, 65, 75] {
                for az in [0.0, 50, 110, 200] {
                    for h in [0.05, 0.1, 0.2, 0.3, 0.45, 0.6, 0.9] {
                        let a = Units.radians(az), e = Units.radians(el), aim = slab.center + up * (0.4 * h)
                        let v = SyntheticScene.camera(at: aim + Vec3(sin(a) * cos(e), sin(e), cos(a) * cos(e)) * dist, lookingAt: aim, intrinsics: full)
                        let B = v.toCamera(slab.center + up * (h + R))
                        guard slab.topCorners.allSatisfy({ v.project(world: $0).map { full.contains($0) } ?? false }),
                              let pf = full.project(B), let rf = Bounce.imageRadius(ballCenter: B, intrinsics: full, ball: BallSpec()),
                              full.contains(pf, margin: rf) else { continue }
                        poses += 1
                        let label = String(format: "%.2f m at %.0f deg, azimuth %.0f, ball %.2f m up", dist, el, az, h)
                        let c = try XCTUnwrap(BallImageCrop.plan(slab: slab, full: v))
                        XCTAssertTrue(holds(c, B, rf), label)
                        XCTAssertLessThanOrEqual(c.factor, 2, label)
                        factors[min(3, c.factor)] += 1
                        radii.append(rf / Double(c.factor))
                        let n8 = try XCTUnwrap(earlier(v, near: 0.02)), n7 = try XCTUnwrap(earlier(v, near: nil))
                        radiiN8.append(rf / Double(n8.factor))
                        XCTAssertLessThanOrEqual(c.factor, n8.factor, label)
                        let stopped = slab.topCorners.contains { v.toCamera($0 + up * 1.2).z <= 0 }
                        if holds(n7, B, rf) && c.factor > n7.factor {
                            larger += 1
                            if stopped { slabOnly += 1 } else { XCTFail("\(label): shrunk by \(c.factor), 4766aba's crop by \(n7.factor)") }
                        }
                    }
                }
            }
        }
        radii.sort(); radiiN8.sort()
        print(String(format: "ball crop from close: %d poses, shrunk by 1 in %d and by 2 in %d; ball radius median %.1f px (e74b53e's crop %.1f), tenth percentile %.1f px (%.1f); shrunk more than 4766aba's crop that held the ball in %d, all where that one stopped at the slab",
                     poses, factors[1], factors[2], radii[radii.count / 2], radiiN8[radiiN8.count / 2], radii[radii.count / 10], radiiN8[radiiN8.count / 10], larger))
        XCTAssertEqual(larger, slabOnly)
        XCTAssertGreaterThan(poses, 300)
    }

    // MARK: depth

    /// The part of the depth map kept on frames without a detection gives exactly the check the whole map gives.
    func testTheDepthRegionGivesTheSameCheckAsTheWholeMap() throws {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 7, heading: 120)
        let w = World(slab: slab, lens: .processing)
        for pos in [Vec3(0, 0.8, 0), Vec3(0.4, 0.7, -0.2), Vec3(-0.3, 1.0, 0.3)] {
            let v = w.view(from: pos, at: slab.center)
            let (d, K) = w.depthMap(v, spec: .standard)
            let a = try XCTUnwrap(PlaneFit.checkSlabTop(depth: d, depthIntrinsics: K, view: v, slab: slab))
            let (part, PK) = try XCTUnwrap(PlaneFit.depthRegion(depth: d, depthIntrinsics: K, view: v, slab: slab))
            XCTAssertLessThan(part.width * part.height, d.width * d.height / 10)
            let b = try XCTUnwrap(PlaneFit.checkSlabTop(depth: part, depthIntrinsics: PK, view: v, slab: slab))
            XCTAssertEqual(a, b)
        }
    }

    // MARK: failures (#32)

    /// A recording's frames.jsonl cut short (the phone's disk filled mid-line) still reads, without its last line.
    func testACutShortLastLineIsLeftOut() throws {
        let folder = tmp.appendingPathComponent("cut.bouncerec")
        let w = try RecordingWriter(folder: folder, session: RecordingSession(build: "t", device: "d", frameWidth: 4, frameHeight: 2, settings: RecordingSettings()))
        let K = CameraIntrinsics(fx: 3, fy: 3, cx: 2, cy: 1, width: 4, height: 2)
        for i in 0..<3 { try w.append(RecordedFrame(index: 0, timestamp: Double(i), file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K), image: nil) }
        w.close()
        let url = folder.appendingPathComponent("frames.jsonl")
        var bytes = try Data(contentsOf: url)
        bytes.removeLast(25)
        try bytes.write(to: url)
        let r = try RecordingReader(folder: folder)
        XCTAssertEqual(r.frames.map { $0.timestamp }, [0, 1])
        XCTAssertEqual(r.skippedLines, 1)
        let rep = try ReplayRunner(reader: r).replay(detector: NullSlabDetector()).report
        XCTAssertTrue(rep.notes.contains { $0.contains("unreadable line") }, "\(rep.notes)")
    }

    /// A write that fails (here: to a handle opened for reading, or on Linux to /dev/full, which is a full disk) throws a
    /// catchable error. FileHandle.write(_ data:) raised an Objective-C exception there (on Linux: a fatal error), which
    /// crashed the app on a full disk.
    func testFailedWritesThrowInsteadOfCrashing() throws {
        let readOnly = tmp.appendingPathComponent("ro.txt")
        try Data("x".utf8).write(to: readOnly)
        var handles: [(String, FileHandle)] = [("read-only", try FileHandle(forReadingFrom: readOnly))]
        #if os(Linux)
        if let full = FileHandle(forWritingAtPath: "/dev/full") { handles.append(("/dev/full", full)) }
        #endif
        let K = CameraIntrinsics(fx: 3, fy: 3, cx: 2, cy: 1, width: 4, height: 2)
        let frame = RecordedFrame(index: 0, timestamp: 0, file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K)
        for (i, (name, h)) in handles.enumerated() {
            let w = try RecordingWriter(folder: tmp.appendingPathComponent("w\(i)"),
                                        session: RecordingSession(build: "t", device: "d", frameWidth: 4, frameHeight: 2, settings: RecordingSettings()), lines: h)
            XCTAssertThrowsError(try w.append(frame, image: nil), name)
            XCTAssertEqual(w.frameCount, 0, name)
            XCTAssertThrowsError(try w.append(frame, image: nil), "\(name): stays failed")
            let entries: [(String, () throws -> Data)] = [("a.txt", { Data("hello".utf8) })]
            XCTAssertThrowsError(try ZipWriter.write(entries: entries, to: h), name)
        }
    }

    /// A zip that fails part-way is removed, not left half-written; one that would not fit is refused before writing;
    /// its size is known beforehand.
    func testAFailedZipLeavesNothingBehind() throws {
        struct Boom: Error {}
        let dest = tmp.appendingPathComponent("x.zip")
        let entries: [(String, () throws -> Data)] = [("a.txt", { Data("hello".utf8) }), ("b.bin", { throw Boom() })]
        XCTAssertThrowsError(try ZipWriter.write(entries: entries, to: dest)) { XCTAssertTrue($0 is Boom) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let folder = tmp.appendingPathComponent("rec.bouncerec")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: folder.appendingPathComponent("sub/b.bin"))
        let size = try ZipWriter.archiveSize(folder: folder)
        XCTAssertThrowsError(try ZipWriter.zip(folder: folder, to: dest, availableBytes: size - 1)) {
            XCTAssertEqual($0 as? ZipWriter.ZipError, .notEnoughSpace(needed: size, available: size - 1))
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("not enough free space") == true)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        try ZipWriter.zip(folder: folder, to: dest, availableBytes: size)
        XCTAssertEqual(Int64(try Data(contentsOf: dest).count), size)
        XCTAssertEqual(try RecordingStorage.size(of: folder), 1005)
        XCTAssertNotNil(RecordingStorage.freeBytes(at: tmp))
        XCTAssertThrowsError(try ZipWriter.zip(folder: tmp.appendingPathComponent("missing"), to: dest)) {
            XCTAssertEqual($0 as? ZipWriter.ZipError, .notAFolder)
        }
    }

    /// ZipError was Hashable (implicitly, with no associated values) before `notEnoughSpace` came: clients may keep it in
    /// sets or as dictionary keys.
    func testZipErrorIsStillHashable() {
        let errors: Set<ZipWriter.ZipError> = [.tooLarge, .notAFolder, .notEnoughSpace(needed: 2, available: 1), .tooLarge]
        XCTAssertEqual(errors.count, 3)
        XCTAssertTrue(errors.contains(.notEnoughSpace(needed: 2, available: 1)))
        XCTAssertEqual([ZipWriter.ZipError.notAFolder: 1][.notAFolder], 1)
    }

    /// A recording stops at its size limit with a clear error, writing nothing of the frame that would pass it.
    func testTheWriterStopsAtItsSizeLimit() throws {
        let folder = tmp.appendingPathComponent("lim.bouncerec")
        let w = try RecordingWriter(folder: folder, session: RecordingSession(build: "t", device: "d", frameWidth: 8, frameHeight: 6, settings: RecordingSettings()),
                                    byteLimit: 2_000)
        let K = CameraIntrinsics(fx: 8, fy: 8, cx: 4, cy: 3, width: 8, height: 6)
        let img = YCCImage(width: 8, height: 6, y: [UInt8](repeating: 1, count: 48), cb: [UInt8](repeating: 128, count: 12), cr: [UInt8](repeating: 128, count: 12))
        var n = 0
        do {
            while n < 100 {
                try w.append(RecordedFrame(index: 0, timestamp: Double(n), file: "", worldFromCamera: RigidTransform.identity.columnMajor4x4, intrinsics: K), image: img)
                n += 1
            }
            XCTFail("no limit")
        } catch {
            XCTAssertEqual(error as? RecordingError, .limitReached(2_000))
        }
        XCTAssertGreaterThan(n, 1)
        XCTAssertEqual(w.frameCount, n)
        XCTAssertLessThanOrEqual(w.bytesWritten, 2_000)
        w.close()
        let r = try RecordingReader(folder: folder)
        XCTAssertEqual(r.frames.count, n)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(format: "f%06d.byc", n)).path))
    }

    /// Recordings made before the slab's side profile existed (every fixture) read with none: the old box, so they replay
    /// as they ran. New settings carry the owner's slab with its profile (`SlabSpec.ownerSlab`), and keep it through JSON.
    func testRecordingsWithoutASideProfileReadAsTheOldBox() throws {
        for name in ["rec_replay_still", "rec_ball_held", "rec_noslab_clutter", "rec_single_cradle_r14_d4", "rec_single_warm_lamp_d4"] {
            let r = try Fixtures.recording(name)
            let s = r.session.settings
            XCTAssertNil(s.faceDropInches, name); XCTAssertNil(s.sideRunInches, name); XCTAssertNil(s.edgeRadiusInches, name)
            XCTAssertNil(s.nearFeatureDegrees, name)
            XCTAssertFalse(s.slab.hasProfile, name)
            XCTAssertEqual(s.slab, SlabSpec(sideU: Units.inches(s.sideUInches), sideV: Units.inches(s.sideVInches),
                                            thickness: Units.inches(s.thicknessInches), dishDepth: Units.inches(s.dishInches)), name)
            if let t = r.session.tracker { XCTAssertFalse(t.spec.hasProfile, name) }
        }
        let s = RecordingSettings()
        XCTAssertEqual(s.slab, SlabSpec.ownerSlab)
        XCTAssertEqual(s.trackerSettings.spec, SlabSpec.ownerSlab)
        let back = try JSONDecoder().decode(RecordingSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.trackerSettings.spec, SlabSpec.ownerSlab)
        // a tracker's settings with the profile keep it (`SlabSpec`'s own coding)
        let t = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(s.trackerSettings))
        XCTAssertEqual(t.spec, SlabSpec.ownerSlab)
        // the owner's slab and ball, one constant each: the kit's 180.2 mm flat top, 1 in, 1/8 in dish; the 30 mm ball
        XCTAssertEqual(SlabSpec.ownerSlab.sideU, 0.1802, accuracy: 1e-12)
        XCTAssertEqual(SlabSpec.ownerSlab.sideV, 0.1802, accuracy: 1e-12)
        XCTAssertEqual(SlabSpec.ownerSlab.thickness, 0.0254, accuracy: 1e-12)
        XCTAssertEqual(SlabSpec.ownerSlab.dishDepth, 0.003175, accuracy: 1e-12)
        XCTAssertEqual(s.ball, BallSpec.ownerBall)
        XCTAssertEqual(s.ball.diameter, 0.030, accuracy: 1e-12)
        XCTAssertEqual(s.trackerSettings.ball, BallSpec.ownerBall)
        XCTAssertEqual(KitMeasurements(settings: s).recordingSettings().slab, SlabSpec.ownerSlab)
        // tests and old recordings keep the first assumptions
        XCTAssertEqual(BallSpec().diameter, 0.035)
        XCTAssertEqual(TrackerSettings().ball, BallSpec())
        XCTAssertEqual(TrackerSettings().spec, SlabSpec.standard)
        // a detection's one-edge shifts are written only when there are any, so a detection without them writes what it did
        let plain = DetectedOutline(quad: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)], sideSigmas: [0.3, 0.3, 0.3, 0.3])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("sideShifts"))
        var shifted = plain
        shifted.sideShifts = [0, 2.5, 0, -1]
        XCTAssertEqual(try JSONDecoder().decode(DetectedOutline.self, from: JSONEncoder().encode(shifted)).sideShifts, [0, 2.5, 0, -1])
        XCTAssertEqual(try JSONDecoder().decode(DetectedOutline.self, from: JSONEncoder().encode(plain)).sideShifts, [])
        // and each side's own part of its sigma likewise
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("sideFrameSigmas"))
        var own = plain
        own.sideFrameSigmas = [0.1, 0.12, 0.1, 0.2]
        XCTAssertEqual(try JSONDecoder().decode(DetectedOutline.self, from: JSONEncoder().encode(own)).sideFrameSigmas, [0.1, 0.12, 0.1, 0.2])
        XCTAssertEqual(try JSONDecoder().decode(DetectedOutline.self, from: JSONEncoder().encode(plain)).sideFrameSigmas, [])
        // the lock keeps each view's newest detections in the app; settings without the key (older recordings) as before
        XCTAssertTrue(s.trackerSettings.lockKeepsNewestPerView)
        XCTAssertFalse(TrackerSettings().lockKeepsNewestPerView)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.trackerSettings)) as! [String: Any]
        old.removeValue(forKey: "lockKeepsNewestPerView")
        XCTAssertFalse(try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: old)).lockKeepsNewestPerView)
        // n18: the app shows the tilt from 2 deg and holds it; older recordings (n11's 1 deg stored, no hold key) as before
        XCTAssertEqual(s.trackerSettings.settle.settleDegrees, 2.0)
        XCTAssertEqual(s.trackerSettings.settle.unsettleDegrees, 2.5)
        XCTAssertTrue(s.trackerSettings.settle.holdShown)
        XCTAssertEqual(TrackerSettings().settle.settleDegrees, 1.0)
        XCTAssertFalse(TrackerSettings().settle.holdShown)
        var n17 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TrackerSettings())) as! [String: Any]
        var settle = n17["settle"] as! [String: Any]
        settle.removeValue(forKey: "holdShown"); n17["settle"] = settle
        let n17Back = try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: n17))
        XCTAssertFalse(n17Back.settle.holdShown)
        XCTAssertEqual(n17Back.settle.settleDegrees, 1.0)
    }

    /// A diagnostics file from the phone written before the profile existed (BOUNCE_DIAGNOSTICS: a path, e.g. the owner's
    /// n10 report, kept outside the repository) still reads, with the old box as its slab.
    func testADiagnosticsFileFromBeforeTheProfileStillReads() throws {
        guard let path = ProcessInfo.processInfo.environment["BOUNCE_DIAGNOSTICS"] else { throw XCTSkip("set BOUNCE_DIAGNOSTICS to a diagnostics file") }
        let rep = try DiagnosticsReport.decode(json: String(contentsOfFile: path, encoding: .utf8))
        let t = try XCTUnwrap(rep.tracker)
        print("DIAGNOSTICS build \(rep.build): slab \(t.spec), profile \(t.spec.hasProfile)")
        if rep.build.hasPrefix("n10") || rep.build.hasPrefix("e4ffadf") { XCTAssertFalse(t.spec.hasProfile) }
    }
}
