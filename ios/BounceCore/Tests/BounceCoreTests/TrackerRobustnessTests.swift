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
    /// bottom of the 1 in cut face instead of at the top edge: that side's line moves to the projected bottom edge and its
    /// corners to where it meets the neighbouring top edges. Worked out here independently of SlabBoxView.
    func cutFlipOutline(in v: CameraView, spec: SlabSpec) -> [Vec2]? {
        let pc = slab.transformed(by: v.cameraFromWorld), K = v.intrinsics
        let topC = pc.topCorners
        let top = topC.compactMap { K.project($0) }, bot = topC.compactMap { K.project($0 - pc.normal * spec.thickness) }
        guard top.count == 4, bot.count == 4 else { return nil }
        var best = -1, bw = 0.0
        for i in 0..<4 {
            let j = (i + 1) % 4, mid = (topC[i] + topC[j]) / 2 - pc.normal * (spec.thickness / 2)
            guard (mid - pc.center).rejecting(pc.normal).dot(-mid) > 0 else { continue }
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
    private(set) var flips = 0, calls = 0
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

    /// the tracker settings the app uses (AppModel only changes the search interval)
    func appSettings(_ spec: SlabSpec = .standard) -> TrackerSettings {
        var s = TrackerSettings(); s.searchInterval = 0.12; s.spec = spec
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

    func testSustainedNearEdgeFlipDoesNotRelockToAWrongTilt() {
        // The real-phone failure (web/tests/LOG.md, 'Paused here'): the near edge flips between the top face's edge and
        // the bottom of the light cut face. Several flipped re-checks in a row used to relock 5-8 deg off.
        for (dist, elev) in [(0.6, 35.0), (0.75, 45.0), (0.9, 50.0)] {
            let slab = World.slabAt(Vec3(0, 0.066, -0.6), tilt: 5, heading: 250, yaw: 12)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 61)
            let tr = SlabTracker(settings: appSettings(), detector: det)
            let e = Units.radians(elev), pos = slab.center + Vec3(0.05, sin(e), cos(e)) * dist
            var k = 0
            for _ in 0..<(30 * 4) { step(tr, det, swaying(w, pos, slab.center, k), Double(k) / 30); k += 1 }
            XCTAssertEqual(tr.state, .locked)
            let before = err(tr.slab, slab)
            let band = w.nearBand(in: swaying(w, pos, slab.center, k), spec: .standard)
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

    func testRandomNearEdgeFlipsKeepTheLock() {
        // 30-50% of re-checks flipped at random over a minute, at desk distance where the band is widest.
        for p in [0.3, 0.5] {
            let slab = World.slabAt(Vec3(0, 0.066, -0.55), tilt: 7, heading: 300, yaw: -8)
            let w = World(slab: slab, lens: .processing)
            let det = SceneDetector(w, noise: 0.5, seed: 71)
            let tr = SlabTracker(settings: appSettings(), detector: det)
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

    // MARK: movers only near an in-view lock (#9)

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
