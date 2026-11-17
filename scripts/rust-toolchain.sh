# Sourced by build-xcframework.sh and package-macos-app.sh (not run on its own):
# the Rust toolchain, Mac target and deployment target, so the core library and
# the MCP helper shipped next to it are built the same way.
#   sets CARGO, MAC_TARGET; exports RUSTC, RUSTDOC, MACOSX_DEPLOYMENT_TARGET

export PATH="$HOME/.cargo/bin:$PATH"
CARGO="${CARGO:-}"

# Homebrew can install standalone Rust alongside rustup. Targets added by
# rustup belong to its toolchain, not Homebrew's rustc. Select the compiler
# explicitly too: merely choosing rustup's cargo still finds rustc via PATH.
if command -v rustup >/dev/null 2>&1; then
  if RUSTUP_CARGO="$(rustup which cargo 2>/dev/null)" && \
     RUSTUP_RUSTC="$(rustup which rustc 2>/dev/null)"; then
    CARGO="${CARGO:-$RUSTUP_CARGO}"
    export RUSTC="${RUSTC:-$RUSTUP_RUSTC}"
    if RUSTUP_RUSTDOC="$(rustup which rustdoc 2>/dev/null)"; then
      export RUSTDOC="${RUSTDOC:-$RUSTUP_RUSTDOC}"
    fi
  fi
fi

CARGO="${CARGO:-cargo}"

export MACOSX_DEPLOYMENT_TARGET=14.0

if [[ "$(uname -m)" == "x86_64" ]]; then
  MAC_TARGET="x86_64-apple-darwin"
else
  MAC_TARGET="aarch64-apple-darwin"
fi
