{
  description = "GiroCrab dev shell: pinned Rust toolchain (+ Apple targets) for building the Rust core and the SwiftUI app.";

  # Xcode itself (Swift toolchain, xcodebuild, iconutil, codesign, xcrun
  # xcstringstool, ditto, install_name_tool, the macOS/iOS SDKs) cannot be
  # provided by Nix for licensing reasons and must already be installed on
  # the Mac (App Store or developer.apple.com, Xcode 15+). This flake only
  # covers the Rust side: the exact toolchain + targets `build-xcframework.sh`
  # needs, and the native build tools the dependency tree needs to compile
  # the vendored SQLCipher/OpenSSL and AWS-LC (rustls' default crypto
  # backend) from source. See docs/nix.md.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachSystem
      [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

          # Everything `./build-xcframework.sh` ever builds for: macOS
          # (arm64 + Intel) and iOS (device + simulator, both arm64 since
          # the simulator target only exists for Apple Silicon hosts).
          # `cargo run -- --demo-seed` / plain `cargo build` only need
          # the host's own aarch64/x86_64-apple-darwin slice (they pass
          # --macos-only); the iOS slices only matter for the full
          # `./build-xcframework.sh` or the Xcode iOS project.
          appleTargets = [
            "aarch64-apple-darwin"
            "x86_64-apple-darwin"
            "aarch64-apple-ios"
            "aarch64-apple-ios-sim"
          ];

          # Floating "stable", like CI's `dtolnay/rust-toolchain@stable` –
          # girocrab-core pins no specific Rust version either (flake.lock
          # fixes the exact release until the next `nix flake update`).
          rustOverlayToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [
              "rust-src"
              "rustfmt"
              "clippy"
            ];
            targets = if isDarwin then appleTargets else [ ];
          };

          # On macOS rust-overlay's toolchain propagates Nixpkgs' clang
          # wrapper (+ its Apple SDK setup hook), which would put a Nix `cc`
          # first in PATH and export CC/NIX_CC/DEVELOPER_DIR – shadowing
          # Xcode's toolchain that build-xcframework.sh, `swift build` and
          # xcodebuild rely on. Re-wrap it without nix-support so rustc links
          # with Xcode's /usr/bin/cc, exactly like a rustup install.
          rustToolchain =
            if isDarwin then
              pkgs.symlinkJoin {
                name = "rust-toolchain-xcode";
                paths = [ rustOverlayToolchain ];
                postBuild = "rm -rf $out/nix-support";
              }
            else
              rustOverlayToolchain;
        in
        {
          # mkShellNoCC, not mkShell: on macOS mkShell's stdenv brings a
          # Nix clang wrapper as `cc` plus its own Apple SDK stub and exports
          # DEVELOPER_DIR/SDKROOT/NIX_LDFLAGS pointing there. The root
          # build.rs runs ./build-xcframework.sh with a cleared environment
          # (keeping PATH and DEVELOPER_DIR only), so the nested cargo then
          # links with that wrapper against the stub SDK without the Nix
          # flags and fails with "ld: library not found for -liconv". With
          # mkShellNoCC, cc/clang/ld/xcrun/swift all come from Xcode.
          devShells.default = pkgs.mkShellNoCC {
            name = "girocrab";

            packages = [
              rustToolchain
              pkgs.rust-analyzer
              pkgs.pkg-config
              # `rusqlite`'s bundled-sqlcipher-vendored-openssl feature
              # compiles its own SQLCipher + OpenSSL from source (Perl's
              # Configure + make); rustls 0.23's default crypto backend
              # (aws-lc-rs -> aws-lc-sys) additionally needs CMake and Go
              # (and NASM on x86_64) to build AWS-LC. None of this is
              # optional: it's the real dependency tree in Cargo.lock, not
              # an alternate feature.
              pkgs.perl
              pkgs.cmake
              pkgs.go
              pkgs.nasm
            ]
            ++ pkgs.lib.optionals (!isDarwin) [
              # On macOS the C/C++ compiler, linker and SDKs come from
              # Xcode (see rustToolchain above); on Linux Nix has to
              # supply a toolchain itself – only girocrab-core (the Rust
              # core without the SwiftUI app) builds there, see docs/nix.md.
              pkgs.gcc
            ];

            shellHook =
              if isDarwin then
                ''
                  if ! xcode-select -p >/dev/null 2>&1; then
                    echo "warning: no Xcode found (xcode-select -p fails)." >&2
                    echo "         The SwiftUI app (swift build / xcodebuild) needs Xcode 15+" >&2
                    echo "         (App Store or developer.apple.com); the Command Line Tools alone" >&2
                    echo "         are NOT enough, even though 'xcode-select --install' offers them." >&2
                  fi
                  # Never point the Apple toolchain at a Nix SDK: Xcode's
                  # xcrun/clang pick the right SDK per target (macOS, iOS,
                  # iOS simulator) themselves.
                  unset DEVELOPER_DIR SDKROOT
                ''
              else
                ''
                  echo "note: Linux shell: only girocrab-core builds and tests here" >&2
                  echo "      (cargo check -p girocrab-core / cargo test -p girocrab-core)." >&2
                  echo "      The full GiroCrab app (SwiftUI) needs macOS 14+ and Xcode 15+." >&2
                '';
          };
        }
      );
}
