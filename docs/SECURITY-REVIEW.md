# Security review package: sandbox gateway and local access control

This package is for an **independent** security review of Nodestro Local Docker. The implementing agent has reviewed
its own code (section 6), but that does not count as an independent review. Until a separate reviewer has worked
through this package, the independent review is **open**.

Section 9 records an **internal defensive cross-check** (2026-10-31) of assumptions S1 to S11 and of K1 to K8. It was
done by reading code, architecture and existing tests and comparing them with CI results. It is **not** an
independent security review and not a penetration test. An adversarial analysis by a separate agent was stopped by
a safety filter and was not continued. A review by another qualified reviewer is still required.

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

Use the master branch of each repository. Runtime PR #33 (request smuggling fix) is merged
(merge commit `1ec9c3545fcc7c9ec0c25ef91db2008540cdd2a1`). Runtime PR #37 (refuse to run without enforced resource
limits) follows it.

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

## 9. Internal defensive cross-check (2026-10-31, not an independent review)

**What this is.** A second agent, which did not write this code, compared each assumption with the code, the
architecture documents, the existing automated tests and their CI results. It wrote no new attack payloads and did
no penetration testing. Its adversarial analysis was stopped by a safety filter and was not continued. Treat this
section as a consistency check that helps the independent reviewer. It is not a replacement for one.

**Code reviewed.** nodestro-runtime master `1ec9c35` (with PR #33) and PR #37 (`8d4f21e`). nodestro-api master
`262fb4d`. nodestro-local-docker PR #2 (`779f37a`). Line numbers refer to those commits.

**Evidence for PR #33.**
- CI run 41238351823 on `263b8a6` is green. The `docker` job ran 123 tests of `test_container_images.py` and
  `test_sandbox_gateway.py`, all passed, with `NODESTRO_DOCKER_TESTS=1` and `NODESTRO_REQUIRE_DOCKER=1`.
- Locally without Docker: 101 gateway tests passed and 2 real-Docker tests were skipped. The full suite gave 884
  passed and 167 skipped.
- The five new protocol tests fail against the pre-fix gateway (`7bf6e02`) and pass after the fix. On the old code,
  `test_a_large_body_is_refused_before_it_is_read` hangs instead of failing, because the old code reads the whole
  body before refusing.

**Rating.**
- **Supported:** shown by code and by tests that ran green in CI.
- **Partly supported:** the code supports the claim, but tests or platforms are missing.
- **Not checked:** not verifiable by reading code and running existing tests.
- **Open risk:** known and not fixed.

### 9.1 Assumptions S1 to S11

| # | Code | Tests (result) | Rating | Open points |
| --- | --- | --- | --- | --- |
| S1 | `compose.yaml`: only `gateway` mounts `${NODESTRO_DOCKER_SOCKET}`; `nodestro` gets volume `sandbox-socket` only. Socket mode 0660, group 10001 (`sandbox_gateway.serve`, umask 0117). | e2e `test_the_containers_are_locked_down` (green, amd64 and arm64). | Supported (Linux) | Docker Desktop: not tested. Sandbox containers get no mounts at all (S4), so A1 never sees either socket. |
| S2 | `parse_head` (l. 555), `read_body` (l. 603), `encode_request` (l. 636), `_forward` (l. 880). Only `User-Agent`, `Content-Type` and `Accept` are copied, and their values have no control characters. Framing (`Content-Length`) is always the gateway's. Non-attach requests carry `Connection: close`. | 12 heads in `test_ambiguous_request_heads_are_refused`, plus `..._smuggled_request_never_reaches_the_daemon`, `..._targets_are_rebuilt...`, `..._large_body...` and `..._switched_attach` (green; fail before the fix). | Supported for the tested classes | Chunk sizes are parsed with `int(x, 16)`, which also accepts `0x`, `_` and signs. That is not a boundary problem, because the gateway re-frames the body. Robustness only; a strict hex check is recommended. No fuzzing. |
| S3 | `Connection: close` on every non-attach request and a rebuilt target are a second barrier besides strict parsing. | `test_raw_requests_cannot_smuggle_past_the_gateway` against Docker 29.x (green). | Partly supported | Only checked against the Docker version of the CI and dev machines. Docker Desktop and older Engine versions are not checked. |
| S4 | `plan_create` (l. 177) builds the forwarded body **from scratch**. Only `Image` (regex), `Cmd`, `Env`, the attach flags and limits at or below the maxima come from the client. | `test_a_container_outside_the_sandbox_shape_is_refused`, `..._missing_isolation_flags_are_added...`, `test_a_created_container_is_locked_down_and_usable` (real Docker, green). | Partly supported | The allow-list is sound. But the daemon can silently drop limits (rootless without cgroup v2 delegation), so the forced limits may not apply. PR #37 now refuses then (see K9). The daemon's default seccomp profile, default runtime and userns settings are not checked (see 9.3). |
| S5 | `Gateway._known` (l. 725): an exact 64-hex ID or a recorded name, and the forwarded target always uses the full ID. `reconcile` (l. 734) by label. | `test_containers_the_gateway_did_not_create_cannot_be_used`, `test_refused_requests_never_reach_the_daemon`, e2e `test_the_studio_cannot_escape_through_the_gateway` (green). | Supported | K8 applies. An auto-removed container stays in the map until the next `reconcile` (up to 10 s); this only matters to another holder of the host socket. |
| S6 | Statement about Docker isolation, not code. | None possible. | Not checked | Rootless, Docker Desktop and gVisor are untested. The description in `SECURITY.md` residual risk 1 is accurate. |
| S7 | `plan_build` (l. 377): exact Dockerfile, `check_lock` (l. 360), the Orkexa files must be identical, and the tag is computed. `container_images._DOCKERFILE`: `pip download --only-binary=:all: --require-hashes`, then `pip install --no-index`. | `test_the_runtime_s_image_build_is_accepted`, `test_a_build_is_refused_when_anything_differs`, `test_a_link_in_the_build_context_is_refused`, `test_only_exact_hashed_locks_are_built` (green). | Partly supported | `ca.pem` is only checked to start with a PEM header. The base image `python:X-slim` is pulled by tag, not by digest. The tar context is decompressed (`r:*`) and read fully into memory without a limit on the unpacked size (see K2). Builds have network access (K4). |
| S8 | `_DOCKERFILE` runs no Python after `pip install`, so a `.pth` file or entry point in a wheel first runs in a sandbox container. | Covered indirectly: the Dockerfile must match exactly. | Supported (by code) | A future change that adds a `RUN python ...` step after the install would break S8. A comment in `_DOCKERFILE` is recommended. |
| S9 | `local_access.py` `_host_allowed` (l. 148) and `_origin_allowed` (l. 153), `strict_origin=local` (`app.py` l. 152); `LaunchSecretMiddleware`. | api `test_local_access.py` and `test_launch.py` (22 tests), `test_local_container.py` (18); e2e `test_without_the_key_only_health_answers`, `test_foreign_host_names_and_origins_are_refused`, `test_other_containers_cannot_use_the_studio_through_its_address` (green). | Partly supported | (a) The claim "with the published port in `Host`" is not what the code does: every loopback name and every port is accepted. That is harmless for DNS rebinding, but the text needs correcting. (b) The session cookie and residual risk 3 are understated (see D1 in 9.3). (c) Sessions have no lifetime and no logout; up to 64 stay valid until the process restarts. |
| S10 | `local_container.create_access_key` (l. 88): `token_urlsafe(32)` gives 43 characters; the staging file is opened with `O_EXCL` and mode 0600, then `os.replace`. `read_access_key` refuses group- or world-readable files. `hmac.compare_digest` is used for the key, the bearer token and the sessions (`launch.py` l. 150-189). `_redact` removes `token=` from the access log. | e2e `test_the_access_key_is_private_and_never_logged` (green); api unit tests. | Supported | The key in the launch URL may stay in the browser history (K5). |
| S11 | `sandbox_policy.SandboxPolicy`: outside the desktop, everything except `trusted` needs a container, and `check_construction` forbids host subprocess sandboxes. There is no fallback. | `test_sandbox_policy.py` (policy matrix and no-host-sandbox tests), e2e `test_without_the_gateway_tool_code_does_not_run_at_all` (green). | Supported | `trusted` (built-in tools, installed integrations) runs in process by design. |

### 9.2 Known points K1 to K8 (and K9)

| # | Description correct? | Risk realistic? | Missing protection | Test coverage | Recommendation |
| --- | --- | --- | --- | --- | --- |
| K1 Disk | Yes. | Yes, medium for a local single-user install. Only A2, an already compromised studio, can trigger it, but it fills the host's disk, not just the sandbox. | No cap on the number or total size of `nodestro-env:*` images. | None. | Gateway: refuse a build once N images or X GB of `nodestro-env:*` exist (`/images/json` with a label filter), and report it as 507/429. Document `nodestro prune`. |
| K2 Connections | Incomplete. Besides idle connections: each queued build holds up to 64 MB in memory **before** it waits for the build semaphore, and the tar context is decompressed into memory without a limit on the unpacked size. A few concurrent build requests can exceed the gateway's 256 MB. | Yes, DoS of the sandbox only. On a restart the gateway removes all running sandbox containers (`reconcile(remove_all=True)`). | Connection limit, idle and head-read timeouts, a build queue limit, and a cap on the unpacked size and member count. | None. | Refuse a second build with 429 instead of queueing it. Time out head reads (e.g. 10 s). Cap connections (e.g. 32). Accept only an uncompressed tar, or cap the unpacked bytes. |
| K3 /info | Yes. | Low. | | | Accept. PR #37 now relies on `/info` itself. |
| K4 Build network | Yes. | Low to medium: pip runs with network, but only hash-pinned wheels are installed. | No digest pin of the base image. | Partly (exact Dockerfile). | Pin `python:X-slim@sha256:...`. Longer term, download in the studio and build with `--network none`. |
| K5 Key in URL | Yes. | Low. | | e2e checks that the logs hold no key. | Document. Optionally make one-time launch tokens that are exchanged for a session. |
| K6 Docker Desktop | Yes. Untested. | Unknown. | No CI or test system. | None. | Real test on Win11 and macOS: ECI, socket mount, cgroup limits in the VM (`/info` check from PR #37), `127.0.0.1` binding. |
| K7 gVisor | Yes. | | | None. | Make gVisor an optional forced runtime, with a test where `runsc` is available. |
| K8 Label race | Yes, accepted. | Low: only a holder of the host socket can do it. | | `test_expired_and_leftover_containers_are_removed`. | Accept. |
| **K9 Limits not enforced** (new, found in the rootless e2e run by the Local Docker thread) | Not in the package before. | **Medium to high:** on rootless Docker without cgroup v2 delegation, Docker silently drops memory, CPU and pids limits, so tool code runs unlimited. | Fixed in **runtime PR #37**: create and build are refused with 503 until `/info` confirms `MemoryLimit`, `PidsLimit`, `CpuCfsQuota` and `CpuCfsPeriod`. | Unit tests in #37; real rootless run by the Local Docker thread. | After merge, also inspect each created container's `HostConfig` limits as a second check. Document cgroup v2 delegation for rootless setups. |

### 9.3 Further observations (defensive, not reproduced as attacks)

| # | Severity | Observation | Where | Recommendation |
| --- | --- | --- | --- | --- |
| D1 | Medium | **The session cookie reaches every program on `localhost`.** Browsers send cookies for a host name to every port of it (RFC 6265). Residual risk 3 in `SECURITY.md` only says that the browser could send the cookie *to Nodestro*. But when the user opens another local program's page under the same host name (`localhost` or `127.0.0.1`), the browser also sends `nodestro_local_session` to **that program's server**. That server can then use the session from a non-browser client, where the Origin check does not apply. `HttpOnly` does not prevent this. This matches attacker A4 in section 2. This conclusion follows from cookie semantics; it was not reproduced in a browser here. | api `launch.py` l. 208; `SECURITY.md` residual risk 3 | Document this correctly now. Design change, to be documented before implementation: let the launcher open a dedicated host name such as `http://nodestro-<port>.localhost:<port>`, because host-only cookies are not sent to `localhost:3000`, and refuse cookie sessions under other names. Also give sessions a lifetime and add a logout. |
| D2 | Low | Daemon-wide defaults are trusted: seccomp profile, default runtime, userns-remap and `no-new-privileges` defaults. An administrator setting such as `seccomp-profile=unconfined` would weaken every sandbox. | `plan_create` | Following PR #37, also check `SecurityOptions` in `/info` (`name=seccomp`, not `unconfined`) and refuse otherwise. |
| D3 | Low | The host check accepts every loopback name and every port; the documentation says "with the published port". | api `local_access.py` l. 148 | Correct the documentation or check the port. |
| D4 | Info | `ca.pem` is checked only by prefix. | `plan_build` l. 452 | Parse it as PEM certificates only. |

### 9.4 Not checked here

- Behavior on Docker Desktop (Windows, macOS), ECI, and other Docker Engine versions.
- Rootless Docker (being tested by the Local Docker thread; see K9).
- Fuzzing of the HTTP parser and the create allow-list; an adversarial review of the API surface.
- Kernel and runtime escapes (S6).

### 9.5 Verdict of the cross-check

The critical request smuggling fix (PR #33) is merged, its regression tests are effective, and CI with a real
daemon is green. Assumptions S1, S2 (for the tested classes), S5, S8, S10 and S11 are supported by code and tests.
S3, S4, S7 and S9 are partly supported. S6 is not verifiable this way. The most important open items are K9 (fixed
by PR #37), D1 (cookie scope), K1 and K2 (resource exhaustion by A2), and the untested Docker Desktop and rootless
platforms. **The independent review stays open.**
