# Changelog

## Unreleased

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
