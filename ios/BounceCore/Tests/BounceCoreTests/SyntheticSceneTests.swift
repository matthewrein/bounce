import XCTest
@testable import BounceCore

final class SyntheticSceneTests: XCTestCase {
    func testRendersTheSlabWhereItsCornersProject() {
        var demo = DemoScript(); demo.ballHeight = 0.3
        let scene = demo.scene(at: 1), view = demo.view(at: 1)
        let rgb = scene.renderRGB(view: view)
        let K = view.intrinsics
        XCTAssertEqual(rgb.count, K.width * K.height * 3)
        let q = scene.corners(in: view)!
        // inside the outline: the grey top; just outside the near side, below it in the image: the light cut face or the
        // black base; far outside: the floor
        let c = (q[0] + q[1] + q[2] + q[3]) / 4
        func luma(_ p: Vec2) -> Double { let i = (Int(p.y) * K.width + Int(p.x)) * 3; return 0.299 * Double(rgb[i]) + 0.587 * Double(rgb[i + 1]) + 0.114 * Double(rgb[i + 2]) }
        XCTAssertGreaterThan(luma(c), 80)
        // somewhere just below the slab's lowest corner, the black base shows
        let lowest = q.max { $0.y < $1.y }!, side = ShapeCheck.meanSide(q)
        let darkest = (1...30).map { luma(lowest + Vec2(-0.1 * side, Double($0) * 0.01 * side)) }.min()!
        XCTAssertLessThan(darkest, 50, "the dark base shows below the slab")
        if let dir = ProcessInfo.processInfo.environment["SYNTH_DUMP"] {
            var ppm = Data("P6\n\(K.width) \(K.height)\n255\n".utf8); ppm.append(contentsOf: rgb)
            try? ppm.write(to: URL(fileURLWithPath: dir).appendingPathComponent("demo.ppm"))
        }
    }

    func testDemoScriptSlides() {
        var d = DemoScript(); d.slideTo = 3; d.slideAt = 5
        XCTAssertEqual(Units.degrees(d.scene(at: 1).slab.tilt(down: Vec3(0, -1, 0))), 8, accuracy: 1e-9)
        XCTAssertEqual(Units.degrees(d.scene(at: 6).slab.tilt(down: Vec3(0, -1, 0))), 3, accuracy: 1e-9)
    }
}
