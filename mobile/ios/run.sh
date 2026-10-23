#!/usr/bin/env bash
# Build, install and launch the FoodCapture POC on a booted iOS simulator.
#
#   ./run.sh                 # first booted simulator
#   ./run.sh <UDID>          # a specific one (xcrun simctl list devices)
set -euo pipefail
cd "$(dirname "$0")"

UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for v in d.values() for x in v))')}"

./FoodCore/scripts/build-rig.sh
xcodegen generate >/dev/null
xcodebuild -project FoodCapture.xcodeproj -scheme FoodCapture -sdk iphonesimulator \
    -destination "id=$UDID" -derivedDataPath build build | tail -1

xcrun simctl install "$UDID" build/Build/Products/Debug-iphonesimulator/FoodCapture.app
xcrun simctl launch "$UDID" ai.commandcode.food.capture
echo "launched on $UDID — log in, then tap Capture"
