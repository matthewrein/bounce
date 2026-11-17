import XCTest
@testable import BounceCore

final class KitFormatsTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kitformats-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func keys(_ data: Data) throws -> Set<String> {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Set(obj?.keys.map { $0 } ?? [])
    }

    func fullFrame() -> KitFrame {
        let pose = RigidTransform(rotation: Mat3(rows: [0, -1, 0, 1, 0, 0, 0, 0, 1]), translation: Vec3(0.5, 1.25, -2)).columnMajor4x4.map(Float.init)
        return KitFrame(index: 7, time: 12345.678901, pose: pose, intrinsics: [900, 901, 640, 480], tracking: .limitedExcessiveMotion,
                        exposure: 0.008, exposureOffset: -0.5, ambientLumens: 950, colorTemperature: 4100, luma: 101.5, blur: 1.25,
                        depthFile: "d000007.bdp2",
                        live: KitLiveResult(state: .locked, tilt: 5.2, corners: [Vec2(1, 2), Vec2(3, 4), Vec2(5, 6), Vec2(7, 8)],
                                            ball: (Vec2(100, 200), 12.5)))
    }

    func testFrameKeysAreTheDocsShortKeys() throws {
        let enc = JSONEncoder()
        XCTAssertEqual(try keys(enc.encode(fullFrame())), ["i", "t", "pose", "K", "track", "exp", "expOff", "amb", "ct", "luma", "blur", "depth", "live"])
        let minimal = KitFrame(index: 0, time: 1, pose: RigidTransform.identity.columnMajor4x4.map(Float.init), intrinsics: [1, 1, 0, 0])
        XCTAssertEqual(try keys(enc.encode(minimal)), ["i", "t", "pose", "K", "track"], "nil optionals are left out")
        var nanFrame = minimal
        nanFrame.luma = .nan; nanFrame.blur = .infinity; nanFrame.exposure = 0.01
        XCTAssertEqual(try keys(enc.encode(nanFrame)), ["i", "t", "pose", "K", "track", "exp"], "non-finite optionals are left out")
        let json = String(decoding: try enc.encode(fullFrame()), as: UTF8.self)
        XCTAssertTrue(json.contains("\"track\":\"limited:excessiveMotion\""))
        let live = try keys(enc.encode(fullFrame().live))
        XCTAssertEqual(live, ["state", "tilt", "corners", "ball"])
    }

    func testFrameRoundTripAndGeometry() throws {
        let f = fullFrame()
        let back = try JSONDecoder().decode(KitFrame.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
        let t = try XCTUnwrap(back.worldFromCamera)
        XCTAssertEqual(t.translation.distance(to: Vec3(0.5, 1.25, -2)), 0, accuracy: 1e-6)
        let k = try XCTUnwrap(back.cameraIntrinsics(videoWidth: 1280, videoHeight: 960))
        XCTAssertEqual(k.fx, 900); XCTAssertEqual(k.cy, 480); XCTAssertEqual(k.width, 1280)
        let v = try XCTUnwrap(back.view(videoWidth: 1280, videoHeight: 960))
        // CV axes: z forward is ARKit's -z
        XCTAssertEqual(v.worldFromCamera.rotation.column(2).distance(to: -(t.rotation.column(2))), 0, accuracy: 1e-6)
        XCTAssertEqual(back.live?.cornerPoints, [Vec2(1, 2), Vec2(3, 4), Vec2(5, 6), Vec2(7, 8)])
        XCTAssertEqual(back.live?.ballCircle?.radius, 12.5)
        XCTAssertEqual(back.live?.slabFound, true)
        var bad = f
        bad.pose = [1, 2, 3]
        bad.intrinsics = [Float.nan, 1, 1, 1]
        XCTAssertNil(bad.worldFromCamera)
        XCTAssertNil(bad.cameraIntrinsics(videoWidth: 10, videoHeight: 10))
        XCTAssertNil(bad.view(videoWidth: 10, videoHeight: 10))
        XCTAssertEqual(KitLiveResult(state: .searching).slabFound, false)
        XCTAssertNil(KitLiveResult(state: .confirming, corners: [Vec2(1, 1)]).cornerPoints)
    }

    func testNonFiniteLiveNumbersAreLeftOutNotThrown() throws {
        // a degenerate pose on one frame: NaN tilt, an infinite corner, a NaN ball radius
        let url = tmp.appendingPathComponent(KitClipFiles.frames)
        let w = try KitJSONLWriter(url: url)
        let pose = RigidTransform.identity.columnMajor4x4.map(Float.init)
        let lives = [KitLiveResult(state: .locked, tilt: .nan, corners: [Vec2(1, 2), Vec2(.infinity, 3), Vec2(5, 6), Vec2(7, 8)], ball: (Vec2(1, 2), .nan)),
                     KitLiveResult(state: .confirming, tilt: .infinity, ball: (Vec2(.nan, 2), 3)),
                     KitLiveResult(state: .locked, tilt: 4.5, corners: [Vec2(1, 2), Vec2(3, 4), Vec2(5, 6), Vec2(7, 8)], ball: (Vec2(1, 2), 3))]
        for (i, l) in lives.enumerated() {
            try w.append(KitFrame(index: i, time: Double(i), pose: pose, intrinsics: [1, 1, 0, 0], luma: .nan, blur: .infinity, live: l))
        }
        try w.close()
        let back = try KitJSONL.read(KitFrame.self, from: url)
        XCTAssertEqual(back.map { $0.index }, [0, 1, 2], "line n is still video frame n")
        XCTAssertEqual(back[0].live?.state, .locked)
        XCTAssertNil(back[0].live?.tilt); XCTAssertNil(back[0].live?.corners); XCTAssertNil(back[0].live?.ball)
        XCTAssertEqual(back[1].live?.state, .confirming)
        XCTAssertNil(back[1].live?.tilt); XCTAssertNil(back[1].live?.ball)
        XCTAssertEqual(back[2].live, lives[2], "finite values are kept")
        XCTAssertEqual(try keys(JSONEncoder().encode(lives[0])), ["state"])
    }

    func testUnknownLiveStatesStillRead() throws {
        // a newer app's tracker state: the frame (and so the clip) still reads, and the spelling survives
        let line = #"{"i":0,"t":1,"pose":[],"K":[],"track":"normal","live":{"state":"lost","tilt":3}}"#
        let f = try JSONDecoder().decode(KitFrame.self, from: Data(line.utf8))
        XCTAssertEqual(f.live?.state, .other("lost"))
        XCTAssertEqual(f.live?.state.rawValue, "lost")
        XCTAssertEqual(f.live?.slabFound, false)
        XCTAssertEqual(f.live?.tilt, 3)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(f.live), as: UTF8.self).contains(#""state":"lost""#))
        XCTAssertEqual(try KitJSONL.decode(KitFrame.self, from: Data((line + "\n" + line + "\n").utf8)).items.count, 2)
        for (t, k) in [(TrackerState.searching, KitLiveState.searching), (.confirming, .confirming), (.locked, .locked)] {
            XCTAssertEqual(KitLiveState(t), k)
            XCTAssertEqual(KitLiveState(rawValue: t.rawValue), k)
            XCTAssertEqual(k.rawValue, t.rawValue)
        }
        XCTAssertTrue(KitLiveResult(state: .confirming).slabFound)
        XCTAssertTrue(KitLiveResult(state: KitLiveState(TrackerState.locked)).slabFound)
    }

    func testClipFileNames() {
        let shot = URL(fileURLWithPath: "/kits/k/shots/s02-scan")
        XCTAssertEqual([KitClipFiles.video, KitClipFiles.frames, KitClipFiles.motion, KitClipFiles.shotManifest, KitClipFiles.depthFolder],
                       ["video.mp4", "frames.jsonl", "motion.jsonl", "shot.json", "depth"])
        XCTAssertEqual(KitClipFiles.shotManifest, KitStore.shotManifestFile)
        XCTAssertEqual(KitClipFiles.depthURL(shotFolder: shot, frame: 42).path, "/kits/k/shots/s02-scan/depth/d000042.bdp2")
        var f = KitFrame(index: 42, time: 0, pose: [], intrinsics: [], depthFile: KitDepth.fileName(frame: 42))
        XCTAssertEqual(f.depthURL(shotFolder: shot), KitClipFiles.depthURL(shotFolder: shot, frame: 42))
        f.depthFile = nil
        XCTAssertNil(f.depthURL(shotFolder: shot))
    }

    func testTrackingReadsUnknownValues() throws {
        func dec(_ s: String) throws -> KitTracking { try JSONDecoder().decode([KitTracking].self, from: Data("[\"\(s)\"]".utf8))[0] }
        for t in KitTracking.allCases { XCTAssertEqual(try dec(t.rawValue), t) }
        XCTAssertEqual(try dec("limited:somethingNew"), .limitedOther)
        XCTAssertEqual(try dec("weird"), .notAvailable)
        XCTAssertTrue(KitTracking.normal.isNormal)
        XCTAssertFalse(KitTracking.limitedRelocalizing.isNormal)
    }

    func testMotionSampleFormat() throws {
        let q = KitQuaternion(axis: Vec3(0.2, -0.3, 1), angle: 2.5)
        let s = KitMotionSample(time: 100.123456789, gravity: Vec3(0.012345678, -0.0234567891, -0.999), userAcceleration: Vec3(0.001, 0, -0.002),
                                rotationRate: Vec3(0.01, -0.02, 0.0300000004), attitude: q)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try keys(data), ["t", "g", "ua", "rr", "q"])
        let back = try JSONDecoder().decode(KitMotionSample.self, from: data)
        XCTAssertEqual(back.time, s.time, accuracy: 1e-5)
        XCTAssertEqual(back.gravity.distance(to: s.gravity), 0, accuracy: 1e-6)
        XCTAssertEqual(back.rotationRate.distance(to: s.rotationRate), 0, accuracy: 1e-6)
        XCTAssertEqual(abs(back.attitude.dot(q)), 1, accuracy: 1e-6)
        // written rounded: 1e-6 for vectors, 10 microseconds for time (short lines, far below the sensors' noise)
        XCTAssertEqual(back.gravity.x, 0.012346)
        XCTAssertEqual(back.gravity.y, -0.023457)
        XCTAssertEqual(back.time, 100.12346)
        // arrays must have the right length
        let bad = Data(#"{"t":1,"g":[0,0],"ua":[0,0,0],"rr":[0,0,0],"q":[0,0,0,1]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KitMotionSample.self, from: bad))
        let badQ = Data(#"{"t":1,"g":[0,0,-1],"ua":[0,0,0],"rr":[0,0,0],"q":[0,0,1]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(KitMotionSample.self, from: badQ))
    }

    func testQuaternion() {
        var rng = KitTestRandom(seed: 7)
        for i in 0..<200 {
            let axis = Vec3(rng.gauss(), rng.gauss(), rng.gauss())
            // include angles near 0 and near 180 degrees
            let angle = i < 20 ? Double.pi - 1e-7 * Double(i) : (i < 40 ? 1e-9 * Double(i) : rng.uniform() * .pi)
            let q = KitQuaternion(axis: axis, angle: angle)
            let v = Vec3(rng.gauss(), rng.gauss(), rng.gauss())
            XCTAssertEqual(q.rotate(v).distance(to: v.rotated(by: axis.normalized * angle)), 0, accuracy: 1e-9)
            let back = KitQuaternion(matrix: q.matrix)
            XCTAssertEqual(abs(back.dot(q)), 1, accuracy: 1e-9, "matrix round trip at angle \(angle)")
            XCTAssertEqual(q.angle, angle, accuracy: 1e-7)
            let rv = q.rotationVector
            XCTAssertEqual(KitQuaternion(rotationVector: rv).rotate(v).distance(to: q.rotate(v)), 0, accuracy: 1e-9)
            let p = KitQuaternion(axis: Vec3(rng.gauss(), rng.gauss(), rng.gauss()), angle: rng.uniform() * 3)
            XCTAssertEqual((p * q).rotate(v).distance(to: p.rotate(q.rotate(v))), 0, accuracy: 1e-9, "a * b rotates by b, then a")
            XCTAssertEqual((q.conjugate * q).angle, 0, accuracy: 1e-7)
        }
        XCTAssertEqual(KitQuaternion.identity.matrix, Mat3.identity)
        XCTAssertEqual(KitQuaternion(rotationVector: .zero), .identity)
        XCTAssertEqual(KitQuaternion(x: 0, y: 0, z: 0, w: 0).normalized, .identity)
    }

    func testJSONLWriterAndReader() throws {
        let url = tmp.appendingPathComponent("motion.jsonl")
        let w = try KitJSONLWriter(url: url, bufferSize: 300)
        var samples: [KitMotionSample] = []
        for i in 0..<500 {
            let s = KitMotionSample(time: Double(i) / 100, gravity: Vec3(0, 0.01 * Double(i % 7), -1), rotationRate: Vec3(0, 0, 0.001 * Double(i)))
            samples.append(s)
            try w.append(s)
        }
        XCTAssertEqual(w.lineCount, 500)
        // the buffer has been written out in pieces already
        XCTAssertGreaterThan(KitFiles.fileSize(url.path), 0)
        try w.close()
        try w.close() // twice is fine
        XCTAssertThrowsError(try w.append(samples[0])) { XCTAssertEqual($0 as? KitFormatError, .closed) }
        let back = try KitJSONL.read(KitMotionSample.self, from: url)
        XCTAssertEqual(back.count, 500)
        XCTAssertEqual(back[499].rotationRate.z, 0.499, accuracy: 1e-9)
        XCTAssertEqual(back.map { $0.time }, samples.map { $0.time })
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 500)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testJSONLToleratesATruncatedLastLine() throws {
        let url = tmp.appendingPathComponent("frames.jsonl")
        let w = try KitJSONLWriter(url: url)
        for i in 0..<3 { try w.append(KitFrame(index: i, time: Double(i), pose: [Float](repeating: 0, count: 16), intrinsics: [1, 1, 0, 0])) }
        try w.close()
        // the app was killed half-way through writing the next line
        let h = try FileHandle(forWritingTo: url)
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"i":3,"t":3,"pose":[0,0,"#.utf8))
        try h.close()
        let r = try KitJSONL.decode(KitFrame.self, from: Data(contentsOf: url))
        XCTAssertEqual(r.items.map { $0.index }, [0, 1, 2])
        XCTAssertTrue(r.droppedLastLine)
        XCTAssertEqual(try KitJSONL.read(KitFrame.self, from: url).count, 3)
        // a complete last line without its newline still counts
        let ok = Data("{\"i\":0,\"t\":0,\"pose\":[],\"K\":[],\"track\":\"normal\"}\n\n{\"i\":1,\"t\":1,\"pose\":[],\"K\":[],\"track\":\"normal\"}".utf8)
        let r2 = try KitJSONL.decode(KitFrame.self, from: ok)
        XCTAssertEqual(r2.items.count, 2); XCTAssertFalse(r2.droppedLastLine)
        XCTAssertEqual(try KitJSONL.decode(KitFrame.self, from: Data()).items.count, 0)
    }

    func testJSONLBadMiddleLineThrows() {
        let data = Data("{\"t\":1,\"g\":[0,0,-1],\"ua\":[0,0,0],\"rr\":[0,0,0],\"q\":[0,0,0,1]}\nnot json\n{\"t\":2,\"g\":[0,0,-1],\"ua\":[0,0,0],\"rr\":[0,0,0],\"q\":[0,0,0,1]}\n".utf8)
        XCTAssertThrowsError(try KitJSONL.decode(KitMotionSample.self, from: data, name: "motion.jsonl")) {
            XCTAssertEqual($0 as? KitFormatError, .badLine(file: "motion.jsonl", line: 2))
        }
        // a cut-short line that does end in a newline is not the app being killed: it throws
        XCTAssertThrowsError(try KitJSONL.decode(KitMotionSample.self, from: Data("{\"t\":1,\n".utf8)))
    }

    func testJSONLWriterThrowsOnIOErrors() {
        XCTAssertThrowsError(try KitJSONLWriter(url: tmp.appendingPathComponent("missing/dir/x.jsonl")))
        XCTAssertThrowsError(try KitJSONL.read(KitFrame.self, from: tmp.appendingPathComponent("none.jsonl")))
        // NaN cannot be written as JSON: append throws rather than writing a bad line
        let w = try? KitJSONLWriter(url: tmp.appendingPathComponent("n.jsonl"))
        XCTAssertThrowsError(try w?.append(KitMotionSample(time: .nan, gravity: Vec3(0, 0, -1))))
        XCTAssertEqual(w?.lineCount, 0)
    }

    func testBDP2RoundTrip() throws {
        let d = DepthMap(width: 4, height: 2, depth: [0, 0.5, 1.2345, Float.nan, Float.infinity, -1, 70, 65.535],
                         confidence: [0, 1, 2, 2, 1, 0, 2, 1])
        let k = try KitDepth(depthMap: d)
        XCTAssertEqual(k.millimetres, [0, 500, 1235, 0, 0, 0, 0, 65535])
        let data = k.data
        XCTAssertEqual(data.count, 8 + 8 * 3, "a third of BDP1's 5 bytes per pixel, roughly")
        XCTAssertEqual(Array(data.prefix(4)), Array("BDP2".utf8))
        XCTAssertEqual(Array(data[4..<8]), [4, 0, 2, 0])
        let back = try KitDepth(data: data)
        XCTAssertEqual(back, k)
        let m = back.depthMap
        XCTAssertEqual(m.width, 4); XCTAssertEqual(m.height, 2)
        XCTAssertTrue(m.depth[0].isNaN); XCTAssertTrue(m.depth[3].isNaN); XCTAssertTrue(m.depth[6].isNaN)
        XCTAssertEqual(m.depth[2], 1.235, accuracy: 1e-6)
        XCTAssertEqual(m.depth[7], 65.535, accuracy: 1e-4)
        XCTAssertEqual(m.confidence, d.confidence)
        XCTAssertEqual(KitDepth.millimetres(fromMetres: 65.5354), 65535)
        XCTAssertEqual(KitDepth.millimetres(fromMetres: 65.5356), 0)
        XCTAssertEqual(KitDepth.millimetres(fromMetres: 0.0004), 0)
        XCTAssertEqual(KitDepth.fileName(frame: 42), "d000042.bdp2")
        let video = CameraIntrinsics(fx: 1000, fy: 1000, cx: 640, cy: 480, width: 1280, height: 960)
        let big = try KitDepth(width: 256, height: 192, millimetres: [UInt16](repeating: 1000, count: 256 * 192), confidence: [UInt8](repeating: 2, count: 256 * 192))
        let di = big.intrinsics(video: video)
        XCTAssertEqual(di.fx, 200); XCTAssertEqual(di.cx, 128); XCTAssertEqual(di.height, 192)
    }

    func testBDP2RejectsBadData() {
        XCTAssertThrowsError(try KitDepth(data: Data([1, 2, 3])))
        XCTAssertThrowsError(try KitDepth(data: DepthMap(width: 1, height: 1, depth: [1], confidence: [2]).data), "BDP1 is not BDP2")
        let good = (try? KitDepth(width: 2, height: 2, millimetres: [1, 2, 3, 4], confidence: [0, 0, 0, 0]))?.data ?? Data()
        XCTAssertThrowsError(try KitDepth(data: good.dropLast()), "cut short")
        XCTAssertThrowsError(try KitDepth(data: Data("BDP2".utf8) + Data([0, 0, 1, 0])), "empty")
        XCTAssertThrowsError(try KitDepth(width: 2, height: 2, millimetres: [1], confidence: [0, 0, 0, 0]))
        XCTAssertThrowsError(try KitDepth(width: 70000, height: 1, millimetres: [], confidence: []))
    }
}

/// A small deterministic random number generator for the kit tests.
struct KitTestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// uniform in [0, 1)
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// standard normal
    mutating func gauss() -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
