#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.request

INPUT_LIMIT = 16 * 1024 * 1024
REPLY_LIMIT = 16 * 1024 * 1024
PERMISSION_TIMEOUT = 240
COORDINATION_PREFIXES = ("mcp__autonom-coord__", "mcp__autonom-orchestrate__")
SENSITIVE = ("PreToolUse", "PermissionRequest")
PATHS = {
    "PreToolUse": "pre-tool-use",
    "PostToolUse": "post-tool-use",
    "PermissionRequest": "permission-request",
    "UserPromptSubmit": "user-prompt-submit",
    "Stop": "stop",
    "PostCompaction": "post-compaction",
    "SessionStart": "session-start",
    "SessionEnd": "session-end",
}
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PORT = os.environ.get("AUTONOM_PORT", "8080")


class HookError(Exception):
    pass


def block(reason):
    return {"decision": "block", "reason": reason}


def mcp_token(session):
    directory = os.environ.get("AUTONOM_DATA_DIR", "")
    if not directory or not isinstance(session, str) or not session:
        return ""

    path = os.path.join(directory, "mcp", session + ".token")
    if not os.path.exists(path):
        return ""

    try:
        with open(path) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def call(method, path, body=None, session=None):
    headers = {"x-autonom-run": os.environ.get("AUTONOM_RUN_TOKEN", "")}
    if session is None and isinstance(body, dict):
        session = body.get("session_id")
    if isinstance(session, str) and session:
        headers["x-autonom-session"] = session
        token = mcp_token(session)
        if token:
            headers["x-autonom-mcp"] = token
    data = json.dumps(body).encode() if body is not None else None
    if data is not None:
        headers["content-type"] = "application/json"
    request = urllib.request.Request(
        "http://127.0.0.1:{}{}".format(PORT, path), data=data, headers=headers, method=method
    )
    try:
        with HTTP.open(request, timeout=10) as response:
            text = response.read(REPLY_LIMIT + 1)
    except Exception:
        raise HookError("Autonom hook transport failed")

    if len(text) > REPLY_LIMIT:
        raise HookError("Autonom hook reply was too large")

    try:
        result = json.loads(text or b"{}")
    except ValueError:
        raise HookError("Autonom hook reply was invalid")
    if not isinstance(result, dict):
        raise HookError("Autonom hook reply was invalid")

    return result


def forward(data, event):
    path = PATHS.get(event)
    if path is None:
        raise HookError("Unknown Autonom hook")

    result = call("POST", "/api/hooks/" + path, data)
    permission = result.get("permission")
    if not permission:
        return result

    session = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    deadline = time.monotonic() + PERMISSION_TIMEOUT
    while time.monotonic() < deadline:
        result = call("GET", "/api/permissions/" + str(permission), session=session)
        if result.get("decision"):
            return {"decision": result["decision"], "reason": result.get("reason", "")}

        time.sleep(0.5)

    return block("Permission request expired without a user decision")


def expected_event():
    argv = sys.argv[1:]
    if "--event" in argv:
        index = argv.index("--event")
        if index + 1 < len(argv):
            return argv[index + 1]

    return None


def run():
    data = {}
    event = None
    expected = expected_event()
    try:
        text = sys.stdin.buffer.read(INPUT_LIMIT + 1)
        if len(text) > INPUT_LIMIT:
            raise HookError("Hook input is too large")

        data = json.loads(text or b"{}")
        if not isinstance(data, dict):
            raise HookError("Invalid hook input")

        event = data.get("hook_event_name")
        session = data.get("session_id")
        if not os.environ.get("AUTONOM_RUN_TOKEN") and not mcp_token(session):
            coordination = str(data.get("tool_name") or "").startswith(COORDINATION_PREFIXES)
            result = block(
                "Only sessions started by Autonom may use Autonom tools") if coordination else {}
        else:
            if expected and event != expected:
                raise HookError("Hook event does not match the registered hook")
            if not isinstance(event, str):
                raise HookError("Invalid hook input")

            result = forward(data, event)
            if not isinstance(result, dict):
                raise HookError("Autonom hook reply was invalid")
    except Exception:
        sensitive = (expected or event) in SENSITIVE
        result = block("Autonom hook is unavailable; the request was not authorized") if sensitive else {}

    sys.stdout.write(json.dumps(result) + "\n")


if __name__ == "__main__":
    run()
