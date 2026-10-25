// swift-tools-version: 6.0
import PackageDescription

// MizarKit — the DSH-Mizar protocol layer.
//
// Built as a Swift package rather than straight into the app target for one
// practical reason: `swift test` runs on the host computer in about a second, while
// anything requiring a simulator round-trip costs far more per iteration. The
// app project consumes this as a local package.
//
// The macOS platform is declared so the test suite can run on the host; nothing
// here is iOS-only.
let package = Package(
    name: "MizarKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "MizarKit", targets: ["MizarKit"]),
        // The cross-language probe: a tiny CLI the TypeScript suite starts to
        // prove the two implementations can actually connect, not just agree
        // on bytes. An executable product so `swift build --product` can
        // select it without building the app's world.
        .executable(name: "mizar-net-probe", targets: ["MizarNetProbe"]),
    ],
    targets: [
        .target(
            name: "MizarKit",
            swiftSettings: [
                // Swift 6 language mode: data-race safety is checked at compile
                // time rather than discovered in the field.
                .swiftLanguageMode(.v6),
            ],
        ),
        // The NAT matrix lab: a userspace NAT simulator, an observing STUN
        // responder, and the matrix runner. A separate target outside
        // `Sources/` on purpose: the app's synchronized group points at
        // `Sources/MizarKit` and must never compile this, and a reader
        // should see at a glance that it is harness, not product.
        .target(
            name: "MizarNetNATLab",
            dependencies: ["MizarKit"],
            path: "Lab/MizarNetNATLab",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        // Built only on MizarKit's public surface: if this needed internals,
        // the engine would not be usable from another module.
        .executableTarget(
            name: "MizarNetProbe",
            dependencies: ["MizarKit"],
            path: "Probe",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
        .testTarget(
            name: "MizarKitTests",
            dependencies: ["MizarKit", "MizarNetNATLab"],
            // No bundled resources: the golden frames live at
            // `protocol/fixtures/` in the repository and are read from there via
            // `#filePath`. Copying them into the test bundle would create a
            // second copy that can drift from the one the TypeScript side reads,
            // which is precisely what the fixtures exist to prevent.
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
        ),
    ],
)
