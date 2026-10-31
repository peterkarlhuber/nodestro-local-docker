# Security model of Nodestro Local Docker

Nodestro Local Docker is for one person on their own computer. It protects that person's Nodestro data and their
computer from three things:

1. other people and devices on the network;
2. other programs and web pages on the same computer, including the browser being tricked by a web page;
3. untrusted code that Nodestro runs, above all tools that its AI writes, together with their tests.

It does not protect against someone who already controls the user's account or Docker. Anyone who can use Docker on
the host can read every container and volume.

## 1. Network: loopback only, with an access key

- Docker publishes the studio only on `127.0.0.1:${NODESTRO_PORT}` (compose `ports: "127.0.0.1:8765:8080"`).
  Nothing listens on the LAN, and the API refuses to turn on LAN access for published APIs (`lan.unavailable`).
- **Access key.** On first start, `nodestro-local serve` creates 32 random bytes (URL-safe) in
  `/var/lib/nodestro/secrets/access-key` with `O_EXCL`, mode 0600 and a 0700 directory. Afterwards it refuses to
  start if the file is readable by anyone else or shorter than 32 characters. The key is never printed in logs. Only
  `nodestro-local link` prints it, on request. `rotate-key` replaces it atomically.
- **Browser sessions.** `/api/launch?token=<key>` checks the key in constant time and gives the browser a random
  session cookie `nodestro_local_session` (`HttpOnly`, `SameSite=Strict`, path `/`). The cookie is not the key, and
  there are at most 64 sessions. Every request except the health check and the key-protected published APIs needs a
  session or `Authorization: Bearer <key>`. Without one, a browser gets a static sign-in help page
  (`Content-Security-Policy: default-src 'none'`), and other clients get 401.
- The launchers open the browser through a private temporary HTML file that forwards to the link, so the key does
  not appear in the process list. The file is mode 0600 on Linux and macOS, and in the user's TEMP folder on Windows.
  It is removed after 60 seconds.

## 2. Same computer: strict Host and Origin checks

Loopback alone is not enough. Every web page in the user's browser can send requests to `127.0.0.1`, and DNS
rebinding can make a foreign name point there.

- **Host check.** Only `127.0.0.1`, `localhost` and `[::1]`, with the published port, are answered. The container's
  own addresses and name are not. A rebound name such as `evil.example` gets 403 before any route runs.
- **Origin check (strict).** Changing requests (`POST`, `PUT`, `PATCH`, `DELETE`) and every WebSocket are accepted
  only when `Origin` is exactly the origin the request was sent to. Other ports of `localhost` count as foreign. So a
  page of another local program cannot use the studio, even though browsers share cookies across the ports of
  `localhost`.
- There is no CORS. The desktop's allowance for development servers is not used.
- The checks are those of the desktop (`LocalAccessMiddleware`, `LaunchSecretMiddleware`), with stricter settings,
  not a separate implementation.

The `local-container` profile refuses to start when these checks would be weaker: `access.key_required` when there is
no key, and `access.network_needs_login` when a non-loopback host name is allowed.

## 3. Untrusted code: only in sandbox containers, through the gateway

Nodestro's sandbox policy (nodestro-runtime ADR-0006) classifies tool code as trusted (shipped with Nodestro),
user-authored or untrusted (every AI-generated tool and its tests, also after the user approved it). In the
`local-container` profile, every class except trusted needs **container isolation**:

- The desktop's built-in Linux sandbox is not accepted inside the container. It was reviewed for desktop systems,
  not for a container that holds Nodestro's data and secrets (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- **If no sandbox container can be started**, for example because the gateway is down or Docker refuses, such tools
  are **blocked** and their runs fail with a sandbox error. Nothing runs in the Nodestro container instead. The
  end-to-end test `test_without_the_gateway_tool_code_does_not_run_at_all` checks this.

### The gateway

The Nodestro container never gets the host's Docker socket. Access to that socket is root on the host. A separate
`gateway` container holds it and offers Nodestro its own socket. That socket speaks the Docker Engine API but allows
only what Nodestro's sandboxes need, and only in a safe form (nodestro-runtime `sandbox_gateway.py`).

**Tool containers.** Whatever the request asks for, the gateway sets:

| Setting | Value |
| --- | --- |
| Network | `none` |
| Root file system | read-only |
| Capabilities | all dropped |
| Privileges | `no-new-privileges`, not privileged |
| User | `65534:65534` (nobody) |
| Memory / CPU / processes | at most 2048 MB / 2 CPUs / 256 (`NODESTRO_SANDBOX_MAX_*`) |
| Writable space | tmpfs `/tmp` and `/work`, `noexec`, small |
| Open files | 1024 |
| Logs | none (output goes only to the attached client) |
| Lifetime | removed when done; the reaper removes anything older than 10 minutes |
| Number | at most 4 at a time (`NODESTRO_SANDBOX_MAX_CONTAINERS`) |
| Image | only `nodestro-env:<key>` images that Nodestro built; nothing is pulled |

A request that asks for anything else is refused with 403 and the reason, not quietly ignored. That covers bind
mounts, volumes, devices, ports, host namespaces, privileged mode, extra capabilities, other runtimes, sysctls,
security options, masked paths or other users. Containers can be used (attach, start, wait, kill, remove, inspect)
only if the gateway created them, and they carry its label `dev.nodestro.sandbox=<project>`.

**Tool environments (images).** A build is accepted only with:

- exactly the Dockerfile that nodestro-runtime writes;
- a lock file whose every package is pinned with a hash, with no index options;
- the same Orkexa package the gateway itself runs;
- exactly the tag computed from that lock.

The build downloads wheels only (`--only-binary`), so no package code runs at build time. One build runs at a time.
BuildKit sessions are refused, so the classic builder is used (`DOCKER_BUILDKIT=0` in the image).

**Everything else** is refused: exec, other images, volumes, networks, events, swarm, plugins, registry
credentials, and every other daemon endpoint (only ping, version and info are answered).

**The gateway container itself** has no network (`network_mode: none`), drops all capabilities, has a read-only
root, a limit of 256 MB and 64 processes, and runs no tool code. It runs as root only so that it can open the host's
socket, which root owns.

### Nodestro container configuration

`read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, user 10001, tmpfs `/tmp` (1 GB), no host paths except
the named volumes `data` and `sandbox-socket`, and a health check. It has network access, because model providers
and the tool environment builds need it.

## Residual risks

These are known and accepted for a preview. They should be reviewed again before a release.

1. **Container escape reaches the host's Docker.** Tool containers run on the host's daemon with Docker's normal
   isolation: namespaces, cgroups, the default seccomp profile, and AppArmor or SELinux where the host has them.
   They also have the restrictions above. A kernel or container-runtime vulnerability can break out of any
   container.
   - With **rootful Docker on Linux**, an escape is root on the host. **Use rootless Docker** when you can
     (`NODESTRO_DOCKER_SOCKET=$XDG_RUNTIME_DIR/docker.sock`); then an escape is limited to the user who runs Docker.
   - On **Docker Desktop** (Windows, macOS), containers run in a Linux VM. An escape reaches that VM, which can see
     the host folders shared with Docker Desktop.
   - Not tested here: gVisor (`runsc`) as the runtime of tool containers. The gateway could require it. It is the
     recommended next hardening step.
2. **The gateway is a security boundary.** A flaw in its request checks could let the Nodestro container start a
   less restricted container. This is mitigated by allow-lists rather than deny-lists, by refusing unknown fields
   that matter, by strict request parsing, by 103 unit and protocol tests, by real-Docker tests of escape and
   request smuggling attempts (nodestro-runtime `tests/test_sandbox_gateway.py`), and by end-to-end tests from
   inside the running studio container. A request smuggling flaw that gave full Docker API access was found and
   fixed in nodestro-runtime PR #33. Since nodestro-runtime PR #37, the gateway refuses to start tool containers
   or builds when the daemon cannot enforce memory, CPU and process limits (for example rootless Docker without
   cgroup v2 delegation). An independent review is open; [SECURITY-REVIEW.md](SECURITY-REVIEW.md) is
   the package for it.
3. **The browser cookie is shared with other localhost ports.** Browsers send `localhost` cookies to every port of
   the same host name. When the user opens the page of another local program under that name, the browser sends the
   Nodestro session cookie to **that program's server** too. That server could then use the session from a
   non-browser client, where the Origin check does not apply. The strict origin check refuses changing requests and
   WebSockets that such a *page* sends through the browser, and read requests return nothing to it (no CORS).
   Mitigations: open Nodestro only through the launcher link, and do not run untrusted local web servers that you
   open in the same browser. A dedicated host name for the studio, so that the cookie is not sent to other ports, is
   proposed (SECURITY-REVIEW.md, D1).
4. **Anyone who can use Docker on the host can read everything.** This includes the access key, the encrypted
   provider keys and their encryption key, which are all in the data volume. This is inherent to Docker. Docker
   access is root-equivalent on rootful Linux.
5. **Tool environment builds have network access** (the gateway's `NODESTRO_SANDBOX_BUILD_NETWORK`, default: Docker's
   default bridge network) to download pinned wheels. Only hash-pinned wheels are installed, and no package code runs at build
   time.
6. **Disk use.** Tool environment images stay in the host's image cache until they are removed
   (`docker image prune --filter label=...` or Docker Desktop's cleanup).
7. **Unsigned, unpublished images.** Images are built locally from pinned commits and are labeled
   `dev.nodestro.signing=unsigned`.

## Secrets

- The repositories are public, so no build token is needed. `NODESTRO_READ` is supported only as an optional
  BuildKit secret and never becomes a layer, a build argument or a label.
- A proxy CA bundle is passed as a BuildKit secret at build time and mounted read-only at run time. It never goes
  into the image.
- Provider API keys belong to the running studio (encrypted in the data volume) or to its environment, never to the
  build.
- `scripts/scan-image.sh` scans every layer of the image for secrets (nodestro-server's `scan_secrets.py`). CI runs
  it on every build.
