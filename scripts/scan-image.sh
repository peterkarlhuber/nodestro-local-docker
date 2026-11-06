#!/usr/bin/env bash
# Secret scan of a saved image (every layer) with nodestro-server's scan_secrets.py at the pinned server commit, then
# its vulnerability scan (scripts/scan-vulnerabilities.sh of the same commit: pip-audit and Trivy; needs pip-audit) when
# that commit has one. NODESTRO_SCAN_SECRETS may list exact values that must not appear (e.g. the token a build used).
# REPORT_DIR receives the vulnerability reports.
#   scripts/scan-image.sh IMAGE [REPORT_DIR]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
server="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-server"])' "$root/components.json")"
"$root/scripts/fetch.sh" nodestro-server "$server" "$work/server"
docker save -o "$work/image.tar" "$1"
allow=()
if [ -f "$work/server/scripts/scan-allow.txt" ]; then allow=(--allow "$work/server/scripts/scan-allow.txt"); fi
python3 -I "$work/server/scripts/scan_secrets.py" "${allow[@]}" "$work/image.tar" "$root"
if [ -x "$work/server/scripts/scan-vulnerabilities.sh" ]; then
  "$work/server/scripts/scan-vulnerabilities.sh" "$1" "${2:-$work/vulnerabilities}"
else
  echo "nodestro-server $server has no scripts/scan-vulnerabilities.sh: vulnerability scan skipped (pin a newer server)"
fi
