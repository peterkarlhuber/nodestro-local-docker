#!/usr/bin/env bash
# Build the Nodestro Local Docker image from components.json: the shared image definition of nodestro-server (target
# `local`) at its pinned commit, with the nodestro-studio commit that pins every component by full SHA.
#
#   scripts/build-image.sh [TAG]            (default: nodestro-local:<studio>-<server>, also tagged nodestro-local:dev)
#
# No token is needed: the Nodestro and Orkexa repositories are public. Options (environment):
#   NODESTRO_PLATFORM       e.g. linux/arm64 (default: the Docker host's platform)
#   NODESTRO_EXTRA_CA_FILE  certificate bundle of a TLS-inspecting proxy (BuildKit secret `build_ca`, never a layer)
#   NODESTRO_BUILD_NETWORK  build network, e.g. host
#   NODESTRO_READ           optional read token (BuildKit secret, never a layer) if the repositories become private
#   NODESTRO_OVERRIDES      development only: a folder of wheels that replace pinned components (tag must end in -dev)
#   NODESTRO_SERVER_SOURCE  development only: a local nodestro-server checkout instead of the pinned commit
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
read_pin() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$root/components.json" "$1"; }
studio="$(read_pin nodestro-studio)"
server="$(read_pin nodestro-server)"
for sha in "$studio" "$server"; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "components.json must name full commit SHAs" >&2; exit 1; }
done
tag="${1:-nodestro-local:${studio:0:12}-${server:0:12}}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ -n "${NODESTRO_SERVER_SOURCE:-}" ]; then
  [[ "$tag" == *-dev || "$tag" == *:dev ]] || { echo "a build from a local server checkout must have a dev tag" >&2; exit 1; }
  context="$NODESTRO_SERVER_SOURCE"
else
  git -C "$work" init -q server
  git -C "$work/server" remote add origin https://github.com/peterkarlhuber/nodestro-server.git
  git -C "$work/server" fetch -q --depth 1 origin "$server"
  git -C "$work/server" checkout -q FETCH_HEAD
  [ "$(git -C "$work/server" rev-parse HEAD)" = "$server" ] || { echo "fetched the wrong server commit" >&2; exit 1; }
  context="$work/server"
fi

args=(--file "$context/image/Dockerfile" --target local --build-arg "STUDIO_COMMIT=$studio" --tag "$tag" --load)
args+=(--label "org.opencontainers.image.title=Nodestro Local Docker")
args+=(--label "org.opencontainers.image.source=https://github.com/peterkarlhuber/nodestro-local-docker")
args+=(--label "org.opencontainers.image.revision=$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)")
args+=(--label "dev.nodestro.studio-commit=$studio" --label "dev.nodestro.server-commit=$server")
args+=(--label "dev.nodestro.channel=preview" --label "dev.nodestro.signing=unsigned")
if [ -n "${NODESTRO_PLATFORM:-}" ]; then args+=(--platform "$NODESTRO_PLATFORM"); fi
if [ -n "${NODESTRO_READ:-}" ]; then args+=(--secret "id=nodestro_read,env=NODESTRO_READ"); fi
if [ -n "${NODESTRO_EXTRA_CA_FILE:-}" ]; then args+=(--secret "id=build_ca,src=$NODESTRO_EXTRA_CA_FILE"); fi
if [ -n "${NODESTRO_BUILD_NETWORK:-}" ]; then args+=(--network "$NODESTRO_BUILD_NETWORK"); fi
for name in HTTPS_PROXY NO_PROXY; do
  if [ -n "${!name:-}" ]; then args+=(--build-arg "$name=${!name}"); fi
done
if [ -n "${NODESTRO_OVERRIDES:-}" ]; then
  [[ "$tag" == *-dev || "$tag" == *:dev ]] || { echo "an image with overrides must have a dev tag" >&2; exit 1; }
  args+=(--build-context "overrides=$NODESTRO_OVERRIDES")
fi
docker buildx build "${args[@]}" "$context"
if [ "$tag" != "nodestro-local:dev" ] && [ -z "${NODESTRO_PLATFORM:-}" ]; then docker tag "$tag" nodestro-local:dev; fi
echo "$tag"
