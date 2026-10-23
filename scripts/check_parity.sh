#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Python =="
uv run pytest -q

echo "== Swift =="
bash mobile/ios/FoodCore/scripts/build-rig.sh
(cd mobile/ios/FoodCore && swift test)
