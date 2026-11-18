// swift-tools-version:5.9
// BounceCore: the slab-and-bounce maths, detectors, tracking logic and recording format, in plain Swift (Foundation
// only) so `swift test` runs on Linux as well as on a Mac. The iOS app (../BounceApp) adds the camera, ARKit and UI.
// `bounce-score` (macOS and Linux) scores capture kits against their ground truth (CaptureKit.md, "Scoring") and
// `bounce-kit` checks a kit that arrived and writes the synthetic phone-sized kit of the hand-off dry run (CaptureKit.md,
// "When the kit is uploaded"); the app links only the BounceCore library.
import PackageDescription

let package = Package(
    name: "BounceCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "BounceCore", targets: ["BounceCore"])],
    targets: [
        .target(name: "BounceCore"),
        .executableTarget(name: "bounce-score", dependencies: ["BounceCore"]),
        .executableTarget(name: "bounce-kit", dependencies: ["BounceCore"]),
        .testTarget(name: "BounceCoreTests", dependencies: ["BounceCore"], resources: [.copy("Fixtures")]),
    ]
)
