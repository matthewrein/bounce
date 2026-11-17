import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack {
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
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { v in model.tap(at: v.location) })
                }
                .onAppear { model.setViewport(geo.size) }
                .onChange(of: geo.size) { s in model.setViewport(s) }
            }
            .ignoresSafeArea()
            // the controls stay inside the safe area
            VStack(spacing: 8) {
                statusChip
                Spacer()
                readouts
                buttons
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.start() } else if phase == .background { model.stop() }
        }
        .sheet(isPresented: $showSettings) { SettingsView { model.settingsChanged() } }
        .sheet(item: Binding(get: { model.shareURL.map(ShareItem.init) }, set: { model.shareURL = $0?.url })) { item in
            ShareSheet(url: item.url)
        }
        .sheet(item: Binding(get: { model.diagnosticsText.map(DiagnosticsItem.init) }, set: { model.diagnosticsText = $0?.text })) { item in
            DiagnosticsView(text: item.text)
        }
        .alert(model.recordingError ?? "", isPresented: Binding(get: { model.recordingError != nil }, set: { if !$0 { model.recordingError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .alert("ARKit is not available on this device", isPresented: Binding(get: { model.arUnsupported }, set: { model.arUnsupported = $0 })) {
            Button("Show the demo") { UserDefaults.standard.set(true, forKey: "demo"); model.restart() }
            Button("OK", role: .cancel) {}
        } message: { Text("The camera tracking needs an iPhone. The demo shows a synthetic slab instead.") }
    }

    private var statusChip: some View {
        Text(model.hud.demo ? "Demo: " + model.hud.status : model.hud.status)
            .accessibilityIdentifier("status")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.hud.locked ? Color.green.opacity(0.8) : Color.black.opacity(0.6))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var readouts: some View {
        VStack(spacing: 6) {
            HStack {
                readout("Tilt", model.hud.tilt, id: "tilt")
                readout("Apex", model.hud.apex, id: "apex")
                readout("Lands", model.hud.landing, id: "lands")
                readout("Air", model.hud.air, id: "air")
            }
            HStack {
                Text("Drop \(model.hud.drop)").accessibilityIdentifier("drop")
                if let d = model.hud.depth { Text("· \(d)") }
                if let r = model.hud.recording { Text("· \(r)").foregroundColor(.red) }
            }
            .font(.caption).foregroundColor(.white.opacity(0.9))
        }
        .padding(10)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func readout(_ label: String, _ value: String, id: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.7))
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.white).accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            button(model.isRecording ? "Stop" : "Record", model.isRecording ? "stop.circle.fill" : "record.circle", id: "record") { model.toggleRecording() }
            button("Reset", "arrow.counterclockwise", id: "reset") { model.reset() }
            button("Diagnostics", "doc.on.doc", id: "diagnostics") { model.copyDiagnostics() }
            button("Settings", "slider.horizontal.3", id: "settings") { showSettings = true }
        }
    }

    private func button(_ title: String, _ icon: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.title3); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .accessibilityIdentifier(id)
        .foregroundColor(.white)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
