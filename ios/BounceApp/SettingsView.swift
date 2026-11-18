import SwiftUI

/// The user's settings: the drop height and the rebound, both optional (stored in UserDefaults). The slab and the ball
/// are baked into the app (AppSettings). At the bottom, a low-key row to the developer tools.
struct SettingsView: View {
    @AppStorage(AppSettings.keys.drop) private var dropFeet = AppSettings.defaultDropFeet
    @AppStorage(AppSettings.keys.reb) private var rebound = AppSettings.defaultReboundPercent
    /// closes Settings (from here or from the Developer screen)
    var close: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("With a ball held over the slab, its height is the drop height; otherwise this one is used. Rebound is how much of the drop height a straight-up bounce would regain.")) {
                    VStack(alignment: .leading) {
                        Text(String(format: "Drop height: %.2f ft", dropFeet)).accessibilityIdentifier("dropValue")
                        Slider(value: $dropFeet, in: AppSettings.dropRange, step: 0.25).accessibilityIdentifier("dropSlider")
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Rebound: %.0f%%", rebound)).accessibilityIdentifier("reboundValue")
                        Slider(value: $rebound, in: AppSettings.reboundRange, step: 1).accessibilityIdentifier("reboundSlider")
                    }
                    Button("Restore defaults") {
                        dropFeet = AppSettings.defaultDropFeet
                        rebound = AppSettings.defaultReboundPercent
                    }
                    .accessibilityIdentifier("restoreDefaults")
                }
                Section {
                    NavigationLink(destination: DeveloperView(close: close)) {
                        Text("Developer").foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("developerRow")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("settingsDone") }
            }
        }
        .onAppear {
            // values stored by earlier builds may lie outside today's ranges: show what the app uses
            let d = AppSettings.clamped(dropFeet, AppSettings.dropRange), r = AppSettings.clamped(rebound, AppSettings.reboundRange)
            if d != dropFeet { dropFeet = d }
            if r != rebound { rebound = r }
        }
    }
}
