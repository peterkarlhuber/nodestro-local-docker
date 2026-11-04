# Local models in Nodestro Local Docker

Nodestro Local Docker runs AI models on your own computer with [Ollama](https://ollama.com), without a cloud API
key: agents, assistants, and the embeddings of semantic knowledge search. Which model suits which task, the model
catalog, offline packages and knowledge search are the runtime's (nodestro-runtime `docs/local-models.md`); this page
covers the container setup.

## The containers

| Container | What it does | Configuration |
| --- | --- | --- |
| `ollama` | Ollama 0.40.14, the official `ollama/ollama` image pinned by the digest of its multi-platform index (linux/amd64, linux/arm64) | User 10001, read-only root, no capabilities, `no-new-privileges`, tmpfs `/tmp` (also its `$HOME`), `OLLAMA_NO_CLOUD=1`, `OLLAMA_CONTEXT_LENGTH=32768` (`NODESTRO_OLLAMA_CONTEXT_LENGTH`; Ollama's 4096-token default is too small for agents) |
| `models-init` | Hands the volume `models` to user 10001, then exits | Root with `CAP_CHOWN` only, no network, read-only |
| `network` | Holds the network namespace that `nodestro` and `ollama` share (`sleep`, user nobody, 32 MB); publishes the studio's port on 127.0.0.1 | No volume, read-only, no capabilities |
| `nodestro` | The studio; manages the models through Ollama's API | `NODESTRO_OLLAMA_URL=http://127.0.0.1:11434`, `NODESTRO_OLLAMA_MODELS_DIR=/var/lib/nodestro-models` |

```
┌─ network namespace of `network` ─────────────────────────────────────┐
│ [ nodestro ] ──127.0.0.1:11434 (loopback)──▶ [ ollama ] ──▶ internet │ (Ollama registry downloads)
└──────┬──────────────────────────────────────────────┬────────────────┘
       │  /var/lib/nodestro-models                    │  /models
       └──────────────── volume `models` ─────────────┘
       │  /import (read-only) ◀── ./import on the host
```

- **No published port, loopback only.** `ollama` runs in the same network namespace as the studio (that of the
  `network` container) and listens on 127.0.0.1:11434 only. The studio reaches it on that shared loopback. Nothing
  else can: not the host and its users (also on Linux with Docker Engine, which routes the host to container
  addresses), not other containers, and not AI-generated tools, which run in sandbox containers without any network.
  Ollama's API has no authentication, so this is its boundary. The small `network` container exists so that the
  namespace outlives restarts of either container: if `nodestro` or `ollama` crashes or is restarted, the other keeps
  working.
- **Downloads.** A model a person downloads in the studio is fetched by Ollama itself, over the studio's internet
  access (the shared namespace). Ollama also checks a model-recommendations cache at ollama.com every few hours; it
  sends no prompts or data. `NODESTRO_LOCAL_MODELS=offline` points Ollama's HTTP(S) proxy at a closed local port, so
  both fail; that is a setting of Ollama, not a network boundary (the studio itself keeps its internet access).
- **Models** live in the volume `models` (several GB per model). `stop`, `restart`, `update` and `uninstall` keep it;
  `uninstall --delete-data` removes it. Backups (`./nodestro backup`) do not contain the models: download or import
  them again after a restore on another computer.
- **CPU or GPU.** Ollama uses the CPU (all cores, as much memory as the model needs). The image contains the NVIDIA
  CUDA libraries, but the compose file passes no GPU: GPU use in this setup is not tested (docs/TODO.md, LD-016).
  Docker Desktop on macOS has no GPU access for containers at all; on a Mac, the desktop app is faster.

## Settings

| Variable | Meaning |
| --- | --- |
| `NODESTRO_LOCAL_MODELS=on` | The default: the local model server with downloads |
| `NODESTRO_LOCAL_MODELS=offline` | The model server without downloads (`compose.local-models-offline.yaml`: Ollama's outgoing requests go to a proxy address on which nothing listens). Models come only from offline imports; downloads in the studio fail. Together with the studio's strict offline mode, the installation uses no external model service |
| `NODESTRO_LOCAL_MODELS=off` | No model server (`compose.local-models-off.yaml`): saves the download of the Ollama image (about 3.4 GB on amd64, 2.8 GB on arm64; about 8.5 GB unpacked). Cloud providers and a model server you name yourself (the Ollama provider's base URL) still work |
| `NODESTRO_OLLAMA_MEMORY` | The model server's memory limit (default `16g`: room for the suggested 4B and 9B models with the 32768-token context window). A model that does not fit fails to load with an Ollama error; the studio and the computer keep running |
| `NODESTRO_OLLAMA_PIDS`, `NODESTRO_OLLAMA_CPUS` | Its process limit (default 2048) and CPU limit (default `0`: all cores; for example `4` leaves the rest to other work) |
| `NODESTRO_IMPORT_DIR` | The host folder for offline imports (default `import/` next to the launcher), read-only in the studio as `/import` |

The launcher remembers `NODESTRO_LOCAL_MODELS` (in `.nodestro/state.env`) until you set it again, so `stop`,
`update` and `rollback` keep the choice.

## Offline imports

Copy the files into the `import` folder, then choose them in the studio (Settings, local models) under `/import/…`:

- an **offline model package** (exported on a computer with internet access; every file is checked by SHA-256 and
  copied into the model volume), or
- a **GGUF file** (and an optional vision projector), which the studio hands to Ollama to create a model.

Behind a TLS-inspecting proxy, `NODESTRO_EXTRA_CA_FILE` also gives Ollama the proxy's certificate authority for
downloads. A proxy that needs `HTTPS_PROXY` can be set for the `ollama` service in `compose.override.yaml` (LD-007).
