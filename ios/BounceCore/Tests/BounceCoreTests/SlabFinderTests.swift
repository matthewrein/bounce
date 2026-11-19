import XCTest
@testable import BounceCore

/// One recorded frame with its truth.
struct SlabFrame {
    var rec: String
    var index: Int
    var frame: ColorFrame
    var intrinsics: CameraIntrinsics
    var down: Vec3
    var spec: SlabSpec
    var truthCorners: [Vec2]?
    var truthNormal: Vec3?   // camera axes
    var view: CameraView     // where the camera was (as ARKit reports it)

    static func load(_ rec: String) throws -> [SlabFrame] {
        let r = try Fixtures.recording(rec), t = try Fixtures.truth(rec)
        let tf = t["frames"] as! [[String: Any]]
        return try zip(r.frames, tf).map { f, tr in
            let view = f.view
            return SlabFrame(rec: rec, index: f.index, frame: try r.image(for: f).colorFrame, intrinsics: f.intrinsics,
                             down: Vec3(f.gravityCamera!), spec: r.session.settings.slab, truthCorners: vec2s(tr["cornersPixels"]),
                             truthNormal: vec3(tr["slabNormalWorld"]).map { view.directionToCamera($0).normalized }, view: view)
        }
    }

    /// Where a slab found in another frame should appear in this one, moved by the camera's own motion between the two
    /// (what the app gets from ARKit every frame), in that outline's corner order.
    func predicted(_ c: SlabCandidate, from prev: SlabFrame) -> [Vec2] {
        let pose = c.fit.pose.transformed(by: prev.view.worldFromCamera).transformed(by: view.cameraFromWorld)
        return Geometry.aligned(pose.topCorners.map { intrinsics.project($0)! }, to: c.quad)
    }

    /// corner errors (pixels) of an outline against the truth, matched corner to corner
    func cornerErrors(_ q: [Vec2]) -> [Double] {
        guard let t = truthCorners else { return [] }
        let m = Geometry.bestCorrespondence(q, t).map
        return (0..<4).map { q[$0].distance(to: t[m[$0]]) }
    }

    func normalError(_ fit: PoseFit) -> Double { truthNormal.map { angleDeg(fit.pose.normal, $0) } ?? .nan }

    /// The same view with the phone turned a quarter turn: the image rotated 90 degrees clockwise (portrait 270x480
    /// becomes landscape 480x270), and the intrinsics, gravity and truth with it. Camera axes turn too: (x, y, z) ->
    /// (-y, x, z).
    func rotatedClockwise() -> SlabFrame {
        let W = frame.width, H = frame.height
        func rot(_ p: Plane) -> Plane {
            var d = [Float](repeating: 0, count: W * H)
            for y in 0..<H { for x in 0..<W { d[x * H + (H - 1 - y)] = p.data[y * W + x] } }
            return Plane(width: H, height: W, data: d)
        }
        let K = intrinsics
        let K2 = CameraIntrinsics(fx: K.fy, fy: K.fx, cx: Double(H) - K.cy, cy: K.cx, width: H, height: W)
        let r3 = { (v: Vec3) -> Vec3 in Vec3(-v.y, v.x, v.z) }
        // the turned camera's axes in the original camera's: x' = -y, y' = x
        let oldFromNew = RigidTransform(rotation: Mat3(rows: [0, 1, 0, -1, 0, 0, 0, 0, 1]), translation: .zero)
        return SlabFrame(rec: rec + " (rotated)", index: index, frame: ColorFrame(y: rot(frame.y), cb: rot(frame.cb), cr: rot(frame.cr)),
                         intrinsics: K2, down: r3(down), spec: spec, truthCorners: truthCorners?.map { Vec2(Double(H) - $0.y, $0.x) },
                         truthNormal: truthNormal.map(r3), view: CameraView(worldFromCamera: view.worldFromCamera * oldFromNew, intrinsics: K2))
    }

    /// The view in a mirror (left and right swapped): the image of the mirrored scene, which holds the same square slab,
    /// box and base. Camera axes: (x, y, z) -> (-x, y, z). (`view` is left as it was: a mirror is not a camera motion.)
    func mirrored() -> SlabFrame {
        let W = frame.width, H = frame.height
        func flip(_ p: Plane) -> Plane {
            var d = [Float](repeating: 0, count: W * H)
            for y in 0..<H { for x in 0..<W { d[y * W + (W - 1 - x)] = p.data[y * W + x] } }
            return Plane(width: W, height: H, data: d)
        }
        let K = intrinsics
        let K2 = CameraIntrinsics(fx: K.fx, fy: K.fy, cx: Double(W) - K.cx, cy: K.cy, width: W, height: H)
        let m3 = { (v: Vec3) -> Vec3 in Vec3(-v.x, v.y, v.z) }
        return SlabFrame(rec: rec + " (mirrored)", index: index, frame: ColorFrame(y: flip(frame.y), cb: flip(frame.cb), cr: flip(frame.cr)),
                         intrinsics: K2, down: m3(down), spec: spec, truthCorners: truthCorners?.map { Vec2(Double(W) - $0.x, $0.y) },
                         truthNormal: truthNormal.map(m3), view: view)
    }
}

func median(_ a: [Double]) -> Double { let s = a.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

final class SlabFinderTests: XCTestCase {
    static let singles = ["rec_single_cradle_r14_d4", "rec_single_d3_t10_h0_mat", "rec_single_d5_t15_h45_wood", "rec_single_d5_t8_h315_darkfloor",
                          "rec_single_level_lined_up_d4", "rec_single_matchtone_concrete_d4", "rec_single_two_lights_d4", "rec_single_warm_lamp_d4"]

    static func slabFrames() throws -> [SlabFrame] {
        var frames: [SlabFrame] = []
        for r in singles + ["rec_replay_still"] { frames += try SlabFrame.load(r) }
        return frames
    }

    struct Accuracy {
        var corners: [Double] = []   // every corner of every frame
        var normals: [Double] = []   // one per frame
        var missed: [String] = []
        var summary: String {
            String(format: "corner error median %.2f px, worst %.2f px; normal error median %.2f deg, worst %.2f deg; %d frames, %d missed",
                   median(corners), corners.max() ?? .nan, median(normals), normals.max() ?? .nan, normals.count, missed.count)
        }
    }

    /// Unprompted search on each frame; the first (largest) find must be the slab.
    func measure(_ frames: [SlabFrame], options: SlabFinder.Options, log: Bool = false) -> Accuracy {
        let finder = SlabFinder(options: options)
        var acc = Accuracy()
        for f in frames {
            let cs = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down)
            guard let c = cs.first else { acc.missed.append("\(f.rec) #\(f.index): nothing found"); continue }
            let e = f.cornerErrors(c.quad)
            // "found" means the slab, not something else: every corner within a fifth of the side of the truth
            guard e.max()! < 0.2 * ShapeCheck.meanSide(f.truthCorners!) else {
                acc.missed.append("\(f.rec) #\(f.index): found something else (corner errors \(e))"); continue
            }
            acc.corners += e
            acc.normals.append(f.normalError(c.fit))
            if log {
                let sides = c.sides.map { String(format: "%@ %.1fpx", $0.mode.rawValue, $0.bandPixels) }.joined(separator: ", ")
                print(String(format: "  %@ #%d: corners %@ px, normal %.2f deg  [%@]", f.rec, f.index,
                             e.map { String(format: "%.2f", $0) }.joined(separator: " "), f.normalError(c.fit), sides))
            }
        }
        return acc
    }

    // MARK: the recorded fixtures

    /// Every slab frame is found, and the box model's top edges beat the plain outline (the web app's) on corners and
    /// on the slab's normal.
    func testFindsEverySlabFrameAndBoxModelImprovesAccuracy() throws {
        let frames = try Self.slabFrames()
        XCTAssertEqual(frames.count, 16)
        var plainOpt = SlabFinder.Options(); plainOpt.useBoxModel = false
        print("plain outline (no edge refiner):")
        let plain = measure(frames, options: plainOpt, log: true)
        print("box model (edge refiner):")
        let box = measure(frames, options: SlabFinder.Options(), log: true)
        print("plain: " + plain.summary)
        print("box:   " + box.summary)
        XCTAssertEqual(box.missed, [], "every slab frame is found")
        XCTAssertEqual(plain.missed, [])
        // the box model's effect (measured: corner error median 1.19 -> 0.39 px, worst 5.08 -> 1.42 px; normal error
        // median 4.83 -> 1.34 deg, worst 6.26 -> 2.59 deg; the first version measured 1.19 -> 0.41 px, 5.07 -> 1.72 px,
        // 4.86 -> 1.41 deg, 6.86 -> 2.42 deg). The bounds below were set after measuring that first version, with margin,
        // and are unchanged.
        XCTAssertLessThan(median(box.corners), 0.6 * median(plain.corners))
        XCTAssertLessThan(median(box.normals), 0.5 * median(plain.normals))
        XCTAssertLessThan(box.normals.max()!, plain.normals.max()!)
        XCTAssertLessThan(median(box.corners), 0.8)
        XCTAssertLessThan(box.corners.max()!, 2.5)
        XCTAssertLessThan(median(box.normals), 2.0)
        XCTAssertLessThan(box.normals.max()!, 3.5)
    }

    /// Nothing is found where there is no slab: clutter (a box, a sheet of paper, a tin) and the black base alone, with
    /// or without the box model, and also when the black base is not required (so the shape gate has to reject them).
    func testNothingFoundWithoutSlab() throws {
        for r in ["rec_noslab_clutter", "rec_noslab_base_only"] {
            for f in try SlabFrame.load(r) {
                for box in [true, false] {
                    for base in [true, false] {
                        var o = SlabFinder.Options(); o.useBoxModel = box; o.requireBase = base
                        let cs = SlabFinder(options: o).find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down)
                        XCTAssertEqual(cs.count, 0, "\(r) box model \(box) base required \(base): found \(cs.map { $0.quad })")
                    }
                }
            }
        }
    }

    /// The clutter frame has nothing dark in it, so the sweep never even grows a region there. Here black strips are
    /// painted beside the box and the paper (as the slab's base would lie beside the slab), so the sweep grows regions on
    /// the clutter and every later gate (texture, base, shape) has to reject them.
    func testSweepRejectsClutterBesideSomethingDark() throws {
        let f = try SlabFrame.load("rec_noslab_clutter")[0]
        var y = f.frame.y, cb = f.frame.cb, cr = f.frame.cr
        // left of and below the box, below and right of the paper
        for (x0, y0, x1, y1) in [(22, 150, 30, 225), (50, 230, 120, 237), (140, 298, 200, 305), (203, 235, 210, 290)] {
            for yy in y0..<y1 { for xx in x0..<x1 { y[xx, yy] = 15; cb[xx, yy] = 0; cr[xx, yy] = 0 } }
        }
        let frame = ColorFrame(y: y, cb: cb, cr: cr)
        // (with the base not required more outlines reach the shape gate: if none passes then, none passes with it)
        for (box, base) in [(true, true), (true, false), (false, false)] {
            do {
                var o = SlabFinder.Options(); o.useBoxModel = box; o.requireBase = base
                let run = FinderRun(options: o, frame: frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, detail: nil, choice: nil)
                let cs = run.sweep()
                print("  clutter beside black strips, box model \(box), base required \(base): \(run.seedsGrown) starting points grown, \(run.regionsKept) regions, \(run.refined) outlines checked, \(cs.count) found")
                XCTAssertGreaterThan(run.regionsKept, 0, "the gates after the dark pre-filter were exercised")
                XCTAssertEqual(cs.count, 0, "box model \(box) base required \(base): found \(cs.map { $0.quad })")
            }
        }
    }

    /// Taps on the clutter find nothing: a tap does not need the black base, so this is the shape gate alone. (With
    /// ShapeCheck's 3% misfit gate a tap on the box's top and one on the paper were taken for the slab.)
    func testTapsOnClutterFindNothing() throws {
        let f = try SlabFrame.load("rec_noslab_clutter")[0]
        let finder = SlabFinder()
        var taps = 0
        for y in stride(from: 100, through: 310, by: 30) {
            for x in stride(from: 15, through: 255, by: 30) {
                taps += 1
                let cs = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, seed: Vec2(Double(x), Double(y)))
                XCTAssertEqual(cs.count, 0, "tap (\(x), \(y)): found \(cs.map { $0.quad })")
            }
        }
        XCTAssertEqual(taps, 72)
    }

    /// Following the still clip (hand-held: the slab shifts 3-6 px between these frames) frame by frame, as the app will:
    /// the last frame's slab moved by the camera's motion is the predicted outline, and the edge choice is passed back.
    /// Every side keeps the same edge mode on all 8 frames, the outline stays accurate, and (since a steady label could
    /// hide a line that moves) each corner stays close to where the camera's motion put the last one.
    func testReplayTrackingKeepsEachSidesEdgeMode() throws {
        let frames = try SlabFrame.load("rec_replay_still")
        XCTAssertEqual(frames.count, 8)
        let finder = SlabFinder()
        var last: SlabCandidate? = nil, lastFrame: SlabFrame? = nil
        var modes: [[EdgeMode]] = []
        var errs: [Double] = [], normals: [Double] = [], jumps: [Double] = []
        for f in frames {
            let near = last.map { f.predicted($0, from: lastFrame!) }
            let cs = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, near: near, choice: last?.choice)
            guard let c = cs.first else { XCTFail("lost on frame \(f.index)"); return }
            if last != nil { XCTAssertEqual(c.source, .tracked, "frame \(f.index) followed by its edges") }
            XCTAssertEqual(c.sides.count, 4)
            modes.append(c.sides.map { $0.mode })
            let e = f.cornerErrors(c.quad)
            errs += e; normals.append(f.normalError(c.fit))
            // how far each corner moved beyond the camera's motion (the tracked outline comes back in the prediction's order)
            let j = near.map { n in (0..<4).map { c.quad[$0].distance(to: n[$0]) } } ?? []
            jumps += j
            print(String(format: "  replay #%d: corners %@ px, moved %@ px beyond the camera's motion, normal %.2f deg, modes %@ (seen %@, used %@)", f.index,
                         e.map { String(format: "%.2f", $0) }.joined(separator: " "), j.map { String(format: "%.2f", $0) }.joined(separator: " "),
                         f.normalError(c.fit), c.sides.map { $0.mode.rawValue }.joined(separator: " "),
                         c.sides.map { $0.observed.rawValue }.joined(separator: " "), c.sides.map { $0.used.rawValue }.joined(separator: " ")))
            last = c; lastFrame = f
        }
        for s in 0..<4 {
            let m = Set(modes.map { $0[s] })
            XCTAssertEqual(m.count, 1, "side \(s) changed mode: \(modes.map { $0[s].rawValue })")
        }
        // the near side's cut face shows: it must not rest on the cut face's bottom
        XCTAssertTrue(modes[0].contains { $0 == .innerEdge || $0 == .shiftedOuter })
        print(String(format: "replay tracking: corner error median %.2f px, worst %.2f px; normal median %.2f deg, worst %.2f deg; corners moved beyond the camera's motion: median %.2f px, most %.2f px",
                     median(errs), errs.max()!, median(normals), normals.max()!, median(jumps), jumps.max()!))
        XCTAssertLessThan(median(errs), 0.8)
        XCTAssertLessThan(errs.max()!, 2.0)
        // a flip between the top edge and a cut face's bottom moves a corner by a band (2-4 px here)
        XCTAssertLessThan(jumps.max()!, 1.5)
    }

    /// The same frames turned a quarter, half and three quarter turn (landscape either way, as ARKit delivers them, and
    /// upside down: gravity pointing anywhere in the image) and seen in a mirror: still found, about as accurately, and
    /// the same outline whichever way up (the review found a half turn moved one corner 3.3 px).
    func testNoAssumptionAboutImageOrientation() throws {
        var upright = try Self.singles.flatMap { try SlabFrame.load($0) }
        var reference = measure(upright, options: SlabFinder.Options())
        var all: [Double] = []
        for (label, turn) in [("turned 90", { (f: SlabFrame) in f.rotatedClockwise() }),
                              ("turned 180", { (f: SlabFrame) in f.rotatedClockwise().rotatedClockwise() }),
                              ("turned 270", { (f: SlabFrame) in f.rotatedClockwise().rotatedClockwise().rotatedClockwise() }),
                              ("mirrored", { (f: SlabFrame) in f.mirrored() })] {
            #if DEBUG
            // a debug build sweeps about 50 times slower: there, after the quarter turn on every frame, the other turns
            // and the mirror run on three frames (among them the matched-tone floor, whose outline depended on the
            // sweep's order); a release build runs them all
            if label != "turned 90" && upright.count == Self.singles.count {
                let keep = ["rec_single_matchtone_concrete_d4", "rec_single_cradle_r14_d4", "rec_single_level_lined_up_d4"]
                upright = upright.filter { keep.contains($0.rec) }
                reference = measure(upright, options: SlabFinder.Options())
            }
            #endif
            let frames = upright.map(turn)
            let acc = measure(frames, options: SlabFinder.Options())
            print("\(label): " + acc.summary)
            XCTAssertEqual(acc.missed, [], label)
            XCTAssertLessThan(median(acc.corners), 0.8, label)
            XCTAssertLessThan(acc.corners.max()!, 2.5, label)
            XCTAssertLessThan(median(acc.normals), 2.0, label)
            XCTAssertLessThan(acc.normals.max()!, 3.5, label)
            // the same answer as upright, frame by frame (corners are compared as sorted errors against the truth)
            for (a, b) in zip(stride(from: 0, to: acc.corners.count, by: 4), stride(from: 0, to: reference.corners.count, by: 4)) {
                let ea = acc.corners[a..<(a + 4)].sorted(), eb = reference.corners[b..<(b + 4)].sorted()
                for k in 0..<4 { XCTAssertEqual(ea[k], eb[k], accuracy: 0.5, "\(label) frame \(a / 4)") }
            }
            all += acc.corners
        }
        print(String(format: "all orientations: corner error median %.2f px, worst %.2f px", median(all), all.max()!))
    }

    /// A tapped point grows the slab without needing the base; a predicted outline a few pixels off is followed.
    func testTappedPointAndPredictedOutline() throws {
        let f = try SlabFrame.load("rec_single_d3_t10_h0_mat")[0]
        let t = f.truthCorners!, mid = Geometry.centroid(t)
        let finder = SlabFinder()
        let tap = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, seed: mid)
        XCTAssertEqual(tap.count, 1)
        XCTAssertEqual(tap.first?.source, .tapped)
        if let c = tap.first { XCTAssertLessThan(f.cornerErrors(c.quad).max()!, 1.5) }
        // a tap off the slab finds nothing there
        XCTAssertEqual(finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, seed: Vec2(40, 60)).count, 0)
        // predicted outline 2-3 px off (the camera moved): followed, and the colour region agrees
        let near = t.enumerated().map { $0.element + Vec2(2.5 * cos(Double($0.offset)), 2.0 * sin(Double($0.offset) + 1)) }
        let tr = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, near: near)
        XCTAssertGreaterThanOrEqual(tr.count, 1)
        XCTAssertEqual(tr.first?.source, .tracked)
        for c in tr {
            XCTAssertLessThan(f.cornerErrors(c.quad).max()!, 1.5, "\(c.source)")
            // corners come back in the predicted outline's order
            XCTAssertEqual(Geometry.bestCorrespondence(c.quad, near).map, [0, 1, 2, 3])
        }
    }

    /// A finer image of the same view (the full-resolution luma around the slab) for the edge steps: the outline is
    /// found in the 270x480 frame, and its edges are placed on the 300x720 crop.
    func testDetailImageForEdges() throws {
        let f = try SlabFrame.load("rec_replay_still")[3] // frame 60 of the clip, which has a full-resolution crop
        let meta = (try Fixtures.json("balls/ball_crops.json") as! [[String: Any]]).first { ($0["file"] as! String) == "ball_d4_t10_h90_mat_60.pgm" }!
        let o = (meta["cropOrigin"] as! [NSNumber]).map { $0.doubleValue }
        let crop = Plane(pgm: try Data(contentsOf: Fixtures.root.appendingPathComponent("balls/ball_d4_t10_h90_mat_60.pgm")))!
        let KD = CameraIntrinsics(verticalFovDegrees: dbl(meta["fovDeg"]), width: 720, height: 1280)
            .cropped(x0: o[0], y0: o[1], scale: 1, width: crop.width, height: crop.height)
        // the crop's intrinsics describe the same camera as the frame's
        let p = Vec3(0.02, 0.1, 1.1)
        XCTAssertLessThan(ImageMap(from: f.intrinsics, to: KD).forward(f.intrinsics.project(p)!).distance(to: KD.project(p)!), 0.02)
        let finder = SlabFinder()
        let a = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down).first!
        let b = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, detail: DetailImage(luma: crop, intrinsics: KD)).first!
        let ea = f.cornerErrors(a.quad), eb = f.cornerErrors(b.quad)
        print(String(format: "detail image: corner errors %@ px (frame only %@ px), normal %.2f deg (frame only %.2f deg), modes %@",
                     eb.map { String(format: "%.2f", $0) }.joined(separator: " "), ea.map { String(format: "%.2f", $0) }.joined(separator: " "),
                     f.normalError(b.fit), f.normalError(a.fit), b.sides.map { $0.mode.rawValue }.joined(separator: " ")))
        XCTAssertLessThan(eb.max()!, 1.5)
        XCTAssertLessThan(f.normalError(b.fit), 2.5)
    }

    /// Time per find() on the 270x480 fixture frames: the unprompted search, and following a predicted outline.
    func testTimePerFind() throws {
        var frames = try Self.slabFrames()
        #if DEBUG
        frames = Array(frames.prefix(2)) // only the release build's numbers mean anything
        #endif
        let finder = SlabFinder()
        var sweep: [Double] = [], track: [Double] = []
        for f in frames {
            var t = Date()
            let c = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down).first
            sweep.append(Date().timeIntervalSince(t) * 1000)
            guard let c = c else { continue }
            t = Date()
            _ = finder.find(frame: f.frame, intrinsics: f.intrinsics, spec: f.spec, down: f.down, near: c.quad, choice: c.choice)
            track.append(Date().timeIntervalSince(t) * 1000)
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(format: "time per find() (%@ build, 270x480): unprompted median %.1f ms, worst %.1f ms; following an outline median %.1f ms, worst %.1f ms",
                     build, median(sweep), sweep.max()!, median(track), track.max()!))
        #if !DEBUG
        // a guard against blow-ups only (measured on a 2.1 GHz server core: about 50 ms and 10 ms)
        XCTAssertLessThan(median(sweep), 250)
        XCTAssertLessThan(median(track), 60)
        #endif
    }

    // MARK: synthetic box-like slabs

    /// The edge refiner on rendered boxes: from the outer outline a plain detector finds (the cut face's bottom on
    /// the sides where it shows), it returns the top face's corners, whether or not the top / cut-face edge is visible.
    func testRefinerReturnsTopEdgeWithAndWithoutInnerEdge() { checkRefinerReturnsTopEdgeWithAndWithoutInnerEdge(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`), refined with that profile.
    func testRefinerReturnsTopEdgeWithAndWithoutInnerEdgeOnSlopedSides() { checkRefinerReturnsTopEdgeWithAndWithoutInnerEdge(TestProfiles.sloped) }

    func checkRefinerReturnsTopEdgeWithAndWithoutInnerEdge(_ spec: SlabSpec) {
        for innerVisible in [true, false] {
            for (k, (pitch, heading, yaw)) in [(50.0, 30.0, 15.0), (35, 200, -25), (60, 120, 40)].enumerated() {
                let s = BoxScene(view: SyntheticView.make(pitch: pitch, distance: 0.8, tilt: 6, heading: heading, yaw: yaw, spec: spec, intrinsics: BoxScene.K),
                                 bandLuma: innerVisible ? 150 : 105)
                let frame = s.render()
                let outer = s.outerOutline().enumerated().map { $0.element + Vec2(0.4 * sin(Double($0.offset) * 2.1), 0.4 * cos(Double($0.offset) * 1.3)) }
                guard let r = EdgeRefiner().refine(outline: outer, frame: frame, intrinsics: s.view.intrinsics, spec: s.view.spec, down: s.view.down) else {
                    XCTFail("no result, case \(k) inner \(innerVisible)"); continue
                }
                let truth = s.view.corners
                let e = (0..<4).map { r.outline[$0].distance(to: truth[$0]) }, eOuter = (0..<4).map { outer[$0].distance(to: truth[$0]) }
                print(String(format: "  box case %d, inner edge %@: corners %@ px (outer outline %@ px), normal %.2f deg, modes %@", k, innerVisible ? "visible" : "hidden",
                             e.map { String(format: "%.2f", $0) }.joined(separator: " "), eOuter.map { String(format: "%.1f", $0) }.joined(separator: " "),
                             angleDeg(r.fit.pose.normal, s.view.pose.normal), r.sides.map { "\($0.mode.rawValue) \(String(format: "%.1f", $0.bandPixels))" }.joined(separator: ", ")))
                XCTAssertLessThan(e.max()!, 0.6, "case \(k) inner \(innerVisible)")
                XCTAssertLessThan(angleDeg(r.fit.pose.normal, s.view.pose.normal), 1.0)
                // the sides whose cut face shows were moved off the cut face's bottom
                for i in 0..<4 where s.bandVisible(side: i) {
                    let m = r.sides[i].mode
                    XCTAssertTrue(m == .innerEdge || m == .shiftedOuter, "case \(k) side \(i): \(m)")
                    if !innerVisible { XCTAssertEqual(m, .shiftedOuter, "case \(k) side \(i): no inner edge to see") }
                }
            }
        }
    }

    /// The whole finder on rendered boxes, with the phone held upright, sideways either way and upside down (gravity
    /// pointing anywhere in the image): found, on the top face's edges.
    func testFinderOnRenderedBoxAnyWayUp() { checkFinderOnRenderedBoxAnyWayUp(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`).
    func testFinderOnRenderedBoxAnyWayUpOnSlopedSides() { checkFinderOnRenderedBoxAnyWayUp(TestProfiles.sloped) }

    func checkFinderOnRenderedBoxAnyWayUp(_ spec: SlabSpec) {
        for roll in [0.0, 90, -90, 180] {
            for innerVisible in [true, false] {
                let s = BoxScene(view: SyntheticView.make(pitch: 48, roll: roll, distance: 0.8, tilt: 5, heading: 70, yaw: 25, spec: spec, intrinsics: BoxScene.K),
                                 bandLuma: innerVisible ? 150 : 105)
                let frame = s.render()
                let cs = SlabFinder().find(frame: frame, intrinsics: s.view.intrinsics, spec: s.view.spec, down: s.view.down)
                guard let c = cs.first else { XCTFail("roll \(roll) inner \(innerVisible): not found"); continue }
                let m = Geometry.bestCorrespondence(c.quad, s.view.corners).map
                let e = (0..<4).map { c.quad[$0].distance(to: s.view.corners[m[$0]]) }
                let ep = (0..<4).map { c.plainQuad[$0].distance(to: s.view.corners[m[$0]]) }
                print(String(format: "  roll %4.0f inner %@: corners %@ px (plain %@ px), normal %.2f deg", roll, innerVisible ? "visible" : "hidden",
                             e.map { String(format: "%.2f", $0) }.joined(separator: " "), ep.map { String(format: "%.1f", $0) }.joined(separator: " "),
                             angleDeg(c.fit.pose.normal, s.view.pose.normal)))
                XCTAssertLessThan(e.max()!, 0.8, "roll \(roll) inner \(innerVisible)")
                XCTAssertLessThan(angleDeg(c.fit.pose.normal, s.view.pose.normal), 1.0)
            }
        }
    }

    /// The edge choice follows the sides when the next outline starts at another corner or runs the other way round,
    /// and is dropped for an outline somewhere else.
    func testEdgeChoiceFollowsSides() {
        let q = [Vec2(100, 100), Vec2(160, 105), Vec2(155, 160), Vec2(98, 150)]
        let modes: [EdgeMode] = [.silhouette, .outerIsTop, .innerEdge, .shiftedOuter]
        let c = EdgeChoice(sides: modes.map { EdgeChoice.Side(mode: $0) }, outline: q, normal: nil)
        // same outline, started at corner 2 and running backwards: corners 2, 1, 0, 3
        let r = [q[2], q[1], q[0], q[3]].map { $0 + Vec2(1, -1) }
        let s = c.sides(matching: r)!
        // new side 0 runs from old corner 2 to old corner 1 = old side 1, and so on
        XCTAssertEqual(s.map { $0.mode }, [.outerIsTop, .silhouette, .shiftedOuter, .innerEdge])
        XCTAssertNil(c.sides(matching: q.map { $0 + Vec2(150, 0) }))
    }

    /// Hysteresis: a side's mode changes only after the new one has been seen on several calls in a row.
    func testModeHysteresis() {
        let o = EdgeRefiner.Options()
        var s = EdgeRefiner.update(nil, raw: .innerEdge, partnerScale: 1.1, options: o)
        XCTAssertEqual(s.mode, .innerEdge)
        XCTAssertEqual(s.bandScale, 1.1, accuracy: 1e-9)
        for raw in [EdgeMode.shiftedOuter, .shiftedOuter, .innerEdge, .shiftedOuter, .shiftedOuter] {
            s = EdgeRefiner.update(s, raw: raw, partnerScale: raw == .innerEdge ? 1.0 : nil, options: o)
            XCTAssertEqual(s.mode, .innerEdge, "noise does not flip it")
        }
        s = EdgeRefiner.update(s, raw: .shiftedOuter, partnerScale: nil, options: o)
        XCTAssertEqual(s.mode, .shiftedOuter, "three in a row do")
        // the learned band share moved toward the inner edges seen, within its limits
        XCTAssertEqual(s.bandScale, 1.1 + (1.0 - 1.1) * o.bandScaleRate, accuracy: 1e-9)
        // a side turning edge-on (hidden) follows the box model at once
        s = EdgeRefiner.update(s, raw: .silhouette, partnerScale: nil, options: o)
        XCTAssertEqual(s.mode, .silhouette)
    }
}

/// A box-like slab rendered from a synthetic view: a floor, the black base under the slab (a little bigger than it),
/// the cut faces the camera can see (a band of `bandLuma`) and the grey top face. Anti-aliased by supersampling.
struct BoxScene {
    /// ARKit's 1920x1440 image at a quarter size: landscape, as the camera delivers it
    static let K = CameraIntrinsics(fx: 362.5, fy: 362.5, cx: 240, cy: 180, width: 480, height: 360)
    /// the fixtures' processing frame: portrait 270x480 (the 720x1280 view's lens at three eighths)
    static let Kportrait = CameraIntrinsics(fx: 327.3187, fy: 327.3187, cx: 135, cy: 240, width: 270, height: 480)
    var view: SyntheticView
    var bandLuma: Float
    var topLuma: Float = 105
    var baseLuma: Float = 18
    var floorLuma: Float = 150
    /// the base's size against the slab's (below 1 the cut faces' bottoms meet the floor: the slab overhangs its base)
    var baseScale: Double = 1.08
    /// sensor noise (grey levels) and its seed
    var noise: Double = 1.2
    var seed: UInt64 = 11

    var box: SlabBoxView { SlabBoxView(pose: view.pose, spec: view.spec, intrinsics: view.intrinsics) }

    /// side i of the true outline (corner i to i+1) shows its cut face
    func bandVisible(side i: Int) -> Bool {
        let b = Geometry.predictBands(pose: view.pose, outline: view.corners, intrinsics: view.intrinsics, spec: view.spec)[i]
        return b.visible && (b.start + b.end) / 2 >= 1
    }

    /// The outline a plain detector finds: on sides whose cut face shows, the bottom of the cut face.
    func outerOutline() -> [Vec2] {
        let ls = box.outerOutlineLines!.map { Line2(p: $0.0, d: ($0.1 - $0.0).normalized) }
        return (0..<4).map { ls[($0 + 3) % 4].intersection(ls[$0])! }
    }

    func render() -> ColorFrame {
        let K = view.intrinsics, W = K.width, H = K.height
        let pose = view.pose, t = view.spec.thickness
        func proj(_ ps: [Vec3]) -> [Vec2] { ps.map { K.project($0)! } }
        let b = box
        // the base: 8% bigger than the slab (by default), from the slab's bottom down 1.3 in toward the floor (with a side
        // profile: from the bottom of the visible faces, where the cradle begins, 8% bigger than they reach)
        let baseTop: [Vec3]
        if view.spec.hasProfile {
            let c0 = pose.center - pose.normal * view.spec.drop
            baseTop = b.bottomCorners.map { c0 + ($0 - c0) * baseScale }
        } else {
            baseTop = slabCornerSigns.map { pose.center - pose.normal * t + pose.axisU * ($0.0 * pose.halfU * baseScale) + pose.axisV * ($0.1 * pose.halfV * baseScale) }
        }
        let baseBottom = baseTop.map { $0 + view.down.normalized * Units.inches(1.3) }
        let base = FinderRun.hull(proj(baseTop + baseBottom))
        // the sides: (polygon, luma). With no profile, the cut faces that show; with one, the rounded edge (in strips: the
        // part before the near feature angle lit like the top, the rest like the face; each strip drawn where it faces the
        // camera, so a hidden face's rounding ends at its tangent point) and the sloped face where it shows.
        var bands: [([Vec2], Float)] = []
        if view.spec.hasProfile {
            let sec = SideSection(spec: view.spec), c = b.topCorners, n = pose.normal
            let out = (0..<4).map { b.outward(side: $0) }
            let psiN = clamp(view.spec.nearFeatureAngle, 0, sec.faceAngle)
            // the arc's strips, about 0.15 rad each, with a cut at the near feature angle
            var cuts: [Double] = []
            if sec.radius > 0 {
                cuts = [0]
                if psiN > 1e-9 {
                    let k1 = max(1, Int((psiN / 0.15).rounded(.up)))
                    for q in 1...k1 { cuts.append(psiN * Double(q) / Double(k1)) }
                }
                let k2 = max(1, Int(((sec.faceAngle - psiN) / 0.15).rounded(.up)))
                for q in 1...k2 { cuts.append(psiN + (sec.faceAngle - psiN) * Double(q) / Double(k2)) }
            }
            for i in 0..<4 {
                let j = (i + 1) % 4, mi = out[(i + 3) % 4] + out[i], mj = out[i] + out[j]
                func at(_ k: Int, _ m: Vec3, _ x: Double, _ z: Double) -> Vec3 { c[k] + m * x + n * z }
                // the rounding shows up to where its normal turns away from the camera (at each end of the side)
                func silhouette(_ p: Vec3) -> Double {
                    let v = -p
                    let a = atan2(n.dot(v), -out[i].dot(v))
                    return a > 0 ? a : .infinity
                }
                let si = silhouette(c[i]), sj = silhouette(c[j])
                for s in 0..<max(0, cuts.count - 1) {
                    let ai = min(cuts[s], si), bi = min(cuts[s + 1], si), aj = min(cuts[s], sj), bj = min(cuts[s + 1], sj)
                    guard bi - ai > 1e-6 || bj - aj > 1e-6 else { continue }
                    let pa = sec.arc(ai), pb = sec.arc(bi), qa = sec.arc(aj), qb = sec.arc(bj)
                    bands.append((proj([at(i, mi, pa.x, pa.z), at(j, mj, qa.x, qa.z), at(j, mj, qb.x, qb.z), at(i, mi, pb.x, pb.z)]),
                                  cuts[s] < psiN ? topLuma : bandLuma))
                }
                if b.cutFaceVisible(side: i) {
                    let e = sec.arcEnd, bt = sec.bottom
                    bands.append((proj([at(i, mi, e.x, e.z), at(j, mj, e.x, e.z), at(j, mj, bt.x, bt.z), at(i, mi, bt.x, bt.z)]), bandLuma))
                }
            }
        } else {
            for i in 0..<4 where b.cutFaceVisible(side: i) {
                let j = (i + 1) % 4
                bands.append((proj([b.topCorners[i], b.topCorners[j], b.bottomCorners[j], b.bottomCorners[i]]), bandLuma))
            }
        }
        let top = proj(b.topCorners)
        func inside(_ p: Vec2, _ q: [Vec2]) -> Bool {
            var sign = 0.0
            for i in 0..<q.count {
                let z = (q[(i + 1) % q.count] - q[i]).cross(p - q[i])
                if z == 0 { continue }
                if sign == 0 { sign = z } else if (z > 0) != (sign > 0) { return false }
            }
            return true
        }
        func shade(_ p: Vec2) -> (Float, Float, Float) {
            if inside(p, top) { return (topLuma, -6, 4) }
            for q in bands where inside(p, q.0) { return (q.1, -6, 4) }
            if inside(p, base) { return (baseLuma, 0, 0) }
            return (floorLuma, -20, 25)
        }
        // every polygon edge, to supersample only the pixels an edge passes near
        var segs: [(Vec2, Vec2)] = []
        for q in [top, base] + bands.map({ $0.0 }) { for i in 0..<q.count { segs.append((q[i], q[(i + 1) % q.count])) } }
        func nearEdge(_ p: Vec2) -> Bool {
            segs.contains { a, b in
                let d = b - a, t = clamp((p - a).dot(d) / max(d.dot(d), 1e-12), 0, 1)
                return (a + d * t).distance(to: p) < 0.8
            }
        }
        let ss = 4
        var y = [Float](repeating: 0, count: W * H), cb = y, cr = y
        var rng = SeededRandom(seed)
        // outside the box around every polygon it is all floor
        let all = top + base + bands.flatMap { $0.0 }
        let bx0 = (all.map { $0.x }.min() ?? 0) - 2, bx1 = (all.map { $0.x }.max() ?? 0) + 2
        let by0 = (all.map { $0.y }.min() ?? 0) - 2, by1 = (all.map { $0.y }.max() ?? 0) + 2
        for py in 0..<H {
            for px in 0..<W {
                var sl: Float = 0, sb: Float = 0, sr: Float = 0
                let centre = Vec2(Double(px) + 0.5, Double(py) + 0.5)
                var n: Float = 1
                if centre.x < bx0 || centre.x > bx1 || centre.y < by0 || centre.y > by1 {
                    sl = floorLuma; sb = -20; sr = 25
                } else if nearEdge(centre) {
                    for sy in 0..<ss {
                        for sx in 0..<ss {
                            let s = shade(Vec2(Double(px) + (Double(sx) + 0.5) / Double(ss), Double(py) + (Double(sy) + 0.5) / Double(ss)))
                            sl += s.0; sb += s.1; sr += s.2
                        }
                    }
                    n = Float(ss * ss)
                } else {
                    let s = shade(centre)
                    sl = s.0; sb = s.1; sr = s.2
                }
                let i = py * W + px
                y[i] = sl / n + Float(rng.gaussian() * noise); cb[i] = sb / n; cr[i] = sr / n
            }
        }
        return ColorFrame(y: Plane(width: W, height: H, data: y), cb: Plane(width: W, height: H, data: cb), cr: Plane(width: W, height: H, data: cr))
    }
}
