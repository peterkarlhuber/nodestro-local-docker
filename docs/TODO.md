# TODO: nodestro-local-docker

> Open work for this repository: release blockers, known bugs, security follow-ups, technical debt and planned improvements.
> GitHub issues are the source of truth for details; this file is the entry point and summary.
>
> **Last full review:** 2026-11-05 against `master` at `f2a0393` (quality round 3 close-out; TODO consolidated).

## Summary

| Priority | Count |
|---|---|
| P0 Critical | 0 |
| P1 High | 1 |
| P2 Medium | 3 |
| P3 Low | 9 |
| P4 Optional | 3 |

**Release blockers:** None for this repository, because no Local Docker release is planned; no entry here blocks
the next planned preview (the desktop candidate, nodestro-desktop DSK-001). Before any Local Docker release, LD-001
(independent security review) and LD-002 (Docker Desktop tests) must be closed.

Nodestro Local Docker works and is tested on Linux amd64, Linux arm64 and rootless Docker (CI end-to-end tests). The
open work is external review, untested Docker Desktop platforms, published images and small hardening and docs items.

## Priorities and statuses

- **P0 Critical**: data loss, security exposure, or broken core function; blocks any release.
- **P1 High**: blocks a planned release or a promised capability, or a significant risk.
- **P2 Medium**: real defect or gap with a workaround; schedule soon.
- **P3 Low**: minor defect, polish, or small debt.
- **P4 Optional**: improvement idea; not a defect.

Statuses: `Open`, `In progress` (PR linked), `Blocked` (names the blocker), `Needs decision` (owner decision pending),
`Needs external review`, `Accepted risk` (deliberately not fixed; reason stated).

## Release blockers and critical items

None known for a planned release (see the summary).

## Security

### LD-001 · Independent security review of the sandbox gateway and local access control

- **Priority:** P1 High · **Status:** Needs external review · **Refs:** `docs/SECURITY-REVIEW.md`
- **What:** The review package exists and an internal defensive cross-check with follow-up fixes is documented
  (sections 9 and 9.6), but the independent review is still open. The gateway is the security boundary between the
  studio and the host's Docker daemon.
- **Next step:** Have a qualified reviewer work through `docs/SECURITY-REVIEW.md` (including section 9.6); route any
  findings privately. The gateway code lives in nodestro-runtime.
- **Depends on:** nodestro-runtime (`sandbox_gateway.py`)

### LD-019 · Offline mode is an Ollama setting, not a network boundary

- **Priority:** P3 Low · **Status:** Needs decision · **Refs:** internal backend audit 2026-11-04 (OPS3-02),
  docs/SECURITY.md
- **What:** Since 2026-11-04 Ollama shares the studio's network namespace and listens on loopback only, so host
  processes can no longer reach its unauthenticated API. In exchange, `NODESTRO_LOCAL_MODELS=offline` stops Ollama's
  downloads with a closed proxy port instead of an internal-only network.
- **Next step:** Decide whether air-gapped installs need a network boundary again (internal-only Ollama behind an
  authenticating proxy).

## Bugs and reliability

None known.

## Architecture and modularity

None known. (There is no Nodestro logic here by design; see `docs/ARCHITECTURE.md`.)

## Performance

None known.

## Features and enhancements

### LD-003 · Published images

- **Priority:** P2 Medium · **Status:** Needs decision · **Refs:** README "Known limitations"
- **What:** There are no published images, so the first start builds from source: several minutes, git required,
  and on Windows also `bash` (Git for Windows or WSL). Publishing images is not approved.
- **Next step:** Owner decides on publishing (registry, signing, channel); then add a publish workflow like
  nodestro-server's and let the launcher pull by digest.

### LD-007 · Proxy settings for the studio container

- **Priority:** P3 Low · **Status:** Open · **Refs:** `compose.yaml`, `compose.extra-ca.yaml`, Bedrock deployment analysis section 3
- **What:** `HTTPS_PROXY`/`NO_PROXY` are not passed to the `nodestro` and `ollama` services, so model providers and
  Ollama model downloads behind a mandatory proxy work only with a hand-written `compose.override.yaml` (`NO_PROXY`
  must then contain `ollama`). The CA overlay exists already and covers `ollama` too.
- **Next step:** Pass the proxy variables through when they are set (or document the override), and cover it in the docs.

### LD-011 · MCP servers on the host's localhost

- **Priority:** P4 Optional · **Status:** Open · **Refs:** README "Known limitations"
- **What:** Local MCP servers on the host cannot be used, because `localhost` inside the container is the container
  and loopback MCP connections are allowed only in the desktop app.
- **Next step:** Decide whether a host-gateway allowlist is worth its risk.

### LD-016 · GPU for the local model server

- **Priority:** P3 Low · **Status:** Open · **Refs:** `docs/LOCAL-MODELS.md`
- **What:** The `ollama` container uses the CPU only: the compose file passes no GPU, although the image contains the
  NVIDIA CUDA libraries. NVIDIA on Linux and on Windows (WSL 2) could work with a GPU overlay
  (`deploy.resources.reservations.devices`); untested, so not offered. Docker Desktop on macOS cannot pass a GPU.
- **Next step:** Add `compose.local-models-gpu.yaml` and a launcher setting, and test it on a real NVIDIA machine.

### LD-017 · Smaller image for the local model server

- **Priority:** P3 Low · **Status:** Open · **Refs:** `compose.yaml` (`x-ollama-image`)
- **What:** The official Ollama image is about 3.4 GB to download on amd64 (2.8 GB on arm64) and 8.5 GB unpacked,
  mostly CUDA libraries that a CPU-only installation never uses.
- **Next step:** Evaluate a CPU-only image built from the SHA-256-verified release archive (the same pin as the
  desktop app), with its own digest pin and scan; weigh it against following the upstream image.

## Tests and quality assurance

### LD-018 · Local model inference in the end-to-end tests

- **Priority:** P3 Low · **Status:** Open · **Refs:** `tests/e2e/test_local_docker.py`
- **What:** The end-to-end tests check the model server's lockdown, network and shared volume, but load no model: no
  test runs an agent or a semantic knowledge search through the container, or an offline package import from
  `/import`, because a real model is gigabytes. The default limit `NODESTRO_OLLAMA_MEMORY=16g` was checked only with
  `qwen3:0.6b` (4.4 GB at 32768 tokens; audit round 3 OPS3-05, a 9B model is untested); Ollama sizes models to host
  memory, not to the cgroup limit, so a too-small limit ends in an OOM-killed model runner (HTTP 500, services stay
  healthy).
- **Next step:** Import a tiny GGUF from `/import` and run a chat and an
  embedding through the studio's API.

## Platform coverage

### LD-002 · Docker Desktop on Windows 11 and macOS

- **Priority:** P2 Medium · **Status:** Open · **Refs:** #12, `docs/PLATFORMS.md`, SECURITY-REVIEW K6
- **What:** Untested: Windows 11 and macOS (Apple Silicon, Intel) with Docker Desktop, including the gateway's
  socket mount with Enhanced Container Isolation, limits in the VM, the loopback binding and `nodestro.ps1` on
  Windows PowerShell 5.1. Windows on Arm is not covered at all.
- **Next step:** Run the checklist in `docs/PLATFORMS.md` on real machines (see #12).

### LD-005 · Browsers with `*.localhost` names

- **Priority:** P3 Low · **Status:** Open · **Refs:** `docs/SESSIONS.md` section 4
- **What:** Safari (and Firefox in practice) were not tested with the installation's random `nodestro-<random>.localhost`
  name; the end-to-end tests check the server side only. Real model providers were not used either.
- **Next step:** Open a session in Safari and Firefox and record the result in `docs/SESSIONS.md`.

### LD-006 · Rootless Docker on arm64

- **Priority:** P3 Low · **Status:** Open · **Refs:** `docs/PLATFORMS.md`
- **What:** Rootless Docker is tested only on x86_64; there is no arm64 rootless CI job.
- **Next step:** Add the `rootless` job on `ubuntu-24.04-arm`.

## Documentation

None known.

## Technical debt

### LD-009 · Warn when the pinned studio falls behind

- **Priority:** P4 Optional · **Status:** Open · **Refs:** `components.json`, backend audit D-01
- **What:** `components.json` pins master merge commits of studio and server (studio `a1acb1b`, server `d589e94`
  since the manual-findings cascade of 2026-11-05), but `scripts/check-pins.sh` checks only reachability and agreement (including the
  Ollama pins since #32), not how far they lag behind the latest studio platform commit (audit round 3 OPS3-06).
- **Next step:** Add a CI warning for pin distance; keep pinning merge commits in every cascade.

## Later optimizations

### LD-010 · Further session hardening

- **Priority:** P4 Optional · **Status:** Open · **Refs:** `docs/SESSIONS.md` section 5, SECURITY-REVIEW K5
- **What:** Option D of the session design and one-time launch tokens (the key in the launch URL can stay in browser
  history) would reduce the documented residual risks further. Implementation would be in nodestro-api.
- **Next step:** Re-evaluate before a release.

## Accepted risks

### LD-012 · A container escape reaches the host's Docker

- **Priority:** P2 Medium · **Status:** Accepted risk · **Refs:** `docs/SECURITY.md` residual risk 1, SECURITY-REVIEW K7
- **What:** Tool containers run on the host's daemon; a kernel or runtime escape is root on rootful Linux, the user
  on rootless Docker, or the VM on Docker Desktop. Accepted for a preview; rootless Docker is recommended. A forced
  gVisor runtime is the next hardening step (nodestro-runtime).
- **Next step:** Review again before a release.

### LD-013 · Tool environment builds have network access

- **Priority:** P3 Low · **Status:** Accepted risk · **Refs:** `docs/SECURITY.md` residual risk 5, SECURITY-REVIEW K4
- **What:** pip downloads hash-pinned wheels during image builds on the default bridge network. Accepted because only
  hash-pinned wheels are installed and bases are digest-pinned.
- **Next step:** Longer term, download in the studio and build with no network.

### LD-014 · Low accepted risks of the local model

- **Priority:** P3 Low · **Status:** Accepted risk · **Refs:** `docs/SECURITY.md` residual risks 4, 6, 7; SECURITY-REVIEW K3, K8
- **What:** Anyone with Docker access can read the data volume; the daemon's info endpoint reveals host details;
  containers with the gateway's label created by another holder of the host socket would be treated as its own;
  images are unsigned. Accepted because each requires an actor who already controls Docker, or because nothing is
  published.
- **Next step:** Review again before a release.

## Cross-repository dependencies

| This repo item | Other repo | Other item | Relation |
|---|---|---|---|
| (pointer) | nodestro-studio | ST-052 (Dependabot policy: weekly groups, cooldown, manual merge; auto-merge prerequisites) | Full entry in studio |
| LD-001 | nodestro-runtime | `sandbox_gateway.py` (gateway code), RT-003 | Review covers code there |
| LD-012 | nodestro-runtime | RT-003 (optional forced gVisor runtime; second check of created containers' limits) | Hardening owned there |
| LD-010 | nodestro-api | Launch and session handling (`launch.py`, `local_access.py`) | Implementation there |
| – | nodestro-server | SRV-003 image vulnerability scan (same image definition, target `local`) | Covers this image |
| – | nodestro-studio | ST-027 (no `nodestro-local-docker` entry in `platform/versions.json` `products`) | Owned there |
| LD-018 | nodestro-runtime, nodestro-studio | Local models (`docs/local-models.md`), studio pin | Needs the pin |
| LD-009 | nodestro-server, nodestro-desktop | SRV-016, DSK-013 (pin distance warning) | Same check in all three |

## CI access to private repositories

Keep the repository secret `NODESTRO_READ`; do not delete it. CI currently installs the sibling repositories anonymously
because they are public, and does not need the secret. When the repositories become private, CI authenticates again
with this read-only secret, passed only in the environment of the install steps (never in a global Git configuration,
a log or an image layer).

## Maintaining this file

- Add an entry when work is identified but not done in the current PR. Use the next free ID; IDs are never reused.
- Link a GitHub issue for anything concrete enough to be picked up; keep details in the issue, not here.
- When an item is finished, delete its entry in the PR that completes it and mention the ID in the PR description.
  Git history is the record; do not keep ticked checklists.
- Accepted risks stay listed with their reason until the risk is removed or re-evaluated.
- Re-review the whole file before each release and update the "Last full review" line.
- Security issues that are not yet fixed are described only in general terms here. Report details privately
  (see docs/SECURITY.md or GitHub private vulnerability reporting), never in this file or in public issues.
