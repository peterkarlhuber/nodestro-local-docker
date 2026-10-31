#!/usr/bin/env bash
# Secret scan of a saved image (every layer) with nodestro-server's scan_secrets.py at the pinned server commit.
# NODESTRO_SCAN_SECRETS may list exact values that must not appear (e.g. the token a build used).
#   scripts/scan-image.sh IMAGE
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
server="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-server"])' "$root/components.json")"
"$root/scripts/fetch.sh" nodestro-server "$server" "$work/server"
docker save -o "$work/image.tar" "$1"
allow=()
if [ -f "$work/server/scripts/scan-allow.txt" ]; then allow=(--allow "$work/server/scripts/scan-allow.txt"); fi
python3 -I "$work/server/scripts/scan_secrets.py" "${allow[@]}" "$work/image.tar" "$root"
