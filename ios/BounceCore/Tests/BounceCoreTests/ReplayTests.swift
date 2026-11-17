import XCTest
@testable import BounceCore

/// Uses truth.json's corner pixels as the "detection", to test the replay path and the tracker on real recorded poses.
final class TruthCornersDetector: SlabDetecting {
    let corners: [[Vec2]]
    var i = 0
    init(_ c: [[Vec2]]) { corners = c }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        defer { i += 1 }
        return i < corners.count ? [DetectedOutline(quad: corners[i])] : []
    }
}

/// Largest corner distance between two outlines, whichever corner each starts at and whichever way round it goes.
func outlineDistance(_ a: [Vec2], _ b: [Vec2]) -> Double {
    var best = Double.infinity
    for rev in [false, true] {
        let bb = rev ? Array(b.reversed()) : b
        for k in 0..<4 { best = min(best, (0..<4).map { a[$0].distance(to: bb[($0 + k) % 4]) }.max()!) }
    }
    return best
}

final class ReplayTests: XCTestCase {
    /// The exported still clip, replayed with perfect detections: it locks, and its tilt and outline match the truth.
    func testReplayStillWithTruthCorners() throws {
        let rec = try Fixtures.recording("rec_replay_still"), truth = try Fixtures.truth("rec_replay_still")
        let tf = truth["frames"] as! [[String: Any]]
        let det = TruthCornersDetector(tf.map { vec2s($0["cornersPixels"])! })
        var s = TrackerSettings(); s.recheckInterval = 0.0
        s.spec = rec.session.settings.slab
        let (steps, tracker) = try ReplayRunner(reader: rec).run(detector: det, settings: s)
        XCTAssertEqual(tracker.state, .locked)
        let last = steps.last!.output
        let trueN = Vec3(tf.last!["slabNormalWorld"] as! [Double])
        XCTAssertLessThan(angleDeg(last.slab!.normal, trueN), 0.2)
        XCTAssertEqual(last.readouts!.tiltDegrees, dbl(tf.last!["tiltDeg"]), accuracy: 0.2)
        // the locked outline, projected into each frame, sits on the true corners
        for (st, t) in zip(steps, tf) where st.output.outline != nil {
            let truthQ = vec2s(t["cornersPixels"])!
            XCTAssertLessThan(outlineDistance(st.output.outline!, truthQ), 0.6, "frame \(st.frame.index)")
        }
    }

    /// Replays a recording named by the BOUNCE_RECORDING environment variable (e.g. one sent from the phone) with the
    /// detector the app uses, and prints what happened frame by frame. Skipped when the variable is not set.
    func testReplayRecordingFromEnvironment() throws {
        guard let path = ProcessInfo.processInfo.environment["BOUNCE_RECORDING"] else { throw XCTSkip("set BOUNCE_RECORDING=/path/to/x.bouncerec") }
        let rec = try RecordingReader(folder: URL(fileURLWithPath: path))
        let (steps, tracker) = try ReplayRunner(reader: rec).run(detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        for st in steps {
            let o = st.output
            print(String(format: "%6.2f  %@  tilt %@  events %@", st.frame.timestamp, o.state.rawValue,
                         o.readouts.map { String(format: "%.2f", $0.tiltDegrees) } ?? "-", o.events.joined(separator: ",")))
        }
        print("counts:", tracker.counts.sorted { $0.key < $1.key })
    }
}

/// The whole pipeline (SlabFinder through SlabTracker), as the app runs it.
final class PipelineTests: XCTestCase {
    /// The exported still clip with the real detector: it locks, and its tilt matches the truth.
    func testReplayStillWithSlabFinder() throws {
        let rec = try Fixtures.recording("rec_replay_still"), truth = try Fixtures.truth("rec_replay_still")
        let tf = truth["frames"] as! [[String: Any]]
        var s = TrackerSettings(); s.recheckInterval = 0
        s.spec = rec.session.settings.slab
        let (steps, tracker) = try ReplayRunner(reader: rec).run(detector: AppDetectors.slab(), settings: s)
        XCTAssertEqual(tracker.state, .locked, "counts \(tracker.counts)")
        guard let last = steps.last?.output, let slab = last.slab else { return XCTFail("no lock") }
        let trueN = Vec3(tf.last!["slabNormalWorld"] as! [Double])
        let err = angleDeg(slab.normal, trueN)
        print(String(format: "PIPELINE replay_still: locked at frame %d, normal error %.2f deg, tilt %.2f (truth %.2f)",
                     steps.firstIndex { $0.output.state == .locked } ?? -1, err, last.readouts?.tiltDegrees ?? -1, dbl(tf.last!["tiltDeg"])))
        XCTAssertLessThan(err, 2.0)
        for (st, t) in zip(steps, tf) where st.output.outline != nil {
            XCTAssertLessThan(outlineDistance(st.output.outline!, vec2s(t["cornersPixels"])!), 3.0, "frame \(st.frame.index)")
        }
    }

    /// The app's demo scene (as the Simulator UI tests see it), through SlabFinder and SlabTracker frame by frame: it locks
    /// within the first second and reads the tilt to within a degree; a held ball's drop and a slide to a new tilt follow.
    func testDemoSceneThroughThePipeline() {
        var d = DemoScript(); d.slideTo = 3; d.slideAt = 4
        var s = TrackerSettings(); s.searchInterval = 0.12
        let tracker = SlabTracker(settings: s, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var lockedAt: Double? = nil, tiltErrs: [Double] = [], after: [Double] = []
        var t = 0.0
        while t < 9 {
            let view = d.view(at: t), scene = d.scene(at: t)
            let img = SyntheticScene.ycc(rgb: scene.renderRGB(view: view), width: view.intrinsics.width, height: view.intrinsics.height)
            let out = tracker.process(TrackerFrame(timestamp: t, view: view, frame: img.colorFrame, floorY: 0))
            if out.state == .locked, lockedAt == nil { lockedAt = t }
            if let r = out.readouts {
                let truth = Units.degrees(scene.slab.tilt(down: Vec3(0, -1, 0)))
                if t < d.slideAt { tiltErrs.append(abs(r.tiltDegrees - truth)) } else if t > d.slideAt + 3 { after.append(abs(r.tiltDegrees - truth)) }
            }
            t += 0.08
        }
        tiltErrs.sort(); after.sort()
        print(String(format: "PIPELINE demo: locked after %.2f s; tilt error median %.2f worst %.2f deg before the slide, median %.2f after (counts %@)",
                     lockedAt ?? -1, tiltErrs.isEmpty ? -1 : tiltErrs[tiltErrs.count / 2], tiltErrs.last ?? -1,
                     after.isEmpty ? -1 : after[after.count / 2], "\(tracker.counts.sorted { $0.key < $1.key })"))
        XCTAssertNotNil(lockedAt)
        XCTAssertLessThan(lockedAt ?? 99, 1.0)
        XCTAssertLessThan(tiltErrs.isEmpty ? 99 : tiltErrs[tiltErrs.count / 2], 1.0)
        XCTAssertLessThan(after.isEmpty ? 99 : after[after.count / 2], 1.0, "the slide to 3 deg shows")
    }
}
