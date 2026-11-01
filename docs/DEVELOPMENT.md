# Developing Nodestro Local Docker

## Layout

| Path | What it is |
| --- | --- |
| `components.json` | The two full commit SHAs an image is built from (nodestro-studio, nodestro-server) |
| `compose.yaml` | The installation: services `nodestro` and `gateway`, volumes `data` and `sandbox-socket` |
| `compose.extra-ca.yaml` | Trust a TLS-inspecting proxy's CA (added by the launcher with `NODESTRO_EXTRA_CA_FILE`) |
| `compose.override.yaml` | Not in the repository: the user's own additions (provider keys, AWS credentials; README), added by the launcher when present |
| `nodestro`, `nodestro.ps1` | Launchers for Linux/macOS and Windows |
| `scripts/build-image.sh` | Builds the image: nodestro-server's `image/Dockerfile`, target `local`, at the pinned commits |
| `scripts/check-pins.sh` | Checks that both SHAs are on master and that the studio's own pins agree |
| `scripts/scan-image.sh` | Secret scan of every image layer (nodestro-server's `scan_secrets.py`) |
| `scripts/manifest.sh` | Image manifest and license inventory (nodestro-server's `release_manifest.py`) |
| `tests/e2e/` | End-to-end tests against the real image, compose file and launcher on a real Docker |
| `tests/model-stub/`, `tests/compose.test.yaml` | An OpenAI-compatible model stub for runs that call tools, for tests only |

There is no Nodestro logic here. A change to how Nodestro behaves belongs in the repository that owns it (see
[ARCHITECTURE.md](ARCHITECTURE.md)). After it is merged, the pins move here.

## Build

```sh
scripts/build-image.sh                     # nodestro-local:<studio12>-<server12>, also tagged nodestro-local:dev
NODESTRO_PLATFORM=linux/arm64 scripts/build-image.sh nodestro-local:arm64-dev   # another platform (QEMU or a real host)
```

The build needs Docker with buildx and network access to GitHub, PyPI, npm and download.docker.com. It needs no
token. Behind a TLS-inspecting proxy, set `NODESTRO_EXTRA_CA_FILE` (and `NODESTRO_BUILD_NETWORK=host` if bridge
containers cannot reach the proxy).

For development only, you can try unmerged components:

- `NODESTRO_OVERRIDES=<folder of wheels>` replaces pinned components with wheels you built.
- `NODESTRO_SERVER_SOURCE=<checkout>` builds from a local nodestro-server.

Both demand a `dev` tag, so such an image cannot be mistaken for a pinned one.

## Test

```sh
python3 -m venv .venv && .venv/bin/pip install pytest==8.4.2
NODESTRO_IMAGE=nodestro-local:dev .venv/bin/python -m pytest tests/e2e -v
```

The tests start their own installation (project `nodestro-e2e`, a random loopback port, a temporary state folder)
and remove it at the end, volumes included. They take about two to three minutes. What they check:

| Test | Checks |
| --- | --- |
| `test_the_port_is_published_on_the_host_loopback_only` | the only published port is on 127.0.0.1 |
| `test_the_containers_are_locked_down` | read-only, no capabilities, no-new-privileges, not privileged, studio user 10001, only the gateway has the host socket, gateway without network |
| `test_the_access_key_is_private_and_never_logged` | key file 0600 and owned by the studio user, not in any log or container setting |
| `test_without_the_key_only_health_answers` | 401 / sign-in page without a session |
| `test_the_link_opens_a_session_and_scripts_use_the_key` | launch link gives a browser session, scripts use `Authorization: Bearer` |
| `test_foreign_host_names_and_origins_are_refused` | DNS rebinding (Host), another localhost port as Origin, `Origin: null` |
| `test_other_containers_cannot_use_the_studio_through_its_address` | a container on the same Docker network gets 403 |
| `test_network_access_for_published_apis_cannot_be_switched_on` | `lan.unavailable` |
| `test_tool_code_runs_only_in_locked_down_sandbox_containers` | an AI-generated tool and its tests run in gateway containers (Docker events, labels, settings), also in a real run with the model stub |
| `test_the_studio_cannot_escape_through_the_gateway` | from inside the studio container: privileged, bind mounts, host network, exec, other images, foreign containers are refused |
| `test_without_the_gateway_tool_code_does_not_run_at_all` | gateway stopped: the tool is blocked, nothing runs in the studio container |
| `test_data_survives_stop_restart_and_recreation` | stop/start, `down`/`up` keep workflows and the key |
| `test_backup_and_restore_through_the_launcher` | `./nodestro backup`, delete, `./nodestro restore` |
| `test_update_and_rollback_keep_the_data` | `./nodestro update` to another image and `./nodestro rollback` |

What code inside a sandbox container can reach (network, files, users, limits) is tested where the gateway lives:
nodestro-runtime `tests/test_sandbox_gateway.py` (`NODESTRO_DOCKER_TESTS=1` for the real-Docker test).

Checks without Docker:

```sh
shellcheck nodestro scripts/*.sh
ruff check tests
docker compose -f compose.yaml config -q
scripts/check-pins.sh
```

## CI

`.github/workflows/ci.yml` runs on every pull request and push to master, without secrets:

- **lint**: shellcheck, a parse of the PowerShell launcher, compose files, ruff, pins.
- **windows-launcher**: the PowerShell launcher's own code on Windows PowerShell 5.1 and PowerShell 7. Windows runners
  have no Linux containers, so this job does not start Nodestro.
- **image** on real `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) runners: build, all end-to-end tests,
  secret scan, and the manifest with license inventory as an artifact. Nothing is pushed to a registry and nothing
  is released.

## Moving the pins

1. Merge the component change and cascade the pins as usual: runtime, examples and integrations, api, sdk, studio
   (`scripts/check_versions.py` in the studio must report that the pins agree).
2. If the image definition changed, merge it in nodestro-server.
3. Set both SHAs in `components.json` (merge commits on master) and open a pull request. CI builds and tests the
   image on both architectures.

## Known build details

- The image sets `DOCKER_BUILDKIT=0`. The gateway accepts only classic builds (`POST /build` with a tar context),
  because a BuildKit session would be an open tunnel to the daemon.
- If Docker Hub answers 429 (rate limit), configure a registry mirror in the daemon
  (`"registry-mirrors": ["https://mirror.gcr.io"]`).
