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
}
