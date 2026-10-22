#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Python =="
uv run pytest -q

echo "== Swift =="
(cd mobile/ios/FoodCore && swift test)
