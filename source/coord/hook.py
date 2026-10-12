import json
import os
import sys
import time

from server import SESSION_CONTEXT, ToolError, call

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


def block(reason):
    return {"decision": "block", "reason": reason}


def forward(data):
    event = data.get("hook_event_name")
    if event not in PATHS:
        raise ToolError("Unknown Autonom hook")

    coordination = str(data.get("tool_name", "")).startswith("mcp__autonom-coord__")
    if not os.environ.get("AUTONOM_RUN_TOKEN"):
        return block("Only sessions started by Autonom may use Autonom tools") if coordination else {}

    token = SESSION_CONTEXT.set(data.get("session_id", ""))
    try:
        result = call("POST", "/api/hooks/" + PATHS[event], data)
        permission = result.get("permission")
        if not permission:
            return result

        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            result = call("GET", "/api/permissions/" + permission)
            if result.get("decision"):
                return {"decision": result["decision"], "reason": result.get("reason", "")}

            time.sleep(0.3)

        return block("Permission request expired without a user decision")
    finally:
        SESSION_CONTEXT.reset(token)


def run():
    data = {}
    try:
        text = sys.stdin.read(1024 * 1024 + 1)
        if len(text) > 1024 * 1024:
            raise ToolError("Hook input is too large")

        data = json.loads(text)
        if not isinstance(data, dict):
            raise ToolError("Invalid hook input")

        result = forward(data)
    except (ToolError, OSError, ValueError):
        event = data.get("hook_event_name") if isinstance(data, dict) else None
        result = block("Autonom hook is unavailable; the request was not authorized") if event in (
            "PreToolUse", "PermissionRequest"
        ) else {}

    sys.stdout.write(json.dumps(result) + "\n")


if __name__ == "__main__":
    run()
