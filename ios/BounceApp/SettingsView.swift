import SwiftUI

/// The user's settings: the drop height and the ball's restitution, both optional (stored in UserDefaults). The slab and
/// the ball are baked into the app (AppSettings). At the bottom, a low-key row to the developer tools.
///
/// It does not redraw with the camera's frames (the main screen that presents it no longer does: see LiveFrame). Its
/// redraws are counted for the UI tests only (RedrawCounter.exposed).
struct SettingsView: View {
    @AppStorage(AppSettings.keys.drop) private var dropFeet = AppSettings.defaultDropFeet
    @AppStorage(AppSettings.keys.restitution) private var restitution = AppSettings.defaultRestitution
    /// this body's redraws so far (for the UI tests: RedrawCounter)
    @State private var redraws = RedrawCounter()
    /// closes Settings (from here or from the Developer screen)
    var close: () -> Void

    var body: some View {
        let redrawCount = redraws.next()
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
                    .redrawCountForUITests(redrawCount)
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

/// Counts a view's body evaluations (its redraws), so the UI tests can check that Settings and Settings > Developer do
/// not redraw with the camera's frames (testSettingsAndDeveloperStayStill). Kept in the view's @State, so it lasts as
/// long as the screen is shown; counting changes no state and redraws nothing.
final class RedrawCounter {
    private(set) var count = 0

    /// one more redraw; the count so far
    func next() -> Int {
        count += 1
        return count
    }

    /// Settings shows its count only to a UI test that asks for it (launched with -countRedraws YES), as its Developer
    /// row's accessibility value; a user (VoiceOver included) never meets it. Developer shows its own ("Screen
    /// redraws").
    static let exposed = UserDefaults.standard.bool(forKey: "countRedraws")
}

extension View {
    /// The redraw count as this element's accessibility value, only when a UI test asks for it (RedrawCounter.exposed).
    @ViewBuilder
    func redrawCountForUITests(_ count: Int) -> some View {
        if RedrawCounter.exposed {
            accessibilityValue(String(count))
        } else {
            self
        }
    }
}
