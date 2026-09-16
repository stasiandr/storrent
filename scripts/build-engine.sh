#!/bin/sh
# Builds the Rust engine as a static library and generates its Swift bindings
# into Sources/ (both generated parts are gitignored).
set -eu
cd "$(dirname "$0")/.."

# Non-interactive shells don't read ~/.zshrc, where rustup's PATH lives.
for dir in /opt/homebrew/opt/rustup/bin "$HOME/.cargo/bin"; do
    [ -d "$dir" ] && PATH="$dir:$PATH"
done

PROFILE="${1:-release}"
# Match Package.swift's platform, otherwise C deps are built for the host OS version.
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --manifest-path engine/Cargo.toml --profile "$PROFILE" --lib
LIB="engine/target/$PROFILE/libstorrent_engine.dylib"

GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
# Library mode reads crate metadata via `cargo metadata`, so run it from the crate.
(cd engine && cargo run --quiet --release --bin uniffi-bindgen -- \
    generate --library "../$LIB" --language swift --out-dir "$GEN")

mkdir -p Sources/StorrentEngine/Generated
cp "$GEN/storrent_engine.swift" Sources/StorrentEngine/Generated/
cp "$GEN/storrent_engineFFI.h" Sources/storrent_engineFFI/
