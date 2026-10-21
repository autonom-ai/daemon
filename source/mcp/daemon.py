"""Loopback daemon startup, authenticated HTTP, and session capability resolution."""

import contextvars
import fcntl
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PORT = "8080"
TIMEOUT_SECONDS = 15
START_TIMEOUT_SECONDS = 20
START_POLL_SECONDS = 0.25
SESSION_CONTEXT = contextvars.ContextVar("autonom_session", default="")
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
RESOLVED_SESSION = None


class ToolError(Exception):
    """A tool call the daemon refused, reported to the agent as a tool error."""


def port():
    return os.environ.get("AUTONOM_PORT", DEFAULT_PORT)


def url(path):
    return "http://127.0.0.1:" + port() + path


def root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def state_directory():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "autonom")


def log_path():
    return os.path.join(state_directory(), "daemon-" + port() + ".log")


def running():
    try:
        with HTTP.open(url("/api/health"), timeout=1) as response:
            return json.loads(response.read() or b"null").get("status") == "ok"
    except Exception:
        return False


def spawn():
    binary = os.path.join(root(), "bin", "autonom")
    if not os.path.exists(binary):
        raise ToolError("The autonom command is not built: %s is missing" % binary)

    os.makedirs(state_directory(), exist_ok=True)
    environment = dict(os.environ)
    environment["AUTONOM_PORT"] = port()
    with open(log_path(), "ab") as log:
        return subprocess.Popen(
            [binary, "daemon"],
            cwd=root(),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )


def ensure():
    if running():
        return True

    os.makedirs(state_directory(), exist_ok=True)
    with open(os.path.join(state_directory(), "daemon-" + port() + ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if running():
            return True

        process = spawn()
        deadline = time.time() + START_TIMEOUT_SECONDS
        while time.time() < deadline:
            if running():
                return True
            if process.poll() is not None:
                return running()

            time.sleep(START_POLL_SECONDS)

    return False


def call(method, path, body=None, query=None):
    target = url(path)
    if query:
        target += "?" + urllib.parse.urlencode(
            {name: value for name, value in query.items() if value is not None}
        )

    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        target,
        data=data,
        method=method,
        headers={
            "content-type": "application/json",
            "x-autonom-mcp": os.environ.get("AUTONOM_MCP_TOKEN", ""),
            "x-autonom-session": SESSION_CONTEXT.get(),
        },
    )
    for attempt in range(2):
        try:
            with HTTP.open(request, timeout=TIMEOUT_SECONDS) as response:
                return json.loads(response.read() or b"null")
        except urllib.error.HTTPError as failure:
            try:
                message = json.loads(failure.read()).get("error")
            except ValueError:
                message = None

            raise ToolError(message or "The daemon returned HTTP %d" % failure.code) from failure
        except OSError as failure:
            if attempt == 0 and ensure():
                continue

            raise ToolError(
                "The autonom daemon is unreachable: %s (log: %s)" % (failure, log_path())
            ) from failure


def session():
    global RESOLVED_SESSION
    if not os.environ.get("AUTONOM_MCP_TOKEN"):
        raise ToolError("Only sessions started by Autonom may use Autonom tools")
    if RESOLVED_SESSION is None:
        resolved = None
        try:
            resolved = call("GET", "/api/mcp/session")
        except ToolError:
            pass

        caller = resolved.get("id") if isinstance(resolved, dict) else None
        if not isinstance(caller, str) or not caller:
            raise ToolError("Only sessions started by Autonom may use Autonom tools")

        RESOLVED_SESSION = caller

    return RESOLVED_SESSION
