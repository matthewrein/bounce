import BounceCore
import XCTest

/// End-to-end tests in the iOS Simulator. ARKit and the camera do not exist there, so the app runs its demo: a synthetic
/// slab rendered from a moving virtual camera, fed through the same tracker, detectors, overlay and readouts as the
/// camera. The truth of the demo scene is known exactly (BounceCore's DemoScript), so the tests check what the app
/// shows against it. Each test prints an "E2E-SUMMARY" line that CI copies into its summary.
///
/// The main screen is point and go: the status chip, the readouts and a gear ("settings"). Settings holds the drop
/// height and the rebound; the developer tools (capture kit, diagnostics, recording, reset, demo, build) are under
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
    /// "Rebound: 50%" -> 50
    func number(_ s: String) -> Double? {
        let parts = s.replacingOccurrences(of: "°", with: " ").replacingOccurrences(of: "%", with: " ").split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(where: { Double($0) != nil }), let v = Double(parts[i]) else { return nil }
        if i + 1 < parts.count, parts[i + 1] == "ft" {
            let inch = i + 2 < parts.count ? Double(parts[i + 2]) ?? 0 : 0
            return v * 12 + inch
        }
        return v
    }

    func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The truth the app should show for a demo script at time t (slab in world, no ball unless given), for a rebound.
    func truth(_ d: DemoScript, at t: Double, rebound: Double = 0.70) -> (tilt: Double, apexInches: Double, dropInches: Double?) {
        let scene = d.scene(at: t)
        let down = Vec3(0, -1, 0)
        let r = Bounce.compute(pose: scene.slab, spec: .standard, ball: BallSpec(rebound: rebound), down: down, ballCenter: scene.ball,
                               defaultDropHeight: Units.feet(3), floorBelowCenter: scene.slab.center.y)
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
        Thread.sleep(forTimeInterval: 2) // let the lock gather a few re-checks
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

    /// Diagnostics (Settings > Developer > Copy diagnostics): the sheet shows valid JSON with the build, the lock and the
    /// counters; the Developer screen shows the same build.
    func testDiagnostics() throws {
        let app = launch()
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        Thread.sleep(forTimeInterval: 2)
        openDeveloper(app)
        XCTAssertTrue(app.staticTexts["buildLabel"].waitForExistence(timeout: 10))
        let buildLabel = label(app, "buildLabel")
        screenshot(app, "developer")
        let json = try readDiagnostics(app, screenshotName: "diagnostics")
        let counts = json["counts"] as? [String: Int] ?? [:]
        summary("diagnostics: build \(json["build"] ?? "?") (Developer shows \"\(buildLabel)\"), state \(json["state"] ?? "?"), "
                + "tracking \(json["tracking"] ?? "?"), fps \(json["fps"] ?? "?"), ms per frame \(json["msProcess"] ?? "?"), "
                + "tilt \(json["tiltDegrees"] ?? "?"), thermal \(json["thermalState"] ?? "?"), "
                + "counts \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        XCTAssertEqual(json["state"] as? String, "locked")
        let build = try XCTUnwrap(json["build"] as? String)
        XCTAssertTrue(buildLabel.contains(build), "the Developer screen shows build \"\(buildLabel)\", diagnostics \(build)")
        XCTAssertGreaterThan(counts["locks"] ?? 0, 0)
        closeSettings(app)
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 5))
    }

    /// Settings: changing the rebound from 70% to 50% scales the apex by about 50/70; Restore defaults puts it back.
    func testReboundChangesTheApex() {
        let d = DemoScript()
        let app = launch(["demoTilt": "\(d.tilt)"])
        appToRestore = app
        XCTAssertNotNil(waitUntil(30) { label(app, "status").contains("Slab locked") })
        Thread.sleep(forTimeInterval: 2)
        let before = number(label(app, "apex"))
        tap(app, "settings")
        XCTAssertTrue(element(app, "reboundValue").waitForExistence(timeout: 10))
        let startRebound = number(label(app, "reboundValue"))
        XCTAssertEqual(startRebound ?? -1, 70, accuracy: 0.5, "rebound did not start at 70%: \(label(app, "reboundValue"))")
        let slider = app.sliders["reboundSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let rebound = number(label(app, "reboundValue")) ?? 70
        screenshot(app, "settings")
        tap(app, "settingsDone")
        waitGone(app, "settingsDone")
        // the new rebound applies when Settings closes: the apex follows on the next frames
        let want = (before ?? 0) * rebound / 70
        let t = waitUntil(15) { (number(label(app, "apex")).map { abs($0 - want) <= max(1.0, want * 0.06) } ?? false) }
        Thread.sleep(forTimeInterval: 1)
        let after = number(label(app, "apex"))
        let tr = truth(d, at: 3, rebound: rebound / 100)
        let ratio = (after ?? 0) / max(1e-6, before ?? 0)
        screenshot(app, "rebound changed")
        // Restore defaults: back to 70%
        tap(app, "settings")
        tap(app, "restoreDefaults")
        let restored = number(label(app, "reboundValue"))
        tap(app, "settingsDone")
        waitGone(app, "settingsDone")
        if restored.map({ abs($0 - 70) < 0.5 }) ?? false { appToRestore = nil }
        summary(String(format: "settings: rebound 70%% -> %.0f%%: apex %@ -> %@ in (ratio %.3f, expected %.3f; truth %.1f in), shown after %.1f s; "
                       + "Restore defaults -> %@", rebound, before.map { String(format: "%.1f", $0) } ?? "-",
                       after.map { String(format: "%.1f", $0) } ?? "-", ratio, rebound / 70, tr.apexInches, t ?? -1,
                       restored.map { String(format: "%.0f%%", $0) } ?? "?"))
        XCTAssertLessThan(rebound, 65, "the slider did not move the rebound down: \(rebound)%")
        XCTAssertNotNil(t, "the apex did not follow the rebound: \(label(app, "apex")), wanted about \(want) in")
        XCTAssertEqual(ratio, rebound / 70, accuracy: 0.06, "apex \(before ?? -1) -> \(after ?? -1) in at rebound \(rebound)%")
        XCTAssertEqual(after ?? -99, tr.apexInches, accuracy: max(1.5, tr.apexInches * 0.06), "apex readout \(label(app, "apex"))")
        XCTAssertEqual(restored ?? -1, 70, accuracy: 0.5, "Restore defaults did not put the rebound back to 70%")
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

        // step 1: the measurements, prefilled
        XCTAssertTrue(element(app, "kitStart").waitForExistence(timeout: 10), "no measurements form")
        let formProgress = label(app, "kitProgress")
        screenshot(app, "kit measurements")
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

        // Quit, and back through Settings > Developer > Capture kit: Resume shows the progress
        tap(app, "kitQuit")
        XCTAssertTrue(element(app, "settings").waitForExistence(timeout: 10), "Quit did not close the kit")
        openDeveloper(app)
        tap(app, "captureKitRow")
        let resume = element(app, "kitResume")
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "no Resume after quitting")
        let resumeText = resume.label
        screenshot(app, "kit resume")
        XCTAssertTrue(resumeText.contains("Step 4 of 12") && resumeText.contains("4 of 28"), "Resume says \"\(resumeText)\"")
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
        XCTAssertTrue(summaryLabel.contains("Captured 4 of 28"), "summary: \(summaryLabel)")

        // the bundle, and one tap to share it
        tap(app, "kitBundle")
        let share = element(app, "kitShare")
        XCTAssertTrue(share.waitForExistence(timeout: 60), "no Share kit after Make bundle: \(label(app, "kitError"))")
        let bundle = label(app, "kitBundleResult")
        share.tap()
        let shared = waitUntil(20) { app.otherElements["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists || app.buttons["Close"].exists }
        screenshot(app, "kit share sheet")
        summary("kit: \(formProgress) form, scan (\(scanProgress), \"\(scanInstruction)\"): recording shown \(recordingSeen), check \"\(scanVerdict)\"; "
                + "flat (\(flatProgress)); hold still: \"\(stillVerdict)\"; resume \"\(resumeText)\", slab-moved question \(askedMoved); "
                + "\(skips) skips (\(heightSkips) heights); summary \"\(summaryLabel.split(separator: "\n").first ?? "")\"; bundle: \(bundle); "
                + String(format: "share sheet after %.1f s", shared ?? -1))
        XCTAssertTrue(recordingSeen, "no recording indicator during the scan")
        XCTAssertEqual(skips, 22, "skips: the 21 remaining required shots and the optional third tilt (one skip for its three shots)")
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
}
