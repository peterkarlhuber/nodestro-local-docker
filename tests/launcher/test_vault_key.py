"""The key file for the secrets (LD-020), without Docker: a stand-in ``docker`` on PATH records each call.

The launchers create the key file once (32 random bytes, base64) outside this folder, with the current user's access
only, refuse one that is open to others, add compose.vault-key.yaml only for an image that supports it, hand Docker
only the file's path, run every ``exec`` as the studio's user, and rotate or replace the key only on request.
The real container's side is covered by tests/e2e.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE_DOCKER = """#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "key_file": os.environ.get("NODESTRO_VAULT_KEY_HOST_FILE")}) + "\\n")
if args[:2] == ["image", "inspect"] and "--format" in args:
    print(os.environ.get("FAKE_DOCKER_LABEL", ""))
sys.exit(0)
"""

LAUNCHERS = [pytest.param(["bash", str(ROOT / "nodestro")], id="bash")]
if shutil.which("pwsh"):
    LAUNCHERS.append(pytest.param(["pwsh", "-NoProfile", "-File", str(ROOT / "nodestro.ps1")], id="pwsh"))

if os.name == "nt":  # pragma: no cover - the tests run on Linux
    pytest.skip("the stand-in docker is a script", allow_module_level=True)


def run(
    launcher: list[str], tmp_path: Path, *args: str, label: str = "1", **settings: str
) -> tuple[subprocess.CompletedProcess[str], list[dict]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "docker"
    fake.write_text(FAKE_DOCKER.replace("python3", Path(sys.executable).as_posix(), 1))
    fake.chmod(0o755)
    log = tmp_path / "calls.jsonl"
    log.unlink(missing_ok=True)
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("NODESTRO_") and key not in ("DOCKER_HOST", "HTTPS_PROXY", "https_proxy")
    }
    env.update(PATH=f"{bin_dir}{os.pathsep}{env.get('PATH', '')}", FAKE_DOCKER_LOG=str(log), FAKE_DOCKER_LABEL=label)
    env.update(
        NODESTRO_STATE_DIR=str(tmp_path / "state"),
        NODESTRO_IMPORT_DIR=str(tmp_path / "import"),
        NODESTRO_VAULT_KEY_FILE=str(tmp_path / "keys" / "vault.key"),
        NODESTRO_NO_BROWSER="1",
    )
    env.update(settings)
    result = subprocess.run([*launcher, *args], env=env, capture_output=True, text=True, timeout=120, check=False)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return result, calls


def compose_call(calls: list[dict], last: str) -> dict:
    return next(call for call in calls if call["args"][:1] == ["compose"] and call["args"][-1] == last)


def files(call: dict) -> list[str]:
    args = call["args"]
    return [Path(args[i + 1]).name for i, arg in enumerate(args) if arg == "-f"]


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_the_key_file_is_created_once_private_and_outside_the_folder(launcher: list[str], tmp_path: Path) -> None:
    result, calls = run(launcher, tmp_path, "stop")
    assert result.returncode == 0, result.stdout + result.stderr
    key = tmp_path / "keys" / "vault.key"
    text = key.read_text()
    assert len(base64.b64decode(text.strip())) == 32 and text.endswith("\n")
    assert stat.S_IMODE(key.stat().st_mode) == 0o600 and stat.S_IMODE(key.parent.stat().st_mode) == 0o700
    assert "Created the key file" in result.stdout + result.stderr
    stop = compose_call(calls, "stop")
    assert files(stop) == ["compose.yaml", "compose.vault-key.yaml"]
    # Docker gets the file's path, never the key.
    assert stop["key_file"] == str(key)
    assert all(text.strip() not in json.dumps(call) for call in calls)
    assert not list(key.parent.glob(".vault-key-*"))

    again, _ = run(launcher, tmp_path, "stop")
    assert again.returncode == 0 and key.read_text() == text  # never replaced
    assert "Created the key file" not in again.stdout + again.stderr


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_an_image_before_the_key_file_runs_without_it(launcher: list[str], tmp_path: Path) -> None:
    result, calls = run(launcher, tmp_path, "stop", label="")
    assert result.returncode == 0, result.stdout + result.stderr
    assert files(compose_call(calls, "stop")) == ["compose.yaml"]
    assert not (tmp_path / "keys").exists()


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_a_key_file_open_to_others_is_refused(launcher: list[str], tmp_path: Path) -> None:
    run(launcher, tmp_path, "vault-key")
    key = tmp_path / "keys" / "vault.key"
    key.chmod(0o644)
    result, calls = run(launcher, tmp_path, "start")
    output = result.stdout + result.stderr
    assert result.returncode != 0 and ("read by others" in output or "open to others" in output), output
    assert not any(call["args"][:1] == ["compose"] and "up" in call["args"] for call in calls)
    key.chmod(0o600)
    key.parent.chmod(0o755)
    result, _ = run(launcher, tmp_path, "start")
    assert result.returncode != 0 and "open to others" in result.stdout + result.stderr


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_a_key_file_inside_the_folder_is_refused(launcher: list[str], tmp_path: Path) -> None:
    result, _ = run(launcher, tmp_path, "vault-key", NODESTRO_VAULT_KEY_FILE=str(ROOT / "keys" / "vault.key"))
    assert result.returncode != 0 and "must not be inside" in result.stdout + result.stderr
    assert not (ROOT / "keys").exists()


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_commands_in_the_container_run_as_the_studio_s_user(launcher: list[str], tmp_path: Path) -> None:
    _, calls = run(launcher, tmp_path, "logout")
    (logout,) = [call for call in calls if "exec" in call["args"]]
    args = logout["args"]
    assert args[args.index("exec") :][:4] == ["exec", "-T", "--user", "10001:10001"]


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_a_new_key_after_a_loss_needs_a_confirmation(launcher: list[str], tmp_path: Path) -> None:
    result, calls = run(launcher, tmp_path, "accept-new-vault-key")
    assert result.returncode != 0 and "--yes" in result.stdout + result.stderr
    assert calls == []
    result, calls = run(launcher, tmp_path, "accept-new-vault-key", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    boots = [call["args"] for call in calls if call["args"][:1] == ["run"]]
    assert [args[-2:] for args in boots] == [["boot", "discard-unreadable"]] * 2  # the data and the rollback copy
    assert all("--network" in args and "none" in args and "10001" not in args[-3] for args in boots)


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_a_rotation_seals_both_volumes_and_then_replaces_the_key_file(launcher: list[str], tmp_path: Path) -> None:
    run(launcher, tmp_path, "vault-key")
    key = tmp_path / "keys" / "vault.key"
    old = key.read_text()
    result, calls = run(launcher, tmp_path, "rotate-vault-key")
    assert result.returncode == 0, result.stdout + result.stderr
    new = key.read_text()
    assert new != old and len(base64.b64decode(new.strip())) == 32
    assert stat.S_IMODE(key.stat().st_mode) == 0o600 and not (tmp_path / "keys" / "vault.key.new").exists()
    order = []
    for call in calls:
        args = call["args"]
        if args[:1] == ["compose"] and "stop" in args:
            order.append("stop")
        elif args[:1] == ["compose"] and "up" in args:
            order.append("up")
        elif args[:1] == ["run"] and args[-1] == "rekey":
            order.append("rekey")
    assert order == ["stop", "rekey", "rekey", "up"]
    for call in calls:
        if call["args"][-1] == "rekey":
            mounts = [arg for arg in call["args"] if arg.startswith("type=bind")]
            assert mounts == [
                f"type=bind,source={key},target=/run/secrets/nodestro-vault-key,readonly",
                f"type=bind,source={key}.new,target=/run/secrets/nodestro-vault-key-new,readonly",
            ]
    assert all(old.strip() not in json.dumps(call) and new.strip() not in json.dumps(call) for call in calls)


@pytest.mark.parametrize("launcher", LAUNCHERS)
def test_uninstall_with_the_data_removes_the_key_file(launcher: list[str], tmp_path: Path) -> None:
    run(launcher, tmp_path, "vault-key")
    result, _ = run(launcher, tmp_path, "uninstall", "--delete-data")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / "keys").exists()
    run(launcher, tmp_path, "vault-key")
    result, _ = run(launcher, tmp_path, "uninstall")
    assert (tmp_path / "keys" / "vault.key").exists()  # kept with the data


def _config(*names: str, **settings: str) -> dict:
    if not shutil.which("docker") or subprocess.run(["docker", "compose", "version"], capture_output=True).returncode:
        pytest.skip("docker compose is not installed")
    args = ["docker", "compose", "--project-directory", str(ROOT)]
    for name in names:
        args += ["-f", str(ROOT / name)]
    output = subprocess.run(
        [*args, "config", "--format", "json"], env={**os.environ, **settings}, capture_output=True, text=True
    )
    assert output.returncode == 0, output.stderr
    return json.loads(output.stdout)


def test_the_key_file_is_a_read_only_mount_and_boot_has_three_capabilities(tmp_path: Path) -> None:
    key = tmp_path / "vault.key"
    key.write_text(base64.b64encode(os.urandom(32)).decode() + "\n")
    studio = _config("compose.yaml", "compose.vault-key.yaml", NODESTRO_VAULT_KEY_HOST_FILE=str(key))["services"][
        "nodestro"
    ]
    (mount,) = [item for item in studio["volumes"] if item["target"] == "/run/secrets/nodestro-vault-key"]
    assert mount["type"] == "bind" and mount["source"] == str(key) and mount["read_only"] is True
    assert studio["user"] == "0:0" and studio["entrypoint"] == ["nodestro-local", "boot"]
    assert studio["command"] == ["serve"]
    assert sorted(studio["cap_add"]) == ["DAC_READ_SEARCH", "SETGID", "SETUID"] and studio["cap_drop"] == ["ALL"]
    assert studio["read_only"] is True and "no-new-privileges:true" in studio["security_opt"]
    assert key.read_text().strip() not in json.dumps(studio)
    assert "setresuid(10001" in " ".join(studio["healthcheck"]["test"])


def test_the_key_file_overlay_needs_the_launcher_s_path() -> None:
    if not shutil.which("docker") or subprocess.run(["docker", "compose", "version"], capture_output=True).returncode:
        pytest.skip("docker compose is not installed")
    env = {key: value for key, value in os.environ.items() if key != "NODESTRO_VAULT_KEY_HOST_FILE"}
    found = subprocess.run(
        ["docker", "compose", "--project-directory", str(ROOT), "-f", str(ROOT / "compose.yaml"), "-f",
         str(ROOT / "compose.vault-key.yaml"), "config", "-q"],
        env=env, capture_output=True, text=True,
    )  # fmt: skip
    assert found.returncode != 0 and "launcher names the key file" in found.stderr
