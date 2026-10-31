# Changelog

## Unreleased

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
