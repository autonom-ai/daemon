"""autonom-coord MCP server.

Speaks the Model Context Protocol over stdio and proxies tool calls to the
autonom daemon's HTTP API. Managed sessions receive a daemon-issued
``AUTONOM_MCP_TOKEN`` in their server environment; the daemon resolves it to
the owning session, so tool arguments never carry a session ID. Unmanaged
processes advertise no tools. A tool call starts the daemon when it is not
already listening.
"""

import json
import os
import sys

import coord
import daemon
from tools import TOOLS

INFO = {"name": "autonom-coord", "version": "0.1.0"}
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
DEFAULT_PROTOCOL = "2025-03-26"


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
        return success(request_id, {"tools": TOOLS if os.environ.get("AUTONOM_MCP_TOKEN") else []})
    if method == "tools/call":
        return success(
            request_id,
            coord.call_tool(params.get("name") or "", params.get("arguments") or {}),
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
    if sys.argv[1:] == ["--ensure"]:
        if not daemon.ensure():
            sys.stderr.write("Autonom did not become ready; check " + daemon.log_path() + "\n")
            sys.exit(1)

        with daemon.HTTP.open(daemon.url("/api/health"), timeout=daemon.TIMEOUT_SECONDS) as response:
            sys.stdout.write(response.read().decode() + "\n")
    else:
        run()
