# Developing Nodestro Local Docker

## Layout

| Path | What it is |
| --- | --- |
| `components.json` | The two full commit SHAs an image is built from (nodestro-studio, nodestro-server) |
| `compose.yaml` | The installation: services `nodestro` and `gateway`, volumes `data` and `sandbox-socket` |
| `compose.extra-ca.yaml` | Trust a TLS-inspecting proxy's CA (added by the launcher with `NODESTRO_EXTRA_CA_FILE`) |
| `compose.proxy.yaml` | An HTTP(S) proxy for the studio and the model server (added by the launcher with `NODESTRO_HTTPS_PROXY`) |
| `compose.override.yaml` | Not in the repository: the user's own additions (provider keys, AWS credentials; README), added by the launcher when present |
| `nodestro`, `nodestro.ps1` | Launchers for Linux/macOS and Windows |
| `scripts/build-image.sh` | Builds the image: nodestro-server's `image/Dockerfile`, target `local`, at the pinned commits |
| `scripts/check-pins.sh` | Checks that both SHAs are on master and that the studio's own pins agree |
| `scripts/scan-image.sh` | Secret scan of every image layer (nodestro-server's `scan_secrets.py`) and, from a server pin that has it, the vulnerability scan (`scan-vulnerabilities.sh`: pip-audit and Trivy) |
| `scripts/manifest.sh` | Image manifest and license inventory (nodestro-server's `release_manifest.py`) |
| `tests/e2e/` | End-to-end tests against the real image, compose file and launcher on a real Docker |
| `tests/launcher/` | The compose files the launchers choose (a stand-in `docker`), and how the files merge (`docker compose config`) |
| `scripts/pin-distance.sh` | Warns when the pins lag behind studio or server master (nodestro-server's `pin_distance.py`) |
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
| `test_the_aws_sdk_is_in_the_image_but_no_aws_credentials_are` | boto3 and the Bedrock provider are in the image, but without a `compose.override.yaml` the container has no `AWS_*` credential variables and no `~/.aws` |
| `test_the_access_key_is_private_and_never_logged` | key file 0600 and owned by the studio user, not in any log or container setting |
| `test_without_the_key_only_health_answers` | 401 / sign-in page without a session |
| `test_the_link_opens_a_session_and_scripts_use_the_key` | launch link gives a browser session, scripts use `Authorization: Bearer` |
| `test_browser_sessions_exist_only_under_the_installation_s_host_name` | the launch link opens no session on `127.0.0.1` or `localhost` (`access.launch_host`), and a session cookie sent there is refused |
| `test_only_the_published_port_is_answered` | a `Host` with another port gets 403 `request.port_not_allowed` |
| `test_logout_ends_the_session_and_the_launcher_ends_all` | `/api/logout` ends one session (not from another origin), `./nodestro logout` ends all |
| `test_foreign_host_names_and_origins_are_refused` | DNS rebinding (Host), another localhost port as Origin, `Origin: null` |
| `test_other_containers_cannot_use_the_studio_through_its_address` | a container on the same Docker network gets 403 |
| `test_network_access_for_published_apis_cannot_be_switched_on` | `lan.unavailable` |
| `test_tool_code_runs_only_in_locked_down_sandbox_containers` | an AI-generated tool and its tests run in gateway containers (Docker events, labels, settings), also in a real run with the model stub |
| `test_the_studio_cannot_escape_through_the_gateway` | from inside the studio container: privileged, bind mounts, host network, exec, other images, foreign containers are refused |
| `test_without_the_gateway_tool_code_does_not_run_at_all` | gateway stopped: the tool is blocked, nothing runs in the studio container |
| `test_data_survives_stop_restart_and_recreation` | stop/start, `down`/`up` keep workflows and the key |
| `test_backup_and_restore_through_the_launcher` | `./nodestro backup`, delete, `./nodestro restore` |
| `test_update_and_rollback_keep_the_data` | `./nodestro update` to another image and `./nodestro rollback` |

`tests/e2e/test_upgrade.py` (skipped in the run above) upgrades a real installation of an older image: the image of
the previous pins in `tests/upgrade-from.json` with data is updated to the current image, a backup written by the old
version is restored by the new one, and `./nodestro rollback` returns to the old image with its data:

```sh
NODESTRO_COMPONENTS=tests/upgrade-from.json scripts/build-image.sh nodestro-local:upgrade-from
scripts/build-image.sh
NODESTRO_IMAGE=nodestro-local:upgrade-from NODESTRO_UPGRADE_TO=nodestro-local:dev \
  .venv/bin/python -m pytest tests/e2e/test_upgrade.py -v
```

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

`.github/workflows/upgrade.yml` runs `tests/e2e/test_upgrade.py` (two image builds, so not on every pull request): on
pull requests and pushes that change the pins or the test, weekly, and on demand.

## Moving the pins

1. Merge the component change and cascade the pins as usual: runtime, examples and integrations, api, sdk, studio
   (`scripts/check_versions.py` in the studio must report that the pins agree).
2. If the image definition changed, merge it in nodestro-server.
3. Set both SHAs in `components.json` (merge commits on master) and open a pull request. CI builds and tests the
   image on both architectures. The upgrade workflow upgrades an installation of `tests/upgrade-from.json`'s image to it; move
   that file forward only to pins that users really have installed (a release), never to the new ones.

## Known build details

- The image sets `DOCKER_BUILDKIT=0`. The gateway accepts only classic builds (`POST /build` with a tar context),
  because a BuildKit session would be an open tunnel to the daemon.
- If Docker Hub answers 429 (rate limit), configure a registry mirror in the daemon
  (`"registry-mirrors": ["https://mirror.gcr.io"]`).
