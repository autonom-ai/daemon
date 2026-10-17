module daemon.interop.mcp;

import daemon.exception;
import daemon.http;
import daemon.api;
import serverino;

import std.algorithm.searching : canFind;
import std.file : thisExePath;
import std.json : JSONType, JSONValue;
import std.path : buildPath, dirName;
import std.uuid : UUID;

public:

enum MCP_SERVER_NAME = "autonom-coord";

string mcpServerPath()
    => buildPath(dirName(dirName(thisExePath)), "source", "mcp", "server.py");

JSONValue coordServer(string port, string token)
    => JSONValue([
        "name": JSONValue(MCP_SERVER_NAME),
        "command": JSONValue("python3"),
        "args": JSONValue([JSONValue(mcpServerPath())]),
        "env": JSONValue([
            JSONValue(["name": JSONValue("AUTONOM_PORT"), "value": JSONValue(port)]),
            JSONValue(["name": JSONValue("AUTONOM_MCP_TOKEN"), "value": JSONValue(token)]),
            JSONValue(["name": JSONValue("AUTONOM_RUN_TOKEN"), "value": JSONValue("")]),
            JSONValue(["name": JSONValue("AUTONOM_CLIENT_TOKEN"), "value": JSONValue("")])
        ])
    ]);

JSONValue injectCoord(JSONValue params, string port, string token)
{
    JSONValue[] servers;
    if ("mcpServers" in params.object && params["mcpServers"].type == JSONType.array)
    {
        foreach (entry; params["mcpServers"].array)
        {
            if (entry.type != JSONType.object || "name" !in entry.object ||
                entry["name"].type != JSONType.string || entry["name"].str != MCP_SERVER_NAME)
                servers ~= entry;
        }
    }

    servers ~= coordServer(port, token);
    params["mcpServers"] = JSONValue(servers);
    return params;
}

@endpoint @route!"/api/mcp/session"
void mcpSession(Request request, Output output)
{
    if (!acceptMethod(request, output, [Request.Method.Get]))
        return;

    string session = bridge.access.mcpSession(request.header.read("x-autonom-mcp"));
    if (!session.length)
    {
        respondError(output, 403, "MCP capability is not bound to a session");
        return;
    }

    respond(output, JSONValue(["id": JSONValue(session)]));
}
