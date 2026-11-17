import BounceCore
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The build label shown in the app and in diagnostics. Bump it on every change to the app or to BounceCore.
let appBuild = "n1"

/// The owner's settings, in the owner's units, stored in UserDefaults.
struct AppSettings: Equatable {
    var sideInches: Double = 7
    var sideBInches: Double = 7
    var thicknessInches: Double = 1
    var dishInches: Double = 0.125
    var ballMm: Double = 35
    var dropFeet: Double = 3
    var reboundPercent: Double = 70
    var dishBounce: Bool = false

    static let keys = (side: "slabSide", sideB: "slabSideB", thick: "slabThickness", dish: "slabDish", ball: "ballMm",
                       drop: "dropFeet", reb: "reboundPercent", dishBounce: "dishBounce")

    static func load(_ d: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings()
        func get(_ k: String, _ v: inout Double, _ lo: Double, _ hi: Double) { if let x = d.object(forKey: k) as? Double, x >= lo, x <= hi { v = x } }
        get(keys.side, &s.sideInches, 3, 20); get(keys.sideB, &s.sideBInches, 3, 20); get(keys.thick, &s.thicknessInches, 0.2, 4)
        get(keys.dish, &s.dishInches, 0, 0.75); get(keys.ball, &s.ballMm, 5, 120); get(keys.drop, &s.dropFeet, 0.1, 15)
        get(keys.reb, &s.reboundPercent, 0, 100)
        s.dishBounce = d.bool(forKey: keys.dishBounce)
        return s
    }

    var recording: RecordingSettings {
        RecordingSettings(sideUInches: sideInches, sideVInches: sideBInches, thicknessInches: thicknessInches, dishInches: dishInches,
                          ballDiameterMm: ballMm, dropHeightFeet: dropFeet, reboundPercent: reboundPercent)
    }

    var tracker: TrackerSettings {
        var t = TrackerSettings()
        t.spec = recording.slab
        t.ball = recording.ball
        t.defaultDropHeight = recording.dropHeight
        t.launchRule = dishBounce ? .dishNormal : .cornerPlane
        t.searchInterval = 0.12   // the search costs tens of ms: a few times a second is plenty
        return t
    }
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

/// What the readout panel shows.
struct HUDState: Equatable {
    var status = "Starting camera"
    var locked = false
    var tilt: String = "–"
    var apex: String = "–"
    var landing: String = "–"
    var air: String = "–"
    var drop: String = "–"
    var depth: String? = nil
    var recording: String? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var overlay = OverlayState()
    @Published var hud = HUDState()
    @Published var settings = AppSettings.load()
    @Published var shareURL: URL? = nil
    @Published var isRecording = false
    @Published var copiedAt: Date? = nil
    @Published var arUnsupported = false

    let controller = ARController()

    init() {
        controller.model = self
    }

    private var running = false

    func start() {
        guard !running else { return }
        guard ARController.isSupported else { arUnsupported = true; hud.status = "This device cannot run ARKit world tracking"; return }
        running = true
        controller.start(settings: settings)
    }

    func stop() {
        guard running else { return }
        running = false
        if isRecording { toggleRecording() }
        controller.stop()
    }

    func settingsChanged() {
        settings = AppSettings.load()
        controller.update(settings: settings)
    }

    func tap(at p: CGPoint) { controller.tap(at: p) }

    func reset() { controller.resetTracking() }

    func toggleRecording() {
        if isRecording {
            controller.stopRecording { [weak self] url in
                Task { @MainActor in self?.isRecording = false; self?.shareURL = url }
            }
        } else {
            isRecording = controller.startRecording(settings: settings)
        }
    }

    func copyDiagnostics() {
        let json = controller.diagnosticsJSON(settings: settings)
        UIPasteboard.general.string = json
        copiedAt = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedAt = nil
        }
    }

    func setViewport(_ size: CGSize) { controller.setViewport(size) }

    // called by the controller on the main queue
    func publish(overlay o: OverlayState, hud h: HUDState) {
        if o != overlay { overlay = o }
        if h != hud { hud = h }
    }
}
