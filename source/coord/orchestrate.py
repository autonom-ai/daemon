"""autonom-orchestrate MCP server.

High-level team orchestration over the autonom daemon: start and stop
teammate sessions, track their work, provision per-teammate git worktrees,
merge their branches, and drive conflict rooms when a merge fails.

Unlike ``autonom-coord``, this server authenticates with the daemon's private
client capability (``dataDir/client.token``), because starting sessions and
inspecting every execution requires control-plane access. It refuses to run
unless ``AUTONOM_RUN_TOKEN`` is present, so only sessions that Autonom itself
started can use it.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

INFO = {"name": "autonom-orchestrate", "version": "0.1.0"}
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2025-03-26"
DEFAULT_PORT = "8080"
TIMEOUT_SECONDS = 20
START_TIMEOUT_SECONDS = 20
START_POLL_SECONDS = 0.25
WAIT_LIMIT_SECONDS = 600
DEFAULT_TEAM_MODEL = "swe-2-medium"
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

SESSION = {"type": "string", "description": "Injected by the Devin session hook."}

TOOLS = [
    {
        "name": "team_status",
        "description": "One team snapshot: profiles with their sessions and unread counts, rooms, "
        "recent executions, and registered worktrees. Start here and after every wait.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
    {
        "name": "team_start",
        "description": "Start one teammate session. Creates the profile when missing and binds the "
        "new session to it. Returns an execution ID; poll it with team_wait. Defaults: directory is "
        "the caller's workspace, mode is bypass so the teammate works unattended (workspace policy "
        "still screens every tool call).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string", "description": "Teammate profile name to create or reuse."},
                "prompt": {"type": "string", "description": "The teammate's task, stated completely."},
                "directory": {"type": "string", "description": "Workspace directory; defaults to the caller's."},
                "worktree": {"type": "string", "description": "Use this worktree's directory as the workspace."},
                "model": {"type": "string", "description": "Model for the teammate; defaults to the caller's model."},
                "mode": {"type": "string", "description": "Permission mode; defaults to bypass."},
                "trusted": {"type": "boolean", "description": "Skip workspace trust for this session."},
                "session_id": SESSION,
            },
            "required": ["profile", "prompt"],
        },
    },
    {
        "name": "team_stop",
        "description": "Request cancellation of a teammate's session and return the stop execution ID.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session": {"type": "string", "description": "Session ID to stop."},
                "session_id": SESSION,
            },
            "required": ["session"],
        },
    },
    {
        "name": "team_wait",
        "description": "Wait for one execution to finish, then return its final record. Use after "
        "team_start, team_stop, or team_remove. Set timeout to 0 for a single status check.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "execution": {"type": "string", "description": "Execution ID to wait for."},
                "timeout": {"type": "integer", "description": "Seconds to wait; default 120."},
                "session_id": SESSION,
            },
            "required": ["execution"],
        },
    },
    {
        "name": "team_remove",
        "description": "Remove a stopped teammate session and delete its profile and inbox. Refuses "
        "while the session is active; call team_stop first and wait for it to finish.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "profile": {"type": "string", "description": "Profile whose session should be removed."},
                "session": {"type": "string", "description": "Session ID; defaults to the profile's session."},
                "session_id": SESSION,
            },
            "required": ["profile"],
        },
    },
    {
        "name": "team_worktree_create",
        "description": "Create a git worktree for one teammate: branch autonom/<name> at "
        ".autonom-worktrees/<name> inside the repository, based on HEAD or the given ref.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Worktree and branch name."},
                "source": {"type": "string", "description": "Git ref to base the branch on; default HEAD."},
                "session_id": SESSION,
            },
            "required": ["name"],
        },
    },
    {
        "name": "team_worktree_list",
        "description": "List registered worktrees with their branches and ready/dirty/missing status.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
    {
        "name": "team_worktree_remove",
        "description": "Remove a worktree and delete its branch. Pass force to discard uncommitted "
        "changes. Refuses while a merge involving it is open.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Worktree to remove."},
                "force": {"type": "boolean", "description": "Discard uncommitted changes."},
                "session_id": SESSION,
            },
            "required": ["name"],
        },
    },
    {
        "name": "team_merge",
        "description": "Merge one teammate's branch into another worktree. On success the target "
        "contains the merge. On conflict the daemon opens a conflict room with the involved profiles, "
        "surfaces an event for each, and returns the conflicted files; coordinate in the room, then "
        "abort or finish the merge.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Worktree that receives the merge."},
                "source": {"type": "string", "description": "Worktree whose branch is merged in."},
                "session_id": SESSION,
            },
            "required": ["target", "source"],
        },
    },
    {
        "name": "team_merge_abort",
        "description": "Abort a conflicted merge, reset the target worktree, and destroy the conflict "
        "room. Use after the source branch was rebased or rewritten; then merge again.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Target worktree of the merge."},
                "source": {"type": "string", "description": "Source worktree of the merge."},
                "session_id": SESSION,
            },
            "required": ["target", "source"],
        },
    },
    {
        "name": "team_merge_finish",
        "description": "Commit a conflicted merge after it was resolved in the target worktree and "
        "destroy the conflict room. Fails while conflicts remain.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {"type": "string", "description": "Target worktree of the merge."},
                "source": {"type": "string", "description": "Source worktree of the merge."},
                "session_id": SESSION,
            },
            "required": ["target", "source"],
        },
    },
    {
        "name": "team_message",
        "description": "Post as the human operator into a room, typically a conflict room, and ping "
        "the listed profiles so their sessions wake with the message.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "room": {"type": "string", "description": "Room to post in."},
                "text": {"type": "string", "description": "Message text."},
                "ping": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Profile names to ping.",
                },
                "session_id": SESSION,
            },
            "required": ["room", "text"],
        },
    },
    {
        "name": "team_models",
        "description": "List the Devin model catalog available for new teammates.",
        "inputSchema": {"type": "object", "properties": {"session_id": SESSION}},
    },
]


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


def expand(path):
    if path.startswith("~"):
        return os.path.expanduser(path)

    return path


def config_path():
    configured = os.environ.get("AUTONOM_CONFIG")
    if configured:
        return expand(configured)

    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "autonom", "config.yml")


def data_directory():
    override = os.environ.get("AUTONOM_DATA_DIR")
    if override:
        return expand(override)

    path = config_path()
    try:
        with open(path, "r", encoding="utf-8") as config:
            for line in config:
                line = line.split("#", 1)[0].strip()
                if not line.startswith("dataDir:"):
                    continue

                value = line.split(":", 1)[1].strip().strip("'\"")
                if not value:
                    break

                value = expand(value)
                if not os.path.isabs(value):
                    value = os.path.join(os.path.dirname(path), value)

                return value
    except OSError:
        pass

    return os.path.dirname(path)


def client_token():
    path = os.path.join(data_directory(), "client.token")
    try:
        with open(path, "r", encoding="utf-8") as token:
            value = token.read().strip()
    except OSError as failure:
        raise ToolError("The Autonom client capability is unavailable: %s" % failure) from failure

    if len(value) != 64:
        raise ToolError("The Autonom client capability is invalid: %s" % path)

    return value


def running():
    try:
        with urllib.request.urlopen(url("/api/health"), timeout=1) as response:
            return json.loads(response.read() or b"null").get("status") == "ok"
    except Exception:
        return False


def spawn():
    binary = os.path.join(root(), "bin", "autonom-daemon")
    if not os.path.exists(binary):
        raise ToolError("The autonom daemon is not built: %s is missing" % binary)

    os.makedirs(state_directory(), exist_ok=True)
    environment = dict(os.environ)
    environment["AUTONOM_PORT"] = port()
    with open(log_path(), "ab") as log:
        return subprocess.Popen(
            [binary],
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
    lock_path = os.path.join(state_directory(), "daemon-" + port() + ".lock")
    with open(lock_path, "w", encoding="utf-8") as lock:
        try:
            import fcntl

            fcntl.flock(lock, fcntl.LOCK_EX)
        except ImportError:
            pass

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
            "x-autonom-client": client_token(),
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


def required(arguments, name):
    value = arguments.get(name)
    if not isinstance(value, str) or not value:
        raise ToolError("A %s is required" % name)

    return value


def caller(arguments):
    if not os.environ.get("AUTONOM_RUN_TOKEN"):
        raise ToolError("Only sessions started by Autonom may use Autonom tools")

    return arguments.get("session_id")


def caller_session(arguments):
    session = caller(arguments)
    if not isinstance(session, str) or not session:
        raise ToolError("No session ID; the autonom hooks are not installed for this session")

    return session


def caller_state(arguments):
    session = caller_session(arguments)
    state = call("GET", "/api/client/state")
    for record in state.get("sessions", []):
        if record.get("id") == session:
            return record

    return {}


def caller_workspace(arguments):
    directory = caller_state(arguments).get("directory")
    if isinstance(directory, str) and directory:
        return directory

    raise ToolError("Could not resolve the calling session's workspace; pass directory explicitly")


def caller_model(arguments):
    model = caller_state(arguments).get("model")
    return model if isinstance(model, str) else ""


def find_worktree(name):
    for worktree in call("GET", "/api/worktrees"):
        if worktree.get("name") == name:
            return worktree

    return None


def find_profile(profile):
    for record in call("GET", "/api/profiles"):
        if record.get("name") == profile:
            return record

    return None


def ensure_profile(profile):
    if find_profile(profile) is None:
        call("POST", "/api/profiles", {"name": profile})

    return profile


def execution_record(execution_id):
    return call("GET", "/api/executions/" + urllib.parse.quote(execution_id))


def finished(execution):
    return execution.get("status") not in ("running", "stopping")


def wait_execution(execution_id, timeout):
    deadline = time.monotonic() + timeout
    while True:
        execution = execution_record(execution_id)
        if finished(execution) or time.monotonic() >= deadline:
            return execution

        time.sleep(0.5)


def start(arguments):
    profile = required(arguments, "profile")
    prompt = required(arguments, "prompt")
    directory = arguments.get("directory")
    worktree = arguments.get("worktree")
    if worktree:
        found = find_worktree(worktree)
        if found is None:
            raise ToolError("Unknown worktree: %s" % worktree)
        if found.get("status") != "ready":
            raise ToolError("Worktree %s is not ready: %s" % (worktree, found.get("status")))

        directory = found.get("path")
    if not isinstance(directory, str) or not directory:
        directory = caller_workspace(arguments)

    model = arguments.get("model")
    if not isinstance(model, str) or not model:
        model = caller_model(arguments) or DEFAULT_TEAM_MODEL

    ensure_profile(profile)
    body = {
        "prompt": prompt,
        "directory": directory,
        "profile": profile,
        "mode": arguments.get("mode") or "bypass",
        "trusted": bool(arguments.get("trusted")),
    }
    if model:
        body["model"] = model

    return call("POST", "/api/sessions", body)


def stop(arguments):
    session = required(arguments, "session")
    return call("POST", "/api/sessions/" + urllib.parse.quote(session) + "/stop", {})


def remove(arguments):
    profile = required(arguments, "profile")
    session = arguments.get("session")
    if not isinstance(session, str) or not session:
        found = find_profile(profile)
        if found is None:
            raise ToolError("Unknown profile: %s" % profile)
        if not found.get("session"):
            raise ToolError("Profile %s has no session to remove" % profile)

        session = found["session"]["id"]

    removal = call("POST", "/api/sessions/remove", {"ids": [session]})
    if removal.get("failed"):
        raise ToolError("The daemon refused to remove %s" % session)

    execution = removal["executions"][0]
    record = wait_execution(execution["id"], WAIT_LIMIT_SECONDS)
    if record.get("status") != "succeeded":
        raise ToolError("Session removal did not succeed: %s" % (record.get("error") or record.get("status")))

    if find_profile(profile) is not None:
        call("DELETE", "/api/client/profiles/" + urllib.parse.quote(profile))

    return {"removed": session, "execution": record}


def status(arguments):
    caller(arguments)
    state = call("GET", "/api/client/state")
    runs = []
    for run in state.get("runs", [])[-20:]:
        execution = call("GET", "/api/executions/" + urllib.parse.quote(run["id"]))
        runs.append(
            {
                "id": execution.get("id"),
                "kind": execution.get("kind"),
                "status": execution.get("status"),
                "profile": execution.get("profile"),
                "workspace": execution.get("workspace"),
                "session": execution.get("sessionId"),
                "createdAt": execution.get("createdAt"),
                "finishedAt": execution.get("finishedAt"),
                "error": execution.get("error"),
            }
        )

    profiles = [
        {
            "name": record.get("name"),
            "session": record.get("session"),
            "events": record.get("events"),
            "schedules": record.get("schedules"),
            "unread": record.get("unread"),
            "managed": record.get("managed"),
        }
        for record in state.get("profiles", [])
    ]
    sessions = [
        {
            "id": record.get("id"),
            "profile": record.get("profile"),
            "status": record.get("status"),
            "title": record.get("title"),
            "directory": record.get("directory"),
            "model": record.get("model"),
            "executionId": record.get("executionId"),
        }
        for record in state.get("sessions", [])
    ]
    rooms = [
        {"name": room.get("name"), "count": room.get("count"), "lastTs": room.get("lastTs")}
        for room in state.get("rooms", [])
    ]
    return {
        "profiles": profiles,
        "sessions": sessions,
        "rooms": rooms,
        "runs": runs,
        "worktrees": call("GET", "/api/worktrees"),
    }


def worktree_create(arguments):
    caller(arguments)
    body = {"name": required(arguments, "name")}
    source = arguments.get("source")
    if isinstance(source, str) and source:
        body["source"] = source

    return call("POST", "/api/worktrees", body)


def worktree_remove(arguments):
    caller(arguments)
    body = {"force": bool(arguments.get("force"))}
    return call(
        "DELETE",
        "/api/worktrees/" + urllib.parse.quote(required(arguments, "name")),
        body,
    )


def merge(arguments):
    caller(arguments)
    target = required(arguments, "target")
    source = required(arguments, "source")
    return call(
        "POST",
        "/api/worktrees/" + urllib.parse.quote(target) + "/merge",
        {"source": source},
    )


def merge_abort(arguments):
    caller(arguments)
    target = required(arguments, "target")
    source = required(arguments, "source")
    return call(
        "POST",
        "/api/worktrees/" + urllib.parse.quote(target) + "/merge/abort",
        {"source": source},
    )


def merge_finish(arguments):
    caller(arguments)
    target = required(arguments, "target")
    source = required(arguments, "source")
    return call(
        "POST",
        "/api/worktrees/" + urllib.parse.quote(target) + "/merge/finish",
        {"source": source},
    )


def message(arguments):
    caller(arguments)
    body = {"text": required(arguments, "text")}
    ping = arguments.get("ping")
    if isinstance(ping, list) and ping:
        body["ping"] = ping

    return call(
        "POST",
        "/api/client/rooms/" + urllib.parse.quote(required(arguments, "room")) + "/messages",
        body,
    )


def dispatch(name, arguments):
    if name == "team_status":
        return status(arguments)
    if name == "team_start":
        return start(arguments)
    if name == "team_stop":
        caller(arguments)
        return stop(arguments)
    if name == "team_wait":
        caller(arguments)
        timeout = arguments.get("timeout")
        if not isinstance(timeout, int) or timeout < 0:
            timeout = 120
        if timeout > WAIT_LIMIT_SECONDS:
            timeout = WAIT_LIMIT_SECONDS

        return wait_execution(required(arguments, "execution"), timeout)
    if name == "team_remove":
        return remove(arguments)
    if name == "team_worktree_create":
        return worktree_create(arguments)
    if name == "team_worktree_list":
        caller(arguments)
        return call("GET", "/api/worktrees")
    if name == "team_worktree_remove":
        return worktree_remove(arguments)
    if name == "team_merge":
        return merge(arguments)
    if name == "team_merge_abort":
        return merge_abort(arguments)
    if name == "team_merge_finish":
        return merge_finish(arguments)
    if name == "team_message":
        return message(arguments)
    if name == "team_models":
        caller(arguments)
        return call("GET", "/api/client/models")

    raise ToolError("Unknown orchestration tool")


def call_tool(name, arguments):
    if not isinstance(arguments, dict):
        return {"content": [{"type": "text", "text": "Tool arguments must be an object"}], "isError": True}

    try:
        result = dispatch(name, arguments)
        return {"content": [{"type": "text", "text": json.dumps(result)}], "isError": False}
    except ToolError as failure:
        return {"content": [{"type": "text", "text": str(failure)}], "isError": True}


def error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def success(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def handle(request):
    if not isinstance(request, dict):
        return error(None, -32600, "Invalid request")

    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params") if isinstance(request.get("params"), dict) else {}
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None
    if not isinstance(method, str):
        return error(request_id, -32600, "Invalid request")

    if method == "initialize":
        protocol = params.get("protocolVersion")
        if protocol not in PROTOCOLS:
            protocol = DEFAULT_PROTOCOL

        return success(
            request_id,
            {
                "protocolVersion": protocol,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": INFO,
            },
        )
    if method == "ping":
        return success(request_id, {})
    if method == "tools/list":
        return success(request_id, {"tools": TOOLS if os.environ.get("AUTONOM_RUN_TOKEN") else []})
    if method == "tools/call":
        return success(
            request_id,
            call_tool(params.get("name") or "", params.get("arguments") or {}),
        )

    return error(request_id, -32601, "Method not found")


def run():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except ValueError:
            request = None

        try:
            response = handle(request) if request is not None else error(None, -32700, "Parse error")
        except Exception as failure:
            request_id = request.get("id") if isinstance(request, dict) else None
            response = error(request_id, -32603, "Internal error: %s" % failure)

        if response is None:
            continue

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    run()
