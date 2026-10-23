#!/usr/bin/env bash
# Build the Rig/Rust static libraries and the generated UniFFI bindings.
#
# FoodCore consumes RigPoc.xcframework (iOS device, iOS simulator, macOS) plus the
# generated `rig_pocFFI` header/modulemap and Swift wrapper. All of those outputs are
# gitignored, so this script must run before any Swift build of FoodCore.
set -euo pipefail

CORE="$(cd "$(dirname "$0")/.." && pwd)"
RIG="$CORE/../Rig"
GEN="$CORE/.rig-build/generated"
HEADERS="$CORE/.rig-build/headers"
INCLUDE="$CORE/Sources/rig_pocFFI/include"
KIT="$CORE/Sources/RigPocKit"
VENDOR="$CORE/Vendor"
EMPTY_C="$CORE/Sources/rig_pocFFI/empty.c"

TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
  aarch64-apple-darwin
  x86_64-apple-darwin
)

mkdir -p "$GEN" "$HEADERS" "$INCLUDE" "$KIT" "$VENDOR" "$(dirname "$EMPTY_C")"
# SwiftPM needs at least one source file in the C target that provides the headers.
: > "$EMPTY_C"

cd "$RIG"
rustup target add "${TARGETS[@]}"

# Host build provides the dylib UniFFI reads to generate bindings.
cargo build --release
cargo run --release --bin uniffi-bindgen -- generate \
  --library "target/release/librig_poc.dylib" \
  --language swift \
  --out-dir "$GEN"

cp "$GEN/rig_poc.swift" "$KIT/"
cp "$GEN/rig_pocFFI.h" "$INCLUDE/"
cp "$GEN/rig_pocFFI.modulemap" "$INCLUDE/module.modulemap"

# The XCFramework headers deliberately omit the module map: SwiftPM gets the
# `rig_pocFFI` module from the C target above, and the binary target only links symbols.
cp "$GEN/rig_pocFFI.h" "$HEADERS/"

for target in "${TARGETS[@]}"; do
  case "$target" in
    *apple-ios*)
      IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --target "$target"
      ;;
    *apple-darwin)
      MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --target "$target"
      ;;
    *)
      cargo build --release --target "$target"
      ;;
  esac
done

lipo -create \
  "target/aarch64-apple-ios-sim/release/librig_poc.a" \
  "target/x86_64-apple-ios/release/librig_poc.a" \
  -output "$GEN/librig_poc_ios_sim.a"
lipo -create \
  "target/aarch64-apple-darwin/release/librig_poc.a" \
  "target/x86_64-apple-darwin/release/librig_poc.a" \
  -output "$GEN/librig_poc_macos.a"

rm -rf "$VENDOR/RigPoc.xcframework"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/librig_poc.a" -headers "$HEADERS" \
  -library "$GEN/librig_poc_ios_sim.a" -headers "$HEADERS" \
  -library "$GEN/librig_poc_macos.a" -headers "$HEADERS" \
  -output "$VENDOR/RigPoc.xcframework"

echo "built $VENDOR/RigPoc.xcframework"
