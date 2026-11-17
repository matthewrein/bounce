import SwiftUI

/// Slab side(s), thickness, dish, ball diameter, drop height, rebound. Stored in UserDefaults.
struct SettingsView: View {
    @AppStorage(AppSettings.keys.side) private var side = 7.0
    @AppStorage(AppSettings.keys.sideB) private var sideB = 7.0
    @AppStorage(AppSettings.keys.thick) private var thickness = 1.0
    @AppStorage(AppSettings.keys.dish) private var dish = 0.125
    @AppStorage(AppSettings.keys.ball) private var ballMm = 35.0
    @AppStorage(AppSettings.keys.drop) private var dropFeet = 3.0
    @AppStorage(AppSettings.keys.reb) private var rebound = 70.0
    @AppStorage(AppSettings.keys.dishBounce) private var dishBounce = false
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Slab"), footer: Text("Measure the top face edge to edge. If it is not quite square, set the second side too. Thickness is the light cut face at the middle of an edge. The dish is how far the middle of the top dips below a straightedge laid corner to corner.")) {
                    row("Side", String(format: "%.2f in", side)) { Stepper("", value: $side, in: 3...20, step: 0.05).labelsHidden() }
                    row("Other side", String(format: "%.2f in", sideB)) { Stepper("", value: $sideB, in: 3...20, step: 0.05).labelsHidden() }
                    row("Thickness", String(format: "%.2f in", thickness)) { Stepper("", value: $thickness, in: 0.2...4, step: 0.05).labelsHidden() }
                    row("Dish depth", String(format: "%.3f in", dish)) { Stepper("", value: $dish, in: 0...0.75, step: 0.03125).labelsHidden() }
                }
                Section(header: Text("Ball and bounce"), footer: Text("With a ball held over the slab, its height sets the drop. Otherwise the drop height below is used. Rebound: how much of the drop height a straight-up bounce would regain.")) {
                    row("Ball diameter", String(format: "%.0f mm", ballMm)) { Stepper("", value: $ballMm, in: 5...120, step: 1).labelsHidden() }
                    VStack(alignment: .leading) {
                        Text(String(format: "Drop height: %.2f ft", dropFeet))
                        Slider(value: $dropFeet, in: 0.25...10, step: 0.25)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Rebound: %.0f%%", rebound))
                        Slider(value: $rebound, in: 0...100, step: 1)
                    }
                    Toggle("Bounce off the dish where it lands", isOn: $dishBounce)
                }
                Section(footer: Text("Build \(appBuild)")) {
                    Button("Restore defaults") {
                        side = 7; sideB = 7; thickness = 1; dish = 0.125; ballMm = 35; dropFeet = 3; rebound = 70; dishBounce = false
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone(); dismiss() } } }
        }
        .onDisappear { onDone() }
    }

    private func row<C: View>(_ label: String, _ value: String, @ViewBuilder control: () -> C) -> some View {
        HStack { Text(label); Spacer(); Text(value).monospacedDigit().foregroundColor(.secondary); control() }
    }
}
