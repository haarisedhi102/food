#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST="$ROOT/../../mobile/ios/Rig"
SWIFT="$ROOT/swift"

cd "$RUST"
cargo build --release

mkdir -p "$SWIFT/artifacts" "$SWIFT/generated" \
  "$SWIFT/Sources/rig_pocFFI/include" "$SWIFT/Sources/RigPoCKit"
cp "$RUST/target/release/librig_poc.dylib" "$SWIFT/artifacts/"

cargo run --bin uniffi-bindgen -- generate \
  --library "$RUST/target/release/librig_poc.dylib" \
  --language swift \
  --out-dir "$SWIFT/generated"

cp "$SWIFT/generated/rig_pocFFI.h" "$SWIFT/Sources/rig_pocFFI/include/"
cp "$SWIFT/generated/rig_poc.swift" "$SWIFT/Sources/RigPoCKit/"

cd "$SWIFT"
swift build
