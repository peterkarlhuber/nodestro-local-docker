#!/usr/bin/env bash
# Fetch one public Nodestro repository at a full commit SHA into DIR (no token, no history).
#   scripts/fetch.sh REPOSITORY SHA DIR
set -euo pipefail
repo=$1 sha=$2 dir=$3
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "not a full commit SHA: $sha" >&2; exit 1; }
git init -q "$dir"
git -C "$dir" remote add origin "https://github.com/peterkarlhuber/$repo.git"
git -C "$dir" fetch -q --depth 1 origin "$sha"
git -C "$dir" checkout -q FETCH_HEAD
[ "$(git -C "$dir" rev-parse HEAD)" = "$sha" ] || { echo "fetched the wrong commit of $repo" >&2; exit 1; }
