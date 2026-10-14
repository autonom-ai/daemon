"""autonom-acp: the Autonom agent as an Agent Client Protocol server.

Speaks newline-delimited JSON-RPC over stdio and proxies every session to the
Autonom daemon, so sessions are daemon-owned: they receive a run token, register
their profile on the first hook, and stay eligible for scheduled wakes.

The adapter cannot run alone: it needs the launcher's private ``--socket`` so
the daemon capability never leaves the launcher process.
"""

import argparse
import base64
import json
import os
import queue
import signal
import socket
import sys
import threading
import time
from urllib.parse import quote

AGENT_NAME = "Autonom"
AGENT_VERSION = "0.1.0"
AGENT_ID = "devin-autonom"
DEFAULT_MODEL = "swe-2-medium"
MAX_FRAME_BYTES = 16 * 1024 * 1024


class ProtocolError(ValueError):
    pass


class DaemonError(RuntimeError):
    pass


def read_frame(stream):
    while True:
        ret = stream.readline(MAX_FRAME_BYTES + 1)
        if len(ret) > MAX_FRAME_BYTES:
            raise ProtocolError("JSON-RPC frame exceeded the size limit")
        if not ret or ret.strip():
            return ret or None


def decode_frame(frame):
    try:
        ret = json.loads(frame)
    except (ValueError, UnicodeError, RecursionError):
        raise ProtocolError("Invalid JSON-RPC frame") from None
    if not isinstance(ret, dict) or ret.get("jsonrpc") != "2.0":
        raise ProtocolError("Invalid JSON-RPC envelope")
    if "id" in ret and type(ret["id"]) not in (int, str):
        raise ProtocolError("Invalid JSON-RPC identifier")
    return ret


class LauncherBridge:
    def __init__(self, socket_path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(socket_path)
        self.pending = {}
        self.pending_lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.sequence = 0
        self.closed = threading.Event()
        self.closing = threading.Event()
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def request(self, path, method="GET", body=None):
        if self.closed.is_set():
            raise DaemonError("Autonom launcher is not running")
        with self.pending_lock:
            self.sequence += 1
            identifier = f"acp-{os.getpid()}-{self.sequence}"
            response = queue.Queue(maxsize=1)
            self.pending[identifier] = response
        message = {"id": identifier, "action": "request", "path": path, "method": method}
        if body is not None:
            message["body"] = body
        try:
            with self.write_lock:
                self.socket.sendall(json.dumps(message, separators=(",", ":")).encode() + b"\n")
            try:
                result = response.get(timeout=30)
            except queue.Empty:
                raise DaemonError("Autonom launcher request timed out") from None
            if isinstance(result, Exception):
                raise result
            return result
        except OSError:
            raise DaemonError("Autonom launcher is not running") from None
        finally:
            with self.pending_lock:
                self.pending.pop(identifier, None)

    def read(self):
        buffered = b""
        try:
            while True:
                chunk = self.socket.recv(65536)
                if not chunk:
                    break
                buffered += chunk
                if len(buffered) > MAX_FRAME_BYTES:
                    break
                while b"\n" in buffered:
                    frame, buffered = buffered.split(b"\n", 1)
                    if not frame:
                        continue
                    if len(frame) > MAX_FRAME_BYTES:
                        return
                    message = json.loads(frame)
                    identifier = message.get("id")
                    with self.pending_lock:
                        response = self.pending.get(identifier)
                    if response is None:
                        continue
                    if "error" in message:
                        response.put_nowait(DaemonError(str(message["error"])))
                    else:
                        response.put_nowait(message.get("result"))
        except (OSError, ValueError, TypeError):
            pass
        finally:
            self.closed.set()
            with self.pending_lock:
                for response in self.pending.values():
                    if response.empty():
                        response.put_nowait(DaemonError("Autonom launcher disconnected"))
            if not self.closing.is_set():
                os.kill(os.getpid(), signal.SIGTERM)

    def close(self):
        self.closing.set()
        self.socket.close()


class Relay:
    def __init__(self, agent, workspace, session=None, model=DEFAULT_MODEL):
        self.agent = agent
        body = {"directory": workspace, "model": model}
        if session:
            body["sessionId"] = session
        self.execution = agent.launcher.request("/api/acp", "POST", body)["id"]
        self.waiters = {}
        self.waiter_lock = threading.Lock()
        self.closed = threading.Event()
        self.close_lock = threading.Lock()
        self.finished = False
        self.replaying = True
        self.sequence = 0
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def send(self, frame):
        if self.closed.is_set():
            raise DaemonError("Native ACP transport is closed")
        self.agent.launcher.request(f"/api/acp/{self.execution}", "POST", frame)

    def call(self, method, params, identifier=None):
        self.sequence += 1
        if identifier is None:
            identifier = f"autonom-internal-{self.sequence}"
        response = queue.Queue(maxsize=1)
        with self.waiter_lock:
            self.waiters[identifier] = response
        try:
            self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
            try:
                ret = response.get(timeout=1800 if method == "session/prompt" else 30)
            except queue.Empty:
                raise DaemonError("Native ACP request timed out") from None
            if isinstance(ret, Exception):
                raise ret
            return ret
        finally:
            with self.waiter_lock:
                self.waiters.pop(identifier, None)

    def read(self):
        offset = 0
        buffered = b""
        try:
            while not self.closed.is_set():
                record = self.agent.launcher.request(f"/api/acp/{self.execution}?offset={offset}")
                offset = record["offset"]
                buffered += base64.b64decode(record["data"], validate=True)
                while b"\n" in buffered:
                    frame, buffered = buffered.split(b"\n", 1)
                    if not frame.strip():
                        continue
                    if len(frame) > MAX_FRAME_BYTES:
                        raise ProtocolError("Native ACP frame exceeded the size limit")
                    message = decode_frame(frame)
                    identifier = message.get("id")
                    if "method" in message:
                        if identifier is not None:
                            forwarded = f"autonom-rpc:{self.execution}:{identifier}"
                            with self.agent.lock:
                                self.agent.responses[forwarded] = (self, identifier)
                            message["id"] = forwarded
                            self.agent.send(message)
                        elif not self.replaying:
                            self.agent.send(message)
                    else:
                        with self.waiter_lock:
                            waiter = self.waiters.get(identifier)
                        if waiter is not None:
                            waiter.put_nowait(message)
                if len(buffered) > MAX_FRAME_BYTES:
                    raise ProtocolError("Native ACP frame exceeded the size limit")
                if record["execution"]["status"] not in ("running", "stopping"):
                    raise DaemonError("Native ACP execution ended")
                self.closed.wait(0.05)
        except (DaemonError, ProtocolError, ValueError, KeyError):
            self.closed.set()
            self.fail_waiters()

    def fail_waiters(self):
        with self.waiter_lock:
            for waiter in self.waiters.values():
                if waiter.empty():
                    waiter.put_nowait(DaemonError("Native ACP transport disconnected"))

    def close(self):
        with self.close_lock:
            if self.finished:
                return
            self.closed.set()
            self.fail_waiters()
            try:
                self.agent.launcher.request(f"/api/executions/{self.execution}/stop", "POST", {})
                deadline = time.monotonic() + 10
                while self.agent.launcher.request(f"/api/executions/{self.execution}")["status"] in ("running", "stopping"):
                    if time.monotonic() >= deadline:
                        raise DaemonError("Native ACP did not release its session")
                    time.sleep(0.05)
            finally:
                self.finished = True
                self.thread.join(timeout=16)
                with self.agent.lock:
                    self.agent.relays.discard(self)
                    for identifier, (relay, _) in list(self.agent.responses.items()):
                        if relay is self:
                            self.agent.responses.pop(identifier)


class Session:
    def __init__(self, params, model=DEFAULT_MODEL):
        self.params = params
        self.model = model
        self.options = {}
        self.lock = threading.Lock()
        self.cancelled = threading.Event()
        self.relay = None
        self.last_node_id = 0
        self.title = None


class Agent:
    def __init__(self, launcher, workspace):
        self.launcher = launcher
        self.workspace = workspace
        self.initialize = None
        self.sessions = {}
        self.relays = set()
        self.responses = {}
        self.lock = threading.Lock()
        self.output_lock = threading.Lock()
        self.stopping = threading.Event()

    def send(self, message):
        with self.output_lock:
            sys.stdout.buffer.write(json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode() + b"\n")
            sys.stdout.buffer.flush()

    @staticmethod
    def text_content(value):
        if isinstance(value, str):
            return value
        if isinstance(value, list):
            return "\n".join(block["text"] for block in value
                             if isinstance(block, dict) and block.get("type") == "text"
                             and isinstance(block.get("text"), str))
        return ""

    def emit_update(self, session_id, update):
        self.send({"jsonrpc": "2.0", "method": "session/update",
                   "params": {"sessionId": session_id, "update": update}})

    def sync_transcript(self, session_id, session, seed=False):
        record = self.launcher.request(f"/api/client/transcript/{quote(session_id, safe='')}")
        messages = record.get("messages")
        if not isinstance(messages, list):
            raise DaemonError("Autonom returned an invalid transcript")

        metadata = record.get("session")
        title = metadata.get("title") if isinstance(metadata, dict) else None
        if isinstance(title, str) and title and title != session.title:
            if not seed:
                self.emit_update(session_id, {"sessionUpdate": "session_info_update", "title": title})
            session.title = title

        newest = session.last_node_id
        for message in messages:
            if not isinstance(message, dict) or type(message.get("nodeId")) is not int:
                continue

            node_id = message["nodeId"]
            newest = max(newest, node_id)
            if seed or node_id <= session.last_node_id:
                continue

            role = message.get("role")
            update_type = {"user": "user_message_chunk", "assistant": "agent_message_chunk"}.get(role)
            text = self.text_content(message.get("content"))
            if update_type and text:
                self.emit_update(session_id, {
                    "sessionUpdate": update_type,
                    "content": {"type": "text", "text": text},
                })
            thought = self.text_content(message.get("reasoning_content")) if role == "assistant" else ""
            if thought:
                self.emit_update(session_id, {
                    "sessionUpdate": "agent_thought_chunk",
                    "content": {"type": "text", "text": thought},
                })

        session.last_node_id = newest

    def poll_transcripts(self):
        while not self.stopping.wait(1):
            with self.lock:
                sessions = list(self.sessions.items())
            for session_id, session in sessions:
                if self.stopping.is_set():
                    return
                if not session.lock.acquire(blocking=False):
                    continue
                try:
                    self.sync_transcript(session_id, session)
                except BrokenPipeError:
                    self.stopping.set()
                    return
                except (DaemonError, KeyError, TypeError, ValueError):
                    continue
                finally:
                    session.lock.release()

    def open(self, session=None, identifier=None, replay=False):
        if self.stopping.is_set():
            raise DaemonError("Autonom adapter is stopping")
        params = session.params if session else {"cwd": self.workspace}
        relay = Relay(self, params["cwd"], identifier, session.model if session else DEFAULT_MODEL)
        with self.lock:
            self.relays.add(relay)
        try:
            if self.stopping.is_set():
                raise DaemonError("Autonom adapter is stopping")
            relay.result = relay.call("initialize", self.initialize)
            if "error" in relay.result:
                raise DaemonError("Native ACP initialization failed")
            if identifier:
                relay.replaying = not replay
                relay.result = relay.call("session/load", {**params, "sessionId": identifier})
                if "error" in relay.result:
                    raise DaemonError("Native ACP session load failed")
                for method, option in session.options.items():
                    result = relay.call(method, {"sessionId": identifier, **option})
                    if "error" in result:
                        raise DaemonError("Native ACP session option failed")
            return relay
        except Exception:
            relay.close()
            raise

    def handle(self, message):
        method = message.get("method")
        identifier = message.get("id")
        params = message.get("params") or {}
        relay = None
        session = None
        acquired = None
        try:
            if method == "initialize":
                self.initialize = params
                relay = self.open()
                result = relay.result
                if "result" in result:
                    result["result"]["agentInfo"] = {"name": AGENT_NAME, "title": AGENT_NAME, "version": AGENT_VERSION}
                    result["result"]["agentCapabilities"]["sessionCapabilities"] = {}
                    result["result"]["agentCapabilities"].pop("_meta", None)
            elif method in ("session/new", "session/load"):
                session_id = params.get("sessionId") if method == "session/load" else None
                session = Session({"cwd": params.get("cwd") or self.workspace, "mcpServers": params.get("mcpServers", [])})
                acquired = session.lock
                acquired.acquire()
                relay = self.open(session, session_id, replay=method == "session/load")
                relay.replaying = False
                result = relay.call(method, params) if method == "session/new" else relay.result
                if "result" in result:
                    session_id = session_id or result["result"]["sessionId"]
                    self.launcher.request(f"/api/acp/{relay.execution}/bind", "POST", {"sessionId": session_id})
                    self.sync_transcript(session_id, session, seed=True)
                    with self.lock:
                        self.sessions[session_id] = session
            else:
                session_id = params.get("sessionId")
                session = self.sessions.get(session_id)
                if session is None:
                    raise ProtocolError("Unknown Autonom session")
                if not session.lock.acquire(blocking=False):
                    raise ProtocolError("Autonom session already has an active request")
                acquired = session.lock
                session.cancelled.clear()
                relay = self.open(session, session_id)
                with self.lock:
                    session.relay = relay
                if session.cancelled.is_set():
                    raise DaemonError("Autonom request cancelled")
                relay.replaying = False
                result = relay.call(method, params)
                if "result" in result and method in ("session/set_config_option", "session/set_mode"):
                    session.options[method] = {name: value for name, value in params.items() if name != "sessionId"}
                    if method == "session/set_config_option" and params.get("configId") == "model":
                        session.model = params["value"]
                elif "result" in result and method == "session/prompt":
                    relay.close()
                    relay = None
                    self.sync_transcript(session_id, session, seed=True)
            relay.close()
            relay = None
            self.send({"jsonrpc": "2.0", "id": identifier, **{key: value for key, value in result.items()
                                                             if key in ("result", "error")}})
        except (DaemonError, ProtocolError, KeyError, TypeError):
            if identifier is not None:
                if session and session.cancelled.is_set() and method == "session/prompt":
                    if relay is not None:
                        relay.close()
                        relay = None
                    self.send({"jsonrpc": "2.0", "id": identifier, "result": {"stopReason": "cancelled"}})
                else:
                    self.send({"jsonrpc": "2.0", "id": identifier,
                               "error": {"code": -32603, "message": "Autonom could not complete the native ACP request"}})
        finally:
            try:
                if relay is not None:
                    relay.close()
            finally:
                if acquired is not None:
                    with self.lock:
                        session.relay = None
                    acquired.release()

    def serve(self):
        workers = []
        poller = threading.Thread(target=self.poll_transcripts, daemon=True)
        poller.start()
        try:
            while (frame := read_frame(sys.stdin.buffer)) is not None:
                message = decode_frame(frame)
                if "method" not in message:
                    with self.lock:
                        response = self.responses.pop(message.get("id"), None)
                    if response:
                        relay, identifier = response
                        relay.send({**message, "id": identifier})
                elif message["method"] == "session/cancel":
                    with self.lock:
                        session = self.sessions.get((message.get("params") or {}).get("sessionId"))
                        relay = session.relay if session else None
                        cancelled = session.cancelled.is_set() if session else True
                        if session:
                            session.cancelled.set()
                    if relay and not cancelled:
                        worker = threading.Thread(target=relay.close, daemon=True)
                        workers.append(worker)
                        worker.start()
                elif message.get("id") is not None:
                    workers = [worker for worker in workers if worker.is_alive()]
                    if len(workers) >= 8:
                        self.send({"jsonrpc": "2.0", "id": message["id"],
                                   "error": {"code": -32603, "message": "Autonom request capacity reached"}})
                        continue
                    worker = threading.Thread(target=self.handle, args=(message,), daemon=True)
                    workers.append(worker)
                    worker.start()
            return 0
        finally:
            self.stopping.set()
            poller.join(timeout=16)
            with self.lock:
                relays = list(self.relays)
            failure = None
            for relay in relays:
                try:
                    relay.close()
                except DaemonError as error:
                    failure = error
            if failure is not None:
                raise failure


def main():
    parser = argparse.ArgumentParser(description="Autonom native Devin Local hook.")
    parser.add_argument("--workspace", default=os.getcwd())
    parser.add_argument("--socket", default=os.environ.get("AUTONOM_ACP_SOCKET"))
    args = parser.parse_args()
    if not args.socket:
        parser.error("Autonom ACP requires the launcher socket (--socket or AUTONOM_ACP_SOCKET)")
    try:
        return Agent(LauncherBridge(args.socket), os.path.abspath(args.workspace)).serve()
    except (DaemonError, ProtocolError, BrokenPipeError, OSError):
        return 1


if __name__ == "__main__":
    sys.exit(main())
