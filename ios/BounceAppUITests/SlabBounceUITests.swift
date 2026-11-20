import BounceCore
import UIKit
import XCTest

/// End-to-end tests in the iOS Simulator. ARKit and the camera do not exist there, so the app runs its demo: a synthetic
/// slab rendered from a moving virtual camera, fed through the same tracker, detectors, overlay and readouts as the
/// camera. The truth of the demo scene is known exactly (BounceCore's DemoScript), so the tests check what the app
/// shows against it. Each test prints an "E2E-SUMMARY" line that CI copies into its summary.
///
/// The main screen is point and go: the status chip, the readouts and a gear ("settings"). Settings holds the drop
/// height and the ball's restitution; the developer tools (capture kit, diagnostics, recording, reset, demo, build) are under
/// Settings > Developer ("developerRow").
final class SlabBounceUITests: XCTestCase {
    /// an app whose stored settings a test changed: tearDown puts them back (even after a failure)
    private var appToRestore: XCUIApplication? = nil

    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        if let app = appToRestore {
            appToRestore = nil
            app.terminate()
            app.launch()
            if element(app, "settings").waitForExistence(timeout: 20) {
                element(app, "settings").tap()
                if element(app, "restoreDefaults").waitForExistence(timeout: 10) { element(app, "restoreDefaults").tap() }
                if element(app, "settingsDone").exists { element(app, "settingsDone").tap() }
            }
        }
        super.tearDown()
    }

    // MARK: helpers

    func launch(_ args: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "YES"] + args.sorted { $0.key < $1.key }.flatMap { ["-" + $0.key, $0.value] }
        app.launch()
        return app
    }

    /// The element with this accessibility id, whatever its type.
    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func label(_ app: XCUIApplication, _ id: String) -> String {
        let e = app.staticTexts[id]
        return e.exists ? e.label : ""
    }

    /// Wait for the element and tap it.
    func tap(_ app: XCUIApplication, _ id: String, timeout: Double = 10) {
        let e = element(app, id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "no \(id) on screen")
        e.tap()
    }

    /// Wait until the element has gone (e.g. a sheet finished closing).
    @discardableResult
    func waitGone(_ app: XCUIApplication, _ id: String, timeout: Double = 10) -> Bool {
        waitUntil(timeout) { !self.element(app, id).exists } != nil
    }

    /// Main screen -> Settings -> Developer.
    func openDeveloper(_ app: XCUIApplication) {
        tap(app, "settings")
        tap(app, "developerRow")
        XCTAssertTrue(element(app, "developerDone").waitForExistence(timeout: 10), "the Developer screen did not open")
    }

    /// Developer (or Settings) -> the main screen.
    func closeSettings(_ app: XCUIApplication) {
        if element(app, "developerDone").exists { element(app, "developerDone").tap() } else { tap(app, "settingsDone") }
        waitGone(app, "developerDone")
        waitGone(app, "settingsDone")
    }

    /// Settings > Developer > Copy diagnostics: the JSON the sheet shows (the sheet is closed again, Developer stays open).
    func readDiagnostics(_ app: XCUIApplication, screenshotName: String? = nil) throws -> [String: Any] {
        tap(app, "diagnostics")
        let text = app.staticTexts["diagnosticsText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        if let n = screenshotName { screenshot(app, n) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.label.utf8)) as? [String: Any], "not JSON: \(text.label.prefix(200))")
        tap(app, "diagnosticsDone")
        waitGone(app, "diagnosticsText")
        return json
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

    /// The first number in a readout: "8.3°" -> 8.3; "Drop 11.2 in (ball)" -> 11.2 (inches); "2 ft 1 in" -> 25 (inches);
    /// "Restitution: 0.50" -> 0.5
    func number(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: "°", with: " ").replacingOccurrences(of: "%", with: " ").split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(where: { Double($0) != nil }), let v = Double(parts[i]) else { return nil }
        if i + 1 < parts.count, parts[i + 1] == "ft" {
            let inch = i + 2 < parts.count ? Double(parts[i + 2]) ?? 0 : 0
            return v * 12 + inch
        }
        return v
    }

    /// Scroll the Developer screen until the element is well on screen (its last rows start below the fold, and a list
    /// makes its rows only when they come into view). "Well on screen" is hittable and clear of the window's edges: a row
    /// cut by the bottom edge counts as hittable, but a tap there, in the home indicator's strip, can be lost (n12's
    /// Developer list, one switch shorter, left the Pre-flight row there).
    @discardableResult
    func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let e = element(app, id)
        for i in 0..<10 {
            if e.exists && e.isHittable && clearOfEdges(app, e) { break }
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            let target = list.exists ? list : app
            if i < 6 { target.swipeUp() } else { target.swipeDown() }
            // let the list stop: a tap while it still coasts only stops the scroll (the row's link does not open)
            Thread.sleep(forTimeInterval: 0.8)
        }
        return e
    }

    /// The element lies inside the window with room to spare: below the top bars and above the bottom strip.
    func clearOfEdges(_ app: XCUIApplication, _ e: XCUIElement) -> Bool {
        let w = app.windows.firstMatch.frame, f = e.frame
        return !f.isEmpty && f.minY > w.minY + 100 && f.maxY < w.maxY - 60
    }

    /// Settings > Developer > Copy log: the text its sheet shows (the sheet is closed again, Developer stays open).
    func readLog(_ app: XCUIApplication, screenshotName: String? = nil) -> String {
        reveal(app, "copyLog")
        tap(app, "copyLog")
        let text = app.staticTexts["logText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "no log sheet")
        if let n = screenshotName { screenshot(app, n) }
        let log = text.label
        tap(app, "logDone")
        waitGone(app, "logText")
        return log
    }

    /// Developer -> Pre-flight, until the pre-flight screen's Run shows and stays. The row is a navigation link near the
    /// foot of the Developer list, below the live line, which redraws several times a second (until n12 the whole list
    /// did, and the rows below the line moved when it rewrapped). Up to three tries: let the
    /// push that opened Developer finish, reveal the row (well on screen, see reveal), tap it and wait; before the third
    /// try Developer is left and opened again, in case the link is stuck. Each try prints what is on screen
    /// ("E2E-DEBUG" lines, which CI copies into its log), and a miss prints the whole screen.
    func openPreflight(_ app: XCUIApplication) -> Bool {
        let run = element(app, "preflightRun")
        for attempt in 1...3 {
            if attempt == 3, element(app, "developerDone").exists {
                // back to Settings (the back button carries the previous screen's title) and into Developer again
                let bar = app.navigationBars["Developer"]
                let back = bar.buttons["Settings"].exists ? bar.buttons["Settings"] : bar.buttons.element(boundBy: 0)
                if back.exists { back.tap() }
                if element(app, "developerRow").waitForExistence(timeout: 5) { element(app, "developerRow").tap() }
                _ = element(app, "developerDone").waitForExistence(timeout: 10)
            }
            // a tap while Developer is still sliding in can be lost
            Thread.sleep(forTimeInterval: 1.0)
            let row = reveal(app, "preflightRow")
            print("E2E-DEBUG pre-flight try \(attempt), before the tap: \(describe(app))")
            if row.exists && row.isHittable { row.tap() }
            if run.waitForExistence(timeout: 8) {
                // and it stays (a push that springs back would leave the rest of the test on the wrong screen)
                Thread.sleep(forTimeInterval: 1.0)
                if run.exists { return true }
            }
            dumpScreen(app, "pre-flight try \(attempt) missed")
            // a sheet that opened instead is closed; anywhere but Developer, stop (the dump says where it went)
            if element(app, "logDone").exists { element(app, "logDone").tap(); waitGone(app, "logText") }
            if element(app, "diagnosticsDone").exists { element(app, "diagnosticsDone").tap(); waitGone(app, "diagnosticsText") }
            if !element(app, "developerDone").exists { return run.exists }
        }
        return false
    }

    /// One line on what is on screen, for a failure message: the app's state (4 = running in the foreground), the
    /// navigation bars, the window and where the Developer and pre-flight screens' key elements are.
    func describe(_ app: XCUIApplication) -> String {
        let bars = app.navigationBars.allElementsBoundByIndex.map { $0.identifier.isEmpty ? "?" : $0.identifier }
        func at(_ id: String) -> String {
            let e = element(app, id)
            guard e.exists else { return "\(id) none" }
            let f = e.frame
            return "\(id) \(e.isHittable ? "hittable" : "NOT hittable") at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
        }
        let w = app.windows.firstMatch.frame
        return "app state \(app.state.rawValue); bars \(bars); window \(Int(w.width))x\(Int(w.height)); "
            + ["developerDone", "preflightRow", "copyLog", "preflightRun", "logText", "diagnosticsText"].map(at).joined(separator: "; ")
    }

    /// The whole screen into the test log ("E2E-DEBUG" lines, which CI prints; at most 150 lines) and a screenshot.
    func dumpScreen(_ app: XCUIApplication, _ why: String) {
        print("E2E-DEBUG \(why): \(describe(app))")
        let lines = app.debugDescription.split(separator: "\n", omittingEmptySubsequences: true)
        for l in lines.prefix(150) { print("E2E-DEBUG   \(l)") }
        if lines.count > 150 { print("E2E-DEBUG   (\(lines.count - 150) more lines)") }
        screenshot(app, why)
    }

    func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The truth the app should show for a demo script at time t (slab in world, no ball unless given), for a restitution:
    /// the app's bounce (the impact rule off the dish, with the owner's ball's tangential share).
    func truth(_ d: DemoScript, at t: Double, restitution: Double = BallSpec.ownerRestitution) -> (tilt: Double, apexInches: Double, dropInches: Double?) {
        // the app's demo renders the app's slab and ball (BounceCore's owner slab and ball: ARController.demoTick)
        let scene = d.scene(at: t, spec: .ownerSlab, ball: .ownerBall)
        let down = Vec3(0, -1, 0)
        let ball = BallSpec(diameter: BallSpec.ownerBall.diameter, restitution: restitution, tangential: BallSpec.ownerTangential)
        let r = Bounce.compute(pose: scene.slab, spec: .ownerSlab, ball: ball, down: down, ballCenter: scene.ball,
                               defaultDropHeight: Units.feet(3), rule: .impact, floorBelowCenter: scene.slab.center.y)
        return (Units.degrees(scene.slab.tilt(down: down)), Units.toInches(r.path.apexHeight), r.drop.map { Units.toInches($0.dropHeight) })
    }

    func summary(_ s: String) { print("E2E-SUMMARY " + s) }

    // MARK: tests

    /// The demo slab is found and locked, and the tilt, apex and drop readouts match the scene's truth. The main screen
    /// is point and go: no record, diagnostics or reset buttons, only the gear.
    func testLocksAndShowsTheRightTilt() {
        let d = DemoScript()
        let app = launch(["demoTilt": "\(d.tilt)"])
        let lockTime = waitUntil(30) { label(app, "status").contains("Slab locked") }
        screenshot(app, "after launch")
        XCTAssertNotNil(lockTime, "never locked; status: \(label(app, "status"))")
        // the tilt shows once it has settled (n11: "settling" until then; from the demo's 48 deg view it settles once two
        // re-checks after the lock agree, about 0.6 s after it). n18: a deviation over 1 deg follows the number ("3.2° ±1.4");
        // number() reads the number before it
        let shownAfter = waitUntil(30) { number(label(app, "tilt")) != nil }
        XCTAssertNotNil(shownAfter, "the tilt never settled: \(label(app, "tilt")), status \(label(app, "status"))")
        screenshot(app, "locked")
        let tr = truth(d, at: 3)
        let tilt = number(label(app, "tilt")), apex = number(label(app, "apex")), drop = number(label(app, "drop"))
        let developerOnMain = ["record", "recordToggle", "diagnostics", "reset", "demoToggle"].filter { element(app, $0).exists }
        summary(String(format: "lock: locked after %.1f s; tilt %@ (truth %.2f); apex %@ in (truth %.1f); drop %@; main screen: gear %@, developer controls %@",
                       lockTime ?? -1, tilt.map { String(format: "%.2f", $0) } ?? "-", tr.tilt, apex.map { String(format: "%.1f", $0) } ?? "-",
                       tr.apexInches, label(app, "drop"), element(app, "settings").exists ? "yes" : "no",
                       developerOnMain.isEmpty ? "none" : developerOnMain.joined(separator: ",")))
        XCTAssertEqual(tilt ?? -99, tr.tilt, accuracy: 1.0, "tilt readout \(label(app, "tilt"))")
        XCTAssertEqual(apex ?? -99, tr.apexInches, accuracy: max(1.5, tr.apexInches * 0.06), "apex readout \(label(app, "apex"))")
        XCTAssertEqual(drop ?? -99, 36, accuracy: 0.6, "with no ball the drop is the 3 ft setting: \(label(app, "drop"))")
        XCTAssertTrue(element(app, "settings").exists, "no gear on the main screen")
        XCTAssertTrue(developerOnMain.isEmpty, "developer controls on the main screen: \(developerOnMain)")
    }

    /// n11: held steeply over the slab (72 deg elevation), the app locks but the tilt reads "settling" (Tilt and Lands; the
    /// status says so): from there one view cannot pin the tilt to a degree. Lowered to 48 deg, the number shows, matching
    /// the scene's truth, with the landing.
    /// n18 (the owner: a number within about 2 s, never "settling" with no hint): the tilt now shows from 2 deg of honest
    /// deviation with the deviation after it while over 1 deg, and the shown value holds until a re-check brings a smaller
    /// deviation. So the steep view (one view's deviation 1.7-4 deg, DemoSettleTests) reads "settling" at first and then,
    /// once two re-checks are at or under 2 deg, the number with its ± ("3.2° ±1.8"); lowered to 48 deg, the better
    /// estimate replaces it and, under 1 deg, the number reads alone, matching the scene's truth, with the landing.
    func testSettlingThenTheTilt() {
        // the steep view lasts 15 s of the demo's own (wall-clock) time: a slow Debug Simulator locks well inside it
        var d = DemoScript(); d.elevation = 72; d.elevationTo = 48; d.elevationAt = 15
        let launched = Date()
        let app = launch(["demoTilt": "\(d.tilt)", "demoElevation": "72", "demoElevationTo": "48", "demoElevationAt": "15"])
        // the lock first, while the view is steep (the time since before the launch bounds the demo's time from above)
        let lockedAt = waitUntil(30) { label(app, "status").contains("Slab locked") }
        let lockedDemoTime = Date().timeIntervalSince(launched)
        XCTAssertNotNil(lockedAt, "never locked; status: \(label(app, "status"))")
        XCTAssertLessThan(lockedDemoTime, d.elevationAt, "the lock came only after the demo lowered the camera (at \(d.elevationAt) s)")
        // seen while the view is steep, with the lock: "settling" in the readouts and the status, or (n18) the number with
        // its ± (the steep view's deviation is over 1 deg)
        var statusSettling = "", tiltSettling = "", landsSettling = ""
        let settlingAt = waitUntil(30) {
            let s = label(app, "status"), tilt = label(app, "tilt")
            if s.contains("Slab locked") && (s.contains("settling") || tilt == "settling" || (number(tilt) != nil && tilt.contains("±"))) {
                statusSettling = s; tiltSettling = tilt; landsSettling = label(app, "lands"); return true
            }
            return false
        }
        screenshot(app, "settling")
        XCTAssertNotNil(settlingAt, "never saw \"settling\" or the tilt with its ± with the lock; status \(label(app, "status")), tilt \(label(app, "tilt"))")
        // lowered: the number alone (its deviation at most 1 deg)
        let shownAt = waitUntil(40) { let t = label(app, "tilt"); return number(t) != nil && !t.contains("±") }
        screenshot(app, "settled")
        let tilt = number(label(app, "tilt")), lands = label(app, "lands"), status = label(app, "status")
        let tr = truth(d, at: 20)
        summary(String(format: "settling: \"settling\" seen %.1f s after the lock (status \"%@\", tilt \"%@\", lands \"%@\"), tilt shown %.1f s after that: %@ (truth %.2f), lands %@, status \"%@\"",
                       settlingAt ?? -1, statusSettling, tiltSettling, landsSettling, shownAt ?? -1, tilt.map { String(format: "%.2f", $0) } ?? "-",
                       tr.tilt, lands, status))
        if tiltSettling == "settling" {
            XCTAssertNil(number(landsSettling), "no landing while settling: \(landsSettling)")
        } else {
            XCTAssertTrue(tiltSettling.contains("±"), "while steep the tilt reads settling or shows its ±: \(tiltSettling)")
        }
        XCTAssertNotNil(shownAt, "the tilt never showed without its ± once lowered: \(label(app, "tilt")), status \(status)")
        XCTAssertEqual(tilt ?? -99, tr.tilt, accuracy: 1.0, "tilt readout \(label(app, "tilt"))")
        XCTAssertNotNil(number(lands), "the landing shows with the tilt: \(lands)")
        XCTAssertFalse(status.contains("settling"), "status still says settling: \(status)")
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

    /// Diagnostics (Settings > Developer > Copy diagnostics): the sheet shows valid JSON with the build, the lock, the
    /// counters and the frame numbers (framePacing: the demo's frames are counted like the camera's); the Developer screen
    /// shows the same build and the frame line.
    func testDiagnostics() throws {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        Thread.sleep(forTimeInterval: 2)
        openDeveloper(app)
        XCTAssertTrue(app.staticTexts["buildLabel"].waitForExistence(timeout: 10))
        let buildLabel = label(app, "buildLabel")
        screenshot(app, "developer")
        let developerLine = label(app, "developerLine")
        let json = try readDiagnostics(app, screenshotName: "diagnostics")
        let counts = json["counts"] as? [String: Int] ?? [:]
        // the frame numbers: delivered, processed, skipped as late, gaps, latencies and processing times (ms, p50/p95)
        let pacing = json["framePacing"] as? [String: Any]
        let total = pacing?["total"] as? [String: Any] ?? [:], recent = pacing?["recent"] as? [String: Any] ?? [:]
        func int(_ w: [String: Any], _ k: String) -> Int { (w[k] as? NSNumber)?.intValue ?? -1 }
        func num(_ w: [String: Any], _ k: String) -> Double { (w[k] as? NSNumber)?.doubleValue ?? -1 }
        func ms(_ w: [String: Any], _ k: String) -> String {
            guard let m = w[k] as? [String: Any] else { return "-" }
            return String(format: "%.1f/%.1f", (m["p50"] as? NSNumber)?.doubleValue ?? -1, (m["p95"] as? NSNumber)?.doubleValue ?? -1)
        }
        let kinds = total["processingByKind"] as? [String: Any] ?? [:]
        let frames = String(format: "frames: total %d received, %d processed, %d skipped late, %d late but idle, %d gaps (%d missed), %d pauses, "
                            + "process %@ ms (p50/p95; search %@, plain %@); recent %.1f s: %.1f processed/s, detector %.1f searches/s %.1f re-checks/s",
                            int(total, "framesReceived"), int(total, "framesProcessed"), int(total, "framesSkippedLate"), int(total, "framesLateButIdle"),
                            int(total, "cameraGaps"), int(total, "framesMissedByCamera"), int(total, "pauses"), ms(total, "processingMs"),
                            ms(kinds, "search"), ms(kinds, "plain"), num(recent, "seconds"), num(recent, "processedPerSecond"),
                            num(recent, "searchesPerSecond"), num(recent, "rechecksPerSecond"))
        let lineFrames: String = developerLine.split(separator: "\n").first(where: { $0.hasPrefix("frames:") }).map { String($0) } ?? "(no frame line read)"
        let slabCrop = json["slabCrop"] != nil ? "yes" : "no"
        summary("diagnostics: build \(json["build"] ?? "?") (Developer shows \"\(buildLabel)\"), state \(json["state"] ?? "?"), "
                + "tracking \(json["tracking"] ?? "?"), fps \(json["fps"] ?? "?"), ms per frame \(json["msProcess"] ?? "?"), "
                + "tilt \(json["tiltDegrees"] ?? "?"), thermal \(json["thermalState"] ?? "?"), "
                + "counts \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        summary("diagnostics frames: " + frames + "; slab crop \(slabCrop); Developer line: " + lineFrames)
        XCTAssertEqual(json["state"] as? String, "locked")
        let build = try XCTUnwrap(json["build"] as? String)
        XCTAssertTrue(buildLabel.contains(build), "the Developer screen shows build \"\(buildLabel)\", diagnostics \(build)")
        XCTAssertGreaterThan(counts["locks"] ?? 0, 0)
        // the frame numbers are there and the demo's frames were processed (no rates asserted: the Simulator is slow and
        // shared)
        XCTAssertNotNil(pacing, "no framePacing in the diagnostics")
        XCTAssertGreaterThan(int(total, "framesProcessed"), 0)
        XCTAssertGreaterThanOrEqual(int(total, "framesReceived"), int(total, "framesProcessed"))
        XCTAssertGreaterThanOrEqual(int(total, "framesSkippedLate"), 0)
        XCTAssertEqual(int(total, "cameraGaps"), 0, "the demo's timer ticks are not camera gaps")
        XCTAssertNotNil(total["processingMs"] as? [String: Any], "no processing times")
        XCTAssertGreaterThan(int(recent, "framesProcessed"), 0)
        // the slab's edges were read from a full-resolution crop (in the demo: of its own image)
        XCTAssertGreaterThan((counts["slabCrops"] ?? 0), 0, "the tracker never got a slab crop")
        // (the Developer line is checked only when the list showed it: a row scrolled out of view may not be readable)
        if !developerLine.isEmpty { XCTAssertTrue(developerLine.contains("frames:"), "the Developer line has no frame numbers: \(developerLine)") }
        closeSettings(app)
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
    }

    /// Settings and Settings > Developer stand still while the frames come (until n12 the main screen observed the
    /// per-frame state, so both redrew with every frame: about 8 times a second in the demo, some 24 times in 3 s), and
    /// the Developer list's rows below the live line stay put while that line changes and rewraps. Settings' redraw
    /// count is its Developer row's accessibility value, shown only to a test that launches with -countRedraws YES;
    /// Developer shows its own ("developerRedraws"). The rows below the live line stay put because the line keeps its
    /// height whatever it says, and that is checked directly, whether or not the line happens to rewrap while it is
    /// watched: its height is the same at every read, through a tracking reset (the demo goes back to searching and
    /// locks again, so the line loses its tilt line and gets it back) and the numbers' changes, and it is room for 14
    /// lines or more of its font (16 kept at the default text size, about 11 used in the demo). The Pre-flight row's top
    /// is also read for 3 s once the list has stopped, and must not move.
    func testSettingsAndDeveloperStayStill() {
        let app = launch(["countRedraws": "YES"])
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") }, "the demo never locked")
        let watch = 3.0

        // Settings, once its sheet has finished opening: its count now and after 3 s
        tap(app, "settings")
        XCTAssertTrue(element(app, "developerRow").waitForExistence(timeout: 10), "Settings did not open")
        Thread.sleep(forTimeInterval: 1.5)
        // (every element carrying the row's id is asked: the count is on whichever holds its accessibility value)
        var settingsValues = ""
        func settingsRedraws() -> Int? {
            let rows = app.descendants(matching: .any).matching(identifier: "developerRow").allElementsBoundByIndex
            settingsValues = rows.map { e in "type \(e.elementType.rawValue) value \(String(describing: e.value))" }.joined(separator: ", ")
            for e in rows {
                if let v = e.value as? String, let n = Int(v) { return n }
            }
            return nil
        }
        let settings0 = settingsRedraws()
        Thread.sleep(forTimeInterval: watch)
        let settings1 = settingsRedraws()
        let settingsSeen = settingsValues
        screenshot(app, "settings")

        // Developer: the same
        tap(app, "developerRow")
        XCTAssertTrue(element(app, "developerDone").waitForExistence(timeout: 10), "the Developer screen did not open")
        Thread.sleep(forTimeInterval: 1.5)
        func developerRedraws() -> Int? { Int(label(app, "developerRedraws")) }
        let developer0 = developerRedraws()
        Thread.sleep(forTimeInterval: watch)
        let developer1 = developerRedraws()
        screenshot(app, "developer")

        // The live line keeps its height whatever it says. Reset tracking (at the top of Developer) sends the demo back
        // to searching: the line loses its tilt line (and may show the tracker's hint) and gets it back when the demo
        // locks again, soon after. Its height and text are read through that change for 2 s, as long as the line is on
        // screen at the top of the list (on a tall phone it is), and again below.
        let liveLine = element(app, "developerLine")
        var heights: [Double] = [], lines: [String] = []
        func readLiveLine() {
            if liveLine.exists { heights.append(Double(liveLine.frame.height)); lines.append(liveLine.label) }
        }
        tap(app, "reset")
        let resetAt = Date()
        while Date().timeIntervalSince(resetAt) < 2 { readLiveLine(); Thread.sleep(forTimeInterval: 0.2) }
        let readsAtTop = lines.count

        // the rows below the live line: the Pre-flight row (scrolled well into view first), once the list has stopped
        // (two tops about 0.3 s apart agree; a slow Simulator can still be coasting when reveal returns), its top read
        // for 3 s and at least 3 times (at most 10 s) while the live line changes, with the line's height and text
        let row = reveal(app, "preflightRow")
        var lastTop: Double? = nil
        let settledAfter = waitUntil(5) {
            Thread.sleep(forTimeInterval: 0.1)
            let top: Double? = row.exists ? Double(row.frame.minY) : nil
            defer { lastTop = top }
            guard let t = top, let last = lastTop else { return false }
            return abs(t - last) < 0.5
        }
        var tops: [Double] = []
        let started = Date()
        while Date().timeIntervalSince(started) < 10 && (Date().timeIntervalSince(started) < watch || tops.count < 3) {
            if row.exists { tops.append(Double(row.frame.minY)) }
            readLiveLine()
            Thread.sleep(forTimeInterval: 0.2)
        }
        let developer2 = developerRedraws()
        screenshot(app, "developer scrolled")
        let topMin: Double = tops.min() ?? -1, topMax: Double = tops.max() ?? -1
        let spread: Double = tops.isEmpty ? 0 : topMax - topMin
        let heightMin: Double = heights.min() ?? -1, heightMax: Double = heights.max() ?? -1
        let lineChanges = zip(lines, lines.dropFirst()).filter { $0.0 != $0.1 }.count
        let framesShown = lines.contains { $0.contains("frames:") } ? "shown" : "not shown"
        // the line's parts (state, tracking, tilt, frames, hint...), one a text line, each wrapping to one or more
        let parts: [Int] = lines.map { $0.split(separator: "\n").count }
        let partsMin: Int = parts.min() ?? 0, partsMax: Int = parts.max() ?? 0
        let notLocked: Int = lines.filter { !$0.hasPrefix("state locked") }.count
        let settledWords: String = settledAfter.map { String(format: "after %.1f s", $0) } ?? "never"
        // one line of the live line's font (caption, monospaced) at the text size in use: the line keeps 16 of them at
        // the default size (more at larger sizes); its text needs about 11 in the demo
        let captionSize: CGFloat = UIFont.preferredFont(forTextStyle: .caption1).pointSize
        let captionLine = Double(UIFont.monospacedSystemFont(ofSize: captionSize, weight: .regular).lineHeight)
        let linesMin: Double = heightMin / captionLine, linesMax: Double = heightMax / captionLine

        func text(_ n: Int?) -> String { n.map { String($0) } ?? "-" }
        func change(_ a: Int?, _ b: Int?) -> String {
            guard let a = a, let b = b else { return "?" }
            return String(b - a)
        }
        let redrawWords = "Settings redrew \(change(settings0, settings1)) times (count \(text(settings0)) -> \(text(settings1))), "
            + "Developer \(change(developer0, developer1)) times (\(text(developer0)) -> \(text(developer1)); "
            + "\(text(developer2)) after a reset, the scroll and \(Int(watch)) s more)"
        summary(String(format: "stillness: in %.0f s %@; Pre-flight row's top %.1f to %.1f pt over %d reads (spread %.1f pt; "
                       + "the list stopped %@) while the live line changed %d times in %d reads (%d at the top after a reset, "
                       + "%d not locked; %d to %d parts; frame numbers %@), its height %.1f to %.1f pt (%.1f to %.1f lines of %.1f pt)",
                       watch, redrawWords, topMin, topMax, tops.count, spread,
                       settledWords, lineChanges, lines.count, readsAtTop, notLocked, partsMin, partsMax, framesShown,
                       heightMin, heightMax, linesMin, linesMax, captionLine))
        guard let s0 = settings0, let s1 = settings1 else {
            XCTFail("Settings' redraw count was not readable (developerRow: \(settingsSeen))")
            return
        }
        XCTAssertLessThanOrEqual(s1 - s0, 2, "Settings redrew \(s1 - s0) times in \(watch) s with nothing touched")
        guard let d0 = developer0, let d1 = developer1 else {
            XCTFail("Developer's redraw count was not readable: \"\(label(app, "developerRedraws"))\"")
            return
        }
        XCTAssertLessThanOrEqual(d1 - d0, 2, "Developer redrew \(d1 - d0) times in \(watch) s with nothing touched")
        // at least 2 reads of the row's top: on a slow shared Simulator a pass of queries can take 4-5 s, and n17's run
        // got 2 in its 10 s (spread 0.0 pt, 0 redraws); the line's height check below is the deterministic part
        XCTAssertGreaterThanOrEqual(tops.count, 2, "the Pre-flight row was not on screen: \(describe(app))")
        XCTAssertLessThanOrEqual(spread, 1.0, "the Pre-flight row moved \(spread) pt while the live line changed (tops \(tops))")
        // the line's height does not follow its text: the same at every read (through the reset and the numbers'
        // changes), and room for more lines than the demo's text needs (16 kept, about 11 used; 14 asked here, so a
        // small difference between this font's line and the app's is no failure)
        XCTAssertGreaterThanOrEqual(heights.count, 2, "the live line was not read: \(describe(app))")
        XCTAssertLessThanOrEqual(heightMax - heightMin, 1.0, "the live line's height changed with its text (heights \(heights))")
        XCTAssertGreaterThanOrEqual(heightMin, 14 * captionLine,
                                    "the live line keeps no room to rewrap: \(heightMin) pt, \(linesMin) lines of \(captionLine) pt")
        closeSettings(app)
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
    }

    /// Settings: changing the restitution from 0.90 (the default since n13) to about 0.50 changes the apex as the app's
    /// bounce says (about (0.5/0.9)², a little less on the tilted demo slab, where part of the ball's speed runs along it);
    /// Restore defaults puts it back.
    func testRestitutionChangesTheApex() {
        let d = DemoScript()
        let app = launch(["demoTilt": "\(d.tilt)"])
        appToRestore = app
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        Thread.sleep(forTimeInterval: 2)
        let before = number(label(app, "apex"))
        tap(app, "settings")
        XCTAssertTrue(element(app, "restitutionValue").waitForExistence(timeout: 10))
        let start = number(label(app, "restitutionValue"))
        XCTAssertEqual(start ?? -1, 0.90, accuracy: 0.005, "restitution did not start at 0.90: \(label(app, "restitutionValue"))")
        let slider = app.sliders["restitutionSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let e = number(label(app, "restitutionValue")) ?? 0.9
        screenshot(app, "settings")
        tap(app, "settingsDone")
        waitGone(app, "settingsDone")
        // the new restitution applies when Settings closes: the apex follows on the next frames, as the truth's ratio
        let t0 = truth(d, at: 3), tr = truth(d, at: 3, restitution: e)
        let expected = tr.apexInches / max(1e-6, t0.apexInches)
        let want = (before ?? 0) * expected
        let t = waitUntil(15) { (number(label(app, "apex")).map { abs($0 - want) <= max(1.0, want * 0.06) } ?? false) }
        Thread.sleep(forTimeInterval: 1)
        let after = number(label(app, "apex"))
        let ratio = (after ?? 0) / max(1e-6, before ?? 0)
        screenshot(app, "restitution changed")
        // Restore defaults: back to 0.90
        tap(app, "settings")
        tap(app, "restoreDefaults")
        let restored = number(label(app, "restitutionValue"))
        tap(app, "settingsDone")
        waitGone(app, "settingsDone")
        if restored.map({ abs($0 - 0.9) < 0.005 }) ?? false { appToRestore = nil }
        summary(String(format: "settings: restitution 0.90 -> %.2f: apex %@ -> %@ in (ratio %.3f, expected %.3f; truth %.1f in), shown after %.1f s; "
                       + "Restore defaults -> %@", e, before.map { String(format: "%.1f", $0) } ?? "-",
                       after.map { String(format: "%.1f", $0) } ?? "-", ratio, expected, tr.apexInches, t ?? -1,
                       restored.map { String(format: "%.2f", $0) } ?? "?"))
        XCTAssertLessThan(e, 0.7, "the slider did not move the restitution down: \(e)")
        XCTAssertNotNil(t, "the apex did not follow the restitution: \(label(app, "apex")), wanted about \(want) in")
        XCTAssertEqual(ratio, expected, accuracy: 0.06, "apex \(before ?? -1) -> \(after ?? -1) in at restitution \(e)")
        XCTAssertEqual(after ?? -99, tr.apexInches, accuracy: max(1.5, tr.apexInches * 0.06), "apex readout \(label(app, "apex"))")
        XCTAssertEqual(restored ?? -1, 0.9, accuracy: 0.005, "Restore defaults did not put the restitution back to 0.90")
    }

    /// The capture kit (Settings > Developer > Capture kit), at a quarter of its real timings (-kitFast YES) on the demo:
    /// a new kit, the measurements, the room scan and its check, the flat-phone true tilt (the demo's synthetic motion,
    /// with a 1.5° camera bump, must give the demo slab's tilt within 0.3°), one more video shot; Quit, then Resume from
    /// Settings > Developer with the progress shown; Skip through the rest; the summary; the bundle; the share sheet.
    func testCaptureKitFlow() throws {
        let d = DemoScript()
        let app = launch(["demoTilt": "\(d.tilt)", "kitFast": "YES"])
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") }, "the demo never locked")
        // never on the main screen by itself
        XCTAssertFalse(element(app, "kitNew").exists || element(app, "kitResume").exists, "the kit opened by itself")
        openDeveloper(app)
        tap(app, "captureKitRow")
        XCTAssertTrue(element(app, "kitNew").waitForExistence(timeout: 15), "the kit did not open")
        screenshot(app, "kit start")
        element(app, "kitNew").tap()
        // an unfinished kit left by an earlier run is replaced (after confirming)
        if element(app, "kitNewConfirm").waitForExistence(timeout: 2) { element(app, "kitNewConfirm").tap() }

        // step 1: the measurements. The form starts empty (the built-in slab and ball are only its placeholders), so
        // Start on it records nothing and says what is missing; then the values are typed in, as measured (the ball
        // first, lowest on the form, before the keyboard is up)
        XCTAssertTrue(element(app, "kitStart").waitForExistence(timeout: 10), "no measurements form")
        let formProgress = label(app, "kitProgress")
        screenshot(app, "kit measurements")
        element(app, "kitStart").tap()
        XCTAssertTrue(element(app, "kitFormProblems").waitForExistence(timeout: 5), "Start took an empty form as measured")
        for (id, value) in [("kitBall", "35"), ("kitWidth", "7"), ("kitDepth", "7"), ("kitThickness", "1")] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "no \(id) field")
            field.tap()
            field.typeText(value)
        }
        element(app, "kitStart").tap()

        // step 2: the room scan, a video shot
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10), "no shot screen after the measurements")
        let scanProgress = label(app, "kitProgress")
        let scanInstruction = label(app, "kitInstruction")
        element(app, "shotStart").tap()
        let recordingSeen = element(app, "kitRecording").waitForExistence(timeout: 15)
        screenshot(app, "kit recording")
        let verdict = app.staticTexts["qualityVerdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 40), "no quality check after the scan: \(label(app, "kitError"))")
        let scanVerdict = verdict.label
        screenshot(app, "kit scan checked")
        tap(app, "shotNext")

        // step 3: the flat phone (true tilt), with the demo's synthetic motion
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10))
        let flatProgress = label(app, "kitProgress")
        element(app, "shotStart").tap()
        XCTAssertTrue(app.staticTexts["flatPrompt"].waitForExistence(timeout: 15), "no flat-phone prompt")
        let firstPrompt = label(app, "flatPrompt")
        screenshot(app, "kit flat prompt")
        let tiltText = app.staticTexts["trueTilt"]
        XCTAssertTrue(tiltText.waitForExistence(timeout: 40), "no true tilt: \(label(app, "flatPrompt")) \(label(app, "kitError"))")
        let trueTiltLabel = tiltText.label
        let trueTilt = number(trueTiltLabel)
        let flatVerdict = label(app, "qualityVerdict")
        screenshot(app, "kit true tilt")
        summary(String(format: "kit flat: %@ (demo slab %.2f°, error %@), check \"%@\", first prompt \"%@\"",
                       trueTiltLabel, d.tilt, trueTilt.map { String(format: "%.3f°", abs($0 - d.tilt)) } ?? "-", flatVerdict, firstPrompt))
        XCTAssertEqual(trueTilt ?? -99, d.tilt, accuracy: 0.3, "true tilt \(trueTiltLabel) against the demo's \(d.tilt)°")
        tap(app, "shotNext")

        // step 4: one more video shot (hold still)
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10))
        element(app, "shotStart").tap()
        XCTAssertTrue(app.staticTexts["qualityVerdict"].waitForExistence(timeout: 40), "no quality check after the hold-still shot")
        let stillVerdict = label(app, "qualityVerdict")
        tap(app, "shotNext")
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10))

        // the next shot (the slab arc, 5 s here) is started and Quit is tapped in the middle of its recording: that
        // attempt is thrown away and every shot before it is kept (Resume below still says 4 of 29 done: the plan's
        // shots, `KitPlan.standard.shotCount`, 29 since standard-v2 took the drops' reading before them)
        element(app, "shotStart").tap()
        let quitMidShot = element(app, "kitRecording").waitForExistence(timeout: 15)
        tap(app, "kitQuit")
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 10), "Quit did not close the kit")
        openDeveloper(app)
        tap(app, "captureKitRow")
        let resume = element(app, "kitResume")
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "no Resume after quitting")
        let resumeText = resume.label
        screenshot(app, "kit resume")
        // The arc is only 5 s here: on a slow runner the Quit tap can come after the arc was saved. Resume then says
        // Step 5 of 12, 5 of 29, and the rest of the flow is scored for that (one shot fewer to skip, 5 captured). The
        // Copy log test checks a mid-recording Quit strictly, at the kit's real timings; the summary line says which.
        let total = KitPlan.standard.shotCount
        let arcSaved = resumeText.contains("Step 5 of 12") && resumeText.contains("5 of \(total)")
        XCTAssertTrue((resumeText.contains("Step 4 of 12") && resumeText.contains("4 of \(total)")) || arcSaved,
                      "Resume says \"\(resumeText)\" (want Step 4 of 12, 4 of \(total) done; or Step 5 of 12, 5 of \(total) if the slab arc, "
                      + "5 s under -kitFast, was saved before the Quit tap came)")
        resume.tap()
        // in the middle of a slab position the kit asks whether the slab moved: it did not
        var askedMoved = false
        if element(app, "slabMovedNo").waitForExistence(timeout: 5) { askedMoved = true; element(app, "slabMovedNo").tap() }

        // Skip through the rest (Skip height where asked)
        var skips = 0, heightSkips = 0
        while !app.staticTexts["kitSummary"].exists && skips < 40 {
            if element(app, "heightSkip").exists { element(app, "heightSkip").tap(); heightSkips += 1; continue }
            let skip = element(app, "shotSkip")
            guard skip.waitForExistence(timeout: 10) else { break }
            skip.tap()
            skips += 1
        }
        let summaryText = app.staticTexts["kitSummary"]
        XCTAssertTrue(summaryText.waitForExistence(timeout: 10), "no summary after skipping \(skips) shots")
        let summaryLabel = summaryText.label
        screenshot(app, "kit summary")
        XCTAssertTrue(summaryLabel.contains("captured") && summaryLabel.contains("skipped"), "summary: \(summaryLabel)")
        XCTAssertTrue(summaryLabel.contains(arcSaved ? "Captured 5 of \(total)" : "Captured 4 of \(total)"), "summary: \(summaryLabel) (arc saved before Quit: \(arcSaved))")

        // the bundle, and one tap to share it
        tap(app, "kitBundle")
        let share = element(app, "kitShare")
        XCTAssertTrue(share.waitForExistence(timeout: 60), "no Share kit after Make bundle: \(label(app, "kitError"))")
        let bundle = label(app, "kitBundleResult")
        share.tap()
        let shared = waitUntil(20) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Close"].exists }
        screenshot(app, "kit share sheet")
        summary("kit: \(formProgress) form, scan (\(scanProgress), \"\(scanInstruction)\"): recording shown \(recordingSeen), check \"\(scanVerdict)\"; "
                + "flat (\(flatProgress)); hold still: \"\(stillVerdict)\"; quit mid-recording \(quitMidShot), arc saved before Quit \(arcSaved); resume \"\(resumeText)\", slab-moved question \(askedMoved); "
                + "\(skips) skips (\(heightSkips) heights); summary \"\(summaryLabel.split(separator: "\n").first ?? "")\"; bundle: \(bundle); "
                + String(format: "share sheet after %.1f s", shared ?? -1))
        XCTAssertTrue(recordingSeen, "no recording indicator during the scan")
        XCTAssertTrue(quitMidShot, "the fifth shot never showed its recording, so Quit was not tested mid-shot")
        XCTAssertEqual(skips, arcSaved ? 21 : 22,
                       "skips: the remaining required shots (21, or 20 if the arc was saved) and the optional third tilt (one skip for its three shots)")
        XCTAssertTrue(bundle.contains("part"), "bundle: \(bundle)")
        XCTAssertNotNil(shared, "no share sheet after Share kit")
    }

    /// Recording (Settings > Developer > Record session): Settings closes, the main screen shows the recording pill,
    /// frames are written, and Stop on the pill offers the zip for sharing.
    func testRecordingProducesAShareableFile() throws {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        openDeveloper(app)
        tap(app, "recordToggle")
        XCTAssertTrue(waitGone(app, "developerDone"), "Settings did not close when the recording started")
        XCTAssertTrue(element(app, "recordStop").waitForExistence(timeout: 10), "no recording pill on the main screen")
        Thread.sleep(forTimeInterval: 4)
        let elapsed = label(app, "recordElapsed")
        screenshot(app, "recording")
        // how many frames were written so far: Settings > Developer > Copy diagnostics, then back to the main screen
        openDeveloper(app)
        let json = try readDiagnostics(app)
        let counts = json["counts"] as? [String: Int] ?? [:]
        let frames = counts["recordedFrames"] ?? 0
        closeSettings(app)
        let stop = element(app, "recordStop")
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        let shared = waitUntil(20) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Close"].exists }
        screenshot(app, "share sheet")
        summary(String(format: "recording: %d frames in 4 s (pill showed %@; pixels dropped %d); share sheet after %.1f s",
                       frames, elapsed.isEmpty ? "-" : elapsed, counts["recordingPixelsDropped"] ?? 0, shared ?? -1))
        XCTAssertGreaterThan(frames, 5)
        XCTAssertNotNil(shared, "no share sheet after stopping the recording")
    }

    /// Pre-flight (Settings > Developer > Pre-flight) in the Simulator, on the demo scene: it does nothing until Run is
    /// tapped, then finishes in about 10-15 s with a result on every item. The Simulator has no camera, ARKit or LiDAR, so
    /// those read N/A (motion too); the recorder test records the demo's frames through the kit's recorder (H.264 here),
    /// reads them back and deletes them: what it shows is reported, not required. Its lines go to the log.
    func testPreflight() {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") }, "the demo never locked")
        openDeveloper(app)
        let opened = openPreflight(app)
        XCTAssertTrue(opened, "no pre-flight screen: \(describe(app))")
        // nothing runs by itself
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(element(app, "preflightDone").exists, "the pre-flight ran by itself")
        let before = element(app, "preflightItem-camera").label
        XCTAssertTrue(before.contains("not run yet"), "before Run the camera item says \"\(before)\"")
        screenshot(app, "preflight before")

        let t0 = Date()
        element(app, "preflightRun").tap()
        let sawProgress = element(app, "preflightProgress").waitForExistence(timeout: 5)
        let done = element(app, "preflightDone")
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the pre-flight did not finish: \(element(app, "preflightNote").exists ? element(app, "preflightNote").label : "")")
        let seconds = Date().timeIntervalSince(t0)
        let headline = done.label
        screenshot(app, "preflight results")
        var items: [String: String] = [:]
        for c in PreflightCheck.allCases {
            let e = element(app, "preflightItem-\(c.rawValue)")
            items[c.rawValue] = e.exists ? e.label : ""
        }
        func tag(_ c: PreflightCheck) -> String { (items[c.rawValue] ?? "").split(separator: " ").first.map(String.init) ?? "" }

        tap(app, "preflightCopy")
        let copied = element(app, "preflightCopied").waitForExistence(timeout: 5)
        // its lines are in the log (back to Developer, Copy log)
        let back = app.navigationBars.buttons["Developer"]
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(element(app, "developerDone").waitForExistence(timeout: 10), "not back on the Developer screen")
        let log = readLog(app)
        let headlineStart = String(headline.prefix(12))
        let logged = log.contains("preflight started") && log.contains("preflight " + headlineStart)
        let took = String(format: "%.1f", seconds)
        let tags = PreflightCheck.allCases.map { c in "\(c.rawValue) \(tag(c))" }.joined(separator: ", ")
        let recorderLine = items["recorder"] ?? "", storageLine = items["storage"] ?? ""
        summary("preflight: finished \(took) s after Run (progress shown \(sawProgress)); \"\(headline)\"; \(tags); "
                + "recorder: \"\(recorderLine)\"; storage: \"\(storageLine)\"; copied \(copied); in the log \(logged)")
        XCTAssertTrue(sawProgress, "no progress bar while it ran")
        XCTAssertLessThan(seconds, 20, "the pre-flight took \(seconds) s")
        for c in PreflightCheck.allCases {
            XCTAssertTrue(["PASS", "WARN", "FAIL", "N/A"].contains(tag(c)), "\(c.rawValue) shows no result: \"\(items[c.rawValue] ?? "")\"")
        }
        for c in [PreflightCheck.camera, .arkit, .lidar] {
            XCTAssertEqual(tag(c), "N/A", "in the Simulator \(c.rawValue) should read not available: \"\(items[c.rawValue] ?? "")\"")
        }
        XCTAssertTrue(copied, "Copy results did not say it copied")
        XCTAssertTrue(logged, "the pre-flight's lines are not in the log")
        closeSettings(app)
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
    }

    /// Copy log (Settings > Developer): after Clear log, a short capture-kit run on the demo leaves its milestones in the
    /// log, with the recorder's summary line, and nothing in it is a file path. The run: a new kit, the measurements
    /// skipped, the room scan quit in the middle of its recording (Resume then offers the scan again, with the skipped
    /// step kept), then the scan recorded and kept. The kit runs at its real timings (not -kitFast), so Quit has the
    /// scan's 20 s to land in: a slow shared Simulator once took longer than -kitFast's 5 s to tap it, the scan was
    /// committed first (a Quit after a shot is saved keeps it) and Resume moved on to step 3. The summary line says which
    /// phase Quit landed in and how far into the scan it came (from the log's own times), so the margin shows in CI.
    func testCopyLogShowsKitMilestones() throws {
        let app = launch(["kitFast": "NO"])
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") }, "the demo never locked")
        openDeveloper(app)
        reveal(app, "clearLog")
        tap(app, "clearLog")
        tap(app, "clearLogConfirm")
        closeSettings(app)

        openDeveloper(app)
        tap(app, "captureKitRow")
        XCTAssertTrue(element(app, "kitNew").waitForExistence(timeout: 15), "the kit did not open")
        element(app, "kitNew").tap()
        if element(app, "kitNewConfirm").waitForExistence(timeout: 2) { element(app, "kitNewConfirm").tap() }
        // step 1 skipped
        XCTAssertTrue(element(app, "kitStart").waitForExistence(timeout: 10), "no measurements form")
        tap(app, "shotSkip")
        // step 2, the room scan (20 s after a 3 s countdown): Quit in the middle of its recording
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10), "no shot screen after skipping the measurements")
        element(app, "shotStart").tap()
        let midShot = element(app, "kitRecording").waitForExistence(timeout: 15)
        tap(app, "kitQuit")
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 10), "Quit did not close the kit")

        // Resume: back at the scan, the skipped step kept; then the scan is recorded and kept
        openDeveloper(app)
        tap(app, "captureKitRow")
        let resume = element(app, "kitResume")
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "no Resume after quitting mid-shot")
        let resumeText = resume.label
        resume.tap()
        XCTAssertTrue(element(app, "shotStart").waitForExistence(timeout: 10), "no shot screen after Resume")
        let resumedAt = label(app, "kitProgress")
        element(app, "shotStart").tap()
        XCTAssertTrue(app.staticTexts["qualityVerdict"].waitForExistence(timeout: 90), "no quality check after the scan: \(label(app, "kitError"))")
        tap(app, "kitQuit")
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 10), "Quit did not close the kit")

        openDeveloper(app)
        let log = readLog(app, screenshotName: "log")
        let lines = log.split(separator: "\n").map(String.init)
        let milestones: [(String, String)] = [
            ("cleared", "INFO app log cleared"), ("opened", "INFO kit opened"), ("created", "INFO kit created slab-kit-"),
            ("skipped", " skipped"), ("started", " started (Step 2 of 12"), ("cancelled", " cancelled during recording"),
            ("quit", "INFO kit quit"), ("closed", "INFO kit closed"), ("resumed", "INFO kit resumed"),
            ("committed", " committed: "), ("recorder summary", " done: "),
        ]
        let missing = milestones.filter { m in !lines.contains { $0.contains(m.1) } }.map { $0.0 }
        let paths = lines.filter { $0.contains("/var/") || $0.contains("/Users/") || $0.contains("file://") || $0.contains("/Library/") }
        let missingWords = missing.isEmpty ? "none" : missing.joined(separator: ", ")
        let errors = lines.filter { $0.contains(" ERROR ") }.count, warnings = lines.filter { $0.contains(" WARN ") }.count
        // the phase the first Quit landed in, from its line ("shot s02-scan cancelled during recording (Quit): ..."); none
        // when the scan had already ended (saved, or failed) by the time the tap came
        var quitPhase = "none"
        if let line = lines.first(where: { $0.contains(" cancelled during ") }),
           let after = line.components(separatedBy: " cancelled during ").last,
           let word = after.split(separator: " ").first {
            quitPhase = String(word)
        }
        // how far into the scan the first Quit came (the margin this test has), from the times its lines start with
        // ("2026-11-18T07:15:02.123Z INFO kit ..."): the scan's first "started" line to the first "kit quit" line (written
        // whether or not a shot was cancelled), less the countdown. More than the scan's length: the tap came too late.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func loggedAt(_ needle: String) -> Date? {
            guard let line = lines.first(where: { $0.contains(needle) }), let stamp = line.split(separator: " ").first else { return nil }
            return iso.date(from: String(stamp))
        }
        let scanSpec = KitPlan.standard.shot("s02-scan")
        let countdown = scanSpec?.countdown ?? 3, scanSeconds = scanSpec?.kind.videoSeconds ?? 20
        var quitInto = "at an unknown time"
        if let started = loggedAt(" started (Step 2 of 12"), let quitAt = loggedAt("INFO kit quit") {
            quitInto = String(format: "about %.1f s into the %.0f s scan", quitAt.timeIntervalSince(started) - countdown, scanSeconds)
        }
        summary("log: \(lines.count) lines after a short kit run (quit mid-recording \(midShot), landed during \(quitPhase), \(quitInto); "
                + "then \"\(resumeText)\", resumed at \(resumedAt)); milestones missing: \(missingWords); lines with a path: \(paths.count); "
                + "errors \(errors), warnings \(warnings)")
        XCTAssertTrue(midShot, "the scan never showed its recording, so Quit was not tested mid-shot")
        let total = KitPlan.standard.shotCount
        XCTAssertTrue(resumeText.contains("Step 2 of 12") && resumeText.contains("1 of \(total)"),
                      "after quitting mid-scan Resume says \"\(resumeText)\" (want Step 2 of 12, 1 of \(total) done); Quit landed during \(quitPhase), "
                      + quitInto + (quitPhase == "none" ? " (no cancel line: the scan had ended before the tap came)" : ""))
        XCTAssertTrue(missing.isEmpty, "milestones missing from the log: \(missing); log:\n\(log.suffix(3000))")
        XCTAssertTrue(paths.isEmpty, "the log has file paths: \(paths.prefix(3))")
        closeSettings(app)
    }

    // MARK: tap hints (optional: the app is point and go without them)

    /// Settings > Developer > Copy diagnostics: the tracker's counters (the tap counters among them), back on the main
    /// screen afterwards.
    func counts(_ app: XCUIApplication) throws -> [String: Int] {
        openDeveloper(app)
        let json = try readDiagnostics(app)
        closeSettings(app)
        return json["counts"] as? [String: Int] ?? [:]
    }

    /// Where an invisible marker is (window points): the "x,y" its text twin carries (`<id>At`, exact whatever frame the
    /// accessibility tree gives the marker), or else its element's middle when that element is marker-sized (an element
    /// made around a positioned view can be the whole screen, whose middle is not the marker); nil otherwise.
    func markerPoint(_ app: XCUIApplication, _ id: String) -> CGPoint? {
        let xy = label(app, id + "At").split(separator: ",").compactMap { Double($0) }
        if xy.count == 2 { return CGPoint(x: xy[0], y: xy[1]) }
        let e = element(app, id)
        let screen = app.windows.firstMatch.frame
        if e.exists, e.frame.width < 0.5 * screen.width, e.frame.height < 0.5 * screen.height {
            return CGPoint(x: e.frame.midX, y: e.frame.midY)
        }
        return nil
    }

    /// A tap on the screen at a point of the window (points).
    func tapAt(_ app: XCUIApplication, _ p: CGPoint) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: p.x, dy: p.y)).tap()
    }

    /// A tap on the floor near a side of the screen, away from the demo's slab and the space over it, and above the
    /// readouts (which are drawn over the tap layer and would take the tap themselves), once the tracker is running:
    /// taken for the slab (a slab tap: the search looks there first), it never keeps the app from locking the slab, nor,
    /// once locked, from keeping it (nothing is found there). The main screen shows no instructions for taps.
    func testAStrayTapNeverCostsTheLock() throws {
        let app = launch()
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 20))
        // the tracker is running once the status chip shows its state (the demo's tracker may start after launch)
        let running = waitUntil(20) {
            let s = label(app, "status")
            return s.contains("Looking for the slab") || s.contains("Checking") || s.contains("Slab locked")
        }
        XCTAssertNotNil(running, "the tracker's state never showed; status \(label(app, "status"))")
        let before = label(app, "status")
        let frame = app.windows.firstMatch.frame
        // well above the readouts' panel (its tilt value's top, less the label and padding over it, less a margin)
        let tilt = element(app, "tilt")
        let y = tilt.exists ? max(0.5 * frame.height, tilt.frame.minY - 60) : 0.7 * frame.height
        tapAt(app, CGPoint(x: frame.width * 0.1, y: y))
        let mark = element(app, "tapMark").waitForExistence(timeout: 2)
        let locked = waitUntil(30) { label(app, "status").contains("Slab locked") }
        XCTAssertNotNil(locked, "never locked after a stray tap; status \(label(app, "status"))")
        // once locked, another stray tap: the lock stays
        tapAt(app, CGPoint(x: frame.width * 0.9, y: y))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(label(app, "status").contains("Slab locked"), "the lock went after a stray tap: \(label(app, "status"))")
        screenshot(app, "stray taps")
        let c = try counts(app)
        summary("stray taps at y \(Int(y)) of \(Int(frame.height)): the first while \"\(before)\", locked \(String(format: "%.1f", locked ?? -1)) s "
                + "after it, mark seen \(mark), counts \(c.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // both reached the tracker (the first: its mark, or the count of two)
        XCTAssertTrue(mark || (c["tapSlab"] ?? 0) >= 2, "the first tap never reached the tracker (no mark, tapSlab \(c["tapSlab"] ?? 0))")
        XCTAssertGreaterThanOrEqual(c["tapSlab"] ?? 0, 1, "the taps were taken for the slab")
        XCTAssertEqual(c["tapBall"] ?? 0, 0)
        XCTAssertEqual(c["tapDismiss"] ?? 0, 0)
    }

    /// The demo's held ball: a tap on its ring dismisses it (the ring goes at once and stays gone while the camera
    /// drifts: its spot is passed over), and a tap where it is takes that back (a ball tap: the ball is looked for there
    /// first and shown again). The diagnostics count both. (Where the dismissed ball is comes from an invisible marker,
    /// "dismissedSpot"; BounceCore's DemoTapTests runs the same on the demo's frames.)
    func testTapARingToDismissItAndTapAgainToTakeItBack() throws {
        let app = launch(["demoBall": "0.30"])
        XCTAssertNotNil(waitUntil(40) { label(app, "status").contains("ball in view") }, "the ball never showed")
        var ringAt: CGPoint? = nil
        _ = waitUntil(5) { ringAt = markerPoint(app, "ballRing"); return ringAt != nil }
        guard let at = ringAt else { XCTFail("no ball ring marker"); return }
        tapAt(app, at)
        let gone = waitUntil(3) { !label(app, "status").contains("ball in view") }
        XCTAssertNotNil(gone, "the dismissed ring stayed; status \(label(app, "status"))")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(label(app, "status").contains("ball in view"), "the dismissed ball came back: \(label(app, "status"))")
        screenshot(app, "dismissed")
        var spotAt: CGPoint? = nil
        _ = waitUntil(3) { spotAt = markerPoint(app, "dismissedSpot"); return spotAt != nil }
        guard let sp = spotAt else { XCTFail("no dismissed spot marker"); return }
        tapAt(app, sp)
        let back = waitUntil(8) { label(app, "status").contains("ball in view") }
        screenshot(app, "taken back")
        let c = try counts(app)
        summary("dismiss and take back: gone after \(String(format: "%.1f", gone ?? -1)) s, back after \(String(format: "%.1f", back ?? -1)) s, "
                + "counts \(c.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        XCTAssertNotNil(back, "the ball never came back after the second tap; status \(label(app, "status")); "
                         + "tapBallAccepted=\(c["tapBallAccepted"] ?? 0) tapBallSet=\(c["tapBallSet"] ?? 0) (accepted: the expected path)")
        XCTAssertEqual(c["tapDismiss"] ?? 0, 1)
        XCTAssertGreaterThanOrEqual(c["tapBall"] ?? 0, 1)
        XCTAssertEqual(c["tapDismissLifted"] ?? 0, 1)
    }

    /// Tap to set the ball: the demo's held ball where the ball finder cannot see it (not drawn: "demoBallHidden"; where
    /// it is comes from an invisible marker, "demoBall"). A tap there finds no ball in its box, so the ball is set at the
    /// tap (the demo has no LiDAR: where the tapped line meets the upright plane through the slab's middle): its own mark
    /// shows ("setBall", not the finder's ring "ballRing"), the status says so and the drop readout says it comes from the
    /// set ball, matching the scene's truth. A tap on the mark clears it: the drop is the setting's again. The diagnostics
    /// count both.
    func testTapTheBallToSetItAndTapAgainToClearIt() throws {
        var d = DemoScript(); d.ballHeight = 0.30
        let app = launch(["demoBall": "0.30", "demoBallHidden": "YES"])
        XCTAssertNotNil(waitUntil(40) { label(app, "status").contains("Slab locked") }, "never locked; status \(label(app, "status"))")
        let dropBefore = label(app, "drop")
        var ballAt: CGPoint? = nil
        _ = waitUntil(5) { ballAt = markerPoint(app, "demoBall"); return ballAt != nil }
        guard let at = ballAt else { XCTFail("no demo ball marker"); return }
        XCTAssertFalse(element(app, "ballRing").exists, "the finder showed a ring for a ball that is not drawn")
        tapAt(app, at)
        let set = waitUntil(5) { label(app, "drop").contains("(set)") }
        screenshot(app, "set")
        let status = label(app, "status"), drop = label(app, "drop")
        let tr = truth(d, at: 3)
        XCTAssertNotNil(set, "the tap never set the ball; status \(status), drop \(drop)")
        XCTAssertTrue(status.contains("ball set"), "status \(status)")
        XCTAssertTrue(element(app, "setBall").exists || markerPoint(app, "setBall") != nil, "no set ball marker")
        XCTAssertFalse(element(app, "ballRing").exists, "a set ball is not drawn as the finder's ring")
        XCTAssertEqual(number(drop) ?? -99, tr.dropInches ?? 0, accuracy: 1.5, "the set ball's drop \(drop) against the truth")
        // a tap on its mark clears it
        var markAt: CGPoint? = nil
        _ = waitUntil(3) { markAt = markerPoint(app, "setBall"); return markAt != nil }
        guard let m = markAt else { XCTFail("no set ball marker to tap"); return }
        tapAt(app, m)
        let cleared = waitUntil(5) { !label(app, "drop").contains("(set)") && !label(app, "status").contains("ball set") }
        screenshot(app, "cleared")
        let c = try counts(app)
        summary("tap to set: set after \(String(format: "%.1f", set ?? -1)) s, drop \(drop) (truth \(String(format: "%.1f", tr.dropInches ?? -1)) in, "
                + "before \(dropBefore)), cleared after \(String(format: "%.1f", cleared ?? -1)) s (drop \(label(app, "drop"))), "
                + "counts \(c.filter { $0.key.hasPrefix("tap") }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        XCTAssertNotNil(cleared, "the set ball stayed after a tap on it; status \(label(app, "status")), drop \(label(app, "drop"))")
        XCTAssertEqual(c["tapBallSet"] ?? 0, 1)
        XCTAssertEqual(c["tapBallSetPlane"] ?? 0, 1, "the demo has no LiDAR: set on the plane")
        XCTAssertEqual(c["tapSetCleared"] ?? 0, 1)
        XCTAssertEqual(c["tapBallAccepted"] ?? 0, 0, "no ball to find")
    }
}
