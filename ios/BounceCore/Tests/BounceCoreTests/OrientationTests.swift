import XCTest
@testable import BounceCore

/// What the phone delivers when held upright in portrait: ARKit's captured image is always in the sensor's landscape
/// orientation, so the web fixtures' portrait images arrive turned 90 degrees counter-clockwise, with world up along
/// image -x and gravity along +x. Pixel (x, y) of a W-wide portrait image is (y, W - x) in the sensor's image; camera
/// axes (x, y, z) become (y, -x, z).
enum PortraitHold {
    static func point(_ p: Vec2, width W: Int) -> Vec2 { Vec2(p.y, Double(W) - p.x) }
    /// back from the sensor's image to the portrait one (W: the portrait image's width)
    static func unpoint(_ q: Vec2, width W: Int) -> Vec2 { Vec2(Double(W) - q.y, q.x) }
    static func vector(_ v: Vec3) -> Vec3 { Vec3(v.y, -v.x, v.z) }
    /// new camera axes in the old camera's: x' = old +y, y' = old -x
    static let turn = Mat3(rows: [0, -1, 0, 1, 0, 0, 0, 0, 1])

    static func intrinsics(_ K: CameraIntrinsics) -> CameraIntrinsics {
        CameraIntrinsics(fx: K.fy, fy: K.fx, cx: K.cy, cy: Double(K.width) - K.cx, width: K.height, height: K.width)
    }

    static func view(_ v: CameraView) -> CameraView {
        CameraView(worldFromCamera: RigidTransform(rotation: v.worldFromCamera.rotation * turn, translation: v.position), intrinsics: intrinsics(v.intrinsics))
    }

    /// The same camera rolled a quarter turn about its axis, image size kept: a landscape view (gravity down the image)
    /// becomes the portrait hold's (gravity along +x).
    static func rolled(_ v: CameraView) -> CameraView {
        CameraView(worldFromCamera: RigidTransform(rotation: v.worldFromCamera.rotation * turn, translation: v.position), intrinsics: v.intrinsics)
    }

    static func plane(_ p: Plane) -> Plane {
        let W = p.width, H = p.height
        var d = [Float](repeating: 0, count: W * H)
        for y in 0..<W { for x in 0..<H { d[y * H + x] = p[W - 1 - y, x] } }
        return Plane(width: H, height: W, data: d)
    }

    static func bytes(_ b: [UInt8], width W: Int, height H: Int) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: W * H)
        for y in 0..<W { for x in 0..<H { d[y * H + x] = b[x * W + (W - 1 - y)] } }
        return d
    }

    static func image(_ im: YCCImage) -> YCCImage {
        precondition(im.width % 2 == 0, "chroma stays aligned only for an even width")
        return YCCImage(width: im.height, height: im.width, y: bytes(im.y, width: im.width, height: im.height),
                        cb: bytes(im.cb, width: im.chromaWidth, height: im.chromaHeight), cr: bytes(im.cr, width: im.chromaWidth, height: im.chromaHeight))
    }

    /// A recording turned into the sensor's orientation (images, intrinsics, camera, gravity), written to `folder`.
    static func recording(_ r: RecordingReader, to folder: URL) throws -> RecordingReader {
        var s = r.session
        s.frameWidth = r.session.frameHeight; s.frameHeight = r.session.frameWidth
        let w = try RecordingWriter(folder: folder, session: s)
        for f in r.frames {
            let v = view(f.view)
            var g = RecordedFrame(index: f.index, timestamp: f.timestamp, file: "", intrinsics: v.intrinsics, trackingNormal: f.trackingNormal,
                                  view: v)
            g.gravityCamera = f.gravityCamera.map { vector(Vec3($0)).array }
            try w.append(g, image: image(try r.image(for: f)), depth: nil)
        }
        w.close()
        return try RecordingReader(folder: folder)
    }
}

extension RecordedFrame {
    init(index: Int, timestamp: Double, file: String, intrinsics: CameraIntrinsics, trackingNormal: Bool, view: CameraView) {
        let a = RigidTransform(rotation: view.worldFromCamera.rotation * ARKitConvention.cvToARKitCamera, translation: view.position)
        self.init(index: index, timestamp: timestamp, file: file, worldFromCamera: a.columnMajor4x4, intrinsics: intrinsics, trackingNormal: trackingNormal)
    }
}

final class OrientationTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-orient-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    /// The recorded fixture, turned into the orientation the phone delivers, replays to the same slab in the world, the
    /// same readouts, and the same outline (turned back).
    func testARecordingInThePhonesOrientationGivesTheSameResult() throws {
        let rec = try Fixtures.recording("rec_replay_still"), truth = try Fixtures.truth("rec_replay_still")
        let W = rec.session.frameWidth
        let turned = try PortraitHold.recording(rec, to: tmp.appendingPathComponent("turned.bouncerec"))
        let tfr = truth["frames"] as! [[String: Any]]
        let corners = tfr.map { vec2s($0["cornersPixels"])! }
        let turnedCorners = corners.map { $0.map { PortraitHold.point($0, width: W) } }
        // as on the phone: a landscape image, gravity along +x, the world up along -x
        for (f, q) in zip(turned.frames, turnedCorners) {
            XCTAssertGreaterThan(f.intrinsics.width, f.intrinsics.height)
            let g = Vec3(f.gravityCamera!)
            XCTAssertGreaterThan(g.x, 0.6); XCTAssertLessThan(abs(g.y), 0.02)
            XCTAssertLessThan(angleDeg(f.view.directionToCamera(ARKitConvention.worldDown), g), 0.05)
            // the image turned with it: the slab's true corners land on the turned corner pixels
            let cw = (tfr[f.index]["slabCornersWorld"] as! [[Double]]).map { Vec3($0) }
            for (w, p) in zip(cw, q) { XCTAssertLessThan(f.view.project(world: w)!.distance(to: p), 0.3) }
            let img = try turned.image(for: f), orig = try rec.image(for: rec.frames[f.index])
            XCTAssertEqual(img.width, orig.height)
            XCTAssertEqual(img.y[5 * img.width + 7], orig.y[7 * orig.width + (W - 1 - 5)])
        }
        var s = TrackerSettings(); s.recheckInterval = 0; s.spec = rec.session.settings.slab
        let (a, ta) = try ReplayRunner(reader: rec).run(detector: TruthCornersDetector(corners), settings: s)
        let (b, tb) = try ReplayRunner(reader: turned).run(detector: TruthCornersDetector(turnedCorners), settings: s)
        XCTAssertEqual(tb.state, .locked)
        XCTAssertEqual(a.map { $0.output.events }, b.map { $0.output.events })
        XCTAssertLessThan(angleDeg(ta.slab!.normal, tb.slab!.normal), 1e-6)
        XCTAssertLessThan(ta.slab!.center.distance(to: tb.slab!.center), 1e-7)
        let ra = a.last!.output.readouts!, rb = b.last!.output.readouts!
        XCTAssertEqual(ra.tiltDegrees, rb.tiltDegrees, accuracy: 1e-6)
        XCTAssertEqual(ra.landingDistance, rb.landingDistance, accuracy: 1e-6)
        XCTAssertEqual(rb.tiltDegrees, dbl(tfr.last!["tiltDeg"]), accuracy: 0.2)
        for (sa, sb) in zip(a, b) where sa.output.outline != nil {
            let back = sb.output.outline!.map { PortraitHold.unpoint($0, width: W) }
            XCTAssertLessThan(zip(sa.output.outline!, back).map { $0.distance(to: $1) }.max()!, 1e-6)
        }
    }

    /// The ball fixtures turned the same way: the drop height from the turned circle, corners, gravity and lens matches
    /// the portrait one's, and the crops' pixels move with their points (for the ported ball finder's tests).
    func testBallFixturesInThePhonesOrientation() throws {
        let rows = try Fixtures.json("gt_balls.json") as! [[String: Any]]
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        var n = 0
        for r in rows {
            let K = CameraIntrinsics(verticalFovDegrees: dbl(r["fovDeg"]), width: 720, height: 1280), K2 = PortraitHold.intrinsics(K)
            let spec = SlabSpec(sideU: Units.inches(dbl(r["sideUInches"])), sideV: Units.inches(dbl(r["sideVInches"])),
                                thickness: Units.inches(dbl(r["thicknessInches"])), dishDepth: Units.inches(dbl(r["dishInches"])))
            let q = vec2s(r["corners"])!, g = vec3(r["down"])!, b = r["ball"] as! [String: Any], ball = BallSpec(diameter: dbl(r["ballDiameterMm"]) / 1000)
            let q2 = q.map { PortraitHold.point($0, width: 720) }, g2 = PortraitHold.vector(g)
            let c = Vec2(dbl(b["x"]), dbl(b["y"])), c2 = PortraitHold.point(c, width: 720)
            XCTAssertGreaterThan(g2.x, 0.5); XCTAssertLessThan(abs(g2.y), 0.02)
            guard let f1 = PoseSolver.solve(corners: q, intrinsics: K, spec: spec, down: g, options: opt),
                  let f2 = PoseSolver.solve(corners: q2, intrinsics: K2, spec: spec, down: g2, options: opt),
                  let B1 = Bounce.ballCenter(pixel: c, radiusPixels: dbl(b["r"]), intrinsics: K, ball: ball, model: .onAxis),
                  let B2 = Bounce.ballCenter(pixel: c2, radiusPixels: dbl(b["r"]), intrinsics: K2, ball: ball, model: .onAxis),
                  let d1 = Bounce.drop(ballCenter: B1, pose: f1.pose, spec: spec, ball: ball, down: g),
                  let d2 = Bounce.drop(ballCenter: B2, pose: f2.pose, spec: spec, ball: ball, down: g2) else {
                XCTFail("no drop for \(r["clip"]!)"); continue
            }
            XCTAssertLessThan(angleDeg(PortraitHold.vector(f1.pose.normal), f2.pose.normal), 1e-6)
            XCTAssertEqual(d1.dropHeight, d2.dropHeight, accuracy: 1e-9)
            n += 1
        }
        XCTAssertGreaterThan(n, 20)

        let crops = try Fixtures.json("balls/ball_crops.json") as! [[String: Any]]
        for r in crops {
            let p = try XCTUnwrap(Plane(pgm: Data(contentsOf: Fixtures.root.appendingPathComponent("balls").appendingPathComponent(r["file"] as! String))))
            let t = PortraitHold.plane(p)
            XCTAssertEqual(t.width, p.height); XCTAssertEqual(t.height, p.width)
            for (x, y) in [(0, 0), (p.width - 1, 3), (p.width / 2, p.height / 2), (2, p.height - 1)] {
                let q = PortraitHold.point(Vec2(Double(x) + 0.5, Double(y) + 0.5), width: p.width)
                XCTAssertEqual(t[Int(q.x), Int(q.y)], p[x, y])
            }
        }
    }

    /// The pose and the shape check do not care which way the image is turned: every quarter turn about the optical axis
    /// gives the same pose. (SyntheticView's roll 0 has gravity running up the image: an upside-down camera.)
    func testPoseAndShapeCheckInEveryQuarterTurn() {
        var opt = PoseSolver.Options(); opt.levelPriorSigmaDegrees = nil
        let wantDown: [Double: (Double, Double)] = [0: (0, -1), 90: (-1, 0), 180: (0, 1), -90: (1, 0)]
        for (k, (tilt, heading)) in [(4.0, 30.0), (10.0, 200.0), (7.0, 95.0)].enumerated() {
            for roll in [0.0, 90.0, 180.0, -90.0] {
                let sv = SyntheticView.make(pitch: 50, roll: roll, distance: 1.2, tilt: tilt, heading: heading, yaw: 15 + Double(k))
                let d2 = Vec2(sv.down.x, sv.down.y).normalized, want = wantDown[roll]!
                XCTAssertEqual(d2.x, want.0, accuracy: 1e-9, "roll \(roll)"); XCTAssertEqual(d2.y, want.1, accuracy: 1e-9, "roll \(roll)")
                let fit = PoseSolver.solve(corners: sv.corners, intrinsics: sv.intrinsics, spec: sv.spec, down: sv.down, options: opt)
                XCTAssertNotNil(fit)
                XCTAssertLessThan(angleDeg(fit!.pose.normal, sv.pose.normal), 1e-6, "roll \(roll)")
                XCTAssertEqual(ShapeCheck.check(fit, outline: sv.corners, down: sv.down, limits: TrackerSettings.defaultShapeLimits), .ok, "roll \(roll)")
                XCTAssertEqual(Units.degrees(fit!.pose.tilt(down: sv.down)), tilt, accuracy: 1e-6)
            }
        }
    }

    /// The tracker with the phone held in portrait (the processing image landscape, gravity along +x): it locks when it
    /// does held in landscape, its outline sits on the slab, its tilt is right, and a held ball gives the same drop height.
    func testTheTrackerWithThePhoneHeldInPortrait() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 7, heading: 60)
        let w = World(slab: slab, lens: .processing)
        var results: [(tilt: Double, drop: Double, lockedAt: Int?)] = []
        for portrait in [false, true] {
            let det = SceneDetector(w, noise: 0, seed: 31)
            let ball = HeldBall()
            var s = TrackerSettings(); s.searchInterval = 0.12
            let tr = SlabTracker(settings: s, detector: det, ballLocator: ball)
            var o: TrackerOutput! = nil, worst = 0.0, lockedAt: Int? = nil
            for k in 0..<(30 * 4) {
                let t = Double(k) / 30
                var v = w.view(from: Vec3(0.1 * sin(t), 0.9, 0.05 * cos(t)), at: slab.center)
                if portrait { v = PortraitHold.rolled(v) }
                if k == 0 {
                    let g = v.directionToCamera(ARKitConvention.worldDown)
                    if portrait { XCTAssertGreaterThan(g.x, 0.5); XCTAssertLessThan(abs(g.y), 1e-9) } else { XCTAssertGreaterThan(g.y, 0.5) }
                }
                ball.present = k > 60
                det.currentView = v
                o = tr.process(TrackerFrame(timestamp: t, view: v, frame: ColorFrame(gray: Plane(width: 4, height: 4)),
                                            ballImage: tr.ballDue(at: t) ? Plane(width: 4, height: 4) : nil, ballIntrinsics: v.intrinsics))
                if let q = o.outline { worst = max(worst, zip(q, w.corners(in: v)).map { $0.distance(to: $1) }.max()!) }
                if lockedAt == nil && o.state == .locked { lockedAt = k }
            }
            XCTAssertEqual(o.state, .locked, "portrait \(portrait)")
            XCTAssertLessThan(worst, 0.05, "portrait \(portrait)")
            XCTAssertEqual(o.readouts!.tiltDegrees, 7, accuracy: 0.01)
            XCTAssertTrue(o.readouts!.dropFromBall)
            results.append((o.readouts!.tiltDegrees, o.readouts!.dropHeight, lockedAt))
        }
        XCTAssertEqual(results[0].lockedAt, results[1].lockedAt)
        XCTAssertEqual(results[0].drop, results[1].drop, accuracy: 1e-6)
    }
}
