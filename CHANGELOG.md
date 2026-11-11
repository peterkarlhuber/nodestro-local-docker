# Changelog

## Unreleased

- Pins nodestro-studio 6755c7a (studio #167, RT-067: orkexa 840add4 replays only the latest reasoning to Ollama so tool
  conversations no longer outgrow the context window and answers instead of failing at a tool-round or reasoning limit;
  runtime 979c11c with `limits_handled` on a step; api e584d6f). nodestro-server stays at 421229c (its image definition
  is unchanged). Limits are unchanged.

- Pins nodestro-studio 9d24565 (studio #162, pin wave W7, TABRION JQ-4: runtime f5da80d, runtime #143, where writes
  are never repeated after a lost connection; axentra 9c4666f with the B-06-1 log redaction (server profile only);
  api 221f9e1) and nodestro-server 421229c (server #75: the same studio pin). The local profile installs no
  PostgreSQL backend; behavior unchanged.

- Pins nodestro-studio c41e3c2 (studio #157, MUP-ONA B6 cascade: runtime 81b0f55, where the knowledge base, file store
  and memory run on orkexa's PostgreSQL backends (orkexa 792a041); api 05e0232) and nodestro-server 89fa4af (server
  #74: the same studio pin, RUNBOOK for `storage.schema_mismatch`). The local profile installs no PostgreSQL backend;
  behavior unchanged.
- Pins nodestro-studio 5318cea (studio #153, MUP-ONA B4 cascade: runtime df4aeb3 with the tenant SQL rule engine,
  the statement catalog and partition guard; examples c9ef422, integrations fe2fa12, api e5b5281, sdk d372eee) and
  nodestro-server c488f1d (server #70: the same studio pin; server #71: the image's base stage installs the Debian
  security updates, which fixes the zlib1g CVEs CVE-2026-76844 and CVE-2026-85091 the image scan reported). Behavior
  unchanged.
- Pins nodestro-studio 9c0a6bd (studio #149, MUP-ONA B2 cascade: runtime d9c3d6e with orkexa 028faa1 and Axentra
  60d83b3, api 44212bc, sdk bda96c1) and nodestro-server a5f3af3 (server #68: the same studio pin, RUNBOOK rows for the
  PDF reading limits).
- Pins nodestro-studio 27f8bd4 (studio #146 and #147, TODO abatement round 5: api 63af1df, sdk 4596be3, runtime
  de56875) and nodestro-server 5b0bdab (server #66: the same studio pin, RUNBOOK for pgvector installed later).
- End-to-end tests (LD-020): the new first test restarts the studio while its first sandbox check builds the
  runtime image (a RUN step of the build runs on the daemon) and requires the sandbox to become approved without
  ever being `unavailable`, and a new tool's tests and run to pass in sandbox containers. When the image exists
  already (the PowerShell rerun in CI, a developer's daemon), it removes the image the self-test used and restarts
  once to get a fresh build. It runs in the image and rootless CI jobs with the rest of `tests/e2e`.
- Pins nodestro-studio f69020a (studio #143, TODO abatement round 4: runtime f26dac4 with the sandbox image build
  retry of LD-020, api 77f53be) and nodestro-server 30e57bb (server #65: the same studio pin, worker health check).
  LD-020 now only tracks the missing end-to-end test that restarts the studio during the first image build.
- End-to-end tests: the sandbox tests wait until the studio's Docker sandbox is approved (`GET /api/sandbox/status`)
  instead of racing its first check, and the studio is no longer restarted while that check builds the sandbox
  image (a CI run had failed with `sandbox.isolation_required`, `docker-image`; LD-020 tracks the product side). CI
  uploads the container logs when an end-to-end run fails.
- Pins nodestro-studio ee3f378 (studio #142, TODO abatement round 3: Settings → Members, export delete; runtime
  b06b371, api 7142761) and nodestro-server 8b2af08 (server #62: the same studio pin, RUNBOOK).
- Pins nodestro-studio 5c0fbd8 (studio #140, TODO abatement round 2: api 56fa762, sdk 1306cbe) and nodestro-server
  9d918aa (server #61: the same studio pin).
- Pins nodestro-studio 39fb164 (studio #136, TODO abatement round) and nodestro-server ddd095f (server #59: image
  vulnerability scan, paired backups, pin distance script).
- Proxy settings: `NODESTRO_HTTPS_PROXY` (and `NODESTRO_NO_PROXY`) in the launchers' environment layer
  `compose.proxy.yaml`, which gives the studio and the model server `HTTPS_PROXY`/`HTTP_PROXY` and a `NO_PROXY` that
  always keeps loopback direct (README, docs/LOCAL-MODELS.md). A launcher test checks the compose file order with a
  fake `docker`.
- CI runs nodestro-server's vulnerability scan on the built image (`scripts/scan-image.sh`, reports as artifacts)
  and warns when the studio pin lags behind studio master (`scripts/pin-distance.sh`); both skip until the server
  pin includes the server's scripts.
- The rootless Docker job runs on Linux arm64 too (docs/PLATFORMS.md).

- Pins nodestro-studio 58bb17d (studio #135: settings, attachments and providers round; orkexa 566aa3c, runtime
  62527d1, api a799912) and nodestro-server 453fb26 (server #58: the same studio pin).

- Pins nodestro-studio a1acb1b (studio #127: product findings of the manual review; runtime 57b40d2 with the strict
  offline mode outside runs, api f796916) and nodestro-server d589e94 (server #55: RUNBOOK on batches and test series).

- Pins nodestro-studio 2c072d7 (studio #123, #124: backend audit and UX round 3; api 5ee13f7, runtime 40c8c06,
  orkexa e9c2147 with the reclaim of a stale managed Ollama, axentra 0a1d1cc) and nodestro-server a567530 (server #51
  restore and upgrade fixes, #53).

- The Ollama image is named by tag and digest (`ollama/ollama:0.40.14@sha256:…`; Docker still uses the digest).
  `scripts/check-pins.sh` (CI) checks that both services use the same image and that its version is the
  `OLLAMA_VERSION` Orkexa installs at the studio's pinned Orkexa commit; the end-to-end test takes the version from
  the tag. Dependabot now also proposes updates of the images in `compose.yaml`.

- Resource limits for the studio and the model server (#11). `nodestro`: 4 GB memory, 512 processes
  (`NODESTRO_MEMORY`, `NODESTRO_PIDS`; `NODESTRO_CPUS`, default `0`: all CPUs). `ollama`: 16 GB memory, 2048 processes
  (`NODESTRO_OLLAMA_MEMORY`, `NODESTRO_OLLAMA_PIDS`, `NODESTRO_OLLAMA_CPUS`), enough for the suggested 4B and 9B models
  with the 32768-token context window, and `oom_score_adj` 500, so that out of memory the kernel ends Ollama's model
  runner before the studio. The end-to-end test checks the defaults.

- Ollama no longer has a container address: it runs in the network namespace of the studio and listens on
  127.0.0.1:11434 only, so the studio reaches it on the shared loopback (`NODESTRO_OLLAMA_URL=http://127.0.0.1:11434`).
  Before, any process on a Linux host with Docker Engine could reach Ollama's unauthenticated API at its container
  addresses. The namespace belongs to the new small container `network` (`sleep` as user nobody, read-only, no
  capabilities, no volume, 32 MB), which also publishes the studio's port, so it outlives restarts of `nodestro` and
  `ollama`. The networks `models` and `models-egress` are gone; Ollama downloads over the studio's internet access.
  `NODESTRO_LOCAL_MODELS=offline` now sets a closed local proxy port for Ollama's outgoing requests (an Ollama setting,
  no longer a separate network). `restart` in both launchers stops and starts the containers (`docker compose restart`
  cannot restart containers that share a namespace in one call). An existing installation switches on its next
  `start` or `update`; the unused networks stay (`docker network rm nodestro-local_models nodestro-local_models-egress`
  removes them).

- `components.json` pins studio `0a6a320` (studio #120: nodestro-runtime `2f1de71`, orkexa `6e61862`: key figures that
  a condition decides on, or that report money or days, must come from a tool, and the runtime checks them; the new
  built-in `table_totals` tool; local Ollama agents with a structured result call their tools; production-downtime
  decides on the computed 4.62 % instead of an estimate) and server `23fd4a2` (server #50: the same studio pin).

- `components.json` pins studio `f9e4a91` (studio #118, #119: nodestro-runtime `7cb9b4b`, in the CPU saving mode the
  quality judge of a local thinking model also answers without the thinking phase, and the local Ollama gets 60 minutes
  per request instead of the SDK's 10, so a long answer on CPU no longer fails with a provider timeout) and server
  `81c1eb7` (server #49: the same studio pin).

- `components.json` pins studio `74a9aa6` (studio #117: nodestro-runtime `3006ce0`, nodestro-api `c2a2ad3`, orkexa
  `4ec738c`: the CPU saving mode for thinking models, hardware and context window advice with a speed measurement,
  building mDenseOn from local files, per-agent local models when copying an example, robust hybrid knowledge search)
  and server `7c3703e` (server #48: the same studio pin). The `nodestro` service gets the same
  `NODESTRO_OLLAMA_CONTEXT_LENGTH` as the `ollama` service, so the local models overview names the context window as
  set by Nodestro instead of "unknown".

- The `ollama` container gets `OLLAMA_CONTEXT_LENGTH=32768` (override with `NODESTRO_OLLAMA_CONTEXT_LENGTH`). Ollama's
  default without a large GPU is 4096 tokens for prompt, thinking and answer together, and local agents ran out of
  it long before their `max_tokens`.
- `components.json` pins studio `97564f4` (studio #115: nodestro-runtime `90ba97b`, nodestro-api `a24f32b`, orkexa
  `71f8aaf`: the local model features, European catalog entries and the "prefer European models" setting, the
  optional mDenseOn embedding build) and server `8254cac` (server #47: the same studio pin; restores drop the newer
  release's tables in the same transaction). The local model features are now active in the studio container.

### Local model server (2026-11-03)

- New container `ollama`: Ollama 0.40.14, the official `ollama/ollama` image pinned by the digest of its
  multi-platform index. User 10001, read-only, no capabilities, `no-new-privileges`, `OLLAMA_NO_CLOUD=1`, no published
  port. Only the studio reaches it, on the new internal network `models`; its own network `models-egress` is for model
  downloads. New volume `models` (Ollama's model store), shared with the studio for offline imports; the one-shot
  `models-init` hands it to user 10001.
- The studio container gets `NODESTRO_OLLAMA_URL=http://ollama:11434` and
  `NODESTRO_OLLAMA_MODELS_DIR=/var/lib/nodestro-models` (nodestro-runtime `docs/local-models.md`, profile
  `local-container`; used once the studio pin contains the local model features), and the host folder
  `NODESTRO_IMPORT_DIR` (default `import/`) read-only as `/import`.
- Launchers (`nodestro`, `nodestro.ps1`): `NODESTRO_LOCAL_MODELS=on|offline|off` (remembered in the state file;
  `compose.local-models-offline.yaml` removes the download network, `compose.local-models-off.yaml` leaves the model
  server out), the `import` folder, a note before the first download of the Ollama image.
- `compose.extra-ca.yaml` gives Ollama the proxy's certificate authority too. The test of other containers reaching the
  studio's address picks the project's default network explicitly (the studio now has two networks).
- New end-to-end tests: the model server is pinned and locked down; only the studio reaches it, on an internal
  network; the studio shares the model folder and reads the import folder read-only. New docs/LOCAL-MODELS.md; README,
  ARCHITECTURE, SECURITY, PLATFORMS and TODO (LD-016 GPU, LD-017 smaller image, LD-018 inference in e2e) updated.

### Backend audit round 2 pins (2026-11-03)

- `components.json` pins studio `6e94ae4` (merge commit of studio #112: nodestro-api `7c195ed`, exporting a project
  works without test tools in the image) and server `ac2ef9a` (merge commit of server #44, the same studio pin).

- `components.json` pins studio `b7c8af2` (merge commit of studio #111, UX round: frontend only, the backend pins of
  `997f485` are unchanged) and server `8b4ae82` (merge commit of server #43: PostgreSQL upgrade test in CI, no change
  to the shared image definition). All three products now build from the same studio commit.

- `components.json` pins studio `997f485` (before `83d8998`, merge commit of studio #110) and server `f840285` (before
  `1f8e14b`, merge commit of server #42, which contains server #41: no pip in the image, digest-pinned base images).
  Component pins: runtime `140d479`, api `84ca99d`, examples `8499edf`, integrations `e2582cc`, orkexa `bc8c4ed`,
  Axentra `a872242` (server profile only). For Local Docker this brings the API's security headers and request body
  limit, keyset run pages, idempotent run starts and the stricter origin checks, and stops sandbox calls on a
  timeout or cancel. No changes in this repository.

### Nodestro–Axentra migration close-out (2026-11-03)

- `components.json` pins studio `83d8998` (before `139bce3`, merge commit of studio #107) and server `1f8e14b` (before
  `ec0e4ac`, merge commit of server #40). Component pins: runtime `bcfea7f`, api `f21fd6a`, examples `9dd0c1a`,
  integrations `b3c7c90`, orkexa `0861c1b`, Axentra `2767a2e` (server profile only). No changes in this repository.

### Docker-first follow-up (2026-11-02)

- `components.json` pins studio `139bce3` (before `6351ad3`, merge commit of studio #105) and server `ec0e4ac` (before
  `c999c64`, merge commit of server #39). Component pins: runtime `958be1d`, api `b8139b0`, examples `8c338d3`,
  integrations `e71bf55`, orkexa `dec66eb`. For Local Docker this means: source builds of Python libraries are refused
  (R-1, plans use wheels only), resolve containers are checked against the proven shape (R-5), MCP containers have a
  15-minute deadline, and adopting AI-created tools is refused (`tool.adoption_desktop_only`, desktop only).

### Python 3.11 minimum (2026-11-02)

- Python 3.11 is now the minimum (3.10 reached end of life in October 2026): ruff `target-version = "py311"` for the
  test code; the image already runs 3.13.
- `components.json` pins studio `6351ad3` (before `d2724c2`, merge commit of studio #103) and server `c999c64`
  (before `1a5febb`, merge commit of server #38). Component pins: axentra `024da57` (server profile only, not
  installed here), orkexa `dec66eb`, runtime `51262a2`, api `ef04cb4`; with the security review fixes of the Axentra
  migration completion (studio #102, server #36) and Python 3.11 as the minimum.

### Run budget decisions and the unified Docker sandbox (2026-11-02)

- `components.json` pins studio `d2724c2` (before `bae25eb`, merge commit of studio #101) and server `1a5febb`
  (before `4a733cf`, merge commit of server #35): attended runs pause for a budget decision (BUDGET-1) and the
  unified Docker sandbox (preflight and self-test). Component pins: runtime `bf9af7d`, api `dde77f5`, orkexa `3364fb8`.

### macOS build fix (2026-11-02)

- `components.json` pins studio `bae25eb` (before `0055a30`, merge commit of studio #89) and server `4a733cf`
  (before `5a4306d`, merge commit of server #31): the studio frontend component `automation/TestStatus.tsx` is
  renamed to `WorkflowTestStatus.tsx`, so it builds on case-insensitive file systems (macOS). Component pins
  unchanged (runtime `a42b672`, api `fb7f438`, orkexa `3467940`).

### Live run chat and steering (LRC-1, 2026-11-01)

- `components.json` pins studio `0055a30` (before `b8c6d48`, merge commit of studio #77) and server `5a4306d`
  (before `b2f0c3f`, merge commit of server #24): live run chat and steering on top of Amazon Bedrock; runtime
  `a42b672`, api `fb7f438`, orkexa `3467940`. Both are on master, so `scripts/check-pins.sh` accepts them.

### Amazon Bedrock branches (branch only, 2026-11-01)

- `components.json` pins studio `b8c6d48` (before `5f96652`) and server `b2f0c3f` (before `ce58ea6`), the Bedrock
  branches: runtime `ac96c6f`, api `4e2c8cd`, orkexa `3467940` (boto3). Not on master yet, so
  `scripts/check-pins.sh` refuses them until the coordinated cascade merges.

### Final UX initiative state (2026-11-01)

- `components.json` pins studio `5f96652` (before `90f08ce`) and server `ce58ea6` (before `a93df72`). Backend pins
  unchanged: runtime `d141b8f`, api `db6a696`, orkexa `6e69b9c`.

### PostgreSQL read performance, accessibility (2026-11-01)

- `components.json` pins studio `90f08ce` (before `561c655`) and server `a93df72` (before `5fac3f6`): runtime
  `d141b8f`, api `db6a696`, orkexa `6e69b9c`; plus the accessibility and in-app docs work of studio master. Local
  Docker uses SQLite, so the PostgreSQL changes do not apply to it.

### Backend audit fixes (2026-11-01)

- `components.json` pins studio `561c655` (before `66fe676`) and server `5fac3f6` (before `bfa2e86`): runtime `6eacec1`,
  api `e16202d`, orkexa `6e69b9c`. This brings in the fixes of the 2026-11-01 backend audit: bounded tool output,
  sandbox cancellation, run fencing and orphan recovery, document locking, health checks that answer 503, log
  redaction, gzip and cache headers for the frontend, and clearer error codes for model providers.
- No change to the launcher, the compose file or the sandbox gateway configuration.

### Browser sessions on a private host name, logout, hardened gateway (2026-10-31)

- The launch link opens the installation's own random host name, `nodestro-<random>.localhost`. Cookies are scoped
  by host name, not port, so the session cookie no longer reaches other local web servers on `localhost` or
  `127.0.0.1` (D1, api PR #29). Design and browser compatibility: [docs/SESSIONS.md](docs/SESSIONS.md).
- Browser sessions end after 8 hours without use and 24 hours at most. `./nodestro logout` and
  `.\nodestro.ps1 logout` end every session; `/api/logout` signs out one browser.
- `compose.yaml` passes `NODESTRO_BROWSER_HOST` (empty by default). Setting it to `127.0.0.1` or `localhost` gives
  up the protection, and the launcher warns.
- D3: only the published port is answered in `Host`; the documentation said so before, and now the code checks it.
- The image contains the hardened sandbox gateway of runtime PR #47 (image and connection limits, build queue,
  seccomp check, strict `ca.pem`, digest-pinned base images) and the digest-pinned base images of server PR #7.
- `components.json` pins studio `66fe676` (before `0609fbb`) and server `bfa2e86` (before `df993bc`): runtime `a13f894`,
  api `c58d5de`, orkexa `b91d0b7`.
- The end-to-end tests check the host name file, sessions under shared names, ports and logout.

### Sandbox gateway security fixes in the image (2026-10-31)

- `components.json` pins studio `0609fbb` (before `c4b3708`) and server `df993bc` (before `e4791a8`). The image
  therefore contains runtime `8597544`, whose sandbox gateway parses request heads strictly (request smuggling fix,
  runtime PR #33) and refuses sandboxes and builds when the Docker daemon cannot enforce memory, CPU and process
  limits (runtime PR #37; for example rootless Docker without cgroup v2 delegation).

### Windows launcher update and rollback, rootless Docker (2026-10-31)

- `nodestro.ps1` gained `update` and `rollback`, like `./nodestro`. Before switching, it makes a backup and a copy of the
  data volume, and it rolls back on its own when the new version does not start. Native commands no longer stop Windows
  PowerShell 5.1 when they write to stderr (`Test-Native`). Backup and restore run through `sh` on PowerShell 7 for Linux
  and macOS.
- CI runs the whole end-to-end suite a second time with the PowerShell launcher (PowerShell 7 on Linux,
  `NODESTRO_E2E_LAUNCHER=pwsh`).
- Rootless Docker: `./nodestro` finds the user's rootless socket (`/run/user/<uid>/docker.sock`) from `DOCKER_HOST` or
  the current docker context and passes it to the gateway. Docker Desktop's contexts keep the default. A new CI job
  `rootless` runs the end-to-end tests on rootless Docker with cgroup v2 delegation.

### First version (2026-10-31)

- Nodestro Local Docker: the Nodestro studio for one person in Docker, used from the host's browser.
  - `compose.yaml` has two services from one image (nodestro-server `image/Dockerfile`, target `local`):
    - `nodestro`: the studio on SQLite in the volume `data`, published on `127.0.0.1` only, behind an access key.
    - `gateway`: the runtime's sandbox gateway, the only container with the host's Docker socket.
- Launchers: `nodestro` (Linux, macOS) and `nodestro.ps1` (Windows).
  - Commands: start, stop, restart, status, open, link, logs, backup, restore, build, rotate-key and uninstall.
  - The bash launcher also has update with automatic rollback, and rollback.
- `components.json` pins nodestro-studio and nodestro-server by full SHA. Scripts build the image without a token,
  check the pins, scan the image for secrets and write the manifest with its license inventory.
- End-to-end tests (14) against real Docker. CI builds and tests on real amd64 and arm64 runners and runs the
  PowerShell launcher on Windows. Nothing is published.
- Documentation: architecture decision, security model, platform matrix, development guide.
