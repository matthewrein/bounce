import SwiftUI

/// The user's settings: the drop height and the ball's restitution, both optional (stored in UserDefaults). The slab and
/// the ball are baked into the app (AppSettings). At the bottom, a low-key row to the developer tools.
struct SettingsView: View {
    @AppStorage(AppSettings.keys.drop) private var dropFeet = AppSettings.defaultDropFeet
    @AppStorage(AppSettings.keys.restitution) private var restitution = AppSettings.defaultRestitution
    /// closes Settings (from here or from the Developer screen)
    var close: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(footer: Text("With a ball held over the slab, its height is the drop height; otherwise this one is used. Restitution is how much of its speed into the slab the ball keeps coming off it: at 0.9 a straight-up bounce regains 81% of the drop height.")) {
                    VStack(alignment: .leading) {
                        Text(String(format: "Drop height: %.2f ft", dropFeet)).accessibilityIdentifier("dropValue")
                        Slider(value: $dropFeet, in: AppSettings.dropRange, step: 0.25).accessibilityIdentifier("dropSlider")
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Restitution: %.2f", restitution)).accessibilityIdentifier("restitutionValue")
                        Slider(value: $restitution, in: AppSettings.restitutionRange, step: 0.01).accessibilityIdentifier("restitutionSlider")
                    }
                    Button("Restore defaults") {
                        dropFeet = AppSettings.defaultDropFeet
                        restitution = AppSettings.defaultRestitution
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
            let d = AppSettings.clamped(dropFeet, AppSettings.dropRange), r = AppSettings.clamped(restitution, AppSettings.restitutionRange)
            if d != dropFeet { dropFeet = d }
            if r != restitution { restitution = r }
        }
    }
}
