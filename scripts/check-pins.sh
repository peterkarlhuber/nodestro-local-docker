#!/usr/bin/env bash
# Check components.json: full SHAs, both commits on their repository's master, and the studio commit's own pins agree
# (its scripts/check_versions.py: pyproject, platform/versions.json and every component pin), and the Ollama image is
# the release Orkexa installs.
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

# The Ollama image (compose.yaml, services ollama and models-init, by tag and digest) must be one reference and the
# release Orkexa installs, OLLAMA_VERSION in orkexa/local/install.py at the studio's pinned Orkexa commit (the desktop
# app checks the same pin when it builds).
image="$(sed -n 's|^ *image: \(docker\.io/ollama/.*\)$|\1|p' "$root/compose.yaml" | sort -u)"
[ "$(grep -c 'image: docker\.io/ollama/' "$root/compose.yaml")" = 2 ] && [ "$(printf '%s\n' "$image" | wc -l)" = 1 ] \
  || { echo "compose.yaml: ollama and models-init must use the same Ollama image" >&2; exit 1; }
[[ "$image" =~ ^docker\.io/ollama/ollama:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$ ]] \
  || { echo "compose.yaml: the Ollama image is not ollama/ollama:<version>@sha256:<digest>: $image" >&2; exit 1; }
image_version="${BASH_REMATCH[1]}"
orkexa="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["orkexa"]["commit"])' \
  "$work/nodestro-studio/platform/versions.json")"
"$root/scripts/fetch.sh" orkexa "$orkexa" "$work/orkexa"
orkexa_version="$(sed -n 's/^OLLAMA_VERSION = "\(.*\)"$/\1/p' "$work/orkexa/src/orkexa/local/install.py")"
[ -n "$orkexa_version" ] || { echo "orkexa $orkexa names no OLLAMA_VERSION" >&2; exit 1; }
[ "$image_version" = "$orkexa_version" ] \
  || { echo "compose.yaml runs Ollama $image_version, orkexa $orkexa installs $orkexa_version: update one" >&2; exit 1; }
echo "Ollama $image_version: compose.yaml and orkexa $orkexa agree"
