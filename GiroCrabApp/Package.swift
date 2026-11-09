// swift-tools-version:5.10
// GiroCrab – SwiftUI multiplatform front end (macOS 14+, iOS 17+).
//
// Run ./build-xcframework.sh first: it produces ../generated/GiroCrabCorePackage
// (the Rust core + UniFFI Swift bindings).
//
//  * GiroCrabUI  – all views, the app model and VaultKeyManager (shared by
//                  macOS and iOS; used by the Xcode project in Xcode/).
//  * GiroCrabMac – a plain macOS executable for `swift run` / `cargo run`
//                  (supports --demo-seed and --screenshot <file.png>).
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
    ],
    targets: [
        .target(
            name: "GiroCrabUI",
            dependencies: [.product(name: "GiroCrabCore", package: "GiroCrabCorePackage")],
            path: "Sources/GiroCrabUI"
        ),
        .executableTarget(
            name: "GiroCrabMac",
            dependencies: ["GiroCrabUI"],
            path: "Sources/GiroCrabMac"
        ),
    ]
)
