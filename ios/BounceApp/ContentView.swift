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
                    ARFeedView(session: model.controller.session)
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
        .alert("ARKit is not available on this device", isPresented: .constant(model.arUnsupported)) { Button("OK") {} }
    }

    private var statusChip: some View {
        Text(model.hud.status)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(model.hud.locked ? Color.green.opacity(0.8) : Color.black.opacity(0.6))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }

    private var readouts: some View {
        VStack(spacing: 6) {
            HStack {
                readout("Tilt", model.hud.tilt)
                readout("Apex", model.hud.apex)
                readout("Lands", model.hud.landing)
                readout("Air", model.hud.air)
            }
            HStack {
                Text("Drop \(model.hud.drop)")
                if let d = model.hud.depth { Text("· \(d)") }
                if let r = model.hud.recording { Text("· \(r)").foregroundColor(.red) }
            }
            .font(.caption).foregroundColor(.white.opacity(0.9))
        }
        .padding(10)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.7))
            Text(value).font(.headline.monospacedDigit()).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            button(model.isRecording ? "Stop" : "Record", model.isRecording ? "stop.circle.fill" : "record.circle") { model.toggleRecording() }
            button("Reset", "arrow.counterclockwise") { model.reset() }
            button(model.copiedAt != nil ? "Copied" : "Diagnostics", "doc.on.doc") { model.copyDiagnostics() }
            button("Settings", "slider.horizontal.3") { showSettings = true }
        }
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) { Image(systemName: icon).font(.title3); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .foregroundColor(.white)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
