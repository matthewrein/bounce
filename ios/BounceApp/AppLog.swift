import BounceCore
import Foundation
import SwiftUI
import UIKit

/// The developer log (Settings > Developer > Copy log): a line for every error the capture kit, the recorders, ARKit,
/// CoreMotion and the pre-flight run into, and a short line for each kit milestone (kit opened, shot started, committed,
/// skipped, cancelled, bundle made) so a failed attempt has its context. BounceCore's `DevLog` keeps it in
/// Application Support/Logs (not shown in the Files app): every line is in the file before the call returns, about 1 MB is
/// kept, and messages are words and numbers only (paths and URLs are cut out). Any queue may log.
enum AppLog {
    /// Application Support/Logs; the temporary folder if Application Support cannot be had
    static let folder: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Logs", isDirectory: true)
    }()

    static let shared = DevLog(folder: folder)

    /// lines shown in the Copy log sheet (the clipboard gets every line)
    static let shownLines = 200

    static func info(_ area: String, _ message: String) { shared.info(area, message) }
    static func warn(_ area: String, _ message: String) { shared.warn(area, message) }
    static func error(_ area: String, _ message: String) { shared.error(area, message) }
    /// "<what>: <the error in words and numbers>"
    static func error(_ area: String, _ what: String, _ error: Error) { shared.error(area, what, error) }
    static func warn(_ area: String, _ what: String, _ error: Error) { shared.log(.warn, area, what + ": " + DevLog.describe(error)) }

    /// set by `start` (main thread, at launch)
    private static var started = false

    /// At launch, once (AppModel.init): a line saying which build started on what, then lines for memory warnings,
    /// thermal changes and an uncaught Objective-C exception (AVFoundation raises those when it is misused), so even a
    /// crash leaves its reason.
    @MainActor static func start() {
        guard !started else { return }
        started = true
        let free = PreflightRunner.freeBytes().map { String(format: "%.0f MB free", Double($0) / 1e6) } ?? "free space unknown"
        info("app", "launched: build \(appBuild), \(Device.model), iOS \(UIDevice.current.systemVersion), "
             + "ARKit \(ARController.isSupported ? "yes" : "no"), LiDAR \(ARController.depthSupported ? "yes" : "no"), "
             + "demo \(AppModel.demoScriptRequested() ? "on" : "off"), thermal \(ARController.thermalState), \(free)")
        if shared.failedWrites > 0 { warn("app", "\(shared.failedWrites) log lines could not be written") }
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            AppLog.warn("app", "memory warning (thermal \(ARController.thermalState))")
        }
        _ = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            AppLog.info("app", "thermal state \(ARController.thermalState)")
        }
        installExceptionHandler()
    }

    /// Not actor-isolated, so the handler is a plain C function (it captures nothing).
    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            AppLog.shared.error("crash", "uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason given")")
        }
    }

    /// What Copy log puts on the clipboard: a header line, then every line kept, oldest first.
    static func copyText() -> String {
        let lines = shared.lines()
        var header = "Slab Bounce log, build \(appBuild), \(Device.model), iOS \(UIDevice.current.systemVersion), "
            + "copied \(ISO8601DateFormatter().string(from: Date())): \(lines.count) lines"
        if shared.failedWrites > 0 { header += ", \(shared.failedWrites) lines could not be written" }
        return ([header] + (lines.isEmpty ? ["(the log is empty)"] : lines)).joined(separator: "\n") + "\n"
    }

    /// The sheet's text: the header and the last `shownLines` lines.
    static func shownText(_ copied: String) -> String {
        let all = copied.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard all.count > shownLines + 2 else { return copied }
        let header = all.first ?? ""
        let tail = all.suffix(shownLines + 1)   // the last element is the empty string after the final newline
        return header + "\n(showing the last \(shownLines) lines; all of them were copied)\n" + tail.joined(separator: "\n")
    }
}

/// The log (already copied to the clipboard): its last lines, to read, or to copy again.
struct LogView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("logText")
            }
            .navigationTitle("Log (copied)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Copy") { UIPasteboard.general.string = AppLog.copyText() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("logDone") }
            }
        }
    }
}
