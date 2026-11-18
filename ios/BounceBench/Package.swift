// swift-tools-version:5.9
// bounce-bench: times each stage of the phone's per-frame path (ARController.handle and the BounceCore code it runs) on
// synthetic camera frames, models the 60 fps budget with the app's cadence and frame pacer, and estimates iPhone times.
// A package of its own (depending on ../BounceCore), so BounceCore's `swift test` never builds it: a compile error here
// can only fail the bench's own (informational) CI job. Run it optimised:
//
//     swift run -c release --package-path ios/BounceBench bounce-bench [options]
import PackageDescription

let package = Package(
    name: "BounceBench",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../BounceCore")],
    targets: [
        .executableTarget(name: "bounce-bench", dependencies: [.product(name: "BounceCore", package: "BounceCore")]),
    ]
)
