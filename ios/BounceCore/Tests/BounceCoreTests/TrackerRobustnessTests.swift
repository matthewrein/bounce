import XCTest
@testable import BounceCore

// Tracker scenarios from the code review, at the lens the app really processes with (ARKit's 1920x1440 divided by 4:
// 480x360, fx 362.5) and with the frame rates and search interval the app uses.

extension CameraIntrinsics {
    /// The app's processing frame (ARController: factor = width / 480 on ARKit's 1920x1440, fx about 1450).
    static let processing = CameraIntrinsics(fx: 362.5, fy: 362.5, cx: 240, cy: 180, width: 480, height: 360)
}

extension World {
    init(slab: SlabPose, lens: CameraIntrinsics) { self.init(slab: slab); intrinsics = lens }

    /// The owner's cradle: the slab's bottom is a sphere of radius R (about 17.2 in) sitting in a matching cradle, so its
    /// normal always passes through the sphere's centre, straight above the base; the top centre lies R - thickness below
    /// it. Level, the top centre is at `base`.
    static func cradled(base: Vec3, tilt: Double, heading: Double, yaw: Double = 10, spec: SlabSpec = .standard,
                        radius: Double = Units.inches(17.2)) -> SlabPose {
        let r = radius - spec.thickness, sphere = base + Vec3(0, r, 0)
        let level = World.slabAt(base, tilt: tilt, heading: heading, yaw: yaw, spec: spec)
        var p = level
        p.center = sphere - level.normal * r
        return p
    }

    /// The outline a detector reports when it takes the near side (the visible cut face with the widest band) at the
    /// bottom of the cut face instead of at the top edge: that side's line moves to the projected bottom edge and its
    /// corners to where it meets the neighbouring top edges. Worked out here independently of SlabBoxView. With a side
    /// profile (`SlabSpec`) the face drops by its face drop H and runs out by R (its bottom corners on the corners'
    /// diagonals, its normal along H x outward + R x normal); with none, a vertical face as deep as the thickness.
    func cutFlipOutline(in v: CameraView, spec: SlabSpec) -> [Vec2]? {
        let pc = slab.transformed(by: v.cameraFromWorld), K = v.intrinsics
        let topC = pc.topCorners
        let H = spec.drop, R = spec.sideRun
        let out: [Vec3] = (0..<4).map { (i: Int) -> Vec3 in
            let mid: Vec3 = (topC[i] + topC[(i + 1) % 4]) / 2
            return (mid - pc.center).rejecting(pc.normal).normalized
        }
        let top = topC.compactMap { K.project($0) }
        let bot: [Vec2] = (0..<4).compactMap { (k: Int) -> Vec2? in
            let m: Vec3 = out[(k + 3) % 4] + out[k]
            let b: Vec3 = topC[k] - pc.normal * H + m * R
            return K.project(b)
        }
        guard top.count == 4, bot.count == 4 else { return nil }
        var best = -1, bw = 0.0
        for i in 0..<4 {
            let j = (i + 1) % 4
            let edgeMid: Vec3 = (topC[i] + topC[j]) / 2
            let mid: Vec3 = edgeMid + out[i] * (R / 2) - pc.normal * (H / 2)
            let faceNormal: Vec3 = out[i] * H + pc.normal * R
            guard faceNormal.dot(-mid) > 0 else { continue }
            let dir = (top[j] - top[i]).normalized
            let w = (abs(dir.cross(bot[i] - top[i])) + abs(dir.cross(bot[j] - top[j]))) / 2
            if w > bw { bw = w; best = i }
        }
        guard best >= 0 else { return nil }
        func meet(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> Vec2 {
            let r = b - a, s = d - c, den = r.cross(s)
            return a + r * ((c - a).cross(s) / den)
        }
        let i = best, j = (i + 1) % 4, h = (i + 3) % 4, k = (j + 1) % 4
        var q = top
        q[i] = meet(bot[i], bot[j], top[h], top[i])
        q[j] = meet(bot[i], bot[j], top[j], top[k])
        return q
    }

    /// The near side's band width (pixels) in a view, for reporting.
    func nearBand(in v: CameraView, spec: SlabSpec) -> Double {
        guard let f = cutFlipOutline(in: v, spec: spec) else { return 0 }
        let t = corners(in: v)
        return zip(f, t).map { $0.distance(to: $1) }.max()!
    }

    /// Depth of the slab (dished top) and, optionally, an occluding rectangle (e.g. a hand) and the floor, with noise.
    func depthMap(_ v: CameraView, spec: SlabSpec, scale: Double = 0.4, occluder: (center: Vec3, normal: Vec3, half: Double)? = nil,
                  slabPresent: Bool = true, floorY: Double = 0, noise: Double = 0, rng: inout SeededRandom) -> (DepthMap, CameraIntrinsics) {
        let K = v.intrinsics.scaled(by: scale)
        var d = [Float](repeating: 3, count: K.width * K.height), c = [UInt8](repeating: 2, count: K.width * K.height)
        let plane = Plane3(point: slab.center, normal: slab.normal), floor = Plane3(point: Vec3(0, floorY, 0), normal: Vec3(0, 1, 0))
        for y in 0..<K.height {
            for x in 0..<K.width {
                let r = v.worldFromCamera.applyDirection(K.ray(Vec2(Double(x) + 0.5, Double(y) + 0.5)))
                var best: Vec3? = floor.intersect(origin: v.position, direction: r)
                func consider(_ p: Vec3?) {
                    guard let p = p else { return }
                    if best == nil || (p - v.position).length < (best! - v.position).length { best = p }
                }
                if slabPresent, var p = plane.intersect(origin: v.position, direction: r) {
                    var (u, w) = slab.local(p)
                    if abs(u) < slab.halfU, abs(w) < slab.halfV {
                        for _ in 0..<4 {
                            let dish = Dish.at(pose: slab, depth: spec.dishDepth, u: u, v: w).depth
                            guard let q = Plane3(point: slab.center - slab.normal * dish, normal: slab.normal).intersect(origin: v.position, direction: r) else { break }
                            p = q; (u, w) = slab.local(p)
                        }
                        consider(p)
                    }
                }
                if let o = occluder, let p = Plane3(point: o.center, normal: o.normal).intersect(origin: v.position, direction: r) {
                    let e = p - o.center, a = o.normal.anyPerpendicular, b = o.normal.cross(a)
                    if abs(e.dot(a)) < o.half && abs(e.dot(b)) < o.half { consider(p) }
                }
                guard let p = best else { continue }
                d[y * K.width + x] = Float(v.toCamera(p).z + (noise > 0 ? rng.gaussian() * noise : 0))
            }
        }
        return (DepthMap(width: K.width, height: K.height, depth: d, confidence: c), K)
    }
}

/// Reports the world's outline seen through the current view, with noise; optionally the near side flipped to the bottom
/// of its cut face (always, or at random), a second slab-like object, and a restricted search around `near`.
final class SceneDetector: SlabDetecting {
    var world: World
    var spec: SlabSpec
    var rng: SeededRandom
    var noise: Double
    var currentView: CameraView?
    var silent = false
    /// flip the near side to the cut face's bottom with this probability per call
    var flipProbability = 0.0
    /// the mirror error: the near side put a band inside the top (an outer edge that was already the top's, shifted in)
    var inwardProbability = 0.0
    private(set) var flips = 0, calls = 0, inward = 0
    /// another square object (a lookalike), reported first unless the seed lies on the real slab
    var other: SlabPose? = nil
    /// report the lookalike only (the real slab is out of view, say)
    var onlyOther = false
    /// like SlabFinder with a predicted outline: look only within this many pixels of the prediction's centre
    var nearRadius: Double? = nil
    /// a misshapen outline at the slab (a hand over a corner): fails the shape check
    var occludedCorner = false
    /// one side moved outward by this many pixels (caught on something beyond it)
    var sideShift: (side: Int, px: Double)? = nil
    /// seeds the tracker passed, per call
    private(set) var seeds: [Vec2?] = []

    init(_ w: World, spec: SlabSpec = .standard, noise: Double = 0.7, seed: UInt64 = 3) {
        world = w; self.spec = spec; self.noise = noise; rng = SeededRandom(seed)
    }

    func outline(of s: SlabPose, in v: CameraView) -> [Vec2]? {
        let q = s.topCorners.compactMap { v.project(world: $0) }
        guard q.count == 4, q.allSatisfy({ v.intrinsics.contains($0, margin: 1) }) else { return nil }
        return q
    }

    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        calls += 1
        seeds.append(seed)
        guard !silent, let v = currentView else { return [] }
        func noisy(_ q: [Vec2]) -> [Vec2] { q.map { Vec2($0.x + rng.gaussian() * noise, $0.y + rng.gaussian() * noise) } }
        var found: [[Vec2]] = []
        if !onlyOther, var q = outline(of: world.slab, in: v) {
            if flipProbability > 0, rng.next() < flipProbability, let f = world.cutFlipOutline(in: v, spec: self.spec) { q = f; flips += 1 }
            if inwardProbability > 0, rng.next() < inwardProbability, let f = world.cutFlipOutline(in: v, spec: self.spec) {
                q = zip(q, f).map { $0 + ($0 - $1) }; inward += 1
            }
            if occludedCorner { let c = (q[0] + q[1] + q[2] + q[3]) / 4; q[1] = q[1] + (c - q[1]) * 0.45 }
            if let (i, px) = sideShift {
                let a = q[i], b = q[(i + 1) % 4], c = (q[0] + q[1] + q[2] + q[3]) / 4
                var n = (b - a).perpendicular.normalized
                if n.dot((a + b) / 2 - c) < 0 { n = -n }
                q[i] = a + n * px; q[(i + 1) % 4] = b + n * px
            }
            found.append(noisy(q))
        }
        if let o = other, let q = outline(of: o, in: v) {
            // the lookalike comes first unless the seed is on the real slab
            let seedOnSlab = seed.map { s in found.first.map { SceneDetector.inside($0, s) } ?? false } ?? false
            if seedOnSlab { } else { found.insert(noisy(q), at: 0) }
        }
        if let r = nearRadius, let n = near {
            let c = (n[0] + n[1] + n[2] + n[3]) / 4
            found = found.filter { q in ((q[0] + q[1] + q[2] + q[3]) / 4).distance(to: c) < r }
        }
        return found.map { DetectedOutline(quad: $0) }
    }

    static func inside(_ q: [Vec2], _ p: Vec2) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let z = (q[(i + 1) % 4] - q[i]).cross(p - q[i])
            if sign == 0 { sign = z } else if (z > 0) != (sign > 0) { return false }
        }
        return true
    }
}

/// A ball held over the slab, found whenever `present`.
final class HeldBall: BallLocating {
    var present = false
    func locate(image: Plane, intrinsics: CameraIntrinsics, slab: SlabPose, spec: SlabSpec, ball: BallSpec, down: Vec3) -> (center: Vec3, circle: Vec2, radius: Double)? {
        guard present else { return nil }
        let c = slab.center - down * 0.3
        return (c, intrinsics.project(c) ?? Vec2(0, 0), 5)
    }
    func reset() {}
}

final class TrackerRobustnessTests: XCTestCase {
    let blank = ColorFrame(gray: Plane(width: 4, height: 4))

    /// the tracker's own settings with the app's search interval. Not all of the app's (`RecordingSettings.trackerSettings`
    /// also sets the ball gate, tap hints and `findsMovedSlab`): `findsMovedSlab` turns the app's moved-slab rule on (n20r)
    func appSettings(_ spec: SlabSpec = .standard, findsMovedSlab: Bool = false) -> TrackerSettings {
        var s = TrackerSettings(); s.searchInterval = 0.12; s.spec = spec; s.findsMovedSlab = findsMovedSlab
        return s
    }

    @discardableResult
    func step(_ t: SlabTracker, _ det: SceneDetector, _ v: CameraView, _ time: Double, depth: (DepthMap, CameraIntrinsics)? = nil,
              tap: Vec2? = nil, normal: Bool = true, ball: Bool = false) -> TrackerOutput {
        det.currentView = v
        return t.process(TrackerFrame(timestamp: time, view: v, frame: blank, depth: depth?.0, depthIntrinsics: depth?.1,
                                      ballImage: ball ? Plane(width: 4, height: 4) : nil, ballIntrinsics: ball ? v.intrinsics : nil,
                                      tap: tap, trackingNormal: normal))
    }

    /// a hand-held phone at `pos`, swaying a little, looking at `target`
    func swaying(_ w: World, _ pos: Vec3, _ target: Vec3, _ k: Int) -> CameraView {
        let d = Double(k)
        return w.view(from: pos + Vec3(0.012 * sin(d * 0.05), 0.008 * cos(d * 0.07), 0.01 * sin(d * 0.031)), at: target)
    }

    func err(_ a: SlabPose?, _ b: SlabPose) -> Double { a.map { angleDeg($0.normal, b.normal) } ?? .infinity }

    // MARK: agreement gates (#6) and the real lens (#25)

    func testLocksQuicklyAndKeepsItsRechecksAtTheRealLensAndNoise() {
        // 1.0 px corner noise on the 480x360 processing frame, line of sight about 1.4 m: two clean detections of a
        // still slab often differ by more than 2.5 cm in depth or 4 deg in normal, which the fixed gates threw away.
        var rng = SeededRandom(31)
        var lockTimes: [Double] = [], agree: [Double] = [], errs: [Double] = []
        for trial in 0..<16 {
            let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: rng.uniform(2, 10.5), heading: rng.uniform(0, 360), yaw: rng.uniform(-40, 40))
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 1.0, seed: UInt64(100 + trial))
            let tr = SlabTracker(settings: appSettings(), detector: det)
            var lockedAt: Double? = nil
            for k in 0..<(30 * 12) {
                let t = Double(k) / 30
                let o = step(tr, det, swaying(w, Vec3(0, 1.05, 0), slab.center, k), t)
                if o.state == .locked && lockedAt == nil { lockedAt = t }
            }
            lockTimes.append(lockedAt ?? 99)
            let a = Double(tr.counts["recheckAgree"] ?? 0), d = Double(tr.counts["recheckDisagree"] ?? 0)
            agree.append(a / max(1, a + d))
            errs.append(err(tr.slab, slab))
        }
        lockTimes.sort(); agree.sort(); errs.sort()
        print(String(format: "real lens, 1 px, 1.4 m: lock median %.2f s worst %.2f s; re-checks kept median %.0f%% worst %.0f%%; error median %.2f max %.2f deg",
                     lockTimes[8], lockTimes.last!, agree[8] * 100, agree[0] * 100, errs[8], errs.last!))
        XCTAssertLessThan(lockTimes[8], 1.0)
        XCTAssertLessThan(lockTimes.last!, 3.0)
        XCTAssertGreaterThan(agree[8], 0.8)
        XCTAssertLessThan(errs[8], 1.5)
        XCTAssertLessThan(errs.last!, 3.0)
    }

    // MARK: a rectangular slab (#1)

    func testRectangularSlabKeepsItsLongSide() {
        // 7.2 x 6.8 in: which outline side is the long one can hardly be told from one noisy frame at the processing
        // frame's resolution (the two assignments' costs differ by far less than the noise), and the wrong one tilts the
        // normal by about 6 deg. Deciding it per frame left about 4 locks in 10 that far off after 10 s at 1 px (2.5 in
        // 10 at 0.7 px); the tracker sums the evidence over its detections instead.
        let spec = SlabSpec(sideU: Units.inches(7.2), sideV: Units.inches(6.8), thickness: Units.inches(1), dishDepth: Units.inches(0.125))
        func run(_ sp: SlabSpec, noise: Double) -> (bad: Int, trials: Int, p90: Double, swaps: Int) {
            var rng = SeededRandom(77)
            var bad = 0, n = 0, errs: [Double] = [], swaps = 0
            for trial in 0..<40 {
                let slab = World.slabAt(Vec3(0, 0.066, -0.9), tilt: rng.uniform(0, 10), heading: rng.uniform(0, 360), yaw: rng.uniform(-45, 45), spec: sp)
                let w = World(slab: slab, lens: .processing)
                let det = SceneDetector(w, spec: sp, noise: noise, seed: UInt64(500 + trial))
                let tr = SlabTracker(settings: appSettings(sp), detector: det)
                var last: TrackerOutput? = nil
                for k in 0..<(30 * 10) { last = step(tr, det, swaying(w, Vec3(0.1, 0.95, 0.1), slab.center, k), Double(k) / 30) }
                swaps += tr.counts["sideSwaps"] ?? 0
                if let o = last, o.state == .locked { n += 1; let e = err(o.slab, slab); errs.append(e); if e > 3 { bad += 1 } }
            }
            errs.sort()
            return (bad, n, errs.isEmpty ? 0 : errs[Int(Double(errs.count) * 0.9)], swaps)
        }
        for noise in [0.7, 1.0] {
            let r = run(spec, noise: noise), sq = run(.standard, noise: noise)
            print(String(format: "rectangle at %.1f px: locks more than 3 deg off after 10 s %d/%d (p90 %.2f deg, %d side swaps); square %d/%d (p90 %.2f)",
                         noise, r.bad, r.trials, r.p90, r.swaps, sq.bad, sq.trials, sq.p90))
            XCTAssertGreaterThan(r.trials, 35)
            XCTAssertLessThanOrEqual(r.bad, sq.bad + 3, "\(noise) px")
            XCTAssertLessThan(r.p90, 3.0, "\(noise) px")
        }
    }

    // MARK: near-overhead views (#2)

    func testNearOverheadViewsDoNotLockAWrongTilt() {
        // Looking almost straight down (pitch 82-86), 0.7 px: each frame's tilt is off by 5-15 deg, and three such
        // frames that happen to agree used to lock and stay there.
        var rng = SeededRandom(9)
        var badLocks = 0, locks = 0
        for trial in 0..<30 {
            let slab = World.slabAt(Vec3(0, 0.066, 0), tilt: rng.uniform(2, 10), heading: rng.uniform(0, 360), yaw: rng.uniform(-40, 40))
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.7, seed: UInt64(900 + trial))
            let tr = SlabTracker(settings: appSettings(), detector: det)
            let pitch = Units.radians(rng.uniform(82, 86)), dist = rng.uniform(0.9, 1.3)
            let pos = slab.center + Vec3(0, sin(pitch), cos(pitch)) * dist
            var worst = 0.0, locked = false
            for k in 0..<(30 * 8) {
                let o = step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30)
                if o.state == .locked { locked = true; worst = max(worst, err(o.slab, slab)) }
            }
            if locked { locks += 1; if worst > 4 { badLocks += 1 } }
        }
        print("near overhead: \(locks)/30 locked, \(badLocks) of them more than 4 deg off at some point")
        XCTAssertLessThanOrEqual(badLocks, 1)
    }

    // MARK: small slides (#7)

    func testSmallSlideShowsWithinTwoSeconds() {
        // The owner fine-tunes the angle by sliding the slab a little in its cradle (about 0.72 cm per degree). A change
        // small enough to pass the agreement gates used to creep into the 15-measurement average over about 5 s.
        for (from, to, noise) in [(4.0, 6.0, 0.3), (6.0, 3.5, 0.3), (2.0, 5.0, 0.7)] {
            let base = Vec3(0, 0.066, -0.75)
            var w = World(slab: World.cradled(base: base, tilt: from, heading: 60), lens: .processing)
            let det = SceneDetector(w, noise: noise, seed: 41)
            let tr = SlabTracker(settings: appSettings(), detector: det)
            let pos = Vec3(0.05, 0.8, 0.0)
            var k = 0
            for _ in 0..<(30 * 6) { step(tr, det, swaying(w, pos, base, k), Double(k) / 30); k += 1 }
            XCTAssertEqual(tr.state, .locked)
            w.slab = World.cradled(base: base, tilt: to, heading: 60); det.world = w
            var tiltAt2 = 0.0
            let t0 = Double(k) / 30
            for _ in 0..<(30 * 3) {
                let o = step(tr, det, swaying(w, pos, base, k), Double(k) / 30); k += 1
                if Double(k) / 30 - t0 <= 2.0, let r = o.readouts { tiltAt2 = r.tiltDegrees }
            }
            print(String(format: "slide %.1f -> %.1f deg (%.1f px): reads %.2f after 2 s", from, to, noise, tiltAt2))
            XCTAssertEqual(tiltAt2, to, accuracy: 0.5, "slide \(from) -> \(to)")
        }
    }

    // MARK: the near edge flipping to the cut face (#8, #24)

    func testSustainedNearEdgeFlipDoesNotRelockToAWrongTilt() { checkSustainedNearEdgeFlipDoesNotRelockToAWrongTilt(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testSustainedNearEdgeFlipDoesNotRelockToAWrongTiltOnSlopedSides() { checkSustainedNearEdgeFlipDoesNotRelockToAWrongTilt(TestProfiles.sloped) }

    func checkSustainedNearEdgeFlipDoesNotRelockToAWrongTilt(_ spec: SlabSpec) {
        // The real-phone failure (web/tests/LOG.md, 'Paused here'): the near edge flips between the top face's edge and
        // the bottom of the light cut face. Several flipped re-checks in a row used to relock 5-8 deg off.
        for (dist, elev) in [(0.6, 35.0), (0.75, 45.0), (0.9, 50.0)] {
            let slab = World.slabAt(Vec3(0, 0.066, -0.6), tilt: 5, heading: 250, yaw: 12)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, spec: spec, noise: 0.5, seed: 61)
            let tr = SlabTracker(settings: appSettings(spec), detector: det)
            let e = Units.radians(elev), pos = slab.center + Vec3(0.05, sin(e), cos(e)) * dist
            var k = 0
            for _ in 0..<(30 * 4) { step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1 }
            XCTAssertEqual(tr.state, .locked)
            let before = err(tr.slab, slab)
            let band = w.nearBand(in: swaying(w, pos, slab.center, k), spec: spec)
            // flipped for 3 s (about 10 re-checks), then clean again
            det.flipProbability = 1
            var worst = 0.0
            for _ in 0..<(30 * 3) { let o = step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1; worst = max(worst, err(o.slab, slab)) }
            det.flipProbability = 0
            for _ in 0..<(30 * 2) { let o = step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1; worst = max(worst, err(o.slab, slab)) }
            print(String(format: "flip at %.2f m, %.0f deg (band %.1f px, %d flipped): error before %.2f, worst %.2f deg, relocks %d",
                         dist, elev, band, det.flips, before, worst, tr.counts["relocks"] ?? 0))
            XCTAssertGreaterThan(det.flips, 5)
            XCTAssertEqual(tr.counts["relocks"] ?? 0, 0, "\(dist) m")
            XCTAssertLessThan(worst, before + 1, "\(dist) m")
        }
    }

    func testRandomNearEdgeFlipsKeepTheLock() { checkRandomNearEdgeFlipsKeepTheLock(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testRandomNearEdgeFlipsKeepTheLockOnSlopedSides() { checkRandomNearEdgeFlipsKeepTheLock(TestProfiles.sloped) }

    func checkRandomNearEdgeFlipsKeepTheLock(_ spec: SlabSpec) {
        // 30-50% of re-checks flipped at random over a minute, at desk distance where the band is widest.
        for p in [0.3, 0.5] {
            let slab = World.slabAt(Vec3(0, 0.066, -0.55), tilt: 7, heading: 300, yaw: -8)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, spec: spec, noise: 0.5, seed: 71)
            let tr = SlabTracker(settings: appSettings(spec), detector: det)
            let pos = slab.center + Vec3(0.0, 0.45, 0.45)
            var k = 0
            for _ in 0..<(30 * 3) { step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1 }
            let before = err(tr.slab, slab)
            det.flipProbability = p
            var worst = 0.0
            for _ in 0..<(30 * 60) { let o = step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1; worst = max(worst, err(o.slab, slab)) }
            print(String(format: "random flips p=%.1f (%d of %d calls): before %.2f, worst %.2f deg, relocks %d", p, det.flips, det.calls,
                         before, worst, tr.counts["relocks"] ?? 0))
            XCTAssertEqual(tr.counts["relocks"] ?? 0, 0, "p \(p)")
            XCTAssertLessThan(worst, max(1.0, before + 0.5), "p \(p)")
            XCTAssertEqual(tr.state, .locked)
        }
    }

    func testRelockIsCheckedAgainstLiDARDepth() {
        // A sustained wrong outline that the box model does not explain (the far side caught 6 px out): with LiDAR, the
        // depth plane agrees with the lock and not with the would-be relock, so it is refused.
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 81)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var rng = SeededRandom(4)
        let dm = w.depthMap(v, spec: .standard, rng: &rng)
        var k = 0
        for _ in 0..<(30 * 3) { step(tr, det, v, Double(k) / 30, depth: dm); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        // the far side (smallest y in the image) pushed outward by 6 px from now on
        let q = w.corners(in: v)
        let far = (0..<4).min { (q[$0].y + q[($0 + 1) % 4].y) < (q[$1].y + q[($1 + 1) % 4].y) }!
        det.sideShift = (far, 6)
        var worst = 0.0
        for _ in 0..<(30 * 8) {
            let o = step(tr, det, v, Double(k) / 30, depth: dm); k += 1
            worst = max(worst, err(o.slab, slab))
        }
        print(String(format: "LiDAR-checked relock: relocks %d, worst %.2f deg", tr.counts["relocks"] ?? 0, worst))
        XCTAssertEqual(tr.counts["relocks"] ?? 0, 0)
        XCTAssertLessThan(worst, 1.0)
    }

    func testNearEdgeFlipsFromTheStartDoNotKeepAWrongLock() { checkNearEdgeFlipsFromTheStartDoNotKeepAWrongLock(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testNearEdgeFlipsFromTheStartDoNotKeepAWrongLockOnSlopedSides() { checkNearEdgeFlipsFromTheStartDoNotKeepAWrongLock(TestProfiles.sloped) }

    func checkNearEdgeFlipsFromTheStartDoNotKeepAWrongLock(_ spec: SlabSpec) {
        // The near edge flips at random from the first frame, so the first three detections are sometimes all flipped
        // and the tracker confirms on them. Only asking whether a re-check was the lock's flip, never whether the lock was
        // the re-check's flip, left such a lock 5-6 deg off for as long as flips continued (the top outline counted as an
        // implausible move, which every flipped re-check agreeing with the lock reset). At 1.5 m the band is about 4 px
        // and some flipped re-checks also passed for the top, pulling even a good lock 3-6 deg off.
        var flippedLocks = 0
        // limit: how far off the lock may be, about the noise floor without flips (a band of 7 px at 0.64 m, 4 px at 1.5 m)
        for (dist, elev, limit) in [(0.64, 45.0, 1.0), (1.5, 55.0, 1.5)] {
            for p in [0.5, 0.7] {
                var endOff = 0, spellMax = 0.0, framesOff = 0, frames = 0, toTop = 0
                for trial in 0..<12 {
                    let slab = World.slabAt(Vec3(0, 0.066, -0.55), tilt: 4 + Double(trial % 5), heading: 250 + Double(trial) * 9, yaw: -8 + Double(trial))
                    let w = World(slab: slab, lens: .processing)
                    let det = SceneDetector(w, spec: spec, noise: 0.5, seed: UInt64(800 + trial))
                    det.flipProbability = p
                    let tr = SlabTracker(settings: appSettings(spec), detector: det)
                    let e = Units.radians(elev), pos = slab.center + Vec3(0.05, sin(e), cos(e)) * dist
                    var spell = 0.0
                    for k in 0..<(30 * 30) {
                        let t = Double(k) / 30
                        let o = step(tr, det, swaying(w, pos, slab.center, k), t)
                        if o.events.contains("locked"), err(o.slab, slab) > 3 { flippedLocks += 1 }
                        guard o.state == .locked else { continue }
                        let er = err(o.slab, slab)
                        // the longest the lock stays more than 1.5 deg off, and how often it is past the limit after 5 s
                        if er > 1.5 { spell += 1.0 / 30; spellMax = max(spellMax, spell) } else { spell = 0 }
                        if t > 5 { frames += 1; if er > limit { framesOff += 1 } }
                    }
                    if err(tr.slab, slab) > limit { endOff += 1 }
                    toTop += tr.counts["relocksToTop"] ?? 0
                }
                let off = Double(framesOff) / Double(max(1, frames))
                print(String(format: "flips from the start, %.2f m %.0f deg, p=%.1f: more than %.1f deg off at 30 s %d/12, after 5 s %.1f%% of frames; longest more than 1.5 deg off %.1f s; relocks to the top %d",
                             dist, elev, p, limit, endOff, off * 100, spellMax, toTop))
                XCTAssertEqual(endOff, 0, "\(dist) m p \(p)")
                XCTAssertLessThan(off, 0.02, "\(dist) m p \(p)")
                XCTAssertLessThan(spellMax, 3.5, "\(dist) m p \(p)")
            }
        }
        // the scenario happened: some trials did confirm on flipped outlines
        XCTAssertGreaterThan(flippedLocks, 5)
    }

    func testALockOnFlippedOutlinesMovesToTheTopAtOnce() { checkALockOnFlippedOutlinesMovesToTheTopAtOnce(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testALockOnFlippedOutlinesMovesToTheTopAtOnceOnSlopedSides() { checkALockOnFlippedOutlinesMovesToTheTopAtOnce(TestProfiles.sloped) }

    func checkALockOnFlippedOutlinesMovesToTheTopAtOnce(_ spec: SlabSpec) {
        // Flipped outlines for the first 2 s (it locks on them), then clean ones: the old tracker needed about 3.4 s of
        // clean re-checks (11-12 of them, the cradle check tripling the evidence) to leave the flipped lock.
        var times: [Double] = []
        for trial in 0..<12 {
            let slab = World.slabAt(Vec3(0, 0.066, -0.55), tilt: 7, heading: 300 + Double(trial) * 11, yaw: -8)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, spec: spec, noise: 0.5, seed: UInt64(400 + trial))
            det.flipProbability = 1
            let tr = SlabTracker(settings: appSettings(spec), detector: det)
            let pos = slab.center + Vec3(0.0, 0.45, 0.45)
            var k = 0
            for _ in 0..<(30 * 2) { step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1 }
            XCTAssertEqual(tr.state, .locked)
            XCTAssertGreaterThan(err(tr.slab, slab), 3, "trial \(trial) locked on the flipped outlines")
            det.flipProbability = 0
            let t0 = Double(k) / 30
            var fixedAt: Double? = nil
            for _ in 0..<(30 * 6) {
                let o = step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1
                if fixedAt == nil, err(o.slab, slab) < 1 { fixedAt = Double(k) / 30 - t0 }
            }
            times.append(fixedAt ?? 99)
            XCTAssertLessThan(err(tr.slab, slab), 1, "trial \(trial)")
            XCTAssertEqual(tr.counts["relocksToTop"] ?? 0, 1, "trial \(trial)")
        }
        times.sort()
        print(String(format: "locked on flipped outlines, then clean: within 1 deg after median %.2f s, worst %.2f s", times[6], times.last!))
        XCTAssertLessThan(times.last!, 1.2)
    }

    func testASidePutABandInsideTheTopDoesNotMoveTheLockAtDeskDistance() { checkASidePutABandInsideTheTopDoesNotMoveTheLockAtDeskDistance(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testASidePutABandInsideTheTopDoesNotMoveTheLockAtDeskDistanceOnSlopedSides() { checkASidePutABandInsideTheTopDoesNotMoveTheLockAtDeskDistance(TestProfiles.sloped) }

    func checkASidePutABandInsideTheTopDoesNotMoveTheLockAtDeskDistance(_ spec: SlabSpec) {
        // The mirror of the flip: a detector that sometimes puts the near side a band inside the top. Geometry alone
        // cannot tell which of two outlines a band apart is the top, so the rule that the inner one is would follow it;
        // up close the pose fits can (the inner outline misfits the square by about 1 px, the top by the noise). The
        // tracker before used to confirm on such outlines and then ignore the top as their flip: more than 3 deg off 33%
        // and 83% of the time at q 0.1 and 0.3. (At 1.5 m the fits cannot tell, and the inner outline is taken.)
        for q in [0.1, 0.3] {
            var endOff = 0, framesOff = 0, frames = 0, ignored = 0
            for trial in 0..<12 {
                let slab = World.slabAt(Vec3(0, 0.066, -0.55), tilt: 3 + Double(trial % 7), heading: 200 + Double(trial) * 13, yaw: -20 + Double(trial))
                let w = World(slab: slab, lens: .processing)
                let det = SceneDetector(w, spec: spec, noise: 0.5, seed: UInt64(6000 + trial))
                det.inwardProbability = q
                let tr = SlabTracker(settings: appSettings(spec), detector: det)
                let e = Units.radians(45.0), pos = slab.center + Vec3(0.05, sin(e), cos(e)) * 0.64
                for k in 0..<(30 * 30) {
                    let t = Double(k) / 30
                    let o = step(tr, det, swaying(w, pos, slab.center, k), t)
                    if t > 5, o.state == .locked { frames += 1; if err(o.slab, slab) > 3 { framesOff += 1 } }
                }
                if err(tr.slab, slab) > 1 { endOff += 1 }
                ignored += tr.counts["recheckInnerWorse"] ?? 0
            }
            let off = Double(framesOff) / Double(max(1, frames))
            print(String(format: "side a band inside the top, q=%.1f at 0.64 m: more than 1 deg off at 30 s %d/12, more than 3 deg off %.1f%% of frames after 5 s; %d such re-checks ignored",
                         q, endOff, off * 100, ignored))
            XCTAssertEqual(endOff, 0, "q \(q)")
            XCTAssertLessThan(off, 0.02, "q \(q)")
            XCTAssertGreaterThan(ignored, 10, "q \(q)")
        }
    }

    func testCleanOutlinesNeverMoveTheLockToAnInnerOutline() { checkCleanOutlinesNeverMoveTheLockToAnInnerOutline(.standard) }
    /// The same on the owner's slab with its sloped sides (`TestProfiles.sloped`): the detector's flips go to the sloped
    /// face's bottom, and the tracker's box model has the profile.
    func testCleanOutlinesNeverMoveTheLockToAnInnerOutlineOnSlopedSides() { checkCleanOutlinesNeverMoveTheLockToAnInnerOutline(TestProfiles.sloped) }

    func checkCleanOutlinesNeverMoveTheLockToAnInnerOutline(_ spec: SlabSpec) {
        // The other side of the rule above: noisy clean outlines of a still slab (a walk around it, 0.6-1.4 m) must not
        // look like the top under a flipped lock often enough to move a good lock inward.
        for noise in [1.0, 1.5] {
            var inner = 0, toTop = 0, rechecks = 0
            for trial in 0..<8 {
                let slab = World.slabAt(Vec3(0, 0.066, 0), tilt: 3 + Double(trial), heading: Double(trial) * 45)
                let w = World(slab: slab, lens: .processing)
                let det = SceneDetector(w, spec: spec, noise: noise, seed: UInt64(900 + trial))
                let tr = SlabTracker(settings: appSettings(spec), detector: det)
                for k in 0..<(30 * 40) {
                    let t = Double(k) / 30
                    let az = Units.radians(90 * t / 40), el = Units.radians(35 + Double(trial) * 3)
                    let pos = slab.center + Vec3(sin(az) * cos(el), sin(el), cos(az) * cos(el)) * (0.6 + 0.12 * Double(trial))
                    step(tr, det, swaying(w, pos, slab.center, k), t)
                }
                inner += tr.counts["recheckInner"] ?? 0; toTop += tr.counts["relocksToTop"] ?? 0; rechecks += tr.counts["rechecks"] ?? 0
            }
            print("clean outlines at \(noise) px: \(rechecks) re-checks, \(inner) taken for the top under a flipped lock, \(toTop) relocks to it")
            XCTAssertEqual(toTop, 0, "\(noise) px")
            XCTAssertLessThan(Double(inner), 0.01 * Double(rechecks), "\(noise) px")
        }
    }

    // MARK: movers only near an in-view lock (#9)

    // MARK: the moved-slab rule (n20r, `findsMovedSlab`, on in the app) and lookalikes at the slab's height

    /// Looking away at a lookalike whose top is at the slab's height (a box, a second slab) 1.5 m away: with the app's
    /// moved-slab rule a whole-view look sees it while the lock is out of the picture, but it lies beyond
    /// `movedSlabRadius` (1 m) of the lock: not the slab moved, the lock stays.
    func testMovedSlabRuleIgnoresASlabHeightLookalikeAcrossTheRoom() {
        XCTAssertTrue(RecordingSettings().trackerSettings.findsMovedSlab, "the app's settings have the rule on")
        for top in [0.03, 0.066, 0.09] {
            let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 91)
            let tr = SlabTracker(settings: appSettings(findsMovedSlab: true), detector: det)
            let pos = Vec3(0, 0.9, 0)
            var k = 0
            for _ in 0..<(30 * 3) { step(tr, det, w.view(from: pos, at: slab.center), Double(k) / 30); k += 1 }
            let before = tr.slab!
            det.other = World.slabAt(Vec3(1.5, top, -0.8), tilt: 0, heading: 0, yaw: 30)
            for _ in 0..<(30 * 6) { step(tr, det, w.view(from: pos, at: det.other!.center), Double(k) / 30); k += 1 }
            XCTAssertLessThan(tr.slab?.center.distance(to: before.center) ?? 99, 0.01, "top \(top) m: the lock stays")
            XCTAssertEqual(tr.counts["movedAway"] ?? 0, 0, "top \(top) m")
            XCTAssertGreaterThan(tr.counts["movedSlabLooks"] ?? 0, 0, "top \(top) m: the whole view was looked over")
        }
    }

    /// A lookalike at the slab's height 35 cm from it, in the picture beside the locked slab for 1 s; then the slab goes
    /// unseen for 1.5 s (glare, a hand that does not excuse the miss) while the lookalike is still found: the whole-view
    /// looks find only it, where a lookalike was seen beside the locked slab, so the lock stays. (A lookalike within 1 m
    /// that was never seen beside the locked slab is taken for the slab moved there after two looks: the accepted risk,
    /// printed here and stated in the README.)
    func testMovedSlabRuleIgnoresALookalikeSeenBesideTheSlab() {
        for seenBeside in [true, false] {
            let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 93)
            let tr = SlabTracker(settings: appSettings(findsMovedSlab: true), detector: det)
            let pos = Vec3(0, 0.9, 0.1)
            var k = 0
            let v = w.view(from: pos, at: slab.center + Vec3(0.15, 0, 0))
            for _ in 0..<(30 * 3) { step(tr, det, v, Double(k) / 30); k += 1 }
            let before = tr.slab!
            det.other = World.slabAt(Vec3(0.35, 0.066, -1.0), tilt: 0, heading: 0, yaw: 10)
            if seenBeside { for _ in 0..<30 { step(tr, det, v, Double(k) / 30); k += 1 } }
            det.onlyOther = true
            for _ in 0..<45 { step(tr, det, v, Double(k) / 30); k += 1 }
            det.onlyOther = false
            for _ in 0..<(30 * 3) { step(tr, det, v, Double(k) / 30); k += 1 }
            let moved = tr.slab?.center.distance(to: before.center) ?? 99
            if seenBeside {
                XCTAssertLessThan(moved, 0.01, "the lock stays at the slab")
                XCTAssertEqual(tr.counts["movedAway"] ?? 0, 0)
                XCTAssertEqual(tr.counts["lost"] ?? 0, 0)
            } else {
                print(String(format: "ACCEPTED RISK (README, n20r): a slab-height lookalike 35 cm away never seen beside the slab, the slab unseen 1.5 s: lock moved %.3f m, moved-away %d",
                             moved, tr.counts["movedAway"] ?? 0))
            }
        }
    }

    func testLookingAwayAtALookalikeDoesNotMoveTheLock() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 91)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let pos = Vec3(0, 0.9, 0)
        var k = 0
        for _ in 0..<(30 * 3) { step(tr, det, w.view(from: pos, at: slab.center), Double(k) / 30); k += 1 }
        let before = tr.slab!
        // a floor tile 1.5 m to the side; the detector ignores the prediction and reports it
        det.other = World.slabAt(Vec3(1.5, 0.0, -0.8), tilt: 0, heading: 0, yaw: 30)
        for _ in 0..<(30 * 6) { step(tr, det, w.view(from: pos, at: det.other!.center), Double(k) / 30); k += 1 }
        XCTAssertLessThan(tr.slab!.center.distance(to: before.center), 0.01)
        XCTAssertEqual(tr.counts["relocks"] ?? 0, 0)
        // looking back, the outline is on the slab at once
        let v = w.view(from: pos, at: slab.center)
        let o = step(tr, det, v, Double(k) / 30)
        let truth = w.corners(in: v)
        XCTAssertLessThan(zip(o.outline!, truth).map { $0.distance(to: $1) }.max()!, 3)
    }

    // MARK: the lost rule (#10)

    func testLimitedTrackingDoesNotCountTowardLosingTheLock() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 101)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        // 5 s of limited tracking (walking around fast), then the first re-check misses (motion blur)
        for _ in 0..<(30 * 5) { step(tr, det, v, Double(k) / 30, normal: false); k += 1 }
        det.silent = true
        for _ in 0..<12 { let o = step(tr, det, v, Double(k) / 30); k += 1; XCTAssertFalse(o.events.contains("lost")) }
        XCTAssertEqual(tr.state, .locked)
        det.silent = false
        for _ in 0..<30 { step(tr, det, v, Double(k) / 30); k += 1 }
        XCTAssertEqual(tr.state, .locked)
    }

    func testABallHeldOverTheSlabDoesNotLoseTheLock() {
        // the held ball hides part of the slab and the detector finds nothing for 8 s; the ball finder sees the ball
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 111)
        let ball = HeldBall()
        let tr = SlabTracker(settings: appSettings(), detector: det, ballLocator: ball)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30, ball: true); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        ball.present = true; det.silent = true
        for _ in 0..<(30 * 8) { step(tr, det, v, Double(k) / 30, ball: true); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        // the hand takes the ball away and the slab is not there any more: lost after the usual time
        ball.present = false
        var lostAfter: Double? = nil
        let t0 = Double(k) / 30
        for _ in 0..<(30 * 8) { let o = step(tr, det, v, Double(k) / 30, ball: true); k += 1; if o.events.contains("lost") { lostAfter = Double(k) / 30 - t0; break } }
        XCTAssertNotNil(lostAfter)
        XCTAssertGreaterThan(lostAfter ?? 0, TrackerSettings().lostAfter - 0.2)
    }

    func testAHandOverACornerDoesNotLoseTheLock() {
        // a hand covering one corner: the detector still finds the slab's outline there, misshapen (it fails the shape
        // check), for 8 s
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 121)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30); k += 1 }
        det.occludedCorner = true
        for _ in 0..<(30 * 8) { step(tr, det, v, Double(k) / 30); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        XCTAssertGreaterThan(tr.counts["reject:misfit"] ?? 0, 10)
    }

    func testLiDARStillSeeingTheTopKeepsTheLock() {
        // the detector misses the slab for 8 s (glare, a shadow) but LiDAR still sees its top where the lock is: kept.
        // When the slab is lifted away, LiDAR sees the ground there instead and the lock goes after the usual time.
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 125)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: slab.center)
        var rng = SeededRandom(12)
        let top = w.depthMap(v, spec: .standard, rng: &rng), ground = w.depthMap(v, spec: .standard, slabPresent: false, rng: &rng)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30, depth: top); k += 1 }
        det.silent = true
        for _ in 0..<(30 * 8) { step(tr, det, v, Double(k) / 30, depth: top); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        var lostAfter: Double? = nil
        let t0 = Double(k) / 30
        for _ in 0..<(30 * 8) { let o = step(tr, det, v, Double(k) / 30, depth: ground); k += 1; if o.events.contains("lost") { lostAfter = Double(k) / 30 - t0; break } }
        XCTAssertNotNil(lostAfter)
        XCTAssertGreaterThan(lostAfter ?? 0, TrackerSettings().lostAfter - 0.2)
    }

    // MARK: LiDAR fusion (#11, #12)

    func testAHandAboveTheSlabIsNotFusedAsItsTop() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0, seed: 131)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: slab.center)
        var rng = SeededRandom(5)
        let clean = w.depthMap(v, spec: .standard, rng: &rng)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30, depth: clean); k += 1 }
        let imageTilt = Units.degrees(tr.imageSlab!.tilt(down: ARKitConvention.worldDown))
        // a flat hand 5 cm above the top, 3 deg off its plane, covering it; then the ground (the slab lifted away)
        let handN = slab.normal.rotated(by: slab.axisU * Units.radians(3))
        for (name, dm) in [("hand", w.depthMap(v, spec: .standard, occluder: (slab.center + slab.normal * 0.05, handN, 0.07), rng: &rng)),
                           ("parallel hand", w.depthMap(v, spec: .standard, occluder: (slab.center + slab.normal * 0.03, slab.normal, 0.07), rng: &rng)),
                           ("ground", w.depthMap(v, spec: .standard, slabPresent: false, rng: &rng))] {
            var worstTilt = 0.0, worstMove = 0.0
            for _ in 0..<20 {
                let o = step(tr, det, v, Double(k) / 30, depth: dm); k += 1
                worstTilt = max(worstTilt, abs(o.readouts!.tiltDegrees - imageTilt))
                worstMove = max(worstMove, o.slab!.center.distance(to: tr.imageSlab!.center))
            }
            print(String(format: "%@: tilt moved %.2f deg, centre %.1f mm, depth offset %.1f mm", name, worstTilt, worstMove * 1000, (tr.depth?.centreOffset ?? 0) * 1000))
            XCTAssertLessThan(worstTilt, 0.3, name)
            XCTAssertLessThan(worstMove, 0.003, name)
        }
    }

    func testDepthNoiseDoesNotShakeTheReadout() {
        // raw per-frame LiDAR planes, fused at weight 0.5 every frame, made the tilt readout jump by tenths of a degree
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 5, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0, seed: 141)
        var s = appSettings(); s.searchInterval = 0
        let tr = SlabTracker(settings: s, detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: slab.center)
        var rng = SeededRandom(6)
        let maps = (0..<12).map { _ in w.depthMap(v, spec: .standard, scale: 0.55, noise: 0.005, rng: &rng) }
        var k = 0, tilts: [Double] = [], fusedErr = 0.0
        for _ in 0..<(60 * 3) {
            let o = step(tr, det, v, Double(k) / 60, depth: maps[k % maps.count]); k += 1
            if k > 60, let r = o.readouts { tilts.append(r.tiltDegrees); fusedErr = err(o.slab, slab) }
        }
        let steps = zip(tilts.dropFirst(), tilts).map { abs($0 - $1) }.sorted()
        print(String(format: "depth noise 5 mm: frame-to-frame tilt change median %.3f max %.3f deg; fused error %.2f deg", steps[steps.count / 2], steps.last!, fusedErr))
        XCTAssertLessThan(steps[steps.count / 2], 0.03)
        XCTAssertLessThan(steps.last!, 0.15)
        XCTAssertLessThan(fusedErr, 1.0)
    }

    // MARK: diagnostics (#13, #27, #28)

    func testRejectionCountersUseFixedKeys() {
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let shear = ShearDetector(w)
        var s = appSettings(); s.searchInterval = 0
        let tr = SlabTracker(settings: s, detector: shear)
        let v = w.view(from: Vec3(0, 0.9, 0), at: slab.center)
        for k in 0..<100 { shear.view = v; shear.amount = 20 + Double(k) * 0.1; _ = tr.process(TrackerFrame(timestamp: Double(k) / 30, view: v, frame: blank)) }
        XCTAssertEqual(tr.counts["reject:misfit"], 100)
        XCTAssertEqual(tr.counts.keys.filter { $0.hasPrefix("reject:misfit") }.count, 1)
    }

    func testPerFrameEventsDoNotFloodTheEventList() {
        // on a LiDAR phone the app's 30 recent events used to fill with "depth-fused" within half a second
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 5, heading: 30)
        let w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.3, seed: 151)
        let tr = SlabTracker(settings: appSettings(), detector: det)
        let v = w.view(from: Vec3(0, 0.9, 0.1), at: slab.center)
        var rng = SeededRandom(7)
        let dm = w.depthMap(v, spec: .standard, rng: &rng)
        var all: [String] = []
        for k in 0..<(60 * 3) { all += step(tr, det, v, Double(k) / 60, depth: dm).events }
        let ring = Array(all.suffix(30))
        print("events over 3 s: \(all.count): \(all.prefix(12))")
        XCTAssertTrue(ring.contains("locked"), "\(ring)")
        XCTAssertLessThanOrEqual(all.filter { $0 == "depth-fused" }.count, 1)
        XCTAssertLessThan(all.count, 15)
    }

    // MARK: the tap (#5)

    func testATapSeedsTheSearchUntilItLocks() {
        // locked on a lookalike B; the owner taps the slab A. The detector ranks B first unless seeded on A.
        let a = World.slabAt(Vec3(0, 0.066, -1.2), tilt: 6, heading: 30)
        let b = World.slabAt(Vec3(0.3, 0.066, -1.3), tilt: 0, heading: 0, yaw: 30)
        let w = World(slab: a, lens: .processing)
        for limitedTap in [false, true] {
            let det = SceneDetector(w, noise: 0.3, seed: 161)
            det.other = b
            let tr = SlabTracker(settings: appSettings(), detector: det)
            let v = w.view(from: Vec3(0.1, 0.9, 0), at: (a.center + b.center) / 2)
            var k = 0
            for _ in 0..<(30 * 2) { step(tr, det, v, Double(k) / 30); k += 1 }
            XCTAssertLessThan(tr.slab!.center.distance(to: b.center), 0.03, "locked on the lookalike first")
            let tapAt = w.corners(in: v).reduce(Vec2.zero) { $0 + $1 } / 4
            step(tr, det, v, Double(k) / 30, tap: tapAt, normal: !limitedTap); k += 1
            if limitedTap { for _ in 0..<10 { step(tr, det, v, Double(k) / 30, normal: false); k += 1 } }
            for _ in 0..<(30 * 3) { step(tr, det, v, Double(k) / 30); k += 1 }
            XCTAssertEqual(tr.state, .locked, "limited \(limitedTap)")
            XCTAssertLessThan(tr.slab?.center.distance(to: a.center) ?? 9, 0.03, "limited \(limitedTap): locked on the tapped slab")
            XCTAssertGreaterThan(det.seeds.compactMap { $0 }.count, 1, "the seed is used for more than one search")
        }
    }

    // MARK: world-frame discontinuities (#15)

    func testAPoseJumpMakesTheLockProveItself() {
        // ARKit snaps its world frame (relocalisation after limited tracking): the camera's reported position jumps by
        // 0.9 m and the real slab's world coordinates move with it; the stored lock is now beside the slab, partly off
        // screen, and a detector that searches around the prediction finds nothing there.
        let slab = World.slabAt(Vec3(0, 0.066, -1.0), tilt: 6, heading: 30)
        var w = World(slab: slab, lens: .processing)
        let det = SceneDetector(w, noise: 0.5, seed: 171)
        det.nearRadius = 80
        let tr = SlabTracker(settings: appSettings(), detector: det)
        var k = 0
        for _ in 0..<(30 * 2) { step(tr, det, swaying(w, Vec3(0, 0.9, 0), slab.center, k), Double(k) / 30); k += 1 }
        XCTAssertEqual(tr.state, .locked)
        let shift = Vec3(0.9, 0, 0.1)
        var moved = slab; moved.center = moved.center + shift
        w.slab = moved; det.world = w
        var o: TrackerOutput! = nil
        for _ in 0..<(30 * 10) { o = step(tr, det, swaying(w, Vec3(0, 0.9, 0) + shift, moved.center, k), Double(k) / 30); k += 1 }
        let truth = w.corners(in: swaying(w, Vec3(0, 0.9, 0) + shift, moved.center, k - 1))
        XCTAssertEqual(o.state, .locked)
        XCTAssertLessThan(o.outline.map { zip($0, truth).map { $0.distance(to: $1) }.max()! } ?? 999, 3)
    }
}

/// An outline sheared more each frame (a misfit every time).
final class ShearDetector: SlabDetecting {
    let world: World
    var view: CameraView?
    var amount = 20.0
    init(_ w: World) { world = w }
    func detect(frame: ColorFrame, intrinsics: CameraIntrinsics, spec: SlabSpec, down: Vec3?, seed: Vec2?, near: [Vec2]?) -> [DetectedOutline] {
        guard let v = view else { return [] }
        var q = world.corners(in: v)
        q[2] = q[2] + Vec2(amount, 0)
        return [DetectedOutline(quad: q)]
    }
}
