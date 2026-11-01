# Nodestro Local Docker

Nodestro for one person, on your own computer, with nothing installed but Docker. Start Docker (or Docker Desktop),
start Nodestro, and use the studio in your normal browser. Workflows, agents and tools work as in the desktop app,
and your data stays in a Docker volume across stops, restarts and updates.

Nodestro Local Docker is the third way to run Nodestro, next to the desktop app and the multi-user server. It is the
same Nodestro (the same runtime, API and studio at the same pinned commits), built from the same image definition
as the server ([nodestro-server](https://github.com/peterkarlhuber/nodestro-server) `image/Dockerfile`, target
`local`). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for why.

> **Status: development preview, not released.** There are no published images yet: the launcher builds the image
> from source on first start. Only Linux x86_64 and Linux arm64 have been tested; see
> [docs/PLATFORMS.md](docs/PLATFORMS.md) before using it on Windows or macOS.

## What you need

- Docker Engine 24 or newer with the compose plugin (Linux), or Docker Desktop (Windows, macOS).
- git, to build the image (it fetches the pinned sources; no account or token is needed).
- About 3 GB of disk for the image and the tool environments.

No Python, Node.js, PostgreSQL or Nodestro app on your computer.

## Start

```sh
git clone https://github.com/peterkarlhuber/nodestro-local-docker.git
cd nodestro-local-docker
./nodestro start            # Windows (PowerShell): .\nodestro.ps1 start
```

The first start builds the image (several minutes). Then the launcher waits until Nodestro is healthy, prints the
address and opens your browser. The link contains your **access key**. Keep it private, like a password. Open
Nodestro again at any time with `./nodestro open`, or print the link with `./nodestro link`.

Nodestro listens only on `127.0.0.1` (default port 8765; another port: `NODESTRO_PORT=9000 ./nodestro start`).
Other computers on your network cannot reach it, and a browser without the access key gets only a sign-in hint.
The link opens your installation's own host name, `nodestro-<random>.localhost`, so that other local web servers
never receive your session cookie ([docs/SESSIONS.md](docs/SESSIONS.md)). A browser session lasts at most 24 hours
(8 hours without use); sign out at `/api/logout`, or end every session with `./nodestro logout`.

## Everyday commands

| Command | What it does |
| --- | --- |
| `./nodestro start` | Start Nodestro and open the browser |
| `./nodestro stop` | Stop it (data is kept) |
| `./nodestro restart` | Restart it |
| `./nodestro status` | Containers, health and whether the tool sandbox is available |
| `./nodestro open` / `link` | Open the browser / print the link with the access key |
| `./nodestro logout` | End every browser session (open Nodestro again with `open`) |
| `./nodestro logs [N]` | The last N log lines (the access key is never logged) |
| `./nodestro backup [FILE]` | Complete backup as a ZIP file (default: `backups/`) |
| `./nodestro restore FILE` | Restore a backup (the state before it is kept as a safety backup) |
| `./nodestro update` | Build the current version, back up, switch, roll back automatically on failure |
| `./nodestro rollback` | Go back to the version and data from before the last update |
| `./nodestro rotate-key` | Replace the access key and the host name (old links and sessions stop working) |
| `./nodestro uninstall` | Remove the containers, keep the data (`--delete-data`: remove everything) |

On Windows, `.\nodestro.ps1` has the same commands. `build` and `update` need `bash` and `git` (Git for Windows or
WSL) to build the image.

## Model providers

Enter provider API keys in the studio (Settings), as on the desktop. They are stored encrypted in the data volume,
never in the image. A key can also come from the environment of the `nodestro` service, in a `compose.override.yaml`
next to `compose.yaml` (the launcher adds it when it exists; it is not part of the repository). Behind a
TLS-inspecting proxy, set `NODESTRO_EXTRA_CA_FILE` to its certificate bundle (this also sets `AWS_CA_BUNDLE`,
because the AWS SDK ignores `SSL_CERT_FILE`).

**Amazon Bedrock (AWS)** has no API key and uses only the AWS default credential chain inside the `nodestro`
container. By default the container has **no AWS credentials**: no `AWS_*` variables and no `~/.aws`. To use
Bedrock, give it credentials in `compose.override.yaml`, either as a read-only mount of your `~/.aws`:

```yaml
services:
  nodestro:
    environment:
      AWS_CONFIG_FILE: /run/nodestro-aws/config
      AWS_SHARED_CREDENTIALS_FILE: /run/nodestro-aws/credentials
      AWS_PROFILE: work          # optional: a profile from your ~/.aws/config
    volumes:
      - ~/.aws:/run/nodestro-aws:ro
```

or as variables taken from your shell when you run `./nodestro start` (for example after
`eval "$(aws configure export-credentials --profile work --format env)"`; they expire like the session they come from):

```yaml
services:
  nodestro:
    environment:
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:?}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY:?}
      AWS_SESSION_TOKEN: ${AWS_SESSION_TOKEN:-}
```

Then choose the region in Settings. Never mount AWS credentials into the data volume (`/var/lib/nodestro`, the
container's home): backups include it. The mount is read-only, so IAM Identity Center (SSO) tokens cannot be refreshed
inside the container: run `aws sso login` on the host when they expire. The container runs as user 10001: on Linux,
your own `~/.aws` files (mode 600) are not readable by it, so use the variables there, or a separate folder readable
by user 10001. AI-generated tools never see these credentials (they run in separate sandbox containers). Network
access needed: `bedrock-runtime.<region>`, `bedrock.<region>` and `sts.<region>.amazonaws.com`.

## AI-generated tools

Tools that Nodestro's AI writes, and their tests, run only in separate, locked-down containers: no network, read-only,
no capabilities, user `nobody`, CPU, memory and process limits. They never run inside the Nodestro container. If that
sandbox is unavailable, such tools are blocked; there is no fallback. See [docs/SECURITY.md](docs/SECURITY.md),
which also explains what this protects against and what it does not. In short: on Linux, use rootless Docker with
cgroup v2 ([setup](docs/PLATFORMS.md#rootless-docker)).

## Data, backups and updates

- All data (workflows, runs, knowledge, settings, encrypted provider keys, the access key) lives in the volume
  `nodestro-local_data`. `stop`, `restart`, `update` and `uninstall` keep it.
- `./nodestro backup` writes the studio's own complete backup. `restore` reads it back, also on another computer.
- `./nodestro update` backs up to `backups/`, snapshots the volume, starts the new version and returns to the old
  one by itself if it does not start. `./nodestro rollback` returns later. Updates are reproducible: the version is
  exactly the commits in [components.json](components.json).

## Known limitations

- No published images. The first start builds from source, which takes several minutes and needs git.
- Only Linux (x86_64, arm64) is tested; see [docs/PLATFORMS.md](docs/PLATFORMS.md).
- MCP servers on your computer's `localhost` cannot be used. Inside the container, `localhost` is the container
  itself, and loopback MCP connections are allowed only in the desktop app. Remote MCP servers over HTTPS work.
- The desktop app's built-in Linux sandbox is not used. AI-generated tools need the sandbox containers, so Docker
  must be able to start them.
- One person only. For several people, use [nodestro-server](https://github.com/peterkarlhuber/nodestro-server).

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the decision (variants compared), components, what is reused
- [docs/SESSIONS.md](docs/SESSIONS.md): how browser sessions work (host name, lifetime, logout, browsers)
- [docs/SECURITY.md](docs/SECURITY.md): the security model, container and sandbox configuration, residual risks
- [docs/PLATFORMS.md](docs/PLATFORMS.md): what was tested where, and what was not
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): building, testing, pins, CI
- [docs/TODO.md](docs/TODO.md): open work (known gaps, reviews, platform tests)

## License

See [LICENSE](LICENSE). The image contains third-party packages under their own licenses; `scripts/manifest.sh`
writes the full inventory.
