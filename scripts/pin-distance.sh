#!/usr/bin/env bash
# Warn when components.json lags behind nodestro-studio or nodestro-server master (backend audit D-01, OPS3-06), with
# nodestro-server's scripts/pin_distance.py at the pinned server commit (the same check as in nodestro-server and
# nodestro-desktop): a `::warning::` per lagging pin, exit 0; exit 2 when a pin cannot be checked. CI runs it as a
# non-blocking step.
#   scripts/pin-distance.sh [--grace-days DAYS]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
server="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-server"])' "$root/components.json")"
"$root/scripts/fetch.sh" nodestro-server "$server" "$work/server"
if [ ! -f "$work/server/scripts/pin_distance.py" ]; then
  echo "nodestro-server $server has no scripts/pin_distance.py: pin distance not checked (pin a newer server)"
  exit 0
fi
python3 -I "$work/server/scripts/pin_distance.py" "$root/components.json" "$@"
