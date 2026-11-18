// swift-tools-version:5.9
// BounceCore: the slab-and-bounce maths, detectors, tracking logic and recording format, in plain Swift (Foundation
// only) so `swift test` runs on Linux as well as on a Mac. The iOS app (../BounceApp) adds the camera, ARKit and UI.
// `bounce-score` (macOS and Linux) scores capture kits against their ground truth (CaptureKit.md, "Scoring"); the app
// links only the BounceCore library. `bounce-bench` times each stage of the phone's per-frame path on synthetic camera
// frames and models the 60 fps budget (run it optimised: `swift run -c release bounce-bench`).
import PackageDescription

let package = Package(
    name: "BounceCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "BounceCore", targets: ["BounceCore"])],
    targets: [
        .target(name: "BounceCore"),
        .executableTarget(name: "bounce-score", dependencies: ["BounceCore"]),
        .executableTarget(name: "bounce-bench", dependencies: ["BounceCore"]),
        .testTarget(name: "BounceCoreTests", dependencies: ["BounceCore"], resources: [.copy("Fixtures")]),
    ]
)
