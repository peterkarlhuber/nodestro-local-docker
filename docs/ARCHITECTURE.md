# Architecture of Nodestro Local Docker

Status: accepted, 2026-10-31. This is the decision record (ADR) of the third way to run Nodestro.

## Goal

One person on their own computer (Linux, Windows with Docker Desktop, macOS Intel or Apple Silicon) starts Docker,
starts Nodestro with one command, and uses the studio in a normal browser. Workflows, agents and tools work, data is
persistent, and nothing but Docker is installed: no Python, Node.js, PostgreSQL or native app. It must reuse the
Nodestro core; there must be no third implementation.

## Constraints

- No duplicated runtime, no copied API logic, no studio that diverges from the desktop and server.
- A container is not a desktop app. The desktop's protections (loopback only, a session secret, host and origin
  checks) must not be switched off just because the process now runs in a container.
- Untrusted code (every AI-generated tool and its tests, also after the user approved it) must not run unisolated in
  the Nodestro container. Without a sufficiently isolated environment it is blocked; there is no unsafe fallback.
- The Nodestro container must not get uncontrolled access to the host's Docker socket. Privileged Docker-in-Docker is
  not acceptable as the default.
- The repositories are public: builds need no token.

## Variants compared

| | A: SQLite image of its own | B: reuse nodestro-server | **C: one image definition, separate profile** |
| --- | --- | --- | --- |
| Build | a second Dockerfile in this repo | the server image and compose stack as they are | target `local` of nodestro-server's Dockerfile |
| Database | SQLite | PostgreSQL (one more container) | SQLite (the desktop's storage) |
| Users | one | multi-user, logins, tenants, admin | one |
| Runtime, API, studio | the same packages, but a second build that drifts | the same | the same, same build stages |
| Tool sandbox | open | a separate privileged DinD daemon | the sandbox gateway (below) |
| Maintenance | two image definitions to keep in step | lowest, but the wrong product for one person | one definition, one profile |
| Security fit | depends on what is copied | multi-user hardening that one person does not need, privileged DinD | made for one host, no privileged container |

**Decision: variant C**, plus a new runtime profile `local-container` and a sandbox gateway.

- B is a multi-user server: logins, tenants, PostgreSQL, workers and an administrator. For one person that is more
  to install, operate and secure, and its tool sandbox is a privileged Docker-in-Docker daemon, which the brief rules
  out for a desktop computer.
- A gives the right product but a second build. Two Dockerfiles would drift (Python, Node, component versions,
  license files, secret handling), which is exactly what the brief forbids.
- C keeps one image definition: the stages that fetch the studio at a pinned commit, build the web interface,
  install every component by full SHA and collect license texts are shared by `server` and `local`. Only the last
  stages differ (`server` adds PostgreSQL tools; `local` sets the profile, the data directory and its entry point).

## Why a profile of its own, not the desktop profile

The desktop profile assumes a native app on the user's machine. In a container two of its assumptions are wrong:

1. **Listening address.** The desktop refuses every interface except loopback. In a container the app must listen on
   the container's interface so that Docker can publish it. Docker publishes it on the host's `127.0.0.1` only, but
   inside the container the address is `0.0.0.0`. Relaxing this for the desktop profile would weaken the desktop.
2. **Built-in sandbox.** The desktop's built-in Linux sandbox (Landlock, seccomp, resource limits) is accepted as
   isolation for untrusted tools on tested desktop systems. The container's base image is Debian 13, one of those
   systems, so its self-test could pass inside the container. It would then run untrusted code in the Nodestro
   container under a sandbox that was reviewed for a desktop, not for a container that holds the Nodestro data and
   secrets. That needs a separate review, so the `local-container` profile does not accept it.

The `local-container` profile (nodestro-runtime `profile.py`) is therefore a single-user profile like the desktop
(one person holds every permission, provider keys may come from the environment), but:

- the sandbox policy (ADR-0006) requires a **container** for every trust class except trusted, as on the server, and
  the built-in sandbox is reported as unavailable ("Nodestro Local Docker runs tool code in sandbox containers only");
- the API (nodestro-api `local_container.py`) may listen on the container's interfaces only with an **access key**
  and only with **loopback host names** allowed, and it applies **strict origin checks**.

## Components

```
host browser ──http://nodestro-<random>.localhost:8765──▶ [ nodestro ]  studio + API + runtime, SQLite in volume `data`
                                            │ DOCKER_HOST=unix:///run/nodestro-sandbox/docker.sock
                                            ▼  (volume `sandbox-socket`)
                                       [ gateway ]  Docker API policy proxy, no network
                                            │ host's /var/run/docker.sock
                                            ▼
                                     host Docker daemon ──▶ tool containers (no network, read-only, nobody, limits)
```

- **`nodestro`** container: the image's `nodestro-local serve`. It is the studio, API and runtime of the pinned
  commits, with no capabilities, `no-new-privileges`, a read-only root file system, a tmpfs `/tmp` and user 10001.
  The access key is created on first start in `/var/lib/nodestro/secrets/access-key` (mode 0600, directory 0700).
- **`gateway`** container: the same image's `nodestro-local gateway`, which is nodestro-runtime's
  `sandbox_gateway`. It is the only holder of the host's Docker socket. It runs with no network, no capabilities and a
  read-only root, with 256 MB and 64 processes. It offers the studio a Docker API socket that only creates
  locked-down tool containers and builds tool environments from Nodestro's own Dockerfile. See
  [SECURITY.md](SECURITY.md).
- **Volumes**: `data` (everything persistent) and `sandbox-socket` (the gateway's socket, shared with `nodestro`).
- **Launcher**: `nodestro` (bash, Linux and macOS) and `nodestro.ps1` (Windows). They wrap `docker compose` for
  start, stop, status, backup, restore, update and rollback, and open the browser without putting the key on a
  command line.

## What is reused, and where general features went

Nothing in this repository is Nodestro logic. Every general feature went to the repository that owns it:

| Feature | Repository | Notes |
| --- | --- | --- |
| `local-container` profile, sandbox policy, built-in sandbox status | nodestro-runtime (#26) | `SINGLE_USER_PROFILES` |
| Sandbox gateway (Docker API policy proxy) | nodestro-runtime (#26) | `sandbox_gateway.py`, unit and real-Docker tests |
| `DOCKER_BUILDKIT` passed to the Docker CLI | nodestro-runtime (#26) | the gateway accepts only the classic builder |
| Access key sessions, Bearer, strict origin | nodestro-api (#25) | extends the desktop's `LaunchSecretMiddleware` and `LocalAccessMiddleware` |
| `nodestro-local` command (serve, link, backup, restore, ...) | nodestro-api (#25) | backup and restore are the studio's own |
| Image target `local` | nodestro-server | shared stages with the server image |
| Image manifest, license inventory, secret scan | nodestro-server scripts | called at the pinned server commit |
| Tool sandboxes (`StreamedSandbox`, `RuntimeImageSandbox`, `ContainerImages`) | nodestro-runtime | unchanged; they run without bind mounts, so a gateway works |
| Static tool check, tool tests | orkexa | unchanged |

This repository holds the compose file, the launchers, the scripts that build from pinned commits, the end-to-end
tests and the documentation.

## Versions and pins

[components.json](../components.json) names two full commit SHAs:

- **nodestro-studio**: pins every component (runtime, api, examples, integrations, orkexa) in its `pyproject.toml`
  and `platform/versions.json`. `scripts/check-pins.sh` checks that they agree.
- **nodestro-server**: holds the image definition.

An image is reproducible from these two commits. Its tag is `nodestro-local:<studio 12>-<server 12>`, and its labels
name both commits.

## Consequences

- One more profile to keep in mind in runtime and API changes. The tests of both repositories cover it.
- Tool containers run on the host's Docker daemon, not inside a nested daemon. This is simpler and avoids privileged
  containers, but an escape from a tool container reaches the host's Docker. This is the main residual risk, see
  [SECURITY.md](SECURITY.md).
- No image is published yet. The launcher builds from source, which takes a few minutes once and needs git.
