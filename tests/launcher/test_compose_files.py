"""Which compose files the launchers pass to Docker, without Docker: a stand-in ``docker`` on PATH records each call.

    python3 -m pytest tests/launcher -v      (pwsh runs the Windows launcher too, when it is installed)

The proxy file (compose.proxy.yaml) comes only with NODESTRO_HTTPS_PROXY, after the CA file and before the offline
file, so NODESTRO_LOCAL_MODELS=offline still closes Ollama's downloads; the real compose files merge that way.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE_DOCKER = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_DOCKER_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
sys.exit(0)
"""

LAUNCHERS = [pytest.param(["bash", str(ROOT / "nodestro")], id="bash")]
if shutil.which("pwsh"):
    LAUNCHERS.append(pytest.param(["pwsh", "-NoProfile", "-File", str(ROOT / "nodestro.ps1")], id="pwsh"))


def compose_files(launcher: list[str], tmp_path: Path, **settings: str) -> list[str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "docker"
    fake.write_text(FAKE_DOCKER.replace("python3", Path(sys.executable).as_posix(), 1))
    fake.chmod(0o755)
    if os.name == "nt":  # pragma: no cover - the tests run on Linux
        pytest.skip("the stand-in docker is a script")
    log = tmp_path / "calls.jsonl"
    log.unlink(missing_ok=True)
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("NODESTRO_") and key not in ("DOCKER_HOST", "HTTPS_PROXY", "https_proxy")
    }
    env.update(PATH=f"{bin_dir}{os.pathsep}{env.get('PATH', '')}", FAKE_DOCKER_LOG=str(log))
    env.update(NODESTRO_STATE_DIR=str(tmp_path / "state"), NODESTRO_IMPORT_DIR=str(tmp_path / "import"), **settings)
    result = subprocess.run([*launcher, "stop"], env=env, capture_output=True, text=True, timeout=120, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    stop = next(call for call in calls if call[:1] == ["compose"] and call[-1] == "stop")
    return [Path(stop[i + 1]).name for i, arg in enumerate(stop) if arg == "-f"]


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_without_a_proxy_setting_there_is_no_proxy_file(launcher: list[str], tmp_path: Path) -> None:
    assert compose_files(launcher, tmp_path) == ["compose.yaml"]


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_the_proxy_file_comes_after_the_ca_file_and_before_the_offline_file(
    launcher: list[str], tmp_path: Path
) -> None:
    files = compose_files(
        launcher,
        tmp_path,
        NODESTRO_HTTPS_PROXY="http://proxy.example:3128",
        NODESTRO_EXTRA_CA_FILE="/etc/ssl/certs/ca-certificates.crt",
        NODESTRO_LOCAL_MODELS="offline",
    )
    assert files == [
        "compose.yaml",
        "compose.extra-ca.yaml",
        "compose.proxy.yaml",
        "compose.local-models-offline.yaml",
    ]


def _config(*files: str, **settings: str) -> dict:
    if not shutil.which("docker") or subprocess.run(["docker", "compose", "version"], capture_output=True).returncode:
        pytest.skip("docker compose is not installed")
    env = {**os.environ, **settings}
    args = ["docker", "compose", "--project-directory", str(ROOT)]
    for name in files:
        args += ["-f", str(ROOT / name)]
    output = subprocess.run([*args, "config", "--format", "json"], env=env, capture_output=True, text=True, check=True)
    return json.loads(output.stdout)


def test_the_proxy_reaches_the_studio_and_the_model_server_but_not_their_loopback() -> None:
    config = _config(
        "compose.yaml", "compose.proxy.yaml", NODESTRO_HTTPS_PROXY="http://proxy.example:3128",
        NODESTRO_NO_PROXY="intranet.example",
    )  # fmt: skip
    for service in ("nodestro", "ollama"):
        environment = config["services"][service]["environment"]
        assert environment["HTTPS_PROXY"] == environment["https_proxy"] == "http://proxy.example:3128"
        assert environment["NO_PROXY"] == environment["no_proxy"] == "127.0.0.1,localhost,::1,intranet.example"
    for service in ("gateway", "network", "models-init"):  # no outgoing requests of their own
        assert "HTTPS_PROXY" not in (config["services"][service].get("environment") or {})


def test_offline_mode_still_closes_the_model_servers_downloads_behind_a_proxy() -> None:
    config = _config(
        "compose.yaml", "compose.proxy.yaml", "compose.local-models-offline.yaml",
        NODESTRO_HTTPS_PROXY="http://proxy.example:3128",
    )  # fmt: skip
    assert config["services"]["ollama"]["environment"]["HTTPS_PROXY"] == "http://127.0.0.1:9"
    assert config["services"]["ollama"]["environment"]["NO_PROXY"] == ""
    assert config["services"]["nodestro"]["environment"]["HTTPS_PROXY"] == "http://proxy.example:3128"
