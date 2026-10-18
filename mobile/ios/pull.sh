#!/usr/bin/env bash
# Pull the session.json the app wrote out of the simulator and validate it with the same
# loader the pipeline uses. Run it after tapping Capture in the app.
#
#   ./pull.sh                       # -> mobile-session.json next to this script
#   ./pull.sh <UDID> <out-path>     # explicit device + destination
#
# To install it straight into the pipeline:
#   cp mobile-session.json ../data/session.json   (or use `food auth --session <file>`)
set -euo pipefail
cd "$(dirname "$0")"

UDID="${1:-$(xcrun simctl list devices booted -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next(x["udid"] for v in d.values() for x in v))')}"
OUT="${2:-mobile-session.json}"
CONTAINER="$(xcrun simctl get_app_container "$UDID" ai.commandcode.food.capture data)"
SRC="$CONTAINER/tmp/session.json"

if [ ! -f "$SRC" ]; then
    echo "no session captured yet — tap Capture in the app first" >&2
    exit 1
fi

cp "$SRC" "$OUT"
python3 - "$OUT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cookies = sum(len(v) for v in d.get("cookies", {}).values())
print(f"imported {sys.argv[1]}: {cookies} cookies across {list(d.get('cookies', {}))}, tokens: {list(d.get('tokens', {}))}")
PY
