import BounceCore
import SwiftUI
import UIKit

/// Settings > Developer > Pre-flight: a Run button (it never runs by itself), about ten seconds with a progress bar, then
/// one line per item: a PASS / WARN / FAIL / N/A mark, its title and a plain reason, and Copy results.
struct PreflightView: View {
    @ObservedObject var runner: PreflightRunner
    @EnvironmentObject var model: AppModel
    /// closes Settings altogether
    var close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("For the first run on a phone. It watches the app for about \(Int(Preflight.seconds)) seconds: the camera permission, ARKit's tracking, LiDAR depth, the motion sensors, the free space for a capture kit, and a \(Int(Preflight.recorderSeconds))-second test recording through the kit's recorder, read back and deleted. Point the phone at the room, hold it fairly still and keep the app open. Nothing is kept or sent.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button(action: { runner.run() }) {
                    Text(runner.running ? "Running" : (runner.report == nil ? "Run" : "Run again")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.running || blocked != nil)
                .accessibilityIdentifier("preflightRun")
                if let b = blocked, !runner.running {
                    Text(b).font(.footnote).foregroundColor(.orange).accessibilityIdentifier("preflightBlocked")
                }
                if runner.running {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: runner.progress)
                            .accessibilityIdentifier("preflightProgress")
                        Text(runner.checkingClip ? "Reading the test clip back" : String(format: "%.0f s left", runner.secondsLeft.rounded(.up)))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                if let n = runner.note {
                    Text(n).font(.footnote).foregroundColor(.orange).accessibilityIdentifier("preflightNote")
                }
                if let r = runner.report {
                    Text(r.headline)
                        .font(.headline)
                        .foregroundColor(PreflightView.colour(r.overall))
                        .accessibilityIdentifier("preflightDone")
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PreflightCheck.allCases, id: \.self) { c in
                        row(c, runner.report?.item(c))
                    }
                }
                if runner.report != nil {
                    Button(action: { runner.copy() }) { Text("Copy results").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("preflightCopy")
                    if runner.copied {
                        Text("Copied: paste it into your message.").font(.footnote).accessibilityIdentifier("preflightCopied")
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Pre-flight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("preflightClose") }
        }
    }

    /// Why Run is off, if it is.
    private var blocked: String? {
        if model.kitOpen { return "The capture kit is open: quit it first." }
        if model.isRecording { return "A session recording is running: stop it first." }
        return nil
    }

    /// One item: its mark, title and reason (before a result: its title only).
    private func row(_ c: PreflightCheck, _ item: PreflightItem?) -> some View {
        let tag = item?.status.tag ?? (runner.running ? "…" : "–")
        let colour = item.map { PreflightView.colour($0.status) } ?? Color.secondary
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(tag)
                .font(.caption.weight(.bold).monospaced())
                .foregroundColor(.white)
                .frame(width: 44)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(colour))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.body.weight(.semibold))
                if let i = item {
                    Text(i.detail).font(.footnote).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.map { "\($0.status.tag) \($0.title): \($0.detail)" } ?? "\(c.title): not run yet"))
        .accessibilityIdentifier("preflightItem-\(c.rawValue)")
    }

    static func colour(_ s: PreflightStatus) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .notAvailable: return .gray
        }
    }
}
