import SwiftUI

/// The main screen: point and go. The camera feed with the overlay, the readouts, a passive status chip and a small
/// gear for Settings. Nothing to set up and nothing to read: the developer tools live in Settings > Developer. While a
/// developer has the capture kit open (Settings > Developer > Capture kit), its screens replace the normal controls.
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack {
            if model.arUnsupported {
                unsupported
            } else {
                // the camera feed, the overlay and the tap target share one full-screen coordinate space
                GeometryReader { geo in
                    ZStack {
                        if model.hud.demo, let bg = model.background {
                            // the demo's synthetic frame, filling the view as the camera feed does
                            Image(decorative: bg, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        } else {
                            ARFeedView(session: model.controller.session)
                        }
                        OverlayView(overlay: model.overlay)
                        // where the ball's ring and a tap's mark are, for the UI tests (invisible, under the tap layer)
                        if let b = model.overlay.ball {
                            let r = max(model.overlay.ballRadius, 6)
                            Color.white.opacity(0.001)
                                .frame(width: 2 * r, height: 2 * r)
                                .position(b)
                                .allowsHitTesting(false)
                                .accessibilityElement()
                                .accessibilityLabel("Ball")
                                .accessibilityIdentifier("ballRing")
                        }
                        ForEach(Array(model.overlay.dismissed.enumerated()), id: \.offset) { _, p in
                            Color.white.opacity(0.001)
                                .frame(width: 24, height: 24)
                                .position(p)
                                .allowsHitTesting(false)
                                .accessibilityElement()
                                .accessibilityLabel("Dismissed ball")
                                .accessibilityIdentifier("dismissedSpot")
                        }
                        // the same places as text ("x,y", view points), which the UI tests can read whatever the
                        // accessibility tree does with a nearly transparent shape
                        if let b = model.overlay.ball {
                            Text(String(format: "%.0f,%.0f", Double(b.x), Double(b.y)))
                                .font(.system(size: 2))
                                .opacity(0.02)
                                .position(b)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("ballRingAt")
                        }
                        if let p = model.overlay.dismissed.first {
                            Text(String(format: "%.0f,%.0f", Double(p.x), Double(p.y)))
                                .font(.system(size: 2))
                                .opacity(0.02)
                                .position(p)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("dismissedSpotAt")
                        }
                        if let m = model.overlay.tapMark {
                            Color.white.opacity(0.001)
                                .frame(width: 2 * m.radius, height: 2 * m.radius)
                                .position(m.center)
                                .allowsHitTesting(false)
                                .accessibilityElement()
                                .accessibilityLabel(m.kind.rawValue)
                                .accessibilityIdentifier("tapMark")
                        }
                        // Taps are optional hints, decided by what is under the finger (BounceCore's SlabTracker.tapKind):
                        // tapping the slab makes the search look there first, tapping the ball looks for it there first,
                        // and tapping a ball ring that is wrong dismisses it. Silent: the app never asks for a tap.
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in model.tap(at: v.location) })
                    }
                    .onAppear { model.setViewport(geo.size) }
                    .onChange(of: geo.size) { s in model.setViewport(s) }
                }
                .ignoresSafeArea()
                if model.kitOpen {
                    KitScreen(kit: model.kit)
                } else {
                    controls
                }
            }
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
        .sheet(isPresented: $showSettings, onDismiss: { model.settingsChanged() }) {
            SettingsView(close: { showSettings = false }).environmentObject(model)
        }
        // a recording stopped from the main screen (one stopped in Settings > Developer is shared from there)
        .sheet(item: Binding(get: { showSettings ? nil : model.shareURL.map(ShareItem.init) }, set: { model.shareURL = $0?.url })) { item in
            ShareSheet(url: item.url)
        }
    }

    /// The status chip, the gear, the recording pill and the readouts (inside the safe area).
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                statusChip
                Spacer(minLength: 0)
                settingsButton
            }
            if model.isRecording || model.recordingError != nil {
                HStack { recordingPill; Spacer(minLength: 0) }
            }
            Spacer()
            readouts
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// On a device without ARKit: a plain message (the demo is a developer tool, in Settings > Developer).
    private var unsupported: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("Slab Bounce needs an iPhone with ARKit.")
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(32)
                .accessibilityIdentifier("unsupported")
            VStack {
                HStack { Spacer(); settingsButton }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var statusChip: some View {
        Text(model.hud.demo ? "Demo: " + model.hud.status : model.hud.status)
            .accessibilityIdentifier("status")
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.hud.locked ? Color.green.opacity(0.8) : Color.black.opacity(0.6))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settings")
    }

    /// While a developer records a session: a small red pill with the elapsed time and Stop. It also carries a recording
    /// error (there are no alerts on the main screen).
    private var recordingPill: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                Circle().fill(Color.white).frame(width: 8, height: 8)
                if let start = model.recordingStartedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text(RecordingClock.elapsed(from: start, to: context.date))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .accessibilityIdentifier("recordElapsed")
                    }
                }
                if let f = model.developer.recordingFailure {
                    Text("stopped: " + f).font(.caption).lineLimit(2)
                }
                Button(model.isStopping ? "Saving" : "Stop") { model.stopRecording() }
                    .font(.caption.weight(.bold))
                    .disabled(model.isStopping)
                    .accessibilityIdentifier("recordStop")
            } else if let e = model.recordingError {
                Text(e).font(.caption).lineLimit(3).accessibilityIdentifier("recordError")
                Button("OK") { model.recordingError = nil }
                    .font(.caption.weight(.bold))
                    .accessibilityIdentifier("recordErrorDismiss")
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.red.opacity(0.85)))
    }

    private var readouts: some View {
        VStack(spacing: 6) {
            HStack {
                readout("Tilt", model.hud.tilt, id: "tilt")
                readout("Apex", model.hud.apex, id: "apex")
                readout("Lands", model.hud.landing, id: "lands")
                readout("Air", model.hud.air, id: "air")
            }
            Text("Drop \(model.hud.drop)")
                .accessibilityIdentifier("drop")
                .font(.caption).foregroundColor(.white.opacity(0.9))
        }
        .padding(10)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func readout(_ label: String, _ value: String, id: String) -> some View {
        // "settling" (the tilt not shown yet) is dimmed, in a smaller face so it fits
        let settling = value == HUDState.settlingText
        return VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.7))
            Text(value)
                .font(settling ? Font.subheadline : Font.headline.monospacedDigit())
                .foregroundColor(.white.opacity(settling ? 0.5 : 1))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The recording pill's clock: "0:07", "1:02:03".
enum RecordingClock {
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct DiagnosticsItem: Identifiable {
    let text: String
    var id: Int { text.hashValue }
}

/// The diagnostics JSON (already copied to the clipboard), to read or copy again.
struct DiagnosticsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("diagnosticsText")
            }
            .navigationTitle("Diagnostics (copied)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Copy") { UIPasteboard.general.string = text } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("diagnosticsDone") }
            }
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet for a recording.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
