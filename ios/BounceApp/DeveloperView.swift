import SwiftUI

/// Settings > Developer: tools for the people working on the app. The app never needs them and never opens them by
/// itself: the capture kit, session recording, diagnostics, a tracking reset, the demo scene, the build and a live
/// line from the tracker (its hints are shown only here), and for a first run on a
/// phone the pre-flight and the developer log (Copy log, Clear log).
///
/// The screen does not redraw with the camera's frames: only its live line (LiveDeveloperLine) and a running
/// recording's failure (LiveRecordingFailure) observe the per-frame state, and the live line keeps its height, so the
/// rows below it stay put. "Screen redraws" counts this body's redraws (testSettingsAndDeveloperStayStill reads it).
struct DeveloperView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(AppSettings.keys.demo) private var demo = false
    /// Clear log was tapped: asking first
    @State private var confirmingClearLog = false
    /// this body's redraws so far (the "Screen redraws" row)
    @State private var redraws = RedrawCounter()
    /// closes Settings altogether
    var close: () -> Void

    var body: some View {
        let redrawCount = redraws.next()
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
                .disabled(model.isStopping || model.preflightRunning)
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
                .disabled(model.isStopping || (model.preflightRunning && !model.isRecording))
                .accessibilityIdentifier("recordToggle")
                if let e = model.recordingError {
                    Text(e).font(.footnote).foregroundColor(.red).accessibilityIdentifier("developerRecordError")
                } else if model.isRecording {
                    LiveRecordingFailure(live: model.live) { f in
                        Text("Recording stopped: " + f).font(.footnote).foregroundColor(.red)
                    }
                }
                Button("Copy diagnostics") { model.copyDiagnostics() }
                    .accessibilityIdentifier("diagnostics")
                Button("Reset tracking") { model.reset() }
                    .accessibilityIdentifier("reset")
            }
            Section(header: Text("Experiments"),
                    footer: Text("The demo shows a synthetic slab instead of the camera (also on a Mac's iPhone Simulator). It applies when Settings closes.")) {
                Toggle("Demo scene (no camera)", isOn: $demo)
                    .accessibilityIdentifier("demoToggle")
            }
            Section(header: Text("Live")) {
                HStack {
                    Text("Build")
                    Spacer()
                    Text(appBuild).foregroundColor(.secondary).accessibilityIdentifier("buildLabel")
                }
                HStack {
                    Text("Screen redraws")
                    Spacer()
                    Text(String(redrawCount)).foregroundColor(.secondary).accessibilityIdentifier("developerRedraws")
                }
                LiveDeveloperLine(live: model.live)
            }
            // last, so the rows above keep their places
            Section(header: Text("First run on a phone"),
                    footer: Text("Pre-flight checks the camera, ARKit, LiDAR, motion, free space and the kit's recorder in about 10 seconds, when you tap Run. Copy log copies the app's log of errors and capture kit steps (words and numbers only) to paste into your message.")) {
                NavigationLink(destination: PreflightView(runner: model.preflight, close: close)) {
                    Text("Pre-flight")
                }
                .accessibilityIdentifier("preflightRow")
                Button("Copy log") { model.copyLog() }
                    .accessibilityIdentifier("copyLog")
                if confirmingClearLog {
                    HStack(spacing: 16) {
                        Text("Clear the log?")
                        Spacer()
                        Button("Clear", role: .destructive) { confirmingClearLog = false; model.clearLog() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("clearLogConfirm")
                        Button("Cancel") { confirmingClearLog = false }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("clearLogCancel")
                    }
                } else {
                    Button("Clear log", role: .destructive) { confirmingClearLog = true }
                        .accessibilityIdentifier("clearLog")
                }
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
        .sheet(item: Binding(get: { model.logText.map(DiagnosticsItem.init) }, set: { model.logText = $0?.text })) { item in
            LogView(text: item.text)
        }
    }

    private var recordTitle: String {
        if model.isStopping { return "Saving the recording" }
        return model.isRecording ? "Stop recording" : "Record session"
    }
}

/// Settings > Developer's live line (`DeveloperStatus.line`), the one row there that redraws with the frames. It always
/// takes `lines` lines, whatever it says, so the rows below it ("First run on a phone") stay put while its numbers
/// change and it rewraps (until n12 they moved up and down). The accessibility label is always the whole line.
struct LiveDeveloperLine: View {
    @ObservedObject var live: LiveFrame

    /// Enough for the longest line on the narrowest iPhone the app runs on (iOS 16: an SE's 375 pt, about 40
    /// characters of this font a line at the default text size): locked with LiDAR, recording, and a busy frames part
    /// of about 260 characters wraps to 15 or 16 lines (the demo's line to about 11). A longer line (a larger text
    /// size) ends in "…" here.
    static let lines = 16

    var body: some View {
        let line = live.developer.line
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(LiveDeveloperLine.lines, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line)
            .accessibilityIdentifier("developerLine")
    }
}
