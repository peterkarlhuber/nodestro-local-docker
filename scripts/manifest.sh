#!/usr/bin/env bash
# Image manifest and license inventory of a Nodestro Local Docker image, written by nodestro-server's
# release_manifest.py (at the pinned server commit) from inside the image: components and their commits, the Python
# distributions it contains, the npm packages of the studio interface, image ID, platform, unsigned/preview state.
#   scripts/manifest.sh IMAGE OUT_DIR [PLATFORM, default linux-amd64]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
image=$1 out=$2 platform=${3:-linux-amd64}
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
server="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["nodestro-server"])' "$root/components.json")"
"$root/scripts/fetch.sh" nodestro-server "$server" "$work/server"
mkdir -p "$out"; chmod 0777 "$out"
id="$(docker image inspect --format '{{.Id}}' "$image")"
docker run --rm --network none --read-only --user 10001:10001 \
  -v "$work/server/scripts/release_manifest.py:/release/release_manifest.py:ro" -v "$(cd "$out" && pwd):/out" \
  --entrypoint /opt/nodestro/venv/bin/python "$image" -I /release/release_manifest.py \
  --product nodestro-local-docker --version "dev-$(git -C "$root" rev-parse --short=12 HEAD)" --out /out \
  --studio-meta /opt/nodestro/meta --commit "$(git -C "$root" rev-parse HEAD)" --python /opt/nodestro/venv/bin/python \
  --platform "$platform" --image "nodestro-local@$id"
echo "$out/release-manifest.json"
