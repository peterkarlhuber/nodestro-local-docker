# Platforms

A platform counts as supported only after Nodestro Local Docker was actually built and tested on it. A platform is
listed as untested when no test environment was available, even if it is expected to work.

| Platform | Image | Status | Evidence |
| --- | --- | --- | --- |
| Linux x86_64, Docker Engine | linux/amd64 | **Tested** | build plus all 14 end-to-end tests: Ubuntu 24.04, Docker 29.9.2, compose 5.6.1, kernel 6.18 (development machine), and CI `image (linux-amd64)` on GitHub's `ubuntu-24.04` |
| Linux arm64, Docker Engine | linux/arm64 | ARM64_STATUS | ARM64_EVIDENCE |
| Windows 11, Docker Desktop (WSL 2) | linux/amd64 | **Untested** | Only the launcher's own code runs in CI (`windows-launcher`: `help` on Windows PowerShell 5.1 and PowerShell 7, on Windows Server 2025). Windows runners have no Linux containers, and no Windows 11 machine with Docker Desktop was available. |
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
3. By hand with `nodestro.ps1` on Windows: `backup`, `restore`, `stop` and `start`, `rotate-key`, `uninstall`. The
   end-to-end tests drive the bash launcher only.
4. Docker Desktop specifics:
   - the published port is reachable as `http://127.0.0.1:<port>` but not from the LAN;
   - file sharing settings do not matter, because no host folder is mounted;
   - "Enhanced Container Isolation", if enabled, may refuse the gateway's socket mount. That needs to be checked.

## Known platform notes

- **Docker Desktop**: containers run in Docker Desktop's Linux VM. The sandbox isolation applies inside that VM (see
  [SECURITY.md](SECURITY.md), residual risk 1).
- **Apple Silicon**: use the arm64 image (the default when building on the Mac). An amd64 image under Rosetta is not
  tested.
- **Windows**: `nodestro.ps1` has no `update` and `rollback` yet. Use `./nodestro` from WSL or Git Bash, or back up,
  `build` and `start`. Building the image needs `bash` and `git`, from Git for Windows or WSL.
