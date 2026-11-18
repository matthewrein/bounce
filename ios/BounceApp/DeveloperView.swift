import SwiftUI

/// Settings > Developer: tools for the people working on the app. The app never needs them and never opens them by
/// itself: the capture kit, session recording, diagnostics, a tracking reset, the demo scene, the launch rule
/// experiment, the build and a live line from the tracker (its hints are shown only here).
struct DeveloperView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppSettings.keys.demo) private var demo = false
    @AppStorage(AppSettings.keys.dishNormal) private var dishNormal = false
    /// closes Settings altogether
    var close: () -> Void

    var body: some View {
        Form {
            Section(header: Text("Capture")) {
                // the capture kit runs over the camera: Settings closes and the kit's screens take over the main screen
                Button(action: {
                    model.openKit()
                    close()
                }) {
                    HStack {
                        Text("Capture kit")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                    }
                }
                .disabled(model.isStopping)
                .accessibilityIdentifier("captureKitRow")
                Button(recordTitle) {
                    if model.isRecording {
                        model.stopRecording()
                    } else {
                        // close Settings so the phone can be aimed; the main screen shows the recording pill and Stop
                        model.startRecording()
                        close()
                    }
                }
                .disabled(model.isStopping)
                .accessibilityIdentifier("recordToggle")
                if let e = model.recordingError {
                    Text(e).font(.footnote).foregroundColor(.red).accessibilityIdentifier("developerRecordError")
                } else if model.isRecording, let f = model.developer.recordingFailure {
                    Text("Recording stopped: " + f).font(.footnote).foregroundColor(.red)
                }
                Button("Copy diagnostics") { model.copyDiagnostics() }
                    .accessibilityIdentifier("diagnostics")
                Button("Reset tracking") { model.reset() }
                    .accessibilityIdentifier("reset")
            }
            Section(header: Text("Experiments"),
                    footer: Text("The demo shows a synthetic slab instead of the camera (also on a Mac's iPhone Simulator). The launch rule sends the ball off along the dish's normal where it lands instead of the corner plane's. Both apply when Settings closes.")) {
                Toggle("Demo scene (no camera)", isOn: $demo)
                    .accessibilityIdentifier("demoToggle")
                Toggle("Launch along the dish's normal", isOn: $dishNormal)
                    .accessibilityIdentifier("launchRuleToggle")
            }
            Section(header: Text("Live")) {
                HStack {
                    Text("Build")
                    Spacer()
                    Text(appBuild).foregroundColor(.secondary).accessibilityIdentifier("buildLabel")
                }
                Text(model.developer.line)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("developerLine")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("developerDone") }
        }
        .sheet(item: Binding(get: { model.diagnosticsText.map(DiagnosticsItem.init) }, set: { model.diagnosticsText = $0?.text })) { item in
            DiagnosticsView(text: item.text)
        }
        // a recording stopped here is shared from here (Settings stays open over the main screen)
        .sheet(item: Binding(get: { model.shareURL.map(ShareItem.init) }, set: { model.shareURL = $0?.url })) { item in
            ShareSheet(url: item.url)
        }
    }

    private var recordTitle: String {
        if model.isStopping { return "Saving the recording" }
        return model.isRecording ? "Stop recording" : "Record session"
    }
}
