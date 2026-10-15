import fcntl
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path


class Agent:
    def __init__(self):
        environment = {name: value for name, value in os.environ.items()
                       if not name.startswith(("ACP_", "WINDSURF_", "VSCODE_", "ELECTRON_"))}
        self.process = subprocess.Popen(["/home/cet/.local/bin/devin", "acp"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=environment, cwd="/tmp")
        self.messages = queue.Queue()
        self.responses = {}
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.messages.put(json.loads(line))
        self.messages.put({"eof": True})

    def send(self, identity, method, parameters):
        message = {"jsonrpc": "2.0", "method": method, "params": parameters}
        if identity is not None:
            message["id"] = identity
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, identity, timeout=120):
        if identity in self.responses:
            return self.responses.pop(identity)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.1, deadline - time.monotonic()))
            if message.get("eof"):
                raise RuntimeError("Agent exited before response")
            if message.get("id") == identity and "method" not in message:
                return message
            if "id" in message and "method" not in message:
                self.responses[message["id"]] = message
            if "method" in message and "id" in message:
                result = {"outcome": {"outcome": "cancelled"}}
                response = {"jsonrpc": "2.0", "id": message["id"]}
                if message["method"] == "session/request_permission":
                    response["result"] = result
                else:
                    response["error"] = {"code": -32601, "message": "Unsupported probe service"}
                self.process.stdin.write(json.dumps(response).encode() + b"\n")
                self.process.stdin.flush()

    def call(self, identity, method, parameters):
        self.send(identity, method, parameters)
        return self.receive(identity)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=10)


def locked(session):
    root = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
    path = root / "devin/cli/session_locks" / (session + ".lock")
    if not path.exists():
        return {"exists": False, "held": False}
    with path.open("rb") as stream:
        holder = stream.read().decode(errors="replace")
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"exists": True, "held": True, "holder": holder}
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        return {"exists": True, "held": False, "holder": holder}


def report(label, result):
    print(json.dumps({"label": label, "result": result}), flush=True)


def main():
    first = Agent()
    second = None
    session = None
    try:
        report("initialize", first.call(1, "initialize", {"protocolVersion": 1,
               "clientCapabilities": {}, "clientInfo": {"name": "autonom-ownership-probe", "version": "1"}}))
        created = first.call(2, "session/new", {"cwd": "/tmp", "mcpServers": []})
        session = created["result"]["sessionId"]
        report("new_session", {"sessionId": session, "pid": first.process.pid, "lock": locked(session)})
        configured = first.call(3, "session/set_config_option", {
            "sessionId": session, "configId": "model", "value": "swe-2-high"})
        report("model", {"id": configured.get("id"), "error": configured.get("error"),
                         "currentValue": next((option.get("currentValue")
                         for option in configured.get("result", {}).get("configOptions", [])
                         if option.get("id") == "model"), None)})
        report("prompt", first.call(4, "session/prompt", {"sessionId": session,
               "prompt": [{"type": "text", "text": "Reply exactly OWNERSHIP-READY. Do not use tools."}]}))
        report("idle_lock", locked(session))
        second = Agent()
        second.call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        report("second_load_while_first_idle", second.call(2, "session/load", {
               "sessionId": session, "cwd": "/tmp", "mcpServers": []}))
        report("lock_after_second_load", locked(session))
        second.close()
        second = None
        report("first_end", first.call(5, "session/end", {"sessionId": session}))
        report("lock_after_end", locked(session))
        report("first_close", first.call(6, "session/close", {"sessionId": session}))
        report("lock_after_close", locked(session))
    finally:
        if second is not None:
            second.close()
        first.close()
        if session is not None:
            report("lock_after_process_exit", locked(session))


def steering():
    agent = Agent()
    try:
        agent.call(1, "initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        session = agent.call(2, "session/new", {"cwd": "/tmp", "mcpServers": []})["result"]["sessionId"]
        agent.call(3, "session/set_config_option", {
            "sessionId": session, "configId": "model", "value": "swe-2-high"})
        agent.call(4, "session/set_config_option", {
            "sessionId": session, "configId": "mode", "value": "bypass"})
        report("steer_session", {"sessionId": session, "pid": agent.process.pid})
        agent.send(5, "session/prompt", {"sessionId": session, "prompt": [{
            "type": "text", "text": "Use the exec tool to run sleep 5. After it finishes reply FIRST-DONE. "
            "Do not write any files."}]})
        deadline = time.monotonic() + 60
        observed = False
        while time.monotonic() < deadline:
            message = agent.messages.get(timeout=10)
            if message.get("method") == "session/update":
                update = message.get("params", {}).get("update", {})
                if update.get("sessionUpdate") == "tool_call":
                    report("first_tool_call", {"title": update.get("title"), "status": update.get("status")})
                    observed = True
                    break
            if message.get("id") == 5:
                agent.responses[5] = message
                break
        report("active_before_steer", {"toolCallObserved": observed, "firstResponseReceived": 5 in agent.responses})
        agent.send(6, "session/prompt", {"sessionId": session, "prompt": [{
            "type": "text", "text": "Additional instruction: after finishing sleep 5, reply SECOND-DONE "
            "instead of FIRST-DONE. Do not run additional tools."}]})
        report("original_prompt_response", agent.receive(5))
        report("steer_prompt_response", agent.receive(6))
    finally:
        agent.close()


if __name__ == "__main__":
    steering() if "--steer" in sys.argv else main()
