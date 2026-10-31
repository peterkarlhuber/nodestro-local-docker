# Platforms

A platform counts as supported only after Nodestro Local Docker was actually built and tested on it. A platform is
listed as untested when no test environment was available, even if it is expected to work.

| Platform | Image | Status | Evidence |
| --- | --- | --- | --- |
| Linux x86_64, Docker Engine | linux/amd64 | **Tested** | Build plus all 14 end-to-end tests, secret scan and manifest. Development machine: Ubuntu 24.04, Docker 29.9.2, compose 5.6.1, kernel 6.18. CI `image (linux-amd64)` on GitHub's `ubuntu-24.04` runner. |
| Linux arm64, Docker Engine | linux/arm64 | **Tested** | Native build, no emulation, plus all 14 end-to-end tests, secret scan and manifest (214 packages, all with a license). CI `image (linux-arm64)` on GitHub's `ubuntu-24.04-arm` runner (aarch64, Docker 28.0.4, compose 2.38.2). First run: 2026-10-31. |
| Windows 11, Docker Desktop (WSL 2) | linux/amd64 | **Untested** | On Windows itself only `help` runs in CI (`windows-launcher`: Windows PowerShell 5.1 and PowerShell 7, on Windows Server 2025). Windows runners have no Linux containers, and no Windows 11 machine with Docker Desktop was available. The launcher's Docker commands pass the end-to-end tests with PowerShell 7 on Linux, which says nothing about Docker Desktop. |
| macOS Apple Silicon, Docker Desktop | linux/arm64 | **Untested** | No Mac was available. The arm64 image is the one tested on Linux arm64. |
| macOS Intel, Docker Desktop | linux/amd64 | **Untested** | No Mac was available. |
| Linux x86_64, rootless Docker (cgroup v2) | linux/amd64 | **Tested, recommended** | All 14 end-to-end tests on rootless Docker 28 with systemd and cgroup v2 delegation (memory, CPU, processes), CI job `rootless` on `ubuntu-24.04`. First run: 2026-10-31. The launcher finds the socket itself. See [Rootless Docker](#rootless-docker). |
| Linux, rootless Docker without cgroup v2 | either | **Refused** | The daemon drops memory, CPU and process limits there (cgroup v1, or no systemd user session). Since nodestro-runtime #37 the gateway refuses to start tool code on such a daemon. Development machine (cgroup v1): the studio runs, tools are blocked. |
| Linux arm64, rootless Docker | linux/arm64 | **Untested** | Expected to behave like x86_64; no CI job yet. |
| Podman, other engines | | **Not supported** | The gateway speaks the Docker Engine API of a Docker daemon. |

## What has to be checked on an untested platform

Before a platform is called supported, run on it:

1. `./nodestro start` (Windows: `.\nodestro.ps1 start`) from a fresh clone. The image builds, the browser opens, and
   the studio loads.
2. The end-to-end tests: `NODESTRO_IMAGE=nodestro-local:dev python -m pytest tests/e2e -v`. On Windows, run them
   from WSL against Docker Desktop. Docker Desktop's socket is `/var/run/docker.sock` inside its VM, which is what the
   compose file uses.
3. By hand with `nodestro.ps1` on Windows PowerShell 5.1 and PowerShell 7: `backup`, `restore`, `stop` and `start`,
   `update` and `rollback`, `rotate-key`, `uninstall`. On Linux, CI runs the end-to-end tests with both launchers,
   but not on Windows, where `cmd` redirection, paths with spaces and Windows PowerShell 5.1 differ.
4. Docker Desktop specifics:
   - the published port is reachable as `http://127.0.0.1:<port>` but not from the LAN;
   - file sharing settings do not matter, because no host folder is mounted;
   - "Enhanced Container Isolation", if enabled, may refuse the gateway's socket mount. That needs to be checked.

## Rootless Docker

Rootless Docker is the recommended setup on Linux. The Docker daemon runs as your user, so an escape from a tool
container is limited to that user instead of root on the host (see [SECURITY.md](SECURITY.md), residual risk 1).

1. Install it as described in Docker's documentation ("Run the Docker daemon as a non-root user"):
   `dockerd-rootless-setuptool.sh install`. It needs `uidmap`, a systemd user session and cgroup v2. On Ubuntu 24.04,
   AppArmor may also need to allow unprivileged user namespaces for `rootlesskit`.
2. Let systemd delegate the cgroup controllers to users, so the sandbox limits are enforced:
   ```
   sudo mkdir -p /etc/systemd/system/user@.service.d
   printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
   sudo systemctl daemon-reload
   ```
3. Check that `docker info --format '{{json .}}'` reports `MemoryLimit`, `PidsLimit`, `CpuCfsQuota` and
   `CpuCfsPeriod` as `true`. Without these, the gateway refuses to run tool code, and such runs fail with a sandbox error.
4. Start Nodestro with `./nodestro start`. The launcher takes the socket `/run/user/<uid>/docker.sock` from
   `DOCKER_HOST` or the current docker context and gives it to the gateway. To set it explicitly, use
   `NODESTRO_DOCKER_SOCKET`.

What the tests show on rootless Docker:

- **Socket permissions.** The gateway runs as root inside the user namespace, which is your user outside, so it can
  open your daemon's socket. The `nodestro` container (user 10001, which maps to a subordinate UID) only sees the
  gateway's socket.
- **Isolation.** The same lockdown applies as on rootful Docker: no network, read-only root, no capabilities, user
  `nobody`, and enforced limits.
- **Files and persistence.** The volumes live under `~/.local/share/docker`. Data survives a stop, a restart and a
  re-creation. Backup, restore, update and rollback work.
- **Limitations.**
  - Files that a compose file mounts from the host must be readable by your user, for example
    `NODESTRO_EXTRA_CA_FILE`.
  - Rootless Docker uses its own image store, so images built with rootful Docker are not visible there.
  - The published port is still `127.0.0.1` only (rootlesskit's port driver).
  - Rootless and rootful Docker on the same machine are separate installations with separate data.

## Known platform notes

- **Docker Desktop**: containers run in Docker Desktop's Linux VM. The sandbox isolation applies inside that VM (see
  [SECURITY.md](SECURITY.md), residual risk 1). What still has to be checked on a real Docker Desktop:
  - the gateway's mount of `/var/run/docker.sock` (the VM's socket), also with "Enhanced Container Isolation" on;
  - that `/info` reports the limits, so that tool code is allowed to run;
  - the compose network, and that the published port is reachable as `127.0.0.1` but not from the LAN;
  - named volumes across Docker Desktop restarts and updates;
  - amd64 on Intel Macs and Windows, arm64 on Apple Silicon (and on Windows on Arm, which is not covered at all).

  The launcher does not take Docker Desktop's context socket (`~/.docker/run/docker.sock`): that path exists on the
  host, not in the VM.
- **Apple Silicon**: use the arm64 image (the default when building on the Mac). An amd64 image under Rosetta is not
  tested.
- **Windows**: `nodestro.ps1` has the same commands as `./nodestro`, including `update` and `rollback`. Building the
  image needs `bash` and `git`, from Git for Windows or WSL. Its Docker commands are tested with PowerShell 7 on Linux
  (CI `image (linux-amd64)`, the whole end-to-end suite with `NODESTRO_E2E_LAUNCHER=pwsh`), because Windows runners
  have no Linux containers. Windows PowerShell 5.1 and Windows itself only run `help` in CI.
