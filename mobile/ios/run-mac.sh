#!/usr/bin/env bash
# Build and launch the native macOS app locally.
#
#   ./run-mac.sh
set -euo pipefail
cd "$(dirname "$0")"

./FoodCore/scripts/build-rig.sh
xcodegen generate >/dev/null
xcodebuild -project FoodCapture.xcodeproj -scheme FoodCaptureMac -sdk macosx \
    -destination 'platform=macOS' -derivedDataPath build-mac \
    CODE_SIGNING_ALLOWED=NO build | tail -1

open build-mac/Build/Products/Debug/FoodCaptureMac.app
echo "launched FoodCaptureMac"
