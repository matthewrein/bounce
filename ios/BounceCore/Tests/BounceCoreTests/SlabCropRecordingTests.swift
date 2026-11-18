import XCTest
@testable import BounceCore

/// A CornerCodeImage detector whose outlines also depend on the full-resolution crop it is given (its pixels and where
/// its intrinsics put it), and whose refine pass moves the find by an amount the crop decides: a replay matches the phone
/// only if it hands the detector the very crops the phone's tracker cut, on the same frames.
final class CornerCodeDetailDetector: SlabDetecting {
    private(set) var calls = 0, detailCalls = 0, refineCalls = 0
    private(set) var shifts: [Double] = []

    /// 0.08-0.38 px, from the crop's pixels and placement
    static func shift(_ d: DetailImage) -> Double {
        let sum = d.luma.data.reduce(0.0) { $0 + Double($1) }
        let a = sum.truncatingRemainder(dividingBy: 997) / 997, b = abs(d.intrinsics.cx.truncatingRemainder(dividingBy: 7)) / 7
        return 0.08 + 0.15 * a + 0.15 * b
    }

    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        detect(frame: frame, intrinsics: intrinsics, spec: spec, down: down, seed: seed, near: near, detail: nil)
    }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?,
                detail: DetailImage?) -> [DetectedOutline] {
        calls += 1
        guard let q = CornerCodeImage.decode(frame) else { return [] }
        var d = 0.0
        if let di = detail { detailCalls += 1; d = CornerCodeDetailDetector.shift(di); shifts.append(d) }
        return [DetectedOutline(quad: q.map { $0 + Vec2(d, -d) }, score: 1, sideModes: ["top", "top", "top", "top"])]
    }
    func refine(outline: [Vec2], frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, detail: DetailImage) -> [DetectedOutline] {
        refineCalls += 1
        let d = CornerCodeDetailDetector.shift(detail)
        shifts.append(-d)
        return [DetectedOutline(quad: outline.map { $0 + Vec2(-d, d) }, score: 1, sideModes: ["top", "top", "top", "top"])]
    }
}

/// The slab's full-resolution crops in recordings: kept exactly on the frames whose detector run used one, and fed back
/// by the replay, so a replay of a new recording runs what the phone ran; recordings without them replay as before.
final class SlabCropRecordingTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bouncecore-slabcrop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func sim() -> AppLoopSim {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var s = AppLoopSim(world: World(slab: slab, lens: .processing))
        s.ball = slab.center + Vec3(0.01, 0.35, -0.005)
        s.slabCrops = true
        s.duration = 5
        return s
    }

    func testThePhonesSlabCropsReplayExactly() throws {
        let folder = tmp.appendingPathComponent("crops.bouncerec")
        var phoneDetectors: [CornerCodeDetailDetector] = []
        var s = sim()
        s.makeDetector = { let d = CornerCodeDetailDetector(); phoneDetectors.append(d); return d }
        let phone = try s.run(recordingTo: folder)
        let rec = try RecordingReader(folder: folder)
        // the recording holds a crop on every frame whose detector run used one, and only there
        let withCrop = rec.frames.filter { $0.output?.slabCrop != nil }
        XCTAssertGreaterThan(withCrop.count, 10)
        XCTAssertTrue(withCrop.allSatisfy { $0.slabFile != nil && $0.slabIntrinsics != nil && $0.output?.detections != nil && $0.hasImage })
        XCTAssertTrue(rec.frames.filter { $0.output?.slabCrop == nil }.allSatisfy { $0.slabFile == nil && $0.slabIntrinsics == nil })
        XCTAssertTrue(rec.frames.contains { $0.output?.refinedDetections != nil }, "a search's refine pass")
        // the pixels read back exactly as the phone's tracker had them
        for (f, o) in zip(rec.frames, phone.outputs) where o.slabDetail != nil {
            XCTAssertEqual(try rec.slab(for: f), o.slabDetail?.luma, "frame \(f.index)")
            XCTAssertEqual(f.slabIntrinsics, o.slabDetail?.intrinsics)
            XCTAssertEqual(f.output?.slabCrop, o.slabDetail?.crop)
        }
        XCTAssertEqual(phoneDetectors.count, 1)
        let pd = phoneDetectors[0]
        XCTAssertGreaterThan(pd.detailCalls, 5); XCTAssertGreaterThanOrEqual(pd.refineCalls, 1)

        // the replay: the same crops on the same frames, so the same outlines and the same lock
        let det = CornerCodeDetailDetector()
        let r = try ReplayRunner(reader: rec).replay(detector: det, ballLocator: DiscBallLocator())
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertTrue(r.report.substitutionCounts.isEmpty, r.report.description)
        XCTAssertEqual(det.calls, pd.calls); XCTAssertEqual(det.detailCalls, pd.detailCalls); XCTAssertEqual(det.refineCalls, pd.refineCalls)
        XCTAssertEqual(det.shifts, pd.shifts, "the detector saw the very crops the phone's did")
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
        XCTAssertEqual(r.tracker.counts, phone.tracker.counts)

        // a detector that ignores the crops does not reproduce the phone, and the report says where
        let r2 = try ReplayRunner(reader: rec).replay(detector: CornerCodeDetector(), ballLocator: DiscBallLocator())
        XCTAssertFalse(r2.report.agrees)
        XCTAssertNotNil(r2.report.differenceCounts["detections"], r2.report.description)
    }

    func testMissingSlabPixelsAreReplacedByThePhonesOutlines() throws {
        let folder = tmp.appendingPathComponent("drop.bouncerec")
        var s = sim()
        s.makeDetector = { CornerCodeDetailDetector() }
        let phone = try s.run(recordingTo: folder, dropPixels: Set(stride(from: 2, to: 400, by: 5)))
        let rec = try RecordingReader(folder: folder)
        XCTAssertTrue(rec.frames.contains { $0.output?.slabCrop != nil && $0.slabFile == nil && $0.slabIntrinsics != nil })
        let r = try ReplayRunner(reader: rec).replay(detector: CornerCodeDetailDetector(), ballLocator: DiscBallLocator())
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertGreaterThan(r.report.substitutionCounts["detections"] ?? 0, 0, r.report.description)
        XCTAssertTrue(r.steps.contains { $0.substitutions.contains { $0.contains("no slab crop recorded") || $0.contains("no image recorded") } })
        XCTAssertEqual(r.tracker.slab, phone.tracker.slab)
    }

    func testARecordingWithoutCropsReplaysAsBefore() throws {
        // the same session without the camera's pixels (as every recording made before them): no crop is cut on the
        // phone or in the replay, and the replay matches it exactly
        let folder = tmp.appendingPathComponent("plain.bouncerec")
        var s = sim(); s.slabCrops = false
        s.makeDetector = { CornerCodeDetailDetector() }
        _ = try s.run(recordingTo: folder)
        let rec = try RecordingReader(folder: folder)
        XCTAssertTrue(rec.frames.allSatisfy { $0.output?.slabCrop == nil && $0.slabFile == nil && $0.output?.refinedDetections == nil })
        let det = CornerCodeDetailDetector()
        let r = try ReplayRunner(reader: rec).replay(detector: det, ballLocator: DiscBallLocator())
        XCTAssertTrue(r.report.agrees, r.report.description)
        XCTAssertEqual(det.detailCalls, 0); XCTAssertEqual(det.refineCalls, 0)
        // frames.jsonl has no slab fields at all (an older reader sees nothing new)
        let lines = try String(contentsOf: folder.appendingPathComponent("frames.jsonl"), encoding: .utf8)
        for key in ["slabFile", "slabIntrinsics", "slabCrop", "refinedDetections"] { XCTAssertFalse(lines.contains(key), key) }
    }

    func testOlderFrameLinesStillDecode() throws {
        // a version 2 line written before the slab crops: no slabFile, slabIntrinsics, slabCrop or refinedDetections
        let line = #"{"index":3,"timestamp":1.5,"file":"","worldFromCamera":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"intrinsics":{"fx":362.5,"fy":362.5,"cx":240,"cy":180,"width":480,"height":360},"trackingNormal":true,"output":{"state":"locked","detections":[{"quad":[[1,2],[3,4],[5,6],[7,8]],"score":1}]}}"#
        let f = try JSONDecoder().decode(RecordedFrame.self, from: Data(line.utf8))
        XCTAssertNil(f.slabFile); XCTAssertNil(f.slabIntrinsics); XCTAssertNil(f.output?.slabCrop); XCTAssertNil(f.output?.refinedDetections)
        XCTAssertEqual(f.output?.detections?.count, 1)
    }
}
