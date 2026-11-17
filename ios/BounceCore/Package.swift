// swift-tools-version:5.9
// BounceCore: the slab-and-bounce maths, detectors, tracking logic and recording format, in plain Swift (Foundation
// only) so `swift test` runs on Linux as well as on a Mac. The iOS app (../BounceApp) adds the camera, ARKit and UI.
import PackageDescription

let package = Package(
    name: "BounceCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "BounceCore", targets: ["BounceCore"])],
    targets: [
        .target(name: "BounceCore"),
        .testTarget(name: "BounceCoreTests", dependencies: ["BounceCore"], resources: [.copy("Fixtures")]),
    ]
)
