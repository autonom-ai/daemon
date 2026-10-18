#!/usr/bin/env python3
import fcntl
import json
import os
import sqlite3
import sys
import threading
import time
import urllib.request

ROOT = os.environ.get("AUTONOM_FAKE_DIR", os.getcwd())
LOCK_DIR = os.environ.get("AUTONOM_FAKE_LOCKDIR", os.path.join(ROOT, "locks"))
DATABASE = os.environ.get("CHISEL_SESSION_DB", os.path.join(os.path.dirname(LOCK_DIR), "sessions.db"))
if os.environ.get("CHISEL_SESSION_DB"):
    LOCK_DIR = os.path.join(os.path.dirname(DATABASE), "session_locks")
PORT = os.environ.get("AUTONOM_PORT", "8080")

CONFIG_OPTIONS = [
    {
        "id": "mode",
        "name": "Mode",
        "type": "select",
        "options": [
            {"value": "accept-edits", "name": "Accept Edits"},
            {"value": "smart", "name": "Smart"},
            {"value": "ask", "name": "Ask"},
            {"value": "plan", "name": "Plan"},
            {"value": "bypass", "name": "Bypass"}
        ]
    },
    {
        "id": "model",
        "name": "Model",
        "type": "select",
        "options": [
            {"value": "swe-2-high", "name": "SWE-2 High"},
            {"value": "SWE-2", "name": "SWE-2"}
        ]
    }
]

locks = {}
pending = {}
timers = {}
permitted = {}
probes = {}
out_lock = threading.Lock()


def path(name):
    return os.path.join(ROOT, name)


def save_session(session_id, directory=None, meta=None):
    os.makedirs(os.path.dirname(DATABASE), exist_ok=True)
    with sqlite3.connect(DATABASE) as connection:
        connection.execute("create table if not exists sessions (id text primary key, model text default '', "
                           "working_directory text, title text default '', agent_mode text default 'ask', "
                           "backend_type text default 'windsurf', created_at integer default 0, "
                           "last_activity_at integer default 0, hidden integer default 0, "
                           "workspace_dirs text default '[]', main_chain_id integer, metadata text)")
        connection.execute("insert or ignore into sessions (id, working_directory) values (?, ?)",
                           (session_id, directory or ROOT))
        if meta is not None:
            connection.execute("update sessions set metadata = ? where id = ?",
                               (json.dumps({"client_meta": meta}), session_id))


def send(message):
    with out_lock:
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()


def send_result(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def send_error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id,
          "error": {"code": code, "message": message}})


def update(session_id, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": session_id,
        "update": {"sessionUpdate": "agent_message_chunk",
                   "content": {"type": "text", "text": text}}}})


def hold_lock(session_id):
    if session_id in locks:
        return
    os.makedirs(LOCK_DIR, exist_ok=True)
    handle = open(os.path.join(LOCK_DIR, session_id + ".lock"), "w+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return
    locks[session_id] = handle


def record_call(entry):
    try:
        with open(path("acp-calls.jsonl"), "a") as handle:
            handle.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def record_prompt(session_id, text):
    record_call({"method": "session/prompt", "sessionId": session_id, "text": text})


def hook_post(payload):
    token = os.environ.get("AUTONOM_RUN_TOKEN", "")
    request = urllib.request.Request(
        "http://127.0.0.1:%s/api/hooks/session-start" % PORT,
        data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "x-autonom-run": token})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status
    except Exception:
        return 0


def finish(request_id, session_id, stop_reason="end_turn"):
    send_result(request_id, {"sessionId": session_id, "stopReason": stop_reason})


def on_prompt(request_id, params):
    session_id = params.get("sessionId", "")
    text = "\n".join(block.get("text", "") for block in params.get("prompt", []))
    record_prompt(session_id, text)

    if text == "exit-after-reply":
        finish(request_id, session_id)
        raise SystemExit(0)

    if os.path.exists(path("fail-prompt")) or text == "fail":
        update(session_id, text)
        send_error(request_id, -32603, "prompt failed")
        return
    if text == "callback":
        status = hook_post({"hook_event_name": "SessionStart"})
        try:
            with open(path("callback.txt"), "w") as handle:
                handle.write(str(status))
        except OSError:
            pass
        update(session_id, "AUTONOM_READY")
        finish(request_id, session_id)
        return
    if text in ("permission", "cancel-permission"):
        request_key = "fake-permission-%d" % request_id if isinstance(request_id, int) \
            else "fake-permission"
        permitted[json.dumps(request_key)] = (request_id, session_id)
        send({"jsonrpc": "2.0", "id": request_key,
              "method": "session/request_permission",
              "params": {"sessionId": session_id,
                         "toolCall": {"toolCallId": "tool-1", "title": "Run command"},
                         "options": [{"optionId": "approve", "kind": "allow_once",
                                      "name": "Approve"},
                                     {"optionId": "reject_once", "kind": "reject_once",
                                      "name": "Reject"}]}})
        if text == "cancel-permission":
            send({"jsonrpc": "2.0", "method": "$/cancel_request",
                  "params": {"requestId": request_key}, "_meta": {"extension": True}})
        return
    if text == "probe-unknown":
        request_key = "fake-probe"
        probes[json.dumps(request_key)] = (request_id, session_id)
        send({"jsonrpc": "2.0", "id": request_key, "method": "bogus/probe",
              "params": {}})
        return
    if text.startswith("sleep "):
        try:
            delay = float(text.split()[1])
        except (ValueError, IndexError):
            delay = 1.0
        timer = threading.Timer(delay, lambda: (pending.pop(request_id, None),
                                                finish(request_id, session_id)))
        timers[request_id] = timer
        pending[request_id] = session_id
        timer.start()
        return
    if text.startswith("auth:") or text == "hang":
        pending[request_id] = session_id
        return
    if text == "/compact":
        if os.path.exists(path("fail-compact")):
            send_error(request_id, -32603, "compaction failed")
            return
        if os.path.exists(path("hang-compact")):
            pending[request_id] = session_id
            return
        update(session_id, "COMPACTED")
        finish(request_id, session_id)
        return

    update(session_id, text)
    finish(request_id, session_id)


def new_session_id():
    marker = path("next-session-id")
    listed = True
    if os.path.exists(marker):
        with open(marker) as handle:
            session_id = handle.read().strip()
        os.remove(marker)
        listed = False
    else:
        count = 0
        listing = path("sessions.txt")
        if os.path.exists(listing):
            with open(listing) as handle:
                count = len([line for line in handle if line.strip()])
        session_id = "created-%d" % count

    if listed:
        with open(path("sessions.txt"), "a") as handle:
            handle.write(session_id + "\n")
    with open(path(session_id + ".token"), "w") as handle:
        handle.write(os.environ.get("AUTONOM_RUN_TOKEN", ""))
    return session_id


def acp_main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue

        request_id = message.get("id")
        method = message.get("method")
        if method is None:
            if request_id is None:
                continue
            key = json.dumps(request_id)
            if key in permitted:
                original, session_id = permitted.pop(key)
                option = "none"
                outcome = message.get("result", {}).get("outcome", {})
                if outcome.get("outcome") == "selected":
                    option = outcome.get("optionId", "none")
                update(session_id, "PERM:%s" % option)
                finish(original, session_id)
            elif key in probes:
                original, session_id = probes.pop(key)
                code = message.get("error", {}).get("code", 0)
                update(session_id, "CODE:%s" % code)
                finish(original, session_id)
            continue

        params = message.get("params") or {}
        if method == "initialize":
            send_result(request_id, {"protocolVersion": 1,
                                     "agentCapabilities": {"loadSession": True}})
        elif method == "session/new":
            if os.path.exists(path("fail-new")):
                send_error(request_id, -32603, "session creation failed")
                continue
            session_id = new_session_id()
            save_session(session_id, params.get("cwd"), params.get("_meta"))
            record_call({"method": "session/new", "sessionId": session_id})
            hold_lock(session_id)
            send_result(request_id, {"sessionId": session_id,
                                     "configOptions": CONFIG_OPTIONS})
        elif method == "session/load":
            session_id = params.get("sessionId", "")
            save_session(session_id, params.get("cwd"), params.get("_meta"))
            record_call({"method": "session/load", "sessionId": session_id})
            if os.path.exists(path("fail-load")) or "locked" in session_id:
                send_error(request_id, -32015, "session_locked")
                continue
            hold_lock(session_id)
            send_result(request_id, {"sessionId": session_id,
                                     "configOptions": CONFIG_OPTIONS})
            replay = path("replay.txt")
            if os.path.exists(replay):
                with open(replay) as handle:
                    update(session_id, handle.read())
        elif method == "session/prompt":
            on_prompt(request_id, params)
        elif method == "session/cancel":
            for key, session_id in list(pending.items()):
                if key in timers:
                    timers[key].cancel()
                send_result(key, {"sessionId": session_id, "stopReason": "cancelled"})
            pending.clear()
            timers.clear()
        elif method == "$/cancel_request":
            identity = params.get("requestId")
            if identity in pending:
                if identity in timers:
                    timers.pop(identity).cancel()
                finish(identity, pending.pop(identity), "cancelled")
        elif method == "session/set_config_option":
            record_call({"method": "session/set_config_option",
                         "sessionId": params.get("sessionId"),
                         "configId": params.get("configId"),
                         "value": params.get("value")})
            with open(path("config-options.jsonl"), "a") as handle:
                handle.write(json.dumps({"sessionId": params.get("sessionId"),
                                         "configId": params.get("configId"),
                                         "value": params.get("value")}) + "\n")
            send_result(request_id, {"configOptions": CONFIG_OPTIONS})
        elif method == "session/delete":
            send_result(request_id, {})
        else:
            send_error(request_id, -32601, "method not found")
    return 0


def cli_main():
    argv = sys.argv[1:]
    try:
        with open(path("invocations.txt"), "a") as handle:
            handle.write("\n".join(argv) + "\n---\n")
    except OSError:
        pass

    if os.path.exists(path("want-environ")):
        with open(path("environ.txt"), "w") as handle:
            handle.write("\n".join("%s=%s" % item for item in os.environ.items()))

    if argv[:1] == ["acp"]:
        return acp_main()
    if argv[:1] == ["list"]:
        listing = path("sessions.txt")
        sessions = ["session-1", "session-2"]
        if os.path.exists(listing):
            with open(listing) as handle:
                sessions = [line.strip() for line in handle if line.strip()]
        sys.stdout.write(json.dumps([{"id": item} for item in sessions]) + "\n")
        sys.stderr.write("noise\n")
        return 0
    if argv[:1] == ["slow"]:
        time.sleep(5)
        return 0
    if argv[:1] == ["rm"]:
        target = argv[-1] if argv else ""
        if target == "missing":
            sys.stderr.write("no session\n")
            return 1
        with open(path("removed.txt"), "w") as handle:
            handle.write("\n".join(argv) + "\n")
        return 0
    if argv[:1] == ["models"]:
        sys.stdout.write(json.dumps({"models": [
            {"id": "swe-2-high", "name": "SWE-2 High", "default": True}]}))
        return 0

    sys.stderr.write("unknown args\n")
    return 1


if __name__ == "__main__":
    sys.exit(cli_main())
