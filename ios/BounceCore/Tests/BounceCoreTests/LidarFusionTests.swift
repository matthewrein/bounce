import XCTest
@testable import BounceCore

/// LiDAR folded into the lock (n11): the app keeps the picture's tilt (its depth plane's normal has weight 0) and uses
/// LiDAR's range for the centre; settings from before n11 read back with the old behaviour.
final class LidarFusionTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    /// A depth plane with LiDAR-like errors (turned 5 deg toward level, 12 mm nearer along the line of sight: the kit's
    /// depth planes were a median 4.9 deg off and 1-2% of the range off): with the app's weights the lock's normal is the
    /// picture's exactly and its centre moves half way to LiDAR's range; with the old weights (0.5 on the normal too) the
    /// same plane turns the tilt by about 2.5 deg.
    func testTheAppsLidarMovesOnlyTheCentre() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.0), tilt: 9, heading: 120))
        let cam = Vec3(0, 0.8, 0)
        let los = (w.slab.center - cam).normalized
        var lidarWorld = w
        lidarWorld.slab = World.slabAt(w.slab.center - los * 0.012, tilt: 4, heading: 120)
        XCTAssertEqual(Units.degrees(lidarWorld.slab.normal.angle(to: w.slab.normal)), 5, accuracy: 0.01)
        let v = w.view(from: cam, at: w.slab.center)
        let dm = lidarWorld.depthMap(v, spec: .standard)

        func run(_ s: TrackerSettings) -> (out: TrackerOutput, tracker: SlabTracker, events: [String]) {
            let det = TruthDetector(w); det.noise = 0
            let tr = SlabTracker(settings: s, detector: det)
            var o: TrackerOutput! = nil, events: [String] = []
            for k in 0..<6 {
                det.currentView = v
                o = tr.process(TrackerFrame(timestamp: Double(k) * 0.11, view: v, frame: blank, depth: dm.0, depthIntrinsics: dm.1))
                events += o.events
            }
            return (o, tr, events)
        }

        var app = RecordingSettings().trackerSettings
        app.recheckInterval = 0.1
        // the World's slab (the test is about LiDAR's weights; with the app's own slab size the picture's range would be
        // off by the two sizes' ratio)
        app.spec = .standard
        XCTAssertEqual(app.depthNormalWeight, 0)
        XCTAssertEqual(app.depthCentreWeight, 0.5)
        let a = run(app)
        let img = try XCTUnwrap(a.tracker.imageSlab), fused = try XCTUnwrap(a.out.slab)
        // the depth check passed its gates and fusion ran, centre only (the event is kept)
        XCTAssertTrue(a.out.depthFused)
        XCTAssertEqual(a.events.filter { $0 == "depth-fused" }.count, 1)
        XCTAssertEqual(a.tracker.depthChecks.used, a.tracker.depthChecks.checks)
        XCTAssertGreaterThan(a.tracker.depthChecks.checks, 0)
        XCTAssertEqual(a.tracker.depthChecks.angleDegrees.median, 5, accuracy: 0.3)
        // the normal and in-plane axes are the picture's, exactly
        XCTAssertEqual(fused.normal, img.normal)
        XCTAssertEqual(fused.axisU, img.axisU)
        // the centre moved half the 12 mm toward the camera, along the line of sight
        let moved = fused.center - img.center
        XCTAssertEqual(moved.length, 0.006, accuracy: 0.0015)
        XCTAssertGreaterThan(-moved.normalized.dot(los), 0.95, "the centre moves along the line of sight, toward the camera")
        // LiDAR reads the range about 1.2% short: k = LiDAR's range over the picture's
        XCTAssertEqual(a.tracker.depthChecks.rangeRatio.median, 1 - 0.012 / w.slab.center.distance(to: cam), accuracy: 0.002)

        // the old weights blend the plane's normal in half way
        var old = TrackerSettings()
        old.recheckInterval = 0.1
        let b = run(old)
        let oldFused = try XCTUnwrap(b.out.slab)
        XCTAssertEqual(Units.degrees(oldFused.normal.angle(to: try XCTUnwrap(b.tracker.imageSlab).normal)), 2.5, accuracy: 0.3)
    }

    /// The centre weight alone turns fusion on, and both at 0 leave the lock as the picture has it (no fusion, no event).
    func testFusionRunsWhileEitherWeightIsOn() throws {
        let w = World(slab: World.slabAt(Vec3(0, 0.06, -1.0), tilt: 6, heading: 30))
        let v = w.view(from: Vec3(0, 0.8, 0), at: w.slab.center)
        let dm = w.depthMap(v, spec: .standard)
        func fused(_ normal: Double, _ centre: Double) -> (Bool, [String]) {
            var s = TrackerSettings(); s.recheckInterval = 0.1; s.depthNormalWeight = normal; s.depthCentreWeight = centre
            let det = TruthDetector(w); det.noise = 0
            let tr = SlabTracker(settings: s, detector: det)
            var o: TrackerOutput! = nil, events: [String] = []
            for k in 0..<6 {
                det.currentView = v
                o = tr.process(TrackerFrame(timestamp: Double(k) * 0.11, view: v, frame: blank, depth: dm.0, depthIntrinsics: dm.1))
                events += o.events
            }
            return (o.depthFused, events)
        }
        XCTAssertTrue(fused(0, 0.5).0)
        XCTAssertTrue(fused(0, 0.5).1.contains("depth-fused"))
        XCTAssertTrue(fused(0.5, 0).0)
        let none = fused(0, 0)
        XCTAssertFalse(none.0)
        XCTAssertFalse(none.1.contains("depth-fused"))
    }

    /// Settings written before n11 have no centre weight: the normal's weight moved the centre too, so they read it as that
    /// weight (a recording replays as the phone ran it); written settings keep both.
    func testOldSettingsReadTheCentreWeightAsTheNormals() throws {
        let dec = JSONDecoder()
        XCTAssertEqual(try dec.decode(TrackerSettings.self, from: Data(#"{"depthNormalWeight": 0.3}"#.utf8)).depthCentreWeight, 0.3)
        XCTAssertEqual(try dec.decode(TrackerSettings.self, from: Data(#"{"depthNormalWeight": 0}"#.utf8)).depthCentreWeight, 0)
        XCTAssertEqual(try dec.decode(TrackerSettings.self, from: Data("{}".utf8)).depthCentreWeight, TrackerSettings().depthNormalWeight)
        XCTAssertEqual(try dec.decode(TrackerSettings.self, from: Data(#"{"depthNormalWeight": 0.3, "depthCentreWeight": 0.1}"#.utf8)).depthCentreWeight, 0.1)
        // a recording's settings from before n11, built from the app's: every key but the new one
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TrackerSettings())) as! [String: Any]
        XCTAssertNotNil(json.removeValue(forKey: "depthCentreWeight"))
        json["depthNormalWeight"] = 0.5
        let old = try dec.decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.depthNormalWeight, 0.5)
        XCTAssertEqual(old.depthCentreWeight, 0.5)
        let app = RecordingSettings().trackerSettings
        XCTAssertEqual(try dec.decode(TrackerSettings.self, from: JSONEncoder().encode(app)), app)
    }
}
