import XCTest
@testable import BounceCore

/// A shot that should not show the slab may show it anyway: in both of the owner's first kits the ball lay on the floor
/// a few inches from the slab in the ball shots, and the app locked the real slab. That is not a false slab. A lock
/// anywhere else in the world, on the floor where the slab stands (52 mm under its top), or in another ARKit session (no
/// slab shot to say where the slab is) still is. Geometry only: the synthetic kit's level still shot's pictures stand in
/// for the near ball shot's, its cameras moved through the world where a test needs the lock to land elsewhere (the same
/// pictures from cameras moved by d put the lock d away).
final class KitScorerSlabInViewTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kit-inview-\(UUID().uuidString)")
    }

    override func tearDown() { if let r = root { try? FileManager.default.removeItem(at: r) } }

    /// Scores a tiny kit whose near ball shot (slab forbidden) sees what the level still shot saw, from cameras moved by
    /// `shift` (world, m), at its own times; `session` replaces its ARKit session.
    func score(shift: Vec3, session: String? = nil) throws -> KitScoreReport {
        var o = KitSyntheticKit.Options()
        o.framesPerShot = 10
        o.shots = ["s01-measure", "s03-flat-level", "s04-level-still", "s07-ball-3ft"]
        o.ballWidth = nil; o.ballHeight = nil
        let kit = try KitSyntheticKit.build(root: root.appendingPathComponent(UUID().uuidString), options: o)
        func folder(_ id: String) throws -> URL {
            kit.folder.appendingPathComponent(try XCTUnwrap(kit.store.manifest.record(id)?.folder))
        }
        let still = try folder("s04-level-still"), ball = try folder("s07-ball-3ft")
        let src = try KitJSONL.read(KitFrame.self, from: still.appendingPathComponent(KitClipFiles.frames))
        let own = try KitJSONL.read(KitFrame.self, from: ball.appendingPathComponent(KitClipFiles.frames))
        let dt = try XCTUnwrap(own.first).time - src[0].time
        XCTAssertGreaterThan(dt, 0, "the ball shot runs after the still shot")
        let lines = try src.map { f -> String in
            var g = f
            g.time += dt
            g.pose[12] += Float(shift.x); g.pose[13] += Float(shift.y); g.pose[14] += Float(shift.z)
            return String(decoding: try JSONEncoder().encode(g), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: ball.appendingPathComponent(KitClipFiles.frames), atomically: true, encoding: .utf8)
        if let s = session {
            let u = ball.appendingPathComponent(KitClipFiles.shotManifest)
            var m = try KitJSON.decode(KitShotManifest.self, from: Data(contentsOf: u))
            m.arSessionId = s
            try KitJSON.encode(m).write(to: u)
        }
        var opt = kit.scorerOptions()
        opt.frames = { input in
            guard input.shotId == "s07-ball-3ft" else { return try kit.frames(input) }
            var s = input
            s.shotId = "s04-level-still"
            return try kit.frames(s)
        }
        return try KitScorer(kitFolder: kit.folder, options: opt).score()
    }

    /// One test, so the unmoved case is scored once (each scoring renders a small synthetic kit).
    func testTheRealSlabLeftInViewIsNotAFalseSlabButALockElsewhereIs() throws {
        let r = try score(shift: .zero)
        let s = try XCTUnwrap(r.shot("s07-ball-3ft"))
        XCTAssertNil(s.error)
        XCTAssertGreaterThan(r.shot("s04-level-still")?.metric("lockRate")?.value ?? 0, 0.8, "the still shot locks the slab")
        // every find, confirming (by its detection's ray) or locked (by the lock's centre), is on the real slab
        let inView = try XCTUnwrap(s.metric("slabInViewRate")?.value)
        XCTAssertGreaterThan(inView, 0.7)
        XCTAssertEqual(s.metric("slabFoundRate")?.value, 0)
        XCTAssertEqual(s.metric("slabLockedRate")?.value, 0)
        XCTAssertEqual(r.aggregate("slabFoundRate")?.value, 0)
        XCTAssertEqual(r.aggregate("slabInViewRate")?.value, inView)
        let note = try XCTUnwrap(r.notes.first { $0.hasPrefix("s07-ball-3ft: the slab was in view") }, "\(r.notes)")
        XCTAssertTrue(note.contains("where s04-level-still locked it (the lock "), note)
        XCTAssertTrue(r.markdown().contains("on the real slab, left in view"))
        // the ball finder looks only over the slab's top: its searches over the real slab are not ball misses
        XCTAssertNil(s.metric("ballDetectionRate")?.value)
        XCTAssertFalse(r.notes.contains { $0.hasPrefix("s07-ball-3ft: not checked") })

        // 0.4 m to the side: more than half the slab's side away, off its top
        let side = try XCTUnwrap(try score(shift: Vec3(0.4, 0, 0)).shot("s07-ball-3ft"))
        XCTAssertEqual(side.metric("slabInViewRate")?.value, 0)
        XCTAssertEqual(try XCTUnwrap(side.metric("slabFoundRate")?.value), inView, accuracy: 0.11, "the same pictures, the same finds")
        XCTAssertGreaterThan(try XCTUnwrap(side.metric("slabLockedRate")?.value), 0.5)
        // where the slab stands, but 52 mm lower: a lock on the floor, not on the slab's top. (A detection before the lock
        // is judged by its line of sight, and that crosses the real top: where the slab stands, it is what that pixel shows.)
        let floor = try XCTUnwrap(try score(shift: Vec3(0, -0.052, 0)).shot("s07-ball-3ft"))
        XCTAssertEqual(try XCTUnwrap(floor.metric("slabLockedRate")?.value), try XCTUnwrap(side.metric("slabLockedRate")?.value),
                       accuracy: 0.11, "every lock is false")
        XCTAssertGreaterThan(try XCTUnwrap(floor.metric("slabLockedRate")?.value), 0.5)
        // another ARKit session: no slab shot says where the slab is in that world, and the report says it was not checked
        let o = try score(shift: .zero, session: "a2")
        let other = try XCTUnwrap(o.shot("s07-ball-3ft"))
        XCTAssertEqual(other.metric("slabInViewRate")?.value, 0)
        XCTAssertGreaterThan(try XCTUnwrap(other.metric("slabLockedRate")?.value), 0.5)
        XCTAssertTrue(o.notes.contains { $0.hasPrefix("s07-ball-3ft: not checked for the real slab left in view") }, "\(o.notes)")
    }
}
