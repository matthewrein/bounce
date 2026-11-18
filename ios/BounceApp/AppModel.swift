import BounceCore
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The build label shown in Settings > Developer and in diagnostics. Bump it on every change to the app or to BounceCore.
let appBuild = "n8"

/// The app's settings. The app is point and go: the only things a user ever sets are the drop height and the rebound
/// (both optional, stored in UserDefaults). Everything else is baked in below and never asked of the user.
struct AppSettings: Equatable {
    // MARK: baked in (the one place the app's slab, ball and detector set-up come from)

    /// The slab: about 7 in square, 1 in thick, with a 1/8 in dish (BounceCore's `SlabSpec.standard`). The slab finder is
    /// tuned for it.
    static let slab = SlabSpec.standard
    /// The ball: 35 mm titanium (BounceCore's `BallSpec()`; its rebound is replaced by the user's setting).
    static let ball = BallSpec()
    // The detectors' tuning is BounceCore's (`AppDetectors`, `Detectors.swift`), and the tracker's settings are built from
    // these values by `RecordingSettings.trackerSettings` (see `tracker`), as a replay of a recording builds them.

    // MARK: the user's settings (Settings)

    static let defaultDropFeet = 3.0
    static let defaultReboundPercent = 70.0
    static let dropRange: ClosedRange<Double> = 0.5...10
    static let reboundRange: ClosedRange<Double> = 0...100

    /// used when no ball is held over the slab
    var dropFeet: Double = AppSettings.defaultDropFeet
    /// the share of the drop height a straight-up bounce would regain
    var reboundPercent: Double = AppSettings.defaultReboundPercent
    /// Developer experiment (Settings > Developer): launch along the dish's normal where the ball lands, not the corner
    /// plane's normal. Off unless a developer turns it on.
    var dishNormal: Bool = false

    /// UserDefaults keys. The slab, thickness, dish, ball and "dishBounce" keys of earlier builds are no longer read.
    static let keys = (drop: "dropFeet", reb: "reboundPercent", dishNormal: "devDishNormalLaunch", demo: "demo")

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings()
        func number(_ k: String) -> Double? {
            guard let x = d.object(forKey: k) as? Double, x.isFinite else { return nil }
            return x
        }
        if let x = number(keys.drop) { s.dropFeet = clamped(x, dropRange) }
        if let x = number(keys.reb) { s.reboundPercent = clamped(x, reboundRange) }
        s.dishNormal = d.bool(forKey: keys.dishNormal)
        return s
    }

    static func clamped(_ x: Double, _ r: ClosedRange<Double>) -> Double { min(max(x, r.lowerBound), r.upperBound) }

    /// The settings in a recording's and the diagnostics' terms (the baked slab and ball in the owner's units).
    var recording: RecordingSettings {
        let s = AppSettings.slab
        return RecordingSettings(sideUInches: Units.toInches(s.sideU), sideVInches: Units.toInches(s.sideV),
                                 thicknessInches: Units.toInches(s.thickness), dishInches: Units.toInches(s.dishDepth),
                                 ballDiameterMm: AppSettings.ball.diameter * 1000, dropHeightFeet: dropFeet,
                                 reboundPercent: reboundPercent, dishBounce: dishNormal)
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

    var line: String {
        var parts = ["state \(state)", "lockUnconfirmed \(lockUnconfirmed)", "tracking \(tracking)"]
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

    let controller = ARController()
    private(set) lazy var kit = KitSession(model: self, controller: controller)

    init() {
        controller.model = self
    }

    private var running = false
    private var runningDemo = false

    /// the demo scene runs instead of the camera
    var demoRunning: Bool { runningDemo }

    /// The demo scene runs instead of the camera when turned on in Settings > Developer, or by launch arguments (UI tests):
    /// -demo YES [-demoTilt 8] [-demoHeading 35] [-demoBall 0.3] [-demoSlideTo 3 -demoSlideAt 8]
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
        return s
    }

    func start() {
        guard !running else { return }
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
        if isRecording { stopRecording() }
        if running { controller.stop(); running = false; UIApplication.shared.isIdleTimerDisabled = false }
        background = nil
        start()
    }

    func stop() {
        guard running else { return }
        running = false
        if kitOpen { kit.appBackgrounded() }
        if isRecording { stopRecording() }
        UIApplication.shared.isIdleTimerDisabled = false
        controller.stop()
    }

    /// Settings closed: apply the drop height, rebound and the developer switches.
    func settingsChanged() {
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
        guard !isRecording else { return }
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
                case .failure(let e): self.recordingError = "Could not save the recording: \(SessionRecorder.describe(e))"
                }
            }
        }
    }

    // MARK: the capture kit (Settings > Developer > Capture kit)

    /// Open the capture kit. Only the Developer screen calls this: the kit never opens by itself.
    func openKit() {
        guard !kitOpen else { return }
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
        isRecording = false
        isStopping = false
        recordingStartedAt = nil
        recordingError = message
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
