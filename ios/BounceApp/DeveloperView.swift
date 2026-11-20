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
    @AppStorage(AppSettings.keys.slabTop) private var slabTopMm = AppSettings.defaultSlabTopMm
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
                    footer: Text("The demo shows a synthetic slab instead of the camera (also on a Mac's iPhone Simulator). Slab top: the flat top's side (tape: 180 mm); a change starts the lock again. Both apply when Settings closes.")) {
                Toggle("Demo scene (no camera)", isOn: $demo)
                    .accessibilityIdentifier("demoToggle")
                Stepper(value: $slabTopMm, in: AppSettings.slabTopRange, step: 1) {
                    Text(String(format: "Slab top (mm): %.1f", slabTopMm))
                }
                .accessibilityIdentifier("slabTopStepper")
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
/// takes `lines(for:)` lines at the text size in use, whatever it says, so the rows below it ("First run on a phone")
/// stay put while its numbers change and it rewraps (until n12 they moved up and down). The accessibility label is
/// always the whole line.
struct LiveDeveloperLine: View {
    @ObservedObject var live: LiveFrame
    /// the text size in use (a larger size wraps the line to more lines, so more are kept for it)
    @Environment(\.dynamicTypeSize) private var textSize

    /// The lines kept for the live line: enough for the longest line on the narrowest iPhone the app runs on (iOS 16:
    /// an SE's 375 pt, about 42 characters of this font a line at the default size, 33 at xxLarge, 12 at the largest
    /// accessibility size). Locked with LiDAR, recording, limited tracking and a busy frames part of about 260
    /// characters wraps to about 15 lines at the default size, 19 at xxLarge, 22 at AX1 and 44 at AX5 (the demo's line
    /// to about 11 at the default size); each size keeps a few lines more than that. A longer line still (a 320 pt
    /// Display Zoom screen) ends in "…" here; its accessibility label is still the whole line.
    static func lines(for size: DynamicTypeSize) -> Int {
        if size <= .large { return 16 }
        if size <= .xLarge { return 18 }
        if size <= .xxLarge { return 22 }
        if size <= .xxxLarge { return 24 }
        if size <= .accessibility1 { return 26 }
        if size <= .accessibility2 { return 30 }
        if size <= .accessibility3 { return 36 }
        if size <= .accessibility4 { return 44 }
        return 50
    }

    var body: some View {
        let line = live.developer.line
        Text(line)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(LiveDeveloperLine.lines(for: textSize), reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(line)
            .accessibilityIdentifier("developerLine")
    }
}
