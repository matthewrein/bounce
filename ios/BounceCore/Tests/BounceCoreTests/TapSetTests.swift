import XCTest
@testable import BounceCore

/// Tap to set the ball (`TrackerSettings.tapSetsBall`, `TapSetBall`): a ball tap whose box finds a ball within
/// `tapAcceptSeconds` accepts it at once; one that finds none sets the ball at the tap, from LiDAR's range there or else
/// where the tapped line meets the upright plane through the slab's middle, if either puts it over the slab at a drop
/// height (else nothing); the set ball's drop height is used until a tap on it, a ball found close to it twice, or the
/// lock ends; without taps nothing changes, and older settings read it off.
final class TapSetTests: XCTestCase {
    let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
    let up = Vec3(0, 1, 0)
    let image = ColorFrame(gray: Plane(width: 8, height: 6))
    let cam = Vec3(0.05, 0.9, 0)

    func settings(sets: Bool = true) -> TrackerSettings {
        var s = RecordingSettings(sideUInches: 7, sideVInches: 7, ballDiameterMm: 30).trackerSettings
        s.spec = .standard
        s.tapSetsBall = sets
        return s
    }

    /// One frame at time t from view v (the ball image: the processing frame's size and intrinsics), with an optional
    /// tap and depth map.
    @discardableResult
    func step(_ tr: SlabTracker, _ det: SceneDetector, _ balls: ScriptedBalls?, _ v: CameraView, _ t: Double, tap: Vec2? = nil,
              depth: (DepthMap, CameraIntrinsics)? = nil) -> TrackerOutput {
        det.currentView = v; balls?.view = v
        let ballDue = tr.ballDue(at: t)
        return tr.process(TrackerFrame(timestamp: t, view: v, frame: image, depth: depth?.0, depthIntrinsics: depth?.1,
                                       ballImage: ballDue ? Plane(width: v.intrinsics.width, height: v.intrinsics.height) : nil,
                                       ballIntrinsics: ballDue ? v.intrinsics : nil, tap: tap))
    }

    func lockedTracker(sets: Bool = true, balls: ScriptedBalls? = nil) -> (SlabTracker, SceneDetector, CameraView, Int) {
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 77)
        let tr = SlabTracker(settings: settings(sets: sets), detector: det, ballLocator: balls)
        let v = w.view(from: cam, at: slab.center)
        var k = 0
        while tr.state != .locked && k < 120 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        return (tr, det, v, k)
    }

    /// A depth map (a quarter of the processing frame's size) reading `z` (camera z, m) everywhere.
    func flatDepth(_ v: CameraView, z: Double) -> (DepthMap, CameraIntrinsics) {
        let K = v.intrinsics.scaled(by: 0.25)
        let n = K.width * K.height
        return (DepthMap(width: K.width, height: K.height, depth: [Float](repeating: Float(z), count: n), confidence: [UInt8](repeating: 2, count: n)), K)
    }

    /// The drop height a ball centred at `c` gives over the lock (as the tracker's bounce takes it).
    func drop(_ tr: SlabTracker, _ c: Vec3) -> Double? {
        TapSetBall.dropHeight(center: c, slab: tr.slab!, spec: tr.settings.spec, ball: tr.settings.ball, down: ARKitConvention.worldDown, rule: tr.settings.launchRule)
    }

    /// Frames until the tap waiting for the finder is decided (`tapAcceptSeconds` and one frame), returning the last
    /// output and when each tap event came (s after `t0`).
    func settle(_ tr: SlabTracker, _ det: SceneDetector, _ balls: ScriptedBalls?, _ v: CameraView, _ k: inout Int, t0: Double,
                frames: Int = 30) -> (TrackerOutput, [String: Double]) {
        var last: TrackerOutput! = nil, when: [String: Double] = [:]
        for _ in 0..<frames {
            let t = Double(k) / 60
            last = step(tr, det, balls, v, t); k += 1
            for e in last.events where e.hasPrefix("tap") && when[e] == nil { when[e] = t - t0 }
        }
        return (last, when)
    }

    // MARK: setting the ball

    func testATapWhereNoBallIsFoundSetsItAtLiDARsRange() {
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        // the ball held 0.3 m over the slab's near half (nearer the phone than its middle): LiDAR reads its near surface
        // under the finger, in front of the plane through the slab's middle
        let toward = (cam - slab.center).rejecting(up).normalized
        let B = slab.center + up * 0.30 + toward * 0.04
        let p = v.project(world: B)!
        let dir = (B - v.position).normalized
        let front = v.toCamera(B - dir * tr.settings.ball.radius)
        let depth = flatDepth(v, z: front.z)
        let t0 = Double(k) / 60
        let o = step(tr, det, balls, v, t0, tap: p, depth: depth); k += 1
        XCTAssertEqual(o.tap?.kind, .ball)
        XCTAssertTrue(o.ballTapPending)
        XCTAssertNil(o.setBall, "not before the finder has had its time")
        let (last, when) = settle(tr, det, balls, v, &k, t0: t0)
        let s = try! XCTUnwrap(tr.setBall)
        XCTAssertEqual(s.source, .lidar)
        XCTAssertLessThan(s.center.distance(to: B), 0.002, "its centre: LiDAR's range plus the ball's radius")
        XCTAssertGreaterThan(when["tap-ball-set"] ?? 0, tr.settings.tapAcceptSeconds)
        XCTAssertLessThan(when["tap-ball-set"] ?? 9, tr.settings.tapAcceptSeconds + 0.05)
        XCTAssertNil(last.ball, "no ring: the set ball has its own mark")
        XCTAssertEqual(last.setBall, s)
        XCTAssertEqual(last.readouts?.dropFromBall, true)
        XCTAssertEqual(last.readouts?.dropFromSetBall, true)
        XCTAssertEqual(last.readouts!.dropHeight, drop(tr, B)!, accuracy: 0.003)
        XCTAssertEqual(last.drop?.ballCenter, s.center)
        XCTAssertEqual(tr.counts["tapBallSet"], 1); XCTAssertEqual(tr.counts["tapBallSetLidar"], 1)
        XCTAssertEqual(tr.tapLog.last?.event, "set")
        XCTAssertEqual(tr.state, .locked, "a ball tap never touches the lock")
    }

    func testWithoutLiDARsRangeItIsSetOnTheUprightPlaneThroughTheSlab() {
        for lidar in ["none", "behind", "past"] {
            let balls = ScriptedBalls()
            var (tr, det, v, k) = lockedTracker(balls: balls)
            for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
            // a ball straight over the slab's middle lies in that plane
            let B = slab.center + up * 0.25
            let p = v.project(world: B)!
            // "behind": LiDAR reads what is behind the ball (the floor 2 m away along the line): not over the slab; "past":
            // it reads 5 cm beyond the ball's near side (through an open lattice ball), still over the slab, but beyond the
            // plane through its middle: the plane's place is taken
            let front = v.toCamera(B - (B - v.position).normalized * tr.settings.ball.radius)
            let depth = lidar == "behind" ? flatDepth(v, z: 2.0) : lidar == "past" ? flatDepth(v, z: front.z + 0.05) : nil
            let t0 = Double(k) / 60
            step(tr, det, balls, v, t0, tap: p, depth: depth); k += 1
            let (last, _) = settle(tr, det, balls, v, &k, t0: t0)
            let s = try! XCTUnwrap(tr.setBall, lidar)
            XCTAssertEqual(s.source, .plane, lidar)
            // (the plane goes through the lock's middle, which the detector's noise puts a few millimetres off the slab's)
            XCTAssertLessThan(s.center.distance(to: B), 0.01, lidar)
            XCTAssertEqual(last.readouts!.dropHeight, drop(tr, B)!, accuracy: 0.005, lidar)
            XCTAssertEqual(tr.counts["tapBallSetPlane"], 1, lidar)
            if lidar == "behind" { XCTAssertTrue(tr.tapLog.last?.note?.contains("lidar: off the slab") ?? false, "\(tr.tapLog.last?.note ?? "-")") }
            if lidar == "past" { XCTAssertTrue(tr.tapLog.last?.note?.contains("beyond the plane") ?? false, "\(tr.tapLog.last?.note ?? "-")") }
        }
    }

    func testATapThatPutsNoBallOverTheSlabSetsNothing() {
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        // the slab's own middle (a ball tap while locked: a ball could be held anywhere along that line), LiDAR reading
        // its top: both places put the ball on the top, not over it
        let p = v.project(world: slab.center)!
        let w = World(slab: slab, lens: .processing)
        let depth = w.depthMap(v, spec: tr.settings.spec, scale: 0.25)
        let t0 = Double(k) / 60
        XCTAssertEqual(step(tr, det, balls, v, t0, tap: p, depth: depth).tap?.kind, .ball)
        k += 1
        let (last, when) = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertNil(tr.setBall)
        XCTAssertNotNil(when["tap-ball-set-none"])
        XCTAssertEqual(tr.counts["tapBallSetNothing"], 1)
        XCTAssertEqual(last.readouts?.dropFromBall, false, "the drop setting stands")
        XCTAssertNil(last.readouts?.dropFromSetBall)
        XCTAssertEqual(tr.tapLog.last?.event, "nothing")
        // the geometry alone: too low on both counts, and above the highest drop
        let c = TapSetBall.candidates(tap: p, view: v, depth: depth.0, depthIntrinsics: depth.1, slab: tr.slab!, spec: tr.settings.spec,
                                      ball: tr.settings.ball, rule: tr.settings.launchRule, maxHeight: tr.settings.tapSetMaxHeight)
        XCTAssertFalse(c.lidarPlausible); XCTAssertFalse(c.planePlausible); XCTAssertNil(c.chosen)
        XCTAssertTrue(c.slabUnderFinger, "LiDAR reads the slab's top under the finger")
        let high = v.project(world: slab.center + up * 0.5)!
        let h = TapSetBall.candidates(tap: high, view: v, depth: nil, depthIntrinsics: nil, slab: tr.slab!, spec: tr.settings.spec,
                                      ball: tr.settings.ball, rule: tr.settings.launchRule, maxHeight: 0.3)
        XCTAssertFalse(h.planePlausible, "over the highest drop: \(h.why)")
        XCTAssertTrue(TapSetBall.candidates(tap: high, view: v, depth: nil, depthIntrinsics: nil, slab: tr.slab!, spec: tr.settings.spec,
                                            ball: tr.settings.ball, rule: tr.settings.launchRule, maxHeight: 1).planePlausible)
    }

    func testATapOnTheSlabsFarHalfWhereLiDARReadsItsTopSetsNothing() {
        // a slab tap out of habit, on the top's far half (while locked a ball tap: a ball held low over the middle would be
        // seen there): the plane through the slab's middle would put a ball a few centimetres over it, but LiDAR reads the
        // top itself under the finger: nothing is held there
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let away = (slab.center - cam).rejecting(slab.normal).normalized
        let p = v.project(world: slab.center + away * 0.06)!
        let w = World(slab: slab, lens: .processing)
        // (LiDAR's map at about the phone's pixel size for this range: its window under the finger stays on the top)
        let depth = w.depthMap(v, spec: tr.settings.spec, scale: 0.6)
        let c = TapSetBall.candidates(tap: p, view: v, depth: depth.0, depthIntrinsics: depth.1, slab: tr.slab!, spec: tr.settings.spec,
                                      ball: tr.settings.ball, rule: tr.settings.launchRule, maxHeight: tr.settings.tapSetMaxHeight)
        XCTAssertTrue(c.planePlausible, "the plane alone would set a ball: \(c.why)")
        XCTAssertTrue(c.slabUnderFinger)
        XCTAssertNil(c.chosen)
        XCTAssertNotNil(c.lidarFirst, "as first specified, the plane's place would have been taken")
        let t0 = Double(k) / 60
        XCTAssertEqual(step(tr, det, balls, v, t0, tap: p, depth: depth).tap?.kind, .ball)
        k += 1
        _ = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertNil(tr.setBall)
        XCTAssertEqual(tr.counts["tapBallSetNothing"], 1)
        XCTAssertEqual(tr.tapLog.last?.note, "lidar: the slab's top under the finger")
        // (without LiDAR there is nothing to tell it from a ball held low over the middle: the plane's place is taken)
        let none = TapSetBall.candidates(tap: p, view: v, depth: nil, depthIntrinsics: nil, slab: tr.slab!, spec: tr.settings.spec,
                                         ball: tr.settings.ball, rule: tr.settings.launchRule, maxHeight: tr.settings.tapSetMaxHeight)
        XCTAssertEqual(none.chosen?.source, .plane)
    }

    func testLiDARAcrossTheBallsEdgeIsNotTaken() {
        // a window that reads two surfaces (the ball and the floor behind it) is not a range
        let v = World(slab: slab, lens: .processing).view(from: cam, at: slab.center)
        var (d, K) = flatDepth(v, z: 0.8)
        let p = Vec2(240, 180), q = K.project(v.intrinsics.ray(p))!
        for y in 0..<d.height { for x in 0..<d.width where Double(x) >= q.x.rounded(.down) { d.depth[y * d.width + x] = 1.6 } }
        XCTAssertEqual(TapSetBall.lidarDepth(p, view: v, depth: d, depthIntrinsics: K).note, "spread")
        XCTAssertEqual(TapSetBall.lidarDepth(Vec2(40, 180), view: v, depth: d, depthIntrinsics: K).z ?? 0, 0.8, accuracy: 1e-6)
        let none = DepthMap(width: d.width, height: d.height, depth: [Float](repeating: 0, count: d.width * d.height), confidence: d.confidence)
        XCTAssertEqual(TapSetBall.lidarDepth(p, view: v, depth: none, depthIntrinsics: K).note, "sparse")
    }

    // MARK: a ball found in the box in time

    func testABallFoundInTheTapsBoxInTimeIsAcceptedAtOnce() {
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { XCTAssertNil(step(tr, det, balls, v, Double(k) / 60).ball); k += 1 }
        let B = slab.center + up * 0.30 - slab.axisV * 0.04
        let t0 = Double(k) / 60
        step(tr, det, balls, v, t0, tap: v.project(world: B)! + Vec2(4, -3)); k += 1
        // the finder sees it from the next search on
        balls.balls = [B]
        let (last, when) = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertNotNil(when["tap-ball-accepted"])
        XCTAssertLessThanOrEqual(when["tap-ball-accepted"] ?? 9, tr.settings.tapAcceptSeconds)
        XCTAssertNil(when["tap-ball-set"], "found in time: nothing is set")
        XCTAssertNil(tr.setBall)
        XCTAssertLessThan(last.ball!.center.distance(to: B), 0.01)
        XCTAssertTrue(last.ballUserConfirmed, "the owner's ball")
        XCTAssertEqual(last.readouts?.dropFromBall, true)
        XCTAssertNil(last.readouts?.dropFromSetBall)
        XCTAssertEqual(tr.counts["tapBallAccepted"], 1)
        XCTAssertNil(tr.counts["tapBallSet"])
        // it stays the owner's while the finder keeps finding it there; it is not once the finder loses it
        balls.balls = []
        var gone: TrackerOutput! = nil
        for _ in 0..<30 { gone = step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertNil(gone.ball); XCTAssertFalse(gone.ballUserConfirmed)
        balls.balls = [B]
        var again: TrackerOutput! = nil
        for _ in 0..<30 { again = step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertNotNil(again.ball); XCTAssertFalse(again.ballUserConfirmed, "found again without a tap: the finder's own")
    }

    func testABallFoundInTheBoxBesideTheFingerIsNotAcceptedAtOnce() {
        // the finder finds something in the tap's box, but beside the finger (the hand holding the ball): not taken for the
        // tapped ball; the ball is set at the tap and the find beside it is not shown
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.30
        let p = v.project(world: B)!
        let t0 = Double(k) / 60
        let o = step(tr, det, balls, v, t0, tap: p); k += 1
        XCTAssertEqual(o.tap?.kind, .ball)
        // 40 px beside the finger in this 360 px frame: more than half again the ball's radius and a fingertip
        let beside = v.toWorld(v.intrinsics.unproject(p + Vec2(40, 0), depth: v.toCamera(B).z))
        XCTAssertFalse(TapSetBall.underFinger(beside, origin: v.position, direction: (B - v.position).normalized,
                                              slack: TapHints.slack(fraction: tr.settings.tapSlackFraction, width: 480, height: 360) / v.intrinsics.focal,
                                              ball: tr.settings.ball))
        balls.balls = [beside]
        let (last, when) = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertNil(when["tap-ball-accepted"])
        XCTAssertNotNil(when["tap-ball-set"])
        XCTAssertNil(last.ball, "the find beside it is not shown while the set ball stands")
        XCTAssertNotNil(last.setBall)
    }

    func testTheBallGateIsBypassedForABallATapAccepts() throws {
        // the app's ball gate shows the finder's ball from its third agreeing find; a ball found under a ball tap is shown
        // on its first, and the gate's verdict on it is noted in the ball's history (source "tap")
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        XCTAssertNotNil(tr.settings.ballGate)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.30 - slab.axisV * 0.04
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: B)!); k += 1
        balls.balls = [B]
        var accepted: TrackerOutput? = nil
        for _ in 0..<30 {
            let o = step(tr, det, balls, v, Double(k) / 60); k += 1
            if o.events.contains("tap-ball-accepted") { accepted = o; break }
            XCTAssertNil(o.ball)
        }
        let o = try XCTUnwrap(accepted)
        XCTAssertEqual(o.ballGateVerdict, .waiting, "the gate alone would not show it yet")
        XCTAssertLessThan(try XCTUnwrap(o.ball).center.distance(to: B), 0.01)
        XCTAssertTrue(o.ballUserConfirmed)
        XCTAssertNil(o.ballFound, "shown: nothing held back")
        XCTAssertEqual(tr.ballLog.suffix(2).map { $0.event }, ["tapAccepted", "waiting"])
        XCTAssertEqual(tr.ballLog.last?.source, "tap")
    }

    func testATappedFindLiDARReadsAsASurfaceIsNotAccepted() throws {
        // a look-alike the finder puts 0.3 m over the slab (its size says so) where LiDAR reads the floor far behind it: the
        // gate refuses it as a surface on every search. A tap on it is a ball tap (the owner sees a ball there), but the
        // tap vouches for a ball, not for that place: it is not accepted, no ring shows and the drop never comes from it;
        // the ball is set at the tap instead, as where no ball is found (a tap on its mark clears it)
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        // (LiDAR resolves the ball at this range in the test's coarse map)
        tr.settings.ballGate?.lidarMinRadiusPixels = 1
        let floor = flatDepth(v, z: 2.0)
        let B = slab.center + up * 0.30 - slab.axisV * 0.04
        balls.balls = [B]
        var searches = 0
        for _ in 0..<30 {
            let o = step(tr, det, balls, v, Double(k) / 60, depth: floor); k += 1
            XCTAssertNil(o.ball)
            if o.ballSearched { searches += 1; XCTAssertEqual(o.ballGateVerdict, .surface) }
        }
        XCTAssertGreaterThan(searches, 2)
        XCTAssertEqual(step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: B)!, depth: floor).tap?.kind, .ball); k += 1
        for _ in 0..<60 {
            let o = step(tr, det, balls, v, Double(k) / 60, depth: floor); k += 1
            XCTAssertNil(o.ball, "no ring where LiDAR reads a surface")
            XCTAssertFalse(o.ballUserConfirmed)
            if o.readouts?.dropFromBall == true { XCTAssertEqual(o.readouts?.dropFromSetBall, true, "the drop only from the ball set at the tap") }
        }
        XCTAssertNil(tr.counts["tapBallAccepted"])
        XCTAssertGreaterThan(tr.counts["tapBallAcceptRefused"] ?? 0, 0)
        XCTAssertEqual(tr.counts["tapBallSet"], 1, "set at the tap instead")
        XCTAssertEqual(tr.ballLog.last(where: { $0.event == "refused" })?.why, "surface")
    }

    func testATappedBallIsLetGoWhenTheGateRefusesItsPlace() throws {
        // a ball a tap accepted (frames without depth: shown at once), then LiDAR reads the floor far behind it: the gate
        // refuses the place, and the acceptance (the bypass of the gate's agreeing finds) ends with it
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        tr.settings.ballGate?.lidarMinRadiusPixels = 1
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.30 - slab.axisV * 0.04
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: B)!); k += 1
        balls.balls = [B]
        var accepted = false
        for _ in 0..<30 {
            let o = step(tr, det, balls, v, Double(k) / 60); k += 1
            if o.events.contains("tap-ball-accepted") { accepted = true; XCTAssertNotNil(o.ball); break }
        }
        XCTAssertTrue(accepted)
        var o: TrackerOutput! = nil
        for _ in 0..<12 { o = step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertNotNil(o.ball); XCTAssertTrue(o.ballUserConfirmed)
        let floor = flatDepth(v, z: 2.0)
        var refused = false
        for _ in 0..<30 {
            o = step(tr, det, balls, v, Double(k) / 60, depth: floor); k += 1
            if o.ballSearched, !refused { refused = true; XCTAssertEqual(o.ballGateVerdict, .surface) }
            if refused { XCTAssertNil(o.ball, "gone from the search that refused it"); XCTAssertFalse(o.ballUserConfirmed) }
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(o.readouts?.dropFromBall, false, "the drop setting again")
        XCTAssertEqual(tr.counts["tapAcceptedRefused"], 1)
        let e = try XCTUnwrap(tr.ballLog.last)
        XCTAssertEqual(e.event, "refused"); XCTAssertEqual(e.why, "surface"); XCTAssertEqual(e.source, "finder"); XCTAssertEqual(e.shown, false)
    }

    func testATapsBoxTakesLowPartOutlinesOnlyWhileTheTapWaitsOrItsBallIsFollowed() {
        // `BallSearchHints.lowPartials` (the box takes part of an outline as low as a whole one): on while the ball tap waits
        // for the finder (`tapAcceptSeconds`), off once it has set a ball or nothing (a box that found nothing under the
        // finger in time takes no low part outline later: on the owner's first kit, the ball lying in the dish read as a
        // ball 6 cm over the slab), and on while a ball the tap accepted is followed
        let balls = ScriptedBalls()
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        // a tap on the slab's middle (while locked a ball tap), nothing found: the box stays `tapBallSeconds`
        var pendingBefore = true, sawOn = 0, sawOff = 0
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: slab.center)!); k += 1
        for _ in 0..<90 {
            let n = balls.given.count
            let o = step(tr, det, balls, v, Double(k) / 60); k += 1
            if o.ballSearched, balls.given.count > n, let h = balls.given.last, h.region != nil {
                XCTAssertEqual(h.lowPartials, pendingBefore, "low part outlines while the tap waits, not after")
                if h.lowPartials { sawOn += 1 } else { sawOff += 1 }
            }
            pendingBefore = o.ballTapPending
        }
        XCTAssertGreaterThan(sawOn, 0); XCTAssertGreaterThan(sawOff, 0)
        // a tap on a ball the finder finds under the finger: accepted, and its box keeps taking low part outlines while
        // it is followed
        for _ in 0..<150 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.08
        balls.balls = [B]
        step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: B)!); k += 1
        var last: TrackerOutput! = nil
        for _ in 0..<60 { last = step(tr, det, balls, v, Double(k) / 60); k += 1 }
        XCTAssertTrue(last.ballUserConfirmed)
        XCTAssertEqual(tr.counts["tapBallAccepted"], 1)
        XCTAssertEqual(balls.given.last?.lowPartials, true)
        XCTAssertNotNil(balls.given.last?.region)
        // without tap to set the ball (tap hints alone, as recorded before it): the box takes them for as long as it lasts
        let other = ScriptedBalls()
        var (tr2, det2, v2, k2) = lockedTracker(sets: false, balls: other)
        step(tr2, det2, other, v2, Double(k2) / 60, tap: v2.project(world: slab.center)!); k2 += 1
        for _ in 0..<90 { step(tr2, det2, other, v2, Double(k2) / 60); k2 += 1 }
        XCTAssertTrue(other.given.filter { $0.region != nil }.allSatisfy { $0.lowPartials })
        XCTAssertGreaterThan(other.given.filter { $0.region != nil }.count, 5)
    }

    // MARK: how a set ball ends

    /// A locked tracker with a ball set on the plane over the slab's middle (no ball found), and k.
    func withSetBall(_ balls: ScriptedBalls) -> (SlabTracker, SceneDetector, CameraView, Int, Vec3) {
        var (tr, det, v, k) = lockedTracker(balls: balls)
        for _ in 0..<12 { step(tr, det, balls, v, Double(k) / 60); k += 1 }
        let B = slab.center + up * 0.28
        let t0 = Double(k) / 60
        step(tr, det, balls, v, t0, tap: v.project(world: B)!); k += 1
        _ = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertNotNil(tr.setBall)
        return (tr, det, v, k, B)
    }

    func testATapOnTheSetBallClearsIt() {
        let balls = ScriptedBalls()
        var (tr, det, v, k, B) = withSetBall(balls)
        let o = step(tr, det, balls, v, Double(k) / 60, tap: v.project(world: B)! + Vec2(5, 4)); k += 1
        XCTAssertEqual(o.tap?.kind, .clearSetBall)
        XCTAssertNil(o.setBall); XCTAssertNil(tr.setBall)
        XCTAssertEqual(o.readouts?.dropFromBall, false)
        XCTAssertNil(o.readouts?.dropFromSetBall)
        XCTAssertEqual(tr.counts["tapSetCleared"], 1)
        XCTAssertEqual(tr.tapLog.last?.event, "cleared")
        XCTAssertNil(o.detectionKind, "no slab search for it")
        // and a tap there again is a ball tap
        XCTAssertEqual(tr.tapKind(v.project(world: B)!, view: v), .ball)
    }

    func testAnotherBallTapReplacesTheSetBall() {
        let balls = ScriptedBalls()
        var (tr, det, v, k, B) = withSetBall(balls)
        let B2 = slab.center + up * 0.45 + slab.axisU * 0.05
        XCTAssertEqual(tr.tapKind(v.project(world: B2)!, view: v), .ball)
        let t0 = Double(k) / 60
        let o = step(tr, det, balls, v, t0, tap: v.project(world: B2)!); k += 1
        XCTAssertEqual(o.setBall.map { $0.center.distance(to: B) < 0.01 }, true, "kept while the new tap waits")
        _ = settle(tr, det, balls, v, &k, t0: t0)
        XCTAssertLessThan(tr.setBall!.center.distance(to: B2), 0.06, "set again at the new tap")
        XCTAssertEqual(tr.counts["tapSetReplacedByTap"], 1)
        // a ball tap that puts nothing over the slab leaves the set ball as it was
        let s = tr.setBall
        let t1 = Double(k) / 60
        step(tr, det, balls, v, t1, tap: v.project(world: slab.center)!); k += 1
        _ = settle(tr, det, balls, v, &k, t0: t1)
        XCTAssertEqual(tr.setBall, s)
    }

    func testABallFoundCloseToTheSetBallTwiceReplacesItAndOneElsewhereIsNotShown() {
        let balls = ScriptedBalls()
        var (tr, det, v, k, B) = withSetBall(balls)
        // the finder, now finding something elsewhere over the slab, and something on the same line of sight far behind it
        // (a print on the floor): not shown while the set ball stands
        balls.balls = [slab.center + up * 0.06 + slab.axisU * 0.08]
        var o: TrackerOutput! = nil
        for _ in 0..<30 { o = step(tr, det, balls, v, Double(k) / 60); k += 1; XCTAssertNil(o.ball, "a find elsewhere is not shown") }
        balls.balls = [v.position + (B - v.position) * 1.6]
        for _ in 0..<30 { o = step(tr, det, balls, v, Double(k) / 60); k += 1; XCTAssertNil(o.ball, "a find behind it is not shown") }
        XCTAssertNotNil(o.setBall)
        XCTAssertEqual(o.readouts?.dropFromSetBall, true)
        XCTAssertGreaterThan(tr.counts["tapSetHeldOverFind"] ?? 0, 0)
        // the finder finds the ball close to it: once is not enough, twice in a row replaces it
        let near = B + slab.axisU * 0.006
        balls.balls = [near]
        var replacedAt: Int? = nil, searchesBefore = 0
        for j in 0..<30 {
            let x = step(tr, det, balls, v, Double(k) / 60); k += 1
            if replacedAt == nil, x.ballSearched { searchesBefore += 1 }
            if x.events.contains("tap-set-replaced") { replacedAt = j; XCTAssertNil(x.setBall); XCTAssertLessThan(x.ball!.center.distance(to: near), 0.01); break }
            XCTAssertNotNil(x.setBall)
        }
        XCTAssertNotNil(replacedAt)
        // the ball gate (the app's) shows the find from its third search; shown close to the set ball twice in a row then
        // replaces it (without the gate: the second search)
        XCTAssertEqual(searchesBefore, 4, "replaced on the second search that showed it close")
        XCTAssertEqual(tr.counts["tapSetReplacedByFind"], 1)
        XCTAssertNil(tr.setBall)
    }

    func testTheSetBallEndsWithTheLock() {
        // a reset
        do {
            let balls = ScriptedBalls()
            let (tr, _, _, _, _) = withSetBall(balls)
            tr.reset()
            XCTAssertNil(tr.setBall)
            XCTAssertEqual(tr.counts["tapSetEnded"], 1)
            XCTAssertEqual(tr.tapLog.last?.note, "reset")
        }
        // the lock lost
        do {
            let balls = ScriptedBalls()
            var (tr, det, v, k, _) = withSetBall(balls)
            det.silent = true
            var o: TrackerOutput! = nil
            for _ in 0..<600 where tr.state == .locked { o = step(tr, det, balls, v, Double(k) / 60); k += 1 }
            XCTAssertTrue(o.events.contains("lost"))
            XCTAssertNil(tr.setBall); XCTAssertNil(o.setBall)
            XCTAssertEqual(tr.tapLog.last?.note, "lost")
        }
        // the world frame jumped
        do {
            let balls = ScriptedBalls()
            var (tr, det, v, k, _) = withSetBall(balls)
            tr.noteWorldDiscontinuity("relocalized")
            let o = step(tr, det, balls, v, Double(k) / 60); k += 1
            XCTAssertNil(o.setBall)
            XCTAssertEqual(tr.tapLog.last?.note, "world frame: relocalized")
        }
    }

    // MARK: without taps, and older files

    func testWithoutATapItChangesNothing() {
        func run(_ sets: Bool) -> [String] {
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 9)
            let balls = ScriptedBalls(); balls.balls = [slab.center + up * 0.32]
            let tr = SlabTracker(settings: settings(sets: sets), detector: det, ballLocator: balls)
            var out: [String] = []
            for k in 0..<360 {
                let t = Double(k) / 60
                let v = w.view(from: Vec3(0.1 * sin(t), 0.9, 0.05 * cos(t * 0.7)), at: slab.center)
                if k == 200 { balls.balls = [] }
                let o = step(tr, det, balls, v, t, depth: k % 7 == 0 ? w.depthMap(v, spec: .standard, scale: 0.25) : nil)
                out.append("\(o.state) \(o.slab.map { "\($0.center) \($0.normal)" } ?? "-") \(o.ball.map { "\($0.center)" } ?? "-") "
                           + "\(o.readouts.map { "\($0)" } ?? "-") \(o.events) \(o.setBall == nil) \(o.ballUserConfirmed) \(o.ballTapPending)")
            }
            return out
        }
        XCTAssertEqual(run(false), run(true))
    }

    func testTheSettingsAreRecordedAndOlderFilesReadThemOff() throws {
        let app = RecordingSettings().trackerSettings
        XCTAssertTrue(app.tapSetsBall)
        XCTAssertEqual(app.tapAcceptSeconds, 0.3)
        XCTAssertEqual(app.tapSetMaxHeight, Units.feet(10), accuracy: 1e-12)
        XCTAssertEqual(try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(app)), app)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as! [String: Any]
        for k in ["tapSetsBall", "tapAcceptSeconds", "tapSetMaxHeight"] { XCTAssertNotNil(json.removeValue(forKey: k), k) }
        let old = try JSONDecoder().decode(TrackerSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.tapSetsBall, "a recording without the key replays its ball taps as they were taken (no tap to set)")
        var expect = app; expect.tapSetsBall = false
        XCTAssertEqual(old, expect, "nothing else changes")
        // readouts without a set ball are written as before (no new key) and older ones read back
        let r = Readouts(tiltDegrees: 3, apexHeight: 0.2, landingDistance: 0.3, airTime: 0.4, dropHeight: 0.5, dropFromBall: true)
        let rj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertNil(rj["dropFromSetBall"])
        XCTAssertEqual(try JSONDecoder().decode(Readouts.self, from: JSONEncoder().encode(r)), r)
        var withSet = r; withSet.dropFromSetBall = true
        XCTAssertEqual(try JSONDecoder().decode(Readouts.self, from: JSONEncoder().encode(withSet)), withSet)
        // the diagnostics' tap summary from before reads back without the set ball and the log
        let taps = #"{"slabTapToLockSeconds":{"count":0,"min":"inf","max":"-inf","median":"nan","last":"nan"},"ballTapToBallSeconds":{"count":0,"min":"inf","max":"-inf","median":"nan","last":"nan"},"dismissedSpots":1,"ballTapSearching":false}"#
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let t = try d.decode(DiagnosticsReport.Taps.self, from: Data(taps.utf8))
        XCTAssertNil(t.setBall); XCTAssertNil(t.log); XCTAssertEqual(t.dismissedSpots, 1)
    }

    func testTheDiagnosticsCarryTheSetBallAndTheTaps() throws {
        let balls = ScriptedBalls()
        let (tr, _, v, _, B) = withSetBall(balls)
        var rep = DiagnosticsReport(build: "t", device: "d", system: "s", time: "now", settings: RecordingSettings(), state: "locked", tracking: "normal",
                                    fps: 60, msProcess: 1, lens: nil, depthSupported: false, depth: nil, captureLocked: false, slab: tr.slab, outline: nil,
                                    sideModes: [], ball: nil, readouts: nil, counts: tr.counts, recentEvents: [], recording: nil)
        rep.addTracker(tr, view: v)
        let s = try XCTUnwrap(rep.taps?.setBall)
        XCTAssertEqual(s.source, .plane)
        XCTAssertEqual(Vec3(s.center[0], s.center[1], s.center[2]).distance(to: B), 0, accuracy: 0.01)
        XCTAssertEqual(s.dropHeightNow ?? 0, s.dropHeightWhenSet, accuracy: 0.002)
        XCTAssertEqual(rep.taps?.log?.map { $0.event }, ["tap", "set"])
        let back = try DiagnosticsReport.decode(json: rep.json())
        XCTAssertEqual(back.taps?.setBall, rep.taps?.setBall)
        XCTAssertEqual(back.taps?.log, rep.taps?.log)
    }
}

/// The app's demo with its held ball not drawn (what SlabBounceUITests.testTapTheBallToSetItAndTapAgainToClearIt sees),
/// through the app's demo path (frames 12.5 a second, the app's tracker, detectors and settings, no LiDAR): the finder
/// finds no ball; a tap where the ball is (a moment after its place was read, as the UI test taps) sets it on the plane
/// through the slab's middle with the scene's drop height, and a tap on it clears it.
final class DemoTapSetTests: XCTestCase {
    func testTheDemosHiddenBallIsSetByATapAndClearedByAnother() {
        var d = DemoScript(); d.ballHeight = 0.30; d.ballHidden = true
        let settings = RecordingSettings().trackerSettings
        XCTAssertTrue(settings.tapSetsBall)
        let tracker = SlabTracker(settings: settings, detector: AppDetectors.slab(), ballLocator: AppDetectors.ball())
        var t = 0.0
        var tap: Vec2? = nil, tapPoint: Vec2? = nil
        var tappedAt: Double? = nil, setAt: Double? = nil, clearTapAt: Double? = nil, clearedAt: Double? = nil
        var setDrop: Double? = nil, trueDrop: Double? = nil, rings = 0
        while t < 9 {
            let view = d.view(at: t), scene = d.scene(at: t, spec: settings.spec, ball: settings.ball)
            XCTAssertNil(scene.ball, "the hidden ball is not drawn")
            let K = view.intrinsics
            let img = SyntheticScene.ycc(rgb: scene.renderRGB(view: view), width: K.width, height: K.height)
            var ballImage: Plane? = nil, ballK: CameraIntrinsics? = nil
            if tracker.state == .locked, tracker.ballDue(at: t), let s = tracker.slab, let c = BallImageCrop.plan(slab: s, full: view) {
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                ballImage = c.factor > 1 ? p.downscaled(by: c.factor) : p
                ballK = c.intrinsics(full: K)
            }
            let detail = SlabImageCrop.provider(processing: K, full: K) { c in
                let p = img.luma.cropped(x0: c.x0, y0: c.y0, width: c.width, height: c.height)
                return c.factor > 1 ? p.downscaled(by: c.factor) : p
            }
            let out = tracker.process(TrackerFrame(timestamp: t, view: view, frame: img.colorFrame, ballImage: ballImage, ballIntrinsics: ballK,
                                                   tap: tap, floorY: 0, slabDetail: detail))
            tap = nil
            if out.ball != nil { rings += 1 }
            if tapPoint == nil, out.state == .locked, t > 3 {
                // where the hidden ball is now (the app's marker); tapped on the next frame (about the UI test's delay)
                tapPoint = view.project(world: d.heldBall(at: t, spec: settings.spec)!)
            } else if tappedAt == nil, let p = tapPoint {
                tap = p; tappedAt = t
            } else if tappedAt != nil, setAt == nil, let r = out.readouts, r.dropFromSetBall == true, let b = out.setBall {
                setAt = t; setDrop = r.dropHeight
                var shown = d; shown.ballHidden = false
                let sc = shown.scene(at: t, spec: settings.spec, ball: settings.ball)
                trueDrop = Bounce.compute(pose: sc.slab, spec: settings.spec, ball: settings.ball, down: ARKitConvention.worldDown, ballCenter: sc.ball,
                                          defaultDropHeight: settings.defaultDropHeight, rule: settings.launchRule).drop?.dropHeight
                XCTAssertEqual(b.source, .plane)
                tap = view.project(world: b.center)   // the app's set ball marker, tapped on the next frame
                clearTapAt = t + 0.08
            } else if clearTapAt != nil, clearedAt == nil, out.setBall == nil {
                XCTAssertEqual(out.tap?.kind, .clearSetBall)
                clearedAt = t
            }
            t += 0.08
        }
        print(String(format: "DEMO TAP SET: tapped at %.2f s, set at %@ (drop %.1f in, truth %.1f in), cleared at %@; rings %d; counts %@",
                     tappedAt ?? -1, setAt.map { String(format: "%.2f s", $0) } ?? "never", Units.toInches(setDrop ?? 0), Units.toInches(trueDrop ?? 0),
                     clearedAt.map { String(format: "%.2f s", $0) } ?? "never", rings,
                     "\(tracker.counts.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key })"))
        XCTAssertEqual(rings, 0, "the finder never saw the hidden ball")
        XCTAssertNotNil(setAt, "the tap never set the ball")
        XCTAssertLessThan((setAt ?? 99) - (tappedAt ?? 0), 0.5)
        XCTAssertEqual(Units.toInches(setDrop ?? 0), Units.toInches(trueDrop ?? 99), accuracy: 1.0, "the set ball's drop against the scene's")
        XCTAssertNotNil(clearedAt, "the tap on the set ball never cleared it")
        XCTAssertEqual(tracker.counts["tapSetCleared"], 1)
        XCTAssertEqual(tracker.counts["tapBallSetPlane"], 1)
    }
}
