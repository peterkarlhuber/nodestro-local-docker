#!/usr/bin/env bash
# Check components.json: full SHAs, both commits on their repository's master, and the studio commit's own pins agree
# (its scripts/check_versions.py: pyproject, platform/versions.json and every component pin).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pin() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$root/components.json" "$1"; }
for repo in nodestro-studio nodestro-server; do
  sha="$(pin "$repo")"
  git init -q "$work/$repo"
  git -C "$work/$repo" remote add origin "https://github.com/peterkarlhuber/$repo.git"
  git -C "$work/$repo" fetch -q --filter=blob:none origin master
  git -C "$work/$repo" merge-base --is-ancestor "$sha" origin/master \
    || { echo "$repo $sha is not on master" >&2; exit 1; }
  echo "$repo $sha is on master"
done
git -C "$work/nodestro-studio" checkout -q "$(pin nodestro-studio)"
(cd "$work/nodestro-studio" && python3 -I scripts/check_versions.py)
