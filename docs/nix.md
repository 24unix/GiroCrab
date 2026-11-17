# Nix development shell (opt-in)

`flake.nix` provides the Rust toolchain (+ Apple targets) and the native build tools that
`girocrab-core` and `./build-xcframework.sh` need. It is entirely optional: CI, `build.rs`,
`build-xcframework.sh` and the usual rustup setup do not use it, and nothing changes for anyone who
does not run `nix develop`.

**Xcode is not part of the flake.** Nix cannot ship it (license terms, no Nix package), and it does
not need to: `swift build`, `xcodebuild`, `codesign`, `iconutil`, `xcrun xcstringstool`, `ditto` and
the macOS/iOS SDKs keep coming from a regular Xcode install.

## Requirements

1. **macOS 14+ with Xcode 15+** (App Store or developer.apple.com). The Command Line Tools alone are
   not enough; the full Xcode app must be installed and selected with `xcode-select -s`.
2. **[Nix](https://nixos.org/download) with flakes enabled** (`experimental-features = nix-command
   flakes` in `~/.config/nix/nix.conf` or `/etc/nix/nix.conf`).

## Usage

```bash
nix develop            # opens the dev shell with Rust + build tools
```

Optional, with [direnv](https://direnv.net): `.envrc` is deliberately **not** checked in (it is
listed in `.gitignore`), so direnv users without Nix never see an error. To load the shell
automatically when entering the project folder, create it once yourself:

```bash
echo 'use flake' > .envrc
direnv allow
```

Inside the shell, everything works as described in README/CONTRIBUTING:

```bash
./build-xcframework.sh          # Rust core + Swift bindings
cargo run -- --demo-seed        # full app with demo data
cargo test -q -p girocrab-core  # Rust tests
```

## What the flake provides

- The `stable` Rust toolchain (like CI's `dtolnay/rust-toolchain@stable`; the repo has no
  `rust-toolchain.toml`) with `rustfmt`, `clippy` and, on macOS, the Apple targets
  `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios` and `aarch64-apple-ios-sim`.
  `build-xcframework.sh` runs `rustup target add` only when `rustup` is on `PATH`; with the Nix
  toolchain it skips that step because the targets are already installed.
- `pkg-config`, `perl`, `cmake`, `go` and `nasm`. These are **required**, not optional:
  `rusqlite` builds SQLCipher/OpenSSL from vendored sources (Perl), and rustls 0.23 uses
  `aws-lc-rs`/`aws-lc-sys` as its default crypto backend, whose build needs CMake, Go and (on
  x86_64) NASM.
- On macOS, deliberately **no** C compiler and **no** Apple SDK of its own: the shell uses
  `mkShellNoCC`, and the Rust toolchain is included without the Nixpkgs clang wrapper that
  rust-overlay would otherwise propagate. `cc`, `clang`, `xcrun`, `swift` and the SDKs therefore come
  from Xcode, just like with a rustup install, and the shell sets neither `CC`, `DEVELOPER_DIR` nor
  `SDKROOT`. Background: the root `build.rs` runs `./build-xcframework.sh` with a cleared
  environment (keeping `PATH`, `DEVELOPER_DIR` and a few others). If those pointed at a Nix SDK,
  linking would fail with "ld: library not found for -liconv".
- `rust-analyzer` for editors/IDEs.
- On Linux additionally `gcc`, since there is no Xcode compiler there.

## Limitations

- **Only macOS builds the full app.** On Linux (also in this shell) only `girocrab-core` builds and
  tests on its own (`cargo check -p girocrab-core`, `cargo test -p girocrab-core`); the root
  package's `build.rs` skips the SwiftUI part whenever the target OS is not `macos`.
- **Versions:** `flake.lock` pins nixpkgs and rust-overlay and with them the exact Rust release.
  Update with `nix flake update` and commit the new `flake.lock`.
- **Maintenance:** the flake is maintained on a best-effort basis.

## Troubleshooting

- If `xcrun` or the linker reports missing SDKs or frameworks, `xcode-select` usually points at the
  Command Line Tools instead of the full Xcode install:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- After changing `flake.nix`, run `direnv reload` once (when using direnv) so no stale environment
  (e.g. a leftover `CC` or `DEVELOPER_DIR`) stays cached.
