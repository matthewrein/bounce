import BounceCore
import XCTest

/// End-to-end tests in the iOS Simulator. ARKit and the camera do not exist there, so the app runs its demo: a synthetic
/// slab rendered from a moving virtual camera, fed through the same tracker, detectors, overlay and readouts as the
/// camera. The truth of the demo scene is known exactly (BounceCore's DemoScript), so the tests check what the app
/// shows against it. Each test prints an "E2E-SUMMARY" line that CI copies into its summary.
final class SlabBounceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: helpers

    func launch(_ args: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"] + args.sorted { $0.key < $1.key }.flatMap { ["-" + $0.key, $0.value] }
        app.launch()
        return app
    }

    func label(_ app: XCUIApplication, _ id: String) -> String {
        let e = app.staticTexts[id]
        return e.exists ? e.label : ""
    }

    /// Wait until `ok` holds (checked every 0.2 s); returns the seconds it took, or nil on timeout.
    @discardableResult
    func waitUntil(_ timeout: Double, _ ok: () -> Bool) -> Double? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if ok() { return Date().timeIntervalSince(t0) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    /// "8.3°" -> 8.3; "11.2 in" -> 11.2 (inches); "2 ft 1 in" -> 25 (inches); "0.71 s" -> 0.71
    func number(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: "°", with: " ").split(separator: " ")
        if let ft = parts.firstIndex(of: "ft"), ft > 0, let f = Double(parts[ft - 1]) {
            let inch = parts.count > ft + 1 ? Double(parts[ft + 1]) ?? 0 : 0
            return f * 12 + inch
        }
        return parts.first.flatMap { Double($0) }
    }

    func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The truth the app should show for a demo script at time t (slab in world, no ball unless given).
    func truth(_ d: DemoScript, at t: Double) -> (tilt: Double, apexInches: Double, dropInches: Double?) {
        let scene = d.scene(at: t)
        let down = Vec3(0, -1, 0)
        let r = Bounce.compute(pose: scene.slab, spec: .standard, ball: BallSpec(), down: down, ballCenter: scene.ball,
                               defaultDropHeight: Units.feet(3), floorBelowCenter: scene.slab.center.y)
        return (Units.degrees(scene.slab.tilt(down: down)), Units.toInches(r.path.apexHeight), r.drop.map { Units.toInches($0.dropHeight) })
    }

    func summary(_ s: String) { print("E2E-SUMMARY " + s) }

    // MARK: tests

    /// The demo slab is found and locked, and the tilt, apex and drop readouts match the scene's truth.
    func testLocksAndShowsTheRightTilt() {
        let d = DemoScript()
        let app = launch(["demoTilt": "\(d.tilt)"])
        let lockTime = waitUntil(30) { label(app, "status").contains("Slab locked") }
        screenshot(app, "after launch")
        XCTAssertNotNil(lockTime, "never locked; status: \(label(app, "status"))")
        Thread.sleep(forTimeInterval: 2) // let the lock gather a few re-checks
        screenshot(app, "locked")
        let tr = truth(d, at: 3)
        let tilt = number(label(app, "tilt")), apex = number(label(app, "apex")), drop = number(label(app, "drop"))
        summary(String(format: "lock: locked after %.1f s; tilt %@ (truth %.2f); apex %@ in (truth %.1f); drop %@",
                       lockTime ?? -1, tilt.map { String(format: "%.2f", $0) } ?? "-", tr.tilt, apex.map { String(format: "%.1f", $0) } ?? "-",
                       tr.apexInches, label(app, "drop")))
        XCTAssertEqual(tilt ?? -99, tr.tilt, accuracy: 1.0, "tilt readout \(label(app, "tilt"))")
        XCTAssertEqual(apex ?? -99, tr.apexInches, accuracy: max(1.5, tr.apexInches * 0.06), "apex readout \(label(app, "apex"))")
        XCTAssertEqual(drop ?? -99, 36, accuracy: 0.6, "with no ball the drop is the 3 ft setting: \(label(app, "drop"))")
    }

    /// A ball held over the slab sets the drop height.
    func testBallSetsTheDropHeight() {
        var d = DemoScript(); d.ballHeight = 0.30
        let app = launch(["demoBall": "0.30"])
        let t = waitUntil(40) { label(app, "status").contains("ball in view") && label(app, "drop").contains("(ball)") }
        screenshot(app, "ball")
        let tr = truth(d, at: 3)
        let drop = number(label(app, "drop"))
        summary(String(format: "ball: seen after %.1f s; drop %@ (truth %.1f in)", t ?? -1, label(app, "drop"), tr.dropInches ?? -1))
        XCTAssertNotNil(t, "the ball never set the drop; status \(label(app, "status")), drop \(label(app, "drop"))")
        XCTAssertEqual(drop ?? -99, tr.dropInches ?? 0, accuracy: 1.5)
    }

    /// Sliding the slab to a new angle: the app re-locks and shows the new tilt.
    func testSlidingTheSlabRelocks() {
        var d = DemoScript(); d.slideTo = 3; d.slideAt = 8
        let app = launch(["demoTilt": "\(d.tilt)", "demoSlideTo": "3", "demoSlideAt": "8"])
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        let before = number(label(app, "tilt"))
        let t = waitUntil(40) { (number(label(app, "tilt")).map { abs($0 - 3) < 1.0 } ?? false) }
        screenshot(app, "after slide")
        summary(String(format: "slide: tilt %@ before, %@ after (truth 8 -> 3), new tilt shown %.1f s after the lock check started",
                       before.map { String(format: "%.2f", $0) } ?? "-", label(app, "tilt"), t ?? -1))
        XCTAssertNotNil(t, "never showed the new tilt; tilt \(label(app, "tilt")), status \(label(app, "status"))")
    }

    /// Diagnostics: the sheet shows valid JSON with the build, the lock and the counters.
    func testDiagnostics() throws {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        Thread.sleep(forTimeInterval: 2)
        app.buttons["diagnostics"].tap()
        let text = app.staticTexts["diagnosticsText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        screenshot(app, "diagnostics")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.label.utf8)) as? [String: Any], "not JSON: \(text.label.prefix(200))")
        let counts = json["counts"] as? [String: Int] ?? [:]
        summary("diagnostics: build \(json["build"] ?? "?"), state \(json["state"] ?? "?"), tracking \(json["tracking"] ?? "?"), "
                + "fps \(json["fps"] ?? "?"), ms per frame \(json["msProcess"] ?? "?"), tilt \(json["tiltDegrees"] ?? "?"), "
                + "counts \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        XCTAssertEqual(json["state"] as? String, "locked")
        XCTAssertNotNil(json["build"] as? String)
        XCTAssertGreaterThan(counts["locks"] ?? 0, 0)
        app.buttons["diagnosticsDone"].tap()
    }

    /// Settings: the build label shows, and changing the slab's size makes the app search again and re-lock.
    func testSettingsChangeRelocks() {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts["buildLabel"].waitForExistence(timeout: 10))
        screenshot(app, "settings")
        let stepper = app.steppers["sideStepper"]
        if stepper.exists { stepper.buttons.element(boundBy: 1).tap() }   // 7.00 -> 7.05 in
        app.buttons["settingsDone"].tap()
        // a different size: searching again, then locked again
        let relock = waitUntil(30) { label(app, "status").contains("Slab locked") }
        summary(String(format: "settings: relocked %.1f s after changing the side; status %@", relock ?? -1, label(app, "status")))
        XCTAssertNotNil(relock)
        // put it back for the other tests
        app.buttons["settings"].tap()
        if app.steppers["sideStepper"].waitForExistence(timeout: 5) { app.steppers["sideStepper"].buttons.element(boundBy: 0).tap() }
        app.buttons["settingsDone"].tap()
    }

    /// Recording: frames are written while recording, and stopping offers the zip for sharing.
    func testRecordingProducesAShareableFile() throws {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        app.buttons["record"].tap()
        Thread.sleep(forTimeInterval: 4)
        app.buttons["diagnostics"].tap()
        let text = app.staticTexts["diagnosticsText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.label.utf8)) as? [String: Any])
        let frames = (json["counts"] as? [String: Int])?["recordedFrames"] ?? 0
        app.buttons["diagnosticsDone"].tap()
        app.buttons["record"].tap() // stop
        let shared = waitUntil(20) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Close"].exists }
        screenshot(app, "share sheet")
        summary(String(format: "recording: %d frames in 4 s; share sheet after %.1f s", frames, shared ?? -1))
        XCTAssertGreaterThan(frames, 5)
        XCTAssertNotNil(shared, "no share sheet after stopping the recording")
    }
}
