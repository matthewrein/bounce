import XCTest
@testable import BounceCore

final class GeometryTests: XCTestCase {
    func testVectorBasics() {
        let a = Vec3(1, 2, 3), b = Vec3(-2, 0.5, 4)
        XCTAssertEqual(a.dot(b), -2 + 1 + 12, accuracy: 1e-12)
        let c = a.cross(b)
        XCTAssertEqual(c.dot(a), 0, accuracy: 1e-12)
        XCTAssertEqual(c.dot(b), 0, accuracy: 1e-12)
        XCTAssertEqual(Vec3(3, 4, 0).length, 5, accuracy: 1e-12)
        XCTAssertEqual(Vec3(1, 0, 0).angle(to: Vec3(0, 1, 0)), .pi / 2, accuracy: 1e-12)
    }

    func testRodriguesRotation() {
        let v = Vec3(1, 0, 0).rotated(by: Vec3(0, 0, .pi / 2))
        XCTAssertEqual(v.x, 0, accuracy: 1e-12); XCTAssertEqual(v.y, 1, accuracy: 1e-12); XCTAssertEqual(v.z, 0, accuracy: 1e-12)
        // rotation keeps length and the axis component
        let w = Vec3(0.3, -0.2, 0.5), p = Vec3(2, -1, 0.5)
        XCTAssertEqual(p.rotated(by: w).length, p.length, accuracy: 1e-12)
        XCTAssertEqual(p.rotated(by: w).dot(w.normalized), p.dot(w.normalized), accuracy: 1e-12)
    }

    func testMatrixInverseAndTransforms() {
        let m = Mat3(rows: [2, 0.5, 0, -1, 3, 0.2, 0.1, 0, 1])
        let inv = m.inverse!
        let id = m * inv
        for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(id[i, j], i == j ? 1 : 0, accuracy: 1e-12) } }
        let rot = Mat3(columns: Vec3(1, 0, 0).rotated(by: Vec3(0.1, 0.2, 0.3)), Vec3(0, 1, 0).rotated(by: Vec3(0.1, 0.2, 0.3)), Vec3(0, 0, 1).rotated(by: Vec3(0.1, 0.2, 0.3)))
        let t = RigidTransform(rotation: rot, translation: Vec3(1, -2, 0.5))
        let p = Vec3(0.3, 0.7, -1.1)
        let back = t.inverse.apply(t.apply(p))
        XCTAssertEqual(back.distance(to: p), 0, accuracy: 1e-12)
        // column-major 4x4 round trip (simd layout)
        let t2 = RigidTransform(columnMajor4x4: t.columnMajor4x4)
        XCTAssertEqual(t2.apply(p).distance(to: t.apply(p)), 0, accuracy: 1e-12)
    }

    func testSolveLinear() {
        let x = solveLinear([[0, 2, 1], [1, 1, 1], [2, 1, 0]], [7, 6, 4])!
        XCTAssertEqual(x[0], 1, accuracy: 1e-12); XCTAssertEqual(x[1], 2, accuracy: 1e-12); XCTAssertEqual(x[2], 3, accuracy: 1e-12)
        XCTAssertNil(solveLinear([[1, 2], [2, 4]], [1, 2]))
    }

    func testIntrinsicsProjectAndScale() {
        let K = CameraIntrinsics(verticalFovDegrees: 72.5, width: 720, height: 1280)
        XCTAssertEqual(K.verticalFovDegrees, 72.5, accuracy: 1e-9)
        let p = Vec3(0.1, -0.05, 1.2)
        let q = K.project(p)!
        let back = K.unproject(q, depth: 1.2)
        XCTAssertEqual(back.distance(to: p), 0, accuracy: 1e-12)
        // a half-size image sees the same point at half the pixel coordinates (corner-origin convention)
        let K2 = K.scaled(by: 0.5), q2 = K2.project(p)!
        XCTAssertEqual(q2.x, q.x / 2, accuracy: 1e-9); XCTAssertEqual(q2.y, q.y / 2, accuracy: 1e-9)
        XCTAssertNil(K.project(Vec3(0, 0, -1)))
        // ARKit's column-major 3x3 layout
        let K3 = CameraIntrinsics(columnMajor3x3: [1400, 0, 0, 0, 1401, 0, 960, 720, 1], width: 1920, height: 1440)
        XCTAssertEqual(K3.fx, 1400); XCTAssertEqual(K3.fy, 1401); XCTAssertEqual(K3.cx, 960); XCTAssertEqual(K3.cy, 720)
    }

    func testARKitConvention() {
        // a camera at the world origin looking straight down -z (ARKit's identity camera) sees a point 1 m ahead at CV z=+1
        let view = CameraView(worldFromCamera: ARKitConvention.worldFromCVCamera(arkitCameraTransform: .identity),
                              intrinsics: CameraIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440))
        let pc = view.toCamera(Vec3(0, 0, -1))
        XCTAssertEqual(pc.z, 1, accuracy: 1e-12)
        // ARKit y up -> image y down: a point above the axis projects above the image centre
        let q = view.project(world: Vec3(0, 0.1, -1))!
        XCTAssertLessThan(q.y, 720)
        // world down seen from this camera is +y in CV axes (down the image)
        let g = view.directionToCamera(ARKitConvention.worldDown)
        XCTAssertEqual(g.y, 1, accuracy: 1e-12)
    }

    func testSlabPoseCornersAndFromCorners() {
        let n = Vec3(0.1, 1, 0.05).normalized, u = n.anyPerpendicular, v = n.cross(u)
        let pose = SlabPose(center: Vec3(0.2, 0.1, -1), normal: n, axisU: u, axisV: v, halfU: 0.09, halfV: 0.085)
        let back = SlabPose.fromCorners(pose.topCorners)!
        XCTAssertEqual(back.center.distance(to: pose.center), 0, accuracy: 1e-12)
        XCTAssertEqual(back.normal.distance(to: pose.normal), 0, accuracy: 1e-12)
        XCTAssertEqual(back.halfU, 0.09, accuracy: 1e-12)
        XCTAssertEqual(back.halfV, 0.085, accuracy: 1e-12)
        let (lu, lv) = pose.local(pose.point(u: 0.03, v: -0.02))
        XCTAssertEqual(lu, 0.03, accuracy: 1e-12); XCTAssertEqual(lv, -0.02, accuracy: 1e-12)
    }

    func testDishShape() {
        let pose = SlabPose(center: .zero, normal: Vec3(0, 1, 0), axisU: Vec3(1, 0, 0), axisV: Vec3(0, 0, -1), halfU: 0.1, halfV: 0.1)
        let D = 0.003
        let mid = Dish.at(pose: pose, depth: D, u: 0, v: 0)
        XCTAssertEqual(mid.depth, D, accuracy: 1e-15)
        XCTAssertEqual(mid.normal.distance(to: pose.normal), 0, accuracy: 1e-15)
        let edge = Dish.at(pose: pose, depth: D, u: 0.1, v: 0)
        XCTAssertEqual(edge.depth, D / 2, accuracy: 1e-15) // middles of the edges: half as deep
        XCTAssertEqual(Dish.at(pose: pose, depth: D, u: 0.1, v: 0.1).depth, 0, accuracy: 1e-15) // corners: on the plane
        // off-centre toward +u, the dish normal leans back toward the middle (-u) by the slope D*u/h^2
        XCTAssertLessThan(edge.normal.x, 0)
        XCTAssertEqual(atan2(-edge.normal.x, edge.normal.y), atan(D * 0.1 / 0.01), accuracy: 1e-12)
        // numerical slope check: the normal is perpendicular to the surface
        let e = 1e-6, s0 = Dish.at(pose: pose, depth: D, u: 0.05, v: 0.02), s1 = Dish.at(pose: pose, depth: D, u: 0.05 + e, v: 0.02)
        let tangent = Vec3(e, -(s1.depth - s0.depth), 0)
        XCTAssertEqual(tangent.normalized.dot(s0.normal), 0, accuracy: 1e-6)
    }

    func testBoxViewCutFaces() {
        // camera at origin looking down at a level slab 1 m ahead and 0.6 m below: the near side's cut face shows,
        // the far side's does not
        let K = CameraIntrinsics(verticalFovDegrees: 60, width: 1280, height: 960)
        let down = Vec3(0, 0.6, 0.8).normalized // camera pitched down (CV axes: y down, z forward)
        let up = -down
        let fwd = Vec3(0, 0, 1).rejecting(up).normalized
        let pose = SlabPose(center: Vec3(0, 0, 0) + fwd * 1.0 + down * 0.6, normal: up, axisU: Vec3(1, 0, 0), axisV: Vec3(1, 0, 0).cross(up).normalized * -1, halfU: 0.089, halfV: 0.089)
        let fixed = SlabPose.fromCorners(pose.topCorners)!
        let box = SlabBoxView(pose: fixed, spec: .standard, intrinsics: K)
        var visible = 0
        for i in 0..<4 where box.cutFaceVisible(side: i) { visible += 1 }
        XCTAssertGreaterThanOrEqual(visible, 1)
        XCTAssertLessThanOrEqual(visible, 2)
        // the visible face's band is a few pixels to tens of pixels wide here
        for i in 0..<4 where box.cutFaceVisible(side: i) {
            let w = box.cutBandWidth(side: i)
            XCTAssertGreaterThan(w.start, 1); XCTAssertLessThan(w.start, 100)
        }
    }

    func testCutBandWidthIsMeasuredAcrossTheSide() {
        // A level slab seen obliquely (pitch 50, yaw 20, 1.2 m, f = 1450): on a side seen at a slant, the band between
        // the top edge and the bottom of the cut face is much narrower than the projected vertical edge is long. The
        // width is the distance of each bottom corner from the top edge's image line.
        let s = SyntheticView.make(pitch: 50, distance: 1.2, tilt: 0, heading: 0, yaw: 20)
        let box = SlabBoxView(pose: s.pose, spec: .standard, intrinsics: s.intrinsics)
        let T = box.topOutline!
        var ratios: [Double] = []
        for i in 0..<4 where box.cutFaceVisible(side: i) {
            let j = (i + 1) % 4, dir = (T[j] - T[i]).normalized
            let w = box.cutBandWidth(side: i)
            let bi = s.intrinsics.project(box.bottomCorners[i])!, bj = s.intrinsics.project(box.bottomCorners[j])!
            XCTAssertEqual(w.start, abs(dir.cross(bi - T[i])), accuracy: 1e-9, "side \(i)")
            XCTAssertEqual(w.end, abs(dir.cross(bj - T[j])), accuracy: 1e-9, "side \(i)")
            XCTAssertEqual(box.verticalEdge(corner: i)!.length, bi.distance(to: T[i]), accuracy: 1e-9)
            ratios.append(w.start / box.verticalEdge(corner: i)!.length)
            // never wider than the vertical edge is long
            XCTAssertLessThanOrEqual(w.start, box.verticalEdge(corner: i)!.length + 1e-9)
        }
        XCTAssertEqual(ratios.count, 2)
        // the obliquely seen side: about 0.3 of the vertical edge's length (the old value overstated it about 3x)
        XCTAssertLessThan(ratios.min()!, 0.45)
        // the side seen nearly square-on: close to the vertical edge's length
        XCTAssertGreaterThan(ratios.max()!, 0.9)
    }

    // MARK: the side profile

    /// A profile with no run and no rounding (a face dropping straight down by the thickness) is the old box exactly: the
    /// same bottom corners, visibility, bands, outer outline and cut-bottom outlines; its features are the band on a face
    /// that shows (departing at the top edge) and nothing on a hidden one.
    func testProfileWithNoRunOrRoundingIsTheOldBox() {
        var p = SlabSpec.standard
        p.faceDrop = p.thickness
        XCTAssertTrue(p.hasProfile)
        XCTAssertFalse(SlabSpec.standard.hasProfile)
        for (pitch, yaw, tilt) in [(50.0, 20.0, 0.0), (35, -40, 8), (75, 10, 5), (20, 60, 12), (85, 0, 0)] {
            let s = SyntheticView.make(pitch: pitch, distance: 1.1, tilt: tilt, heading: 40, yaw: yaw)
            let old = SlabBoxView(pose: s.pose, spec: .standard, intrinsics: s.intrinsics)
            let new = SlabBoxView(pose: s.pose, spec: p, intrinsics: s.intrinsics)
            XCTAssertEqual(old.bottomCorners, new.bottomCorners)
            for i in 0..<4 {
                XCTAssertEqual(old.cutFaceVisible(side: i), new.cutFaceVisible(side: i), "pitch \(pitch) side \(i)")
                let a = old.cutBandWidth(side: i), b = new.cutBandWidth(side: i)
                XCTAssertEqual(a.start, b.start); XCTAssertEqual(a.end, b.end)
                let f0 = new.featureOffsets(side: i, at: 0)!, f1 = new.featureOffsets(side: i, at: 1)!
                XCTAssertEqual(f0.departure, 0); XCTAssertEqual(f1.departure, 0)
                XCTAssertEqual(f0.outer, a.start, accuracy: 1e-9, "pitch \(pitch) side \(i)")
                XCTAssertEqual(f1.outer, a.end, accuracy: 1e-9, "pitch \(pitch) side \(i)")
                XCTAssertEqual(old.featureOffsets(side: i, at: 0.5)!.outer, new.featureOffsets(side: i, at: 0.5)!.outer)
            }
            let lo = old.outerOutlineLines!, ln = new.outerOutlineLines!
            for i in 0..<4 { XCTAssertEqual(lo[i].0, ln[i].0); XCTAssertEqual(lo[i].1, ln[i].1) }
            for sides: Set<Int> in [[0], [1, 2], [3, 0]] { XCTAssertEqual(old.outlineWithCutBottom(onSides: sides), new.outlineWithCutBottom(onSides: sides)) }
        }
    }

    /// A level slab whose side `o` is seen at view angle `phi` (degrees from straight outside toward the normal) from
    /// `distance` metres, its middle on the optical axis; the side's index.
    func sideView(phi: Double, distance d: Double, spec: SlabSpec, K: CameraIntrinsics) -> (box: SlabBoxView, side: Int) {
        let f = Units.radians(phi)
        // the camera looks along +z at the side's middle M = (0, 0, d); from M it lies along cos(phi) o + sin(phi) n
        let n = Vec3(0, cos(f), -sin(f)), o = Vec3(0, -sin(f), -cos(f))
        let M = Vec3(0, 0, d), along = o.cross(n).normalized   // (o x n) x o = n: the corners run so the normal is n
        let raw = SlabPose(center: M - o * spec.halfV, normal: n, axisU: along, axisV: o, halfU: spec.halfU, halfV: spec.halfV)
        let pose = SlabPose.fromCorners(raw.topCorners)!
        let box = SlabBoxView(pose: pose, spec: spec, intrinsics: K)
        let side = (0..<4).max { box.outward(side: $0).dot(o) < box.outward(side: $1).dot(o) }!
        return (box, side)
    }

    /// A side seen edge-on (the camera straight above its edge): a vertical cut face does not show, the owner's sloped
    /// one does, as a band of its run seen from above: R f / d, d the depth of the band's bottom. The kit's near-level
    /// shots (slab-kit-20261118 s08-s11) showed 5.0-5.7 px where this gives 5.9.
    func testAnEdgeOnSideShowsItsRun() {
        let K = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        for d in [0.6, 1.0, 1.5] {
            let v = sideView(phi: 90, distance: d, spec: .standard, K: K)
            XCTAssertFalse(v.box.cutFaceVisible(side: v.side))
            XCTAssertEqual(v.box.featureOffsets(side: v.side, at: 0.5)!.outer, 0, accuracy: 1e-9)
            for spec in [TestProfiles.sloped, TestProfiles.rounded(0.002)] {
                let w = sideView(phi: 90, distance: d, spec: spec, K: K)
                XCTAssertTrue(w.box.cutFaceVisible(side: w.side), "\(d) m")
                let f = w.box.featureOffsets(side: w.side, at: 0.5)!
                let expected = spec.sideRun * K.fx / (d + spec.drop)
                XCTAssertEqual(f.outer - f.departure, expected, accuracy: 0.05, "\(d) m, r \(spec.edgeRadius)")
                XCTAssertEqual(w.box.sideProfile(side: w.side)!.bandMiddle, f.outer - f.departure, accuracy: 1e-9)
            }
        }
    }

    /// A side seen at a grazing angle from across the slab: a vertical cut face is hidden from any view angle past 90
    /// deg, the sloped face shows until 180 deg - atan(H / R) (109.2 deg for the owner's 21.5 / 7.5 mm), as a band that
    /// narrows from its edge-on width to nothing there; past that only the rounded edge's tangent point bounds the side.
    func testAGrazingSideShowsItsSlopedFace() {
        let K = CameraIntrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let limit = 180 - Units.degrees(atan2(TestProfiles.sloped.drop, TestProfiles.sloped.sideRun))
        XCTAssertEqual(limit, 109.2, accuracy: 0.05)
        var last = TestProfiles.sloped.sideRun * K.fx / (1.2 + TestProfiles.sloped.drop)
        for phi in [95.0, 100, 105, 108] {
            let v = sideView(phi: phi, distance: 1.2, spec: .standard, K: K), w = sideView(phi: phi, distance: 1.2, spec: TestProfiles.sloped, K: K)
            XCTAssertFalse(v.box.cutFaceVisible(side: v.side), "\(phi)")
            XCTAssertTrue(w.box.cutFaceVisible(side: w.side), "\(phi)")
            XCTAssertEqual(Units.degrees(w.box.viewAngle(side: w.side)), phi, accuracy: 1e-6)
            let band = w.box.sideProfile(side: w.side)!.bandMiddle
            XCTAssertGreaterThan(band, 0, "\(phi)"); XCTAssertLessThan(band, last, "\(phi)")
            last = band
        }
        for phi in [111.0, 130] {
            let w = sideView(phi: phi, distance: 1.2, spec: TestProfiles.sloped, K: K)
            XCTAssertFalse(w.box.cutFaceVisible(side: w.side), "\(phi)")
            // with a rounded edge the outline lies at the rounding's tangent point, r (1 - cos(180 - phi)) out
            let r = TestProfiles.rounded(0.002)
            let x = sideView(phi: phi, distance: 1.2, spec: r, K: K)
            let beta = Units.radians(180 - phi), z = 1.2
            XCTAssertEqual(x.box.featureOffsets(side: x.side, at: 0.5)!.outer, 0.002 * (1 - cos(beta)) * K.fx / z, accuracy: 0.02, "\(phi)")
        }
    }

    /// The profile in a spec round-trips through JSON; a spec without one writes exactly what it wrote before the profile
    /// existed, and an old spec (no profile keys) reads back as the old box.
    func testSlabSpecCodingKeepsOldFiles() throws {
        let old = #"{"sideU":0.1778,"sideV":0.1778,"thickness":0.0254,"dishDepth":0.003175}"#
        let s = try JSONDecoder().decode(SlabSpec.self, from: Data(old.utf8))
        XCTAssertEqual(s, SlabSpec(sideU: 0.1778, sideV: 0.1778, thickness: 0.0254, dishDepth: 0.003175))
        XCTAssertFalse(s.hasProfile)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        XCTAssertEqual(String(data: try enc.encode(s), encoding: .utf8), #"{"dishDepth":0.003175,"sideU":0.1778,"sideV":0.1778,"thickness":0.0254}"#)
        for spec in [SlabSpec.ownerSlab, TestProfiles.rounded(0.003, psiN: 0.7)] {
            XCTAssertEqual(try JSONDecoder().decode(SlabSpec.self, from: try enc.encode(spec)), spec)
        }
        XCTAssertTrue(SlabSpec.ownerSlab.hasProfile)
        XCTAssertEqual(SlabSpec.ownerSlab.thickness, SlabSpec.standard.thickness)
        XCTAssertEqual(SlabSpec.ownerSlab.faceDrop, 0.0215, accuracy: 1e-12)
        XCTAssertEqual(SlabSpec.ownerSlab.sideRun, 0.0075, accuracy: 1e-12)
        XCTAssertEqual(SlabSpec.ownerSlab.edgeRadius, 0.002, accuracy: 1e-12)
    }
}
