# Security review package: sandbox gateway and local access control

This package is for an **independent** security review of Nodestro Local Docker. The implementing agent has reviewed
its own code (section 6), but that does not count as an independent review. Until a separate reviewer has worked
through this package, the independent review is **open**.

The reviewer should not have to trust anything stated here. Every claim names the code or test that backs it, so
that it can be checked and attacked.

## 1. Scope

| Area | Repository | Files |
| --- | --- | --- |
| Sandbox gateway (Docker API policy proxy) | nodestro-runtime | `src/nodestro_runtime/sandbox_gateway.py` |
| Gateway tests | nodestro-runtime | `tests/test_sandbox_gateway.py` |
| Sandbox policy (which code needs which isolation) | nodestro-runtime | `src/nodestro_runtime/sandbox_policy.py`, `profile.py` (profile `local-container`), ADR-0006 in `docs/` |
| Client side: images and containers through the CLI | nodestro-runtime | `src/nodestro_runtime/container_images.py`, `python_envs.py`, `workspace.py` |
| Client side: running tool code in a container | orkexa | `src/orkexa/dynamic/sandbox.py` (`DockerSandbox`) |
| Access key, browser sessions | nodestro-api | `src/nodestro_api/launch.py` (`LaunchSecretMiddleware`) |
| Host and Origin checks | nodestro-api | `src/nodestro_api/local_access.py` (`LocalAccessMiddleware`) |
| Profile start-up, key file, refusals | nodestro-api | `src/nodestro_api/local_container.py` |
| Image (target `local`) | nodestro-server | `image/Dockerfile`, `image/` scripts |
| Deployment | nodestro-local-docker | `compose.yaml`, `compose.extra-ca.yaml`, `nodestro`, `nodestro.ps1`, `scripts/` |
| End-to-end tests | nodestro-local-docker | `tests/e2e/test_local_docker.py` |
| Security model for users | nodestro-local-docker | `docs/SECURITY.md`, `docs/ARCHITECTURE.md` |

Use the master branch of each repository. Runtime PR #33 (request smuggling fix) must be merged; until then, review
its branch `claude/project-thread-5h8b7a`.

## 2. Threat model

**Assets.** In order of value:

1. the host: the Docker socket is root on rootful Linux;
2. the user's Nodestro data: the data volume, provider API keys and their encryption key, the access key;
3. the availability of the user's computer: disk, memory and CPU.

**Attackers.**

| ID | Attacker | Starting point | Must not be able to |
| --- | --- | --- | --- |
| A1 | Untrusted tool code (AI-generated tools and their tests) | Runs in a sandbox container: no network, nobody, read-only, no capabilities | leave the container; reach the network, the studio, the gateway or the Docker socket; exhaust the host |
| A2 | A compromised studio process | Full control of the `nodestro` container (user 10001, network, the gateway's socket) | use the gateway for anything beyond creating locked-down sandbox containers and building `nodestro-env:*` images; reach the host Docker socket; touch other containers, images, volumes or networks |
| A3 | A web page in the user's browser | Can make the browser send requests to `127.0.0.1:<port>`, and can use DNS rebinding | read or change anything in the studio |
| A4 | Another local program or user on the same computer, without Docker access | Can connect to `127.0.0.1:<port>`, and may run its own web server on another `localhost` port | use the studio without the access key |
| A5 | A device on the LAN | Network access to the host | reach the studio at all |

**Out of scope.** Anyone who can use Docker on the host or who controls the user's account: they can read every
volume. Kernel and container runtime vulnerabilities themselves are out of scope, but their impact is not (see
assumption S6).

## 3. Security assumptions

Each of these must hold. The reviewer should try to break each one.

- **S1.** The `nodestro` container never sees the host Docker socket. It sees only the gateway's socket, on the named
  volume `sandbox-socket`. Check `compose.yaml`.
- **S2.** The gateway reads each request head completely and strictly, decides on it, and forwards only bytes that
  it built itself from the checked parts: method, rebuilt target, a fixed set of headers, and its own body. No byte
  from the client reaches the daemon unparsed, except on an attach stream **after** the daemon has answered `101`.
  Check `parse_head`, `read_body`, `encode_request` and `Gateway._forward`.
- **S3.** The Docker daemon interprets each forwarded request exactly as the gateway did. Same method, path, query,
  body, and the same request boundaries on a kept-alive connection. Runtime PR #33 fixed a violation of S3.
- **S4.** Container create is an allow-list. Every `HostConfig` field that matters is either set by the gateway or
  must be absent or default; anything else is refused. Check `plan_create` and `_is_default`.
- **S5.** Containers can only be used (attach, start, wait, kill, remove, inspect) if the gateway created them. It
  tracks them by ID and label. Check `Gateway._known`, `reconcile` and `route`.
- **S6.** A sandbox container is as weak as Docker's default isolation plus the gateway's settings. An escape gives
  the attacker the daemon's privileges: root on rootful Linux, the user on rootless Docker, the VM on Docker Desktop.
- **S7.** An image build cannot run attacker-chosen code at build time and cannot produce an image other than
  `nodestro-env:<hash of the lock>`. The Dockerfile is fixed, the lock is hash-pinned, and only wheels are allowed.
  Check `plan_build` and `check_lock`.
- **S8.** Wheels installed into an image do not run at build time. A malicious `.pth` file or entry point runs only
  later, inside a sandbox container, as A1.
- **S9.** The studio answers only `127.0.0.1`, `localhost` and `[::1]` with the published port in `Host`. Changing
  requests and WebSockets are accepted only from exactly the request's own origin. Every route except
  `/api/health` and `/api/published/*` needs a session cookie or the bearer key. Check `local_access.py` and
  `launch.py`.
- **S10.** The access key is at least 32 characters, created with `O_EXCL` in mode 0600, never logged, and compared
  in constant time.
- **S11.** Without a working gateway, untrusted tool code does not run anywhere. It is never run in the `nodestro`
  container instead. Check `sandbox_policy.py` and the e2e test
  `test_without_the_gateway_tool_code_does_not_run_at_all`.

## 4. What the gateway allows

| Route | Method | Notes |
| --- | --- | --- |
| `/_ping`, `/version`, `/info` | GET, HEAD | Forwarded without a query. `/info` reveals host details (low). |
| `/images/{name}/json` | GET | `nodestro-env:*` only; the name is validated and the target rebuilt. |
| `/images/{name}` | DELETE | `nodestro-env:*` only. |
| `/build` | POST | Fixed Dockerfile, hash-pinned lock, the gateway's own Orkexa, computed tag; memory and CPU limits; one at a time; at most 64 MB context; BuildKit refused. |
| `/containers/create` | POST | Allow-list; forced settings are listed in `docs/SECURITY.md`, section 3. At most `NODESTRO_SANDBOX_MAX_CONTAINERS` at a time. |
| `/containers/{id}/attach`, `start`, `wait`, `kill`, `json`, `DELETE` | various | Only for the gateway's own containers. |

Everything else gets 403 or 404. The API version prefix `/v1.xx` is accepted and kept.

## 5. Tests that back the claims

**Gateway unit and protocol tests.** `tests/test_sandbox_gateway.py` holds 103 tests. The real-Docker tests need
`NODESTRO_DOCKER_TESTS=1` and a Docker daemon. They cover:

- every refused `HostConfig` field: privileged mode, capabilities, binds, mounts, volumes, devices, ports, host
  namespaces (network, PID, IPC, UTS, user, cgroup), runtimes, sysctls, security options, masked or read-only paths,
  users, links, extra hosts and more;
- forced settings and limits;
- foreign containers and images;
- build checks: Dockerfile, lock, tag, index options, Orkexa;
- the container limit and the reaper;
- added by PR #33:
  - `test_ambiguous_request_heads_are_refused` (12 heads: bare LF, bare CR, NUL, folding, bad method, version,
    fragment, absolute form, space in target, `*`, bad header name, CL+TE);
  - `test_a_smuggled_request_never_reaches_the_daemon`;
  - `test_forwarded_targets_are_rebuilt_from_what_was_checked`;
  - `test_a_large_body_is_refused_before_it_is_read`;
  - `test_client_bytes_pass_only_through_a_switched_attach`;
  - `test_raw_requests_cannot_smuggle_past_the_gateway` (against a real daemon);
- `test_tools_run_through_the_gateway_and_escapes_are_refused`, run against a real daemon.

**End-to-end tests.** `tests/e2e/test_local_docker.py` holds 14 tests that run against the built image with
`NODESTRO_IMAGE=nodestro-local:dev`. They cover:

- the loopback-only port;
- locked-down containers;
- the access key;
- Host and Origin checks;
- other containers reaching the studio;
- LAN access cannot be switched on;
- tool code runs only in sandbox containers (proved with `docker events` and the label);
- an escape attempt through the gateway from inside the studio container;
- no gateway means no tool code runs;
- persistence, backup and restore, update and rollback.

**Reproducing the fixed vulnerability.** On the code before PR #33, run against a real daemon:

```
GET /_ping HTTP/1.1\r\nHost: x\r\nUser-Agent: x\n\nGET /containers/json HTTP/1.1\nHost: x\r\n\r\n
```

The daemon returned the unfiltered container list. The test `test_raw_requests_cannot_smuggle_past_the_gateway`
encodes this.

## 6. Self-review by the implementing agent (not independent)

**Fixed in runtime PR #33.**

| # | Severity | Finding | Fix |
| --- | --- | --- | --- |
| F1 | Critical | Request smuggling: a bare LF in a forwarded header value split the request at the daemon. A second, unchecked request ran on the kept-alive connection. A2 had full Docker API access. | Strict `parse_head`; header values with control characters are refused. |
| F2 | Medium | Ping, version, info and image targets were forwarded as written, query included. | Targets are rebuilt from the checked parts. |
| F3 | Medium | Attach piped client bytes to the daemon before knowing whether the daemon switched protocols. On an error answer, those bytes could be read as a further request. | Client bytes pass only after `101`; otherwise the gateway relays the answer and closes. |
| F4 | Low | Every route accepted a 64 MB body. | Body limit chosen by route before reading. |
| F5 | Low | Builds had no memory or CPU limit. | `memory`, `memswap`, `cpuperiod`, `cpuquota`. |
| F6 | Low | `IpcMode`, `Binds`, `Mounts` and `Devices` were left to daemon defaults. | Set explicitly. |

**Checked and found to hold.** These were checked in a limited way and are not proven:

- `LocalAccessMiddleware` with `strict_origin`:
  - `*.localhost` names are answered, and browsers resolve them to loopback, so rebinding to them gains nothing;
  - a `Host` with two colons is refused;
  - `Origin: null` is refused.
- `LaunchSecretMiddleware`:
  - constant-time comparisons for the key and the sessions;
  - launch is GET only;
  - no login CSRF without the key;
  - the session cookie differs from the key.
- Gateway: absolute-form targets, fragments and `..` in paths are refused or harmless after rebuilding. Docker
  answers non-normalized paths with 301 and does not follow them.

**Known, not fixed.** These need the reviewer's opinion:

| # | Topic | Status |
| --- | --- | --- |
| K1 | **Disk exhaustion.** A2 can build any number of distinct `nodestro-env:*` images, one per distinct valid lock. Each needs downloads, but nothing caps their number or total size. | Open. A cap on the gateway's images is suggested. |
| K2 | **Connections.** The gateway has no limit on concurrent client connections or idle time per connection. A2 can tie up its memory (256 MB limit, its own container). | Open. DoS of the sandbox only. |
| K3 | `/info` reveals host details: kernel, CPUs, memory, driver, names. | Accepted, low. |
| K4 | **Build network.** Builds use the default bridge network, so the classic builder's `RUN` steps have network access. The Dockerfile is fixed, but pip itself runs with network. | Accepted (`docs/SECURITY.md` residual risk 5). |
| K5 | The launch link carries the key in the URL. The launchers avoid the process list, but the URL may stay in browser history. | Document. |
| K6 | **Docker Desktop.** Enhanced Container Isolation may refuse the socket mount. Docker Desktop's socket semantics differ: it runs in a VM, and an escape reaches the VM and its file shares. | Untested; see `docs/PLATFORMS.md`. |
| K7 | gVisor (`runsc`) as a forced runtime is not supported yet. | Next hardening step. |
| K8 | **Reconcile and reap races.** The gateway rebuilds its container list from labels at start. A2 cannot set labels: they are forced. Containers created by another holder of the host socket with the same label would count as the gateway's. | Accepted: such a holder is already root. |

## 7. Docker Engine and Docker Desktop

| Aspect | Docker Engine on Linux, rootful | Docker Engine on Linux, rootless | Docker Desktop (Windows, macOS) |
| --- | --- | --- | --- |
| Socket | `/var/run/docker.sock`, root | `$XDG_RUNTIME_DIR/docker.sock`, the user | `/var/run/docker.sock` inside the VM |
| Impact of an escape | host root | the user's account | the VM and the folders it shares |
| Gateway user | root, to open the socket | root inside the user namespace, which is the user outside | root in the VM |
| seccomp and AppArmor | Docker defaults | Docker defaults; some cgroup limits need cgroup v2 delegation | Docker defaults in the VM |
| Tested | yes (amd64, arm64) | see `docs/PLATFORMS.md` | **no** |

## 8. Questions for the reviewer

1. Can A2 make the daemon run anything other than what the gateway checked? Look at smuggling, header handling,
   chunked bodies, hijacked connections, and API version prefixes.
2. Can A2 create a container with weaker isolation than section 4 says? Consider fields that `plan_create` misses,
   newer API versions, `NetworkingConfig`, labels, `Healthcheck`, `Entrypoint` and `StopSignal`.
3. Can A2 reach a container, image, volume or network that the gateway did not create?
4. Can A1 reach the gateway, the studio, the network, or the host through anything the gateway allows?
5. Can a build run code or leak data at build time, or produce an image under a tag the runtime will trust?
6. Can A3 or A4 use the studio without the key?
7. Are the residual risks in `docs/SECURITY.md` and K1 to K8 correctly described and rated?

Please report findings with a severity, a reproduction and the affected file and line.
