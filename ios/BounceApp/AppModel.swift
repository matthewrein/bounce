import BounceCore
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The build label shown in Settings > Developer and in diagnostics. Bump it on every change to the app or to BounceCore.
let appBuild = "n11"

/// The app's settings. The app is point and go: the only things a user ever sets are the drop height and the ball's
/// restitution (both optional, stored in UserDefaults). Everything else is baked in below and never asked of the user.
struct AppSettings: Equatable {
    // MARK: baked in (the one place the app's slab, ball and detector set-up come from)

    /// The slab: a 180.2 mm (7.09 in) square flat top, 1 in thick, with a 1/8 in dish and its sloped, rounded sides
    /// (BounceCore's `SlabSpec.ownerSlab`, the same as `RecordingSettings()`'s, so the kit scorer and replays run what the
    /// app runs; its constants are the one place to change it). The slab finder is tuned for it.
    static let slab = SlabSpec.ownerSlab
    /// The ball: 30 mm titanium (BounceCore's `BallSpec.ownerBall`; its restitution is replaced by the user's setting).
    static let ball = BallSpec.ownerBall
    // The detectors' tuning is BounceCore's (`AppDetectors`, `Detectors.swift`), and the tracker's settings are built from
    // these values by `RecordingSettings.trackerSettings` (see `tracker`), as a replay of a recording builds them.

    // MARK: the user's settings (Settings)

    static let defaultDropFeet = 3.0
    /// the owner's ball on the slab (BounceCore's `BallSpec.ownerRestitution`: 0.8)
    static let defaultRestitution = BallSpec.ownerRestitution
    static let dropRange: ClosedRange<Double> = 0.5...10
    static let restitutionRange: ClosedRange<Double> = 0...1

    /// used when no ball is held over the slab
    var dropFeet: Double = AppSettings.defaultDropFeet
    /// the ball's restitution e: the share of its speed into the slab, along the slab's surface normal, that it keeps
    /// coming off (a straight-up bounce regains e² of the drop height)
    var restitution: Double = AppSettings.defaultRestitution

    /// UserDefaults keys. The slab, thickness, dish, ball and "dishBounce" keys of earlier builds are no longer read.
    static let keys = (drop: "dropFeet", restitution: "restitution", demo: "demo")
    /// Keys of the builds before n12 that are removed, not read (`load`): the rebound percent ("reboundPercent") tuned the
    /// old launch along the slab's normal, which had no speed along the surface, so it stood in for that missing speed
    /// as well as for the bounce (the owner's 100% matched the distance); read as a restitution it would make the new
    /// bounce land a third too far. Settings starts at the owner's restitution instead. The developer's dish-normal switch
    /// ("devDishNormalLaunch") is gone: the bounce always leaves about the dish's own normal where the ball hits.
    static let retiredKeys = ["reboundPercent", "devDishNormalLaunch"]

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings()
        func number(_ k: String) -> Double? {
            guard let x = d.object(forKey: k) as? Double, x.isFinite else { return nil }
            return x
        }
        for k in retiredKeys where d.object(forKey: k) != nil { d.removeObject(forKey: k) }
        if let x = number(keys.drop) { s.dropFeet = clamped(x, dropRange) }
        if let x = number(keys.restitution) { s.restitution = clamped(x, restitutionRange) }
        return s
    }

    static func clamped(_ x: Double, _ r: ClosedRange<Double>) -> Double { min(max(x, r.lowerBound), r.upperBound) }

    /// The settings in a recording's and the diagnostics' terms: BounceCore's defaults (`RecordingSettings()`: the baked
    /// slab and ball, `slab` and `ball` above, in the owner's units, and the impact rule with the ball's tangential share)
    /// with the user's drop height and restitution (and the rebound it gives, e², for older readers).
    var recording: RecordingSettings {
        var r = RecordingSettings()
        r.dropHeightFeet = dropFeet
        r.restitution = restitution
        r.reboundPercent = RecordingSettings.reboundPercent(restitution: restitution)
        return r
    }

    /// The tracker's settings, built exactly as a replay of a recording builds them (`RecordingSettings.trackerSettings`).
    var tracker: TrackerSettings { recording.trackerSettings }
}

/// What the overlay draws, already in view points.
struct OverlayState: Equatable {
    var outline: [CGPoint] = []
    var measured: [CGPoint] = []
    var path: [CGPoint] = []
    var start: CGPoint? = nil
    var apex: CGPoint? = nil
    var landing: CGPoint? = nil
    var normalTip: CGPoint? = nil
    var ball: CGPoint? = nil
    var ballRadius: CGFloat = 0
    var dropTop: CGPoint? = nil
    /// the tilt is not settled yet (`TrackerOutput.angleSettled`): the launch line and path are drawn faint and dashed,
    /// and the landing ring and its label are left out (1 deg of tilt moves the landing about 4.5 cm)
    var settling = false
}

/// What the main screen shows: a passive status and the readouts. (No hints or instructions: those are developer-only.)
struct HUDState: Equatable {
    var status = "Starting camera"
    var locked = false
    var tilt: String = "–"
    var apex: String = "–"
    var landing: String = "–"
    var air: String = "–"
    var drop: String = "–"
    var demo = false
    /// the slab is locked but its tilt is still settling (`TrackerOutput.angleSettled` false): Tilt and Lands read
    /// `HUDState.settlingText`, dimmed; Apex and Air keep their values (a degree moves them by at most 6 mm and 4 ms)
    var settling = false

    /// what Tilt and Lands read while the tilt settles
    static let settlingText = "settling"
}

/// The live developer line (Settings > Developer): the tracker's state, whether the lock is unconfirmed, its hint, and
/// the recording's progress.
struct DeveloperStatus: Equatable {
    var state = "not started"
    var lockUnconfirmed = false
    var hint: String? = nil
    var tracking = "not started"
    var depth: String? = nil
    var recordedFrames: Int? = nil
    /// why a running recording stopped writing, if it did
    var recordingFailure: String? = nil
    /// how the camera's frames came and went over the last 10 s (ARController.framesLine), updated once a second
    var frames: String? = nil
    /// the tilt's honest uncertainty while locked, e.g. "tilt sigma 1.7° · 1 view group · settling" (ARController
    /// .tiltLine)
    var tilt: String? = nil

    var line: String {
        var parts = ["state \(state)", "lockUnconfirmed \(lockUnconfirmed)", "tracking \(tracking)"]
        if let t = tilt { parts.append(t) }
        if let f = frames { parts.append(f) }
        if let d = depth { parts.append(d) }
        if let n = recordedFrames { parts.append("recorded \(n) frames") }
        parts.append("hint: " + (hint ?? "none"))
        return parts.joined(separator: "\n")
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var overlay = OverlayState()
    @Published var hud = HUDState()
    @Published var developer = DeveloperStatus()
    @Published var settings = AppSettings.load()
    @Published var shareURL: URL? = nil
    @Published var isRecording = false
    /// a stop was asked for and the recording is being zipped
    @Published var isStopping = false
    @Published var recordingStartedAt: Date? = nil
    @Published var arUnsupported = false
    @Published var background: CGImage? = nil
    @Published var diagnosticsText: String? = nil
    /// why the last recording could not start or be saved (shown in Settings > Developer and on the recording pill)
    @Published var recordingError: String? = nil
    /// the capture kit (a developer tool, Settings > Developer > Capture kit) is open over the camera
    @Published var kitOpen = false
    /// Settings > Developer > Pre-flight is running (the capture kit and recording wait for it)
    @Published var preflightRunning = false
    /// Settings > Developer > Copy log: the text shown in its sheet (the clipboard has all of it)
    @Published var logText: String? = nil

    let controller = ARController()
    private(set) lazy var kit = KitSession(model: self, controller: controller)
    private(set) lazy var preflight = PreflightRunner(model: self, controller: controller)

    init() {
        controller.model = self
        AppLog.start()
    }

    private var running = false
    private var runningDemo = false

    /// the demo scene runs instead of the camera
    var demoRunning: Bool { runningDemo }

    /// The demo scene runs instead of the camera when turned on in Settings > Developer, or by launch arguments (UI tests):
    /// -demo YES [-demoTilt 8] [-demoHeading 35] [-demoBall 0.3] [-demoSlideTo 3 -demoSlideAt 8]
    /// [-demoElevation 72 -demoElevationTo 48 -demoElevationAt 15] (the camera held steeply, then lowered)
    nonisolated static func demoScriptRequested(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: AppSettings.keys.demo) }

    nonisolated static func demoScript(_ d: UserDefaults = .standard) -> DemoScript? {
        guard demoScriptRequested(d) else { return nil }
        var s = DemoScript()
        func num(_ k: String) -> Double? { d.string(forKey: k).flatMap { Double($0) } }
        if let x = num("demoTilt") { s.tilt = x }
        if let x = num("demoHeading") { s.heading = x }
        if let x = num("demoBall") { s.ballHeight = x }
        if let x = num("demoSlideTo") { s.slideTo = x }
        if let x = num("demoSlideAt") { s.slideAt = x }
        if let x = num("demoElevation") { s.elevation = x }
        if let x = num("demoElevationTo") { s.elevationTo = x }
        if let x = num("demoElevationAt") { s.elevationAt = x }
        return s
    }

    func start() {
        guard !running else { return }
        AppLog.info("app", "active: " + (AppModel.demoScriptRequested() ? "demo scene" : ARController.isSupported ? "camera" : "no ARKit on this device"))
        if let demo = AppModel.demoScript() {
            running = true; runningDemo = true
            arUnsupported = false
            UIApplication.shared.isIdleTimerDisabled = true   // aiming is hands-off: don't let the screen lock
            controller.startDemo(script: demo, settings: settings)
            return
        }
        runningDemo = false
        guard ARController.isSupported else {
            arUnsupported = true
            return
        }
        arUnsupported = false
        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // aiming and recording are hands-off: don't let the screen lock
        controller.start(settings: settings)
    }

    /// The demo switch changed: restart on the camera or the demo (a running recording is stopped and saved first).
    func restart() {
        AppLog.info("app", "restarting on the " + (AppModel.demoScriptRequested() ? "demo scene" : "camera"))
        if isRecording { stopRecording() }
        if running { controller.stop(); running = false; UIApplication.shared.isIdleTimerDisabled = false }
        background = nil
        start()
    }

    func stop() {
        guard running else { return }
        running = false
        AppLog.info("app", "background")
        if preflightRunning { preflight.cancel("the app left the foreground") }
        if kitOpen { kit.appBackgrounded() }
        if isRecording { stopRecording() }
        UIApplication.shared.isIdleTimerDisabled = false
        controller.stop()
    }

    /// Settings closed: apply the drop height, restitution and the developer switches.
    func settingsChanged() {
        if preflightRunning { preflight.cancel("Settings was closed") }
        settings = AppSettings.load()
        controller.update(settings: settings)
        if !running || runningDemo != AppModel.demoScriptRequested() { restart() }
    }

    func tap(at p: CGPoint) { controller.tap(at: p) }

    func reset() { controller.resetTracking() }

    // MARK: session recording (Settings > Developer)

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !isRecording, !preflightRunning else { return }
        recordingError = nil
        isRecording = true
        isStopping = false
        recordingStartedAt = Date()
        controller.startRecording()
    }

    func stopRecording() {
        guard isRecording, !isStopping else { return }
        isStopping = true
        controller.stopRecording { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRecording = false
                self.isStopping = false
                self.recordingStartedAt = nil
                switch result {
                case .success(let url): self.shareURL = url
                case .failure(let e):
                    self.recordingError = "Could not save the recording: \(SessionRecorder.describe(e))"
                    AppLog.error("session-rec", "could not save the recording", e)
                }
            }
        }
    }

    // MARK: the capture kit (Settings > Developer > Capture kit)

    /// Open the capture kit. Only the Developer screen calls this: the kit never opens by itself.
    func openKit() {
        guard !kitOpen, !preflightRunning else { return }
        if isRecording { stopRecording() }
        kitOpen = true
        kit.open()
    }

    /// The kit closed itself (Quit, or its kit was deleted).
    func kitClosed() {
        kitOpen = false
        UIApplication.shared.isIdleTimerDisabled = running
    }

    /// ARKit's session was interrupted (a phone call, another app took the camera).
    func cameraInterrupted() {
        if kitOpen { kit.cameraInterrupted() }
    }

    /// Called by the controller when a recording could not start.
    func recordingDidFail(_ message: String) {
        AppLog.error("session-rec", message)
        isRecording = false
        isStopping = false
        recordingStartedAt = nil
        recordingError = message
    }

    /// Settings > Developer > Copy log: every line of the developer log to the clipboard, and the last ones in a sheet.
    func copyLog() {
        let text = AppLog.copyText()
        UIPasteboard.general.string = text
        logText = AppLog.shownText(text)
    }

    /// Settings > Developer > Clear log (after confirming).
    func clearLog() {
        AppLog.shared.clear()
        AppLog.info("app", "log cleared (build \(appBuild), \(Device.model), iOS \(UIDevice.current.systemVersion))")
    }

    /// Copies the diagnostics JSON and shows it.
    func copyDiagnostics() {
        let json = controller.diagnosticsJSON(settings: settings)
        UIPasteboard.general.string = json
        diagnosticsText = json
    }

    func setViewport(_ size: CGSize) { controller.setViewport(size) }

    // called by the controller on the main queue
    func publish(overlay o: OverlayState, hud h: HUDState, developer d: DeveloperStatus, background bg: CGImage?) {
        if o != overlay { overlay = o }
        if h != hud { hud = h }
        if d != developer { developer = d }
        if let bg = bg { background = bg } else if !h.demo, background != nil { background = nil }
    }
}
