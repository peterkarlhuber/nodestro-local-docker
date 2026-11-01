"""End-to-end tests of Nodestro Local Docker: the real image, the compose file and the launcher, on a real Docker.

They start their own installation (project ``nodestro-e2e``, a random loopback port) and remove it at the end:

    NODESTRO_IMAGE=nodestro-local:dev python -m pytest tests/e2e -v

Behind a TLS-inspecting proxy, set NODESTRO_EXTRA_CA_FILE to its certificate bundle.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
from typing import Any
import urllib.error
import urllib.request

import pytest

ROOT = Path(__file__).resolve().parents[2]
PROJECT = "nodestro-e2e"
IMAGE = os.environ.get("NODESTRO_IMAGE", "nodestro-local:dev")
STUB = "http://model-stub:9100/v1"
MODEL = "compatible:stub-model"

# Orkexa's static check allows only pure computation in tools (no os, socket, files); where the code runs is proven
# by the containers it started (Docker's events). What code inside such a container can reach is tested in
# nodestro-runtime (tests/test_sandbox_gateway.py, real Docker).
TOOL = '''\
def shout(text: str) -> str:
    """Shout a text.

    Args:
        text: What to shout.

    Returns:
        The text in capitals with an exclamation mark.
    """
    return text.upper() + "!"
'''

TOOL_TESTS = """\
from tool import shout


def test_shout():
    assert shout("hi") == "HI!"
"""


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


PORT = _free_port()
STATE = Path(tempfile.mkdtemp(prefix="nodestro-e2e-state-"))
(STATE / "state.env").write_text(f"NODESTRO_IMAGE={IMAGE}\n")
ENV = {
    **os.environ,
    "NODESTRO_PROJECT": PROJECT,
    "NODESTRO_PORT": str(PORT),
    "NODESTRO_IMAGE": IMAGE,
    "NODESTRO_NO_BROWSER": "1",
    "NODESTRO_STATE_DIR": str(STATE),
}
# Rootless Docker: the launcher finds the user's socket itself; the tests' own compose calls need it named.
_HOST = os.environ.get("DOCKER_HOST", "")
if _HOST.startswith("unix:///run/user/") and not os.environ.get("NODESTRO_DOCKER_SOCKET"):
    ENV["NODESTRO_DOCKER_SOCKET"] = _HOST[len("unix://") :]
#: The launcher under test: ./nodestro, or with NODESTRO_E2E_LAUNCHER=pwsh the Windows launcher on PowerShell 7.
LAUNCHER = (
    ["pwsh", "-NoProfile", "-File", str(ROOT / "nodestro.ps1")]
    if os.environ.get("NODESTRO_E2E_LAUNCHER") == "pwsh"
    else [str(ROOT / "nodestro")]
)
FILES = ["-f", str(ROOT / "compose.yaml"), "-f", str(ROOT / "tests" / "compose.test.yaml")]
if os.environ.get("NODESTRO_EXTRA_CA_FILE"):
    FILES += ["-f", str(ROOT / "compose.extra-ca.yaml")]


def compose(*args: str, check: bool = True, input: bytes | None = None, timeout: float = 600) -> Any:
    return subprocess.run(
        ["docker", "compose", "--project-directory", str(ROOT), *FILES, *args],
        env=ENV,
        capture_output=True,
        check=check,
        input=input,
        timeout=timeout,
    )


def docker(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=check, timeout=300)


def wait_for(condition: Callable[[], Any], *, timeout: float, what: str, every: float = 1.0) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = condition()
        if found:
            return found
        time.sleep(every)
    raise AssertionError(f"timed out waiting for {what}")


#: The launch link: the installation's random browser host name (docs/SESSIONS.md), the port and the key.
LINK = re.compile(rf"http://(nodestro-[a-z0-9]{{10}}\.localhost):{PORT}/api/launch\?token=([A-Za-z0-9_-]{{43}})")


class Client:
    """A browser or script on the host: requests to 127.0.0.1:<port> with a cookie jar.

    ``host`` is the name the browser sends in ``Host`` (``*.localhost`` names resolve to loopback in browsers, but not
    necessarily in this test's resolver, so the connection always goes to 127.0.0.1)."""

    def __init__(self, host: str | None = None, *, origin: str | None = None) -> None:
        self.base = f"http://127.0.0.1:{PORT}"
        self.host = host
        self.origin = origin or (f"http://{host}:{PORT}" if host else self.base)
        self.cookies: dict[str, str] = {}
        self.headers: dict[str, str] = {}

    def request(self, method: str, path: str, body: Any = None, *, headers: dict[str, str] | None = None,
                timeout: float = 120) -> tuple[int, Any, dict[str, str]]:  # fmt: skip
        data = json.dumps(body).encode() if body is not None else None
        sent = {"Accept": "application/json", **self.headers, **(headers or {})}
        if self.host and "Host" not in sent:
            sent["Host"] = f"{self.host}:{PORT}"
        if data is not None:
            sent["Content-Type"] = "application/json"
        if method not in ("GET", "HEAD"):
            sent.setdefault("Origin", self.origin)
        if self.cookies:
            sent["Cookie"] = "; ".join(f"{key}={value}" for key, value in self.cookies.items())
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=sent)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                status, raw, received = answer.status, answer.read(), {k.lower(): v for k, v in answer.headers.items()}
                cookie_headers = answer.headers.get_all("Set-Cookie") or []
        except urllib.error.HTTPError as error:
            status, raw, received = error.code, error.read(), {k.lower(): v for k, v in error.headers.items()}
            cookie_headers = error.headers.get_all("Set-Cookie") or []
        for header in cookie_headers:
            name, _, rest = header.partition("=")
            self.cookies[name] = rest.split(";", 1)[0]
        try:
            parsed: Any = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw.decode("utf-8", "replace")
        return status, parsed, received

    def get(self, path: str, **options: Any) -> tuple[int, Any, dict[str, str]]:
        return self.request("GET", path, **options)

    def post(self, path: str, body: Any = None, **options: Any) -> tuple[int, Any, dict[str, str]]:
        return self.request("POST", path, body, **options)

    def put(self, path: str, body: Any = None, **options: Any) -> tuple[int, Any, dict[str, str]]:
        return self.request("PUT", path, body, **options)


def link() -> str:
    return str(compose("exec", "-T", "nodestro", "nodestro-local", "link", "--port", str(PORT)).stdout.decode().strip())


def browser_host() -> str:
    found = LINK.fullmatch(link())
    assert found, link()
    return found.group(1)


def access_key() -> str:
    found = LINK.fullmatch(link())
    assert found, link()
    return found.group(2)


def browser() -> Client:
    url = link()
    found = LINK.fullmatch(url)
    assert found, url
    client = Client(found.group(1))
    status, _, headers = client.get(f"/api/launch?token={found.group(2)}")
    assert status == 200 and "nodestro_local_session" in client.cookies
    assert headers["referrer-policy"] == "no-referrer"
    return client


def launcher(*args: str, check: bool = True, timeout: float = 900) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([*LAUNCHER, *args], env=ENV, capture_output=True, text=True, timeout=timeout, check=False)
    if check and result.returncode != 0:
        raise AssertionError(f"{LAUNCHER[-1]} {' '.join(args)} failed:\n{result.stdout}\n{result.stderr}")
    return result


def container(service: str) -> dict[str, Any]:
    name = compose("ps", "-q", service).stdout.decode().strip()
    assert name, f"{service} is not running"
    return dict(json.loads(docker("inspect", name).stdout)[0])


@pytest.fixture(scope="session", autouse=True)
def installation() -> Iterator[None]:
    if docker("image", "inspect", IMAGE, check=False).returncode != 0:
        pytest.fail(f"the image {IMAGE} is missing: build it with scripts/build-image.sh")
    compose("down", "-v", "--remove-orphans", check=False)
    started = launcher("start")
    assert LINK.search(started.stdout), started.stdout
    compose("up", "-d", "--wait", "model-stub")
    try:
        yield
    finally:
        logs = compose("logs", "--no-color", check=False).stdout.decode()
        Path(tempfile.gettempdir(), "nodestro-e2e.log").write_text(logs)
        compose("down", "-v", "--remove-orphans", check=False)
        docker("volume", "rm", f"{PROJECT}_data-before-update", check=False)


# ---- installation and network --------------------------------------------------------------------------------------


def test_the_port_is_published_on_the_host_loopback_only() -> None:
    bindings = container("nodestro")["NetworkSettings"]["Ports"]["8080/tcp"]
    assert bindings == [{"HostIp": "127.0.0.1", "HostPort": str(PORT)}]
    assert container("gateway")["NetworkSettings"]["Ports"] == {}


def test_the_containers_are_locked_down() -> None:
    for service in ("nodestro", "gateway"):
        host = container(service)["HostConfig"]
        assert host["ReadonlyRootfs"] is True, service
        assert host["CapDrop"] == ["ALL"] and not host["CapAdd"], service
        assert "no-new-privileges:true" in host["SecurityOpt"], service
        assert host["Privileged"] is False, service
    gateway = container("gateway")
    assert gateway["HostConfig"]["NetworkMode"] == "none"
    # Only the gateway has the host's Docker socket; the studio has only the gateway's.
    studio_mounts = {mount["Destination"] for mount in container("nodestro")["Mounts"]}
    assert "/var/run/docker.sock" not in studio_mounts and "/run/nodestro-sandbox" in studio_mounts
    assert "/var/run/docker.sock" in {mount["Destination"] for mount in gateway["Mounts"]}
    assert container("nodestro")["Config"]["User"] == "10001:10001"


def test_the_access_key_is_private_and_never_logged() -> None:
    mode = compose("exec", "-T", "nodestro", "stat", "-c", "%a %u", "/var/lib/nodestro/secrets/access-key").stdout
    assert mode.decode().split() == ["600", "10001"]
    mode = compose("exec", "-T", "nodestro", "stat", "-c", "%a %u", "/var/lib/nodestro/secrets/browser-host").stdout
    assert mode.decode().split() == ["600", "10001"]
    key, host = access_key(), browser_host()
    browser()  # a launch is in the access log
    logs = compose("logs", "--no-color").stdout.decode()
    assert key not in logs and host not in logs
    assert key not in json.dumps(container("nodestro")["Config"])


# ---- authentication, host and origin --------------------------------------------------------------------------------


def test_without_the_key_only_health_answers() -> None:
    client = Client()
    assert client.get("/api/health")[0] == 200
    for path in ("/api/workflows", "/api/settings", "/api/backup"):
        assert client.get(path)[0] == 401, path
    status, body, _ = client.get("/", headers={"Accept": "text/html"})
    assert status == 401 and "nodestro-local" in body
    assert client.post("/api/workflows", {"name": "x"})[0] == 401
    assert client.get("/api/launch?token=" + "x" * 43)[0] == 403


def test_the_link_opens_a_session_and_scripts_use_the_key() -> None:
    client = browser()
    assert client.get("/api/workflows")[0] == 200
    script = Client()
    script.headers["Authorization"] = "Bearer " + access_key()
    assert script.get("/api/workflows")[0] == 200


def test_browser_sessions_exist_only_under_the_installation_s_host_name() -> None:
    client = browser()
    session = client.cookies["nodestro_local_session"]
    # 127.0.0.1 and localhost are shared with every other local web server: no session is opened there ...
    for name in ("127.0.0.1", "localhost"):
        shared = Client(name)
        status, body, headers = shared.get(f"/api/launch?token={access_key()}")
        assert status == 403 and body["code"] == "access.launch_host", name
        assert "set-cookie" not in headers and not shared.cookies
        # ... and a session cookie that reaches such a name (another server collected it) is not accepted.
        shared.cookies["nodestro_local_session"] = session
        assert shared.get("/api/workflows")[0] == 401, name
    assert client.get("/api/workflows")[0] == 200


def test_only_the_published_port_is_answered() -> None:
    client = browser()
    status, body, _ = client.get("/api/workflows", headers={"Host": f"{browser_host()}:3000"})
    assert status == 403 and body["code"] == "request.port_not_allowed"
    assert client.get("/api/workflows")[0] == 200


def test_logout_ends_the_session_and_the_launcher_ends_all() -> None:
    first, second = browser(), browser()
    status, page, _ = first.get("/api/logout", headers={"Accept": "text/html"})
    assert status == 200 and 'action="/api/logout"' in page
    # Another page cannot sign the person out.
    assert first.post("/api/logout", headers={"Origin": "http://localhost:3000"})[0] == 403
    assert first.get("/api/workflows")[0] == 200
    status, _, headers = first.post("/api/logout", headers={"Accept": "text/html"})
    assert status == 200 and "Max-Age=0" in headers["set-cookie"]
    assert first.get("/api/workflows")[0] == 401
    assert second.get("/api/workflows")[0] == 200
    assert "ended" in launcher("logout").stdout
    assert second.get("/api/workflows")[0] == 401


def test_foreign_host_names_and_origins_are_refused() -> None:
    client = browser()
    # DNS rebinding: the browser sends the attacker's name.
    status, body, _ = client.get("/api/workflows", headers={"Host": "evil.example"})
    assert status == 403 and body["code"] == "request.host_not_allowed"
    # Another program on localhost (same site): no changes with the session.
    status, body, _ = client.post("/api/workflows", {"name": "x"}, headers={"Origin": "http://localhost:3000"})
    assert status == 403 and body["code"] == "request.origin_not_allowed"
    status, body, _ = client.post("/api/workflows", {"name": "x"}, headers={"Origin": "null"})
    assert status == 403


def test_other_containers_cannot_use_the_studio_through_its_address() -> None:
    address = next(iter(container("nodestro")["NetworkSettings"]["Networks"].values()))["IPAddress"]
    script = (
        "import urllib.request, urllib.error\n"
        f"r = urllib.request.Request('http://{address}:8080/api/workflows')\n"
        "try:\n    print(urllib.request.urlopen(r, timeout=5).status)\n"
        "except urllib.error.HTTPError as e:\n    print(e.code)\n"
    )
    found = compose("exec", "-T", "model-stub", "python", "-c", script).stdout.decode().strip()
    assert found == "403"  # its address is not a loopback name (and it has no key)


def test_network_access_for_published_apis_cannot_be_switched_on() -> None:
    status, body, _ = browser().put("/api/api-network", {"enabled": True, "port": 8800})
    assert status >= 400 and body["code"] == "lan.unavailable"


# ---- tool code ------------------------------------------------------------------------------------------------------


def _sandbox_containers(since: float) -> list[str]:
    events = ["events", "--since", f"{since:.0f}", "--until", f"{time.time() + 1:.0f}", "--filter", "type=container"]
    events += ["--filter", "event=start", "--filter", f"label=dev.nodestro.sandbox={PROJECT}"]
    return docker(*events, "--format", "{{.Actor.Attributes.name}}").stdout.split()


def test_tool_code_runs_only_in_locked_down_sandbox_containers() -> None:
    client = browser()
    since = time.time() - 1
    status, saved, _ = client.post(
        "/api/tools", {"function_name": "shout", "code": TOOL, "tests": TOOL_TESTS}, timeout=900
    )
    assert status in (200, 201), saved
    assert saved["tool"] is not None, saved  # its tests passed, in a sandbox container
    status, answer, _ = client.post("/api/tools/shout/run", {"input": {"text": "direct"}}, timeout=600)
    assert status == 200, answer
    assert answer == {"output": "DIRECT!", "is_error": False}, answer
    # In a run: the agent (the model stub) calls the tool.
    supported = {name: "supported" for name in ("tools", "streaming")}
    status, body, _ = client.put(
        "/api/settings",
        {"providers": {"compatible": {"base_url": STUB, "api_key": "stub-key", "capabilities": supported}}},
    )
    assert status == 200, body
    flow = {
        "name": "Tool run",
        "nodes": [
            {"id": "start", "type": "start"},
            {
                "id": "a",
                "type": "agent",
                "label": "A",
                "agent": {
                    "name": "A",
                    "system_prompt": 'CALL shout {"text": "in a run"}',
                    "model": MODEL,
                    "effort": None,
                    "tools": ["shout"],
                },
            },
            {"id": "out", "type": "output"},
        ],
        "edges": [{"id": "e1", "source": "start", "target": "a"}, {"id": "e2", "source": "a", "target": "out"}],
    }
    status, workflow, _ = client.post("/api/workflows", flow)
    assert status == 201, workflow
    status, run, _ = client.post(f"/api/workflows/{workflow['id']}/runs", {"input": "go"})
    assert status == 201, run

    def finished() -> Any:
        found = client.get(f"/api/runs/{run['id']}")[1]
        return found if found["status"] in ("succeeded", "failed", "cancelled") else None

    done = wait_for(finished, timeout=600, what="the tool run")
    assert done["status"] == "succeeded" and done["output"] == "tool said: IN A RUN!", done
    started = _sandbox_containers(since)
    assert len(started) >= 3 and all(name.startswith("nodestro-sandbox-") for name in started), started
    images = docker("images", "--format", "{{.Repository}}:{{.Tag}}").stdout.split()
    assert any(re.fullmatch(r"nodestro-env:[0-9a-f]{32}", image) for image in images), images


def test_the_studio_cannot_escape_through_the_gateway() -> None:
    def from_studio(*args: str) -> str:
        found = compose("exec", "-T", "nodestro", "docker", *args, check=False)
        assert found.returncode != 0, args
        return str(found.stderr.decode())

    tag = next(image for image in docker("images", "--format", "{{.Repository}}:{{.Tag}}").stdout.split()
               if image.startswith("nodestro-env:"))  # fmt: skip
    for args in (
        ("run", "--rm", "--privileged", tag, "true"),
        ("run", "--rm", "-v", "/:/host", tag, "true"),
        ("run", "--rm", "--network", "host", tag, "true"),
        ("run", "--rm", "--user", "0", tag, "true"),
        ("run", "--rm", "python:3.13-slim", "true"),
        ("ps",),
        ("exec", f"{PROJECT}-nodestro-1", "true"),
        ("volume", "ls"),
        ("pull", "alpine"),
    ):
        assert "Nodestro sandbox gateway" in from_studio(*args), args


def test_without_the_gateway_tool_code_does_not_run_at_all() -> None:
    client = browser()
    since = time.time() - 1
    compose("stop", "gateway")
    try:
        status, body, _ = client.post("/api/tools/shout/run", {"input": {"text": "no gateway"}}, timeout=120)
        assert status >= 400 or body.get("is_error") is True, body
        assert "NO GATEWAY!" not in json.dumps(body)  # nothing ran, not in the studio's container either
        assert _sandbox_containers(since) == []
    finally:
        compose("up", "-d", "--wait", "gateway")


# ---- data ----------------------------------------------------------------------------------------------------------


def _workflow(client: Client, name: str) -> str:
    status, body, _ = client.post("/api/workflows", {"name": name, "nodes": [], "edges": []})
    assert status == 201, body
    return str(body["id"])


def _names(client: Client) -> list[str]:
    status, body, _ = client.get("/api/workflows")
    assert status == 200, body
    return [item["name"] for item in body]


def test_data_survives_stop_restart_and_recreation() -> None:
    _workflow(browser(), "Kept across restarts")
    launcher("stop")
    launcher("start")
    assert "Kept across restarts" in _names(browser())
    compose("down")  # containers removed, the volume stays
    launcher("start")
    assert "Kept across restarts" in _names(browser())


def test_backup_and_restore_through_the_launcher(tmp_path: Path) -> None:
    client = browser()
    _workflow(client, "In the backup")
    backup = tmp_path / "backup.zip"
    launcher("backup", str(backup))
    assert backup.stat().st_size > 0 and backup.read_bytes()[:2] == b"PK"
    _workflow(client, "After the backup")
    launcher("restore", str(backup))
    names = _names(browser())
    assert "In the backup" in names and "After the backup" not in names


def test_update_and_rollback_keep_the_data() -> None:
    _workflow(browser(), "Before the update")
    # The update path with a prepared image (NODESTRO_UPDATE_IMAGE): a second tag of the same image.
    docker("tag", IMAGE, "nodestro-local:e2e-next")
    try:
        result = subprocess.run(
            [*LAUNCHER, "update"],
            env={**ENV, "NODESTRO_UPDATE_IMAGE": "nodestro-local:e2e-next"},
            capture_output=True,
            text=True,
            timeout=900,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert container("nodestro")["Config"]["Image"] == "nodestro-local:e2e-next"
        assert list((ROOT / "backups").glob("before-update-*.zip")), "the update makes a backup first"
        _workflow(browser(), "After the update")
        launcher("rollback")
        names = _names(browser())
        assert "Before the update" in names and "After the update" not in names
        assert container("nodestro")["Config"]["Image"] == IMAGE
    finally:
        docker("rmi", "nodestro-local:e2e-next", check=False)
