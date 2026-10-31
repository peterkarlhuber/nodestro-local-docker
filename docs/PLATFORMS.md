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
| Linux, rootless Docker | either | **Untested** | Recommended for security (see [SECURITY.md](SECURITY.md)). Not tested here; the socket path is set with `NODESTRO_DOCKER_SOCKET`. |
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

## Known platform notes

- **Docker Desktop**: containers run in Docker Desktop's Linux VM. The sandbox isolation applies inside that VM (see
  [SECURITY.md](SECURITY.md), residual risk 1).
- **Apple Silicon**: use the arm64 image (the default when building on the Mac). An amd64 image under Rosetta is not
  tested.
- **Windows**: `nodestro.ps1` has the same commands as `./nodestro`, including `update` and `rollback`. Building the
  image needs `bash` and `git`, from Git for Windows or WSL. Its Docker commands are tested with PowerShell 7 on Linux
  (CI `image (linux-amd64)`, the whole end-to-end suite with `NODESTRO_E2E_LAUNCHER=pwsh`), because Windows runners
  have no Linux containers. Windows PowerShell 5.1 and Windows itself only run `help` in CI.
