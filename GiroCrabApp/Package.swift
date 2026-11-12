// swift-tools-version:5.10
// GiroCrab – SwiftUI multiplatform front end (macOS 14+, iOS 17+).
//
// Run ./build-xcframework.sh first: it produces ../generated/GiroCrabCorePackage
// (the Rust core + UniFFI Swift bindings).
//
//  * GiroCrabUI  – all views, the app model and VaultKeyManager (shared by
//                  macOS and iOS; used by the Xcode project in Xcode/).
//  * GiroCrabMac – a plain macOS executable for `swift run` / `cargo run`
//                  and the release bundle (package-macos-app.sh; hosts the
//                  Sparkle updater, see GiroCrabMac/Updater.swift)
//                  (supports --demo-seed and --screenshot <file.png>).
//  * GiroCrabUITests – AppModel tests on the demo vault (macOS + iOS).
import PackageDescription

let package = Package(
    name: "GiroCrabApp",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GiroCrabUI", targets: ["GiroCrabUI"]),
        .executable(name: "GiroCrabMac", targets: ["GiroCrabMac"]),
    ],
    dependencies: [
        .package(name: "GiroCrabCorePackage", path: "../generated/GiroCrabCorePackage"),
        // Auto-update of the macOS release bundle (EdDSA-signed appcast,
        // stable GitHub releases only). Linked into GiroCrabMac only.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "GiroCrabUI",
            dependencies: [.product(name: "GiroCrabCore", package: "GiroCrabCorePackage")],
            path: "Sources/GiroCrabUI"
        ),
        .executableTarget(
            name: "GiroCrabMac",
            dependencies: [
                "GiroCrabUI",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/GiroCrabMac"
        ),
        // App-model tests on the demo vault; run on macOS (`swift test`) and
        // the iOS Simulator (`xcodebuild test -scheme GiroCrabApp-Package`).
        .testTarget(
            name: "GiroCrabUITests",
            dependencies: ["GiroCrabUI"],
            path: "Tests/GiroCrabUITests"
        ),
    ]
)
